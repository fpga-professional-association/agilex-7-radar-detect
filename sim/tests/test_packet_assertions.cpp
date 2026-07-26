// -----------------------------------------------------------------------------
// test_packet_assertions.cpp — negative test for the SPEC 14 packet assertions
// (issue #18).
//
// The assertion set in rtl/packet/ is only worth having if it fires. This test
// drives the REAL fabric — sim/verilator/tops/packet_top.sv, the same top
// test_packet.cpp uses, with no deliberately-broken RTL anywhere — through the
// two hooks that exist for exactly this purpose, and requires each one to
// provoke the property it is aimed at:
//
//   mode 0  clean       NO assertion fires, over a full run with stalls
//   mode 1  length      a packet whose header declares four flits but whose
//                       framing ends after two. a_pkt_len_matches must fire at
//                       the ingress, and a_egr_length at the far end, so the
//                       SPEC 14 "packet length consistency" property is proved
//                       load-bearing at BOTH ends of the network.
//   mode 2  parity      one payload bit flipped in flight by the fault-injection
//                       hook. a_sw_parity must fire — inside a switch stage, at
//                       the first hop, which is the localisation claim
//                       packet_pkg section 3 makes for per-flit parity.
//
// THIS IS NOT A VIOLATOR MODULE, and that is the difference from
// test_stream_assertions and test_cdc_assertions. Those tests need a knowingly
// wrong copy of the RTL because a correct stream stage cannot be made to violate
// its own protocol from the outside. A packet fabric can: SPEC 7.8 asks for an
// error-injection hook, the design has one, and the hook is wired to the
// register plane. So the negative test injects through the PRODUCTION path,
// which means it also proves the fault-injection hook works — and there is no
// second copy of the fabric to keep in step.
//
// It is not enough that "an" assertion fires: each mode names the property it
// must provoke, and the run fails if that exact label is absent — a checker that
// fired the wrong assertion would otherwise look like a pass.
//
// EXPECTED-FAILURE SEMANTICS
// --------------------------
// A failing Verilator assertion prints
//     %Error: <file>:<line>: Assertion failed in <hier>.<label>: 'assert' failed
// and calls vl_stop, which by default routes to vl_fatal and aborts the process.
// That is the right behaviour for every other test in this repository and is
// left alone. Here — and only here — `Verilated::fatalOnError(false)` turns the
// failure into an observable event, so this test can observe it, name it, and
// exit 0 for a run in which every expected violation was detected. An unexpected
// clean run is the failure. (Measured under Verilator 5.020; DECISIONS.md
// 2026-07-26 decision 3.)
//
// The assertion text goes to stdout, so each mode runs with file descriptor 1
// redirected to a temporary file; the captured text is searched for the expected
// label and then reprinted, so the transcript still shows exactly what fired.
// POSIX (dup/dup2) — simulation runs in WSL Ubuntu-24.04 by construction
// (PLAN.md split-toolchain rule).
// -----------------------------------------------------------------------------

#include <unistd.h>

#include <chrono>
#include <cstdio>
#include <cstdint>
#include <memory>
#include <string>
#include <vector>

#include "Vpacket_top.h"
#include "verilated.h"

#include "config_sim.h"
#include "harness/error_collector.h"
#include "harness/packet_tb.h"
#include "harness/random.h"
#include "harness/run_summary.h"
#include "harness/sim_args.h"

#include "packet/packet_model.hpp"

using harness::ErrorCollector;
using harness::RunSummary;
using harness::SimArgs;
using packet_tb::Device;
using packet_tb::kNPorts;

namespace {

constexpr const char* kTestName = "test_packet_assertions";

struct ModeSpec {
  unsigned mode;
  const char* name;
  const char* description;
  // Assertion labels that must all appear in the captured output. Empty means
  // no assertion may fire at all.
  std::vector<const char*> expect_labels;
};

const std::vector<ModeSpec>& mode_specs() {
  static const std::vector<ModeSpec> specs = {
      {0, "clean", "ordinary traffic with stalls on both sides", {}},
      {1, "length",
       "header declares four flits, framing ends after two",
       {"a_pkt_len_matches", "a_egr_length"}},
      {2, "parity", "one payload bit flipped in flight", {"a_sw_parity"}},
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
    while ((n = std::fread(buf, 1, sizeof(buf), tmp_)) > 0) out.append(buf, n);
    std::fclose(tmp_);
    tmp_ = nullptr;
    return out;
  }

 private:
  int saved_fd_ = -1;
  std::FILE* tmp_ = nullptr;
};

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

// ---------------------------------------------------------------------------
// One mode. A fresh elaboration each time, because an assertion that has fired
// leaves the fabric in a state no later mode should have to reason about.
// ---------------------------------------------------------------------------
std::string run_mode(const ModeSpec& spec, std::uint64_t seed) {
  auto top = std::make_unique<Vpacket_top>();
  const harness::SeedSource seeds(seed + spec.mode);
  Device dev(top.get(), seeds.engine("packet.assert"));
  dev.reset();

  switch (spec.mode) {
    case 0: {
      dev.set_stall_probability(0.35);
      for (unsigned i = 0; i < 24; ++i) {
        const unsigned s = i % kNPorts;
        dev.enqueue(s, dev.make_packet(s, (i * 5 + 1) % kNPorts, i % 4,
                                       packet_model::kTypeCounter,
                                       1 + (i % 4)));
      }
      dev.run_until_drained(200000);
      dev.set_stall_probability(0.0);
      break;
    }
    case 1: {
      // The lie: a header that declares four flits on a packet that will be
      // framed in two.
      dev.enqueue_malformed(/*port=*/2, /*dest=*/6, /*vc=*/1,
                            /*declared_len=*/4, /*actual_beats=*/2);
      dev.run_cycles(4000);
      break;
    }
    case 2: {
      dev.enqueue(3, dev.make_packet(3, 12, 2, packet_model::kTypeRaw, 5));
      dev.arm_flip(3, /*two_bits=*/false);
      dev.run_cycles(4000);
      dev.disarm_flip(3);
      break;
    }
    default:
      break;
  }

  top->final();
  return std::string();
}

}  // namespace

int harness::sim_test_main(const SimArgs& args) {
  const auto wall_start = std::chrono::steady_clock::now();

  // The one place in the repository where an assertion failure is data rather
  // than a stop. See the header.
  Verilated::fatalOnError(false);

  ErrorCollector errors;
  std::size_t failures = 0;
  std::size_t assertions_seen = 0;

  std::printf("--- packet assertions (expected-failure suite) ---\n");

  for (const ModeSpec& spec : mode_specs()) {
    StdoutCapture cap;
    if (!cap.begin()) {
      std::printf("  FAIL [capture] could not redirect stdout for mode %u\n",
                  spec.mode);
      errors.error("capture", "stdout redirection failed");
      ++failures;
      continue;
    }
    run_mode(spec, args.seed);
    const std::string captured = cap.end();

    const std::size_t n = count_assertions(captured);
    assertions_seen += n;

    std::printf("  mode %u (%s): %s\n", spec.mode, spec.name, spec.description);
    std::printf("    assertions fired: %zu\n", n);
    if (n != 0) std::printf("%s", assertion_lines(captured, 4).c_str());

    if (spec.expect_labels.empty()) {
      if (n != 0) {
        std::printf("    FAIL: the clean mode must fire nothing\n");
        errors.error("unexpected_assertion",
                     "clean mode fired " + std::to_string(n) + " assertions");
        ++failures;
      } else {
        std::printf("    OK: clean\n");
      }
      continue;
    }

    for (const char* label : spec.expect_labels) {
      if (captured.find(label) == std::string::npos) {
        std::printf("    FAIL: %s did not fire\n", label);
        errors.error("missing_assertion",
                     std::string(label) + " did not fire in mode " +
                         std::to_string(spec.mode));
        ++failures;
      } else {
        std::printf("    OK: %s fired\n", label);
      }
    }
  }

  const bool passed = failures == 0;

  const auto wall_end = std::chrono::steady_clock::now();
  RunSummary summary;
  summary.test_name = kTestName;
  summary.config_name = sim_config::kName;
  summary.build_mode = args.build_mode;
  summary.seed = args.seed;
  summary.passed = passed;
  summary.stop_reason = passed ? "pass" : "error";
  summary.stop_detail =
      passed ? "every expected packet assertion fired and the clean mode stayed clean"
             : "an expected packet assertion did not fire";
  summary.passes = mode_specs().size();
  summary.beats_observed = assertions_seen;
  summary.absorb(errors);
  summary.wall_time_s =
      std::chrono::duration<double>(wall_end - wall_start).count();
  const std::string written = summary.write(args.results_dir);
  if (!written.empty()) std::printf("  summary json     : %s\n", written.c_str());

  if (passed) {
    std::printf(
        "RESULT: PASS seed=%llu test=%s config=%s assertions_observed=%zu\n",
        static_cast<unsigned long long>(args.seed), kTestName,
        sim_config::kName, assertions_seen);
    return 0;
  }
  std::printf("RESULT: FAIL seed=%llu test=%s config=%s failures=%zu\n",
              static_cast<unsigned long long>(args.seed), kTestName,
              sim_config::kName, failures);
  return 1;
}
