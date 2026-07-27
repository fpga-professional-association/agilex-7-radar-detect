// -----------------------------------------------------------------------------
// align_net — the SPEC.md 7.4 frequency-bin alignment network (issue #16).
//
// One module, one interface, either architecture. `NET_SEL` picks the direct
// registered crossbar or the multistage omega network; nothing else about the
// block changes, which is what makes SPEC 7.4's mandated comparison a comparison
// of routing fabrics rather than of two designs.
//
//     BIN_PAR history read ports                     one beamformer beat
//     ==========================                     ===================
//
//   rd_req[p] ---> (history_core p) ---> rsp[p] --+
//        ^                                        |   +----------+
//        |                                        +-->| ingress  |
//   +----+-----+                                      | decode   |
//   | align_   |  allocates an entry, then issues     +----+-----+
//   | sched    |  BIN_PAR requests in one cycle            | dst = bin[low]
//   +----+-----+                                           v
//        | alloc                                    +-------------+
//        |                                          | align_      |  xbar
//        |                                          | switch      |   or
//        |                                          +------+------+  clos
//        |                                                 | BIN_PAR lanes
//        v                                                 v
//   +--------------------------------------------------------------+
//   | align_collect : reassembly, identity check, missing/duplicate |
//   +--------------------------------+-----------------------------+
//                                    v
//                     SPEC 5 stream, BIN_PAR x N_ANT beat
//
// The interpretation of SPEC 7.4 this block implements — in particular why the
// antenna transpose is NOT here, and what is left once #15's corner turn has
// done it — is stated at length in rtl/align/align_pkg.sv section 0. Read that
// first; ARCHITECTURE.md repeats it and DECISIONS.md records it as a decision.
//
// -----------------------------------------------------------------------------
// 1. THE SCHEDULER, AND WHY IT ISSUES A WHOLE GROUP AT ONCE
// -----------------------------------------------------------------------------
// A group is one output beat: BIN_PAR consecutive bins of one frame. The
// scheduler issues ALL BIN_PAR of its requests in a single cycle, across
// BIN_PAR independent history read ports, or it issues none of them.
//
// All-or-nothing rather than port-by-port, and the reason is that the
// alternative buys nothing and costs the invariant. Issuing partially would let
// a group start while one port is busy — but that group still cannot retire
// until its last response arrives, so the beat rate is unchanged; what changes
// is that groups would no longer be strictly ordered in the reassembly buffer,
// and `align_collect`'s entry index would stop being a bit slice of the bin
// (align_pkg section 3). The whole detector's cheapness rests on that slice.
//
// A group is issued when, in one cycle: the block is enabled, a reassembly entry
// is free, and every request port can take a request. The sustained rate is
// therefore ONE BEAT PER CYCLE — BIN_PAR bins per cycle — and every departure
// from it is one of those three conditions failing, which is exactly what
// `stat_issue_stall_count` counts and what `test_align`'s throughput pass
// measures against the model.
//
// THE SCHEDULE ROTATES: beat position `j` of group `g` is requested on port
// (j + g) mod BIN_PAR. align_pkg section 2 gives the physical reason (a fixed
// assignment would pin every port to one residue class of bins and therefore to
// one subset of #15's memory lanes, forever). The consequence here is the one
// that matters for this issue: the mapping from response port to beat position
// is a DIFFERENT cyclic permutation on every group, so the network is routing a
// genuinely time-varying permutation rather than a wiring diagram.
//
// -----------------------------------------------------------------------------
// 2. THE INGRESS REGISTER IS PART OF THE BLOCK, NOT OF EITHER ARCHITECTURE
// -----------------------------------------------------------------------------
// The response payload is unpacked, its metadata decoded, and the routing key
// sliced out of the bin index — all before the network sees anything, and the
// result is registered. That register is HERE rather than inside `align_xbar`
// or `align_clos` for one reason: it must be identical in both, or the two
// measurements would differ by a decode stage instead of by a topology.
//
// It is also what makes `in_ready` safe. `align_clos`'s ready is a function of
// its inputs' valids (a switch cannot promise to accept until it knows whether
// its neighbour is competing), and a producer whose valid depended on ready
// would close a combinational loop. A registered ingress cannot.
//
// -----------------------------------------------------------------------------
// 3. FAULT INJECTION IS A TAG COLLISION, AND IT IS ONE-SHOT
// -----------------------------------------------------------------------------
// SPEC 9 wants a way to make the detector fire without breaking the design.
// `cfg_force_unsafe` is edge-armed: a rising edge arms it, and the NEXT group
// issued opens its reassembly entry LABELLED WITH THE WRONG GROUP INDEX — the
// following one's. Its BIN_PAR requests go out normally. The responses then
// compute the right entry (the entry index is a slice of their own bin index)
// and find it open but labelled for a different group: a tag collision, in the
// exact sense the issue asks about. `align_collect` refuses every one of the
// writes, advances `stat_orphan_count` by BIN_PAR, and the entry ages out and
// emits a beat marked `ALGN_USER_MISSING | ALGN_USER_ORPHAN` with
// `stat_missing_count` advanced by BIN_PAR. Every number is exact, which is what
// makes it a test rather than a demonstration.
//
// MIS-LABELLING RATHER THAN SKIPPING THE ALLOCATION, and the difference matters:
// skipping would desynchronise the allocation pointer from the group counter
// permanently, breaking align_collect's arithmetic-index invariant for the rest
// of the run — the injection would damage the block instead of exercising the
// detector. Mis-labelling leaves both pointers in step, so the run recovers
// completely on the next group and the test can prove that it does.
//
// Edge-armed rather than level-driven so that one strobe injects exactly one
// fault. A level would corrupt every group for as long as it was high, which
// produces a flood the test cannot count exactly, and an inexact expectation is
// not a test.
//
// -----------------------------------------------------------------------------
// 4. WHAT CROSSES A CLOCK DOMAIN HERE: NOTHING
// -----------------------------------------------------------------------------
// This block is single-clock, in `history_clk`, because both of its interfaces
// already are: history_pkg section 5 puts the read request and the read response
// in that domain, and the beamformer that consumes the output beat is in it too
// (ARCHITECTURE.md 4). There is no CDC primitive here and no
// `(* cdc_primitive *)` attribute, and `scripts/cdc_inventory.py --strict`
// therefore expects to find no crossing in this hierarchy — which is a check,
// not an absence: a two-clock module added here without a tag would fail it.
//
// Lint contract: clean under `verilator --lint-only --Wall` with no waiver.
// -----------------------------------------------------------------------------

`default_nettype none

module align_net
  import align_pkg::*;
  import history_pkg::*;
  import stream_pkg::*;
#(
    // ---- the history geometry this block reads from (history_pkg) ----
    parameter int unsigned N_ANT      = 2,
    parameter int unsigned FFT_SIZE   = 64,
    parameter int unsigned LANES      = 1,
    parameter int unsigned FRAMES_MAX = 4,
    parameter int unsigned SAMPLE_W   = 16,

    // ---- this block's own geometry ----
    // Bins per output beat. Also the number of history read ports and the width
    // of the routing network: the network is square by construction.
    parameter int unsigned BIN_PAR = 2,
    // Reassembly entries. Power of two; must divide FFT_SIZE / BIN_PAR.
    parameter int unsigned GROUPS  = 4,

    // ---- the SPEC 7.4 architecture selector ----
    // MEASURED DEFAULT (issue #16 SPEC 18 sweep; changed from 0 to 1 by issue
    // #17 when this block was instantiated in the pipeline, exactly as
    // DECISIONS.md issue #16's recommendation asked). At the full-scale routing
    // width the omega network is 24.6% fewer ALMs, 31.4% fewer registers and
    // clears 400 MHz where the crossbar measured 296.5; the crossbar remains
    // buildable and verified so the SPEC 7.4 comparison stays reproducible.
    parameter int unsigned NET_SEL    = 1,   // 0 = crossbar, 1 = omega
    parameter int unsigned MUX_STAGES = 2,   // crossbar mux levels

    // Missing-sample timeout, in cycles of PROGRESS (align_collect section 2).
    // Defaulted from align_pkg so it moves with the geometry and the chosen
    // architecture rather than being a number somebody has to remember to
    // change.
    parameter int unsigned TIMEOUT_CYCLES =
        int'(algn_default_timeout(algn_geom(N_ANT, FFT_SIZE, LANES, FRAMES_MAX,
                                            SAMPLE_W, BIN_PAR, GROUPS),
                                  algn_uint_t'(NET_SEL),
                                  algn_uint_t'(MUX_STAGES))),

    // ---- SPEC 5 field geometry of the history response streams ----
    parameter int unsigned RD_ID_W   = 2,
    parameter int unsigned RD_SEQ_W  = 16,
    parameter int unsigned RD_USER_W = 4,

    // ---- SPEC 5 field geometry of the output stream ----
    parameter int unsigned STREAM_ID_W = 2,
    parameter int unsigned SEQ_W       = 16,
    parameter int unsigned USER_W      = 4,

    parameter int unsigned OUT_DEPTH = 4,
    parameter int unsigned TELEM_W   = 32,

    // ---- DERIVED; never overridden ----
    parameter int unsigned RSP_PAYLOAD_W =
        int'(stream_payload_w(stream_geom(
            hist_data_w(hist_geom(N_ANT, FFT_SIZE, LANES, FRAMES_MAX, SAMPLE_W)),
            RD_ID_W, RD_SEQ_W, RD_USER_W))),
    parameter int unsigned M_PAYLOAD_W =
        int'(stream_payload_w(stream_geom(
            algn_out_data_w(algn_geom(N_ANT, FFT_SIZE, LANES, FRAMES_MAX,
                                      SAMPLE_W, BIN_PAR, GROUPS)),
            STREAM_ID_W, SEQ_W, USER_W)))
) (
    input  wire                            clk,
    input  wire                            rst_n,

    // ---- configuration ----
    input  wire                            cfg_enable,
    // Sweep gate. While high the scheduler walks the spectrum continuously.
    // Dropping it stops AT THE NEXT FRAME BOUNDARY, never mid-frame, so the
    // output stream always ends on a beat carrying `eof` and never leaves a
    // SPEC 5 frame open — which is the difference between stopping the block and
    // corrupting its output. Raising it again resumes at bin 0 of a new frame.
    //
    // It is separate from `cfg_enable` because the two mean different things and
    // conflating them is a deadlock: `cfg_enable` low also stops the block
    // ACCEPTING responses, so a block disabled with work in flight would strand
    // its own reassembly entries and report them as missing samples. `cfg_run`
    // low keeps every consumer running and only closes the tap.
    input  wire                            cfg_run,
    // Which frame the next sweep reads, in #15's relative encoding: 0 = newest
    // complete frame. Latched at the start of every sweep, so a frame is always
    // assembled from ONE offset even if software changes it mid-frame.
    input  wire [HIST_PORT_W-1:0]          cfg_frame_off,
    input  wire                            cfg_partial_pass,
    input  wire                            cfg_counter_clear,
    input  wire                            cfg_sticky_clear,
    input  wire [BIN_PAR-1:0]              cfg_lane_stall,
    // SPEC 9 tag-collision injection. Edge-armed; see header section 3.
    input  wire                            cfg_force_unsafe,

    // ---- request masters, one per history read port ----
    output wire [BIN_PAR-1:0]              rd_req_valid,
    input  wire [BIN_PAR-1:0]              rd_req_ready,
    output wire [BIN_PAR*HIST_PORT_W-1:0]  rd_req_bin,
    output wire [BIN_PAR*HIST_PORT_W-1:0]  rd_req_frame_off,

    // ---- response slaves, one per history read port (SPEC 5) ----
    input  wire [BIN_PAR-1:0]              rsp_valid,
    output wire [BIN_PAR-1:0]              rsp_ready,
    input  wire [BIN_PAR*RSP_PAYLOAD_W-1:0] rsp_payload,

    // ---- the beamformer input beat (SPEC 5) ----
    output wire                            m_valid,
    input  wire                            m_ready,
    output wire [M_PAYLOAD_W-1:0]          m_payload,

    // ---- telemetry (SPEC 9) ----
    output wire [TELEM_W-1:0]              stat_beat_count,
    output wire [TELEM_W-1:0]              stat_issue_count,
    output wire [TELEM_W-1:0]              stat_issue_stall_count,
    output wire [TELEM_W-1:0]              stat_missing_count,
    output wire [TELEM_W-1:0]              stat_dup_count,
    output wire [TELEM_W-1:0]              stat_orphan_count,
    output wire [TELEM_W-1:0]              stat_timeout_count,
    output wire [TELEM_W-1:0]              stat_conflict_count,
    // Cycles in which the network delivered more than one lane at once. THE
    // throughput statement SPEC 7.4's comparison rests on: a run in which this
    // stayed at zero never asked the network to do anything a bundle of wires
    // could not do, and any architecture comparison drawn from it would be a
    // comparison of two idle networks. test_align fails a run in which it is
    // zero, which is why it is telemetry rather than a simulation artefact.
    output wire [TELEM_W-1:0]              stat_multi_lane_count,
    // Total routed words delivered, and a sticky bit per lane.
    output wire [TELEM_W-1:0]              stat_lane_word_count,
    output wire [BIN_PAR-1:0]              stat_lane_seen,
    // Groups mis-labelled by the SPEC 9 injection (header section 3).
    output wire [TELEM_W-1:0]              stat_inject_count,
    output wire [ALGN_FAULT_W-1:0]         stat_fault,

    // ---- elaborated geometry echo ----
    // Ports rather than parameters a consumer recomputes, for the reason
    // beamformer.sv exports its throughput numbers on ports: a figure in a pull
    // request should be readable out of the design that produced it.
    output wire [7:0]                      obs_net_sel,
    output wire [7:0]                      obs_net_latency,
    output wire [7:0]                      obs_block_latency,
    output wire [7:0]                      obs_bin_par,
    output wire [7:0]                      obs_groups
);

  // ---------------------------------------------------------------------------
  // Geometry
  // ---------------------------------------------------------------------------
  localparam algn_geom_t GEOM =
      algn_geom(N_ANT, FFT_SIZE, LANES, FRAMES_MAX, SAMPLE_W, BIN_PAR, GROUPS);
  localparam hist_geom_t HGEOM =
      hist_geom(N_ANT, FFT_SIZE, LANES, FRAMES_MAX, SAMPLE_W);

  localparam int unsigned VEC_W      = int'(algn_vec_w(GEOM));
  localparam int unsigned BIN_W      = int'(algn_bin_w(GEOM));
  localparam int unsigned LANE_W     = int'(algn_lane_w(GEOM));
  localparam int unsigned GID_W      = int'(algn_gid_w(GEOM));
  localparam int unsigned GIDX_W     = int'(algn_gidx_w(GEOM));
  localparam int unsigned FOFF_W     = int'(algn_foff_w(GEOM));
  localparam int unsigned FID_W      = int'(algn_fid_w());
  localparam int unsigned NET_DATA_W = int'(algn_net_data_w(GEOM));
  localparam int unsigned GPF        = int'(algn_groups_per_frame(GEOM));
  localparam int unsigned HIST_DATA_W = int'(hist_data_w(HGEOM));
  localparam int unsigned HIST_META_W = int'(hist_meta_w(HGEOM));

  localparam stream_geom_t RGEOM =
      stream_geom(HIST_DATA_W, RD_ID_W, RD_SEQ_W, RD_USER_W);

`ifndef SYNTHESIS
  initial begin
    if (!algn_geom_ok(GEOM)) begin
      $fatal(1, "align_net: illegal geometry (n_ant=%0d fft=%0d lanes=%0d frames=%0d sample_w=%0d bin_par=%0d groups=%0d)",
             N_ANT, FFT_SIZE, LANES, FRAMES_MAX, SAMPLE_W, BIN_PAR, GROUPS);
    end
    if (!hist_geom_ok(HGEOM)) begin
      $fatal(1, "align_net: the history geometry this block reads from is illegal");
    end
    if ((GPF % GROUPS) != 0) begin
      $fatal(1, "align_net: GROUPS=%0d must divide GROUPS_PER_FRAME=%0d", GROUPS, GPF);
    end
    if (!algn_net_sel_ok(algn_uint_t'(NET_SEL))) begin
      $fatal(1, "align_net: NET_SEL=%0d is not a known architecture", NET_SEL);
    end
    if (int'(hist_bin_w(HGEOM)) != BIN_W) begin
      $fatal(1, "align_net: bin width disagrees with history_pkg (%0d vs %0d)",
             BIN_W, int'(hist_bin_w(HGEOM)));
    end
    if (int'(hist_vec_w(HGEOM)) != VEC_W) begin
      $fatal(1, "align_net: antenna-vector width disagrees with history_pkg (%0d vs %0d)",
             VEC_W, int'(hist_vec_w(HGEOM)));
    end
    // The output beat must be exactly what beamformer_pkg says a beamformer
    // input beat is. Two files, one contract, checked rather than believed.
    if (int'(algn_out_data_w(GEOM)) !=
        int'(beamformer_pkg::bf_in_data_w(beamformer_pkg::bf_uint_t'(BIN_PAR),
                                          beamformer_pkg::bf_uint_t'(N_ANT)))) begin
      $fatal(1, "align_net: the output beat (%0d bits) is not beamformer_pkg's input beat (%0d bits)",
             int'(algn_out_data_w(GEOM)),
             int'(beamformer_pkg::bf_in_data_w(beamformer_pkg::bf_uint_t'(BIN_PAR),
                                               beamformer_pkg::bf_uint_t'(N_ANT))));
    end
    if (int'(hist_port_fits(HGEOM)) == 0) begin
      $fatal(1, "align_net: the geometry does not fit history_pkg's fixed control ports");
    end
    $display("[align_net] %s, BIN_PAR=%0d ports, GROUPS=%0d entries, %0d bins/frame, vec=%0d bits, beat=%0d bits, net latency=%0d, block latency=%0d, timeout=%0d",
             (NET_SEL == int'(ALGN_NET_CLOS)) ? "omega (clos)" : "direct crossbar",
             BIN_PAR, GROUPS, FFT_SIZE, VEC_W, int'(algn_out_data_w(GEOM)),
             int'(algn_net_latency(algn_uint_t'(NET_SEL), algn_uint_t'(BIN_PAR),
                                   algn_uint_t'(MUX_STAGES))),
             int'(algn_block_latency(algn_uint_t'(NET_SEL), algn_uint_t'(BIN_PAR),
                                     algn_uint_t'(MUX_STAGES))),
             TIMEOUT_CYCLES);
  end
`endif

  // ===========================================================================
  // The scheduler
  // ===========================================================================
  logic [GIDX_W-1:0]        gidx_q;
  // Carried at #15's full control-port width, not at FOFF_W, and driven onto the
  // request port unmodified. An offset that does not fit FOFF_W is OUT OF RANGE,
  // and history_pkg section 5 already defines what happens to it: #15 answers
  // deterministically, sets HIST_FLAG_OUT_OF_RANGE and advances its own error
  // counter. Truncating it here would instead send a DIFFERENT, perfectly legal
  // request and get a perfectly good answer to a question nobody asked. The
  // returned metadata then disagrees with the entry key and the responses are
  // counted as orphans — loud, exact, and correct: a software error is reported
  // rather than silently reinterpreted.
  logic [HIST_PORT_W-1:0]   foff_q;
  logic                     unsafe_arm_q;
  logic                     unsafe_prev_q;

  logic [BIN_PAR-1:0]       rq_valid_q;
  logic [BIN_W-1:0]         rq_bin_q   [BIN_PAR];
  logic [HIST_PORT_W-1:0]   rq_foff_q  [BIN_PAR];

  wire  [BIN_PAR-1:0]    rq_free = ~rq_valid_q | rd_req_ready;

  wire                   alloc_ready;
  wire                   inject     = unsafe_arm_q;
  wire                   ports_free = &rq_free;

  // "Finish the frame you started." A sweep in progress (gidx_q != 0) ignores
  // `cfg_run`; only the decision to begin a NEW frame consults it. That single
  // term is the whole frame-boundary stop — no state, no handshake, and no way
  // for a frame to be left open.
  // ---------------------------------------------------------------------------
  // Registered `cfg_enable` fanout  (issue #17, from DECISIONS.md issue #16
  // finding 7)
  //
  // The omega build's measured worst path was `en_q` into a stage-2 switch
  // register: 0.581 ns of cell delay against 5.469 ns of ROUTING. A 9:1
  // routing-to-logic ratio is not a logic path, it is one register driving most
  // of the block — the SPEC 23 "avoid one chip-wide clock enable" case, and the
  // same net exists in the crossbar build (masked there by finding 6's detector
  // path). Peak long-haul interconnect demand of 137% is the router's view of
  // the same fact.
  //
  // The fix is the one issue #15 demonstrated with `hist_addr_pipe`: a LOCAL
  // COPY per consumer instead of one register per block. `cfg_enable` is
  // quasi-static — it comes from a register-plane write — so a one-cycle-delayed
  // local copy is semantically identical, and every copy has the SAME one-cycle
  // delay, which is what keeps `issue`, `rsp_ready` and align_collect's
  // `lane_ready`/`alloc_ready` consistent with each other on every cycle. There
  // is no cycle in which one part of the block believes it is enabled and
  // another does not.
  //
  // `dont_merge`/`preserve` because the whole point is duplication: without them
  // synthesis is free to notice the copies are identical and rebuild the single
  // net this replaces. align_collect carries its own copy of this block for its
  // own consumers and is deliberately fed the RAW `cfg_enable`, so that it sees
  // exactly one register stage too rather than two.
  // ---------------------------------------------------------------------------
  localparam int unsigned EN_COPIES = BIN_PAR + 2;

  (* preserve *) (* dont_merge *) logic [EN_COPIES-1:0] en_q;

  always_ff @(posedge clk) begin
    if (!rst_n) en_q <= '0;
    else        en_q <= {EN_COPIES{cfg_enable}};
  end

  wire en_issue = en_q[BIN_PAR];
  wire en_tel   = en_q[BIN_PAR + 1];

  wire                   run_gate   = cfg_run || (gidx_q != '0);
  wire                   issue      = en_issue && run_gate && ports_free &&
                                      alloc_ready;

  // Every issued group opens an entry. The injection changes the LABEL, not the
  // bookkeeping (header section 3).
  wire                   alloc_valid = issue;

  wire [GIDX_W-1:0]      gidx_next =
      (gidx_q == GIDX_W'(GPF - 1)) ? '0 : (gidx_q + GIDX_W'(1));

  wire [GIDX_W-1:0]      alloc_gidx = inject ? gidx_next : gidx_q;

  // The frame offset a sweep uses is latched at its first group, so one frame is
  // always assembled from one offset.
  wire [HIST_PORT_W-1:0] foff_next = (gidx_q == '0) ? cfg_frame_off : foff_q;

  always_ff @(posedge clk) begin
    if (!rst_n) begin
      gidx_q        <= '0;
      foff_q        <= '0;
      unsafe_arm_q  <= 1'b0;
      unsafe_prev_q <= 1'b0;
    end else begin
      unsafe_prev_q <= cfg_force_unsafe;
      if (cfg_force_unsafe && !unsafe_prev_q) begin
        unsafe_arm_q <= 1'b1;
      end else if (issue) begin
        unsafe_arm_q <= 1'b0;
      end
      if (issue) begin
        foff_q <= foff_next;
        gidx_q <= gidx_next;
      end
    end
  end

  for (genvar p = 0; p < int'(BIN_PAR); p++) begin : g_req
    // Which beat position this port serves for the group being issued: the
    // inverse of align_pkg's rotating schedule, port(g, j) = (j + g) mod
    // BIN_PAR, so j = (p - g) mod BIN_PAR. BIN_PAR is a power of two, so every
    // modulo below is a mask; the arithmetic is done at 32 bits so that it does
    // not depend on GIDX_W being at least LANE_W, which the geometry does not
    // guarantee.
    wire [LANE_W-1:0] lane_for_port =
        LANE_W'(((32'(p) + 32'(BIN_PAR)) - (32'(gidx_q) & 32'(BIN_PAR - 1)))
                & 32'(BIN_PAR - 1));

    wire [BIN_W-1:0] bin_for_port =
        BIN_W'((32'(gidx_q) << LANE_W) | 32'(lane_for_port));

    always_ff @(posedge clk) begin
      if (!rst_n) begin
        rq_valid_q[p] <= 1'b0;
      end else if (issue) begin
        rq_valid_q[p] <= 1'b1;
      end else if (rd_req_ready[p]) begin
        rq_valid_q[p] <= 1'b0;
      end
    end

    always_ff @(posedge clk) begin
      if (issue) begin
        rq_bin_q[p]  <= bin_for_port;
        rq_foff_q[p] <= foff_next;
      end
    end

    assign rd_req_valid[p] = rq_valid_q[p];
    assign rd_req_bin[p*HIST_PORT_W +: HIST_PORT_W]       = HIST_PORT_W'(rq_bin_q[p]);
    assign rd_req_frame_off[p*HIST_PORT_W +: HIST_PORT_W] = rq_foff_q[p];
  end : g_req

  // ===========================================================================
  // Ingress decode (header section 2)
  // ===========================================================================
  logic [BIN_PAR-1:0]        ing_valid_q;
  logic [NET_DATA_W-1:0]     ing_data_q [BIN_PAR];
  logic [LANE_W-1:0]         ing_dst_q  [BIN_PAR];

  wire  [BIN_PAR-1:0]        sw_in_ready;
  wire  [BIN_PAR-1:0]        ing_free = ~ing_valid_q | sw_in_ready;

  logic [BIN_PAR*NET_DATA_W-1:0] sw_in_data;
  logic [BIN_PAR*LANE_W-1:0]     sw_in_dst;

  for (genvar p = 0; p < int'(BIN_PAR); p++) begin : g_ing
    // The `data` field is sliced out of the payload directly rather than through
    // a `stream_fields_t`: this block wants one of the six fields, and an
    // unpacked struct would leave five of them dead. The offset comes from
    // stream_pkg's own accessor, which is the normative statement of the layout.
    wire [HIST_DATA_W-1:0] r_data =
        rsp_payload[p*RSP_PAYLOAD_W + int'(stream_data_lsb(RGEOM)) +: HIST_DATA_W];

    hist_meta_fields_t mf;
    assign mf = hist_meta_unpack(HGEOM, hist_meta_t'(r_data[VEC_W +: HIST_META_W]));

    wire [VEC_W-1:0]        r_vec  = r_data[VEC_W-1:0];
    wire [BIN_W-1:0]        r_bin  = BIN_W'(mf.bin);
    wire [FOFF_W-1:0]       r_foff = FOFF_W'(mf.frame_off);
    wire [FID_W-1:0]        r_fid  = mf.frame_id;
    wire [HIST_FLAGS_W-1:0] r_flag = mf.flags;

    // The routed word: identity above the vector (align_pkg, "The routed word").
    wire [NET_DATA_W-1:0] word = {r_flag, r_fid, r_foff, r_bin, r_vec};

    // Local copy of the enable, one register per response port (see the fanout
    // block above), never the block-wide net.
    wire en_p = en_q[p];

    wire load = ing_free[p] && rsp_valid[p] && en_p;

    assign rsp_ready[p] = ing_free[p] && en_p;

    always_ff @(posedge clk) begin
      if (!rst_n) begin
        ing_valid_q[p] <= 1'b0;
      end else if (load) begin
        ing_valid_q[p] <= 1'b1;
      end else if (sw_in_ready[p]) begin
        ing_valid_q[p] <= 1'b0;
      end
    end

    always_ff @(posedge clk) begin
      if (load) begin
        ing_data_q[p] <= word;
        ing_dst_q[p]  <= r_bin[LANE_W-1:0];
      end
    end

    assign sw_in_data[p*NET_DATA_W +: NET_DATA_W] = ing_data_q[p];
    assign sw_in_dst[p*LANE_W +: LANE_W]          = ing_dst_q[p];
  end : g_ing

  // ===========================================================================
  // The routing network — either architecture, one instance
  // ===========================================================================
  wire [BIN_PAR-1:0]             lane_valid;
  wire [BIN_PAR-1:0]             lane_ready;
  wire [BIN_PAR*NET_DATA_W-1:0]  lane_data;
  wire                           conflict_event;
  wire [7:0]                     net_latency;

  align_switch #(
      .N          (BIN_PAR),
      .DATA_W     (NET_DATA_W),
      .NET_SEL    (NET_SEL),
      .MUX_STAGES (MUX_STAGES),
      .DST_W      (LANE_W)
  ) u_switch (
      .clk            (clk),
      .rst_n          (rst_n),
      .in_valid       (ing_valid_q),
      .in_ready       (sw_in_ready),
      .in_data        (sw_in_data),
      .in_dst         (sw_in_dst),
      .out_valid      (lane_valid),
      .out_ready      (lane_ready),
      .out_data       (lane_data),
      .conflict_event (conflict_event),
      .net_latency    (net_latency)
  );

  // ===========================================================================
  // Reassembly and detection
  // ===========================================================================
  wire [GID_W:0] open_groups_unused;

  align_collect #(
      .N_ANT          (N_ANT),
      .FFT_SIZE       (FFT_SIZE),
      .LANES          (LANES),
      .FRAMES_MAX     (FRAMES_MAX),
      .SAMPLE_W       (SAMPLE_W),
      .BIN_PAR        (BIN_PAR),
      .GROUPS         (GROUPS),
      .TIMEOUT_CYCLES (TIMEOUT_CYCLES),
      .STREAM_ID_W    (STREAM_ID_W),
      .SEQ_W          (SEQ_W),
      .USER_W         (USER_W),
      .OUT_DEPTH      (OUT_DEPTH),
      .TELEM_W        (TELEM_W)
  ) u_collect (
      .clk                (clk),
      .rst_n              (rst_n),
      .cfg_enable         (cfg_enable),
      .cfg_partial_pass   (cfg_partial_pass),
      .cfg_counter_clear  (cfg_counter_clear),
      .cfg_sticky_clear   (cfg_sticky_clear),
      .cfg_lane_stall     (cfg_lane_stall),
      .alloc_valid        (alloc_valid),
      .alloc_ready        (alloc_ready),
      .alloc_gid          (gidx_q[GID_W-1:0]),
      .alloc_gidx         (alloc_gidx),
      .alloc_foff         (foff_next[FOFF_W-1:0]),
      .alloc_sof          (gidx_q == '0),
      .alloc_eof          (gidx_q == GIDX_W'(GPF - 1)),
      .lane_valid         (lane_valid),
      .lane_ready         (lane_ready),
      .lane_data          (lane_data),
      .m_valid            (m_valid),
      .m_ready            (m_ready),
      .m_payload          (m_payload),
      .stat_beat_count    (stat_beat_count),
      .stat_missing_count (stat_missing_count),
      .stat_dup_count     (stat_dup_count),
      .stat_orphan_count  (stat_orphan_count),
      .stat_timeout_count (stat_timeout_count),
      .stat_fault         (stat_fault),
      .stat_open_groups   (open_groups_unused)
  );

  // ===========================================================================
  // Block-level telemetry
  // ===========================================================================
  // A stall is a cycle in which the block WANTED to issue a group and could
  // not. A cycle in which it is deliberately idle — `cfg_run` low at a frame
  // boundary — is not a stall, and counting it as one would make the throughput
  // figure a function of how long the test left the tap closed.
  wire stall_event = en_issue && run_gate && !issue;

  // Lane delivery census. `lane_fire` is the set of lanes that handed a word to
  // the reassembly buffer this cycle; more than one at a time is the network
  // doing the thing it exists for.
  wire [BIN_PAR-1:0] lane_fire = lane_valid & lane_ready;

  localparam int unsigned LN_W = $clog2(BIN_PAR + 1);
  logic [LN_W-1:0] lane_fire_n;
  always_comb begin
    lane_fire_n = '0;
    for (int unsigned l = 0; l < BIN_PAR; l++) begin
      if (lane_fire[l]) lane_fire_n = lane_fire_n + LN_W'(1);
    end
  end

  logic [BIN_PAR-1:0] lane_seen_q;
  always_ff @(posedge clk) begin
    if (!rst_n || cfg_sticky_clear) begin
      lane_seen_q <= '0;
    end else begin
      lane_seen_q <= lane_seen_q | lane_fire;
    end
  end
  assign stat_lane_seen = lane_seen_q;

  wire [TELEM_W-1:0] c_issue, c_stall, c_conf, c_multi, c_lword, c_inj;
  wire i_snapv_unused, i_wrapp_unused, i_wrapd_unused;
  wire s_snapv_unused, s_wrapp_unused, s_wrapd_unused;
  wire k_snapv_unused, k_wrapp_unused, k_wrapd_unused;
  wire x_snapv_unused, x_wrapp_unused, x_wrapd_unused;
  wire w_snapv_unused, w_wrapp_unused, w_wrapd_unused;
  wire j_snapv_unused, j_wrapp_unused, j_wrapd_unused;
  wire [TELEM_W-1:0] i_snap_unused, s_snap_unused, k_snap_unused,
                     x_snap_unused, w_snap_unused, j_snap_unused;

  perf_counter #(.WIDTH(TELEM_W), .INCR_W(1), .SATURATE(1'b1)) u_cnt_issue (
      .clk (clk), .rst_n (rst_n), .enable (1'b1),
      .event_i (issue), .incr (1'b1),
      .clear (cfg_counter_clear), .snapshot (1'b0),
      .count (c_issue), .snap (i_snap_unused), .snap_valid (i_snapv_unused),
      .wrap_pulse (i_wrapp_unused), .wrapped (i_wrapd_unused)
  );

  perf_counter #(.WIDTH(TELEM_W), .INCR_W(1), .SATURATE(1'b1)) u_cnt_stall (
      .clk (clk), .rst_n (rst_n), .enable (1'b1),
      .event_i (stall_event), .incr (1'b1),
      .clear (cfg_counter_clear), .snapshot (1'b0),
      .count (c_stall), .snap (s_snap_unused), .snap_valid (s_snapv_unused),
      .wrap_pulse (s_wrapp_unused), .wrapped (s_wrapd_unused)
  );

  perf_counter #(.WIDTH(TELEM_W), .INCR_W(1), .SATURATE(1'b1)) u_cnt_conflict (
      .clk (clk), .rst_n (rst_n), .enable (1'b1),
      .event_i (conflict_event), .incr (1'b1),
      .clear (cfg_counter_clear), .snapshot (1'b0),
      .count (c_conf), .snap (k_snap_unused), .snap_valid (k_snapv_unused),
      .wrap_pulse (k_wrapp_unused), .wrapped (k_wrapd_unused)
  );

  perf_counter #(.WIDTH(TELEM_W), .INCR_W(1), .SATURATE(1'b1)) u_cnt_multi (
      .clk (clk), .rst_n (rst_n), .enable (1'b1),
      .event_i (lane_fire_n > LN_W'(1)), .incr (1'b1),
      .clear (cfg_counter_clear), .snapshot (1'b0),
      .count (c_multi), .snap (x_snap_unused), .snap_valid (x_snapv_unused),
      .wrap_pulse (x_wrapp_unused), .wrapped (x_wrapd_unused)
  );

  perf_counter #(.WIDTH(TELEM_W), .INCR_W(LN_W), .SATURATE(1'b1)) u_cnt_lword (
      .clk (clk), .rst_n (rst_n), .enable (1'b1),
      .event_i (lane_fire_n != '0), .incr (lane_fire_n),
      .clear (cfg_counter_clear), .snapshot (1'b0),
      .count (c_lword), .snap (w_snap_unused), .snap_valid (w_snapv_unused),
      .wrap_pulse (w_wrapp_unused), .wrapped (w_wrapd_unused)
  );

  perf_counter #(.WIDTH(TELEM_W), .INCR_W(1), .SATURATE(1'b1)) u_cnt_inject (
      .clk (clk), .rst_n (rst_n), .enable (1'b1),
      .event_i (issue && inject), .incr (1'b1),
      .clear (cfg_counter_clear), .snapshot (1'b0),
      .count (c_inj), .snap (j_snap_unused), .snap_valid (j_snapv_unused),
      .wrap_pulse (j_wrapp_unused), .wrapped (j_wrapd_unused)
  );

  assign stat_issue_count       = c_issue;
  assign stat_issue_stall_count = c_stall;
  assign stat_conflict_count    = c_conf;
  assign stat_multi_lane_count  = c_multi;
  assign stat_lane_word_count   = c_lword;
  assign stat_inject_count      = c_inj;

  assign obs_net_sel       = 8'(NET_SEL);
  assign obs_net_latency   = net_latency;
  assign obs_block_latency =
      8'(algn_block_latency(algn_uint_t'(NET_SEL), algn_uint_t'(BIN_PAR),
                            algn_uint_t'(MUX_STAGES)));
  assign obs_bin_par       = 8'(BIN_PAR);
  assign obs_groups        = 8'(GROUPS);

`ifndef SYNTHESIS
  // SPEC 14. The output interface, checked as a SPEC 5 stream in its own right.
  stream_protocol_checker #(
      .PAYLOAD_W   (M_PAYLOAD_W),
      .DATA_W      (int'(algn_out_data_w(GEOM))),
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

  align_assertions #(
      .BIN_PAR    (BIN_PAR),
      .LANE_W     (LANE_W),
      .NET_DATA_W (NET_DATA_W),
      .BIN_W      (BIN_W),
      .VEC_W      (VEC_W)
  ) u_assertions (
      .clk        (clk),
      .rst_n      (rst_n),
      .enable     (en_tel),
      .in_valid   (ing_valid_q),
      .in_ready   (sw_in_ready),
      .in_dst     (sw_in_dst),
      .lane_valid (lane_valid),
      .lane_ready (lane_ready),
      .lane_data  (lane_data)
  );
`endif

endmodule : align_net

`default_nettype wire
