// -----------------------------------------------------------------------------
// covar_engine — cross-power Rxy = X * conj(Y) for a programmed pair list
// (SPEC.md 7.6, issue #13).
//
// The second half of the SPEC 7.6 block. N_PAIRS independent cross-power
// channels, each watching one (X, Y) pair drawn from a parallel vector of
// antenna or beam streams, each integrated by its own rtl/covariance/integrator.sv
// with the same window, the same accumulator protection and the same flush
// semantics as the power path, and each with a runtime enable.
//
// -----------------------------------------------------------------------------
// 1. Input contract: parallel sources, not time-multiplexed pairs
// -----------------------------------------------------------------------------
// The input is ONE BEAT carrying one complex sample from each of N_SRC sources
// simultaneously — the antenna vector, or the beam vector — and the pair table
// selects two of them per pair. The alternative contract, a serialised stream of
// (X, Y) pair samples with the pair index as metadata, was rejected. The reason
// is the shape of the pipeline this block sits in (SPEC 3):
//
//     ... -> frequency alignment -> beamforming matrix -> HERE -> CFAR ...
//
// Everything upstream already produces all channels for a given instant in the
// same beat: the alignment network exists precisely to put matching frequency
// bins from every antenna on the same cycle, and the beamforming matrix emits
// all N_BEAMS at once. A time-multiplexed input would therefore require a
// re-serialiser in front of this block whose only purpose is to undo that, and
// it would cap the input rate at one vector every (number of enabled pairs)
// cycles — for the SPEC 11 medium configuration, N_SRC = 4 with the full upper
// triangle of 10 pairs, that is a 10x rate reduction on a pipeline whose every
// other stage runs at one beat per cycle. It would also need an elastic buffer
// and a ready chain, which is exactly the free-running, latency-insensitive
// convention every other Phase 2 kernel avoids on purpose (DECISIONS.md issue #9,
// decision 4).
//
// The price of the parallel contract is DSPs: one complex multiplier per pair,
// four 16x16 multipliers each at MULT4. At medium that is 10 pairs = 40 DSPs,
// about half a percent of the AGMF039's DSP column, against a 10x throughput
// gain — so the trade is not close at this size. It does NOT stay comfortable
// at full scale: N_SRC = 16 with a full upper triangle is 136 pairs = 544 DSPs,
// which is where MULT3 (three multipliers per pair, DECISIONS.md issue #9
// decision 2 — bit-identical, so it is a pure resource decision) and a pruned
// pair list start to matter. Both are already parameters here: VARIANT and
// N_PAIRS. The full-scale pair count is a SPEC 18 measurement, not a guess made
// in this file.
//
// -----------------------------------------------------------------------------
// 2. Conjugation without a negation: the operand swap
// -----------------------------------------------------------------------------
// SPEC 7.6 wants X * conj(Y), and issue #13 requires it to come out of the
// issue #9 complex multiplier rather than out of new arithmetic. The obvious
// wiring — feed the multiplier b = (y.re, -y.im) — IS WRONG, and wrong on the
// one input a reviewer tries first: y.im = -32768 is a legal Q1.15 value whose
// negation is +32768, which does not fit 16 bits. Negating it saturates (giving
// the wrong product) or wraps back to -32768 (giving the wrong sign). Either way
// the extreme corner, which is exactly the corner the accumulator analysis is
// built on, would be silently incorrect.
//
// The fix is to conjugate by rewiring rather than by negating. Feed the
// multiplier the Y operand with its two halves EXCHANGED:
//
//     a = X = (x.re, x.im)          b = (b.re = y.im, b.im = y.re)
//
// complex_multiplier then computes, by its own definition,
//
//     p_re = a.re*b.re - a.im*b.im = x.re*y.im - x.im*y.re
//     p_im = a.re*b.im + a.im*b.re = x.re*y.re + x.im*y.im
//
// while the conjugate product is
//
//     X*conj(Y) = (x.re + j x.im)(y.re - j y.im)
//               = (x.re*y.re + x.im*y.im) + j (x.im*y.re - x.re*y.im)
//
// so
//
//     Rxy.re =  p_im            Rxy.im = -p_re                            (**)
//
// The negation moved from a 16-bit OPERAND, where -32768 overflows, to the
// 33-bit exact PRODUCT port, where |p_re| <= 2^31 and the field holds
// [-2^32, 2^32-1] — so it cannot overflow, for any input, and it costs one
// adder rather than one multiplier. No new arithmetic, no saturation, the issue
// #9 kernel used exactly as it is.
//
// The test that keeps (**) honest is a directed one: X = Y makes Rxx real and
// equal to the power, so `Rxx.re` must equal power_calc's output for the same
// sample and `Rxx.im` must be exactly zero, on the corners including
// (-32768, -32768). Swapping the two halves back — the "drop the conjugate"
// fault injection — breaks both immediately.
//
// ROUND_OUT = 0. The multiplier's rounded Q1.15 port is not instantiated: the
// accumulator consumes the EXACT 33-bit product, because quantising each term
// back to Q1.15 before summing 255 of them would throw away precisely the bits
// the 40-bit accumulator exists to keep (covar_pkg section 1). The rounding
// network optimises away entirely.
//
// -----------------------------------------------------------------------------
// 3. Per-pair enable, and where the gate is
// -----------------------------------------------------------------------------
// The enable gates the ACCUMULATION, not the multiply. The multiplier free-runs:
// its registers have no clock enable, for the reason SPEC 23 gives and issue #9
// measured — an enable on a DSP register is what stops the tool from using the
// block's own pipeline registers, and a per-pair enable is exactly the kind of
// high-fanout control that should not reach a datapath register.
//
// So a disabled pair still computes a product, and that product goes nowhere:
// integrator.sv's `cfg_enable` is what admits a sample, and it latches at a
// window boundary, so a pair disabled mid-window finishes the window it was in
// and then stops, and a pair enabled mid-window starts at the NEXT window with a
// full-length one. Neither ever emits a partial window as a side effect of a
// register write; the only thing that produces a short window is an explicit
// flush, and it is marked. That is the "clean window semantics" the runtime
// enable has to have to be usable at all: a mask written while data flows must
// not corrupt the window in flight.
//
// -----------------------------------------------------------------------------
// 4. The pair table takes effect at a flush, not at a window boundary
// -----------------------------------------------------------------------------
// The X and Y source SELECTORS are latched on reset and on `flush`, and nowhere
// else. This is deliberately stricter than the enable rule above, and the reason
// is the pipeline: the multiplier is CMULT_PIPE_STAGES deep, so at any instant
// there are products in flight that were formed from the selectors as they were
// several cycles ago. A selector change timed against the integrator's window
// boundary would still let a handful of in-flight products from the old sources
// land in the new window — a boundary that is exact at the accumulator is not
// exact at the multiplier input, and pretending otherwise is how a block
// acquires a rare, timing-dependent wrong answer.
//
// Re-pointing a pair is therefore: write the table, pulse FLUSH. The flush
// drains whatever was open, marks it, and restarts every pair from a known
// state, and the in-flight products belong to a window that has already been
// closed and labelled. The per-window runtime control SPEC 7.6 actually asks for
// is the per-pair ENABLE (section 3), which has no such hazard because a
// disabled pair's in-flight products are discarded rather than misattributed.
//
// A selector naming a source that does not exist (index >= N_SRC) reads source
// 0. Out-of-range is defined rather than undefined, for the same reason
// cmult_top's observation mux defines it: a register plane can be programmed
// with anything, and "X" is not a behaviour.
//
// Lint contract: clean under `verilator --lint-only --Wall` with no waiver.
// -----------------------------------------------------------------------------

`default_nettype none

module covar_engine
  import fxp_pkg::*;
  import covar_pkg::*;
#(
    // Parallel source streams on the input beat: antennas after alignment, or
    // beams after the beamforming matrix. The engine does not care which.
    parameter int unsigned N_SRC = 2,

    // Cross-power channels. Each has its own pair-table entry, its own
    // multiplier and its own pair of accumulators.
    parameter int unsigned N_PAIRS = 3,

    // Passed straight through to rtl/common/complex_multiplier.sv. "MULT4" and
    // "MULT3" are bit-identical (DECISIONS.md issue #9, decision 2); the choice
    // is DSP count against ALM count and is a SPEC 18 measurement.
    parameter string       CMULT_VARIANT     = "MULT4",
    parameter int unsigned CMULT_PIPE_STAGES = 4,

    // Accumulator width (SPEC 3 POWER_W) and window geometry. Passed through to
    // integrator.sv, which owns the protection analysis.
    parameter int unsigned ACC_W       = COVAR_POWER_W,
    parameter int unsigned WINDOW_W    = COVAR_WINDOW_LEN_W,
    parameter int unsigned SAT_COUNT_W = 32,

    // Source-selector width in the pair table. Fixed by the register-plane
    // field width; checked against covar_pkg at elaboration and never
    // overridden in the design. It is a parameter rather than a localparam only
    // because a port width cannot reference a body localparam.
    parameter int unsigned SEL_W = 8
) (
    input  wire                                  clk,
    input  wire                                  rst_n,

    // ---- source vector -------------------------------------------------------
    // One complex Q1.15 sample per source, packed low-index-first, each entry
    // {im, re} exactly as fxp_pkg::fxp_complex_t packs. No ready; see section 1.
    input  wire                                  valid_in,
    input  wire [N_SRC*2*FXP_SAMPLE_W-1:0]       src,

    // ---- pair table (register plane). Latched on flush; see section 4. -------
    input  wire [N_PAIRS*SEL_W-1:0]              cfg_pair_x,
    input  wire [N_PAIRS*SEL_W-1:0]              cfg_pair_y,

    // ---- per-pair runtime enable. Latched at a window boundary; section 3. ---
    input  wire [N_PAIRS-1:0]                    cfg_pair_enable,

    // ---- integration configuration, shared by every pair --------------------
    input  wire [WINDOW_W-1:0]                   cfg_window_len,
    input  wire                                  cfg_mode,      // covar_mode_e
    input  wire [COVAR_EXP_K_W-1:0]              cfg_exp_k,
    input  wire                                  flush,
    input  wire                                  sat_clear,

    // ---- per-pair window results --------------------------------------------
    output wire [N_PAIRS-1:0]                    pair_valid,
    output wire [N_PAIRS*ACC_W-1:0]              pair_acc_re,
    output wire [N_PAIRS*ACC_W-1:0]              pair_acc_im,
    output wire [N_PAIRS*COVAR_WINDOW_ID_W-1:0]  pair_window_id,
    output wire [N_PAIRS*WINDOW_W-1:0]           pair_sample_count,
    output wire [N_PAIRS-1:0]                    pair_flushed,
    output wire [N_PAIRS-1:0]                    pair_truncated,

    // ---- accumulator protection ---------------------------------------------
    output wire [N_PAIRS-1:0]                    pair_sat,
    output wire                                  sat_any,
    output wire [SAT_COUNT_W-1:0]                sat_count_max,

    // ---- observation --------------------------------------------------------
    // The active selectors, so a test can prove the flush-latched table is what
    // actually ran rather than what was written.
    output wire [N_PAIRS*SEL_W-1:0]              obs_pair_x,
    output wire [N_PAIRS*SEL_W-1:0]              obs_pair_y,
    output wire [N_PAIRS-1:0]                    obs_pair_enable
);

  // ---------------------------------------------------------------------------
  // Widths
  // ---------------------------------------------------------------------------

  // The exact cross-power term: complex_multiplier's full-precision port width,
  // 33 signed bits holding |v| <= 2^31 (section 2, covar_pkg section 1).
  localparam int unsigned XP_W = int'(covar_prod_w());

  localparam int unsigned SRC_W = 2 * FXP_SAMPLE_W;

  typedef logic signed [XP_W-1:0] xp_t;

`ifndef SYNTHESIS
  initial begin
    if (N_SRC < 1)   $fatal(1, "covar_engine: N_SRC=%0d must be at least 1", N_SRC);
    if (N_PAIRS < 1) $fatal(1, "covar_engine: N_PAIRS=%0d must be at least 1", N_PAIRS);
    if (SEL_W != int'(covar_src_sel_w())) begin
      $fatal(1, "covar_engine: SEL_W=%0d disagrees with covar_pkg::covar_src_sel_w()=%0d",
             SEL_W, int'(covar_src_sel_w()));
    end
    if (N_SRC > (1 << SEL_W)) begin
      $fatal(1, "covar_engine: N_SRC=%0d cannot be addressed by a %0d-bit selector",
             N_SRC, SEL_W);
    end
  end
`endif

  // ---------------------------------------------------------------------------
  // Pair table. Latched on reset and on flush only (section 4).
  // ---------------------------------------------------------------------------
  logic [N_PAIRS-1:0][SEL_W-1:0] sel_x_q, sel_y_q;

  always_ff @(posedge clk) begin
    if (!rst_n || flush) begin
      for (int unsigned p = 0; p < N_PAIRS; p++) begin
        sel_x_q[p] <= cfg_pair_x[p*SEL_W +: SEL_W];
        sel_y_q[p] <= cfg_pair_y[p*SEL_W +: SEL_W];
      end
    end
  end

  for (genvar p = 0; p < int'(N_PAIRS); p++) begin : g_obs_sel
    assign obs_pair_x[p*SEL_W +: SEL_W] = sel_x_q[p];
    assign obs_pair_y[p*SEL_W +: SEL_W] = sel_y_q[p];
  end

  // ---------------------------------------------------------------------------
  // Per-pair datapath
  // ---------------------------------------------------------------------------
  logic [N_PAIRS-1:0]             p_valid;
  logic [N_PAIRS-1:0][ACC_W-1:0]  p_acc_re, p_acc_im;
  logic [N_PAIRS-1:0][COVAR_WINDOW_ID_W-1:0] p_wid;
  logic [N_PAIRS-1:0][WINDOW_W-1:0] p_cnt;
  logic [N_PAIRS-1:0]             p_flushed, p_trunc, p_sat;
  logic [N_PAIRS-1:0][SAT_COUNT_W-1:0] p_sat_count;
  logic [N_PAIRS-1:0]             p_en;

  for (genvar p = 0; p < int'(N_PAIRS); p++) begin : g_pair

    // ---- source mux. Out of range reads source 0 (section 4). --------------
    fxp_complex_t x_sel, y_sel;

    always_comb begin
      x_sel = fxp_complex_t'(src[0 +: SRC_W]);
      y_sel = fxp_complex_t'(src[0 +: SRC_W]);
      for (int unsigned s = 0; s < N_SRC; s++) begin
        if (32'(sel_x_q[p]) == s) x_sel = fxp_complex_t'(src[s*SRC_W +: SRC_W]);
        if (32'(sel_y_q[p]) == s) y_sel = fxp_complex_t'(src[s*SRC_W +: SRC_W]);
      end
    end

    // ---- conjugation by operand swap (section 2, equation **) --------------
    // b.re = y.im and b.im = y.re. Nothing is negated at 16 bits.
    fxp_complex_t b_swapped;
    assign b_swapped = '{re: y_sel.im, im: y_sel.re};

    wire                    xp_valid;
    wire signed [XP_W-1:0]  p_re_raw, p_im_raw;
    wire fxp16_t            y_re_unused, y_im_unused;
    wire fxp_flags_t        f_re_unused, f_im_unused;
    wire                    ovf_unused;

    complex_multiplier #(
        .VARIANT     (CMULT_VARIANT),
        .PIPE_STAGES (CMULT_PIPE_STAGES),
        .ROUND_OUT   (0)
    ) u_cmult (
        .clk       (clk),
        .rst_n     (rst_n),
        .valid_in  (valid_in),
        .a         (x_sel),
        .b         (b_swapped),
        .valid_out (xp_valid),
        .p_re      (p_re_raw),
        .p_im      (p_im_raw),
        .y_re      (y_re_unused),
        .y_im      (y_im_unused),
        .flags_re  (f_re_unused),
        .flags_im  (f_im_unused),
        .ovf       (ovf_unused)
    );

    // Equation (**). The negation is exact at XP_W bits: |p_re_raw| <= 2^31 and
    // the field holds [-2^32, 2^32-1].
    wire xp_t rxy_re = xp_t'(p_im_raw);
    wire xp_t rxy_im = xp_t'(-p_re_raw);

    // ---- integration -------------------------------------------------------
    wire fxp_flags_t sat_flags_re_unused, sat_flags_im_unused;
    wire             sat_re, sat_im;
    wire [SAT_COUNT_W-1:0] sat_cnt_re, sat_cnt_im;
    wire signed [ACC_W-1:0] obs_acc_re_unused, obs_acc_im_unused;
    wire [WINDOW_W-1:0] obs_cnt_re_unused, obs_cnt_im_unused;
    wire [WINDOW_W-1:0] obs_len_re_unused, obs_len_im_unused;
    wire obs_mode_re_unused, obs_mode_im_unused;
    wire [COVAR_EXP_K_W-1:0] obs_k_re_unused, obs_k_im_unused;
    wire obs_en_re, obs_en_im_unused;
    wire vld_re, vld_im;
    wire [COVAR_WINDOW_ID_W-1:0] wid_re, wid_im;
    wire [WINDOW_W-1:0] cnt_re, cnt_im;
    wire flushed_re, flushed_im, trunc_re, trunc_im;
    wire signed [ACC_W-1:0] acc_re_w, acc_im_w;

    integrator #(
        .DATA_W      (XP_W),
        .ACC_W       (ACC_W),
        .WINDOW_W    (WINDOW_W),
        .SAT_COUNT_W (SAT_COUNT_W)
    ) u_int_re (
        .clk            (clk),
        .rst_n          (rst_n),
        .cfg_window_len (cfg_window_len),
        .cfg_mode       (cfg_mode),
        .cfg_exp_k      (cfg_exp_k),
        .cfg_enable     (cfg_pair_enable[p]),
        .flush          (flush),
        .sat_clear      (sat_clear),
        .valid_in       (xp_valid),
        .data_in        (rxy_re),
        .valid_out      (vld_re),
        .acc_out        (acc_re_w),
        .window_id      (wid_re),
        .sample_count   (cnt_re),
        .flushed        (flushed_re),
        .truncated      (trunc_re),
        .sat_flags      (sat_flags_re_unused),
        .sat_sticky     (sat_re),
        .sat_count      (sat_cnt_re),
        .obs_acc        (obs_acc_re_unused),
        .obs_count      (obs_cnt_re_unused),
        .obs_window_len (obs_len_re_unused),
        .obs_mode       (obs_mode_re_unused),
        .obs_exp_k      (obs_k_re_unused),
        .obs_enable     (obs_en_re)
    );

    integrator #(
        .DATA_W      (XP_W),
        .ACC_W       (ACC_W),
        .WINDOW_W    (WINDOW_W),
        .SAT_COUNT_W (SAT_COUNT_W)
    ) u_int_im (
        .clk            (clk),
        .rst_n          (rst_n),
        .cfg_window_len (cfg_window_len),
        .cfg_mode       (cfg_mode),
        .cfg_exp_k      (cfg_exp_k),
        .cfg_enable     (cfg_pair_enable[p]),
        .flush          (flush),
        .sat_clear      (sat_clear),
        .valid_in       (xp_valid),
        .data_in        (rxy_im),
        .valid_out      (vld_im),
        .acc_out        (acc_im_w),
        .window_id      (wid_im),
        .sample_count   (cnt_im),
        .flushed        (flushed_im),
        .truncated      (trunc_im),
        .sat_flags      (sat_flags_im_unused),
        .sat_sticky     (sat_im),
        .sat_count      (sat_cnt_im),
        .obs_acc        (obs_acc_im_unused),
        .obs_count      (obs_cnt_im_unused),
        .obs_window_len (obs_len_im_unused),
        .obs_mode       (obs_mode_im_unused),
        .obs_exp_k      (obs_k_im_unused),
        .obs_enable     (obs_en_im_unused)
    );

    // The two halves of a pair are driven by identical control, so they close
    // and flush on the same cycle by construction; the assertion below is what
    // turns "by construction" into a checked fact.
    assign p_valid[p]     = vld_re;
    assign p_acc_re[p]    = acc_re_w;
    assign p_acc_im[p]    = acc_im_w;
    assign p_wid[p]       = wid_re;
    assign p_cnt[p]       = cnt_re;
    assign p_flushed[p]   = flushed_re;
    assign p_trunc[p]     = trunc_re;
    assign p_sat[p]       = sat_re | sat_im;
    assign p_sat_count[p] = (sat_cnt_re > sat_cnt_im) ? sat_cnt_re : sat_cnt_im;
    assign p_en[p]        = obs_en_re;

`ifndef SYNTHESIS
    always_ff @(posedge clk) begin
      if (rst_n) begin
        a_covar_halves_in_step : assert ((vld_re == vld_im) &&
                                         (wid_re == wid_im) &&
                                         (cnt_re == cnt_im) &&
                                         (flushed_re == flushed_im) &&
                                         (trunc_re == trunc_im))
          else $error("covar_engine: pair %0d real and imaginary accumulators disagree on window framing",
                      p);
      end
    end
`endif

  end

  // ---------------------------------------------------------------------------
  // Flattening
  // ---------------------------------------------------------------------------
  for (genvar p = 0; p < int'(N_PAIRS); p++) begin : g_flat
    assign pair_acc_re[p*ACC_W +: ACC_W]                           = p_acc_re[p];
    assign pair_acc_im[p*ACC_W +: ACC_W]                           = p_acc_im[p];
    assign pair_window_id[p*COVAR_WINDOW_ID_W +: COVAR_WINDOW_ID_W] = p_wid[p];
    assign pair_sample_count[p*WINDOW_W +: WINDOW_W]               = p_cnt[p];
  end

  assign pair_valid      = p_valid;
  assign pair_flushed    = p_flushed;
  assign pair_truncated  = p_trunc;
  assign pair_sat        = p_sat;
  assign sat_any         = |p_sat;
  assign obs_pair_enable = p_en;

  // Highest saturation-event count across the pairs. One number for the
  // telemetry plane; the per-pair sticky bits say WHICH pair.
  logic [SAT_COUNT_W-1:0] sat_count_max_c;

  always_comb begin
    sat_count_max_c = '0;
    for (int unsigned q = 0; q < N_PAIRS; q++) begin
      if (p_sat_count[q] > sat_count_max_c) sat_count_max_c = p_sat_count[q];
    end
  end

  assign sat_count_max = sat_count_max_c;

endmodule : covar_engine

`default_nettype wire
