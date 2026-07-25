// -----------------------------------------------------------------------------
// fxp_pkg — the single shared fixed-point package (SPEC.md 6).
//
// SPEC 6 ("Rounding and saturation"): "Define one shared package containing:
// signed rounding rules, convergent or round-to-nearest behavior, saturation
// functions, truncation locations, accumulator widths, overflow flags. Do not
// allow each module to invent its own rounding behavior. The C++ reference
// model and RTL must use identical numerical rules."
//
// This file is that package. NUMERICS.md is its normative prose; model/cpp/fxp/
// is its bit-identical C++ twin; model/python/fxp_reference.py is an
// independent NumPy implementation used only to generate the golden vectors
// that prove the two agree. Where this file and NUMERICS.md disagree, one of
// them is a defect — fix both together.
//
// THE RULE (SPEC 6, restated because it is the reason this file exists)
// --------------------------------------------------------------------
// No module may implement its own rounding, saturation or truncation. Every
// quantisation in the design is a call into this package. A module that writes
// `>> 15` or `+ 16384` inline is a bug even when the arithmetic happens to be
// right, because the next module will write it differently.
//
// Working type
// ------------
// Every function operates on `fxp_wide_t` — signed 64-bit — and takes the
// target width or shift as an argument, because SystemVerilog has no
// parameterised subroutines (IEEE 1800-2017 has no `function #(...)`), and a
// per-width copy of each function is exactly the duplication SPEC 6 forbids.
// Callers cast into and out of the working type at the call site, which keeps
// the width visible in the RTL rather than hidden in an overload.
//
// Contract on the working type (checked by the vectors, not by the RTL):
//   * shift amounts `s` satisfy 0 <= s <= 63; s >= 64 returns 0.
//   * target widths `w` satisfy 2 <= w <= 64.
//   * intermediate values passed in must already fit in 64 bits with room for
//     one addition — i.e. |v| <= 2^62. Every accumulator this design defines is
//     at most 48 bits wide (FXP_PROD_W + growth for the largest configuration),
//     so the margin is ~14 bits.
//
// Lint contract: this package is linted by `make lint` on every run and must be
// clean under `--Wall` with no waiver.
// -----------------------------------------------------------------------------

`default_nettype none

package fxp_pkg;

  // ---------------------------------------------------------------------------
  // Working types
  // ---------------------------------------------------------------------------

  // Width of the internal working type. Not a design width: no register in the
  // benchmark is 64 bits wide. It is the width every function computes in so
  // that intermediate growth cannot wrap before saturation is applied.
  localparam int unsigned FXP_WIDE_W = 64;

  typedef logic signed [FXP_WIDE_W-1:0] fxp_wide_t;

  // Unsigned 32-bit integer type. Exists so widths and shift counts can be cast
  // explicitly (`uint_t'(x)`); `int unsigned'(x)` is not legal cast syntax.
  typedef int unsigned uint_t;

  // ---------------------------------------------------------------------------
  // Formats (SPEC 6 "Input format" / "Coefficients", SPEC 3 invariant widths)
  // ---------------------------------------------------------------------------

  // Q1.15: signed 16-bit, one sign bit, 15 fractional bits.
  // Range [-1.0, +1.0 - 2^-15]; resolution 2^-15.
  localparam int unsigned FXP_SAMPLE_W = 16;  // SPEC 3 SAMPLE_W
  localparam int unsigned FXP_COEFF_W  = 16;  // SPEC 3 COEFF_W
  localparam int unsigned FXP_FRAC_W   = 15;  // fractional bits in Q1.15

  // Q1.15 x Q1.15 -> Q2.30: signed 32-bit, two integer bits, 30 fractional
  // bits. The product of two Q1.15 values spans [-2^30, +2^30] exactly (the
  // upper end is reached only by (-1.0)*(-1.0)), which needs 32 bits.
  localparam int unsigned FXP_PROD_W      = 32;
  localparam int unsigned FXP_PROD_FRAC_W = 30;

  // Fractional bits discarded when a Q2.30 product returns to Q1.15. Derived,
  // not written as 15, because the day a format changes this must move with it.
  localparam int unsigned FXP_PROD_SHIFT = FXP_PROD_FRAC_W - FXP_FRAC_W;  // 15

  typedef logic signed [FXP_SAMPLE_W-1:0] fxp16_t;      // Q1.15 sample
  typedef logic signed [FXP_COEFF_W-1:0]  fxp_coeff_t;  // Q1.15 coefficient
  typedef logic signed [FXP_PROD_W-1:0]   fxp32_t;      // Q2.30 product

  // Complex sample / coefficient. Field order is {im, re} so that the packed
  // vector's low half is the real part, matching how the C++ model and the
  // vector files pack a complex operand into one integer.
  typedef struct packed {
    fxp16_t im;
    fxp16_t re;
  } fxp_complex_t;

  typedef struct packed {
    fxp32_t im;
    fxp32_t re;
  } fxp_complex32_t;

  // Q1.15 endpoints are exported as functions (fxp_q15_max / fxp_q15_min, below,
  // next to fxp_max_of / fxp_min_of) rather than as literal constants, so there
  // is no second copy of 0x7FFF / 0x8000 that can drift away from the general
  // saturation rule.

  // ---------------------------------------------------------------------------
  // Rounding mode selection
  //
  // PROJECT RULE: round-to-nearest, ties-to-even (convergent). Rationale is in
  // NUMERICS.md 4 and DECISIONS.md; the short version is that round-half-up
  // carries a +2^-(k+1) mean error that is coherent across taps, FFT stages and
  // beamformer accumulations and lands as a DC/bias term in the power estimate
  // that CFAR then thresholds against.
  //
  // fxp_round_half_up() is implemented and exported because NUMERICS.md
  // documents the comparison and the vector set proves both, NOT because it may
  // be used in a datapath. Datapath code calls fxp_round() / fxp_round_sat()
  // and nothing else.
  // ---------------------------------------------------------------------------

  localparam int unsigned FXP_ROUND_MODE_NEAREST_EVEN = 0;
  localparam int unsigned FXP_ROUND_MODE_HALF_UP      = 1;

  // The project-wide rule. Changing this constant changes every quantisation in
  // the design and invalidates every golden vector; it is a DECISIONS.md event,
  // not a tuning knob.
  localparam int unsigned FXP_ROUND_MODE = FXP_ROUND_MODE_NEAREST_EVEN;

  // ---------------------------------------------------------------------------
  // Range endpoints for a signed field of `w` bits
  // ---------------------------------------------------------------------------

  // Largest value representable in a signed w-bit field: 2^(w-1) - 1.
  function automatic fxp_wide_t fxp_max_of(input uint_t w);
    fxp_wide_t one;
    one = 64'sd1;
    if (w >= FXP_WIDE_W)  fxp_max_of = fxp_wide_t'(64'h7FFF_FFFF_FFFF_FFFF);
    else if (w < 2)       fxp_max_of = 64'sd0;  // out of contract; degenerate
    else                  fxp_max_of = (one <<< (w - 1)) - one;
  endfunction

  // Smallest value representable in a signed w-bit field: -2^(w-1).
  function automatic fxp_wide_t fxp_min_of(input uint_t w);
    fxp_wide_t one;
    one = 64'sd1;
    if (w >= FXP_WIDE_W)  fxp_min_of = fxp_wide_t'(64'h8000_0000_0000_0000);
    else if (w < 2)       fxp_min_of = 64'sd0;  // out of contract; degenerate
    else                  fxp_min_of = -(one <<< (w - 1));
  endfunction

  // Q1.15 endpoints. Saturation is to the full two's-complement range, so the
  // negative endpoint is exactly -1.0 and the positive endpoint is one LSB short
  // of +1.0. That asymmetry is real and is the reason -(-1.0) saturates.
  function automatic fxp16_t fxp_q15_max();  // 16'h7FFF = +0.999969482421875
    fxp_q15_max = fxp16_t'(fxp_max_of(FXP_SAMPLE_W));
  endfunction

  function automatic fxp16_t fxp_q15_min();  // 16'h8000 = -1.0
    fxp_q15_min = fxp16_t'(fxp_min_of(FXP_SAMPLE_W));
  endfunction

  // ---------------------------------------------------------------------------
  // Saturation (SPEC 6 "Saturation functions")
  //
  // Clamp, never wrap. A wrapped overflow turns a large positive detection into
  // a large negative one, which CFAR cannot distinguish from a real target;
  // clamping degrades gracefully and sets a flag.
  //
  // Saturation is to the FULL two's-complement range [-2^(w-1), 2^(w-1)-1], not
  // to a symmetric range. See NUMERICS.md 5 for why.
  // ---------------------------------------------------------------------------

  function automatic logic fxp_sat_ovf(input fxp_wide_t v, input uint_t w);
    fxp_sat_ovf = (v > fxp_max_of(w)) || (v < fxp_min_of(w));
  endfunction

  function automatic fxp_wide_t fxp_sat(input fxp_wide_t v, input uint_t w);
    if (v > fxp_max_of(w))       fxp_sat = fxp_max_of(w);
    else if (v < fxp_min_of(w))  fxp_sat = fxp_min_of(w);
    else                         fxp_sat = v;
  endfunction

  // ---------------------------------------------------------------------------
  // Truncation (SPEC 6 "Truncation locations")
  //
  // Arithmetic right shift = floor(v / 2^s) = round toward -infinity. This is
  // what a bare `>>>` does and it is BIASED by -0.5 LSB on average; it is
  // provided so that the places which deliberately truncate (see NUMERICS.md 6,
  // "truncation points policy") say so by calling this function, and so that a
  // reviewer grepping for quantisation finds them.
  // ---------------------------------------------------------------------------

  function automatic fxp_wide_t fxp_trunc(input fxp_wide_t v, input uint_t s);
    if (s == 0)                fxp_trunc = v;
    else if (s >= FXP_WIDE_W)  fxp_trunc = (v < 0) ? -64'sd1 : 64'sd0;
    else                       fxp_trunc = v >>> s;
  endfunction

  // ---------------------------------------------------------------------------
  // Rounding
  //
  // Both modes implemented; see the rounding-mode block above for which one the
  // datapath is allowed to call.
  // ---------------------------------------------------------------------------

  // Round-half-up: floor((v + 2^(s-1)) / 2^s).
  //
  // Cheap (a carry-in, free inside a DSP block) but asymmetric: exact halves
  // always move toward +infinity, so -0.5 -> 0 while +0.5 -> +1. Mean error
  // +2^-(s+1) LSB. NOT the project rule.
  function automatic fxp_wide_t fxp_round_half_up(input fxp_wide_t v,
                                                  input uint_t    s);
    fxp_wide_t half;
    if (s == 0)                fxp_round_half_up = v;
    else if (s >= FXP_WIDE_W)  fxp_round_half_up = 64'sd0;
    else begin
      half              = 64'sd1 <<< (s - 1);
      fxp_round_half_up = (v + half) >>> s;
    end
  endfunction

  // Round-to-nearest, ties-to-even (convergent). THE PROJECT RULE.
  //
  //   rem = v mod 2^s   (floor remainder, always in [0, 2^s) even for v < 0)
  //   rem >  half  ->  q + 1
  //   rem <  half  ->  q
  //   rem == half  ->  q + (q & 1)   i.e. move to the even neighbour
  //
  // Zero mean error for input whose sub-LSB residue is uniform, and symmetric
  // about zero: RNE(+1.5)=+2, RNE(+0.5)=0, RNE(-0.5)=0, RNE(-1.5)=-2.
  function automatic fxp_wide_t fxp_round_even(input fxp_wide_t v,
                                               input uint_t    s);
    fxp_wide_t q, half, rem, mask;
    if (s == 0)                fxp_round_even = v;
    else if (s >= FXP_WIDE_W)  fxp_round_even = 64'sd0;
    else begin
      mask = (64'sd1 <<< s) - 64'sd1;
      half = 64'sd1 <<< (s - 1);
      q    = v >>> s;
      rem  = v & mask;
      if (rem > half)       fxp_round_even = q + 64'sd1;
      else if (rem < half)  fxp_round_even = q;
      else                  fxp_round_even = q + (q & 64'sd1);
    end
  endfunction

  // The datapath rounding entry point. This is the ONLY rounding function RTL
  // outside this package may call. The selection folds at elaboration time —
  // FXP_ROUND_MODE is a localparam, so exactly one of the two implementations
  // reaches synthesis — and it is written as a selection rather than as a
  // direct call so that flipping the project rule is a one-line change here
  // and nowhere else.
  function automatic fxp_wide_t fxp_round(input fxp_wide_t v, input uint_t s);
    fxp_round = (FXP_ROUND_MODE == FXP_ROUND_MODE_HALF_UP)
                  ? fxp_round_half_up(v, s)
                  : fxp_round_even(v, s);
  endfunction

  // ---------------------------------------------------------------------------
  // Composite quantisation: round then saturate
  //
  // Order matters and is fixed: round FIRST, saturate SECOND. Rounding a value
  // that already sits at the top of the target range can push it one LSB over
  // (0x7FFF.8 -> 0x8000), and only a saturation applied afterwards catches it.
  // Saturating first would clamp, then round the clamped value, and silently
  // report no overflow.
  // ---------------------------------------------------------------------------

  function automatic fxp_wide_t fxp_round_sat(input fxp_wide_t v,
                                              input uint_t    s,
                                              input uint_t    w);
    fxp_round_sat = fxp_sat(fxp_round(v, s), w);
  endfunction

  function automatic logic fxp_round_sat_ovf(input fxp_wide_t v,
                                             input uint_t    s,
                                             input uint_t    w);
    fxp_round_sat_ovf = fxp_sat_ovf(fxp_round(v, s), w);
  endfunction

  // ---------------------------------------------------------------------------
  // Saturating add / subtract / negate
  //
  // The sum is formed at the full 64-bit working width and clamped to `w`, so
  // the intermediate can never wrap for any w <= 63 given the input contract.
  // ---------------------------------------------------------------------------

  function automatic fxp_wide_t fxp_add_sat(input fxp_wide_t a,
                                            input fxp_wide_t b,
                                            input uint_t    w);
    fxp_add_sat = fxp_sat(a + b, w);
  endfunction

  function automatic logic fxp_add_sat_ovf(input fxp_wide_t a,
                                           input fxp_wide_t b,
                                           input uint_t    w);
    fxp_add_sat_ovf = fxp_sat_ovf(a + b, w);
  endfunction

  function automatic fxp_wide_t fxp_sub_sat(input fxp_wide_t a,
                                            input fxp_wide_t b,
                                            input uint_t    w);
    fxp_sub_sat = fxp_sat(a - b, w);
  endfunction

  function automatic logic fxp_sub_sat_ovf(input fxp_wide_t a,
                                           input fxp_wide_t b,
                                           input uint_t    w);
    fxp_sub_sat_ovf = fxp_sat_ovf(a - b, w);
  endfunction

  // Negation saturates: -(-2^(w-1)) is not representable in w bits. In Q1.15
  // this is the -1.0 case, which is why the asymmetric range is worth a flag.
  function automatic fxp_wide_t fxp_neg_sat(input fxp_wide_t a, input uint_t w);
    fxp_neg_sat = fxp_sat(-a, w);
  endfunction

  function automatic logic fxp_neg_sat_ovf(input fxp_wide_t a, input uint_t w);
    fxp_neg_sat_ovf = fxp_sat_ovf(-a, w);
  endfunction

  // ---------------------------------------------------------------------------
  // Q1.15 multiply (SPEC 6 "Multiplication")
  // ---------------------------------------------------------------------------

  // Exact Q1.15 x Q1.15 -> Q2.30. Cannot overflow 32 bits: the extreme case
  // (-1.0)*(-1.0) is 0x4000_0000 = +2^30.
  function automatic fxp32_t fxp_mul_q15(input fxp16_t a, input fxp16_t b);
    fxp_mul_q15 = fxp32_t'(a) * fxp32_t'(b);
  endfunction

  // Q1.15 x Q1.15 -> Q1.15, rounded then saturated. The single scalar
  // quantisation primitive; every scalar coefficient multiply in the design is
  // this function or an unrounded fxp_mul_q15 feeding an accumulator.
  function automatic fxp16_t fxp_mul_q15_rs(input fxp16_t a, input fxp16_t b);
    fxp_mul_q15_rs = fxp16_t'(fxp_round_sat(fxp_wide_t'(fxp_mul_q15(a, b)),
                                            FXP_PROD_SHIFT, FXP_SAMPLE_W));
  endfunction

  function automatic logic fxp_mul_q15_rs_ovf(input fxp16_t a, input fxp16_t b);
    fxp_mul_q15_rs_ovf = fxp_round_sat_ovf(fxp_wide_t'(fxp_mul_q15(a, b)),
                                           FXP_PROD_SHIFT, FXP_SAMPLE_W);
  endfunction

  // ---------------------------------------------------------------------------
  // Complex multiply (SPEC 6: four-real-multiply form)
  //
  //   real = a_re*b_re - a_im*b_im
  //   imag = a_re*b_im + a_im*b_re
  //
  // Both partial products are summed at full Q2.30 precision and the result is
  // rounded ONCE, at the output. Rounding each partial product first would
  // double the quantisation noise and would not match the C++ model. The
  // three-real-multiply variant SPEC 6 also asks for is an arithmetic
  // restructuring of the same numerics and belongs to the kernel that uses it
  // (issues #11/#12); it must produce this exact result.
  // ---------------------------------------------------------------------------

  function automatic fxp_wide_t fxp_cmul_q15_re_raw(input fxp_complex_t a,
                                                    input fxp_complex_t b);
    fxp_cmul_q15_re_raw = fxp_wide_t'(fxp_mul_q15(a.re, b.re))
                        - fxp_wide_t'(fxp_mul_q15(a.im, b.im));
  endfunction

  function automatic fxp_wide_t fxp_cmul_q15_im_raw(input fxp_complex_t a,
                                                    input fxp_complex_t b);
    fxp_cmul_q15_im_raw = fxp_wide_t'(fxp_mul_q15(a.re, b.im))
                        + fxp_wide_t'(fxp_mul_q15(a.im, b.re));
  endfunction

  function automatic fxp_complex_t fxp_cmul_q15(input fxp_complex_t a,
                                                input fxp_complex_t b);
    fxp_cmul_q15.re = fxp16_t'(fxp_round_sat(fxp_cmul_q15_re_raw(a, b),
                                             FXP_PROD_SHIFT, FXP_SAMPLE_W));
    fxp_cmul_q15.im = fxp16_t'(fxp_round_sat(fxp_cmul_q15_im_raw(a, b),
                                             FXP_PROD_SHIFT, FXP_SAMPLE_W));
  endfunction

  // ---------------------------------------------------------------------------
  // Accumulator width policy (SPEC 6 "Accumulator widths")
  //
  //   growth(N)   = ceil(log2(N))                 [ $clog2, so growth(1) = 0 ]
  //   acc_w(P, N) = P + growth(N)
  //
  // For an N-term sum of Q1.15 x Q1.15 products, P = FXP_PROD_W = 32 and the
  // accumulator is 32 + ceil(log2 N) bits. That is EXACT for power-of-two N and
  // conservative by at most one bit otherwise (N=3 gets 34 bits where 33 would
  // do). The design pays one flip-flop rather than carrying a per-N special
  // case, and in exchange the accumulator itself provably cannot overflow: the
  // only saturation in a MAC is the final round-and-saturate back to Q1.15.
  //
  // Consequence, stated because it is load-bearing for every kernel: no
  // intermediate saturation inside an accumulation tree. A tree that saturates
  // internally is not associative, and its result would depend on the reduction
  // order, which is exactly the kind of thing that makes RTL and model diverge.
  // ---------------------------------------------------------------------------

  function automatic uint_t fxp_growth_bits(input uint_t n_terms);
    fxp_growth_bits = (n_terms <= 1) ? 32'd0 : uint_t'($clog2(n_terms));
  endfunction

  function automatic uint_t fxp_acc_w(input uint_t prod_w, input uint_t n_terms);
    fxp_acc_w = prod_w + fxp_growth_bits(n_terms);
  endfunction

  // Accumulator width for an N-term Q1.15 MAC.
  function automatic uint_t fxp_mac_q15_acc_w(input uint_t n_terms);
    fxp_mac_q15_acc_w = fxp_acc_w(FXP_PROD_W, n_terms);
  endfunction

  // ---------------------------------------------------------------------------
  // Overflow / saturation flag conventions (SPEC 6 "Overflow flags")
  //
  // Direction is kept because it is diagnostically different: persistent
  // positive saturation is a gain-staging error, alternating positive/negative
  // saturation is oscillation, and negative-only saturation on a power path is
  // a sign bug. Collapsing both into one bit throws that away for one flip-flop.
  //
  // Flags are produced combinationally alongside a result and made sticky by
  // fxp_sticky_flags (rtl/common/fxp_sticky_flags.sv). Sticky, not pulsed: a
  // one-cycle saturation 40 000 cycles into a frame must still be visible when
  // the frame ends and the telemetry plane (issue #8) reads it.
  // ---------------------------------------------------------------------------

  typedef struct packed {
    logic sat_pos;  // clamped to +max
    logic sat_neg;  // clamped to -min
  } fxp_flags_t;

  function automatic fxp_flags_t fxp_flags_none();
    fxp_flags_none = '{sat_pos: 1'b0, sat_neg: 1'b0};
  endfunction

  function automatic logic fxp_flags_any(input fxp_flags_t f);
    fxp_flags_any = f.sat_pos | f.sat_neg;
  endfunction

  function automatic fxp_flags_t fxp_flags_merge(input fxp_flags_t a,
                                                 input fxp_flags_t b);
    fxp_flags_merge = '{sat_pos: a.sat_pos | b.sat_pos,
                        sat_neg: a.sat_neg | b.sat_neg};
  endfunction

  // Direction-resolved saturation flags for clamping `v` into `w` bits.
  function automatic fxp_flags_t fxp_sat_flags(input fxp_wide_t v,
                                               input uint_t    w);
    fxp_sat_flags = '{sat_pos: (v > fxp_max_of(w)),
                      sat_neg: (v < fxp_min_of(w))};
  endfunction

endpackage : fxp_pkg

`default_nettype wire
