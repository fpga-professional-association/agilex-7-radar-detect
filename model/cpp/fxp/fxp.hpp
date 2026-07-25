// -----------------------------------------------------------------------------
// fxp.hpp — bit-identical C++ twin of rtl/packages/fxp_pkg.sv (SPEC.md 12.4).
//
// SPEC 12.4 requires a bit-accurate C++ reference library with complex
// fixed-point types, saturation and rounding, and it requires that library to be
// "validated independently against Python, NumPy, or MATLAB-generated vectors
// before using it as the RTL oracle". SPEC 6 requires that the C++ model and the
// RTL "use identical numerical rules".
//
// This header is the C++ half. Every function below is a line-for-line mirror of
// the SystemVerilog function of the same name in fxp_pkg, and NUMERICS.md is the
// prose both are derived from. Read all three together; changing one alone is
// the defect this whole arrangement exists to prevent.
//
//   SystemVerilog            C++
//   ---------------------    ------------------------
//   fxp_wide_t               fxp::wide_t   (int64_t)
//   fxp16_t / fxp_coeff_t    fxp::i16
//   fxp32_t                  fxp::i32
//   fxp_complex_t            fxp::Complex
//   fxp_flags_t              fxp::Flags
//   fxp_sat / fxp_round /…   fxp::sat / fxp::round /…
//
// Exactness, not "close enough"
// -----------------------------
// SystemVerilog arithmetic on a 64-bit signed vector wraps; C++ signed overflow
// is undefined behaviour, and C++17 leaves the result of `>>` on a negative
// value implementation-defined. Neither is allowed to be the difference between
// the model and the RTL, so every primitive here is expressed through unsigned
// 64-bit operations with an explicit reinterpretation at the end: `add_wrap`,
// `neg_wrap`, `shl_wrap`, `asr`. That makes the mirror exact by construction on
// any conforming compiler rather than by observation on this one.
//
// Header-only. Build contract: g++ 13, -std=c++17 -O3 -Wall -Wextra -Werror.
// -----------------------------------------------------------------------------
#ifndef MODEL_CPP_FXP_FXP_HPP_
#define MODEL_CPP_FXP_FXP_HPP_

#include <cstdint>

namespace fxp {

// ---------------------------------------------------------------------------
// Working types (fxp_pkg "Working types")
// ---------------------------------------------------------------------------

using wide_t = std::int64_t;   // fxp_wide_t
using u64_t = std::uint64_t;
using i16 = std::int16_t;      // fxp16_t / fxp_coeff_t — Q1.15
using i32 = std::int32_t;      // fxp32_t              — Q2.30

inline constexpr unsigned kWideW = 64;  // FXP_WIDE_W

// ---------------------------------------------------------------------------
// Formats (fxp_pkg "Formats")
// ---------------------------------------------------------------------------

inline constexpr unsigned kSampleW = 16;   // FXP_SAMPLE_W
inline constexpr unsigned kCoeffW = 16;    // FXP_COEFF_W
inline constexpr unsigned kFracW = 15;     // FXP_FRAC_W
inline constexpr unsigned kProdW = 32;     // FXP_PROD_W
inline constexpr unsigned kProdFracW = 30; // FXP_PROD_FRAC_W
inline constexpr unsigned kProdShift = kProdFracW - kFracW;  // FXP_PROD_SHIFT

// ---------------------------------------------------------------------------
// Rounding mode selection (fxp_pkg "Rounding mode selection")
//
// PROJECT RULE: round-to-nearest, ties-to-even. See NUMERICS.md 4. round_half_up
// is implemented so the comparison is testable, not so it can be used.
// ---------------------------------------------------------------------------

enum class RoundMode : unsigned {
  kNearestEven = 0,  // FXP_ROUND_MODE_NEAREST_EVEN
  kHalfUp = 1,       // FXP_ROUND_MODE_HALF_UP
};

inline constexpr RoundMode kRoundMode = RoundMode::kNearestEven;  // FXP_ROUND_MODE

// ---------------------------------------------------------------------------
// Wrapping primitives
//
// These carry the SystemVerilog semantics into C++ without undefined behaviour.
// Nothing outside this block may use a raw +, -, unary minus, << or >> on a
// wide_t.
// ---------------------------------------------------------------------------

constexpr u64_t bits_of(wide_t v) { return static_cast<u64_t>(v); }
constexpr wide_t from_bits(u64_t v) { return static_cast<wide_t>(v); }

constexpr wide_t add_wrap(wide_t a, wide_t b) {
  return from_bits(bits_of(a) + bits_of(b));
}
constexpr wide_t sub_wrap(wide_t a, wide_t b) {
  return from_bits(bits_of(a) - bits_of(b));
}
constexpr wide_t neg_wrap(wide_t a) { return from_bits(0ULL - bits_of(a)); }

constexpr wide_t shl_wrap(wide_t a, unsigned s) {
  return s >= kWideW ? wide_t{0} : from_bits(bits_of(a) << s);
}

// Arithmetic right shift = floor(v / 2^s), spelled out so it does not depend on
// the implementation-defined behaviour of `>>` on a negative value.
constexpr wide_t asr(wide_t v, unsigned s) {
  if (s == 0) return v;
  if (s >= kWideW) return v < 0 ? wide_t{-1} : wide_t{0};
  const u64_t logical = bits_of(v) >> s;
  const u64_t sign_fill = (v < 0) ? (~u64_t{0} << (kWideW - s)) : u64_t{0};
  return from_bits(logical | sign_fill);
}

// ---------------------------------------------------------------------------
// Range endpoints (fxp_max_of / fxp_min_of)
// ---------------------------------------------------------------------------

constexpr wide_t max_of(unsigned w) {
  if (w >= kWideW) return static_cast<wide_t>(0x7FFFFFFFFFFFFFFFULL);
  if (w < 2) return 0;
  return from_bits((u64_t{1} << (w - 1)) - 1U);
}

constexpr wide_t min_of(unsigned w) {
  if (w >= kWideW) return from_bits(0x8000000000000000ULL);
  if (w < 2) return 0;
  return neg_wrap(from_bits(u64_t{1} << (w - 1)));
}

// Q1.15 endpoints (fxp_q15_max / fxp_q15_min).
constexpr i16 q15_max() { return static_cast<i16>(max_of(kSampleW)); }  // 0x7FFF
constexpr i16 q15_min() { return static_cast<i16>(min_of(kSampleW)); }  // 0x8000

// ---------------------------------------------------------------------------
// Overflow / saturation flags (fxp_flags_t and friends)
// ---------------------------------------------------------------------------

struct Flags {
  bool sat_pos = false;  // clamped to +max
  bool sat_neg = false;  // clamped to -min

  constexpr bool any() const { return sat_pos || sat_neg; }
  constexpr bool operator==(const Flags& o) const {
    return sat_pos == o.sat_pos && sat_neg == o.sat_neg;
  }
  constexpr bool operator!=(const Flags& o) const { return !(*this == o); }

  // Packed form matching the SystemVerilog `fxp_flags_t` port encoding
  // ({sat_pos, sat_neg}: sat_pos is the MSB because it is declared first).
  constexpr unsigned packed() const {
    return (sat_pos ? 2U : 0U) | (sat_neg ? 1U : 0U);
  }
  static constexpr Flags from_packed(unsigned p) {
    return Flags{(p & 2U) != 0U, (p & 1U) != 0U};
  }
};

constexpr Flags flags_none() { return Flags{}; }  // fxp_flags_none
constexpr bool flags_any(Flags f) { return f.any(); }  // fxp_flags_any

constexpr Flags flags_merge(Flags a, Flags b) {  // fxp_flags_merge
  return Flags{a.sat_pos || b.sat_pos, a.sat_neg || b.sat_neg};
}

constexpr Flags sat_flags(wide_t v, unsigned w) {  // fxp_sat_flags
  return Flags{v > max_of(w), v < min_of(w)};
}

// ---------------------------------------------------------------------------
// Saturation (fxp_sat / fxp_sat_ovf)
// ---------------------------------------------------------------------------

constexpr bool sat_ovf(wide_t v, unsigned w) {
  return v > max_of(w) || v < min_of(w);
}

constexpr wide_t sat(wide_t v, unsigned w) {
  if (v > max_of(w)) return max_of(w);
  if (v < min_of(w)) return min_of(w);
  return v;
}

// ---------------------------------------------------------------------------
// Truncation (fxp_trunc) — round toward -infinity, biased by -0.5 LSB.
// ---------------------------------------------------------------------------

constexpr wide_t trunc(wide_t v, unsigned s) { return asr(v, s); }

// ---------------------------------------------------------------------------
// Rounding (fxp_round_half_up / fxp_round_even / fxp_round)
// ---------------------------------------------------------------------------

constexpr wide_t round_half_up(wide_t v, unsigned s) {
  if (s == 0) return v;
  if (s >= kWideW) return 0;
  const wide_t half = from_bits(u64_t{1} << (s - 1));
  return asr(add_wrap(v, half), s);
}

constexpr wide_t round_even(wide_t v, unsigned s) {
  if (s == 0) return v;
  if (s >= kWideW) return 0;
  const wide_t q = asr(v, s);
  const u64_t mask = (u64_t{1} << s) - 1U;
  const u64_t rem = bits_of(v) & mask;   // floor remainder, in [0, 2^s)
  const u64_t half = u64_t{1} << (s - 1);
  if (rem > half) return add_wrap(q, 1);
  if (rem < half) return q;
  return add_wrap(q, from_bits(bits_of(q) & 1U));  // ties to even
}

// The datapath rounding entry point (fxp_round). Model code calls this and
// nothing else.
constexpr wide_t round(wide_t v, unsigned s) {
  return kRoundMode == RoundMode::kHalfUp ? round_half_up(v, s)
                                          : round_even(v, s);
}

// ---------------------------------------------------------------------------
// Composite quantisation: round first, saturate second (fxp_round_sat)
// ---------------------------------------------------------------------------

constexpr wide_t round_sat(wide_t v, unsigned s, unsigned w) {
  return sat(round(v, s), w);
}

constexpr bool round_sat_ovf(wide_t v, unsigned s, unsigned w) {
  return sat_ovf(round(v, s), w);
}

constexpr Flags round_sat_flags(wide_t v, unsigned s, unsigned w) {
  return sat_flags(round(v, s), w);
}

// ---------------------------------------------------------------------------
// Saturating add / subtract / negate (fxp_add_sat / fxp_sub_sat / fxp_neg_sat)
// ---------------------------------------------------------------------------

constexpr wide_t add_sat(wide_t a, wide_t b, unsigned w) {
  return sat(add_wrap(a, b), w);
}
constexpr Flags add_sat_flags(wide_t a, wide_t b, unsigned w) {
  return sat_flags(add_wrap(a, b), w);
}

constexpr wide_t sub_sat(wide_t a, wide_t b, unsigned w) {
  return sat(sub_wrap(a, b), w);
}
constexpr Flags sub_sat_flags(wide_t a, wide_t b, unsigned w) {
  return sat_flags(sub_wrap(a, b), w);
}

constexpr wide_t neg_sat(wide_t a, unsigned w) { return sat(neg_wrap(a), w); }
constexpr Flags neg_sat_flags(wide_t a, unsigned w) {
  return sat_flags(neg_wrap(a), w);
}

// ---------------------------------------------------------------------------
// Q1.15 multiply (fxp_mul_q15 / fxp_mul_q15_rs)
// ---------------------------------------------------------------------------

// Exact Q1.15 x Q1.15 -> Q2.30. |result| <= 2^30, so 32 bits always suffice.
constexpr i32 mul_q15(i16 a, i16 b) {
  return static_cast<i32>(static_cast<wide_t>(a) * static_cast<wide_t>(b));
}

constexpr i16 mul_q15_rs(i16 a, i16 b) {
  return static_cast<i16>(
      round_sat(static_cast<wide_t>(mul_q15(a, b)), kProdShift, kSampleW));
}

constexpr Flags mul_q15_rs_flags(i16 a, i16 b) {
  return round_sat_flags(static_cast<wide_t>(mul_q15(a, b)), kProdShift,
                         kSampleW);
}

// ---------------------------------------------------------------------------
// Complex fixed-point type (SPEC 12.4 "complex fixed-point types")
// ---------------------------------------------------------------------------

struct Complex {
  i16 re = 0;
  i16 im = 0;

  constexpr bool operator==(const Complex& o) const {
    return re == o.re && im == o.im;
  }
  constexpr bool operator!=(const Complex& o) const { return !(*this == o); }

  // {im, re} packed into one 32-bit word, real part in the low half — the same
  // layout as the SystemVerilog `fxp_complex_t` and the vector files.
  constexpr std::uint32_t packed() const {
    return (static_cast<std::uint32_t>(static_cast<std::uint16_t>(im)) << 16) |
           static_cast<std::uint32_t>(static_cast<std::uint16_t>(re));
  }
  static constexpr Complex from_packed(std::uint32_t p) {
    return Complex{static_cast<i16>(static_cast<std::uint16_t>(p & 0xFFFFU)),
                   static_cast<i16>(static_cast<std::uint16_t>(p >> 16))};
  }
};

// Full-precision partial sums (fxp_cmul_q15_re_raw / _im_raw). SPEC 6:
//   real = a_re*b_re - a_im*b_im
//   imag = a_re*b_im + a_im*b_re
constexpr wide_t cmul_q15_re_raw(Complex a, Complex b) {
  return sub_wrap(static_cast<wide_t>(mul_q15(a.re, b.re)),
                  static_cast<wide_t>(mul_q15(a.im, b.im)));
}

constexpr wide_t cmul_q15_im_raw(Complex a, Complex b) {
  return add_wrap(static_cast<wide_t>(mul_q15(a.re, b.im)),
                  static_cast<wide_t>(mul_q15(a.im, b.re)));
}

// Rounded ONCE at the output, after the exact two-term sum (fxp_cmul_q15).
constexpr Complex cmul_q15(Complex a, Complex b) {
  return Complex{
      static_cast<i16>(round_sat(cmul_q15_re_raw(a, b), kProdShift, kSampleW)),
      static_cast<i16>(round_sat(cmul_q15_im_raw(a, b), kProdShift, kSampleW))};
}

constexpr Flags cmul_q15_re_flags(Complex a, Complex b) {
  return round_sat_flags(cmul_q15_re_raw(a, b), kProdShift, kSampleW);
}
constexpr Flags cmul_q15_im_flags(Complex a, Complex b) {
  return round_sat_flags(cmul_q15_im_raw(a, b), kProdShift, kSampleW);
}

// ---------------------------------------------------------------------------
// Accumulator width policy (fxp_growth_bits / fxp_acc_w / fxp_mac_q15_acc_w)
//
//   growth(N)   = ceil(log2 N), matching SystemVerilog $clog2 (growth(1) = 0)
//   acc_w(P, N) = P + growth(N)
// ---------------------------------------------------------------------------

constexpr unsigned growth_bits(unsigned n_terms) {
  if (n_terms <= 1) return 0;
  unsigned b = 0;
  unsigned v = n_terms - 1U;
  while (v != 0U) {
    v >>= 1;
    ++b;
  }
  return b;
}

constexpr unsigned acc_w(unsigned prod_w, unsigned n_terms) {
  return prod_w + growth_bits(n_terms);
}

// Accumulator width for an N-term Q1.15 MAC.
constexpr unsigned mac_q15_acc_w(unsigned n_terms) {
  return acc_w(kProdW, n_terms);
}

// ---------------------------------------------------------------------------
// Sticky saturation flags — the C++ twin of rtl/common/fxp_sticky_flags.sv
// ---------------------------------------------------------------------------

class StickyFlags {
 public:
  // `clear` wins over a simultaneous event, exactly as in the RTL.
  void step(bool valid, Flags f, bool clear = false) {
    if (clear) {
      sticky_ = Flags{};
      count_ = 0;
      return;
    }
    if (!valid) return;
    sticky_ = flags_merge(sticky_, f);
    if (f.any() && count_ != 0xFFFFFFFFU) ++count_;  // saturates, never wraps
  }

  void clear() { step(false, Flags{}, true); }

  Flags sticky() const { return sticky_; }
  bool any() const { return sticky_.any(); }
  std::uint32_t event_count() const { return count_; }

 private:
  Flags sticky_;
  std::uint32_t count_ = 0;
};

// ---------------------------------------------------------------------------
// Saturating accumulator — the C++ twin of fxp_probe_top's accumulator.
//
// Saturates at EVERY step. That is deliberately the pessimistic behaviour: it
// is order-dependent, so pinning it down in vectors is what lets NUMERICS.md
// state, and the kernels rely on, the opposite policy — accumulate at
// acc_w(P, N) where overflow is impossible and saturate only on the way out.
// ---------------------------------------------------------------------------

class Acc {
 public:
  explicit Acc(unsigned width) : width_(width) {}

  void clear() {
    value_ = 0;
    flags_.clear();
  }

  // Adds `x`, saturating to the accumulator width. Returns the new value.
  wide_t add(wide_t x) {
    const wide_t sum = add_wrap(value_, x);
    const Flags f = sat_flags(sum, width_);
    value_ = sat(sum, width_);
    flags_.step(true, f);
    return value_;
  }

  wide_t value() const { return value_; }
  unsigned width() const { return width_; }
  const StickyFlags& flags() const { return flags_; }

 private:
  unsigned width_;
  wide_t value_ = 0;
  StickyFlags flags_;
};

}  // namespace fxp

#endif  // MODEL_CPP_FXP_FXP_HPP_
