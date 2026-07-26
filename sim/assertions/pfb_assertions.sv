// -----------------------------------------------------------------------------
// pfb_assertions.sv — the SPEC 14 property set for the polyphase FIR bank
// (SPEC.md 7.1, 14; issue #10).
//
// INSTANTIATED by rtl/pfb/pfb_bank.sv under `ifndef SYNTHESIS` rather than bound
// from a test — the same arrangement rtl/stream/ uses for
// stream_protocol_checker. The consequence is the point: these properties hold
// wherever pfb_bank is used, in the fast build, in every test, with no test-side
// wiring, and a future integration cannot forget to attach them.
//
// This file carries the BLOCK-LEVEL contract. The dual-coefficient-bank
// properties SPEC 7.1 states — swap only at a frame boundary, and
// inactive-bank-write-has-no-effect — live in the companion file
// sim/assertions/coeff_bank_checker.sv, because a Verilator --Wall build
// requires the filename to match the module name and the two attach to
// different design modules.
//
// WHAT SPEC 7.1 AND SPEC 23 REQUIRE HERE, AND WHICH ASSERTION IS WHICH
// --------------------------------------------------------------------
//   "Valid metadata must travel with the corresponding samples", and the SPEC 23
//   requirement that a fixed-latency interior never has to stall
//        -> a_pfb_out_never_blocked, a_pfb_lane_valid_uniform,
//           a_pfb_credit_bound, a_pfb_admit_is_a_transfer
//
// Tool limits measured on Verilator 5.020 (DECISIONS.md 2026-07-26 decision 3):
// no `##` cycle-delay sequences, so every property below is written with
// implication and $past. A failing assertion prints and calls vl_stop, which
// aborts unless a test clears `Verilated::fatalOnError`.
// -----------------------------------------------------------------------------

`default_nettype none

// -----------------------------------------------------------------------------
// pfb_assertions — the block-level flow-control contract
// -----------------------------------------------------------------------------
module pfb_assertions #(
    parameter int unsigned PHASES    = 8,
    parameter int unsigned OUT_DEPTH = 12,
    parameter int unsigned CRED_W    = 4
) (
    input  wire                clk,
    input  wire                rst_n,

    input  wire                admit,
    input  wire                s_valid,
    input  wire                s_ready,
    input  wire [CRED_W-1:0]   credits,

    input  wire [PHASES-1:0]   lane_valid,
    input  wire                out_valid,
    input  wire                out_buf_ready
);

`ifndef SYNTHESIS

  // THE CREDIT ARGUMENT, checked rather than argued. A beat is admitted only
  // against a reserved slot, so by the time it reaches the output buffer the
  // slot is still there. If this ever fires, the interior stalled — which the
  // fixed-latency datapath has no way to survive, and which would show up
  // downstream as a lost beat rather than as a stall.
  a_pfb_out_never_blocked : assert property (
      @(posedge clk) disable iff (!rst_n)
      out_valid |-> out_buf_ready
  ) else $error("pfb_bank: output elastic buffer refused a beat; the credit reservation is wrong");

  // Every lane is the same module driven by one `admit`, so their valids are one
  // signal in PHASES copies. A disagreement means the lane generate loop or the
  // shared enable has been broken, which would otherwise surface only as a
  // wrong sum in one phase.
  a_pfb_lane_valid_uniform : assert property (
      @(posedge clk) disable iff (!rst_n)
      (lane_valid == {PHASES{lane_valid[0]}})
  ) else $error("pfb_bank: lane valids disagree (%b)", lane_valid);

  // The credit counter counts free slots of an OUT_DEPTH-entry buffer and can
  // therefore never exceed it. Above it means a credit was returned that was
  // never taken; a wrap to all-ones would silently re-enable admission into a
  // full buffer.
  //
  // Elaborated only when OUT_DEPTH is not 2**CRED_W - 1. At that value the
  // counter's own width already bounds it and the comparison is constant —
  // vacuous rather than wrong, and Verilator 5.020 reports it (CMPCONST). Same
  // guard, for the same reason, as rtl/stream/stream_elastic_buffer.sv's
  // occupancy bound.
  if (OUT_DEPTH < ((1 << CRED_W) - 1)) begin : g_credit_bound
    a_pfb_credit_bound : assert property (
        @(posedge clk) disable iff (!rst_n)
        (credits <= CRED_W'(OUT_DEPTH))
    ) else $error("pfb_bank: credit counter %0d exceeds OUT_DEPTH %0d", credits,
                  OUT_DEPTH);
  end

  // No admission without a credit. The safety half of the credit argument, and
  // the one that is always elaborated: `s_ready` is a flip-flop whose input is
  // exactly (credits_d != 0), so an empty credit counter MUST refuse the next
  // beat. If this ever fires, a beat entered a pipeline with no reserved slot at
  // the far end and will be dropped by the output buffer.
  //
  // Stated one-directionally on purpose. The converse — a non-empty counter
  // implies ready — is true only from the second cycle after reset release, and
  // an assertion that needs a reset caveat is an assertion that gets disabled.
  a_pfb_no_credit_no_admit : assert property (
      @(posedge clk) disable iff (!rst_n)
      (credits == CRED_W'(0)) |-> !s_ready
  ) else $error("pfb_bank: s_ready is high with no credits left");

  // A beat is admitted only on a completed handshake. Structural, but it is the
  // premise every other property here rests on.
  a_pfb_admit_is_a_transfer : assert property (
      @(posedge clk) disable iff (!rst_n)
      admit |-> (s_valid && s_ready)
  ) else $error("pfb_bank: a beat was admitted without a valid/ready transfer");

`endif

endmodule : pfb_assertions


`default_nettype wire
