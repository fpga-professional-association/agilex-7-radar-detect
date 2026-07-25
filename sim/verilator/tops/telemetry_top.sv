// -----------------------------------------------------------------------------
// telemetry_top — telemetry unit-test top (SPEC 13.1, SPEC 9, issue #8).
//
// Everything issue #8 delivers, in one place, with a real stream running through
// it and the SPEC 9 master port at the boundary so the C++ register driver in
// sim/verilator/harness/reg_driver.h can read the counters exactly as software
// would. A failure in this build is always a telemetry failure — the same
// arrangement, for the same reason, as stream_prims_top, cdc_prims_top and
// control_top.
//
//   u_in_skid / u_fifo / u_out_skid   a real datapath to measure: registered
//                                     ready on both faces and a FIFO in the
//                                     middle whose fill level varies under
//                                     backpressure, so the high-water mark has
//                                     something to find.
//   u_telemetry                       the SPEC 9 counters block, watching the
//                                     datapath's OUTPUT interface.
//   u_seq                             the sequence checker, watching the same
//                                     interface — or, with `sq_override`, a
//                                     stimulus the test drives directly.
//   u_pc_wrap / u_pc_sat / u_pc_incr  three deliberately narrow perf_counters,
//                                     8 bits wide, so a test can wrap one in
//                                     three hundred events instead of four
//                                     billion.
//
// WHY THE SEQUENCE CHECKER HAS AN OVERRIDE
// ----------------------------------------
// Injecting a dropped, duplicated or reordered beat into the datapath is not an
// option: every stream primitive instantiates a stream_protocol_checker, whose
// `a_seq_continuous` assertion would fire — correctly — and abort the run. The
// fault would be caught by the wrong mechanism and the thing under test would
// never see it.
//
// So the checker's four watched signals pass through a mux. Normally they are
// the datapath's, which is what proves the integration: real traffic, at real
// backpressure, must produce exactly zero sequence faults. With `sq_override`
// they are driven by the test, and a fault can be constructed exactly — one
// missing number, one repeat, one step backwards — with nothing between the
// stimulus and the classifier to blur it.
//
// One checker rather than two, on purpose: the instance that must report zero on
// good traffic is the same instance that must report the right category on bad,
// so neither result can be explained by a difference between them.
//
// ONE CLOCK
// ---------
// The register plane and the observed datapath share `clk` here. SPEC 8 puts the
// register plane in cfg_clk and a datapath in core_clk, and the crossing between
// them is a crossing of the REGISTER INTERFACE — one bus, one issue #6 handshake
// — which belongs to the multi-domain integration in issue #19 and not to the
// counters. Introducing it here would add an unverified crossing to a top whose
// job is to prove the counting is exact, and a counting error and a CDC error
// would then be indistinguishable. See telemetry_block's header and DECISIONS.md.
//
// Simulation only. Never synthesized, never in a Quartus source list.
// -----------------------------------------------------------------------------

`default_nettype none

module telemetry_top
  import reg_if_pkg::*;
  import regmap_pkg::*;
  import config_pkg::*;
(
    input  wire                         clk,
    input  wire                         rst_n,

    // ---- SPEC 9 master port ----
    input  wire [REG_ADDR_W-1:0]        address,
    input  wire [REG_DATA_W-1:0]        write_data,
    input  wire [REG_STRB_W-1:0]        byte_enable,
    input  wire                         write_enable,
    input  wire                         read_enable,
    output wire [REG_DATA_W-1:0]        read_data,
    output wire                         ready,
    output wire                         error,

    // ---- observed datapath: skid -> sync_fifo -> skid ----
    input  wire                         s_valid,
    output wire                         s_ready,
    input  wire [STREAM_PAYLOAD_W-1:0]  s_payload,
    output wire                         m_valid,
    input  wire                         m_ready,
    output wire [STREAM_PAYLOAD_W-1:0]  m_payload,

    // The FIFO's own occupancy and high-water mark, so the test can compare the
    // number telemetry reports against the number the FIFO itself keeps. Two
    // independent trackers agreeing is worth more than either one asserted.
    output wire [7:0]                   fifo_occupancy,
    output wire [7:0]                   fifo_high_water,
    output wire                         fifo_full,
    output wire                         fifo_empty,
    output wire                         fifo_almost_full,
    output wire                         fifo_almost_empty,
    output wire                         fifo_overflow_sticky,
    output wire                         fifo_underflow_sticky,

    // ---- events that arrive from elsewhere in a real design ----
    // A FIFO overflow, an arithmetic saturation and a CDC error are produced by
    // blocks this top does not contain, so the test injects them. What is under
    // test here is that they are counted, not where they came from.
    input  wire                         inj_overflow,
    input  wire                         inj_saturate,
    input  wire                         inj_cdc_error,

    // ---- sequence-checker stimulus override ----
    input  wire                         sq_override,
    input  wire                         sq_beat,
    input  wire [STREAM_ID_W-1:0]       sq_stream_id,
    input  wire [STREAM_SEQ_W-1:0]      sq_seq,
    input  wire                         sq_sof,

    // ---- sequence-checker observation, without the register plane ----
    output wire                         sq_err_gap,
    output wire                         sq_err_dup,
    output wire                         sq_err_reorder,
    output wire                         sq_err_untracked,
    output wire [STREAM_SEQ_W-1:0]      sq_gap_size,
    output wire [3:0]                   sq_sticky,
    output wire [31:0]                  sq_cnt_gap,
    output wire [31:0]                  sq_cnt_lost,
    output wire [31:0]                  sq_cnt_dup,
    output wire [31:0]                  sq_cnt_reorder,
    output wire [31:0]                  sq_cnt_untracked,
    output wire                         sq_snap_valid,
    output wire                         sq_counts_saturate_event,
    output wire                         sq_counts_saturated,

    // ---- narrow perf_counter probes (SPEC 13.4 wrap testing) ----
    input  wire                         pc_enable,
    input  wire                         pc_event,
    input  wire [TELEM_PROBE_INCR_W-1:0] pc_incr,
    input  wire                         pc_clear,
    input  wire                         pc_snapshot,

    output wire [TELEM_PROBE_W-1:0]     pcw_count,      // modulo
    output wire [TELEM_PROBE_W-1:0]     pcw_snap,
    output wire                         pcw_snap_valid,
    output wire                         pcw_wrap_pulse,
    output wire                         pcw_wrapped,

    output wire [TELEM_PROBE_W-1:0]     pcs_count,      // saturating
    output wire [TELEM_PROBE_W-1:0]     pcs_snap,
    output wire                         pcs_snap_valid,
    output wire                         pcs_wrap_pulse,
    output wire                         pcs_wrapped,

    output wire [TELEM_PROBE_W-1:0]     pci_count,      // weighted increments
    output wire [TELEM_PROBE_W-1:0]     pci_snap,
    output wire                         pci_snap_valid,
    output wire                         pci_wrap_pulse,
    output wire                         pci_wrapped,

    // ---- telemetry control outputs, so a test sees the strobes it caused ----
    output wire                         obs_count_enable,
    output wire                         obs_seq_enable,
    output wire                         obs_seq_sof_resync,
    output wire                         obs_snapshot_strobe,
    output wire                         obs_counter_clear,
    output wire                         obs_sticky_clear,

    // The observed interface, exported so the C++ ground truth counts exactly
    // the cycles the RTL counts, from the same signals.
    output wire                         obs_beat,
    output wire                         obs_stall,
    output wire                         obs_idle,

    // ---- live counts, beside the shadows the register plane reads ----
    // The coherence claim is "the shadow does not move while the counter does".
    // That is only checkable if both are visible, so both are.
    output wire [TELEM_WIDE_W-1:0]      live_beat_count,
    output wire [TELEM_WIDE_W-1:0]      live_stall_count,
    output wire [TELEM_COUNT_W-1:0]     live_idle_count,
    output wire [TELEM_COUNT_W-1:0]     live_frame_count,
    output wire [TELEM_COUNT_W-1:0]     live_frame_start_count,
    output wire [TELEM_COUNT_W-1:0]     live_overflow_count,
    output wire [TELEM_COUNT_W-1:0]     live_saturate_count,
    output wire [TELEM_COUNT_W-1:0]     live_cdc_error_count,
    output wire [TELEM_COUNT_W-1:0]     live_snapshot_id,
    output wire [7:0]                   live_fifo_high_water,

    // The counters block's storage and pulse vectors, seen without the read
    // mux — the same observation control_top provides for every other block,
    // and for the same reason: it separates "the write did not land" from "the
    // read path is broken".
    output wire [REGMAP_COUNTERS_N_REGS*32-1:0] obs_counters_csr,
    output wire [REGMAP_COUNTERS_N_REGS*32-1:0] obs_counters_pulse
);

  localparam int unsigned IDX_W  = REGMAP_WINDOW_W - 2;
  localparam int unsigned OCC_W  = $clog2(TELEM_FIFO_DEPTH + 1);

  localparam stream_pkg::stream_geom_t GEOM = stream_pkg::stream_geom(
      STREAM_DATA_W, STREAM_ID_W, STREAM_SEQ_W, STREAM_USER_W);

  // ---------------------------------------------------------------------------
  // Datapath: skid -> sync_fifo -> skid
  // ---------------------------------------------------------------------------
  wire                        a_valid, a_ready;
  wire [STREAM_PAYLOAD_W-1:0] a_payload;
  wire                        b_valid, b_ready;
  wire [STREAM_PAYLOAD_W-1:0] b_payload;
  wire [OCC_W-1:0]            occ;
  wire [OCC_W-1:0]            high;

  stream_skid_buffer #(
      .PAYLOAD_W   (STREAM_PAYLOAD_W),
      .DATA_W      (STREAM_DATA_W),
      .STREAM_ID_W (STREAM_ID_W),
      .SEQ_W       (STREAM_SEQ_W),
      .USER_W      (STREAM_USER_W)
  ) u_in_skid (
      .clk (clk), .rst_n (rst_n),
      .s_valid (s_valid), .s_ready (s_ready), .s_payload (s_payload),
      .m_valid (a_valid), .m_ready (a_ready), .m_payload (a_payload)
  );

  sync_fifo #(
      .WIDTH   (STREAM_PAYLOAD_W),
      .DEPTH   (TELEM_FIFO_DEPTH),
      .STORAGE ("regs")
  ) u_fifo (
      .clk              (clk),
      .rst_n            (rst_n),
      .s_valid          (a_valid),
      .s_ready          (a_ready),
      .s_data           (a_payload),
      .m_valid          (b_valid),
      .m_ready          (b_ready),
      .m_data           (b_payload),
      .occupancy        (occ),
      .full             (fifo_full),
      .empty            (fifo_empty),
      .almost_full      (fifo_almost_full),
      .almost_empty     (fifo_almost_empty),
      .high_water       (high),
      .overflow_sticky  (fifo_overflow_sticky),
      .underflow_sticky (fifo_underflow_sticky),
      // The FIFO's own high-water mark is cleared by the same strobe that
      // clears telemetry's, so the two trackers stay comparable across a clear.
      .sticky_clear     (obs_counter_clear)
  );

  stream_skid_buffer #(
      .PAYLOAD_W   (STREAM_PAYLOAD_W),
      .DATA_W      (STREAM_DATA_W),
      .STREAM_ID_W (STREAM_ID_W),
      .SEQ_W       (STREAM_SEQ_W),
      .USER_W      (STREAM_USER_W)
  ) u_out_skid (
      .clk (clk), .rst_n (rst_n),
      .s_valid (b_valid), .s_ready (b_ready), .s_payload (b_payload),
      .m_valid (m_valid), .m_ready (m_ready), .m_payload (m_payload)
  );

  assign fifo_occupancy  = 8'(occ);
  assign fifo_high_water = 8'(high);

  // ---------------------------------------------------------------------------
  // The observed interface, decoded once
  // ---------------------------------------------------------------------------
  // Field offsets from stream_pkg's accessors, never from a hand-written
  // concatenation — the package's rule, and these six functions are the
  // normative statement of the layout that every consumer resolves through.
  //
  // The four fields telemetry needs are extracted individually rather than by
  // calling stream_unpack(): telemetry never looks at `data` or `user`, and an
  // unpack would produce two fields nothing reads, which
  // `verilator --lint-only --Wall` reports as unused bits and this project does
  // not waive.
  localparam int unsigned SOF_LSB = int'(stream_pkg::stream_sof_lsb(GEOM));
  localparam int unsigned EOF_LSB = int'(stream_pkg::stream_eof_lsb(GEOM));
  localparam int unsigned ID_LSB  = int'(stream_pkg::stream_id_lsb(GEOM));
  localparam int unsigned SEQ_LSB = int'(stream_pkg::stream_seq_lsb(GEOM));

  wire                    m_sof = m_payload[SOF_LSB];
  wire                    m_eof = m_payload[EOF_LSB];
  wire [STREAM_ID_W-1:0]  m_id  = m_payload[ID_LSB  +: STREAM_ID_W];
  wire [STREAM_SEQ_W-1:0] m_sq  = m_payload[SEQ_LSB +: STREAM_SEQ_W];

  wire dp_beat = m_valid && m_ready;

  assign obs_beat  =  m_valid &&  m_ready;
  assign obs_stall =  m_valid && !m_ready;
  assign obs_idle  = !m_valid &&  m_ready;

  // ---------------------------------------------------------------------------
  // Sequence checker, with the stimulus override described in the header
  // ---------------------------------------------------------------------------
  wire                    chk_beat = sq_override ? sq_beat      : dp_beat;
  wire [STREAM_ID_W-1:0]  chk_id   = sq_override ? sq_stream_id : m_id;
  wire [STREAM_SEQ_W-1:0] chk_seq  = sq_override ? sq_seq       : m_sq;
  wire                    chk_sof  = sq_override ? sq_sof       : m_sof;

  // The checker's shadows. They go nowhere but telemetry_block, which is the
  // point: the register plane reads a frozen value, never a running one.
  wire [TELEM_COUNT_W-1:0] seq_snap_gap;
  wire [TELEM_COUNT_W-1:0] seq_snap_lost;
  wire [TELEM_COUNT_W-1:0] seq_snap_dup;
  wire [TELEM_COUNT_W-1:0] seq_snap_reorder;
  wire [TELEM_COUNT_W-1:0] seq_snap_untracked;

  seq_checker #(
      .SEQ_W (STREAM_SEQ_W),
      .ID_W  (STREAM_ID_W),
      .N_IDS (TELEM_TRACKED_IDS),
      .CNT_W (TELEM_COUNT_W)
  ) u_seq (
      .clk            (clk),
      .rst_n          (rst_n),
      .enable         (obs_seq_enable),
      .sof_resync     (obs_seq_sof_resync),
      .beat           (chk_beat),
      .stream_id      (chk_id),
      .seq            (chk_seq),
      .sof            (chk_sof),
      .sticky_clear   (obs_sticky_clear),
      .count_clear    (obs_counter_clear),
      .snapshot       (obs_snapshot_strobe),
      .err_gap        (sq_err_gap),
      .err_dup        (sq_err_dup),
      .err_reorder    (sq_err_reorder),
      .err_untracked  (sq_err_untracked),
      .gap_size       (sq_gap_size),
      .sticky         (sq_sticky),
      .cnt_gap        (sq_cnt_gap),
      .cnt_lost       (sq_cnt_lost),
      .cnt_dup        (sq_cnt_dup),
      .cnt_reorder    (sq_cnt_reorder),
      .cnt_untracked  (sq_cnt_untracked),
      .snap_gap       (seq_snap_gap),
      .snap_lost      (seq_snap_lost),
      .snap_dup       (seq_snap_dup),
      .snap_reorder   (seq_snap_reorder),
      .snap_untracked (seq_snap_untracked),
      .snap_valid     (sq_snap_valid),
      .counts_saturate_event (sq_counts_saturate_event),
      .counts_saturated      (sq_counts_saturated)
  );

  // ---------------------------------------------------------------------------
  // Register fabric — one block, the SPEC 9 counters window
  // ---------------------------------------------------------------------------
  wire [0:0]            blk_sel;
  wire                  blk_we;
  wire                  blk_re;
  wire [IDX_W-1:0]      blk_index;
  wire [REG_DATA_W-1:0] blk_wdata;
  wire [REG_STRB_W-1:0] blk_be;
  wire [REG_DATA_W-1:0] blk_rdata;
  wire                  blk_ready;
  wire                  blk_error;

  reg_fabric #(
      .N_BLOCKS   (1),
      .WINDOW_W   (REGMAP_WINDOW_W),
      .BLOCK_BASE (REGMAP_COUNTERS_BASE)
  ) u_fabric (
      .clk              (clk),
      .rst_n            (rst_n),
      .address          (address),
      .write_data       (write_data),
      .byte_enable      (byte_enable),
      .write_enable     (write_enable),
      .read_enable      (read_enable),
      .read_data        (read_data),
      .ready            (ready),
      .error            (error),
      .blk_sel          (blk_sel),
      .blk_write_enable (blk_we),
      .blk_read_enable  (blk_re),
      .blk_index        (blk_index),
      .blk_write_data   (blk_wdata),
      .blk_byte_enable  (blk_be),
      .blk_read_data    (blk_rdata),
      .blk_ready        (blk_ready),
      .blk_error        (blk_error)
  );

  wire [OCC_W-1:0] live_hwm;

  telemetry_block #(
      .IDX_W            (IDX_W),
      .COUNT_W          (TELEM_COUNT_W),
      .WIDE_W           (TELEM_WIDE_W),
      .LEVEL_W          (OCC_W),
      .FIFO_DEPTH       (TELEM_FIFO_DEPTH),
      .N_TRACKED_IDS    (TELEM_TRACKED_IDS),
      .TRAFFIC_SATURATE (1'b0),
      .ERROR_SATURATE   (1'b1)
  ) u_telemetry (
      .clk          (clk),
      .rst_n        (rst_n),
      .sel          (blk_sel[0]),
      .write_enable (blk_we),
      .read_enable  (blk_re),
      .index        (blk_index),
      .write_data   (blk_wdata),
      .byte_enable  (blk_be),
      .read_data    (blk_rdata),
      .ready        (blk_ready),
      .error        (blk_error),
      .csr          (obs_counters_csr),
      .pulse        (obs_counters_pulse),

      .obs_valid    (m_valid),
      .obs_ready    (m_ready),
      .obs_sof      (m_sof),
      .obs_eof      (m_eof),

      .fifo_level          (occ),
      .fifo_overflow_event (inj_overflow),
      .saturate_event      (inj_saturate),
      .cdc_error_event     (inj_cdc_error),

      .seq_gap_event       (sq_err_gap),
      .seq_dup_event       (sq_err_dup),
      .seq_reorder_event   (sq_err_reorder),
      .seq_untracked_event (sq_err_untracked),
      .seq_gap_count       (seq_snap_gap),
      .seq_lost_count      (seq_snap_lost),
      .seq_dup_count       (seq_snap_dup),
      .seq_reorder_count   (seq_snap_reorder),
      .seq_untracked_count (seq_snap_untracked),
      .seq_sticky          (sq_sticky),

      .snapshot_strobe (obs_snapshot_strobe),
      .counter_clear   (obs_counter_clear),
      .sticky_clear    (obs_sticky_clear),
      .count_enable    (obs_count_enable),
      .seq_enable      (obs_seq_enable),
      .seq_sof_resync  (obs_seq_sof_resync),

      .live_beat_count        (live_beat_count),
      .live_stall_count       (live_stall_count),
      .live_idle_count        (live_idle_count),
      .live_frame_count       (live_frame_count),
      .live_frame_start_count (live_frame_start_count),
      .live_overflow_count    (live_overflow_count),
      .live_saturate_count    (live_saturate_count),
      .live_cdc_error_count   (live_cdc_error_count),
      .live_snapshot_id       (live_snapshot_id),
      .live_fifo_high_water   (live_hwm)
  );

  assign live_fifo_high_water = 8'(live_hwm);

  // ---------------------------------------------------------------------------
  // Narrow counter probes (SPEC 13.4)
  //
  // Eight bits wide so a test wraps them in three hundred events rather than in
  // four billion. Wrap is not an exotic condition to be reasoned about: at this
  // width it is reachable in a directed test, in every seed, in milliseconds.
  // The three cover the three things that can differ at the boundary — modulo
  // arithmetic, saturating arithmetic, and an increment larger than one, which
  // is the case where the boundary can be crossed without ever landing on it.
  // ---------------------------------------------------------------------------
  perf_counter #(
      .WIDTH (TELEM_PROBE_W), .INCR_W (1), .SATURATE (1'b0)
  ) u_pc_wrap (
      .clk (clk), .rst_n (rst_n), .enable (pc_enable),
      .event_i (pc_event), .incr (1'b1),
      .clear (pc_clear), .snapshot (pc_snapshot),
      .count (pcw_count), .snap (pcw_snap), .snap_valid (pcw_snap_valid),
      .wrap_pulse (pcw_wrap_pulse), .wrapped (pcw_wrapped)
  );

  perf_counter #(
      .WIDTH (TELEM_PROBE_W), .INCR_W (1), .SATURATE (1'b1)
  ) u_pc_sat (
      .clk (clk), .rst_n (rst_n), .enable (pc_enable),
      .event_i (pc_event), .incr (1'b1),
      .clear (pc_clear), .snapshot (pc_snapshot),
      .count (pcs_count), .snap (pcs_snap), .snap_valid (pcs_snap_valid),
      .wrap_pulse (pcs_wrap_pulse), .wrapped (pcs_wrapped)
  );

  perf_counter #(
      .WIDTH (TELEM_PROBE_W), .INCR_W (TELEM_PROBE_INCR_W), .SATURATE (1'b0)
  ) u_pc_incr (
      .clk (clk), .rst_n (rst_n), .enable (pc_enable),
      .event_i (pc_event), .incr (pc_incr),
      .clear (pc_clear), .snapshot (pc_snapshot),
      .count (pci_count), .snap (pci_snap), .snap_valid (pci_snap_valid),
      .wrap_pulse (pci_wrap_pulse), .wrapped (pci_wrapped)
  );

  // ---------------------------------------------------------------------------
  // Elaboration-time agreement between the protocol definition, the register map
  // and the generated configuration. Same device as control_top and
  // benchmark_sim_top: two independently maintained definitions that disagree
  // must fail at time 0 by name, not at cycle 40000 as a decode mystery.
  // ---------------------------------------------------------------------------
`ifndef SYNTHESIS
  initial begin
    if (REGMAP_ADDR_W != REG_ADDR_W) begin
      $fatal(1, "telemetry_top: regmap address width %0d != reg_if_pkg REG_ADDR_W %0d",
             REGMAP_ADDR_W, REG_ADDR_W);
    end
    if (int'(STREAM_PAYLOAD_W) != int'(stream_pkg::stream_payload_w(GEOM))) begin
      $fatal(1, "telemetry_top: config/stream_pkg layout drift: STREAM_PAYLOAD_W=%0d, package says %0d",
             STREAM_PAYLOAD_W, int'(stream_pkg::stream_payload_w(GEOM)));
    end
    if (TELEM_TRACKED_IDS >= (1 << STREAM_ID_W)) begin
      $fatal(1, "telemetry_top: TELEM_TRACKED_IDS=%0d leaves no untracked stream_id to test with (ID_W=%0d)",
             TELEM_TRACKED_IDS, STREAM_ID_W);
    end
  end
`endif

endmodule : telemetry_top

`default_nettype wire
