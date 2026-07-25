// -----------------------------------------------------------------------------
// stream_protocol_checker — the SPEC 5 / SPEC 14 protocol checker as a module.
//
// Wraps the property set in sim/assertions/stream_sva.svh so it can be attached
// to any stream interface in the design by either mechanism:
//
//   instantiation   every primitive in rtl/stream/ instantiates one on its
//                   master interface inside `ifndef SYNTHESIS`, so a design
//                   built from the primitives is checked everywhere by
//                   construction, in the SPEC 12.1 fast build, with no test-side
//                   wiring.
//
//   bind            for a stage whose source you do not want to touch:
//                       bind <module> stream_protocol_checker #(...) u (...);
//                   Verified working under Verilator 5.020, including the
//                   concurrent properties (DECISIONS.md 2026-07-26 decision 3);
//                   sim/verilator/tops/stream_violator_top.sv is the worked
//                   example, and it is the negative test's mechanism.
//
// Geometry is optional. With DATA_W left at 0 the checker knows only that the
// payload is PAYLOAD_W opaque bits and runs the payload-agnostic properties —
// which is the right contract for a primitive parameterised on payload width
// alone. Give it the four field widths and it additionally decodes
// start_of_frame / end_of_frame / stream_id / seq through stream_pkg's offset
// functions and runs the framing and sequence-continuity checks.
//
// This module contains no functional logic and drives nothing. It is
// simulation-only: it is never listed in a Quartus source list, and every
// instantiation of it in design RTL sits inside `ifndef SYNTHESIS`.
// -----------------------------------------------------------------------------

`default_nettype none

`include "stream_sva.svh"

module stream_protocol_checker #(
    // Width of the packed payload vector being observed.
    parameter int unsigned PAYLOAD_W   = 8,

    // Field geometry. DATA_W == 0 means "unknown": the framing and sequence
    // checks are then omitted and only the payload-agnostic properties run.
    parameter int unsigned DATA_W      = 0,
    parameter int unsigned STREAM_ID_W = 0,
    parameter int unsigned SEQ_W       = 0,
    parameter int unsigned USER_W      = 0
) (
    input  wire                 clk,
    input  wire                 rst_n,
    input  wire                 valid,
    input  wire                 ready,
    input  wire [PAYLOAD_W-1:0] payload
);

  // Payload-agnostic protocol properties: stability under stall, valid never
  // withdrawn, validity cleared by reset, no X while valid.
  `STREAM_SVA_HANDSHAKE(clk, rst_n, valid, ready, payload)

  localparam int unsigned CHECK_FIELDS = (DATA_W != 0) ? 1 : 0;

  localparam stream_pkg::stream_geom_t GEOM =
      stream_pkg::stream_geom(DATA_W, STREAM_ID_W, SEQ_W, USER_W);

  // Elaboration-time contract: a checker given a geometry must have been given
  // the geometry of the interface it is watching. A mismatch here means some
  // instance is decoding the wrong bits, which would otherwise show up as a
  // baffling sequence-discontinuity failure.
`ifndef SYNTHESIS
  initial begin
    if (CHECK_FIELDS != 0) begin
      if (!stream_pkg::stream_geom_ok(GEOM)) begin
        $fatal(1, "stream_protocol_checker: geometry out of range (data_w=%0d id_w=%0d seq_w=%0d user_w=%0d)",
               DATA_W, STREAM_ID_W, SEQ_W, USER_W);
      end
      if (int'(stream_pkg::stream_payload_w(GEOM)) != int'(PAYLOAD_W)) begin
        $fatal(1, "stream_protocol_checker: PAYLOAD_W=%0d but the geometry packs to %0d bits",
               PAYLOAD_W, int'(stream_pkg::stream_payload_w(GEOM)));
      end
    end
  end
`endif

  if (CHECK_FIELDS != 0) begin : g_fields
    // Field positions come from stream_pkg's offset functions — the normative
    // definition of the layout. Individual slices rather than a decoded
    // stream_fields_t struct: the checker needs four of the six fields, and an
    // unpacked struct would leave `data` and `user` as dead bits.
    localparam int unsigned EOF_LSB = int'(stream_pkg::stream_eof_lsb(GEOM));
    localparam int unsigned SOF_LSB = int'(stream_pkg::stream_sof_lsb(GEOM));
    localparam int unsigned ID_LSB  = int'(stream_pkg::stream_id_lsb(GEOM));
    localparam int unsigned SEQ_LSB = int'(stream_pkg::stream_seq_lsb(GEOM));

    localparam int unsigned N_ID = 1 << STREAM_ID_W;

    wire                   f_eof = payload[EOF_LSB];
    wire                   f_sof = payload[SOF_LSB];
    wire [STREAM_ID_W-1:0] f_sid = payload[ID_LSB +: STREAM_ID_W];
    wire [SEQ_W-1:0]       f_seq = payload[SEQ_LSB +: SEQ_W];

    `STREAM_SVA_FRAMING(clk, rst_n, valid, ready, f_sof, f_eof, f_sid, f_seq,
                        N_ID, SEQ_W)
  end : g_fields

endmodule : stream_protocol_checker

`default_nettype wire
