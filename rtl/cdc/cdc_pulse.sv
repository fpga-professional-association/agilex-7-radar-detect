// -----------------------------------------------------------------------------
// cdc_pulse — toggle-based pulse synchronizer with busy and overrun (SPEC.md 8).
//
// SPEC 8: "Use toggle or handshake synchronizers for pulses." A single-cycle
// strobe cannot be synchronized directly: if the destination clock is slower
// than the source clock, a one-cycle pulse can fall entirely between two
// destination edges and vanish. The standard fix, and the one implemented here,
// is to convert the *event* into a level change — a toggle — synchronize the
// level, and recover the event as an edge on the destination side.
//
//     src_pulse  __/‾\______/‾\____________
//     toggle_q   _____/‾‾‾‾‾‾‾‾\___________   one flip per accepted pulse
//     toggle_dst ________/‾‾‾‾‾‾‾‾\________   two destination flops later
//     dst_pulse  ________/‾\______/‾\______   one strobe per edge
//
// THE PART THAT IS USUALLY MISSING
// --------------------------------
// A bare toggle synchronizer silently loses pulses that arrive closer together
// than the crossing latency: the toggle flips twice, the destination sees one
// net level change, and one event disappears. That is a real defect and it is
// invisible without instrumentation, so this module closes the loop instead of
// documenting the hazard:
//
//   * the destination's synchronized toggle is synchronized *back* into the
//     source domain, and `src_busy` is high whenever the two disagree — i.e. for
//     the whole round trip during which a second pulse would be unsafe;
//   * a `src_pulse` asserted while `src_busy` is high is REFUSED (the toggle
//     does not flip, so no event is corrupted) and sets `src_overrun`, a sticky
//     flag. Overrun is a design error — the producer sent faster than the
//     crossing can carry — and it is reported rather than absorbed.
//
// A producer that cannot tolerate refusal must gate on `src_busy`, which is what
// makes this a flow-controlled crossing rather than a best-effort one. A
// producer that needs to carry data with the event uses rtl/cdc/cdc_handshake.sv
// or, for a stream of them, rtl/cdc/async_fifo.sv.
//
// Round-trip cost: SYNC_STAGES destination cycles out plus SYNC_STAGES source
// cycles back, plus registration at each end. `src_busy` therefore stays high
// for roughly 2 x SYNC_STAGES cycles of the slower of the two clocks; size the
// producer's pacing against that, not against the source clock.
//
// Reset: synchronous per domain, active low. The two resets are assumed to be
// asserted together and released independently — the project-wide CDC reset
// contract stated in DECISIONS.md (issue #6) and implemented by
// rtl/cdc/async_fifo.sv. This module needs no reset gating to honour it: with
// both toggles cleared to 0 the crossing is idle, and a source that runs while
// the destination is still held in reset sees `src_busy` stay high (the echo
// cannot return) and correctly reports every further pulse as an overrun.
// -----------------------------------------------------------------------------

`default_nettype none

(* cdc_primitive = "pulse_toggle", cdc_src_clk = "src_clk", cdc_dst_clk = "dst_clk", cdc_width = "1", cdc_stages = "SYNC_STAGES" *)
module cdc_pulse #(
    // Flip-flops per synchronizer chain; see cdc_pkg::cdc_sync_stages_default().
    parameter int unsigned SYNC_STAGES = 2
) (
    // ---- source domain ----
    input  wire  src_clk,
    input  wire  src_rst_n,

    // One-cycle strobe in the source domain. Ignored (and counted as an
    // overrun) while `src_busy` is high.
    input  wire  src_pulse,

    // High while a pulse is in flight; a new `src_pulse` will be refused.
    output wire  src_busy,

    // Sticky: at least one pulse was refused since the last clear.
    output wire  src_overrun,

    // Synchronous clear for `src_overrun`. Tie low if unused.
    input  wire  src_sticky_clear,

    // ---- destination domain ----
    input  wire  dst_clk,
    input  wire  dst_rst_n,

    // One-cycle strobe in the destination domain, one per accepted source pulse.
    output wire  dst_pulse
);

`ifndef SYNTHESIS
  initial begin
    if (SYNC_STAGES < int'(cdc_pkg::cdc_sync_stages_min())) begin
      $fatal(1, "cdc_pulse: SYNC_STAGES=%0d is illegal; minimum is %0d",
             SYNC_STAGES, int'(cdc_pkg::cdc_sync_stages_min()));
    end
  end
`endif

  // ---------------------------------------------------------------------------
  // Source domain: the toggle, and the flow control around it.
  // ---------------------------------------------------------------------------
  logic toggle_q;      // flips once per accepted pulse
  logic overrun_q;
  wire  echo_w;        // destination's view of the toggle, brought back
  wire  busy_w  = (toggle_q != echo_w);
  wire  accept  = src_pulse && !busy_w;

  always_ff @(posedge src_clk) begin
    if (!src_rst_n) begin
      toggle_q  <= 1'b0;
      overrun_q <= 1'b0;
    end else begin
      if (accept) toggle_q <= ~toggle_q;

      if (src_sticky_clear) begin
        overrun_q <= 1'b0;
      end else if (src_pulse && busy_w) begin
        overrun_q <= 1'b1;
      end
    end
  end

  // ---------------------------------------------------------------------------
  // Source -> destination: the toggle level.
  // ---------------------------------------------------------------------------
  wire toggle_dst_w;

  cdc_sync2 #(
      .WIDTH      (1),
      .STAGES     (SYNC_STAGES),
      .RST_VALUE  (1'b0),
      .GRAY_CODED (1'b0)
  ) u_sync_fwd (
      .clk   (dst_clk),
      .rst_n (dst_rst_n),
      .d     (toggle_q),
      .q     (toggle_dst_w)
  );

  // ---------------------------------------------------------------------------
  // Destination domain: edge detect.
  // ---------------------------------------------------------------------------
  logic toggle_dst_q;

  always_ff @(posedge dst_clk) begin
    if (!dst_rst_n) begin
      toggle_dst_q <= 1'b0;
    end else begin
      toggle_dst_q <= toggle_dst_w;
    end
  end

  assign dst_pulse = toggle_dst_w ^ toggle_dst_q;

  // ---------------------------------------------------------------------------
  // Destination -> source: the echo that closes the loop.
  //
  // `toggle_dst_q` rather than `toggle_dst_w` is echoed on purpose: it is one
  // further destination flip-flop of separation, so the echo cannot lead the
  // edge detector and `src_busy` is guaranteed to stay high until after
  // `dst_pulse` has actually been emitted.
  // ---------------------------------------------------------------------------
  cdc_sync2 #(
      .WIDTH      (1),
      .STAGES     (SYNC_STAGES),
      .RST_VALUE  (1'b0),
      .GRAY_CODED (1'b0)
  ) u_sync_echo (
      .clk   (src_clk),
      .rst_n (src_rst_n),
      .d     (toggle_dst_q),
      .q     (echo_w)
  );

  assign src_busy    = busy_w;
  assign src_overrun = overrun_q;

  // ---------------------------------------------------------------------------
  // Assertions (SPEC 14). The toggle is a one-bit value, so its "Gray" property
  // is trivially true and is not worth an instance; what is worth checking is
  // that the flow control is actually doing its job.
  // ---------------------------------------------------------------------------
`ifndef SYNTHESIS
  always_ff @(posedge src_clk) begin
    if (src_rst_n) begin
      a_no_toggle_while_busy : assert (!(accept && busy_w))
        else $error("cdc_pulse: a pulse was accepted while the crossing was still busy");
    end
  end

  // The destination must not emit more strobes than the source accepted. Two
  // free-running counters in different domains cannot be compared cycle by
  // cycle, so the check is the one relation that holds at every instant:
  // deliveries never lead acceptances. Sampled in the destination domain, where
  // `accept_count_q` is at least as old as the truth, which makes the check
  // conservative in the safe direction.
  logic [31:0] accept_count_q;
  logic [31:0] deliver_count_q;

  always_ff @(posedge src_clk) begin
    if (!src_rst_n) accept_count_q <= 32'd0;
    else if (accept) accept_count_q <= accept_count_q + 32'd1;
  end

  always_ff @(posedge dst_clk) begin
    if (!dst_rst_n) begin
      deliver_count_q <= 32'd0;
    end else if (dst_pulse) begin
      deliver_count_q <= deliver_count_q + 32'd1;
      a_no_phantom_pulse : assert (deliver_count_q < accept_count_q)
        else $error("cdc_pulse: delivered %0d strobes but only %0d were accepted",
                    deliver_count_q + 32'd1, accept_count_q);
    end
  end
`endif

endmodule : cdc_pulse

`default_nettype wire
