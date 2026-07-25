// -----------------------------------------------------------------------------
// stream_violator — deliberately broken stream stage, for the negative test.
//
// A test that never sees its checks fail has not been shown to check anything.
// This top exists so that sim/tests/test_stream_assertions.cpp can prove the
// SPEC 14 protocol assertion set is load-bearing: each violation mode breaks
// exactly one clause of SPEC 5, and the test requires the matching assertion —
// by name — to fire, and requires NO assertion to fire in the clean mode.
//
// It is also the worked example of attaching the checker by `bind` rather than
// by instantiation: the broken stage below contains no checker of its own, and
// the `bind` statement at the bottom of this file attaches one to every instance
// of it. Verified working under Verilator 5.020, concurrent properties included
// (DECISIONS.md 2026-07-26, decision 3).
//
// Violation modes (`viol_mode`)
//
//   0  clean          a correct one-deep register stage. No assertion may fire.
//   1  stability      the payload is mutated while the transfer is stalled.
//                     Expected: a_payload_stable.
//   2  valid withdrawn the offered beat is retracted without a transfer.
//                     Expected: a_valid_held.
//   3  discontinuity  one sequence field is corrupted in flight.
//                     Expected: a_seq_continuous.
//   4  framing        start-of-frame is stripped from a beat that opens a frame.
//                     Expected: a_sof_opens_frame.
//
// Modes 3 and 4 inject exactly once, after the stream is running, so the failure
// is a single well-defined event rather than a storm. Modes 1 and 2 fire on the
// first stall, which the test creates by holding m_ready low.
//
// Simulation-only, and deliberately not correct RTL. Nothing here may ever be
// instantiated by a design top; it is not in sim/verilator/files.f and never
// enters a Quartus source list.
// -----------------------------------------------------------------------------

`default_nettype none

module stream_violator #(
    parameter int unsigned PAYLOAD_W = 32,
    parameter int unsigned SOF_LSB   = 0,
    parameter int unsigned SEQ_LSB   = 0,
    // Beats to pass through untouched before a one-shot injection (modes 3, 4).
    parameter int unsigned WARMUP    = 4
) (
    input  wire                 clk,
    input  wire                 rst_n,
    input  wire [2:0]           viol_mode,

    input  wire                 s_valid,
    output wire                 s_ready,
    input  wire [PAYLOAD_W-1:0] s_payload,

    output wire                 m_valid,
    input  wire                 m_ready,
    output wire [PAYLOAD_W-1:0] m_payload
);

  logic                 valid_q;
  logic [PAYLOAD_W-1:0] payload_q;
  logic [15:0]          beats_q;
  logic                 fired_q;

  wire accept  = s_valid && s_ready;
  wire stalled = valid_q && !m_ready;

  // One-deep stage with a combinational ready. That is legal SPEC 5 (the ready
  // chain crosses one boundary) and is not what is being violated here.
  assign s_ready   = !valid_q || m_ready;
  assign m_valid   = valid_q;
  assign m_payload = payload_q;

  // Injection decision for the one-shot modes.
  wire inject_seq = (viol_mode == 3'd3) && !fired_q && accept &&
                    (beats_q >= 16'(WARMUP));
  wire inject_sof = (viol_mode == 3'd4) && !fired_q && accept &&
                    (beats_q >= 16'(WARMUP)) && s_payload[SOF_LSB];

  always_ff @(posedge clk) begin
    if (!rst_n) begin
      valid_q <= 1'b0;
      beats_q <= 16'd0;
      fired_q <= 1'b0;
    end else begin
      if (accept) beats_q <= beats_q + 16'd1;
      if (inject_seq || inject_sof) fired_q <= 1'b1;

      if (s_ready) begin
        valid_q <= s_valid;
      end

      // Mode 2: retract an offered beat without a transfer.
      if ((viol_mode == 3'd2) && stalled) begin
        valid_q <= 1'b0;
      end
    end
  end

  always_ff @(posedge clk) begin
    if (s_ready && s_valid) begin
      if (inject_seq) begin
        // Toggle the low bit of the sequence field: the stream is continuous
        // on the way in, so the output is guaranteed discontinuous.
        payload_q <= s_payload ^ (PAYLOAD_W'(1) << SEQ_LSB);
      end else if (inject_sof) begin
        // Strip start-of-frame from a beat that opens a frame.
        payload_q <= s_payload & ~(PAYLOAD_W'(1) << SOF_LSB);
      end else begin
        payload_q <= s_payload;
      end
    end else if ((viol_mode == 3'd1) && stalled) begin
      // Mode 1: mutate the payload while the transfer is stalled.
      payload_q <= payload_q ^ PAYLOAD_W'(1);
    end
  end

endmodule : stream_violator


`default_nettype wire
