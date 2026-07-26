// -----------------------------------------------------------------------------
// history_model.hpp — bit-exact reference model of the SPEC.md 7.3 time-frequency
// history and corner turn (issue #15).
//
// Mirrors rtl/memory/history_core.sv and rtl/packages/history_pkg.sv symbol for
// symbol. The correspondence, which is the thing that must not drift:
//
//     history_pkg.sv                          this file
//     ----------------------------------------------------------------------
//     hist_geom_t                             hist::Config
//     hist_beats_per_frame / hist_n_banks     Config::beats_per_frame / n_banks
//     hist_bank_of / hist_addr_of             hist::bank_of / hist::addr_of
//     hist_bitrev                             hist::bitrev
//     hist_stored_bin                         hist::stored_bin
//     hist_lane_of_bin / hist_beat_of_bin     hist::lane_of_bin / beat_of_bin
//     hist_slot_of                            hist::slot_of
//     hist_flag_e                             hist::kFlag*
//     history_core's rotation and counters    hist::Model
//
// IT CONTAINS NO ARITHMETIC ON SAMPLE VALUES, and that is the point. A corner
// turn moves words; it does not compute. Every sample this model stores comes
// back bit-identical or the model is wrong, so there is not one call into
// fxp.hpp's rounding or saturation anywhere below — the samples travel as
// fxp::Complex and are compared with `operator==`. If a future revision ever
// needs a quantisation here, that is a signal that the block has grown a
// datapath and the change belongs in a decision entry, not in this header.
//
// -----------------------------------------------------------------------------
// WHAT IS AND IS NOT PREDICTED  (SPEC 12.5)
// -----------------------------------------------------------------------------
// The RTL has two clock domains, and the read side works from a view of the
// write side's pointer that is published across a handshake. How stale that view
// is depends on the clock ratio and on where in the handshake the frame landed,
// which is not a function of the stimulus. So the model predicts:
//
//   * EXACTLY, in a quiesced phase (writes stopped, pointer settled): every
//     returned sample, every flag, every counter, the occupancy and the readable
//     bound. This is the mode the bit-exactness tests run in, over several
//     rotations of the buffer.
//   * BY IDENTITY, in a concurrent phase (writes and reads at once): the
//     response carries the ABSOLUTE frame id it was served from, so the test
//     asks `peek(frame_id, bin)` and requires a bit-identical answer, plus the
//     structural invariants (one response per request, in order, no loss, no
//     duplication). It does NOT predict which frame_id a given request will get,
//     because that is exactly the pointer staleness the clock ratio decides.
//
// SPEC 12.5 forbids requiring one fixed end-to-end latency when elastic
// buffering is enabled; this is the same rule applied one level up, to a
// crossing rather than to a FIFO.
//
// Header-only. Build contract: g++ 13, -std=c++17 -O3 -Wall -Wextra -Werror,
// -Imodel/cpp.
// -----------------------------------------------------------------------------

#ifndef MODEL_CPP_HISTORY_HISTORY_MODEL_HPP_
#define MODEL_CPP_HISTORY_HISTORY_MODEL_HPP_

#include <cstdint>
#include <string>
#include <vector>

#include "fxp/fxp.hpp"

namespace hist {

// Response flag bits. Same order, same meaning, as history_pkg::hist_flag_e.
inline constexpr unsigned kFlagOutOfRange = 1u << 0;
inline constexpr unsigned kFlagCollision  = 1u << 1;
inline constexpr unsigned kFlagStale      = 1u << 2;

// Fixed control/status port width, mirroring history_pkg::HIST_PORT_W. The model
// truncates exactly where the RTL truncates, so a deliberately absurd request
// produces the same answer in both.
inline constexpr unsigned kPortW = 16;

inline constexpr bool is_pow2(unsigned v) { return v >= 1 && (v & (v - 1)) == 0; }

inline unsigned clog2(unsigned v) {
  unsigned w = 0;
  while ((1u << w) < v) ++w;
  return w;
}

// $clog2 floored at 1, mirroring history_pkg::hist_w_of.
inline unsigned w_of(unsigned count) {
  const unsigned w = clog2(count);
  return w == 0 ? 1u : w;
}

// -----------------------------------------------------------------------------
// Geometry — history_pkg::hist_geom_t
// -----------------------------------------------------------------------------
struct Config {
  unsigned n_ant      = 2;
  unsigned fft_size   = 64;
  unsigned lanes      = 1;
  unsigned frames_max = 4;
  unsigned sample_w   = 16;
  // True when the upstream FFT ran with REORDER = 0 and therefore emitted
  // bit-reversed beat order. See history_pkg header section 3.
  bool bit_reversed = false;

  bool valid() const {
    return n_ant >= 1 && fft_size >= 2 && is_pow2(fft_size) && lanes >= 1 &&
           is_pow2(lanes) && lanes < fft_size && frames_max >= 2 &&
           is_pow2(frames_max) && sample_w >= 2 && sample_w <= 32;
  }

  unsigned beats_per_frame() const { return fft_size / lanes; }
  unsigned n_banks() const { return n_ant * lanes; }
  unsigned bank_words() const { return frames_max * beats_per_frame(); }
  unsigned bin_w() const { return w_of(fft_size); }
  unsigned beat_w() const { return w_of(beats_per_frame()); }
  unsigned slot_w() const { return w_of(frames_max); }
  unsigned depth_w() const { return clog2(frames_max + 1); }
  // Width the bit reversal acts on: the BEAT index, log2(M) — not log2(FFT_SIZE).
  unsigned rev_w() const { return clog2(beats_per_frame()); }
  std::uint64_t total_bits() const {
    return static_cast<std::uint64_t>(n_banks()) * bank_words() * 2 * sample_w;
  }
};

// -----------------------------------------------------------------------------
// The mapping — history_pkg section 1, NORMATIVE there and mirrored here
// -----------------------------------------------------------------------------
inline unsigned bitrev(unsigned v, unsigned w) {
  unsigned r = 0;
  for (unsigned i = 0; i < w; ++i) {
    if ((v >> i) & 1u) r |= 1u << (w - 1 - i);
  }
  return r;
}

inline unsigned bank_of(const Config& c, unsigned ant, unsigned lane) {
  return ant * c.lanes + lane;
}

inline unsigned addr_of(const Config& c, unsigned slot, unsigned beat) {
  return slot * c.beats_per_frame() + beat;
}

inline unsigned slot_of(unsigned frame, unsigned depth) {
  return depth == 0 ? 0u : frame % depth;
}

// Write direction: the natural bin of the sample that arrived on (beat, lane).
inline unsigned stored_bin(const Config& c, unsigned beat, unsigned lane) {
  const unsigned m = c.bit_reversed ? bitrev(beat, c.rev_w()) : beat;
  return lane * c.beats_per_frame() + m;
}

// Read direction: where natural bin `bin` lives.
inline unsigned lane_of_bin(const Config& c, unsigned bin) {
  return bin / c.beats_per_frame();
}
inline unsigned beat_of_bin(const Config& c, unsigned bin) {
  const unsigned m = bin % c.beats_per_frame();
  return c.bit_reversed ? bitrev(m, c.rev_w()) : m;
}

// -----------------------------------------------------------------------------
// A read response — history_pkg header section 5
// -----------------------------------------------------------------------------
struct Response {
  std::vector<fxp::Complex> vec;   // one sample per antenna, antenna 0 first
  unsigned      bin       = 0;
  unsigned      frame_off = 0;     // AFTER clamping, as the RTL reports it
  std::uint32_t frame_id  = 0;
  unsigned      flags     = 0;

  bool trustworthy() const { return flags == 0; }
};

// 32-bit saturating counter, mirroring perf_counter with SATURATE = 1.
class SatCounter {
 public:
  void bump(std::uint32_t by = 1) {
    const std::uint64_t n = static_cast<std::uint64_t>(v_) + by;
    v_ = n > 0xFFFFFFFFull ? 0xFFFFFFFFu : static_cast<std::uint32_t>(n);
  }
  void clear() { v_ = 0; }
  std::uint32_t value() const { return v_; }

 private:
  std::uint32_t v_ = 0;
};

// -----------------------------------------------------------------------------
// The model
// -----------------------------------------------------------------------------
class Model {
 public:
  explicit Model(const Config& c) : cfg_(c) { reset(); }

  const Config& config() const { return cfg_; }

  void reset() {
    store_.assign(cfg_.n_banks(),
                  std::vector<std::uint32_t>(cfg_.bank_words(), 0));
    resident_.assign(cfg_.frames_max, kNoFrame);
    beat_.assign(cfg_.n_ant, 0);
    slot_.assign(cfg_.n_ant, 0);
    frame_.assign(cfg_.n_ant, 0);
    in_frame_.assign(cfg_.n_ant, false);
    frames_done_ = 0;
    done_slot_   = 0;
    depth_       = cfg_.frames_max;
    depth_req_   = cfg_.frames_max;
    depth_pend_  = false;
    epoch_       = 0;
    skew_prev_   = false;
    overwrite_.clear();
    skew_.clear();
    wbeat_.clear();
    read_.clear();
    collision_.clear();
    error_.clear();
    framing_ = false;
  }

  // -------------------------------------------------------------------------
  // Write side
  //
  // `samples` is one beat: cfg.lanes complex values, lane 0 first, exactly as
  // the SPEC 5 data field packs them. Returns true when the beat was a framing
  // defect (the RTL counts the same condition into its sticky fault vector).
  // -------------------------------------------------------------------------
  bool write_beat(unsigned ant, const std::vector<fxp::Complex>& samples,
                  bool sof, bool eof) {
    const unsigned m = cfg_.beats_per_frame();
    const bool err = (eof && beat_[ant] != m - 1) || (!eof && beat_[ant] == m - 1) ||
                     (sof && beat_[ant] != 0) || (!sof && beat_[ant] == 0);
    if (err) framing_ = true;

    for (unsigned l = 0; l < cfg_.lanes && l < samples.size(); ++l) {
      store_[bank_of(cfg_, ant, l)][addr_of(cfg_, slot_[ant], beat_[ant])] =
          samples[l].packed();
    }
    wbeat_.bump();

    in_frame_[ant] = !eof;
    if (eof) {
      // This antenna has finished the frame it was writing; the slot now holds
      // it, and holds nothing else.
      resident_[slot_[ant]] = frame_[ant];
      beat_[ant] = 0;
      frame_[ant] += 1;
      slot_[ant] = (slot_[ant] + 1 == depth_) ? 0 : slot_[ant] + 1;
    } else {
      beat_[ant] += 1;
    }

    settle_();
    return err;
  }

  // -------------------------------------------------------------------------
  // Depth programming — history_core header section 6
  // -------------------------------------------------------------------------
  void request_depth(unsigned d) {
    if (d == 0) d = 1;
    if (d > cfg_.frames_max) d = cfg_.frames_max;
    depth_req_  = d;
    depth_pend_ = true;
    settle_();
  }

  bool at_safe_boundary() const {
    for (bool f : in_frame_) {
      if (f) return false;
    }
    return true;
  }
  bool depth_pending() const { return depth_pend_; }

  // -------------------------------------------------------------------------
  // Read side
  //
  // Answers exactly as history_core answers when the read domain's published
  // view has caught up with the write domain — which is what the quiesced test
  // phases guarantee.
  // -------------------------------------------------------------------------
  Response read(unsigned bin, unsigned frame_off, bool force_unsafe = false) {
    Response r;
    const unsigned depth_mask = (1u << cfg_.depth_w()) - 1u;
    const unsigned slot_mask  = (1u << cfg_.slot_w()) - 1u;
    const unsigned ext_mask   = (1u << (cfg_.slot_w() + 1)) - 1u;
    const unsigned port_mask  = (kPortW >= 32) ? 0xFFFFFFFFu : ((1u << kPortW) - 1u);

    const unsigned bin_p = bin & port_mask;
    const unsigned off_p = frame_off & port_mask;

    const unsigned rd = readable();
    const bool oor = (bin_p >= cfg_.fft_size) || (rd == 0) || (off_p >= rd);

    const unsigned off_clamped = (rd == 0) ? 0u : rd - 1u;
    const unsigned off_safe =
        (oor && !force_unsafe) ? off_clamped : (off_p & depth_mask);

    const unsigned off_ext  = off_safe & ext_mask;
    const unsigned done_ext = done_slot_ & ext_mask;
    const unsigned slot =
        (done_ext >= off_ext)
            ? ((done_ext - off_ext) & slot_mask)
            : (((done_ext - off_ext + depth_) & ext_mask) & slot_mask);

    const unsigned write_slot =
        (done_slot_ + 1 == depth_) ? 0u : (done_slot_ + 1) & slot_mask;
    const bool collision = (frames_done_ != 0) && (slot == write_slot);

    const std::uint32_t frame_id =
        static_cast<std::uint32_t>(frames_done_ - 1u - off_safe);

    // Stale is decided at the output stage against the pointer as it stands
    // then. In a quiesced phase the pointer has not moved, so this is exact.
    const bool stale =
        static_cast<std::uint32_t>(frames_done_ - frame_id) > depth_;

    const unsigned lane = lane_of_bin(cfg_, bin_p % cfg_.fft_size);
    const unsigned beat = beat_of_bin(cfg_, bin_p % cfg_.fft_size);
    const unsigned addr = addr_of(cfg_, slot, beat);

    r.vec.resize(cfg_.n_ant);
    for (unsigned a = 0; a < cfg_.n_ant; ++a) {
      r.vec[a] = fxp::Complex::from_packed(store_[bank_of(cfg_, a, lane)][addr]);
    }
    r.bin       = bin_p & ((1u << cfg_.bin_w()) - 1u);
    r.frame_off = off_safe;
    r.frame_id  = frame_id;
    r.flags     = (oor ? kFlagOutOfRange : 0u) | (collision ? kFlagCollision : 0u) |
                  (stale ? kFlagStale : 0u);

    read_.bump();
    if (collision) collision_.bump();
    if (oor) error_.bump();
    return r;
  }

  // -------------------------------------------------------------------------
  // Storage inspection, for the concurrent phases
  // -------------------------------------------------------------------------
  bool frame_resident(std::uint32_t frame_id) const {
    const unsigned slot = slot_of(static_cast<unsigned>(frame_id), depth_);
    return slot < resident_.size() && resident_[slot] == frame_id;
  }

  // The antenna vector for (frame_id, bin) as the storage holds it NOW. Only
  // meaningful while frame_resident(frame_id).
  std::vector<fxp::Complex> peek(std::uint32_t frame_id, unsigned bin) const {
    const unsigned slot = slot_of(static_cast<unsigned>(frame_id), depth_);
    const unsigned lane = lane_of_bin(cfg_, bin);
    const unsigned beat = beat_of_bin(cfg_, bin);
    const unsigned addr = addr_of(cfg_, slot, beat);
    std::vector<fxp::Complex> v(cfg_.n_ant);
    for (unsigned a = 0; a < cfg_.n_ant; ++a) {
      v[a] = fxp::Complex::from_packed(store_[bank_of(cfg_, a, lane)][addr]);
    }
    return v;
  }

  // -------------------------------------------------------------------------
  // State and counters
  // -------------------------------------------------------------------------
  unsigned depth() const { return depth_; }
  unsigned epoch() const { return epoch_; }
  std::uint32_t frames_done() const { return frames_done_; }
  unsigned occupancy() const {
    return frames_done_ >= depth_ ? depth_ : static_cast<unsigned>(frames_done_);
  }
  // Two slots short of the depth: one for the frame being written, one to
  // absorb a frame of publication lag across the clock-domain crossing. See
  // history_core header section 5 - a depth-1 bound is a real defect.
  unsigned readable() const {
    const unsigned dm2 = depth_ <= 2 ? 0u : depth_ - 2u;
    return frames_done_ >= dm2 ? dm2 : static_cast<unsigned>(frames_done_);
  }

  std::uint32_t overwrite_count() const { return overwrite_.value(); }
  std::uint32_t skew_count() const { return skew_.value(); }
  std::uint32_t write_beat_count() const { return wbeat_.value(); }
  std::uint32_t read_count() const { return read_.value(); }
  std::uint32_t collision_count() const { return collision_.value(); }
  std::uint32_t error_count() const { return error_.value(); }
  bool framing_fault() const { return framing_; }

  void clear_counters() {
    overwrite_.clear();
    skew_.clear();
    wbeat_.clear();
    read_.clear();
    collision_.clear();
    error_.clear();
  }
  void clear_sticky() { framing_ = false; }

  std::string describe() const {
    return std::to_string(cfg_.n_ant) + " ant x " + std::to_string(cfg_.lanes) +
           " lanes = " + std::to_string(cfg_.n_banks()) + " banks of " +
           std::to_string(cfg_.bank_words()) + " x " +
           std::to_string(2 * cfg_.sample_w) + " bits";
  }

 private:
  static constexpr std::uint32_t kNoFrame = 0xFFFFFFFFu;

  // Advance everything that is decided by the state rather than by an event:
  // the frame barrier, the overwrite bookkeeping, the skew edge, and a pending
  // depth change that has become safe. Called after every write and after every
  // configuration change, which is every point at which any of them can move.
  void settle_() {
    // Frame barrier: frames_done = min over antennas, as an advance-while loop
    // — the same fixed point history_core reaches one cycle at a time.
    for (;;) {
      bool all_past = true;
      for (unsigned a = 0; a < cfg_.n_ant; ++a) {
        if (frame_[a] == frames_done_) all_past = false;
      }
      if (!all_past) break;
      if (frames_done_ >= depth_) overwrite_.bump();
      frames_done_ += 1;
      if (frames_done_ != 1) {
        done_slot_ = (done_slot_ + 1 == depth_) ? 0u : done_slot_ + 1u;
      }
    }

    // Skew, on the rising edge of the condition. See history_core's note on why
    // this is an episode count and not a duration.
    bool skew_now = false;
    for (unsigned a = 0; a < cfg_.n_ant; ++a) {
      if (frame_[a] - frames_done_ >= depth_) skew_now = true;
    }
    if (skew_now && !skew_prev_) skew_.bump();
    skew_prev_ = skew_now;

    // A pending depth change lands the moment no antenna is mid-frame, and it
    // DISCARDS the history: the frame-to-slot mapping changed, so nothing
    // already stored means what it used to.
    if (depth_pend_ && at_safe_boundary()) {
      depth_       = depth_req_;
      depth_pend_  = false;
      epoch_      += 1;
      frames_done_ = 0;
      done_slot_   = 0;
      skew_prev_   = false;
      for (unsigned a = 0; a < cfg_.n_ant; ++a) {
        beat_[a]  = 0;
        slot_[a]  = 0;
        frame_[a] = 0;
      }
      resident_.assign(cfg_.frames_max, kNoFrame);
    }
  }

  Config cfg_;
  std::vector<std::vector<std::uint32_t>> store_;
  std::vector<std::uint32_t> resident_;   // frame id currently in each slot
  std::vector<unsigned> beat_, slot_;
  std::vector<std::uint32_t> frame_;
  std::vector<bool> in_frame_;
  std::uint32_t frames_done_ = 0;
  unsigned done_slot_ = 0;
  unsigned depth_ = 0, depth_req_ = 0, epoch_ = 0;
  bool depth_pend_ = false;
  bool skew_prev_ = false;
  bool framing_ = false;
  SatCounter overwrite_, skew_, wbeat_, read_, collision_, error_;
};

}  // namespace hist

#endif  // MODEL_CPP_HISTORY_HISTORY_MODEL_HPP_
