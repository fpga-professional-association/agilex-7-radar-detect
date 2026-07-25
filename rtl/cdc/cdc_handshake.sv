// -----------------------------------------------------------------------------
// cdc_handshake — four-phase multibit handshake synchronizer (SPEC.md 8, 14).
//
// SPEC 8: "Use toggle or handshake synchronizers for pulses" and "Do not
// synchronize a multibit bus by independently synchronizing every bit." This is
// the module for a multibit value that is not Gray-coded and does not arrive
// often enough to deserve a FIFO — a configuration word, a threshold, a captured
// counter, a status vector. Bulk traffic goes through rtl/cdc/async_fifo.sv.
//
// How it is safe
// --------------
// The payload itself is NOT synchronized. It is registered once in the source
// domain and then held perfectly still while the request is up; the request is
// the only thing that crosses through flip-flop synchronizers. By the time the
// destination sees the request — at least SYNC_STAGES destination cycles after
// the source raised it — the payload has been stable for at least that long, so
// the destination's capture is of a settled value. The payload path is a
// static-timing problem (`set_net_delay -max` / `set_max_skew` on the bus, per
// the Quartus Pro Timing Analyzer guide) and not a functional one.
//
// The property that argument rests on — "payload does not change while the
// request is up" — is exactly `a_hs_data_stable` in sim/assertions/cdc_sva.svh,
// instantiated below, and it is one of the two properties the negative test
// (sim/tests/test_cdc_assertions.cpp) proves can fire.
//
// FOUR PHASE, NOT TWO (DECISIONS.md, issue #6)
// --------------------------------------------
// Two-phase (non-return-to-zero) signalling halves the round trip: request and
// acknowledge are toggles, and a transfer is one edge each way rather than a
// full up-and-down on both. It was rejected here for three reasons:
//
//   1. Reset. A two-phase crossing's idle condition is "the two toggles agree",
//      which is a *relation between two clock domains*. If one domain is reset
//      and the other is not, the two toggles disagree and the crossing wakes up
//      believing a transfer is in flight — it delivers a phantom value, or
//      wedges. Four-phase has an absolute idle state, request = 0 and
//      acknowledge = 0, that each domain reaches from its own reset alone. Given
//      that this design releases each domain's reset on its own clock (SPEC 8,
//      and the harness's ResetSequencer does exactly that), that is decisive.
//   2. Checkability. "Request is held until acknowledged, and the payload is
//      stable throughout" is a property with an explicit window. A two-phase
//      crossing has no held request to write the property against; the stability
//      window is implicit and an assertion for it has to reconstruct the state
//      machine, which means the assertion can be wrong in the same way the
//      design is.
//   3. Cost. The extra latency is one more round trip of synchronizer delay on a
//      path that is, by construction, not a throughput path — anything that
//      needs throughput uses the asynchronous FIFO. Trading latency this crossing
//      does not need for reset behaviour it does need is the right side of the
//      trade.
//
// Sequence, with `s_ready` as the source-side flow control:
//
//     s_valid & s_ready   ->  payload latched, req raised, s_ready drops
//     req seen (2 flops)  ->  destination latches payload, pulses d_valid,
//                             raises ack
//     ack seen (2 flops)  ->  source drops req
//     req low seen        ->  destination drops ack
//     ack low seen        ->  s_ready rises; the next transfer may start
//
// Throughput is therefore one transfer per full round trip, which is the honest
// cost of a handshake crossing and the reason it is not the bulk mechanism.
//
// Reset: synchronous per domain, active low, control state only — the two state
// machines, the request and the acknowledge. The payload registers are not reset
// (SPEC 23); they are unreadable until a transfer delivers them.
// -----------------------------------------------------------------------------

`default_nettype none

(* cdc_primitive = "handshake_4phase", cdc_src_clk = "src_clk", cdc_dst_clk = "dst_clk", cdc_width = "WIDTH", cdc_stages = "SYNC_STAGES" *)
module cdc_handshake #(
    // Payload width. Any width: the payload does not cross through flip-flop
    // synchronizers, so the SPEC 8 multibit prohibition does not apply — that is
    // the entire point of this module.
    parameter int unsigned WIDTH = 16,

    // Flip-flops per synchronizer chain.
    parameter int unsigned SYNC_STAGES = 2,

    // Bound, in source cycles, on how long a raised request may go unanswered
    // before `a_hs_completes` fires (simulation only; see cdc_sva.svh). The
    // default covers a destination clock up to ~200x slower than the source,
    // which is far outside anything SPEC 8 defines.
    parameter int unsigned ACK_TIMEOUT_CYCLES = 4096
) (
    // ---- source domain ----
    input  wire              src_clk,
    input  wire              src_rst_n,

    // Offer a value. Accepted on the cycle `s_valid && s_ready`; the payload
    // must be held for that cycle only, after which this module owns it.
    input  wire              s_valid,
    output wire              s_ready,
    input  wire [WIDTH-1:0]  s_data,

    // High while a transfer is in flight. Equal to !s_ready; exported under its
    // own name because a producer usually wants to read it as status rather than
    // as flow control.
    output wire              s_busy,

    // ---- destination domain ----
    input  wire              dst_clk,
    input  wire              dst_rst_n,

    // One-cycle strobe when a new value has been captured.
    output wire              d_valid,

    // The captured value. Held stable from the strobe until the next one, so a
    // consumer may either sample on `d_valid` or simply read the register.
    output wire [WIDTH-1:0]  d_data
);

`ifndef SYNTHESIS
  initial begin
    if (SYNC_STAGES < int'(cdc_pkg::cdc_sync_stages_min())) begin
      $fatal(1, "cdc_handshake: SYNC_STAGES=%0d is illegal; minimum is %0d",
             SYNC_STAGES, int'(cdc_pkg::cdc_sync_stages_min()));
    end
    if (WIDTH < 1) begin
      $fatal(1, "cdc_handshake: WIDTH=%0d is illegal", WIDTH);
    end
  end
`endif

  // ---------------------------------------------------------------------------
  // Source-domain state machine.
  // ---------------------------------------------------------------------------
  typedef enum logic [1:0] {
    SRC_IDLE    = 2'b00,  // ready for a new value
    SRC_REQ     = 2'b01,  // request up, waiting for the acknowledge
    SRC_RELEASE = 2'b10   // request dropped, waiting for the acknowledge to drop
  } src_state_e;

  src_state_e       src_state_q;
  logic             req_q;
  logic [WIDTH-1:0] src_data_q;
  wire              ack_src_w;   // destination acknowledge, synchronized here

  wire src_accept = (src_state_q == SRC_IDLE) && s_valid;

  always_ff @(posedge src_clk) begin
    if (!src_rst_n) begin
      src_state_q <= SRC_IDLE;
      req_q       <= 1'b0;
    end else begin
      unique case (src_state_q)
        SRC_IDLE: begin
          if (s_valid) begin
            req_q       <= 1'b1;
            src_state_q <= SRC_REQ;
          end
        end
        SRC_REQ: begin
          if (ack_src_w) begin
            req_q       <= 1'b0;
            src_state_q <= SRC_RELEASE;
          end
        end
        SRC_RELEASE: begin
          if (!ack_src_w) begin
            src_state_q <= SRC_IDLE;
          end
        end
        default: begin
          // Unreachable: the enumeration is exhaustive over the encoding this
          // state machine can hold. Present so synthesis has no inferred latch
          // and so a corrupted state recovers to idle rather than wedging.
          src_state_q <= SRC_IDLE;
          req_q       <= 1'b0;
        end
      endcase
    end
  end

  // Payload register: not reset (SPEC 23). Loaded only on acceptance, so it is
  // constant for the whole request window — the property the crossing rests on.
  always_ff @(posedge src_clk) begin
    if (src_accept) src_data_q <= s_data;
  end

  assign s_ready = (src_state_q == SRC_IDLE);
  assign s_busy  = (src_state_q != SRC_IDLE);

  // ---------------------------------------------------------------------------
  // Source -> destination: the request.
  // ---------------------------------------------------------------------------
  wire req_dst_w;

  cdc_sync2 #(
      .WIDTH      (1),
      .STAGES     (SYNC_STAGES),
      .RST_VALUE  (1'b0),
      .GRAY_CODED (1'b0)
  ) u_sync_req (
      .clk   (dst_clk),
      .rst_n (dst_rst_n),
      .d     (req_q),
      .q     (req_dst_w)
  );

  // ---------------------------------------------------------------------------
  // Destination-domain state machine.
  // ---------------------------------------------------------------------------
  logic             ack_q;
  logic             capture_q;   // the one-cycle strobe
  logic [WIDTH-1:0] dst_data_q;

  wire dst_capture = !ack_q && req_dst_w;

  always_ff @(posedge dst_clk) begin
    if (!dst_rst_n) begin
      ack_q     <= 1'b0;
      capture_q <= 1'b0;
    end else begin
      capture_q <= dst_capture;
      if (dst_capture) begin
        ack_q <= 1'b1;
      end else if (ack_q && !req_dst_w) begin
        ack_q <= 1'b0;
      end
    end
  end

  // Payload capture: not reset (SPEC 23). `src_data_q` has been stable for at
  // least SYNC_STAGES destination cycles by the time `dst_capture` is true.
  always_ff @(posedge dst_clk) begin
    if (dst_capture) dst_data_q <= src_data_q;
  end

  assign d_valid = capture_q;
  assign d_data  = dst_data_q;

  // ---------------------------------------------------------------------------
  // Destination -> source: the acknowledge.
  // ---------------------------------------------------------------------------
  cdc_sync2 #(
      .WIDTH      (1),
      .STAGES     (SYNC_STAGES),
      .RST_VALUE  (1'b0),
      .GRAY_CODED (1'b0)
  ) u_sync_ack (
      .clk   (src_clk),
      .rst_n (src_rst_n),
      .d     (ack_q),
      .q     (ack_src_w)
  );

  // ---------------------------------------------------------------------------
  // Assertions (SPEC 14: CDC handshake completion).
  //
  // Attached in the SOURCE domain, on the request the source drives and the
  // acknowledge the source actually reacts to — the synchronized one. Watching
  // `ack_q` directly from here would be sampling a foreign clock domain in a
  // checker, which reports races the design cannot see and does not have.
  // ---------------------------------------------------------------------------
`ifndef SYNTHESIS
  cdc_handshake_checker #(
      .WIDTH          (WIDTH),
      .ACK_TIMEOUT    (ACK_TIMEOUT_CYCLES)
  ) u_chk_src (
      .clk   (src_clk),
      .rst_n (src_rst_n),
      .req   (req_q),
      .ack   (ack_src_w),
      .data  (src_data_q)
  );

  // Delivery accounting, the cdc_pulse pattern: the destination must never
  // report more captures than the source has started. Conservative by
  // construction — `src_xfer_q` is sampled in the destination domain, so it is
  // at least as old as the truth.
  logic [31:0] src_xfer_q;
  logic [31:0] dst_xfer_q;

  always_ff @(posedge src_clk) begin
    if (!src_rst_n) src_xfer_q <= 32'd0;
    else if (src_accept) src_xfer_q <= src_xfer_q + 32'd1;
  end

  always_ff @(posedge dst_clk) begin
    if (!dst_rst_n) begin
      dst_xfer_q <= 32'd0;
    end else if (capture_q) begin
      dst_xfer_q <= dst_xfer_q + 32'd1;
      a_no_phantom_transfer : assert (dst_xfer_q < src_xfer_q)
        else $error("cdc_handshake: delivered %0d values but only %0d were offered",
                    dst_xfer_q + 32'd1, src_xfer_q);
    end
  end
`endif

endmodule : cdc_handshake

`default_nettype wire
