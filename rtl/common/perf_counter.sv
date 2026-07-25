// -----------------------------------------------------------------------------
// perf_counter — the one event counter in this design (SPEC.md 9, 13.4, #8).
//
// Every counter the register plane exposes — stream beats, stalls, idle cycles,
// frames, FIFO overflows, saturation events, CDC errors, sequence faults — is an
// instance of this module. Written once because the interesting parts are the
// parts that are easy to get subtly wrong and impossible to notice: what happens
// at the top of the range, and what a multi-register read means while the
// counter is still running.
//
// Wrap policy (SPEC 13.4 "Counter wrap testing")
// ----------------------------------------------
// SPEC 13.4 requires the long stress test to exercise counter wrap, so wrap must
// be a DEFINED behaviour rather than whatever the adder happens to do. Both
// behaviours are here, selected per instance by `SATURATE`:
//
//   SATURATE = 0  MODULO. The count is exact modulo 2**WIDTH. `wrap_pulse`
//                 fires on the cycle the counter passes its maximum and
//                 `wrapped` latches. Right for traffic counters, where the low
//                 bits are still meaningful after a wrap and the difference
//                 between two reads is the quantity anyone actually wants.
//
//   SATURATE = 1  STICKY MAXIMUM. The count stops at all-ones and stays there;
//                 `wrap_pulse` and `wrapped` report that it happened. Right for
//                 error and fault counters, where a dump taken long after the
//                 run must not report a small number because the counter went
//                 round — the same argument reg_block_fault.sv makes for its own
//                 saturating counter, now made once here.
//
// In neither mode is there an undefined overflow: the adder is one bit wider
// than the counter and the carry out is the wrap decision, so the behaviour at
// the boundary is structural rather than a property of the synthesiser.
//
// Snapshot (SPEC 9 "Snapshot and debug control")
// ----------------------------------------------
// A 64-bit counter read through a 32-bit register plane takes two accesses, and
// a set of counters that describe one interval takes as many accesses as there
// are counters. Read live, those accesses land at different times and describe
// no single instant: the low word can wrap between the two reads and report a
// beat count that never existed.
//
// So the register plane never reads a running counter. `snapshot` is a one-cycle
// strobe that latches the counter into a shadow register, and the shadow is what
// software reads. One strobe broadcast to every counter in a telemetry_block
// therefore freezes a whole set of counters at one edge, and any number of
// subsequent reads describe that edge exactly.
//
// The latched value is `count_d` — the value the counter itself takes at that
// same edge — so the snapshot includes any event in the strobe cycle and equals
// the counter's own content for the whole cycle after the strobe. Stating it
// against the counter's next state rather than its current state is what makes
// "snapshot then read" return the count of every event up to and including the
// strobe, with no off-by-one to reason about at the call site.
//
// `clear` and `snapshot` in the same cycle is defined by the same rule: the
// counter clears, `count_d` is zero, and the shadow latches zero.
//
// Gating
// ------
// `enable` is a level and `event_i` a strobe; the counter advances by `incr`
// only when both are true. Gating with a level rather than by qualifying the
// event upstream keeps a measurement window a property of the counter — a test,
// or software, can open and close the window without touching the thing being
// measured.
//
// Reset (SPEC 23): counters are control state and reset in full. A counter that
// survived reset would report a number belonging to a previous run.
// -----------------------------------------------------------------------------

`default_nettype none

module perf_counter #(
    // Counter width. 64 is legal and used for the beat/stall counters, which the
    // register plane presents as a LO/HI pair made coherent by the snapshot.
    parameter int unsigned WIDTH = 32,

    // Width of the per-event increment. 1 for an ordinary event counter (tie
    // `incr` to 1'b1); wider for a counter that accumulates a quantity rather
    // than an occurrence — the lost-beat counter in seq_checker adds the size of
    // each detected gap, not one per gap.
    parameter int unsigned INCR_W = 1,

    // 0 = modulo (wrap), 1 = sticky maximum. See the header.
    parameter bit SATURATE = 1'b0
) (
    input  wire               clk,
    input  wire               rst_n,

    // Measurement window. The counter advances only while `enable` is high.
    input  wire               enable,

    // Event strobe and its weight. `incr` is sampled only in a counting cycle.
    input  wire               event_i,
    input  wire [INCR_W-1:0]  incr,

    // Synchronous clear of the count, the shadow, the wrap flag and the
    // shadow-valid flag. One cycle wide; a level holds everything at zero.
    input  wire               clear,

    // Shadow latch strobe. See the header for exactly what is captured.
    input  wire               snapshot,

    // Live count. Correct at all times, but NOT what the register plane reads.
    output wire [WIDTH-1:0]   count,

    // Shadow: the value `count` took at the most recent `snapshot` edge.
    output wire [WIDTH-1:0]   snap,
    // A snapshot has been taken since reset or the last `clear`. Without it,
    // `snap` reads zero and a reader cannot tell "no events" from "never asked".
    output wire               snap_valid,

    // One cycle wide, on the edge at which the counter passed its maximum.
    output wire               wrap_pulse,
    // Sticky form of the same event, cleared by `clear`.
    output wire               wrapped
);

  // The adder is one bit wider than the counter; its carry out IS the wrap.
  localparam int unsigned SUM_W = WIDTH + 1;

`ifndef SYNTHESIS
  initial begin
    if (WIDTH < 1) begin
      $fatal(1, "perf_counter: WIDTH=%0d is illegal; minimum is 1", WIDTH);
    end
    if (INCR_W < 1) begin
      $fatal(1, "perf_counter: INCR_W=%0d is illegal; minimum is 1", INCR_W);
    end
    if (INCR_W > WIDTH) begin
      $fatal(1, "perf_counter: INCR_W=%0d exceeds WIDTH=%0d; the carry out of a %0d-bit adder would not be the wrap condition",
             INCR_W, WIDTH, WIDTH);
    end
  end
`endif

  // ---------------------------------------------------------------------------
  // Count
  // ---------------------------------------------------------------------------
  logic [WIDTH-1:0] count_q;
  logic             wrapped_q;
  logic             wrap_q;

  wire              counting = enable && event_i;
  wire [INCR_W-1:0] amount   = counting ? incr : {INCR_W{1'b0}};

  wire [SUM_W-1:0]  sum      = {1'b0, count_q} + SUM_W'(amount);
  // Carry out of the widened add. True exactly when the count passed its
  // maximum, in both modes.
  wire              over     = sum[WIDTH];

  logic [WIDTH-1:0] count_d;
  always_comb begin
    if (SATURATE) begin
      count_d = over ? {WIDTH{1'b1}} : sum[WIDTH-1:0];
    end else begin
      count_d = sum[WIDTH-1:0];
    end
    // Clear beats everything, including an event in the same cycle: a cleared
    // counter must read zero, not one.
    if (clear) begin
      count_d = {WIDTH{1'b0}};
    end
  end

  always_ff @(posedge clk) begin
    if (!rst_n) begin
      count_q   <= {WIDTH{1'b0}};
      wrapped_q <= 1'b0;
      wrap_q    <= 1'b0;
    end else begin
      count_q   <= count_d;
      wrap_q    <= over && !clear;
      wrapped_q <= clear ? 1'b0 : (wrapped_q || over);
    end
  end

  // ---------------------------------------------------------------------------
  // Shadow
  // ---------------------------------------------------------------------------
  logic [WIDTH-1:0] snap_q;
  logic             snap_valid_q;

  always_ff @(posedge clk) begin
    if (!rst_n) begin
      snap_q       <= {WIDTH{1'b0}};
      snap_valid_q <= 1'b0;
    end else if (snapshot) begin
      // count_d, not count_q: the shadow is the value the counter itself takes
      // at this edge, so the snapshot includes this cycle's event and equals the
      // counter for the whole of the next cycle.
      snap_q       <= count_d;
      snap_valid_q <= 1'b1;
    end else if (clear) begin
      snap_q       <= {WIDTH{1'b0}};
      snap_valid_q <= 1'b0;
    end
  end

  assign count      = count_q;
  assign snap       = snap_q;
  assign snap_valid = snap_valid_q;
  assign wrap_pulse = wrap_q;
  assign wrapped    = wrapped_q;

  // ---------------------------------------------------------------------------
  // SPEC 14 assertions. Simulation only, active in the fast build, so every
  // instance of this module in the design is checked with no test-side wiring.
  // ---------------------------------------------------------------------------
`ifndef SYNTHESIS
  telemetry_assertions #(
      .WIDTH    (WIDTH),
      .SATURATE (SATURATE)
  ) u_assertions (
      .clk        (clk),
      .rst_n      (rst_n),
      .enable     (enable),
      .event_i    (event_i),
      .clear      (clear),
      .snapshot   (snapshot),
      .count      (count_q),
      .snap       (snap_q),
      .snap_valid (snap_valid_q),
      .wrap_pulse (wrap_q),
      .wrapped    (wrapped_q)
  );
`endif

endmodule : perf_counter

`default_nettype wire
