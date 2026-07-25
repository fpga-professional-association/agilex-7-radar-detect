// -----------------------------------------------------------------------------
// cdc_violator_top — top for the SPEC 14 CDC negative assertion test.
//
// Wraps sim/verilator/tops/cdc_violator.sv — the deliberately broken crossing —
// and attaches the SPEC 14 CDC checkers to it by `bind`. The violation modes and
// what each one must provoke are documented in cdc_violator.sv.
//
// Both checkers are attached by bind rather than by instantiation, for the same
// reason stream_violator_top does it: the module under observation contains no
// assertion of its own, which is exactly the situation bind exists for, and it
// proves that a crossing whose source you do not own can still be checked. The
// bind statements are at file scope rather than inside the module, because a
// bind's parameter and port expressions are elaborated in the scope of the
// TARGET module and so cannot see this top's imports; package-qualified names
// (`config_pkg::...`) resolve from anywhere. Measured under Verilator 5.020; see
// DECISIONS.md 2026-07-26 decision 3.
//
// Simulation-only. Listed in sim/verilator/files_cdc_violator.f and in no other
// file list, so the knowingly-wrong RTL beneath it can never reach the design
// build or a Quartus source list.
// -----------------------------------------------------------------------------

`default_nettype none

module cdc_violator_top
  import config_pkg::*;
(
    input  logic                            clk,
    input  logic                            rst_n,
    input  logic [2:0]                      viol_mode,

    input  logic                            advance,
    input  logic                            hs_start,

    output logic [CDC_VIOLATOR_PTR_W-1:0]   ptr,
    output logic                            req,
    output logic                            ack,
    output logic [CDC_HANDSHAKE_W-1:0]      data
);

  cdc_violator #(
      .PTR_W      (CDC_VIOLATOR_PTR_W),
      .WIDTH      (CDC_HANDSHAKE_W),
      .ACK_DELAY  (3),
      .DROP_DELAY (2)
  ) u_violator (
      .clk       (clk),
      .rst_n     (rst_n),
      .viol_mode (viol_mode),
      .advance   (advance),
      .hs_start  (hs_start),
      .ptr       (ptr),
      .req       (req),
      .ack       (ack),
      .data      (data)
  );

endmodule : cdc_violator_top

// SPEC 14 "Gray-pointer one-bit transitions", attached to a pointer that mode 1
// deliberately does not Gray-encode.
bind cdc_violator cdc_gray_checker #(
    .WIDTH (config_pkg::CDC_VIOLATOR_PTR_W)
) u_bound_gray (
    .clk   (clk),
    .rst_n (rst_n),
    .gray  (ptr)
);

// SPEC 14 "CDC handshake completion", attached to a source that modes 2, 3 and 4
// deliberately break. ACK_TIMEOUT is small here on purpose: the violator's own
// responder answers within a handful of cycles, so a bound in the hundreds is
// still far above any legal delay while keeping a wedged handshake detectable
// inside a short run.
bind cdc_violator cdc_handshake_checker #(
    .WIDTH       (config_pkg::CDC_HANDSHAKE_W),
    .ACK_TIMEOUT (256)
) u_bound_hs (
    .clk   (clk),
    .rst_n (rst_n),
    .req   (req),
    .ack   (ack),
    .data  (data)
);

`default_nettype wire
