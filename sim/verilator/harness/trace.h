// -----------------------------------------------------------------------------
// trace.h — optional FST tracing (SPEC.md 12.1 debug build, 12.2).
//
// SPEC 12.1: tracing must not exist in the fastest regression build, FST rather
// than VCD, limited hierarchy depth, "enabled only for a failing test", and it
// "reuses the exact failing random seed".
//
// Two gates enforce that:
//
//   1. Compile time — the tracing code is behind SIM_TRACE_ENABLED, which only
//      scripts/build_verilator.py's debug mode defines. The fast, lint and
//      coverage builds contain no trace calls at all, so there is no
//      "tracing is off" branch on the per-cycle path.
//   2. Run time — even in the debug build, tracing is off until +trace is
//      passed. The trace file name defaults to the run's seed
//      (sim/failures/<test>_seed<N>.fst), so the artefact is self-identifying
//      and the reproduction command is the file name.
//
// The class is a template over the Verilated model type so the harness library
// never includes a generated model header.
// -----------------------------------------------------------------------------
#ifndef HARNESS_TRACE_H_
#define HARNESS_TRACE_H_

#include <cstdint>
#include <string>

#ifdef SIM_TRACE_ENABLED
#include "verilated.h"
#include "verilated_fst_c.h"
#endif

#include "harness/sim_time.h"

namespace harness {

// Whether this binary was compiled with tracing support at all.
bool trace_compiled_in();

// Default artefact path for a run: sim/failures/<test>_seed<seed>.fst.
// sim/failures/ is where SPEC 13.3 / VERIFICATION_PLAN 7 expect reproduction
// material to live.
std::string default_trace_path(const std::string& test_name,
                               std::uint64_t seed);

// Trace depth used by the debug build. SPEC 12.1: "Limit trace depth and omit
// enormous arrays." Depth 8 reaches through benchmark_sim_top into the loopback
// stages' registers without dumping deep memory arrays once they exist.
inline constexpr int kDefaultTraceDepth = 8;

class TraceControl {
 public:
  bool active() const { return active_; }
  const std::string& path() const { return path_; }
  std::uint64_t samples() const { return samples_; }

  // Opens the trace if the binary supports it. Returns false (and explains on
  // stderr) in a non-debug build, so `+trace` on a fast binary is a loud
  // no-trace rather than a silent one.
  template <class TModel>
  bool open(TModel* model, const std::string& path,
            int depth = kDefaultTraceDepth) {
#ifdef SIM_TRACE_ENABLED
    Verilated::traceEverOn(true);
    fst_ = new VerilatedFstC;
    model->trace(fst_, depth);
    fst_->open(path.c_str());
    path_ = path;
    active_ = true;
    return true;
#else
    (void)model;
    (void)path;
    (void)depth;
    warn_not_compiled_in();
    return false;
#endif
  }

  // Registered as the scheduler step hook; one sample per time step.
  //
  // The scheduler also settles at zero time (ClockScheduler::settle(), used by
  // the reset sequencer for an immediate assertion), which would ask for a
  // second dump at an already-dumped timestamp. FST rejects that with a
  // warning, so the duplicate is dropped here rather than left to noise up
  // every debug run. The state change is still visible at the next time step.
  void dump(SimTime t) {
#ifdef SIM_TRACE_ENABLED
    if (!active_) return;
    if (samples_ != 0 && t <= last_t_) return;
    fst_->dump(static_cast<std::uint64_t>(t));
    last_t_ = t;
    ++samples_;
#else
    (void)t;
#endif
  }

  void close() {
#ifdef SIM_TRACE_ENABLED
    if (fst_ != nullptr) {
      fst_->close();
      delete fst_;
      fst_ = nullptr;
    }
#endif
    active_ = false;
  }

  ~TraceControl() { close(); }

 private:
  static void warn_not_compiled_in();

  bool active_ = false;
  std::string path_;
  std::uint64_t samples_ = 0;
  SimTime last_t_ = 0;
#ifdef SIM_TRACE_ENABLED
  VerilatedFstC* fst_ = nullptr;
#endif
};

}  // namespace harness

#endif  // HARNESS_TRACE_H_
