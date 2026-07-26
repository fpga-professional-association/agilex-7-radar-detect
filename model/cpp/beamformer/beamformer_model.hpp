// -----------------------------------------------------------------------------
// beamformer_model.hpp — bit-accurate C++ reference model for the beamforming
// matrix (SPEC.md 6, 7.5, 12.4; issue #12).
//
//     Y[b][f] = sum over antennas a of X[a][f] * W[b][a]
//
// The RTL oracle for rtl/beamformer/bf_dot.sv and rtl/beamformer/beamformer.sv.
// Header-only, depends only on model/cpp/fxp/, and every arithmetic operation is
// a call into that library — there is no second rounding rule here, exactly as
// there is none in the RTL (rtl/packages/fxp_pkg.sv, THE RULE).
//
// -----------------------------------------------------------------------------
// The numerical contract this model implements, restated so it can be checked
// -----------------------------------------------------------------------------
//   1. Each antenna's complex product is formed EXACTLY, at full precision, by
//      fxp::cmul_q15_re_raw / _im_raw — the same functions rtl/packages/fxp_pkg.sv
//      exports and rtl/common/complex_multiplier.sv is asserted against on every
//      cycle.
//   2. The N_ANT products are summed with no intermediate rounding and NO
//      INTERMEDIATE SATURATION. fxp::wide_t is 64 bits; the sum of 32 exact
//      33-bit values needs at most 38, so the C++ accumulation cannot wrap for
//      any geometry beamformer_pkg permits. The RTL accumulates in
//      bf_acc_w(N_ANT) bits, which is exactly wide enough for the same reason.
//      The two are therefore the same integer, not merely close.
//   3. The sum is rounded and saturated ONCE, to Q1.15, by fxp::round_sat at
//      fxp::kProdShift into fxp::kSampleW, with direction-resolved flags taken
//      AFTER the round and BEFORE the saturate — the order fxp_pkg fixes and the
//      only order in which a round-induced overflow is reportable.
//
// Point 2 has a consequence worth stating because the RTL leans on it: integer
// addition is associative and nothing clamps in between, so the ORDER of the
// accumulation is irrelevant. This model sums antenna 0 upward; the RTL sums
// through a balanced binary tree whose register stride is a parameter. All three
// orderings produce the same integer, which is what makes ADD_REG_EVERY a pure
// cost parameter and what lets one expectation list serve every DUT.
//
// -----------------------------------------------------------------------------
// What this model does NOT have: state
// -----------------------------------------------------------------------------
// A beamformer has no sample history. Y[b][f] depends on the antenna vector of
// bin f and on the weights, and on nothing that came before. So `step()` is a
// pure function of (beat, weights) and the only mutable state in the class is
// the weight array — which is why the double-buffering model here is a single
// `swap_weights()` call rather than the two-set, per-tap-skew arrangement
// model/cpp/pfb/pfb_model.hpp needs for a systolic cascade. A weight swap at a
// frame boundary is instantaneous in the RTL for the same reason: every
// multiplier of a beat sees the same bank on the same cycle.
//
// -----------------------------------------------------------------------------
// The output-beat convention (mirrors rtl/beamformer/beamformer.sv section 4)
// -----------------------------------------------------------------------------
// One input beat yields BEAM_MUX = N_BEAMS / BEAM_PAR output beats. Output beat
// `g` carries beams [g*BEAM_PAR, (g+1)*BEAM_PAR) for all BIN_PAR bins,
// beam-major and bin-minor, with
//
//     seq_out = (seq_in << clog2(BEAM_MUX)) | g
//     user    = g
//     sof     = sof_in && (g == 0)
//     eof     = eof_in && (g == BEAM_MUX-1)
//
// `split_beat()` performs that split so the test does not reimplement it.
// -----------------------------------------------------------------------------
#ifndef MODEL_BEAMFORMER_BEAMFORMER_MODEL_HPP_
#define MODEL_BEAMFORMER_BEAMFORMER_MODEL_HPP_

#include <cstddef>
#include <cstdint>
#include <vector>

#include "fxp/fxp.hpp"

namespace bf {

using fxp::Complex;
using fxp::Flags;
using fxp::wide_t;

// ---------------------------------------------------------------------------
// Geometry and latency arithmetic — the C++ twin of rtl/beamformer/beamformer_pkg.sv
//
// Every function here is checked against the RTL's own echo of the same value in
// sim/tests/test_beamformer.cpp before any comparison runs, so a drift between
// the two is a named configuration failure rather than a silently wrong
// expectation.
// ---------------------------------------------------------------------------

// ceil(log2 n), matching SystemVerilog $clog2 (0 and 1 both give 0).
inline unsigned tree_levels(unsigned n) {
  if (n <= 1) return 0;
  unsigned b = 0;
  unsigned v = n - 1u;
  while (v != 0u) {
    ++b;
    v >>= 1;
  }
  return b;
}

inline unsigned tree_leaves(unsigned n) {
  return (n <= 1) ? 1u : (1u << tree_levels(n));
}

// bf_acc_w: FXP_PROD_W + ceil(log2(2*N_ANT)).
inline unsigned acc_w(unsigned n_ant) {
  return fxp::mac_q15_acc_w(2u * n_ant);
}

// bf_tree_regs: a register after every `reg_every` levels, and always after the
// last one, hence ceil(levels / reg_every).
inline unsigned tree_regs(unsigned n_ant, unsigned reg_every) {
  const unsigned lv = tree_levels(n_ant);
  const unsigned re = (reg_every == 0u) ? 1u : reg_every;
  return (lv + re - 1u) / re;
}

// bf_dot_lat: the multiplier, the registered tree levels, the output register.
inline unsigned dot_lat(unsigned n_ant, unsigned mult_pipe, unsigned reg_every) {
  return mult_pipe + tree_regs(n_ant, reg_every) + 1u;
}

// bf_lat_cycles: the block's input hold register plus the dot product.
inline unsigned lat_cycles(unsigned n_ant, unsigned mult_pipe,
                           unsigned reg_every) {
  return 1u + dot_lat(n_ant, mult_pipe, reg_every);
}

inline unsigned beam_mux(unsigned n_beams, unsigned beam_par) {
  return (beam_par == 0u) ? 1u : (n_beams / beam_par);
}

inline unsigned seq_shift(unsigned mux) {
  return (mux <= 1u) ? 0u : tree_levels(mux);
}

// bf_weight_index: beam-major, antenna-minor. THE weight address contract,
// shared by the register plane, the RTL and this model.
inline std::size_t weight_index(unsigned n_ant, unsigned beam, unsigned ant) {
  return static_cast<std::size_t>(beam) * n_ant + ant;
}

// ---------------------------------------------------------------------------
// The dot product
// ---------------------------------------------------------------------------

struct DotResult {
  Complex y;          // Q1.15, rounded once and saturated
  Flags f_re;         // direction-resolved saturation flags
  Flags f_im;
  wide_t acc_re = 0;  // the exact accumulator, before any quantisation
  wide_t acc_im = 0;

  Flags merged() const { return fxp::flags_merge(f_re, f_im); }
  bool saturating() const { return merged().any(); }
};

// Y = sum_a x[a] * w[a]. `x` and `w` are n_ant elements each.
//
// The accumulation is a plain int64 sum of exact products (point 2 of the
// header). No fxp::add_sat here, deliberately: a saturating add would clamp
// inside the accumulation, which would make the result depend on the summation
// order and would stop matching an adder tree.
inline DotResult dot(const Complex* x, const Complex* w, unsigned n_ant) {
  DotResult r;
  wide_t are = 0;
  wide_t aim = 0;
  for (unsigned a = 0; a < n_ant; ++a) {
    are = fxp::add_wrap(are, fxp::cmul_q15_re_raw(x[a], w[a]));
    aim = fxp::add_wrap(aim, fxp::cmul_q15_im_raw(x[a], w[a]));
  }
  r.acc_re = are;
  r.acc_im = aim;
  r.y.re = static_cast<fxp::i16>(
      fxp::round_sat(are, fxp::kProdShift, fxp::kSampleW));
  r.y.im = static_cast<fxp::i16>(
      fxp::round_sat(aim, fxp::kProdShift, fxp::kSampleW));
  r.f_re = fxp::sat_flags(fxp::round(are, fxp::kProdShift), fxp::kSampleW);
  r.f_im = fxp::sat_flags(fxp::round(aim, fxp::kProdShift), fxp::kSampleW);
  return r;
}

inline DotResult dot(const std::vector<Complex>& x,
                     const std::vector<Complex>& w) {
  return dot(x.data(), w.data(), static_cast<unsigned>(x.size()));
}

// ---------------------------------------------------------------------------
// An independent, non-fixed-point evaluation of the same sum.
//
// SPEC 12.4's standing problem: an oracle that agrees only with itself is not an
// oracle. `dot()` and the RTL share fxp_pkg's definitions by design — that is
// what makes them bit-exact — so agreement between them proves the WIRING and
// not the ARITHMETIC. This function evaluates the same mathematical expression
// in double precision, through no shared code at all, and the test requires the
// two to agree to within a few LSB on every non-saturating beat.
//
// It produces no expected value and cannot: it is a different number system.
// What it catches is the one class of error a self-consistent bit-exact model
// cannot — a dot product that agrees with itself and is not a dot product. The
// precedent is issue #11's NumPy FFT cross-check (DECISIONS.md, issue #11
// decision 10), moved into C++ here because this issue ships no NumPy generator.
// ---------------------------------------------------------------------------
struct DotFloat {
  double re = 0.0;
  double im = 0.0;
};

inline DotFloat dot_float(const Complex* x, const Complex* w, unsigned n_ant) {
  DotFloat r;
  for (unsigned a = 0; a < n_ant; ++a) {
    const double xr = static_cast<double>(x[a].re);
    const double xi = static_cast<double>(x[a].im);
    const double wr = static_cast<double>(w[a].re);
    const double wi = static_cast<double>(w[a].im);
    r.re += xr * wr - xi * wi;
    r.im += xr * wi + xi * wr;
  }
  // The products are Q2.30 and the output is Q1.15, so the scale between the
  // accumulator and the sample is 2^kProdShift.
  const double scale = static_cast<double>(1u << fxp::kProdShift);
  r.re /= scale;
  r.im /= scale;
  return r;
}

// ---------------------------------------------------------------------------
// The matrix
// ---------------------------------------------------------------------------

// One input beat's worth of results: y[beam][bin].
struct BeamBeat {
  std::vector<std::vector<Complex>> y;
  std::vector<std::vector<Flags>> f_re;
  std::vector<std::vector<Flags>> f_im;
  std::vector<std::vector<wide_t>> acc_re;
  std::vector<std::vector<wide_t>> acc_im;
  bool saturating = false;

  unsigned n_beams() const { return static_cast<unsigned>(y.size()); }
  unsigned n_bins() const { return y.empty() ? 0u : static_cast<unsigned>(y[0].size()); }
};

// One output beat as the RTL emits it: BEAM_PAR beams x BIN_PAR bins of one
// group, beam-major and bin-minor, with the metadata convention of
// rtl/beamformer/beamformer.sv section 4.
struct OutBeatExp {
  std::vector<Complex> data;   // [k*BIN_PAR + j]
  std::uint32_t seq = 0;
  std::uint32_t user = 0;      // the beam group index
  bool sof = false;
  bool eof = false;
  std::uint32_t stream_id = 0;
  bool saturating = false;
};

class BeamformerModel {
 public:
  BeamformerModel() = default;

  // `w` is n_beams*n_ant weights, beam-major (weight_index above).
  BeamformerModel(unsigned n_ant, unsigned n_beams, unsigned bin_par,
                  const std::vector<Complex>& w)
      : n_ant_(n_ant), n_beams_(n_beams), bin_par_(bin_par), w_(w) {
    w_.resize(static_cast<std::size_t>(n_beams) * n_ant);
  }

  unsigned n_ant() const { return n_ant_; }
  unsigned n_beams() const { return n_beams_; }
  unsigned bin_par() const { return bin_par_; }
  const std::vector<Complex>& weights() const { return w_; }

  // The model twin of a weight-bank swap. Instantaneous, and that is not a
  // simplification: every dot product of a beat reads the same bank on the same
  // cycle in the RTL too (there is no history to skew it), so the frame after a
  // swap is computed entirely with the new matrix and the frame before it
  // entirely with the old.
  void swap_weights(const std::vector<Complex>& w) {
    w_ = w;
    w_.resize(static_cast<std::size_t>(n_beams_) * n_ant_);
  }

  // `beat` is x[bin][antenna], bin_par x n_ant. Returns every beam of every bin;
  // splitting that into BEAM_MUX output beats is split_beat()'s job.
  BeamBeat step(const std::vector<std::vector<Complex>>& beat) const {
    BeamBeat r;
    r.y.assign(n_beams_, std::vector<Complex>(bin_par_));
    r.f_re.assign(n_beams_, std::vector<Flags>(bin_par_));
    r.f_im.assign(n_beams_, std::vector<Flags>(bin_par_));
    r.acc_re.assign(n_beams_, std::vector<wide_t>(bin_par_));
    r.acc_im.assign(n_beams_, std::vector<wide_t>(bin_par_));
    for (unsigned b = 0; b < n_beams_; ++b) {
      const Complex* row = &w_[weight_index(n_ant_, b, 0)];
      for (unsigned j = 0; j < bin_par_; ++j) {
        const DotResult d = dot(beat[j].data(), row, n_ant_);
        r.y[b][j] = d.y;
        r.f_re[b][j] = d.f_re;
        r.f_im[b][j] = d.f_im;
        r.acc_re[b][j] = d.acc_re;
        r.acc_im[b][j] = d.acc_im;
        if (d.saturating()) r.saturating = true;
      }
    }
    return r;
  }

  // The double-precision evaluation of the same beat, for the cross-check the
  // header of dot_float() describes. Returns yf[beam][bin].
  std::vector<std::vector<DotFloat>> step_float(
      const std::vector<std::vector<Complex>>& beat) const {
    std::vector<std::vector<DotFloat>> out(n_beams_,
                                           std::vector<DotFloat>(bin_par_));
    for (unsigned b = 0; b < n_beams_; ++b) {
      const Complex* row = &w_[weight_index(n_ant_, b, 0)];
      for (unsigned j = 0; j < bin_par_; ++j) {
        out[b][j] = dot_float(beat[j].data(), row, n_ant_);
      }
    }
    return out;
  }

 private:
  unsigned n_ant_ = 0;
  unsigned n_beams_ = 0;
  unsigned bin_par_ = 0;
  std::vector<Complex> w_;
};

// Splits one BeamBeat into the BEAM_MUX output beats the RTL emits, applying the
// metadata convention of rtl/beamformer/beamformer.sv section 4. `beam_par` must
// divide the beat's beam count and the quotient must be a power of two, which is
// the RTL's own elaboration contract.
inline std::vector<OutBeatExp> split_beat(const BeamBeat& r, unsigned beam_par,
                                          std::uint32_t seq_in,
                                          std::uint32_t stream_id, bool sof_in,
                                          bool eof_in) {
  const unsigned n_beams = r.n_beams();
  const unsigned bins = r.n_bins();
  const unsigned mux = beam_mux(n_beams, beam_par);
  const unsigned sh = seq_shift(mux);

  std::vector<OutBeatExp> out;
  out.reserve(mux);
  for (unsigned g = 0; g < mux; ++g) {
    OutBeatExp o;
    o.data.resize(static_cast<std::size_t>(beam_par) * bins);
    o.seq = (sh == 0u) ? seq_in : ((seq_in << sh) | g);
    o.user = g;
    o.sof = sof_in && (g == 0u);
    o.eof = eof_in && (g == mux - 1u);
    o.stream_id = stream_id;
    for (unsigned k = 0; k < beam_par; ++k) {
      const unsigned b = g * beam_par + k;
      for (unsigned j = 0; j < bins; ++j) {
        o.data[static_cast<std::size_t>(k) * bins + j] = r.y[b][j];
        if (r.f_re[b][j].any() || r.f_im[b][j].any()) o.saturating = true;
      }
    }
    out.push_back(std::move(o));
  }
  return out;
}

// ---------------------------------------------------------------------------
// Weight-set construction, used by the directed cases
// ---------------------------------------------------------------------------

// Unit weights: beam b selects antenna `sel[b]` and nothing else. The expected
// output is then the selected antenna's sample, EXACTLY — no model needed to
// predict it, which is what makes this the right first directed case.
//
// The weight value is fxp::q15_max() = 0x7FFF, not 1.0, because 1.0 is not
// representable in Q1.15. So the passthrough is a gain of 32767/32768 and the
// expected output is round_sat(x * 0x7FFF), not x. That is the same fact issue
// #11 recorded for the FFT's trivial twiddle (DECISIONS.md, issue #11 decision
// 6) and it is stated here rather than discovered by a failing test.
inline std::vector<Complex> unit_weights(unsigned n_ant, unsigned n_beams,
                                         const std::vector<unsigned>& sel) {
  std::vector<Complex> w(static_cast<std::size_t>(n_beams) * n_ant, Complex{});
  for (unsigned b = 0; b < n_beams; ++b) {
    const unsigned a = sel[b % sel.size()] % n_ant;
    w[weight_index(n_ant, b, a)] = Complex{fxp::q15_max(), 0};
  }
  return w;
}

// The expected passthrough sample for a unit-weight beam: x * 0x7FFF, rounded
// and saturated once. Written as the model's own single-term dot product so that
// it cannot disagree with the general path.
inline Complex unit_weight_expect(Complex x) {
  const Complex w{fxp::q15_max(), 0};
  return dot(&x, &w, 1u).y;
}

// Zero weights everywhere: the SPEC 13.2 "zero input produces zero output"
// relation from the other side. Any input must produce exactly zero with no
// saturation flag.
inline std::vector<Complex> zero_weights(unsigned n_ant, unsigned n_beams) {
  return std::vector<Complex>(static_cast<std::size_t>(n_beams) * n_ant,
                              Complex{});
}

// Full-scale weights: every weight is -1.0 + -1.0j, the operand pair that makes
// a complex product reach its extreme. With full-scale input this saturates the
// output of every beam in BOTH directions across a run, which is what the
// saturation directed case needs and what the coverage audit refuses to pass
// without.
inline std::vector<Complex> max_weights(unsigned n_ant, unsigned n_beams) {
  return std::vector<Complex>(static_cast<std::size_t>(n_beams) * n_ant,
                              Complex{fxp::q15_min(), fxp::q15_min()});
}

// Permutes the antenna axis of a weight set: w_out[b][p[a]] = w_in[b][a].
// Paired with the identical permutation of the antenna vector, this is the
// SPEC 13.2 metamorphic relation "permuting antenna inputs and weights
// consistently produces equivalent beam outputs" — and it is EXACT, not
// approximate, because the accumulation has no intermediate saturation and
// integer addition is commutative.
inline std::vector<Complex> permute_weights(const std::vector<Complex>& w,
                                            unsigned n_ant, unsigned n_beams,
                                            const std::vector<unsigned>& p) {
  std::vector<Complex> out(w.size(), Complex{});
  for (unsigned b = 0; b < n_beams; ++b) {
    for (unsigned a = 0; a < n_ant; ++a) {
      out[weight_index(n_ant, b, p[a])] = w[weight_index(n_ant, b, a)];
    }
  }
  return out;
}

}  // namespace bf

#endif  // MODEL_BEAMFORMER_BEAMFORMER_MODEL_HPP_
