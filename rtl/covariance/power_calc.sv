// -----------------------------------------------------------------------------
// power_calc — Power = I^2 + Q^2, per sample (SPEC.md 7.6, issue #13).
//
// The first half of the SPEC 7.6 block: one complex Q1.15 sample in, one
// non-negative POWER_W-bit power out, on a fixed-latency valid pipeline. The
// integration window, the exponential averaging and the accumulator protection
// belong to integrator.sv; the cross-power belongs to covar_engine.sv. This
// module does the squaring and nothing else, which is what makes its saturation
// argument a one-line proof instead of a case analysis.
//
// -----------------------------------------------------------------------------
// 1. Numerics, and why nothing here can saturate
// -----------------------------------------------------------------------------
// I and Q are Q1.15 (fxp_pkg::fxp16_t): signed 16-bit, |x| <= 2^15, with the
// negative endpoint -2^15 = -1.0 attainable and the positive endpoint one LSB
// short of +1.0.
//
//     I^2 in [0, 2^30]        the upper end reached only by I = -32768
//     Q^2 in [0, 2^30]        likewise
//     I^2 + Q^2 in [0, 2^31]  the upper end reached only by I = Q = -32768
//
// Every step is an EXACT integer operation: two squares and one add, no shift,
// no round, no truncation. There is therefore no call into fxp_pkg here, and
// that absence is deliberate rather than an oversight — fxp_pkg is the home of
// QUANTISATION, and a computation that loses no bits has nothing to quantise.
// (complex_multiplier.sv makes the same distinction for the same reason.) What
// this module does borrow from fxp_pkg is the WIDTHS, so that a change to the
// sample format moves this file with it.
//
// SATURATION IS IMPOSSIBLE BY CONSTRUCTION, not by clamping:
//
//     max(I^2 + Q^2) = 2^31  <  2^32 - 1 = max of an unsigned 32-bit field
//                            <  2^39 - 1 = max of the signed POWER_W field
//
// so the result is carried in the low bits of a signed POWER_W = 40 field with
// eight bits of headroom to spare — and those eight bits are not slack, they are
// exactly the integration growth that lets integrator.sv sum 255 of these
// without clamping either (covar_pkg section 1). There is consequently NO
// saturation flag on this module. A flag that can never fire is worse than no
// flag: it invites a consumer to believe the datapath is monitored when the
// monitoring is downstream. The impossibility is instead asserted every cycle in
// simulation (a_power_range below), so the claim is checked rather than
// declared.
//
// The output is declared SIGNED even though it is provably non-negative. Two
// reasons, both structural: integrator.sv accumulates power and cross-power in
// the same signed accumulator with one saturation rule (covar_pkg section 1),
// and a zero-extended unsigned value fed into a signed accumulator is the exact
// same bit pattern with none of the sign-extension hazards at the boundary.
//
// -----------------------------------------------------------------------------
// 2. DSP mapping: two 16x16 squares fused into one block
// -----------------------------------------------------------------------------
// Agilex 7 DSP blocks provide two multipliers and an internal adder in the
// "sum of two 18x19 multipliers" mode. I^2 + Q^2 is exactly that shape: two
// 16x16 signed multiplies whose sum never leaves the block, so one complex
// sample's power should cost ONE DSP rather than two plus fabric.
//
// The RTL is written so the inference is available:
//
//   * the two products and their sum are ONE combinational expression between
//     two register stages — nothing is registered between the multipliers and
//     the adder, because a register there is precisely what stops the tool from
//     folding the adder into the block;
//   * the operand register (REG_IN) and the result register (REG_SUM) are the
//     DSP's own input and output registers, so at PIPE_STAGES = 2 the entire
//     computation is inside the block and the fabric sees only wires;
//   * neither data register has a clock enable or a reset (SPEC 23: "reset
//     validity, not every datapath bit"), because an enable or an async reset on
//     a DSP register is what forces the tool to build it in fabric instead.
//
// Whether the tool actually fuses is a measurement, not an argument. It is what
// quartus/calibration/power_calc_calib.qsf is for, and the answer lands in
// results/synthesis/. If it does not fuse, the cost is one extra DSP per
// channel and no change in numerics.
//
// -----------------------------------------------------------------------------
// 3. Pipeline
// -----------------------------------------------------------------------------
// Three register locations, switched on in a fixed priority order as
// PIPE_STAGES grows, so LATENCY == PIPE_STAGES exactly for every legal value —
// the same arrangement, for the same reason, as complex_multiplier (DECISIONS.md
// issue #9, decision 3):
//
//   n = PIPE_STAGES      1     2     3
//   -------------------  ----  ----  ----
//   REG_IN   operands    on    on    on
//   REG_SUM  I^2+Q^2     -     on    on
//   REG_OUT  result      -     -     on
//
// The default is 2: that is the shape that fits entirely inside one DSP block.
// The third stage is a fabric register that takes the DSP's output off the path
// into whatever consumes it, and it is the first thing to try if the SPEC 18
// calibration shows this kernel on the critical path.
//
// A `tag` of TAG_W bits rides the same pipeline, so a caller can carry a stream
// id, a bin index or a beat counter through without building a parallel delay
// line and without this module having to know what it is. TAG_W = 1 with a tied
// tag is the degenerate case and costs one flip-flop per stage.
//
// No `ready`. This is a fixed-latency arithmetic kernel, exactly like
// complex_multiplier: backpressure is a block-level concern served by the SPEC 5
// primitives in rtl/stream/, and a ready chain here would put the consumer's
// stall signal on the enable of every DSP register and undo section 2. Because
// there is no enable, the module is invariant to gaps in `valid_in` — the same
// beats in the same order produce the same results whether they arrive back to
// back or one every hundred cycles, which is the property
// sim/tests/test_covariance.cpp checks as "backpressure invariance".
//
// Lint contract: clean under `verilator --lint-only --Wall` with no waiver.
// -----------------------------------------------------------------------------

`default_nettype none

module power_calc
  import fxp_pkg::*;
  import covar_pkg::*;
#(
    // Total register stages == output latency in cycles. Legal range [1, 3];
    // see the table in section 3.
    parameter int unsigned PIPE_STAGES = 2,

    // Width of the pass-through tag. >= 1; a caller with nothing to carry ties
    // it to a constant.
    parameter int unsigned TAG_W = 1
) (
    input  wire                          clk,
    input  wire                          rst_n,

    // Fixed-latency valid pipeline. No ready; see section 3.
    input  wire                          valid_in,
    input  wire fxp_complex_t            sample,
    input  wire [TAG_W-1:0]              tag_in,

    output wire                          valid_out,

    // Power = I^2 + Q^2, exact, in [0, 2^31]. Signed POWER_W per SPEC 3; see
    // section 1 for why signed and why POWER_W.
    output wire signed [COVAR_POWER_W-1:0] power,
    output wire [TAG_W-1:0]              tag_out
);

  // ---------------------------------------------------------------------------
  // Widths
  // ---------------------------------------------------------------------------

  localparam int unsigned PC_PIPE_MIN = 1;
  localparam int unsigned PC_PIPE_MAX = 3;

  // Exact width of one square: Q1.15 x Q1.15 -> Q2.30, |v| <= 2^30, so 32 bits
  // signed (fxp_pkg::FXP_PROD_W). The SUM of two of them reaches 2^31 and needs
  // one more bit — the same "sum of two products is not a product" fact that
  // sizes complex_multiplier's full-precision port.
  localparam int unsigned SQ_W  = FXP_PROD_W;       // 32
  localparam int unsigned SUM_W = FXP_PROD_W + 1;   // 33

  localparam bit EN_IN  = (PIPE_STAGES >= 1);
  localparam bit EN_SUM = (PIPE_STAGES >= 2);
  localparam bit EN_OUT = (PIPE_STAGES >= 3);

  typedef logic signed [SQ_W-1:0]  sq_t;
  typedef logic signed [SUM_W-1:0] sum_t;

`ifndef SYNTHESIS
  initial begin
    if (PIPE_STAGES < PC_PIPE_MIN || PIPE_STAGES > PC_PIPE_MAX) begin
      $fatal(1, "power_calc: PIPE_STAGES=%0d outside [%0d, %0d]",
             PIPE_STAGES, PC_PIPE_MIN, PC_PIPE_MAX);
    end
    if (TAG_W < 1) begin
      $fatal(1, "power_calc: TAG_W=%0d must be at least 1", TAG_W);
    end
    if ((int'(EN_IN) + int'(EN_SUM) + int'(EN_OUT)) != int'(PIPE_STAGES)) begin
      $fatal(1, "power_calc: stage enables do not sum to PIPE_STAGES=%0d",
             PIPE_STAGES);
    end
    // The output field must be able to hold the extreme without clamping. This
    // is section 1's proof, elaborated rather than believed.
    if (COVAR_POWER_W < SUM_W) begin
      $fatal(1, "power_calc: COVAR_POWER_W=%0d cannot hold a %0d-bit power",
             COVAR_POWER_W, SUM_W);
    end
  end
`endif

  // ---------------------------------------------------------------------------
  // REG_IN — operand register (stage 1). The DSP block's input register: no
  // enable, no reset (section 2).
  // ---------------------------------------------------------------------------
  fxp_complex_t     s_s1;
  logic [TAG_W-1:0] tag_s1;

  if (EN_IN) begin : g_reg_in
    fxp_complex_t     s_q;
    logic [TAG_W-1:0] tag_q;
    always_ff @(posedge clk) begin
      s_q   <= sample;
      tag_q <= tag_in;
    end
    assign s_s1   = s_q;
    assign tag_s1 = tag_q;
  end else begin : g_no_reg_in
    assign s_s1   = sample;
    assign tag_s1 = tag_in;
  end

  // ---------------------------------------------------------------------------
  // The arithmetic. ONE combinational expression: two squares and their sum,
  // with nothing registered in between, so the adder can live inside the DSP
  // block (section 2).
  // ---------------------------------------------------------------------------
  sum_t sum_c;
  assign sum_c = sum_t'(sq_t'(s_s1.re) * sq_t'(s_s1.re))
               + sum_t'(sq_t'(s_s1.im) * sq_t'(s_s1.im));

  // ---------------------------------------------------------------------------
  // REG_SUM — result register (stage 2). The DSP block's output register.
  // ---------------------------------------------------------------------------
  sum_t             sum_s2;
  logic [TAG_W-1:0] tag_s2;

  if (EN_SUM) begin : g_reg_sum
    sum_t             sum_q;
    logic [TAG_W-1:0] tag_q;
    always_ff @(posedge clk) begin
      sum_q <= sum_c;
      tag_q <= tag_s1;
    end
    assign sum_s2 = sum_q;
    assign tag_s2 = tag_q;
  end else begin : g_no_reg_sum
    assign sum_s2 = sum_c;
    assign tag_s2 = tag_s1;
  end

  // ---------------------------------------------------------------------------
  // REG_OUT — fabric output register (stage 3).
  // ---------------------------------------------------------------------------
  sum_t             sum_s3;
  logic [TAG_W-1:0] tag_s3;

  if (EN_OUT) begin : g_reg_out
    sum_t             sum_q;
    logic [TAG_W-1:0] tag_q;
    always_ff @(posedge clk) begin
      sum_q <= sum_s2;
      tag_q <= tag_s2;
    end
    assign sum_s3 = sum_q;
    assign tag_s3 = tag_q;
  end else begin : g_no_reg_out
    assign sum_s3 = sum_s2;
    assign tag_s3 = tag_s2;
  end

  // Sign-extend the exact 33-bit power into the POWER_W plane. The value is
  // non-negative, so this is a zero-extension in practice; it is written as a
  // signed cast because the field is signed.
  assign power   = COVAR_POWER_W'(sum_s3);
  assign tag_out = tag_s3;

  // ---------------------------------------------------------------------------
  // Valid chain. The ONLY reset in the module (SPEC 23). Written as a chain of
  // PIPE_STAGES+1 taps driven one stage per generate instance, so every bit has
  // exactly one driver and PIPE_STAGES = 1 needs no special case.
  // ---------------------------------------------------------------------------
  logic [PIPE_STAGES:0] valid_ch;
  assign valid_ch[0] = valid_in;

  for (genvar d = 0; d < int'(PIPE_STAGES); d++) begin : g_valid
    logic v_q;
    always_ff @(posedge clk) begin
      if (!rst_n) v_q <= 1'b0;
      else        v_q <= valid_ch[d];
    end
    assign valid_ch[d+1] = v_q;
  end

  assign valid_out = valid_ch[PIPE_STAGES];

  // ---------------------------------------------------------------------------
  // Simulation-only proofs (SPEC 14)
  //
  // a_power_range   the impossibility claim of section 1, checked every cycle
  //                 on every qualified output rather than argued in a comment.
  // a_power_matches_pkg
  //                 the arithmetic against fxp_pkg's own Q1.15 multiply, on a
  //                 shadow copy of the operands delayed to the same stage. This
  //                 is what makes "exact integer arithmetic" a checked claim
  //                 rather than a second implementation nobody compares.
  // ---------------------------------------------------------------------------
`ifndef SYNTHESIS
  // Shadow of the input sample, delayed by the whole pipeline. Packed chain
  // driven by one continuous assignment per tap, exactly as
  // complex_multiplier's shadow is, so no bit has two drivers.
  localparam int unsigned SHADOW_W = $bits(fxp_complex_t);

  logic [PIPE_STAGES:0][SHADOW_W-1:0] shadow_ch;
  assign shadow_ch[0] = sample;

  for (genvar d = 0; d < int'(PIPE_STAGES); d++) begin : g_shadow
    logic [SHADOW_W-1:0] sh_q;
    always_ff @(posedge clk) begin
      sh_q <= shadow_ch[d];
    end
    assign shadow_ch[d+1] = sh_q;
  end

  fxp_complex_t shadow_s;
  assign shadow_s = fxp_complex_t'(shadow_ch[PIPE_STAGES]);

  fxp_wide_t exp_power;
  assign exp_power = fxp_wide_t'(fxp_mul_q15(shadow_s.re, shadow_s.re))
                   + fxp_wide_t'(fxp_mul_q15(shadow_s.im, shadow_s.im));

  always_ff @(posedge clk) begin
    if (rst_n && valid_out) begin
      a_power_range : assert (fxp_wide_t'(power) >= 64'sd0 &&
                              fxp_wide_t'(power) <= (64'sd1 <<< 31))
        else $error("power_calc: power %0d outside [0, 2^31]", power);
      a_power_matches_pkg : assert (fxp_wide_t'(power) == exp_power)
        else $error("power_calc: power %0d != fxp_pkg expectation %0d",
                    power, exp_power);
    end
  end
`endif

endmodule : power_calc

`default_nettype wire
