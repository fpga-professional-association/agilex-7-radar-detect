// -----------------------------------------------------------------------------
// beamformer_assertions.sv — the SPEC 14 property set for the beamforming matrix
// (SPEC.md 7.5, 14; issue #12).
//
// INSTANTIATED by rtl/beamformer/beamformer.sv under `ifndef SYNTHESIS` rather
// than bound from a test — the same arrangement rtl/stream/ uses for
// stream_protocol_checker and rtl/pfb/ uses for pfb_assertions. The consequence
// is the point: these properties hold wherever the beamformer is used, in the
// fast build, in every test, with no test-side wiring, and a future integration
// cannot forget to attach them.
//
// This file carries the BLOCK-LEVEL contract. The weight-bank properties SPEC
// 7.5 states — swap only at a frame boundary, and inactive-bank-write-has-no-
// effect — are already checked inside the store by
// sim/assertions/coeff_bank_checker.sv, which rtl/beamformer/weight_bank.sv
// reuses along with the store itself (weight_bank section 1). Restating them
// here would be a second copy that can drift.
//
// WHAT SPEC 7.5 AND SPEC 23 REQUIRE HERE, AND WHICH ASSERTION IS WHICH
// --------------------------------------------------------------------
//   "Pipelined accumulation tree" with a fixed-latency interior that is never
//   stalled (SPEC 23)
//        -> a_bf_out_never_blocked, a_bf_dot_valid_uniform, a_bf_credit_bound,
//           a_bf_no_credit_no_admit, a_bf_admit_is_a_transfer
//
//   "Do not silently reduce throughput to meet utilization. Any time
//   multiplexing must be visible in parameters and reported throughput."
//        -> a_bf_group_in_range, a_bf_admit_only_when_group_complete,
//           a_bf_issue_implies_held
//
// The multiplex properties are the interesting ones and they are the reason this
// file exists rather than the block reusing pfb_assertions. A beamformer that
// admitted a second input beat before the first one's beam groups had all been
// issued would silently DROP beams — every output beat would still be a
// well-formed beam sample, the stream protocol would still be legal, the frame
// counts would still add up, and the only symptom would be wrong values on
// beams the scoreboard happened not to be watching that cycle. The
// admit-only-when-complete property turns that into an immediate named failure.
//
// Tool limits measured on Verilator 5.020 (DECISIONS.md 2026-07-26 decision 3):
// no `##` cycle-delay sequences, so every property below is written with
// implication and $past. A failing assertion prints and calls vl_stop, which
// aborts unless a test clears `Verilated::fatalOnError`.
// -----------------------------------------------------------------------------

`default_nettype none

module beamformer_assertions #(
    // Dot products in the engine: BEAM_PAR * BIN_PAR.
    parameter int unsigned N_DOT     = 4,
    parameter int unsigned OUT_DEPTH = 16,
    parameter int unsigned CRED_W    = 5,
    // Beam time-multiplex factor, N_BEAMS / BEAM_PAR.
    parameter int unsigned BEAM_MUX  = 1,
    parameter int unsigned GRP_W     = 1
) (
    input  wire                clk,
    input  wire                rst_n,

    input  wire                admit,
    input  wire                issue,
    input  wire                s_valid,
    input  wire                s_ready,
    input  wire [CRED_W-1:0]   credits,

    input  wire                hold_valid,
    input  wire [GRP_W-1:0]    grp,

    input  wire [N_DOT-1:0]    dot_valid_all,
    input  wire                out_valid,
    input  wire                out_buf_ready
);

`ifndef SYNTHESIS

  // ---------------------------------------------------------------------------
  // The credit argument, checked rather than argued
  // ---------------------------------------------------------------------------

  // A beat is admitted only against BEAM_MUX reserved slots, so by the time its
  // groups reach the output buffer the slots are still there. If this ever
  // fires, the interior stalled — which the fixed-latency datapath has no way to
  // survive, and which would show up downstream as a lost beam rather than as a
  // stall.
  a_bf_out_never_blocked : assert property (
      @(posedge clk) disable iff (!rst_n)
      out_valid |-> out_buf_ready
  ) else $error("beamformer: output elastic buffer refused a beat; the credit reservation is wrong");

  // Every dot product is the same module driven by one `issue`, so their valids
  // are one signal in N_DOT copies. A disagreement means the BIN_PAR x BEAM_PAR
  // generate nest has been broken, which would otherwise surface only as a wrong
  // value on one beam of one bin.
  a_bf_dot_valid_uniform : assert property (
      @(posedge clk) disable iff (!rst_n)
      (dot_valid_all == {N_DOT{dot_valid_all[0]}})
  ) else $error("beamformer: dot-product valids disagree (%b)", dot_valid_all);

  // The credit counter counts free slots of an OUT_DEPTH-entry buffer and can
  // therefore never exceed it. Above it means a credit was returned that was
  // never taken; a wrap to all-ones would silently re-enable admission into a
  // full buffer.
  //
  // Elaborated only when OUT_DEPTH is not 2**CRED_W - 1. At that value the
  // counter's own width already bounds it and the comparison is constant —
  // vacuous rather than wrong, and Verilator 5.020 reports it (CMPCONST). Same
  // guard, for the same reason, as pfb_assertions and
  // rtl/stream/stream_elastic_buffer.sv.
  if (OUT_DEPTH < ((1 << CRED_W) - 1)) begin : g_credit_bound
    a_bf_credit_bound : assert property (
        @(posedge clk) disable iff (!rst_n)
        (credits <= CRED_W'(OUT_DEPTH))
    ) else $error("beamformer: credit counter %0d exceeds OUT_DEPTH %0d", credits,
                  OUT_DEPTH);
  end

  // No admission without the FULL reservation. The safety half of the credit
  // argument: an input beat is an all-or-nothing commitment to BEAM_MUX output
  // beats, so a partial reservation is not a smaller commitment, it is a beat
  // whose later groups have nowhere to go.
  //
  // Stated one-directionally on purpose. The converse — enough credits implies
  // ready — is true only from the second cycle after reset release and only when
  // the hold register is also free, and an assertion that needs two caveats is
  // an assertion that gets disabled.
  a_bf_no_credit_no_admit : assert property (
      @(posedge clk) disable iff (!rst_n)
      (credits < CRED_W'(BEAM_MUX)) |-> !s_ready
  ) else $error("beamformer: s_ready is high with %0d credits, below the %0d a beat reserves",
                credits, BEAM_MUX);

  // A beat is admitted only on a completed handshake. Structural, but it is the
  // premise every other property here rests on.
  a_bf_admit_is_a_transfer : assert property (
      @(posedge clk) disable iff (!rst_n)
      admit |-> (s_valid && s_ready)
  ) else $error("beamformer: a beat was admitted without a valid/ready transfer");

  // ---------------------------------------------------------------------------
  // The time-multiplex contract (SPEC 7.5). See the header for why these are
  // the properties that matter.
  // ---------------------------------------------------------------------------

  // The group counter never leaves [0, BEAM_MUX). Elaborated only when GRP_W
  // can actually represent an out-of-range value: when BEAM_MUX == 2**GRP_W the
  // counter's own width bounds it and the comparison is constant.
  if (BEAM_MUX < (1 << GRP_W)) begin : g_group_range
    a_bf_group_in_range : assert property (
        @(posedge clk) disable iff (!rst_n)
        (grp < GRP_W'(BEAM_MUX))
    ) else $error("beamformer: beam group %0d is outside [0, %0d)", grp, BEAM_MUX);
  end

  // THE PROPERTY THIS FILE EXISTS FOR. A new input beat may only be admitted on
  // a cycle when the held beat has no groups left to issue — either the hold
  // register is empty, or its last group is being issued right now. Admitting
  // earlier overwrites a beat whose remaining beams have not been computed, and
  // the result is silently missing beams rather than a protocol violation.
  //
  // Elaborated only when BEAM_MUX > 1: at BEAM_MUX == 1 every group is the last
  // group and the property is constant-true.
  if (BEAM_MUX > 1) begin : g_mux
    a_bf_admit_only_when_group_complete : assert property (
        @(posedge clk) disable iff (!rst_n)
        admit |-> (!hold_valid || (issue && (grp == GRP_W'(BEAM_MUX - 1))))
    ) else $error("beamformer: a beat was admitted while group %0d of %0d was still outstanding; beams would be dropped",
                  grp, BEAM_MUX);

    // The group counter advances exactly once per issued group and wraps at
    // BEAM_MUX. Written with $past because Verilator 5.020 has no `##`.
    a_bf_group_advances_on_issue : assert property (
        @(posedge clk) disable iff (!rst_n)
        $past(rst_n) && $past(issue) |->
            (grp == ($past(grp) == GRP_W'(BEAM_MUX - 1) ? GRP_W'(0)
                                                        : GRP_W'($past(grp) + GRP_W'(1))))
    ) else $error("beamformer: the beam group counter did not advance on an issued group");

    // And it does NOT advance on a cycle with nothing to issue, which is what
    // keeps the group index aligned with the metadata that travels with it.
    a_bf_group_holds_when_idle : assert property (
        @(posedge clk) disable iff (!rst_n)
        $past(rst_n) && !$past(issue) |-> (grp == $past(grp))
    ) else $error("beamformer: the beam group counter advanced with no group issued");
  end

  // A group is only ever issued from a beat that is actually held. If this fires
  // the engine multiplied whatever the hold register happened to contain,
  // which is don't-care data by construction (the hold register is deliberately
  // unreset, SPEC 23) — so the output would be plausible noise rather than an X.
  a_bf_issue_implies_held : assert property (
      @(posedge clk) disable iff (!rst_n)
      issue |-> hold_valid
  ) else $error("beamformer: a beam group was issued with no beat held");

`endif

endmodule : beamformer_assertions

`default_nettype wire
