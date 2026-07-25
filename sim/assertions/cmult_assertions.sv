// -----------------------------------------------------------------------------
// cmult_assertions — the SPEC 14 property set for the complex multiplier (#9).
//
// Watches a MATCHED PAIR of complex_multiplier instances: same PIPE_STAGES, same
// ROUND_OUT, different VARIANT. Everything SPEC 6 asks of the module that can be
// stated as a relation between observable signals is stated here, and it is
// checked on every cycle of every test that elaborates
// sim/verilator/tops/cmult_top.sv — including the ten thousand random beats per
// seed, which is where the interesting operand combinations actually live.
//
// Four groups:
//
//   1. LATENCY IS THE PARAMETER
//      a_cmult_latency_a / _b
//          valid_out is valid_in delayed by exactly PIPE_STAGES. Checked against
//          this module's own reference shift register rather than against
//          $past(valid_in, N), so the property is explicit about what "exactly"
//          means and does not depend on tool support for a counted $past.
//      a_cmult_valid_aligned
//          the two variants present their results on the SAME cycle. A variant
//          that quietly added or dropped a stage would still agree
//          value-for-value in a queue-based scoreboard; it would not agree here.
//
//   2. THE TWO VARIANTS ARE BIT-IDENTICAL
//      a_cmult_p_re_match / a_cmult_p_im_match / a_cmult_y_re_match /
//      a_cmult_y_im_match / a_cmult_flags_re_match / a_cmult_flags_im_match /
//      a_cmult_ovf_match
//          every output bit, on every valid beat. This is the SPEC 6 obligation
//          that the three-multiply form "must produce this exact result", and it
//          is checked structurally rather than by trusting that both happened to
//          match the same reference model.
//
//   3. THE ROUNDED OUTPUT IS THE PACKAGE'S ROUNDING OF THE FULL-PRECISION ONE
//      a_cmult_round_re / a_cmult_round_im / a_cmult_flags_re_def /
//      a_cmult_flags_im_def
//          y == fxp_round_sat(p, FXP_PROD_SHIFT, FXP_SAMPLE_W) and
//          flags == fxp_sat_flags(fxp_round(p, FXP_PROD_SHIFT), FXP_SAMPLE_W),
//          recomputed here from fxp_pkg. Both output ports leave the module on
//          the same cycle, so this is a same-cycle relation and needs no
//          alignment. It is what makes the two ports provably two views of one
//          number instead of two independently computed results, and it is the
//          SPEC 14 "saturation flags match the expected overflow cases" check —
//          stated as a definition, so it holds on every operand pair rather than
//          on the directed ones a vector file happens to contain.
//
//   4. THE FLAG SUMMARY IS THE SUMMARY
//      a_cmult_ovf_def
//          ovf is exactly the OR of the four flag bits.
//      a_cmult_no_flags_when_unrounded
//          ROUND_OUT = 0 leaves y and the flags at zero. Without this the
//          full-precision-only configuration would be checked only for what it
//          does produce, never for what it must not.
//
// Form: immediate assertions inside always_ff with an else $error action — the
// construct DECISIONS.md 2026-07-26 (decision 3) records as measured-supported
// in Verilator 5.020, and the one every other assertion set in this repository
// uses. All are gated on rst_n and, where they concern data, on valid_out: the
// datapath registers are free-running and deliberately unreset (SPEC 23), so
// their contents between valid beats are don't-care by construction.
//
// Simulation only. Never in a Quartus source list.
// -----------------------------------------------------------------------------

`default_nettype none

module cmult_assertions
  import fxp_pkg::*;
#(
    parameter int unsigned PIPE_STAGES = 3,
    parameter int unsigned ROUND_OUT   = 1,
    parameter int unsigned PROD_W      = 33
) (
    input wire                clk,
    input wire                rst_n,
    input wire                valid_in,

    // Variant A (the four-multiply instance).
    input wire                valid_out_a,
    input wire [PROD_W-1:0]   p_re_a,
    input wire [PROD_W-1:0]   p_im_a,
    input wire [15:0]         y_re_a,
    input wire [15:0]         y_im_a,
    input wire [1:0]          flags_re_a,
    input wire [1:0]          flags_im_a,
    input wire                ovf_a,

    // Variant B (the three-multiply instance).
    input wire                valid_out_b,
    input wire [PROD_W-1:0]   p_re_b,
    input wire [PROD_W-1:0]   p_im_b,
    input wire [15:0]         y_re_b,
    input wire [15:0]         y_im_b,
    input wire [1:0]          flags_re_b,
    input wire [1:0]          flags_im_b,
    input wire                ovf_b
);

  localparam bit DO_ROUND = (ROUND_OUT != 0);

  // ---------------------------------------------------------------------------
  // Group 1 — reference valid pipeline
  //
  // An independent PIPE_STAGES-deep shift register, written here and nowhere
  // else. If the DUT's chain is one stage short or one stage long, ref_valid and
  // valid_out disagree on the very first beat.
  // ---------------------------------------------------------------------------
  logic [PIPE_STAGES:0] ref_valid;
  assign ref_valid[0] = valid_in;

  for (genvar s = 0; s < int'(PIPE_STAGES); s++) begin : g_ref
    logic q;
    always_ff @(posedge clk) begin
      if (!rst_n) q <= 1'b0;
      else        q <= ref_valid[s];
    end
    assign ref_valid[s+1] = q;
  end

  // ---------------------------------------------------------------------------
  // Expected quantisation of the full-precision output, recomputed from fxp_pkg
  // ---------------------------------------------------------------------------
  fxp_wide_t  p_re_wide, p_im_wide;
  fxp16_t     exp_y_re, exp_y_im;
  fxp_flags_t exp_f_re, exp_f_im;

  // The full-precision port is a signed PROD_W-bit value; widen it as signed.
  assign p_re_wide = fxp_wide_t'($signed(p_re_a));
  assign p_im_wide = fxp_wide_t'($signed(p_im_a));

  always_comb begin
    if (DO_ROUND) begin
      exp_y_re = fxp16_t'(fxp_round_sat(p_re_wide, FXP_PROD_SHIFT, FXP_SAMPLE_W));
      exp_y_im = fxp16_t'(fxp_round_sat(p_im_wide, FXP_PROD_SHIFT, FXP_SAMPLE_W));
      exp_f_re = fxp_sat_flags(fxp_round(p_re_wide, FXP_PROD_SHIFT), FXP_SAMPLE_W);
      exp_f_im = fxp_sat_flags(fxp_round(p_im_wide, FXP_PROD_SHIFT), FXP_SAMPLE_W);
    end else begin
      exp_y_re = '0;
      exp_y_im = '0;
      exp_f_re = fxp_flags_none();
      exp_f_im = fxp_flags_none();
    end
  end

  // ---------------------------------------------------------------------------
  // The properties
  // ---------------------------------------------------------------------------
  always_ff @(posedge clk) begin
    if (rst_n) begin
      // ---- group 1: latency is the parameter --------------------------------
      a_cmult_latency_a : assert (valid_out_a == ref_valid[PIPE_STAGES])
        else $error("cmult: variant A valid_out=%0b but a %0d-stage reference says %0b",
                    valid_out_a, PIPE_STAGES, ref_valid[PIPE_STAGES]);
      a_cmult_latency_b : assert (valid_out_b == ref_valid[PIPE_STAGES])
        else $error("cmult: variant B valid_out=%0b but a %0d-stage reference says %0b",
                    valid_out_b, PIPE_STAGES, ref_valid[PIPE_STAGES]);
      a_cmult_valid_aligned : assert (valid_out_a == valid_out_b)
        else $error("cmult: the two variants present results on different cycles (%0b vs %0b)",
                    valid_out_a, valid_out_b);

      if (valid_out_a) begin
        // ---- group 2: the two variants are bit-identical --------------------
        a_cmult_p_re_match : assert (p_re_a == p_re_b)
          else $error("cmult: full-precision re differs: MULT4 %0d, MULT3 %0d",
                      $signed(p_re_a), $signed(p_re_b));
        a_cmult_p_im_match : assert (p_im_a == p_im_b)
          else $error("cmult: full-precision im differs: MULT4 %0d, MULT3 %0d",
                      $signed(p_im_a), $signed(p_im_b));
        a_cmult_y_re_match : assert (y_re_a == y_re_b)
          else $error("cmult: rounded re differs: MULT4 %0d, MULT3 %0d",
                      $signed(y_re_a), $signed(y_re_b));
        a_cmult_y_im_match : assert (y_im_a == y_im_b)
          else $error("cmult: rounded im differs: MULT4 %0d, MULT3 %0d",
                      $signed(y_im_a), $signed(y_im_b));
        a_cmult_flags_re_match : assert (flags_re_a == flags_re_b)
          else $error("cmult: re flags differ: MULT4 %02b, MULT3 %02b",
                      flags_re_a, flags_re_b);
        a_cmult_flags_im_match : assert (flags_im_a == flags_im_b)
          else $error("cmult: im flags differ: MULT4 %02b, MULT3 %02b",
                      flags_im_a, flags_im_b);
        a_cmult_ovf_match : assert (ovf_a == ovf_b)
          else $error("cmult: ovf differs: MULT4 %0b, MULT3 %0b", ovf_a, ovf_b);

        // ---- group 3: the rounded port is the package's rounding ------------
        a_cmult_round_re : assert (y_re_a == exp_y_re)
          else $error("cmult: y_re=%0d but fxp_round_sat(p_re=%0d) = %0d",
                      $signed(y_re_a), $signed(p_re_a), $signed(exp_y_re));
        a_cmult_round_im : assert (y_im_a == exp_y_im)
          else $error("cmult: y_im=%0d but fxp_round_sat(p_im=%0d) = %0d",
                      $signed(y_im_a), $signed(p_im_a), $signed(exp_y_im));
        a_cmult_flags_re_def : assert (flags_re_a == exp_f_re)
          else $error("cmult: re flags %02b but fxp_sat_flags says %02b (p_re=%0d)",
                      flags_re_a, exp_f_re, $signed(p_re_a));
        a_cmult_flags_im_def : assert (flags_im_a == exp_f_im)
          else $error("cmult: im flags %02b but fxp_sat_flags says %02b (p_im=%0d)",
                      flags_im_a, exp_f_im, $signed(p_im_a));

        // ---- group 4: the flag summary is the summary -----------------------
        a_cmult_ovf_def : assert (ovf_a == (|flags_re_a | |flags_im_a))
          else $error("cmult: ovf=%0b does not summarise flags %02b/%02b",
                      ovf_a, flags_re_a, flags_im_a);

        if (!DO_ROUND) begin
          a_cmult_no_flags_when_unrounded :
            assert (y_re_a == '0 && y_im_a == '0 && flags_re_a == '0 &&
                    flags_im_a == '0 && ovf_a == 1'b0)
              else $error("cmult: ROUND_OUT=0 but y=(%0d,%0d) flags=%02b/%02b ovf=%0b",
                          $signed(y_re_a), $signed(y_im_a), flags_re_a,
                          flags_im_a, ovf_a);
        end
      end
    end
  end

endmodule : cmult_assertions

`default_nettype wire
