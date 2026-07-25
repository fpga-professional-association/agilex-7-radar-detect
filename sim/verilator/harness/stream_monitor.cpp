#include "harness/stream_monitor.h"

#include <utility>

namespace harness {

StreamMonitor::StreamMonitor(std::string name, StreamSinkPort& port,
                             std::mt19937_64 rng, BackpressureConfig cfg,
                             ErrorCollector& errors)
    : name_(std::move(name)), port_(port), bp_(rng, cfg), errors_(errors) {}

void StreamMonitor::set_sequence_width(unsigned bits) {
  seq_mask_ = (bits >= 32) ? 0xFFFFFFFFu
                           : static_cast<std::uint32_t>((1ULL << bits) - 1ULL);
}

StreamMonitor::StreamState& StreamMonitor::state_for(std::uint32_t stream_id) {
  return streams_[stream_id];
}

void StreamMonitor::on_sample() {
  // Pre-edge values: exactly the beat transferring at this edge.
  if (!(port_.sample_valid() && port_.sample_ready())) return;

  const StreamBeat b = port_.sample_payload();
  const std::uint64_t cyc = cycles_ ? *cycles_ : 0;
  ++beats_received_;

  StreamState& st = state_for(b.stream_id);
  ++st.beats;

  // --- frame integrity (SPEC 5: frame boundaries survive backpressure) ---
  if (b.start_of_frame && st.in_frame) {
    errors_.error("frame",
                  name_ + ": start_of_frame inside an open frame on stream " +
                      std::to_string(b.stream_id) + " at beat " +
                      std::to_string(st.beats));
  }
  if (!b.start_of_frame && !st.in_frame) {
    errors_.error("frame",
                  name_ + ": beat outside a frame (no start_of_frame seen) on "
                          "stream " +
                      std::to_string(b.stream_id) + " at beat " +
                      std::to_string(st.beats));
  }
  if (b.start_of_frame) st.in_frame = true;
  if (b.end_of_frame) {
    if (!st.in_frame) {
      errors_.error("frame", name_ + ": end_of_frame with no open frame on "
                                     "stream " +
                                 std::to_string(b.stream_id));
    }
    st.in_frame = false;
    ++frames_received_;
  }

  // --- sequence continuity (SPEC 5: sequence permits loss/order checks) ---
  if (!st.have_seq) {
    st.have_seq = true;
  } else if (b.sequence != st.next_seq) {
    errors_.error("sequence",
                  name_ + ": stream " + std::to_string(b.stream_id) +
                      " sequence discontinuity: expected " +
                      std::to_string(st.next_seq) + ", observed " +
                      std::to_string(b.sequence));
  }
  st.next_seq = (b.sequence + 1u) & seq_mask_;

  if (observe_hook_) observe_hook_(b, cyc);
}

void StreamMonitor::on_drive() { port_.drive_ready(bp_.allow()); }

void StreamMonitor::reset() {
  port_.drive_ready(false);
  streams_.clear();
  beats_received_ = 0;
  frames_received_ = 0;
  bp_.clear_state();
}

std::size_t StreamMonitor::open_frames() const {
  std::size_t n = 0;
  for (const auto& kv : streams_) {
    if (kv.second.in_frame) ++n;
  }
  return n;
}

void StreamMonitor::check_drained() {
  for (const auto& kv : streams_) {
    if (kv.second.in_frame) {
      errors_.error("frame", name_ + ": stream " + std::to_string(kv.first) +
                                 " ended mid-frame (no end_of_frame)");
    }
  }
}

}  // namespace harness
