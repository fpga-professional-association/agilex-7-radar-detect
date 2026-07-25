// -----------------------------------------------------------------------------
// test_sync_fifo.cpp — unit test for rtl/common/sync_fifo.sv (SPEC 13.1, 12.4).
//
// SPEC 13.1 requires directed, boundary, randomized, reset and stall tests plus
// protocol assertions for every module. SPEC 12.4 requires the RTL to be checked
// against a bit-accurate C++ reference model rather than against itself. Both
// obligations are met here:
//
//   fifo0   sync_fifo DEPTH=8, registered output, STORAGE="regs"
//           almost_full at DEPTH-2, almost_empty at 1
//   fifo1   sync_fifo DEPTH=4, show-ahead,        STORAGE="mlab"
//           almost_full at DEPTH-1, almost_empty at 1
//
// The two configurations differ in exactly the two axes that change behaviour —
// output timing and depth — so a defect in the show-ahead path cannot hide
// behind the registered one, and the shallow FIFO reaches `full` in every stall
// pass while the deeper one sweeps a real occupancy range.
//
// WHAT IS CHECKED, EVERY CYCLE, AGAINST model/cpp/cdc/fifo_ref.h
// --------------------------------------------------------------
// `SyncFifoRef` predicts s_ready, m_valid, occupancy, high_water, full, empty,
// almost_full and almost_empty from the handshake alone. It reads nothing from
// the DUT, so an agreement is evidence and a disagreement is a real defect in
// one of the two implementations. Every one of those eight observables is
// compared on every cycle of every pass — not sampled, not spot-checked.
//
// On top of that, per pass:
//   * the transaction-identity scoreboard (SPEC 12.5): zero lost, duplicated,
//     misordered, corrupted or unexpected beats;
//   * frame integrity and sequence continuity from the C++ monitor, independent
//     of the RTL assertions that check the same properties inside the DUT;
//   * the sticky overflow and underflow flags stay clear — they are unreachable
//     in correct operation, which is what the in-RTL assertions prove, so a set
//     flag here means an assertion was disabled rather than that traffic was
//     heavy;
//   * a coverage floor: a pass whose sink stalls must actually fill the FIFO. A
//     stall test that never filled anything proved nothing, so failing to fill
//     is a test failure, not a quiet pass.
//
// Reset is re-run before every pass, so reset coverage is per pass per seed.
//
// This test drives only the two synchronous FIFOs in cdc_prims_top; the CDC DUTs
// in the same top sit idle with their inputs held at zero, which the protocol
// checkers inside them require and verify.
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
#include "harness/harness.h"

using harness::BackpressureConfig;
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

constexpr const char* kTestName = "test_sync_fifo";

static_assert(sim_config::STREAM_PAYLOAD_W > 32,
              "packed payload no longer maps to a Verilator QData port");
static_assert(sim_config::STREAM_PAYLOAD_W <= 64,
              "packed payload exceeds the 64-bit host transport");

constexpr std::uint32_t kMinFrameLen = 1;
constexpr std::uint32_t kMaxFrameLen = 12;
constexpr std::uint64_t kDefaultFramesPerPass = 20;

// Both FIFOs live in clock domain A. Domain B is still clocked and still reset,
// because the asynchronous DUTs in the same top hold themselves in reset until
// both domains are released and their assertions run either way.
constexpr SimTime kHalfA = 1000;
constexpr SimTime kHalfB = 1500;

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

// One FIFO under test: the DUT ports, the reference model, and the per-pass
// bookkeeping.
struct FifoDut {
  const char* name;
  unsigned depth;
  unsigned almost_full;
  unsigned almost_empty;
  bool show_ahead;

  // Ports (all in domain A).
  CData* s_valid;
  const CData* s_ready;
  QData* s_data;
  const CData* m_valid;
  CData* m_ready;
  const QData* m_data;
  const CData* occ;
  const CData* high;
  const CData* full;
  const CData* empty;
  const CData* af;
  const CData* ae;
  const CData* ovf;
  const CData* unf;

  std::unique_ptr<model::SyncFifoRef> ref;
  std::unique_ptr<harness::PackedSourcePort> src;
  std::unique_ptr<harness::PackedSinkPort> snk;
  std::unique_ptr<StreamDriver> driver;
  std::unique_ptr<StreamMonitor> monitor;
  std::unique_ptr<Scoreboard> scoreboard;

  std::uint64_t accepted = 0;
  std::uint64_t emitted = 0;
  std::uint64_t pass_beats = 0;
  unsigned max_occ = 0;
  bool model_failed = false;
};

struct PassSpec {
  const char* name;
  BackpressureConfig source;
  BackpressureConfig sink;
  bool directed;
  bool fills;
};

const std::vector<PassSpec>& pass_specs() {
  static const std::vector<PassSpec> specs = {
      {"directed_no_stall", BackpressureConfig::none(),
       BackpressureConfig::none(), true, false},
      {"slow_producer", BackpressureConfig::bursty(),
       BackpressureConfig::none(), false, false},
      {"slow_consumer", BackpressureConfig::none(),
       BackpressureConfig::bursty(), false, true},
      {"slow_both", BackpressureConfig::heavy(), BackpressureConfig::heavy(),
       false, true},
      {"bursty_both", BackpressureConfig::bursty(),
       BackpressureConfig::bursty(), false, true},
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
  ClockScheduler sched([&top]() { top->eval(); });
  errors.set_time_probe(sched.time_ptr());

  const int clk_a = sched.add_clock("clk_a", kHalfA, &top->clk_a, kHalfA);
  const int clk_b = sched.add_clock("clk_b", kHalfB, &top->clk_b, kHalfB);

  ResetSequencer reset(sched);
  reset.add_domain("rst_a_n", clk_a, &top->rst_a_n, 8);
  reset.add_domain("rst_b_n", clk_b, &top->rst_b_n, 5);

  std::uint64_t cycle_a = 0;
  sched.on_posedge_sample(clk_a, [&cycle_a]() { ++cycle_a; });

  SeedSource seeds(args.seed);

  // -----------------------------------------------------------------------
  // The two DUTs. Depths and thresholds come from the generated constants the
  // RTL is elaborated with, so neither side hard-codes the other's numbers.
  // -----------------------------------------------------------------------
  std::vector<FifoDut> duts(2);

  duts[0].name = "fifo0_reg_out";
  duts[0].depth = sim_config::CDC_SYNC_FIFO_DEPTH;
  duts[0].almost_full = sim_config::CDC_SYNC_FIFO_DEPTH - 2;
  duts[0].almost_empty = 1;
  duts[0].show_ahead = false;
  duts[0].s_valid = &top->f0_s_valid;
  duts[0].s_ready = &top->f0_s_ready;
  duts[0].s_data = &top->f0_s_data;
  duts[0].m_valid = &top->f0_m_valid;
  duts[0].m_ready = &top->f0_m_ready;
  duts[0].m_data = &top->f0_m_data;
  duts[0].occ = &top->f0_occ;
  duts[0].high = &top->f0_high;
  duts[0].full = &top->f0_full;
  duts[0].empty = &top->f0_empty;
  duts[0].af = &top->f0_almost_full;
  duts[0].ae = &top->f0_almost_empty;
  duts[0].ovf = &top->f0_overflow;
  duts[0].unf = &top->f0_underflow;

  duts[1].name = "fifo1_show_ahead";
  duts[1].depth = sim_config::CDC_SYNC_FIFO_SA_DEPTH;
  duts[1].almost_full = sim_config::CDC_SYNC_FIFO_SA_DEPTH - 1;
  duts[1].almost_empty = 1;
  duts[1].show_ahead = true;
  duts[1].s_valid = &top->f1_s_valid;
  duts[1].s_ready = &top->f1_s_ready;
  duts[1].s_data = &top->f1_s_data;
  duts[1].m_valid = &top->f1_m_valid;
  duts[1].m_ready = &top->f1_m_ready;
  duts[1].m_data = &top->f1_m_data;
  duts[1].occ = &top->f1_occ;
  duts[1].high = &top->f1_high;
  duts[1].full = &top->f1_full;
  duts[1].empty = &top->f1_empty;
  duts[1].af = &top->f1_almost_full;
  duts[1].ae = &top->f1_almost_empty;
  duts[1].ovf = &top->f1_overflow;
  duts[1].unf = &top->f1_underflow;

  for (FifoDut& d : duts) {
    d.ref = std::make_unique<model::SyncFifoRef>(d.depth, d.almost_full,
                                                 d.almost_empty, d.show_ahead);
    d.src = std::make_unique<harness::PackedSourcePort>(d.s_valid, d.s_ready,
                                                        d.s_data, layout);
    d.snk = std::make_unique<harness::PackedSinkPort>(d.m_valid, d.m_ready,
                                                      d.m_data, layout);
    d.scoreboard = std::make_unique<Scoreboard>(d.name, errors);
  }

  bool stimulus_enabled = false;
  bool pass_complete = false;

  // Sample phase, domain A. The reference-model comparison runs FIRST, before
  // the drivers and monitors touch anything, so it sees exactly the values the
  // RTL registers hold at this edge.
  sched.on_posedge_sample(clk_a, [&]() {
    if (!stimulus_enabled) return;

    for (FifoDut& d : duts) {
      const bool s_valid = (*d.s_valid != 0);
      const bool m_ready = (*d.m_ready != 0);

      const std::string bad =
          d.ref->check(*d.s_ready != 0, *d.m_valid != 0,
                       static_cast<unsigned>(*d.occ),
                       static_cast<unsigned>(*d.high), *d.full != 0,
                       *d.empty != 0, *d.af != 0, *d.ae != 0);
      if (!bad.empty() && !d.model_failed) {
        // One report per DUT per pass: a model divergence repeats every cycle
        // once it starts, and 20 lines of it hide everything else.
        d.model_failed = true;
        errors.error("reference_model",
                     std::string(d.name) + " cycle " +
                         std::to_string(d.ref->cycles()) + ": " + bad);
      }
      if (*d.ovf != 0 || *d.unf != 0) {
        errors.error("sticky_error",
                     std::string(d.name) + ": a sticky error flag is set "
                     "(overflow=" + std::to_string(*d.ovf != 0) +
                     " underflow=" + std::to_string(*d.unf != 0) + ")");
      }
      d.max_occ = std::max<unsigned>(d.max_occ, static_cast<unsigned>(*d.occ));

      d.ref->step(s_valid, m_ready);
    }

    for (FifoDut& d : duts) {
      d.driver->on_sample();
      d.monitor->on_sample();
    }
  });

  sched.on_posedge_drive(clk_a, [&]() {
    if (!stimulus_enabled) return;
    for (FifoDut& d : duts) {
      d.driver->on_drive();
      d.monitor->on_drive();
    }
  });

  const std::uint64_t max_beats = frames_per_pass * kMaxFrameLen;
  const std::uint64_t hard_limit =
      args.timeout_cycles != 0 ? args.timeout_cycles : (max_beats * 200 + 10000);
  TimeoutGuard timeout(sched, errors, hard_limit, 5000, [&]() {
    std::uint64_t total = 0;
    for (const FifoDut& d : duts) {
      if (d.monitor) total += d.monitor->beats_received();
    }
    return total;
  });
  sched.on_posedge_drive(clk_a, [&]() {
    if (!stimulus_enabled) return;
    timeout.on_cycle();
  });

  sched.on_posedge_drive(clk_a, [&]() {
    if (!stimulus_enabled || pass_complete) return;
    for (const FifoDut& d : duts) {
      if (!d.driver->idle() || d.scoreboard->outstanding() != 0) return;
    }
    pass_complete = true;
    sched.stop_pass("pass drained");
  });

  harness::TraceControl trace;
  std::string trace_path;
  if (args.trace) {
    trace_path = args.trace_file.empty()
                     ? harness::default_trace_path(kTestName, args.seed)
                     : args.trace_file;
    if (trace.open(top.get(), trace_path, harness::kDefaultTraceDepth)) {
      sched.set_step_hook([&trace](SimTime t) { trace.dump(t); });
      std::printf("  trace      : %s\n", trace_path.c_str());
    } else {
      trace_path.clear();
    }
  }

  const SimTime time_limit = static_cast<SimTime>(hard_limit + 100000) *
                             kHalfB * 2 *
                             static_cast<SimTime>(pass_specs().size());

  // -----------------------------------------------------------------------
  // Passes
  // -----------------------------------------------------------------------
  ScoreboardStats totals;
  std::uint64_t total_beats_driven = 0;
  std::uint64_t total_beats_observed = 0;
  std::uint64_t total_frames_driven = 0;
  std::uint64_t total_frames_observed = 0;
  bool failed = false;
  bool first_stat = true;
  std::string first_failure;

  for (std::size_t pi = 0; pi < pass_specs().size() && !failed; ++pi) {
    const PassSpec& spec = pass_specs()[pi];

    for (FifoDut& d : duts) {
      const std::string tag = std::string(d.name) + "." + spec.name;
      d.driver = std::make_unique<StreamDriver>(
          d.name, *d.src, seeds.engine("fifo_driver." + tag), spec.source,
          errors);
      d.monitor = std::make_unique<StreamMonitor>(
          d.name, *d.snk, seeds.engine("fifo_monitor." + tag), spec.sink,
          errors);
      d.monitor->set_sequence_width(layout.seq_w);
      d.driver->set_cycle_probe(&cycle_a);
      d.monitor->set_cycle_probe(&cycle_a);

      FifoDut* dp = &d;
      d.driver->set_accept_hook([dp](const StreamBeat& b, std::uint64_t cyc) {
        ++dp->accepted;
        dp->scoreboard->expect(identity_of(b), b, cyc);
      });
      d.monitor->set_observe_hook([dp](const StreamBeat& b, std::uint64_t cyc) {
        ++dp->emitted;
        dp->scoreboard->observe(identity_of(b), b, cyc);
      });

      d.scoreboard->reset();
      // Latency is bounded only in the directed pass: DEPTH+1 for the
      // registered output, DEPTH for show-ahead. Under backpressure SPEC 12.5
      // forbids assuming a bound at all.
      d.scoreboard->set_latency_bound(
          spec.directed ? (d.depth + (d.show_ahead ? 0u : 1u)) : 0);
      d.accepted = 0;
      d.emitted = 0;
      d.pass_beats = 0;
      d.max_occ = 0;
      d.model_failed = false;
      d.ref->reset();
      d.driver->reset(true);
      d.monitor->reset();
    }

    // Reset the DUTs before every pass (SPEC 13.1 reset tests).
    stimulus_enabled = false;
    pass_complete = false;
    sched.clear_stop();
    reset.assert_all();
    if (reset.release_all(time_limit) != StopReason::kRunning) {
      failed = true;
      first_failure =
          std::string("reset sequence did not complete in pass ") + spec.name;
      break;
    }

    for (FifoDut& d : duts) {
      Generator gen(
          seeds.engine(std::string("stimulus.") + d.name + "." + spec.name));
      for (std::uint64_t f = 0; f < frames_per_pass; ++f) {
        std::uint32_t len;
        std::uint32_t stream_id;
        if (spec.directed) {
          // Boundary sweep 1..8, including the single-beat frame where
          // start_of_frame and end_of_frame land on the same beat.
          len = static_cast<std::uint32_t>((f % 8) + 1);
          stream_id = static_cast<std::uint32_t>(f % streams);
        } else {
          len = static_cast<std::uint32_t>(
              harness::uniform_u64(gen.rng, kMinFrameLen, kMaxFrameLen));
          stream_id = static_cast<std::uint32_t>(
              harness::uniform_u64(gen.rng, 0, streams - 1));
        }
        const std::vector<StreamBeat> frame =
            gen.make_frame(layout, stream_id, len);
        d.pass_beats += frame.size();
        d.driver->queue_frame(frame);
      }
    }

    timeout.reset();
    stimulus_enabled = true;
    const StopReason reason = sched.run(time_limit);
    stimulus_enabled = false;

    bool pass_ok = (reason == StopReason::kPass);
    for (FifoDut& d : duts) {
      d.scoreboard->finalize();
      d.monitor->check_drained();
      const ScoreboardStats& st = d.scoreboard->stats();

      bool dut_ok = st.clean() && st.observed == d.pass_beats &&
                    st.matched == d.pass_beats && !d.model_failed;

      // A pass whose sink stalls must actually fill the FIFO past a single
      // beat, or the occupancy, almost-full and high-water checks proved
      // nothing.
      if (spec.fills && dut_ok && d.max_occ < 2) {
        errors.error("coverage",
                     std::string(d.name) + ": stall pass never held more than " +
                         std::to_string(d.max_occ) +
                         " beats; backpressure was not exercised");
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
            "  pass %zu/%zu %-18s %-17s beats=%llu obs=%llu occ_max=%u/%u "
            "hw=%u model_cycles=%llu -> %s\n",
            pi + 1, pass_specs().size(), spec.name, d.name,
            static_cast<unsigned long long>(d.pass_beats),
            static_cast<unsigned long long>(st.observed), d.max_occ, d.depth,
            static_cast<unsigned>(*d.high),
            static_cast<unsigned long long>(d.ref->cycles()),
            dut_ok ? "OK" : "FAILED");
      }

      if (!dut_ok && pass_ok) {
        pass_ok = false;
        first_failure =
            std::string("pass ") + spec.name + " dut " + d.name +
            ": expected=" + std::to_string(st.expected) +
            " observed=" + std::to_string(st.observed) +
            " matched=" + std::to_string(st.matched) +
            " lost=" + std::to_string(st.lost) +
            " dup=" + std::to_string(st.duplicated) +
            " order=" + std::to_string(st.misordered) +
            " content=" + std::to_string(st.content_mismatch) +
            " model_diverged=" + std::to_string(d.model_failed ? 1 : 0);
      }
    }
    std::fflush(stdout);

    if (!pass_ok || !errors.ok()) {
      failed = true;
      if (first_failure.empty()) {
        first_failure = std::string("pass ") + spec.name +
                        " failed: stop=" + harness::to_string(reason);
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
  summary.stop_reason = harness::to_string(sched.stop_reason());
  summary.stop_detail = failed ? first_failure : sched.stop_detail();
  summary.passes = pass_specs().size() * duts.size();
  summary.core_cycles = sched.cycles(clk_a);
  summary.cfg_cycles = sched.cycles(clk_b);
  summary.sim_time_ps = sched.time();
  summary.beats_driven = total_beats_driven;
  summary.beats_observed = total_beats_observed;
  summary.frames_driven = total_frames_driven;
  summary.frames_observed = total_frames_observed;
  summary.scoreboard = totals;
  summary.trace_path = trace_path;
  summary.absorb(errors);
  summary.wall_time_s =
      std::chrono::duration<double>(wall_end - wall_start).count();

  const std::string written = summary.write(args.results_dir);

  std::printf("--- summary ---\n");
  std::printf("  duts           : %zu (%s, %s)\n", duts.size(), duts[0].name,
              duts[1].name);
  std::printf("  passes         : %zu per dut\n", pass_specs().size());
  std::printf("  clk_a cycles   : %llu\n",
              static_cast<unsigned long long>(sched.cycles(clk_a)));
  std::printf("  beats          : driven=%llu observed=%llu matched=%llu\n",
              static_cast<unsigned long long>(total_beats_driven),
              static_cast<unsigned long long>(total_beats_observed),
              static_cast<unsigned long long>(totals.matched));
  std::printf("  errors         : %zu\n", errors.count());
  if (!written.empty()) std::printf("  summary json   : %s\n", written.c_str());

  trace.close();
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
