// -----------------------------------------------------------------------------
// coeff_bank_checker.sv — the SPEC 14 dual-coefficient-bank property set
// (SPEC.md 7.1, 14; issue #10).
//
// The companion of sim/assertions/pfb_assertions.sv: that file carries the
// block-level flow-control properties of rtl/pfb/pfb_bank.sv, this one carries
// the two properties SPEC 7.1 states about the coefficient banks themselves.
// Two files rather than one because a Verilator --Wall build requires the
// filename to match the module name, and each of these is instantiated by a
// different design module.
//
// Both are INSTANTIATED by the RTL under `ifndef SYNTHESIS` rather than bound
// from a test — the same arrangement rtl/stream/ uses for
// stream_protocol_checker. The consequence is the point: these properties hold
// wherever coeff_bank is used, in the fast build, in every test, with no
// test-side wiring, and a future integration cannot forget to attach them.
//
//   "Active coefficient bank may change only at a safe frame boundary"
//        -> a_coeff_swap_at_sof
//   double buffering, i.e. programming the spare bank must not disturb the
//   filter that is running
//        -> a_coeff_stable_between   (stated on the OUTPUT, not on the write
//                                     logic, so it survives a rewrite of the
//                                     write logic)
//
// a_coeff_swap_at_sof is made falsifiable by coeff_bank's ALLOW_UNSAFE_SWAP
// parameter, which sim/verilator/tops/pfb_top.sv instantiates once, outside the
// datapath, for exactly that purpose. An assertion that nothing can provoke is
// an assertion nobody has tested; see sim/tests/test_pfb_bank.cpp, mode
// `illegal-swap`.
//
// Tool limits measured on Verilator 5.020 (DECISIONS.md 2026-07-26 decision 3):
// no `##` cycle-delay sequences, so every property below is written with
// implication and $past. A failing assertion prints and calls vl_stop, which
// aborts unless a test clears `Verilated::fatalOnError`.
// -----------------------------------------------------------------------------

`default_nettype none

// -----------------------------------------------------------------------------
// coeff_bank_checker — the dual-bank contract
// -----------------------------------------------------------------------------
module coeff_bank_checker #(
    // Total bits of one bank's coefficient image. Passed rather than recomputed
    // so this file has no opinion about the polyphase geometry.
    parameter int unsigned COEFF_BITS = 512
) (
    input  wire                  clk,
    input  wire                  rst_n,

    // The admitted-beat pair that defines the safe swap point.
    input  wire                  beat,
    input  wire                  sof,

    // The bank IN USE for the current beat (coeff_bank's `bank_sel`), not the
    // settled register: the swap takes effect on the start-of-frame beat.
    input  wire                  active_bank,
    input  wire [COEFF_BITS-1:0] coeff
);

`ifndef SYNTHESIS

  // The bank IN USE changes ONLY on a cycle carrying an admitted start-of-frame
  // beat. This is SPEC 7.1's "safe frame boundary", stated as an observation of
  // the coefficient read select rather than of the state machine that drives it,
  // and compared against the CURRENT beat/sof rather than the previous cycle's
  // because the swap takes effect ON the start-of-frame beat (see
  // rtl/pfb/coeff_bank.sv, `bank_sel`).
  a_coeff_swap_at_sof : assert property (
      @(posedge clk) disable iff (!rst_n)
      (active_bank != $past(active_bank)) |-> (beat && sof)
  ) else $error("coeff_bank: active bank changed outside a start-of-frame beat");

  // The active bank's CONTENTS are stable except on the cycle the active bank
  // changes. This is the inactive-bank-write-has-no-effect property: a write
  // aimed at the spare bank cannot move a single bit of what the lanes see, and
  // a write aimed at the active bank is refused, so the only thing that can move
  // the coefficients is a swap.
  a_coeff_stable_between : assert property (
      @(posedge clk) disable iff (!rst_n)
      (coeff != $past(coeff)) |-> (active_bank != $past(active_bank))
  ) else $error("coeff_bank: active coefficients changed without a bank swap");

`endif

endmodule : coeff_bank_checker

`default_nettype wire
