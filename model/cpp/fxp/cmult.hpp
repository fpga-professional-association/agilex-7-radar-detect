// -----------------------------------------------------------------------------
// cmult.hpp — bit-identical C++ twin of rtl/common/complex_multiplier.sv.
//
// SPEC 6 requires the C++ reference model and the RTL to use identical numerical
// rules; SPEC 12.4 requires the C++ model to be validated against independent
// Python/NumPy vectors before it is trusted as the RTL oracle. This header is
// the C++ half for the complex multiplier: it is what sim/tests/test_cmult.cpp
// compares the RTL against, and what model/cpp/test/test_fxp_vectors.cpp
// validates against model/vectors/cmult.vec.
//
// It contains NO rounding or saturation of its own — every quantisation is a
// call into fxp.hpp, exactly as the RTL's every quantisation is a call into
// fxp_pkg. The arithmetic below is exact integer arithmetic, expressed through
// the wrapping primitives of fxp.hpp so the mirror is exact by construction
// rather than by observation on one compiler.
//
//   SystemVerilog                          C++
//   -------------------------------------  ------------------------------------
//   complex_multiplier VARIANT="MULT4"     fxp::cmult::raw_mult4 / eval(kMult4)
//   complex_multiplier VARIANT="MULT3"     fxp::cmult::raw_mult3 / eval(kMult3)
//   p_re / p_im   (33-bit, exact)          Result::p_re / p_im
//   y_re / y_im   (Q1.15, ROUND_OUT)       Result::y_re / y_im
//   flags_re / flags_im / ovf              Result::f_re / f_im / ovf
//
// Two independent paths on purpose
// --------------------------------
// raw_mult4 and raw_mult3 are written out separately, each as the arithmetic its
// RTL variant performs, rather than raw_mult3 calling raw_mult4 and returning.
// A model in which the two share an implementation cannot detect a factorization
// error at all; it would agree with itself while the RTL disagreed with both.
// `variants_agree()` is the property test that the two paths coincide, and
// model/cpp/test/test_fxp_vectors.cpp sweeps it over the Q1.15 boundary grid and
// a large pseudo-random set.
//
// Header-only. Build contract: g++ 13, -std=c++17 -O3 -Wall -Wextra -Werror.
// -----------------------------------------------------------------------------
#ifndef MODEL_CPP_FXP_CMULT_HPP_
#define MODEL_CPP_FXP_CMULT_HPP_

#include <cstdint>

#include "fxp/fxp.hpp"

namespace fxp {
namespace cmult {

// ---------------------------------------------------------------------------
// Formats
// ---------------------------------------------------------------------------

// Width of the exact full-precision product port, in bits. This is fxp_pkg's
// two-term MAC accumulator width, 32 + ceil(log2 2) = 33, and the bound is TIGHT:
// (-1-1j)*(-1-1j) has imaginary part +2^31, which does not fit 32 bits. See the
// width note at the top of rtl/common/complex_multiplier.sv.
inline constexpr unsigned kCmulProdW = kProdW + 1;  // 33

static_assert(kCmulProdW == acc_w(kProdW, 2),
              "kCmulProdW must equal fxp::acc_w(kProdW, 2)");

// True when `v` is representable in a signed kCmulProdW-bit field, i.e. when the
// RTL's 34-bit-to-33-bit post-adder cast is lossless.
constexpr bool fits_prod(wide_t v) { return !sat_ovf(v, kCmulProdW); }

enum class Variant : unsigned {
  kMult4 = 0,  // VARIANT = "MULT4"
  kMult3 = 1,  // VARIANT = "MULT3"
};

// ---------------------------------------------------------------------------
// Exact full-precision products
// ---------------------------------------------------------------------------

struct Raw {
  wide_t re = 0;
  wide_t im = 0;

  constexpr bool operator==(const Raw& o) const {
    return re == o.re && im == o.im;
  }
  constexpr bool operator!=(const Raw& o) const { return !(*this == o); }
};

// Four real multiplies, two adds (SPEC 6):
//   re = a.re*b.re - a.im*b.im      im = a.re*b.im + a.im*b.re
constexpr Raw raw_mult4(Complex a, Complex b) {
  return Raw{sub_wrap(static_cast<wide_t>(mul_q15(a.re, b.re)),
                      static_cast<wide_t>(mul_q15(a.im, b.im))),
             add_wrap(static_cast<wide_t>(mul_q15(a.re, b.im)),
                      static_cast<wide_t>(mul_q15(a.im, b.re)))};
}

// Karatsuba/Gauss three-real-multiply form, written as the RTL performs it:
//   k1 = a.re * (b.re + b.im)
//   k2 = b.im * (a.re + a.im)
//   k3 = b.re * (a.im - a.re)
//   re = k1 - k2                    im = k1 + k3
//
// The pre-adds are 17-bit exact and the products 33-bit exact; every step here
// stays far inside int64, so no intermediate can wrap.
constexpr wide_t k1_of(Complex a, Complex b) {
  return static_cast<wide_t>(a.re) *
         add_wrap(static_cast<wide_t>(b.re), static_cast<wide_t>(b.im));
}
constexpr wide_t k2_of(Complex a, Complex b) {
  return static_cast<wide_t>(b.im) *
         add_wrap(static_cast<wide_t>(a.re), static_cast<wide_t>(a.im));
}
constexpr wide_t k3_of(Complex a, Complex b) {
  return static_cast<wide_t>(b.re) *
         sub_wrap(static_cast<wide_t>(a.im), static_cast<wide_t>(a.re));
}

constexpr Raw raw_mult3(Complex a, Complex b) {
  return Raw{sub_wrap(k1_of(a, b), k2_of(a, b)),
             add_wrap(k1_of(a, b), k3_of(a, b))};
}

constexpr Raw raw_of(Variant v, Complex a, Complex b) {
  return v == Variant::kMult3 ? raw_mult3(a, b) : raw_mult4(a, b);
}

// The exactness property of DECISIONS.md (issue #9), as a callable predicate.
constexpr bool variants_agree(Complex a, Complex b) {
  return raw_mult4(a, b) == raw_mult3(a, b);
}

// ---------------------------------------------------------------------------
// The module's observable outputs
// ---------------------------------------------------------------------------

struct Result {
  wide_t p_re = 0;   // exact, 33-bit signed
  wide_t p_im = 0;
  i16 y_re = 0;      // Q1.15, zero when round_out is false
  i16 y_im = 0;
  Flags f_re;        // zero when round_out is false
  Flags f_im;
  bool ovf = false;

  constexpr bool operator==(const Result& o) const {
    return p_re == o.p_re && p_im == o.p_im && y_re == o.y_re &&
           y_im == o.y_im && f_re == o.f_re && f_im == o.f_im && ovf == o.ovf;
  }
  constexpr bool operator!=(const Result& o) const { return !(*this == o); }
};

// The whole module, for one beat. `round_out` mirrors the RTL parameter of the
// same name: false leaves the Q1.15 outputs and the flags at zero, which is what
// the RTL's tied-off branch produces and what the ROUND_OUT=0 calibration point
// synthesises.
constexpr Result eval(Variant v, Complex a, Complex b, bool round_out = true) {
  Result r;
  const Raw raw = raw_of(v, a, b);
  r.p_re = raw.re;
  r.p_im = raw.im;
  if (round_out) {
    r.y_re = static_cast<i16>(round_sat(raw.re, kProdShift, kSampleW));
    r.y_im = static_cast<i16>(round_sat(raw.im, kProdShift, kSampleW));
    r.f_re = round_sat_flags(raw.re, kProdShift, kSampleW);
    r.f_im = round_sat_flags(raw.im, kProdShift, kSampleW);
    r.ovf = r.f_re.any() || r.f_im.any();
  }
  return r;
}

// Equivalent spelling through fxp::cmul_q15, kept so a reader can see that the
// rounded output of this module IS the package's complex multiply and not a
// second definition of it. Checked in test_fxp_vectors.cpp.
constexpr Complex rounded_via_pkg(Complex a, Complex b) {
  return cmul_q15(a, b);
}

}  // namespace cmult
}  // namespace fxp

#endif  // MODEL_CPP_FXP_CMULT_HPP_
