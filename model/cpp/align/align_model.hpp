// -----------------------------------------------------------------------------
// align_model — bit-accurate reference for the SPEC.md 7.4 frequency-bin
// alignment network (issue #16).
//
// Mirrors rtl/align/align_pkg.sv and rtl/align/align_collect.sv symbol for
// symbol. The correspondence, which is the thing that must not drift:
//
//     align_pkg.sv / align_collect.sv          this file
//     ----------------------------------------------------------------------
//     algn_geom_t                              algn::Config
//     algn_vec_w / algn_out_data_w             Config::vec_w / out_data_w
//     algn_lane_of_bin / algn_group_of_bin     algn::lane_of_bin / group_of_bin
//     algn_gid_of_group                        algn::gid_of_group
//     algn_port_of / algn_bin_of               algn::port_of / bin_of
//     algn_user_e                              algn::kUser*
//     the reassembly entry                     algn::Model::Entry
//     the identity check                       algn::Model::deliver
//     the retirement rule                      algn::Model::retire
//     the five saturating counters             algn::Model::Counters
//
// WHAT THIS MODEL IS, AND WHAT IT DELIBERATELY IS NOT
// ---------------------------------------------------
// It is FUNCTIONAL, not cycle-accurate, and that is a decision rather than a
// shortcut. The content of an output beat is a pure function of which responses
// reached the collector and what they carried; WHEN they reached it changes only
// how long the beat waited. Modelling the pipeline cycle by cycle would mean
// re-implementing the two architectures' arbitration in C++ — at which point the
// scoreboard would be comparing a model of the crossbar against the crossbar,
// and the omega network against a different model, and SPEC 7.4's whole claim
// (that the two are interchangeable) would be assumed by the test rather than
// checked by it.
//
// So the model is driven by EVENTS the test already knows it caused:
//
//     open(gidx, frame_off, mislabel)   the scheduler allocated an entry
//     deliver(word)                     a routed word reached the collector
//     retire(partial_pass)              the head entry produced a beat
//
// and the test — which owns the history-port model, and therefore decides
// exactly which responses it drops, duplicates or corrupts — replays the same
// events. The beat sequence and every counter are then exact, and the ordering
// requirement is the only one the test has to respect: entries retire in
// allocation order, which is what rtl/align/align_collect.sv's circular buffer
// guarantees and what its `a_align_emit_open` assertion checks.
//
// Header-only. Build contract: g++ 13, -std=c++17 -O3 -Wall -Wextra -Werror,
// -Imodel/cpp.
// -----------------------------------------------------------------------------

#ifndef MODEL_CPP_ALIGN_ALIGN_MODEL_HPP_
#define MODEL_CPP_ALIGN_ALIGN_MODEL_HPP_

#include <cstdint>
#include <deque>
#include <string>
#include <vector>

#include "fxp/fxp.hpp"

namespace algn {

// The SPEC 5 `user` bits of an output beat. Same encoding as align_pkg's
// `algn_user_e`, and the same encoding as the block's sticky fault word.
inline constexpr unsigned kUserMissing   = 1u << 0;
inline constexpr unsigned kUserDuplicate = 1u << 1;
inline constexpr unsigned kUserOrphan    = 1u << 2;
inline constexpr unsigned kUserHist      = 1u << 3;

// history_pkg's response flags, repeated here because a routed word carries
// them and the model has to reproduce the OR that reaches the beat.
inline constexpr unsigned kHistOutOfRange = 1u << 0;
inline constexpr unsigned kHistCollision  = 1u << 1;
inline constexpr unsigned kHistStale      = 1u << 2;

// ---------------------------------------------------------------------------
// Geometry — algn_geom_t
// ---------------------------------------------------------------------------
struct Config {
  unsigned n_ant      = 2;
  unsigned fft_size   = 64;
  unsigned lanes      = 1;
  unsigned frames_max = 4;
  unsigned sample_w   = 16;
  unsigned bin_par    = 2;
  unsigned groups     = 4;

  // Not geometry, but the two things the beat sequence depends on and the test
  // has to agree with the DUT about.
  unsigned net_sel    = 0;   // 0 = crossbar, 1 = omega
  unsigned mux_stages = 2;

  static bool is_pow2(unsigned v) { return v >= 1 && (v & (v - 1)) == 0; }

  bool valid() const {
    return n_ant >= 1 && fft_size >= 4 && is_pow2(fft_size) && lanes >= 1 &&
           is_pow2(lanes) && lanes < fft_size && frames_max >= 2 &&
           is_pow2(frames_max) && sample_w >= 2 && sample_w <= 32 &&
           bin_par >= 2 && is_pow2(bin_par) && bin_par <= fft_size / 2 &&
           groups >= 2 && is_pow2(groups) &&
           (groups_per_frame() % groups) == 0;
  }

  unsigned pair_w() const { return 2 * sample_w; }
  unsigned vec_w() const { return n_ant * pair_w(); }
  unsigned out_data_w() const { return bin_par * vec_w(); }
  unsigned groups_per_frame() const { return fft_size / bin_par; }

  static unsigned w_of(unsigned count) {
    unsigned w = 0;
    while ((1u << w) < count) ++w;
    return w == 0 ? 1u : w;
  }
  unsigned bin_w() const { return w_of(fft_size); }
  unsigned lane_w() const { return w_of(bin_par); }
  unsigned gid_w() const { return w_of(groups); }
  unsigned gidx_w() const { return w_of(groups_per_frame()); }

  std::string describe() const {
    return std::string(net_sel == 1 ? "omega" : "crossbar") + " bin_par=" +
           std::to_string(bin_par) + " groups=" + std::to_string(groups) +
           " n_ant=" + std::to_string(n_ant) + " fft=" + std::to_string(fft_size);
  }
};

// ---------------------------------------------------------------------------
// The mapping — align_pkg's normative section 1 and 2
// ---------------------------------------------------------------------------
inline unsigned lane_of_bin(const Config& c, unsigned bin) {
  return bin % c.bin_par;
}
inline unsigned group_of_bin(const Config& c, unsigned bin) {
  return bin / c.bin_par;
}
inline unsigned gid_of_group(const Config& c, unsigned grp) {
  return grp % c.groups;
}
// The rotating schedule: which history read port beat position `lane` of group
// `grp` is requested on.
inline unsigned port_of(const Config& c, unsigned grp, unsigned lane) {
  return (lane + grp) % c.bin_par;
}
inline unsigned bin_of(const Config& c, unsigned grp, unsigned lane) {
  return grp * c.bin_par + lane;
}

// ---------------------------------------------------------------------------
// A routed word: exactly what align_pkg's "routed word" carries.
// ---------------------------------------------------------------------------
struct Word {
  std::vector<fxp::Complex> vec;   // n_ant samples, antenna 0 first
  unsigned      bin       = 0;
  unsigned      frame_off = 0;
  std::uint32_t frame_id  = 0;
  unsigned      flags     = 0;     // history_pkg response flags
};

// How the collector classified a delivered word. Returned by deliver() so the
// test can check the classification cycle by cycle as well as in aggregate.
enum class Verdict { kWritten, kDuplicate, kOrphan };

// ORDER WITHIN A CYCLE IS PART OF THE CONTRACT. When several responses reach an
// entry in the same cycle and the entry has not yet fixed its absolute frame
// number, the RTL takes the LOWEST-NUMBERED LANE's as the reference and rejects
// the others if they disagree (rtl/align/align_collect.sv, "The absolute-frame
// test"). A test that fed this model in PORT order instead of lane order would
// therefore see a different reference and a different verdict, so the caller
// must deliver a cycle's words sorted by lane. `lane_of_bin` is the sort key.

// ---------------------------------------------------------------------------
// An output beat, in the beamformer's input layout.
// ---------------------------------------------------------------------------
struct Beat {
  // bin_par * n_ant samples, index (lane * n_ant + antenna) — bin-major,
  // antenna-minor, exactly beamformer_pkg::bf_in_data_w's ordering.
  std::vector<fxp::Complex> data;
  bool          sof  = false;
  bool          eof  = false;
  unsigned      seq  = 0;
  unsigned      user = 0;

  bool operator==(const Beat& o) const {
    return data == o.data && sof == o.sof && eof == o.eof && seq == o.seq &&
           user == o.user;
  }
  bool operator!=(const Beat& o) const { return !(*this == o); }
};

// ---------------------------------------------------------------------------
// Saturating counters, mirroring perf_counter with SATURATE = 1.
// ---------------------------------------------------------------------------
class SatCounter {
 public:
  void bump(std::uint32_t by = 1) {
    const std::uint64_t next = static_cast<std::uint64_t>(v_) + by;
    v_ = next > 0xFFFFFFFFULL ? 0xFFFFFFFFU : static_cast<std::uint32_t>(next);
  }
  void clear() { v_ = 0; }
  std::uint32_t value() const { return v_; }

 private:
  std::uint32_t v_ = 0;
};

// ---------------------------------------------------------------------------
// The model
// ---------------------------------------------------------------------------
class Model {
 public:
  struct Counters {
    std::uint32_t beats    = 0;
    std::uint32_t missing  = 0;
    std::uint32_t dup      = 0;
    std::uint32_t orphan   = 0;
    std::uint32_t timeout  = 0;
  };

  explicit Model(const Config& c) : cfg_(c) { reset(); }

  const Config& config() const { return cfg_; }

  void reset() {
    open_.clear();
    beats_.clear();
    seq_ = 0;
    fault_ = 0;
    c_beats_.clear();
    c_missing_.clear();
    c_dup_.clear();
    c_orphan_.clear();
    c_timeout_.clear();
  }

  void clear_counters() {
    c_beats_.clear();
    c_missing_.clear();
    c_dup_.clear();
    c_orphan_.clear();
    c_timeout_.clear();
  }
  void clear_sticky() { fault_ = 0; }

  // --- the scheduler allocated an entry for group `gidx` of frame offset
  //     `frame_off`. `mislabel` reproduces align_net's SPEC 9 tag-collision
  //     injection: the entry is opened for the NEXT group index instead.
  void open(unsigned gidx, unsigned frame_off, bool mislabel) {
    Entry e;
    e.gid       = gid_of_group(cfg_, gidx);
    e.gidx      = mislabel ? ((gidx + 1) % cfg_.groups_per_frame()) : gidx;
    e.frame_off = frame_off;
    e.sof       = (gidx == 0);
    e.eof       = (gidx == cfg_.groups_per_frame() - 1);
    e.present.assign(cfg_.bin_par, false);
    e.store.assign(cfg_.bin_par, std::vector<fxp::Complex>(cfg_.n_ant));
    open_.push_back(std::move(e));
  }

  std::size_t open_groups() const { return open_.size(); }

  // --- a routed word reached the collector on the lane its bin names.
  //
  // THE ENTRY IS FOUND BY SEARCHING THE OPEN LIST FROM THE BACK, and that is not
  // an implementation detail — it is what keeps the model aligned with a block
  // whose output is elastic. The RTL frees a reassembly entry when the beat is
  // PUSHED into the output buffer; the test only learns about the beat when it
  // is POPPED, up to OUT_DEPTH cycles later, and calls retire() then. So the
  // model can be holding an entry the RTL has already reused. Taking the NEWEST
  // open entry with the matching index reproduces exactly what the RTL sees: the
  // one currently allocated at that index. A response for the older occupant
  // then fails the key check in both, which is the correct answer — it IS an
  // orphan by then.
  Verdict deliver(const Word& w) {
    const unsigned lane = lane_of_bin(cfg_, w.bin);
    const unsigned grp  = group_of_bin(cfg_, w.bin);
    const unsigned gid  = gid_of_group(cfg_, grp);

    Entry* live = nullptr;
    for (auto it = open_.rbegin(); it != open_.rend(); ++it) {
      if (it->gid == gid) {
        live = &(*it);
        break;
      }
    }

    const bool fid_ok = live && (!live->fid_set || live->fid == w.frame_id);
    const bool key_ok = live && fid_ok && (live->gidx == grp) &&
                        (live->frame_off == w.frame_off);

    if (!key_ok) {
      c_orphan_.bump();
      fault_ |= kUserOrphan;
      if (live) live->orphan = true;   // attributable to a real beat
      return Verdict::kOrphan;
    }
    if (live->present[lane]) {
      c_dup_.bump();
      fault_ |= kUserDuplicate;
      live->dup = true;
      return Verdict::kDuplicate;
    }
    live->present[lane] = true;
    live->store[lane]   = w.vec;
    live->hflags |= w.flags;
    if (!live->fid_set) {
      live->fid_set = true;
      live->fid     = w.frame_id;
    }
    return Verdict::kWritten;
  }

  // Is the oldest open entry complete?
  bool head_complete() const {
    if (open_.empty()) return false;
    for (bool p : open_.front().present) {
      if (!p) return false;
    }
    return true;
  }

  // --- the head entry produced a beat. Returns it, exactly as the RTL's
  //     `beat_data` / `beat_user` / `seq_q` build it.
  Beat retire(bool partial_pass) {
    Beat b;
    if (open_.empty()) return b;
    const Entry e = open_.front();
    open_.pop_front();

    unsigned absent = 0;
    b.data.assign(static_cast<std::size_t>(cfg_.bin_par) * cfg_.n_ant,
                  fxp::Complex{});
    for (unsigned l = 0; l < cfg_.bin_par; ++l) {
      if (!e.present[l]) ++absent;
      if (e.present[l] || partial_pass) {
        for (unsigned a = 0; a < cfg_.n_ant; ++a) {
          b.data[static_cast<std::size_t>(l) * cfg_.n_ant + a] =
              a < e.store[l].size() ? e.store[l][a] : fxp::Complex{};
        }
      }
    }

    b.sof  = e.sof;
    b.eof  = e.eof;
    b.seq  = seq_;
    b.user = (absent != 0 ? kUserMissing : 0u) |
             (e.dup ? kUserDuplicate : 0u) |
             (e.orphan ? kUserOrphan : 0u) |
             (e.hflags != 0 ? kUserHist : 0u);

    seq_ = (seq_ + 1) & 0xFFFFU;
    c_beats_.bump();
    if (absent != 0) {
      c_missing_.bump(absent);
      c_timeout_.bump();
      fault_ |= kUserMissing;
    }
    if (e.hflags != 0) fault_ |= kUserHist;

    beats_.push_back(b);
    return b;
  }

  Counters counters() const {
    return Counters{c_beats_.value(), c_missing_.value(), c_dup_.value(),
                    c_orphan_.value(), c_timeout_.value()};
  }
  unsigned fault() const { return fault_; }

  const std::deque<Beat>& beats() const { return beats_; }

 private:
  struct Entry {
    unsigned                               gid       = 0;
    unsigned                               gidx      = 0;
    unsigned                               frame_off = 0;
    bool                                   sof       = false;
    bool                                   eof       = false;
    std::vector<bool>                      present;
    std::vector<std::vector<fxp::Complex>> store;
    bool                                   dup       = false;
    bool                                   orphan    = false;
    unsigned                               hflags    = 0;
    bool                                   fid_set   = false;
    std::uint32_t                          fid       = 0;
  };

  Config             cfg_;
  std::deque<Entry>  open_;
  std::deque<Beat>   beats_;
  unsigned           seq_   = 0;
  unsigned           fault_ = 0;

  SatCounter c_beats_, c_missing_, c_dup_, c_orphan_, c_timeout_;
};

}  // namespace algn

#endif  // MODEL_CPP_ALIGN_ALIGN_MODEL_HPP_
