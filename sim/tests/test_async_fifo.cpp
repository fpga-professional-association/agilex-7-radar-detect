// -----------------------------------------------------------------------------
// test_async_fifo.cpp — multi-clock unit test for rtl/cdc/async_fifo.sv and
// rtl/cdc/stream_cdc.sv (SPEC 8, 12.3, 12.5, 13.1).
//
// SPEC 8 makes the asynchronous FIFO the bulk-CDC mechanism for the whole
// benchmark, so this is the test that has to be convincing. It drives three
// crossings at once, through the SPEC 12.3 multi-clock scheduler, across the
// clock-ratio sweep in sim/verilator/harness/clock_ratios.h:
//
//   afifo    async_fifo, A -> B, registered output, STORAGE="m20k", DEPTH=8
//   scdc_f   stream_cdc, A -> B, registered output, DEPTH=16
//   scdc_r   stream_cdc, B -> A, show-ahead read side, DEPTH=16
//
// The reverse-direction instance is not redundant: `full` is derived in the
// write domain and `empty` in the read domain, so the two directions exercise
// opposite sides of the pointer-synchronizer staleness. With one instance in
// each direction, every ratio in the sweep makes some crossing source-fast and
// some crossing source-slow within the same pass.
//
// RATIOS (sim/verilator/harness/clock_ratios.h, seven entries)
//   1:1 in phase, 1:1 with a phase offset, 2:1, 1:2, 7:3, 3:7, and 100:99 —
//   the last being a near-unity ratio whose long repeat drifts the two domains
//   through a continuum of relative phases inside a single pass. Each ratio runs
//   with no backpressure and then with heavy randomized backpressure on both
//   sides, so a crossing is exercised both at full rate and under stalls at
//   every alignment.
//
// WHAT IS CHECKED
//   * transaction identity (SPEC 12.5): the scoreboard proves zero lost, zero
//     duplicated, zero misordered, zero corrupted and zero unexpected beats
//     across every crossing at every ratio. Latency is reported, never used to
//     key the match — SPEC 12.5 forbids assuming a fixed latency, and across two
//     asynchronous clocks there is not even a fixed unit to assume it in.
//   * frame integrity and sequence continuity, from the C++ monitor in the
//     destination domain, independently of the assertions inside the RTL.
//   * per-domain occupancy invariants, via model/cpp/cdc/fifo_ref.h: each side's
//     estimate stays within 0..DEPTH, each side's high-water mark follows the
//     shared rule exactly within its own domain, never decreases, and the sticky
//     overflow and underflow flags stay clear.
//   * the capacity bound across the crossing: beats accepted minus beats emitted
//     never exceeds DEPTH plus the output register. This is the cross-domain
//     property the per-side estimates cannot state.
//   * a coverage floor: the FIFO must actually fill during the stalled passes.
//     A crossing that never held more than one beat did not test the pointer
//     synchronizers at all, so failing to fill is a test failure.
//   * reset: every pass re-runs the two-domain reset with DIFFERENT release
//     delays per domain (8 cycles of A, 5 of B), so the release skew the
//     async_fifo reset contract exists to absorb is exercised on every pass at
//     every ratio, not once at time zero.
// -----------------------------------------------------------------------------

#include <algorithm>
#include <chrono>
#include <cstdio>
#include <memory>
#include <string>
#include <vector>

#include "Vcdc_prims_top.h"
#include "verilated.h"

#include "cdc/fifo_ref.h"
#include "config_sim.h"
#include "harness/clock_ratios.h"
#include "harness/harness.h"

using harness::BackpressureConfig;
using harness::ClockRatio;
using harness::ClockScheduler;
using harness::ErrorCollector;
using harness::ResetSequencer;
using harness::RunSummary;
using harness::Scoreboard;
using harness::ScoreboardStats;
using harness::SeedSource;
using harness::SimArgs;
using harness::SimTime;
using harness::StopReason;
using harness::StreamBeat;
using harness::StreamDriver;
using harness::StreamLayout;
using harness::StreamMonitor;
using harness::TimeoutGuard;
using harness::TransactionId;

namespace {

constexpr const char* kTestName = "test_async_fifo";

static_assert(sim_config::STREAM_PAYLOAD_W > 32,
              "packed payload no longer maps to a Verilator QData port");
static_assert(sim_config::STREAM_PAYLOAD_W <= 64,
              "packed payload exceeds the 64-bit host transport");

constexpr std::uint32_t kMinFrameLen = 1;
constexpr std::uint32_t kMaxFrameLen = 8;
// Fourteen passes (seven ratios x two stall profiles) x three crossings. Kept
// small per pass so the whole sweep stays inside the sim-tiny runtime budget
// while every ratio still moves hundreds of beats.
constexpr std::uint64_t kDefaultFramesPerPass = 8;

StreamLayout payload_layout() {
  StreamLayout l;
  l.data_w = sim_config::STREAM_DATA_W;
  l.id_w = sim_config::STREAM_ID_W;
  l.seq_w = sim_config::STREAM_SEQ_W;
  l.user_w = sim_config::STREAM_USER_W;
  l.user_lsb = sim_config::STREAM_USER_LSB;
  l.seq_lsb = sim_config::STREAM_SEQ_LSB;
  l.id_lsb = sim_config::STREAM_ID_LSB;
  l.eof_lsb = sim_config::STREAM_EOF_LSB;
  l.sof_lsb = sim_config::STREAM_SOF_LSB;
  l.data_lsb = sim_config::STREAM_DATA_LSB;
  l.payload_w = sim_config::STREAM_PAYLOAD_W;
  return l;
}

std::uint32_t stream_count() {
  const std::uint32_t id_span = 1u << sim_config::STREAM_ID_W;
  return std::min<std::uint32_t>(sim_config::N_ANTENNAS, id_span);
}

TransactionId identity_of(const StreamBeat& b) {
  TransactionId id;
  id.stream_id = b.stream_id;
  id.frame_id = b.user;
  id.sequence = b.seq;
  return id;
}

// One crossing under test.
struct CrossingDut {
  const char* name;
  unsigned depth;
  unsigned capacity;   // depth plus the output register, if any
  bool src_is_a;       // false: the source is domain B

  std::unique_ptr<harness::PackedSourcePort> src;
  std::unique_ptr<harness::PackedSinkPort> snk;
  std::unique_ptr<StreamDriver> driver;
  std::unique_ptr<StreamMonitor> monitor;
  std::unique_ptr<Scoreboard> scoreboard;

  // Occupancy and status ports, when the DUT exports them. nullptr means the
  // instance does not, and the per-domain invariant check is skipped for it.
  const CData* wr_occ = nullptr;
  const CData* wr_high = nullptr;
  const CData* wr_err = nullptr;
  const CData* rd_occ = nullptr;
  const CData* rd_high = nullptr;
  const CData* rd_err = nullptr;
  std::unique_ptr<model::AsyncFifoBoundsRef> wr_ref;
  std::unique_ptr<model::AsyncFifoBoundsRef> rd_ref;

  std::uint64_t accepted = 0;
  std::uint64_t emitted = 0;
  std::uint64_t pass_beats = 0;
  std::uint64_t max_in_flight = 0;
  unsigned global_peak_occ = 0;
  bool invariant_failed = false;
};

struct StallSpec {
  const char* name;
  BackpressureConfig source;
  BackpressureConfig sink;
  bool fills;
};

const std::vector<StallSpec>& stall_specs() {
  static const std::vector<StallSpec> specs = {
      {"free_running", BackpressureConfig::none(), BackpressureConfig::none(),
       false},
      {"stalled_both", BackpressureConfig::heavy(), BackpressureConfig::bursty(),
       true},
  };
  return specs;
}

struct Generator {
  std::mt19937_64 rng;
  std::vector<std::uint32_t> next_seq;
  std::uint32_t frame_index = 0;

  explicit Generator(std::mt19937_64 r) : rng(r), next_seq(stream_count(), 0) {}

  std::vector<StreamBeat> make_frame(const StreamLayout& layout,
                                     std::uint32_t stream_id,
                                     std::uint32_t length) {
    std::vector<StreamBeat> frame;
    frame.reserve(length);
    const std::uint32_t tag =
        frame_index &
        static_cast<std::uint32_t>(StreamLayout::mask_of(layout.user_w));
    const std::uint32_t seq_mask =
        static_cast<std::uint32_t>(StreamLayout::mask_of(layout.seq_w));
    for (std::uint32_t i = 0; i < length; ++i) {
      StreamBeat b;
      b.data = harness::uniform_u64(rng, 0, StreamLayout::mask_of(layout.data_w));
      b.start_of_frame = (i == 0);
      b.end_of_frame = (i + 1 == length);
      b.stream_id = stream_id;
      b.seq = next_seq[stream_id] & seq_mask;
      b.user = tag;
      next_seq[stream_id] = (next_seq[stream_id] + 1u) & seq_mask;
      frame.push_back(b);
    }
    ++frame_index;
    return frame;
  }
};

void accumulate(ScoreboardStats* total, const ScoreboardStats& s, bool first) {
  total->expected += s.expected;
  total->observed += s.observed;
  total->matched += s.matched;
  total->lost += s.lost;
  total->duplicated += s.duplicated;
  total->misordered += s.misordered;
  total->content_mismatch += s.content_mismatch;
  total->unexpected += s.unexpected;
  total->latency_violation += s.latency_violation;
  total->latency_sum += s.latency_sum;
  total->latency_min =
      first ? s.latency_min : std::min(total->latency_min, s.latency_min);
  total->latency_max = std::max(total->latency_max, s.latency_max);
}

}  // namespace

// ---------------------------------------------------------------------------
// Test entry point (main() lives in sim/verilator/sim_main.cpp).
// ---------------------------------------------------------------------------
int harness::sim_test_main(const SimArgs& args) {
  const auto wall_start = std::chrono::steady_clock::now();

  const StreamLayout layout = payload_layout();
  {
    const std::string bad = layout.self_check();
    if (!bad.empty()) {
      std::fprintf(stderr, "ERROR: generated stream layout is inconsistent: %s\n",
                   bad.c_str());
      std::printf("RESULT: FAIL seed=%llu test=%s reason=layout_inconsistent\n",
                  static_cast<unsigned long long>(args.seed), kTestName);
      return 2;
    }
  }

  const std::uint64_t frames_per_pass =
      args.frames != 0 ? args.frames : kDefaultFramesPerPass;
  const std::uint32_t streams = stream_count();

  std::unique_ptr<Vcdc_prims_top> top(new Vcdc_prims_top);

  // Inputs this test does not drive are held at a defined value so the idle
  // DUTs present a legal, quiet interface to their own protocol checkers.
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
  ClockScheduler sched([&top]() { top->eval(); });
  errors.set_time_probe(sched.time_ptr());

  SeedSource seeds(args.seed);

  // -----------------------------------------------------------------------
  // The three crossings.
  // -----------------------------------------------------------------------
  std::vector<CrossingDut> duts(3);

  duts[0].name = "afifo_a2b";
  duts[0].depth = sim_config::CDC_ASYNC_FIFO_DEPTH;
  duts[0].capacity = sim_config::CDC_ASYNC_FIFO_DEPTH + 1;  // OUT_REG = 1
  duts[0].src_is_a = true;
  duts[0].src = std::make_unique<harness::PackedSourcePort>(
      &top->af_wr_valid, &top->af_wr_ready, &top->af_wr_data, layout);
  duts[0].snk = std::make_unique<harness::PackedSinkPort>(
      &top->af_rd_valid, &top->af_rd_ready, &top->af_rd_data, layout);
  duts[0].wr_occ = &top->af_wr_occ;
  duts[0].wr_high = &top->af_wr_high;
  duts[0].wr_err = &top->af_wr_overflow;
  duts[0].rd_occ = &top->af_rd_occ;
  duts[0].rd_high = &top->af_rd_high;
  duts[0].rd_err = &top->af_rd_underflow;

  duts[1].name = "stream_cdc_a2b";
  duts[1].depth = sim_config::CDC_STREAM_CDC_DEPTH;
  duts[1].capacity = sim_config::CDC_STREAM_CDC_DEPTH + 1;  // OUT_REG = 1
  duts[1].src_is_a = true;
  duts[1].src = std::make_unique<harness::PackedSourcePort>(
      &top->cf_s_valid, &top->cf_s_ready, &top->cf_s_payload, layout);
  duts[1].snk = std::make_unique<harness::PackedSinkPort>(
      &top->cf_m_valid, &top->cf_m_ready, &top->cf_m_payload, layout);
  duts[1].wr_occ = &top->cf_s_occ;
  duts[1].wr_high = &top->cf_s_high;
  duts[1].rd_occ = &top->cf_m_occ;
  duts[1].rd_high = &top->cf_m_high;

  duts[2].name = "stream_cdc_b2a";
  duts[2].depth = sim_config::CDC_STREAM_CDC_DEPTH;
  duts[2].capacity = sim_config::CDC_STREAM_CDC_DEPTH;  // show-ahead read side
  duts[2].src_is_a = false;
  duts[2].src = std::make_unique<harness::PackedSourcePort>(
      &top->cr_s_valid, &top->cr_s_ready, &top->cr_s_payload, layout);
  duts[2].snk = std::make_unique<harness::PackedSinkPort>(
      &top->cr_m_valid, &top->cr_m_ready, &top->cr_m_payload, layout);

  for (CrossingDut& d : duts) {
    d.scoreboard = std::make_unique<Scoreboard>(d.name, errors);
    if (d.wr_occ != nullptr) {
      d.wr_ref = std::make_unique<model::AsyncFifoBoundsRef>(d.depth);
    }
    if (d.rd_occ != nullptr) {
      d.rd_ref = std::make_unique<model::AsyncFifoBoundsRef>(d.depth);
    }
  }

  bool stimulus_enabled = false;
  bool pass_complete = false;

  // Records an invariant failure once per DUT per pass: a broken invariant
  // repeats every cycle, and twenty lines of it hide everything else.
  auto note = [&](CrossingDut& d, const std::string& what) {
    if (d.invariant_failed) return;
    d.invariant_failed = true;
    errors.error("cdc_invariant", std::string(d.name) + ": " + what);
  };

  // -----------------------------------------------------------------------
  // Per-domain callbacks. Everything a domain owns runs on that domain's own
  // edges: a driver on its source clock, a monitor on its destination clock,
  // and each occupancy invariant in the domain whose registers produce it.
  // -----------------------------------------------------------------------
  auto domain_sample = [&](bool is_a) {
    if (!stimulus_enabled) return;
    for (CrossingDut& d : duts) {
      // Write-side status lives in the source domain.
      if (d.wr_ref && (d.src_is_a == is_a)) {
        const unsigned occ = static_cast<unsigned>(*d.wr_occ);
        const std::string bad = d.wr_ref->check(
            "write side", occ, static_cast<unsigned>(*d.wr_high),
            d.wr_err != nullptr && *d.wr_err != 0);
        if (!bad.empty()) note(d, bad);
        d.global_peak_occ = std::max(d.global_peak_occ, occ);
      }
      // Read-side status lives in the destination domain.
      if (d.rd_ref && (d.src_is_a != is_a)) {
        const std::string bad = d.rd_ref->check(
            "read side", static_cast<unsigned>(*d.rd_occ),
            static_cast<unsigned>(*d.rd_high),
            d.rd_err != nullptr && *d.rd_err != 0);
        if (!bad.empty()) note(d, bad);
      }

      const std::uint64_t in_flight = d.accepted - d.emitted;
      d.max_in_flight = std::max(d.max_in_flight, in_flight);
      if (in_flight > d.capacity) {
        note(d, "beats in flight " + std::to_string(in_flight) +
                    " exceeds the crossing's capacity of " +
                    std::to_string(d.capacity));
      }

      if (d.src_is_a == is_a) d.driver->on_sample();
      if (d.src_is_a != is_a) d.monitor->on_sample();
    }
  };

  auto domain_drive = [&](bool is_a) {
    if (!stimulus_enabled) return;
    for (CrossingDut& d : duts) {
      if (d.src_is_a == is_a) d.driver->on_drive();
      if (d.src_is_a != is_a) d.monitor->on_drive();
    }
  };

  // -----------------------------------------------------------------------
  // Passes: every ratio x every stall profile. The scheduler and its clocks are
  // rebuilt per pass, because the ratio IS the clock configuration.
  // -----------------------------------------------------------------------
  ScoreboardStats totals;
  std::uint64_t total_beats_driven = 0;
  std::uint64_t total_beats_observed = 0;
  std::uint64_t total_frames_driven = 0;
  std::uint64_t total_frames_observed = 0;
  std::uint64_t total_cycles_a = 0;
  std::uint64_t total_cycles_b = 0;
  bool failed = false;
  bool first_stat = true;
  std::string first_failure;
  std::size_t pass_index = 0;
  const std::size_t total_passes =
      harness::clock_ratios().size() * stall_specs().size();

  for (const ClockRatio& ratio : harness::clock_ratios()) {
    for (const StallSpec& stall : stall_specs()) {
      if (failed) break;
      ++pass_index;
      const std::string pass_name =
          std::string(ratio.name) + "/" + stall.name;

      // A fresh scheduler per pass. Rebuilding it is what changes the ratio,
      // and it also guarantees that no callback registered for a previous
      // ratio survives into the next one.
      ClockScheduler pass_sched([&top]() { top->eval(); });
      errors.set_time_probe(pass_sched.time_ptr());

      const int clk_a =
          pass_sched.add_clock("clk_a", ratio.half_a, &top->clk_a, ratio.first_a);
      const int clk_b =
          pass_sched.add_clock("clk_b", ratio.half_b, &top->clk_b, ratio.first_b);

      std::uint64_t cycle_a = 0;
      std::uint64_t cycle_b = 0;
      pass_sched.on_posedge_sample(clk_a, [&cycle_a]() { ++cycle_a; });
      pass_sched.on_posedge_sample(clk_b, [&cycle_b]() { ++cycle_b; });

      ResetSequencer reset(pass_sched);
      // Deliberately different release delays: the two domains leave reset at
      // different absolute times, which is exactly the skew the async_fifo
      // reset contract exists to absorb.
      reset.add_domain("rst_a_n", clk_a, &top->rst_a_n, 8);
      reset.add_domain("rst_b_n", clk_b, &top->rst_b_n, 5);

      pass_sched.on_posedge_sample(clk_a, [&]() { domain_sample(true); });
      pass_sched.on_posedge_sample(clk_b, [&]() { domain_sample(false); });
      pass_sched.on_posedge_drive(clk_a, [&]() { domain_drive(true); });
      pass_sched.on_posedge_drive(clk_b, [&]() { domain_drive(false); });

      const std::uint64_t max_beats = frames_per_pass * kMaxFrameLen;
      const std::uint64_t hard_limit = args.timeout_cycles != 0
                                           ? args.timeout_cycles
                                           : (max_beats * 400 + 20000);
      TimeoutGuard timeout(pass_sched, errors, hard_limit, 20000, [&]() {
        std::uint64_t t = 0;
        for (const CrossingDut& d : duts) {
          if (d.monitor) t += d.monitor->beats_received();
        }
        return t;
      });
      pass_sched.on_posedge_drive(clk_a, [&]() {
        if (!stimulus_enabled) return;
        timeout.on_cycle();
      });

      pass_sched.on_posedge_drive(clk_a, [&]() {
        if (!stimulus_enabled || pass_complete) return;
        for (const CrossingDut& d : duts) {
          if (!d.driver->idle() || d.scoreboard->outstanding() != 0) return;
        }
        pass_complete = true;
        pass_sched.stop_pass("pass drained");
      });

      // Per-pass drivers, monitors and scoreboards.
      for (CrossingDut& d : duts) {
        const std::string tag = std::string(d.name) + "." + pass_name;
        d.driver = std::make_unique<StreamDriver>(
            d.name, *d.src, seeds.engine("cdc_driver." + tag), stall.source,
            errors);
        d.monitor = std::make_unique<StreamMonitor>(
            d.name, *d.snk, seeds.engine("cdc_monitor." + tag), stall.sink,
            errors);
        d.monitor->set_sequence_width(layout.seq_w);
        d.driver->set_cycle_probe(d.src_is_a ? &cycle_a : &cycle_b);
        d.monitor->set_cycle_probe(d.src_is_a ? &cycle_b : &cycle_a);

        CrossingDut* dp = &d;
        d.driver->set_accept_hook([dp](const StreamBeat& b, std::uint64_t cyc) {
          ++dp->accepted;
          dp->scoreboard->expect(identity_of(b), b, cyc);
        });
        d.monitor->set_observe_hook([dp](const StreamBeat& b, std::uint64_t cyc) {
          ++dp->emitted;
          dp->scoreboard->observe(identity_of(b), b, cyc);
        });

        d.scoreboard->reset();
        // No latency bound: input and output cycles are counted in different
        // clocks, so a cycle difference between them is not a duration.
        d.scoreboard->set_latency_bound(0);
        d.accepted = 0;
        d.emitted = 0;
        d.pass_beats = 0;
        d.max_in_flight = 0;
        d.invariant_failed = false;
        if (d.wr_ref) d.wr_ref->reset();
        if (d.rd_ref) d.rd_ref->reset();
        d.driver->reset(true);
        d.monitor->reset();
      }

      const SimTime time_limit =
          static_cast<SimTime>(hard_limit + 100000) *
          harness::slowest_half(ratio) * 2;

      stimulus_enabled = false;
      pass_complete = false;
      reset.assert_all();
      if (reset.release_all(time_limit) != StopReason::kRunning) {
        failed = true;
        first_failure = "reset sequence did not complete in pass " + pass_name;
        break;
      }

      for (CrossingDut& d : duts) {
        Generator gen(
            seeds.engine(std::string("stimulus.") + d.name + "." + pass_name));
        for (std::uint64_t f = 0; f < frames_per_pass; ++f) {
          const std::uint32_t len = static_cast<std::uint32_t>(
              harness::uniform_u64(gen.rng, kMinFrameLen, kMaxFrameLen));
          const std::uint32_t stream_id = static_cast<std::uint32_t>(
              harness::uniform_u64(gen.rng, 0, streams - 1));
          const std::vector<StreamBeat> frame =
              gen.make_frame(layout, stream_id, len);
          d.pass_beats += frame.size();
          d.driver->queue_frame(frame);
        }
      }

      timeout.reset();
      stimulus_enabled = true;
      const StopReason reason = pass_sched.run(time_limit);
      stimulus_enabled = false;

      total_cycles_a += pass_sched.cycles(clk_a);
      total_cycles_b += pass_sched.cycles(clk_b);

      bool pass_ok = (reason == StopReason::kPass);
      for (CrossingDut& d : duts) {
        d.scoreboard->finalize();
        d.monitor->check_drained();
        const ScoreboardStats& st = d.scoreboard->stats();

        bool dut_ok = st.clean() && st.observed == d.pass_beats &&
                      st.matched == d.pass_beats && !d.invariant_failed;

        // A stalled pass must actually back the crossing up, or the pointer
        // synchronizers were never exercised at a non-trivial fill level.
        if (stall.fills && dut_ok && d.max_in_flight < 2) {
          errors.error("coverage",
                       std::string(d.name) + " at " + pass_name +
                           ": never held more than " +
                           std::to_string(d.max_in_flight) +
                           " beats; the crossing was not backed up");
          dut_ok = false;
        }

        accumulate(&totals, st, first_stat);
        first_stat = false;
        total_beats_driven += d.driver->beats_sent();
        total_beats_observed += d.monitor->beats_received();
        total_frames_driven += frames_per_pass;
        total_frames_observed += d.monitor->frames_received();

        if (!args.quiet) {
          std::printf(
              "  pass %2zu/%2zu %-22s %-15s beats=%3llu obs=%3llu "
              "max_inflight=%2llu/%2u peak_occ=%2u -> %s\n",
              pass_index, total_passes, pass_name.c_str(), d.name,
              static_cast<unsigned long long>(d.pass_beats),
              static_cast<unsigned long long>(st.observed),
              static_cast<unsigned long long>(d.max_in_flight), d.capacity,
              d.global_peak_occ, dut_ok ? "OK" : "FAILED");
        }

        if (!dut_ok && pass_ok) {
          pass_ok = false;
          first_failure =
              "pass " + pass_name + " dut " + d.name +
              ": expected=" + std::to_string(st.expected) +
              " observed=" + std::to_string(st.observed) +
              " matched=" + std::to_string(st.matched) +
              " lost=" + std::to_string(st.lost) +
              " dup=" + std::to_string(st.duplicated) +
              " order=" + std::to_string(st.misordered) +
              " content=" + std::to_string(st.content_mismatch) +
              " invariant=" + std::to_string(d.invariant_failed ? 1 : 0);
        }
      }
      std::fflush(stdout);

      if (!pass_ok || !errors.ok()) {
        failed = true;
        if (first_failure.empty()) {
          first_failure =
              "pass " + pass_name + " failed: stop=" + harness::to_string(reason);
        }
      }
    }
  }

  // Coverage across the whole sweep: every crossing that exports an occupancy
  // port must have reached a non-trivial fill at least once.
  if (!failed) {
    for (const CrossingDut& d : duts) {
      if (d.wr_occ != nullptr && d.global_peak_occ < 2) {
        errors.error("coverage",
                     std::string(d.name) +
                         ": write-side occupancy never exceeded " +
                         std::to_string(d.global_peak_occ) +
                         " across the whole ratio sweep");
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
      passed ? "every crossing clean at every ratio" : first_failure;
  summary.passes = total_passes * duts.size();
  summary.core_cycles = total_cycles_a;
  summary.cfg_cycles = total_cycles_b;
  summary.sim_time_ps = sched.time();
  summary.beats_driven = total_beats_driven;
  summary.beats_observed = total_beats_observed;
  summary.frames_driven = total_frames_driven;
  summary.frames_observed = total_frames_observed;
  summary.scoreboard = totals;
  summary.absorb(errors);
  summary.wall_time_s =
      std::chrono::duration<double>(wall_end - wall_start).count();

  const std::string written = summary.write(args.results_dir);

  std::printf("--- summary ---\n");
  std::printf("  crossings      : %zu (%s, %s, %s)\n", duts.size(),
              duts[0].name, duts[1].name, duts[2].name);
  std::printf("  ratios         : %zu, stall profiles %zu, passes %zu\n",
              harness::clock_ratios().size(), stall_specs().size(),
              total_passes);
  std::printf("  cycles         : clk_a=%llu clk_b=%llu\n",
              static_cast<unsigned long long>(total_cycles_a),
              static_cast<unsigned long long>(total_cycles_b));
  std::printf("  beats          : driven=%llu observed=%llu matched=%llu\n",
              static_cast<unsigned long long>(total_beats_driven),
              static_cast<unsigned long long>(total_beats_observed),
              static_cast<unsigned long long>(totals.matched));
  std::printf("  loss/dup/order : %llu/%llu/%llu\n",
              static_cast<unsigned long long>(totals.lost),
              static_cast<unsigned long long>(totals.duplicated),
              static_cast<unsigned long long>(totals.misordered));
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
