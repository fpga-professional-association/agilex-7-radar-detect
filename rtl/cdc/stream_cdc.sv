// -----------------------------------------------------------------------------
// stream_cdc — a SPEC 5 stream crossing between two clock domains (SPEC.md 5, 8).
//
// SPEC 8 requires asynchronous FIFOs for bulk CDC traffic; SPEC 5 requires one
// common streaming interface at every module boundary in the design. This module
// is the intersection: a valid/ready stream in, the same stream out, a different
// clock on each side, and rtl/cdc/async_fifo.sv doing the work.
//
// It exists as its own module rather than as "instantiate async_fifo with
// PAYLOAD_W" for the reasons a named boundary usually exists:
//
//   * the SPEC 5 protocol checker is instantiated on BOTH sides, in the right
//     clock domain each time, so a crossing in the pipeline is protocol-checked
//     on the way in and on the way out with no test-side wiring. The FIFO alone
//     carries opaque bits and cannot do that;
//   * the payload is a stream_pkg-packed vector, and the geometry can be handed
//     down so those checkers decode frame boundaries and sequence numbers rather
//     than only checking stability. A crossing is exactly where a lost or
//     reordered beat first becomes visible, so it is exactly where the framing
//     and sequence-continuity checks earn their keep;
//   * every stream crossing in the design then appears in the SPEC 8 CDC
//     inventory under one name, with one type, at one width — which is what
//     makes the inventory a review artefact rather than a list of FIFOs.
//
// Ordering, loss and duplication: none, by construction. A FIFO is a queue; the
// crossing preserves beat order exactly, and the Gray-pointer flag derivation
// makes it impossible to write into a full FIFO or read from an empty one. The
// multi-clock unit test (sim/tests/test_async_fifo.cpp) proves it across a sweep
// of clock ratios and phase offsets with a transaction-identity scoreboard,
// rather than asserting it here.
//
// Depth: sized by the instantiator against the synchronizer round trip plus the
// burst to absorb. The round trip is roughly 2 x SYNC_STAGES cycles of the
// SLOWER clock, during which the write side cannot see space that the read side
// has freed; a crossing sized only for the burst throttles at exactly the moment
// it matters.
//
// Reset: two domains, the contract stated in async_fifo.sv's header — asserted
// together, released per domain on that domain's own clock, and the FIFO bridges
// the release skew itself.
//
// (* cdc_primitive *) — scripts/cdc_inventory.py reads the attribute block above
// the module keyword to build the SPEC 8 CDC inventory report. This module is
// tagged as well as the async_fifo inside it, deliberately: the inventory then
// shows the crossing at the level a reviewer thinks about it ("this stream
// crosses from s_clk to m_clk, PAYLOAD_W bits wide") as well as at the level the
// synchronizers live at. The script also flags any instantiated module with two
// or more clock ports that carries NO such tag, so an untagged crossing added
// later is a failed inventory rather than a silent omission.
// -----------------------------------------------------------------------------

`default_nettype none

(* cdc_primitive = "stream_cdc", cdc_src_clk = "s_clk", cdc_dst_clk = "m_clk", cdc_width = "PAYLOAD_W", cdc_stages = "SYNC_STAGES" *)
module stream_cdc #(
    // Width of the packed SPEC 5 payload vector. Normally
    // int'(stream_pkg::stream_payload_w(GEOM)) for the instance's geometry.
    parameter int unsigned PAYLOAD_W = 32,

    // Entries in the crossing FIFO. Power of two, minimum 2.
    parameter int unsigned DEPTH = 16,

    parameter int unsigned SYNC_STAGES = 2,

    // Registered read output (default) — see async_fifo.sv.
    parameter bit OUT_REG = 1'b1,

    // Storage geometry: "regs", "mlab" or "m20k".
    parameter string STORAGE = "regs",

    parameter int unsigned ALMOST_FULL_THRESHOLD = (DEPTH > 1) ? (DEPTH - 1) : 1,

    // Optional field geometry for the protocol checkers, exactly as
    // rtl/stream/*.sv take it. DATA_W == 0 means "unknown": the checkers then
    // run only the payload-agnostic properties. Supplying it turns on the frame
    // and sequence-continuity checks on both sides of the crossing.
    parameter int unsigned DATA_W      = 0,
    parameter int unsigned STREAM_ID_W = 0,
    parameter int unsigned SEQ_W       = 0,
    parameter int unsigned USER_W      = 0
) (
    // ---- source domain ----
    input  wire                       s_clk,
    input  wire                       s_rst_n,

    input  wire                       s_valid,
    output wire                       s_ready,
    input  wire [PAYLOAD_W-1:0]       s_payload,

    // Conservative fill as the source side sees it, its sticky maximum, the
    // almost-full flag and the sticky overflow flag. Wired to the register plane
    // (issue #7) and to telemetry (issue #8) by their owning issues.
    output wire [$clog2(DEPTH+1)-1:0] s_occupancy,
    output wire [$clog2(DEPTH+1)-1:0] s_high_water,
    output wire                       s_almost_full,
    output wire                       s_overflow_sticky,
    input  wire                       s_sticky_clear,

    // ---- destination domain ----
    input  wire                       m_clk,
    input  wire                       m_rst_n,

    output wire                       m_valid,
    input  wire                       m_ready,
    output wire [PAYLOAD_W-1:0]       m_payload,

    output wire [$clog2(DEPTH+1)-1:0] m_occupancy,
    output wire [$clog2(DEPTH+1)-1:0] m_high_water,
    output wire                       m_underflow_sticky,
    input  wire                       m_sticky_clear
);

  localparam int unsigned CHECK_FIELDS = (DATA_W != 0) ? 1 : 0;

  localparam stream_pkg::stream_geom_t GEOM =
      stream_pkg::stream_geom(DATA_W, STREAM_ID_W, SEQ_W, USER_W);

`ifndef SYNTHESIS
  initial begin
    if (CHECK_FIELDS != 0) begin
      if (!stream_pkg::stream_geom_ok(GEOM)) begin
        $fatal(1, "stream_cdc: geometry out of range (data_w=%0d id_w=%0d seq_w=%0d user_w=%0d)",
               DATA_W, STREAM_ID_W, SEQ_W, USER_W);
      end
      if (int'(stream_pkg::stream_payload_w(GEOM)) != int'(PAYLOAD_W)) begin
        $fatal(1, "stream_cdc: PAYLOAD_W=%0d but the geometry packs to %0d bits",
               PAYLOAD_W, int'(stream_pkg::stream_payload_w(GEOM)));
      end
    end
  end
`endif

  // Named sinks rather than `()`: an empty pin connection is a lint warning
  // (PINCONNECTEMPTY) and, more usefully, a named wire says which outputs this
  // wrapper deliberately does not export. `wr_full` is subsumed by
  // `s_almost_full` at the default threshold, and `rd_empty` is exactly
  // `!m_valid` on the show-ahead read side, so neither earns a stream port.
  wire fifo_wr_full_unused;
  wire fifo_rd_empty_unused;

  async_fifo #(
      .WIDTH                 (PAYLOAD_W),
      .DEPTH                 (DEPTH),
      .SYNC_STAGES           (SYNC_STAGES),
      .OUT_REG               (OUT_REG),
      .STORAGE               (STORAGE),
      .ALMOST_FULL_THRESHOLD (ALMOST_FULL_THRESHOLD)
  ) u_fifo (
      .wr_clk             (s_clk),
      .wr_rst_n           (s_rst_n),
      .wr_valid           (s_valid),
      .wr_ready           (s_ready),
      .wr_data            (s_payload),
      .wr_full            (fifo_wr_full_unused),
      .wr_almost_full     (s_almost_full),
      .wr_occupancy       (s_occupancy),
      .wr_high_water      (s_high_water),
      .wr_overflow_sticky (s_overflow_sticky),
      .wr_sticky_clear    (s_sticky_clear),

      .rd_clk             (m_clk),
      .rd_rst_n           (m_rst_n),
      .rd_valid           (m_valid),
      .rd_ready           (m_ready),
      .rd_data            (m_payload),
      .rd_empty           (fifo_rd_empty_unused),
      .rd_occupancy       (m_occupancy),
      .rd_high_water      (m_high_water),
      .rd_underflow_sticky(m_underflow_sticky),
      .rd_sticky_clear    (m_sticky_clear)
  );

  // ---------------------------------------------------------------------------
  // SPEC 5 / SPEC 14 protocol checkers, one per domain. The source-side instance
  // watches whatever is feeding the crossing (in a unit test, the harness
  // driver); the destination-side instance watches the crossing's own output.
  // Both are simulation-only.
  // ---------------------------------------------------------------------------
`ifndef SYNTHESIS
  stream_protocol_checker #(
      .PAYLOAD_W   (PAYLOAD_W),
      .DATA_W      (DATA_W),
      .STREAM_ID_W (STREAM_ID_W),
      .SEQ_W       (SEQ_W),
      .USER_W      (USER_W)
  ) u_chk_s (
      .clk     (s_clk),
      .rst_n   (s_rst_n),
      .valid   (s_valid),
      .ready   (s_ready),
      .payload (s_payload)
  );

  stream_protocol_checker #(
      .PAYLOAD_W   (PAYLOAD_W),
      .DATA_W      (DATA_W),
      .STREAM_ID_W (STREAM_ID_W),
      .SEQ_W       (SEQ_W),
      .USER_W      (USER_W)
  ) u_chk_m (
      .clk     (m_clk),
      .rst_n   (m_rst_n),
      .valid   (m_valid),
      .ready   (m_ready),
      .payload (m_payload)
  );
`endif

endmodule : stream_cdc

`default_nettype wire
