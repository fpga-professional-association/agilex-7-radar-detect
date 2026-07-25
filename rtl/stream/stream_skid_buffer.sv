// -----------------------------------------------------------------------------
// stream_skid_buffer — single-stage fully-decoupling register slice (SPEC.md 5).
//
// The smallest legal SPEC 5 elastic element: two beats of storage, one beat per
// cycle sustained, and NO combinational path in either direction.
//
//   forward   m_valid and m_payload are register outputs.
//   backward  s_ready is a register output.
//
// That is the whole point of the module. A register slice that only registers
// the forward path leaves `ready` combinational, and a chain of such slices
// builds exactly the pipeline-long ready chain SPEC 5 forbids ("Do not use a
// combinational ready chain across the entire pipeline"). Here a ready chain
// crosses zero module boundaries: `s_ready` is a flip-flop output whose input
// is a function of this stage's own state only.
//
// Structure
// ---------
//   out_*   the beat currently offered downstream
//   skid_*  the overflow beat captured while the output slot was stalled
//   rdy_q   registered upstream ready, asserted exactly when the skid slot will
//           be empty next cycle. That is the invariant that makes a registered
//           ready safe: at most one beat can be accepted per cycle, so one free
//           slot is enough to absorb anything sent against the one-cycle ready
//           latency.
//
// Cost: 2 x PAYLOAD_W registers + 3 control flops. Latency 1 cycle with no
// backpressure (stream_pkg::STREAM_SKID_LATENCY). Throughput one beat per cycle.
//
// Reset (SPEC 23 "Reset validity, not every datapath bit"): synchronous, active
// low, and applied to the three control flops only. The payload registers carry
// no reset and are qualified by the valid bits — resetting them would add a
// PAYLOAD_W-wide reset fanout to a register that Quartus should be free to
// retime into Hyper-Registers.
// -----------------------------------------------------------------------------

`default_nettype none

module stream_skid_buffer #(
    // Width of the packed SPEC 5 payload. Use
    // stream_pkg::stream_payload_w(GEOM) at the instantiation site rather than
    // a literal, so the width follows the bundle definition.
    parameter int unsigned PAYLOAD_W = 32,

    // Optional field geometry, forwarded to the protocol checker so it can also
    // run the framing and sequence-continuity checks. Leave at 0 to check only
    // the payload-agnostic properties (stability, valid-held, reset).
    parameter int unsigned DATA_W      = 0,
    parameter int unsigned STREAM_ID_W = 0,
    parameter int unsigned SEQ_W       = 0,
    parameter int unsigned USER_W      = 0
) (
    input  wire                 clk,
    input  wire                 rst_n,

    // Slave (upstream) side.
    input  wire                 s_valid,
    output wire                 s_ready,
    input  wire [PAYLOAD_W-1:0] s_payload,

    // Master (downstream) side.
    output wire                 m_valid,
    input  wire                 m_ready,
    output wire [PAYLOAD_W-1:0] m_payload
);

  logic [PAYLOAD_W-1:0] out_payload_q,  out_payload_d;
  logic                 out_valid_q,    out_valid_d;
  logic [PAYLOAD_W-1:0] skid_payload_q, skid_payload_d;
  logic                 skid_valid_q,   skid_valid_d;
  logic                 rdy_q,          rdy_d;

  logic accept;     // an upstream beat transfers into this stage this cycle
  logic emit;       // the offered beat transfers downstream this cycle
  logic slot_free;  // the output register is free, or frees, this cycle
  logic taken;      // the accepted beat went straight into the output slot

  always_comb begin
    accept    = rdy_q && s_valid;
    emit      = out_valid_q && m_ready;
    slot_free = emit || !out_valid_q;

    out_payload_d  = out_payload_q;
    out_valid_d    = out_valid_q && !emit;
    skid_payload_d = skid_payload_q;
    skid_valid_d   = skid_valid_q;
    taken          = 1'b0;

    if (slot_free) begin
      if (skid_valid_q) begin
        // Drain the skid slot first, to preserve ordering. `accept` is
        // necessarily 0 here because rdy_q == !skid_valid_q.
        out_payload_d = skid_payload_q;
        out_valid_d   = 1'b1;
        skid_valid_d  = 1'b0;
      end else if (accept) begin
        out_payload_d = s_payload;
        out_valid_d   = 1'b1;
        taken         = 1'b1;
      end
    end

    if (accept && !taken) begin
      // Output slot busy and stalled: the accepted beat skids.
      skid_payload_d = s_payload;
      skid_valid_d   = 1'b1;
    end

    // Room exists next cycle exactly when the skid slot will be empty.
    rdy_d = !skid_valid_d;
  end

  // Control state: reset.
  always_ff @(posedge clk) begin
    if (!rst_n) begin
      out_valid_q  <= 1'b0;
      skid_valid_q <= 1'b0;
      rdy_q        <= 1'b0;
    end else begin
      out_valid_q  <= out_valid_d;
      skid_valid_q <= skid_valid_d;
      rdy_q        <= rdy_d;
    end
  end

  // Payload state: never reset (SPEC 23), qualified by the valid bits above.
  always_ff @(posedge clk) begin
    out_payload_q  <= out_payload_d;
    skid_payload_q <= skid_payload_d;
  end

  assign s_ready   = rdy_q;
  assign m_valid   = out_valid_q;
  assign m_payload = out_payload_q;

  // ---------------------------------------------------------------------------
  // Protocol checking (SPEC 14). Active in the SPEC 12.1 fast build.
  // ---------------------------------------------------------------------------
`ifndef SYNTHESIS
  stream_protocol_checker #(
      .PAYLOAD_W   (PAYLOAD_W),
      .DATA_W      (DATA_W),
      .STREAM_ID_W (STREAM_ID_W),
      .SEQ_W       (SEQ_W),
      .USER_W      (USER_W)
  ) u_chk_m (
      .clk     (clk),
      .rst_n   (rst_n),
      .valid   (m_valid),
      .ready   (m_ready),
      .payload (m_payload)
  );
`endif

endmodule : stream_skid_buffer

`default_nettype wire
