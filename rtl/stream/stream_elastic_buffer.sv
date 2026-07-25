// -----------------------------------------------------------------------------
// stream_elastic_buffer — parameterised-depth elastic buffer (SPEC.md 5, 23).
//
// SPEC 5: "Insert elastic buffers where needed." SPEC 23: "Break ready/valid
// feedback with elastic buffers." This is the module that does it, at any depth
// from 2 upward, in distributed registers rather than an M20K — the memory
// FIFOs and the CDC crossings are issue #6's, and are a different cost class.
//
// The ready feedback is broken completely: `s_ready` is a flip-flop output whose
// input depends only on this buffer's own occupancy. Nothing downstream —
// neither `m_ready` nor anything it is a function of — reaches `s_ready` in the
// same cycle, at any depth.
//
// Why a registered ready is safe
// ------------------------------
// `s_ready` is asserted for the next cycle exactly when at least one slot will
// be free then (`count_d < DEPTH`). At most one beat can be accepted per cycle,
// so one free slot is always enough to absorb whatever the producer sends
// against the one-cycle ready latency. That is the whole overflow argument, and
// it is asserted below rather than left as a comment.
//
// Cost and behaviour
// ------------------
//   storage     DEPTH x PAYLOAD_W distributed registers, one read port
//   latency     1 cycle unloaded (stream_pkg::STREAM_ELASTIC_LATENCY)
//   throughput  one beat per cycle sustained for any DEPTH >= 2
//   occupancy   exported, 0..DEPTH, for credit schemes and telemetry (issue #8)
//
// DEPTH == 2 is the two-deep register slice that gives higher stall tolerance
// than a single skid without a FIFO's cost — the `reg_slice_2deep` of the issue
// #5 task list, delivered as a parameter value rather than as a second module
// (DECISIONS.md 2026-07-26, decision 4).
//
// Reset (SPEC 23 "Reset validity, not every datapath bit"): synchronous, active
// low, applied to the pointers, the occupancy counter and the ready flop only.
// The payload array is NEVER reset — resetting DEPTH x PAYLOAD_W flops would
// build a reset fanout that scales with the buffer and pin every one of those
// registers out of Hyper-Register retiming for no functional gain. Correctness
// comes from the occupancy counter: an entry is unreadable until it is written.
// -----------------------------------------------------------------------------

`default_nettype none

module stream_elastic_buffer #(
    parameter int unsigned PAYLOAD_W = 32,

    // Entries of storage. Minimum 2 (checked at elaboration): a depth-1 buffer
    // cannot both accept and present a beat in the same cycle with a registered
    // ready, so it would halve throughput. Use stream_skid_buffer when two beats
    // of storage are all that is wanted.
    parameter int unsigned DEPTH     = 4,

    // Optional field geometry for the protocol checker; see stream_skid_buffer.
    parameter int unsigned DATA_W      = 0,
    parameter int unsigned STREAM_ID_W = 0,
    parameter int unsigned SEQ_W       = 0,
    parameter int unsigned USER_W      = 0
) (
    input  wire                        clk,
    input  wire                        rst_n,

    // Slave (upstream) side.
    input  wire                        s_valid,
    output wire                        s_ready,
    input  wire [PAYLOAD_W-1:0]        s_payload,

    // Master (downstream) side.
    output wire                        m_valid,
    input  wire                        m_ready,
    output wire [PAYLOAD_W-1:0]        m_payload,

    // Current fill level, 0..DEPTH. Combinational from the counter register.
    output wire [$clog2(DEPTH+1)-1:0]  occupancy
);

  localparam int unsigned OCC_W = $clog2(DEPTH + 1);
  localparam int unsigned PTR_W = (DEPTH <= 1) ? 1 : $clog2(DEPTH);

`ifndef SYNTHESIS
  initial begin
    if (DEPTH < 2) begin
      $fatal(1, "stream_elastic_buffer: DEPTH=%0d is illegal; minimum is 2 (use stream_skid_buffer for two beats of storage)",
             DEPTH);
    end
  end
`endif

  // Payload array. Distributed registers by construction: DEPTH is small and
  // the read is a mux, so no synthesis attribute is needed to keep it out of an
  // M20K. Deliberately not reset.
  logic [PAYLOAD_W-1:0] mem [DEPTH];

  logic [PTR_W-1:0] wr_ptr_q, wr_ptr_d;
  logic [PTR_W-1:0] rd_ptr_q, rd_ptr_d;
  logic [OCC_W-1:0] count_q,  count_d;
  logic             rdy_q,    rdy_d;

  logic wr_en;  // a beat is accepted from upstream this cycle
  logic rd_en;  // a beat transfers downstream this cycle

  assign wr_en = rdy_q && s_valid;
  assign rd_en = (count_q != OCC_W'(0)) && m_ready;

  always_comb begin
    wr_ptr_d = wr_ptr_q;
    rd_ptr_d = rd_ptr_q;

    if (wr_en) begin
      wr_ptr_d = (wr_ptr_q == PTR_W'(DEPTH - 1)) ? PTR_W'(0) : (wr_ptr_q + PTR_W'(1));
    end
    if (rd_en) begin
      rd_ptr_d = (rd_ptr_q == PTR_W'(DEPTH - 1)) ? PTR_W'(0) : (rd_ptr_q + PTR_W'(1));
    end

    if (wr_en && !rd_en) begin
      count_d = count_q + OCC_W'(1);
    end else if (rd_en && !wr_en) begin
      count_d = count_q - OCC_W'(1);
    end else begin
      count_d = count_q;
    end

    // Assert ready for the next cycle iff a slot will be free then. This is the
    // only expression in the module that decides acceptance, and it reads no
    // downstream signal.
    rdy_d = (count_d < OCC_W'(DEPTH));
  end

  // Control state: reset.
  always_ff @(posedge clk) begin
    if (!rst_n) begin
      wr_ptr_q <= PTR_W'(0);
      rd_ptr_q <= PTR_W'(0);
      count_q  <= OCC_W'(0);
      rdy_q    <= 1'b0;
    end else begin
      wr_ptr_q <= wr_ptr_d;
      rd_ptr_q <= rd_ptr_d;
      count_q  <= count_d;
      rdy_q    <= rdy_d;
    end
  end

  // Payload state: never reset (SPEC 23).
  always_ff @(posedge clk) begin
    if (wr_en) mem[wr_ptr_q] <= s_payload;
  end

  assign s_ready   = rdy_q;
  assign m_valid   = (count_q != OCC_W'(0));
  assign m_payload = mem[rd_ptr_q];
  assign occupancy = count_q;

  // ---------------------------------------------------------------------------
  // Assertions (SPEC 14: FIFO overflow, FIFO underflow, illegal simultaneous
  // read/write states) plus the full stream protocol check on the master side.
  // ---------------------------------------------------------------------------
`ifndef SYNTHESIS
  // Independent shadow model of the fill level. `count_q` cannot check itself:
  // an assertion written against the same counter that drives `m_valid` and
  // `s_ready` is a tautology and catches nothing. These two free-running
  // counters are a second, deliberately naive implementation of the same
  // quantity, so a pointer or counter defect shows up as a disagreement.
  logic [31:0] wr_count_q, rd_count_q;

  always_ff @(posedge clk) begin
    if (!rst_n) begin
      wr_count_q <= 32'd0;
      rd_count_q <= 32'd0;
    end else begin
      if (wr_en) wr_count_q <= wr_count_q + 32'd1;
      if (rd_en) rd_count_q <= rd_count_q + 32'd1;
    end
  end

  always_ff @(posedge clk) begin
    if (rst_n) begin
      a_no_overflow : assert (!(wr_en && (count_q == OCC_W'(DEPTH))))
        else $error("stream_elastic_buffer: overflow - accepted a beat while full (DEPTH=%0d)",
                    DEPTH);
      a_no_underflow : assert (rd_count_q <= wr_count_q)
        else $error("stream_elastic_buffer: underflow - %0d reads against %0d writes",
                    rd_count_q, wr_count_q);
      a_occupancy_shadow : assert (int'(count_q) == int'(wr_count_q - rd_count_q))
        else $error("stream_elastic_buffer: occupancy %0d disagrees with writes-minus-reads %0d",
                    count_q, wr_count_q - rd_count_q);
      a_occupancy_bound : assert (count_q <= OCC_W'(DEPTH))
        else $error("stream_elastic_buffer: occupancy %0d exceeds DEPTH=%0d", count_q, DEPTH);
      // Simultaneous read and write is legal and is the steady state at full
      // throughput; the pointers must still track the fill level exactly.
      a_ptr_consistent : assert ((int'(count_q) % int'(DEPTH)) ==
                                 ((int'(wr_ptr_q) - int'(rd_ptr_q) + int'(DEPTH)) % int'(DEPTH)))
        else $error("stream_elastic_buffer: pointers (wr=%0d rd=%0d) disagree with occupancy %0d",
                    wr_ptr_q, rd_ptr_q, count_q);
    end
  end

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

endmodule : stream_elastic_buffer

`default_nettype wire
