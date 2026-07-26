// -----------------------------------------------------------------------------
// history_core_wrap — SPEC.md 18 calibration wrapper for a SLICE of the SPEC 7.3
// corner turn (issue #15).
//
// history_bank_wrap prices the ATOM — one memory, one geometry. This wrapper
// prices the BLOCK: several banks, the per-antenna write sequencers, the frame
// barrier, the rotation and readable-set arithmetic, the registered read fanout,
// the three CDC crossings and the counters. The difference between the two
// numbers is the corner turn's FIXED COST measured rather than argued, which is
// the same reason issue #11 compiled a stage and a whole FFT, and issue #12 a
// dot product and a whole matrix.
//
// It is a slice and not the full-scale block on purpose: at SPEC 11 full scale
// this module is 16 antennas x 1024 bins x 512 frames, which is most of the
// device's M20K budget and a Fitter run measured in hours. What a slice can
// answer, and what the projection in the pull request needs, is the PER-BANK
// cost and the FIXED overhead; the full-scale figure is then those two numbers
// times a count, which is arithmetic that does not need a compile.
//
// One clock, for the reason history_bank_wrap gives at length: `core_clk` and
// `history_clk` are tied together here, so the crossings are elaborated and
// costed but the asynchrony is not. The three cdc_ instances are real logic
// either way — a handshake's flops and its synchroniser chains exist whether or
// not the clocks differ — so their AREA is measured correctly and only their
// timing behaviour is not exercised. That gap is covered where it belongs, by
// the clock-ratio sweep in sim/tests/test_history.cpp.
//
// The instance is named `u_kernel` because calibrate.tcl matches on it.
//
// Lint contract: linted by `make lint` through sim/verilator/files_history.f.
// -----------------------------------------------------------------------------

`default_nettype none

module history_core_wrap
  import history_pkg::*;
  import stream_pkg::*;
#(
    parameter int unsigned N_ANT      = 4,
    parameter int unsigned FFT_SIZE   = 64,
    parameter int unsigned LANES      = 1,
    parameter int unsigned FRAMES_MAX = 4,
    parameter int unsigned SAMPLE_W   = 16,

    // 0 natural beat order, 1 bit-reversed (the FFT's REORDER = 0 case).
    parameter int unsigned BIT_REVERSED = 0,

    //   0 auto   1 m20k   2 mlab   3 regs
    parameter int unsigned MEM_SEL = 0
) (
    input  wire         clk,
    input  wire         rst_n,

    // Per-antenna SPEC 5 write payloads, concatenated. Sized to the widest
    // geometry this project sweeps so the virtual-pin globs are stable.
    input  wire [3:0]   wr_valid_in,
    input  wire [511:0] wr_payload_in,

    input  wire         cfg_enable_in,
    input  wire [15:0]  cfg_depth_in,
    input  wire         cfg_apply_in,
    input  wire         cfg_clear_in,
    input  wire         cfg_unsafe_in,

    input  wire         req_valid_in,
    input  wire [15:0]  req_bin_in,
    input  wire [15:0]  req_off_in,
    input  wire         m_ready_in,

    output wire [3:0]   wr_ready_out,
    output wire         req_ready_out,
    output wire         m_valid_out,
    output wire [127:0] m_vec_out,
    output wire [63:0]  m_meta_out,
    // Every status word folded into one 64-bit output. Folded rather than
    // dropped: SPEC 24 forbids letting logic optimise away, and 200 pins of
    // counters would dwarf the block being measured. All of them still
    // participate, so none of them optimises away.
    output wire [63:0]  stat_fold_out
);

  localparam string MEM_STYLE =
      (MEM_SEL == 1) ? "m20k" :
      (MEM_SEL == 2) ? "mlab" :
      (MEM_SEL == 3) ? "regs" : "auto";

  localparam bit BR = (BIT_REVERSED != 0);

  localparam int unsigned WR_ID_W   = 2;
  localparam int unsigned WR_SEQ_W  = 16;
  localparam int unsigned WR_USER_W = 4;
  localparam int unsigned RD_ID_W   = 2;
  localparam int unsigned RD_SEQ_W  = 16;
  localparam int unsigned RD_USER_W = 4;

  localparam hist_geom_t GK =
      hist_geom(N_ANT, FFT_SIZE, LANES, FRAMES_MAX, SAMPLE_W);
  localparam int unsigned VEC_W_K  = int'(hist_vec_w(GK));
  localparam int unsigned DATA_W_K = int'(hist_data_w(GK));
  localparam int unsigned META_W_K = int'(hist_meta_w(GK));

  localparam stream_geom_t WGK =
      stream_geom(LANES * 2 * SAMPLE_W, WR_ID_W, WR_SEQ_W, WR_USER_W);
  localparam stream_geom_t RGK =
      stream_geom(DATA_W_K, RD_ID_W, RD_SEQ_W, RD_USER_W);

  localparam int unsigned WPW = int'(stream_payload_w(WGK));
  localparam int unsigned RPW = int'(stream_payload_w(RGK));

  // ---- input registers. Only the valid bits are reset (SPEC 23). ----
  logic [N_ANT-1:0]     wv_q;
  logic                 rv_q, mr_q;
  logic                 en_q, ap_q, cl_q, un_q;
  logic [N_ANT*WPW-1:0] wp_q;
  logic [15:0]          dep_q, bin_q, off_q;

  always_ff @(posedge clk) begin
    if (!rst_n) begin
      wv_q <= '0;
      rv_q <= 1'b0;
      mr_q <= 1'b0;
      en_q <= 1'b0;
      ap_q <= 1'b0;
      cl_q <= 1'b0;
      un_q <= 1'b0;
    end else begin
      wv_q <= wr_valid_in[N_ANT-1:0];
      rv_q <= req_valid_in;
      mr_q <= m_ready_in;
      en_q <= cfg_enable_in;
      ap_q <= cfg_apply_in;
      cl_q <= cfg_clear_in;
      un_q <= cfg_unsafe_in;
    end
  end

  always_ff @(posedge clk) begin
    wp_q  <= wr_payload_in[N_ANT*WPW-1:0];
    dep_q <= cfg_depth_in;
    bin_q <= req_bin_in;
    off_q <= req_off_in;
  end

  wire [N_ANT-1:0] wr_ready_w;
  wire [15:0]      depth_w, occ_w;
  wire [31:0]      frames_w, ovw_w, skw_w, wbt_w, rdc_w, col_w, err_w;
  wire [7:0]       epoch_w;
  wire [3:0]       fault_w;
  wire             pending_w, req_ready_w, mv_w;
  wire [RPW-1:0]   mp_w;

  history_core #(
      .N_ANT              (N_ANT),
      .FFT_SIZE           (FFT_SIZE),
      .LANES              (LANES),
      .FRAMES_MAX         (FRAMES_MAX),
      .SAMPLE_W           (SAMPLE_W),
      .INPUT_BIT_REVERSED (BR),
      .STORAGE            (MEM_STYLE),
      .SYNC_STAGES        (2),
      .WR_ID_W            (WR_ID_W),
      .WR_SEQ_W           (WR_SEQ_W),
      .WR_USER_W          (WR_USER_W),
      .RD_ID_W            (RD_ID_W),
      .RD_SEQ_W           (RD_SEQ_W),
      .RD_USER_W          (RD_USER_W)
  ) u_kernel (
      .core_clk              (clk),
      .core_rst_n            (rst_n),
      .s_valid               (wv_q),
      .s_ready               (wr_ready_w),
      .s_payload             (wp_q),
      .cfg_enable            (en_q),
      .cfg_depth             (dep_q),
      .cfg_depth_apply       (ap_q),
      .cfg_counter_clear     (cl_q),
      .cfg_sticky_clear      (cl_q),
      .cfg_force_unsafe      (un_q),
      .stat_depth_active     (depth_w),
      .stat_occupancy        (occ_w),
      .stat_frames_done      (frames_w),
      .stat_overwrite_count  (ovw_w),
      .stat_skew_count       (skw_w),
      .stat_write_beat_count (wbt_w),
      .stat_read_count       (rdc_w),
      .stat_collision_count  (col_w),
      .stat_error_count      (err_w),
      .stat_epoch            (epoch_w),
      .stat_fault            (fault_w),
      .obs_depth_pending     (pending_w),
      .history_clk           (clk),
      .history_rst_n         (rst_n),
      .rd_req_valid          (rv_q),
      .rd_req_ready          (req_ready_w),
      .rd_req_bin            (bin_q),
      .rd_req_frame_off      (off_q),
      .m_valid               (mv_w),
      .m_ready               (mr_q),
      .m_payload             (mp_w)
  );

  stream_fields_t rf;
  assign rf = stream_unpack(RGK, stream_payload_t'(mp_w));

  // ---- output registers ----
  logic [N_ANT-1:0] wrdy_q;
  logic             rrdy_q, mv_q;
  logic [127:0]     vec_q;
  logic [63:0]      meta_q;
  logic [63:0]      fold_q;

  always_ff @(posedge clk) begin
    if (!rst_n) begin
      wrdy_q <= '0;
      rrdy_q <= 1'b0;
      mv_q   <= 1'b0;
    end else begin
      wrdy_q <= wr_ready_w;
      rrdy_q <= req_ready_w;
      mv_q   <= mv_w;
    end
  end

  always_ff @(posedge clk) begin
    vec_q  <= 128'(rf.data[VEC_W_K-1:0]);
    meta_q <= 64'(rf.data[VEC_W_K +: META_W_K]);
    fold_q <= {depth_w, occ_w, epoch_w, 4'd0, fault_w, pending_w, 3'd0} ^
              {frames_w, ovw_w} ^ {skw_w, wbt_w} ^ {rdc_w, col_w} ^
              {err_w, 16'(rf.seq[RD_SEQ_W-1:0]), 16'd0};
  end

  assign wr_ready_out  = 4'(wrdy_q);
  assign req_ready_out = rrdy_q;
  assign m_valid_out   = mv_q;
  assign m_vec_out     = vec_q;
  assign m_meta_out    = meta_q;
  assign stat_fold_out = fold_q;

endmodule : history_core_wrap

`default_nettype wire
