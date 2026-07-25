// -----------------------------------------------------------------------------
// complex_multiplier — the SPEC.md 6 complex product, in both required forms.
//
// SPEC 6 ("Multiplication") defines the four-real-multiply complex product and
// then requires a three-real-multiply alternative, "parameterized so Quartus
// results can compare" DSP consumption, ALM consumption, pipeline depth,
// routing pressure, Fmax and power. This module is that parameterization: one
// module, one set of numerics, two arithmetic realisations, a configurable
// register depth, and both output formats.
//
// It is the first Phase 2 DSP kernel and the first entry in the SPEC 18
// resource-calibration database (quartus/calibration/, scripts/run_calibration.py).
// Every later kernel — FIR lane, PFB, FFT butterfly, beamformer dot product —
// instantiates it, so its numerics and its pipeline shape are fixed here and
// nowhere else.
//
// -----------------------------------------------------------------------------
// 1. Numerics
// -----------------------------------------------------------------------------
// Operands are Q1.15 complex (fxp_pkg::fxp_complex_t). SPEC 6:
//
//     re = a.re*b.re - a.im*b.im
//     im = a.re*b.im + a.im*b.re
//
// Both partial products are summed at FULL precision and quantised ONCE, at the
// output, exactly as fxp_pkg::fxp_cmul_q15 defines it. Rounding a partial
// product first would double the quantisation noise and would not match the C++
// model (model/cpp/fxp/cmult.hpp) or the golden vectors (model/vectors/cmult.vec).
//
// EVERY quantisation in this module is a call into fxp_pkg. There is no `>>> 15`
// and no `+ 16384` anywhere below; see the standing rule at the top of
// rtl/packages/fxp_pkg.sv. What this module does implement directly is EXACT
// integer arithmetic — multiplies, adds and sign extension that cannot lose a
// bit — which is not quantisation and has no package entry point for the widths
// the three-multiply form needs.
//
// Output width of the full-precision port (read this before assuming 32)
// ----------------------------------------------------------------------
// A single Q1.15 x Q1.15 product is Q2.30 in 32 bits (fxp_pkg::FXP_PROD_W). The
// SUM of two of them is not. fxp_pkg's own accumulator-width policy says a
// two-term Q1.15 MAC needs fxp_mac_q15_acc_w(2) = 32 + ceil(log2 2) = 33 bits,
// and that bound is TIGHT here rather than conservative:
//
//     a = b = (-1.0 - 1.0j)  ->  im = (-2^15)(-2^15) + (-2^15)(-2^15) = +2^31
//
// +2^31 does not fit a signed 32-bit field; it is one past the top. So the
// full-precision port is 33 bits wide — Q3.30, thirty fractional bits, three
// integer bits including the sign — and it is EXACT: it never saturates and has
// no flags. Calling it "Q2.30" and clamping would make the "full precision"
// output not full precision, and would put a saturation event on the one input
// pair a reviewer is most likely to try first. The port width is written as
// `[FXP_PROD_W:0]` and checked against fxp_mac_q15_acc_w(2) at elaboration, so
// it moves if the format ever does.
//
// The rounded output is the ordinary Q1.15 result: fxp_round_sat at
// FXP_PROD_SHIFT into FXP_SAMPLE_W, with direction-resolved saturation flags.
// That one CAN saturate, and on exactly the case above: +2^31 >> 15 = +2^16
// rounds to 65536 and clamps to +32767 with sat_pos set.
//
// -----------------------------------------------------------------------------
// 2. The two variants, and why they are bit-identical
// -----------------------------------------------------------------------------
// VARIANT = "MULT4" — four real multiplies, two adds:
//
//     p_rr = a.re*b.re   p_ii = a.im*b.im   p_ri = a.re*b.im   p_ir = a.im*b.re
//     re   = p_rr - p_ii            im = p_ri + p_ir
//
// VARIANT = "MULT3" — three real multiplies, three pre-adds, two post-adds.
// The factorization used here is the Karatsuba/Gauss form:
//
//     k1 = a.re * (b.re + b.im)
//     k2 = b.im * (a.re + a.im)
//     k3 = b.re * (a.im - a.re)
//
//     re = k1 - k2 = a.re*b.re + a.re*b.im - a.re*b.im - a.im*b.im
//                  = a.re*b.re - a.im*b.im                              [1]
//     im = k1 + k3 = a.re*b.re + a.re*b.im + a.im*b.re - a.re*b.re
//                  = a.re*b.im + a.im*b.re                              [2]
//
// EXACTNESS. [1] and [2] are identities in the commutative ring Z: every step is
// distributivity and cancellation of INTEGER terms, with no division and no
// rounding. They therefore hold bit-exactly for two's-complement arithmetic as
// long as no intermediate wraps, which is a statement about widths and is
// discharged below. This is the whole reason the three-multiply form is allowed
// to exist in a design that quantises once: it is not an approximation of the
// four-multiply form, it is the same integer.
//
// The two forms differ ONLY in internal growth, which is what the calibration
// sweep is there to price:
//
//   term          MULT4                       MULT3
//   ------------  --------------------------  ---------------------------------
//   pre-add       none                        3 x 17-bit  (16b + 16b)
//   multiplier    4 x (16 x 16 -> 32b)        3 x (16 x 17 -> 33b)
//   post-add      2 x (32b + 32b -> 33b)      2 x (33b +/- 33b -> 33b)
//
// So MULT3 buys one multiplier at the price of three 17-bit adders AND one extra
// bit on every remaining multiplier operand and product. On a device whose DSP
// block natively does 18x19, the extra bit is free in the multiplier and the
// pre-adders are the real cost; on a device where it pushes an operand past the
// native width it is not free at all. Which of those this device does is a
// measurement, not an argument — see results/synthesis/calibration_cmult.json.
//
// Width discharge for MULT3 (the "no intermediate wraps" obligation):
//   |a.re|, |a.im|, |b.re|, |b.im| <= 2^15                  (Q1.15, 16-bit)
//   b.re + b.im, a.re + a.im, a.im - a.re  in [-2^16, 2^16-1]  -> 17 bits, exact
//   |k1|, |k2|, |k3| <= 2^15 * 2^16 = 2^31                  -> 33 bits, exact
//   |k1 - k2| = |re| <= 2^31 and |k1 + k3| = |im| <= 2^31    -> 33 bits, exact
// The post-adder is nevertheless FORMED at 34 bits and cast down to 33, so the
// last line above is a fact about the hardware rather than a fact about the
// reviewer's bound; a simulation-only assertion checks the cast is lossless on
// every cycle, and a second one checks the whole post-adder against
// fxp_pkg::fxp_cmul_q15_re_raw / _im_raw — the package's canonical four-multiply
// definition — on every cycle. See "Simulation-only proofs" at the bottom.
//
// -----------------------------------------------------------------------------
// 3. Pipeline (SPEC 23: "Provide registers on both sides of DSP-heavy operations")
// -----------------------------------------------------------------------------
// Five register locations, switched on in a fixed priority order as PIPE_STAGES
// grows, so LATENCY == PIPE_STAGES exactly, for both variants, for every legal
// value:
//
//   n = PIPE_STAGES     1     2     3     4     5
//   ------------------  ----  ----  ----  ----  ----
//   REG_IN   operands   on    on    on    on    on
//   REG_MULT products   -     on    on    on    on
//   REG_POST sums       -     -     on    on    on
//   REG_OUT  results    -     -     -     on    on
//   REG_PRE  pre-adds   -     -     -     -     on
//
// Order rationale. REG_IN and REG_MULT come first because they are the two
// registers a DSP block owns natively (input register and output/pipeline
// register): at PIPE_STAGES=2 the whole multiply is inside the block and the
// fabric sees only the post-adder. REG_POST is next because the post-adder is
// the widest fabric arithmetic in the module. REG_OUT is next because it is what
// keeps the rounding network — the only place a carry chain crosses 33 bits —
// off the path into whatever consumes this module. REG_PRE is last because only
// MULT3 has anything to put there; for MULT4 it is a second operand register,
// which is not wasted (HyperFlex can retime it forward into the multiply) but is
// not the first thing worth spending.
//
// Latency is therefore the parameter, not a table a caller has to look up, and
// sim/tests/test_cmult.cpp measures it from the RTL rather than assuming it.
//
// Free-running datapath, reset validity only (SPEC 23). The data registers have
// no clock enable and no reset: there is no chip-wide enable to distribute and
// nothing for a global reset to fan out to. Only the valid chain is reset. A
// beat's outputs are meaningful when valid_out is high and are don't-care
// otherwise, which is what makes the datapath registers retimable.
//
// No ready, on purpose. This is a fixed-latency arithmetic kernel, not a stream
// stage. Backpressure is a block-level concern and is provided by the SPEC 5
// primitives (rtl/stream/) when this module is wrapped into a lane; putting a
// ready chain here would put m_ready on the enable of every DSP register and
// undo the paragraph above. See DECISIONS.md (issue #9).
//
// -----------------------------------------------------------------------------
// 4. Simulation-only proofs
// -----------------------------------------------------------------------------
// Under `ifndef SYNTHESIS this module carries a shadow copy of {a, b} delayed to
// the post-adder level and asserts, every cycle:
//
//   a_cmult_re_matches_pkg / a_cmult_im_matches_pkg
//       the post-adder output equals fxp_pkg::fxp_cmul_q15_{re,im}_raw of the
//       shadow operands. For MULT3 this is the exactness claim of section 2,
//       checked against the package's own definition rather than against a
//       second copy of the algebra.
//   a_cmult_post_adder_fits
//       the 34-bit post-adder value is exactly representable in the 33-bit
//       output, i.e. the cast loses nothing.
//
// These are inside the module, so they hold everywhere it is instantiated, in
// every test, without any test-side wiring — the same arrangement the stream and
// CDC primitives use.
//
// Lint contract: clean under `verilator --lint-only --Wall` with no waiver.
// -----------------------------------------------------------------------------

`default_nettype none

module complex_multiplier
  import fxp_pkg::*;
#(
    // "MULT4" — four real multiplies. "MULT3" — Karatsuba/Gauss, three.
    // Bit-identical outputs; different DSP/ALM/Fmax. Checked at elaboration.
    parameter string       VARIANT     = "MULT4",

    // Total register stages == output latency in cycles. Legal range
    // [CMULT_PIPE_MIN, CMULT_PIPE_MAX] = [1, 5]; see the table in section 3.
    //
    // The default is 4 because that is what the SPEC 18 sweep measured, not
    // because four looked reasonable: at 3 the kernel reaches 490 MHz against a
    // 450 MHz target — inside the target, with no margin for the logic around it
    // — and at 4 it clears the 600 MHz probe outright. The fourth stage is the
    // output register, and the sweep shows it is the one that takes the rounding
    // network off the path into whatever consumes this module. See DECISIONS.md
    // (issue #9, decision 9) and results/synthesis/calibration_cmult.json.
    parameter int unsigned PIPE_STAGES = 4,

    // 1: produce the rounded/saturated Q1.15 output and its flags.
    // 0: full-precision port only; y_re/y_im/flags are tied off and the whole
    //    rounding network optimises away. The calibration sweep prices both.
    //
    // Declared `int unsigned` rather than `bit` so that a plain integer override
    // — Verilator's -GROUND_OUT=1, Quartus's `set_parameter -name ROUND_OUT 1` —
    // is width-clean at every tool. Legal values are 0 and 1, checked below.
    parameter int unsigned ROUND_OUT   = 1
) (
    input  wire                clk,
    input  wire                rst_n,

    // Fixed-latency valid pipeline. No ready; see section 3.
    input  wire                valid_in,
    input  wire fxp_complex_t  a,
    input  wire fxp_complex_t  b,
    output wire                valid_out,

    // Exact full-precision product, Q3.30 in FXP_PROD_W+1 = 33 bits. Never
    // saturates. See the width note in section 1.
    output wire signed [FXP_PROD_W:0] p_re,
    output wire signed [FXP_PROD_W:0] p_im,

    // Rounded Q1.15 product and its direction-resolved saturation flags.
    // Zero when ROUND_OUT = 0.
    output wire fxp16_t        y_re,
    output wire fxp16_t        y_im,
    output wire fxp_flags_t    flags_re,
    output wire fxp_flags_t    flags_im,
    output wire                ovf
);

  // ---------------------------------------------------------------------------
  // Widths and variant selection
  // ---------------------------------------------------------------------------

  // Legal PIPE_STAGES range. Exported as localparams so a sweep (the test's
  // depth sweep, the calibration matrix) names the endpoints rather than
  // repeating 1 and 5.
  localparam int unsigned CMULT_PIPE_MIN = 1;
  localparam int unsigned CMULT_PIPE_MAX = 5;

  // Full-precision product width: fxp_pkg's two-term MAC accumulator width.
  // Written as FXP_PROD_W+1 because a port width must be an expression the port
  // list can see; checked against fxp_mac_q15_acc_w(2) at elaboration below.
  localparam int unsigned PROD_W = FXP_PROD_W + 1;         // 33
  localparam int unsigned PRE_W  = FXP_SAMPLE_W + 1;       // 17
  localparam int unsigned K_W    = FXP_SAMPLE_W + PRE_W;   // 33
  localparam int unsigned SUM_W  = PROD_W + 1;             // 34

  localparam bit USE_MULT3 = (VARIANT == "MULT3");
  localparam bit DO_ROUND  = (ROUND_OUT != 0);

  // Register-stage enables. The priority order of section 3; the sum of these
  // five bits is PIPE_STAGES, which is what makes latency == the parameter.
  localparam bit EN_IN   = (PIPE_STAGES >= 1);
  localparam bit EN_MULT = (PIPE_STAGES >= 2);
  localparam bit EN_POST = (PIPE_STAGES >= 3);
  localparam bit EN_OUT  = (PIPE_STAGES >= 4);
  localparam bit EN_PRE  = (PIPE_STAGES >= 5);

  // Latency from the operand ports to the post-adder output, used by the
  // simulation-only shadow pipeline.
  localparam int unsigned PRE_POST_LAT = int'(EN_IN) + int'(EN_PRE) + int'(EN_MULT);

  typedef logic signed [PROD_W-1:0] prod_t;
  typedef logic signed [SUM_W-1:0]  sum_t;
  typedef logic signed [PRE_W-1:0]  pre_t;
  typedef logic signed [K_W-1:0]    k_t;

`ifndef SYNTHESIS
  initial begin
    if (VARIANT != "MULT4" && VARIANT != "MULT3") begin
      $fatal(1, "complex_multiplier: VARIANT=\"%s\" is not \"MULT4\" or \"MULT3\"",
             VARIANT);
    end
    if (PIPE_STAGES < CMULT_PIPE_MIN || PIPE_STAGES > CMULT_PIPE_MAX) begin
      $fatal(1, "complex_multiplier: PIPE_STAGES=%0d outside [%0d, %0d]",
             PIPE_STAGES, CMULT_PIPE_MIN, CMULT_PIPE_MAX);
    end
    if (ROUND_OUT > 1) begin
      $fatal(1, "complex_multiplier: ROUND_OUT=%0d is not 0 or 1", ROUND_OUT);
    end
    // The full-precision port must be exactly fxp_pkg's two-term MAC width. If
    // the format ever changes, this is where it is caught, not in a vector diff.
    if (PROD_W != fxp_mac_q15_acc_w(uint_t'(2))) begin
      $fatal(1, "complex_multiplier: PROD_W=%0d but fxp_mac_q15_acc_w(2)=%0d",
             PROD_W, fxp_mac_q15_acc_w(uint_t'(2)));
    end
    // The enable table must sum to the requested depth; see section 3.
    if ((int'(EN_IN) + int'(EN_MULT) + int'(EN_POST) + int'(EN_OUT) +
         int'(EN_PRE)) != int'(PIPE_STAGES)) begin
      $fatal(1, "complex_multiplier: stage enables do not sum to PIPE_STAGES=%0d",
             PIPE_STAGES);
    end
  end
`endif

  // ---------------------------------------------------------------------------
  // REG_IN — operand registers (stage 1)
  // ---------------------------------------------------------------------------
  fxp_complex_t a_s1, b_s1;

  if (EN_IN) begin : g_reg_in
    fxp_complex_t a_q, b_q;
    always_ff @(posedge clk) begin
      a_q <= a;
      b_q <= b;
    end
    assign a_s1 = a_q;
    assign b_s1 = b_q;
  end else begin : g_no_reg_in
    assign a_s1 = a;
    assign b_s1 = b;
  end

  // ---------------------------------------------------------------------------
  // Arithmetic core. Both branches produce the same two 33-bit sums.
  // ---------------------------------------------------------------------------
  prod_t sum_re_c, sum_im_c;   // post-adder output, combinational

  if (USE_MULT3) begin : g_mult3
    // ---- pre-adders (exact, 17 bits) ---------------------------------------
    pre_t pre_bsum_c, pre_asum_c, pre_adif_c;
    assign pre_bsum_c = pre_t'(b_s1.re) + pre_t'(b_s1.im);  // b.re + b.im
    assign pre_asum_c = pre_t'(a_s1.re) + pre_t'(a_s1.im);  // a.re + a.im
    assign pre_adif_c = pre_t'(a_s1.im) - pre_t'(a_s1.re);  // a.im - a.re

    // ---- REG_PRE (stage 5) --------------------------------------------------
    // Carries the three pre-adder results and the three bare operands that are
    // still needed as multiplicands.
    pre_t   pre_bsum_s2, pre_asum_s2, pre_adif_s2;
    fxp16_t a_re_s2, b_re_s2, b_im_s2;

    if (EN_PRE) begin : g_reg_pre
      pre_t   bsum_q, asum_q, adif_q;
      fxp16_t are_q, bre_q, bim_q;
      always_ff @(posedge clk) begin
        bsum_q <= pre_bsum_c;
        asum_q <= pre_asum_c;
        adif_q <= pre_adif_c;
        are_q  <= a_s1.re;
        bre_q  <= b_s1.re;
        bim_q  <= b_s1.im;
      end
      assign pre_bsum_s2 = bsum_q;
      assign pre_asum_s2 = asum_q;
      assign pre_adif_s2 = adif_q;
      assign a_re_s2     = are_q;
      assign b_re_s2     = bre_q;
      assign b_im_s2     = bim_q;
    end else begin : g_no_reg_pre
      assign pre_bsum_s2 = pre_bsum_c;
      assign pre_asum_s2 = pre_asum_c;
      assign pre_adif_s2 = pre_adif_c;
      assign a_re_s2     = a_s1.re;
      assign b_re_s2     = b_s1.re;
      assign b_im_s2     = b_s1.im;
    end

    // ---- three 16 x 17 multiplies (exact, 33 bits) --------------------------
    k_t k1_c, k2_c, k3_c;
    assign k1_c = k_t'(a_re_s2) * k_t'(pre_bsum_s2);   // a.re * (b.re + b.im)
    assign k2_c = k_t'(b_im_s2) * k_t'(pre_asum_s2);   // b.im * (a.re + a.im)
    assign k3_c = k_t'(b_re_s2) * k_t'(pre_adif_s2);   // b.re * (a.im - a.re)

    // ---- REG_MULT (stage 2) -------------------------------------------------
    k_t k1_s3, k2_s3, k3_s3;
    if (EN_MULT) begin : g_reg_mult
      k_t k1_q, k2_q, k3_q;
      always_ff @(posedge clk) begin
        k1_q <= k1_c;
        k2_q <= k2_c;
        k3_q <= k3_c;
      end
      assign k1_s3 = k1_q;
      assign k2_s3 = k2_q;
      assign k3_s3 = k3_q;
    end else begin : g_no_reg_mult
      assign k1_s3 = k1_c;
      assign k2_s3 = k2_c;
      assign k3_s3 = k3_c;
    end

    // ---- post-adders --------------------------------------------------------
    // Formed one bit wider than the output and cast down. The cast is provably
    // lossless (section 2) and a_cmult_post_adder_fits checks it every cycle.
    sum_t wide_re_c, wide_im_c;
    assign wide_re_c = sum_t'(k1_s3) - sum_t'(k2_s3);
    assign wide_im_c = sum_t'(k1_s3) + sum_t'(k3_s3);

    assign sum_re_c = prod_t'(wide_re_c);
    assign sum_im_c = prod_t'(wide_im_c);

`ifndef SYNTHESIS
    // Immediate assertions inside always_ff: the form Verilator 5.020 is
    // measured to enforce (DECISIONS.md 2026-07-26, decision 3).
    always_ff @(posedge clk) begin
      if (rst_n) begin
        a_cmult_post_adder_fits_re : assert (sum_t'(sum_re_c) == wide_re_c)
          else $error("complex_multiplier(MULT3): re post-adder %0d does not fit %0d bits",
                      wide_re_c, PROD_W);
        a_cmult_post_adder_fits_im : assert (sum_t'(sum_im_c) == wide_im_c)
          else $error("complex_multiplier(MULT3): im post-adder %0d does not fit %0d bits",
                      wide_im_c, PROD_W);
      end
    end
`endif

  end else begin : g_mult4
    // ---- REG_PRE (stage 5) --------------------------------------------------
    // MULT4 has no pre-adder, so this location is a second operand register. It
    // is not dead: HyperFlex may retime it forward into the multiply, and it
    // keeps LATENCY == PIPE_STAGES identical across the two variants, which is
    // what makes the calibration sweep a comparison of arithmetic rather than a
    // comparison of pipeline depth.
    fxp_complex_t a_s2, b_s2;
    if (EN_PRE) begin : g_reg_pre
      fxp_complex_t a_q, b_q;
      always_ff @(posedge clk) begin
        a_q <= a_s1;
        b_q <= b_s1;
      end
      assign a_s2 = a_q;
      assign b_s2 = b_q;
    end else begin : g_no_reg_pre
      assign a_s2 = a_s1;
      assign b_s2 = b_s1;
    end

    // ---- four 16 x 16 multiplies (exact, 32 bits) ---------------------------
    // fxp_mul_q15 is the package's exact Q1.15 x Q1.15 -> Q2.30 product. Using
    // it rather than a bare `*` keeps the one multiply the package defines in
    // the package.
    fxp32_t pp_rr_c, pp_ii_c, pp_ri_c, pp_ir_c;
    assign pp_rr_c = fxp_mul_q15(a_s2.re, b_s2.re);
    assign pp_ii_c = fxp_mul_q15(a_s2.im, b_s2.im);
    assign pp_ri_c = fxp_mul_q15(a_s2.re, b_s2.im);
    assign pp_ir_c = fxp_mul_q15(a_s2.im, b_s2.re);

    // ---- REG_MULT (stage 2) -------------------------------------------------
    fxp32_t pp_rr_s3, pp_ii_s3, pp_ri_s3, pp_ir_s3;
    if (EN_MULT) begin : g_reg_mult
      fxp32_t rr_q, ii_q, ri_q, ir_q;
      always_ff @(posedge clk) begin
        rr_q <= pp_rr_c;
        ii_q <= pp_ii_c;
        ri_q <= pp_ri_c;
        ir_q <= pp_ir_c;
      end
      assign pp_rr_s3 = rr_q;
      assign pp_ii_s3 = ii_q;
      assign pp_ri_s3 = ri_q;
      assign pp_ir_s3 = ir_q;
    end else begin : g_no_reg_mult
      assign pp_rr_s3 = pp_rr_c;
      assign pp_ii_s3 = pp_ii_c;
      assign pp_ri_s3 = pp_ri_c;
      assign pp_ir_s3 = pp_ir_c;
    end

    // ---- post-adders (32 + 32 -> 33, exact) ---------------------------------
    assign sum_re_c = prod_t'(pp_rr_s3) - prod_t'(pp_ii_s3);
    assign sum_im_c = prod_t'(pp_ri_s3) + prod_t'(pp_ir_s3);
  end

  // ---------------------------------------------------------------------------
  // REG_POST — post-adder registers (stage 3)
  // ---------------------------------------------------------------------------
  prod_t sum_re_s4, sum_im_s4;

  if (EN_POST) begin : g_reg_post
    prod_t re_q, im_q;
    always_ff @(posedge clk) begin
      re_q <= sum_re_c;
      im_q <= sum_im_c;
    end
    assign sum_re_s4 = re_q;
    assign sum_im_s4 = im_q;
  end else begin : g_no_reg_post
    assign sum_re_s4 = sum_re_c;
    assign sum_im_s4 = sum_im_c;
  end

  // ---------------------------------------------------------------------------
  // Quantisation — the module's only rounding, and it is a package call
  // ---------------------------------------------------------------------------
  fxp16_t     y_re_c, y_im_c;
  fxp_flags_t flags_re_c, flags_im_c;

  always_comb begin
    if (DO_ROUND) begin
      y_re_c = fxp16_t'(fxp_round_sat(fxp_wide_t'(sum_re_s4),
                                      FXP_PROD_SHIFT, FXP_SAMPLE_W));
      y_im_c = fxp16_t'(fxp_round_sat(fxp_wide_t'(sum_im_s4),
                                      FXP_PROD_SHIFT, FXP_SAMPLE_W));
      // Flags describe the value being clamped, i.e. AFTER the round and BEFORE
      // the saturate, which is the order fxp_pkg fixes and the only order in
      // which a round-induced overflow is reportable at all.
      flags_re_c = fxp_sat_flags(fxp_round(fxp_wide_t'(sum_re_s4), FXP_PROD_SHIFT),
                                 FXP_SAMPLE_W);
      flags_im_c = fxp_sat_flags(fxp_round(fxp_wide_t'(sum_im_s4), FXP_PROD_SHIFT),
                                 FXP_SAMPLE_W);
    end else begin
      y_re_c     = '0;
      y_im_c     = '0;
      flags_re_c = fxp_flags_none();
      flags_im_c = fxp_flags_none();
    end
  end

  // ---------------------------------------------------------------------------
  // REG_OUT — output registers (stage 4)
  // ---------------------------------------------------------------------------
  prod_t      p_re_s5, p_im_s5;
  fxp16_t     y_re_s5, y_im_s5;
  fxp_flags_t flags_re_s5, flags_im_s5;

  if (EN_OUT) begin : g_reg_out
    prod_t      pre_q, pim_q;
    fxp16_t     yre_q, yim_q;
    fxp_flags_t fre_q, fim_q;
    always_ff @(posedge clk) begin
      pre_q <= sum_re_s4;
      pim_q <= sum_im_s4;
      yre_q <= y_re_c;
      yim_q <= y_im_c;
      fre_q <= flags_re_c;
      fim_q <= flags_im_c;
    end
    assign p_re_s5     = pre_q;
    assign p_im_s5     = pim_q;
    assign y_re_s5     = yre_q;
    assign y_im_s5     = yim_q;
    assign flags_re_s5 = fre_q;
    assign flags_im_s5 = fim_q;
  end else begin : g_no_reg_out
    assign p_re_s5     = sum_re_s4;
    assign p_im_s5     = sum_im_s4;
    assign y_re_s5     = y_re_c;
    assign y_im_s5     = y_im_c;
    assign flags_re_s5 = flags_re_c;
    assign flags_im_s5 = flags_im_c;
  end

  assign p_re     = p_re_s5;
  assign p_im     = p_im_s5;
  assign y_re     = y_re_s5;
  assign y_im     = y_im_s5;
  assign flags_re = flags_re_s5;
  assign flags_im = flags_im_s5;
  assign ovf      = fxp_flags_any(flags_re_s5) | fxp_flags_any(flags_im_s5);

  // ---------------------------------------------------------------------------
  // Valid pipeline — the only reset state in the module (SPEC 23)
  // ---------------------------------------------------------------------------
  logic [PIPE_STAGES:0] valid_ch;
  assign valid_ch[0] = valid_in;

  for (genvar s = 0; s < int'(PIPE_STAGES); s++) begin : g_valid
    logic v_q;
    always_ff @(posedge clk) begin
      if (!rst_n) v_q <= 1'b0;
      else        v_q <= valid_ch[s];
    end
    assign valid_ch[s+1] = v_q;
  end

  assign valid_out = valid_ch[PIPE_STAGES];

  // ---------------------------------------------------------------------------
  // Simulation-only proof that the arithmetic core computes what SPEC 6 says
  //
  // A shadow copy of {a, b}, delayed by exactly the operand-to-post-adder
  // latency, is fed to fxp_pkg's canonical four-multiply definition and compared
  // against the post-adder output. For MULT4 this checks the wiring; for MULT3
  // it is the exactness claim of section 2, checked against the package rather
  // than against a second copy of the same algebra. It runs in every test that
  // instantiates this module, on every cycle, with no test-side wiring.
  //
  // Gated by rst_n only: the datapath is free-running, so before the first reset
  // release the shadow chain holds X and the comparison is meaningless.
  // ---------------------------------------------------------------------------
`ifndef SYNTHESIS
  // Packed 2-D chains, driven only by continuous assignments, so every bit has
  // exactly one driver and the shadow adds no procedural writer to a shared
  // array (which is what MULTIDRIVEN would report).
  localparam int unsigned SHADOW_W = 2 * $bits(fxp_complex_t);

  logic [PRE_POST_LAT:0][SHADOW_W-1:0] shadow_ch;
  logic [PRE_POST_LAT:0]               shadow_vld;

  assign shadow_ch[0]  = {a, b};
  assign shadow_vld[0] = 1'b1;

  for (genvar d = 0; d < int'(PRE_POST_LAT); d++) begin : g_shadow
    logic [SHADOW_W-1:0] sh_q;
    logic                sv_q;
    always_ff @(posedge clk) begin
      sh_q <= shadow_ch[d];
      if (!rst_n) sv_q <= 1'b0;
      else        sv_q <= shadow_vld[d];
    end
    assign shadow_ch[d+1]  = sh_q;
    assign shadow_vld[d+1] = sv_q;
  end

  fxp_complex_t shadow_a, shadow_b;
  assign {shadow_a, shadow_b} = shadow_ch[PRE_POST_LAT];

  always_ff @(posedge clk) begin
    if (rst_n && shadow_vld[PRE_POST_LAT]) begin
      a_cmult_re_matches_pkg : assert (fxp_wide_t'(sum_re_c) ==
          fxp_cmul_q15_re_raw(shadow_a, shadow_b))
        else $error("complex_multiplier(%s): re core %0d != fxp_cmul_q15_re_raw %0d",
                    VARIANT, sum_re_c,
                    fxp_cmul_q15_re_raw(shadow_a, shadow_b));
      a_cmult_im_matches_pkg : assert (fxp_wide_t'(sum_im_c) ==
          fxp_cmul_q15_im_raw(shadow_a, shadow_b))
        else $error("complex_multiplier(%s): im core %0d != fxp_cmul_q15_im_raw %0d",
                    VARIANT, sum_im_c,
                    fxp_cmul_q15_im_raw(shadow_a, shadow_b));
    end
  end
`endif

endmodule : complex_multiplier

`default_nettype wire
