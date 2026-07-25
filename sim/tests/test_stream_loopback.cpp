// -----------------------------------------------------------------------------
// test_stream_loopback.cpp — Phase 0 randomized ready/valid loopback test.
//
// Spec: SPEC 19 Phase 0 ("One trivial stream loopback test"), SPEC 13.1 (every
// module needs directed, boundary, randomized, reset and stall tests),
// SPEC 12.5 (transaction-identity scoreboarding), SPEC 5 (stream protocol).
//
// The DUT is deliberately trivial. The subject under test is the harness: the
// multi-clock scheduler, the reset sequencer, the randomized-stall driver and
// monitor, and the scoreboard. A bug in any of those shows up here as a false
// failure against a DUT that provably cannot lose, duplicate or reorder a beat,
// which is exactly why the loopback exists before any real RTL.
//
// Passes (all run in one binary invocation, all from one master seed):
//
//   1  directed_no_stall   no stalls on either side. Proves full throughput and
//                          a fixed 2-cycle latency, and enforces the SPEC 12.5
//                          bounded-latency check with a tight bound. Frame
//                          lengths sweep 1..8 including the length-1 boundary
//                          case where start_of_frame and end_of_frame coincide.
//   2  random_light        10% stalls, 1-2 cycles, both sides.
//   3  random_heavy        50% stalls, 1-8 cycles, both sides.
//   4  random_sink_bursty  source runs flat out, sink stalls in 4-40 cycle
//                          bursts: fills both skid slots and holds them full.
//   5  random_source_gappy source stalls in bursts, sink runs flat out: the
//                          empty-pipeline case, where a stale valid would show.
//
// Every pass re-runs the reset sequence, so reset is covered on every seed
// rather than once at time zero.
//
// Checks, per pass: zero lost / duplicated / misordered / corrupted beats
// (scoreboard), frame integrity and sequence continuity (monitor), no timeout,
// and every beat driven accounted for.
// -----------------------------------------------------------------------------

#include <algorithm>
#include <chrono>
#include <cstdio>
#include <memory>
#include <string>
#include <vector>

#include "Vbenchmark_sim_top.h"
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
using harness::StreamMonitor;
using harness::StreamSinkPort;
using harness::StreamSourcePort;
using harness::TimeoutGuard;
using harness::TransactionId;

namespace {

constexpr const char* kTestName = "test_stream_loopback";

// Payload masks from the generated configuration, so a width change in
// config/<name>.json cannot silently corrupt a field.
constexpr std::uint64_t kDataMask = sim_config::mask_bits(sim_config::STREAM_DATA_W);
constexpr std::uint32_t kIdMask =
    static_cast<std::uint32_t>(sim_config::mask_bits(sim_config::STREAM_ID_W));
constexpr std::uint32_t kSeqMask =
    static_cast<std::uint32_t>(sim_config::mask_bits(sim_config::STREAM_SEQ_W));
constexpr std::uint32_t kUserMask =
    static_cast<std::uint32_t>(sim_config::mask_bits(sim_config::STREAM_USER_W));

constexpr std::uint32_t kMinFrameLen = 1;
constexpr std::uint32_t kMaxFrameLen = 16;
constexpr std::uint64_t kDefaultFramesPerPass = 48;

// Latency, in core cycles, of the provisional loopback with no backpressure:
// one cycle per skid stage. The directed pass enforces this exactly; the
// randomized passes cannot, because latency there is a function of how long the
// sink stalls (SPEC 12.5: do not assume a fixed end-to-end latency).
constexpr std::uint64_t kNoStallLatency = sim_config::STREAM_LOOPBACK_STAGES;

// Number of concurrent logical streams driven through the loopback: one per
// antenna, capped by what stream_id can encode.
std::uint32_t stream_count() {
  return std::min<std::uint32_t>(sim_config::N_ANTENNAS, kIdMask + 1u);
}

template <class T>
inline void put(T& dst, std::uint64_t v) {
  dst = static_cast<T>(v);
}

// ---------------------------------------------------------------------------
// Port adapters: the only code in the harness stack that knows the model type.
// ---------------------------------------------------------------------------

class LoopbackSource : public StreamSourcePort {
 public:
  explicit LoopbackSource(Vbenchmark_sim_top* top) : top_(top) {}

  void drive_valid(bool v) override { put(top_->s_valid, v ? 1u : 0u); }

  void drive_payload(const StreamBeat& b) override {
    put(top_->s_data, b.data & kDataMask);
    put(top_->s_start_of_frame, b.start_of_frame ? 1u : 0u);
    put(top_->s_end_of_frame, b.end_of_frame ? 1u : 0u);
    put(top_->s_stream_id, b.stream_id & kIdMask);
    put(top_->s_sequence, b.sequence & kSeqMask);
    put(top_->s_user, b.user & kUserMask);
  }

  bool sample_valid() const override { return top_->s_valid != 0; }
  bool sample_ready() const override { return top_->s_ready != 0; }

 private:
  Vbenchmark_sim_top* top_;
};

class LoopbackSink : public StreamSinkPort {
 public:
  explicit LoopbackSink(Vbenchmark_sim_top* top) : top_(top) {}

  void drive_ready(bool r) override { put(top_->m_ready, r ? 1u : 0u); }
  bool sample_valid() const override { return top_->m_valid != 0; }
  bool sample_ready() const override { return top_->m_ready != 0; }

  StreamBeat sample_payload() const override {
    StreamBeat b;
    b.data = static_cast<std::uint64_t>(top_->m_data) & kDataMask;
    b.start_of_frame = top_->m_start_of_frame != 0;
    b.end_of_frame = top_->m_end_of_frame != 0;
    b.stream_id = static_cast<std::uint32_t>(top_->m_stream_id) & kIdMask;
    b.sequence = static_cast<std::uint32_t>(top_->m_sequence) & kSeqMask;
    b.user = static_cast<std::uint32_t>(top_->m_user) & kUserMask;
    return b;
  }

 private:
  Vbenchmark_sim_top* top_;
};

// ---------------------------------------------------------------------------
// Transaction identity (SPEC 12.5).
//
// The provisional bundle carries no frame_id field, so the frame tag rides in
// `user` — which also makes `user` a checked field end to end instead of dead
// padding. Uniqueness of the identity within a pass comes from `sequence`,
// which increments monotonically per stream; the guard in sim_test_main()
// refuses to run a pass long enough to wrap it.
// ---------------------------------------------------------------------------
TransactionId identity_of(const StreamBeat& b) {
  TransactionId id;
  id.stream_id = b.stream_id;
  id.frame_id = b.user;
  id.sequence = b.sequence;
  return id;
}

struct PassSpec {
  const char* name;
  BackpressureConfig source;
  BackpressureConfig sink;
  bool directed;  // fixed frame-length sweep instead of random lengths
};

const std::vector<PassSpec>& pass_specs() {
  static const std::vector<PassSpec> specs = {
      {"directed_no_stall", BackpressureConfig::none(),
       BackpressureConfig::none(), true},
      {"random_light", BackpressureConfig::light(), BackpressureConfig::light(),
       false},
      {"random_heavy", BackpressureConfig::heavy(), BackpressureConfig::heavy(),
       false},
      {"random_sink_bursty", BackpressureConfig::none(),
       BackpressureConfig::bursty(), false},
      {"random_source_gappy", BackpressureConfig::bursty(),
       BackpressureConfig::none(), false},
  };
  return specs;
}

// Running total across passes, for the run summary.
void accumulate(ScoreboardStats* total, const ScoreboardStats& s,
                bool first) {
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
  total->latency_min = first ? s.latency_min
                             : std::min(total->latency_min, s.latency_min);
  total->latency_max = std::max(total->latency_max, s.latency_max);
}

// ---------------------------------------------------------------------------
// Stimulus generation.
// ---------------------------------------------------------------------------

struct Generator {
  std::mt19937_64 rng;
  std::vector<std::uint32_t> next_seq;  // per stream
  std::uint32_t frame_index = 0;

  explicit Generator(std::mt19937_64 r)
      : rng(r), next_seq(stream_count(), 0) {}

  // One frame: `length` beats on one stream, start_of_frame on the first and
  // end_of_frame on the last (both on the same beat when length == 1).
  std::vector<StreamBeat> make_frame(std::uint32_t stream_id,
                                     std::uint32_t length) {
    std::vector<StreamBeat> frame;
    frame.reserve(length);
    const std::uint32_t tag = frame_index & kUserMask;
    for (std::uint32_t i = 0; i < length; ++i) {
      StreamBeat b;
      b.data = harness::uniform_u64(rng, 0, kDataMask);
      b.start_of_frame = (i == 0);
      b.end_of_frame = (i + 1 == length);
      b.stream_id = stream_id;
      b.sequence = next_seq[stream_id] & kSeqMask;
      b.user = tag;
      next_seq[stream_id] = (next_seq[stream_id] + 1u) & kSeqMask;
      frame.push_back(b);
    }
    ++frame_index;
    return frame;
  }
};

}  // namespace

// ---------------------------------------------------------------------------
// Test entry point (main() lives in sim/verilator/sim_main.cpp).
// ---------------------------------------------------------------------------
int harness::sim_test_main(const SimArgs& args) {
  const auto wall_start = std::chrono::steady_clock::now();

  const std::uint64_t frames_per_pass =
      args.frames != 0 ? args.frames : kDefaultFramesPerPass;
  const std::uint32_t streams = stream_count();

  // Sequence-space guard: the scoreboard identity is unique only while the
  // sequence field does not wrap within a pass.
  const std::uint64_t worst_case_beats_per_stream =
      frames_per_pass * kMaxFrameLen;
  if (worst_case_beats_per_stream > (static_cast<std::uint64_t>(kSeqMask) + 1)) {
    std::fprintf(stderr,
                 "ERROR: +frames=%llu can wrap the %u-bit sequence field "
                 "(worst case %llu beats/stream); transaction identity would "
                 "not be unique.\n",
                 static_cast<unsigned long long>(frames_per_pass),
                 sim_config::STREAM_SEQ_W,
                 static_cast<unsigned long long>(worst_case_beats_per_stream));
    std::printf("RESULT: FAIL seed=%llu test=%s reason=frames_out_of_range\n",
                static_cast<unsigned long long>(args.seed), kTestName);
    return 2;
  }

  std::unique_ptr<Vbenchmark_sim_top> top(new Vbenchmark_sim_top);

  ErrorCollector errors;
  ClockScheduler sched([&top]() { top->eval(); });
  errors.set_time_probe(sched.time_ptr());

  // --- clocks (SPEC 8) ---------------------------------------------------
  // Two asynchronous domains at Phase 0. core_clk is the datapath clock; the
  // cfg_clk domain exists so the scheduler is genuinely multi-clock and the
  // reset sequencer has two independent domains to release.
  const SimTime core_half = harness::half_period_ps(harness::kCoreClkMhz);
  const SimTime cfg_half = harness::half_period_ps(harness::kCfgClkMhz);
  const int core_clk =
      sched.add_clock("core_clk", core_half, &top->core_clk, core_half);
  // Deliberately offset so the two domains rarely share an edge instant: it
  // keeps the coincident-edge path from being the only path exercised, and it
  // is what a genuinely asynchronous domain looks like.
  const int cfg_clk =
      sched.add_clock("cfg_clk", cfg_half, &top->cfg_clk, cfg_half / 3);

  // --- reset sequencing --------------------------------------------------
  ResetSequencer reset(sched);
  reset.add_domain("core_rst_n", core_clk, &top->core_rst_n, 8);
  reset.add_domain("cfg_rst_n", cfg_clk, &top->cfg_rst_n, 3);

  // --- cycle probe -------------------------------------------------------
  // Registered before every other core_clk sample callback, so the value the
  // driver and monitor stamp on a beat is the cycle of the edge at which the
  // transfer happens.
  std::uint64_t core_cycle = 0;
  sched.on_posedge_sample(core_clk, [&core_cycle]() { ++core_cycle; });

  // --- harness components ------------------------------------------------
  SeedSource seeds(args.seed);
  LoopbackSource src_port(top.get());
  LoopbackSink snk_port(top.get());
  Scoreboard scoreboard("loopback", errors);

  // Rebuilt per pass so each pass gets its own stall generator. The callbacks
  // below hold the owning pointers, not the objects.
  std::unique_ptr<StreamDriver> driver;
  std::unique_ptr<StreamMonitor> monitor;

  bool stimulus_enabled = false;
  bool pass_complete = false;

  sched.on_posedge_sample(core_clk, [&]() {
    if (!stimulus_enabled) return;
    driver->on_sample();
    monitor->on_sample();
  });
  sched.on_posedge_drive(core_clk, [&]() {
    if (!stimulus_enabled) return;
    driver->on_drive();
    monitor->on_drive();
  });

  // --- timeout (SPEC 12.3 step 6) ---------------------------------------
  // Hard limit sized from the worst plausible pass. The stall limit is what
  // actually fires on a deadlock, and is far tighter.
  const std::uint64_t max_beats = frames_per_pass * kMaxFrameLen;
  const std::uint64_t hard_limit =
      args.timeout_cycles != 0 ? args.timeout_cycles : (max_beats * 200 + 10000);
  const std::uint64_t stall_limit = 5000;
  TimeoutGuard timeout(sched, errors, hard_limit, stall_limit, [&]() {
    return monitor ? monitor->beats_received() : 0;
  });
  sched.on_posedge_drive(core_clk, [&]() {
    if (!stimulus_enabled) return;
    timeout.on_cycle();
  });

  // --- pass completion ---------------------------------------------------
  sched.on_posedge_drive(core_clk, [&]() {
    if (!stimulus_enabled || pass_complete) return;
    if (driver->idle() && scoreboard.outstanding() == 0) {
      pass_complete = true;
      sched.stop_pass("pass drained");
    }
  });

  // --- optional tracing (debug build only) -------------------------------
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

  // Absolute wall of simulated time across all passes. Generous; the
  // cycle-based timeout is the real guard.
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
  std::string first_failure;

  for (std::size_t pi = 0; pi < pass_specs().size() && !failed; ++pi) {
    const PassSpec& spec = pass_specs()[pi];

    // Substream names, not draw order, fix each generator's sequence: adding a
    // component never perturbs an existing one's stimulus for a given seed.
    driver = std::make_unique<StreamDriver>(
        "src", src_port,
        seeds.engine(std::string("stream_driver.src.") + spec.name),
        spec.source, errors);
    monitor = std::make_unique<StreamMonitor>(
        "snk", snk_port,
        seeds.engine(std::string("stream_monitor.snk.") + spec.name),
        spec.sink, errors);
    monitor->set_sequence_width(sim_config::STREAM_SEQ_W);
    driver->set_cycle_probe(&core_cycle);
    monitor->set_cycle_probe(&core_cycle);
    driver->set_accept_hook([&](const StreamBeat& b, std::uint64_t cyc) {
      scoreboard.expect(identity_of(b), b, cyc);
    });
    monitor->set_observe_hook([&](const StreamBeat& b, std::uint64_t cyc) {
      scoreboard.observe(identity_of(b), b, cyc);
    });

    scoreboard.reset();
    // SPEC 12.5 bounded latency: enforceable exactly when neither side stalls.
    scoreboard.set_latency_bound(spec.directed ? kNoStallLatency : 0);

    // Reset the DUT before every pass (SPEC 13.1 reset tests).
    stimulus_enabled = false;
    pass_complete = false;
    driver->reset(true);
    monitor->reset();
    sched.clear_stop();
    reset.assert_all();
    if (reset.release_all(time_limit) != StopReason::kRunning) {
      failed = true;
      first_failure =
          std::string("reset sequence did not complete in pass ") + spec.name;
      break;
    }

    // Build this pass's stimulus.
    Generator gen(seeds.engine(std::string("stimulus.") + spec.name));
    std::uint64_t pass_beats = 0;
    for (std::uint64_t f = 0; f < frames_per_pass; ++f) {
      std::uint32_t len;
      std::uint32_t stream_id;
      if (spec.directed) {
        // Boundary sweep: 1..8, including the single-beat frame where
        // start_of_frame and end_of_frame land on the same beat.
        len = static_cast<std::uint32_t>((f % 8) + 1);
        stream_id = static_cast<std::uint32_t>(f % streams);
      } else {
        len = static_cast<std::uint32_t>(
            harness::uniform_u64(gen.rng, kMinFrameLen, kMaxFrameLen));
        stream_id = static_cast<std::uint32_t>(
            harness::uniform_u64(gen.rng, 0, streams - 1));
      }
      const std::vector<StreamBeat> frame = gen.make_frame(stream_id, len);
      pass_beats += frame.size();
      driver->queue_frame(frame);
    }

    timeout.reset();
    stimulus_enabled = true;
    const StopReason reason = sched.run(time_limit);
    stimulus_enabled = false;

    scoreboard.finalize();
    monitor->check_drained();

    const ScoreboardStats& st = scoreboard.stats();
    bool pass_ok = (reason == StopReason::kPass) && st.clean() && errors.ok() &&
                   st.observed == pass_beats && st.matched == pass_beats;

    // The directed pass additionally proves full throughput: with no stalls on
    // either side, every beat must traverse in exactly kNoStallLatency cycles.
    if (spec.directed && pass_ok &&
        (st.latency_max != kNoStallLatency ||
         st.latency_min != kNoStallLatency)) {
      errors.error("throughput",
                   "directed pass latency is not the expected fixed " +
                       std::to_string(kNoStallLatency) + " cycles (min " +
                       std::to_string(st.latency_min) + ", max " +
                       std::to_string(st.latency_max) +
                       "): the loopback did not sustain one beat per cycle");
      pass_ok = false;
    }

    accumulate(&totals, st, pi == 0);
    total_beats_driven += driver->beats_sent();
    total_beats_observed += monitor->beats_received();
    total_frames_driven += frames_per_pass;
    total_frames_observed += monitor->frames_received();

    if (!args.quiet) {
      std::printf(
          "  pass %zu/%zu %-20s beats=%llu obs=%llu lat[min/mean/max]="
          "%llu/%.2f/%llu src_stall=%llu snk_stall=%llu -> %s\n",
          pi + 1, pass_specs().size(), spec.name,
          static_cast<unsigned long long>(pass_beats),
          static_cast<unsigned long long>(st.observed),
          static_cast<unsigned long long>(st.latency_min), st.latency_mean(),
          static_cast<unsigned long long>(st.latency_max),
          static_cast<unsigned long long>(driver->backpressure().stall_cycles()),
          static_cast<unsigned long long>(monitor->backpressure().stall_cycles()),
          pass_ok ? "OK" : "FAILED");
      std::fflush(stdout);
    }

    if (!pass_ok) {
      failed = true;
      first_failure =
          std::string("pass ") + spec.name +
          " failed: stop=" + harness::to_string(reason) +
          " expected=" + std::to_string(st.expected) +
          " observed=" + std::to_string(st.observed) +
          " matched=" + std::to_string(st.matched) +
          " lost=" + std::to_string(st.lost) +
          " dup=" + std::to_string(st.duplicated) +
          " order=" + std::to_string(st.misordered) +
          " content=" + std::to_string(st.content_mismatch) +
          " errors=" + std::to_string(errors.count());
    }
  }

  const bool passed = !failed && errors.ok();

  // Evidence that the second clock domain really ran: the only Phase 0 proof
  // that the scheduler is multi-clock rather than single-clock with a spare net.
  const std::uint32_t heartbeat = static_cast<std::uint32_t>(top->cfg_heartbeat);

  // -----------------------------------------------------------------------
  // Run summary (results/simulation/, gitignored).
  // -----------------------------------------------------------------------
  const auto wall_end = std::chrono::steady_clock::now();
  RunSummary summary;
  summary.test_name = kTestName;
  summary.config_name = sim_config::kName;
  summary.build_mode = args.build_mode;
  summary.seed = args.seed;
  summary.passed = passed;
  summary.stop_reason = harness::to_string(sched.stop_reason());
  summary.stop_detail = failed ? first_failure : sched.stop_detail();
  summary.passes = pass_specs().size();
  summary.core_cycles = sched.cycles(core_clk);
  summary.cfg_cycles = sched.cycles(cfg_clk);
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
  std::printf("  passes         : %zu\n", pass_specs().size());
  std::printf("  core cycles    : %llu (%.3f MHz)\n",
              static_cast<unsigned long long>(sched.cycles(core_clk)),
              harness::realized_mhz(core_half));
  std::printf("  cfg cycles     : %llu (%.3f MHz), heartbeat=%u\n",
              static_cast<unsigned long long>(sched.cycles(cfg_clk)),
              harness::realized_mhz(cfg_half), heartbeat);
  std::printf("  sim time       : %llu ps\n",
              static_cast<unsigned long long>(sched.time()));
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
