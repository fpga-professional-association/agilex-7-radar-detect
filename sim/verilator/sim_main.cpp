// -----------------------------------------------------------------------------
// sim_main.cpp — entry point for every Verilator simulation binary.
//
// Owns main() so that argument parsing, the seed banner and the Verilator
// context setup exist once rather than once per test. A test provides
// harness::sim_test_main(); it never writes its own main().
//
// SPEC 12.2 ("deterministic random seeds") and SPEC 13.3 ("every failing seed is
// recorded and replayable") are served by printing the resolved seed and the
// exact replay command line before any stimulus exists, on every run — a run
// that dies unexpectedly still tells you how to reproduce it.
// -----------------------------------------------------------------------------
#include <cstdio>
#include <cstdlib>
#include <filesystem>
#include <string>

#include "verilated.h"

// VM_COVERAGE is defined on the compile line by the coverage build only.
#if VM_COVERAGE
#include "verilated_cov.h"
#endif

// SIM_CONFIG_NAME comes from the generated configuration header; the build mode
// arrives as a valueless -D from scripts/build_verilator.py (a valueless macro
// survives Verilator's -CFLAGS quoting, a string-valued one does not).
#include "config_sim.h"

#include "harness/sim_args.h"
#include "harness/trace.h"

#if defined(SIM_BUILD_MODE_FAST)
#define SIM_BUILD_MODE "fast"
#elif defined(SIM_BUILD_MODE_DEBUG)
#define SIM_BUILD_MODE "debug"
#elif defined(SIM_BUILD_MODE_COVERAGE)
#define SIM_BUILD_MODE "coverage"
#elif defined(SIM_BUILD_MODE_LINT)
#define SIM_BUILD_MODE "lint"
#else
#define SIM_BUILD_MODE "unknown"
#endif

namespace harness {
namespace {

bool starts_with(const std::string& s, const std::string& p) {
  return s.size() >= p.size() && s.compare(0, p.size(), p) == 0;
}

bool parse_u64(const std::string& s, std::uint64_t* out) {
  if (s.empty()) return false;
  char* end = nullptr;
  const unsigned long long v = std::strtoull(s.c_str(), &end, 0);
  if (end == s.c_str() || *end != '\0') return false;
  *out = static_cast<std::uint64_t>(v);
  return true;
}

}  // namespace

std::string SimArgs::plusarg(const std::string& key,
                             const std::string& fallback) const {
  const std::string prefix = "+" + key + "=";
  for (const std::string& a : raw) {
    if (starts_with(a, prefix)) return a.substr(prefix.size());
  }
  return fallback;
}

bool SimArgs::has_flag(const std::string& key) const {
  const std::string flag = "+" + key;
  for (const std::string& a : raw) {
    if (a == flag) return true;
  }
  return false;
}

SimArgs parse_args(int argc, char** argv) {
  SimArgs args;
  args.config_name = SIM_CONFIG_NAME;
  args.build_mode = SIM_BUILD_MODE;

  for (int i = 1; i < argc; ++i) args.raw.emplace_back(argv[i]);

  // Seed precedence: +seed= beats $SIM_SEED beats the default of 1. The
  // environment variable exists so a whole regression sweep can be reseeded
  // without rewriting every command line.
  bool seed_set = false;
  if (const char* env = std::getenv("SIM_SEED")) {
    std::uint64_t v = 0;
    if (parse_u64(env, &v)) {
      args.seed = v;
      seed_set = true;
    } else {
      std::fprintf(stderr, "WARNING: ignoring non-numeric SIM_SEED=%s\n", env);
    }
  }
  const std::string seed_arg = args.plusarg("seed");
  if (!seed_arg.empty()) {
    std::uint64_t v = 0;
    if (parse_u64(seed_arg, &v)) {
      args.seed = v;
      seed_set = true;
    } else {
      std::fprintf(stderr, "ERROR: cannot parse +seed=%s\n", seed_arg.c_str());
      std::exit(2);
    }
  }
  (void)seed_set;

  args.test_name = args.plusarg("test", args.test_name);
  args.results_dir = args.plusarg("results", args.results_dir);
  args.trace = args.has_flag("trace");
  args.trace_file = args.plusarg("trace_file");
  args.quiet = args.has_flag("quiet");

  const std::string timeout_arg = args.plusarg("timeout");
  if (!timeout_arg.empty() && !parse_u64(timeout_arg, &args.timeout_cycles)) {
    std::fprintf(stderr, "ERROR: cannot parse +timeout=%s\n",
                 timeout_arg.c_str());
    std::exit(2);
  }
  const std::string frames_arg = args.plusarg("frames");
  if (!frames_arg.empty() && !parse_u64(frames_arg, &args.frames)) {
    std::fprintf(stderr, "ERROR: cannot parse +frames=%s\n", frames_arg.c_str());
    std::exit(2);
  }
  return args;
}

}  // namespace harness

int main(int argc, char** argv) {
  Verilated::commandArgs(argc, argv);

  const harness::SimArgs args = harness::parse_args(argc, argv);

  // Seed banner: printed before any stimulus, on every run.
  std::printf("=== simulation run ===\n");
  std::printf("  build_mode : %s\n", args.build_mode.c_str());
  std::printf("  config     : %s\n", args.config_name.c_str());
  std::printf("  seed       : %llu\n",
              static_cast<unsigned long long>(args.seed));
  std::printf("  tracing    : %s\n",
              harness::trace_compiled_in()
                  ? (args.trace ? "armed (+trace)" : "compiled in, disarmed")
                  : "not compiled in");
  std::printf("  replay     : %s +seed=%llu\n", argv[0],
              static_cast<unsigned long long>(args.seed));
  std::fflush(stdout);

  const int rc = harness::sim_test_main(args);

#if VM_COVERAGE
  // Coverage data is per-run; the merge across a randomized regression is the
  // regression runner's job (issue #17), so each run writes its own seeded file
  // rather than clobbering one shared coverage.dat.
  {
    const std::string cov_path = args.plusarg(
        "coverage",
        args.results_dir + "/coverage_seed" + std::to_string(args.seed) + ".dat");
    std::error_code ec;
    std::filesystem::create_directories(
        std::filesystem::path(cov_path).parent_path(), ec);
    Verilated::threadContextp()->coveragep()->write(cov_path.c_str());
    std::printf("  coverage       : %s\n", cov_path.c_str());
  }
#endif

  std::fflush(stdout);
  return rc;
}
