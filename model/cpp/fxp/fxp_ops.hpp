// -----------------------------------------------------------------------------
// fxp_ops.hpp — the operation table shared by the vectors, the C++ unit test and
// the RTL cross-check.
//
// One numbered operation set, three consumers:
//
//   model/python/gen_fxp_vectors.py   writes the op NAME into model/vectors/
//   model/cpp/test/test_fxp_vectors.cpp  evaluates it with fxp::  (C++ vs vectors)
//   sim/tests/test_fxp_rtl.cpp        drives the CODE into fxp_probe_top
//                                     (RTL vs vectors, and RTL vs C++)
//
// THE CODES ARE MIRRORED in sim/verilator/tops/fxp_probe_top.sv (FXP_OP_*). The
// names are mirrored in model/python/gen_fxp_vectors.py (OPS). A name the loader
// does not recognise is a hard failure, so a drift in any of the three shows up
// as "unknown op" rather than as a silently wrong answer.
//
// `apply()` is the C++ evaluation of an operation and is written to mirror the
// probe's case statement arm for arm. It contains no arithmetic of its own —
// every line is a call into fxp.hpp — for the same reason the probe contains no
// arithmetic of its own.
// -----------------------------------------------------------------------------
#ifndef MODEL_CPP_FXP_FXP_OPS_HPP_
#define MODEL_CPP_FXP_FXP_OPS_HPP_

#include <cstddef>
#include <cstdint>
#include <cstring>

#include "fxp/fxp.hpp"

namespace fxp {
namespace ops {

enum Op : unsigned {
  kSat = 0,
  kTrunc = 1,
  kRoundEven = 2,
  kRoundHalfUp = 3,
  kRound = 4,
  kRoundSat = 5,
  kAddSat = 6,
  kSubSat = 7,
  kNegSat = 8,
  kMulQ15 = 9,
  kMulQ15Rs = 10,
  kCmulRe = 11,
  kCmulIm = 12,
  kAccW = 13,
  kGrowthBits = 14,
  kOpCount = 15,
};

struct OpEntry {
  const char* name;
  unsigned code;
};

inline constexpr OpEntry kOpTable[] = {
    {"sat", kSat},
    {"trunc", kTrunc},
    {"round_even", kRoundEven},
    {"round_half_up", kRoundHalfUp},
    {"round", kRound},
    {"round_sat", kRoundSat},
    {"add_sat", kAddSat},
    {"sub_sat", kSubSat},
    {"neg_sat", kNegSat},
    {"mul_q15", kMulQ15},
    {"mul_q15_rs", kMulQ15Rs},
    {"cmul_re", kCmulRe},
    {"cmul_im", kCmulIm},
    {"acc_w", kAccW},
    {"growth_bits", kGrowthBits},
};

static_assert(sizeof(kOpTable) / sizeof(kOpTable[0]) == kOpCount,
              "kOpTable must cover every Op");

// Returns the op code for `name`, or kOpCount if the name is unknown.
inline unsigned code_of(const char* name) {
  for (const OpEntry& e : kOpTable) {
    if (std::strcmp(e.name, name) == 0) return e.code;
  }
  return kOpCount;
}

inline const char* name_of(unsigned code) {
  for (const OpEntry& e : kOpTable) {
    if (e.code == code) return e.name;
  }
  return "?";
}

struct Result {
  wide_t y = 0;
  Flags flags;
};

// Low 16 / low 32 bits of a wide operand, reinterpreted the way the probe's
// operand views do it.
inline i16 low16(wide_t v) {
  return static_cast<i16>(static_cast<std::uint16_t>(bits_of(v) & 0xFFFFULL));
}
inline std::uint32_t low32(wide_t v) {
  return static_cast<std::uint32_t>(bits_of(v) & 0xFFFFFFFFULL);
}

// Mirrors the always_comb dispatch in fxp_probe_top, arm for arm.
inline Result apply(unsigned op, wide_t a, wide_t b, unsigned sh, unsigned w) {
  Result r;
  switch (op) {
    case kSat:
      r.y = sat(a, w);
      r.flags = sat_flags(a, w);
      break;
    case kTrunc:
      r.y = trunc(a, sh);
      break;
    case kRoundEven:
      r.y = round_even(a, sh);
      break;
    case kRoundHalfUp:
      r.y = round_half_up(a, sh);
      break;
    case kRound:
      r.y = round(a, sh);
      break;
    case kRoundSat:
      r.y = round_sat(a, sh, w);
      r.flags = round_sat_flags(a, sh, w);
      break;
    case kAddSat:
      r.y = add_sat(a, b, w);
      r.flags = add_sat_flags(a, b, w);
      break;
    case kSubSat:
      r.y = sub_sat(a, b, w);
      r.flags = sub_sat_flags(a, b, w);
      break;
    case kNegSat:
      r.y = neg_sat(a, w);
      r.flags = neg_sat_flags(a, w);
      break;
    case kMulQ15:
      r.y = static_cast<wide_t>(mul_q15(low16(a), low16(b)));
      break;
    case kMulQ15Rs:
      r.y = static_cast<wide_t>(mul_q15_rs(low16(a), low16(b)));
      r.flags = mul_q15_rs_flags(low16(a), low16(b));
      break;
    case kCmulRe: {
      const Complex ca = Complex::from_packed(low32(a));
      const Complex cb = Complex::from_packed(low32(b));
      r.y = static_cast<wide_t>(cmul_q15(ca, cb).re);
      r.flags = cmul_q15_re_flags(ca, cb);
      break;
    }
    case kCmulIm: {
      const Complex ca = Complex::from_packed(low32(a));
      const Complex cb = Complex::from_packed(low32(b));
      r.y = static_cast<wide_t>(cmul_q15(ca, cb).im);
      r.flags = cmul_q15_im_flags(ca, cb);
      break;
    }
    case kAccW:
      // Accumulator width for `a` terms of `w`-bit products.
      r.y = static_cast<wide_t>(acc_w(w, low32(a)));
      break;
    case kGrowthBits:
      r.y = static_cast<wide_t>(growth_bits(low32(a)));
      break;
    default:
      r.y = 0;
      break;
  }
  return r;
}

}  // namespace ops
}  // namespace fxp

#endif  // MODEL_CPP_FXP_FXP_OPS_HPP_
