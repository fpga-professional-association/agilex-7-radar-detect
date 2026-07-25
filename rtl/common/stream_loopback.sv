// -----------------------------------------------------------------------------
// stream_loopback — provisional two-stage streaming pass-through.
//
// Governing spec: SPEC.md 5 (Streaming Protocol), SPEC.md 19 (Phase 0:
// "One trivial stream loopback test").
//
// PROVISIONAL. This module exists only so that the Phase 0 Verilator harness
// (clock scheduler, reset sequencer, stream driver/monitor, scoreboard) has a
// protocol-correct DUT to exercise before any real datapath exists. The real
// stream interface, elastic buffer and skid buffer, together with the full
// protocol assertion set, are owned by issue #5 and will replace the storage
// element implemented here. Do not build datapath logic on top of this module.
//
// Structure
// ---------
// STAGES cascaded skid stages carrying the complete SPEC 5 bundle
// (data / start_of_frame / end_of_frame / stream_id / sequence / user) as one
// packed payload vector. Each stage is a full-throughput skid buffer:
//
//   * one output register + one skid register  -> two beats of storage,
//   * s_ready is a register output, so there is no combinational path from any
//     downstream ready to any upstream ready (SPEC 5: "No combinational ready
//     loop may cross more than one module boundary" — here it crosses none),
//   * a beat accepted into a stage is held bit-stable until it is transferred
//     out (SPEC 5: "A source must hold payload and metadata stable while
//     stalled"),
//   * back-to-back transfers are sustained at one beat per cycle when neither
//     side stalls.
//
// Reset: synchronous, active low. SPEC 23 ("avoid asynchronous resets in
// performance-critical pipelines") makes synchronous reset the default for
// datapath logic; SPEC 8 ("avoid resetting every datapath register") means only
// control state — the valid bits and the ready bit — is reset, and the payload
// registers are flushed by validity tracking instead.
// -----------------------------------------------------------------------------

`default_nettype none

module stream_loopback #(
    parameter int unsigned DATA_W      = 32,
    parameter int unsigned STREAM_ID_W = 4,
    parameter int unsigned SEQ_W       = 16,
    parameter int unsigned USER_W      = 4,
    // Number of cascaded skid stages. Two is the Phase 0 configuration and the
    // minimum that proves a multi-stage handshake; the parameter exists so the
    // harness can be re-pointed at a deeper pipeline without editing the RTL.
    parameter int unsigned STAGES      = 2
) (
    input  logic                   clk,
    input  logic                   rst_n,

    // Slave (input) side of the provisional SPEC 5 stream bundle.
    input  logic                   s_valid,
    output logic                   s_ready,
    input  logic [DATA_W-1:0]      s_data,
    input  logic                   s_start_of_frame,
    input  logic                   s_end_of_frame,
    input  logic [STREAM_ID_W-1:0] s_stream_id,
    input  logic [SEQ_W-1:0]       s_sequence,
    input  logic [USER_W-1:0]      s_user,

    // Master (output) side.
    output logic                   m_valid,
    input  logic                   m_ready,
    output logic [DATA_W-1:0]      m_data,
    output logic                   m_start_of_frame,
    output logic                   m_end_of_frame,
    output logic [STREAM_ID_W-1:0] m_stream_id,
    output logic [SEQ_W-1:0]       m_sequence,
    output logic [USER_W-1:0]      m_user
);

  // Packed payload: every field of the SPEC 5 bundle except valid/ready.
  localparam int unsigned PAYLOAD_W = DATA_W + 1 + 1 + STREAM_ID_W + SEQ_W + USER_W;

  logic [PAYLOAD_W-1:0] stage_payload [STAGES+1];
  logic                 stage_valid   [STAGES+1];
  logic                 stage_ready   [STAGES+1];

  // Stage 0 input is the module's slave port.
  assign stage_payload[0] = {s_data, s_start_of_frame, s_end_of_frame,
                             s_stream_id, s_sequence, s_user};
  assign stage_valid[0]   = s_valid;
  assign s_ready          = stage_ready[0];

  for (genvar g = 0; g < int'(STAGES); g++) begin : gen_stage
    // ---------------------------------------------------------------------
    // Full-throughput skid stage.
    //
    //   out_*  : the beat currently presented downstream
    //   skid_* : the overflow beat captured while the output slot was stalled
    //   rdy_q  : registered upstream ready; asserted iff the skid slot will be
    //            free next cycle, which guarantees room for any beat accepted
    //            while it is high.
    // ---------------------------------------------------------------------
    logic [PAYLOAD_W-1:0] out_payload_q,  out_payload_d;
    logic                 out_valid_q,    out_valid_d;
    logic [PAYLOAD_W-1:0] skid_payload_q, skid_payload_d;
    logic                 skid_valid_q,   skid_valid_d;
    logic                 rdy_q,          rdy_d;

    logic accept;     // an upstream beat transfers into this stage this cycle
    logic emit;       // the output beat transfers downstream this cycle
    logic slot_free;  // the output register is free (or frees) this cycle
    logic taken;      // the accepted beat went straight into the output slot

    always_comb begin
      accept    = rdy_q && stage_valid[g];
      emit      = out_valid_q && stage_ready[g+1];
      slot_free = emit || !out_valid_q;

      out_payload_d  = out_payload_q;
      out_valid_d    = out_valid_q && !emit;
      skid_payload_d = skid_payload_q;
      skid_valid_d   = skid_valid_q;
      taken          = 1'b0;

      if (slot_free) begin
        if (skid_valid_q) begin
          // Drain the skid slot first to preserve ordering. accept is
          // necessarily 0 here because rdy_q == !skid_valid_q.
          out_payload_d = skid_payload_q;
          out_valid_d   = 1'b1;
          skid_valid_d  = 1'b0;
        end else if (accept) begin
          out_payload_d = stage_payload[g];
          out_valid_d   = 1'b1;
          taken         = 1'b1;
        end
      end

      if (accept && !taken) begin
        // Output slot busy and stalled: the accepted beat skids.
        skid_payload_d = stage_payload[g];
        skid_valid_d   = 1'b1;
      end

      // Room exists next cycle exactly when the skid slot will be empty.
      rdy_d = !skid_valid_d;
    end

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

    // Payload registers carry no reset; they are qualified by the valid bits.
    always_ff @(posedge clk) begin
      out_payload_q  <= out_payload_d;
      skid_payload_q <= skid_payload_d;
    end

    assign stage_payload[g+1] = out_payload_q;
    assign stage_valid[g+1]   = out_valid_q;
    assign stage_ready[g]     = rdy_q;
  end : gen_stage

  // Final stage output is the module's master port.
  assign m_valid             = stage_valid[STAGES];
  assign stage_ready[STAGES] = m_ready;
  assign {m_data, m_start_of_frame, m_end_of_frame,
          m_stream_id, m_sequence, m_user} = stage_payload[STAGES];

  // ---------------------------------------------------------------------
  // Provisional protocol assertions (SPEC 14). Compiled only when Verilator
  // is invoked with --assert. The complete stream assertion set is issue #5;
  // these two cover exactly what this module and its driver promise.
  // ---------------------------------------------------------------------

  // DUT promise: a stalled master holds valid and the whole payload stable.
  property p_master_stable;
    @(posedge clk) disable iff (!rst_n)
      (m_valid && !m_ready) |=> (m_valid && $stable(stage_payload[STAGES]));
  endproperty
  a_master_stable : assert property (p_master_stable);

  // Driver promise (checks the C++ stream driver, not the RTL): a stalled
  // source holds valid and the whole payload stable.
  property p_slave_stable;
    @(posedge clk) disable iff (!rst_n)
      (s_valid && !s_ready) |=> (s_valid && $stable(stage_payload[0]));
  endproperty
  a_slave_stable : assert property (p_slave_stable);

endmodule : stream_loopback

`default_nettype wire
