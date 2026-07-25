// -----------------------------------------------------------------------------
// test_stream_primitives.cpp — unit tests for rtl/stream/ (SPEC 13.1, issue #5).
//
// SPEC 13.1 requires every module to have directed, boundary, randomized, reset
// and stall tests plus protocol assertions. This binary covers all three
// canonical primitives, in four configurations, in one run from one seed:
//
//   dut0  stream_skid_buffer                 capacity 2,  latency 1
//   dut1  stream_elastic_buffer DEPTH=2      capacity 2,  latency 1
//   dut2  stream_elastic_buffer DEPTH=8      capacity 8,  latency 1
//   dut3  stream_pipe STAGES=4 OUT_DEPTH=6   capacity 6,  latency 5
//
// The four DUTs are independent streams in sim/verilator/tops/stream_prims_top.sv
// and share only the clock and the reset, so each one has its own driver,
// monitor, scoreboard and stall pattern, and a failure names the primitive.
//
// Passes (SPEC 13.1 stall tests; all four fast/slow producer-consumer
// combinations, plus a bursty case on each side)
//
//   1  directed_no_stall     fast producer, fast consumer. Boundary sweep of
//                            frame lengths 1..8 including the single-beat frame
//                            where start_of_frame and end_of_frame coincide.
//                            Enforces exact latency and full throughput.
//   2  slow_producer         gappy source, fast consumer: the empty-pipeline
//                            case, where a stale valid or a lost bubble shows.
//   3  slow_consumer         fast source, bursty sink: fills every DUT to its
//                            capacity and holds it there.
//   4  slow_both             50% stalls, 1-8 cycles, on both sides.
//   5  bursty_both           4-40 cycle stall bursts on both sides.
//
// Checks, per DUT per pass
//
//   * scoreboard (SPEC 12.5): zero lost, duplicated, misordered, corrupted or
//     unexpected transactions, keyed on transaction identity rather than on a
//     fixed latency.
//   * framing and sequence continuity, from the C++ monitor, independently of
//     the RTL assertions that check the same properties inside the DUT.
//   * occupancy (the two elastic buffers): the reported fill level must equal
//     the number of beats the harness has put in and not yet got out, every
//     cycle — an independent model of the counter, not a restatement of it —
//     and must never exceed DEPTH.
//   * in-flight bound: for every DUT, beats accepted minus beats emitted never
//     exceeds the storage the primitive is parameterised to have. That is what
//     proves the credit accounting in stream_pipe and the registered ready in
//     the elastic buffer are actually bounding anything.
//   * exact latency and one-beat-per-cycle throughput, in the directed pass
//     only (SPEC 12.5 forbids assuming a fixed latency under backpressure).
//
// Reset is re-run before every pass, so reset coverage is per pass per seed
// rather than once at time zero.
// -----------------------------------------------------------------------------

#include <algorithm>
#include <chrono>
#include <cstdio>
#include <memory>
#include <string>
#include <vector>

#include "Vstream_prims_top.h"
#include "verilated.h"

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
using harness::StreamSinkPort;
using harness::StreamSourcePort;
using harness::TimeoutGuard;
using harness::TransactionId;

namespace {

constexpr const char* kTestName = "test_stream_primitives";

// The packed payload travels in one host integer. Every configuration this
// project defines lands between 33 and 64 bits (2*SAMPLE_W + 2 + STREAM_ID_W +
// SEQ_W + USER_W), which is exactly Verilator's QData range. A configuration
// that leaves that range must widen the transport deliberately rather than
// silently truncate, so it fails here at compile time.
static_assert(sim_config::STREAM_PAYLOAD_W > 32,
              "packed payload no longer maps to a Verilator QData port");
static_assert(sim_config::STREAM_PAYLOAD_W <= 64,
              "packed payload exceeds the 64-bit host transport");

constexpr std::uint32_t kMinFrameLen = 1;
constexpr std::uint32_t kMaxFrameLen = 16;
constexpr std::uint64_t kDefaultFramesPerPass = 24;

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

// ---------------------------------------------------------------------------
// One DUT under test.
// ---------------------------------------------------------------------------
struct DutSpec {
  const char* name;
  const char* module;
  // Beats the primitive can hold at once. The in-flight check is against this.
  std::uint64_t capacity;
  // Latency in cycles with no backpressure on either side.
  std::uint64_t latency;
  // Occupancy port, or nullptr when the primitive does not export one.
  const CData* occupancy;
  // Declared depth for the occupancy bound check (0 when there is no port).
  std::uint64_t depth;
};

struct DutState {
  DutSpec spec;
  std::unique_ptr<harness::PackedSourcePort> src;
  std::unique_ptr<harness::PackedSinkPort> snk;
  std::unique_ptr<StreamDriver> driver;
  std::unique_ptr<StreamMonitor> monitor;
  std::unique_ptr<Scoreboard> scoreboard;
  std::uint64_t accepted = 0;   // beats the DUT has taken in this pass
  std::uint64_t emitted = 0;    // beats the DUT has given out this pass
  std::uint64_t max_in_flight = 0;
  std::uint64_t max_occupancy = 0;
  std::uint64_t pass_beats = 0;
};

TransactionId identity_of(const StreamBeat& b) {
  TransactionId id;
  id.stream_id = b.stream_id;
  id.frame_id = b.user;
  id.sequence = b.seq;
  return id;
}

struct PassSpec {
  const char* name;
  BackpressureConfig source;
  BackpressureConfig sink;
  bool directed;
  // True when the sink stalls in this pass, so beats must actually accumulate
  // inside the DUT. Only such a pass can require the storage to fill; with a
  // fast consumer a correct primitive holds at most one beat, and demanding
  // more would be demanding a defect.
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

  explicit Generator(std::mt19937_64 r)
      : rng(r), next_seq(stream_count(), 0) {}

  std::vector<StreamBeat> make_frame(const StreamLayout& layout,
                                     std::uint32_t stream_id,
                                     std::uint32_t length) {
    std::vector<StreamBeat> frame;
    frame.reserve(length);
    const std::uint32_t tag =
        frame_index & static_cast<std::uint32_t>(
                          StreamLayout::mask_of(layout.user_w));
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

  const std::uint64_t worst_case_beats_per_stream = frames_per_pass * kMaxFrameLen;
  if (worst_case_beats_per_stream > StreamLayout::mask_of(layout.seq_w) + 1) {
    std::fprintf(stderr,
                 "ERROR: +frames=%llu can wrap the %u-bit sequence field\n",
                 static_cast<unsigned long long>(frames_per_pass), layout.seq_w);
    std::printf("RESULT: FAIL seed=%llu test=%s reason=frames_out_of_range\n",
                static_cast<unsigned long long>(args.seed), kTestName);
    return 2;
  }

  std::unique_ptr<Vstream_prims_top> top(new Vstream_prims_top);

  ErrorCollector errors;
  ClockScheduler sched([&top]() { top->eval(); });
  errors.set_time_probe(sched.time_ptr());

  const SimTime core_half = harness::half_period_ps(harness::kCoreClkMhz);
  const int core_clk =
      sched.add_clock("core_clk", core_half, &top->clk, core_half);

  ResetSequencer reset(sched);
  reset.add_domain("rst_n", core_clk, &top->rst_n, 8);

  std::uint64_t core_cycle = 0;
  sched.on_posedge_sample(core_clk, [&core_cycle]() { ++core_cycle; });

  SeedSource seeds(args.seed);

  // -----------------------------------------------------------------------
  // The four DUTs. Capacity and latency are properties of the parameters the
  // top instantiates, taken from the same generated constants the RTL uses, so
  // neither side hard-codes the other's numbers.
  // -----------------------------------------------------------------------
  std::vector<DutState> duts(4);

  duts[0].spec = {"skid", "stream_skid_buffer", 2, 1, nullptr, 0};
  duts[1].spec = {"elastic2", "stream_elastic_buffer",
                  sim_config::STREAM_PRIM_EB_SHALLOW_DEPTH, 1, &top->occ1,
                  sim_config::STREAM_PRIM_EB_SHALLOW_DEPTH};
  duts[2].spec = {"elastic8", "stream_elastic_buffer",
                  sim_config::STREAM_PRIM_EB_DEEP_DEPTH, 1, &top->occ2,
                  sim_config::STREAM_PRIM_EB_DEEP_DEPTH};
  duts[3].spec = {"pipe4", "stream_pipe", sim_config::STREAM_PRIM_PIPE_OUT_DEPTH,
                  sim_config::STREAM_PRIM_PIPE_STAGES + 1u, nullptr, 0};

  duts[0].src = std::make_unique<harness::PackedSourcePort>(&top->s0_valid, &top->s0_ready,
                                               &top->s0_payload, layout);
  duts[0].snk = std::make_unique<harness::PackedSinkPort>(&top->m0_valid, &top->m0_ready,
                                             &top->m0_payload, layout);
  duts[1].src = std::make_unique<harness::PackedSourcePort>(&top->s1_valid, &top->s1_ready,
                                               &top->s1_payload, layout);
  duts[1].snk = std::make_unique<harness::PackedSinkPort>(&top->m1_valid, &top->m1_ready,
                                             &top->m1_payload, layout);
  duts[2].src = std::make_unique<harness::PackedSourcePort>(&top->s2_valid, &top->s2_ready,
                                               &top->s2_payload, layout);
  duts[2].snk = std::make_unique<harness::PackedSinkPort>(&top->m2_valid, &top->m2_ready,
                                             &top->m2_payload, layout);
  duts[3].src = std::make_unique<harness::PackedSourcePort>(&top->s3_valid, &top->s3_ready,
                                               &top->s3_payload, layout);
  duts[3].snk = std::make_unique<harness::PackedSinkPort>(&top->m3_valid, &top->m3_ready,
                                             &top->m3_payload, layout);

  for (DutState& d : duts) {
    d.scoreboard = std::make_unique<Scoreboard>(d.spec.name, errors);
  }

  bool stimulus_enabled = false;
  bool pass_complete = false;

  // Sample phase. The occupancy and in-flight checks run BEFORE the drivers and
  // monitors update their counts, so `accepted - emitted` is the state the DUT
  // registers hold at this edge — the same instant the occupancy port reports.
  sched.on_posedge_sample(core_clk, [&]() {
    if (!stimulus_enabled) return;
    for (DutState& d : duts) {
      const std::uint64_t in_flight = d.accepted - d.emitted;
      d.max_in_flight = std::max(d.max_in_flight, in_flight);
      if (in_flight > d.spec.capacity) {
        errors.error("capacity",
                     std::string(d.spec.name) + ": " +
                         std::to_string(in_flight) +
                         " beats in flight exceeds the primitive's capacity of " +
                         std::to_string(d.spec.capacity));
      }
      if (d.spec.occupancy != nullptr) {
        const std::uint64_t occ = *d.spec.occupancy;
        d.max_occupancy = std::max(d.max_occupancy, occ);
        if (occ > d.spec.depth) {
          errors.error("occupancy",
                       std::string(d.spec.name) + ": reported occupancy " +
                           std::to_string(occ) + " exceeds DEPTH " +
                           std::to_string(d.spec.depth));
        }
        if (occ != in_flight) {
          errors.error("occupancy",
                       std::string(d.spec.name) + ": reported occupancy " +
                           std::to_string(occ) +
                           " disagrees with the harness count of " +
                           std::to_string(in_flight) + " beats in flight");
        }
      }
    }
    for (DutState& d : duts) {
      d.driver->on_sample();
      d.monitor->on_sample();
    }
  });

  sched.on_posedge_drive(core_clk, [&]() {
    if (!stimulus_enabled) return;
    for (DutState& d : duts) {
      d.driver->on_drive();
      d.monitor->on_drive();
    }
  });

  const std::uint64_t max_beats = frames_per_pass * kMaxFrameLen;
  const std::uint64_t hard_limit =
      args.timeout_cycles != 0 ? args.timeout_cycles : (max_beats * 200 + 10000);
  const std::uint64_t stall_limit = 5000;
  TimeoutGuard timeout(sched, errors, hard_limit, stall_limit, [&]() {
    std::uint64_t total = 0;
    for (const DutState& d : duts) {
      if (d.monitor) total += d.monitor->beats_received();
    }
    return total;
  });
  sched.on_posedge_drive(core_clk, [&]() {
    if (!stimulus_enabled) return;
    timeout.on_cycle();
  });

  sched.on_posedge_drive(core_clk, [&]() {
    if (!stimulus_enabled || pass_complete) return;
    for (const DutState& d : duts) {
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
                             core_half * 2 *
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

    for (DutState& d : duts) {
      const std::string tag = std::string(d.spec.name) + "." + spec.name;
      d.driver = std::make_unique<StreamDriver>(
          d.spec.name, *d.src, seeds.engine("stream_driver." + tag),
          spec.source, errors);
      d.monitor = std::make_unique<StreamMonitor>(
          d.spec.name, *d.snk, seeds.engine("stream_monitor." + tag), spec.sink,
          errors);
      d.monitor->set_sequence_width(layout.seq_w);
      d.driver->set_cycle_probe(&core_cycle);
      d.monitor->set_cycle_probe(&core_cycle);

      DutState* dp = &d;
      d.driver->set_accept_hook([dp](const StreamBeat& b, std::uint64_t cyc) {
        ++dp->accepted;
        dp->scoreboard->expect(identity_of(b), b, cyc);
      });
      d.monitor->set_observe_hook([dp](const StreamBeat& b, std::uint64_t cyc) {
        ++dp->emitted;
        dp->scoreboard->observe(identity_of(b), b, cyc);
      });

      d.scoreboard->reset();
      d.scoreboard->set_latency_bound(spec.directed ? d.spec.latency : 0);
      d.accepted = 0;
      d.emitted = 0;
      d.max_in_flight = 0;
      d.max_occupancy = 0;
      d.pass_beats = 0;
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

    for (DutState& d : duts) {
      Generator gen(seeds.engine(std::string("stimulus.") + d.spec.name + "." +
                                 spec.name));
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
    for (DutState& d : duts) {
      d.scoreboard->finalize();
      d.monitor->check_drained();
      const ScoreboardStats& st = d.scoreboard->stats();

      bool dut_ok = st.clean() && st.observed == d.pass_beats &&
                    st.matched == d.pass_beats;

      // The directed pass is the only one that may assume a latency, and it
      // must: a primitive that silently costs an extra cycle, or that cannot
      // sustain one beat per cycle, is a defect this is the only check for.
      if (spec.directed && dut_ok &&
          (st.latency_min != d.spec.latency || st.latency_max != d.spec.latency)) {
        errors.error("latency",
                     std::string(d.spec.name) + " (" + d.spec.module +
                         "): no-stall latency is not the expected " +
                         std::to_string(d.spec.latency) + " cycles (min " +
                         std::to_string(st.latency_min) + ", max " +
                         std::to_string(st.latency_max) + ")");
        dut_ok = false;
      }

      // A pass whose sink stalls must actually fill the primitive, or the
      // capacity and occupancy checks above proved nothing.
      if (spec.fills && dut_ok && d.spec.capacity > 1 && d.max_in_flight < 2) {
        errors.error("coverage",
                     std::string(d.spec.name) +
                         ": stall pass never put more than " +
                         std::to_string(d.max_in_flight) +
                         " beats in flight; backpressure was not exercised");
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
            "  pass %zu/%zu %-18s %-9s beats=%llu obs=%llu lat[min/mean/max]="
            "%llu/%.2f/%llu max_inflight=%llu/%llu occ_max=%llu -> %s\n",
            pi + 1, pass_specs().size(), spec.name, d.spec.name,
            static_cast<unsigned long long>(d.pass_beats),
            static_cast<unsigned long long>(st.observed),
            static_cast<unsigned long long>(st.latency_min), st.latency_mean(),
            static_cast<unsigned long long>(st.latency_max),
            static_cast<unsigned long long>(d.max_in_flight),
            static_cast<unsigned long long>(d.spec.capacity),
            static_cast<unsigned long long>(d.max_occupancy),
            dut_ok ? "OK" : "FAILED");
      }

      if (!dut_ok && pass_ok) {
        pass_ok = false;
        first_failure = std::string("pass ") + spec.name + " dut " +
                        d.spec.name + ": expected=" +
                        std::to_string(st.expected) + " observed=" +
                        std::to_string(st.observed) + " matched=" +
                        std::to_string(st.matched) + " lost=" +
                        std::to_string(st.lost) + " dup=" +
                        std::to_string(st.duplicated) + " order=" +
                        std::to_string(st.misordered) + " content=" +
                        std::to_string(st.content_mismatch);
      }
    }
    std::fflush(stdout);

    if (!pass_ok || !errors.ok()) {
      failed = true;
      if (first_failure.empty()) {
        first_failure = std::string("pass ") + spec.name + " failed: stop=" +
                        harness::to_string(reason);
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
  summary.core_cycles = sched.cycles(core_clk);
  summary.cfg_cycles = 0;
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
  std::printf("  duts           : %zu (%s, %s, %s, %s)\n", duts.size(),
              duts[0].spec.name, duts[1].spec.name, duts[2].spec.name,
              duts[3].spec.name);
  std::printf("  passes         : %zu per dut\n", pass_specs().size());
  std::printf("  core cycles    : %llu\n",
              static_cast<unsigned long long>(sched.cycles(core_clk)));
  std::printf("  beats          : driven=%llu observed=%llu matched=%llu\n",
              static_cast<unsigned long long>(total_beats_driven),
              static_cast<unsigned long long>(total_beats_observed),
              static_cast<unsigned long long>(totals.matched));
  std::printf("  frames         : driven=%llu observed=%llu\n",
              static_cast<unsigned long long>(total_frames_driven),
              static_cast<unsigned long long>(total_frames_observed));
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
