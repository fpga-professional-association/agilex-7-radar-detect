// -----------------------------------------------------------------------------
// timeout.h — timeout detection (SPEC.md 12.2, 12.3 step 6).
//
// Two independent limits, because a stuck simulation and a slow simulation fail
// differently:
//
//   * hard limit    — total cycles of the reference clock. Catches a run that
//                     makes progress but will never finish.
//   * stall limit   — cycles since the progress probe last changed. Catches a
//                     deadlocked handshake immediately instead of after the
//                     hard limit, which matters when the hard limit is large.
//
// A timeout is a scheduler stop (StopReason::kTimeout) plus an error entry, so
// it is reported through the same path as any other failure and lands in the
// JSON run summary with the seed needed to replay it.
//
// Header-only: it is a few dozen lines and every test instantiates it.
// -----------------------------------------------------------------------------
#ifndef HARNESS_TIMEOUT_H_
#define HARNESS_TIMEOUT_H_

#include <cstdint>
#include <functional>
#include <string>
#include <utility>

#include "harness/clock_scheduler.h"
#include "harness/error_collector.h"

namespace harness {

class TimeoutGuard {
 public:
  // `progress` returns any monotonically non-decreasing measure of forward
  // progress (beats received, transactions retired, ...). 0 for either limit
  // disables that limit.
  TimeoutGuard(ClockScheduler& sched, ErrorCollector& errors,
               std::uint64_t max_cycles, std::uint64_t max_stall_cycles,
               std::function<std::uint64_t()> progress)
      : sched_(sched),
        errors_(errors),
        max_cycles_(max_cycles),
        max_stall_cycles_(max_stall_cycles),
        progress_(std::move(progress)) {}

  // Register with sched.on_posedge_drive(clk, ...) on the reference clock.
  void on_cycle() {
    ++cycles_;
    const std::uint64_t p = progress_ ? progress_() : 0;
    if (p != last_progress_) {
      last_progress_ = p;
      stalled_ = 0;
    } else {
      ++stalled_;
    }

    if (max_cycles_ != 0 && cycles_ > max_cycles_) {
      fire("hard timeout: " + std::to_string(cycles_) +
           " cycles exceeds limit " + std::to_string(max_cycles_));
      return;
    }
    if (max_stall_cycles_ != 0 && stalled_ > max_stall_cycles_) {
      fire("stall timeout: no progress for " + std::to_string(stalled_) +
           " cycles (limit " + std::to_string(max_stall_cycles_) +
           "), progress counter stuck at " + std::to_string(last_progress_));
    }
  }

  void reset() {
    cycles_ = 0;
    stalled_ = 0;
    fired_ = false;
    last_progress_ = progress_ ? progress_() : 0;
  }

  bool fired() const { return fired_; }
  std::uint64_t cycles() const { return cycles_; }
  const std::string& reason() const { return reason_; }

 private:
  void fire(std::string why) {
    if (fired_) return;
    fired_ = true;
    reason_ = std::move(why);
    errors_.error("timeout", reason_);
    sched_.stop_timeout(reason_);
  }

  ClockScheduler& sched_;
  ErrorCollector& errors_;
  std::uint64_t max_cycles_;
  std::uint64_t max_stall_cycles_;
  std::function<std::uint64_t()> progress_;
  std::uint64_t cycles_ = 0;
  std::uint64_t stalled_ = 0;
  std::uint64_t last_progress_ = 0;
  bool fired_ = false;
  std::string reason_;
};

}  // namespace harness

#endif  // HARNESS_TIMEOUT_H_
