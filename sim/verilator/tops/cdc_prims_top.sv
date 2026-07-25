// -----------------------------------------------------------------------------
// cdc_prims_top — per-primitive unit-test top for rtl/cdc/ and rtl/common/
// sync_fifo.sv (SPEC 13.1, SPEC 12.3).
//
// SPEC 13.1 requires every module to have directed, boundary, randomized, reset
// and stall tests plus protocol assertions. This top exposes every primitive
// issue #6 delivers as an independent DUT so that one binary, one seed and one
// multi-clock scheduler cover all of them, and so a failure names the primitive
// that failed rather than "the CDC test".
//
//   fifo0   sync_fifo    DEPTH=8, registered output, STORAGE="regs"
//   fifo1   sync_fifo    DEPTH=4, show-ahead,        STORAGE="mlab"
//   afifo   async_fifo   clk_a -> clk_b, registered output, STORAGE="m20k"
//   scdc_f  stream_cdc   clk_a -> clk_b, full SPEC 5 geometry
//   scdc_r  stream_cdc   clk_b -> clk_a, the reverse direction
//   pulse   cdc_pulse    clk_a -> clk_b
//   hshake  cdc_handshake clk_a -> clk_b
//   sync    cdc_sync2    clk_a -> clk_b, one status bit
//
// The DUTs share only the two clocks and the two resets, so a defect cannot
// propagate between them and each one's stall pattern is independent. Both
// directions of stream_cdc are instantiated deliberately: a crossing whose
// source is the fast domain and one whose source is the slow domain exercise
// opposite sides of the flag staleness, and a sweep over clock ratios covers
// both with one set of instances rather than by running the suite twice.
//
// TWO CLOCKS, NOT SIX. SPEC 8 defines six logical domains; this top uses two,
// named `clk_a` and `clk_b` rather than after any SPEC 8 domain, because the
// property under test is the crossing itself and the test sweeps the ratio
// between them — 1:1 in phase, 1:1 out of phase, 2:1, 1:2, 7:3, 3:7, 100:99 —
// rather than any one nominal frequency pair. Instantiating the six named
// domains here would fix the ratios at exactly the six values least likely to
// expose a pointer-synchronizer defect.
//
// Payload transport for the two stream crossings is the packed vector, and the
// geometry is passed down so their protocol checkers decode frame boundaries and
// sequence numbers as well as checking stability.
//
// Simulation-only. Never synthesized, never listed in a Quartus source list.
// -----------------------------------------------------------------------------

`default_nettype none

module cdc_prims_top
  import config_pkg::*;
(
    // ---- two asynchronous clock domains ----
    input  logic                        clk_a,
    input  logic                        rst_a_n,
    input  logic                        clk_b,
    input  logic                        rst_b_n,

    // ---- fifo0: sync_fifo, registered output, in domain A ----
    input  logic                        f0_s_valid,
    output logic                        f0_s_ready,
    input  logic [STREAM_PAYLOAD_W-1:0] f0_s_data,
    output logic                        f0_m_valid,
    input  logic                        f0_m_ready,
    output logic [STREAM_PAYLOAD_W-1:0] f0_m_data,
    output logic [7:0]                  f0_occ,
    output logic [7:0]                  f0_high,
    output logic                        f0_full,
    output logic                        f0_empty,
    output logic                        f0_almost_full,
    output logic                        f0_almost_empty,
    output logic                        f0_overflow,
    output logic                        f0_underflow,
    input  logic                        f0_sticky_clear,

    // ---- fifo1: sync_fifo, show-ahead, in domain A ----
    input  logic                        f1_s_valid,
    output logic                        f1_s_ready,
    input  logic [STREAM_PAYLOAD_W-1:0] f1_s_data,
    output logic                        f1_m_valid,
    input  logic                        f1_m_ready,
    output logic [STREAM_PAYLOAD_W-1:0] f1_m_data,
    output logic [7:0]                  f1_occ,
    output logic [7:0]                  f1_high,
    output logic                        f1_full,
    output logic                        f1_empty,
    output logic                        f1_almost_full,
    output logic                        f1_almost_empty,
    output logic                        f1_overflow,
    output logic                        f1_underflow,

    // ---- afifo: async_fifo, A -> B ----
    input  logic                        af_wr_valid,
    output logic                        af_wr_ready,
    input  logic [STREAM_PAYLOAD_W-1:0] af_wr_data,
    output logic                        af_wr_full,
    output logic                        af_wr_almost_full,
    output logic [7:0]                  af_wr_occ,
    output logic [7:0]                  af_wr_high,
    output logic                        af_wr_overflow,
    input  logic                        af_wr_sticky_clear,
    output logic                        af_rd_valid,
    input  logic                        af_rd_ready,
    output logic [STREAM_PAYLOAD_W-1:0] af_rd_data,
    output logic                        af_rd_empty,
    output logic [7:0]                  af_rd_occ,
    output logic [7:0]                  af_rd_high,
    output logic                        af_rd_underflow,
    input  logic                        af_rd_sticky_clear,

    // ---- scdc_f: stream_cdc, A -> B ----
    input  logic                        cf_s_valid,
    output logic                        cf_s_ready,
    input  logic [STREAM_PAYLOAD_W-1:0] cf_s_payload,
    output logic [7:0]                  cf_s_occ,
    output logic [7:0]                  cf_s_high,
    output logic                        cf_s_almost_full,
    output logic                        cf_m_valid,
    input  logic                        cf_m_ready,
    output logic [STREAM_PAYLOAD_W-1:0] cf_m_payload,
    output logic [7:0]                  cf_m_occ,
    output logic [7:0]                  cf_m_high,

    // ---- scdc_r: stream_cdc, B -> A ----
    input  logic                        cr_s_valid,
    output logic                        cr_s_ready,
    input  logic [STREAM_PAYLOAD_W-1:0] cr_s_payload,
    output logic                        cr_m_valid,
    input  logic                        cr_m_ready,
    output logic [STREAM_PAYLOAD_W-1:0] cr_m_payload,

    // ---- pulse: cdc_pulse, A -> B ----
    input  logic                        pl_src_pulse,
    output logic                        pl_src_busy,
    output logic                        pl_src_overrun,
    input  logic                        pl_src_sticky_clear,
    output logic                        pl_dst_pulse,

    // ---- hshake: cdc_handshake, A -> B ----
    input  logic                        hs_s_valid,
    output logic                        hs_s_ready,
    input  logic [CDC_HANDSHAKE_W-1:0]  hs_s_data,
    output logic                        hs_s_busy,
    output logic                        hs_d_valid,
    output logic [CDC_HANDSHAKE_W-1:0]  hs_d_data,

    // ---- sync: cdc_sync2, A -> B, one status bit ----
    input  logic                        sy_d,
    output logic                        sy_q
);

  localparam int unsigned SF_DEPTH    = CDC_SYNC_FIFO_DEPTH;
  localparam int unsigned SF_SA_DEPTH = CDC_SYNC_FIFO_SA_DEPTH;
  localparam int unsigned AF_DEPTH    = CDC_ASYNC_FIFO_DEPTH;
  localparam int unsigned SC_DEPTH    = CDC_STREAM_CDC_DEPTH;
  localparam int unsigned STAGES      = CDC_SYNC_STAGES;

  // Narrow status vectors, widened to a byte for the C++ harness exactly as
  // stream_prims_top does, so the harness never has to know a $clog2 width.
  wire [$clog2(SF_DEPTH+1)-1:0]    f0_occ_raw, f0_high_raw;
  wire [$clog2(SF_SA_DEPTH+1)-1:0] f1_occ_raw, f1_high_raw;
  wire [$clog2(AF_DEPTH+1)-1:0]    af_wr_occ_raw, af_wr_high_raw;
  wire [$clog2(AF_DEPTH+1)-1:0]    af_rd_occ_raw, af_rd_high_raw;
  wire [$clog2(SC_DEPTH+1)-1:0]    cf_s_occ_raw, cf_s_high_raw;
  wire [$clog2(SC_DEPTH+1)-1:0]    cf_m_occ_raw, cf_m_high_raw;

  assign f0_occ     = 8'(f0_occ_raw);
  assign f0_high    = 8'(f0_high_raw);
  assign f1_occ     = 8'(f1_occ_raw);
  assign f1_high    = 8'(f1_high_raw);
  assign af_wr_occ  = 8'(af_wr_occ_raw);
  assign af_wr_high = 8'(af_wr_high_raw);
  assign af_rd_occ  = 8'(af_rd_occ_raw);
  assign af_rd_high = 8'(af_rd_high_raw);
  assign cf_s_occ   = 8'(cf_s_occ_raw);
  assign cf_s_high  = 8'(cf_s_high_raw);
  assign cf_m_occ   = 8'(cf_m_occ_raw);
  assign cf_m_high  = 8'(cf_m_high_raw);

  // ---------------------------------------------------------------------------
  // fifo0 — the default synchronous FIFO: registered output, ALM storage.
  // ---------------------------------------------------------------------------
  sync_fifo #(
      .WIDTH                  (STREAM_PAYLOAD_W),
      .DEPTH                  (SF_DEPTH),
      .ALMOST_FULL_THRESHOLD  (SF_DEPTH - 2),
      .ALMOST_EMPTY_THRESHOLD (1),
      .SHOW_AHEAD             (1'b0),
      .STORAGE                ("regs")
  ) u_fifo0 (
      .clk              (clk_a),
      .rst_n            (rst_a_n),
      .s_valid          (f0_s_valid),
      .s_ready          (f0_s_ready),
      .s_data           (f0_s_data),
      .m_valid          (f0_m_valid),
      .m_ready          (f0_m_ready),
      .m_data           (f0_m_data),
      .occupancy        (f0_occ_raw),
      .full             (f0_full),
      .empty            (f0_empty),
      .almost_full      (f0_almost_full),
      .almost_empty     (f0_almost_empty),
      .high_water       (f0_high_raw),
      .overflow_sticky  (f0_overflow),
      .underflow_sticky (f0_underflow),
      .sticky_clear     (f0_sticky_clear)
  );

  // ---------------------------------------------------------------------------
  // fifo1 — show-ahead, MLAB storage, shallow. Exercises the zero-latency path
  // and the second storage style.
  // ---------------------------------------------------------------------------
  sync_fifo #(
      .WIDTH                  (STREAM_PAYLOAD_W),
      .DEPTH                  (SF_SA_DEPTH),
      .ALMOST_FULL_THRESHOLD  (SF_SA_DEPTH - 1),
      .ALMOST_EMPTY_THRESHOLD (1),
      .SHOW_AHEAD             (1'b1),
      .STORAGE                ("mlab")
  ) u_fifo1 (
      .clk              (clk_a),
      .rst_n            (rst_a_n),
      .s_valid          (f1_s_valid),
      .s_ready          (f1_s_ready),
      .s_data           (f1_s_data),
      .m_valid          (f1_m_valid),
      .m_ready          (f1_m_ready),
      .m_data           (f1_m_data),
      .occupancy        (f1_occ_raw),
      .full             (f1_full),
      .empty            (f1_empty),
      .almost_full      (f1_almost_full),
      .almost_empty     (f1_almost_empty),
      .high_water       (f1_high_raw),
      .overflow_sticky  (f1_overflow),
      .underflow_sticky (f1_underflow),
      .sticky_clear     (1'b0)
  );

  // ---------------------------------------------------------------------------
  // afifo — the asynchronous FIFO in the raw, without the stream wrapper, so the
  // FIFO's own flags and occupancy estimates are observable directly.
  // STORAGE="m20k" also proves the elaboration rule that it implies OUT_REG.
  // ---------------------------------------------------------------------------
  async_fifo #(
      .WIDTH                 (STREAM_PAYLOAD_W),
      .DEPTH                 (AF_DEPTH),
      .SYNC_STAGES           (STAGES),
      .OUT_REG               (1'b1),
      .STORAGE               ("m20k"),
      .ALMOST_FULL_THRESHOLD (AF_DEPTH - 2)
  ) u_afifo (
      .wr_clk              (clk_a),
      .wr_rst_n            (rst_a_n),
      .wr_valid            (af_wr_valid),
      .wr_ready            (af_wr_ready),
      .wr_data             (af_wr_data),
      .wr_full             (af_wr_full),
      .wr_almost_full      (af_wr_almost_full),
      .wr_occupancy        (af_wr_occ_raw),
      .wr_high_water       (af_wr_high_raw),
      .wr_overflow_sticky  (af_wr_overflow),
      .wr_sticky_clear     (af_wr_sticky_clear),
      .rd_clk              (clk_b),
      .rd_rst_n            (rst_b_n),
      .rd_valid            (af_rd_valid),
      .rd_ready            (af_rd_ready),
      .rd_data             (af_rd_data),
      .rd_empty            (af_rd_empty),
      .rd_occupancy        (af_rd_occ_raw),
      .rd_high_water       (af_rd_high_raw),
      .rd_underflow_sticky (af_rd_underflow),
      .rd_sticky_clear     (af_rd_sticky_clear)
  );

  // ---------------------------------------------------------------------------
  // scdc_f — SPEC 5 stream crossing, A -> B, with the full field geometry so
  // both protocol checkers run the framing and sequence-continuity checks.
  // ---------------------------------------------------------------------------
  wire cf_overflow_unused;
  wire cf_underflow_unused;

  stream_cdc #(
      .PAYLOAD_W             (STREAM_PAYLOAD_W),
      .DEPTH                 (SC_DEPTH),
      .SYNC_STAGES           (STAGES),
      .OUT_REG               (1'b1),
      .STORAGE               ("regs"),
      .ALMOST_FULL_THRESHOLD (SC_DEPTH - 4),
      .DATA_W                (STREAM_DATA_W),
      .STREAM_ID_W           (STREAM_ID_W),
      .SEQ_W                 (STREAM_SEQ_W),
      .USER_W                (STREAM_USER_W)
  ) u_scdc_f (
      .s_clk              (clk_a),
      .s_rst_n            (rst_a_n),
      .s_valid            (cf_s_valid),
      .s_ready            (cf_s_ready),
      .s_payload          (cf_s_payload),
      .s_occupancy        (cf_s_occ_raw),
      .s_high_water       (cf_s_high_raw),
      .s_almost_full      (cf_s_almost_full),
      .s_overflow_sticky  (cf_overflow_unused),
      .s_sticky_clear     (1'b0),
      .m_clk              (clk_b),
      .m_rst_n            (rst_b_n),
      .m_valid            (cf_m_valid),
      .m_ready            (cf_m_ready),
      .m_payload          (cf_m_payload),
      .m_occupancy        (cf_m_occ_raw),
      .m_high_water       (cf_m_high_raw),
      .m_underflow_sticky (cf_underflow_unused),
      .m_sticky_clear     (1'b0)
  );

  // ---------------------------------------------------------------------------
  // scdc_r — the same crossing in the opposite direction, so whichever clock the
  // ratio sweep makes the fast one, some instance has its source there.
  // ---------------------------------------------------------------------------
  wire [$clog2(SC_DEPTH+1)-1:0] cr_s_occ_unused, cr_s_high_unused;
  wire [$clog2(SC_DEPTH+1)-1:0] cr_m_occ_unused, cr_m_high_unused;
  wire cr_almost_full_unused;
  wire cr_overflow_unused;
  wire cr_underflow_unused;

  stream_cdc #(
      .PAYLOAD_W             (STREAM_PAYLOAD_W),
      .DEPTH                 (SC_DEPTH),
      .SYNC_STAGES           (STAGES),
      .OUT_REG               (1'b0),          // show-ahead read side
      .STORAGE               ("mlab"),
      .ALMOST_FULL_THRESHOLD (SC_DEPTH - 4),
      .DATA_W                (STREAM_DATA_W),
      .STREAM_ID_W           (STREAM_ID_W),
      .SEQ_W                 (STREAM_SEQ_W),
      .USER_W                (STREAM_USER_W)
  ) u_scdc_r (
      .s_clk              (clk_b),
      .s_rst_n            (rst_b_n),
      .s_valid            (cr_s_valid),
      .s_ready            (cr_s_ready),
      .s_payload          (cr_s_payload),
      .s_occupancy        (cr_s_occ_unused),
      .s_high_water       (cr_s_high_unused),
      .s_almost_full      (cr_almost_full_unused),
      .s_overflow_sticky  (cr_overflow_unused),
      .s_sticky_clear     (1'b0),
      .m_clk              (clk_a),
      .m_rst_n            (rst_a_n),
      .m_valid            (cr_m_valid),
      .m_ready            (cr_m_ready),
      .m_payload          (cr_m_payload),
      .m_occupancy        (cr_m_occ_unused),
      .m_high_water       (cr_m_high_unused),
      .m_underflow_sticky (cr_underflow_unused),
      .m_sticky_clear     (1'b0)
  );

  // ---------------------------------------------------------------------------
  // pulse — toggle synchronizer with busy and overrun.
  // ---------------------------------------------------------------------------
  cdc_pulse #(
      .SYNC_STAGES (STAGES)
  ) u_pulse (
      .src_clk          (clk_a),
      .src_rst_n        (rst_a_n),
      .src_pulse        (pl_src_pulse),
      .src_busy         (pl_src_busy),
      .src_overrun      (pl_src_overrun),
      .src_sticky_clear (pl_src_sticky_clear),
      .dst_clk          (clk_b),
      .dst_rst_n        (rst_b_n),
      .dst_pulse        (pl_dst_pulse)
  );

  // ---------------------------------------------------------------------------
  // hshake — four-phase multibit handshake.
  // ---------------------------------------------------------------------------
  cdc_handshake #(
      .WIDTH       (CDC_HANDSHAKE_W),
      .SYNC_STAGES (STAGES)
  ) u_hshake (
      .src_clk   (clk_a),
      .src_rst_n (rst_a_n),
      .s_valid   (hs_s_valid),
      .s_ready   (hs_s_ready),
      .s_data    (hs_s_data),
      .s_busy    (hs_s_busy),
      .dst_clk   (clk_b),
      .dst_rst_n (rst_b_n),
      .d_valid   (hs_d_valid),
      .d_data    (hs_d_data)
  );

  // ---------------------------------------------------------------------------
  // sync — a bare single-bit status synchronizer, the SPEC 8 "proper
  // synchronizer for single-bit status".
  // ---------------------------------------------------------------------------
  cdc_sync2 #(
      .WIDTH      (1),
      .STAGES     (STAGES),
      .RST_VALUE  (1'b0),
      .GRAY_CODED (1'b0)
  ) u_sync (
      .clk   (clk_b),
      .rst_n (rst_b_n),
      .d     (sy_d),
      .q     (sy_q)
  );

  // ---------------------------------------------------------------------------
  // Slave-side protocol checkers on the two synchronous FIFOs. These watch the
  // C++ driver rather than the RTL: a harness that violates the protocol it is
  // testing for would otherwise be invisible. The stream crossings already carry
  // a checker on each side inside stream_cdc.
  // ---------------------------------------------------------------------------
`ifndef SYNTHESIS
  stream_protocol_checker #(
      .PAYLOAD_W   (STREAM_PAYLOAD_W),
      .DATA_W      (STREAM_DATA_W),
      .STREAM_ID_W (STREAM_ID_W),
      .SEQ_W       (STREAM_SEQ_W),
      .USER_W      (STREAM_USER_W)
  ) u_chk_f0_s (
      .clk (clk_a), .rst_n (rst_a_n),
      .valid (f0_s_valid), .ready (f0_s_ready), .payload (f0_s_data)
  );

  stream_protocol_checker #(
      .PAYLOAD_W   (STREAM_PAYLOAD_W),
      .DATA_W      (STREAM_DATA_W),
      .STREAM_ID_W (STREAM_ID_W),
      .SEQ_W       (STREAM_SEQ_W),
      .USER_W      (STREAM_USER_W)
  ) u_chk_f0_m (
      .clk (clk_a), .rst_n (rst_a_n),
      .valid (f0_m_valid), .ready (f0_m_ready), .payload (f0_m_data)
  );

  stream_protocol_checker #(
      .PAYLOAD_W   (STREAM_PAYLOAD_W),
      .DATA_W      (STREAM_DATA_W),
      .STREAM_ID_W (STREAM_ID_W),
      .SEQ_W       (STREAM_SEQ_W),
      .USER_W      (STREAM_USER_W)
  ) u_chk_f1_m (
      .clk (clk_a), .rst_n (rst_a_n),
      .valid (f1_m_valid), .ready (f1_m_ready), .payload (f1_m_data)
  );
`endif

endmodule : cdc_prims_top

`default_nettype wire
