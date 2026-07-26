// -----------------------------------------------------------------------------
// covar_assertions.sv — the SPEC 14 property set for the integration window
// (SPEC.md 7.6, 14; issue #13).
//
// INSTANTIATED by rtl/covariance/integrator.sv under `ifndef SYNTHESIS`, not
// bound from a test — the same arrangement rtl/stream/ uses for
// stream_protocol_checker and rtl/pfb/ for pfb_assertions, and for the same
// reason: the window contract then holds wherever an integrator is used, in the
// fast build, in every test, with no test-side wiring, and a later integration
// cannot forget to attach it. There is one instance per integrator, which means
// one per power channel and two per covariance pair.
//
// WHAT SPEC 7.6 REQUIRES HERE, AND WHICH PROPERTY IS WHICH
// --------------------------------------------------------
//   "Window-boundary metadata"
//        -> a_covar_wid_increments, a_covar_wid_restarts_after_flush
//   "never emit a partial window silently" (the readable form of the same)
//        -> a_covar_short_window_is_marked, a_covar_full_window_is_not_marked
//   "Programmable integration window"
//        -> a_covar_count_in_range, a_covar_count_nonzero
//   "Runtime enable per covariance pair" — no accumulation while disabled
//        -> a_covar_no_result_while_disabled
//
// Tool limits measured on Verilator 5.020 (DECISIONS.md 2026-07-26, decision 3):
// no `##` cycle-delay sequences, so every property is written with implication
// and $past. A failing assertion prints and calls vl_stop, which aborts the run
// unless a test clears `Verilated::fatalOnError` — which sim/tests/test_covariance.cpp
// does exactly once, for the deliberate fault-injection pass.
// -----------------------------------------------------------------------------

`default_nettype none

module covar_assertions #(
    parameter int unsigned WINDOW_W = 16,
    parameter int unsigned ACC_W    = 40
) (
    input  wire                clk,
    input  wire                rst_n,

    // The raw flush request. Registered here so it lines up with `valid_out`,
    // which is the result of the decision taken one cycle earlier. It is needed
    // because a flush that finds NOTHING to drain emits no result at all and
    // still restarts the window id — without it, the id sequence check would
    // fire on the first result after such a flush.
    input  wire                flush,

    input  wire                valid_out,
    input  wire                flushed,
    input  wire                truncated,
    input  wire [15:0]         window_id,
    input  wire [WINDOW_W-1:0] sample_count,
    input  wire signed [ACC_W-1:0] acc_out,

    // The ACTIVE configuration inside the integrator, not the cfg_* ports: the
    // properties below are about the window that actually ran.
    input  wire [WINDOW_W-1:0] active_len,
    input  wire                enable
);

`ifndef SYNTHESIS

  // A result never covers zero samples. An empty window carries no information
  // and would still consume a window id, so a consumer counting ids would see a
  // gap it could not explain.
  a_covar_count_nonzero : assert property (
      @(posedge clk) disable iff (!rst_n)
      valid_out |-> (sample_count != '0))
    else $error("integrator: emitted a window covering zero samples");

  // A result never covers more samples than the window that was running.
  a_covar_count_in_range : assert property (
      @(posedge clk) disable iff (!rst_n)
      valid_out |-> (sample_count <= $past(active_len)))
    else $error("integrator: sample_count %0d exceeds the active window length %0d",
                sample_count, $past(active_len));

  // THE "no silent partial window" PROPERTY, both directions. A short result
  // must be marked truncated; a full-length result must not be.
  a_covar_short_window_is_marked : assert property (
      @(posedge clk) disable iff (!rst_n)
      (valid_out && (sample_count != $past(active_len))) |-> truncated)
    else $error("integrator: short window (%0d of %0d) emitted without truncated",
                sample_count, $past(active_len));

  a_covar_full_window_is_not_marked : assert property (
      @(posedge clk) disable iff (!rst_n)
      (valid_out && (sample_count == $past(active_len))) |-> !truncated)
    else $error("integrator: full window (%0d) emitted with truncated set",
                sample_count);

  // A truncated result is always a flushed one: the counter reaching the length
  // is the only other way a window closes, and that one is full by definition.
  a_covar_truncated_implies_flushed : assert property (
      @(posedge clk) disable iff (!rst_n)
      (valid_out && truncated) |-> flushed)
    else $error("integrator: a window was truncated without a flush");

  // Window ids advance by exactly one between consecutive NORMAL results, and
  // restart at zero after a flush. Together these are the whole boundary
  // contract: a consumer that sees id n+2 after id n knows a window was lost,
  // and a consumer that sees id 0 knows the block was restarted.
  logic        flush_q;       // `flush`, aligned with the registered outputs
  logic        have_prev_q;   // a previous result exists AND was a normal close
  logic        prev_flush_q;  // the block was flushed since the previous result
  logic [15:0] prev_wid_q;

  always_ff @(posedge clk) begin
    if (!rst_n) flush_q <= 1'b0;
    else        flush_q <= flush;
  end

  always_ff @(posedge clk) begin
    if (!rst_n) begin
      have_prev_q  <= 1'b0;
      prev_flush_q <= 1'b0;
      prev_wid_q   <= '0;
    end else if (valid_out) begin
      have_prev_q  <= !flushed;
      prev_flush_q <= flushed;
      prev_wid_q   <= window_id;
    end else if (flush_q) begin
      // A flush with an empty window emits nothing and still restarts the id.
      have_prev_q  <= 1'b0;
      prev_flush_q <= 1'b1;
    end
  end

  a_covar_wid_increments : assert property (
      @(posedge clk) disable iff (!rst_n)
      (valid_out && have_prev_q) |-> (window_id == 16'(prev_wid_q + 16'd1)))
    else $error("integrator: window_id jumped from %0d to %0d",
                prev_wid_q, window_id);

  a_covar_wid_restarts_after_flush : assert property (
      @(posedge clk) disable iff (!rst_n)
      (valid_out && prev_flush_q) |-> (window_id == 16'd0))
    else $error("integrator: the first window after a flush carries id %0d, not 0",
                window_id);

  // A disabled integrator accepts nothing, so the only result it can produce is
  // the flush that drains what it accumulated while it was still enabled.
  a_covar_no_result_while_disabled : assert property (
      @(posedge clk) disable iff (!rst_n)
      (valid_out && !$past(enable)) |-> flushed)
    else $error("integrator: a disabled window produced a non-flush result");

  // SPEC 13.2 metamorphic aid rather than a correctness property: a result is
  // only meaningful if the accumulator is inside its own field. This cannot fail
  // structurally — acc_out IS ACC_W bits — and exists so the width appears in
  // the waveform annotation next to the value.
  a_covar_acc_defined : assert property (
      @(posedge clk) disable iff (!rst_n)
      valid_out |-> !$isunknown(acc_out))
    else $error("integrator: emitted an unknown accumulator value");

`endif

endmodule : covar_assertions

`default_nettype wire
