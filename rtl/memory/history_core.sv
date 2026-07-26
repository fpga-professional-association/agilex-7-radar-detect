// -----------------------------------------------------------------------------
// history_core — the SPEC.md 7.3 banked time-frequency history and corner turn
// (issue #15).
//
// Writes: one continuous SPEC 5 stream per antenna, in the core_clk domain,
// carrying that antenna's FFT frames frequency-sequentially.
// Reads:  a (bin, frame_offset) request port in the history_clk domain, answered
//         with the ANTENNA VECTOR for that bin — one complex sample from every
//         antenna, same bin, same frame — as a SPEC 5 stream.
//
// The address algebra that turns the first into the second, the response payload
// layout, and the rotation and overwrite policy are all stated in
// rtl/packages/history_pkg.sv. That file is normative and this one implements
// it; nothing here recomputes a mapping inline. Read history_pkg's header first
// — in particular section 1 (the corner turn as algebra) and section 5 (the read
// contract, which issue #16 depends on literally).
//
// -----------------------------------------------------------------------------
// 1. WHY THE WRITE SIDE CANNOT STALL, AND WHY THAT IS THE ARCHITECTURE
// -----------------------------------------------------------------------------
// `s_ready` is high whenever the block is enabled, for every antenna, forever.
// That is not an optimisation and not an assumption about the producer: it is a
// structural property of the banking scheme, and it is the reason the scheme was
// chosen.
//
// A write beat from antenna `a` carries LANES samples. They go to LANES
// DIFFERENT banks — banks (a,0) .. (a,LANES-1) — one word each, at one address.
// No other antenna shares those banks. No read shares those ports, because every
// bank is simple dual port with one dedicated write port. So a beat consumes
// exactly one write-port cycle on LANES banks that nothing else can want, and
// there is no arbiter, no queue and no condition under which the beat cannot be
// taken.
//
// SPEC 7.3 asks for "continuous writes". This is what continuous writes cost
// when the banking is chosen for it: nothing. The alternative shapes — a shared
// wide bank, a transpose buffer, a write crossbar — all buy read flexibility by
// making the ingest stallable, and a stalled ingest in this pipeline back-
// pressures the FFT and ultimately the front end.
//
// -----------------------------------------------------------------------------
// 2. FRAME COMPLETION IS A BARRIER ACROSS ANTENNAS
// -----------------------------------------------------------------------------
// A read wants one bin from EVERY antenna of ONE frame. A frame is therefore not
// readable until every antenna has finished writing it, and the published
// pointer is
//
//     frames_done = min over antennas a of frame_count[a]
//
// computed as a barrier rather than as a minimum tree: `frames_done` advances by
// one whenever every antenna's frame counter differs from it, which for monotone
// counters is exactly the minimum and costs N_ANT equality comparators instead
// of N_ANT-1 magnitude comparators. It is off the datapath — it moves once per
// frame, not once per beat.
//
// SKEW IS COUNTED, NOT ASSUMED AWAY. Nothing forces the antennas to stay in step,
// and an antenna that runs `depth` frames ahead of the barrier is about to
// overwrite a slot the barrier still considers live. `stat_skew_count` counts
// that, a sticky fault bit records it, and the response metadata carries a
// per-response `skew` flag, because a beamformer vector assembled across a skew
// event is the failure mode SPEC 7.4 exists to prevent and it is invisible in
// the output values.
//
// -----------------------------------------------------------------------------
// 3. WHAT CROSSES BETWEEN core_clk AND history_clk, AND WHAT DOES NOT
// -----------------------------------------------------------------------------
// SPEC 8 puts the history memory in its own domain. The seam is arranged so that
// BULK DATA NEVER CROSSES IT:
//
//   * written words are written in core_clk and read in history_clk out of a
//     dual-clock memory — but a word is only ever read after the frame
//     containing it has been published as complete, and the publication is a
//     real crossing. The memory is not being used as a synchroniser;
//   * the read request and the read response both live entirely in history_clk.
//     The consumer (issue #16, then the beamformer) is in history_clk;
//   * the register/control plane attaches on the core_clk side, because that is
//     where the write sequencers and the rotation policy live.
//
// Three crossings, one per SPEC 8 mechanism, all through rtl/cdc/ primitives:
//
//   core -> history   cdc_handshake   the publication bundle (see below)
//   core -> history   cdc_pulse       counter-clear strobe
//   history -> core   cdc_handshake   the read-side counter bundle
//
// THE PUBLICATION BUNDLE IS A HANDSHAKE AND NOT A GRAY POINTER, and the reason
// is worth stating because a Gray pointer is the obvious choice and is wrong
// here. What the read side needs is not one counter, it is a CONSISTENT SET:
// {frames_done, done_slot, depth, readable, epoch}. Gray coding is only valid
// for a single monotone counter — it guarantees that a value sampled mid-change
// resolves to the old or the new value of THAT counter, and says nothing about
// two counters sampled together. A reader that took `done_slot` from after a
// depth change and `depth` from before it would compute a slot that belongs to
// neither configuration, and would do it silently. cdc_handshake transfers the
// whole bundle as one payload that never passes through a synchroniser, which is
// exactly the case SPEC 8's multibit prohibition carves out.
//
// The cost is latency: a four-phase handshake takes a few cycles of the slower
// clock, so the read side learns about a completed frame a little late. A frame
// is BEATS_PER_FRAME core cycles long — 64 at the tiny geometry, 1024 at full
// scale — and the handshake round trip is under ten, so the publisher is never
// the limit on how fresh the pointer is. The publisher re-offers the bundle
// whenever it changes and the crossing is idle, so the read side is never more
// than one handshake behind.
//
// -----------------------------------------------------------------------------
// 4. THE FOUR SPEC 7.3 COUNTERS, AND WHAT EACH ONE ACTUALLY MEANS
// -----------------------------------------------------------------------------
// SPEC 7.3 requires occupancy, overwrite, collision and error counters. Naming
// them is easy; making each one mean something falsifiable is the work.
//
// OCCUPANCY (`stat_occupancy`) is a LEVEL, not a counter: complete frames
// currently held, min(frames_done, depth). It saturates at `depth` and it is
// exact — it counts frames the barrier has passed, so it never claims a frame
// one antenna has not finished.
//
// OVERWRITE (`stat_overwrite_count`) counts frames EVICTED, i.e. it advances on
// every frame completion after the buffer is full. It is the honest measure of
// how much history the consumer lost, and it is exactly
// max(frames_done - depth, 0) at every instant, which is what the C++ model
// asserts.
//
// ERROR (`stat_error_count`) counts requests whose `frame_off` is outside the
// readable set. The request is still ANSWERED — deterministically, clamped to
// the newest readable frame — and the response carries HIST_FLAG_OUT_OF_RANGE.
// Answering rather than dropping is deliberate: a dropped response breaks the
// one-response-per-request invariant the consumer's pipeline is built on, and
// turns a software mistake into a hang.
//
// COLLISION (`stat_collision_count`) counts responses whose addressed slot was
// the slot being written at the moment the memory was read. In correct operation
// IT IS ALWAYS ZERO, because the readable set excludes the in-flight slot by
// construction (see `readable` below) — which makes it a defect detector rather
// than a statistic, and raises the obvious problem that a counter which cannot
// fire cannot be tested.
//
// So it is made to fire on purpose. `cfg_force_unsafe` (SPEC 9's fault-injection
// group) removes the clamp, so a deliberately out-of-range request reaches the
// in-flight slot and the collision counter increments. The test exercises it and
// the C++ model predicts it exactly. A counter verified only by argument is a
// counter nobody has run.
//
// -----------------------------------------------------------------------------
// 5. THE READABLE SET, AND WHY IT IS depth-2 AND NOT depth-1
// -----------------------------------------------------------------------------
//     readable = min(frames_done, depth - 2)
//
// TWO slots short of the depth, always, and the second one is the interesting
// one. This is the double buffering SPEC 7.3 asks for, stated as an index bound
// rather than as a second buffer, and the arithmetic is where the clock-domain
// crossing shows up in the FUNCTIONAL contract and not only in the timing.
//
// The first excluded slot is obvious: when the buffer is full the oldest slot is
// not old history, it is the slot the writer is filling right now. Offering it
// would hand the consumer a frame that is half the newest and half the oldest
// and is bit-exactly neither.
//
// The second is the one that is easy to get wrong, and a `depth-1` bound is
// wrong for a reason worth writing down. The reader works from a PUBLISHED
// pointer, and publication costs a handshake. Between the moment the writer
// finishes frame F - which makes the pointer read F+1 - and the moment the read
// domain sees F+1, the writer has already begun frame F+1 and is filling
// slot(F+1). A reader still working from `frames_done = F`, allowed the full
// `depth-1` offsets, would address at its maximum offset exactly slot(F+1). It
// would be reading the slot being written, it would get a frame that is half one
// and half another, AND THE COLLISION COUNTER WOULD NOT SEE IT, because the
// collision test is made against the same stale pointer.
//
// Excluding one further slot closes it: at maximum offset the reader now
// addresses slot(F+2), which the writer reaches only after TWO more frame
// completions. One frame of publication lag is absorbed, and one frame is an
// enormous margin - a frame is BEATS_PER_FRAME core cycles (32 at the smallest
// geometry this project builds, 1024 at full scale) against a handshake round
// trip of roughly 2 x SYNC_STAGES cycles of each clock.
// `a_history_publication_fresh` checks that the margin holds rather than
// assuming it, so a future clock ratio that broke it would fail loudly and by
// name instead of as unexplained corruption at maximum frame offset.
//
// The price is one frame slot, and it is the honest price of putting the read
// side in its own clock domain. The consequence for the register plane is that a
// programmed depth of 1 or 2 makes the history unreadable - legal, reported
// through `stat_occupancy` and `HIST_FLAG_OUT_OF_RANGE`, and tested. SPEC 11's
// smallest configuration is HISTORY_FRAMES=4, which reads two frames back.
//
// -----------------------------------------------------------------------------
// 6. PROGRAMMABLE DEPTH, AND WHAT A "SAFE BOUNDARY" IS
// -----------------------------------------------------------------------------
// `cfg_depth` is 1..FRAMES_MAX and takes effect on `cfg_depth_apply`, but not
// immediately: changing the depth changes the frame-to-slot mapping, so every
// frame already stored is at an address that the new mapping would read as a
// different frame. There is no reinterpretation that preserves the data, and
// pretending otherwise would produce plausible-looking wrong answers.
//
// The apply therefore waits for a SAFE BOUNDARY — every antenna between frames,
// nothing mid-write — and then DISCARDS the history: frame counters, slots and
// occupancy all return to zero, and the new depth takes effect with an empty
// buffer. `obs_depth_pending` reports the wait, `stat_depth_active` reports what
// is actually in force, and `stat_epoch` increments on every apply so a consumer
// can tell "no frames yet" from "frames from before a reconfiguration".
//
// Discarding rather than preserving is the decision, and it is recorded in
// DECISIONS.md with the alternative (a depth change that only ever GROWS, which
// can preserve data but only from a power-of-two depth to another power-of-two
// depth, and which makes the legal transitions a table nobody will read).
//
// -----------------------------------------------------------------------------
// 7. NO GLOBALLY BROADCAST ADDRESS OR ENABLE NETWORK (SPEC 7.3, SPEC 23)
// -----------------------------------------------------------------------------
// WRITE SIDE: there is no shared write address at all. Antenna `a` owns
// `beat_q[a]`, `slot_q[a]` and its own address adder; the address fans out to
// that antenna's LANES banks and nowhere else. The fanout of a write-address
// register is LANES, independent of N_ANT.
//
// READ SIDE: one logical address per cycle is shared by N_ANT banks — that is
// what a corner turn IS. It is distributed as a two-level registered tree:
//
//     decode  ->  rd_addr_ant_q[a]  ->  history_bank's own input register
//                 (one register per antenna)      (one register per bank)
//
// so the decode register drives N_ANT loads, each per-antenna register drives at
// most LANES loads, and every bank's memory sees an address that came out of a
// flip-flop inside that bank. No register in this design drives every bank.
//
// The ENABLE is not even logically a broadcast: only the addressed LANE is
// enabled, so LANES-1 of every LANES banks are held still on any read cycle.
//
// -----------------------------------------------------------------------------
// 8. LATENCY AND BACKPRESSURE
// -----------------------------------------------------------------------------
// The read path has NO internal stall: the banks cannot backpressure, so once a
// request is accepted its response is coming whether the consumer wants it or
// not. Elasticity is therefore provided by a credit scheme in front of an output
// FIFO sized to hold everything that can be in flight: a request is accepted
// only against a reserved slot, so `push` into the output FIFO can never be
// refused. That is asserted rather than assumed
// (`a_history_out_never_blocked`).
//
// The consumer may stall `m_ready` indefinitely and nothing about the returned
// values changes — VERIFICATION_PLAN.md's backpressure-invariance test runs the
// same stimulus at four backpressure profiles and requires a byte-identical
// response sequence.
//
// Lint contract: linted by `make lint` on every run, clean under --Wall with no
// waiver.
// -----------------------------------------------------------------------------

`default_nettype none


// (* cdc_primitive *) — this module owns a core_clk/history_clk seam. It is
// tagged as a COMPOSITE, the same arrangement rtl/pfb/pfb_bank.sv and
// rtl/beamformer/beamformer.sv use over their own configuration planes: the
// inventory lists this module by name, and the real synchronisers (the two
// cdc_handshake instances, the cdc_pulse, and every history_bank) appear nested
// beneath it. Without the tag scripts/cdc_inventory.py --strict reports it as an
// untagged two-clock module, which is the correct default.
(* cdc_primitive = "history_corner_turn", cdc_src_clk = "core_clk", cdc_dst_clk = "history_clk", cdc_width = "PUB_W", cdc_stages = "SYNC_STAGES" *)
module history_core
  import history_pkg::*;
  import stream_pkg::*;
#(
    parameter int unsigned N_ANT      = 2,
    parameter int unsigned FFT_SIZE   = 64,
    parameter int unsigned LANES      = 1,
    parameter int unsigned FRAMES_MAX = 4,
    parameter int unsigned SAMPLE_W   = 16,

    // 1 when the upstream FFT runs with rtl/fft/streaming_fft.sv's REORDER = 0
    // and therefore emits bit-reversed beat order. Costs nothing here; see
    // history_pkg header section 3.
    parameter bit INPUT_BIT_REVERSED = 1'b0,

    // Storage style handed to every history_bank. "auto" lets Quartus choose,
    // which is the right default until the SPEC 18 sweep says otherwise.
    parameter string STORAGE = "auto",

    parameter int unsigned SYNC_STAGES = 2,

    // Write-stream field geometry, per antenna. DATA_W is derived and is not a
    // parameter: a write beat is LANES complex samples and nothing else.
    parameter int unsigned WR_ID_W   = 2,
    parameter int unsigned WR_SEQ_W  = 16,
    parameter int unsigned WR_USER_W = 4,

    // Read-response field geometry. DATA_W is derived from the geometry.
    parameter int unsigned RD_ID_W   = 2,
    parameter int unsigned RD_SEQ_W  = 16,
    parameter int unsigned RD_USER_W = 4,

    // Width of the core->history publication bundle. A PARAMETER rather than a
    // body localparam for one specific reason: the `(* cdc_primitive *)`
    // attribute above quotes it as this crossing's width, and
    // scripts/cdc_inventory.py resolves that name against the module's
    // parameters or as a decimal literal -- a localparam is neither, and the
    // SPEC 8 inventory would carry an unresolved width for the design's only
    // core/history seam. Derived, and overriding it is an elaboration error.
    parameter int unsigned PUB_W =
        32 + int'(hist_slot_w(hist_geom(N_ANT, FFT_SIZE, LANES, FRAMES_MAX, SAMPLE_W)))
           + 2 * int'(hist_occ_w(hist_geom(N_ANT, FFT_SIZE, LANES, FRAMES_MAX, SAMPLE_W)))
           + 1,

    // Derived port widths. Overriding either is an elaboration error: they exist
    // as parameters only because a port width must be a parameter expression.
    parameter int unsigned WR_PAYLOAD_W =
        int'(stream_payload_w(stream_geom(LANES * 2 * SAMPLE_W,
                                          WR_ID_W, WR_SEQ_W, WR_USER_W))),
    parameter int unsigned RD_PAYLOAD_W =
        int'(stream_payload_w(stream_geom(
            hist_data_w(hist_geom(N_ANT, FFT_SIZE, LANES, FRAMES_MAX, SAMPLE_W)),
            RD_ID_W, RD_SEQ_W, RD_USER_W)))
) (
    // ======================= write domain: core_clk =========================
    input  wire                          core_clk,
    input  wire                          core_rst_n,

    // One SPEC 5 slave port per antenna, flattened. Antenna `a` occupies
    // s_payload[a*WR_PAYLOAD_W +: WR_PAYLOAD_W] and bit `a` of s_valid/s_ready.
    input  wire [N_ANT-1:0]              s_valid,
    output wire [N_ANT-1:0]              s_ready,
    input  wire [N_ANT*WR_PAYLOAD_W-1:0] s_payload,

    // ---- configuration (rtl/control/reg_block_history.sv), core domain ----
    input  wire                          cfg_enable,
    input  wire [HIST_PORT_W-1:0]        cfg_depth,
    input  wire                          cfg_depth_apply,
    input  wire                          cfg_counter_clear,
    input  wire                          cfg_sticky_clear,
    // SPEC 9 fault injection: remove the readable-set clamp so an out-of-range
    // request reaches the in-flight slot. See header section 4.
    input  wire                          cfg_force_unsafe,

    // ---- status, core domain ----
    output wire [HIST_PORT_W-1:0]        stat_depth_active,
    output wire [HIST_PORT_W-1:0]        stat_occupancy,
    output wire [31:0]                   stat_frames_done,
    output wire [31:0]                   stat_overwrite_count,
    output wire [31:0]                   stat_skew_count,
    output wire [31:0]                   stat_write_beat_count,
    output wire [31:0]                   stat_read_count,
    output wire [31:0]                   stat_collision_count,
    output wire [31:0]                   stat_error_count,
    output wire [7:0]                    stat_epoch,
    output wire [3:0]                    stat_fault,
    output wire                          obs_depth_pending,

    // ======================= read domain: history_clk =======================
    input  wire                          history_clk,
    input  wire                          history_rst_n,

    // Request: natural frequency bin, and frames back from the newest complete
    // frame. See history_pkg header section 5.
    input  wire                          rd_req_valid,
    output wire                          rd_req_ready,
    input  wire [HIST_PORT_W-1:0]        rd_req_bin,
    input  wire [HIST_PORT_W-1:0]        rd_req_frame_off,

    // Response: the antenna vector plus metadata, as a SPEC 5 stream.
    output wire                          m_valid,
    input  wire                          m_ready,
    output wire [RD_PAYLOAD_W-1:0]       m_payload
);

  // ---------------------------------------------------------------------------
  // Geometry
  // ---------------------------------------------------------------------------
  localparam hist_geom_t G =
      hist_geom(N_ANT, FFT_SIZE, LANES, FRAMES_MAX, SAMPLE_W);

  localparam int unsigned M       = int'(hist_beats_per_frame(G));
  localparam int unsigned N_BANKS = int'(hist_n_banks(G));
  localparam int unsigned WORD_W  = int'(hist_word_w(G));
  localparam int unsigned WORDS   = int'(hist_bank_words(G));
  localparam int unsigned ADDR_W  = int'(hist_addr_w(G));
  localparam int unsigned BEAT_W  = int'(hist_beat_w(G));
  localparam int unsigned LANE_W  = int'(hist_lane_w(G));
  localparam int unsigned SLOT_W  = int'(hist_slot_w(G));
  localparam int unsigned DEPTH_W = int'(hist_occ_w(G));
  localparam int unsigned BIN_W   = int'(hist_bin_w(G));
  localparam int unsigned VEC_W   = int'(hist_vec_w(G));
  localparam int unsigned META_W  = int'(hist_meta_w(G));
  localparam int unsigned DATA_W  = int'(hist_data_w(G));
  localparam int unsigned REV_W   = int'(hist_rev_w(G));

  localparam stream_geom_t WR_GEOM =
      stream_geom(LANES * 2 * SAMPLE_W, WR_ID_W, WR_SEQ_W, WR_USER_W);
  localparam stream_geom_t RD_GEOM =
      stream_geom(DATA_W, RD_ID_W, RD_SEQ_W, RD_USER_W);

  // Width of the history->core counter bundle: three 32-bit counters, crossed
  // together so a reader can never mix two snapshots.
  localparam int unsigned TELE_W = 96;

  // Output FIFO. Deep enough to hold everything the read pipeline can have in
  // flight plus slack, rounded to a power of two.
  localparam int unsigned OUT_DEPTH = 8;
  localparam int unsigned CRED_W    = $clog2(OUT_DEPTH + 1);

  localparam int unsigned BANK_LAT = int'(hist_bank_read_latency());

`ifndef SYNTHESIS
  initial begin
    hist_uint_t b;
    if (!hist_geom_ok(G)) begin
      $fatal(1, "history_core: illegal geometry N_ANT=%0d FFT_SIZE=%0d LANES=%0d FRAMES_MAX=%0d SAMPLE_W=%0d",
             N_ANT, FFT_SIZE, LANES, FRAMES_MAX, SAMPLE_W);
    end
    if (!hist_port_fits(G)) begin
      $fatal(1, "history_core: geometry needs %0d bin bits and %0d depth bits, past HIST_PORT_W=%0d",
             BIN_W, DEPTH_W, HIST_PORT_W);
    end
    if (ADDR_W != SLOT_W + BEAT_W) begin
      $fatal(1, "history_core: address split %0d+%0d does not fill ADDR_W=%0d",
             SLOT_W, BEAT_W, ADDR_W);
    end
    if (PUB_W != int'(32 + SLOT_W + DEPTH_W + DEPTH_W + 1)) begin
      $fatal(1, "history_core: PUB_W=%0d overridden; it is derived (%0d)",
             PUB_W, int'(32 + SLOT_W + DEPTH_W + DEPTH_W + 1));
    end
    if (PIPE_META_W != int'(BIN_W + DEPTH_W + 32 + HIST_REQ_FLAGS_W + LANE_W)) begin
      $fatal(1, "history_core: hist_req_meta_w() disagrees with the pipeline built here");
    end
    if (WR_PAYLOAD_W != int'(stream_payload_w(WR_GEOM))) begin
      $fatal(1, "history_core: WR_PAYLOAD_W=%0d overridden; it is derived (%0d)",
             WR_PAYLOAD_W, int'(stream_payload_w(WR_GEOM)));
    end
    if (RD_PAYLOAD_W != int'(stream_payload_w(RD_GEOM))) begin
      $fatal(1, "history_core: RD_PAYLOAD_W=%0d overridden; it is derived (%0d)",
             RD_PAYLOAD_W, int'(stream_payload_w(RD_GEOM)));
    end
    if (!stream_geom_ok(RD_GEOM)) begin
      $fatal(1, "history_core: the response data field is %0d bits, past stream_pkg's bound; widen STREAM_MAX_DATA_W or reduce N_ANT",
             DATA_W);
    end
    if (int'(hist_read_latency()) != int'(1 + BANK_LAT + 2)) begin
      $fatal(1, "history_core: hist_read_latency() disagrees with the pipeline built here");
    end
    // The involution the read decode depends on, checked over the whole beat
    // range rather than trusted. If hist_bitrev were not its own inverse a
    // bit-reversed frame would be stored at one address and read from another,
    // and every value would be wrong in a way that looks like a data bug.
    for (int unsigned i = 0; i < M; i++) begin
      if (int'(hist_bitrev(hist_uint_t'(REV_W),
                           hist_bitrev(hist_uint_t'(REV_W), hist_idx_t'(i)))) !=
          int'(i)) begin
        $fatal(1, "history_core: hist_bitrev is not an involution at %0d (width %0d)",
               i, REV_W);
      end
    end
    // The round trip the corner turn IS: store a sample at (beat, lane), ask
    // where natural bin b lives, get the same place back.
    for (int unsigned k = 0; k < M; k++) begin
      for (int unsigned l = 0; l < LANES; l++) begin
        b = hist_stored_bin(G, INPUT_BIT_REVERSED, hist_uint_t'(k), hist_uint_t'(l));
        if (int'(hist_lane_of_bin(G, b)) != int'(l) ||
            int'(hist_beat_of_bin(G, INPUT_BIT_REVERSED, b)) != int'(k)) begin
          $fatal(1, "history_core: address round trip failed at beat=%0d lane=%0d bin=%0d",
                 k, l, b);
        end
      end
    end
    $display("[history_core] %0d ant x %0d lanes = %0d banks of %0d x %0d bits (%0d bits), M=%0d, FRAMES_MAX=%0d, bitrev=%0d, storage=%s",
             N_ANT, LANES, N_BANKS, WORDS, WORD_W, int'(hist_total_bits(G)),
             M, FRAMES_MAX, INPUT_BIT_REVERSED, STORAGE);
  end
`endif

  // ---------------------------------------------------------------------------
  // Unused instance outputs
  //
  // Named rather than left as empty port connections: an empty connection is a
  // `PINCONNECTEMPTY` warning under --Wall, and a waiver for it would be a
  // design-wide waiver on a rule that catches real wiring mistakes. The `unused`
  // in each name is what the linter's unused-signal regexp matches, so the
  // declaration is self-documenting in both directions. Same device, same
  // spelling, as rtl/cfar/cfar_core.sv.
  // ---------------------------------------------------------------------------
  wire [31:0] ovw_snap_unused, skw_snap_unused, wbt_snap_unused;
  wire [31:0] rdc_snap_unused, col_snap_unused, err_snap_unused;
  wire        ovw_snapv_unused, skw_snapv_unused, wbt_snapv_unused;
  wire        rdc_snapv_unused, col_snapv_unused, err_snapv_unused;
  wire        ovw_wrapp_unused, skw_wrapp_unused, wbt_wrapp_unused;
  wire        rdc_wrapp_unused, col_wrapp_unused, err_wrapp_unused;
  wire        ovw_wrapd_unused, skw_wrapd_unused, wbt_wrapd_unused;
  wire        rdc_wrapd_unused, col_wrapd_unused, err_wrapd_unused;
  wire        pub_busy_unused, tele_busy_unused, tele_ready_unused;
  wire        clr_busy_unused, clr_overrun_unused;
  wire [$clog2(OUT_DEPTH+1)-1:0] fifo_occ_unused, fifo_high_unused;
  wire        fifo_full_unused, fifo_empty_unused;
  wire        fifo_afull_unused, fifo_aempty_unused;
  wire        fifo_ovf_unused, fifo_unf_unused;

  // ===========================================================================
  // Declarations
  //
  // All of the write-side state is declared before any of it is used, because
  // the depth-apply strobe is read by the per-antenna sequencers and computed
  // from their own in-frame flags. Declaring in one place makes that loop
  // visible instead of leaving it to a forward reference.
  // ===========================================================================
  logic [DEPTH_W-1:0]      depth_q;
  logic [DEPTH_W-1:0]      depth_req_q;
  logic                    depth_pending_q;
  logic [31:0]             frames_done_q;
  logic [SLOT_W-1:0]       done_slot_q;
  logic [7:0]              epoch_q;

  logic [N_ANT-1:0]        wr_fire;
  logic [N_ANT-1:0]        in_frame_q;
  logic [BEAT_W-1:0]       beat_q    [N_ANT];
  logic [SLOT_W-1:0]       slot_q    [N_ANT];
  logic [31:0]             frame_q   [N_ANT];
  logic [ADDR_W-1:0]       wr_addr_q [N_ANT];
  logic [N_ANT-1:0]        wr_en_q;
  logic [LANES*WORD_W-1:0] wr_word_q [N_ANT];
  logic [N_ANT-1:0]        framing_err;

  wire at_safe_boundary = (in_frame_q == '0);
  wire depth_apply      = depth_pending_q && at_safe_boundary;

  // ===========================================================================
  // WRITE SIDE (core_clk)
  // ===========================================================================

  // Nothing can refuse a beat; see header section 1.
  assign s_ready = {N_ANT{cfg_enable}};

  for (genvar a = 0; a < int'(N_ANT); a++) begin : g_wr
    stream_fields_t f;
    assign f = stream_unpack(WR_GEOM, stream_payload_t'(
                   s_payload[a*WR_PAYLOAD_W +: WR_PAYLOAD_W]));

    assign wr_fire[a] = s_valid[a] && cfg_enable;

    // A frame that ends anywhere but on beat M-1, that runs past M-1 without an
    // end-of-frame, or that starts anywhere but beat 0, is a framing defect.
    // Counted and made sticky rather than silently absorbed: nothing downstream
    // can tell a short frame from a correct one, because both are just words in
    // a bank, and a frame that is one beat short shifts every subsequent bin of
    // that antenna by one for the rest of the run.
    assign framing_err[a] =
        wr_fire[a] && ((f.eof && (beat_q[a] != BEAT_W'(M-1)))  ||
                       (!f.eof && (beat_q[a] == BEAT_W'(M-1))) ||
                       (f.sof && (beat_q[a] != '0))            ||
                       (!f.sof && (beat_q[a] == '0)));

    // The SPEC 5 identity fields this block deliberately does not use. A history
    // bank stores samples, not provenance: `stream_id` is already implicit in
    // WHICH port the beat arrived on, and `seq`/`user` describe a per-antenna
    // frame that no single response corresponds to — a response mixes N_ANT
    // antennas, so forwarding one antenna's sequence number would be a lie.
    // Named and driven rather than left unread so that "ignored on purpose" is
    // in the source rather than in a lint waiver; the `unused` in the name is
    // what the linter's unused-signal regexp matches.
    wire [WR_ID_W + WR_SEQ_W + WR_USER_W - 1:0] ident_unused =
        {f.stream_id[WR_ID_W-1:0], f.seq[WR_SEQ_W-1:0], f.user[WR_USER_W-1:0]};

    always_ff @(posedge core_clk) begin
      if (!core_rst_n || depth_apply) begin
        beat_q[a]     <= '0;
        slot_q[a]     <= '0;
        frame_q[a]    <= '0;
        in_frame_q[a] <= 1'b0;
        wr_en_q[a]    <= 1'b0;
      end else begin
        wr_en_q[a] <= wr_fire[a];
        if (wr_fire[a]) begin
          in_frame_q[a] <= !f.eof;
          if (f.eof) begin
            beat_q[a]  <= '0;
            frame_q[a] <= frame_q[a] + 32'd1;
            slot_q[a]  <= (((SLOT_W+1)'(slot_q[a]) + (SLOT_W+1)'(1)) ==
                           (SLOT_W+1)'(depth_q)) ? '0 : (slot_q[a] + SLOT_W'(1));
          end else begin
            beat_q[a] <= beat_q[a] + BEAT_W'(1);
          end
        end
      end
    end

    // The write address. `{slot, beat}` is hist_addr_of() with the multiply
    // realised as a concatenation, exact because FRAMES_MAX and M are both
    // powers of two. No multiplier, no adder, and no address shared with any
    // other antenna (header section 7).
    always_ff @(posedge core_clk) begin
      wr_addr_q[a] <= {slot_q[a], beat_q[a]};
      wr_word_q[a] <= f.data[LANES*WORD_W-1:0];
    end
  end

  // ---------------------------------------------------------------------------
  // The frame barrier (header section 2)
  // ---------------------------------------------------------------------------
  logic all_past_barrier;
  logic skew_now;
  always_comb begin
    all_past_barrier = 1'b1;
    skew_now         = 1'b0;
    for (int unsigned a = 0; a < N_ANT; a++) begin
      if (frame_q[a] == frames_done_q)                  all_past_barrier = 1'b0;
      if ((frame_q[a] - frames_done_q) >= 32'(depth_q)) skew_now         = 1'b1;
    end
  end

  // Counted on the RISING EDGE of the condition, not while it holds. Skew is an
  // episode, not a duration: a level counter would report a number that depends
  // on how long the test happened to leave the antennas apart, which no
  // reference model can predict and which tells a reader nothing they can act
  // on. One count means one occasion on which an antenna ran a whole depth ahead
  // of the barrier.
  logic skew_q;
  always_ff @(posedge core_clk) begin
    if (!core_rst_n || depth_apply) skew_q <= 1'b0;
    else                            skew_q <= skew_now;
  end
  wire skew_event = skew_now && !skew_q;

  wire frames_done_inc = all_past_barrier && !depth_apply;

  // ---------------------------------------------------------------------------
  // Depth programming (header section 6)
  // ---------------------------------------------------------------------------
  wire [DEPTH_W-1:0] depth_clamped =
      (cfg_depth == '0)                              ? DEPTH_W'(1) :
      (cfg_depth > HIST_PORT_W'(FRAMES_MAX))         ? DEPTH_W'(FRAMES_MAX) :
                                                       DEPTH_W'(cfg_depth);

  always_ff @(posedge core_clk) begin
    if (!core_rst_n) begin
      depth_q         <= DEPTH_W'(FRAMES_MAX);
      depth_req_q     <= DEPTH_W'(FRAMES_MAX);
      depth_pending_q <= 1'b0;
      epoch_q         <= '0;
    end else begin
      if (cfg_depth_apply) begin
        depth_req_q     <= depth_clamped;
        depth_pending_q <= 1'b1;
      end
      if (depth_apply) begin
        depth_q         <= depth_req_q;
        depth_pending_q <= 1'b0;
        epoch_q         <= epoch_q + 8'd1;
      end
    end
  end

  always_ff @(posedge core_clk) begin
    if (!core_rst_n || depth_apply) begin
      frames_done_q <= '0;
      done_slot_q   <= '0;
    end else if (frames_done_inc) begin
      frames_done_q <= frames_done_q + 32'd1;
      // Frame 0 lands in slot 0, so the slot only starts moving on the second
      // completion. Written this way rather than as (frames_done-1) % depth,
      // because a modulo by a run-time value is a divider.
      if (frames_done_q != 32'd0) begin
        done_slot_q <= ((((SLOT_W+1)'(done_slot_q) + (SLOT_W+1)'(1)) ==
                         (SLOT_W+1)'(depth_q))) ? '0 : (done_slot_q + SLOT_W'(1));
      end
    end
  end

  // occupancy = min(frames_done, depth); readable = min(frames_done, depth-1).
  // See header section 5 for why the readable set is one slot short.
  wire [DEPTH_W-1:0] occ_w =
      (frames_done_q >= 32'(depth_q)) ? depth_q : DEPTH_W'(frames_done_q);
  wire [DEPTH_W-1:0] depth_m2 =
      (depth_q <= DEPTH_W'(2)) ? '0 : (depth_q - DEPTH_W'(2));
  wire [DEPTH_W-1:0] readable_w =
      (frames_done_q >= 32'(depth_m2)) ? depth_m2 : DEPTH_W'(frames_done_q);

  // ---------------------------------------------------------------------------
  // Core-domain counters (issue #8 primitives)
  // ---------------------------------------------------------------------------
  wire overwrite_event = frames_done_inc && (frames_done_q >= 32'(depth_q));

  localparam int unsigned WB_W = $clog2(N_ANT + 1);

  logic [WB_W-1:0] wbeat_cnt;
  always_comb begin
    wbeat_cnt = '0;
    for (int unsigned a = 0; a < N_ANT; a++) begin
      if (wr_fire[a]) wbeat_cnt = wbeat_cnt + WB_W'(1);
    end
  end

  wire [31:0] c_overwrite, c_skew, c_wbeat;

  perf_counter #(.WIDTH(32), .INCR_W(1), .SATURATE(1'b1)) u_cnt_overwrite (
      .clk (core_clk), .rst_n (core_rst_n), .enable (1'b1),
      .event_i (overwrite_event), .incr (1'b1),
      .clear (cfg_counter_clear), .snapshot (1'b0),
      .count (c_overwrite), .snap (ovw_snap_unused), .snap_valid (ovw_snapv_unused),
      .wrap_pulse (ovw_wrapp_unused), .wrapped (ovw_wrapd_unused)
  );

  perf_counter #(.WIDTH(32), .INCR_W(1), .SATURATE(1'b1)) u_cnt_skew (
      .clk (core_clk), .rst_n (core_rst_n), .enable (1'b1),
      .event_i (skew_event), .incr (1'b1),
      .clear (cfg_counter_clear), .snapshot (1'b0),
      .count (c_skew), .snap (skw_snap_unused), .snap_valid (skw_snapv_unused),
      .wrap_pulse (skw_wrapp_unused), .wrapped (skw_wrapd_unused)
  );

  perf_counter #(.WIDTH(32), .INCR_W(WB_W), .SATURATE(1'b1)) u_cnt_wbeat (
      .clk (core_clk), .rst_n (core_rst_n), .enable (1'b1),
      .event_i (wbeat_cnt != '0), .incr (wbeat_cnt),
      .clear (cfg_counter_clear), .snapshot (1'b0),
      .count (c_wbeat), .snap (wbt_snap_unused), .snap_valid (wbt_snapv_unused),
      .wrap_pulse (wbt_wrapp_unused), .wrapped (wbt_wrapd_unused)
  );

  // Sticky faults: {framing, skew, collision seen, error seen}.
  wire        rd_collision_seen;
  wire        rd_error_seen;
  logic [3:0] fault_q;

  always_ff @(posedge core_clk) begin
    if (!core_rst_n || cfg_sticky_clear) begin
      fault_q <= '0;
    end else begin
      fault_q[3] <= fault_q[3] | (framing_err != '0);
      fault_q[2] <= fault_q[2] | skew_event;
      fault_q[1] <= fault_q[1] | rd_collision_seen;
      fault_q[0] <= fault_q[0] | rd_error_seen;
    end
  end

  // ===========================================================================
  // CROSSING 1 — publication bundle, core -> history (header section 3)
  // ===========================================================================
  wire [PUB_W-1:0] pub_bundle =
      {cfg_force_unsafe, readable_w, depth_q, done_slot_q, frames_done_q};

  logic [PUB_W-1:0] pub_sent_q;
  logic             pub_dirty_q;
  wire              pub_ready;

  always_ff @(posedge core_clk) begin
    if (!core_rst_n) begin
      pub_sent_q  <= '0;
      pub_dirty_q <= 1'b1;
    end else if (pub_dirty_q && pub_ready) begin
      pub_sent_q  <= pub_bundle;
      pub_dirty_q <= 1'b0;
    end else if (pub_bundle != pub_sent_q) begin
      pub_dirty_q <= 1'b1;
    end
  end

  wire             pub_d_valid;
  wire [PUB_W-1:0] pub_d_data;

  cdc_handshake #(
      .WIDTH       (PUB_W),
      .SYNC_STAGES (SYNC_STAGES)
  ) u_pub (
      .src_clk   (core_clk),
      .src_rst_n (core_rst_n),
      .s_valid   (pub_dirty_q),
      .s_ready   (pub_ready),
      .s_data    (pub_bundle),
      .s_busy    (pub_busy_unused),
      .dst_clk   (history_clk),
      .dst_rst_n (history_rst_n),
      .d_valid   (pub_d_valid),
      .d_data    (pub_d_data)
  );

  // ===========================================================================
  // CROSSING 2 — counter-clear strobe, core -> history
  // ===========================================================================
  wire rd_clear;

  cdc_pulse #(
      .SYNC_STAGES (SYNC_STAGES)
  ) u_clear (
      .src_clk          (core_clk),
      .src_rst_n        (core_rst_n),
      .src_pulse        (cfg_counter_clear),
      .src_busy         (clr_busy_unused),
      .src_overrun      (clr_overrun_unused),
      .src_sticky_clear (cfg_sticky_clear),
      .dst_clk          (history_clk),
      .dst_rst_n        (history_rst_n),
      .dst_pulse        (rd_clear)
  );

  // ===========================================================================
  // READ SIDE (history_clk)
  // ===========================================================================

  // The published view, held stable by cdc_handshake between updates.
  logic [31:0]        h_frames_done_q;
  logic [SLOT_W-1:0]  h_done_slot_q;
  logic [DEPTH_W-1:0] h_depth_q;
  logic [DEPTH_W-1:0] h_readable_q;
  logic               h_unsafe_q;

  always_ff @(posedge history_clk) begin
    if (!history_rst_n) begin
      h_frames_done_q <= '0;
      h_done_slot_q   <= '0;
      h_depth_q       <= DEPTH_W'(1);
      h_readable_q    <= '0;
      h_unsafe_q      <= 1'b0;
    end else if (pub_d_valid) begin
      {h_unsafe_q, h_readable_q, h_depth_q, h_done_slot_q, h_frames_done_q}
          <= pub_d_data;
    end
  end

  // ---- credit: a request is accepted only against a reserved output slot ----
  logic [CRED_W-1:0] credit_q;
  wire               out_pop;
  wire               req_fire = rd_req_valid && rd_req_ready;

  assign rd_req_ready = (credit_q != '0);

  always_ff @(posedge history_clk) begin
    if (!history_rst_n) begin
      credit_q <= CRED_W'(OUT_DEPTH);
    end else begin
      credit_q <= credit_q - CRED_W'(req_fire) + CRED_W'(out_pop);
    end
  end

  // ---- request decode ----
  // Every line here is a bit slice, a compare or one subtract; see history_pkg
  // section 1 for why none of it is arithmetic.
  // The request ports are HIST_PORT_W wide and the geometry uses BIN_W of them.
  // The surplus bits are not ignored: a bin at or past FFT_SIZE is an error
  // rather than an address that silently wraps onto a real bin, which is the
  // difference between a software mistake that is reported and one that returns
  // plausible data from the wrong place.
  wire              req_bin_oor = (rd_req_bin >= HIST_PORT_W'(FFT_SIZE));
  wire [BIN_W-1:0]  req_bin     = rd_req_bin[BIN_W-1:0];
  wire [LANE_W-1:0] req_lane = (LANES == 1) ? '0 : req_bin[BIN_W-1 -: LANE_W];
  wire [BEAT_W-1:0] req_m    = req_bin[BEAT_W-1:0];

  logic [BEAT_W-1:0] req_beat;
  always_comb begin
    req_beat = req_m;
    if (INPUT_BIT_REVERSED) begin
      for (int unsigned i = 0; i < BEAT_W; i++) begin
        req_beat[i] = (i < REV_W) ? req_m[REV_W-1-i] : 1'b0;
      end
    end
  end

  // Out of range when the request asks for a frame outside the readable set.
  // Answered anyway, clamped, with the flag set (header section 4).
  wire req_oor = req_bin_oor || (h_readable_q == '0) ||
                 (rd_req_frame_off >= HIST_PORT_W'(h_readable_q));

  wire [DEPTH_W-1:0] off_clamped =
      (h_readable_q == '0) ? '0 : (h_readable_q - DEPTH_W'(1));

  wire [DEPTH_W-1:0] req_off_safe =
      (req_oor && !h_unsafe_q) ? off_clamped : DEPTH_W'(rd_req_frame_off);

  // slot = (done_slot - off) mod depth, as a subtract with a conditional add.
  wire [SLOT_W:0]   off_ext  = (SLOT_W+1)'(req_off_safe);
  wire [SLOT_W:0]   done_ext = (SLOT_W+1)'(h_done_slot_q);
  wire [SLOT_W:0]   slot_raw = done_ext - off_ext;
  wire [SLOT_W-1:0] req_slot =
      (done_ext >= off_ext) ? slot_raw[SLOT_W-1:0]
                            : SLOT_W'(slot_raw + (SLOT_W+1)'(h_depth_q));

  wire [31:0] req_frame_id = h_frames_done_q - 32'd1 - 32'(req_off_safe);

  // The slot the writer is filling, as the read side last saw it. A response
  // addressing it is the collision SPEC 7.3 asks to be counted.
  wire [SLOT_W-1:0] write_slot =
      ((((SLOT_W+1)'(h_done_slot_q) + (SLOT_W+1)'(1)) == (SLOT_W+1)'(h_depth_q)))
        ? '0 : (h_done_slot_q + SLOT_W'(1));
  wire req_hits_write_slot =
      (h_frames_done_q != 32'd0) && (req_slot == write_slot);

  // ---- stage R1: the registered per-antenna fanout (header section 7) ----
  localparam int unsigned PIPE_META_W = int'(hist_req_meta_w(G));

  logic                   r1_v_q;
  logic [ADDR_W-1:0]      r1_addr_q [N_ANT];
  logic [LANES-1:0]       r1_en_q   [N_ANT];
  logic [PIPE_META_W-1:0] r1_meta_q;

  // Only the two request-time flags are pipelined. The third, HIST_FLAG_STALE,
  // is decided at the output stage because it depends on how far rotation moved
  // WHILE the request was in flight, which is not knowable when it is accepted.
  wire [HIST_REQ_FLAGS_W-1:0] req_flags = {req_hits_write_slot, req_oor};
  wire [ADDR_W-1:0]           req_addr  = {req_slot, req_beat};

  for (genvar a = 0; a < int'(N_ANT); a++) begin : g_fanout
    always_ff @(posedge history_clk) begin
      if (!history_rst_n) begin
        r1_en_q[a] <= '0;
      end else begin
        for (int unsigned l = 0; l < LANES; l++) begin
          r1_en_q[a][l] <= req_fire && (LANE_W'(l) == req_lane);
        end
      end
    end
    always_ff @(posedge history_clk) begin
      r1_addr_q[a] <= req_addr;
    end
  end

  always_ff @(posedge history_clk) begin
    if (!history_rst_n) r1_v_q <= 1'b0;
    else                r1_v_q <= req_fire;
  end
  always_ff @(posedge history_clk) begin
    r1_meta_q <= {req_lane, req_flags, req_frame_id, req_off_safe, req_bin};
  end

  // ---- the banks ----
  wire [WORD_W-1:0] bank_data [N_ANT][LANES];
  wire [N_ANT-1:0]  bank_dvalid_any;

  for (genvar a = 0; a < int'(N_ANT); a++) begin : g_ant
    logic [LANES-1:0] dv;
    for (genvar l = 0; l < int'(LANES); l++) begin : g_lane
      history_bank #(
          .WIDTH   (WORD_W),
          .DEPTH   (WORDS),
          .IN_REG  (1'b1),
          .OUT_REG (1'b1),
          .STORAGE (STORAGE)
      ) u_bank (
          .wr_clk        (core_clk),
          .wr_rst_n      (core_rst_n),
          .wr_en         (wr_en_q[a]),
          .wr_addr       (wr_addr_q[a]),
          .wr_data       (wr_word_q[a][l*WORD_W +: WORD_W]),
          .rd_clk        (history_clk),
          .rd_rst_n      (history_rst_n),
          .rd_en         (r1_en_q[a][l]),
          .rd_addr       (r1_addr_q[a]),
          .rd_data_valid (dv[l]),
          .rd_data       (bank_data[a][l])
      );
    end
    assign bank_dvalid_any[a] = |dv;
  end

  // ---- metadata pipeline, matched to the bank latency ----
  logic [BANK_LAT-1:0]    mv_q;
  logic [PIPE_META_W-1:0] mm_q [BANK_LAT];

  always_ff @(posedge history_clk) begin
    if (!history_rst_n) mv_q <= '0;
    else                mv_q <= {mv_q[BANK_LAT-2:0], r1_v_q};
  end
  always_ff @(posedge history_clk) begin
    mm_q[0] <= r1_meta_q;
    for (int unsigned i = 1; i < BANK_LAT; i++) mm_q[i] <= mm_q[i-1];
  end

  wire                    out_v    = mv_q[BANK_LAT-1];
  wire [PIPE_META_W-1:0]  out_meta = mm_q[BANK_LAT-1];

  wire [BIN_W-1:0]            out_bin   = out_meta[BIN_W-1:0];
  wire [DEPTH_W-1:0]          out_off   = out_meta[BIN_W +: DEPTH_W];
  wire [31:0]                 out_frame = out_meta[BIN_W+DEPTH_W +: 32];
  wire [HIST_REQ_FLAGS_W-1:0] out_flag0 =
      out_meta[BIN_W+DEPTH_W+32 +: HIST_REQ_FLAGS_W];
  wire [LANE_W-1:0]           out_lane  = out_meta[PIPE_META_W-1 -: LANE_W];

  // Rotation overtook the served frame between acceptance and the memory read.
  wire out_stale = (h_frames_done_q - out_frame) > 32'(h_depth_q);

  wire [HIST_FLAGS_W-1:0] out_flags = {out_stale, out_flag0};

  // ---- the antenna vector: the corner turn's product ----
  logic [VEC_W-1:0] out_vec;
  always_comb begin
    out_vec = '0;
    for (int unsigned a = 0; a < N_ANT; a++) begin
      for (int unsigned l = 0; l < LANES; l++) begin
        if (LANE_W'(l) == out_lane) begin
          out_vec[a*WORD_W +: WORD_W] = bank_data[a][l];
        end
      end
    end
  end

  hist_meta_fields_t out_mf;
  always_comb begin
    out_mf           = '0;
    out_mf.bin       = hist_idx_t'(out_bin);
    out_mf.frame_off = hist_idx_t'(out_off);
    out_mf.frame_id  = out_frame;
    out_mf.flags     = out_flags;
  end

  wire [DATA_W-1:0] out_data = {META_W'(hist_meta_pack(G, out_mf)), out_vec};

  // ---- response stream ----
  logic [RD_SEQ_W-1:0] rsp_seq_q;
  always_ff @(posedge history_clk) begin
    if (!history_rst_n) rsp_seq_q <= '0;
    else if (out_v)     rsp_seq_q <= rsp_seq_q + RD_SEQ_W'(1);
  end

  stream_fields_t rsp_fields;
  always_comb begin
    rsp_fields           = '0;
    rsp_fields.data      = STREAM_MAX_DATA_W'(out_data);
    // Every response is a complete one-beat frame: a request is answered by
    // exactly one antenna vector, and a consumer that re-frames them into
    // beamformer beats (issue #16) does its own framing.
    rsp_fields.sof       = 1'b1;
    rsp_fields.eof       = 1'b1;
    rsp_fields.stream_id = STREAM_MAX_ID_W'(0);
    rsp_fields.seq       = STREAM_MAX_SEQ_W'(rsp_seq_q);
    rsp_fields.user      = STREAM_MAX_USER_W'(out_flags);
  end

  wire [RD_PAYLOAD_W-1:0] rsp_payload =
      RD_PAYLOAD_W'(stream_pack(RD_GEOM, rsp_fields));

  wire out_fifo_ready;

  sync_fifo #(
      .WIDTH      (RD_PAYLOAD_W),
      .DEPTH      (OUT_DEPTH),
      .SHOW_AHEAD (1'b0),
      .STORAGE    ("regs")
  ) u_out (
      .clk              (history_clk),
      .rst_n            (history_rst_n),
      .s_valid          (out_v),
      .s_ready          (out_fifo_ready),
      .s_data           (rsp_payload),
      .m_valid          (m_valid),
      .m_ready          (m_ready),
      .m_data           (m_payload),
      .occupancy        (fifo_occ_unused),
      .full             (fifo_full_unused),
      .empty            (fifo_empty_unused),
      .almost_full      (fifo_afull_unused),
      .almost_empty     (fifo_aempty_unused),
      .high_water       (fifo_high_unused),
      .overflow_sticky  (fifo_ovf_unused),
      .underflow_sticky (fifo_unf_unused),
      .sticky_clear     (1'b0)
  );

  assign out_pop = m_valid && m_ready;

  // ---- read-domain counters ----
  wire [31:0] c_read, c_coll, c_err;

  perf_counter #(.WIDTH(32), .INCR_W(1), .SATURATE(1'b1)) u_cnt_read (
      .clk (history_clk), .rst_n (history_rst_n), .enable (1'b1),
      .event_i (out_v), .incr (1'b1),
      .clear (rd_clear), .snapshot (1'b0),
      .count (c_read), .snap (rdc_snap_unused), .snap_valid (rdc_snapv_unused),
      .wrap_pulse (rdc_wrapp_unused), .wrapped (rdc_wrapd_unused)
  );

  perf_counter #(.WIDTH(32), .INCR_W(1), .SATURATE(1'b1)) u_cnt_coll (
      .clk (history_clk), .rst_n (history_rst_n), .enable (1'b1),
      .event_i (out_v && out_flags[1]), .incr (1'b1),
      .clear (rd_clear), .snapshot (1'b0),
      .count (c_coll), .snap (col_snap_unused), .snap_valid (col_snapv_unused),
      .wrap_pulse (col_wrapp_unused), .wrapped (col_wrapd_unused)
  );

  perf_counter #(.WIDTH(32), .INCR_W(1), .SATURATE(1'b1)) u_cnt_err (
      .clk (history_clk), .rst_n (history_rst_n), .enable (1'b1),
      .event_i (out_v && out_flags[0]), .incr (1'b1),
      .clear (rd_clear), .snapshot (1'b0),
      .count (c_err), .snap (err_snap_unused), .snap_valid (err_snapv_unused),
      .wrap_pulse (err_wrapp_unused), .wrapped (err_wrapd_unused)
  );

  // ===========================================================================
  // CROSSING 3 — read-side counter bundle, history -> core
  //
  // Free-running: the read domain re-offers the bundle whenever the crossing is
  // idle, so the core side always holds a recent and INTERNALLY CONSISTENT
  // snapshot of all three counters. Consistency is the reason this is one
  // handshake rather than three synchronised buses — a reader that saw a read
  // count from after an event and an error count from before it would be shown a
  // history that never happened.
  // ===========================================================================
  wire [TELE_W-1:0] tele_bundle = {c_err, c_coll, c_read};
  wire              tele_d_valid;
  wire [TELE_W-1:0] tele_d_data;

  cdc_handshake #(
      .WIDTH       (TELE_W),
      .SYNC_STAGES (SYNC_STAGES)
  ) u_tele (
      .src_clk   (history_clk),
      .src_rst_n (history_rst_n),
      .s_valid   (1'b1),
      .s_ready   (tele_ready_unused),
      .s_data    (tele_bundle),
      .s_busy    (tele_busy_unused),
      .dst_clk   (core_clk),
      .dst_rst_n (core_rst_n),
      .d_valid   (tele_d_valid),
      .d_data    (tele_d_data)
  );

  logic [TELE_W-1:0] tele_q;
  always_ff @(posedge core_clk) begin
    if (!core_rst_n)       tele_q <= '0;
    else if (tele_d_valid) tele_q <= tele_d_data;
  end

  assign stat_read_count      = tele_q[31:0];
  assign stat_collision_count = tele_q[63:32];
  assign stat_error_count     = tele_q[95:64];
  assign rd_collision_seen    = (tele_q[63:32] != 32'd0);
  assign rd_error_seen        = (tele_q[95:64] != 32'd0);

  // ---------------------------------------------------------------------------
  // Status
  // ---------------------------------------------------------------------------
  assign stat_depth_active     = HIST_PORT_W'(depth_q);
  assign stat_occupancy        = HIST_PORT_W'(occ_w);
  assign stat_frames_done      = frames_done_q;
  assign stat_overwrite_count  = c_overwrite;
  assign stat_skew_count       = c_skew;
  assign stat_write_beat_count = c_wbeat;
  assign stat_epoch            = epoch_q;
  assign stat_fault            = fault_q;
  assign obs_depth_pending     = depth_pending_q;

  // ---------------------------------------------------------------------------
  // SPEC 14 property set. Instantiated here rather than bound externally, for
  // the reason rtl/covariance/integrator.sv gives: the properties then hold
  // wherever this module is used, including in the Quartus calibration wrapper
  // that no testbench ever drives.
  // ---------------------------------------------------------------------------
//
// TWO checkers, one per clock domain, rather than one straddling both. Every
// other checker in sim/assertions/ takes a single `clk`, and the reason is not
// only stylistic: scripts/cdc_inventory.py --strict reports ANY instantiated
// module with two clock-like ports and no `(* cdc_primitive *)` tag, which is
// the correct default and which a two-clock checker would trip. Tagging the
// checker instead would put a crossing in the SPEC 8 inventory that does not
// exist in the hardware, and an inventory with an imaginary entry is worse than
// one with a missing entry.
`ifndef SYNTHESIS
  history_wr_assertions #(
      .N_ANT   (N_ANT),
      .DEPTH_W (DEPTH_W)
  ) u_assert_wr (
      .clk           (core_clk),
      .rst_n         (core_rst_n),
      .depth_active  (depth_q),
      .occupancy     (occ_w),
      .readable_core (readable_w),
      .frames_done   (frames_done_q),
      .depth_apply   (depth_apply),
      .in_frame      (in_frame_q),
      .wr_en         (wr_en_q)
  );

  history_rd_assertions #(
      .N_ANT   (N_ANT),
      .LANES   (LANES),
      .SLOT_W  (SLOT_W)
  ) u_assert_rd (
      .clk             (history_clk),
      .rst_n           (history_rst_n),
      .req_fire        (req_fire),
      .req_slot        (req_slot),
      .write_slot      (write_slot),
      .req_oor         (req_oor),
      .force_unsafe    (h_unsafe_q),
      .frames_done_pub (h_frames_done_q),
      .frames_done_core(frames_done_q),
      .lane_en         (r1_en_q[0]),
      .r1_v            (r1_v_q),
      .out_v           (out_v),
      .out_fifo_ready  (out_fifo_ready),
      .bank_dvalid     (bank_dvalid_any)
  );
`endif

endmodule : history_core

`default_nettype wire
