// -----------------------------------------------------------------------------
// benchmark_sim_top — Verilator simulation top (SPEC.md 4.1).
//
// SPEC 4.1 defines this variant as the pure-RTL, vendor-IP-free top used by the
// C++ harness. As of issue #2 (Phase 0) it contains exactly what the harness
// needs to prove itself: one provisional stream loopback in the core clock
// domain, and a second, independent clock domain (cfg_clk) whose only content
// is a free-running heartbeat counter. The second domain is not decoration —
// it is what makes the SPEC 12.3 multi-clock scheduler observable at Phase 0,
// and it gives the reset sequencer two independent domains to sequence.
//
// This top grows in later issues: the loopback is replaced by the real stream
// interface (#5), then the PFB/FFT/beamformer/CFAR chain (#10-#14), the packet
// fabric (#18), and the full-scale elaboration (#20). Parameters come from
// config_pkg, which scripts/build_verilator.py generates from config/<name>.json
// — never edit elaboration parameters here.
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

    // Provisional SPEC 5 stream bundle, source side (driven by the harness).
    input  logic                       s_valid,
    output logic                       s_ready,
    input  logic [STREAM_DATA_W-1:0]   s_data,
    input  logic                       s_start_of_frame,
    input  logic                       s_end_of_frame,
    input  logic [STREAM_ID_W-1:0]     s_stream_id,
    input  logic [STREAM_SEQ_W-1:0]    s_sequence,
    input  logic [STREAM_USER_W-1:0]   s_user,

    // Provisional SPEC 5 stream bundle, sink side (sampled by the harness).
    output logic                       m_valid,
    input  logic                       m_ready,
    output logic [STREAM_DATA_W-1:0]   m_data,
    output logic                       m_start_of_frame,
    output logic                       m_end_of_frame,
    output logic [STREAM_ID_W-1:0]     m_stream_id,
    output logic [STREAM_SEQ_W-1:0]    m_sequence,
    output logic [STREAM_USER_W-1:0]   m_user,

    // cfg_clk-domain liveness counter. Read by the harness to confirm the
    // scheduler is actually toggling the second clock at its own rate.
    output logic [31:0]                cfg_heartbeat
);

  // ---------------------------------------------------------------------------
  // Core domain: provisional stream loopback DUT.
  // ---------------------------------------------------------------------------
  stream_loopback #(
      .DATA_W      (STREAM_DATA_W),
      .STREAM_ID_W (STREAM_ID_W),
      .SEQ_W       (STREAM_SEQ_W),
      .USER_W      (STREAM_USER_W),
      .STAGES      (STREAM_LOOPBACK_STAGES)
  ) u_loopback (
      .clk              (core_clk),
      .rst_n            (core_rst_n),

      .s_valid          (s_valid),
      .s_ready          (s_ready),
      .s_data           (s_data),
      .s_start_of_frame (s_start_of_frame),
      .s_end_of_frame   (s_end_of_frame),
      .s_stream_id      (s_stream_id),
      .s_sequence       (s_sequence),
      .s_user           (s_user),

      .m_valid          (m_valid),
      .m_ready          (m_ready),
      .m_data           (m_data),
      .m_start_of_frame (m_start_of_frame),
      .m_end_of_frame   (m_end_of_frame),
      .m_stream_id      (m_stream_id),
      .m_sequence       (m_sequence),
      .m_user           (m_user)
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

endmodule : benchmark_sim_top

`default_nettype wire
