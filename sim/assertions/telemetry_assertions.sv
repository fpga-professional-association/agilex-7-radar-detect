// -----------------------------------------------------------------------------
// telemetry_assertions — the SPEC 14 counter property set as a module (#8).
//
// Simulation only. rtl/common/perf_counter.sv instantiates one of these under
// `ifndef SYNTHESIS`, which is why there is no `bind` anywhere for it: there is
// exactly ONE counter implementation in this design, so checking it at its own
// definition checks every counter in every build — the telemetry block's nine,
// the sequence checker's five, and every counter a later kernel instantiates —
// without the kernel author knowing this file exists.
//
// The property text lives in sim/assertions/telemetry_sva.svh; this module is
// the port list and the mode selection. Splitting them is the arrangement
// stream_protocol_checker.sv already uses, and it is what lets the same
// properties be reused inline by a module that does not want an instance.
//
// Mode selection. The two mode-specific property sets are mutually exclusive
// obligations — a saturating counter must NEVER come out below where it went in,
// a modulo counter must ALWAYS do so when it reports a wrap — so they are chosen
// by a generate-if on the same parameter that chooses the arithmetic. A counter
// built one way and checked the other would be checked against a specification
// it never claimed to meet.
//
// Never synthesized, never in a Quartus source list.
// -----------------------------------------------------------------------------

`default_nettype none

`include "telemetry_sva.svh"

module telemetry_assertions #(
    parameter int unsigned WIDTH    = 32,
    parameter bit          SATURATE = 1'b0
) (
    input wire             clk,
    input wire             rst_n,

    // The counter's control inputs, as the counter itself sees them.
    input wire             enable,
    input wire             event_i,
    input wire             clear,
    input wire             snapshot,

    // Its observable state.
    input wire [WIDTH-1:0] count,
    input wire [WIDTH-1:0] snap,
    input wire             snap_valid,
    input wire             wrap_pulse,
    input wire             wrapped
);

  // Mode-independent obligations.
  `TELEMETRY_SVA_COUNTER(clk, rst_n, enable, event_i, clear, snapshot,
                         count, snap, snap_valid, wrap_pulse, wrapped)

  if (SATURATE) begin : g_saturating
    `TELEMETRY_SVA_COUNTER_SAT(clk, rst_n, clear, count, wrap_pulse)
  end else begin : g_modulo
    `TELEMETRY_SVA_COUNTER_MOD(clk, rst_n, count, wrap_pulse)
  end

endmodule : telemetry_assertions

`default_nettype wire
