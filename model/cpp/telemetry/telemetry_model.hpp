// -----------------------------------------------------------------------------
// telemetry_model.hpp — cycle-accurate C++ mirror of the issue #8 primitives.
//
// SPEC 12.4 requires a reference model the RTL is checked against rather than a
// test that asserts what the RTL happens to do. This header is that model for
// rtl/common/perf_counter.sv and rtl/common/seq_checker.sv: an independent
// implementation of the same two specifications, written from the NORMATIVE
// paragraphs in those files' headers and not from their logic.
//
// Cycle accurate, not transaction accurate. `tick()` is one positive clock edge,
// takes exactly the inputs the module's ports take, and leaves the object in the
// state the module's registers are in after that edge. A test therefore compares
// every observable on every cycle — which is what caught the off-by-one in the
// snapshot rule that a transaction-level model would have reproduced faithfully
// in both places.
//
// The two agreements that matter, and are checked in sim/tests/:
//
//   perf_counter        count, shadow, shadow-valid, wrap pulse and sticky flag,
//                       in both modulo and saturating mode, at any width from 1
//                       to 64.
//   seq_checker         the classification of every beat, the per-kind counts
//                       and the sticky flags, including at a sequence wrap.
//
// Header-only and dependency-free: it is compiled into the telemetry test
// binaries by scripts/build_verilator.py, which puts model/cpp on the include
// path, and it must also be readable on its own as the statement of what the
// hardware is supposed to do.
// -----------------------------------------------------------------------------
#ifndef MODEL_CPP_TELEMETRY_TELEMETRY_MODEL_HPP_
#define MODEL_CPP_TELEMETRY_TELEMETRY_MODEL_HPP_

#include <algorithm>
#include <cstdint>
#include <string>
#include <vector>

namespace telemetry {

// `bits` low bits set. bits >= 64 yields all ones; bits == 0 yields zero.
inline constexpr std::uint64_t mask_of(unsigned bits) {
  if (bits == 0) return 0;
  return bits >= 64 ? ~0ULL : ((1ULL << bits) - 1ULL);
}

// -----------------------------------------------------------------------------
// perf_counter
//
// Mirrors the NORMATIVE rules in rtl/common/perf_counter.sv:
//   * the counter advances by `incr` only when `enable` and `event_i` are both
//     high;
//   * `clear` beats everything, including an event in the same cycle;
//   * in modulo mode the count is exact modulo 2**width; in saturating mode it
//     stops at all ones;
//   * `wrap_pulse` is registered: it is high in the cycle AFTER the edge at
//     which the counter passed its maximum, and is suppressed by a clear;
//   * the shadow latches the value the COUNTER ITSELF takes at the strobe edge,
//     so a snapshot includes that cycle's event and the shadow equals the live
//     count for the whole of the following cycle.
// -----------------------------------------------------------------------------
class CounterModel {
 public:
  CounterModel() = default;
  CounterModel(unsigned width, bool saturate)
      : width_(width), saturate_(saturate), mask_(mask_of(width)) {}

  void configure(unsigned width, bool saturate) {
    width_ = width;
    saturate_ = saturate;
    mask_ = mask_of(width);
    reset();
  }

  void reset() {
    count_ = 0;
    snap_ = 0;
    snap_valid_ = false;
    wrap_pulse_ = false;
    wrapped_ = false;
  }

  // One positive clock edge, with the inputs as they were held during the cycle
  // that edge ends.
  void tick(bool enable, bool event, std::uint64_t incr, bool clear,
            bool snapshot) {
    const std::uint64_t amount = (enable && event) ? incr : 0ULL;

    // The RTL's carry-out of a (width+1)-bit adder, computed here without
    // relying on a wider type: at width 64 there is no wider type.
    const bool over = amount != 0 && (count_ > mask_ - amount);
    const std::uint64_t sum = (count_ + amount) & mask_;

    std::uint64_t next = saturate_ ? (over ? mask_ : sum) : sum;
    if (clear) next = 0;

    if (snapshot) {
      snap_ = next;
      snap_valid_ = true;
    } else if (clear) {
      snap_ = 0;
      snap_valid_ = false;
    }

    wrap_pulse_ = over && !clear;
    wrapped_ = clear ? false : (wrapped_ || over);
    count_ = next;
  }

  std::uint64_t count() const { return count_; }
  std::uint64_t snap() const { return snap_; }
  bool snap_valid() const { return snap_valid_; }
  bool wrap_pulse() const { return wrap_pulse_; }
  bool wrapped() const { return wrapped_; }
  unsigned width() const { return width_; }
  bool saturating() const { return saturate_; }

 private:
  unsigned width_ = 32;
  bool saturate_ = false;
  std::uint64_t mask_ = 0xFFFFFFFFULL;

  std::uint64_t count_ = 0;
  std::uint64_t snap_ = 0;
  bool snap_valid_ = false;
  bool wrap_pulse_ = false;
  bool wrapped_ = false;
};

// -----------------------------------------------------------------------------
// seq_checker
//
// One accepted beat produces exactly one verdict. The names and the arithmetic
// are the NORMATIVE table in rtl/common/seq_checker.sv.
// -----------------------------------------------------------------------------
enum class Verdict {
  kNone,       // no accepted beat this cycle
  kInit,       // first beat of a stream: establishes the expectation, no error
  kResync,     // start_of_frame with sof_resync on: same, deliberately
  kInOrder,    // delta == 0
  kGap,        // 0 < delta < 2**(seq_w-1): `gap` beats never arrived
  kDuplicate,  // delta == -1: the beat just accepted, again
  kReorder,    // backwards, and not the immediately preceding beat
  kUntracked   // stream_id at or above the tracked count
};

inline const char* to_string(Verdict v) {
  switch (v) {
    case Verdict::kNone: return "none";
    case Verdict::kInit: return "init";
    case Verdict::kResync: return "resync";
    case Verdict::kInOrder: return "in_order";
    case Verdict::kGap: return "gap";
    case Verdict::kDuplicate: return "duplicate";
    case Verdict::kReorder: return "reorder";
    case Verdict::kUntracked: return "untracked";
  }
  return "?";
}

// Which counter, if any, a verdict feeds. Kept beside the enum so a test never
// re-derives it.
inline bool is_fault(Verdict v) {
  return v == Verdict::kGap || v == Verdict::kDuplicate ||
         v == Verdict::kReorder || v == Verdict::kUntracked;
}

struct SeqCounts {
  std::uint64_t gap = 0;
  std::uint64_t lost = 0;
  std::uint64_t dup = 0;
  std::uint64_t reorder = 0;
  std::uint64_t untracked = 0;

  bool operator==(const SeqCounts& o) const {
    return gap == o.gap && lost == o.lost && dup == o.dup &&
           reorder == o.reorder && untracked == o.untracked;
  }
  std::string to_string() const {
    return "gap=" + std::to_string(gap) + " lost=" + std::to_string(lost) +
           " dup=" + std::to_string(dup) + " reorder=" + std::to_string(reorder) +
           " untracked=" + std::to_string(untracked);
  }
};

class SeqTrackerModel {
 public:
  SeqTrackerModel(unsigned seq_w, unsigned n_ids, unsigned count_w)
      : seq_w_(seq_w),
        seq_mask_(static_cast<std::uint32_t>(mask_of(seq_w))),
        n_ids_(n_ids),
        known_(n_ids, false),
        expect_(n_ids, 0) {
    gap_.configure(count_w, true);
    lost_.configure(count_w, true);
    dup_.configure(count_w, true);
    reorder_.configure(count_w, true);
    untracked_.configure(count_w, true);
    reset();
  }

  void reset() {
    std::fill(known_.begin(), known_.end(), false);
    std::fill(expect_.begin(), expect_.end(), 0u);
    sticky_ = 0;
    last_ = Verdict::kNone;
    last_gap_size_ = 0;
    gap_.reset();
    lost_.reset();
    dup_.reset();
    reorder_.reset();
    untracked_.reset();
  }

  // Classify without changing state. Exposed so a test can predict a verdict
  // before driving it, which is how the directed fault-injection cases are
  // written: the expectation is computed from the specification, not read back
  // from the model afterwards.
  Verdict classify(bool enable, bool beat, std::uint32_t stream_id,
                   std::uint32_t seq, bool sof, bool sof_resync,
                   std::uint32_t* gap_size = nullptr) const {
    if (gap_size) *gap_size = 0;
    if (!enable || !beat) return Verdict::kNone;
    if (stream_id >= n_ids_) return Verdict::kUntracked;
    if (sof_resync && sof) return Verdict::kResync;
    if (!known_[stream_id]) return Verdict::kInit;

    const std::uint32_t delta = (seq - expect_[stream_id]) & seq_mask_;
    if (delta == 0) return Verdict::kInOrder;
    if (delta == seq_mask_) return Verdict::kDuplicate;
    const bool backward = (delta >> (seq_w_ - 1)) & 1u;
    if (!backward) {
      if (gap_size) *gap_size = delta;
      return Verdict::kGap;
    }
    return Verdict::kReorder;
  }

  // One positive clock edge.
  void tick(bool enable, bool beat, std::uint32_t stream_id, std::uint32_t seq,
            bool sof, bool sof_resync, bool sticky_clear, bool count_clear,
            bool snapshot) {
    std::uint32_t gap_size = 0;
    const Verdict v =
        classify(enable, beat, stream_id, seq, sof, sof_resync, &gap_size);

    // `enable` low clears every stream's expectation, so the first beat after it
    // rises re-initialises instead of reporting a loss.
    if (!enable) {
      std::fill(known_.begin(), known_.end(), false);
    } else if (v == Verdict::kInit || v == Verdict::kResync ||
               v == Verdict::kInOrder || v == Verdict::kGap) {
      known_[stream_id] = true;
      expect_[stream_id] = (seq + 1) & seq_mask_;
    }

    const bool e_gap = (v == Verdict::kGap);
    const bool e_dup = (v == Verdict::kDuplicate);
    const bool e_ror = (v == Verdict::kReorder);
    const bool e_unt = (v == Verdict::kUntracked);

    const unsigned events = (e_gap ? 1u : 0u) | (e_dup ? 2u : 0u) |
                            (e_ror ? 4u : 0u) | (e_unt ? 8u : 0u);
    sticky_ = (sticky_clear ? 0u : sticky_) | events;

    gap_.tick(true, e_gap, 1, count_clear, snapshot);
    lost_.tick(true, e_gap, gap_size, count_clear, snapshot);
    dup_.tick(true, e_dup, 1, count_clear, snapshot);
    reorder_.tick(true, e_ror, 1, count_clear, snapshot);
    untracked_.tick(true, e_unt, 1, count_clear, snapshot);

    last_ = v;
    last_gap_size_ = e_gap ? gap_size : 0;
  }

  // The verdict, and the gap size, of the most recent tick. These are what the
  // RTL presents combinationally in the cycle the beat is accepted, so a test
  // compares them against the pins BEFORE the edge that ticks the model.
  Verdict last_verdict() const { return last_; }
  std::uint32_t last_gap_size() const { return last_gap_size_; }

  // {untracked, reorder, dup, gap}, matching seq_checker's `sticky` port.
  unsigned sticky() const { return sticky_; }

  SeqCounts counts() const {
    return SeqCounts{gap_.count(), lost_.count(), dup_.count(),
                     reorder_.count(), untracked_.count()};
  }
  SeqCounts shadows() const {
    return SeqCounts{gap_.snap(), lost_.snap(), dup_.snap(), reorder_.snap(),
                     untracked_.snap()};
  }
  bool snap_valid() const { return gap_.snap_valid(); }

 private:
  unsigned seq_w_;
  std::uint32_t seq_mask_;
  unsigned n_ids_;

  std::vector<bool> known_;
  std::vector<std::uint32_t> expect_;
  unsigned sticky_ = 0;

  Verdict last_ = Verdict::kNone;
  std::uint32_t last_gap_size_ = 0;

  CounterModel gap_;
  CounterModel lost_;
  CounterModel dup_;
  CounterModel reorder_;
  CounterModel untracked_;
};

}  // namespace telemetry

#endif  // MODEL_CPP_TELEMETRY_TELEMETRY_MODEL_HPP_
