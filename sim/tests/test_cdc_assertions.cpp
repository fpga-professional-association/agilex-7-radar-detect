// -----------------------------------------------------------------------------
// test_cdc_assertions.cpp — negative test for the SPEC 14 CDC assertions.
//
// The CDC assertion set in sim/assertions/cdc_sva.svh is only worth having if it
// fires. This test drives sim/verilator/tops/cdc_violator_top.sv — a
// deliberately broken crossing with cdc_gray_checker and cdc_handshake_checker
// attached by `bind` — once per violation mode, and requires:
//
//   mode 0  clean            NO assertion fires, over a full run
//   mode 1  gray_is_binary   a_gray_one_bit fires
//   mode 2  data_mutates     a_hs_data_stable fires
//   mode 3  req_withdrawn    a_hs_req_held fires
//   mode 4  spurious_ack     a_hs_ack_after_req fires
//
// Modes 1 and 2 are the two the issue #6 gate names explicitly: the Gray
// transition rule and the handshake payload-stability rule are the two
// properties the whole asynchronous-FIFO and multibit-handshake construction
// rests on, so they are the two that must be shown to be load-bearing.
//
// It is not enough that "an" assertion fires: each mode names the property it
// must provoke, and the run fails if that exact property is absent — a checker
// that fired the wrong assertion would otherwise look like a pass.
//
// EXPECTED-FAILURE SEMANTICS
// --------------------------
// Identical to sim/tests/test_stream_assertions.cpp, and for the same measured
// reason: a failing Verilator assertion prints to stdout and calls vl_stop,
// which by default aborts the process. `Verilated::fatalOnError(false)` turns
// that into an observable event, so this test — and only this test, alongside
// its stream counterpart — can name the failure and exit 0 for a run in which
// every expected violation was detected. An unexpected clean run is the failure.
//
// The assertion text goes to stdout, so each mode runs with file descriptor 1
// redirected to a temporary file; the captured text is searched for the expected
// property name and then reprinted, so the transcript still shows exactly what
// fired. POSIX (dup/dup2) — simulation runs in WSL Ubuntu-24.04 by construction
// (PLAN.md split-toolchain rule).
// -----------------------------------------------------------------------------

#include <unistd.h>

#include <chrono>
#include <cstdio>
#include <memory>
#include <string>
#include <vector>

#include "Vcdc_violator_top.h"
#include "verilated.h"

#include "config_sim.h"
#include "harness/harness.h"

using harness::ClockScheduler;
using harness::ErrorCollector;
using harness::ResetSequencer;
using harness::RunSummary;
using harness::SimArgs;
using harness::SimTime;
using harness::StopReason;

namespace {

constexpr const char* kTestName = "test_cdc_assertions";

// Cycles per mode. Every injection happens within the first few dozen cycles;
// this is a generous ceiling that also gives the clean mode a real run.
constexpr std::uint64_t kCyclesPerMode = 400;

// The violator's pointer steps every kAdvancePeriod cycles. Slow enough that
// the pointer is visibly stationary between steps (so the clean mode exercises
// the "unchanged" arm of the one-bit rule too), fast enough that mode 1 reaches
// the 1 -> 2 binary transition well inside the run.
constexpr std::uint64_t kAdvancePeriod = 4;

constexpr SimTime kHalfPeriod = 1000;

struct ModeSpec {
  unsigned mode;
  const char* name;
  const char* description;
  // Assertion label that must appear in the captured output. Empty means no
  // assertion may fire at all.
  const char* expect_label;
  // Whether the handshake source is started in this mode. Mode 4 must not start
  // one: the defect it demonstrates is an acknowledge arriving with nothing
  // outstanding.
  bool start_handshake;
};

const std::vector<ModeSpec>& mode_specs() {
  static const std::vector<ModeSpec> specs = {
      {0, "clean", "Gray pointer and four-phase handshake, both correct", "",
       true},
      {1, "gray_is_binary", "pointer increments in binary, presented as Gray",
       "a_gray_one_bit", true},
      {2, "data_mutates", "payload changed while the request was outstanding",
       "a_hs_data_stable", true},
      {3, "req_withdrawn", "request dropped before it was acknowledged",
       "a_hs_req_held", true},
      {4, "spurious_ack", "acknowledge raised with no request outstanding",
       "a_hs_ack_after_req", false},
  };
  return specs;
}

// ---------------------------------------------------------------------------
// stdout capture. Verilator writes assertion diagnostics with printf(3) to file
// descriptor 1, so the capture has to be at the descriptor level.
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
    while ((n = std::fread(buf, 1, sizeof(buf), tmp_)) > 0) out.append(buf, n);
    std::fclose(tmp_);
    tmp_ = nullptr;
    return out;
  }

 private:
  int saved_fd_ = -1;
  std::FILE* tmp_ = nullptr;
};

std::string assertion_lines(const std::string& text, std::size_t limit) {
  std::string out;
  std::size_t start = 0;
  std::size_t shown = 0;
  while (start < text.size() && shown < limit) {
    const std::size_t end = text.find('\n', start);
    const std::string line = text.substr(
        start, end == std::string::npos ? std::string::npos : end - start);
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

struct ModeResult {
  unsigned mode = 0;
  const char* name = "";
  bool fired = false;
  bool expected_seen = false;
  std::size_t assertion_count = 0;
  std::uint64_t cycles = 0;
  std::string evidence;
  bool ok = false;
};

// Runs one violation mode in a fresh model instance, so checker state never
// carries over from a mode that deliberately corrupted it.
ModeResult run_mode(const ModeSpec& spec, bool quiet) {
  ModeResult r;
  r.mode = spec.mode;
  r.name = spec.name;

  std::unique_ptr<Vcdc_violator_top> top(new Vcdc_violator_top);

  ClockScheduler sched([&top]() { top->eval(); });

  const int clk = sched.add_clock("clk", kHalfPeriod, &top->clk, kHalfPeriod);

  ResetSequencer reset(sched);
  reset.add_domain("rst_n", clk, &top->rst_n, 8);

  top->viol_mode = static_cast<CData>(spec.mode);
  top->advance = 0;
  top->hs_start = 0;

  std::uint64_t cycle = 0;
  bool stop_now = false;
  bool stimulus_enabled = false;

  sched.on_posedge_drive(clk, [&]() {
    if (!stimulus_enabled) return;
    top->advance = ((cycle % kAdvancePeriod) == 0) ? 1 : 0;
    top->hs_start = spec.start_handshake ? 1 : 0;
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

  reset.assert_all();
  const StopReason reset_reason = reset.release_all(
      static_cast<SimTime>(kCyclesPerMode + 1000) * kHalfPeriod * 2);
  if (reset_reason == StopReason::kRunning) {
    stimulus_enabled = true;
    sched.run(static_cast<SimTime>(kCyclesPerMode + 1000) * kHalfPeriod * 2);
    stimulus_enabled = false;
  }

  const std::string text = captured ? capture.end() : std::string();

  r.cycles = cycle;
  r.fired = Verilated::gotError();
  r.assertion_count = count_assertions(text);
  r.expected_seen = (spec.expect_label[0] == '\0')
                        ? false
                        : text.find(spec.expect_label) != std::string::npos;
  r.evidence = assertion_lines(text, 3);

  if (spec.expect_label[0] == '\0') {
    r.ok = !r.fired && r.assertion_count == 0;
  } else {
    r.ok = r.fired && r.expected_seen;
  }

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

  // The one place, alongside test_stream_assertions.cpp, where an assertion
  // failure is not fatal. Everything below depends on this line.
  Verilated::fatalOnError(false);

  std::printf("  expected-fail mode: assertion failures are observed, not fatal\n");
  std::printf("  violator pointer width: %u bits, handshake payload: %u bits\n",
              sim_config::CDC_VIOLATOR_PTR_W, sim_config::CDC_HANDSHAKE_W);

  ErrorCollector errors;
  std::vector<ModeResult> results;
  results.reserve(mode_specs().size());

  for (const ModeSpec& spec : mode_specs()) {
    const ModeResult r = run_mode(spec, args.quiet);
    results.push_back(r);

    if (!args.quiet) {
      std::printf("  mode %u %-16s %-56s -> %s (%zu assertions, %llu cycles)\n",
                  spec.mode, spec.name, spec.description,
                  r.ok ? (spec.expect_label[0] == '\0'
                              ? "clean, as required"
                              : "expected failure observed")
                       : (spec.expect_label[0] == '\0' ? "UNEXPECTED FAILURE"
                                                       : "DID NOT FIRE"),
                  r.assertion_count,
                  static_cast<unsigned long long>(r.cycles));
      if (!r.evidence.empty()) std::printf("%s", r.evidence.c_str());
      std::fflush(stdout);
    }

    if (!r.ok) {
      if (spec.expect_label[0] == '\0') {
        errors.error("unexpected_assertion",
                     std::string("mode ") + spec.name +
                         " is correct but " +
                         std::to_string(r.assertion_count) +
                         " assertion(s) fired");
      } else if (!r.fired) {
        errors.error("assertion_missing",
                     std::string("mode ") + spec.name +
                         " breaks the crossing but no assertion fired; " +
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
      passed ? "every expected CDC assertion fired; the clean mode stayed clean"
             : "an expected CDC assertion did not fire, or a clean run asserted";
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
