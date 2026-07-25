// -----------------------------------------------------------------------------
// cdc_handshake_checker — SPEC 14 "CDC handshake completion", as a module.
//
// Wraps the `CDC_SVA_HANDSHAKE` and `CDC_SVA_HANDSHAKE_LIVE` properties from
// sim/assertions/cdc_sva.svh. Watch a four-phase request/acknowledge pair and
// its payload IN THE SOURCE DOMAIN, using the acknowledge the source actually
// reacts to — the synchronized one. Watching the destination's own acknowledge
// register from here would be sampling a foreign clock domain in a checker,
// which reports races the design neither sees nor has.
//
// What it enforces:
//   * a raised request is never withdrawn before it is answered;
//   * the payload is frozen for the whole request window — the property that
//     makes a multibit crossing legal at all;
//   * no acknowledge appears without an offer, and an acknowledge is not dropped
//     while the offer is still up;
//   * every request is answered within ACK_TIMEOUT cycles of `clk`.
//
// rtl/cdc/cdc_handshake.sv instantiates one inside `ifndef SYNTHESIS`; the
// negative test (sim/tests/test_cdc_assertions.cpp) `bind`s one onto a
// deliberately broken source and requires `a_hs_data_stable` to fire by name.
//
// Simulation-only: never in a Quartus source list, and every instantiation in
// design RTL sits inside `ifndef SYNTHESIS`.
// -----------------------------------------------------------------------------

`default_nettype none

`include "cdc_sva.svh"

module cdc_handshake_checker #(
    parameter int unsigned WIDTH = 8,

    // Bound, in cycles of `clk`, on an unanswered request. Generous by design:
    // the round trip is (source registration + STAGES destination cycles +
    // destination registration + STAGES source cycles), and one source cycle may
    // be a small fraction of a destination cycle.
    parameter int unsigned ACK_TIMEOUT = 4096
) (
    input  wire             clk,
    input  wire             rst_n,
    input  wire             req,
    input  wire             ack,
    input  wire [WIDTH-1:0] data
);

  `CDC_SVA_HANDSHAKE(clk, rst_n, req, ack, data)
  `CDC_SVA_HANDSHAKE_LIVE(clk, rst_n, req, ack, ACK_TIMEOUT)

endmodule : cdc_handshake_checker

`default_nettype wire
