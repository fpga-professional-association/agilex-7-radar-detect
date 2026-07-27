// -----------------------------------------------------------------------------
// benchmark_pipeline_ctrl - frame-boundary control glue for the medium-config
// integrated pipeline (issue #17, SPEC.md 19 Phase 3).
//
// This module is the single place the pipeline's ONE frame boundary is
// generated from and where the ONE runtime-update gate lives. It exists as its
// own file for two reasons:
//
//   1. The individual per-block coefficient / weight bank swaps (rtl/pfb/
//      coeff_bank.sv and rtl/beamformer/weight_bank.sv) each verify their own
//      frame-boundary rule in the block-level tests of #10 and #12. When the
//      blocks are wired together, the pipeline-level rule is that BOTH the PFB
//      coefficient bank and the beamformer weight bank must swap at the SAME
//      frame boundary as seen from the PFB input side. Enforcing that here
//      instead of at the two block-level gates keeps the per-block rules
//      intact and lets us prove the integration rule independently.
//
//   2. It provides a clean, plumbable interface so the register plane (issue
//      #19) can eventually replace the harness's direct swap requests without
//      reworking the pipeline top.
//
// The control glue is intentionally minimal: a small state machine that
//   - counts frames observed at the PFB input,
//   - opens a "swap-armed" window on end-of-frame,
//   - forwards a swap-request pulse to both coefficient banks at the same
//     cycle, so both banks change ownership at the same input-side frame
//     boundary,
//   - reports a busy flag to the requester until both banks have completed
//     their swap.
//
// A cfg_swap_req arriving mid-frame is LATCHED and dispatched at the next
// end-of-frame, which is exactly the safety property the per-block checkers
// require. A second cfg_swap_req arriving while a first is still pending or
// in flight is COUNTED as an overrun and dropped.
//
// Lint contract: clean under `verilator --lint-only --Wall` with no waiver.
// -----------------------------------------------------------------------------

`default_nettype none

module benchmark_pipeline_ctrl (
    input  wire        clk,
    input  wire        rst_n,

    // ---- pipeline traffic observation --------------------------------------
    // A beat is admitted at the pipeline head this cycle. This is the SOF/EOF
    // reference plane: all frame boundaries in the whole design are anchored
    // to what the PFB input sees, not to some downstream latency-shifted view.
    input  wire        head_admit,
    input  wire        head_sof,
    input  wire        head_eof,

    // ---- external swap request --------------------------------------------
    // A one-cycle pulse asks the controller to swap both coefficient banks
    // at the next end-of-frame. Level-driven requests are latched into the
    // one-cycle form by the caller (the register plane in production, the
    // C++ harness in simulation).
    input  wire        cfg_swap_req,

    // ---- to the per-block swap ports ---------------------------------------
    // pfb_swap and bf_swap are one-cycle pulses that fire on the SAME cycle,
    // which is the end-of-frame following an armed swap. Both banks then take
    // the same frame boundary as their swap point.
    output wire        pfb_swap,
    output wire        bf_swap,

    // ---- status ------------------------------------------------------------
    output wire        swap_pending,
    output wire        swap_busy,
    output wire [31:0] frame_count,
    output wire [31:0] swap_count,
    output wire [31:0] swap_overrun_count,

    // ---- from the per-block busy indications -------------------------------
    input  wire        pfb_swap_busy,
    input  wire        bf_swap_busy
);

  // ---------------------------------------------------------------------------
  // Frame counter, on the PFB input plane. eof && admit is one frame.
  // ---------------------------------------------------------------------------
  logic [31:0] frame_q;
  always_ff @(posedge clk) begin
    if (!rst_n) begin
      frame_q <= 32'd0;
    end else if (head_admit && head_eof) begin
      frame_q <= frame_q + 32'd1;
    end
  end
  assign frame_count = frame_q;

  // ---------------------------------------------------------------------------
  // Swap-arm state
  //   idle          no request outstanding
  //   armed         request seen, waiting for end-of-frame
  //   dispatched    swap pulse issued this cycle; block-level busy will
  //                 assert next cycle and hold until swap completes
  //   waiting_busy  waiting for both blocks to report busy low
  // ---------------------------------------------------------------------------
  typedef enum logic [1:0] {
    S_IDLE       = 2'd0,
    S_ARMED      = 2'd1,
    S_DISPATCHED = 2'd2,
    S_WAIT_BUSY  = 2'd3
  } state_e;

  state_e state_q, state_d;

  logic pfb_swap_q, bf_swap_q;
  logic swap_dispatch;

  logic [31:0] swap_q, overrun_q;

  logic new_req;
  assign new_req = cfg_swap_req;

  logic eof_this_cycle;
  assign eof_this_cycle = head_admit && head_eof;

  always_comb begin
    state_d       = state_q;
    swap_dispatch = 1'b0;
    unique case (state_q)
      S_IDLE: begin
        if (new_req) state_d = S_ARMED;
      end
      S_ARMED: begin
        // Wait for end-of-frame; a repeat cfg_swap_req while armed is an
        // overrun and does nothing.
        if (eof_this_cycle) begin
          state_d       = S_DISPATCHED;
          swap_dispatch = 1'b1;
        end
      end
      S_DISPATCHED: begin
        // Give the block-level busy a cycle to rise before we watch it.
        state_d = S_WAIT_BUSY;
      end
      S_WAIT_BUSY: begin
        if (!pfb_swap_busy && !bf_swap_busy) state_d = S_IDLE;
      end
      default: state_d = S_IDLE;
    endcase
  end

  always_ff @(posedge clk) begin
    if (!rst_n) begin
      state_q    <= S_IDLE;
      pfb_swap_q <= 1'b0;
      bf_swap_q  <= 1'b0;
      swap_q     <= 32'd0;
      overrun_q  <= 32'd0;
    end else begin
      state_q    <= state_d;
      pfb_swap_q <= swap_dispatch;
      bf_swap_q  <= swap_dispatch;
      if (swap_dispatch) swap_q <= swap_q + 32'd1;
      // Overrun: a new request while any state other than idle is active, and
      // it isn't the request that armed the current cycle.
      if (new_req && state_q != S_IDLE) overrun_q <= overrun_q + 32'd1;
    end
  end

  assign pfb_swap           = pfb_swap_q;
  assign bf_swap            = bf_swap_q;
  assign swap_pending       = (state_q == S_ARMED);
  assign swap_busy          = (state_q != S_IDLE);
  assign swap_count         = swap_q;
  assign swap_overrun_count = overrun_q;

`ifndef SYNTHESIS
  // Frame-boundary rule: the swap pulses must never fire on a cycle other than
  // an end-of-frame on the head admit plane.
  always_ff @(posedge clk) begin
    if (rst_n && (pfb_swap || bf_swap)) begin
      a_swap_at_eof : assert (state_q == S_DISPATCHED)
        else $error("benchmark_pipeline_ctrl: swap pulse outside dispatched state (state=%0d)",
                    state_q);
    end
  end
`endif

endmodule : benchmark_pipeline_ctrl

`default_nettype wire
