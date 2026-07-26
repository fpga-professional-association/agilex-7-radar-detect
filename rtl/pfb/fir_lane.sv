// -----------------------------------------------------------------------------
// fir_lane — one complex FIR lane of the polyphase bank (SPEC.md 6, 7.1, 23).
//
// TAPS complex taps, complex coefficients supplied by a coefficient bank (never
// hard-coded), built from rtl/common/complex_multiplier.sv, quantised ONCE at
// the output through fxp_pkg. It is the SPEC 18 calibration kernel "one complex
// FIR lane" and the unit rtl/pfb/pfb_bank.sv replicates per phase.
//
// -----------------------------------------------------------------------------
// 1. Numerics — one quantisation, and where it is
// -----------------------------------------------------------------------------
//     y[n] = sum_{k=0}^{TAPS-1} h[k] * x[n-k]        (complex, Q1.15 operands)
//
// Every complex_multiplier runs with ROUND_OUT = 0, so each tap contributes its
// EXACT 33-bit partial sums (p_re, p_im) and its rounding network does not
// exist. The TAPS partial sums are accumulated at
// pfb_pkg::pfb_acc_w(TAPS) = fxp_pkg::fxp_mac_q15_acc_w(2*TAPS) bits, a width at
// which the accumulation PROVABLY cannot overflow, and the result is rounded and
// saturated exactly once, at the lane output, by fxp_pkg::fxp_round_sat.
//
// This is fxp_pkg's accumulator policy applied literally, and the consequence is
// the one that matters here: there is no intermediate saturation anywhere in the
// lane, so the accumulation is ASSOCIATIVE and the two accumulation structures
// below are bit-identical rather than merely close. A lane that saturated
// internally would give a different answer for a different reduction order, and
// "tree vs cascade" would stop being a pure cost comparison.
//
// There is no `>>> 15` and no `+ 16384` in this file. Every quantisation is a
// call into fxp_pkg (the standing rule at the top of rtl/packages/fxp_pkg.sv);
// what this module does directly is exact integer addition, which is not
// quantisation.
//
// -----------------------------------------------------------------------------
// 2. The two accumulation structures, and why both exist
// -----------------------------------------------------------------------------
// ACC_STYLE = "TREE" (default)
//     A balanced binary adder tree over the TAPS partial sums, one register per
//     level: clog2(TAPS) levels, 15 adders for TAPS = 16. Every node combines
//     values from the SAME beat, so every register free-runs and the lane has a
//     pure cycle latency. Fabric adders; the DSP blocks do the multiplies only.
//
// ACC_STYLE = "SYSTOLIC"
//     A linear cascade: stage k adds its own product to the PREVIOUS BEAT's
//     partial sum arriving from stage k-1. This is the shape an Agilex DSP
//     cascade wants — each block's chainout feeds the next block's chainin, no
//     fabric adder at all — and it is the textbook answer for a long FIR.
//
//     It costs two things. The data delay line needs TWO stages per tap instead
//     of one (pfb_pkg::pfb_tap_stride), because the partial sum walks forward
//     one stage per beat while the data must walk backward relative to it. And
//     the cascade registers combine values from DIFFERENT beats, so they carry
//     the beat enable and part of the lane's latency is measured in BEATS rather
//     than cycles.
//
// Which one wins on Agilex 7 with Quartus Pro 26.1 is a MEASUREMENT, not an
// argument: the SPEC 18 sweep (quartus/calibration/fir_calib.qsf,
// scripts/run_calibration.py --kernel fir) compiles both and records DSP count,
// cascade usage, ALMs, MLAB/M20K and restricted Fmax. DECISIONS.md carries the
// outcome. Until that data existed the default was TREE, for the honest reason
// that a fabric adder tree is the structure whose cost is predictable without
// knowing what the synthesiser will infer.
//
// -----------------------------------------------------------------------------
// 3. Beats and cycles — the alignment contract
// -----------------------------------------------------------------------------
// `valid_in` marks a cycle carrying a sample. The delay line advances ONLY on
// those cycles: a FIR history is indexed by SAMPLE, and a history that advanced
// once per clock would shift a stale sample in during a SPEC 5 gap and corrupt
// every subsequent output. The gapped-stimulus passes in sim/tests/ exist to
// make that falsifiable rather than assumed.
//
// The lane's latency therefore has two components, both computed by pfb_pkg and
// neither of which may be folded into the other:
//
//     ACC_STYLE    LAT_BEATS   LAT_CYCLES
//     ---------    ---------   --------------------------------
//     TREE             0       MULT_PIPE + clog2(TAPS) + 1
//     SYSTOLIC     TAPS-1      MULT_PIPE + 2
//
// A consumer aligns metadata with a result by delaying it LAT_BEATS BEATS and
// then LAT_CYCLES CYCLES. rtl/pfb/pfb_bank.sv does exactly that; doing it in
// either unit alone is wrong the moment backpressure appears.
//
// A SYSTOLIC lane also has a WARM-UP: its first TAPS-1 beats produce partial
// cascades, and `valid_out` suppresses them. So a finite input burst yields
// TAPS-1 fewer output beats than a TREE lane does, with the remainder still in
// flight — the ordinary drain behaviour of a filter whose latency is measured in
// samples. The output SEQUENCE is identical; only its timing and its tail
// differ.
//
// -----------------------------------------------------------------------------
// 4. Reset and flow control (SPEC 23)
// -----------------------------------------------------------------------------
// Reset validity, not every datapath bit: the delay line, the products, the
// accumulator and the output register have no reset and no global clock enable.
// Only the valid chain and the warm-up counter reset. A beat's outputs are
// meaningful when `valid_out` is high and don't-care otherwise, which is what
// leaves the datapath registers free for Hyper-Register retiming.
//
// No `ready`. This is a fixed-latency arithmetic kernel, exactly as
// complex_multiplier is one, for the same reason: a ready chain here would land
// on the clock enable of every DSP register. Backpressure is the block's
// concern and is handled by the SPEC 5 elastic buffers at the pfb_bank
// boundary.
//
// Lint contract: clean under `verilator --lint-only --Wall` with no waiver.
// -----------------------------------------------------------------------------

`default_nettype none

module fir_lane
  import fxp_pkg::*;
  import pfb_pkg::*;
#(
    parameter int unsigned TAPS = 16,

    // complex_multiplier PIPE_STAGES; equals that module's latency. 4 is the
    // issue #9 calibrated default (DECISIONS.md, issue #9 decision 9).
    parameter int unsigned MULT_PIPE_STAGES = 4,

    // "MULT4" (four real multiplies) or "MULT3" (Karatsuba). Bit-identical.
    parameter string MULT_VARIANT = "MULT4",

    // "TREE" or "SYSTOLIC". See section 2.
    parameter string ACC_STYLE = "TREE",

    // Delay-line storage: "AUTO" | "SRL" | "MEM". A FIR history is tapped at
    // every stage, so pfb_pkg resolves AUTO to SRL here at any depth and an
    // explicit "MEM" is an elaboration error. The parameter exists so the
    // choice is visible and swept, not so it can be got wrong.
    parameter string DELAY_STYLE = "AUTO"
) (
    input  wire                                   clk,
    input  wire                                   rst_n,

    // A sample is present this cycle.
    input  wire                                   valid_in,
    input  wire fxp_complex_t                     x_in,

    // The lane's TAPS complex coefficients, tap-minor: tap k at k*32 +: 32,
    // packed {im, re}. Driven from rtl/pfb/coeff_bank.sv; never a constant.
    input  wire [TAPS*2*FXP_SAMPLE_W-1:0]         coeff,

    output wire                                   valid_out,
    output wire fxp_complex_t                     y_out,

    // Direction-resolved saturation flags for the single output quantisation.
    output wire fxp_flags_t                       flags_re,
    output wire fxp_flags_t                       flags_im,
    output wire                                   ovf
);

  localparam int unsigned COEFF_W = 2 * FXP_SAMPLE_W;         // 32
  localparam int unsigned PROD_W  = FXP_PROD_W + 1;           // 33, exact
  localparam int unsigned ACC_W   = int'(pfb_acc_w(pfb_uint_t'(TAPS)));
  localparam int unsigned LEVELS  = int'(pfb_tree_levels(pfb_uint_t'(TAPS)));
  localparam int unsigned NPAD    = int'(pfb_tree_leaves(pfb_uint_t'(TAPS)));
  localparam int unsigned STRIDE  = int'(pfb_tap_stride(ACC_STYLE));

  localparam bit USE_SYS = pfb_style_systolic(ACC_STYLE);

  // Latency, from pfb_pkg. Exported to nothing: a consumer calls the same
  // functions. They are localparams here so the elaboration check below compares
  // the CONSTRUCTED pipeline against the ADVERTISED one.
  localparam int unsigned LAT_BEATS =
      int'(pfb_lat_beats(ACC_STYLE, pfb_uint_t'(TAPS)));
  localparam int unsigned LAT_CYCLES =
      int'(pfb_lat_cycles(ACC_STYLE, pfb_uint_t'(TAPS), pfb_uint_t'(MULT_PIPE_STAGES)));

  // Free-running register stages after the multiplier: the tree levels plus the
  // output register, or the cascade's accumulator register plus the output
  // register. See pfb_pkg's pfb_lat_cycles() for why the cascade has two.
  localparam int unsigned POST_STAGES = USE_SYS ? 2 : (LEVELS + 1);

  localparam int unsigned WARM_W = (TAPS <= 1) ? 1 : $clog2(TAPS);

`ifndef SYNTHESIS
  initial begin
    if (TAPS < 1 || TAPS > int'(pfb_max_taps())) begin
      $fatal(1, "fir_lane: TAPS=%0d outside [1, %0d]", TAPS, pfb_max_taps());
    end
    if (!pfb_style_ok(ACC_STYLE)) begin
      $fatal(1, "fir_lane: ACC_STYLE=\"%s\" is not \"TREE\" or \"SYSTOLIC\"",
             ACC_STYLE);
    end
    if (!pfb_delay_style_ok(DELAY_STYLE)) begin
      $fatal(1, "fir_lane: DELAY_STYLE=\"%s\" is not \"AUTO\", \"SRL\" or \"MEM\"",
             DELAY_STYLE);
    end
    // The advertised cycle latency must equal the number of register stages this
    // module actually builds. If either side is edited alone, this fires at
    // time 0 rather than as a misaligned scoreboard entry.
    if (LAT_CYCLES != MULT_PIPE_STAGES + POST_STAGES) begin
      $fatal(1, "fir_lane: pfb_lat_cycles()=%0d but the pipeline builds %0d stages",
             LAT_CYCLES, MULT_PIPE_STAGES + POST_STAGES);
    end
    if (LAT_BEATS != (USE_SYS ? (TAPS - 1) : 0)) begin
      $fatal(1, "fir_lane: pfb_lat_beats()=%0d disagrees with the cascade depth",
             LAT_BEATS);
    end
    // The accumulator must be wide enough that the sum of TAPS exact 33-bit
    // partial sums cannot overflow. Restated as an inequality rather than
    // trusted from the package, because it is the assumption that makes
    // "no intermediate saturation" true.
    if (ACC_W < PROD_W + int'(pfb_tree_levels(pfb_uint_t'(TAPS)))) begin
      $fatal(1, "fir_lane: ACC_W=%0d is too narrow for %0d partial sums of %0d bits",
             ACC_W, TAPS, PROD_W);
    end
  end
`endif

  // ---------------------------------------------------------------------------
  // Sample history. Tap 0 is the live sample; tap k comes from the delay line.
  // The line advances only on a beat (section 3).
  // ---------------------------------------------------------------------------
  logic [TAPS-1:0][COEFF_W-1:0] xtap;

  assign xtap[0] = x_in;

  if (TAPS > 1) begin : g_delay
    logic [(TAPS-1)*COEFF_W-1:0] dl_taps;

    // Named sink rather than `()`; see rtl/cdc/stream_cdc.sv for the
    // convention. The deepest tap is already dl_taps[TAPS-2].
    logic [COEFF_W-1:0] dl_q_unused;

    delay_line #(
        .WIDTH      (COEFF_W),
        .N_TAPS     (TAPS - 1),
        .TAP_STRIDE (STRIDE),
        .STYLE      (DELAY_STYLE)
    ) u_hist (
        .clk  (clk),
        .en   (valid_in),
        .d    (x_in),
        .taps (dl_taps),
        .q    (dl_q_unused)
    );

    for (genvar k = 1; k < int'(TAPS); k++) begin : g_tap
      assign xtap[k] = dl_taps[(k-1)*COEFF_W +: COEFF_W];
    end
  end

  // ---------------------------------------------------------------------------
  // TAPS complex multipliers, exact output (ROUND_OUT = 0)
  //
  // prod[0] is the real component's partial sum, prod[1] the imaginary one.
  // ---------------------------------------------------------------------------
  logic [1:0][TAPS-1:0][PROD_W-1:0] prod;
  logic [TAPS-1:0]                  mult_valid_all;

  for (genvar k = 0; k < int'(TAPS); k++) begin : g_mult
    fxp_complex_t             a_k, b_k;
    logic                     v_k;
    logic signed [PROD_W-1:0] pr_k, pi_k;

    // ROUND_OUT = 0, so the rounded port and its flags are tied off inside the
    // multiplier and its whole rounding network is absent. Named sinks rather
    // than `()`; the lane rounds ONCE, at its own output.
    fxp16_t     y_re_unused, y_im_unused;
    fxp_flags_t flags_re_unused, flags_im_unused;
    logic       ovf_unused;

    assign a_k = fxp_complex_t'(xtap[k]);
    assign b_k = fxp_complex_t'(coeff[k*COEFF_W +: COEFF_W]);

    complex_multiplier #(
        .VARIANT     (MULT_VARIANT),
        .PIPE_STAGES (MULT_PIPE_STAGES),
        .ROUND_OUT   (0)
    ) u_mult (
        .clk       (clk),
        .rst_n     (rst_n),
        .valid_in  (valid_in),
        .a         (a_k),
        .b         (b_k),
        .valid_out (v_k),
        .p_re      (pr_k),
        .p_im      (pi_k),
        .y_re      (y_re_unused),
        .y_im      (y_im_unused),
        .flags_re  (flags_re_unused),
        .flags_im  (flags_im_unused),
        .ovf       (ovf_unused)
    );

    assign prod[0][k]        = pr_k;
    assign prod[1][k]        = pi_k;
    assign mult_valid_all[k] = v_k;
  end

  // Every multiplier is identical and identically stimulated, so their valids
  // are the same signal; tap 0's is used and the others feed the elaboration-
  // independent check below rather than being dropped silently.
  logic mult_valid;
  assign mult_valid = mult_valid_all[0];

  // ---------------------------------------------------------------------------
  // Accumulation
  // ---------------------------------------------------------------------------
  logic [1:0][ACC_W-1:0] acc;

  // Head of the output valid chain. For the cascade it carries the WARM-UP gate:
  // the first TAPS-1 beats produce partial cascades and must not be presented as
  // results. Built inside the generate rather than as a ternary at module scope
  // so that a tree lane elaborates no warm-up counter at all.
  logic core_valid;

  if (USE_SYS) begin : g_warm
    // Counts admitted beats at the cascade input and saturates at TAPS-1, which
    // is the beat index from which the cascade output is a complete sum.
    logic [WARM_W-1:0] warm_q;

    always_ff @(posedge clk) begin
      if (!rst_n) begin
        warm_q <= '0;
      end else if (mult_valid && (warm_q != WARM_W'(TAPS - 1))) begin
        warm_q <= warm_q + WARM_W'(1);
      end
    end

    assign core_valid = mult_valid && (warm_q == WARM_W'(TAPS - 1));
  end else begin : g_no_warm
    // A tree lane has no warm-up: its first output is a complete sum, computed
    // from a history that is still mostly zero — which is exactly what the C++
    // reference model computes too.
    assign core_valid = mult_valid;
  end

  if (USE_SYS) begin : g_cascade
    // -------------------------------------------------------------------------
    // Linear cascade. ONE shared enable for every stage, and it is the
    // multiplier's output valid — not a per-stage delayed copy of it.
    //
    // That distinction is the whole correctness argument. With one shared
    // enable, every cascade register advances exactly once per beat, so at the
    // enable for beat m stage k-1 still holds beat m-1's partial sum, which is
    // the one-beat skew the cascade needs. With per-stage enables, stage k-1
    // would have been enabled one cycle earlier FOR THE SAME BEAT and the skew
    // would collapse to zero — a defect that is invisible on a gapless stream
    // and wrong on every other one.
    // -------------------------------------------------------------------------
    logic [1:0][TAPS-1:0][ACC_W-1:0] chain;

    for (genvar c = 0; c < 2; c++) begin : g_comp
      for (genvar k = 0; k < int'(TAPS); k++) begin : g_stage
        logic signed [PROD_W-1:0] pv;
        logic signed [ACC_W-1:0]  sum_c;
        logic        [ACC_W-1:0]  stage_q;

        assign pv = signed'(prod[c][k]);

        if (k == 0) begin : g_head
          assign sum_c = ACC_W'(pv);
        end else begin : g_body
          assign sum_c = ACC_W'(pv) + signed'(chain[c][k-1]);
        end

        always_ff @(posedge clk) begin
          if (mult_valid) stage_q <= sum_c;
        end

        assign chain[c][k] = stage_q;
      end

      assign acc[c] = chain[c][TAPS-1];
    end

  end else begin : g_tree
    // -------------------------------------------------------------------------
    // Balanced adder tree. Padded to a power of two so the structure is one
    // uniform loop; the padding leaves are constant zero and disappear.
    //
    // Every bit of `node` has exactly one continuous driver — the same
    // discipline rtl/common/complex_multiplier.sv uses for its shadow chain —
    // so no node can pick up a second procedural writer as the module grows.
    // -------------------------------------------------------------------------
    logic [1:0][LEVELS:0][NPAD-1:0][ACC_W-1:0] node;

    for (genvar c = 0; c < 2; c++) begin : g_comp
      for (genvar i = 0; i < int'(NPAD); i++) begin : g_leaf
        if (i < int'(TAPS)) begin : g_real
          logic signed [PROD_W-1:0] pv;
          assign pv            = signed'(prod[c][i]);
          assign node[c][0][i] = ACC_W'(pv);
        end else begin : g_pad
          assign node[c][0][i] = '0;
        end
      end

      for (genvar l = 1; l <= int'(LEVELS); l++) begin : g_level
        for (genvar i = 0; i < int'(NPAD); i++) begin : g_node
          if (i < (int'(NPAD) >> l)) begin : g_add
            logic [ACC_W-1:0] sum_q;
            always_ff @(posedge clk) begin
              sum_q <= ACC_W'(signed'(node[c][l-1][2*i]) +
                              signed'(node[c][l-1][2*i+1]));
            end
            assign node[c][l][i] = sum_q;
          end else begin : g_unused
            assign node[c][l][i] = '0;
          end
        end
      end

      assign acc[c] = node[c][LEVELS][0];
    end
  end

  // ---------------------------------------------------------------------------
  // The lane's ONE quantisation, and its output register
  //
  // Flags describe the value being clamped — after the round, before the
  // saturate — which is the order fxp_pkg fixes and the only order in which a
  // round-induced overflow is reportable at all.
  // ---------------------------------------------------------------------------
  fxp16_t     y_re_c, y_im_c;
  fxp_flags_t f_re_c, f_im_c;

  always_comb begin
    y_re_c = fxp16_t'(fxp_round_sat(fxp_wide_t'(signed'(acc[0])),
                                    FXP_PROD_SHIFT, FXP_SAMPLE_W));
    y_im_c = fxp16_t'(fxp_round_sat(fxp_wide_t'(signed'(acc[1])),
                                    FXP_PROD_SHIFT, FXP_SAMPLE_W));
    f_re_c = fxp_sat_flags(fxp_round(fxp_wide_t'(signed'(acc[0])),
                                     FXP_PROD_SHIFT), FXP_SAMPLE_W);
    f_im_c = fxp_sat_flags(fxp_round(fxp_wide_t'(signed'(acc[1])),
                                     FXP_PROD_SHIFT), FXP_SAMPLE_W);
  end

  fxp16_t     y_re_q, y_im_q;
  fxp_flags_t f_re_q, f_im_q;

  always_ff @(posedge clk) begin
    y_re_q <= y_re_c;
    y_im_q <= y_im_c;
    f_re_q <= f_re_c;
    f_im_q <= f_im_c;
  end

  assign y_out    = '{im: y_im_q, re: y_re_q};
  assign flags_re = f_re_q;
  assign flags_im = f_im_q;
  assign ovf      = fxp_flags_any(f_re_q) | fxp_flags_any(f_im_q);

  // ---------------------------------------------------------------------------
  // Valid pipeline — the only reset state in the datapath (SPEC 23)
  //
  // POST_STAGES free-running stages after the multiplier for the tree; for the
  // cascade, one stage, gated by the warm-up so the partial cascades of the
  // first TAPS-1 beats never appear as results.
  // ---------------------------------------------------------------------------
  logic [POST_STAGES:0] vch;

  assign vch[0] = core_valid;

  for (genvar s = 0; s < int'(POST_STAGES); s++) begin : g_valid
    logic v_q;
    always_ff @(posedge clk) begin
      if (!rst_n) v_q <= 1'b0;
      else        v_q <= vch[s];
    end
    assign vch[s+1] = v_q;
  end

  assign valid_out = vch[POST_STAGES];

  // ---------------------------------------------------------------------------
  // Simulation-only structural check: every multiplier in the lane must agree
  // about when its result is valid. They are identical modules driven by one
  // `valid_in`, so a disagreement means the generate loop has been broken —
  // which would otherwise show up only as a wrong sum.
  // ---------------------------------------------------------------------------
`ifndef SYNTHESIS
  always_ff @(posedge clk) begin
    if (rst_n) begin
      a_fir_mult_valid_uniform : assert (mult_valid_all == {TAPS{mult_valid}})
        else $error("fir_lane: multiplier valids disagree (%b)", mult_valid_all);
    end
  end
`endif

endmodule : fir_lane

`default_nettype wire
