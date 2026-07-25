// -----------------------------------------------------------------------------
// fxp_probe_top — thin test harness exposing every fxp_pkg function to C++.
//
// Purpose (SPEC.md 12.4): prove that rtl/packages/fxp_pkg.sv and model/cpp/fxp/
// compute bit-identical results for the same golden vectors. The C++ reference
// model is only allowed to be the RTL oracle once that equivalence is measured,
// so this module exists to make the RTL side measurable.
//
// It is a *probe*, not design RTL: no pipelining, no handshake, no reset of the
// combinational path. It contains no arithmetic of its own — every operation is
// a single call into fxp_pkg, which is the whole point. If this file ever grows
// an expression that is not a package call, the cross-check stops proving
// anything about the package.
//
// Two interfaces:
//
//   1. Combinational op port. Drive {op, a, b, sh, w}, eval(), read {y, flags}.
//      One vector per eval; no clock needed. `sim/tests/test_fxp_rtl.cpp` walks
//      model/vectors/fxp_ops.vec through it.
//
//   2. Clocked saturating accumulator. Exercises the accumulator-width policy
//      and rtl/common/fxp_sticky_flags.sv against
//      model/vectors/fxp_accum.vec — the sequences that cross overflow, where a
//      per-step result and a sticky flag both have to match.
//
// OP CODES ARE MIRRORED in model/cpp/fxp/fxp_ops.hpp (kOpTable). The two lists
// must agree; they are checked against each other by the vector name lookup, so
// a drift shows up as an unknown-op failure rather than a wrong answer.
// -----------------------------------------------------------------------------

`default_nettype none

module fxp_probe_top
  import fxp_pkg::*;
(
    input  logic        clk,
    input  logic        rst_n,

    // ---- combinational op port -------------------------------------------
    input  logic [7:0]  op,      // FXP_OP_* below
    input  logic [63:0] a,       // operand A (bit pattern of a signed value)
    input  logic [63:0] b,       // operand B
    input  logic [7:0]  sh,      // shift / fractional-bit count
    input  logic [7:0]  w,       // target signed width in bits
    output logic [63:0] y,       // result (bit pattern of a signed value)
    output fxp_flags_t  flags,   // saturation flags for this operation
    output logic        ovf,     // flags.sat_pos | flags.sat_neg

    // ---- clocked saturating accumulator ----------------------------------
    input  logic        acc_clear,
    input  logic        acc_en,
    input  logic [7:0]  acc_width,
    input  logic [63:0] acc_x,
    output logic [63:0] acc_y,
    // Flags for the step the accumulator is *about* to take, sampled before the
    // clock edge; this is the per-step column of model/vectors/fxp_accum.vec.
    output fxp_flags_t  acc_flags_now,
    output fxp_flags_t  acc_flags_sticky,
    output logic        acc_any_sticky,
    output logic [31:0] acc_event_count
);

  // ---------------------------------------------------------------------------
  // Operation codes. Keep in sync with model/cpp/fxp/fxp_ops.hpp.
  // ---------------------------------------------------------------------------
  localparam logic [7:0] FXP_OP_SAT           = 8'd0;
  localparam logic [7:0] FXP_OP_TRUNC         = 8'd1;
  localparam logic [7:0] FXP_OP_ROUND_EVEN    = 8'd2;
  localparam logic [7:0] FXP_OP_ROUND_HALF_UP = 8'd3;
  localparam logic [7:0] FXP_OP_ROUND         = 8'd4;
  localparam logic [7:0] FXP_OP_ROUND_SAT     = 8'd5;
  localparam logic [7:0] FXP_OP_ADD_SAT       = 8'd6;
  localparam logic [7:0] FXP_OP_SUB_SAT       = 8'd7;
  localparam logic [7:0] FXP_OP_NEG_SAT       = 8'd8;
  localparam logic [7:0] FXP_OP_MUL_Q15       = 8'd9;
  localparam logic [7:0] FXP_OP_MUL_Q15_RS    = 8'd10;
  localparam logic [7:0] FXP_OP_CMUL_RE       = 8'd11;
  localparam logic [7:0] FXP_OP_CMUL_IM       = 8'd12;
  localparam logic [7:0] FXP_OP_ACC_W         = 8'd13;
  localparam logic [7:0] FXP_OP_GROWTH_BITS   = 8'd14;

  // ---------------------------------------------------------------------------
  // Operand views
  // ---------------------------------------------------------------------------
  fxp_wide_t    a_wide, b_wide;
  uint_t        sh_u, w_u;
  fxp16_t       a16, b16;
  fxp_complex_t a_cplx, b_cplx;

  assign a_wide = fxp_wide_t'(a);
  assign b_wide = fxp_wide_t'(b);
  assign sh_u   = uint_t'(sh);
  assign w_u    = uint_t'(w);
  assign a16    = fxp16_t'(a[FXP_SAMPLE_W-1:0]);
  assign b16    = fxp16_t'(b[FXP_SAMPLE_W-1:0]);

  // A complex operand packs {im, re} into the low 32 bits, real part first.
  assign a_cplx = '{re: fxp16_t'(a[15:0]), im: fxp16_t'(a[31:16])};
  assign b_cplx = '{re: fxp16_t'(b[15:0]), im: fxp16_t'(b[31:16])};

  // ---------------------------------------------------------------------------
  // Combinational operation dispatch.
  //
  // Every arm is exactly one fxp_pkg call for the value and one for the flags.
  // `default` covers unknown codes with a zero result and no flags, so an op
  // code the C++ side invents shows up as a mismatch rather than as X.
  // ---------------------------------------------------------------------------
  fxp_wide_t y_wide;

  always_comb begin
    y_wide = 64'sd0;
    flags  = fxp_flags_none();

    unique case (op)
      FXP_OP_SAT: begin
        y_wide = fxp_sat(a_wide, w_u);
        flags  = fxp_sat_flags(a_wide, w_u);
      end
      FXP_OP_TRUNC: begin
        y_wide = fxp_trunc(a_wide, sh_u);
      end
      FXP_OP_ROUND_EVEN: begin
        y_wide = fxp_round_even(a_wide, sh_u);
      end
      FXP_OP_ROUND_HALF_UP: begin
        y_wide = fxp_round_half_up(a_wide, sh_u);
      end
      FXP_OP_ROUND: begin
        y_wide = fxp_round(a_wide, sh_u);
      end
      FXP_OP_ROUND_SAT: begin
        y_wide = fxp_round_sat(a_wide, sh_u, w_u);
        flags  = fxp_sat_flags(fxp_round(a_wide, sh_u), w_u);
      end
      FXP_OP_ADD_SAT: begin
        y_wide = fxp_add_sat(a_wide, b_wide, w_u);
        flags  = fxp_sat_flags(a_wide + b_wide, w_u);
      end
      FXP_OP_SUB_SAT: begin
        y_wide = fxp_sub_sat(a_wide, b_wide, w_u);
        flags  = fxp_sat_flags(a_wide - b_wide, w_u);
      end
      FXP_OP_NEG_SAT: begin
        y_wide = fxp_neg_sat(a_wide, w_u);
        flags  = fxp_sat_flags(-a_wide, w_u);
      end
      FXP_OP_MUL_Q15: begin
        y_wide = fxp_wide_t'(fxp_mul_q15(a16, b16));
      end
      FXP_OP_MUL_Q15_RS: begin
        y_wide = fxp_wide_t'(fxp_mul_q15_rs(a16, b16));
        flags  = fxp_sat_flags(
                   fxp_round(fxp_wide_t'(fxp_mul_q15(a16, b16)), FXP_PROD_SHIFT),
                   FXP_SAMPLE_W);
      end
      FXP_OP_CMUL_RE: begin
        y_wide = fxp_wide_t'(fxp_cmul_q15(a_cplx, b_cplx).re);
        flags  = fxp_sat_flags(
                   fxp_round(fxp_cmul_q15_re_raw(a_cplx, b_cplx), FXP_PROD_SHIFT),
                   FXP_SAMPLE_W);
      end
      FXP_OP_CMUL_IM: begin
        y_wide = fxp_wide_t'(fxp_cmul_q15(a_cplx, b_cplx).im);
        flags  = fxp_sat_flags(
                   fxp_round(fxp_cmul_q15_im_raw(a_cplx, b_cplx), FXP_PROD_SHIFT),
                   FXP_SAMPLE_W);
      end
      FXP_OP_ACC_W: begin
        // Accumulator width for `a` terms of `w`-bit products.
        y_wide = fxp_wide_t'(fxp_acc_w(w_u, uint_t'(a[31:0])));
      end
      FXP_OP_GROWTH_BITS: begin
        y_wide = fxp_wide_t'(fxp_growth_bits(uint_t'(a[31:0])));
      end
      default: begin
        y_wide = 64'sd0;
        flags  = fxp_flags_none();
      end
    endcase
  end

  assign y   = y_wide;
  assign ovf = fxp_flags_any(flags);

  // ---------------------------------------------------------------------------
  // Clocked saturating accumulator.
  //
  // Deliberately saturating *per step* rather than accumulating full precision
  // and saturating once: this is the behaviour the vectors pin down, and it is
  // the behaviour a naive kernel would implement, so the model has to reproduce
  // it exactly (including the fact that it is order-dependent) before any
  // kernel is allowed to rely on the full-precision policy instead.
  // ---------------------------------------------------------------------------
  fxp_wide_t  acc_q;
  fxp_wide_t  acc_sum;
  uint_t      acc_w_u;
  logic       acc_step;

  assign acc_w_u       = uint_t'(acc_width);
  assign acc_sum       = acc_q + fxp_wide_t'(acc_x);
  assign acc_flags_now = fxp_sat_flags(acc_sum, acc_w_u);
  assign acc_step      = acc_en && !acc_clear;

  always_ff @(posedge clk) begin
    if (!rst_n) begin
      acc_q <= 64'sd0;
    end else if (acc_clear) begin
      acc_q <= 64'sd0;
    end else if (acc_en) begin
      acc_q <= fxp_sat(acc_sum, acc_w_u);
    end
  end

  assign acc_y = acc_q;

  fxp_sticky_flags #(
      .COUNT_W (32)
  ) u_acc_flags (
      .clk          (clk),
      .rst_n        (rst_n),
      .clear        (acc_clear),
      .valid        (acc_step),
      .flags_in     (acc_flags_now),
      .flags_sticky (acc_flags_sticky),
      .any_sticky   (acc_any_sticky),
      .event_count  (acc_event_count)
  );

endmodule : fxp_probe_top

`default_nettype wire
