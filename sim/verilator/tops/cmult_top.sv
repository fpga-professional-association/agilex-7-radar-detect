// -----------------------------------------------------------------------------
// cmult_top — the complex-multiplier verification top (issue #9, SPEC 13.1).
//
// Holds the WHOLE parameter space of rtl/common/complex_multiplier.sv in one
// elaboration, driven from one stimulus port, so that "both variants agree" and
// "latency is the parameter" are same-cycle facts rather than a comparison of
// two separate runs:
//
//   index  VARIANT  PIPE_STAGES  ROUND_OUT
//   -----  -------  -----------  ---------
//    0..4  MULT4      1,2,3,4,5      1
//    5..9  MULT3      1,2,3,4,5      1
//     10   MULT4          3          0
//     11   MULT3          3          0
//
// Indices i and i+5 are the SAME configuration with a different factorization,
// and 10/11 are the same pair with the rounding network switched off. Every such
// pair is watched every cycle by a cmult_assertions instance, which is what makes
// bit-identity a property of the build rather than of the test that happened to
// run. sim/tests/test_cmult.cpp additionally reads all twelve through the
// observation mux and compares each against model/cpp/fxp/cmult.hpp and against
// model/vectors/cmult.vec.
//
// Observation mux. All twelve DUTs are clocked and stimulated identically and
// always; `dut_sel` chooses which one drives the output ports. The C++ side
// re-evaluates the model once per DUT per cycle, so a single stimulus pass
// observes all twelve — no replay, no assumption that two runs saw the same
// pseudo-random stream.
//
// Parameter echo. cfg_pipe_stages / cfg_variant_mult3 / cfg_round_out report the
// SELECTED DUT's elaboration parameters. The latency test measures the pipeline
// depth from the RTL and compares it against this, so "latency == PIPE_STAGES"
// is checked against what was elaborated rather than against a number the test
// also chose.
//
// Simulation only. Not in files.f, never in a Quartus source list; the DUT
// itself is in files.f and in quartus/calibration/.
// -----------------------------------------------------------------------------

`default_nettype none

module cmult_top
  import fxp_pkg::*;
(
    input  wire         clk,
    input  wire         rst_n,

    // Shared stimulus. One operand pair per cycle, qualified by valid_in.
    input  wire         valid_in,
    input  wire [15:0]  a_re,
    input  wire [15:0]  a_im,
    input  wire [15:0]  b_re,
    input  wire [15:0]  b_im,

    // Observation mux select. Out-of-range values select DUT 0.
    input  wire [7:0]   dut_sel,

    // The selected DUT's outputs.
    output wire         valid_out,
    output wire [32:0]  p_re,
    output wire [32:0]  p_im,
    output wire [15:0]  y_re,
    output wire [15:0]  y_im,
    output wire [1:0]   flags_re,   // {sat_pos, sat_neg}
    output wire [1:0]   flags_im,
    output wire         ovf,

    // The selected DUT's elaboration parameters, and the geometry of the grid.
    output wire [7:0]   cfg_n_dut,
    output wire [7:0]   cfg_pipe_stages,
    output wire         cfg_variant_mult3,
    output wire         cfg_round_out,
    output wire [7:0]   cfg_prod_w,
    output wire [7:0]   cfg_pipe_min,
    output wire [7:0]   cfg_pipe_max
);

  // ---------------------------------------------------------------------------
  // Grid definition. Mirrored in sim/tests/test_cmult.cpp (kDutStages /
  // kDutMult3 / kDutRound); the test checks its mirror against the cfg_* echo on
  // every DUT, so a drift is a failure rather than a silently wrong comparison.
  // ---------------------------------------------------------------------------
  localparam int unsigned N_DUT  = 12;
  localparam int unsigned PROD_W = FXP_PROD_W + 1;   // 33

  // Legal PIPE_STAGES range, restated here so the grid and the DUT cannot
  // disagree about what "min" and "max" mean.
  localparam int unsigned PIPE_MIN = 1;
  localparam int unsigned PIPE_MAX = 5;

  localparam int unsigned DUT_STAGES [N_DUT] =
      '{1, 2, 3, 4, 5,  1, 2, 3, 4, 5,  3, 3};
  localparam bit          DUT_MULT3  [N_DUT] =
      '{0, 0, 0, 0, 0,  1, 1, 1, 1, 1,  0, 1};
  localparam int unsigned DUT_ROUND  [N_DUT] =
      '{1, 1, 1, 1, 1,  1, 1, 1, 1, 1,  0, 0};

  // Matched pairs: same PIPE_STAGES and ROUND_OUT, different factorization.
  localparam int unsigned N_PAIR = 6;
  localparam int unsigned PAIR_A [N_PAIR] = '{0, 1, 2, 3, 4, 10};
  localparam int unsigned PAIR_B [N_PAIR] = '{5, 6, 7, 8, 9, 11};

  fxp_complex_t a_in, b_in;
  assign a_in = '{re: fxp16_t'(a_re), im: fxp16_t'(a_im)};
  assign b_in = '{re: fxp16_t'(b_re), im: fxp16_t'(b_im)};

  // ---------------------------------------------------------------------------
  // The grid. Packed collector buses: one continuous driver per index, so no
  // element ever has two drivers.
  // ---------------------------------------------------------------------------
  logic [N_DUT-1:0]             d_valid;
  logic [N_DUT-1:0][PROD_W-1:0] d_p_re, d_p_im;
  logic [N_DUT-1:0][15:0]       d_y_re, d_y_im;
  logic [N_DUT-1:0][1:0]        d_flags_re, d_flags_im;
  logic [N_DUT-1:0]             d_ovf;

  for (genvar i = 0; i < int'(N_DUT); i++) begin : g_dut
    logic              vo;
    logic signed [PROD_W-1:0] pre_o, pim_o;
    fxp16_t            yre_o, yim_o;
    fxp_flags_t        fre_o, fim_o;
    logic              ovf_o;

    // The two branches exist because VARIANT is a string parameter and a
    // conditional-expression override of one is not portable across tools. The
    // outputs are collected into the shared buses below either way, so the
    // hierarchy difference is invisible to everything outside this scope.
    if (DUT_MULT3[i]) begin : g_m3
      complex_multiplier #(
          .VARIANT     ("MULT3"),
          .PIPE_STAGES (DUT_STAGES[i]),
          .ROUND_OUT   (DUT_ROUND[i])
      ) u_dut (
          .clk       (clk),
          .rst_n     (rst_n),
          .valid_in  (valid_in),
          .a         (a_in),
          .b         (b_in),
          .valid_out (vo),
          .p_re      (pre_o),
          .p_im      (pim_o),
          .y_re      (yre_o),
          .y_im      (yim_o),
          .flags_re  (fre_o),
          .flags_im  (fim_o),
          .ovf       (ovf_o)
      );
    end else begin : g_m4
      complex_multiplier #(
          .VARIANT     ("MULT4"),
          .PIPE_STAGES (DUT_STAGES[i]),
          .ROUND_OUT   (DUT_ROUND[i])
      ) u_dut (
          .clk       (clk),
          .rst_n     (rst_n),
          .valid_in  (valid_in),
          .a         (a_in),
          .b         (b_in),
          .valid_out (vo),
          .p_re      (pre_o),
          .p_im      (pim_o),
          .y_re      (yre_o),
          .y_im      (yim_o),
          .flags_re  (fre_o),
          .flags_im  (fim_o),
          .ovf       (ovf_o)
      );
    end

    assign d_valid[i]    = vo;
    assign d_p_re[i]     = pre_o;
    assign d_p_im[i]     = pim_o;
    assign d_y_re[i]     = yre_o;
    assign d_y_im[i]     = yim_o;
    assign d_flags_re[i] = fre_o;
    assign d_flags_im[i] = fim_o;
    assign d_ovf[i]      = ovf_o;
  end

  // ---------------------------------------------------------------------------
  // Cross-variant checkers, one per matched pair
  // ---------------------------------------------------------------------------
  for (genvar q = 0; q < int'(N_PAIR); q++) begin : g_pair
    cmult_assertions #(
        .PIPE_STAGES (DUT_STAGES[PAIR_A[q]]),
        .ROUND_OUT   (DUT_ROUND[PAIR_A[q]]),
        .PROD_W      (PROD_W)
    ) u_chk (
        .clk         (clk),
        .rst_n       (rst_n),
        .valid_in    (valid_in),
        .valid_out_a (d_valid[PAIR_A[q]]),
        .p_re_a      (d_p_re[PAIR_A[q]]),
        .p_im_a      (d_p_im[PAIR_A[q]]),
        .y_re_a      (d_y_re[PAIR_A[q]]),
        .y_im_a      (d_y_im[PAIR_A[q]]),
        .flags_re_a  (d_flags_re[PAIR_A[q]]),
        .flags_im_a  (d_flags_im[PAIR_A[q]]),
        .ovf_a       (d_ovf[PAIR_A[q]]),
        .valid_out_b (d_valid[PAIR_B[q]]),
        .p_re_b      (d_p_re[PAIR_B[q]]),
        .p_im_b      (d_p_im[PAIR_B[q]]),
        .y_re_b      (d_y_re[PAIR_B[q]]),
        .y_im_b      (d_y_im[PAIR_B[q]]),
        .flags_re_b  (d_flags_re[PAIR_B[q]]),
        .flags_im_b  (d_flags_im[PAIR_B[q]]),
        .ovf_b       (d_ovf[PAIR_B[q]])
    );
  end

  // ---------------------------------------------------------------------------
  // Observation mux
  // ---------------------------------------------------------------------------
  logic [$clog2(N_DUT)-1:0] sel;
  assign sel = (dut_sel < 8'(N_DUT)) ? dut_sel[$clog2(N_DUT)-1:0] : '0;

  assign valid_out = d_valid[sel];
  assign p_re      = 33'(d_p_re[sel]);
  assign p_im      = 33'(d_p_im[sel]);
  assign y_re      = d_y_re[sel];
  assign y_im      = d_y_im[sel];
  assign flags_re  = d_flags_re[sel];
  assign flags_im  = d_flags_im[sel];
  assign ovf       = d_ovf[sel];

  assign cfg_n_dut         = 8'(N_DUT);
  assign cfg_pipe_stages   = 8'(DUT_STAGES[sel]);
  assign cfg_variant_mult3 = DUT_MULT3[sel];
  assign cfg_round_out     = (DUT_ROUND[sel] != 0);
  assign cfg_prod_w        = 8'(PROD_W);
  assign cfg_pipe_min      = 8'(PIPE_MIN);
  assign cfg_pipe_max      = 8'(PIPE_MAX);

  // ---------------------------------------------------------------------------
  // Elaboration sanity: the grid must actually cover the legal depth range and
  // both variants, or the "min/typ/max" claim in VERIFICATION_PLAN.md is empty.
  // ---------------------------------------------------------------------------
`ifndef SYNTHESIS
  initial begin
    automatic int unsigned seen_m4 = 0;
    automatic int unsigned seen_m3 = 0;
    automatic int unsigned dmin = 255;
    automatic int unsigned dmax = 0;
    for (int unsigned i = 0; i < N_DUT; i++) begin
      if (DUT_MULT3[i]) seen_m3++; else seen_m4++;
      if (DUT_STAGES[i] < dmin) dmin = DUT_STAGES[i];
      if (DUT_STAGES[i] > dmax) dmax = DUT_STAGES[i];
    end
    if (seen_m3 == 0 || seen_m4 == 0) begin
      $fatal(1, "cmult_top: grid does not cover both variants");
    end
    if (dmin != PIPE_MIN || dmax != PIPE_MAX) begin
      $fatal(1, "cmult_top: grid covers depths [%0d, %0d], expected [%0d, %0d]",
             dmin, dmax, PIPE_MIN, PIPE_MAX);
    end
    for (int unsigned q = 0; q < N_PAIR; q++) begin
      if (DUT_STAGES[PAIR_A[q]] != DUT_STAGES[PAIR_B[q]] ||
          DUT_ROUND[PAIR_A[q]]  != DUT_ROUND[PAIR_B[q]]  ||
          DUT_MULT3[PAIR_A[q]]  == DUT_MULT3[PAIR_B[q]]) begin
        $fatal(1, "cmult_top: pair %0d is not a matched MULT4/MULT3 pair", q);
      end
    end
  end
`endif

endmodule : cmult_top

`default_nettype wire
