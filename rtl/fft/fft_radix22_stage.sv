// -----------------------------------------------------------------------------
// fft_radix22_stage — one complete radix-2^2 SDF stage: BF2I, BF2II and the
// twiddle multiplier that completes the group (SPEC.md 7.2, issue #11).
//
//     din --> [ BF2I  D=L/2 ] --> [ BF2II D=L/4 ] --> [ x W_L^{n3(k1+2k2)} ] --> dout
//              plain butterfly     butterfly + (-j)     ROM + complex_multiplier
//
// The two butterflies are fft_bf2 instances differing only in DELAY, in the
// trivial-twiddle flag and in their entry of the scaling schedule. The twiddle
// multiplier is rtl/common/complex_multiplier.sv — the SPEC 6 kernel verified
// and calibrated by issue #9 — fed from an fft_twiddle_rom addressed by the
// sample's own position tag.
//
// The stage is the unit the SPEC 18 calibration measures
// (quartus/calibration/fft_stage_calib.qsf): it is the smallest piece of the FFT
// that contains all four cost classes at once — delay-feedback memory, a twiddle
// ROM, a DSP-mapped complex multiply and the fixed-point quantisation network.
//
// -----------------------------------------------------------------------------
// Alignment: why half of this module is delay
// -----------------------------------------------------------------------------
// The coefficient comes out of a memory ROM_LATENCY beats after its address goes
// in, and the address is the sample's own position, so the SAMPLE has to wait
// the same ROM_LATENCY beats to meet its coefficient at the multiplier's inputs.
// That alignment chain is enabled by the same beat-valid that enables the ROM,
// because "delayed by N beats" and "delayed by N cycles" are different things in
// a gap-tolerant pipeline and only the first one is correct here.
//
// Past the multiplier the opposite holds: complex_multiplier's datapath is
// deliberately free-running with no clock enable (its own header explains why —
// a ready on those registers would undo the HyperFlex properties the issue #9
// calibration measured). A free-running register still delays the BEAT SEQUENCE
// by exactly one beat, because each beat occupies it for exactly one cycle, so
// the position tag rides through a matching free-running chain and the
// multiplier's own valid pipeline carries the beat-present signal. Mixing the
// two delay styles is safe precisely as long as each parallel path uses the SAME
// style, which is what the two chains below are.
//
// -----------------------------------------------------------------------------
// Flags
// -----------------------------------------------------------------------------
// Three quantisation sites, three (flags, valid) pairs, reported separately
// rather than merged: they live at different depths in the pipeline, so one
// merged pair would need one of them to be delayed to meet the others, and a
// saturation event would be attributed to the wrong beat. fft_core owns the
// sticky collectors and folds the sites into per-stage flags there.
//
// Lint contract: clean under `verilator --lint-only --Wall` with no waiver.
// -----------------------------------------------------------------------------

`default_nettype none

module fft_radix22_stage
  import fxp_pkg::*;
  import fft_pkg::*;
#(
    // Position-tag width; the lane transform is 2^IDX_W points.
    parameter int unsigned IDX_W       = 5,

    // Sub-stages in this lane (n) and the index of this group's BF2I (even).
    parameter int unsigned N_LANE      = 5,
    parameter int unsigned S           = 0,

    // Scaling schedule bits for the two butterflies.
    parameter int unsigned SHIFT_A     = 1,
    parameter int unsigned SHIFT_B     = 1,

    // 1: this group ends with a non-trivial twiddle multiplier. The last group
    // of a path has none — all its twiddles are W^0.
    parameter int unsigned HAS_TWIDDLE = 1,

    // complex_multiplier configuration. The defaults are what issue #9 measured:
    // MULT4 at four register stages clears the 600 MHz calibration probe.
    parameter string       TW_VARIANT  = "MULT4",
    parameter int unsigned TW_PIPE     = 4,

    // Twiddle ROM output register (see fft_twiddle_rom).
    parameter int unsigned TW_ROM_OUT_REG = 1,

    // SPEC 18 memory-geometry axes. "DEFAULT" is the project rule measured
    // by the issue #11 sweep (fft_pkg, "Delay-feedback placement"); "AUTO",
    // "M20K", "MLAB" and "LOGIC" are passed through verbatim.
    parameter string       MEM_STYLE   = "DEFAULT",
    parameter string       TW_STYLE    = "AUTO"
) (
    input  wire                clk,
    input  wire                rst_n,

    input  wire                vld_in,
    input  wire fxp_complex_t  din,
    input  wire [IDX_W-1:0]    idx_in,
    input  wire                warm_in,

    output wire                vld_out,
    output wire fxp_complex_t  dout,
    output wire [IDX_W-1:0]    idx_out,
    output wire                warm_out,

    // Per-site saturation reporting; see the note above.
    output wire fxp_flags_t    flags_a,
    output wire                flags_a_valid,
    output wire fxp_flags_t    flags_b,
    output wire                flags_b_valid,
    output wire fxp_flags_t    flags_tw,
    output wire                flags_tw_valid
);

  // ---------------------------------------------------------------------------
  // Geometry, all of it from fft_pkg
  // ---------------------------------------------------------------------------
  localparam int unsigned DELAY_A = int'(fft_bf_delay(fft_uint_t'(N_LANE), fft_uint_t'(S)));
  localparam int unsigned DELAY_B = int'(fft_bf_delay(fft_uint_t'(N_LANE), fft_uint_t'(S) + 32'd1));

  // log2 of this group's sub-transform length L. The twiddle ROM has L entries
  // and is addressed by the low log2(L) bits of the position.
  localparam int unsigned L2L     = int'(fft_group_l2l(fft_uint_t'(N_LANE), fft_uint_t'(S) + 32'd1));

  localparam int unsigned ROM_LAT = 1 + TW_ROM_OUT_REG;

  // Each feedback resolves its own placement: the two lines of a group differ
  // by a factor of two in depth, and the project rule is a function of depth.
  localparam string MEM_STYLE_A =
      fft_resolve_mem_style(MEM_STYLE, fft_uint_t'(DELAY_A));
  localparam string MEM_STYLE_B =
      fft_resolve_mem_style(MEM_STYLE, fft_uint_t'(DELAY_B));
  localparam int unsigned CPLX_W  = $bits(fxp_complex_t);

  // {idx, data} through the enabled alignment chain; {idx} through the
  // free-running chain that matches the multiplier. Warmth travels beside both
  // in its own reset-gated chain; see the note at the alignment chain.
  localparam int unsigned ALIGN_W = IDX_W + CPLX_W;
  localparam int unsigned TAG_W   = IDX_W;

`ifndef SYNTHESIS
  initial begin
    if ((S % 2) != 0) begin
      $fatal(1, "fft_radix22_stage: S=%0d must be the EVEN sub-stage index of the group", S);
    end
    if ((S + 1) >= N_LANE) begin
      $fatal(1, "fft_radix22_stage: group (%0d,%0d) does not fit a %0d-sub-stage lane",
             S, S + 1, N_LANE);
    end
    if (IDX_W != N_LANE) begin
      $fatal(1, "fft_radix22_stage: IDX_W=%0d must equal N_LANE=%0d", IDX_W, N_LANE);
    end
    if ((HAS_TWIDDLE != 0) !=
        fft_stage_has_twiddle(fft_uint_t'(N_LANE), fft_uint_t'(S) + 32'd1)) begin
      $fatal(1, "fft_radix22_stage: HAS_TWIDDLE=%0d contradicts fft_pkg for n=%0d s=%0d",
             HAS_TWIDDLE, N_LANE, S + 1);
    end
    if (L2L > IDX_W) begin
      $fatal(1, "fft_radix22_stage: twiddle ROM needs %0d address bits, the tag is %0d",
             L2L, IDX_W);
    end
  end
`endif

  // ---------------------------------------------------------------------------
  // BF2I — plain radix-2 butterfly, delay L/2
  // ---------------------------------------------------------------------------
  logic             a_vld;
  fxp_complex_t     a_data;
  logic [IDX_W-1:0] a_idx;
  logic             a_warm;

  fft_bf2 #(
      .IDX_W     (IDX_W),
      .DELAY     (DELAY_A),
      .IS_BF2II  (0),
      .SHIFT     (SHIFT_A),
      .MEM_STYLE (MEM_STYLE_A)
  ) u_bf2i (
      .clk         (clk),
      .rst_n       (rst_n),
      .en          (vld_in),
      .din         (din),
      .idx_in      (idx_in),
      .warm_in     (warm_in),
      .dout        (a_data),
      .idx_out     (a_idx),
      .warm_out    (a_warm),
      .vld_out     (a_vld),
      .flags       (flags_a),
      .flags_valid (flags_a_valid)
  );

  // ---------------------------------------------------------------------------
  // BF2II — the same butterfly with the trivial -j, delay L/4
  // ---------------------------------------------------------------------------
  logic             b_vld;
  fxp_complex_t     b_data;
  logic [IDX_W-1:0] b_idx;
  logic             b_warm;

  fft_bf2 #(
      .IDX_W     (IDX_W),
      .DELAY     (DELAY_B),
      .IS_BF2II  (1),
      .SHIFT     (SHIFT_B),
      .MEM_STYLE (MEM_STYLE_B)
  ) u_bf2ii (
      .clk         (clk),
      .rst_n       (rst_n),
      .en          (a_vld),
      .din         (a_data),
      .idx_in      (a_idx),
      .warm_in     (a_warm),
      .dout        (b_data),
      .idx_out     (b_idx),
      .warm_out    (b_warm),
      .vld_out     (b_vld),
      .flags       (flags_b),
      .flags_valid (flags_b_valid)
  );

  // ---------------------------------------------------------------------------
  // Twiddle multiplier
  // ---------------------------------------------------------------------------
  if (HAS_TWIDDLE != 0) begin : g_twiddle

    // ---- coefficient -------------------------------------------------------
    fxp_complex_t tw;

    fft_twiddle_rom #(
        .KIND    ("R22"),
        .ADDR_W  (L2L),
        .L2L     (L2L),
        .OUT_REG (TW_ROM_OUT_REG),
        .STYLE   (TW_STYLE)
    ) u_rom (
        .clk  (clk),
        .en   (b_vld),
        .addr (b_idx[L2L-1:0]),
        .tw   (tw)
    );

    // ---- beat-enabled alignment chain, ROM_LAT deep ------------------------
    // Packed 2-D and continuous assignment per element, so every bit has exactly
    // one driver (the arrangement complex_multiplier uses for its shadow chain).
    //
    // WARMTH IS RESET, THE DATAPATH IS NOT (SPEC 23). The sample and its
    // position tag are don't-care until warmth says otherwise, so their
    // registers carry no reset — resetting them would be a reset fanout across
    // the whole FFT for no functional gain. Warmth itself is a control bit and
    // MUST start at zero: an unreset warm bit comes out of reset as X, which
    // under Verilator's --x-initial unique is a coin flip, and a spurious 1
    // would mark the delay feedbacks' fill as real data.
    logic [ROM_LAT:0][ALIGN_W-1:0] align_ch;
    logic [ROM_LAT:0]              warm_align_ch;
    assign align_ch[0]      = {b_idx, b_data};
    assign warm_align_ch[0] = b_warm;

    for (genvar i = 0; i < ROM_LAT; i++) begin : g_align
      logic [ALIGN_W-1:0] r_q;
      logic               w_q;
      always_ff @(posedge clk) begin
        if (b_vld) r_q <= align_ch[i];
      end
      always_ff @(posedge clk) begin
        if (!rst_n)     w_q <= 1'b0;
        else if (b_vld) w_q <= warm_align_ch[i];
      end
      assign align_ch[i+1]      = r_q;
      assign warm_align_ch[i+1] = w_q;
    end

    fxp_complex_t     mul_a;
    logic [IDX_W-1:0] mul_idx;
    logic             mul_warm;
    assign {mul_idx, mul_a} = align_ch[ROM_LAT];
    assign mul_warm         = warm_align_ch[ROM_LAT];

    // ---- the SPEC 6 kernel -------------------------------------------------
    // The ROM and the alignment chain share b_vld as their enable, so at every
    // beat-present cycle the coefficient at the ROM output and the sample at the
    // end of the chain belong to the same beat. b_vld is therefore the
    // multiplier's valid_in unchanged: no further delay is correct here, and
    // adding one would be the classic off-by-a-beat.
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
        .valid_in  (b_vld),
        .a         (mul_a),
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

    // ---- free-running tag chain, matching the multiplier's depth -----------
    // Free-running because complex_multiplier's datapath is: a free-running
    // register still delays the BEAT SEQUENCE by exactly one beat, so the tag
    // stays with its sample. Warmth is reset here too, for the reason above.
    logic [TW_PIPE:0][TAG_W-1:0] tag_ch;
    logic [TW_PIPE:0]            warm_tag_ch;
    assign tag_ch[0]      = mul_idx;
    assign warm_tag_ch[0] = mul_warm;

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

    logic [IDX_W-1:0] out_idx;
    logic             out_warm;
    assign out_idx  = tag_ch[TW_PIPE];
    assign out_warm = warm_tag_ch[TW_PIPE];

    assign vld_out        = mul_vld;
    assign dout           = '{re: mul_y_re, im: mul_y_im};
    assign idx_out        = out_idx;
    assign warm_out       = out_warm;
    assign flags_tw       = fxp_flags_merge(mul_f_re, mul_f_im);
    assign flags_tw_valid = mul_vld && out_warm;

`ifndef SYNTHESIS
    // The exact 33-bit port has no datapath consumer here — a twiddle multiply
    // is a rotation, so the Q1.15 result is the whole answer — but it is not
    // left dangling either. It is the input to the multiplier's own rounding,
    // so re-quantising it with fxp_pkg must reproduce the rounded port exactly,
    // on every beat, which is a free cross-check of the kernel's output stage in
    // the context that uses it.
    always_ff @(posedge clk) begin
      if (rst_n && mul_vld) begin
        a_fft_tw_round_matches_pkg : assert (
            (mul_y_re == fxp16_t'(fxp_round_sat(fxp_wide_t'(mul_p_re),
                                                FXP_PROD_SHIFT, FXP_SAMPLE_W))) &&
            (mul_y_im == fxp16_t'(fxp_round_sat(fxp_wide_t'(mul_p_im),
                                                FXP_PROD_SHIFT, FXP_SAMPLE_W))))
          else $error("fft_radix22_stage: twiddle multiply rounded (%0d,%0d) but fxp_pkg says (%0d,%0d)",
                      mul_y_re, mul_y_im,
                      fxp_round_sat(fxp_wide_t'(mul_p_re), FXP_PROD_SHIFT, FXP_SAMPLE_W),
                      fxp_round_sat(fxp_wide_t'(mul_p_im), FXP_PROD_SHIFT, FXP_SAMPLE_W));
        a_fft_tw_ovf_consistent : assert (mul_ovf ==
            (fxp_flags_any(mul_f_re) || fxp_flags_any(mul_f_im)))
          else $error("fft_radix22_stage: twiddle multiply ovf disagrees with its flags");
      end
    end
`endif

  end else begin : g_no_twiddle
    // The final group of a path: every twiddle is W^0 and the multiplier is
    // absent by construction, not bypassed at run time.
    assign vld_out        = b_vld;
    assign dout           = b_data;
    assign idx_out        = b_idx;
    assign warm_out       = b_warm;
    assign flags_tw       = fxp_flags_none();
    assign flags_tw_valid = 1'b0;
  end

endmodule : fft_radix22_stage

`default_nettype wire
