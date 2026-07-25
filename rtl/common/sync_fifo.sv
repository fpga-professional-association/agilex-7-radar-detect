// -----------------------------------------------------------------------------
// sync_fifo — parameterised single-clock FIFO (SPEC.md 8, 14, 23).
//
// The general-purpose buffer for a boundary that needs real storage rather than
// decoupling. The rule set in DECISIONS.md by issue #5 still stands and this
// module does not change it: a boundary that needs only to break a ready path
// gets stream_skid_buffer or a shallow stream_elastic_buffer, never a FIFO. This
// is what you reach for when the depth is tens or hundreds of entries, when the
// storage should land in a memory block rather than in ALMs, or when the
// consumer needs occupancy, a high-water mark, or an almost-full threshold to
// drive a credit scheme (issue #8 telemetry, issue #7 register plane).
//
// Its asynchronous sibling is rtl/cdc/async_fifo.sv. The two are deliberately
// separate modules rather than one with a SAME_CLOCK parameter: the pointer
// comparison, the flag derivation and the reset contract are all different, and
// a single module hiding both would be two designs sharing a file.
//
// Interface: valid/ready on both sides, the SPEC 5 handshake, so this FIFO drops
// into a stream path without an adapter. `s_ready` is a combinational function
// of the module's own occupancy register and reads nothing from the master side,
// so it never forms a combinational ready chain (SPEC 5).
//
// Cost and behaviour
// ------------------
//   storage      DEPTH x WIDTH, in registers, MLAB or M20K per STORAGE
//   latency      0 cycles with SHOW_AHEAD, 1 cycle with the registered output
//   throughput   one beat per cycle sustained in both modes
//   flags        full, empty, almost_full, almost_empty, occupancy, high_water
//   errors       sticky overflow and underflow, plus the assertions that make
//                them provably unreachable in correct operation
//
// Reset (SPEC 23, DECISIONS.md decision 6): synchronous, active low, control
// state only — pointers, occupancy counter, output-stage validity, flags. The
// payload array is never reset. Resetting DEPTH x WIDTH flops would build a
// reset fanout that scales with the buffer, pin every one of those registers out
// of Hyper-Register retiming, and prevent M20K inference outright. Correctness
// comes from the occupancy counter: an entry is unreadable until it is written.
// -----------------------------------------------------------------------------

`default_nettype none

module sync_fifo #(
    parameter int unsigned WIDTH = 32,

    // Entries of storage. Minimum 2 (checked at elaboration). Need not be a
    // power of two: this FIFO compares a counter, not wrapped pointer bits, so
    // any depth is legal. (rtl/cdc/async_fifo.sv does require a power of two —
    // its Gray full/empty derivation depends on the pointer wrapping exactly at
    // the top of its binary range.)
    parameter int unsigned DEPTH = 16,

    // Occupancy at or above which `almost_full` asserts. Defaults to DEPTH-1,
    // i.e. "one slot left". A credit scheme sizes this to its own round-trip:
    // the threshold has to fire early enough that everything already in flight
    // still fits. Elaboration-time rather than a register, because the value is
    // a property of the surrounding topology; a run-time-writable threshold, if
    // one is ever wanted, belongs to the register plane (issue #7) and arrives
    // as an input port then.
    parameter int unsigned ALMOST_FULL_THRESHOLD = (DEPTH > 1) ? (DEPTH - 1) : 1,

    // Occupancy at or below which `almost_empty` asserts.
    parameter int unsigned ALMOST_EMPTY_THRESHOLD = 1,

    // Output timing.
    //   0  registered output (default). `m_data` is a flip-flop output, which is
    //      what a downstream timing path wants and what SPEC 23 asks for around
    //      memories. Costs one cycle of latency and one extra beat of storage.
    //   1  show-ahead / first-word-fall-through. `m_data` is a combinational read
    //      of the storage array, so the head beat is visible the cycle it is
    //      written. Zero latency, but the array read is on the downstream
    //      timing path and the array cannot be an M20K.
    parameter bit SHOW_AHEAD = 1'b0,

    // Storage geometry. This is the knob that matters for the SPEC 11 full-scale
    // M20K budget, so it is a parameter from the start rather than something to
    // retrofit once the block count is measured:
    //   "regs"  ALM registers. Right for shallow, wide, or latency-critical.
    //   "mlab"  LUT-RAM. Right for a few hundred bits at any depth up to ~64.
    //   "m20k"  block RAM. Right for deep storage; requires SHOW_AHEAD=0,
    //           because an M20K read port is registered and cannot present the
    //           head beat combinationally. Checked at elaboration.
    // The value selects a literal `ramstyle` attribute below rather than being
    // substituted into one: Quartus wants a string literal there, and Verilator
    // does not count a parameter read inside an attribute as a use of the
    // parameter (measured — it reports UNUSEDPARAM).
    parameter string STORAGE = "regs"
) (
    input  wire                 clk,
    input  wire                 rst_n,

    // Slave (write) side.
    input  wire                 s_valid,
    output wire                 s_ready,
    input  wire [WIDTH-1:0]     s_data,

    // Master (read) side.
    output wire                 m_valid,
    input  wire                 m_ready,
    output wire [WIDTH-1:0]     m_data,

    // Status. `occupancy` counts the storage array only; with the registered
    // output stage one further beat may be held in it, so the module's total
    // capacity is DEPTH + 1 - SHOW_AHEAD and `occupancy` is the array's share.
    output wire [$clog2(DEPTH+1)-1:0] occupancy,
    output wire                 full,
    output wire                 empty,
    output wire                 almost_full,
    output wire                 almost_empty,

    // Sticky maximum of `occupancy` since the last clear. The number that sizes
    // the next revision of DEPTH, and the one issue #8 exports as telemetry.
    output wire [$clog2(DEPTH+1)-1:0] high_water,

    // Sticky error flags. Both are unreachable in correct operation — the
    // assertions below prove it — so either one set is a design defect, not a
    // traffic condition. They exist because a defect that appears once in a long
    // run must still be visible at the end of it.
    output wire                 overflow_sticky,
    output wire                 underflow_sticky,

    // Clears `high_water` and both sticky flags, synchronously. Tie low if
    // unused.
    input  wire                 sticky_clear
);

  // Port widths are written as $clog2(DEPTH+1) rather than as OCC_W: a localparam
  // declared in the module body is not visible in the port list, and adding a
  // width parameter to the port list would let an instantiator override it.
  localparam int unsigned OCC_W = $clog2(DEPTH + 1);
  localparam int unsigned PTR_W = (DEPTH <= 1) ? 1 : $clog2(DEPTH);

`ifndef SYNTHESIS
  initial begin
    if (DEPTH < 2) begin
      $fatal(1, "sync_fifo: DEPTH=%0d is illegal; minimum is 2 (use stream_skid_buffer for two beats of decoupling)",
             DEPTH);
    end
    if (WIDTH < 1) begin
      $fatal(1, "sync_fifo: WIDTH=%0d is illegal", WIDTH);
    end
    if (ALMOST_FULL_THRESHOLD < 1 || ALMOST_FULL_THRESHOLD > DEPTH) begin
      $fatal(1, "sync_fifo: ALMOST_FULL_THRESHOLD=%0d is outside 1..DEPTH (DEPTH=%0d)",
             ALMOST_FULL_THRESHOLD, DEPTH);
    end
    if (ALMOST_EMPTY_THRESHOLD > DEPTH) begin
      $fatal(1, "sync_fifo: ALMOST_EMPTY_THRESHOLD=%0d exceeds DEPTH=%0d",
             ALMOST_EMPTY_THRESHOLD, DEPTH);
    end
    if (STORAGE != "regs" && STORAGE != "mlab" && STORAGE != "m20k") begin
      $fatal(1, "sync_fifo: STORAGE=\"%s\" is not one of regs, mlab, m20k", STORAGE);
    end
    if (STORAGE == "m20k" && SHOW_AHEAD) begin
      $fatal(1, "sync_fifo: STORAGE=\"m20k\" requires SHOW_AHEAD=0; an M20K read port is registered and cannot present the head beat combinationally");
    end
  end
`endif

  // ---------------------------------------------------------------------------
  // Storage
  //
  // One named generate block per style so that the `ramstyle` attribute is a
  // literal in every branch. All three branches name the block `g_store`, so
  // `g_store.mem` refers to whichever one was elaborated and the access code
  // below exists once.
  // ---------------------------------------------------------------------------
  if (STORAGE == "m20k") begin : g_store
    (* ramstyle = "M20K, no_rw_check" *) logic [WIDTH-1:0] mem [DEPTH];
  end else if (STORAGE == "mlab") begin : g_store
    (* ramstyle = "MLAB, no_rw_check" *) logic [WIDTH-1:0] mem [DEPTH];
  end else begin : g_store
    (* ramstyle = "logic" *) logic [WIDTH-1:0] mem [DEPTH];
  end

  // ---------------------------------------------------------------------------
  // Pointers and occupancy
  // ---------------------------------------------------------------------------
  logic [PTR_W-1:0] wr_ptr_q, wr_ptr_d;
  logic [PTR_W-1:0] rd_ptr_q, rd_ptr_d;
  logic [OCC_W-1:0] count_q,  count_d;
  logic [OCC_W-1:0] high_q,   high_d;
  logic             ovf_q,    unf_q;

  wire full_w  = (count_q == OCC_W'(DEPTH));
  wire empty_w = (count_q == OCC_W'(0));

  // Write acceptance. Combinational from this module's own occupancy register
  // and from nothing on the master side.
  wire s_ready_w = !full_w;
  wire wr_en     = s_valid && s_ready_w;

  // Read acceptance, from the storage array into whatever is downstream of it —
  // the output register stage, or the master port directly in show-ahead mode.
  wire              core_valid = !empty_w;
  wire [WIDTH-1:0]  core_data  = g_store.mem[rd_ptr_q];
  logic             core_ready;
  wire              rd_en      = core_valid && core_ready;

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

    // Tracks the occupancy this cycle, not the one the counter is about to
    // take. Deliberately the same semantics as async_fifo's per-domain high
    // water mark, where the next occupancy is not available cheaply: in both
    // modules `high_water` is the maximum occupancy observed up to and
    // including the PREVIOUS cycle. One rule, so one reference model checks
    // both (model/cpp/cdc/fifo_ref.h).
    high_d = (count_q > high_q) ? count_q : high_q;
  end

  // Control state: reset.
  always_ff @(posedge clk) begin
    if (!rst_n) begin
      wr_ptr_q <= PTR_W'(0);
      rd_ptr_q <= PTR_W'(0);
      count_q  <= OCC_W'(0);
      high_q   <= OCC_W'(0);
      ovf_q    <= 1'b0;
      unf_q    <= 1'b0;
    end else begin
      wr_ptr_q <= wr_ptr_d;
      rd_ptr_q <= rd_ptr_d;
      count_q  <= count_d;

      if (sticky_clear) begin
        high_q <= count_q;
        ovf_q  <= 1'b0;
        unf_q  <= 1'b0;
      end else begin
        high_q <= high_d;
        if (wr_en && full_w)  ovf_q <= 1'b1;
        if (rd_en && empty_w) unf_q <= 1'b1;
      end
    end
  end

  // Payload state: never reset (SPEC 23).
  always_ff @(posedge clk) begin
    if (wr_en) g_store.mem[wr_ptr_q] <= s_data;
  end

  // ---------------------------------------------------------------------------
  // Output stage
  // ---------------------------------------------------------------------------
  if (SHOW_AHEAD) begin : g_show_ahead
    // First-word-fall-through: the array read is the master data path.
    assign core_ready = m_ready;
    assign m_valid    = core_valid;
    assign m_data     = core_data;
  end else begin : g_out_reg
    // One registered beat. `core_ready` is high whenever the register is empty
    // or is being drained this cycle, so a beat is accepted every cycle and
    // throughput is unaffected. `m_valid` and `m_data` are flip-flop outputs and
    // depend on nothing downstream in the same cycle.
    logic             out_valid_q;
    logic [WIDTH-1:0] out_data_q;

    assign core_ready = !out_valid_q || m_ready;

    always_ff @(posedge clk) begin
      if (!rst_n) begin
        out_valid_q <= 1'b0;
      end else if (core_ready) begin
        out_valid_q <= core_valid;
      end
    end

    // Payload register: no reset (SPEC 23); guarded by out_valid_q.
    always_ff @(posedge clk) begin
      if (core_ready) out_data_q <= core_data;
    end

    assign m_valid = out_valid_q;
    assign m_data  = out_data_q;
  end

  assign s_ready          = s_ready_w;
  assign occupancy        = count_q;
  assign full             = full_w;
  assign empty            = empty_w;
  assign almost_full      = (count_q >= OCC_W'(ALMOST_FULL_THRESHOLD));
  assign almost_empty     = (count_q <= OCC_W'(ALMOST_EMPTY_THRESHOLD));
  assign high_water       = high_q;
  assign overflow_sticky  = ovf_q;
  assign underflow_sticky = unf_q;

  // ---------------------------------------------------------------------------
  // Assertions (SPEC 14: FIFO overflow, FIFO underflow, illegal simultaneous
  // read/write states).
  //
  // Checked against an independent shadow model, not against `count_q`: an
  // assertion written on the same counter that drives `full` and `empty` is a
  // tautology and catches nothing. The two free-running counters below are a
  // second, deliberately naive implementation of the fill level, so a pointer or
  // counter defect appears as a disagreement.
  // ---------------------------------------------------------------------------
`ifndef SYNTHESIS
  logic [31:0] wr_count_q, rd_count_q;
  logic [OCC_W-1:0] prev_count_q;

  always_ff @(posedge clk) begin
    if (!rst_n) begin
      wr_count_q   <= 32'd0;
      rd_count_q   <= 32'd0;
      prev_count_q <= OCC_W'(0);
    end else begin
      prev_count_q <= count_q;
      if (wr_en) wr_count_q <= wr_count_q + 32'd1;
      if (rd_en) rd_count_q <= rd_count_q + 32'd1;
    end
  end

  always_ff @(posedge clk) begin
    if (rst_n) begin
      a_no_overflow : assert (!(wr_en && full_w))
        else $error("sync_fifo: overflow - accepted a beat while full (DEPTH=%0d)", DEPTH);
      a_no_underflow : assert (!(rd_en && empty_w))
        else $error("sync_fifo: underflow - read a beat while empty");
      a_occupancy_shadow : assert (int'(count_q) == int'(wr_count_q - rd_count_q))
        else $error("sync_fifo: occupancy %0d disagrees with writes-minus-reads %0d",
                    count_q, wr_count_q - rd_count_q);
      a_occupancy_bound : assert (count_q <= OCC_W'(DEPTH))
        else $error("sync_fifo: occupancy %0d exceeds DEPTH=%0d", count_q, DEPTH);
      // Simultaneous read and write is legal and is the steady state at full
      // throughput; the pointers must still track the fill level exactly.
      a_ptr_consistent : assert ((int'(count_q) % int'(DEPTH)) ==
                                 ((int'(wr_ptr_q) - int'(rd_ptr_q) + int'(DEPTH)) % int'(DEPTH)))
        else $error("sync_fifo: pointers (wr=%0d rd=%0d) disagree with occupancy %0d",
                    wr_ptr_q, rd_ptr_q, count_q);
      // `high_water` is the maximum occupancy up to and including the PREVIOUS
      // cycle, so it is compared against the previous occupancy and not the
      // current one. A shadow register holds that value; comparing against
      // `count_q` would be off by one cycle and would fail on every fill.
      a_high_water : assert (high_q >= prev_count_q)
        else $error("sync_fifo: high-water mark %0d is below the previous occupancy %0d",
                    high_q, prev_count_q);
      a_no_sticky_error : assert (!ovf_q && !unf_q)
        else $error("sync_fifo: a sticky error flag is set (overflow=%0b underflow=%0b)",
                    ovf_q, unf_q);
    end
  end
`endif

endmodule : sync_fifo

`default_nettype wire
