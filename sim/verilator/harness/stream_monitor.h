// -----------------------------------------------------------------------------
// stream_monitor.h — randomized-ready stream sink (SPEC.md 12.2).
//
// Applies a randomized ready pattern to a SPEC 5 sink port, records every
// observed beat, and enforces the two structural properties that do not need a
// reference model:
//
//   * frame integrity — start_of_frame opens exactly one frame per stream_id,
//     end_of_frame closes it, and no beat appears outside a frame. Frame
//     boundaries must survive arbitrary backpressure (SPEC 5).
//   * sequence continuity — per stream_id the sequence field increments by one
//     with wraparound. This is the loss/reorder detector that SPEC 5 requires
//     sequence numbers to permit, independent of the scoreboard.
//
// Observed beats are forwarded to a sink callback (the scoreboard in practice),
// keeping the monitor free of any expectation model.
//
// Wiring: on_sample() in Phase::kSample and on_drive() in Phase::kDrive of the
// sink clock's positive edge.
// -----------------------------------------------------------------------------
#ifndef HARNESS_STREAM_MONITOR_H_
#define HARNESS_STREAM_MONITOR_H_

#include <cstdint>
#include <functional>
#include <map>
#include <string>
#include <utility>

#include "harness/error_collector.h"
#include "harness/random.h"
#include "harness/stream_types.h"

namespace harness {

class StreamMonitor {
 public:
  using ObserveHook = std::function<void(const StreamBeat&, std::uint64_t)>;

  StreamMonitor(std::string name, StreamSinkPort& port, std::mt19937_64 rng,
                BackpressureConfig cfg, ErrorCollector& errors);

  void set_observe_hook(ObserveHook h) { observe_hook_ = std::move(h); }
  void set_cycle_probe(const std::uint64_t* cycles) { cycles_ = cycles; }

  void on_sample();
  void on_drive();

  // Clears per-stream frame/sequence tracking and deasserts ready. Called on
  // reset; the observed-beat counters are cleared too so per-pass statistics
  // are independent.
  void reset();

  std::uint64_t beats_received() const { return beats_received_; }
  std::uint64_t frames_received() const { return frames_received_; }
  // Streams left mid-frame. Non-zero at end of test means a truncated frame.
  std::size_t open_frames() const;
  const BackpressureGenerator& backpressure() const { return bp_; }
  const std::string& name() const { return name_; }

  // Reports any stream still inside a frame as a frame-integrity error.
  void check_drained();

 private:
  struct StreamState {
    bool in_frame = false;
    bool have_seq = false;
    std::uint32_t next_seq = 0;
    std::uint64_t beats = 0;
  };

  StreamState& state_for(std::uint32_t stream_id);

  std::string name_;
  StreamSinkPort& port_;
  BackpressureGenerator bp_;
  ErrorCollector& errors_;
  // std::map, not unordered_map: iteration order must be deterministic because
  // check_drained() emits errors while iterating it.
  std::map<std::uint32_t, StreamState> streams_;
  std::uint64_t beats_received_ = 0;
  std::uint64_t frames_received_ = 0;
  std::uint32_t seq_mask_ = 0xFFFFFFFFu;
  const std::uint64_t* cycles_ = nullptr;
  ObserveHook observe_hook_;

 public:
  // Sequence field width, used for wraparound. Set from the generated config.
  void set_sequence_width(unsigned bits);
};

}  // namespace harness

#endif  // HARNESS_STREAM_MONITOR_H_
