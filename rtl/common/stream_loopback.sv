// -----------------------------------------------------------------------------
// stream_loopback — SPEC 5 pass-through built from the canonical primitives.
//
// Governing spec: SPEC.md 5 (Streaming Protocol), SPEC.md 19 Phase 0 ("One
// trivial stream loopback test").
//
// History: issue #2 needed a protocol-correct DUT before any real datapath
// existed, and implemented one with an inline skid stage. Issue #5 replaced that
// implementation with the canonical primitives; the module keeps its name, its
// ports (except the `seq` rename below) and its behaviour, and contains no
// storage element of its own.
//
//     s_* fields --pack--> skid --> elastic(ELASTIC_DEPTH) --> skid --unpack--> m_* fields
//
// Why that chain and not one primitive: it is the smallest arrangement that
// exercises all three properties the harness needs to be able to trust — a
// registered ready on both module faces (the two skids), a real fill level that
// varies under backpressure (the elastic buffer), and a payload that crosses a
// primitive boundary in packed form. It is also the shape every datapath block
// in this design will have: decouple in, buffer, decouple out.
//
// Field ports, not a packed port, are deliberate: this is where the SPEC 12.2
// C++ harness attaches, and the packing is applied and removed here by
// stream_pkg so that the harness sees named fields while everything inside the
// design carries one vector. Verilator cannot pass an interface through a
// top-level port at all (DECISIONS.md 2026-07-26, decision 1), which is the
// measured reason the boundary looks like this.
//
// Field naming: `s_seq` / `m_seq`, not `s_sequence` / `m_sequence`. SPEC 5's
// `sequence` is a SystemVerilog keyword; `seq` is the project-wide spelling
// (DECISIONS.md 2026-07-26, decision 2).
//
// Latency with no backpressure is LATENCY_NO_STALL below — computed from the
// primitives' own exported constants, never written as a number. Under
// backpressure there is no fixed latency and SPEC 12.5 forbids assuming one.
//
// Reset: synchronous, active low, and entirely delegated to the primitives,
// which reset validity and not payload (SPEC 23).
// -----------------------------------------------------------------------------

`default_nettype none

module stream_loopback #(
    parameter int unsigned DATA_W        = 32,
    parameter int unsigned STREAM_ID_W   = 4,
    parameter int unsigned SEQ_W         = 16,
    parameter int unsigned USER_W        = 4,
    // Depth of the middle elastic buffer. 4 is the Phase 0 configuration: deep
    // enough that a bursty sink fills it and the occupancy check has something
    // to observe, small enough to stay in distributed registers.
    parameter int unsigned ELASTIC_DEPTH = 4,

    // DERIVED — do not override. Exists only because a port range cannot refer
    // to a localparam declared in the module body, and writing the width
    // arithmetic out by hand in the port list is exactly the duplicated
    // concatenation stream_pkg exists to prevent.
    parameter int unsigned PAYLOAD_W = int'(stream_pkg::stream_payload_w(
        stream_pkg::stream_geom(DATA_W, STREAM_ID_W, SEQ_W, USER_W)))
) (
    input  wire                   clk,
    input  wire                   rst_n,

    // Slave (input) side of the SPEC 5 bundle.
    input  wire                   s_valid,
    output wire                   s_ready,
    input  wire [DATA_W-1:0]      s_data,
    input  wire                   s_start_of_frame,
    input  wire                   s_end_of_frame,
    input  wire [STREAM_ID_W-1:0] s_stream_id,
    input  wire [SEQ_W-1:0]       s_seq,
    input  wire [USER_W-1:0]      s_user,

    // Master (output) side.
    output wire                   m_valid,
    input  wire                   m_ready,
    output wire [DATA_W-1:0]      m_data,
    output wire                   m_start_of_frame,
    output wire                   m_end_of_frame,
    output wire [STREAM_ID_W-1:0] m_stream_id,
    output wire [SEQ_W-1:0]       m_seq,
    output wire [USER_W-1:0]      m_user,

    // The packed payload presented on the master side, exported so the C++
    // harness can check its own copy of the SPEC 5 packing against the RTL's on
    // every beat. Not a datapath port: no other module reads it.
    output wire [PAYLOAD_W-1:0]   m_payload
);

  localparam stream_pkg::stream_geom_t GEOM =
      stream_pkg::stream_geom(DATA_W, STREAM_ID_W, SEQ_W, USER_W);

  // Structural no-backpressure latency, summed from the primitives rather than
  // written as a number. benchmark_sim_top checks this against the value the
  // C++ harness was generated with, so the two cannot drift.
  localparam int unsigned LATENCY_NO_STALL = stream_pkg::stream_skid_latency() +
                                             stream_pkg::stream_elastic_latency() +
                                             stream_pkg::stream_skid_latency();

  // ---------------------------------------------------------------------------
  // Pack the slave-side fields into the canonical payload.
  // ---------------------------------------------------------------------------
  stream_pkg::stream_fields_t s_fields;
  wire [PAYLOAD_W-1:0]        s_payload;

  always_comb begin
    s_fields           = '0;
    s_fields.data      = stream_pkg::STREAM_MAX_DATA_W'(s_data);
    s_fields.sof       = s_start_of_frame;
    s_fields.eof       = s_end_of_frame;
    s_fields.stream_id = stream_pkg::STREAM_MAX_ID_W'(s_stream_id);
    s_fields.seq       = stream_pkg::STREAM_MAX_SEQ_W'(s_seq);
    s_fields.user      = stream_pkg::STREAM_MAX_USER_W'(s_user);
  end

  assign s_payload = PAYLOAD_W'(stream_pkg::stream_pack(GEOM, s_fields));

  // ---------------------------------------------------------------------------
  // skid -> elastic -> skid
  // ---------------------------------------------------------------------------
  wire                 a_valid, a_ready;
  wire [PAYLOAD_W-1:0] a_payload;
  wire                 b_valid, b_ready;
  wire [PAYLOAD_W-1:0] b_payload;
  wire [$clog2(ELASTIC_DEPTH+1)-1:0] elastic_occupancy;

  stream_skid_buffer #(
      .PAYLOAD_W   (PAYLOAD_W),
      .DATA_W      (DATA_W),
      .STREAM_ID_W (STREAM_ID_W),
      .SEQ_W       (SEQ_W),
      .USER_W      (USER_W)
  ) u_in_skid (
      .clk       (clk),
      .rst_n     (rst_n),
      .s_valid   (s_valid),
      .s_ready   (s_ready),
      .s_payload (s_payload),
      .m_valid   (a_valid),
      .m_ready   (a_ready),
      .m_payload (a_payload)
  );

  stream_elastic_buffer #(
      .PAYLOAD_W   (PAYLOAD_W),
      .DEPTH       (ELASTIC_DEPTH),
      .DATA_W      (DATA_W),
      .STREAM_ID_W (STREAM_ID_W),
      .SEQ_W       (SEQ_W),
      .USER_W      (USER_W)
  ) u_elastic (
      .clk       (clk),
      .rst_n     (rst_n),
      .s_valid   (a_valid),
      .s_ready   (a_ready),
      .s_payload (a_payload),
      .m_valid   (b_valid),
      .m_ready   (b_ready),
      .m_payload (b_payload),
      .occupancy (elastic_occupancy)
  );

  stream_skid_buffer #(
      .PAYLOAD_W   (PAYLOAD_W),
      .DATA_W      (DATA_W),
      .STREAM_ID_W (STREAM_ID_W),
      .SEQ_W       (SEQ_W),
      .USER_W      (USER_W)
  ) u_out_skid (
      .clk       (clk),
      .rst_n     (rst_n),
      .s_valid   (b_valid),
      .s_ready   (b_ready),
      .s_payload (b_payload),
      .m_valid   (m_valid),
      .m_ready   (m_ready),
      .m_payload (m_payload)
  );

  // ---------------------------------------------------------------------------
  // Unpack the master-side payload back into fields.
  // ---------------------------------------------------------------------------
  stream_pkg::stream_fields_t m_fields;

  assign m_fields = stream_pkg::stream_unpack(
                        GEOM, stream_pkg::stream_payload_t'(m_payload));

  assign m_data           = DATA_W'(m_fields.data);
  assign m_start_of_frame = m_fields.sof;
  assign m_end_of_frame   = m_fields.eof;
  assign m_stream_id      = STREAM_ID_W'(m_fields.stream_id);
  assign m_seq            = SEQ_W'(m_fields.seq);
  assign m_user           = USER_W'(m_fields.user);

  // ---------------------------------------------------------------------------
  // A pack/unpack round trip must be the identity. This is the RTL half of the
  // single-packing-definition guarantee; the C++ half is checked beat by beat in
  // sim/tests/test_stream_loopback.cpp against the exported m_payload.
  // ---------------------------------------------------------------------------
`ifndef SYNTHESIS
  initial begin
    if (int'(LATENCY_NO_STALL) < 1) begin
      $fatal(1, "stream_loopback: structural latency must be positive");
    end
    if (int'(PAYLOAD_W) != int'(stream_pkg::stream_payload_w(GEOM))) begin
      $fatal(1, "stream_loopback: PAYLOAD_W was overridden (%0d) and no longer matches the geometry (%0d)",
             PAYLOAD_W, int'(stream_pkg::stream_payload_w(GEOM)));
    end
  end

  always_ff @(posedge clk) begin
    if (rst_n && s_valid && s_ready) begin
      a_pack_roundtrip : assert (stream_pkg::stream_unpack(GEOM,
                                     stream_pkg::stream_payload_t'(s_payload)) == s_fields)
        else $error("stream_loopback: stream_pack/stream_unpack round trip is not the identity");
    end
    if (rst_n) begin
      a_elastic_occupancy : assert (int'(elastic_occupancy) <= int'(ELASTIC_DEPTH))
        else $error("stream_loopback: elastic occupancy %0d exceeds depth %0d",
                    elastic_occupancy, ELASTIC_DEPTH);
    end
  end
`endif

endmodule : stream_loopback

`default_nettype wire
