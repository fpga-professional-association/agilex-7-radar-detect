// -----------------------------------------------------------------------------
// pipeline_top - Verilator wrapper around the integrated pipeline for issue #17
// tests. Fans SPEC 5 metadata out to unpacked ports the C++ harness drives,
// and reports selected status.
//
// The DUT is rtl/top/benchmark_sim_top.sv (module `benchmark_pipeline_top`);
// see that file for the pipeline diagram, clock domains and geometry.
//
// Simulation only. Never synthesized.
// -----------------------------------------------------------------------------

`default_nettype none

module pipeline_top (
    // ---- clocks and resets -------------------------------------------------
    input  wire         core_clk,
    input  wire         core_rst_n,
    input  wire         history_clk,
    input  wire         history_rst_n,
    input  wire         cfg_clk,
    input  wire         cfg_rst_n,

    // ---- PFB coefficient bank programming ---------------------------------
    input  wire         cfg_pfb_wr_valid,
    output wire         cfg_pfb_wr_ready,
    input  wire         cfg_pfb_wr_bank,
    input  wire [3:0]   cfg_pfb_wr_addr,
    input  wire [31:0]  cfg_pfb_wr_data,

    // ---- beamformer weight bank programming ------------------------------
    input  wire         cfg_bf_wr_valid,
    output wire         cfg_bf_wr_ready,
    input  wire         cfg_bf_wr_bank,
    input  wire [3:0]   cfg_bf_wr_addr,
    input  wire [31:0]  cfg_bf_wr_data,

    // ---- pipeline swap request --------------------------------------------
    input  wire         cfg_pipe_swap_req,

    // ---- history control --------------------------------------------------
    input  wire         cfg_hist_enable,
    input  wire [15:0]  cfg_hist_depth,
    input  wire         cfg_hist_depth_apply,
    input  wire         cfg_hist_counter_clear,
    input  wire         cfg_hist_sticky_clear,

    // ---- alignment control ------------------------------------------------
    input  wire         cfg_align_enable,
    input  wire         cfg_align_run,
    input  wire [15:0]  cfg_align_frame_off,
    input  wire         cfg_align_partial_pass,
    input  wire         cfg_align_counter_clear,
    input  wire         cfg_align_sticky_clear,

    // ---- CFAR control -----------------------------------------------------
    input  wire         cfg_cfar_enable,
    input  wire [1:0]   cfg_cfar_mode,
    input  wire         cfg_cfar_out_mode,
    input  wire [4:0]   cfg_cfar_guard_lead,
    input  wire [4:0]   cfg_cfar_guard_lag,
    input  wire [5:0]   cfg_cfar_ref_lead,
    input  wire [5:0]   cfg_cfar_ref_lag,
    input  wire [15:0]  cfg_cfar_alpha,
    input  wire         cfg_cfar_status_clear,

    // ---- input stimulus (per antenna, unpacked) --------------------------
    input  wire [3:0]   s_valid,
    output wire [3:0]   s_ready,
    input  wire [3:0]   s_sof,
    input  wire [3:0]   s_eof,
    // Antenna a, phase p occupies s_data[a*128 + p*32 +: 32]
    input  wire [255:0] s_data,
    input  wire [15:0]  s_seq,

    // ---- output: CFAR detections -----------------------------------------
    output wire         m_valid,
    input  wire         m_ready,
    output wire [63:0]  m_event_data,
    output wire         m_sof,
    output wire         m_eof,
    output wire [15:0]  m_seq,
    output wire [3:0]   m_id,

    // ---- telemetry / status -----------------------------------------------
    output wire [31:0]  stat_pipe_frame_count,
    output wire [31:0]  stat_pipe_swap_count,
    output wire [31:0]  stat_pipe_swap_overrun,
    output wire         stat_pipe_swap_busy,
    output wire         stat_pipe_swap_pending,

    output wire [31:0]  stat_pfb_frame_count,
    output wire         stat_pfb_sat_any,

    output wire [31:0]  stat_history_frames_done,
    output wire [31:0]  stat_history_write_beats,
    output wire [31:0]  stat_history_read_count,
    output wire [31:0]  stat_history_error_count,
    output wire [15:0]  stat_history_depth_active,
    output wire [15:0]  stat_history_occupancy,

    output wire [31:0]  stat_align_beat_count,
    output wire [31:0]  stat_align_missing_count,
    output wire [31:0]  stat_align_timeout_count,

    output wire [31:0]  stat_bf_frame_count,
    output wire         stat_bf_sat_any,

    output wire [31:0]  stat_cfar_det_count,
    output wire [31:0]  stat_cfar_sup_count,
    output wire [31:0]  stat_cfar_frame_count
);

  benchmark_pipeline_top u_dut (
      .core_clk                  (core_clk),
      .core_rst_n                (core_rst_n),
      .history_clk               (history_clk),
      .history_rst_n             (history_rst_n),
      .cfg_clk                   (cfg_clk),
      .cfg_rst_n                 (cfg_rst_n),

      .cfg_pfb_wr_valid          (cfg_pfb_wr_valid),
      .cfg_pfb_wr_ready          (cfg_pfb_wr_ready),
      .cfg_pfb_wr_bank           (cfg_pfb_wr_bank),
      .cfg_pfb_wr_addr           (cfg_pfb_wr_addr),
      .cfg_pfb_wr_data           (cfg_pfb_wr_data),

      .cfg_bf_wr_valid           (cfg_bf_wr_valid),
      .cfg_bf_wr_ready           (cfg_bf_wr_ready),
      .cfg_bf_wr_bank            (cfg_bf_wr_bank),
      .cfg_bf_wr_addr            (cfg_bf_wr_addr),
      .cfg_bf_wr_data            (cfg_bf_wr_data),

      .cfg_pipe_swap_req         (cfg_pipe_swap_req),

      .cfg_hist_enable           (cfg_hist_enable),
      .cfg_hist_depth            (cfg_hist_depth),
      .cfg_hist_depth_apply      (cfg_hist_depth_apply),
      .cfg_hist_counter_clear    (cfg_hist_counter_clear),
      .cfg_hist_sticky_clear     (cfg_hist_sticky_clear),

      .cfg_align_enable          (cfg_align_enable),
      .cfg_align_run             (cfg_align_run),
      .cfg_align_frame_off       (cfg_align_frame_off),
      .cfg_align_partial_pass    (cfg_align_partial_pass),
      .cfg_align_counter_clear   (cfg_align_counter_clear),
      .cfg_align_sticky_clear    (cfg_align_sticky_clear),

      .cfg_cfar_enable           (cfg_cfar_enable),
      .cfg_cfar_mode             (cfg_cfar_mode),
      .cfg_cfar_out_mode         (cfg_cfar_out_mode),
      .cfg_cfar_guard_lead       (cfg_cfar_guard_lead),
      .cfg_cfar_guard_lag        (cfg_cfar_guard_lag),
      .cfg_cfar_ref_lead         (cfg_cfar_ref_lead),
      .cfg_cfar_ref_lag          (cfg_cfar_ref_lag),
      .cfg_cfar_alpha            (cfg_cfar_alpha),
      .cfg_cfar_status_clear     (cfg_cfar_status_clear),

      .s_valid                   (s_valid),
      .s_ready                   (s_ready),
      .s_sof                     (s_sof),
      .s_eof                     (s_eof),
      .s_data                    (s_data),
      .s_seq                     (s_seq),

      .m_valid                   (m_valid),
      .m_ready                   (m_ready),
      .m_event_data              (m_event_data),
      .m_sof                     (m_sof),
      .m_eof                     (m_eof),
      .m_seq                     (m_seq),
      .m_id                      (m_id),

      .stat_pipe_frame_count     (stat_pipe_frame_count),
      .stat_pipe_swap_count      (stat_pipe_swap_count),
      .stat_pipe_swap_overrun    (stat_pipe_swap_overrun),
      .stat_pipe_swap_busy       (stat_pipe_swap_busy),
      .stat_pipe_swap_pending    (stat_pipe_swap_pending),
      .stat_pfb_frame_count      (stat_pfb_frame_count),
      .stat_pfb_sat_any          (stat_pfb_sat_any),
      .stat_history_frames_done  (stat_history_frames_done),
      .stat_history_write_beats  (stat_history_write_beats),
      .stat_history_read_count   (stat_history_read_count),
      .stat_history_error_count  (stat_history_error_count),
      .stat_history_depth_active (stat_history_depth_active),
      .stat_history_occupancy    (stat_history_occupancy),
      .stat_align_beat_count     (stat_align_beat_count),
      .stat_align_missing_count  (stat_align_missing_count),
      .stat_align_timeout_count  (stat_align_timeout_count),
      .stat_bf_frame_count       (stat_bf_frame_count),
      .stat_bf_sat_any           (stat_bf_sat_any),
      .stat_cfar_det_count       (stat_cfar_det_count),
      .stat_cfar_sup_count       (stat_cfar_sup_count),
      .stat_cfar_frame_count     (stat_cfar_frame_count)
  );

endmodule : pipeline_top

`default_nettype wire
