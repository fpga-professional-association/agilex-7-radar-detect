// -----------------------------------------------------------------------------
// test_fxp_vectors.cpp — validates model/cpp/fxp against the NumPy vectors.
//
// SPEC 12.4: "Validate the C++ model independently against Python, NumPy, or
// MATLAB-generated vectors before using it as the RTL oracle." This is that
// validation, and it is the gate that has to pass before any later issue is
// allowed to compare RTL output against the C++ reference model.
//
// Standalone: no Verilator, no harness, no build system beyond one g++ command.
//
//   g++ -std=c++17 -O3 -Wall -Wextra -Werror -Imodel/cpp
//       -o model/cpp/build/test_fxp_vectors model/cpp/test/test_fxp_vectors.cpp
//   ./model/cpp/build/test_fxp_vectors --vectors model/vectors
//
// (one command; the second line is the continuation of the first)
//
// `make numerics-check` runs exactly that, and `make sim-tiny` depends on it.
//
// Three groups of checks:
//
//   1. Every record of model/vectors/fxp_ops.vec, bit-exactly, value and flags.
//   2. Every step of model/vectors/fxp_accum.vec, bit-exactly, including the
//      sticky flags and the saturating event counter.
//   3. Properties that no finite vector set can establish on its own — rounding
//      identities, saturation idempotence, and the measured bias of both
//      rounding modes over a complete residue sweep. Group 3 is what turns
//      "the vectors agree" into "the rule is the rule NUMERICS.md states".
//
// A vector file that fails to load, declares the wrong schema, declares the
// wrong rounding mode, or contains fewer records than its own header says is a
// failure — never a quiet skip.
// -----------------------------------------------------------------------------

#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <string>
#include <vector>

#include "fxp/cmult.hpp"
#include "fxp/fxp.hpp"
#include "fxp/fxp_ops.hpp"
#include "fxp/fxp_vectors.hpp"

namespace {

constexpr const char* kTestName = "test_fxp_vectors";
constexpr int kMaxReportedFailures = 12;

int g_failures = 0;
int g_checks = 0;

void fail(const std::string& what) {
  ++g_failures;
  if (g_failures <= kMaxReportedFailures) {
    std::printf("  FAIL %s\n", what.c_str());
  } else if (g_failures == kMaxReportedFailures + 1) {
    std::printf("  ... further failures suppressed\n");
  }
}

void expect(bool cond, const std::string& what) {
  ++g_checks;
  if (!cond) fail(what);
}

std::string hex64(fxp::wide_t v) {
  char buf[32];
  std::snprintf(buf, sizeof(buf), "0x%016llx",
                static_cast<unsigned long long>(fxp::bits_of(v)));
  return buf;
}

std::string flags_str(unsigned packed) {
  const fxp::Flags f = fxp::Flags::from_packed(packed);
  return std::string(f.sat_pos ? "+" : "-") + (f.sat_neg ? "-" : ".");
}

// ---------------------------------------------------------------------------
// Group 1 — op vectors
// ---------------------------------------------------------------------------

bool check_ops(const std::string& path) {
  std::vector<fxp::vectors::OpVector> vecs;
  fxp::vectors::Header hdr;
  std::string err;
  if (!fxp::vectors::load_ops(path, &vecs, &hdr, &err)) {
    std::printf("  FAIL loading vectors: %s\n", err.c_str());
    ++g_failures;
    return false;
  }
  if (hdr.rounding_mode != fxp::vectors::expected_rounding_mode()) {
    std::printf(
        "  FAIL %s was generated for rounding mode '%s' but this build of "
        "fxp.hpp uses '%s'\n",
        path.c_str(), hdr.rounding_mode.c_str(),
        fxp::vectors::expected_rounding_mode());
    ++g_failures;
    return false;
  }

  const int before = g_failures;
  for (const fxp::vectors::OpVector& v : vecs) {
    const fxp::ops::Result r = fxp::ops::apply(v.code, v.a, v.b, v.sh, v.w);
    ++g_checks;
    if (r.y != v.y || r.flags.packed() != v.flags) {
      fail("op vector " + v.id + " (" + v.op + " a=" + std::to_string(v.a) +
           " b=" + std::to_string(v.b) + " sh=" + std::to_string(v.sh) +
           " w=" + std::to_string(v.w) + "): expected y=" +
           std::to_string(v.y) + " " + hex64(v.y) + " flags=" +
           flags_str(v.flags) + ", got y=" + std::to_string(r.y) + " " +
           hex64(r.y) + " flags=" + flags_str(r.flags.packed()));
    }
  }
  std::printf("  ops     : %zu vectors, seed=%llu, mode=%s -> %s\n",
              vecs.size(), static_cast<unsigned long long>(hdr.seed),
              hdr.rounding_mode.c_str(),
              g_failures == before ? "all bit-exact" : "MISMATCH");
  return g_failures == before;
}

// ---------------------------------------------------------------------------
// Group 2 — accumulator sequences
// ---------------------------------------------------------------------------

bool check_accum(const std::string& path) {
  std::vector<fxp::vectors::AccumStep> steps;
  fxp::vectors::Header hdr;
  std::string err;
  if (!fxp::vectors::load_accum(path, &steps, &hdr, &err)) {
    std::printf("  FAIL loading vectors: %s\n", err.c_str());
    ++g_failures;
    return false;
  }

  const int before = g_failures;
  std::size_t sequences = 0;
  fxp::Acc acc(fxp::kProdW);
  std::string current;

  for (const fxp::vectors::AccumStep& s : steps) {
    if (s.step == 0) {
      // A new sequence always starts from a cleared accumulator at its own
      // width, which is also how the RTL cross-check drives the probe.
      acc = fxp::Acc(s.acc_w);
      current = s.id;
      ++sequences;
    }
    if (s.id != current) {
      fail("accum vector " + s.id + " step " + std::to_string(s.step) +
           ": sequence does not begin at step 0");
      break;
    }
    acc.add(s.x);
    ++g_checks;
    // Value, sticky flags and event count after the step. The vector's
    // per-step `step_flags` column is checked separately, by
    // check_accum_step_flags(), which replays the sequence at the primitive
    // level rather than through fxp::Acc.
    const unsigned sticky = acc.flags().sticky().packed();
    if (acc.value() != s.y || sticky != s.sticky_flags ||
        acc.flags().event_count() != s.count) {
      fail("accum vector " + s.id + " step " + std::to_string(s.step) +
           " (w=" + std::to_string(s.acc_w) + " x=" + std::to_string(s.x) +
           "): expected y=" + std::to_string(s.y) + " sticky=" +
           flags_str(s.sticky_flags) + " count=" + std::to_string(s.count) +
           ", got y=" + std::to_string(acc.value()) + " sticky=" +
           flags_str(sticky) + " count=" +
           std::to_string(acc.flags().event_count()));
    }
  }
  std::printf("  accum   : %zu steps in %zu sequences -> %s\n", steps.size(),
              sequences, g_failures == before ? "all bit-exact" : "MISMATCH");
  return g_failures == before;
}

// Re-checks each step's own flags by replaying the sequence with an explicit
// pre-clamp evaluation, which is what the vector's `step_flags` column records.
bool check_accum_step_flags(const std::string& path) {
  std::vector<fxp::vectors::AccumStep> steps;
  std::string err;
  if (!fxp::vectors::load_accum(path, &steps, nullptr, &err)) return false;

  const int before = g_failures;
  fxp::wide_t value = 0;
  for (const fxp::vectors::AccumStep& s : steps) {
    if (s.step == 0) value = 0;
    const fxp::wide_t sum = fxp::add_wrap(value, s.x);
    const fxp::Flags f = fxp::sat_flags(sum, s.acc_w);
    value = fxp::sat(sum, s.acc_w);
    ++g_checks;
    if (f.packed() != s.step_flags) {
      fail("accum step flags " + s.id + " step " + std::to_string(s.step) +
           ": expected " + flags_str(s.step_flags) + ", got " +
           flags_str(f.packed()));
    }
  }
  return g_failures == before;
}

// ---------------------------------------------------------------------------
// Group 4 — complex-multiplier vectors (issue #9)
//
// model/vectors/cmult.vec against model/cpp/fxp/cmult.hpp: the exact
// full-precision product, the rounded Q1.15 product and both flag words, for
// BOTH arithmetic variants. Every record is evaluated twice — once through the
// four-multiply path, once through the Karatsuba path — and both must equal the
// NumPy expectation. A factorization error therefore fails here, before the RTL
// is ever built, which is the order SPEC 12.4 requires.
// ---------------------------------------------------------------------------

bool check_cmult(const std::string& path) {
  std::vector<fxp::vectors::CmultVector> vecs;
  fxp::vectors::Header hdr;
  std::string err;
  if (!fxp::vectors::load_cmult(path, &vecs, &hdr, &err)) {
    std::printf("  FAIL loading vectors: %s\n", err.c_str());
    ++g_failures;
    return false;
  }
  if (hdr.kind != "cmult") {
    std::printf("  FAIL %s: kind '%s', expected 'cmult'\n", path.c_str(),
                hdr.kind.c_str());
    ++g_failures;
    return false;
  }
  if (hdr.rounding_mode != fxp::vectors::expected_rounding_mode()) {
    std::printf("  FAIL %s: rounding_mode '%s', this build is '%s'\n",
                path.c_str(), hdr.rounding_mode.c_str(),
                fxp::vectors::expected_rounding_mode());
    ++g_failures;
    return false;
  }
  // A vector set written for a different full-precision width would silently
  // "pass" against whichever implementation happened to match it.
  if (hdr.prod_w != fxp::cmult::kCmulProdW) {
    std::printf("  FAIL %s: prod_w %u, this build is %u\n", path.c_str(),
                hdr.prod_w, fxp::cmult::kCmulProdW);
    ++g_failures;
    return false;
  }

  const int before = g_failures;
  for (const fxp::vectors::CmultVector& v : vecs) {
    for (const fxp::cmult::Variant variant :
         {fxp::cmult::Variant::kMult4, fxp::cmult::Variant::kMult3}) {
      const char* vname =
          variant == fxp::cmult::Variant::kMult3 ? "MULT3" : "MULT4";
      const fxp::cmult::Result r = fxp::cmult::eval(variant, v.a, v.b);
      const std::string where =
          v.id + " [" + vname + "] (" + std::to_string(v.a.re) + "," +
          std::to_string(v.a.im) + ")*(" + std::to_string(v.b.re) + "," +
          std::to_string(v.b.im) + ")";
      expect(r.p_re == v.p_re,
             where + ": p_re " + std::to_string(r.p_re) + " != vector " +
                 std::to_string(v.p_re));
      expect(r.p_im == v.p_im,
             where + ": p_im " + std::to_string(r.p_im) + " != vector " +
                 std::to_string(v.p_im));
      expect(r.y_re == v.y_re,
             where + ": y_re " + std::to_string(r.y_re) + " != vector " +
                 std::to_string(v.y_re));
      expect(r.y_im == v.y_im,
             where + ": y_im " + std::to_string(r.y_im) + " != vector " +
                 std::to_string(v.y_im));
      expect(r.f_re.packed() == v.flags_re,
             where + ": flags_re " + flags_str(r.f_re.packed()) +
                 " != vector " + flags_str(v.flags_re));
      expect(r.f_im.packed() == v.flags_im,
             where + ": flags_im " + flags_str(r.f_im.packed()) +
                 " != vector " + flags_str(v.flags_im));
      expect(r.ovf == (v.flags_re != 0 || v.flags_im != 0),
             where + ": ovf disagrees with the flag words");
      // The exact product must fit the declared width; this is the RTL's
      // 34-bit-to-33-bit post-adder cast, checked in the model.
      expect(fxp::cmult::fits_prod(r.p_re) && fxp::cmult::fits_prod(r.p_im),
             where + ": full-precision product does not fit " +
                 std::to_string(fxp::cmult::kCmulProdW) + " bits");
    }
    // ROUND_OUT = 0 leaves the Q1.15 outputs and the flags at zero.
    const fxp::cmult::Result full =
        fxp::cmult::eval(fxp::cmult::Variant::kMult4, v.a, v.b, false);
    expect(full.p_re == v.p_re && full.p_im == v.p_im,
           v.id + ": ROUND_OUT=0 changed the full-precision product");
    expect(full.y_re == 0 && full.y_im == 0 && !full.f_re.any() &&
               !full.f_im.any() && !full.ovf,
           v.id + ": ROUND_OUT=0 did not tie off the rounded outputs");
  }

  std::printf("  cmult   : %zu records (seed %llu, prod_w %u), both variants\n",
              vecs.size(), static_cast<unsigned long long>(hdr.seed),
              hdr.prod_w);
  return g_failures == before;
}

// ---------------------------------------------------------------------------
// Group 3 — properties no finite vector set establishes on its own
// ---------------------------------------------------------------------------

void check_properties() {
  using namespace fxp;

  // Shift 0 is the identity for every quantiser.
  for (wide_t v : {wide_t{-32768}, wide_t{-1}, wide_t{0}, wide_t{1},
                   wide_t{32767}, wide_t{1} << 40}) {
    expect(round_even(v, 0) == v, "round_even(v,0) != v");
    expect(round_half_up(v, 0) == v, "round_half_up(v,0) != v");
    expect(trunc(v, 0) == v, "trunc(v,0) != v");
  }

  // Saturation is idempotent and never leaves the target range.
  for (unsigned w = 2; w <= 48; ++w) {
    for (wide_t v : {min_of(w) - 3, min_of(w), wide_t{0}, max_of(w),
                     max_of(w) + 3}) {
      const wide_t s1 = sat(v, w);
      expect(sat(s1, w) == s1, "sat is not idempotent");
      expect(s1 >= min_of(w) && s1 <= max_of(w), "sat left the range");
      expect(sat_ovf(v, w) == (v < min_of(w) || v > max_of(w)),
             "sat_ovf disagrees with sat");
      expect(sat_flags(v, w).any() == sat_ovf(v, w),
             "sat_flags disagrees with sat_ovf");
    }
  }

  // Q1.15 endpoints are what NUMERICS.md 2 says they are.
  expect(q15_max() == 32767, "q15_max is not 0x7FFF");
  expect(q15_min() == -32768, "q15_min is not 0x8000");

  // The asymmetry that motivates the saturating negate.
  expect(neg_sat(q15_min(), kSampleW) == q15_max(),
         "-(-1.0) does not saturate to +max");
  expect(neg_sat_flags(q15_min(), kSampleW).sat_pos,
         "-(-1.0) does not raise sat_pos");
  expect(mul_q15(q15_min(), q15_min()) == (1 << 30),
         "(-1.0)*(-1.0) is not 2^30 in Q2.30");
  expect(mul_q15_rs(q15_min(), q15_min()) == q15_max(),
         "(-1.0)*(-1.0) does not saturate to +max in Q1.15");

  // The project rule really is round-to-nearest-even.
  expect(kRoundMode == RoundMode::kNearestEven,
         "kRoundMode is not kNearestEven");
  for (unsigned s = 0; s <= 40; ++s) {
    const wide_t v = (wide_t{1} << 41) - 12345;
    expect(round(v, s) == round_even(v, s), "round() is not round_even()");
  }

  // The four tie classes, spelled out (s = 1, so one LSB is one half).
  expect(round_even(3, 1) == 2, "RNE(+1.5) != +2");
  expect(round_even(1, 1) == 0, "RNE(+0.5) != 0");
  expect(round_even(-1, 1) == 0, "RNE(-0.5) != 0");
  expect(round_even(-3, 1) == -2, "RNE(-1.5) != -2");
  expect(round_half_up(3, 1) == 2, "RHU(+1.5) != +2");
  expect(round_half_up(1, 1) == 1, "RHU(+0.5) != +1");
  expect(round_half_up(-1, 1) == 0, "RHU(-0.5) != 0");
  expect(round_half_up(-3, 1) == -1, "RHU(-1.5) != -1");

  // Measured bias over a complete residue sweep — the number NUMERICS.md 4 and
  // DECISIONS.md quote as the reason for choosing convergent rounding. Over a
  // contiguous range of inputs, round-to-nearest-even's total error is zero;
  // round-half-up's is +N/2 LSB where N is the number of exact ties.
  {
    constexpr unsigned s = 3;
    constexpr wide_t scale = wide_t{1} << s;
    constexpr wide_t lo = -(wide_t{1} << 16);
    constexpr wide_t hi = wide_t{1} << 16;
    wide_t err_rne = 0;
    wide_t err_rhu = 0;
    wide_t ties = 0;
    for (wide_t v = lo; v < hi; ++v) {
      err_rne += round_even(v, s) * scale - v;
      err_rhu += round_half_up(v, s) * scale - v;
      if ((v & (scale - 1)) == (scale >> 1)) ++ties;
    }
    expect(err_rne == 0, "round-to-nearest-even has non-zero total bias");
    expect(err_rhu == ties * (scale >> 1),
           "round-half-up bias is not +half an LSB per tie");
    std::printf("  bias    : over %lld inputs at s=%u, RNE total error = %lld, "
                "RHU total error = %lld LSB-scaled (%lld ties)\n",
                static_cast<long long>(hi - lo), s,
                static_cast<long long>(err_rne),
                static_cast<long long>(err_rhu),
                static_cast<long long>(ties));
  }

  // Accumulator-width policy: at acc_w(32, N), an N-term sum of worst-case
  // Q1.15 products provably cannot leave the accumulator range. This is the
  // property the whole no-intermediate-saturation rule rests on.
  for (unsigned n : {1u, 2u, 3u, 4u, 5u, 8u, 16u, 17u, 64u, 1024u}) {
    const unsigned w = mac_q15_acc_w(n);
    const wide_t worst = static_cast<wide_t>(n) * (wide_t{1} << 30);
    expect(worst <= max_of(w), "acc_w(32,N) cannot hold N worst-case products");
    expect(-worst >= min_of(w),
           "acc_w(32,N) cannot hold N worst-case negative products");
    expect(growth_bits(n) == w - kProdW, "growth_bits/acc_w disagree");
  }
  expect(growth_bits(1) == 0, "growth_bits(1) != 0");
  expect(growth_bits(2) == 1, "growth_bits(2) != 1");
  expect(growth_bits(3) == 2, "growth_bits(3) != 2");
  expect(growth_bits(4) == 2, "growth_bits(4) != 2");
  expect(growth_bits(5) == 3, "growth_bits(5) != 3");

  // Complex multiply packing round-trips, and the SPEC 6 formula holds.
  for (i16 re : {i16{-32768}, i16{-1}, i16{0}, i16{1}, i16{32767}}) {
    for (i16 im : {i16{-32768}, i16{0}, i16{32767}}) {
      const Complex c{re, im};
      expect(Complex::from_packed(c.packed()) == c,
             "Complex packing does not round-trip");
    }
  }
  {
    const Complex a{-32768, 0};
    const Complex b{-32768, 0};
    expect(cmul_q15(a, b).re == q15_max(),
           "(-1.0+0j)^2 real part does not saturate to +max");
    expect(cmul_q15(a, b).im == 0, "(-1.0+0j)^2 imaginary part is not 0");
    expect(cmul_q15_re_flags(a, b).sat_pos,
           "(-1.0+0j)^2 real part does not raise sat_pos");
  }

  // -------------------------------------------------------------------------
  // Complex multiplier (issue #9): the exactness of the three-multiply form,
  // and the width of the full-precision product.
  //
  // The factorization identity is an identity in Z, so it cannot be established
  // by a vector file — a vector file only says it held 864 times. What it CAN be
  // established by is an exhaustive-in-the-corners plus large-random sweep of
  // the two independently written paths, which is what this block is.
  // -------------------------------------------------------------------------
  {
    using fxp::cmult::kCmulProdW;
    using fxp::cmult::raw_mult3;
    using fxp::cmult::raw_mult4;

    expect(kCmulProdW == acc_w(kProdW, 2),
           "kCmulProdW is not the two-term MAC accumulator width");
    expect(kCmulProdW == 33, "kCmulProdW is not 33");

    // The bound is TIGHT, not conservative: (-1-1j)^2 has imaginary part +2^31,
    // which needs the 33rd bit. This is the reason the port is not 32 bits.
    {
      const Complex m{-32768, -32768};
      const fxp::cmult::Raw r = raw_mult4(m, m);
      expect(r.im == (wide_t{1} << 31), "(-1-1j)^2 imaginary part is not +2^31");
      expect(r.re == 0, "(-1-1j)^2 real part is not 0");
      expect(sat_ovf(r.im, kProdW), "+2^31 unexpectedly fits 32 bits");
      expect(!sat_ovf(r.im, kCmulProdW), "+2^31 does not fit 33 bits");
      expect(fxp::cmult::eval(fxp::cmult::Variant::kMult4, m, m).y_im ==
                 q15_max(),
             "(-1-1j)^2 rounded imaginary part does not saturate to +max");
      expect(fxp::cmult::eval(fxp::cmult::Variant::kMult4, m, m).f_im.sat_pos,
             "(-1-1j)^2 does not raise sat_pos on the imaginary part");
    }

    // Corner grid: every ordered pair of the Q1.15 boundary complex values.
    static const i16 kEdges[] = {-32768, -32767, -16384, -1, 0, 1, 16384, 32766,
                                 32767};
    wide_t agree = 0;
    wide_t widest = 0;
    for (i16 are : kEdges) {
      for (i16 aim : kEdges) {
        for (i16 bre : kEdges) {
          for (i16 bim : kEdges) {
            const Complex a{are, aim};
            const Complex b{bre, bim};
            const fxp::cmult::Raw r4 = raw_mult4(a, b);
            const fxp::cmult::Raw r3 = raw_mult3(a, b);
            if (r4 != r3) {
              fail("MULT3 disagrees with MULT4 on a corner pair");
            } else {
              ++agree;
            }
            if (!fxp::cmult::fits_prod(r4.re) ||
                !fxp::cmult::fits_prod(r4.im)) {
              fail("corner-pair product does not fit the declared width");
            }
            const wide_t m = r4.re < 0 ? -r4.re : r4.re;
            if (m > widest) widest = m;
            const wide_t n = r4.im < 0 ? -r4.im : r4.im;
            if (n > widest) widest = n;
            // The rounded output IS fxp::cmul_q15, not a second definition.
            const fxp::cmult::Result e =
                fxp::cmult::eval(fxp::cmult::Variant::kMult3, a, b);
            const Complex pkg = fxp::cmult::rounded_via_pkg(a, b);
            if (e.y_re != pkg.re || e.y_im != pkg.im) {
              fail("cmult::eval disagrees with fxp::cmul_q15");
            }
          }
        }
      }
    }
    g_checks += 3;
    expect(agree == 9LL * 9 * 9 * 9, "corner-grid agreement count is wrong");
    expect(widest == (wide_t{1} << 31),
           "the corner grid never reaches the +2^31 extreme");

    // A large pseudo-random sweep, with a fixed multiplier so the set is the
    // same on every machine and every run. xorshift64*, not std::mt19937,
    // because this file must build with nothing but <cstdio> and friends.
    {
      std::uint64_t s = 0x9E3779B97F4A7C15ULL;
      auto next = [&s]() {
        s ^= s >> 12;
        s ^= s << 25;
        s ^= s >> 27;
        return s * 0x2545F4914F6CDD1DULL;
      };
      constexpr int kSweep = 200000;
      int bad = 0;
      int overwide = 0;
      for (int i = 0; i < kSweep; ++i) {
        const std::uint64_t w = next();
        const Complex a{static_cast<i16>(w & 0xFFFFU),
                        static_cast<i16>((w >> 16) & 0xFFFFU)};
        const Complex b{static_cast<i16>((w >> 32) & 0xFFFFU),
                        static_cast<i16>((w >> 48) & 0xFFFFU)};
        const fxp::cmult::Raw r4 = raw_mult4(a, b);
        if (r4 != raw_mult3(a, b)) ++bad;
        if (!fxp::cmult::fits_prod(r4.re) || !fxp::cmult::fits_prod(r4.im)) {
          ++overwide;
        }
      }
      expect(bad == 0, "MULT3 disagrees with MULT4 on a random pair");
      expect(overwide == 0,
             "a random product did not fit the declared full-precision width");
      std::printf("  cmult   : MULT3 == MULT4 on %d corner pairs and %d random "
                  "pairs; max |product| = 2^31\n",
                  9 * 9 * 9 * 9, kSweep);
    }
  }

  // Sticky flags: sticky, clear-wins, and a counter that saturates.
  {
    StickyFlags sf;
    sf.step(true, Flags{true, false});
    sf.step(true, Flags{});
    expect(sf.any(), "sticky flag did not stick");
    expect(sf.event_count() == 1, "sticky counter counted a non-event");
    sf.step(true, Flags{true, false}, /*clear=*/true);
    expect(!sf.any(), "clear did not win over a simultaneous event");
    expect(sf.event_count() == 0, "clear did not reset the counter");
  }
}

}  // namespace

int main(int argc, char** argv) {
  std::string dir = "model/vectors";
  for (int i = 1; i < argc; ++i) {
    if (std::strcmp(argv[i], "--vectors") == 0 && i + 1 < argc) {
      dir = argv[++i];
    } else {
      std::fprintf(stderr, "usage: %s [--vectors DIR]\n", argv[0]);
      return 2;
    }
  }

  std::printf("=== %s ===\n", kTestName);
  std::printf("  vectors : %s\n", dir.c_str());

  const bool ops_ok = check_ops(dir + "/fxp_ops.vec");
  const bool acc_ok = check_accum(dir + "/fxp_accum.vec");
  const bool acc_flags_ok = check_accum_step_flags(dir + "/fxp_accum.vec");
  const bool cmult_ok = check_cmult(dir + "/cmult.vec");
  check_properties();

  std::printf("  checks  : %d, failures: %d\n", g_checks, g_failures);
  const bool passed =
      g_failures == 0 && ops_ok && acc_ok && acc_flags_ok && cmult_ok;
  if (passed) {
    std::printf("RESULT: PASS test=%s checks=%d\n", kTestName, g_checks);
    return 0;
  }
  std::printf("RESULT: FAIL test=%s checks=%d failures=%d\n", kTestName,
              g_checks, g_failures);
  return 1;
}
