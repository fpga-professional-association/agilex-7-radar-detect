// -----------------------------------------------------------------------------
// fft_ref.hpp — bit-exact C++ reference for rtl/fft/ (SPEC.md 7.2, 12.4).
//
// SPEC 12.4 requires a bit-accurate C++ model, validated against independent
// Python/NumPy vectors, before it is used as the RTL oracle. This header is that
// model for the streaming FFT. It is a line-for-line mirror of
// rtl/fft/fft_pkg.sv and of the four modules that implement it; read them
// together, and change them together.
//
//   SystemVerilog                       C++
//   ----------------------------------  ---------------------------------------
//   fft_pkg::fft_bitrev                 fft::bitrev
//   fft_pkg::fft_r22_tw_exp             fft::r22_tw_exp
//   fft_pkg::fft_r22_tw / fft_dit_tw    fft::r22_tw / fft::dit_tw
//   fft_pkg::fft_shift                  fft::shift_of
//   fft_pkg::fft_*_latency              fft::*_latency
//   fft_bf2 (BF2I / BF2II)              fft::Engine::butterfly_stage
//   fft_radix22_stage's multiplier      fft::Engine::twiddle_stage
//   fft_dit_merge                       fft::Engine::merge
//   fft_reorder                         fft::Engine::reorder
//
// It contains NO arithmetic of its own. Every quantisation is a call into
// fxp.hpp — the same package the RTL calls — and every coefficient comes from
// fft_twiddle_table.hpp, the committed table the RTL's ROMs are built from. So
// "the model and the RTL agree" is a property of two descriptions sharing one
// definition rather than of two implementations happening to match.
//
// -----------------------------------------------------------------------------
// Streams versus arrays
// -----------------------------------------------------------------------------
// The RTL is a serial delay-feedback pipeline; this model works on arrays. That
// is a difference of MECHANISM, not of arithmetic, and the mapping is exact:
//
//   * position p in the model's lane array IS the sample's position in the
//     stream at that point in the pipeline. Each SDF sub-stage delays its output
//     stream by D positions, and the model's in-place array update is the same
//     permutation with the delay removed;
//   * a butterfly at sub-stage s works on blocks of L = 2^(n-s): the first L/2
//     entries of a block are the samples the hardware has in its feedback and
//     the second L/2 are the samples arriving, which is exactly what the phase
//     bit p[log2(L/2)] selects;
//   * BF2II's trivial -j is selected by the block's parity, which is the bit
//     p[log2(L)] the hardware reads.
//
// Nothing here reasons about latency. The model computes one frame; the latency
// arithmetic it exports exists so the test can size its expectations and so the
// RTL's own alignment assertions have a number to be checked against.
//
// Header-only. Build contract: g++ 13, -std=c++17 -O3 -Wall -Wextra -Werror.
// -----------------------------------------------------------------------------
#ifndef MODEL_CPP_FFT_FFT_REF_HPP_
#define MODEL_CPP_FFT_FFT_REF_HPP_

#include <cstdint>
#include <vector>

#include "fft/fft_twiddle_table.hpp"
#include "fxp/fxp.hpp"

namespace fft {

// ---------------------------------------------------------------------------
// Geometry (fft_pkg "Geometry")
// ---------------------------------------------------------------------------

// Deepest butterfly chain the twiddle table can serve: log2(kTwN).
inline constexpr unsigned kMaxStages = 10;
static_assert(1u << kMaxStages == kTwN, "kMaxStages must be log2(kTwN)");

inline constexpr bool is_pow2(unsigned v) {
  return v != 0 && (v & (v - 1)) == 0;
}

// Exact log2 of a power of two. Every argument is checked to be one.
inline constexpr unsigned log2_exact(unsigned v) {
  unsigned r = 0;
  while ((1u << r) < v) ++r;
  return r;
}

inline constexpr unsigned lane_len(unsigned n_fft, unsigned spc) {
  return n_fft / spc;
}
inline constexpr unsigned lane_stages(unsigned n_fft, unsigned spc) {
  return log2_exact(lane_len(n_fft, spc));
}
inline constexpr unsigned merge_levels(unsigned spc) { return log2_exact(spc); }
inline constexpr unsigned total_stages(unsigned n_fft) {
  return log2_exact(n_fft);
}

// Reversal of the low `w` bits (fft_pkg::fft_bitrev).
inline constexpr unsigned bitrev(unsigned v, unsigned w) {
  unsigned r = 0;
  for (unsigned i = 0; i < w; ++i) {
    if ((v >> i) & 1u) r |= 1u << (w - 1 - i);
  }
  return r;
}

// ---------------------------------------------------------------------------
// Radix-2^2 structure (fft_pkg section 2)
// ---------------------------------------------------------------------------

inline constexpr unsigned bf_delay(unsigned n, unsigned s) {
  return 1u << (n - 1 - s);
}
inline constexpr bool bf_is_bf2ii(unsigned s) { return (s % 2) == 1; }
inline constexpr bool stage_has_twiddle(unsigned n, unsigned s) {
  return bf_is_bf2ii(s) && s + 1 < n;
}
inline constexpr unsigned lane_mults(unsigned n) {
  return n < 1 ? 0 : (n - 1) / 2;
}
inline constexpr unsigned group_l2l(unsigned n, unsigned s) {
  return n - s + 1;
}

// ---------------------------------------------------------------------------
// Twiddle addressing (fft_pkg "Twiddle addressing")
// ---------------------------------------------------------------------------

inline constexpr unsigned r22_tw_exp(unsigned l2l, unsigned p) {
  const unsigned q = p & ((1u << l2l) - 1u);
  const unsigned k1 = (q >> (l2l - 1)) & 1u;
  const unsigned k2 = (q >> (l2l - 2)) & 1u;
  const unsigned n3 = q & ((1u << (l2l - 2)) - 1u);
  return n3 * (k1 + 2u * k2);
}

inline fxp::Complex tw(unsigned l2l, unsigned e) {
  return fxp::Complex::from_packed(kTw[e << (kMaxStages - l2l)]);
}

inline fxp::Complex r22_tw(unsigned l2l, unsigned p) {
  return tw(l2l, r22_tw_exp(l2l, p));
}

inline constexpr unsigned dit_tw_exp(unsigned n_lane, unsigned level,
                                     unsigned j) {
  const unsigned w = n_lane + level;
  return bitrev(j & ((1u << w) - 1u), w);
}

inline fxp::Complex dit_tw(unsigned n_lane, unsigned level, unsigned j) {
  return tw(n_lane + level + 1, dit_tw_exp(n_lane, level, j));
}

// ---------------------------------------------------------------------------
// Scaling schedule (fft_pkg section 4)
// ---------------------------------------------------------------------------

inline constexpr unsigned kSchedAll = 0xFFFFFFFFu;

inline constexpr unsigned shift_of(unsigned sched, unsigned g) {
  return (sched >> g) & 1u;
}

// ---------------------------------------------------------------------------
// Latency (fft_pkg "Latency accounting")
// ---------------------------------------------------------------------------

inline constexpr unsigned tw_rom_latency(unsigned out_reg) {
  return 1 + out_reg;
}
inline constexpr unsigned mult_latency(unsigned rom_lat, unsigned tw_pipe) {
  return rom_lat + tw_pipe;
}
inline constexpr unsigned lane_pos_offset(unsigned n_lane) {
  return (1u << n_lane) - 1u;
}
inline constexpr unsigned lane_time_latency(unsigned n_lane, unsigned rom_lat,
                                            unsigned tw_pipe) {
  return n_lane + lane_mults(n_lane) * mult_latency(rom_lat, tw_pipe);
}
inline constexpr unsigned merge_latency(unsigned rom_lat, unsigned tw_pipe) {
  return mult_latency(rom_lat, tw_pipe) + 1;
}
inline constexpr unsigned core_latency(unsigned n_fft, unsigned spc,
                                       unsigned rom_lat, unsigned tw_pipe) {
  const unsigned n_lane = lane_stages(n_fft, spc);
  return lane_pos_offset(n_lane) + lane_time_latency(n_lane, rom_lat, tw_pipe) +
         merge_levels(spc) * merge_latency(rom_lat, tw_pipe);
}
inline constexpr unsigned reorder_latency(unsigned n_fft, unsigned spc) {
  return lane_len(n_fft, spc) + 1;
}
inline constexpr unsigned total_latency(unsigned n_fft, unsigned spc,
                                        unsigned rom_lat, unsigned tw_pipe,
                                        bool reorder) {
  return core_latency(n_fft, spc, rom_lat, tw_pipe) +
         (reorder ? reorder_latency(n_fft, spc) : 0);
}

// ---------------------------------------------------------------------------
// Configuration and result
// ---------------------------------------------------------------------------

struct Config {
  unsigned n_fft = 64;
  unsigned spc = 2;
  unsigned scale_sched = kSchedAll;
  bool reorder = true;

  // Only used by the latency helpers; the arithmetic does not depend on them.
  unsigned tw_rom_out_reg = 1;
  unsigned tw_pipe = 4;

  unsigned lane() const { return lane_len(n_fft, spc); }
  unsigned n_lane() const { return lane_stages(n_fft, spc); }
  unsigned stages() const { return total_stages(n_fft); }
  unsigned latency() const {
    return total_latency(n_fft, spc, tw_rom_latency(tw_rom_out_reg), tw_pipe,
                         reorder);
  }
  bool valid() const {
    return is_pow2(n_fft) && is_pow2(spc) && n_fft >= 8 && n_fft <= kTwN &&
           lane_len(n_fft, spc) >= 4 && (spc == 1 || spc == 2);
  }
};

struct Result {
  // n_fft samples in BEAT ORDER: beat b, slot p is out[b * spc + p]. The beat
  // layout is fft_core's, restated here because it is normative for the vectors
  // and for the test:
  //   reorder = 0   beat j holds X[bitrev(j)] and X[bitrev(j) + n_fft/2]
  //   reorder = 1   beat j holds X[j]         and X[j + n_fft/2]
  std::vector<fxp::Complex> out;

  // One entry per butterfly sub-stage of the whole transform, in the same order
  // the scaling schedule indexes: lane sub-stages 0..n_lane-1, then merge level
  // L at index n_lane + L. The OR over the frame of every quantisation that
  // belongs to that sub-stage — which is what fft_core's sticky collectors hold.
  std::vector<fxp::Flags> stage_flags;

  // Convenience: the whole transform in NATURAL BIN ORDER, bin k at index k,
  // independent of `reorder`. The test uses it to compare a reordered and a
  // non-reordered instance against each other and against NumPy.
  std::vector<fxp::Complex> bins;
};

// ---------------------------------------------------------------------------
// The transform
// ---------------------------------------------------------------------------

class Engine {
 public:
  explicit Engine(const Config& cfg) : cfg_(cfg) {}

  Result run(const std::vector<fxp::Complex>& in) const {
    const unsigned n = cfg_.n_fft;
    const unsigned p = cfg_.spc;
    const unsigned m = lane_len(n, p);
    const unsigned nl = lane_stages(n, p);

    Result r;
    r.stage_flags.assign(total_stages(n), fxp::flags_none());
    r.out.assign(n, fxp::Complex{});
    r.bins.assign(n, fxp::Complex{});

    // ---- decimation in time: lane q is the subsequence x[p*t + q] ----------
    std::vector<std::vector<fxp::Complex>> lane(p,
                                                std::vector<fxp::Complex>(m));
    for (unsigned t = 0; t < m; ++t) {
      for (unsigned q = 0; q < p; ++q) lane[q][t] = in[t * p + q];
    }

    // ---- each lane: an m-point radix-2^2 DIF SDF path ----------------------
    for (unsigned q = 0; q < p; ++q) {
      for (unsigned s = 0; s < nl; ++s) {
        butterfly_stage(&lane[q], nl, s, &r.stage_flags[s]);
        if (stage_has_twiddle(nl, s)) {
          twiddle_stage(&lane[q], nl, s, &r.stage_flags[s]);
        }
      }
    }

    // ---- decimation-in-time merge across the lanes -------------------------
    // Beat j holds, per merge output, X[m_j] and X[m_j + n/2] with
    // m_j = bitrev(j). For p = 1 there is nothing to merge and the lane's own
    // bit-reversed output is the answer.
    std::vector<fxp::Complex> beats(n);
    if (p == 1) {
      for (unsigned j = 0; j < m; ++j) beats[j] = lane[0][j];
    } else {
      merge(lane[0], lane[1], nl, cfg_.scale_sched, &beats,
            &r.stage_flags[nl]);
    }

    // ---- natural bin order, for the caller that wants bins ----------------
    for (unsigned j = 0; j < m; ++j) {
      const unsigned mj = bitrev(j, nl);
      for (unsigned q = 0; q < p; ++q) {
        r.bins[mj + q * (n / p)] = beats[j * p + q];
      }
    }

    // ---- optional reorder --------------------------------------------------
    if (cfg_.reorder) {
      for (unsigned j = 0; j < m; ++j) {
        const unsigned src = bitrev(j, nl);
        for (unsigned q = 0; q < p; ++q) r.out[j * p + q] = beats[src * p + q];
      }
    } else {
      r.out = beats;
    }
    return r;
  }

 private:
  Config cfg_;

  // Quantise one component: round once, then saturate, and take the flags of
  // the ROUNDED value. fxp_pkg's order, and fft_bf2's.
  static fxp::i16 quant(fxp::wide_t v, unsigned sh, fxp::Flags* acc) {
    *acc = fxp::flags_merge(
        *acc, fxp::sat_flags(fxp::round(v, sh), fxp::kSampleW));
    return static_cast<fxp::i16>(fxp::round_sat(v, sh, fxp::kSampleW));
  }

  // -j * (re + j*im) = im - j*re, with a saturating negate (fft_bf2).
  static fxp::Complex neg_j(fxp::Complex c, fxp::Flags* acc) {
    *acc = fxp::flags_merge(
        *acc, fxp::sat_flags(fxp::neg_wrap(static_cast<fxp::wide_t>(c.re)),
                             fxp::kSampleW));
    fxp::Complex o;
    o.re = c.im;
    o.im = static_cast<fxp::i16>(
        fxp::neg_sat(static_cast<fxp::wide_t>(c.re), fxp::kSampleW));
    return o;
  }

  // One BF2I / BF2II sub-stage, in place (fft_bf2).
  void butterfly_stage(std::vector<fxp::Complex>* v, unsigned n_lane,
                       unsigned s, fxp::Flags* acc) const {
    const unsigned l = 1u << (n_lane - s);
    const unsigned half = l / 2;
    const unsigned sh = shift_of(cfg_.scale_sched, s);
    const bool bf2ii = bf_is_bf2ii(s);

    for (unsigned b = 0; b < v->size(); b += l) {
      // BF2II's trivial twiddle is selected by the block's parity, which is the
      // position bit above the phase bit — see fft_bf2's k1.
      const bool k1 = bf2ii && (((b / l) & 1u) != 0u);
      for (unsigned i = 0; i < half; ++i) {
        const fxp::Complex a = (*v)[b + i];
        fxp::Complex t = (*v)[b + half + i];
        if (k1) t = neg_j(t, acc);

        const fxp::wide_t sre = static_cast<fxp::wide_t>(a.re) + t.re;
        const fxp::wide_t sim = static_cast<fxp::wide_t>(a.im) + t.im;
        const fxp::wide_t dre = static_cast<fxp::wide_t>(a.re) - t.re;
        const fxp::wide_t dim = static_cast<fxp::wide_t>(a.im) - t.im;

        fxp::Complex lo, hi;
        lo.re = quant(sre, sh, acc);
        lo.im = quant(sim, sh, acc);
        hi.re = quant(dre, sh, acc);
        hi.im = quant(dim, sh, acc);

        (*v)[b + i] = lo;
        (*v)[b + half + i] = hi;
      }
    }
  }

  // The twiddle multiplier that closes the group ending at sub-stage s.
  void twiddle_stage(std::vector<fxp::Complex>* v, unsigned n_lane, unsigned s,
                     fxp::Flags* acc) const {
    const unsigned l2l = group_l2l(n_lane, s);
    for (unsigned i = 0; i < v->size(); ++i) {
      const fxp::Complex w = r22_tw(l2l, i);
      *acc = fxp::flags_merge(*acc, fxp::cmul_q15_re_flags((*v)[i], w));
      *acc = fxp::flags_merge(*acc, fxp::cmul_q15_im_flags((*v)[i], w));
      (*v)[i] = fxp::cmul_q15((*v)[i], w);
    }
  }

  // The radix-2 decimation-in-time merge (fft_dit_merge).
  static void merge(const std::vector<fxp::Complex>& e,
                    const std::vector<fxp::Complex>& o, unsigned n_lane,
                    unsigned sched, std::vector<fxp::Complex>* beats,
                    fxp::Flags* acc) {
    const unsigned m = static_cast<unsigned>(e.size());
    const unsigned sh = shift_of(sched, n_lane);
    for (unsigned j = 0; j < m; ++j) {
      const fxp::Complex w = dit_tw(n_lane, 0, j);
      *acc = fxp::flags_merge(*acc, fxp::cmul_q15_re_flags(o[j], w));
      *acc = fxp::flags_merge(*acc, fxp::cmul_q15_im_flags(o[j], w));
      const fxp::Complex t = fxp::cmul_q15(o[j], w);

      const fxp::wide_t sre = static_cast<fxp::wide_t>(e[j].re) + t.re;
      const fxp::wide_t sim = static_cast<fxp::wide_t>(e[j].im) + t.im;
      const fxp::wide_t dre = static_cast<fxp::wide_t>(e[j].re) - t.re;
      const fxp::wide_t dim = static_cast<fxp::wide_t>(e[j].im) - t.im;

      fxp::Complex lo, hi;
      lo.re = quant(sre, sh, acc);
      lo.im = quant(sim, sh, acc);
      hi.re = quant(dre, sh, acc);
      hi.im = quant(dim, sh, acc);

      (*beats)[j * 2 + 0] = lo;
      (*beats)[j * 2 + 1] = hi;
    }
  }
};

inline Result transform(const Config& cfg,
                        const std::vector<fxp::Complex>& in) {
  return Engine(cfg).run(in);
}

}  // namespace fft

#endif  // MODEL_CPP_FFT_FFT_REF_HPP_
