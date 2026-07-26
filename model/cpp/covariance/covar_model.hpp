// -----------------------------------------------------------------------------
// covar_model.hpp — bit-accurate C++ twin of rtl/covariance/ (SPEC.md 7.6, 12.4).
//
// SPEC 12.4 requires a bit-accurate reference model for every kernel, built on
// the shared fixed-point library, and SPEC 6 requires the model and the RTL to
// use identical numerical rules. This header is that model for the power and
// covariance engine:
//
//   covar::power()          rtl/covariance/power_calc.sv
//   covar::cross_power()    rtl/covariance/covar_engine.sv (the conjugate wiring)
//   covar::Integrator       rtl/covariance/integrator.sv (window, exponential
//                           mode, saturation, sticky flags, flush)
//   covar::Engine           rtl/covariance/covar_engine.sv (pair table, per-pair
//                           enable, two accumulators per pair)
//
// Every quantisation, saturation and shift below is a call into model/cpp/fxp/,
// which is itself the mirror of rtl/packages/fxp_pkg.sv. There is no arithmetic
// in this file that fxp.hpp does not define — that is the same rule the RTL
// obeys, and it is what makes "bit exact" mean something stronger than "agrees
// on the cases we tried".
//
// CYCLE ACCURACY. Integrator::step() performs exactly one clock edge's worth of
// work and returns the result the RTL registers ON that edge — which the RTL
// therefore PRESENTS on the following cycle. A test that drives the DUT, reads
// its outputs, and then calls step() with the same inputs is cycle-aligned by
// construction; sim/tests/test_covariance.cpp uses a one-deep expectation queue
// so the alignment is checked rather than assumed.
//
// Header-only. Build contract: g++ 13, -std=c++17 -O3 -Wall -Wextra -Werror.
// -----------------------------------------------------------------------------
#ifndef MODEL_CPP_COVARIANCE_COVAR_MODEL_HPP_
#define MODEL_CPP_COVARIANCE_COVAR_MODEL_HPP_

#include <cstdint>
#include <vector>

#include "fxp/fxp.hpp"

namespace covar {

// ---------------------------------------------------------------------------
// Widths (covar_pkg)
// ---------------------------------------------------------------------------

// SPEC 3 POWER_W. 32 bits of single-sample magnitude plus 8 bits of integration
// growth; see rtl/packages/covar_pkg.sv section 1 for the derivation.
inline constexpr unsigned kPowerW = 40;      // COVAR_POWER_W

// The "zero growth" width: one term satisfies |term| <= 2^31, which needs 31
// magnitude bits and a sign.
inline constexpr unsigned kTermW = fxp::kProdW;  // COVAR_TERM_W == 32

// Exact width of one cross-power component, i.e. complex_multiplier's
// full-precision port.
inline constexpr unsigned kProdW = fxp::kProdW + 1;  // covar_prod_w() == 33

inline constexpr unsigned kExpKW = 4;        // COVAR_EXP_K_W
inline constexpr unsigned kExpKMax = (1U << kExpKW) - 1U;
inline constexpr unsigned kWindowIdW = 16;   // COVAR_WINDOW_ID_W
inline constexpr unsigned kWindowLenW = 16;  // COVAR_WINDOW_LEN_W
inline constexpr unsigned kSelW = 8;         // covar_src_sel_w()

// ---------------------------------------------------------------------------
// Accumulator sizing — covar_pkg's covar_acc_w_required / covar_window_max_exact
//
//   a signed w-bit accumulator sums N terms bounded by 2^31 exactly
//   iff  N <= 2^(w-32) - 1
// ---------------------------------------------------------------------------

constexpr unsigned acc_w_required(std::uint64_t n_samples) {
  const std::uint64_t n = (n_samples == 0) ? 1 : n_samples;
  // ceil(log2(n + 1)), matching $clog2(n + 1).
  unsigned bits = 0;
  std::uint64_t v = n;  // (n+1) - 1
  while (v != 0) {
    v >>= 1;
    ++bits;
  }
  return kTermW + bits;
}

constexpr std::uint64_t window_max_exact(unsigned acc_w) {
  if (acc_w <= kTermW) return 0;
  if (acc_w >= kTermW + 31) return 0xFFFFFFFFULL;
  return (1ULL << (acc_w - kTermW)) - 1ULL;
}

constexpr bool window_is_exact(unsigned acc_w, std::uint64_t n) {
  return n <= window_max_exact(acc_w);
}

// ---------------------------------------------------------------------------
// Power = I^2 + Q^2 (power_calc.sv)
//
// Exact integer arithmetic: two squares and one add, in [0, 2^31]. Expressed
// through fxp::mul_q15 so it is the same multiply the rest of the design uses.
// ---------------------------------------------------------------------------

inline fxp::wide_t power(fxp::Complex s) {
  return static_cast<fxp::wide_t>(fxp::mul_q15(s.re, s.re)) +
         static_cast<fxp::wide_t>(fxp::mul_q15(s.im, s.im));
}

// ---------------------------------------------------------------------------
// Cross power Rxy = X * conj(Y) (covar_engine.sv section 2)
// ---------------------------------------------------------------------------

struct Cross {
  fxp::wide_t re = 0;
  fxp::wide_t im = 0;

  constexpr bool operator==(const Cross& o) const {
    return re == o.re && im == o.im;
  }
  constexpr bool operator!=(const Cross& o) const { return !(*this == o); }
};

// Path A: the DIRECT definition. This is what X*conj(Y) means, written out.
inline Cross cross_power_direct(fxp::Complex x, fxp::Complex y) {
  Cross c;
  c.re = static_cast<fxp::wide_t>(fxp::mul_q15(x.re, y.re)) +
         static_cast<fxp::wide_t>(fxp::mul_q15(x.im, y.im));
  c.im = static_cast<fxp::wide_t>(fxp::mul_q15(x.im, y.re)) -
         static_cast<fxp::wide_t>(fxp::mul_q15(x.re, y.im));
  return c;
}

// Path B: the OPERAND-SWAP wiring the RTL actually builds — the issue #9 complex
// multiplier fed b = (b.re = y.im, b.im = y.re), with
//
//     Rxy.re = p_im        Rxy.im = -p_re
//
// This is a second, independently written expression of the same quantity, and
// the two are required to agree on every input the test drives. That is the
// same discipline model/cpp/fxp/cmult.hpp applies to MULT3 vs MULT4: an identity
// the RTL depends on is CHECKED in the model, not asserted in a comment.
inline Cross cross_power_swap(fxp::Complex x, fxp::Complex y) {
  const fxp::Complex b{y.im, y.re};  // {re = y.im, im = y.re}
  const fxp::wide_t p_re = fxp::cmul_q15_re_raw(x, b);
  const fxp::wide_t p_im = fxp::cmul_q15_im_raw(x, b);
  Cross c;
  c.re = p_im;
  c.im = -p_re;
  return c;
}

// The oracle. Both paths must agree; callers that want the cross-check call the
// two explicitly (the test does, on every beat).
inline Cross cross_power(fxp::Complex x, fxp::Complex y) {
  return cross_power_swap(x, y);
}

// ---------------------------------------------------------------------------
// Integrator (integrator.sv)
// ---------------------------------------------------------------------------

enum class Mode : unsigned { kBlock = 0, kExp = 1 };

struct Config {
  unsigned window_len = 1;
  Mode mode = Mode::kBlock;
  unsigned exp_k = 0;
  bool enable = true;

  constexpr bool operator==(const Config& o) const {
    return window_len == o.window_len && mode == o.mode && exp_k == o.exp_k &&
           enable == o.enable;
  }
};

struct Result {
  fxp::wide_t acc = 0;
  unsigned window_id = 0;
  unsigned sample_count = 0;
  bool flushed = false;
  bool truncated = false;

  constexpr bool operator==(const Result& o) const {
    return acc == o.acc && window_id == o.window_id &&
           sample_count == o.sample_count && flushed == o.flushed &&
           truncated == o.truncated;
  }
  constexpr bool operator!=(const Result& o) const { return !(*this == o); }
};

class Integrator {
 public:
  Integrator(unsigned acc_w, unsigned window_w)
      : acc_w_(acc_w), window_w_(window_w) {}

  // Reset, matching the RTL's synchronous reset: the active configuration is
  // loaded from the cfg ports and everything else is zero.
  void reset(const Config& cfg) {
    active_ = cfg;
    acc_ = 0;
    count_ = 0;
    window_id_ = 0;
    sticky_ = fxp::StickyFlags{};
  }

  // One clock edge. Returns true and fills *out when a window result is
  // registered on this edge. `cfg` is what the cfg_* ports carry THIS cycle;
  // it is latched only at a boundary, exactly as the RTL latches it.
  bool step(const Config& cfg, bool valid_in, fxp::wide_t data, bool flush,
            bool sat_clear, Result* out) {
    const unsigned wl = effective_len();
    const bool accept = valid_in && active_.enable;

    fxp::wide_t raw = acc_;
    if (accept) {
      if (active_.mode == Mode::kExp) {
        // y + trunc((x - y) >> k). integrator.sv section 4.
        raw = fxp::add_wrap(acc_, fxp::trunc(fxp::sub_wrap(data, acc_),
                                             active_.exp_k));
      } else {
        raw = fxp::add_wrap(acc_, data);
      }
    }

    const fxp::Flags step_flags =
        accept ? fxp::sat_flags(raw, acc_w_) : fxp::Flags{};
    const fxp::wide_t acc_next = fxp::sat(raw, acc_w_);

    const unsigned count_next = accept ? (count_ + 1U) : count_;
    const bool close = accept && (count_next >= wl);
    const bool flush_emit = flush && !close && (count_next != 0U);
    const bool emit = close || flush_emit;

    if (emit && out != nullptr) {
      out->acc = acc_next;
      out->window_id = window_id_;
      out->sample_count = count_next;
      out->flushed = flush;
      out->truncated = (count_next != wl);
    }

    // Sticky flags. `clear` wins over a simultaneous event, and a flush clears
    // — flush means fresh start (integrator.sv section 3).
    sticky_.step(accept, step_flags, sat_clear || flush);

    // A boundary: no window open AND none opening. The `!accept` term is what
    // stops a configuration written in the cycle a window OPENS from applying to
    // that window; see integrator.sv's `boundary`.
    const bool at_boundary = close || flush || (count_ == 0U && !accept);

    if (flush) {
      acc_ = 0;
      count_ = 0;
      window_id_ = 0;
    } else if (close) {
      acc_ = (active_.mode == Mode::kExp) ? acc_next : 0;
      count_ = 0;
      window_id_ = (window_id_ + 1U) & ((1U << kWindowIdW) - 1U);
    } else {
      acc_ = acc_next;
      count_ = count_next;
    }

    if (at_boundary) active_ = cfg;

    return emit;
  }

  // Live state, mirroring the integrator's obs_* ports.
  fxp::wide_t acc() const { return acc_; }
  unsigned count() const { return count_; }
  unsigned window_id() const { return window_id_; }
  const Config& active() const { return active_; }
  unsigned effective_len() const {
    return (active_.window_len == 0U) ? 1U : active_.window_len;
  }

  fxp::Flags sat_flags() const { return sticky_.sticky(); }
  bool sat_sticky() const { return sticky_.any(); }
  std::uint32_t sat_count() const { return sticky_.event_count(); }

  unsigned acc_w() const { return acc_w_; }
  unsigned window_w() const { return window_w_; }

 private:
  unsigned acc_w_;
  unsigned window_w_;
  Config active_{};
  fxp::wide_t acc_ = 0;
  unsigned count_ = 0;
  unsigned window_id_ = 0;
  fxp::StickyFlags sticky_{};
};

// ---------------------------------------------------------------------------
// Engine (covar_engine.sv)
//
// N_PAIRS channels, each with a pair-table entry and two accumulators. The pair
// SELECTORS latch on reset and on flush only (covar_engine.sv section 4); the
// per-pair ENABLE is the integrator's cfg_enable and therefore latches at a
// window boundary.
//
// The multiplier pipeline is modelled as a pure delay on the (x, y) operands:
// the engine's complex multiplier has a fixed latency and no enable, so a beat
// presented at cycle t is accumulated at cycle t + CMULT_PIPE_STAGES with the
// SELECTORS THAT APPLIED AT t. Modelling the delay explicitly is what makes the
// in-flight-product hazard of section 4 visible in the model rather than a
// property only the RTL knows about.
// ---------------------------------------------------------------------------

struct PairEntry {
  unsigned x = 0;
  unsigned y = 0;
};

struct PairResult {
  bool valid = false;     // the real accumulator emitted
  bool valid_im = false;  // the imaginary one; must always equal `valid`
  Result re{};
  Result im{};
};

class Engine {
 public:
  Engine(unsigned n_src, unsigned n_pairs, unsigned acc_w, unsigned window_w,
         unsigned cmult_latency)
      : n_src_(n_src),
        n_pairs_(n_pairs),
        cmult_latency_(cmult_latency),
        table_(n_pairs),
        active_table_(n_pairs) {
    for (unsigned p = 0; p < n_pairs; ++p) {
      acc_re_.emplace_back(acc_w, window_w);
      acc_im_.emplace_back(acc_w, window_w);
    }
    pipe_.assign((cmult_latency == 0) ? 1 : cmult_latency, Beat{});
  }

  void set_table(unsigned pair, PairEntry e) { table_[pair] = e; }
  const PairEntry& active_entry(unsigned pair) const {
    return active_table_[pair];
  }

  void reset(const Config& cfg) {
    active_table_ = table_;
    for (auto& a : acc_re_) a.reset(cfg);
    for (auto& a : acc_im_) a.reset(cfg);
    for (auto& b : pipe_) b = Beat{};
  }

  // One clock edge. `src` is the source vector presented this cycle; `enable`
  // is the per-pair mask on the cfg ports. Returns the per-pair results
  // registered on this edge.
  std::vector<PairResult> step(const Config& cfg,
                               const std::vector<bool>& enable, bool valid_in,
                               const std::vector<fxp::Complex>& src, bool flush,
                               bool sat_clear) {
    // The product that lands in the accumulators this cycle was formed
    // cmult_latency cycles ago, from the sources and selectors of that cycle.
    const Beat landed = pipe_.front();

    std::vector<PairResult> out(n_pairs_);
    for (unsigned p = 0; p < n_pairs_; ++p) {
      Config c = cfg;
      c.enable = enable[p];

      Cross xp{};
      if (landed.valid) {
        const unsigned xi = (landed.sel[p].x < n_src_) ? landed.sel[p].x : 0U;
        const unsigned yi = (landed.sel[p].y < n_src_) ? landed.sel[p].y : 0U;
        xp = cross_power(landed.src[xi], landed.src[yi]);
      }

      Result r_re{};
      Result r_im{};
      const bool e_re = acc_re_[p].step(c, landed.valid, xp.re, flush, sat_clear,
                                        &r_re);
      const bool e_im = acc_im_[p].step(c, landed.valid, xp.im, flush, sat_clear,
                                        &r_im);
      // The two halves are driven by identical control, so they emit together.
      // Both flags are reported rather than merged: the test checks the
      // equality instead of the model quietly assuming it.
      out[p].valid = e_re;
      out[p].valid_im = e_im;
      out[p].re = r_re;
      out[p].im = r_im;
    }

    // Advance the multiplier pipeline, then latch the table if this was a
    // flush (covar_engine.sv section 4).
    Beat b;
    b.valid = valid_in;
    b.src = src;
    b.sel = active_table_;
    pipe_.erase(pipe_.begin());
    pipe_.push_back(b);

    if (flush) active_table_ = table_;

    return out;
  }

  const Integrator& re(unsigned pair) const { return acc_re_[pair]; }
  const Integrator& im(unsigned pair) const { return acc_im_[pair]; }

 private:
  struct Beat {
    bool valid = false;
    std::vector<fxp::Complex> src;
    std::vector<PairEntry> sel;
  };

  unsigned n_src_;
  unsigned n_pairs_;
  unsigned cmult_latency_;
  std::vector<PairEntry> table_;
  std::vector<PairEntry> active_table_;
  std::vector<Integrator> acc_re_;
  std::vector<Integrator> acc_im_;
  std::vector<Beat> pipe_;
};

}  // namespace covar

#endif  // MODEL_CPP_COVARIANCE_COVAR_MODEL_HPP_
