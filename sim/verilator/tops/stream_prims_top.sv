// -----------------------------------------------------------------------------
// stream_prims_top — per-primitive unit-test top for rtl/stream/ (SPEC 13.1).
//
// SPEC 13.1 requires every module to have directed, boundary, randomized, reset
// and stall tests plus protocol assertions. This top exposes the three canonical
// primitives — in four configurations — as four independent streams so that one
// binary, one seed and one scheduler cover all of them, and so a failure names
// the primitive that failed rather than "the loopback".
//
//   dut0  stream_skid_buffer                       two beats of storage
//   dut1  stream_elastic_buffer DEPTH=2            the two-deep register slice
//   dut2  stream_elastic_buffer DEPTH=8            a deeper buffer, occupancy sweep
//   dut3  stream_pipe STAGES=4 OUT_DEPTH=6         credit-based latency insertion
//
// The four have no connection to each other: they share only the clock and the
// reset, so a defect cannot propagate between them and each one's stall pattern
// is independent.
//
// Payload transport is the packed vector, not fields: the primitives are
// parameterised on payload width alone and never decode the bundle, which is
// exactly the contract being tested. sim/tests/test_stream_primitives.cpp packs
// and unpacks with the generated layout constants — the same constants
// benchmark_sim_top proves equal to rtl/packages/stream_pkg.sv at time 0.
//
// Geometry is passed down so that each primitive's built-in protocol checker
// runs the framing and sequence-continuity checks as well as the payload-
// agnostic ones. A second checker is instantiated on each DUT's slave interface,
// which is not redundant: it checks the C++ driver rather than the RTL, and a
// harness that violates the protocol it is testing for would otherwise be
// invisible.
//
// Simulation-only. Never synthesized, never listed in a Quartus source list.
// -----------------------------------------------------------------------------

`default_nettype none

module stream_prims_top
  import config_pkg::*;
(
    input  logic                        clk,
    input  logic                        rst_n,

    // dut0 — stream_skid_buffer
    input  logic                        s0_valid,
    output logic                        s0_ready,
    input  logic [STREAM_PAYLOAD_W-1:0] s0_payload,
    output logic                        m0_valid,
    input  logic                        m0_ready,
    output logic [STREAM_PAYLOAD_W-1:0] m0_payload,

    // dut1 — stream_elastic_buffer, shallow
    input  logic                        s1_valid,
    output logic                        s1_ready,
    input  logic [STREAM_PAYLOAD_W-1:0] s1_payload,
    output logic                        m1_valid,
    input  logic                        m1_ready,
    output logic [STREAM_PAYLOAD_W-1:0] m1_payload,
    output logic [7:0]                  occ1,

    // dut2 — stream_elastic_buffer, deep
    input  logic                        s2_valid,
    output logic                        s2_ready,
    input  logic [STREAM_PAYLOAD_W-1:0] s2_payload,
    output logic                        m2_valid,
    input  logic                        m2_ready,
    output logic [STREAM_PAYLOAD_W-1:0] m2_payload,
    output logic [7:0]                  occ2,

    // dut3 — stream_pipe
    input  logic                        s3_valid,
    output logic                        s3_ready,
    input  logic [STREAM_PAYLOAD_W-1:0] s3_payload,
    output logic                        m3_valid,
    input  logic                        m3_ready,
    output logic [STREAM_PAYLOAD_W-1:0] m3_payload
);

  localparam int unsigned EB_SHALLOW_DEPTH = STREAM_PRIM_EB_SHALLOW_DEPTH;
  localparam int unsigned EB_DEEP_DEPTH    = STREAM_PRIM_EB_DEEP_DEPTH;
  localparam int unsigned PIPE_STAGES      = STREAM_PRIM_PIPE_STAGES;
  localparam int unsigned PIPE_OUT_DEPTH   = STREAM_PRIM_PIPE_OUT_DEPTH;

  wire [$clog2(EB_SHALLOW_DEPTH+1)-1:0] occ1_raw;
  wire [$clog2(EB_DEEP_DEPTH+1)-1:0]    occ2_raw;

  assign occ1 = 8'(occ1_raw);
  assign occ2 = 8'(occ2_raw);

  // ---------------------------------------------------------------------------
  // dut0 — single-stage skid buffer.
  // ---------------------------------------------------------------------------
  stream_skid_buffer #(
      .PAYLOAD_W   (STREAM_PAYLOAD_W),
      .DATA_W      (STREAM_DATA_W),
      .STREAM_ID_W (STREAM_ID_W),
      .SEQ_W       (STREAM_SEQ_W),
      .USER_W      (STREAM_USER_W)
  ) u_dut0 (
      .clk       (clk),
      .rst_n     (rst_n),
      .s_valid   (s0_valid),
      .s_ready   (s0_ready),
      .s_payload (s0_payload),
      .m_valid   (m0_valid),
      .m_ready   (m0_ready),
      .m_payload (m0_payload)
  );

  // ---------------------------------------------------------------------------
  // dut1 — elastic buffer at the minimum legal depth (the two-deep slice).
  // ---------------------------------------------------------------------------
  stream_elastic_buffer #(
      .PAYLOAD_W   (STREAM_PAYLOAD_W),
      .DEPTH       (EB_SHALLOW_DEPTH),
      .DATA_W      (STREAM_DATA_W),
      .STREAM_ID_W (STREAM_ID_W),
      .SEQ_W       (STREAM_SEQ_W),
      .USER_W      (STREAM_USER_W)
  ) u_dut1 (
      .clk       (clk),
      .rst_n     (rst_n),
      .s_valid   (s1_valid),
      .s_ready   (s1_ready),
      .s_payload (s1_payload),
      .m_valid   (m1_valid),
      .m_ready   (m1_ready),
      .m_payload (m1_payload),
      .occupancy (occ1_raw)
  );

  // ---------------------------------------------------------------------------
  // dut2 — deeper elastic buffer, so occupancy sweeps a real range.
  // ---------------------------------------------------------------------------
  stream_elastic_buffer #(
      .PAYLOAD_W   (STREAM_PAYLOAD_W),
      .DEPTH       (EB_DEEP_DEPTH),
      .DATA_W      (STREAM_DATA_W),
      .STREAM_ID_W (STREAM_ID_W),
      .SEQ_W       (STREAM_SEQ_W),
      .USER_W      (STREAM_USER_W)
  ) u_dut2 (
      .clk       (clk),
      .rst_n     (rst_n),
      .s_valid   (s2_valid),
      .s_ready   (s2_ready),
      .s_payload (s2_payload),
      .m_valid   (m2_valid),
      .m_ready   (m2_ready),
      .m_payload (m2_payload),
      .occupancy (occ2_raw)
  );

  // ---------------------------------------------------------------------------
  // dut3 — credit-based pipeline.
  // ---------------------------------------------------------------------------
  stream_pipe #(
      .PAYLOAD_W   (STREAM_PAYLOAD_W),
      .STAGES      (PIPE_STAGES),
      .OUT_DEPTH   (PIPE_OUT_DEPTH),
      .DATA_W      (STREAM_DATA_W),
      .STREAM_ID_W (STREAM_ID_W),
      .SEQ_W       (STREAM_SEQ_W),
      .USER_W      (STREAM_USER_W)
  ) u_dut3 (
      .clk       (clk),
      .rst_n     (rst_n),
      .s_valid   (s3_valid),
      .s_ready   (s3_ready),
      .s_payload (s3_payload),
      .m_valid   (m3_valid),
      .m_ready   (m3_ready),
      .m_payload (m3_payload)
  );

  // ---------------------------------------------------------------------------
  // Slave-side protocol checkers: these watch the C++ driver, not the RTL.
  // ---------------------------------------------------------------------------
`ifndef SYNTHESIS
  stream_protocol_checker #(
      .PAYLOAD_W   (STREAM_PAYLOAD_W),
      .DATA_W      (STREAM_DATA_W),
      .STREAM_ID_W (STREAM_ID_W),
      .SEQ_W       (STREAM_SEQ_W),
      .USER_W      (STREAM_USER_W)
  ) u_chk_s0 (
      .clk (clk), .rst_n (rst_n),
      .valid (s0_valid), .ready (s0_ready), .payload (s0_payload)
  );

  stream_protocol_checker #(
      .PAYLOAD_W   (STREAM_PAYLOAD_W),
      .DATA_W      (STREAM_DATA_W),
      .STREAM_ID_W (STREAM_ID_W),
      .SEQ_W       (STREAM_SEQ_W),
      .USER_W      (STREAM_USER_W)
  ) u_chk_s1 (
      .clk (clk), .rst_n (rst_n),
      .valid (s1_valid), .ready (s1_ready), .payload (s1_payload)
  );

  stream_protocol_checker #(
      .PAYLOAD_W   (STREAM_PAYLOAD_W),
      .DATA_W      (STREAM_DATA_W),
      .STREAM_ID_W (STREAM_ID_W),
      .SEQ_W       (STREAM_SEQ_W),
      .USER_W      (STREAM_USER_W)
  ) u_chk_s2 (
      .clk (clk), .rst_n (rst_n),
      .valid (s2_valid), .ready (s2_ready), .payload (s2_payload)
  );

  stream_protocol_checker #(
      .PAYLOAD_W   (STREAM_PAYLOAD_W),
      .DATA_W      (STREAM_DATA_W),
      .STREAM_ID_W (STREAM_ID_W),
      .SEQ_W       (STREAM_SEQ_W),
      .USER_W      (STREAM_USER_W)
  ) u_chk_s3 (
      .clk (clk), .rst_n (rst_n),
      .valid (s3_valid), .ready (s3_ready), .payload (s3_payload)
  );
`endif

endmodule : stream_prims_top

`default_nettype wire
