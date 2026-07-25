#include "harness/trace.h"

#include <cstdio>

namespace harness {

bool trace_compiled_in() {
#ifdef SIM_TRACE_ENABLED
  return true;
#else
  return false;
#endif
}

std::string default_trace_path(const std::string& test_name,
                               std::uint64_t seed) {
  return "sim/failures/" + test_name + "_seed" + std::to_string(seed) + ".fst";
}

void TraceControl::warn_not_compiled_in() {
  std::fprintf(stderr,
               "WARNING: +trace requested but this binary has no tracing "
               "support.\n"
               "         Rebuild with: scripts/build_verilator.py --mode debug "
               "and rerun with the same +seed.\n");
}

}  // namespace harness
