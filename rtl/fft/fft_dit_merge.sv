// -----------------------------------------------------------------------------
// fft_dit_merge — one decimation-in-time merge level: the step that turns two
// half-length transforms, computed on separate lanes, back into one.
//
// This is where the SAMPLES_PER_CYCLE parallelism of the design lives. The
// derivation is in fft_pkg section 1; in one line, for P = 2:
//
//     X[m]       = E[m] + W_N^m O[m]
//     X[m + N/2] = E[m] - W_N^m O[m]        m = bitrev(j), j the output beat
//
// with E and O the M-point transforms of the even and odd subsequences, which
// the two fft_sdf_path instances deliver in bit-reversed order — so beat j
// carries E[m] and O[m] for the SAME m, and the merge is one complex multiply
// and one radix-2 butterfly per beat, with no memory at all.
//
// That is the whole reason the parallelism is bought this way. A P-parallel
// delay-COMMUTATOR architecture would carry the same total delay memory but
// would put a commutator network between every pair of stages and make each
// stage's control a function of P; here P changes how many identical lanes exist
// and how many of these levels sit behind them, and changes nothing inside a
// lane.
//
// LEVEL exists for the P > 2 generalisation (issue #20): level L merges
// sub-transforms of length M*2^L using powers of W_{M*2^(L+1)}, and fft_pkg's
// fft_dit_tw() takes the level as an argument for exactly that reason. Only
// level 0 is verified by issue #11, and fft_pkg::fft_spc_supported() is what
// keeps an unverified level from elaborating.
//
// -----------------------------------------------------------------------------
// Alignment and numerics
// -----------------------------------------------------------------------------
// Same two-part delay as fft_radix22_stage, for the same reason: the ROM and its
// alignment chain advance on beats, the multiplier and the chain that matches it
// advance on cycles, and each parallel path uses one style throughout. The `E`
// operand travels the full ROM_LAT + TW_PIPE so that it meets W*O at the adder.
//
// The butterfly is quantised exactly as fft_bf2 quantises its own: the sum is
// formed at the working width and fxp_round_sat is applied ONCE, at the
// schedule's shift for this stage, with direction-resolved flags taken after the
// round and before the saturate.
//
// Lint contract: clean under `verilator --lint-only --Wall` with no waiver.
// -----------------------------------------------------------------------------

`default_nettype none

module fft_dit_merge
  import fxp_pkg::*;
  import fft_pkg::*;
#(
    // log2 of a lane's transform length. The beat index is N_LANE bits.
    parameter int unsigned N_LANE = 5,

    // Merge level. 0 is the only value issue #11 verifies.
    parameter int unsigned LEVEL  = 0,

    // Right shift applied to both butterfly outputs, 0 or 1.
    parameter int unsigned SHIFT  = 1,

    parameter string       TW_VARIANT     = "MULT4",
    parameter int unsigned TW_PIPE        = 4,
    parameter int unsigned TW_ROM_OUT_REG = 1,
    parameter string       TW_STYLE       = "AUTO"
) (
    input  wire                clk,
    input  wire                rst_n,

    input  wire                vld_in,
    input  wire fxp_complex_t  e_in,     // lane holding the even subsequence
    input  wire fxp_complex_t  o_in,     // lane holding the odd subsequence
    input  wire [N_LANE-1:0]   idx_in,
    input  wire                warm_in,

    output wire                vld_out,
    output wire fxp_complex_t  y_lo,     // X[m]
    output wire fxp_complex_t  y_hi,     // X[m + N/2]
    output wire [N_LANE-1:0]   idx_out,
    output wire                warm_out,

    output wire fxp_flags_t    flags_bf,
    output wire                flags_bf_valid,
    output wire fxp_flags_t    flags_tw,
    output wire                flags_tw_valid
);

  localparam int unsigned CPLX_W  = $bits(fxp_complex_t);
  localparam int unsigned ROM_LAT = 1 + TW_ROM_OUT_REG;
  localparam int unsigned ALIGN_W = N_LANE + 2 * CPLX_W;   // {idx, e, o}
  localparam int unsigned TAG_W   = N_LANE + CPLX_W;       // {idx, e}

`ifndef SYNTHESIS
  initial begin
    if (SHIFT > 1) $fatal(1, "fft_dit_merge: SHIFT=%0d is not 0 or 1", SHIFT);
  end
`endif

  // ---------------------------------------------------------------------------
  // Coefficient
  // ---------------------------------------------------------------------------
  fxp_complex_t tw;

  fft_twiddle_rom #(
      .KIND    ("DIT"),
      .ADDR_W  (N_LANE),
      .N_LANE  (N_LANE),
      .LEVEL   (LEVEL),
      .OUT_REG (TW_ROM_OUT_REG),
      .STYLE   (TW_STYLE)
  ) u_rom (
      .clk  (clk),
      .en   (vld_in),
      .addr (idx_in),
      .tw   (tw)
  );

  // ---------------------------------------------------------------------------
  // Beat-enabled alignment to the ROM
  // ---------------------------------------------------------------------------
  // WARMTH IS RESET, THE DATAPATH IS NOT (SPEC 23) — the same split, for the
  // same reason, as fft_radix22_stage's alignment chain: an unreset warm bit
  // comes out of reset as X and a spurious 1 would mark the delay feedbacks'
  // fill as real data.
  logic [ROM_LAT:0][ALIGN_W-1:0] align_ch;
  logic [ROM_LAT:0]              warm_align_ch;
  assign align_ch[0]      = {idx_in, CPLX_W'(e_in), CPLX_W'(o_in)};
  assign warm_align_ch[0] = warm_in;

  for (genvar i = 0; i < ROM_LAT; i++) begin : g_align
    logic [ALIGN_W-1:0] r_q;
    logic               w_q;
    always_ff @(posedge clk) begin
      if (vld_in) r_q <= align_ch[i];
    end
    always_ff @(posedge clk) begin
      if (!rst_n)      w_q <= 1'b0;
      else if (vld_in) w_q <= warm_align_ch[i];
    end
    assign align_ch[i+1]      = r_q;
    assign warm_align_ch[i+1] = w_q;
  end

  logic              al_warm;
  logic [N_LANE-1:0] al_idx;
  logic [CPLX_W-1:0] al_e, al_o;
  assign {al_idx, al_e, al_o} = align_ch[ROM_LAT];
  assign al_warm              = warm_align_ch[ROM_LAT];

  // ---------------------------------------------------------------------------
  // W * O
  // ---------------------------------------------------------------------------
  logic       mul_vld;
  fxp16_t     mul_y_re, mul_y_im;
  fxp_flags_t mul_f_re, mul_f_im;
  logic       mul_ovf;
  logic signed [FXP_PROD_W:0] mul_p_re, mul_p_im;

  complex_multiplier #(
      .VARIANT     (TW_VARIANT),
      .PIPE_STAGES (TW_PIPE),
      .ROUND_OUT   (1)
  ) u_mul (
      .clk       (clk),
      .rst_n     (rst_n),
      .valid_in  (vld_in),
      .a         (fxp_complex_t'(al_o)),
      .b         (tw),
      .valid_out (mul_vld),
      .p_re      (mul_p_re),
      .p_im      (mul_p_im),
      .y_re      (mul_y_re),
      .y_im      (mul_y_im),
      .flags_re  (mul_f_re),
      .flags_im  (mul_f_im),
      .ovf       (mul_ovf)
  );

  // ---------------------------------------------------------------------------
  // E, and the tag, through a matching free-running chain
  // ---------------------------------------------------------------------------
  logic [TW_PIPE:0][TAG_W-1:0] tag_ch;
  logic [TW_PIPE:0]            warm_tag_ch;
  assign tag_ch[0]      = {al_idx, al_e};
  assign warm_tag_ch[0] = al_warm;

  for (genvar i = 0; i < TW_PIPE; i++) begin : g_tag
    logic [TAG_W-1:0] r_q;
    logic             w_q;
    always_ff @(posedge clk) begin
      r_q <= tag_ch[i];
    end
    always_ff @(posedge clk) begin
      if (!rst_n) w_q <= 1'b0;
      else        w_q <= warm_tag_ch[i];
    end
    assign tag_ch[i+1]      = r_q;
    assign warm_tag_ch[i+1] = w_q;
  end

  logic              bf_warm;
  logic [N_LANE-1:0] bf_idx;
  logic [CPLX_W-1:0] bf_e;
  assign {bf_idx, bf_e} = tag_ch[TW_PIPE];
  assign bf_warm        = warm_tag_ch[TW_PIPE];

  // ---------------------------------------------------------------------------
  // Radix-2 butterfly and its single quantisation
  // ---------------------------------------------------------------------------
  fxp_complex_t e_op, t_op;
  assign e_op = fxp_complex_t'(bf_e);
  assign t_op = '{re: mul_y_re, im: mul_y_im};

  fxp_wide_t sum_re, sum_im, dif_re, dif_im;
  assign sum_re = fxp_wide_t'(e_op.re) + fxp_wide_t'(t_op.re);
  assign sum_im = fxp_wide_t'(e_op.im) + fxp_wide_t'(t_op.im);
  assign dif_re = fxp_wide_t'(e_op.re) - fxp_wide_t'(t_op.re);
  assign dif_im = fxp_wide_t'(e_op.im) - fxp_wide_t'(t_op.im);

  fxp_complex_t lo_c, hi_c;
  fxp_flags_t   bf_flags_c;

  always_comb begin
    lo_c.re = fxp16_t'(fxp_round_sat(sum_re, fft_uint_t'(SHIFT), FXP_SAMPLE_W));
    lo_c.im = fxp16_t'(fxp_round_sat(sum_im, fft_uint_t'(SHIFT), FXP_SAMPLE_W));
    hi_c.re = fxp16_t'(fxp_round_sat(dif_re, fft_uint_t'(SHIFT), FXP_SAMPLE_W));
    hi_c.im = fxp16_t'(fxp_round_sat(dif_im, fft_uint_t'(SHIFT), FXP_SAMPLE_W));

    bf_flags_c = fxp_flags_merge(
        fxp_flags_merge(
            fxp_sat_flags(fxp_round(sum_re, fft_uint_t'(SHIFT)), FXP_SAMPLE_W),
            fxp_sat_flags(fxp_round(sum_im, fft_uint_t'(SHIFT)), FXP_SAMPLE_W)),
        fxp_flags_merge(
            fxp_sat_flags(fxp_round(dif_re, fft_uint_t'(SHIFT)), FXP_SAMPLE_W),
            fxp_sat_flags(fxp_round(dif_im, fft_uint_t'(SHIFT)), FXP_SAMPLE_W)));
  end

  // ---------------------------------------------------------------------------
  // Output registers
  // ---------------------------------------------------------------------------
  fxp_complex_t      lo_q, hi_q;
  logic [N_LANE-1:0] idx_q;
  logic              warm_q, vld_q;
  fxp_flags_t        flags_q;

  always_ff @(posedge clk) begin
    lo_q    <= lo_c;
    hi_q    <= hi_c;
    idx_q   <= bf_idx;
    flags_q <= bf_flags_c;
  end

  always_ff @(posedge clk) begin
    if (!rst_n) begin
      vld_q  <= 1'b0;
      warm_q <= 1'b0;
    end else begin
      vld_q  <= mul_vld;
      warm_q <= bf_warm;
    end
  end

  assign vld_out        = vld_q;
  assign y_lo           = lo_q;
  assign y_hi           = hi_q;
  assign idx_out        = idx_q;
  assign warm_out       = warm_q;
  assign flags_bf       = flags_q;
  assign flags_bf_valid = vld_q && warm_q;
  assign flags_tw       = fxp_flags_merge(mul_f_re, mul_f_im);
  assign flags_tw_valid = mul_vld && bf_warm;

  // ---------------------------------------------------------------------------
  // Simulation-only proofs, the same two fft_radix22_stage makes about its own
  // multiplier: the rounded port is fxp_pkg's quantisation of the exact one, and
  // the overflow summary agrees with the component flags.
  // ---------------------------------------------------------------------------
`ifndef SYNTHESIS
  always_ff @(posedge clk) begin
    if (rst_n && mul_vld) begin
      a_fft_merge_round_matches_pkg : assert (
          (mul_y_re == fxp16_t'(fxp_round_sat(fxp_wide_t'(mul_p_re),
                                              FXP_PROD_SHIFT, FXP_SAMPLE_W))) &&
          (mul_y_im == fxp16_t'(fxp_round_sat(fxp_wide_t'(mul_p_im),
                                              FXP_PROD_SHIFT, FXP_SAMPLE_W))))
        else $error("fft_dit_merge: multiply rounded (%0d,%0d), fxp_pkg says (%0d,%0d)",
                    mul_y_re, mul_y_im,
                    fxp_round_sat(fxp_wide_t'(mul_p_re), FXP_PROD_SHIFT, FXP_SAMPLE_W),
                    fxp_round_sat(fxp_wide_t'(mul_p_im), FXP_PROD_SHIFT, FXP_SAMPLE_W));
      a_fft_merge_ovf_consistent : assert (mul_ovf ==
          (fxp_flags_any(mul_f_re) || fxp_flags_any(mul_f_im)))
        else $error("fft_dit_merge: multiply ovf disagrees with its flags");
    end
    if (rst_n && vld_q && warm_q && (SHIFT == 1)) begin
      a_fft_merge_scaled_no_sat : assert (!fxp_flags_any(flags_q))
        else $error("fft_dit_merge: SHIFT=1 saturated, which the scaling policy says is impossible");
    end
  end
`endif

endmodule : fft_dit_merge

`default_nettype wire
