// -----------------------------------------------------------------------------
// align_collect — the reassembly buffer and the SPEC.md 7.4 detector (issue #16).
//
// This is the far side of the routing network: it takes BIN_PAR lane ports, each
// carrying at most one routed word per cycle, reassembles them into beamformer
// input beats, and answers SPEC 7.4's three obligations that no other block in
// the design can:
//
//   "Preserve antenna identity / frequency-bin identity / frame identity"
//   "Detect missing or duplicated samples"
//   "Support backpressure"
//
// It is COMMON TO BOTH ARCHITECTURES and contains no knowledge of either. That
// is deliberate and it is what makes the SPEC 7.4 comparison a comparison: the
// detector is not part of the thing being compared, so a difference in the
// measured numbers is a difference between a crossbar and an omega network and
// nothing else.
//
// -----------------------------------------------------------------------------
// 1. THE ENTRY, AND WHY THE INDEX IS ARITHMETIC RATHER THAN A CAM
// -----------------------------------------------------------------------------
// GROUPS entries, allocated in order by rtl/align/align_sched.sv and retired in
// order here — a circular buffer, not an associative store. An arriving word
// finds its entry by a BIT SLICE of its own bin index:
//
//     lane j   = bin[LANE_W-1:0]         which beat position it fills
//     group g  = bin[BIN_W-1:LANE_W]     which output beat it belongs to
//     entry    = g[GID_W-1:0]            which entry that beat was allocated in
//
// (align_pkg section 3.) The last step is only valid because GROUPS is a power
// of two AND divides GROUPS_PER_FRAME, so entry allocation and the group counter
// wrap together — align_net checks both at elaboration. The alternative, a CAM
// over the open entries, would be BIN_PAR * GROUPS comparators of a key wider
// than the index it replaces, on the response path, to compute something the
// address already contains.
//
// The entry independently records what it was allocated for. Every arriving word
// is checked against that record, and the check is the whole detector:
//
//   ROUTE     the word's own lane index must equal the lane port it arrived on.
//             This is the network checking itself: a routing fault shows up here
//             even though nothing downstream would otherwise notice, because a
//             beamformer beat with two copies of bin 3 and no bin 5 is a
//             perfectly well-formed beat.
//   ENTRY     the entry must be open, and its (group, frame_off) must match the
//             word's. A stale answer to a request from GROUPS groups ago, or a
//             tag collision forced by SPEC 9 fault injection, fails here.
//   DUPLICATE the lane's present bit must not already be set. THE FIRST COPY
//             WINS: a second copy is counted and discarded rather than
//             overwriting, because the first is the one that was in flight when
//             the entry was opened and the second is by definition the anomaly.
//
// A word that fails any of them is DROPPED and counted. It is never written,
// because writing a word that failed its identity check is exactly the silent
// corruption SPEC 7.4 exists to prevent.
//
// -----------------------------------------------------------------------------
// 2. THE TIMEOUT COUNTS PROGRESS, NOT WALL TIME  (this is load-bearing)
// -----------------------------------------------------------------------------
// An entry's age advances only in cycles where THE BLOCK COULD HAVE RETIRED A
// BEAT — that is, when the output elastic buffer can accept one. Ages freeze
// whenever the consumer backpressures.
//
// Without that rule the detector is worse than useless: a beamformer that stalls
// for longer than the timeout would make every open group "time out", and the
// block would report missing samples for a pipeline that lost nothing. A
// missing-sample counter that fires on backpressure is a counter nobody can act
// on. With the rule, the timeout measures exactly what it claims — cycles in
// which a response could have arrived and did not — and the backpressure
// invariance test (`test_align` pass 6) requires a byte-identical output
// sequence AND identical counters at four stall profiles, which is the property
// that would fail immediately if the age counters were free-running.
//
// -----------------------------------------------------------------------------
// 3. AN INCOMPLETE GROUP EMITS A BEAT; IT DOES NOT VANISH
// -----------------------------------------------------------------------------
// align_pkg section 4 states the policy and the reason in full. In short: SPEC 5
// requires `sequence` to advance by exactly one per beat and requires one `eof`
// per frame, so deleting a beat replaces a detected fault with an undetected
// protocol violation, and deleting the beat that carried `eof` leaves the frame
// open forever. The beat is therefore emitted with
//
//   * the absent lanes ZEROED (`cfg_partial_pass` = 0, the default) — never
//     stale, because a stale antenna vector from the previous occupant of the
//     entry is a beat the beamformer cannot tell from a good one;
//   * `ALGN_USER_MISSING` set in the SPEC 5 `user` field;
//   * `stat_missing_count` advanced by the exact number of absent lanes.
//
// `cfg_partial_pass` = 1 emits whatever the entry holds for the absent lanes,
// for diagnosis. Both settings are modelled and both are tested.
//
// -----------------------------------------------------------------------------
// 4. WHY THE LANE PORTS ARE ALWAYS READY
// -----------------------------------------------------------------------------
// `lane_ready` is high whenever the block is enabled and not being stalled by
// the test port. It does not depend on how full the buffer is, and that is a
// deadlock argument rather than an optimisation: every word arriving on a lane
// belongs to an entry that is ALREADY OPEN, because the scheduler allocates the
// entry before it issues the requests. Refusing such a word could not free
// anything — the entry it would fill is the very thing the buffer is waiting for
// — so a full-buffer stall on the lane ports would be a deadlock, not
// backpressure. The place backpressure is applied is `alloc_ready`, one level
// upstream, where refusing to open a new group genuinely does bound the work in
// flight.
//
// `cfg_lane_stall` exists so the test can drive `lane_ready` low anyway and
// prove the network handles a stalled egress; SPEC 13.1 requires stall testing
// at every interface and this is the only way to reach this one. It is a real
// port, driven by the harness and by the calibration wrapper's pins, not a
// tie-off.
//
// Lint contract: clean under `verilator --lint-only --Wall` with no waiver.
// -----------------------------------------------------------------------------

`default_nettype none

module align_collect
  import align_pkg::*;
  import history_pkg::*;
  import stream_pkg::*;
#(
    parameter int unsigned N_ANT      = 2,
    parameter int unsigned FFT_SIZE   = 64,
    parameter int unsigned LANES      = 1,
    parameter int unsigned FRAMES_MAX = 4,
    parameter int unsigned SAMPLE_W   = 16,
    parameter int unsigned BIN_PAR    = 2,
    parameter int unsigned GROUPS     = 4,

    // Cycles of PROGRESS (header section 2) an entry may stay incomplete.
    parameter int unsigned TIMEOUT_CYCLES = 64,

    // SPEC 5 field geometry of the output stream.
    parameter int unsigned STREAM_ID_W = 2,
    parameter int unsigned SEQ_W       = 16,
    parameter int unsigned USER_W      = 4,

    // Output elastic buffer depth.
    parameter int unsigned OUT_DEPTH = 4,

    parameter int unsigned TELEM_W = 32,

    // DERIVED; never overridden. They exist as parameters only because a port
    // width must be a parameter expression, and they spell the geometry out in
    // full for the reason history_core does: a body localparam is not visible in
    // a port declaration, and an overridable width on a port is a way for an
    // instantiator to silently truncate one.
    parameter int unsigned NET_DATA_W =
        int'(algn_net_data_w(algn_geom(N_ANT, FFT_SIZE, LANES, FRAMES_MAX,
                                       SAMPLE_W, BIN_PAR, GROUPS))),
    parameter int unsigned GID_W =
        int'(algn_gid_w(algn_geom(N_ANT, FFT_SIZE, LANES, FRAMES_MAX,
                                  SAMPLE_W, BIN_PAR, GROUPS))),
    parameter int unsigned GIDX_W =
        int'(algn_gidx_w(algn_geom(N_ANT, FFT_SIZE, LANES, FRAMES_MAX,
                                   SAMPLE_W, BIN_PAR, GROUPS))),
    parameter int unsigned FOFF_W =
        int'(algn_foff_w(algn_geom(N_ANT, FFT_SIZE, LANES, FRAMES_MAX,
                                   SAMPLE_W, BIN_PAR, GROUPS))),
    parameter int unsigned M_PAYLOAD_W =
        int'(stream_payload_w(stream_geom(
            algn_out_data_w(algn_geom(N_ANT, FFT_SIZE, LANES, FRAMES_MAX,
                                      SAMPLE_W, BIN_PAR, GROUPS)),
            STREAM_ID_W, SEQ_W, USER_W)))
) (
    input  wire                         clk,
    input  wire                         rst_n,

    input  wire                         cfg_enable,
    // 0 = zero the lanes that never answered (default, safe).
    // 1 = emit whatever the entry holds for them, for diagnosis.
    input  wire                         cfg_partial_pass,
    input  wire                         cfg_counter_clear,
    input  wire                         cfg_sticky_clear,
    // SPEC 13.1 stall injection on the network's egress. One bit per lane.
    input  wire [BIN_PAR-1:0]           cfg_lane_stall,

    // ---- group allocation, from align_sched ----
    input  wire                         alloc_valid,
    output wire                         alloc_ready,
    input  wire [GID_W-1:0]             alloc_gid,
    input  wire [GIDX_W-1:0]            alloc_gidx,
    input  wire [FOFF_W-1:0]            alloc_foff,
    input  wire                         alloc_sof,
    input  wire                         alloc_eof,

    // ---- routed words, one port per beat position ----
    input  wire [BIN_PAR-1:0]           lane_valid,
    output wire [BIN_PAR-1:0]           lane_ready,
    input  wire [BIN_PAR*NET_DATA_W-1:0] lane_data,

    // ---- the beamformer input beat (SPEC 5) ----
    output wire                         m_valid,
    input  wire                         m_ready,
    output wire [M_PAYLOAD_W-1:0]       m_payload,

    // ---- telemetry (SPEC 9) ----
    output wire [TELEM_W-1:0]           stat_beat_count,
    output wire [TELEM_W-1:0]           stat_missing_count,
    output wire [TELEM_W-1:0]           stat_dup_count,
    output wire [TELEM_W-1:0]           stat_orphan_count,
    output wire [TELEM_W-1:0]           stat_timeout_count,
    output wire [ALGN_FAULT_W-1:0]      stat_fault,
    // Entries currently open. A level, not a counter.
    output wire [GID_W:0]               stat_open_groups
);

  // ---------------------------------------------------------------------------
  // Geometry
  // ---------------------------------------------------------------------------
  localparam algn_geom_t GEOM =
      algn_geom(N_ANT, FFT_SIZE, LANES, FRAMES_MAX, SAMPLE_W, BIN_PAR, GROUPS);

  localparam int unsigned VEC_W    = int'(algn_vec_w(GEOM));
  localparam int unsigned BIN_W    = int'(algn_bin_w(GEOM));
  localparam int unsigned LANE_W   = int'(algn_lane_w(GEOM));
  localparam int unsigned OUT_W    = int'(algn_out_data_w(GEOM));
  localparam int unsigned VEC_LSB  = int'(algn_net_vec_lsb(GEOM));
  localparam int unsigned BIN_LSB  = int'(algn_net_bin_lsb(GEOM));
  localparam int unsigned FOFF_LSB = int'(algn_net_foff_lsb(GEOM));
  localparam int unsigned FID_LSB  = int'(algn_net_fid_lsb(GEOM));
  localparam int unsigned FLG_LSB  = int'(algn_net_flags_lsb(GEOM));
  localparam int unsigned FID_W    = int'(algn_fid_w());

  localparam int unsigned TO_W  = int'(algn_timeout_w(algn_uint_t'(TIMEOUT_CYCLES)));
  localparam int unsigned MIS_W = $clog2(BIN_PAR + 1);
  localparam int unsigned CNT_W = GID_W + 1;

  localparam stream_geom_t OGEOM =
      stream_geom(OUT_W, STREAM_ID_W, SEQ_W, USER_W);

`ifndef SYNTHESIS
  initial begin
    if (!algn_geom_ok(GEOM)) begin
      $fatal(1, "align_collect: illegal geometry (n_ant=%0d fft=%0d lanes=%0d frames=%0d sample_w=%0d bin_par=%0d groups=%0d)",
             N_ANT, FFT_SIZE, LANES, FRAMES_MAX, SAMPLE_W, BIN_PAR, GROUPS);
    end
    if ((int'(algn_groups_per_frame(GEOM)) % GROUPS) != 0) begin
      $fatal(1, "align_collect: GROUPS=%0d must divide GROUPS_PER_FRAME=%0d, or the entry index stops being a bit slice of the bin",
             GROUPS, int'(algn_groups_per_frame(GEOM)));
    end
    if (TIMEOUT_CYCLES < 2) begin
      $fatal(1, "align_collect: TIMEOUT_CYCLES=%0d must be at least 2", TIMEOUT_CYCLES);
    end
    if (!algn_status_encoding_ok()) begin
      $fatal(1, "align_collect: the beat's status field and the sticky fault word are not the same encoding");
    end
    if (USER_W < ALGN_USER_W) begin
      $fatal(1, "align_collect: USER_W=%0d cannot carry the %0d SPEC 7.4 status bits",
             USER_W, ALGN_USER_W);
    end
    if (!stream_geom_ok(OGEOM)) begin
      $fatal(1, "align_collect: output stream geometry out of range (data_w=%0d). stream_pkg::STREAM_MAX_DATA_W bounds it.",
             OUT_W);
    end
    if (int'(stream_payload_w(OGEOM)) != int'(M_PAYLOAD_W)) begin
      $fatal(1, "align_collect: M_PAYLOAD_W is derived and must not be overridden");
    end
  end
`endif

  // ---------------------------------------------------------------------------
  // Entry state
  // ---------------------------------------------------------------------------
  logic                  e_valid   [GROUPS];
  logic [GIDX_W-1:0]     e_gidx    [GROUPS];
  logic [FOFF_W-1:0]     e_foff    [GROUPS];
  logic                  e_sof     [GROUPS];
  logic                  e_eof     [GROUPS];
  logic [BIN_PAR-1:0]    e_present [GROUPS];
  logic [TO_W-1:0]       e_age     [GROUPS];
  logic                  e_dup     [GROUPS];
  logic                  e_orphan  [GROUPS];
  logic [HIST_FLAGS_W-1:0] e_hflag [GROUPS];
  // The absolute frame the first arriving response was served from, and whether
  // one has arrived. Every later response must agree: this is what makes "one
  // beat, one frame" a checked property rather than an assumption
  // (align_pkg, "The routed word").
  logic [FID_W-1:0]      e_fid     [GROUPS];
  logic                  e_fid_set [GROUPS];

  logic [VEC_W-1:0]      e_store   [GROUPS][BIN_PAR];

  logic [GID_W-1:0]      head_q, tail_q;
  logic [CNT_W-1:0]      count_q;

  assign stat_open_groups = count_q;

  // ---------------------------------------------------------------------------
  // Lane ingress: decode, check, and decide
  // ---------------------------------------------------------------------------
  logic [BIN_PAR-1:0]    l_fire;      // a word was presented and taken
  logic [BIN_PAR-1:0]    l_cand;      // ... and matched its entry's (group,
                                      // frame offset) — everything but the
                                      // absolute-frame test
  logic [BIN_PAR-1:0]    l_open;      // ... and named an entry that IS open
  logic [BIN_PAR-1:0]    l_write;     // ... and passed every check
  logic [BIN_PAR-1:0]    l_dup;
  logic [BIN_PAR-1:0]    l_orphan;    // failed the identity check, any reason
  logic [BIN_PAR-1:0]    l_orphan_at; // ... and named an entry that IS open, so
                                      // the fault is attributable to that beat
  logic [BIN_PAR-1:0]    l_fidset;    // its entry has already fixed a frame id
  logic [GID_W-1:0]      l_gid   [BIN_PAR];
  logic [VEC_W-1:0]      l_vec   [BIN_PAR];
  logic [FID_W-1:0]      l_fid   [BIN_PAR];
  logic [FID_W-1:0]      l_regfid[BIN_PAR];
  logic [FID_W-1:0]      l_ref   [BIN_PAR];
  logic [BIN_PAR-1:0]    l_present;
  logic [HIST_FLAGS_W-1:0] l_flag [BIN_PAR];

  // ---------------------------------------------------------------------------
  // Registered `cfg_enable` fanout  (issue #17, from DECISIONS.md issue #16
  // finding 7)
  //
  // One local copy per lane, plus one for the allocator, rather than one
  // register driving every lane's `lane_ready` and the allocation path as well.
  // The reasoning, the measurement and the `dont_merge` argument are in
  // rtl/align/align_net.sv's copy of this block; the two are deliberately
  // separate one-stage replications rather than one chained through the module
  // boundary, so that everything in the block sees the enable change on the SAME
  // cycle.
  // ---------------------------------------------------------------------------
  localparam int unsigned EN_COPIES = BIN_PAR + 1;

  (* preserve *) (* dont_merge *) logic [EN_COPIES-1:0] en_q;

  always_ff @(posedge clk) begin
    if (!rst_n) en_q <= '0;
    else        en_q <= {EN_COPIES{cfg_enable}};
  end

  wire en_alloc = en_q[BIN_PAR];

  for (genvar l = 0; l < int'(BIN_PAR); l++) begin : g_lane
    wire [NET_DATA_W-1:0] w    = lane_data[l*NET_DATA_W +: NET_DATA_W];
    wire [VEC_W-1:0]      vec  = w[VEC_LSB  +: VEC_W];
    wire [BIN_W-1:0]      bin  = w[BIN_LSB  +: BIN_W];
    wire [FOFF_W-1:0]     foff = w[FOFF_LSB +: FOFF_W];
    wire [FID_W-1:0]      fid  = w[FID_LSB  +: FID_W];
    wire [HIST_FLAGS_W-1:0] hf = w[FLG_LSB  +: HIST_FLAGS_W];

    // The word's own opinion of where it belongs.
    wire [LANE_W-1:0] w_lane = bin[LANE_W-1:0];
    wire [GIDX_W-1:0] w_gidx = GIDX_W'(bin >> LANE_W);
    wire [GID_W-1:0]  w_gid  = w_gidx[GID_W-1:0];

    // The word arrived on the lane port its own bin index names, and the entry
    // it names is open and was opened for exactly this (group, frame offset).
    wire route_ok   = (w_lane == LANE_W'(l));

    assign lane_ready[l] = en_q[l] && !cfg_lane_stall[l];
    assign l_fire[l]     = lane_valid[l] && lane_ready[l];
    assign l_open[l]     = l_fire[l] && route_ok && e_valid[w_gid];
    assign l_cand[l]     = l_open[l] && (e_gidx[w_gid] == w_gidx) &&
                                        (e_foff[w_gid] == foff);

    assign l_gid[l]     = w_gid;
    assign l_vec[l]     = vec;
    assign l_flag[l]    = hf;
    assign l_fid[l]     = fid;
    assign l_regfid[l]  = e_fid[w_gid];
    assign l_fidset[l]  = e_fid_set[w_gid];
    assign l_present[l] = e_present[w_gid][l];
  end : g_lane

  // ---------------------------------------------------------------------------
  // The absolute-frame test  (SPEC 7.4, "preserve frame identity")
  //
  // Every lane of a beat must carry the SAME absolute frame number. Once an
  // entry has one, the test is a comparison against the register. Before it
  // has one — the first cycle any response reaches it — there is nothing to
  // compare against yet, and the responses that arrive in THAT cycle have to be
  // compared against each other, or the hazard escapes exactly when it is most
  // likely: BIN_PAR independent history instances answer a group's requests in
  // step, so the natural case is that they all arrive together.
  //
  // The reference is the LOWEST-NUMBERED arriving lane of the entry, found by a
  // prefix scan across lanes. Lowest-numbered rather than arbitrary because the
  // rule has to be stated somewhere both the RTL and model/cpp/align can
  // implement; "whichever the tool happened to pick last" is not a rule.
  //
  // Cost is BIN_PAR*(BIN_PAR-1)/2 selections of one frame id, not GROUPS x
  // BIN_PAR: the scan is over lanes, and the entry-indexed part
  // (`l_regfid`) is a lookup this block already had to do for the group and
  // offset comparison.
  // ---------------------------------------------------------------------------
  always_comb begin
    for (int unsigned l = 0; l < BIN_PAR; l++) begin
      // Default: the entry's registered id if it has one, otherwise this lane's
      // own — a lane with no earlier peer is its own reference and passes.
      l_ref[l] = l_fidset[l] ? l_regfid[l] : l_fid[l];
      if (!l_fidset[l]) begin
        // Descending, so the LAST assignment (and therefore the winner) is the
        // lowest-numbered matching lane.
        for (int unsigned j = BIN_PAR; j > 0; j--) begin
          if ((j - 1) < l) begin
            if (l_cand[j-1] && (l_gid[j-1] == l_gid[l])) l_ref[l] = l_fid[j-1];
          end
        end
      end
    end
  end

  always_comb begin
    for (int unsigned l = 0; l < BIN_PAR; l++) begin
      automatic logic key_ok;
      automatic logic is_dup;
      key_ok = l_cand[l] && (l_fid[l] == l_ref[l]);
      is_dup = key_ok && l_present[l];

      l_orphan[l] = l_fire[l] && !key_ok;
      // A word that named an OPEN entry and still failed is the tag-collision
      // case: the beat it landed on is a real beat and it is now suspect, so the
      // fault is recorded on that beat as well as counted. A word that named a
      // closed entry belongs to no beat and is only counted.
      l_orphan_at[l] = l_open[l] && !key_ok;
      l_dup[l]       = is_dup;
      l_write[l]     = key_ok && !is_dup;
    end
  end

  // ---------------------------------------------------------------------------
  // Retirement
  // ---------------------------------------------------------------------------
  wire                head_open  = e_valid[head_q];
  wire [BIN_PAR-1:0]  head_pres  = e_present[head_q];
  wire                head_full  = &head_pres;
  wire                head_late  = e_age[head_q] >= TO_W'(TIMEOUT_CYCLES);

  wire                push_ready;   // from the output elastic buffer
  wire                emit = head_open && (head_full || head_late) && push_ready;

  // Ages advance only in cycles the block could have retired a beat (header
  // section 2).
  wire                age_en = push_ready;

  // Number of lanes that never answered, on the beat being emitted.
  logic [MIS_W-1:0]   miss_n;
  always_comb begin
    miss_n = '0;
    for (int unsigned l = 0; l < BIN_PAR; l++) begin
      if (!head_pres[l]) miss_n = miss_n + MIS_W'(1);
    end
  end

  // ---------------------------------------------------------------------------
  // Allocation
  // ---------------------------------------------------------------------------
  assign alloc_ready = en_alloc && (count_q < CNT_W'(GROUPS));
  wire   alloc_fire  = alloc_valid && alloc_ready;

  always_ff @(posedge clk) begin
    if (!rst_n) begin
      head_q  <= '0;
      tail_q  <= '0;
      count_q <= '0;
    end else begin
      if (alloc_fire) tail_q <= tail_q + GID_W'(1);
      if (emit)       head_q <= head_q + GID_W'(1);
      case ({alloc_fire, emit})
        2'b10:   count_q <= count_q + CNT_W'(1);
        2'b01:   count_q <= count_q - CNT_W'(1);
        default: count_q <= count_q;
      endcase
    end
  end

  // ---------------------------------------------------------------------------
  // Entry updates
  // ---------------------------------------------------------------------------
  for (genvar g = 0; g < int'(GROUPS); g++) begin : g_entry
    wire alloc_here = alloc_fire && (alloc_gid == GID_W'(g));
    wire emit_here  = emit       && (head_q    == GID_W'(g));

    // Which lanes write into this entry this cycle, and the OR of the history
    // flags they brought with them. The OR is computed combinationally rather
    // than by accumulating inside a loop of non-blocking assignments, where only
    // the last iteration would survive.
    logic [BIN_PAR-1:0]      wr_here;
    logic [BIN_PAR-1:0]      dup_here;
    logic [BIN_PAR-1:0]      orph_here;
    logic [HIST_FLAGS_W-1:0] flg_here;
    // The frame id the entry adopts, from the lowest-numbered lane writing this
    // cycle. Only used when no response has arrived yet, so which lane it comes
    // from is arbitrary and the choice is made deterministic rather than left to
    // whichever iteration happens to be last.
    logic [FID_W-1:0]        fid_here;
    always_comb begin
      wr_here   = '0;
      dup_here  = '0;
      orph_here = '0;
      flg_here  = '0;
      fid_here  = '0;
      for (int unsigned l = 0; l < BIN_PAR; l++) begin
        if (l_gid[l] == GID_W'(g)) begin
          wr_here[l]   = l_write[l];
          dup_here[l]  = l_dup[l];
          orph_here[l] = l_orphan_at[l];
          if (l_write[l]) flg_here = flg_here | l_flag[l];
        end
      end
      for (int unsigned l = BIN_PAR; l > 0; l--) begin
        if ((l_gid[l-1] == GID_W'(g)) && wr_here[l-1]) fid_here = l_fid[l-1];
      end
    end

    always_ff @(posedge clk) begin
      if (!rst_n) begin
        e_valid[g] <= 1'b0;
      end else if (alloc_here) begin
        e_valid[g] <= 1'b1;
      end else if (emit_here) begin
        e_valid[g] <= 1'b0;
      end
    end

    always_ff @(posedge clk) begin
      if (alloc_here) begin
        e_gidx[g] <= alloc_gidx;
        e_foff[g] <= alloc_foff;
        e_sof[g]  <= alloc_sof;
        e_eof[g]  <= alloc_eof;
      end
    end

    always_ff @(posedge clk) begin
      if (!rst_n) begin
        e_present[g] <= '0;
        e_dup[g]     <= 1'b0;
        e_orphan[g]  <= 1'b0;
        e_hflag[g]   <= '0;
      end else if (alloc_here) begin
        e_present[g] <= '0;
        e_dup[g]     <= 1'b0;
        e_orphan[g]  <= 1'b0;
        e_hflag[g]   <= '0;
      end else begin
        e_present[g] <= e_present[g] | wr_here;
        e_dup[g]     <= e_dup[g]     | (|dup_here);
        e_orphan[g]  <= e_orphan[g]  | (|orph_here);
        e_hflag[g]   <= e_hflag[g]   | flg_here;
      end
    end

    always_ff @(posedge clk) begin
      if (!rst_n) begin
        e_fid_set[g] <= 1'b0;
      end else if (alloc_here) begin
        e_fid_set[g] <= 1'b0;
      end else if (|wr_here) begin
        e_fid_set[g] <= 1'b1;
      end
    end

    always_ff @(posedge clk) begin
      if ((|wr_here) && !e_fid_set[g]) e_fid[g] <= fid_here;
    end

    always_ff @(posedge clk) begin
      if (!rst_n) begin
        e_age[g] <= '0;
      end else if (alloc_here) begin
        e_age[g] <= '0;
      end else if (e_valid[g] && age_en && (e_age[g] < TO_W'(TIMEOUT_CYCLES))) begin
        e_age[g] <= e_age[g] + TO_W'(1);
      end
    end

    // Payload storage. Lane `l` only ever writes column `l`, so the columns are
    // independent and no write port is shared.
    for (genvar l = 0; l < int'(BIN_PAR); l++) begin : g_cell
      always_ff @(posedge clk) begin
        if (wr_here[l]) e_store[g][l] <= l_vec[l];
      end
    end : g_cell
  end : g_entry

  // ---------------------------------------------------------------------------
  // The output beat
  // ---------------------------------------------------------------------------
  logic [SEQ_W-1:0] seq_q;

  always_ff @(posedge clk) begin
    if (!rst_n) begin
      seq_q <= '0;
    end else if (emit) begin
      seq_q <= seq_q + SEQ_W'(1);
    end
  end

  logic [OUT_W-1:0] beat_data;
  always_comb begin
    beat_data = '0;
    for (int unsigned l = 0; l < BIN_PAR; l++) begin
      if (head_pres[l] || cfg_partial_pass) begin
        beat_data[l*VEC_W +: VEC_W] = e_store[head_q][l];
      end
    end
  end

  wire [ALGN_USER_W-1:0] beat_user = {
      |e_hflag[head_q],        // ALGN_USER_HIST
      e_orphan[head_q],        // ALGN_USER_ORPHAN
      e_dup[head_q],           // ALGN_USER_DUPLICATE
      |(~head_pres)            // ALGN_USER_MISSING
  };

  stream_fields_t beat_f;
  always_comb begin
    beat_f           = '0;
    beat_f.data      = STREAM_MAX_DATA_W'(beat_data);
    beat_f.sof       = e_sof[head_q];
    beat_f.eof       = e_eof[head_q];
    beat_f.stream_id = '0;
    beat_f.seq       = STREAM_MAX_SEQ_W'(seq_q);
    beat_f.user      = STREAM_MAX_USER_W'(beat_user);
  end

  wire [M_PAYLOAD_W-1:0] push_payload = M_PAYLOAD_W'(stream_pack(OGEOM, beat_f));

  wire [$clog2(OUT_DEPTH+1)-1:0] out_occ_unused;

  stream_elastic_buffer #(
      .PAYLOAD_W   (M_PAYLOAD_W),
      .DEPTH       (OUT_DEPTH),
      .DATA_W      (OUT_W),
      .STREAM_ID_W (STREAM_ID_W),
      .SEQ_W       (SEQ_W),
      .USER_W      (USER_W)
  ) u_out (
      .clk       (clk),
      .rst_n     (rst_n),
      .s_valid   (emit),
      .s_ready   (push_ready),
      .s_payload (push_payload),
      .m_valid   (m_valid),
      .m_ready   (m_ready),
      .m_payload (m_payload),
      .occupancy (out_occ_unused)
  );

  // ---------------------------------------------------------------------------
  // Telemetry (SPEC 9). Saturating, exactly as history_core's are: a wrapped
  // error counter reads like a healthy one.
  // ---------------------------------------------------------------------------
  wire miss_event = emit && (miss_n != '0);
  wire to_event   = emit && head_late && !head_full;

  logic [MIS_W-1:0] dup_n, orph_n;
  always_comb begin
    dup_n  = '0;
    orph_n = '0;
    for (int unsigned l = 0; l < BIN_PAR; l++) begin
      if (l_dup[l])    dup_n  = dup_n  + MIS_W'(1);
      if (l_orphan[l]) orph_n = orph_n + MIS_W'(1);
    end
  end

  // ---------------------------------------------------------------------------
  // The verdict/count split  (issue #17, from DECISIONS.md issue #16 finding 6)
  //
  // The measured worst path of this block ran from the routing fabric's output
  // register straight into `u_cnt_dup`'s adder — eleven levels of logic covering
  // the identity comparison, the duplicate decision, the population count across
  // lanes and the saturating counter's own add, in ONE combinational cone.
  // 241 MHz, which is the number that limited the whole block in both
  // architectures (the cone is in logic they share).
  //
  // The fix is this register stage, and it is legitimate for one specific
  // reason: every signal crossing it is TELEMETRY. The entry-write path — which
  // must stay same-cycle, because a response has to land in its entry on the
  // cycle it arrives — is `l_write`/`wr_here` and does not pass through here.
  // A count that lands one cycle later is indistinguishable from an on-time one
  // to every consumer of `stat_*`, which are register-plane reads.
  //
  // COUNTS ARE UNCHANGED, not merely "close": `cfg_counter_clear` and
  // `cfg_sticky_clear` are delayed by the SAME one cycle, so the interleaving of
  // events and clears is preserved exactly. A clear that used to discard an
  // event still discards it and one that used to follow it still follows it.
  // sim/tests/test_align.cpp checks the counters after the run quiesces, and
  // sim/tests/test_pipeline_continuous.cpp checks this property directly.
  // ---------------------------------------------------------------------------
  logic [MIS_W-1:0] dup_n_q, orph_n_q, miss_n_q;
  logic             miss_ev_q, to_ev_q, emit_q, hist_ev_q;
  logic             cnt_clear_q, stky_clear_q;

  always_ff @(posedge clk) begin
    if (!rst_n) begin
      dup_n_q      <= '0;
      orph_n_q     <= '0;
      miss_n_q     <= '0;
      miss_ev_q    <= 1'b0;
      to_ev_q      <= 1'b0;
      emit_q       <= 1'b0;
      hist_ev_q    <= 1'b0;
      cnt_clear_q  <= 1'b0;
      stky_clear_q <= 1'b0;
    end else begin
      dup_n_q      <= dup_n;
      orph_n_q     <= orph_n;
      miss_n_q     <= miss_n;
      miss_ev_q    <= miss_event;
      to_ev_q      <= to_event;
      emit_q       <= emit;
      hist_ev_q    <= emit && (|e_hflag[head_q]);
      cnt_clear_q  <= cfg_counter_clear;
      stky_clear_q <= cfg_sticky_clear;
    end
  end

  // The observation ports no consumer here wants. Named `*_unused` because that
  // is what the linter's unused-signal regexp matches, which keeps `--Wall`
  // clean without a design-wide waiver on a rule that catches real wiring
  // mistakes. Same device, same reason, as history_core.
  wire [TELEM_W-1:0] c_beat, c_miss, c_dup, c_orph, c_to;
  wire b_snapv_unused, b_wrapp_unused, b_wrapd_unused;
  wire m_snapv_unused, m_wrapp_unused, m_wrapd_unused;
  wire d_snapv_unused, d_wrapp_unused, d_wrapd_unused;
  wire o_snapv_unused, o_wrapp_unused, o_wrapd_unused;
  wire t_snapv_unused, t_wrapp_unused, t_wrapd_unused;
  wire [TELEM_W-1:0] b_snap_unused, m_snap_unused, d_snap_unused,
                     o_snap_unused, t_snap_unused;

  perf_counter #(.WIDTH(TELEM_W), .INCR_W(1), .SATURATE(1'b1)) u_cnt_beat (
      .clk (clk), .rst_n (rst_n), .enable (1'b1),
      .event_i (emit_q), .incr (1'b1),
      .clear (cnt_clear_q), .snapshot (1'b0),
      .count (c_beat), .snap (b_snap_unused), .snap_valid (b_snapv_unused),
      .wrap_pulse (b_wrapp_unused), .wrapped (b_wrapd_unused)
  );

  perf_counter #(.WIDTH(TELEM_W), .INCR_W(MIS_W), .SATURATE(1'b1)) u_cnt_miss (
      .clk (clk), .rst_n (rst_n), .enable (1'b1),
      .event_i (miss_ev_q), .incr (miss_n_q),
      .clear (cnt_clear_q), .snapshot (1'b0),
      .count (c_miss), .snap (m_snap_unused), .snap_valid (m_snapv_unused),
      .wrap_pulse (m_wrapp_unused), .wrapped (m_wrapd_unused)
  );

  perf_counter #(.WIDTH(TELEM_W), .INCR_W(MIS_W), .SATURATE(1'b1)) u_cnt_dup (
      .clk (clk), .rst_n (rst_n), .enable (1'b1),
      .event_i (dup_n_q != '0), .incr (dup_n_q),
      .clear (cnt_clear_q), .snapshot (1'b0),
      .count (c_dup), .snap (d_snap_unused), .snap_valid (d_snapv_unused),
      .wrap_pulse (d_wrapp_unused), .wrapped (d_wrapd_unused)
  );

  perf_counter #(.WIDTH(TELEM_W), .INCR_W(MIS_W), .SATURATE(1'b1)) u_cnt_orph (
      .clk (clk), .rst_n (rst_n), .enable (1'b1),
      .event_i (orph_n_q != '0), .incr (orph_n_q),
      .clear (cnt_clear_q), .snapshot (1'b0),
      .count (c_orph), .snap (o_snap_unused), .snap_valid (o_snapv_unused),
      .wrap_pulse (o_wrapp_unused), .wrapped (o_wrapd_unused)
  );

  perf_counter #(.WIDTH(TELEM_W), .INCR_W(1), .SATURATE(1'b1)) u_cnt_to (
      .clk (clk), .rst_n (rst_n), .enable (1'b1),
      .event_i (to_ev_q), .incr (1'b1),
      .clear (cnt_clear_q), .snapshot (1'b0),
      .count (c_to), .snap (t_snap_unused), .snap_valid (t_snapv_unused),
      .wrap_pulse (t_wrapp_unused), .wrapped (t_wrapd_unused)
  );

  assign stat_beat_count    = c_beat;
  assign stat_missing_count = c_miss;
  assign stat_dup_count     = c_dup;
  assign stat_orphan_count  = c_orph;
  assign stat_timeout_count = c_to;

  // Sticky faults, same encoding as the beat's `user` field so one decode serves
  // both. A counter that has been cleared no longer says whether the condition
  // ever happened; this does.
  logic [ALGN_FAULT_W-1:0] fault_q;
  always_ff @(posedge clk) begin
    if (!rst_n || stky_clear_q) begin
      fault_q <= '0;
    end else begin
      if (miss_ev_q)      fault_q[ALGN_USER_MISSING]   <= 1'b1;
      if (dup_n_q  != '0) fault_q[ALGN_USER_DUPLICATE] <= 1'b1;
      if (orph_n_q != '0) fault_q[ALGN_USER_ORPHAN]    <= 1'b1;
      if (hist_ev_q)      fault_q[ALGN_USER_HIST]      <= 1'b1;
    end
  end
  assign stat_fault = fault_q;

`ifndef SYNTHESIS
  // SPEC 14. Two properties the data comparison cannot localise.
  always_ff @(posedge clk) begin
    if (rst_n) begin
      // An entry may only be retired once, in order: the head must be open
      // whenever a beat leaves.
      a_align_emit_open : assert (!emit || head_open)
        else $error("align_collect: a beat was emitted from an entry that was not open");
      // The allocation pointer and the entry index derived from the bin must
      // agree, or the arithmetic-index argument (header section 1) is false.
      a_align_alloc_ptr : assert (!alloc_fire || (alloc_gid == tail_q))
        else $error("align_collect: allocation at entry %0d but the buffer's tail is %0d",
                    alloc_gid, tail_q);
    end
  end
`endif

endmodule : align_collect

`default_nettype wire
