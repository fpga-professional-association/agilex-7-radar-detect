// -----------------------------------------------------------------------------
// stream_driver.h — randomized-valid stream source (SPEC.md 12.2).
//
// Holds a queue of beats and presents them on a SPEC 5 source port under a
// randomized stall pattern. The two protocol obligations of a source are
// structural here rather than checked after the fact:
//
//   * payload and valid change only after an accepted transfer, so a stalled
//     source is bit-stable by construction (SPEC 5);
//   * a beat is never withdrawn once asserted — the stall generator is consulted
//     only when the driver is free to pick a new beat.
//
// Wiring: on_sample() in ClockScheduler Phase::kSample, on_drive() in
// Phase::kDrive, both on the source clock's positive edge. Sampling before the
// toggle is what makes `valid && ready` mean "this beat transfers at this edge".
// -----------------------------------------------------------------------------
#ifndef HARNESS_STREAM_DRIVER_H_
#define HARNESS_STREAM_DRIVER_H_

#include <cstdint>
#include <deque>
#include <functional>
#include <string>
#include <utility>
#include <vector>

#include "harness/error_collector.h"
#include "harness/random.h"
#include "harness/stream_types.h"

namespace harness {

class StreamDriver {
 public:
  StreamDriver(std::string name, StreamSourcePort& port, std::mt19937_64 rng,
               BackpressureConfig cfg, ErrorCollector& errors);

  // Queues one beat / one whole frame for transmission.
  void queue(const StreamBeat& b) { pending_.push_back(b); }
  void queue_frame(const std::vector<StreamBeat>& frame);

  // Invoked when a beat is accepted by the DUT, with the accepting cycle.
  // Used by the test to feed the scoreboard's expected queue at the exact
  // moment the DUT takes ownership.
  using AcceptHook = std::function<void(const StreamBeat&, std::uint64_t)>;
  void set_accept_hook(AcceptHook h) { accept_hook_ = std::move(h); }

  // Cycle counter used to stamp accepted beats. Bound to the source clock.
  void set_cycle_probe(const std::uint64_t* cycles) { cycles_ = cycles; }

  void on_sample();
  void on_drive();

  // Drops the driven outputs and any in-flight beat. Queued beats are kept
  // unless `drop_queue` is set, so a reset mid-test is a stall, not a loss.
  void reset(bool drop_queue = true);

  bool idle() const { return pending_.empty() && !holding_; }
  std::size_t queued() const { return pending_.size(); }
  std::uint64_t beats_sent() const { return beats_sent_; }
  const BackpressureGenerator& backpressure() const { return bp_; }
  const std::string& name() const { return name_; }

 private:
  std::string name_;
  StreamSourcePort& port_;
  BackpressureGenerator bp_;
  ErrorCollector& errors_;
  std::deque<StreamBeat> pending_;
  StreamBeat held_{};
  bool holding_ = false;
  std::uint64_t beats_sent_ = 0;
  std::uint64_t stall_hold_checks_ = 0;
  const std::uint64_t* cycles_ = nullptr;
  AcceptHook accept_hook_;
};

}  // namespace harness

#endif  // HARNESS_STREAM_DRIVER_H_
