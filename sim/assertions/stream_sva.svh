// -----------------------------------------------------------------------------
// stream_sva.svh — the reusable SPEC 5 / SPEC 14 stream protocol property set.
//
// SPEC 14 requires assertions for valid-data stability while stalled, frame
// boundary consistency and sequence discontinuity, and requires them to "remain
// active in fast simulation". SPEC 5 states the obligations they encode:
//
//     * transfer occurs only when valid && ready
//     * a source must hold payload and metadata stable while stalled
//     * frame boundaries must survive arbitrary backpressure
//     * sequence numbers must permit end-to-end loss and ordering checks
//
// This header holds the property TEXT, once. Two ways to use it:
//
//   1. `stream_protocol_checker` (sim/assertions/stream_protocol_checker.sv) —
//      a module built from these macros. Instantiate it inside a stage, or
//      `bind` it onto a module you do not own. Both mechanisms are exercised:
//      every primitive in rtl/stream/ instantiates one on its master interface,
//      and sim/verilator/tops/stream_violator_top.sv binds one onto a
//      deliberately broken stage.
//   2. The macros directly, for a stage that wants a check on an internal
//      interface without an instance. One use per scope: the macros declare
//      fixed assertion names, so a second use in the same scope needs its own
//      named block.
//
// What Verilator 5.020 actually enforces (measured — DECISIONS.md 2026-07-26,
// decision 3):
//
//   concurrent assert property with |=>, |->, $stable, $past, disable iff   yes
//   immediate assert inside always_ff, with an else $error action           yes
//   bind of a checker module onto a design module                           yes
//   cover property (counted only in a --coverage build)                     yes
//   ## cycle-delay sequences                                                NO -
//       "Unsupported: ## (in sequence expression)". Everything here is
//       therefore written with implication and $past instead of concatenation.
//   $isunknown                                                              compiles,
//       but the tool is two-state, so the X checks below are structurally dead
//       under it and exist for four-state simulators.
//
// Also measured, and load-bearing for how these macros are written: this
// preprocessor substitutes macro arguments inside string literals. A message
// must therefore never contain a word that is also a macro parameter name, or
// the text silently mutates at every use site.
//
// A failing assertion prints `%Error: <file>:<line>: Assertion failed in
// <hier>.<label>` and calls vl_stop, which aborts the process by default. The
// negative test (sim/tests/test_stream_assertions.cpp) clears
// `Verilated::fatalOnError` so that a failure becomes an observable event
// instead of a SIGABRT, which is what lets a deliberate protocol violation be
// reported as an expected failure with a zero exit status.
//
// Non-synthesizable constructs are guarded by `ifndef SYNTHESIS` at every use
// site, per the issue #5 task list. NOTE: these primitives are not yet in the
// Quartus source list; the issue that adds them must confirm that Quartus Pro
// defines SYNTHESIS for its Verilog compiler, or add
// `set_global_assignment -name VERILOG_MACRO "SYNTHESIS=1"` to the qsf.
// -----------------------------------------------------------------------------

`ifndef STREAM_SVA_SVH_
`define STREAM_SVA_SVH_

// -----------------------------------------------------------------------------
// `STREAM_SVA_HANDSHAKE(clk_i, rst_ni, vld_i, rdy_i, pld_i)
//
// The payload-agnostic half of the protocol: everything checkable without
// knowing the field geometry. Safe on any stream interface anywhere.
//
//   a_valid_held         valid is never withdrawn without a transfer. A source
//                        that drops an offered beat has lost it.
//   a_payload_stable     the whole payload — data and every metadata field — is
//                        bit-stable while the transfer is stalled.
//   a_reset_clears_valid validity is low in the cycle after reset is asserted.
//                        SPEC 23 resets validity and not the datapath, which
//                        makes validity exactly the thing that must provably
//                        reset.
//   a_no_x_when_valid    no X on the payload while valid (four-state tools).
//
// The covers, counted only in the SPEC 12.1 coverage build, record that the
// interesting states were reached rather than merely not violated: a stall that
// ends in a transfer, and two transfers back to back.
// -----------------------------------------------------------------------------
`define STREAM_SVA_HANDSHAKE(clk_i, rst_ni, vld_i, rdy_i, pld_i)                \
  property p_valid_held;                                                        \
    @(posedge (clk_i)) disable iff (!(rst_ni))                                  \
      ((vld_i) && !(rdy_i)) |=> (vld_i);                                        \
  endproperty                                                                   \
  a_valid_held : assert property (p_valid_held)                                 \
    else $error("stream protocol: valid withdrawn without a transfer");         \
                                                                                \
  property p_payload_stable;                                                    \
    @(posedge (clk_i)) disable iff (!(rst_ni))                                  \
      ((vld_i) && !(rdy_i)) |=> $stable(pld_i);                                 \
  endproperty                                                                   \
  a_payload_stable : assert property (p_payload_stable)                         \
    else $error("stream protocol: payload changed while the transfer stalled"); \
                                                                                \
  property p_reset_clears_valid;                                                \
    @(posedge (clk_i)) (!(rst_ni)) |=> !(vld_i);                                \
  endproperty                                                                   \
  a_reset_clears_valid : assert property (p_reset_clears_valid)                 \
    else $error("stream protocol: validity survived reset");                    \
                                                                                \
  property p_no_x_when_valid;                                                   \
    @(posedge (clk_i)) disable iff (!(rst_ni))                                  \
      (vld_i) |-> !$isunknown(pld_i);                                           \
  endproperty                                                                   \
  a_no_x_when_valid : assert property (p_no_x_when_valid)                       \
    else $error("stream protocol: unknown bits in an offered payload");         \
                                                                                \
  property p_stall_then_transfer;                                               \
    @(posedge (clk_i)) disable iff (!(rst_ni))                                  \
      ((vld_i) && (rdy_i) && $past((vld_i) && !(rdy_i)));                       \
  endproperty                                                                   \
  c_stall_then_transfer : cover property (p_stall_then_transfer);               \
                                                                                \
  property p_back_to_back;                                                      \
    @(posedge (clk_i)) disable iff (!(rst_ni))                                  \
      ((vld_i) && (rdy_i) && $past((vld_i) && (rdy_i)));                        \
  endproperty                                                                   \
  c_back_to_back : cover property (p_back_to_back);

// -----------------------------------------------------------------------------
// `STREAM_SVA_FRAMING(clk_i, rst_ni, vld_i, rdy_i, sof_i, eof_i, id_i, sq_i,
//                     N_ID_I, SQ_W_I)
//
// The geometry-aware half: frame-boundary legality and sequence continuity,
// tracked per stream_id. Written procedurally with immediate assertions rather
// than as concurrent properties because the state is an array indexed by a
// payload field, which SVA cannot carry across attempts without one property
// instance per id — and the working-type bound on the id field is 256.
//
//   a_sof_opens_frame   a beat outside a frame must carry start_of_frame
//   a_sof_not_in_frame  a beat inside a frame must not carry start_of_frame
//   a_seq_continuous    the sequence field increments by exactly one per beat
//                       within a stream, modulo its width. This is the loss and
//                       reorder detector that SPEC 5 requires the field to
//                       permit.
//
// Frame state is cleared by reset: it is control state, not payload (SPEC 23).
// A frame left open when a run ends is reported by the C++ monitor
// (StreamMonitor::check_drained), which sees the whole run rather than one edge.
// -----------------------------------------------------------------------------
`define STREAM_SVA_FRAMING(clk_i, rst_ni, vld_i, rdy_i, sof_i, eof_i, id_i, sq_i, N_ID_I, SQ_W_I) \
  logic                  in_frame_q  [N_ID_I];                                  \
  logic                  known_q     [N_ID_I];                                  \
  logic [(SQ_W_I)-1:0]   expect_q    [N_ID_I];                                  \
                                                                                \
  always_ff @(posedge (clk_i)) begin                                            \
    if (!(rst_ni)) begin                                                        \
      for (int unsigned i = 0; i < (N_ID_I); i++) begin                         \
        in_frame_q[i] <= 1'b0;                                                  \
        known_q[i]    <= 1'b0;                                                  \
      end                                                                       \
    end else if ((vld_i) && (rdy_i)) begin                                      \
      a_sof_opens_frame : assert (in_frame_q[(id_i)] || (sof_i))                \
        else $error("stream protocol: beat outside a frame without start-of-frame, stream %0d", (id_i)); \
      a_sof_not_in_frame : assert (!in_frame_q[(id_i)] || !(sof_i))             \
        else $error("stream protocol: start-of-frame inside an open frame, stream %0d", (id_i)); \
      a_seq_continuous : assert (!known_q[(id_i)] || ((sq_i) == expect_q[(id_i)])) \
        else $error("stream protocol: discontinuity on stream %0d, expected %0d saw %0d", (id_i), expect_q[(id_i)], (sq_i)); \
                                                                                \
      in_frame_q[(id_i)] <= !(eof_i);                                           \
      known_q[(id_i)]    <= 1'b1;                                               \
      expect_q[(id_i)]   <= (sq_i) + {{((SQ_W_I)-1){1'b0}}, 1'b1};              \
    end                                                                         \
  end

`endif  // STREAM_SVA_SVH_
