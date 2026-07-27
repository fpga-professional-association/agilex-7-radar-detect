// -----------------------------------------------------------------------------
// pipeline_model.hpp — the end-to-end SPEC.md 3 reference (issue #17).
//
// The bit-exact C++ twin of rtl/top/benchmark_core.sv, composed from the
// per-block models issues #10-#16 already validated:
//
//     adc  (here)  ->  pfb::PfbModel  ->  fft::transform  ->  hist (here)
//                  ->  algn reshape   ->  bf::dot         ->  covar::power
//                  ->  cfar::run_frame
//
// 1. What is new here and what is reused (NORMATIVE)
// --------------------------------------------------
// Only TWO things in this file are new arithmetic, and both mirror RTL that
// issue #17 also wrote: the synthetic source (rtl/top/adc_source.sv) and the
// corner-turn indexing (which is `hist::Model`'s, re-expressed as a pure
// function because the pipeline test drives the memory through the pipeline
// rather than directly). Everything else — every multiply, every rounding, every
// saturation — is a CALL into a model that is already the oracle for its own
// block's unit test. Re-deriving any of it here would create a second answer
// that could disagree with the first, and SPEC 28 forbids resolving such a
// disagreement by editing both sides.
//
// 2. The composition is by VALUE, not by timing
// ---------------------------------------------
// This model computes, for a given configuration and a given frame index, the
// exact detection events that frame must produce. It has no notion of cycles,
// stalls, credits or clock ratios, and that is deliberate for the reason
// `pfb_model.hpp` states for itself: the RTL's timing is elastic by
// construction, so a model that predicted cycles would have to be re-derived
// every time a buffer depth changed and would be checking the buffer rather than
// the arithmetic.
//
// SPEC 12.5's requirement is met by the TEST, not by the model: the harness
// keys every observed transaction by its own identity (`frame_id`, `bin`,
// `stream_id`, `seq`) and asks this model for the value that identity must
// carry. There is no fixed-latency assumption anywhere in the loop.
//
// 3. Per-stage checking, and why it is worth the extra surface
// ------------------------------------------------------------
// The model exposes every intermediate, not only the events:
//
//     frame_samples()   what the sources must have produced
//     frame_bins()      what the transforms must have produced
//     beam_bins()       what the beamformer must have produced
//     bin_powers()      what the power stage must have produced
//     frame_events()    what the detectors must have produced
//
// An end-to-end test that compares only events can say the answer is wrong and
// nothing else; against an eight-stage pipeline that is a week of bisecting. The
// harness checks each stage against this model applied to that stage's OBSERVED
// input, so a failure names the stage, and then checks the whole chain against
// the model applied to the configuration, so a set of individually-correct
// stages that are wired together wrongly still fails.
//
// 4. The two sign conventions worth stating once
// ----------------------------------------------
//   * a TONE at step `k` peaks at bin `(FFT_SIZE - k) mod FFT_SIZE`. The source
//     table and the transform kernel are both exp(-j2*pi*e/N), so the
//     correlation peaks at the conjugate index. Stated in adc_source.sv too.
//   * UNIT weights are `fxp::q15_max()` = 0x7FFF, not 1.0, which is not
//     representable in Q1.15. A "pass-through" beam therefore has a gain of
//     32767/32768 and the expected output is `round_sat(x * 0x7FFF)`, not `x`.
//     `bf::unit_weights` carries the same caveat.
//
// Header-only. Build contract: g++ 13, -std=c++17 -O3 -Wall -Wextra -Werror.
// -----------------------------------------------------------------------------
#ifndef MODEL_CPP_PIPELINE_PIPELINE_MODEL_HPP_
#define MODEL_CPP_PIPELINE_PIPELINE_MODEL_HPP_

#include <cstdint>
#include <string>
#include <vector>

#include "beamformer/beamformer_model.hpp"
#include "cfar/cfar_model.hpp"
#include "covariance/covar_model.hpp"
#include "fft/fft_ref.hpp"
#include "fft/fft_twiddle_table.hpp"
#include "fxp/fxp.hpp"
#include "pfb/pfb_model.hpp"

namespace pipeline {

using fxp::Complex;
using fxp::i16;

// ---------------------------------------------------------------------------
// 1. Geometry
// ---------------------------------------------------------------------------
struct Geometry {
  unsigned n_ant = 4;
  unsigned lanes = 2;  // SAMPLES_PER_CYCLE
  unsigned fft_size = 256;
  unsigned pfb_taps = 8;
  unsigned n_beams = 4;
  unsigned history_frames = 16;
  unsigned bin_par = 2;
  unsigned beam_par = 4;
  unsigned align_groups = 4;
  unsigned covar_pairs = 6;
  unsigned cfar_max_guard = 2;
  unsigned cfar_max_ref = 16;

  unsigned beats_per_frame() const { return fft_size / lanes; }
  unsigned beam_mux() const { return beam_par == 0 ? 1 : n_beams / beam_par; }
  // Bins the history can serve, given the two slots its rotation reserves.
  unsigned readable_frames(unsigned depth) const {
    (void)this;
    return depth >= 2 ? depth - 2 : 0;
  }

  std::string describe() const {
    return "N_ANT=" + std::to_string(n_ant) + " LANES=" + std::to_string(lanes) +
           " FFT=" + std::to_string(fft_size) +
           " TAPS=" + std::to_string(pfb_taps) +
           " BEAMS=" + std::to_string(n_beams) +
           " BIN_PAR=" + std::to_string(bin_par) +
           " FRAMES=" + std::to_string(history_frames);
  }
};

// ---------------------------------------------------------------------------
// 2. The synthetic source — the bit-exact twin of rtl/top/adc_source.sv
//
// Every constant and every recurrence below is stated once in the RTL and once
// here, and the two are compared beat by beat by the harness against the
// `obs_adc_*` tap before anything downstream is checked. That comparison is the
// reason this duplication is safe: a divergence is a named failure on the first
// beat of the first frame, not a wrong spectrum a thousand cycles later.
// ---------------------------------------------------------------------------
enum class SrcMode : unsigned {
  kZero = 0,
  kImpulse = 1,
  kConst = 2,
  kTone = 3,
  kLfsr = 4,
};

inline constexpr std::uint32_t kLfsrTaps = 0xEDB88320u;
inline constexpr std::uint32_t kLfsrGolden = 0x9E3779B9u;

inline std::uint32_t lfsr_next(std::uint32_t s) {
  return (s & 1u) ? ((s >> 1) ^ kLfsrTaps) : (s >> 1);
}

// Per-antenna seed decorrelation. See adc_source.sv: one shared seed would give
// every antenna the same samples, and a beamformer fed identical antennas
// produces the same answer whether the alignment network works or not.
inline std::uint32_t lfsr_mix(std::uint32_t seed, unsigned ant) {
  const std::uint32_t m = seed ^ (kLfsrGolden * static_cast<std::uint32_t>(ant));
  return m == 0u ? 1u : m;
}

struct SrcConfig {
  SrcMode mode = SrcMode::kLfsr;
  i16 gain = fxp::q15_max();
  unsigned tone_step = 1;   // k, in FFT bins
  unsigned ant_step = 0;    // per-antenna phase step, in FFT bins
  std::uint32_t seed = 0x12345678u;
};

// TONE_TAB[e] = exp(-j2*pi*e/fft_size), decimated from the committed master
// table exactly as the RTL's elaboration-time function does.
inline Complex tone_entry(unsigned fft_size, unsigned e) {
  const unsigned decim = fft::kTwN / fft_size;
  return Complex::from_packed(fft::kTw[(e % fft_size) * decim]);
}

// One antenna's whole frame of `fft_size` samples.
//
// `frame_index` selects the frame: the tone phase resets every frame (so every
// frame is identical), while the LFSR runs free across frames (so frames differ
// and a delay-invariance check has something to distinguish).
inline std::vector<Complex> frame_samples(const Geometry& g, const SrcConfig& c,
                                          unsigned ant, unsigned frame_index) {
  std::vector<Complex> out(g.fft_size);
  std::uint32_t lf = lfsr_mix(c.seed, ant);
  // The RTL's LFSR is a single register advanced once per sample from reset, so
  // sample n of frame f is the state advanced (f*fft_size + n) times.
  for (std::uint64_t i = 0;
       i < static_cast<std::uint64_t>(frame_index) * g.fft_size; ++i) {
    lf = lfsr_next(lf);
  }

  const unsigned ant_phase = (ant * c.ant_step) % g.fft_size;

  for (unsigned n = 0; n < g.fft_size; ++n) {
    Complex raw{0, 0};
    switch (c.mode) {
      case SrcMode::kZero:
        break;
      case SrcMode::kImpulse:
        if (n == 0) raw = Complex{fxp::q15_max(), 0};
        break;
      case SrcMode::kConst:
        raw = Complex{fxp::q15_max(), 0};
        break;
      case SrcMode::kTone:
        raw = tone_entry(g.fft_size, (c.tone_step * n + ant_phase) % g.fft_size);
        break;
      case SrcMode::kLfsr:
        raw = Complex{static_cast<i16>(lf & 0xFFFFu),
                      static_cast<i16>((lf >> 16) & 0xFFFFu)};
        break;
    }
    // Scaled per component; NOT a complex multiply. See adc_source.sv 1.
    out[n] = Complex{fxp::mul_q15_rs(raw.re, c.gain),
                     fxp::mul_q15_rs(raw.im, c.gain)};
    lf = lfsr_next(lf);
  }
  return out;
}

// ---------------------------------------------------------------------------
// 3. The front end: polyphase bank then transform, per antenna
//
// `PfbModel` is STATEFUL — it holds a tap history across frames — so the model
// walks frames in order and cannot be asked for frame 7 without having produced
// frames 0..6. `FrontEnd` owns that state and enforces the order.
// ---------------------------------------------------------------------------
class FrontEnd {
 public:
  FrontEnd(const Geometry& g, const SrcConfig& src,
           const std::vector<Complex>& coeff, bool reorder = false)
      : g_(g), src_(src), reorder_(reorder), next_frame_(0) {
    for (unsigned a = 0; a < g_.n_ant; ++a) {
      banks_.emplace_back(g_.lanes, g_.pfb_taps, coeff);
    }
  }

  const Geometry& geometry() const { return g_; }
  unsigned frames_produced() const { return next_frame_; }

  // Replace the coefficient set WITHOUT touching the tap history — exactly what
  // a bank swap at a frame boundary does in the RTL (issue #10, decision 3).
  void swap_coeff(const std::vector<Complex>& coeff) {
    for (auto& b : banks_) b.swap_coeff(coeff);
  }

  // Produce the next frame. Returns bins[antenna][bin] in NATURAL bin order.
  std::vector<std::vector<Complex>> next() {
    const unsigned f = next_frame_++;
    std::vector<std::vector<Complex>> bins(g_.n_ant);

    for (unsigned a = 0; a < g_.n_ant; ++a) {
      const std::vector<Complex> x = frame_samples(g_, src_, a, f);

      // Polyphase, beat by beat: one beat is `lanes` consecutive samples.
      std::vector<Complex> filtered(g_.fft_size);
      for (unsigned k = 0; k < g_.beats_per_frame(); ++k) {
        std::vector<Complex> beat(g_.lanes);
        for (unsigned l = 0; l < g_.lanes; ++l) beat[l] = x[k * g_.lanes + l];
        const pfb::BeatResult r = banks_[a].step(beat);
        for (unsigned l = 0; l < g_.lanes; ++l) filtered[k * g_.lanes + l] = r.y[l];
      }

      fft::Config fc;
      fc.n_fft = g_.fft_size;
      fc.spc = g_.lanes;
      fc.reorder = reorder_;
      // `bins` is natural-order regardless of `reorder`, which is exactly the
      // field the history's read port serves: the transform's beat order and the
      // memory's bit-reversal absorption cancel (ARCHITECTURE.md 3.4).
      bins[a] = fft::transform(fc, filtered).bins;
    }
    return bins;
  }

 private:
  Geometry g_;
  SrcConfig src_;
  bool reorder_;
  unsigned next_frame_;
  std::vector<pfb::PfbModel> banks_;
};

// ---------------------------------------------------------------------------
// 4. The back end, as pure functions of one frame's bins
//
// Nothing here is stateful: a beamformer has no sample history, the power is a
// per-sample function, and a CFAR frame is a function of the frame's bins alone.
// The covariance integrator IS stateful and is deliberately not modelled here —
// it is checked in `test_pipeline_directed` against `covar::Engine` driven by
// the observed serialized beats, because its window boundaries are a function of
// how many beats the pipeline admitted rather than of the signal.
// ---------------------------------------------------------------------------

// Y[beam][bin], from bins[antenna][bin] and beam-major weights.
inline std::vector<std::vector<Complex>> beam_bins(
    const Geometry& g, const std::vector<std::vector<Complex>>& bins,
    const std::vector<Complex>& weights) {
  std::vector<std::vector<Complex>> y(g.n_beams,
                                      std::vector<Complex>(g.fft_size));
  std::vector<Complex> x(g.n_ant);
  std::vector<Complex> w(g.n_ant);
  for (unsigned b = 0; b < g.n_beams; ++b) {
    for (unsigned a = 0; a < g.n_ant; ++a) {
      w[a] = weights[bf::weight_index(g.n_ant, b, a)];
    }
    for (unsigned k = 0; k < g.fft_size; ++k) {
      for (unsigned a = 0; a < g.n_ant; ++a) x[a] = bins[a][k];
      y[b][k] = bf::dot(x, w).y;
    }
  }
  return y;
}

// P[beam][bin] = I^2 + Q^2, exact.
inline std::vector<std::vector<std::uint64_t>> bin_powers(
    const Geometry& g, const std::vector<std::vector<Complex>>& y) {
  std::vector<std::vector<std::uint64_t>> p(
      g.n_beams, std::vector<std::uint64_t>(g.fft_size, 0));
  for (unsigned b = 0; b < g.n_beams; ++b) {
    for (unsigned k = 0; k < g.fft_size; ++k) {
      p[b][k] = static_cast<std::uint64_t>(covar::power(y[b][k]));
    }
  }
  return p;
}

// The detection events of one sweep, per beam, in the order each detector emits
// them. The MERGE order across beams is the bank's round-robin arbitration and
// is deliberately not predicted: `stream_id` demultiplexes the merged stream and
// each beam's sub-sequence is what this returns.
inline std::vector<std::vector<cfar::Event>> frame_events(
    const Geometry& g, const std::vector<std::vector<std::uint64_t>>& powers,
    const cfar::Config& cfg, unsigned frame_id) {
  std::vector<std::vector<cfar::Event>> ev(g.n_beams);
  for (unsigned b = 0; b < g.n_beams; ++b) {
    ev[b] = cfar::run_frame(powers[b], cfg, g.cfar_max_guard, g.cfar_max_ref,
                            frame_id);
  }
  return ev;
}

// ---------------------------------------------------------------------------
// 5. The alignment reshape
//
// `align_net`'s output beat is bin-major, antenna-minor over BIN_PAR consecutive
// bins — `algn::Beat::data`'s layout and `beamformer_pkg::bf_in_data_w`'s, which
// are the same layout by elaboration check. This is the pure-indexing bridge the
// harness uses to turn an observed beat back into the (bin, antenna) grid the
// model works in; it contains no arithmetic and cannot be wrong about a value,
// only about a position.
// ---------------------------------------------------------------------------
inline std::size_t align_index(const Geometry& g, unsigned lane, unsigned ant) {
  return static_cast<std::size_t>(lane) * g.n_ant + ant;
}

// The bin an alignment beat's lane `j` carries, given the beat's group index.
inline unsigned align_bin_of(const Geometry& g, unsigned group, unsigned lane) {
  return group * g.bin_par + lane;
}

// The history read port a group's lane is requested on. Rotates so that over
// BIN_PAR consecutive groups every port sees every beat position (ARCHITECTURE
// 3.4a, "The schedule, and why the routing is not the identity").
inline unsigned align_port_of(const Geometry& g, unsigned group, unsigned lane) {
  return (lane + group) % g.bin_par;
}

// ---------------------------------------------------------------------------
// 6. The whole chain, for one frame
//
// The convenience the directed tests use: configuration and a frame index in,
// the events that frame must produce out. `FrontEnd` is passed by reference
// because it is stateful and the caller owns the frame order.
// ---------------------------------------------------------------------------
struct FrameResult {
  std::vector<std::vector<Complex>> bins;                 // [antenna][bin]
  std::vector<std::vector<Complex>> beams;                // [beam][bin]
  std::vector<std::vector<std::uint64_t>> powers;         // [beam][bin]
  std::vector<std::vector<cfar::Event>> events;           // [beam][event]
};

inline FrameResult run_frame(const Geometry& g, FrontEnd& fe,
                             const std::vector<Complex>& weights,
                             const cfar::Config& cfg, unsigned frame_id) {
  FrameResult r;
  r.bins = fe.next();
  r.beams = beam_bins(g, r.bins, weights);
  r.powers = bin_powers(g, r.beams);
  r.events = frame_events(g, r.powers, cfg, frame_id);
  return r;
}

// ---------------------------------------------------------------------------
// 7. Coefficient and weight sets the tests program
//
// Named here rather than in each test so that "the identity filter" means one
// thing across the whole suite.
// ---------------------------------------------------------------------------

// A polyphase bank that passes its input through: tap 0 of every phase is unity
// (to within the Q1.15 LSB) and every other tap is zero. The output is therefore
// `round_sat(x * 0x7FFF)`, not `x` — see the header, 4.
inline std::vector<Complex> passthrough_coeff(unsigned phases, unsigned taps) {
  std::vector<Complex> c(static_cast<std::size_t>(phases) * taps, Complex{0, 0});
  for (unsigned p = 0; p < phases; ++p) {
    c[pfb::coeff_index(taps, p, 0)] = Complex{fxp::q15_max(), 0};
  }
  return c;
}

// A prototype low-pass-shaped set: a raised-cosine window over the taps, scaled
// so the sum of any phase's taps cannot saturate. Not a design filter — a set
// whose every tap is distinct, so a swapped or mis-indexed coefficient changes
// the answer.
inline std::vector<Complex> shaped_coeff(unsigned phases, unsigned taps,
                                         std::uint32_t seed) {
  std::vector<Complex> c(static_cast<std::size_t>(phases) * taps);
  std::uint32_t s = seed == 0 ? 1u : seed;
  for (unsigned p = 0; p < phases; ++p) {
    for (unsigned t = 0; t < taps; ++t) {
      s = lfsr_next(s);
      // Bounded well below full scale so a `taps`-long accumulation of the
      // worst input cannot reach the saturation limit; the saturation path has
      // its own directed test and does not belong in every random pass.
      const int mag = static_cast<int>(s % 4096u) - 2048;
      c[pfb::coeff_index(taps, p, t)] =
          Complex{static_cast<i16>(mag), static_cast<i16>((mag * 3) / 7)};
    }
  }
  return c;
}

// An ORTHOGONAL beam set: beam `b` steers to the wavefront whose per-antenna
// phase step is `b * beam_spacing(n_ant, fft_size)`.
//
// The spacing is `fft_size / n_ant` — a full turn of phase across the array per
// beam index — and that choice is what makes the beams discriminate. A spacing
// of one bin would give a four-antenna array a total phase spread of 4/256 of a
// turn, and every beam would see every wavefront almost equally; the test
// "the target appears in the right beam" would then pass on a design whose
// antenna axis was wired backwards. At this spacing the weight matrix is a
// DFT over the array, beam `b` sums coherently for `ant_step = b * spacing` and
// sums to EXACTLY ZERO for every other beam index, which is a check with no
// threshold in it.
//
// The weight is the conjugate of the arrival phase, and the table gives a
// conjugate as the entry at the negated index rather than by negating a
// component — `-32768` has no Q1.15 negation (NUMERICS.md) and the corner would
// be silently wrong.
inline unsigned beam_spacing(unsigned n_ant, unsigned fft_size) {
  return n_ant == 0 ? 1 : fft_size / n_ant;
}

inline std::vector<Complex> steering_weights(unsigned n_ant, unsigned n_beams,
                                             unsigned fft_size) {
  const unsigned sp = beam_spacing(n_ant, fft_size);
  std::vector<Complex> w(static_cast<std::size_t>(n_beams) * n_ant);
  for (unsigned b = 0; b < n_beams; ++b) {
    for (unsigned a = 0; a < n_ant; ++a) {
      const unsigned e = (fft_size - ((a * b * sp) % fft_size)) % fft_size;
      w[bf::weight_index(n_ant, b, a)] = tone_entry(fft_size, e);
    }
  }
  return w;
}

// The bin a tone at step `k` lands in. Stated as a function so no test writes
// the sign convention down a second time. See the header, 4.
inline unsigned tone_bin(unsigned fft_size, unsigned tone_step) {
  return (fft_size - (tone_step % fft_size)) % fft_size;
}

// A tone step that puts the line at `bin`, which is the inverse of the above.
inline unsigned step_for_bin(unsigned fft_size, unsigned bin) {
  return (fft_size - (bin % fft_size)) % fft_size;
}

// True when a CFAR detector with this geometry can evaluate `bin` at all: the
// complete programmed window must lie inside the frame, and the first and last
// `guard + reference` bins of every frame therefore yield no detections
// (ARCHITECTURE.md 3.5, "Edge policy: suppress"). A directed test that placed
// its target near an edge would be testing the edge policy while believing it
// was testing detection.
inline bool bin_is_evaluable(const Geometry& g, const cfar::Config& c,
                             unsigned bin) {
  const unsigned d_lead = c.guard_lead + c.ref_lead;
  const unsigned d_lag = c.guard_lag + c.ref_lag;
  return bin >= d_lead && bin + d_lag < g.fft_size;
}

// Only beam `sel` sees anything, and it sees antenna `sel` alone. The simplest
// weight set for which a mis-wired antenna axis is immediately visible.
inline std::vector<Complex> selector_weights(unsigned n_ant, unsigned n_beams) {
  std::vector<Complex> w(static_cast<std::size_t>(n_beams) * n_ant, Complex{0, 0});
  for (unsigned b = 0; b < n_beams; ++b) {
    w[bf::weight_index(n_ant, b, b % n_ant)] = Complex{fxp::q15_max(), 0};
  }
  return w;
}

}  // namespace pipeline

#endif  // MODEL_CPP_PIPELINE_PIPELINE_MODEL_HPP_
