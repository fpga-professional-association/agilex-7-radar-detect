// -----------------------------------------------------------------------------
// test_cdc_synchronizers.cpp — multi-clock unit test for rtl/cdc/cdc_sync2.sv,
// rtl/cdc/cdc_pulse.sv and rtl/cdc/cdc_handshake.sv (SPEC 8, 12.3, 13.1).
//
// SPEC 8 requires "proper synchronizers for single-bit status" and "toggle or
// handshake synchronizers for pulses". The three primitives that satisfy those
// clauses are exercised here across the clock-ratio sweep in
// sim/verilator/harness/clock_ratios.h — 1:1 in phase, 1:1 with a phase offset,
// 2:1, 1:2, 7:3, 3:7 and 100:99 — because a pulse or handshake crossing that
// works at one ratio proves almost nothing about the others. Every phase below
// runs at every ratio.
//
// PHASES
//
//   pulse_paced       Random pulses, offered only while `src_busy` is low —
//                     the contract a flow-controlled producer honours. The
//                     destination must emit EXACTLY one strobe per accepted
//                     pulse: no loss, no duplication, no phantom. `src_overrun`
//                     must stay clear, because nothing was ever refused.
//
//   pulse_overrun     A pulse offered on EVERY source cycle, ignoring busy.
//                     This is the abuse case, and the point is that it is
//                     detected rather than absorbed: the refused pulses must not
//                     corrupt the ones that were accepted (delivered still
//                     equals accepted), `src_overrun` must latch, and the
//                     sticky flag must then clear when told to. A toggle
//                     synchronizer without this instrumentation loses pulses
//                     here silently, which is the defect the module exists to
//                     make visible.
//
//   handshake_burst   `s_valid` held high continuously with a fresh value on
//                     every acceptance — back to back at the crossing's maximum
//                     rate. The destination must observe exactly the values
//                     sent, in order, with none lost, none repeated and none
//                     invented.
//
//   handshake_gapped  The same, with random idle gaps, so the source-side state
//                     machine is exercised returning to idle and restarting
//                     rather than only steady-state cycling.
//
//   status_bit        A single-bit status crossing a domain through cdc_sync2.
//                     The input is held stable for a window long enough for the
//                     destination to have taken several clocks, then the output
//                     is required to equal it. Within a window the output may
//                     change at most once: a synchronizer that glitched, or one
//                     wired to the wrong stage, shows up as a second transition.
//
// Every phase re-runs the two-domain reset first, with different release delays
// per domain, so reset recovery is covered per phase per ratio rather than once.
// -----------------------------------------------------------------------------

#include <algorithm>
#include <chrono>
#include <cstdio>
#include <deque>
#include <memory>
#include <string>
#include <vector>

#include "Vcdc_prims_top.h"
#include "verilated.h"

#include "config_sim.h"
#include "harness/clock_ratios.h"
#include "harness/harness.h"

using harness::ClockRatio;
using harness::ClockScheduler;
using harness::ErrorCollector;
using harness::ResetSequencer;
using harness::RunSummary;
using harness::SeedSource;
using harness::SimArgs;
using harness::SimTime;
using harness::StopReason;

namespace {

constexpr const char* kTestName = "test_cdc_synchronizers";

// Named TestPhase, not Phase: this file's body is inside namespace harness
// (sim_test_main is `harness::sim_test_main`), where `Phase` already names the
// scheduler's sample/drive edge phase.
enum class TestPhase {
  kPulsePaced,
  kPulseOverrun,
  kHandshakeBurst,
  kHandshakeGapped,
  kStatusBit,
};

struct PhaseSpec {
  TestPhase phase;
  const char* name;
  // Source-domain cycles of stimulus, then of quiet drain.
  std::uint64_t drive_cycles;
  std::uint64_t drain_cycles;
};

const std::vector<PhaseSpec>& phase_specs() {
  static const std::vector<PhaseSpec> specs = {
      {TestPhase::kPulsePaced, "pulse_paced", 400, 200},
      {TestPhase::kPulseOverrun, "pulse_overrun", 200, 200},
      {TestPhase::kHandshakeBurst, "handshake_burst", 400, 300},
      {TestPhase::kHandshakeGapped, "handshake_gapped", 400, 300},
      {TestPhase::kStatusBit, "status_bit", 512, 64},
  };
  return specs;
}

// Cycles the status-bit phase holds each value. Long enough that the slowest
// destination clock in the sweep takes many edges inside one window.
constexpr std::uint64_t kStatusWindow = 64;

// Minimum events a phase must produce before it counts as having tested
// anything. A phase that delivered two pulses proves nothing about a crossing.
constexpr std::uint64_t kMinPulses = 8;
constexpr std::uint64_t kMinTransfers = 5;

}  // namespace

// ---------------------------------------------------------------------------
// Test entry point (main() lives in sim/verilator/sim_main.cpp).
// ---------------------------------------------------------------------------
int harness::sim_test_main(const SimArgs& args) {
  const auto wall_start = std::chrono::steady_clock::now();

  std::unique_ptr<Vcdc_prims_top> top(new Vcdc_prims_top);

  // Every input this test does not drive is held at a defined value, so the
  // idle DUTs in the same top present a legal, quiet interface to their own
  // protocol checkers.
  top->f0_s_valid = 0;  top->f0_m_ready = 0;  top->f0_s_data = 0;
  top->f0_sticky_clear = 0;
  top->f1_s_valid = 0;  top->f1_m_ready = 0;  top->f1_s_data = 0;
  top->af_wr_valid = 0; top->af_rd_ready = 0; top->af_wr_data = 0;
  top->af_wr_sticky_clear = 0; top->af_rd_sticky_clear = 0;
  top->cf_s_valid = 0;  top->cf_m_ready = 0;  top->cf_s_payload = 0;
  top->cr_s_valid = 0;  top->cr_m_ready = 0;  top->cr_s_payload = 0;
  top->pl_src_pulse = 0; top->pl_src_sticky_clear = 0;
  top->hs_s_valid = 0;  top->hs_s_data = 0;
  top->sy_d = 0;

  ErrorCollector errors;
  SeedSource seeds(args.seed);

  const unsigned data_mask =
      static_cast<unsigned>((1ull << sim_config::CDC_HANDSHAKE_W) - 1ull);

  // Aggregate statistics for the run summary.
  std::uint64_t total_pulses_accepted = 0;
  std::uint64_t total_pulses_delivered = 0;
  std::uint64_t total_transfers = 0;
  std::uint64_t total_cycles_a = 0;
  std::uint64_t total_cycles_b = 0;
  std::size_t phases_run = 0;
  bool failed = false;
  std::string first_failure;

  auto fail = [&](const std::string& category, const std::string& what) {
    errors.error(category, what);
    if (first_failure.empty()) first_failure = what;
    failed = true;
  };

  for (const ClockRatio& ratio : harness::clock_ratios()) {
    for (const PhaseSpec& ps : phase_specs()) {
      if (failed) break;
      ++phases_run;
      const std::string tag = std::string(ratio.name) + "/" + ps.name;

      // A fresh scheduler per phase: the ratio IS the clock configuration, and
      // rebuilding guarantees no callback from a previous phase survives.
      ClockScheduler sched([&top]() { top->eval(); });
      errors.set_time_probe(sched.time_ptr());

      const int clk_a =
          sched.add_clock("clk_a", ratio.half_a, &top->clk_a, ratio.first_a);
      const int clk_b =
          sched.add_clock("clk_b", ratio.half_b, &top->clk_b, ratio.first_b);

      ResetSequencer reset(sched);
      reset.add_domain("rst_a_n", clk_a, &top->rst_a_n, 8);
      reset.add_domain("rst_b_n", clk_b, &top->rst_b_n, 5);

      std::mt19937_64 rng = seeds.engine("cdc_sync." + tag);

      // ---- per-phase state ----
      std::uint64_t cycle_a = 0;
      bool stimulus = false;
      bool driving = false;   // false during the drain tail

      std::uint64_t pulses_offered = 0;
      std::uint64_t pulses_accepted = 0;
      std::uint64_t pulses_delivered = 0;
      bool overrun_seen = false;
      bool clearing_sticky = false;
      bool sticky_cleared_ok = true;

      std::deque<unsigned> hs_in_flight;   // values accepted, not yet observed
      std::uint64_t hs_sent = 0;
      std::uint64_t hs_received = 0;
      unsigned hs_next_value = 1;
      std::uint32_t hs_gap = 0;

      // status_bit bookkeeping
      unsigned status_value = 0;
      std::uint64_t status_transitions_in_window = 0;
      unsigned status_last_q = 0;
      bool status_q_primed = false;

      // ---- source domain (A) ----
      sched.on_posedge_sample(clk_a, [&]() {
        if (!stimulus) return;
        ++cycle_a;

        if (ps.phase == TestPhase::kPulsePaced || ps.phase == TestPhase::kPulseOverrun) {
          if (top->pl_src_pulse != 0) {
            ++pulses_offered;
            if (top->pl_src_busy == 0) ++pulses_accepted;
          }
          if (top->pl_src_overrun != 0) overrun_seen = true;
          if (clearing_sticky && top->pl_src_overrun != 0) {
            // Checked one cycle after the clear has been applied and taken
            // effect; see the drive callback below.
          }
        }

        if (ps.phase == TestPhase::kHandshakeBurst ||
            ps.phase == TestPhase::kHandshakeGapped) {
          if (top->hs_s_valid != 0 && top->hs_s_ready != 0) {
            hs_in_flight.push_back(static_cast<unsigned>(top->hs_s_data));
            ++hs_sent;
          }
          if (top->hs_s_busy != 0 && top->hs_s_ready != 0) {
            fail("handshake",
                 tag + ": the source reported ready and busy at the same time");
          }
        }
      });

      sched.on_posedge_drive(clk_a, [&]() {
        if (!stimulus) return;

        switch (ps.phase) {
          case TestPhase::kPulsePaced: {
            // Offer a pulse only when the crossing can take it. Roughly one in
            // four cycles, so gaps and back-to-back offers both occur.
            const bool offer =
                driving && (top->pl_src_busy == 0) && harness::bernoulli(rng, 0.25);
            top->pl_src_pulse = offer ? 1 : 0;
            break;
          }
          case TestPhase::kPulseOverrun: {
            // Deliberate abuse: a pulse every cycle regardless of busy.
            top->pl_src_pulse = driving ? 1 : 0;
            top->pl_src_sticky_clear = clearing_sticky ? 1 : 0;
            break;
          }
          case TestPhase::kHandshakeBurst: {
            // Back to back: valid never drops while there is more to send.
            if (top->hs_s_ready != 0) {
              top->hs_s_data = static_cast<unsigned>(hs_next_value & data_mask);
              hs_next_value = (hs_next_value + 1u) & data_mask;
              if (hs_next_value == 0) hs_next_value = 1;
            }
            top->hs_s_valid = driving ? 1 : 0;
            break;
          }
          case TestPhase::kHandshakeGapped: {
            if (top->hs_s_valid != 0 && top->hs_s_ready == 0) break;  // hold
            if (hs_gap > 0) {
              --hs_gap;
              top->hs_s_valid = 0;
              break;
            }
            if (!driving) {
              top->hs_s_valid = 0;
              break;
            }
            top->hs_s_data = static_cast<unsigned>(hs_next_value & data_mask);
            hs_next_value = (hs_next_value + 1u) & data_mask;
            if (hs_next_value == 0) hs_next_value = 1;
            top->hs_s_valid = 1;
            hs_gap = static_cast<std::uint32_t>(harness::uniform_u64(rng, 0, 12));
            break;
          }
          case TestPhase::kStatusBit: {
            if ((cycle_a % kStatusWindow) == 0) {
              // End of a window: the destination has had many clocks to settle,
              // so its output must now equal the held input, and it must not
              // have moved more than once inside the window.
              if (cycle_a != 0) {
                if (static_cast<unsigned>(top->sy_q) != status_value) {
                  fail("status_bit",
                       tag + ": synchronizer output is " +
                           std::to_string(top->sy_q) + " after a full window " +
                           "holding " + std::to_string(status_value));
                }
                if (status_transitions_in_window > 1) {
                  fail("status_bit",
                       tag + ": synchronizer output changed " +
                           std::to_string(status_transitions_in_window) +
                           " times while the input was held stable");
                }
              }
              status_transitions_in_window = 0;
              status_value = harness::bernoulli(rng, 0.5) ? 1u : 0u;
              top->sy_d = static_cast<CData>(status_value);
            }
            break;
          }
        }
      });

      // ---- destination domain (B) ----
      sched.on_posedge_sample(clk_b, [&]() {
        if (!stimulus) return;

        if (ps.phase == TestPhase::kPulsePaced || ps.phase == TestPhase::kPulseOverrun) {
          if (top->pl_dst_pulse != 0) ++pulses_delivered;
        }

        if (ps.phase == TestPhase::kHandshakeBurst ||
            ps.phase == TestPhase::kHandshakeGapped) {
          if (top->hs_d_valid != 0) {
            const unsigned got = static_cast<unsigned>(top->hs_d_data);
            ++hs_received;
            if (hs_in_flight.empty()) {
              fail("handshake",
                   tag + ": the destination delivered value " +
                       std::to_string(got) + " that the source never offered");
            } else {
              const unsigned want = hs_in_flight.front();
              hs_in_flight.pop_front();
              if (got != want) {
                fail("handshake", tag + ": the destination delivered " +
                                      std::to_string(got) + " where " +
                                      std::to_string(want) + " was offered");
              }
            }
          }
        }

        if (ps.phase == TestPhase::kStatusBit) {
          const unsigned q = static_cast<unsigned>(top->sy_q);
          if (status_q_primed && q != status_last_q) {
            ++status_transitions_in_window;
          }
          status_last_q = q;
          status_q_primed = true;
        }
      });

      // ---- run: reset, drive, drain ----
      const SimTime slow = harness::slowest_half(ratio);
      const SimTime time_limit =
          static_cast<SimTime>(ps.drive_cycles + ps.drain_cycles + 5000) *
          slow * 4;

      stimulus = false;
      driving = false;
      top->pl_src_pulse = 0;
      top->pl_src_sticky_clear = 0;
      top->hs_s_valid = 0;
      top->hs_s_data = 0;
      top->sy_d = 0;

      reset.assert_all();
      if (reset.release_all(time_limit) != StopReason::kRunning) {
        fail("reset", tag + ": reset sequence did not complete");
        break;
      }

      stimulus = true;
      driving = true;
      if (sched.run_cycles(clk_a, ps.drive_cycles, time_limit) !=
          StopReason::kRunning) {
        fail("timeout", tag + ": stimulus phase did not complete");
        break;
      }

      driving = false;
      top->pl_src_pulse = 0;
      top->hs_s_valid = 0;
      if (sched.run_cycles(clk_a, ps.drain_cycles, time_limit) !=
          StopReason::kRunning) {
        fail("timeout", tag + ": drain phase did not complete");
        break;
      }

      // The overrun phase additionally proves the sticky flag CLEARS when told
      // to: it is a status bit the register plane (issue #7) will own, and a
      // flag that latches but cannot be cleared is a flag that reports one
      // event and then lies for the rest of the run.
      if (ps.phase == TestPhase::kPulseOverrun) {
        clearing_sticky = true;
        if (sched.run_cycles(clk_a, 8, time_limit) != StopReason::kRunning) {
          fail("timeout", tag + ": sticky-clear phase did not complete");
          break;
        }
        clearing_sticky = false;
        top->pl_src_sticky_clear = 0;
        if (sched.run_cycles(clk_a, 4, time_limit) != StopReason::kRunning) {
          fail("timeout", tag + ": sticky-clear settle did not complete");
          break;
        }
        sticky_cleared_ok = (top->pl_src_overrun == 0);
      }

      stimulus = false;
      total_cycles_a += sched.cycles(clk_a);
      total_cycles_b += sched.cycles(clk_b);

      // ---- per-phase checks ----
      bool phase_ok = true;
      switch (ps.phase) {
        case TestPhase::kPulsePaced:
          total_pulses_accepted += pulses_accepted;
          total_pulses_delivered += pulses_delivered;
          if (pulses_delivered != pulses_accepted) {
            fail("pulse", tag + ": delivered " +
                              std::to_string(pulses_delivered) +
                              " strobes for " + std::to_string(pulses_accepted) +
                              " accepted pulses");
            phase_ok = false;
          }
          if (overrun_seen) {
            fail("pulse", tag +
                              ": overrun was reported although every pulse was "
                              "offered while the crossing was idle");
            phase_ok = false;
          }
          if (pulses_accepted < kMinPulses) {
            fail("coverage", tag + ": only " + std::to_string(pulses_accepted) +
                                 " pulses crossed; the phase tested nothing");
            phase_ok = false;
          }
          break;

        case TestPhase::kPulseOverrun:
          total_pulses_accepted += pulses_accepted;
          total_pulses_delivered += pulses_delivered;
          if (pulses_delivered != pulses_accepted) {
            fail("pulse", tag + ": under overrun, delivered " +
                              std::to_string(pulses_delivered) +
                              " strobes for " + std::to_string(pulses_accepted) +
                              " accepted pulses - a refused pulse corrupted an "
                              "accepted one");
            phase_ok = false;
          }
          if (!overrun_seen) {
            fail("pulse", tag + ": " + std::to_string(pulses_offered) +
                              " pulses were offered back to back but no overrun "
                              "was reported");
            phase_ok = false;
          }
          if (pulses_offered <= pulses_accepted) {
            fail("pulse", tag +
                              ": every back-to-back pulse was accepted, so the "
                              "flow control did nothing");
            phase_ok = false;
          }
          if (!sticky_cleared_ok) {
            fail("pulse", tag + ": the sticky overrun flag did not clear");
            phase_ok = false;
          }
          break;

        case TestPhase::kHandshakeBurst:
        case TestPhase::kHandshakeGapped:
          total_transfers += hs_received;
          if (!hs_in_flight.empty()) {
            fail("handshake", tag + ": " + std::to_string(hs_in_flight.size()) +
                                  " offered values never reached the "
                                  "destination");
            phase_ok = false;
          }
          if (hs_received != hs_sent) {
            fail("handshake", tag + ": sent " + std::to_string(hs_sent) +
                                  " values but the destination saw " +
                                  std::to_string(hs_received));
            phase_ok = false;
          }
          if (hs_sent < kMinTransfers) {
            fail("coverage", tag + ": only " + std::to_string(hs_sent) +
                                 " transfers completed; the phase tested "
                                 "nothing");
            phase_ok = false;
          }
          break;

        case TestPhase::kStatusBit:
          // Checked continuously in the drive callback; nothing to total.
          break;
      }

      if (!args.quiet) {
        std::printf(
            "  %-22s %-17s a=%5llu b=%5llu pulses=%llu/%llu transfers=%llu "
            "-> %s\n",
            ratio.name, ps.name,
            static_cast<unsigned long long>(sched.cycles(clk_a)),
            static_cast<unsigned long long>(sched.cycles(clk_b)),
            static_cast<unsigned long long>(pulses_delivered),
            static_cast<unsigned long long>(pulses_accepted),
            static_cast<unsigned long long>(hs_received),
            (phase_ok && !failed) ? "OK" : "FAILED");
        std::fflush(stdout);
      }
    }
  }

  const bool passed = !failed && errors.ok();

  const auto wall_end = std::chrono::steady_clock::now();
  RunSummary summary;
  summary.test_name = kTestName;
  summary.config_name = sim_config::kName;
  summary.build_mode = args.build_mode;
  summary.seed = args.seed;
  summary.passed = passed;
  summary.stop_reason = passed ? "pass" : "error";
  summary.stop_detail =
      passed ? "every synchronizer clean at every ratio" : first_failure;
  summary.passes = phases_run;
  summary.core_cycles = total_cycles_a;
  summary.cfg_cycles = total_cycles_b;
  summary.beats_driven = total_pulses_accepted + total_transfers;
  summary.beats_observed = total_pulses_delivered + total_transfers;
  summary.absorb(errors);
  summary.wall_time_s =
      std::chrono::duration<double>(wall_end - wall_start).count();

  const std::string written = summary.write(args.results_dir);

  std::printf("--- summary ---\n");
  std::printf("  ratios         : %zu, phases %zu, runs %zu\n",
              harness::clock_ratios().size(), phase_specs().size(), phases_run);
  std::printf("  cycles         : clk_a=%llu clk_b=%llu\n",
              static_cast<unsigned long long>(total_cycles_a),
              static_cast<unsigned long long>(total_cycles_b));
  std::printf("  pulses         : accepted=%llu delivered=%llu\n",
              static_cast<unsigned long long>(total_pulses_accepted),
              static_cast<unsigned long long>(total_pulses_delivered));
  std::printf("  handshakes     : %llu\n",
              static_cast<unsigned long long>(total_transfers));
  std::printf("  errors         : %zu\n", errors.count());
  if (!written.empty()) std::printf("  summary json   : %s\n", written.c_str());

  top->final();

  if (passed) {
    std::printf("RESULT: PASS seed=%llu test=%s config=%s\n",
                static_cast<unsigned long long>(args.seed), kTestName,
                sim_config::kName);
    return 0;
  }
  std::printf("RESULT: FAIL seed=%llu test=%s config=%s errors=%zu reason=%s\n",
              static_cast<unsigned long long>(args.seed), kTestName,
              sim_config::kName, errors.count(),
              first_failure.empty() ? "see log" : first_failure.c_str());
  return 1;
}
