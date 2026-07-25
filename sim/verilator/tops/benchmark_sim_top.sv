// -----------------------------------------------------------------------------
// benchmark_sim_top — Verilator simulation top (SPEC.md 4.1).
//
// SPEC 4.1 defines this variant as the pure-RTL, vendor-IP-free top used by the
// C++ harness. As of issue #5 it contains one stream loopback built entirely
// from the canonical stream primitives (rtl/stream/), and a second, independent
// clock domain (cfg_clk) whose only content is a free-running heartbeat counter.
// The second domain is not decoration — it is what makes the SPEC 12.3
// multi-clock scheduler observable, and it gives the reset sequencer two
// independent domains to sequence.
//
// This top grows in later issues: the PFB/FFT/beamformer/CFAR chain (#10-#14),
// the packet fabric (#18), the full-scale elaboration (#20). Parameters come
// from config_pkg, which scripts/build_verilator.py generates from
// config/<name>.json — never edit elaboration parameters here.
//
// Layout consistency (issue #5)
// -----------------------------
// The SPEC 5 payload layout has one normative definition, rtl/packages/
// stream_pkg.sv, and one mirror — the constants scripts/build_verilator.py
// writes into the generated config package and the generated C++ header, which
// is what the harness packs and unpacks with. The `initial` block at the bottom
// of this file compares the two at time 0 on every run, so a mirror that drifts
// from the package fails immediately and by name rather than as a corrupted
// payload a thousand cycles later. The remaining half of the guarantee — that
// the C++ *code* uses those constants correctly — is checked beat by beat by
// test_stream_loopback.cpp against the exported `m_payload`.
// -----------------------------------------------------------------------------

`default_nettype none

module benchmark_sim_top
  import config_pkg::*;
(
    // Core processing domain (SPEC 8: core_clk).
    input  logic                       core_clk,
    input  logic                       core_rst_n,

    // Configuration domain (SPEC 8: cfg_clk). Asynchronous to core_clk.
    input  logic                       cfg_clk,
    input  logic                       cfg_rst_n,

    // SPEC 5 stream bundle, source side (driven by the harness).
    input  logic                       s_valid,
    output logic                       s_ready,
    input  logic [STREAM_DATA_W-1:0]   s_data,
    input  logic                       s_start_of_frame,
    input  logic                       s_end_of_frame,
    input  logic [STREAM_ID_W-1:0]     s_stream_id,
    input  logic [STREAM_SEQ_W-1:0]    s_seq,
    input  logic [STREAM_USER_W-1:0]   s_user,

    // SPEC 5 stream bundle, sink side (sampled by the harness).
    output logic                       m_valid,
    input  logic                       m_ready,
    output logic [STREAM_DATA_W-1:0]   m_data,
    output logic                       m_start_of_frame,
    output logic                       m_end_of_frame,
    output logic [STREAM_ID_W-1:0]     m_stream_id,
    output logic [STREAM_SEQ_W-1:0]    m_seq,
    output logic [STREAM_USER_W-1:0]   m_user,

    // The same beat in canonical packed form, so the harness can prove its own
    // copy of the SPEC 5 packing agrees with the RTL's on every transfer.
    output logic [STREAM_PAYLOAD_W-1:0] m_payload,

    // cfg_clk-domain liveness counter. Read by the harness to confirm the
    // scheduler is actually toggling the second clock at its own rate.
    output logic [31:0]                cfg_heartbeat
);

  // ---------------------------------------------------------------------------
  // Core domain: stream loopback, built from the canonical primitives
  // (skid -> elastic -> skid).
  // ---------------------------------------------------------------------------
  stream_loopback #(
      .DATA_W        (STREAM_DATA_W),
      .STREAM_ID_W   (STREAM_ID_W),
      .SEQ_W         (STREAM_SEQ_W),
      .USER_W        (STREAM_USER_W),
      .ELASTIC_DEPTH (STREAM_LOOPBACK_ELASTIC_DEPTH)
  ) u_loopback (
      .clk              (core_clk),
      .rst_n            (core_rst_n),

      .s_valid          (s_valid),
      .s_ready          (s_ready),
      .s_data           (s_data),
      .s_start_of_frame (s_start_of_frame),
      .s_end_of_frame   (s_end_of_frame),
      .s_stream_id      (s_stream_id),
      .s_seq            (s_seq),
      .s_user           (s_user),

      .m_valid          (m_valid),
      .m_ready          (m_ready),
      .m_data           (m_data),
      .m_start_of_frame (m_start_of_frame),
      .m_end_of_frame   (m_end_of_frame),
      .m_stream_id      (m_stream_id),
      .m_seq            (m_seq),
      .m_user           (m_user),
      .m_payload        (m_payload)
  );

  // ---------------------------------------------------------------------------
  // Configuration domain: free-running heartbeat.
  //
  // Deliberately has no path to or from the core domain. Register-plane CDC is
  // issue #7; introducing a crossing here would create an unverified one.
  // ---------------------------------------------------------------------------
  logic [31:0] cfg_heartbeat_q;

  // Synchronous reset, per SPEC 23.
  always_ff @(posedge cfg_clk) begin
    if (!cfg_rst_n) begin
      cfg_heartbeat_q <= 32'd0;
    end else begin
      cfg_heartbeat_q <= cfg_heartbeat_q + 32'd1;
    end
  end

  assign cfg_heartbeat = cfg_heartbeat_q;

  // ---------------------------------------------------------------------------
  // Time-0 consistency check: generated mirror vs. normative package.
  //
  // Everything compared here has two independent implementations — one in
  // rtl/packages/stream_pkg.sv (SystemVerilog, normative) and one in
  // scripts/build_verilator.py (Python, mirrored into config_pkg.sv and
  // config_sim.h for the C++ harness). The check is cheap, runs on every
  // simulation of every seed, and turns a silent layout drift into a named
  // elaboration failure.
  // ---------------------------------------------------------------------------
`ifndef SYNTHESIS
  localparam stream_pkg::stream_geom_t GEOM = stream_pkg::stream_geom(
      STREAM_DATA_W, STREAM_ID_W, STREAM_SEQ_W, STREAM_USER_W);

  localparam int unsigned LOOPBACK_LATENCY = stream_pkg::stream_skid_latency() +
                                             stream_pkg::stream_elastic_latency() +
                                             stream_pkg::stream_skid_latency();

  initial begin
    if (int'(STREAM_PAYLOAD_W) != int'(stream_pkg::stream_payload_w(GEOM))) begin
      $fatal(1, "config/stream_pkg layout drift: STREAM_PAYLOAD_W=%0d, package says %0d",
             STREAM_PAYLOAD_W, int'(stream_pkg::stream_payload_w(GEOM)));
    end
    if (int'(STREAM_USER_LSB) != int'(stream_pkg::stream_user_lsb(GEOM))) begin
      $fatal(1, "config/stream_pkg layout drift: STREAM_USER_LSB=%0d, package says %0d",
             STREAM_USER_LSB, int'(stream_pkg::stream_user_lsb(GEOM)));
    end
    if (int'(STREAM_SEQ_LSB) != int'(stream_pkg::stream_seq_lsb(GEOM))) begin
      $fatal(1, "config/stream_pkg layout drift: STREAM_SEQ_LSB=%0d, package says %0d",
             STREAM_SEQ_LSB, int'(stream_pkg::stream_seq_lsb(GEOM)));
    end
    if (int'(STREAM_ID_LSB) != int'(stream_pkg::stream_id_lsb(GEOM))) begin
      $fatal(1, "config/stream_pkg layout drift: STREAM_ID_LSB=%0d, package says %0d",
             STREAM_ID_LSB, int'(stream_pkg::stream_id_lsb(GEOM)));
    end
    if (int'(STREAM_EOF_LSB) != int'(stream_pkg::stream_eof_lsb(GEOM))) begin
      $fatal(1, "config/stream_pkg layout drift: STREAM_EOF_LSB=%0d, package says %0d",
             STREAM_EOF_LSB, int'(stream_pkg::stream_eof_lsb(GEOM)));
    end
    if (int'(STREAM_SOF_LSB) != int'(stream_pkg::stream_sof_lsb(GEOM))) begin
      $fatal(1, "config/stream_pkg layout drift: STREAM_SOF_LSB=%0d, package says %0d",
             STREAM_SOF_LSB, int'(stream_pkg::stream_sof_lsb(GEOM)));
    end
    if (int'(STREAM_DATA_LSB) != int'(stream_pkg::stream_data_lsb(GEOM))) begin
      $fatal(1, "config/stream_pkg layout drift: STREAM_DATA_LSB=%0d, package says %0d",
             STREAM_DATA_LSB, int'(stream_pkg::stream_data_lsb(GEOM)));
    end
    if (int'(STREAM_LOOPBACK_LATENCY) != int'(LOOPBACK_LATENCY)) begin
      $fatal(1, "loopback latency drift: config says %0d, the instantiated structure is %0d",
             STREAM_LOOPBACK_LATENCY, LOOPBACK_LATENCY);
    end
  end
`endif

endmodule : benchmark_sim_top

`default_nettype wire
