// -----------------------------------------------------------------------------
// sim_args.h — runtime arguments shared by every simulation binary.
//
// Arguments arrive as Verilator-style plusargs so that the same command line
// works whether the binary is run directly or through a Verilator wrapper, and
// so nothing collides with Verilator's own +verilator+ options.
//
//   +seed=<n>          master random seed        (default: $SIM_SEED, else 1)
//   +test=<name>       test name for artefacts   (default: test-supplied)
//   +trace             arm FST tracing           (debug build only, off by default)
//   +trace_file=<path> override the trace path
//   +timeout=<cycles>  hard cycle timeout        (0 = test default)
//   +frames=<n>        frames per randomized pass (0 = test default)
//   +results=<dir>     run-summary directory     (default: results/simulation)
//   +quiet             suppress per-pass progress lines
//
// SPEC 12.2 requires deterministic seeds and SPEC 13.3 requires every failing
// seed to be replayable, so the resolved seed is printed on every run, pass or
// fail, before any stimulus is generated.
// -----------------------------------------------------------------------------
#ifndef HARNESS_SIM_ARGS_H_
#define HARNESS_SIM_ARGS_H_

#include <cstdint>
#include <string>
#include <vector>

namespace harness {

struct SimArgs {
  std::uint64_t seed = 1;
  std::string test_name;
  bool trace = false;
  std::string trace_file;
  std::uint64_t timeout_cycles = 0;
  std::uint64_t frames = 0;
  std::string results_dir = "results/simulation";
  bool quiet = false;

  // Build identity, baked in by scripts/build_verilator.py through -D.
  std::string config_name;
  std::string build_mode;

  std::vector<std::string> raw;

  // Returns the value of an arbitrary +key=value plusarg, or `fallback`.
  std::string plusarg(const std::string& key,
                      const std::string& fallback = {}) const;
  bool has_flag(const std::string& key) const;
};

// Parses argv. Unknown plusargs are retained in `raw` for the test to read.
SimArgs parse_args(int argc, char** argv);

// The entry point every test provides. sim_main.cpp owns main(), parses
// arguments, prints the seed banner, and calls this.
int sim_test_main(const SimArgs& args);

}  // namespace harness

#endif  // HARNESS_SIM_ARGS_H_
