#include "harness/reset_sequencer.h"

#include <algorithm>
#include <utility>

namespace harness {

void ResetSequencer::add_domain(std::string name, int clk, std::uint8_t* rst_n,
                                std::uint64_t release_after_cycles) {
  Domain d;
  d.name = std::move(name);
  d.clk = clk;
  d.rst_n = rst_n;
  d.release_after = release_after_cycles;
  const std::size_t idx = domains_.size();
  domains_.push_back(d);

  // The release check runs in kDrive so the deasserted level is stable for the
  // whole cycle preceding the next capturing edge.
  sched_.on_posedge_drive(clk, [this, idx]() {
    Domain& dom = domains_[idx];
    if (dom.released) return;
    if (sched_.cycles(dom.clk) - dom.assert_cycle >= dom.release_after) {
      *dom.rst_n = 1;
      dom.released = true;
    }
  });
}

void ResetSequencer::assert_all() {
  for (Domain& d : domains_) {
    *d.rst_n = 0;
    d.released = false;
    d.assert_cycle = sched_.cycles(d.clk);
  }
  release_hooks_fired_ = false;
  for (auto& fn : on_assert_) fn();
  // Asynchronous assert: make it visible to the model without advancing time.
  sched_.settle();
}

bool ResetSequencer::all_released() const {
  return std::all_of(domains_.begin(), domains_.end(),
                     [](const Domain& d) { return d.released; });
}

StopReason ResetSequencer::release_all(SimTime time_limit_ps,
                                       std::uint64_t settle_cycles) {
  if (domains_.empty()) return sched_.stop_reason();

  // Advance until every domain has deasserted. The bound is generous: the
  // slowest domain needs release_after cycles of its own clock, and the
  // scheduler's own time limit catches a genuinely stuck run.
  while (sched_.stop_reason() == StopReason::kRunning && !all_released()) {
    if (sched_.run_cycles(domains_.front().clk, 1, time_limit_ps) !=
        StopReason::kRunning) {
      break;
    }
  }

  if (all_released() && !release_hooks_fired_) {
    release_hooks_fired_ = true;
    for (auto& fn : on_release_) fn();
  }

  // Settle on the slowest registered domain so every domain sees at least a
  // few post-release cycles before stimulus starts.
  if (sched_.stop_reason() == StopReason::kRunning && settle_cycles > 0) {
    int slowest = domains_.front().clk;
    for (const Domain& d : domains_) {
      if (sched_.half_period(d.clk) > sched_.half_period(slowest)) {
        slowest = d.clk;
      }
    }
    sched_.run_cycles(slowest, settle_cycles, time_limit_ps);
  }
  return sched_.stop_reason();
}

StopReason ResetSequencer::cycle(SimTime time_limit_ps,
                                 std::uint64_t settle_cycles) {
  assert_all();
  return release_all(time_limit_ps, settle_cycles);
}

}  // namespace harness
