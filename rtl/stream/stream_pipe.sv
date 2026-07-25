// -----------------------------------------------------------------------------
// stream_pipe — N-stage latency insertion with no enable and no ready chain
//               (SPEC.md 5, SPEC.md 23).
//
// What it is for: adding pipeline depth to a SPEC 5 stream — to cross a floorplan
// distance, to give Quartus registers to retime into a congested region, or to
// balance one branch of a fork against another — without any of the three things
// SPEC 23 warns about: a broad clock enable, a stalled pipeline, or a ready chain.
//
// Mechanism: credit-based fill (DECISIONS.md 2026-07-26, decision 5)
// ------------------------------------------------------------------
// The STAGES register stages are FREE-RUNNING. They have no clock enable and no
// stall condition; every cycle, every stage shifts. A beat is admitted only when
// a credit is available, and a credit is available only when the output elastic
// buffer is guaranteed to have room for that beat when it arrives. The pipeline
// therefore never needs to be told to stop, and Quartus is free to retime the
// whole delay line into Hyper-Registers.
//
//     s_valid/s_payload --[credit gate]--> STAGES free-running stages -->
//         stream_elastic_buffer (OUT_DEPTH) --> m_valid/m_payload
//
//   credits    initialised to OUT_DEPTH, decremented on admission, incremented
//              when a beat leaves the buffer. `s_ready` is the registered
//              "credits will be non-zero next cycle" flag, so the backward path
//              is a flip-flop output that no downstream signal reaches
//              combinationally.
//   OUT_DEPTH  must be at least STAGES + 2 to sustain one beat per cycle: a
//              beat admitted at cycle T leaves the buffer at T+STAGES+1 and its
//              credit is usable at T+STAGES+2, so that many credits must be in
//              flight for the gate never to close on an idle sink. It is the
//              default, and it is checked at elaboration.
//
// Alternative rejected: the textbook "N register stages sharing one advance
// enable, enable = !m_valid || m_ready". That costs no output buffer, but it
// puts `m_ready` on the enable of every stage — a fanout that grows with STAGES
// and with payload width, feeding registers Quartus can then no longer retime
// freely — and it makes `s_ready` a combinational function of `m_ready`. The
// storage this module spends (OUT_DEPTH entries) buys the removal of both.
//
// Cost and behaviour
// ------------------
//   storage     STAGES x (PAYLOAD_W + 1) registers + OUT_DEPTH x PAYLOAD_W
//   latency     STAGES + 1 with no backpressure
//               (stream_pkg::stream_pipe_latency(STAGES))
//   throughput  one beat per cycle for OUT_DEPTH >= STAGES + 2
//
// Reset (SPEC 23): synchronous, active low, applied to the valid bits, the
// credit counter and the ready flop. The delay line's payload registers are
// never reset — they are qualified by the valid bit travelling beside them,
// which is precisely "reset validity, not every datapath bit".
// -----------------------------------------------------------------------------

`default_nettype none

module stream_pipe #(
    parameter int unsigned PAYLOAD_W = 32,

    // Number of free-running forward register stages. 0 is legal and degenerates
    // to a bare elastic buffer.
    parameter int unsigned STAGES    = 1,

    // Output elastic buffer depth. The default is the smallest value that
    // sustains full throughput; a larger value adds stall tolerance.
    parameter int unsigned OUT_DEPTH = STAGES + 2,

    // Optional field geometry for the protocol checker; see stream_skid_buffer.
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

  localparam int unsigned CRED_W = $clog2(OUT_DEPTH + 1);
  localparam int unsigned OCC_W  = $clog2(OUT_DEPTH + 1);

`ifndef SYNTHESIS
  initial begin
    if (OUT_DEPTH < 2) begin
      $fatal(1, "stream_pipe: OUT_DEPTH=%0d is illegal; minimum is 2", OUT_DEPTH);
    end
    if (OUT_DEPTH < STAGES + 2) begin
      $fatal(1, "stream_pipe: OUT_DEPTH=%0d cannot sustain full throughput for STAGES=%0d (need >= %0d)",
             OUT_DEPTH, STAGES, STAGES + 2);
    end
  end
`endif

  // ---------------------------------------------------------------------------
  // Credit gate. The only backward-facing logic in the module.
  // ---------------------------------------------------------------------------
  logic [CRED_W-1:0] credits_q, credits_d;
  logic              rdy_q,     rdy_d;

  logic admit;    // a beat is admitted into the delay line this cycle
  logic release_; // a beat leaves the output buffer this cycle

  assign admit = rdy_q && s_valid;

  always_comb begin
    if (admit && !release_) begin
      credits_d = credits_q - CRED_W'(1);
    end else if (release_ && !admit) begin
      credits_d = credits_q + CRED_W'(1);
    end else begin
      credits_d = credits_q;
    end
    // rdy_q is exactly (credits_q != 0) one cycle later, so the gate is both
    // registered and exact — it never admits a beat without a credit and never
    // withholds admission while a credit exists.
    rdy_d = (credits_d != CRED_W'(0));
  end

  always_ff @(posedge clk) begin
    if (!rst_n) begin
      credits_q <= CRED_W'(OUT_DEPTH);
      rdy_q     <= 1'b0;
    end else begin
      credits_q <= credits_d;
      rdy_q     <= rdy_d;
    end
  end

  assign s_ready = rdy_q;

  // ---------------------------------------------------------------------------
  // Free-running delay line. No enable, no stall, no feedback.
  // ---------------------------------------------------------------------------
  logic                 line_valid;
  logic [PAYLOAD_W-1:0] line_payload;

  if (STAGES == 0) begin : g_no_stages
    assign line_valid   = admit;
    assign line_payload = s_payload;
  end else begin : g_stages
    logic                 vld_q [STAGES];
    logic [PAYLOAD_W-1:0] pl_q  [STAGES];

    // Validity is reset; payload is not (SPEC 23).
    always_ff @(posedge clk) begin
      if (!rst_n) begin
        for (int unsigned i = 0; i < STAGES; i++) vld_q[i] <= 1'b0;
      end else begin
        vld_q[0] <= admit;
        for (int unsigned i = 1; i < STAGES; i++) vld_q[i] <= vld_q[i-1];
      end
    end

    always_ff @(posedge clk) begin
      pl_q[0] <= s_payload;
      for (int unsigned i = 1; i < STAGES; i++) pl_q[i] <= pl_q[i-1];
    end

    assign line_valid   = vld_q[STAGES-1];
    assign line_payload = pl_q[STAGES-1];
  end

  // ---------------------------------------------------------------------------
  // Output elastic buffer. Its s_ready is guaranteed high whenever the delay
  // line presents a beat — that is what the credit accounting buys — and the
  // guarantee is asserted rather than assumed.
  // ---------------------------------------------------------------------------
  wire             buf_ready;
  wire [OCC_W-1:0] buf_occupancy;

  stream_elastic_buffer #(
      .PAYLOAD_W   (PAYLOAD_W),
      .DEPTH       (OUT_DEPTH),
      .DATA_W      (DATA_W),
      .STREAM_ID_W (STREAM_ID_W),
      .SEQ_W       (SEQ_W),
      .USER_W      (USER_W)
  ) u_out_buf (
      .clk       (clk),
      .rst_n     (rst_n),
      .s_valid   (line_valid),
      .s_ready   (buf_ready),
      .s_payload (line_payload),
      .m_valid   (m_valid),
      .m_ready   (m_ready),
      .m_payload (m_payload),
      .occupancy (buf_occupancy)
  );

  assign release_ = m_valid && m_ready;

  // ---------------------------------------------------------------------------
  // Assertions (SPEC 14).
  // ---------------------------------------------------------------------------
`ifndef SYNTHESIS
  always_ff @(posedge clk) begin
    if (rst_n) begin
      a_buffer_has_room : assert (!line_valid || buf_ready)
        else $error("stream_pipe: credit accounting failed - delay line presented a beat to a full buffer (occupancy=%0d credits=%0d)",
                    buf_occupancy, credits_q);
      a_credits_bounded : assert (credits_q <= CRED_W'(OUT_DEPTH))
        else $error("stream_pipe: credit counter %0d exceeds OUT_DEPTH=%0d", credits_q, OUT_DEPTH);
      // Every credit is either held, in the delay line, or in the buffer.
      a_credit_conservation : assert (int'(credits_q) + int'(buf_occupancy) <= int'(OUT_DEPTH))
        else $error("stream_pipe: credits (%0d) + occupancy (%0d) exceed OUT_DEPTH=%0d",
                    credits_q, buf_occupancy, OUT_DEPTH);
    end
  end
`endif

endmodule : stream_pipe

`default_nettype wire
