// -----------------------------------------------------------------------------
// cdc_gray_checker — SPEC 14 "Gray-pointer one-bit transitions", as a module.
//
// Wraps the `CDC_SVA_GRAY` property from sim/assertions/cdc_sva.svh so it can be
// attached to any pointer in the design by either mechanism, exactly as
// sim/assertions/stream_protocol_checker.sv does for the SPEC 5 stream protocol:
//
//   instantiation   rtl/cdc/async_fifo.sv instantiates one of these per pointer,
//                   inside `ifndef SYNTHESIS`, so any design built from that
//                   FIFO is checked by construction, in the SPEC 12.1 fast
//                   build, with no test-side wiring.
//   bind            for a crossing whose source you do not own:
//                       bind <module> cdc_gray_checker #(.WIDTH(N)) u (...);
//                   sim/verilator/tops/cdc_violator_top.sv is the worked example
//                   and is the negative test's mechanism.
//
// WATCH THE POINTER IN THE DOMAIN THAT OWNS IT, and only there. The one-bit rule
// is a statement about consecutive values of the pointer REGISTER; the
// synchronized copy in the other domain is that register sampled by a different
// clock, and when the source clock is the faster of the two it legitimately
// advances several Gray steps between two destination samples. Attaching this
// checker to a synchronizer output therefore fails on correct RTL at every
// non-unity clock ratio (measured, at 2:1). What the crossing depends on is that
// the value ENTERING the synchronizer is Gray-coded, which is what an instance
// in the owning domain checks.
//
// This module contains no functional logic and drives nothing. It is
// simulation-only: it is never listed in a Quartus source list, and every
// instantiation of it in design RTL sits inside `ifndef SYNTHESIS`.
//
// Separate file from cdc_handshake_checker.sv because the two share no port, no
// state and no failure mode — and because one module per file is what keeps
// `verilator --lint-only --Wall` clean without a DECLFILENAME waiver.
// -----------------------------------------------------------------------------

`default_nettype none

`include "cdc_sva.svh"

module cdc_gray_checker #(
    parameter int unsigned WIDTH = 4
) (
    input  wire             clk,
    input  wire             rst_n,
    input  wire [WIDTH-1:0] gray
);

  `CDC_SVA_GRAY(clk, rst_n, gray, WIDTH)

endmodule : cdc_gray_checker

`default_nettype wire
