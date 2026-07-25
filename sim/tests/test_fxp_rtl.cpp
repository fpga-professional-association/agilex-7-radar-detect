// -----------------------------------------------------------------------------
// test_fxp_rtl.cpp — RTL/C++/NumPy numerics equivalence (SPEC.md 6, 12.4).
//
// SPEC 6: "The C++ reference model and RTL must use identical numerical rules."
// SPEC 12.4: the C++ model must be validated against Python/NumPy vectors before
// it is used as the RTL oracle.
//
// This test closes the triangle. Every vector in model/vectors/ is driven
// through `fxp_probe_top` (which is nothing but calls into
// rtl/packages/fxp_pkg.sv) and the result is compared against BOTH:
//
//   * the expected value written by the independent NumPy model, and
//   * the value model/cpp/fxp computes for the same inputs.
//
// Three-way agreement is the point. RTL == C++ alone would be satisfied by two
// implementations sharing a mistake; RTL == NumPy alone would leave the C++
// oracle unproven. Both comparisons are checked and reported separately, so a
// failure says which pair disagrees.
//
// Coverage of the accumulator half additionally exercises
// rtl/common/fxp_sticky_flags.sv: value, per-step flags, sticky flags and the
// saturating event counter are all compared at every step, not only at the end
// of a sequence.
//
// Built by `make numerics-check` (which `make sim-tiny` depends on) as:
//   scripts/build_verilator.py --mode fast --top fxp_probe_top
//       --files sim/verilator/files_fxp.f --test test_fxp_rtl
//
// Style follows sim/tests/test_stream_loopback.cpp: no main() (sim_main.cpp owns
// it), harness ErrorCollector for categorised failures, a deterministic
// RunSummary, and a RESULT: line. There is no stream protocol and no second
// clock here, so the SPEC 12.3 scheduler would add ceremony without adding
// coverage; the accumulator is clocked by an explicit two-eval tick.
// -----------------------------------------------------------------------------

#include <chrono>
#include <cstdio>
#include <cstdint>
#include <memory>
#include <string>
#include <vector>

#include "Vfxp_probe_top.h"
#include "verilated.h"

#include "config_sim.h"
#include "harness/error_collector.h"
#include "harness/run_summary.h"
#include "harness/sim_args.h"

#include "fxp/fxp.hpp"
#include "fxp/fxp_ops.hpp"
#include "fxp/fxp_vectors.hpp"

using harness::ErrorCollector;
using harness::RunSummary;
using harness::SimArgs;

namespace {

constexpr const char* kTestName = "test_fxp_rtl";

std::string hex64(fxp::wide_t v) {
  char buf[32];
  std::snprintf(buf, sizeof(buf), "0x%016llx",
                static_cast<unsigned long long>(fxp::bits_of(v)));
  return buf;
}

std::string flags_str(unsigned packed) {
  const fxp::Flags f = fxp::Flags::from_packed(packed);
  return std::string(f.sat_pos ? "+" : ".") + (f.sat_neg ? "-" : ".");
}

// Counts mismatches per relation so the run reports "12 rtl_vs_vector, 0
// rtl_vs_cpp" rather than 12 identical-looking lines. Which relation fails is
// the whole diagnosis (NUMERICS.md 10, "triage procedure").
struct Counters {
  std::size_t rtl_vs_vector = 0;
  std::size_t rtl_vs_cpp = 0;
  std::size_t cpp_vs_vector = 0;
};

// Every mismatch is recorded; the ErrorCollector's own print limit decides how
// many reach the log, and the per-relation totals above stay exact.
void report(ErrorCollector* errors, const char* category, std::size_t* counter,
            const std::string& message) {
  ++*counter;
  errors->error(category, message);
}

// One clock cycle: low eval, high eval. The probe's only sequential element is
// the accumulator, so this is the whole clocking requirement.
void tick(Vfxp_probe_top* top) {
  top->clk = 0;
  top->eval();
  top->clk = 1;
  top->eval();
}

// ---------------------------------------------------------------------------
// Combinational op vectors
// ---------------------------------------------------------------------------

void run_op_vectors(Vfxp_probe_top* top,
                    const std::vector<fxp::vectors::OpVector>& vecs,
                    ErrorCollector* errors, Counters* c) {
  for (const fxp::vectors::OpVector& v : vecs) {
    top->op = static_cast<std::uint8_t>(v.code);
    top->a = fxp::bits_of(v.a);
    top->b = fxp::bits_of(v.b);
    top->sh = static_cast<std::uint8_t>(v.sh);
    top->w = static_cast<std::uint8_t>(v.w);
    top->eval();

    const fxp::wide_t rtl_y = fxp::from_bits(top->y);
    const unsigned rtl_flags = static_cast<unsigned>(top->flags);
    const unsigned rtl_ovf = static_cast<unsigned>(top->ovf);

    const fxp::ops::Result cpp = fxp::ops::apply(v.code, v.a, v.b, v.sh, v.w);

    const std::string where =
        std::string(v.id) + " (" + v.op + " a=" + std::to_string(v.a) +
        " b=" + std::to_string(v.b) + " sh=" + std::to_string(v.sh) +
        " w=" + std::to_string(v.w) + ")";

    if (rtl_y != v.y || rtl_flags != v.flags) {
      report(errors, "rtl_vs_vector", &c->rtl_vs_vector,
             where + ": vector expects y=" + std::to_string(v.y) + " " +
                 hex64(v.y) + " flags=" + flags_str(v.flags) + ", RTL gives y=" +
                 std::to_string(rtl_y) + " " + hex64(rtl_y) + " flags=" +
                 flags_str(rtl_flags));
    }
    if (rtl_y != cpp.y || rtl_flags != cpp.flags.packed()) {
      report(errors, "rtl_vs_cpp", &c->rtl_vs_cpp,
             where + ": C++ gives y=" + std::to_string(cpp.y) + " flags=" +
                 flags_str(cpp.flags.packed()) + ", RTL gives y=" +
                 std::to_string(rtl_y) + " flags=" + flags_str(rtl_flags));
    }
    if (cpp.y != v.y || cpp.flags.packed() != v.flags) {
      report(errors, "cpp_vs_vector", &c->cpp_vs_vector,
             where + ": vector expects y=" + std::to_string(v.y) +
                 " flags=" + flags_str(v.flags) + ", C++ gives y=" +
                 std::to_string(cpp.y) + " flags=" +
                 flags_str(cpp.flags.packed()));
    }
    // ovf must be exactly the OR of the two flag bits, on every vector.
    if (rtl_ovf != (rtl_flags != 0 ? 1u : 0u)) {
      report(errors, "rtl_vs_cpp", &c->rtl_vs_cpp,
             where + ": ovf=" + std::to_string(rtl_ovf) +
                 " does not match flags=" + flags_str(rtl_flags));
    }
  }
}

// ---------------------------------------------------------------------------
// Clocked accumulator sequences
// ---------------------------------------------------------------------------

std::size_t run_accum_vectors(Vfxp_probe_top* top,
                              const std::vector<fxp::vectors::AccumStep>& steps,
                              ErrorCollector* errors, Counters* c) {
  std::size_t sequences = 0;
  fxp::Acc acc(fxp::kProdW);
  std::string current;

  for (const fxp::vectors::AccumStep& s : steps) {
    if (s.step == 0) {
      // New sequence: one clear cycle, then the C++ twin is rebuilt at the
      // same width. Both sides start from a proven-zero state.
      top->acc_clear = 1;
      top->acc_en = 0;
      top->acc_width = static_cast<std::uint8_t>(s.acc_w);
      top->acc_x = 0;
      tick(top);
      top->acc_clear = 0;
      acc = fxp::Acc(s.acc_w);
      current = s.id;
      ++sequences;

      if (fxp::from_bits(top->acc_y) != 0 ||
          static_cast<unsigned>(top->acc_flags_sticky) != 0 ||
          top->acc_event_count != 0) {
        report(errors, "rtl_vs_vector", &c->rtl_vs_vector,
               s.id + ": accumulator not clean after clear (y=" +
                   std::to_string(fxp::from_bits(top->acc_y)) + " sticky=" +
                   flags_str(static_cast<unsigned>(top->acc_flags_sticky)) +
                   " count=" + std::to_string(top->acc_event_count) + ")");
      }
    }

    top->acc_en = 1;
    top->acc_width = static_cast<std::uint8_t>(s.acc_w);
    top->acc_x = fxp::bits_of(s.x);
    top->eval();  // settle the combinational step flags before the edge

    const unsigned rtl_step_flags =
        static_cast<unsigned>(top->acc_flags_now);

    tick(top);
    top->acc_en = 0;

    acc.add(s.x);

    const fxp::wide_t rtl_y = fxp::from_bits(top->acc_y);
    const unsigned rtl_sticky = static_cast<unsigned>(top->acc_flags_sticky);
    const std::uint32_t rtl_count =
        static_cast<std::uint32_t>(top->acc_event_count);
    const unsigned rtl_any = static_cast<unsigned>(top->acc_any_sticky);

    const std::string where = s.id + " step " + std::to_string(s.step) +
                              " (w=" + std::to_string(s.acc_w) +
                              " x=" + std::to_string(s.x) + ")";

    if (rtl_y != s.y || rtl_step_flags != s.step_flags ||
        rtl_sticky != s.sticky_flags || rtl_count != s.count) {
      report(errors, "rtl_vs_vector", &c->rtl_vs_vector,
             where + ": vector expects y=" + std::to_string(s.y) + " step=" +
                 flags_str(s.step_flags) + " sticky=" +
                 flags_str(s.sticky_flags) + " count=" +
                 std::to_string(s.count) + ", RTL gives y=" +
                 std::to_string(rtl_y) + " step=" + flags_str(rtl_step_flags) +
                 " sticky=" + flags_str(rtl_sticky) + " count=" +
                 std::to_string(rtl_count));
    }
    if (rtl_y != acc.value() ||
        rtl_sticky != acc.flags().sticky().packed() ||
        rtl_count != acc.flags().event_count()) {
      report(errors, "rtl_vs_cpp", &c->rtl_vs_cpp,
             where + ": C++ gives y=" + std::to_string(acc.value()) +
                 " sticky=" + flags_str(acc.flags().sticky().packed()) +
                 " count=" + std::to_string(acc.flags().event_count()) +
                 ", RTL gives y=" + std::to_string(rtl_y) + " sticky=" +
                 flags_str(rtl_sticky) + " count=" + std::to_string(rtl_count));
    }
    if (acc.value() != s.y || acc.flags().sticky().packed() != s.sticky_flags ||
        acc.flags().event_count() != s.count) {
      report(errors, "cpp_vs_vector", &c->cpp_vs_vector,
             where + ": C++ disagrees with the vector");
    }
    if (rtl_any != (rtl_sticky != 0 ? 1u : 0u)) {
      report(errors, "rtl_vs_cpp", &c->rtl_vs_cpp,
             where + ": any_sticky does not match the sticky flags");
    }
  }
  return sequences;
}

}  // namespace

// ---------------------------------------------------------------------------
// Test entry point (main() lives in sim/verilator/sim_main.cpp).
// ---------------------------------------------------------------------------
int harness::sim_test_main(const SimArgs& args) {
  const auto wall_start = std::chrono::steady_clock::now();

  const std::string dir = args.plusarg("vectors", "model/vectors");
  const std::string ops_path = dir + "/fxp_ops.vec";
  const std::string acc_path = dir + "/fxp_accum.vec";

  ErrorCollector errors;
  Counters counters;

  std::vector<fxp::vectors::OpVector> ops;
  std::vector<fxp::vectors::AccumStep> accum;
  fxp::vectors::Header ops_hdr;
  fxp::vectors::Header acc_hdr;
  std::string err;

  if (!fxp::vectors::load_ops(ops_path, &ops, &ops_hdr, &err) ||
      !fxp::vectors::load_accum(acc_path, &accum, &acc_hdr, &err)) {
    std::fprintf(stderr, "ERROR: %s\n", err.c_str());
    std::printf(
        "RESULT: FAIL seed=%llu test=%s reason=vector_load: %s\n",
        static_cast<unsigned long long>(args.seed), kTestName, err.c_str());
    return 2;
  }

  // A vector set generated under the other rounding mode must never be silently
  // accepted: it would "pass" against whichever implementation matched it.
  const std::string want = fxp::vectors::expected_rounding_mode();
  if (ops_hdr.rounding_mode != want || acc_hdr.rounding_mode != want) {
    std::printf(
        "RESULT: FAIL seed=%llu test=%s reason=rounding_mode_mismatch "
        "(vectors=%s/%s, build=%s)\n",
        static_cast<unsigned long long>(args.seed), kTestName,
        ops_hdr.rounding_mode.c_str(), acc_hdr.rounding_mode.c_str(),
        want.c_str());
    return 2;
  }

  std::unique_ptr<Vfxp_probe_top> top(new Vfxp_probe_top);

  // Reset the sequential half. The combinational op port needs no reset.
  top->clk = 0;
  top->rst_n = 0;
  top->op = 0;
  top->a = 0;
  top->b = 0;
  top->sh = 0;
  top->w = 16;
  top->acc_clear = 0;
  top->acc_en = 0;
  top->acc_width = 32;
  top->acc_x = 0;
  for (int i = 0; i < 4; ++i) tick(top.get());
  top->rst_n = 1;
  tick(top.get());

  run_op_vectors(top.get(), ops, &errors, &counters);
  const std::size_t sequences =
      run_accum_vectors(top.get(), accum, &errors, &counters);

  const bool passed = counters.rtl_vs_vector == 0 && counters.rtl_vs_cpp == 0 &&
                      counters.cpp_vs_vector == 0;

  std::printf("--- numerics cross-check ---\n");
  std::printf("  vectors        : %s\n", dir.c_str());
  std::printf("  generator seed : %llu (rounding_mode=%s)\n",
              static_cast<unsigned long long>(ops_hdr.seed),
              ops_hdr.rounding_mode.c_str());
  std::printf("  op vectors     : %zu\n", ops.size());
  std::printf("  accum steps    : %zu in %zu sequences\n", accum.size(),
              sequences);
  std::printf("  RTL vs vectors : %zu mismatches\n", counters.rtl_vs_vector);
  std::printf("  RTL vs C++     : %zu mismatches\n", counters.rtl_vs_cpp);
  std::printf("  C++ vs vectors : %zu mismatches\n", counters.cpp_vs_vector);

  const auto wall_end = std::chrono::steady_clock::now();
  RunSummary summary;
  summary.test_name = kTestName;
  summary.config_name = sim_config::kName;
  summary.build_mode = args.build_mode;
  summary.seed = args.seed;
  summary.passed = passed;
  summary.stop_reason = passed ? "pass" : "error";
  summary.stop_detail =
      passed ? "all vectors bit-exact across RTL, C++ and NumPy"
             : "numerics mismatch; see errors_by_category";
  summary.passes = 2;  // op vectors, accumulator sequences
  summary.beats_driven = ops.size() + accum.size();
  summary.beats_observed = ops.size() + accum.size();
  summary.frames_driven = sequences;
  summary.frames_observed = sequences;
  summary.absorb(errors);
  summary.wall_time_s =
      std::chrono::duration<double>(wall_end - wall_start).count();
  const std::string written = summary.write(args.results_dir);
  if (!written.empty()) std::printf("  summary json   : %s\n", written.c_str());

  top->final();

  if (passed) {
    std::printf("RESULT: PASS seed=%llu test=%s config=%s vectors=%zu\n",
                static_cast<unsigned long long>(args.seed), kTestName,
                sim_config::kName, ops.size() + accum.size());
    return 0;
  }
  std::printf(
      "RESULT: FAIL seed=%llu test=%s config=%s rtl_vs_vector=%zu "
      "rtl_vs_cpp=%zu cpp_vs_vector=%zu\n",
      static_cast<unsigned long long>(args.seed), kTestName, sim_config::kName,
      counters.rtl_vs_vector, counters.rtl_vs_cpp, counters.cpp_vs_vector);
  return 1;
}
