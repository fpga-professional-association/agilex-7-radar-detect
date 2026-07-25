// -----------------------------------------------------------------------------
// test_stream_assertions.cpp — negative test for the SPEC 14 protocol assertions.
//
// The assertion set in sim/assertions/ is only worth having if it fires. This
// test drives sim/verilator/tops/stream_violator_top.sv — a deliberately broken
// stage with the checker attached by `bind` — once per violation mode, and
// requires:
//
//   mode 0  clean            NO assertion fires, over a full run with stalls
//   mode 1  stability        a_payload_stable fires
//   mode 2  valid withdrawn  a_valid_held fires
//   mode 3  discontinuity    a_seq_continuous fires
//   mode 4  framing          a_sof_opens_frame fires
//
// It is not enough that "an" assertion fires: each mode names the property it
// must provoke, and the run is failed if that exact property is absent — a
// checker that fired the wrong assertion would otherwise look like a pass.
//
// EXPECTED-FAILURE SEMANTICS
// --------------------------
// A failing Verilator assertion prints
//     %Error: <file>:<line>: Assertion failed in <hier>.<label>: 'assert' failed
// and calls vl_stop, which by default routes to vl_fatal and aborts the process.
// That is the right behaviour for every other test in this repository and is
// left alone. Here — and only here — `Verilated::fatalOnError(false)` turns the
// failure into an observable event: vl_stop then prints, sets gotError, and
// returns, so this test can observe the failure, name it, and exit 0 for a run
// in which every expected violation was detected. An unexpected clean run is the
// failure. (Measured under Verilator 5.020; DECISIONS.md 2026-07-26 decision 3.)
//
// The assertion text goes to stdout, so each mode runs with file descriptor 1
// redirected to a temporary file; the captured text is searched for the expected
// property name and then reprinted, so the transcript still shows exactly what
// fired. POSIX (dup/dup2) — simulation runs in WSL Ubuntu-24.04 by construction
// (PLAN.md split-toolchain rule).
//
// The stimulus source is the ordinary harness StreamDriver, which is
// protocol-correct by construction: any assertion that fires is therefore the
// DUT's fault and not the testbench's.
// -----------------------------------------------------------------------------

#include <unistd.h>

#include <chrono>
#include <cstdio>
#include <cstring>
#include <memory>
#include <string>
#include <vector>

#include "Vstream_violator_top.h"
#include "verilated.h"

#include "config_sim.h"
#include "harness/harness.h"

using harness::BackpressureConfig;
using harness::ClockScheduler;
using harness::ErrorCollector;
using harness::ResetSequencer;
using harness::RunSummary;
using harness::SeedSource;
using harness::SimArgs;
using harness::SimTime;
using harness::StopReason;
using harness::StreamBeat;
using harness::StreamDriver;
using harness::StreamLayout;

namespace {

constexpr const char* kTestName = "test_stream_assertions";

static_assert(sim_config::STREAM_PAYLOAD_W > 32 &&
                  sim_config::STREAM_PAYLOAD_W <= 64,
              "packed payload no longer maps to a Verilator QData port");

// Cycles to run per mode. Every injection happens within the first few dozen
// cycles; this is a generous ceiling that also gives the clean mode a real run.
constexpr std::uint64_t kCyclesPerMode = 400;

constexpr std::uint32_t kFrameLen = 4;
constexpr std::uint64_t kFramesPerMode = 24;

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

struct ModeSpec {
  unsigned mode;
  const char* name;
  const char* description;
  // Assertion label that must appear in the captured output. Empty means no
  // assertion may fire at all.
  const char* expect_label;
};

const std::vector<ModeSpec>& mode_specs() {
  static const std::vector<ModeSpec> specs = {
      {0, "clean", "correct one-deep stage", ""},
      {1, "stability", "payload mutated while stalled", "a_payload_stable"},
      {2, "valid_withdrawn", "offered beat retracted", "a_valid_held"},
      {3, "discontinuity", "sequence field corrupted in flight",
       "a_seq_continuous"},
      {4, "framing", "start-of-frame stripped from a frame-opening beat",
       "a_sof_opens_frame"},
  };
  return specs;
}

// ---------------------------------------------------------------------------
// stdout capture. Verilator writes assertion diagnostics with printf(3) to file
// descriptor 1, so the capture has to be at the descriptor level rather than at
// the std::ostream level.
// ---------------------------------------------------------------------------
class StdoutCapture {
 public:
  bool begin() {
    std::fflush(stdout);
    saved_fd_ = dup(STDOUT_FILENO);
    if (saved_fd_ < 0) return false;
    tmp_ = std::tmpfile();
    if (tmp_ == nullptr) {
      close(saved_fd_);
      saved_fd_ = -1;
      return false;
    }
    if (dup2(fileno(tmp_), STDOUT_FILENO) < 0) {
      std::fclose(tmp_);
      tmp_ = nullptr;
      close(saved_fd_);
      saved_fd_ = -1;
      return false;
    }
    return true;
  }

  std::string end() {
    if (saved_fd_ < 0) return std::string();
    std::fflush(stdout);
    dup2(saved_fd_, STDOUT_FILENO);
    close(saved_fd_);
    saved_fd_ = -1;

    std::string out;
    std::fseek(tmp_, 0, SEEK_SET);
    char buf[4096];
    std::size_t n;
    while ((n = std::fread(buf, 1, sizeof(buf), tmp_)) > 0) {
      out.append(buf, n);
    }
    std::fclose(tmp_);
    tmp_ = nullptr;
    return out;
  }

 private:
  int saved_fd_ = -1;
  std::FILE* tmp_ = nullptr;
};

// First `limit` lines of `text` that mention an assertion, for the transcript.
std::string assertion_lines(const std::string& text, std::size_t limit) {
  std::string out;
  std::size_t start = 0;
  std::size_t shown = 0;
  while (start < text.size() && shown < limit) {
    const std::size_t end = text.find('\n', start);
    const std::string line =
        text.substr(start, end == std::string::npos ? std::string::npos
                                                    : end - start);
    if (line.find("Assertion failed") != std::string::npos) {
      out += "      " + line + "\n";
      ++shown;
    }
    if (end == std::string::npos) break;
    start = end + 1;
  }
  return out;
}

std::size_t count_assertions(const std::string& text) {
  std::size_t n = 0;
  std::size_t pos = 0;
  const std::string needle = "Assertion failed";
  while ((pos = text.find(needle, pos)) != std::string::npos) {
    ++n;
    pos += needle.size();
  }
  return n;
}

// One frame of `kFrameLen` beats on stream 0, protocol-legal by construction.
std::vector<StreamBeat> make_frame(const StreamLayout& layout,
                                   std::uint32_t frame_index,
                                   std::uint32_t* next_seq) {
  std::vector<StreamBeat> frame;
  const std::uint32_t seq_mask =
      static_cast<std::uint32_t>(StreamLayout::mask_of(layout.seq_w));
  const std::uint32_t user_mask =
      static_cast<std::uint32_t>(StreamLayout::mask_of(layout.user_w));
  for (std::uint32_t i = 0; i < kFrameLen; ++i) {
    StreamBeat b;
    b.data = 0x5A5A0000u + (frame_index * kFrameLen + i);
    b.start_of_frame = (i == 0);
    b.end_of_frame = (i + 1 == kFrameLen);
    b.stream_id = 0;
    b.seq = *next_seq & seq_mask;
    b.user = frame_index & user_mask;
    *next_seq = (*next_seq + 1u) & seq_mask;
    frame.push_back(b);
  }
  return frame;
}

struct ModeResult {
  unsigned mode = 0;
  const char* name = "";
  bool fired = false;              // any assertion fired
  bool expected_seen = false;      // the named property fired
  std::size_t assertion_count = 0;
  std::uint64_t cycles = 0;
  std::string evidence;            // captured assertion lines
  bool ok = false;
};

// Runs one violation mode in a fresh model instance. Returns what happened; it
// never decides pass or fail, which keeps the reporting in one place.
ModeResult run_mode(const ModeSpec& spec, const StreamLayout& layout,
                    std::uint64_t seed, bool quiet) {
  ModeResult r;
  r.mode = spec.mode;
  r.name = spec.name;

  // Each mode gets a fresh model, so checker state (frame and sequence
  // tracking) never carries over from a mode that deliberately corrupted it.
  std::unique_ptr<Vstream_violator_top> top(new Vstream_violator_top);

  ErrorCollector errors;  // local: harness-side errors are reported by hand here
  ClockScheduler sched([&top]() { top->eval(); });

  const SimTime core_half = harness::half_period_ps(harness::kCoreClkMhz);
  const int clk = sched.add_clock("clk", core_half, &top->clk, core_half);

  ResetSequencer reset(sched);
  reset.add_domain("rst_n", clk, &top->rst_n, 8);

  top->viol_mode = static_cast<CData>(spec.mode);
  top->m_ready = 0;

  harness::PackedSourcePort src(&top->s_valid, &top->s_ready, &top->s_payload,
                                layout);
  SeedSource seeds(seed);
  StreamDriver driver("src", src,
                      seeds.engine(std::string("violator.src.") + spec.name),
                      BackpressureConfig::none(), errors);

  std::uint32_t next_seq = 0;
  for (std::uint64_t f = 0; f < kFramesPerMode; ++f) {
    driver.queue_frame(make_frame(layout, static_cast<std::uint32_t>(f), &next_seq));
  }

  // Deterministic sink: eight cycles ready, eight cycles stalled. The stall
  // window is what modes 1 and 2 need, and it also exercises the stability and
  // valid-held properties positively in the clean mode.
  //
  // Stimulus is gated until reset has been released. Without the gate the
  // violator's combinational `s_ready` is high throughout reset — its output
  // register is empty — so the driver would hand over beats that the module,
  // held in reset, never captures. The stream would then resume mid-frame and
  // every mode, including the clean one, would report a framing violation that
  // the testbench caused.
  std::uint64_t cycle = 0;
  bool stop_now = false;
  bool stimulus_enabled = false;

  sched.on_posedge_sample(clk, [&]() {
    if (!stimulus_enabled) return;
    driver.on_sample();
  });
  sched.on_posedge_drive(clk, [&]() {
    if (!stimulus_enabled) return;
    driver.on_drive();
    top->m_ready = ((cycle / 8) % 2 == 0) ? 1 : 0;
    ++cycle;
    if (Verilated::gotError() || cycle >= kCyclesPerMode) {
      if (!stop_now) {
        stop_now = true;
        sched.stop_pass(Verilated::gotError() ? "assertion fired"
                                              : "cycle budget reached");
      }
    }
  });

  Verilated::gotError(false);
  Verilated::gotFinish(false);

  StdoutCapture capture;
  const bool captured = capture.begin();

  driver.reset(false);
  reset.assert_all();
  const StopReason reset_reason = reset.release_all(
      static_cast<SimTime>(kCyclesPerMode + 1000) * core_half * 2);
  if (reset_reason == StopReason::kRunning) {
    stimulus_enabled = true;
    sched.run(static_cast<SimTime>(kCyclesPerMode + 1000) * core_half * 2);
    stimulus_enabled = false;
  }

  const std::string text = captured ? capture.end() : std::string();

  r.cycles = cycle;
  r.fired = Verilated::gotError();
  r.assertion_count = count_assertions(text);
  r.expected_seen =
      (spec.expect_label[0] == '\0')
          ? false
          : text.find(spec.expect_label) != std::string::npos;
  r.evidence = assertion_lines(text, 3);

  if (spec.expect_label[0] == '\0') {
    r.ok = !r.fired && r.assertion_count == 0 && errors.ok();
  } else {
    r.ok = r.fired && r.expected_seen;
  }

  // Leave the context clean for the next mode.
  Verilated::gotError(false);
  Verilated::gotFinish(false);
  top->final();

  if (!captured && !quiet) {
    std::printf("  WARNING: could not capture stdout for mode %u\n", spec.mode);
  }
  return r;
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

  // The one place in the repository where an assertion failure is not fatal.
  // Everything below depends on this line, and nothing above it does.
  Verilated::fatalOnError(false);

  std::printf("  expected-fail mode: assertion failures are observed, not fatal\n");

  ErrorCollector errors;
  std::vector<ModeResult> results;
  results.reserve(mode_specs().size());

  for (const ModeSpec& spec : mode_specs()) {
    const ModeResult r = run_mode(spec, layout, args.seed, args.quiet);
    results.push_back(r);

    if (!args.quiet) {
      if (spec.expect_label[0] == '\0') {
        std::printf("  mode %u %-16s %-52s -> %s (%zu assertions, %llu cycles)\n",
                    spec.mode, spec.name, spec.description,
                    r.ok ? "clean, as required" : "UNEXPECTED FAILURE",
                    r.assertion_count,
                    static_cast<unsigned long long>(r.cycles));
      } else {
        std::printf("  mode %u %-16s %-52s -> %s (%zu assertions, %llu cycles)\n",
                    spec.mode, spec.name, spec.description,
                    r.ok ? "expected failure observed" : "DID NOT FIRE",
                    r.assertion_count,
                    static_cast<unsigned long long>(r.cycles));
      }
      if (!r.evidence.empty()) std::printf("%s", r.evidence.c_str());
      std::fflush(stdout);
    }

    if (!r.ok) {
      if (spec.expect_label[0] == '\0') {
        errors.error("unexpected_assertion",
                     std::string("mode ") + spec.name +
                         " is protocol-correct but " +
                         std::to_string(r.assertion_count) +
                         " assertion(s) fired");
      } else if (!r.fired) {
        errors.error("assertion_missing",
                     std::string("mode ") + spec.name +
                         " violates the protocol but no assertion fired; " +
                         spec.expect_label + " is not load-bearing");
      } else {
        errors.error("assertion_wrong",
                     std::string("mode ") + spec.name + " fired " +
                         std::to_string(r.assertion_count) +
                         " assertion(s), but not the expected " +
                         spec.expect_label);
      }
    }
  }

  const bool passed = errors.ok();

  const auto wall_end = std::chrono::steady_clock::now();
  RunSummary summary;
  summary.test_name = kTestName;
  summary.config_name = sim_config::kName;
  summary.build_mode = args.build_mode;
  summary.seed = args.seed;
  summary.passed = passed;
  summary.stop_reason = passed ? "pass" : "error";
  summary.stop_detail =
      passed ? "every expected assertion fired; the clean mode stayed clean"
             : "an expected assertion did not fire, or a clean run asserted";
  summary.passes = mode_specs().size();
  summary.core_cycles = 0;
  for (const ModeResult& r : results) summary.core_cycles += r.cycles;
  summary.absorb(errors);
  summary.wall_time_s =
      std::chrono::duration<double>(wall_end - wall_start).count();

  const std::string written = summary.write(args.results_dir);

  std::printf("--- summary ---\n");
  std::printf("  modes          : %zu (1 clean, %zu violating)\n",
              mode_specs().size(), mode_specs().size() - 1);
  std::printf("  cycles         : %llu\n",
              static_cast<unsigned long long>(summary.core_cycles));
  std::printf("  errors         : %zu\n", errors.count());
  if (!written.empty()) std::printf("  summary json   : %s\n", written.c_str());

  if (passed) {
    std::printf("RESULT: PASS seed=%llu test=%s config=%s "
                "(expected failures observed in %zu modes)\n",
                static_cast<unsigned long long>(args.seed), kTestName,
                sim_config::kName, mode_specs().size() - 1);
    return 0;
  }
  std::printf("RESULT: FAIL seed=%llu test=%s config=%s errors=%zu\n",
              static_cast<unsigned long long>(args.seed), kTestName,
              sim_config::kName, errors.count());
  return 1;
}
