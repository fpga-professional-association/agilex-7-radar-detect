// -----------------------------------------------------------------------------
// clock_scheduler.h — integer-time multi-clock event scheduler (SPEC.md 12.3).
//
// SPEC 12.3, verbatim requirements:
//   1. Tracks the next edge time of every clock.
//   2. Advances to the earliest scheduled edge.
//   3. Toggles all clocks with an edge at that time.
//   4. Calls eval().
//   5. Performs driver and monitor work on appropriate edges.
//   6. Stops on pass, failure, or timeout.
//
// No SystemVerilog delay-based clock generation is used anywhere; the clock
// nets are plain model inputs written by this class.
//
// Edge phases
// -----------
// Requirement 5 is split into two phases per edge, because a single post-eval
// callback cannot both sample and drive correctly:
//
//   Phase::kSample  runs at the edge time *before* the clock toggles and before
//                   eval(). It therefore observes exactly the values the model's
//                   flip-flops are about to capture — the C++ equivalent of a
//                   Verilog testbench sampling in the non-blocking region. This
//                   is where handshake completion (valid && ready) is detected.
//
//   Phase::kDrive   runs *after* the toggle and eval(). New stimulus applied
//                   here is stable for the remainder of the cycle and is
//                   captured at the following edge. A second eval() is issued
//                   after the drive phase so combinational outputs settle.
//
// Sampling after eval() instead would read post-edge values — i.e. the *next*
// cycle's `ready` — and silently corrupt every handshake decision. The split is
// the reason this harness needs no per-DUT delta-cycle tuning.
//
// Determinism: callbacks fire in registration order within a (clock, edge,
// phase) triple, and clocks due at the same time are processed in the order
// they were added. Nothing depends on floating point or on hash iteration.
// -----------------------------------------------------------------------------
#ifndef HARNESS_CLOCK_SCHEDULER_H_
#define HARNESS_CLOCK_SCHEDULER_H_

#include <cstdint>
#include <functional>
#include <string>
#include <vector>

#include "harness/sim_time.h"

namespace harness {

enum class Edge : std::uint8_t { kPos, kNeg };
enum class Phase : std::uint8_t { kSample, kDrive };

// Why the scheduler returned from run().
enum class StopReason : std::uint8_t {
  kRunning,       // not stopped (never returned by run())
  kPass,          // a participant called stop_pass()
  kFail,          // a participant called stop_fail()
  kTimeout,       // wall of simulated time reached
};

const char* to_string(StopReason r);

class ClockScheduler {
 public:
  using Callback = std::function<void()>;
  using EvalFn = std::function<void()>;
  // Called once per time step, after the final eval() of that step, with the
  // current simulation time. Used by the trace writer.
  using StepHook = std::function<void(SimTime)>;

  explicit ClockScheduler(EvalFn eval);

  // Registers a clock net. `signal` points at the model's clock input, which
  // this class owns from now on. The clock starts at 0 and takes its first
  // edge (0 -> 1) at `first_edge_ps`. Returns the clock's handle.
  int add_clock(std::string name, SimTime half_period_ps, std::uint8_t* signal,
                SimTime first_edge_ps = 0);

  int clock_count() const { return static_cast<int>(clocks_.size()); }
  const std::string& clock_name(int clk) const { return clocks_.at(clk).name; }
  SimTime half_period(int clk) const { return clocks_.at(clk).half_period; }
  // Completed positive edges on `clk`, i.e. elapsed cycles.
  std::uint64_t cycles(int clk) const { return clocks_.at(clk).posedges; }

  void on(int clk, Edge edge, Phase phase, Callback cb);
  // Conveniences for the two overwhelmingly common registrations.
  void on_posedge_sample(int clk, Callback cb) {
    on(clk, Edge::kPos, Phase::kSample, std::move(cb));
  }
  void on_posedge_drive(int clk, Callback cb) {
    on(clk, Edge::kPos, Phase::kDrive, std::move(cb));
  }

  void set_step_hook(StepHook hook) { step_hook_ = std::move(hook); }

  // Requirement 6. Any of these ends the current time step and returns from
  // run(); the first call wins, so a failure reported before a pass is not
  // overwritten.
  void stop_pass(std::string detail = {});
  void stop_fail(std::string detail);
  void stop_timeout(std::string detail);

  // Runs until stopped or until simulation time would exceed `time_limit_ps`
  // (which then reports kTimeout). Returns the stop reason.
  StopReason run(SimTime time_limit_ps);

  // Advances at most `cycles` positive edges of `clk`, or until stopped.
  StopReason run_cycles(int clk, std::uint64_t cycles, SimTime time_limit_ps);

  SimTime time() const { return time_; }
  // Live pointer to the current time, for ErrorCollector::set_time_probe().
  const SimTime* time_ptr() const { return &time_; }
  StopReason stop_reason() const { return stop_reason_; }
  const std::string& stop_detail() const { return stop_detail_; }
  // Clears a kPass/kFail/kTimeout so the scheduler can be re-run (used between
  // test passes). Does not rewind time.
  void clear_stop();

  // Issues one eval() plus a step hook without advancing time. Used by the
  // reset sequencer to make an asynchronous reset assertion visible.
  void settle();

 private:
  struct Clock {
    std::string name;
    SimTime half_period = 0;
    SimTime next_edge = 0;
    std::uint8_t* signal = nullptr;
    std::uint64_t posedges = 0;
    // [edge][phase] -> callbacks, edge 0 = pos, phase 0 = sample.
    std::vector<Callback> cb[2][2];
  };

  static std::size_t edge_idx(Edge e) { return e == Edge::kPos ? 0u : 1u; }
  static std::size_t phase_idx(Phase p) { return p == Phase::kSample ? 0u : 1u; }

  void run_callbacks(Clock& c, Edge e, Phase p);
  SimTime next_edge_time() const;
  void step();

  EvalFn eval_;
  StepHook step_hook_;
  std::vector<Clock> clocks_;
  std::vector<int> due_;  // scratch, reused every step to avoid allocation
  SimTime time_ = 0;
  StopReason stop_reason_ = StopReason::kRunning;
  std::string stop_detail_;
};

}  // namespace harness

#endif  // HARNESS_CLOCK_SCHEDULER_H_
