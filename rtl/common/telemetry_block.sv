// -----------------------------------------------------------------------------
// telemetry_block — the SPEC 9 counter groups, behind the register plane (#8).
//
// One instance watches one interface and answers the `counters` window at
// 0x7000. It is an aggregator and nothing else: every counter in it is a
// perf_counter, the sequence faults it reports come from a seq_checker beside
// it, and the register semantics come from reg_csr_block. What this module adds
// is the wiring, the snapshot discipline, and the decision about which counter
// wraps and which saturates.
//
// SPEC 9 groups served, in the order SPEC 9 lists them
// ----------------------------------------------------
//   Stream counters                BEAT_COUNT_LO/HI
//   Stall counters                 STALL_COUNT_LO/HI, IDLE_COUNT
//   FIFO high-water marks          FIFO_HIGH_WATER
//   Overflow and saturation counts OVERFLOW_COUNT, SATURATE_COUNT
//   Frame counts                   FRAME_COUNT, FRAME_START_COUNT
//   Sequence errors                SEQ_*, SEQ_STATUS
//   CDC errors                     CDC_ERROR_COUNT
//   Snapshot and debug control     TELEM_CTRL, TELEM_STATUS, SNAPSHOT_ID
//
// The ready cycle, split three ways
// ---------------------------------
// A cycle on a SPEC 5 interface is one of four things, and three of them are
// worth counting:
//
//     valid &&  ready    BEAT     work happened
//     valid && !ready    STALL    the sink refused work that was offered
//    !valid &&  ready    IDLE     the sink was willing and the source had none
//    !valid && !ready    -        nobody was ready; uninformative, uncounted
//
// Counting all three rather than beats alone is what separates "this stage is
// the bottleneck" from "this stage is starved by the one before it", which is
// the first question asked of any throughput number and is unanswerable from a
// beat count.
//
// WHY EVERY COUNT REGISTER READS A SHADOW  (NORMATIVE)
// ----------------------------------------------------
// The register plane is 32 bits and the beat counter is 64. Reading a running
// counter as two accesses returns two values from two different instants, and
// the low word can wrap between them: the pair then names a beat count that
// never existed. The same is true, less dramatically, of any two counters meant
// to describe one interval — a stall count from after the beat count was read
// can exceed the total.
//
// So software never reads a running counter here. TELEM_CTRL.SNAPSHOT broadcasts
// one strobe to every counter in this block and to the sequence checker's five,
// each latches its own shadow at that edge, and every count register reads its
// shadow. Any number of reads afterwards, in any order, describe that one edge.
// SNAPSHOT_ID counts the strobes, so a reader can prove that nobody else
// snapshotted in the middle of its sweep by reading it before and after.
//
// TELEM_STATUS.SNAP_VALID exists because the mechanism has one failure mode a
// number cannot express: before the first snapshot the shadows are zero, and
// zero is also a perfectly good count. The flag separates "nothing happened"
// from "you never asked".
//
// WRAP POLICY  (NORMATIVE — the parameter defaults state it)
// ----------------------------------------------------------
//   traffic counters (beat, stall, idle, frame, frame-start)  MODULO
//     They are rate measures. After a wrap the difference between two reads is
//     still exactly right, which is the quantity anyone actually uses, and
//     SPEC 13.4 requires the long stress test to exercise wrap rather than avoid
//     it. Each sets its own sticky WRAP_STATUS bit, so a reader always knows
//     whether the absolute value still means anything.
//
//   error counters (overflow, saturation, CDC, and the checker's five)  SATURATE
//     A dump taken long after a run must not report a small number because the
//     counter went round. reg_block_fault.sv made this argument for its own
//     counter in issue #7; it is made once here and reused.
//
// Both are parameters, because a design that wants the other trade should say so
// at elaboration rather than discovering the wrong one in a report.
//
// CLOCKING
// --------
// One clock: the domain of the interface being observed. Counting in the domain
// where the events occur is the only way to count them exactly, and the
// alternative — crossing every event into cfg_clk — would put twenty crossings
// where the design needs none.
//
// When the register plane runs in a different domain, what crosses is the
// REGISTER INTERFACE, once, with an issue #6 handshake, and not the counters.
// That is one crossing to verify instead of twenty, and the snapshot mechanism
// is what makes it correct: the cfg-side reader strobes a snapshot and then
// reads shadows that are not moving. The crossing itself belongs to the
// register path and lands with the multi-domain integration (issue #19); this
// module deliberately stops at the domain boundary rather than inventing one.
//
// Reset (SPEC 23): everything. Counters, shadows, high-water marks and sticky
// bits are control state by definition.
// -----------------------------------------------------------------------------

`default_nettype none

module telemetry_block
  import reg_if_pkg::*;
  import regmap_pkg::*;
#(
    parameter int unsigned IDX_W = REGMAP_WINDOW_W - 2,

    // Ordinary counter width. At most 32: a wider one would not fit the single
    // register that presents it, and silently truncating a telemetry counter is
    // the failure this parameter exists to make impossible.
    parameter int unsigned COUNT_W = 32,

    // Beat and stall counter width, presented as a LO/HI register pair. At most
    // 64. 64 bits at 450 MHz is 1.3 million years, so the pair never wraps in
    // any run; the modulo behaviour still exists and is still tested, because
    // the narrow configurations a unit test builds do wrap.
    parameter int unsigned WIDE_W = 64,

    // Width of the observed FIFO's fill level, and the depth it was built with.
    parameter int unsigned LEVEL_W    = 8,
    parameter int unsigned FIFO_DEPTH = 8,

    // Streams the attached seq_checker tracks. Reported in TELEM_STATUS so a
    // reader can tell an untracked-beat count from a sizing mistake.
    parameter int unsigned N_TRACKED_IDS = 4,

    // See the wrap policy above.
    parameter bit TRAFFIC_SATURATE = 1'b0,
    parameter bit ERROR_SATURATE   = 1'b1
) (
    input  wire                                  clk,
    input  wire                                  rst_n,

    // ---- register-plane port, from reg_fabric ----
    input  wire                                  sel,
    input  wire                                  write_enable,
    input  wire                                  read_enable,
    input  wire [IDX_W-1:0]                      index,
    input  wire [REG_DATA_W-1:0]                 write_data,
    input  wire [REG_STRB_W-1:0]                 byte_enable,

    output wire [REG_DATA_W-1:0]                 read_data,
    output wire                                  ready,
    output wire                                  error,

    output wire [REGMAP_COUNTERS_N_REGS*32-1:0]  csr,
    output wire [REGMAP_COUNTERS_N_REGS*32-1:0]  pulse,

    // ---- the observed SPEC 5 interface ----
    // Handshake and frame flags only: this module never looks at the payload.
    input  wire                                  obs_valid,
    input  wire                                  obs_ready,
    input  wire                                  obs_sof,
    input  wire                                  obs_eof,

    // ---- the observed storage ----
    input  wire [LEVEL_W-1:0]                    fifo_level,
    input  wire                                  fifo_overflow_event,

    // ---- the observed datapath and its crossings ----
    input  wire                                  saturate_event,
    input  wire                                  cdc_error_event,

    // ---- from the seq_checker beside this block ----
    // Pulses drive the sticky SEQ_STATUS bits; the counts are that checker's
    // SHADOWS, latched by the `snapshot` strobe this block emits, which is what
    // makes them coherent with everything else here.
    input  wire                                  seq_gap_event,
    input  wire                                  seq_dup_event,
    input  wire                                  seq_reorder_event,
    input  wire                                  seq_untracked_event,
    input  wire [COUNT_W-1:0]                    seq_gap_count,
    input  wire [COUNT_W-1:0]                    seq_lost_count,
    input  wire [COUNT_W-1:0]                    seq_dup_count,
    input  wire [COUNT_W-1:0]                    seq_reorder_count,
    input  wire [COUNT_W-1:0]                    seq_untracked_count,
    input  wire [3:0]                            seq_sticky,

    // ---- control outputs, same domain ----
    // Broadcast to every counter this block does not own — the sequence
    // checker's, and any a kernel adds — so one strobe freezes everything.
    output wire                                  snapshot_strobe,
    output wire                                  counter_clear,
    output wire                                  sticky_clear,
    output wire                                  count_enable,
    output wire                                  seq_enable,
    output wire                                  seq_sof_resync,

    // ---- live counts, for a consumer that is not the register plane ----
    // The register plane reads shadows and must; these are the running values,
    // brought out for RTL that wants a live number (a throttle, a watchdog) and
    // for a test that has to prove a shadow stayed still while its counter did
    // not. Having both visible is what makes the coherence claim checkable
    // instead of asserted.
    output wire [WIDE_W-1:0]                     live_beat_count,
    output wire [WIDE_W-1:0]                     live_stall_count,
    output wire [COUNT_W-1:0]                    live_idle_count,
    output wire [COUNT_W-1:0]                    live_frame_count,
    output wire [COUNT_W-1:0]                    live_frame_start_count,
    output wire [COUNT_W-1:0]                    live_overflow_count,
    output wire [COUNT_W-1:0]                    live_saturate_count,
    output wire [COUNT_W-1:0]                    live_cdc_error_count,
    output wire [COUNT_W-1:0]                    live_snapshot_id,
    output wire [LEVEL_W-1:0]                    live_fifo_high_water
);

  localparam int unsigned N = REGMAP_COUNTERS_N_REGS;

`ifndef SYNTHESIS
  initial begin
    if (COUNT_W < 1 || COUNT_W > 32) begin
      $fatal(1, "telemetry_block: COUNT_W=%0d is out of range 1..32; a counter must fit the register that presents it",
             COUNT_W);
    end
    if (WIDE_W < 1 || WIDE_W > 64) begin
      $fatal(1, "telemetry_block: WIDE_W=%0d is out of range 1..64", WIDE_W);
    end
    if (LEVEL_W < 1 || LEVEL_W > 16) begin
      $fatal(1, "telemetry_block: LEVEL_W=%0d is out of range 1..16", LEVEL_W);
    end
    if (FIFO_DEPTH > 16'hFFFF) begin
      $fatal(1, "telemetry_block: FIFO_DEPTH=%0d does not fit the 16-bit DEPTH field", FIFO_DEPTH);
    end
    if (N_TRACKED_IDS > 255) begin
      $fatal(1, "telemetry_block: N_TRACKED_IDS=%0d does not fit the 8-bit TRACKED_IDS field",
             N_TRACKED_IDS);
    end
  end
`endif

  // ---------------------------------------------------------------------------
  // Register file
  // ---------------------------------------------------------------------------
  wire [N*32-1:0] csr_w;
  wire [N*32-1:0] pulse_w;

  wire [31:0] ctrl_word  = csr_w  [REGMAP_COUNTERS_TELEM_CTRL_INDEX * 32 +: 32];
  wire [31:0] ctrl_pulse = pulse_w[REGMAP_COUNTERS_TELEM_CTRL_INDEX * 32 +: 32];

  assign count_enable    = ctrl_word [REGMAP_COUNTERS_TELEM_CTRL_ENABLE_LSB];
  assign seq_enable      = ctrl_word [REGMAP_COUNTERS_TELEM_CTRL_SEQ_ENABLE_LSB];
  assign seq_sof_resync  = ctrl_word [REGMAP_COUNTERS_TELEM_CTRL_SEQ_SOF_RESYNC_LSB];
  assign snapshot_strobe = ctrl_pulse[REGMAP_COUNTERS_TELEM_CTRL_SNAPSHOT_LSB];
  assign counter_clear   = ctrl_pulse[REGMAP_COUNTERS_TELEM_CTRL_CLEAR_LSB];
  assign sticky_clear    = ctrl_pulse[REGMAP_COUNTERS_TELEM_CTRL_STICKY_CLEAR_LSB];

  wire snap = snapshot_strobe;
  wire clr  = counter_clear;

  // ---------------------------------------------------------------------------
  // The three arms of a cycle, plus the frame boundaries
  // ---------------------------------------------------------------------------
  wire beat_ev  =  obs_valid &&  obs_ready;
  wire stall_ev =  obs_valid && !obs_ready;
  wire idle_ev  = !obs_valid &&  obs_ready;
  wire eof_ev   = beat_ev && obs_eof;
  wire sof_ev   = beat_ev && obs_sof;

  // ---------------------------------------------------------------------------
  // Counters. Traffic first, then the fault counters.
  // ---------------------------------------------------------------------------
  wire [WIDE_W-1:0]  beat_snap;
  wire [WIDE_W-1:0]  stall_snap;
  wire [COUNT_W-1:0] idle_snap;
  wire [COUNT_W-1:0] eof_snap;
  wire [COUNT_W-1:0] sof_snap;
  wire [COUNT_W-1:0] ovf_snap;
  wire [COUNT_W-1:0] sat_snap;
  wire [COUNT_W-1:0] cdc_snap;
  wire [COUNT_W-1:0] snapid_snap;

  // One bit per counter, in WRAP_STATUS's own bit order.
  wire [8:0] wrap_pulse_v;
  wire [8:0] wrapped_v;
  // Nine shadows, one strobe: SNAP_VALID is the conjunction, so a partly valid
  // shadow set is unrepresentable rather than merely unlikely.
  wire [8:0] snap_valid_v;

  perf_counter #(.WIDTH (WIDE_W), .INCR_W (1), .SATURATE (TRAFFIC_SATURATE)
  ) u_beat (
      .clk (clk), .rst_n (rst_n), .enable (count_enable),
      .event_i (beat_ev), .incr (1'b1), .clear (clr), .snapshot (snap),
      .count (live_beat_count), .snap (beat_snap), .snap_valid (snap_valid_v[0]),
      .wrap_pulse (wrap_pulse_v[0]), .wrapped (wrapped_v[0])
  );

  perf_counter #(.WIDTH (WIDE_W), .INCR_W (1), .SATURATE (TRAFFIC_SATURATE)
  ) u_stall (
      .clk (clk), .rst_n (rst_n), .enable (count_enable),
      .event_i (stall_ev), .incr (1'b1), .clear (clr), .snapshot (snap),
      .count (live_stall_count), .snap (stall_snap), .snap_valid (snap_valid_v[1]),
      .wrap_pulse (wrap_pulse_v[1]), .wrapped (wrapped_v[1])
  );

  perf_counter #(.WIDTH (COUNT_W), .INCR_W (1), .SATURATE (TRAFFIC_SATURATE)
  ) u_idle (
      .clk (clk), .rst_n (rst_n), .enable (count_enable),
      .event_i (idle_ev), .incr (1'b1), .clear (clr), .snapshot (snap),
      .count (live_idle_count), .snap (idle_snap), .snap_valid (snap_valid_v[2]),
      .wrap_pulse (wrap_pulse_v[2]), .wrapped (wrapped_v[2])
  );

  perf_counter #(.WIDTH (COUNT_W), .INCR_W (1), .SATURATE (TRAFFIC_SATURATE)
  ) u_frame (
      .clk (clk), .rst_n (rst_n), .enable (count_enable),
      .event_i (eof_ev), .incr (1'b1), .clear (clr), .snapshot (snap),
      .count (live_frame_count), .snap (eof_snap), .snap_valid (snap_valid_v[3]),
      .wrap_pulse (wrap_pulse_v[3]), .wrapped (wrapped_v[3])
  );

  perf_counter #(.WIDTH (COUNT_W), .INCR_W (1), .SATURATE (TRAFFIC_SATURATE)
  ) u_frame_start (
      .clk (clk), .rst_n (rst_n), .enable (count_enable),
      .event_i (sof_ev), .incr (1'b1), .clear (clr), .snapshot (snap),
      .count (live_frame_start_count), .snap (sof_snap), .snap_valid (snap_valid_v[4]),
      .wrap_pulse (wrap_pulse_v[4]), .wrapped (wrapped_v[4])
  );

  perf_counter #(.WIDTH (COUNT_W), .INCR_W (1), .SATURATE (ERROR_SATURATE)
  ) u_overflow (
      .clk (clk), .rst_n (rst_n), .enable (count_enable),
      .event_i (fifo_overflow_event), .incr (1'b1), .clear (clr), .snapshot (snap),
      .count (live_overflow_count), .snap (ovf_snap), .snap_valid (snap_valid_v[5]),
      .wrap_pulse (wrap_pulse_v[5]), .wrapped (wrapped_v[5])
  );

  perf_counter #(.WIDTH (COUNT_W), .INCR_W (1), .SATURATE (ERROR_SATURATE)
  ) u_saturate (
      .clk (clk), .rst_n (rst_n), .enable (count_enable),
      .event_i (saturate_event), .incr (1'b1), .clear (clr), .snapshot (snap),
      .count (live_saturate_count), .snap (sat_snap), .snap_valid (snap_valid_v[6]),
      .wrap_pulse (wrap_pulse_v[6]), .wrapped (wrapped_v[6])
  );

  perf_counter #(.WIDTH (COUNT_W), .INCR_W (1), .SATURATE (ERROR_SATURATE)
  ) u_cdc_error (
      .clk (clk), .rst_n (rst_n), .enable (count_enable),
      .event_i (cdc_error_event), .incr (1'b1), .clear (clr), .snapshot (snap),
      .count (live_cdc_error_count), .snap (cdc_snap), .snap_valid (snap_valid_v[7]),
      .wrap_pulse (wrap_pulse_v[7]), .wrapped (wrapped_v[7])
  );

  // SNAPSHOT_ID counts its own strobe, and is NOT gated by ENABLE: a reader must
  // be able to prove a sweep was coherent even with the measurement window shut.
  // Modulo rather than saturating, because it is an identity and not a
  // magnitude: a saturated identity would make every later sweep compare equal
  // to every other and quietly stop detecting the race it exists to detect.
  perf_counter #(.WIDTH (COUNT_W), .INCR_W (1), .SATURATE (1'b0)
  ) u_snapshot_id (
      .clk (clk), .rst_n (rst_n), .enable (1'b1),
      .event_i (snap), .incr (1'b1), .clear (clr), .snapshot (snap),
      .count (live_snapshot_id), .snap (snapid_snap), .snap_valid (snap_valid_v[8]),
      .wrap_pulse (wrap_pulse_v[8]), .wrapped (wrapped_v[8])
  );

  // ---------------------------------------------------------------------------
  // FIFO high-water mark
  //
  // Not a perf_counter: it tracks a maximum, not a sum. Same discipline though —
  // gated by the same enable, cleared by the same clear, and shadowed by the
  // same strobe, so it belongs to the same instant as everything around it.
  // ---------------------------------------------------------------------------
  logic [LEVEL_W-1:0] hwm_q;
  logic [LEVEL_W-1:0] hwm_snap_q;
  logic [LEVEL_W-1:0] hwm_d;

  always_comb begin
    hwm_d = hwm_q;
    if (count_enable && (fifo_level > hwm_q)) begin
      hwm_d = fifo_level;
    end
    if (clr) begin
      hwm_d = {LEVEL_W{1'b0}};
    end
  end

  always_ff @(posedge clk) begin
    if (!rst_n) begin
      hwm_q      <= {LEVEL_W{1'b0}};
      hwm_snap_q <= {LEVEL_W{1'b0}};
    end else begin
      hwm_q <= hwm_d;
      if (snap) begin
        hwm_snap_q <= hwm_d;
      end else if (clr) begin
        hwm_snap_q <= {LEVEL_W{1'b0}};
      end
    end
  end

  assign live_fifo_high_water = hwm_q;

  // ---------------------------------------------------------------------------
  // Hardware read values and sticky sets
  // ---------------------------------------------------------------------------
  wire [63:0] beat_wide  = 64'(beat_snap);
  wire [63:0] stall_wide = 64'(stall_snap);

  logic [N*32-1:0] hw_value;
  logic [N*32-1:0] hw_set;

  always_comb begin
    hw_value = '0;

    // ---- TELEM_STATUS ----
    hw_value[REGMAP_COUNTERS_TELEM_STATUS_INDEX*32 + REGMAP_COUNTERS_TELEM_STATUS_COUNT_W_LSB
             +: REGMAP_COUNTERS_TELEM_STATUS_COUNT_W_WIDTH] =
        REGMAP_COUNTERS_TELEM_STATUS_COUNT_W_WIDTH'(COUNT_W);
    hw_value[REGMAP_COUNTERS_TELEM_STATUS_INDEX*32 + REGMAP_COUNTERS_TELEM_STATUS_WIDE_W_LSB
             +: REGMAP_COUNTERS_TELEM_STATUS_WIDE_W_WIDTH] =
        REGMAP_COUNTERS_TELEM_STATUS_WIDE_W_WIDTH'(WIDE_W);
    hw_value[REGMAP_COUNTERS_TELEM_STATUS_INDEX*32 + REGMAP_COUNTERS_TELEM_STATUS_TRACKED_IDS_LSB
             +: REGMAP_COUNTERS_TELEM_STATUS_TRACKED_IDS_WIDTH] =
        REGMAP_COUNTERS_TELEM_STATUS_TRACKED_IDS_WIDTH'(N_TRACKED_IDS);
    hw_value[REGMAP_COUNTERS_TELEM_STATUS_INDEX*32 + REGMAP_COUNTERS_TELEM_STATUS_SNAP_VALID_LSB] =
        &snap_valid_v;
    hw_value[REGMAP_COUNTERS_TELEM_STATUS_INDEX*32 + REGMAP_COUNTERS_TELEM_STATUS_TRAFFIC_SATURATE_LSB] =
        TRAFFIC_SATURATE;
    hw_value[REGMAP_COUNTERS_TELEM_STATUS_INDEX*32 + REGMAP_COUNTERS_TELEM_STATUS_ERROR_SATURATE_LSB] =
        ERROR_SATURATE;
    hw_value[REGMAP_COUNTERS_TELEM_STATUS_INDEX*32 + REGMAP_COUNTERS_TELEM_STATUS_WRAP_ANY_LSB] =
        |wrapped_v;

    // ---- counts, every one of them a shadow ----
    hw_value[REGMAP_COUNTERS_SNAPSHOT_ID_INDEX*32       +: 32] = 32'(snapid_snap);
    hw_value[REGMAP_COUNTERS_BEAT_COUNT_LO_INDEX*32     +: 32] = beat_wide[31:0];
    hw_value[REGMAP_COUNTERS_BEAT_COUNT_HI_INDEX*32     +: 32] = beat_wide[63:32];
    hw_value[REGMAP_COUNTERS_STALL_COUNT_LO_INDEX*32    +: 32] = stall_wide[31:0];
    hw_value[REGMAP_COUNTERS_STALL_COUNT_HI_INDEX*32    +: 32] = stall_wide[63:32];
    hw_value[REGMAP_COUNTERS_IDLE_COUNT_INDEX*32        +: 32] = 32'(idle_snap);
    hw_value[REGMAP_COUNTERS_FRAME_COUNT_INDEX*32       +: 32] = 32'(eof_snap);
    hw_value[REGMAP_COUNTERS_FRAME_START_COUNT_INDEX*32 +: 32] = 32'(sof_snap);
    hw_value[REGMAP_COUNTERS_OVERFLOW_COUNT_INDEX*32    +: 32] = 32'(ovf_snap);
    hw_value[REGMAP_COUNTERS_SATURATE_COUNT_INDEX*32    +: 32] = 32'(sat_snap);
    hw_value[REGMAP_COUNTERS_CDC_ERROR_COUNT_INDEX*32   +: 32] = 32'(cdc_snap);

    hw_value[REGMAP_COUNTERS_SEQ_GAP_COUNT_INDEX*32       +: 32] = 32'(seq_gap_count);
    hw_value[REGMAP_COUNTERS_SEQ_DUP_COUNT_INDEX*32       +: 32] = 32'(seq_dup_count);
    hw_value[REGMAP_COUNTERS_SEQ_REORDER_COUNT_INDEX*32   +: 32] = 32'(seq_reorder_count);
    hw_value[REGMAP_COUNTERS_SEQ_LOST_BEATS_INDEX*32      +: 32] = 32'(seq_lost_count);
    hw_value[REGMAP_COUNTERS_SEQ_UNTRACKED_COUNT_INDEX*32 +: 32] = 32'(seq_untracked_count);

    // ---- FIFO_HIGH_WATER ----
    hw_value[REGMAP_COUNTERS_FIFO_HIGH_WATER_INDEX*32 + REGMAP_COUNTERS_FIFO_HIGH_WATER_HIGH_LSB
             +: REGMAP_COUNTERS_FIFO_HIGH_WATER_HIGH_WIDTH] =
        REGMAP_COUNTERS_FIFO_HIGH_WATER_HIGH_WIDTH'(hwm_snap_q);
    hw_value[REGMAP_COUNTERS_FIFO_HIGH_WATER_INDEX*32 + REGMAP_COUNTERS_FIFO_HIGH_WATER_DEPTH_LSB
             +: REGMAP_COUNTERS_FIFO_HIGH_WATER_DEPTH_WIDTH] =
        REGMAP_COUNTERS_FIFO_HIGH_WATER_DEPTH_WIDTH'(FIFO_DEPTH);

    // ---- SEQ_STATUS.CHECKER_STICKY ----
    hw_value[REGMAP_COUNTERS_SEQ_STATUS_INDEX*32 + REGMAP_COUNTERS_SEQ_STATUS_CHECKER_STICKY_LSB
             +: REGMAP_COUNTERS_SEQ_STATUS_CHECKER_STICKY_WIDTH] = seq_sticky;
  end

  // W1C sets. A hardware set beats a software clear in the same cycle
  // (reg_csr_block), so a fault is never lost to a racing acknowledgement.
  always_comb begin
    hw_set = '0;
    hw_set[REGMAP_COUNTERS_SEQ_STATUS_INDEX*32 + REGMAP_COUNTERS_SEQ_STATUS_GAP_LSB]       = seq_gap_event;
    hw_set[REGMAP_COUNTERS_SEQ_STATUS_INDEX*32 + REGMAP_COUNTERS_SEQ_STATUS_DUP_LSB]       = seq_dup_event;
    hw_set[REGMAP_COUNTERS_SEQ_STATUS_INDEX*32 + REGMAP_COUNTERS_SEQ_STATUS_REORDER_LSB]   = seq_reorder_event;
    hw_set[REGMAP_COUNTERS_SEQ_STATUS_INDEX*32 + REGMAP_COUNTERS_SEQ_STATUS_UNTRACKED_LSB] = seq_untracked_event;

    hw_set[REGMAP_COUNTERS_WRAP_STATUS_INDEX*32 + REGMAP_COUNTERS_WRAP_STATUS_BEAT_LSB]        = wrap_pulse_v[0];
    hw_set[REGMAP_COUNTERS_WRAP_STATUS_INDEX*32 + REGMAP_COUNTERS_WRAP_STATUS_STALL_LSB]       = wrap_pulse_v[1];
    hw_set[REGMAP_COUNTERS_WRAP_STATUS_INDEX*32 + REGMAP_COUNTERS_WRAP_STATUS_IDLE_LSB]        = wrap_pulse_v[2];
    hw_set[REGMAP_COUNTERS_WRAP_STATUS_INDEX*32 + REGMAP_COUNTERS_WRAP_STATUS_FRAME_LSB]       = wrap_pulse_v[3];
    hw_set[REGMAP_COUNTERS_WRAP_STATUS_INDEX*32 + REGMAP_COUNTERS_WRAP_STATUS_FRAME_START_LSB] = wrap_pulse_v[4];
    hw_set[REGMAP_COUNTERS_WRAP_STATUS_INDEX*32 + REGMAP_COUNTERS_WRAP_STATUS_OVERFLOW_LSB]    = wrap_pulse_v[5];
    hw_set[REGMAP_COUNTERS_WRAP_STATUS_INDEX*32 + REGMAP_COUNTERS_WRAP_STATUS_SATURATE_LSB]    = wrap_pulse_v[6];
    hw_set[REGMAP_COUNTERS_WRAP_STATUS_INDEX*32 + REGMAP_COUNTERS_WRAP_STATUS_CDC_ERROR_LSB]   = wrap_pulse_v[7];
    hw_set[REGMAP_COUNTERS_WRAP_STATUS_INDEX*32 + REGMAP_COUNTERS_WRAP_STATUS_SNAPSHOT_ID_LSB] = wrap_pulse_v[8];
  end

  assign csr   = csr_w;
  assign pulse = pulse_w;

  reg_csr_block #(
      .N_REGS     (N),
      .IDX_W      (IDX_W),
      .RESET_VAL  (REGMAP_COUNTERS_RESET),
      .WMASK      (REGMAP_COUNTERS_WMASK),
      .W1C_MASK   (REGMAP_COUNTERS_W1CMASK),
      .PULSE_MASK (REGMAP_COUNTERS_PULSEMASK),
      .HW_MASK    (REGMAP_COUNTERS_HWMASK)
  ) u_csr (
      .clk          (clk),
      .rst_n        (rst_n),
      .sel          (sel),
      .write_enable (write_enable),
      .read_enable  (read_enable),
      .index        (index),
      .write_data   (write_data),
      .byte_enable  (byte_enable),
      .read_data    (read_data),
      .ready        (ready),
      .error        (error),
      .hw_value     (hw_value),
      .hw_set       (hw_set),
      .csr          (csr_w),
      .pulse        (pulse_w)
  );

endmodule : telemetry_block

`default_nettype wire
