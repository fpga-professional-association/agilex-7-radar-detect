// -----------------------------------------------------------------------------
// reset_sequencer.h — deterministic per-domain reset sequencing (SPEC.md 12.2).
//
// Each SPEC 8 clock domain has its own active-low reset. The sequencer asserts
// every registered reset before time advances, then releases each one after a
// per-domain number of cycles *of that domain's own clock*. Domains therefore
// leave reset at different absolute times, which is the point: it is the
// cheapest way to keep a CDC bug from hiding behind a globally synchronous
// release, and it matches how the device behaves.
//
// Release happens in the kDrive phase, so the deasserted reset is stable for a
// whole cycle before the next capturing edge — no race with the model's
// asynchronous reset.
//
// Deterministic by construction: release cycle counts are fixed parameters, not
// random draws, so reset behaviour never varies with the seed.
// -----------------------------------------------------------------------------
#ifndef HARNESS_RESET_SEQUENCER_H_
#define HARNESS_RESET_SEQUENCER_H_

#include <cstdint>
#include <functional>
#include <string>
#include <vector>

#include "harness/clock_scheduler.h"

namespace harness {

class ResetSequencer {
 public:
  explicit ResetSequencer(ClockScheduler& sched) : sched_(sched) {}

  // Registers an active-low reset in the domain of clock `clk`, to be released
  // `release_after_cycles` positive edges after assertion.
  void add_domain(std::string name, int clk, std::uint8_t* rst_n,
                  std::uint64_t release_after_cycles);

  // Called by the test between passes: hooks that must re-arm (drivers,
  // monitors, scoreboards) register here and are invoked at assertion time.
  void on_assert(std::function<void()> fn) { on_assert_.push_back(std::move(fn)); }
  void on_release(std::function<void()> fn) {
    on_release_.push_back(std::move(fn));
  }

  // Asserts every reset immediately (asynchronous assert) and settles the
  // model so the assertion is visible without advancing time.
  void assert_all();

  // Runs the scheduler until every domain has been released, plus
  // `settle_cycles` further cycles of the slowest registered domain. Returns
  // the scheduler stop reason (kRunning means the sequence completed normally).
  StopReason release_all(SimTime time_limit_ps, std::uint64_t settle_cycles = 4);

  // Convenience: assert_all() followed by release_all().
  StopReason cycle(SimTime time_limit_ps, std::uint64_t settle_cycles = 4);

  bool all_released() const;

 private:
  struct Domain {
    std::string name;
    int clk = 0;
    std::uint8_t* rst_n = nullptr;
    std::uint64_t release_after = 0;
    std::uint64_t assert_cycle = 0;  // clk cycle count at assertion
    bool released = false;
  };

  ClockScheduler& sched_;
  std::vector<Domain> domains_;
  std::vector<std::function<void()>> on_assert_;
  std::vector<std::function<void()>> on_release_;
  bool release_hooks_fired_ = false;
};

}  // namespace harness

#endif  // HARNESS_RESET_SEQUENCER_H_
