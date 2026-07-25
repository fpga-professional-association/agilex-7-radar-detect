// -----------------------------------------------------------------------------
// stream_violator_top — top for the negative assertion test (SPEC 14).
//
// Wraps sim/verilator/tops/stream_violator.sv — the deliberately broken stage —
// and attaches the SPEC 14 protocol checker to it by `bind`. The violation modes
// and what each one must provoke are documented in stream_violator.sv.
//
// The bind is at file scope rather than inside the module: a bind's parameter
// and port expressions are elaborated in the scope of the TARGET module, so a
// bind written inside this top cannot see this top's imports. Package-qualified
// names (`config_pkg::...`) resolve from anywhere, which is what the statement
// at the bottom of this file uses. Measured under Verilator 5.020; see
// DECISIONS.md 2026-07-26 decision 3.
//
// Simulation-only. Never in sim/verilator/files.f, never in a Quartus source
// list.
// -----------------------------------------------------------------------------

`default_nettype none

module stream_violator_top
  import config_pkg::*;
(
    input  logic                        clk,
    input  logic                        rst_n,
    input  logic [2:0]                  viol_mode,

    input  logic                        s_valid,
    output logic                        s_ready,
    input  logic [STREAM_PAYLOAD_W-1:0] s_payload,

    output logic                        m_valid,
    input  logic                        m_ready,
    output logic [STREAM_PAYLOAD_W-1:0] m_payload
);

  stream_violator #(
      .PAYLOAD_W (STREAM_PAYLOAD_W),
      .SOF_LSB   (STREAM_SOF_LSB),
      .SEQ_LSB   (STREAM_SEQ_LSB),
      .WARMUP    (4)
  ) u_violator (
      .clk       (clk),
      .rst_n     (rst_n),
      .viol_mode (viol_mode),
      .s_valid   (s_valid),
      .s_ready   (s_ready),
      .s_payload (s_payload),
      .m_valid   (m_valid),
      .m_ready   (m_ready),
      .m_payload (m_payload)
  );

endmodule : stream_violator_top

// The checker is attached by bind, not by instantiation: the module under
// observation contains no assertion of its own, which is exactly the situation
// bind exists for. Package-qualified parameter names, because these expressions
// are elaborated in stream_violator's scope, not this file's.
bind stream_violator stream_protocol_checker #(
    .PAYLOAD_W   (config_pkg::STREAM_PAYLOAD_W),
    .DATA_W      (config_pkg::STREAM_DATA_W),
    .STREAM_ID_W (config_pkg::STREAM_ID_W),
    .SEQ_W       (config_pkg::STREAM_SEQ_W),
    .USER_W      (config_pkg::STREAM_USER_W)
) u_bound_chk (
    .clk     (clk),
    .rst_n   (rst_n),
    .valid   (m_valid),
    .ready   (m_ready),
    .payload (m_payload)
);

`default_nettype wire
