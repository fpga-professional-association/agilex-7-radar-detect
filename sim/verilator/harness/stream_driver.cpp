#include "harness/stream_driver.h"

#include <utility>

namespace harness {

StreamDriver::StreamDriver(std::string name, StreamSourcePort& port,
                           std::mt19937_64 rng, BackpressureConfig cfg,
                           ErrorCollector& errors)
    : name_(std::move(name)), port_(port), bp_(rng, cfg), errors_(errors) {}

void StreamDriver::queue_frame(const std::vector<StreamBeat>& frame) {
  for (const StreamBeat& b : frame) pending_.push_back(b);
}

void StreamDriver::on_sample() {
  // Pre-edge values: this is the transfer the DUT is about to capture.
  if (!holding_) return;
  if (port_.sample_valid() && port_.sample_ready()) {
    ++beats_sent_;
    holding_ = false;
    if (accept_hook_) accept_hook_(held_, cycles_ ? *cycles_ : 0);
  } else {
    // Still stalled. The RTL-side assertion a_slave_stable proves stability on
    // the wire; this counter records how often the case was actually hit, so a
    // "passing" run that never stalled is visible in the summary.
    ++stall_hold_checks_;
  }
}

void StreamDriver::on_drive() {
  if (holding_) {
    // SPEC 5: hold payload and metadata stable while stalled. Deliberately no
    // re-drive here — the port keeps the values written when the beat was
    // selected, so there is no path by which a held beat can change.
    return;
  }
  if (pending_.empty()) {
    port_.drive_valid(false);
    return;
  }
  if (!bp_.allow()) {
    // Randomized idle gap between beats.
    port_.drive_valid(false);
    return;
  }
  held_ = pending_.front();
  pending_.pop_front();
  port_.drive_payload(held_);
  port_.drive_valid(true);
  holding_ = true;
}

void StreamDriver::reset(bool drop_queue) {
  port_.drive_valid(false);
  holding_ = false;
  if (drop_queue) pending_.clear();
  bp_.clear_state();
  (void)errors_;
}

}  // namespace harness
