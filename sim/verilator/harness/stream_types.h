// -----------------------------------------------------------------------------
// stream_types.h — provisional SPEC 5 stream bundle, as seen by the C++ harness.
//
// SPEC 5 defines the synthesizable bundle:
//     valid / ready / data / start_of_frame / end_of_frame / stream_id /
//     sequence / user
// StreamBeat below is exactly the payload half of that (everything but the
// handshake), so the driver, monitor and scoreboard all speak one vocabulary.
//
// PROVISIONAL: field widths are the Phase 0 provisional ones generated from
// config/<name>.json; issue #5 owns the real stream interface. The C++ side
// keeps every field in a fixed-width host integer and masks on drive, so a
// width change in the config never silently truncates.
//
// Port abstraction
// ----------------
// The harness never includes the Verilated model header. A test binds concrete
// DUT ports to StreamSourcePort / StreamSinkPort implementations, which is what
// lets the same driver, monitor and scoreboard be pointed at any stream in the
// design as the RTL grows, and keeps the harness library compilable and
// reviewable without a build of the model.
// -----------------------------------------------------------------------------
#ifndef HARNESS_STREAM_TYPES_H_
#define HARNESS_STREAM_TYPES_H_

#include <cstdint>
#include <string>

namespace harness {

struct StreamBeat {
  std::uint64_t data = 0;
  bool start_of_frame = false;
  bool end_of_frame = false;
  std::uint32_t stream_id = 0;
  std::uint32_t sequence = 0;
  std::uint32_t user = 0;

  bool operator==(const StreamBeat& o) const {
    return data == o.data && start_of_frame == o.start_of_frame &&
           end_of_frame == o.end_of_frame && stream_id == o.stream_id &&
           sequence == o.sequence && user == o.user;
  }
  bool operator!=(const StreamBeat& o) const { return !(*this == o); }

  std::string to_string() const;
};

// Source side: the harness drives valid + payload, the DUT drives ready.
class StreamSourcePort {
 public:
  virtual ~StreamSourcePort() = default;
  virtual void drive_valid(bool v) = 0;
  virtual void drive_payload(const StreamBeat& b) = 0;
  virtual bool sample_valid() const = 0;
  virtual bool sample_ready() const = 0;
};

// Sink side: the DUT drives valid + payload, the harness drives ready.
class StreamSinkPort {
 public:
  virtual ~StreamSinkPort() = default;
  virtual void drive_ready(bool r) = 0;
  virtual bool sample_valid() const = 0;
  virtual bool sample_ready() const = 0;
  virtual StreamBeat sample_payload() const = 0;
};

}  // namespace harness

#endif  // HARNESS_STREAM_TYPES_H_
