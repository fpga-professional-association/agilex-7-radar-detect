// -----------------------------------------------------------------------------
// fft_bf2 — one radix-2 butterfly with delay feedback: the BF2I / BF2II
// sub-stage of a radix-2^2 SDF path (SPEC.md 7.2, issue #11).
//
// The derivation, the delay schedule and the control-bit assignment are in
// rtl/fft/fft_pkg.sv, section 2. This module is that description in hardware and
// nothing more: it computes no index arithmetic of its own and invents no
// rounding of its own.
//
// -----------------------------------------------------------------------------
// What it does, per enabled beat
// -----------------------------------------------------------------------------
// Let D = DELAY, and let `p` be the position of the arriving sample in the
// stage's own input stream (the tag on idx_in). The phase bit p[log2 D] splits
// each 2D-sample block in half:
//
//   phase 0 (p[log2 D] = 0)   the arriving sample is PUSHED into the feedback,
//                             and the feedback's output — the "late" result of
//                             the previous block — is what leaves the stage.
//   phase 1 (p[log2 D] = 1)   the arriving sample `b` meets the sample `a` that
//                             entered D beats earlier and is now at the head of
//                             the feedback. a+b leaves the stage now; a-b is
//                             pushed into the feedback and leaves D beats later.
//
// That is the whole SDF trick: one adder, one subtractor and D words of memory
// perform a radix-2 DIF stage on a serial stream, and the output stream is the
// input stream delayed by D POSITIONS — which is why idx_out is idx_in - D and
// why nothing here needs to know the latency of anything ahead of it.
//
// BF2II additionally applies the radix-2^2 decomposition's trivial twiddle:
// when the k1 bit p[log2 D + 1] is set, the arriving sample is multiplied by -j
// before the butterfly. -j*(re + j*im) = im - j*re, so it is a swap and a
// negate — no multiplier, which is exactly why a radix-2^2 path needs a real
// twiddle multiplier only once per TWO butterflies.
//
// The negate is fxp_pkg::fxp_neg_sat, not a bare minus: -(-1.0) is not
// representable in Q1.15, so that one input value saturates and says so. A
// silently wrapping negate would turn a full-scale negative sample into a
// full-scale positive one, which is indistinguishable from a real signal.
//
// -----------------------------------------------------------------------------
// Numerics (fft_pkg section 4; every quantisation is an fxp_pkg call)
// -----------------------------------------------------------------------------
// The butterfly sum of two Q1.15 values is formed at the full working width and
// quantised ONCE, by fxp_round_sat at SHIFT into FXP_SAMPLE_W. SHIFT = 1 is the
// scaled schedule and provably cannot saturate; SHIFT = 0 keeps the bit and lets
// the value saturate, with direction-resolved flags.
//
// The phase-0 path is NOT quantised: it carries a value that was already
// quantised when it was stored, D beats earlier. Both halves of the butterfly
// therefore receive exactly one shift, at the same place in the arithmetic, and
// the stage's output is Q1.15 on every beat.
//
// -----------------------------------------------------------------------------
// Warmth, and why the flags need it
// -----------------------------------------------------------------------------
// A delay-feedback stage produces meaningless output until its feedback has been
// filled, and a meaningless output can saturate. If those saturations reached
// the flag collectors, "did stage 3 overflow on this frame?" would depend on how
// long ago reset was released.
//
// `warm_in` states that the arriving sample is a real one; `warm_out` states the
// same of the departing one, and it is `warm_in` delayed by D+1 enabled beats —
// D for the feedback and one for the output register. Because warmth is
// monotone within a run, the delay is a saturating counter rather than a shift
// register. flags_valid is warm_out: the collectors in fft_core count exactly
// the saturations of real samples, from the first frame onward.
//
// Lint contract: clean under `verilator --lint-only --Wall` with no waiver.
// -----------------------------------------------------------------------------

`default_nettype none

module fft_bf2
  import fxp_pkg::*;
#(
    // Width of the position tag. The lane's transform is 2^IDX_W points, so the
    // tag wraps modulo the transform length for free.
    parameter int unsigned IDX_W    = 5,

    // Delay-feedback length in samples, a power of two, >= 1.
    parameter int unsigned DELAY    = 16,

    // 0: BF2I (plain radix-2 butterfly). 1: BF2II (adds the trivial -j).
    parameter int unsigned IS_BF2II = 0,

    // Right shift applied to both butterfly outputs, 0 or 1.
    parameter int unsigned SHIFT    = 1,

    // Delay-feedback memory placement; see fft_delay_line.
    parameter string       MEM_STYLE = "AUTO"
) (
    input  wire                clk,
    input  wire                rst_n,

    // `en` IS the beat-present signal of the stage's input stream: one enabled
    // cycle is one sample position, and a cycle without a beat must not advance
    // the feedback. The FFT core is valid-tagged and gap-tolerant rather than
    // globally stallable — see the header of rtl/fft/streaming_fft.sv — so this
    // is a per-stage enable driven by a local, pipelined valid, not a fan-out of
    // one chip-wide clock enable (SPEC 23).
    input  wire                en,

    input  wire fxp_complex_t  din,
    input  wire [IDX_W-1:0]    idx_in,
    input  wire                warm_in,

    output wire fxp_complex_t  dout,
    output wire [IDX_W-1:0]    idx_out,
    output wire                warm_out,

    // `en` delayed by the stage's one register: the beat-present signal of the
    // output stream. The only reset state in the datapath (SPEC 23).
    output wire                vld_out,

    // Saturation of this beat's quantisations, qualified by flags_valid.
    output wire fxp_flags_t    flags,
    output wire                flags_valid
);

  // ---------------------------------------------------------------------------
  // Geometry
  // ---------------------------------------------------------------------------

  // Bit of the position that selects the phase. $clog2(1) = 0, so a DELAY = 1
  // stage alternates on the position's least significant bit, which is right.
  localparam int unsigned LG = $clog2(DELAY);

  // Bit of the position that carries k1 for BF2II. Forced to 0 for BF2I, where
  // it is unused: for the first sub-stage of a path LG+1 is one past the top of
  // the tag, and an out-of-range select is an error even in a branch that never
  // uses the value.
  localparam int unsigned K1_BIT = (IS_BF2II != 0) ? (LG + 1) : 0;

  // Exact width of a two-term Q1.15 sum, from fxp_pkg's own accumulator policy.
  // Not a datapath width — the arithmetic below is done at the package's working
  // width — but the bound the simulation-only assertion checks.
  localparam int unsigned SUM_W = 17;

  localparam int unsigned WARM_TARGET = DELAY + 1;
  localparam int unsigned WARM_CNT_W  = $clog2(WARM_TARGET + 1);

`ifndef SYNTHESIS
  initial begin
    if (DELAY < 1 || ((DELAY & (DELAY - 1)) != 0)) begin
      $fatal(1, "fft_bf2: DELAY=%0d is not a power of two >= 1", DELAY);
    end
    if (SHIFT > 1) begin
      $fatal(1, "fft_bf2: SHIFT=%0d is not 0 or 1", SHIFT);
    end
    if (IS_BF2II > 1) begin
      $fatal(1, "fft_bf2: IS_BF2II=%0d is not 0 or 1", IS_BF2II);
    end
    if (LG >= IDX_W) begin
      $fatal(1, "fft_bf2: DELAY=%0d needs position bit %0d but the tag is %0d bits",
             DELAY, LG, IDX_W);
    end
    if ((IS_BF2II != 0) && (K1_BIT >= IDX_W)) begin
      $fatal(1, "fft_bf2: BF2II with DELAY=%0d needs position bit %0d but the tag is %0d bits",
             DELAY, K1_BIT, IDX_W);
    end
    if (SUM_W != fxp_acc_w(FXP_SAMPLE_W, uint_t'(2))) begin
      $fatal(1, "fft_bf2: SUM_W=%0d but fxp_acc_w(%0d, 2)=%0d",
             SUM_W, FXP_SAMPLE_W, fxp_acc_w(FXP_SAMPLE_W, uint_t'(2)));
    end
  end
`endif

  // ---------------------------------------------------------------------------
  // Control, straight off the position tag
  // ---------------------------------------------------------------------------
  logic phase;   // 0: push the arriving sample. 1: butterfly.
  logic k1;      // BF2II trivial-twiddle select.

  assign phase = idx_in[LG];
  assign k1    = (IS_BF2II != 0) ? idx_in[K1_BIT] : 1'b0;

  // ---------------------------------------------------------------------------
  // Trivial twiddle: b := -j*b when BF2II and k1
  // ---------------------------------------------------------------------------
  fxp_complex_t b_op;
  fxp_flags_t   negj_flags;

  always_comb begin
    if (k1) begin
      // -j*(re + j*im) = im - j*re
      b_op.re    = din.im;
      b_op.im    = fxp16_t'(fxp_neg_sat(fxp_wide_t'(din.re), FXP_SAMPLE_W));
      negj_flags = fxp_sat_flags(-fxp_wide_t'(din.re), FXP_SAMPLE_W);
    end else begin
      b_op       = din;
      negj_flags = fxp_flags_none();
    end
  end

  // ---------------------------------------------------------------------------
  // Delay feedback
  // ---------------------------------------------------------------------------
  fxp_complex_t dly_out, dly_in;

  fft_delay_line #(
      .WIDTH ($bits(fxp_complex_t)),
      .DEPTH (DELAY),
      .STYLE (MEM_STYLE)
  ) u_dly (
      .clk   (clk),
      .rst_n (rst_n),
      .en    (en),
      .d     (dly_in),
      .q     (dly_out)
  );

  // ---------------------------------------------------------------------------
  // Butterfly and its single quantisation
  // ---------------------------------------------------------------------------
  fxp_wide_t sum_re, sum_im, dif_re, dif_im;

  assign sum_re = fxp_wide_t'(dly_out.re) + fxp_wide_t'(b_op.re);
  assign sum_im = fxp_wide_t'(dly_out.im) + fxp_wide_t'(b_op.im);
  assign dif_re = fxp_wide_t'(dly_out.re) - fxp_wide_t'(b_op.re);
  assign dif_im = fxp_wide_t'(dly_out.im) - fxp_wide_t'(b_op.im);

  fxp_complex_t sum_q, dif_q;
  fxp_flags_t   sum_flags, dif_flags;

  always_comb begin
    sum_q.re = fxp16_t'(fxp_round_sat(sum_re, uint_t'(SHIFT), FXP_SAMPLE_W));
    sum_q.im = fxp16_t'(fxp_round_sat(sum_im, uint_t'(SHIFT), FXP_SAMPLE_W));
    dif_q.re = fxp16_t'(fxp_round_sat(dif_re, uint_t'(SHIFT), FXP_SAMPLE_W));
    dif_q.im = fxp16_t'(fxp_round_sat(dif_im, uint_t'(SHIFT), FXP_SAMPLE_W));

    // Flags describe the value being clamped — after the round, before the
    // saturate. Same order, for the same reason, as complex_multiplier.
    sum_flags = fxp_flags_merge(
        fxp_sat_flags(fxp_round(sum_re, uint_t'(SHIFT)), FXP_SAMPLE_W),
        fxp_sat_flags(fxp_round(sum_im, uint_t'(SHIFT)), FXP_SAMPLE_W));
    dif_flags = fxp_flags_merge(
        fxp_sat_flags(fxp_round(dif_re, uint_t'(SHIFT)), FXP_SAMPLE_W),
        fxp_sat_flags(fxp_round(dif_im, uint_t'(SHIFT)), FXP_SAMPLE_W));
  end

  fxp_complex_t y_c;
  fxp_flags_t   flags_c;

  always_comb begin
    if (phase) begin
      y_c     = sum_q;
      dly_in  = dif_q;
      flags_c = fxp_flags_merge(negj_flags,
                                fxp_flags_merge(sum_flags, dif_flags));
    end else begin
      y_c     = dly_out;   // already quantised, D beats ago
      dly_in  = din;
      flags_c = fxp_flags_none();
    end
  end

  // ---------------------------------------------------------------------------
  // Output registers. Free-running under `en`; only the control state resets.
  // ---------------------------------------------------------------------------
  fxp_complex_t     dout_q;
  logic [IDX_W-1:0] idx_q;
  fxp_flags_t       flags_q;

  always_ff @(posedge clk) begin
    if (en) begin
      dout_q  <= y_c;
      idx_q   <= idx_in - IDX_W'(DELAY);   // wraps modulo the transform length
      flags_q <= flags_c;
    end
  end

  // ---------------------------------------------------------------------------
  // Warmth
  // ---------------------------------------------------------------------------
  logic [WARM_CNT_W-1:0] warm_cnt_q;
  logic                  vld_q;

  always_ff @(posedge clk) begin
    if (!rst_n) begin
      warm_cnt_q <= '0;
      vld_q      <= 1'b0;
    end else begin
      vld_q <= en;
      if (en && warm_in && (warm_cnt_q != WARM_CNT_W'(WARM_TARGET))) begin
        warm_cnt_q <= warm_cnt_q + WARM_CNT_W'(1);
      end
    end
  end

  assign vld_out     = vld_q;
  assign dout        = dout_q;
  assign idx_out     = idx_q;
  assign warm_out    = (warm_cnt_q == WARM_CNT_W'(WARM_TARGET));
  assign flags       = flags_q;
  // A saturation is counted once, for a beat that is both present and real.
  assign flags_valid = vld_q && (warm_cnt_q == WARM_CNT_W'(WARM_TARGET));

  // ---------------------------------------------------------------------------
  // Simulation-only proofs
  //
  //  * the exact butterfly sums fit the width fxp_pkg's growth rule predicts,
  //    so "17 bits" is a checked fact rather than an argument in a comment;
  //  * the scaled schedule's headroom claim, stated PRECISELY. The comfortable
  //    version of that claim — "one place of right shift cannot overflow" — is
  //    false, and this assertion is what found it: a - b reaches 2^16 - 1 at
  //    a = +0.99997, b = -1.0, and rne(65535/2) = 32768 is one LSB past the top
  //    of Q1.15. What IS true, and what is checked here on every beat, is that a
  //    scaled butterfly can only ever exceed the range by that single LSB, and
  //    only upward. See fft_pkg section 4.
  // ---------------------------------------------------------------------------
`ifndef SYNTHESIS
  fxp_wide_t r_sum_re, r_sum_im, r_dif_re, r_dif_im;
  assign r_sum_re = fxp_round(sum_re, uint_t'(SHIFT));
  assign r_sum_im = fxp_round(sum_im, uint_t'(SHIFT));
  assign r_dif_re = fxp_round(dif_re, uint_t'(SHIFT));
  assign r_dif_im = fxp_round(dif_im, uint_t'(SHIFT));

  always_ff @(posedge clk) begin
    if (rst_n && en && warm_out) begin
      a_fft_bf2_sum_width : assert (
          (sum_re <= fxp_max_of(uint_t'(SUM_W))) &&
          (sum_re >= fxp_min_of(uint_t'(SUM_W))) &&
          (sum_im <= fxp_max_of(uint_t'(SUM_W))) &&
          (sum_im >= fxp_min_of(uint_t'(SUM_W))) &&
          (dif_re <= fxp_max_of(uint_t'(SUM_W))) &&
          (dif_re >= fxp_min_of(uint_t'(SUM_W))) &&
          (dif_im <= fxp_max_of(uint_t'(SUM_W))) &&
          (dif_im >= fxp_min_of(uint_t'(SUM_W))))
        else $error("fft_bf2: butterfly sums (%0d,%0d)/(%0d,%0d) do not fit %0d bits",
                    sum_re, sum_im, dif_re, dif_im, SUM_W);
      // The scaling policy's claim, stated so that it is true.
      //
      // Gated by `phase`: in the push phase the butterfly's outputs are not used
      // at all, so their flags are not the stage's and must not be checked. The
      // claim is also NOT about the trivial twiddle: -j negates a component, and
      // -(-1.0) is not representable in Q1.15, so a sample of exactly -32768
      // saturates in BF2II whatever the schedule says. That is a real, modelled
      // event — the C++ model merges the same flag — and the two assertions
      // below are written against the butterfly's own quantisation only, so they
      // leave it visible rather than hiding it.
      if ((SHIFT == 1) && phase) begin
        a_fft_bf2_scaled_never_underflows : assert (
            !sum_flags.sat_neg && !dif_flags.sat_neg)
          else $error("fft_bf2: a scaled butterfly saturated NEGATIVE, which cannot happen: rne(-2^16/2) = -2^15 fits");
        a_fft_bf2_scaled_over_by_one_lsb : assert (
            (r_sum_re <= fxp_max_of(FXP_SAMPLE_W) + 64'sd1) &&
            (r_sum_im <= fxp_max_of(FXP_SAMPLE_W) + 64'sd1) &&
            (r_dif_re <= fxp_max_of(FXP_SAMPLE_W) + 64'sd1) &&
            (r_dif_im <= fxp_max_of(FXP_SAMPLE_W) + 64'sd1))
          else $error("fft_bf2: a scaled butterfly rounded to (%0d,%0d)/(%0d,%0d), more than one LSB past Q1.15",
                      r_sum_re, r_sum_im, r_dif_re, r_dif_im);
      end
    end
  end
`endif

endmodule : fft_bf2

`default_nettype wire
