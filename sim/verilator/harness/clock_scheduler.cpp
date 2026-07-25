#include "harness/clock_scheduler.h"

#include <algorithm>
#include <limits>
#include <utility>

namespace harness {

const char* to_string(StopReason r) {
  switch (r) {
    case StopReason::kRunning: return "running";
    case StopReason::kPass:    return "pass";
    case StopReason::kFail:    return "fail";
    case StopReason::kTimeout: return "timeout";
  }
  return "unknown";
}

ClockScheduler::ClockScheduler(EvalFn eval) : eval_(std::move(eval)) {}

int ClockScheduler::add_clock(std::string name, SimTime half_period_ps,
                              std::uint8_t* signal, SimTime first_edge_ps) {
  Clock c;
  c.name = std::move(name);
  c.half_period = half_period_ps;
  c.next_edge = first_edge_ps;
  c.signal = signal;
  *signal = 0;
  clocks_.push_back(std::move(c));
  return static_cast<int>(clocks_.size()) - 1;
}

void ClockScheduler::on(int clk, Edge edge, Phase phase, Callback cb) {
  clocks_.at(clk).cb[edge_idx(edge)][phase_idx(phase)].push_back(std::move(cb));
}

void ClockScheduler::stop_pass(std::string detail) {
  if (stop_reason_ != StopReason::kRunning) return;
  stop_reason_ = StopReason::kPass;
  stop_detail_ = std::move(detail);
}

void ClockScheduler::stop_fail(std::string detail) {
  if (stop_reason_ != StopReason::kRunning) return;
  stop_reason_ = StopReason::kFail;
  stop_detail_ = std::move(detail);
}

void ClockScheduler::stop_timeout(std::string detail) {
  if (stop_reason_ != StopReason::kRunning) return;
  stop_reason_ = StopReason::kTimeout;
  stop_detail_ = std::move(detail);
}

void ClockScheduler::clear_stop() {
  stop_reason_ = StopReason::kRunning;
  stop_detail_.clear();
}

void ClockScheduler::run_callbacks(Clock& c, Edge e, Phase p) {
  for (auto& fn : c.cb[edge_idx(e)][phase_idx(p)]) fn();
}

void ClockScheduler::settle() {
  eval_();
  if (step_hook_) step_hook_(time_);
}

SimTime ClockScheduler::next_edge_time() const {
  SimTime next = std::numeric_limits<SimTime>::max();
  for (const Clock& c : clocks_) next = std::min(next, c.next_edge);
  return next;
}

// One complete time step: SPEC 12.3 steps (1)-(5) for a single instant.
void ClockScheduler::step() {
  time_ = next_edge_time();

  // Clocks with an edge at this instant, in registration order.
  due_.clear();
  for (int i = 0; i < static_cast<int>(clocks_.size()); ++i) {
    if (clocks_[i].next_edge == time_) due_.push_back(i);
  }

  // Phase kSample: pre-toggle, pre-eval. Observes exactly the values the model
  // is about to capture at this edge.
  for (int i : due_) {
    Clock& c = clocks_[i];
    run_callbacks(c, *c.signal ? Edge::kNeg : Edge::kPos, Phase::kSample);
  }

  // (3) Toggle every clock due at this instant, then (4) eval once.
  for (int i : due_) {
    Clock& c = clocks_[i];
    *c.signal = static_cast<std::uint8_t>(*c.signal ? 0 : 1);
    if (*c.signal) ++c.posedges;
    c.next_edge += c.half_period;
  }
  eval_();

  // (5) Phase kDrive: post-eval stimulus, then a settling eval so that
  // combinational outputs reflect the new inputs for the rest of the cycle.
  for (int i : due_) {
    Clock& c = clocks_[i];
    run_callbacks(c, *c.signal ? Edge::kPos : Edge::kNeg, Phase::kDrive);
  }
  eval_();

  if (step_hook_) step_hook_(time_);
}

StopReason ClockScheduler::run(SimTime time_limit_ps) {
  if (clocks_.empty()) {
    stop_fail("clock scheduler has no clocks");
    return stop_reason_;
  }
  while (stop_reason_ == StopReason::kRunning) {
    if (next_edge_time() > time_limit_ps) {
      stop_timeout("simulation time limit reached at " + std::to_string(time_) +
                   " ps (limit " + std::to_string(time_limit_ps) + " ps)");
      break;
    }
    step();
  }
  return stop_reason_;
}

StopReason ClockScheduler::run_cycles(int clk, std::uint64_t cycles,
                                      SimTime time_limit_ps) {
  if (clocks_.empty()) {
    stop_fail("clock scheduler has no clocks");
    return stop_reason_;
  }
  const std::uint64_t target = clocks_.at(clk).posedges + cycles;
  while (stop_reason_ == StopReason::kRunning &&
         clocks_.at(clk).posedges < target) {
    if (next_edge_time() > time_limit_ps) {
      stop_timeout("simulation time limit reached at " + std::to_string(time_) +
                   " ps (limit " + std::to_string(time_limit_ps) + " ps)");
      break;
    }
    step();
  }
  return stop_reason_;
}

}  // namespace harness
