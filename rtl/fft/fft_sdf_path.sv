// -----------------------------------------------------------------------------
// fft_sdf_path — one complete radix-2^2 single-path delay-feedback core.
//
// An M = 2^N_LANE point decimation-in-frequency transform on a serial stream,
// one sample per beat, output in bit-reversed order. This is the module SPEC 7.2
// names as the preferred architecture; fft_core instantiates one per lane.
//
//   n even   groups (0,1) (2,3) ... (n-2,n-1)          log4(M)-1 multipliers
//   n odd    groups (0,1) ... (n-3,n-2) + BF2I(D=1)    (n-1)/2 multipliers
//
// THE TRAILING RADIX-2 STAGE IS THE NORMAL CASE HERE, not an exception. Every
// power-of-four FFT_SIZE with SAMPLES_PER_CYCLE = 2 gives M = FFT_SIZE/2 and
// therefore an odd n: 64/2 -> M = 32, n = 5; 256/2 -> M = 128, n = 7;
// 1024/2 -> M = 512, n = 9. The rule in fft_pkg — sub-stage s is BF2I when s is
// even, BF2II when odd, and carries a twiddle multiplier when s is odd and
// s < n-1 — produces the trailing lone BF2I with delay 1 by itself, so both
// parities come out of one generate loop and neither is a special case written
// twice. That is also why fft_pkg exports fft_lane_mults(): the multiplier count
// is a property of the structure, and the elaboration check below holds the
// generated chain to it.
//
// Everything structural is fft_pkg's: delays, butterfly types, which groups end
// in a multiplier, and the per-sub-stage scaling schedule. This module is a
// chain and an elaboration check, nothing else.
//
// Lint contract: clean under `verilator --lint-only --Wall` with no waiver.
// -----------------------------------------------------------------------------

`default_nettype none

module fft_sdf_path
  import fxp_pkg::*;
  import fft_pkg::*;
#(
    // log2 of this lane's transform length. The position tag is N_LANE bits.
    parameter int unsigned N_LANE      = 5,

    // Per-sub-stage right shifts: bit s applies to sub-stage s. Bits at or above
    // N_LANE are ignored here (they belong to the merge levels).
    parameter int unsigned SCALE_SCHED = 32'hFFFF_FFFF,

    parameter string       TW_VARIANT     = "MULT4",
    parameter int unsigned TW_PIPE        = 4,
    parameter int unsigned TW_ROM_OUT_REG = 1,
    parameter string       MEM_STYLE      = "DEFAULT",
    parameter string       TW_STYLE       = "AUTO"
) (
    input  wire                     clk,
    input  wire                     rst_n,

    input  wire                     vld_in,
    input  wire fxp_complex_t       din,
    input  wire [N_LANE-1:0]        idx_in,
    input  wire                     warm_in,

    output wire                     vld_out,
    output wire fxp_complex_t       dout,
    output wire [N_LANE-1:0]        idx_out,
    output wire                     warm_out,

    // Per-sub-stage saturation reporting. Index s is sub-stage s; the butterfly
    // site and the twiddle site are reported apart because they sit at different
    // pipeline depths (see fft_radix22_stage).
    output wire [N_LANE-1:0][1:0]   bf_flags,
    output wire [N_LANE-1:0]        bf_flags_valid,
    output wire [N_LANE-1:0][1:0]   tw_flags,
    output wire [N_LANE-1:0]        tw_flags_valid
);

  localparam int unsigned CPLX_W   = $bits(fxp_complex_t);
  localparam int unsigned N_GROUP  = N_LANE / 2;          // full radix-2^2 groups
  localparam int unsigned HAS_TAIL = N_LANE % 2;          // trailing lone BF2I
  localparam int unsigned N_ELEM   = N_GROUP + HAS_TAIL;  // chain elements
  localparam int unsigned N_MULT   = int'(fft_lane_mults(fft_uint_t'(N_LANE)));

`ifndef SYNTHESIS
  initial begin
    if (N_LANE < 2) begin
      $fatal(1, "fft_sdf_path: N_LANE=%0d is too small; a lane needs >= 4 points",
             N_LANE);
    end
    if (N_LANE > int'(fft_pkg::FFT_MAX_STAGES)) begin
      $fatal(1, "fft_sdf_path: N_LANE=%0d exceeds the twiddle table's %0d",
             N_LANE, fft_pkg::FFT_MAX_STAGES);
    end
  end
`endif

  // ---------------------------------------------------------------------------
  // Chain wiring. Packed 2-D buses with one continuous driver per element.
  // ---------------------------------------------------------------------------
  logic [N_ELEM:0]              ch_vld;
  logic [N_ELEM:0][CPLX_W-1:0]  ch_data;
  logic [N_ELEM:0][N_LANE-1:0]  ch_idx;
  logic [N_ELEM:0]              ch_warm;

  assign ch_vld[0]  = vld_in;
  assign ch_data[0] = CPLX_W'(din);
  assign ch_idx[0]  = idx_in;
  assign ch_warm[0] = warm_in;

  // Per-sub-stage flag collection, driven element by element below.
  logic [N_LANE-1:0][1:0] bf_f, tw_f;
  logic [N_LANE-1:0]      bf_v, tw_v;

  // ---------------------------------------------------------------------------
  // Radix-2^2 groups
  // ---------------------------------------------------------------------------
  for (genvar g = 0; g < int'(N_GROUP); g++) begin : g_group
    localparam int unsigned SA = 2 * g;
    localparam int unsigned SB = 2 * g + 1;
    localparam int unsigned HAS_TW =
        fft_stage_has_twiddle(fft_uint_t'(N_LANE), fft_uint_t'(SB)) ? 1 : 0;

    fxp_complex_t  s_din, s_dout;
    logic          s_vld;
    logic [N_LANE-1:0] s_idx;
    logic          s_warm;
    fxp_flags_t    f_a, f_b, f_tw;
    logic          v_a, v_b, v_tw;

    assign s_din = fxp_complex_t'(ch_data[g]);

    fft_radix22_stage #(
        .IDX_W          (N_LANE),
        .N_LANE         (N_LANE),
        .S              (SA),
        .SHIFT_A        (int'(fft_shift(fft_uint_t'(SCALE_SCHED), fft_uint_t'(SA)))),
        .SHIFT_B        (int'(fft_shift(fft_uint_t'(SCALE_SCHED), fft_uint_t'(SB)))),
        .HAS_TWIDDLE    (HAS_TW),
        .TW_VARIANT     (TW_VARIANT),
        .TW_PIPE        (TW_PIPE),
        .TW_ROM_OUT_REG (TW_ROM_OUT_REG),
        .MEM_STYLE      (MEM_STYLE),
        .TW_STYLE       (TW_STYLE)
    ) u_stage (
        .clk            (clk),
        .rst_n          (rst_n),
        .vld_in         (ch_vld[g]),
        .din            (s_din),
        .idx_in         (ch_idx[g]),
        .warm_in        (ch_warm[g]),
        .vld_out        (s_vld),
        .dout           (s_dout),
        .idx_out        (s_idx),
        .warm_out       (s_warm),
        .flags_a        (f_a),
        .flags_a_valid  (v_a),
        .flags_b        (f_b),
        .flags_b_valid  (v_b),
        .flags_tw       (f_tw),
        .flags_tw_valid (v_tw)
    );

    assign ch_vld[g+1]  = s_vld;
    assign ch_data[g+1] = CPLX_W'(s_dout);
    assign ch_idx[g+1]  = s_idx;
    assign ch_warm[g+1] = s_warm;

    // The group's two butterflies report against their own sub-stage indices.
    // The multiplier belongs to the group and is reported against the BF2II,
    // which is the sub-stage whose schedule entry precedes it.
    assign bf_f[SA] = f_a;   assign bf_v[SA] = v_a;
    assign bf_f[SB] = f_b;   assign bf_v[SB] = v_b;
    assign tw_f[SA] = 2'b00; assign tw_v[SA] = 1'b0;
    assign tw_f[SB] = f_tw;  assign tw_v[SB] = v_tw;
  end

  // ---------------------------------------------------------------------------
  // Trailing radix-2 stage, present exactly when n is odd
  // ---------------------------------------------------------------------------
  if (HAS_TAIL != 0) begin : g_tail
    localparam int unsigned ST = N_LANE - 1;

    fxp_complex_t  t_din, t_dout;
    logic          t_vld;
    logic [N_LANE-1:0] t_idx;
    logic          t_warm;
    fxp_flags_t    t_flags;
    logic          t_fvalid;

    assign t_din = fxp_complex_t'(ch_data[N_GROUP]);

    fft_bf2 #(
        .IDX_W     (N_LANE),
        .DELAY     (int'(fft_bf_delay(fft_uint_t'(N_LANE), fft_uint_t'(ST)))),   // == 1
        .IS_BF2II  (0),
        .SHIFT     (int'(fft_shift(fft_uint_t'(SCALE_SCHED), fft_uint_t'(ST)))),
        .MEM_STYLE (fft_resolve_mem_style(
                        MEM_STYLE,
                        fft_bf_delay(fft_uint_t'(N_LANE), fft_uint_t'(ST))))
    ) u_tail (
        .clk         (clk),
        .rst_n       (rst_n),
        .en          (ch_vld[N_GROUP]),
        .din         (t_din),
        .idx_in      (ch_idx[N_GROUP]),
        .warm_in     (ch_warm[N_GROUP]),
        .dout        (t_dout),
        .idx_out     (t_idx),
        .warm_out    (t_warm),
        .vld_out     (t_vld),
        .flags       (t_flags),
        .flags_valid (t_fvalid)
    );

    assign ch_vld[N_ELEM]  = t_vld;
    assign ch_data[N_ELEM] = CPLX_W'(t_dout);
    assign ch_idx[N_ELEM]  = t_idx;
    assign ch_warm[N_ELEM] = t_warm;

    assign bf_f[ST] = t_flags;  assign bf_v[ST] = t_fvalid;
    assign tw_f[ST] = 2'b00;    assign tw_v[ST] = 1'b0;
  end

  assign vld_out        = ch_vld[N_ELEM];
  assign dout           = fxp_complex_t'(ch_data[N_ELEM]);
  assign idx_out        = ch_idx[N_ELEM];
  assign warm_out       = ch_warm[N_ELEM];
  assign bf_flags       = bf_f;
  assign bf_flags_valid = bf_v;
  assign tw_flags       = tw_f;
  assign tw_flags_valid = tw_v;

  // ---------------------------------------------------------------------------
  // Elaboration check: the chain the generate loop built must have the shape
  // fft_pkg predicts. A miscount here would be a silently wrong transform, so it
  // is checked against the package's own formula rather than against the loop
  // that produced it.
  // ---------------------------------------------------------------------------
`ifndef SYNTHESIS
  initial begin
    automatic int unsigned mults = 0;
    for (int unsigned s = 0; s < N_LANE; s++) begin
      if (fft_stage_has_twiddle(fft_uint_t'(N_LANE), s)) mults++;
    end
    if (mults != N_MULT) begin
      $fatal(1, "fft_sdf_path: chain has %0d twiddle multipliers, fft_lane_mults(%0d)=%0d",
             mults, N_LANE, N_MULT);
    end
    if ((2 * N_GROUP + HAS_TAIL) != N_LANE) begin
      $fatal(1, "fft_sdf_path: %0d groups + %0d tail do not cover %0d sub-stages",
             N_GROUP, HAS_TAIL, N_LANE);
    end
  end
`endif

endmodule : fft_sdf_path

`default_nettype wire
