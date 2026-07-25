// ---------------------------------------------------------------------------
// benchmark_fabric_top — Phase 0 minimal fabric top (SPEC.md 15, 19 Phase 0)
// ---------------------------------------------------------------------------
// Purpose
//   Give Quartus Prime Pro something synthesizable and timing-meaningful for the
//   AGMF039R47B1E1VC project skeleton before any DSP kernel exists. This module
//   is deliberately small: it exercises the SPEC.md 5 stream field set, has
//   fully registered IO, contains no combinational passthrough from input to
//   output, and honours backpressure without a combinational ready chain.
//
//   It is NOT part of the benchmark workload. Issues #5 onward replace the
//   inline elastic buffer here with the real stream/elastic-buffer primitives.
//
// Structure
//   stream in -> 4-deep elastic input buffer -> 4 pipeline register stages ->
//   stream out
//
//   * `in_ready` is driven directly by a flip-flop (registered input handshake).
//     It is computed one cycle ahead from the buffer occupancy, so the producer
//     can never overflow the buffer: ready deasserts while occupancy would
//     otherwise reach the last two entries, and at most one beat can be in
//     flight against the one-cycle ready latency.
//   * The pipeline advances as a unit. It freezes when the final stage holds a
//     valid beat that the consumer is not accepting, which preserves both data
//     and bubbles under arbitrary backpressure.
//   * All stream outputs are register outputs.
//
// Note on SPEC.md 5 field naming: the spec lists a field named `sequence`,
// which is a SystemVerilog reserved word. The ports are therefore named
// `in_sequence` / `out_sequence`; the field semantics are unchanged.
// ---------------------------------------------------------------------------

`default_nettype none

module benchmark_fabric_top #(
    parameter int DATA_W      = 64,
    parameter int STREAM_ID_W = 8,
    parameter int SEQ_W       = 32,
    parameter int USER_W      = 8
) (
    input  wire                    core_clk,
    input  wire                    rst_n,

    // --- stream input (SPEC.md 5) ---
    input  wire                    in_valid,
    output wire                    in_ready,
    input  wire [DATA_W-1:0]       in_data,
    input  wire                    in_start_of_frame,
    input  wire                    in_end_of_frame,
    input  wire [STREAM_ID_W-1:0]  in_stream_id,
    input  wire [SEQ_W-1:0]        in_sequence,
    input  wire [USER_W-1:0]       in_user,

    // --- stream output (SPEC.md 5) ---
    output wire                    out_valid,
    input  wire                    out_ready,
    output wire [DATA_W-1:0]       out_data,
    output wire                    out_start_of_frame,
    output wire                    out_end_of_frame,
    output wire [STREAM_ID_W-1:0]  out_stream_id,
    output wire [SEQ_W-1:0]        out_sequence,
    output wire [USER_W-1:0]       out_user
);

  // Packed payload layout: metadata in the low bits, data in the high bits.
  localparam int META_W  = 2 + STREAM_ID_W + SEQ_W + USER_W;
  localparam int PAYLD_W = DATA_W + META_W;

  localparam int SOF_LSB = 0;
  localparam int EOF_LSB = 1;
  localparam int SID_LSB = 2;
  localparam int SEQ_LSB = SID_LSB + STREAM_ID_W;
  localparam int USR_LSB = SEQ_LSB + SEQ_W;
  localparam int DAT_LSB = USR_LSB + USER_W;

  localparam int BUF_DEPTH = 4;
  localparam int PIPE_STAGES = 4;

  wire [PAYLD_W-1:0] in_payload;
  assign in_payload[SOF_LSB]                     = in_start_of_frame;
  assign in_payload[EOF_LSB]                     = in_end_of_frame;
  assign in_payload[SID_LSB +: STREAM_ID_W]      = in_stream_id;
  assign in_payload[SEQ_LSB +: SEQ_W]            = in_sequence;
  assign in_payload[USR_LSB +: USER_W]           = in_user;
  assign in_payload[DAT_LSB +: DATA_W]           = in_data;

  // -------------------------------------------------------------------------
  // Elastic input buffer (4 entries, registered ready)
  // -------------------------------------------------------------------------
  reg  [PAYLD_W-1:0] buf_mem  [0:BUF_DEPTH-1];
  reg  [1:0]         buf_wr;
  reg  [1:0]         buf_rd;
  reg  [2:0]         buf_count;
  reg                in_ready_q;

  assign in_ready = in_ready_q;

  wire pipe_adv;                                   // pipeline accepts a beat
  wire buf_rvalid = (buf_count != 3'd0);
  wire buf_push   = in_valid  & in_ready_q;
  wire buf_pop    = buf_rvalid & pipe_adv;

  wire [2:0] buf_count_next = buf_count
                            + (buf_push ? 3'd1 : 3'd0)
                            - (buf_pop  ? 3'd1 : 3'd0);

  wire [PAYLD_W-1:0] buf_dout = buf_mem[buf_rd];

  always @(posedge core_clk) begin
    if (!rst_n) begin
      buf_wr     <= 2'd0;
      buf_rd     <= 2'd0;
      buf_count  <= 3'd0;
      in_ready_q <= 1'b0;
    end else begin
      if (buf_push) begin
        buf_mem[buf_wr] <= in_payload;
        buf_wr          <= buf_wr + 2'd1;
      end
      if (buf_pop) begin
        buf_rd <= buf_rd + 2'd1;
      end
      buf_count <= buf_count_next;
      // Computed one cycle ahead: with a one-cycle ready latency at most one
      // extra beat can arrive, so occupancy never exceeds BUF_DEPTH.
      in_ready_q <= (buf_count_next <= 3'd2);
    end
  end

  // -------------------------------------------------------------------------
  // Four pipeline register stages
  // -------------------------------------------------------------------------
  reg  [PIPE_STAGES-1:0]   stage_valid;
  reg  [PAYLD_W-1:0]       stage_payload [0:PIPE_STAGES-1];

  // Freeze the whole pipeline while the consumer stalls the final stage. This
  // preserves data and bubble positions under arbitrary backpressure.
  assign pipe_adv = out_ready | ~stage_valid[PIPE_STAGES-1];

  // Per-stage payload transform. Metadata is carried through unchanged; the
  // data word is mixed so the stages cannot be merged or optimized away.
  function automatic [PAYLD_W-1:0] mix(input [PAYLD_W-1:0] p, input int unsigned stage);
    reg [DATA_W-1:0] d;
    reg [SEQ_W-1:0]  s;
    begin
      d = p[DAT_LSB +: DATA_W];
      s = p[SEQ_LSB +: SEQ_W];
      case (stage)
        0:       d = d ^ {d[DATA_W-2:0], d[DATA_W-1]};
        1:       d = d + {{(DATA_W-SEQ_W){1'b0}}, s};
        2:       d = {d[DATA_W/2-1:0], d[DATA_W-1:DATA_W/2]};
        default: d = d ^ {{(DATA_W-SEQ_W){1'b0}}, ~s};
      endcase
      mix = p;
      mix[DAT_LSB +: DATA_W] = d;
    end
  endfunction

  integer i;
  always @(posedge core_clk) begin
    if (!rst_n) begin
      stage_valid <= {PIPE_STAGES{1'b0}};
    end else if (pipe_adv) begin
      stage_valid[0]   <= buf_pop;
      stage_payload[0] <= mix(buf_dout, 0);
      for (i = 1; i < PIPE_STAGES; i = i + 1) begin
        stage_valid[i]   <= stage_valid[i-1];
        stage_payload[i] <= mix(stage_payload[i-1], i);
      end
    end
  end

  // -------------------------------------------------------------------------
  // Registered stream output
  // -------------------------------------------------------------------------
  wire [PAYLD_W-1:0] out_payload = stage_payload[PIPE_STAGES-1];

  assign out_valid          = stage_valid[PIPE_STAGES-1];
  assign out_start_of_frame = out_payload[SOF_LSB];
  assign out_end_of_frame   = out_payload[EOF_LSB];
  assign out_stream_id      = out_payload[SID_LSB +: STREAM_ID_W];
  assign out_sequence       = out_payload[SEQ_LSB +: SEQ_W];
  assign out_user           = out_payload[USR_LSB +: USER_W];
  assign out_data           = out_payload[DAT_LSB +: DATA_W];

endmodule

`default_nettype wire
