// -----------------------------------------------------------------------------
// seq_checker — end-to-end loss / duplication / reorder detection (SPEC 5, #8).
//
// SPEC 5 requires that "sequence numbers must permit end-to-end loss and
// ordering checks". This module is that check, in hardware, attachable to any
// SPEC 5 stream: give it the accepted-transfer strobe and the `stream_id`,
// `seq` and `start_of_frame` fields of that transfer and it classifies every
// beat, per stream, into exactly one of five outcomes.
//
// Why in hardware at all, when the C++ monitor already checks continuity: the
// C++ monitor watches the simulation. This watches the device. Phase 2 onward
// every kernel must report loss and reordering of its own inputs through the
// register plane (SPEC 9 "Sequence errors"), on hardware nobody is simulating,
// and a Verilator-only check cannot do that.
//
// CLASSIFICATION  (NORMATIVE — the register-map field names follow it)
// --------------------------------------------------------------------
// Per tracked stream the module holds `expect`, the sequence number the next
// beat should carry. For an accepted beat carrying `seq`, let
//
//     delta = (seq - expect) mod 2**SEQ_W
//
// and split the modular circle in half, forward and backward:
//
//   delta == 0                          IN ORDER.     expect <- seq + 1
//   delta == 2**SEQ_W - 1               DUPLICATE.    expect unchanged
//     i.e. seq is exactly the beat just accepted: the immediately preceding
//     number arriving a second time. This is what a retransmit or a doubled
//     write looks like, and it is the one backward case common enough to
//     deserve its own name and its own counter.
//   0 < delta < 2**(SEQ_W-1)            GAP (LOSS).   expect <- seq + 1
//     `delta` beats never arrived. The count of missing beats is reported on
//     `gap_size` and accumulated separately from the number of gap EVENTS, so
//     one gap of forty and forty gaps of one are distinguishable.
//   otherwise (backward, not the last)  REORDER.      expect unchanged
//     a beat from behind the current position — arriving late, or out of order.
//
// The half-circle split is what makes this work at a wrap: at SEQ_W = 16 the
// step from 0xFFFF to 0x0000 has delta 0 and is in order, and a gap that
// straddles the wrap is still a small forward delta. Nothing here special-cases
// the top of the range, which is exactly why nothing here breaks at it.
//
// A fifth outcome, UNTRACKED, is a beat on a `stream_id` at or above `N_IDS`.
// It is counted rather than ignored: an instance sized for four streams that
// silently drops everything on stream 7 would report a clean run on traffic it
// never looked at. Sizing N_IDS too small is then a visible number, not a
// silent hole.
//
// INITIALISATION AND RESYNC  (NORMATIVE)
// --------------------------------------
// A stream's expectation is unknown until its first beat, so:
//
//   * the FIRST beat of a stream after reset, after `enable` was low, or after
//     a resync, initialises `expect` to seq + 1 and is never an error. A checker
//     cannot know what the first sequence number should have been, and inventing
//     one — zero, say — would report a loss on every stream that legitimately
//     starts elsewhere.
//   * `enable` low clears every stream's "known" bit. Closing and reopening a
//     measurement window therefore starts clean, instead of reporting a gap the
//     size of everything that flowed while the window was shut.
//   * `sof_resync` high makes a beat carrying `start_of_frame` re-initialise its
//     stream, with no error, whatever it carries. For a source whose sequence
//     numbering restarts per frame this is correct; for one whose numbering is
//     continuous across frames it would mask real loss at every frame boundary,
//     which is why it is off unless asked for.
//
// `sof_resync` is a runtime input rather than an elaboration parameter, and
// telemetry_block exposes it as a CSR bit, so both behaviours are reachable in
// one build and testable against one instance. (A parameter would also leave
// `sof` unreferenced in every instance that switched the feature off, which
// `verilator --lint-only --Wall` reports and this project does not waive.)
//
// COUNTERS
// --------
// Five saturating perf_counter instances — gap events, lost beats, duplicates,
// reorders and untracked beats — sharing this module's `snapshot` strobe, so the
// five counts a register plane reads describe one instant. Saturating, not
// modulo: these are error counts, and a dump taken after a long run must not
// report a small number because the counter went round.
//
// Reset (SPEC 23): all of it. Sequence expectation, sticky flags and counts are
// control state by definition.
// -----------------------------------------------------------------------------

`default_nettype none

module seq_checker #(
    // Geometry of the stream being watched. SEQ_W >= 2: the forward/backward
    // split needs a sign bit and a magnitude.
    parameter int unsigned SEQ_W = 16,
    parameter int unsigned ID_W  = 4,

    // Streams tracked independently. Ids at or above this are counted as
    // untracked rather than folded onto a tracked stream, which would produce
    // fictitious faults out of two perfectly good streams.
    parameter int unsigned N_IDS = 4,

    // Width of the five error counters. Must be at least SEQ_W, because the
    // lost-beat counter accumulates gap sizes.
    parameter int unsigned CNT_W = 32
) (
    input  wire              clk,
    input  wire              rst_n,

    // Measurement window. Low clears every stream's expectation, so the first
    // beat after it rises re-initialises rather than reporting a gap.
    input  wire              enable,

    // Treat start_of_frame as a resync point. See the header.
    input  wire              sof_resync,

    // The watched transfer: `beat` is valid && ready on the interface, and the
    // three fields are that beat's.
    input  wire              beat,
    input  wire [ID_W-1:0]   stream_id,
    input  wire [SEQ_W-1:0]  seq,
    input  wire              sof,

    // Clears the sticky flags. A fault detected in the same cycle still sets
    // them: reg_csr_block's rule, for reg_csr_block's reason — an event lost to
    // a racing clear makes a status register lie.
    input  wire              sticky_clear,
    // Clears the five counters and their shadows.
    input  wire              count_clear,
    // Latches all five counters into their shadows, at one edge.
    input  wire              snapshot,

    // ---- classification, one cycle per accepted beat, at most one high ----
    output wire              err_gap,
    output wire              err_dup,
    output wire              err_reorder,
    output wire              err_untracked,
    // Beats missing in the gap reported this cycle; zero otherwise.
    output wire [SEQ_W-1:0]  gap_size,

    // {untracked, reorder, duplicate, gap}, sticky since the last sticky_clear.
    output wire [3:0]        sticky,

    // ---- live counts ----
    output wire [CNT_W-1:0]  cnt_gap,
    output wire [CNT_W-1:0]  cnt_lost,
    output wire [CNT_W-1:0]  cnt_dup,
    output wire [CNT_W-1:0]  cnt_reorder,
    output wire [CNT_W-1:0]  cnt_untracked,

    // ---- the same five, frozen at the last snapshot edge ----
    output wire [CNT_W-1:0]  snap_gap,
    output wire [CNT_W-1:0]  snap_lost,
    output wire [CNT_W-1:0]  snap_dup,
    output wire [CNT_W-1:0]  snap_reorder,
    output wire [CNT_W-1:0]  snap_untracked,
    // Every counter here shares one strobe, so this is the AND of all five: a
    // shadow set that is only partly valid would be a defect, not a state, and
    // reporting the conjunction makes that unrepresentable rather than merely
    // unlikely.
    output wire              snap_valid,

    // These counters saturate, so their reaching the maximum is the one
    // condition under which their values stop being absolute. Reported as an
    // event and as a sticky flag, exactly as perf_counter reports it, so a
    // consumer does not have to watch for it.
    output wire              counts_saturate_event,
    output wire              counts_saturated
);

`ifndef SYNTHESIS
  initial begin
    if (SEQ_W < 2) begin
      $fatal(1, "seq_checker: SEQ_W=%0d is illegal; the forward/backward split needs at least 2 bits",
             SEQ_W);
    end
    if (ID_W < 1) begin
      $fatal(1, "seq_checker: ID_W=%0d is illegal", ID_W);
    end
    if (N_IDS < 1) begin
      $fatal(1, "seq_checker: N_IDS=%0d is illegal", N_IDS);
    end
    if (N_IDS > (1 << ID_W)) begin
      $fatal(1, "seq_checker: N_IDS=%0d exceeds the %0d streams an ID_W=%0d field can name",
             N_IDS, (1 << ID_W), ID_W);
    end
    if (CNT_W < SEQ_W) begin
      $fatal(1, "seq_checker: CNT_W=%0d is narrower than SEQ_W=%0d; the lost-beat counter accumulates gap sizes",
             CNT_W, SEQ_W);
    end
  end
`endif

  // ---------------------------------------------------------------------------
  // Per-stream expectation
  // ---------------------------------------------------------------------------
  logic             known_q  [N_IDS];
  logic [SEQ_W-1:0] expect_q [N_IDS];

  wire in_range = (32'(stream_id) < 32'(N_IDS));
  wire active   = enable && beat;
  wire tracked  = active && in_range;

  // The selected stream's state. A loop rather than an array index so the
  // out-of-range case cannot read past the end of the array in any tool.
  logic             known_sel;
  logic [SEQ_W-1:0] expect_sel;
  always_comb begin
    known_sel  = 1'b0;
    expect_sel = {SEQ_W{1'b0}};
    for (int unsigned i = 0; i < N_IDS; i++) begin
      if (32'(stream_id) == i) begin
        known_sel  = known_q[i];
        expect_sel = expect_q[i];
      end
    end
  end

  // ---------------------------------------------------------------------------
  // Classification. See the NORMATIVE table in the header.
  // ---------------------------------------------------------------------------
  wire [SEQ_W-1:0] delta = seq - expect_sel;

  wire resync    = sof_resync && sof;
  wire judge     = known_sel && !resync;   // there is an expectation to judge against

  wire is_order  = judge && (delta == {SEQ_W{1'b0}});
  wire is_dup    = judge && (delta == {SEQ_W{1'b1}});
  wire is_gap    = judge && (delta != {SEQ_W{1'b0}}) && !delta[SEQ_W-1];
  wire is_reord  = judge && delta[SEQ_W-1] && (delta != {SEQ_W{1'b1}});

  assign err_untracked = active && !in_range;
  assign err_gap       = tracked && is_gap;
  assign err_dup       = tracked && is_dup;
  assign err_reorder   = tracked && is_reord;
  assign gap_size      = err_gap ? delta : {SEQ_W{1'b0}};

  // The expectation advances on everything that establishes a new position:
  // an initialisation, a resync, an in-order beat, or a gap (which resynchronises
  // forward, so one lost burst is one report and not one per subsequent beat).
  wire advance = tracked && (!judge || is_order || is_gap);

  always_ff @(posedge clk) begin
    if (!rst_n) begin
      for (int unsigned i = 0; i < N_IDS; i++) begin
        known_q[i]  <= 1'b0;
        expect_q[i] <= {SEQ_W{1'b0}};
      end
    end else if (!enable) begin
      for (int unsigned i = 0; i < N_IDS; i++) begin
        known_q[i] <= 1'b0;
      end
    end else if (advance) begin
      for (int unsigned i = 0; i < N_IDS; i++) begin
        if (32'(stream_id) == i) begin
          known_q[i]  <= 1'b1;
          expect_q[i] <= seq + SEQ_W'(1);
        end
      end
    end
  end

  // ---------------------------------------------------------------------------
  // Sticky flags
  // ---------------------------------------------------------------------------
  wire [3:0] events = {err_untracked, err_reorder, err_dup, err_gap};

  logic [3:0] sticky_q;
  always_ff @(posedge clk) begin
    if (!rst_n) begin
      sticky_q <= 4'd0;
    end else begin
      sticky_q <= (sticky_clear ? 4'd0 : sticky_q) | events;
    end
  end

  assign sticky = sticky_q;

  // ---------------------------------------------------------------------------
  // Counters. Saturating; one shared snapshot strobe, so the five reads that
  // follow it describe one edge.
  //
  // `enable` is tied high at each counter because the events are already gated
  // by it: gating twice would be the same window written in two places.
  // ---------------------------------------------------------------------------
  wire [4:0] snap_valid_v;
  wire [4:0] sat_pulse_v;
  wire [4:0] saturated_v;

  perf_counter #(
      .WIDTH (CNT_W), .INCR_W (1), .SATURATE (1'b1)
  ) u_cnt_gap (
      .clk (clk), .rst_n (rst_n), .enable (1'b1),
      .event_i (err_gap), .incr (1'b1),
      .clear (count_clear), .snapshot (snapshot),
      .count (cnt_gap), .snap (snap_gap), .snap_valid (snap_valid_v[0]),
      .wrap_pulse (sat_pulse_v[0]), .wrapped (saturated_v[0])
  );

  // Beats lost, not gaps seen: `incr` is the size of this gap.
  perf_counter #(
      .WIDTH (CNT_W), .INCR_W (SEQ_W), .SATURATE (1'b1)
  ) u_cnt_lost (
      .clk (clk), .rst_n (rst_n), .enable (1'b1),
      .event_i (err_gap), .incr (gap_size),
      .clear (count_clear), .snapshot (snapshot),
      .count (cnt_lost), .snap (snap_lost), .snap_valid (snap_valid_v[1]),
      .wrap_pulse (sat_pulse_v[1]), .wrapped (saturated_v[1])
  );

  perf_counter #(
      .WIDTH (CNT_W), .INCR_W (1), .SATURATE (1'b1)
  ) u_cnt_dup (
      .clk (clk), .rst_n (rst_n), .enable (1'b1),
      .event_i (err_dup), .incr (1'b1),
      .clear (count_clear), .snapshot (snapshot),
      .count (cnt_dup), .snap (snap_dup), .snap_valid (snap_valid_v[2]),
      .wrap_pulse (sat_pulse_v[2]), .wrapped (saturated_v[2])
  );

  perf_counter #(
      .WIDTH (CNT_W), .INCR_W (1), .SATURATE (1'b1)
  ) u_cnt_reorder (
      .clk (clk), .rst_n (rst_n), .enable (1'b1),
      .event_i (err_reorder), .incr (1'b1),
      .clear (count_clear), .snapshot (snapshot),
      .count (cnt_reorder), .snap (snap_reorder), .snap_valid (snap_valid_v[3]),
      .wrap_pulse (sat_pulse_v[3]), .wrapped (saturated_v[3])
  );

  perf_counter #(
      .WIDTH (CNT_W), .INCR_W (1), .SATURATE (1'b1)
  ) u_cnt_untracked (
      .clk (clk), .rst_n (rst_n), .enable (1'b1),
      .event_i (err_untracked), .incr (1'b1),
      .clear (count_clear), .snapshot (snapshot),
      .count (cnt_untracked), .snap (snap_untracked), .snap_valid (snap_valid_v[4]),
      .wrap_pulse (sat_pulse_v[4]), .wrapped (saturated_v[4])
  );

  assign snap_valid            = &snap_valid_v;
  assign counts_saturate_event = |sat_pulse_v;
  assign counts_saturated      = |saturated_v;

  // ---------------------------------------------------------------------------
  // SPEC 14 assertions on the classifier itself. Simulation only, active in the
  // fast build.
  // ---------------------------------------------------------------------------
`ifndef SYNTHESIS
  seq_checker_assertions #(
      .SEQ_W (SEQ_W)
  ) u_assertions (
      .clk           (clk),
      .rst_n         (rst_n),
      .active        (active),
      .err_gap       (err_gap),
      .err_dup       (err_dup),
      .err_reorder   (err_reorder),
      .err_untracked (err_untracked),
      .gap_size      (gap_size)
  );
`endif

endmodule : seq_checker

`default_nettype wire
