// -----------------------------------------------------------------------------
// stream_types.h — the SPEC 5 stream bundle as seen by the C++ harness.
//
// SPEC 5 defines the synthesizable bundle:
//     valid / ready / data / start_of_frame / end_of_frame / stream_id /
//     seq / user
// StreamBeat below is exactly the payload half of that (everything but the
// handshake), so the driver, monitor and scoreboard all speak one vocabulary.
//
// Field naming: `seq`, matching rtl/packages/stream_pkg.sv. SPEC 5 spells the
// field `sequence`, which is a SystemVerilog keyword and therefore illegal as a
// struct member there; `seq` is the project-wide spelling in both languages
// (DECISIONS.md 2026-07-26, decision 2). `TransactionId::sequence` keeps its own
// name: that is SPEC 12.5's identity tuple, a different concept from the wire
// field, and it is never a SystemVerilog identifier.
//
// Packing (issue #5)
// ------------------
// StreamLayout is the C++ view of the packed payload vector. It holds no layout
// knowledge of its own: a test builds one from the generated constants in
// config_sim.h, which scripts/build_verilator.py derives from the same field
// order as rtl/packages/stream_pkg.sv and which benchmark_sim_top compares
// against the package at time 0 of every run. So there are three artefacts and
// one definition:
//
//   rtl/packages/stream_pkg.sv     NORMATIVE field order and offsets
//   scripts/build_verilator.py     mirror -> config_pkg.sv + config_sim.h
//   StreamLayout (here)            consumes the mirror; adds no constants
//
// and two independent checks that they agree: the time-0 comparison in
// benchmark_sim_top (offsets), and test_stream_loopback.cpp comparing this
// class's unpack() against the RTL's exported `m_payload` on every beat
// (the packing code itself).
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
  std::uint32_t seq = 0;
  std::uint32_t user = 0;

  bool operator==(const StreamBeat& o) const {
    return data == o.data && start_of_frame == o.start_of_frame &&
           end_of_frame == o.end_of_frame && stream_id == o.stream_id &&
           seq == o.seq && user == o.user;
  }
  bool operator!=(const StreamBeat& o) const { return !(*this == o); }

  std::string to_string() const;
};

// -----------------------------------------------------------------------------
// Packed-payload layout. Every value here comes from the caller (in practice
// from the generated config_sim.h); nothing is defaulted to a "known" offset,
// because a default would be a second definition of the layout.
// -----------------------------------------------------------------------------
struct StreamLayout {
  unsigned data_w = 0;
  unsigned id_w = 0;
  unsigned seq_w = 0;
  unsigned user_w = 0;

  unsigned user_lsb = 0;
  unsigned seq_lsb = 0;
  unsigned id_lsb = 0;
  unsigned eof_lsb = 0;
  unsigned sof_lsb = 0;
  unsigned data_lsb = 0;
  unsigned payload_w = 0;

  // `bits` low bits set; bits >= 64 yields all ones.
  static std::uint64_t mask_of(unsigned bits) {
    return bits >= 64 ? ~0ULL : ((1ULL << bits) - 1ULL);
  }

  // The C++ side carries a payload in one std::uint64_t, which is what the
  // Verilated port is for any width up to 64. A configuration that outgrows
  // that must widen this type deliberately rather than silently truncate, so
  // the condition is exposed and asserted by the tests.
  bool fits_u64() const { return payload_w <= 64; }

  // Field values truncated to their declared widths — what the RTL will see.
  StreamBeat truncate(const StreamBeat& b) const {
    StreamBeat t = b;
    t.data = b.data & mask_of(data_w);
    t.stream_id = static_cast<std::uint32_t>(b.stream_id & mask_of(id_w));
    t.seq = static_cast<std::uint32_t>(b.seq & mask_of(seq_w));
    t.user = static_cast<std::uint32_t>(b.user & mask_of(user_w));
    return t;
  }

  std::uint64_t pack(const StreamBeat& b) const {
    std::uint64_t p = 0;
    p |= (b.data & mask_of(data_w)) << data_lsb;
    p |= static_cast<std::uint64_t>(b.start_of_frame ? 1 : 0) << sof_lsb;
    p |= static_cast<std::uint64_t>(b.end_of_frame ? 1 : 0) << eof_lsb;
    p |= (static_cast<std::uint64_t>(b.stream_id) & mask_of(id_w)) << id_lsb;
    p |= (static_cast<std::uint64_t>(b.seq) & mask_of(seq_w)) << seq_lsb;
    p |= (static_cast<std::uint64_t>(b.user) & mask_of(user_w)) << user_lsb;
    return p & mask_of(payload_w);
  }

  StreamBeat unpack(std::uint64_t p) const {
    StreamBeat b;
    b.data = (p >> data_lsb) & mask_of(data_w);
    b.start_of_frame = ((p >> sof_lsb) & 1ULL) != 0;
    b.end_of_frame = ((p >> eof_lsb) & 1ULL) != 0;
    b.stream_id = static_cast<std::uint32_t>((p >> id_lsb) & mask_of(id_w));
    b.seq = static_cast<std::uint32_t>((p >> seq_lsb) & mask_of(seq_w));
    b.user = static_cast<std::uint32_t>((p >> user_lsb) & mask_of(user_w));
    return b;
  }

  // Self-consistency of the mirror, independent of the RTL: the offsets must be
  // exactly the field order stream_pkg.sv defines, with no gap and no overlap.
  // Returns an empty string when consistent, a description otherwise.
  std::string self_check() const;

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

// -----------------------------------------------------------------------------
// Port adapters for a DUT that carries the SPEC 5 bundle as one packed vector —
// which is every module under rtl/stream/. Bound to three raw signal pointers
// plus the layout, so one pair of classes serves every packed interface in the
// design instead of a hand-written adapter per DUT.
//
// The pointer types are the host integers Verilator uses for a port of that
// width (CData == std::uint8_t for 1..8 bits, QData == std::uint64_t for
// 33..64), spelled here as the standard types so the harness still does not
// include the model header. A test static_asserts that its payload width lands
// in the 64-bit range; see sim/tests/test_stream_primitives.cpp.
// -----------------------------------------------------------------------------
class PackedSourcePort : public StreamSourcePort {
 public:
  PackedSourcePort(std::uint8_t* valid, const std::uint8_t* ready,
                   std::uint64_t* payload, const StreamLayout& layout)
      : valid_(valid), ready_(ready), payload_(payload), layout_(layout) {}

  void drive_valid(bool v) override { *valid_ = v ? 1 : 0; }
  void drive_payload(const StreamBeat& b) override {
    *payload_ = layout_.pack(b);
  }
  bool sample_valid() const override { return *valid_ != 0; }
  bool sample_ready() const override { return *ready_ != 0; }

 private:
  std::uint8_t* valid_;
  const std::uint8_t* ready_;
  std::uint64_t* payload_;
  StreamLayout layout_;
};

class PackedSinkPort : public StreamSinkPort {
 public:
  PackedSinkPort(const std::uint8_t* valid, std::uint8_t* ready,
                 const std::uint64_t* payload, const StreamLayout& layout)
      : valid_(valid), ready_(ready), payload_(payload), layout_(layout) {}

  void drive_ready(bool r) override { *ready_ = r ? 1 : 0; }
  bool sample_valid() const override { return *valid_ != 0; }
  bool sample_ready() const override { return *ready_ != 0; }
  StreamBeat sample_payload() const override {
    return layout_.unpack(*payload_);
  }

 private:
  const std::uint8_t* valid_;
  std::uint8_t* ready_;
  const std::uint64_t* payload_;
  StreamLayout layout_;
};

}  // namespace harness

#endif  // HARNESS_STREAM_TYPES_H_
