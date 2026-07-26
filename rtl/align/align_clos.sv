// -----------------------------------------------------------------------------
// align_clos — SPEC.md 7.4 architecture 2: the MULTISTAGE PIPELINED PERMUTATION
// NETWORK (issue #16).
//
// Same ports, same parameters, same protocol and (at the calibrated settings)
// the same latency as rtl/align/align_xbar.sv. Different topology: instead of
// N arbiters each reaching every input and N muxes each reaching every input,
// this is log2(N) stages of N/2 two-by-two switches, each switch registered and
// each switch arbitrating only between its own two inputs.
//
// -----------------------------------------------------------------------------
// 1. WHY AN OMEGA NETWORK AND NOT A LITERAL THREE-STAGE CLOS
// -----------------------------------------------------------------------------
// SPEC 7.4 says "multistage or Clos-style". A literal Clos C(n, m, r) with
// m >= 2n-1 is strictly non-blocking, and that is the property people reach for
// when they say Clos — but it is the wrong purchase HERE, and the reason is
// worth stating because "non-blocking" sounds unconditionally better.
//
// A strictly non-blocking Clos buys the guarantee that ANY new connection can be
// added without rearranging existing ones. That guarantee is about CIRCUITS held
// open across time. This network carries single-cycle PACKETS: every word is
// independently routed, nothing is held open, and there is no connection to
// rearrange. What blocking costs here is not a refused connection, it is one
// cycle of delay for one word — and the reassembly buffer downstream
// (rtl/align/align_collect.sv) exists precisely to absorb exactly that, because
// it must already absorb the far larger skew between independent history
// instances. Paying 2n-1 middle stages to remove a hazard the consumer is
// already immune to would be buying the same insurance twice.
//
// What is bought instead is the multistage property that actually matters
// against a crossbar, and it is a WIRING property: every connection in this
// network is between adjacent switch positions of consecutive stages, so a
// routed word never has to be presented across the full width of the block. A
// crossbar's mux, by contrast, must present all N sources at every one of the N
// destinations — N^2 * DATA_W bits of wire that all have to reach all of it. On
// a device where SPEC 7.4 asks specifically for CONGESTION to be recorded, that
// is the difference the measurement is looking for.
//
// The omega network is the minimal member of the multistage family with this
// property: log2(N) stages, N/2 switches per stage, self-routing on one address
// bit per stage with NO routing tables and NO global scheduler. It is blocking,
// the blocking rate is measured and reported through `conflict_event`, and
// DECISIONS.md carries the number rather than an assurance.
//
// -----------------------------------------------------------------------------
// 2. THE TOPOLOGY, STATED EXACTLY
// -----------------------------------------------------------------------------
// n = log2(N). Stages are numbered s = 0 .. n-1, and each stage is a PERFECT
// SHUFFLE followed by a column of N/2 two-by-two switches:
//
//     link q of stage s-1 feeds switch input position rotl(q) of stage s
//     equivalently, position j of stage s is fed by link rotr(j)
//     switch p = j >> 1 routes on address bit dst[n-1-s]          (MSB first)
//     the routed word leaves at link 2*p + dst[n-1-s] of stage s
//
// where rotl and rotr are one-place left and right rotations of the n-bit
// position index.
//
// The claim that this delivers input i to output dst, for EVERY (i, dst), is not
// taken on faith: the module walks the same wiring at elaboration over the whole
// N x N space (`route_ok`) and fails at time 0 if any pair does not arrive. A
// permutation network whose shuffle is off by one rotation is otherwise a block
// that passes every test in which the destination happens to equal the source —
// and at BIN_PAR = 2 that is every test there is.
//
// EVERY LINK IS A REGISTER. There are exactly n stages of registers, so the
// latency is n cycles — `align_pkg::algn_clos_latency(N)` — which at N = 8 is 3,
// which is `align_xbar`'s latency at MUX_STAGES = 2. The two architectures are
// therefore compared at matched pipeline depth, which is the only way the
// comparison means anything.
//
// -----------------------------------------------------------------------------
// 3. ARBITRATION IS LOCAL, AND THAT IS THE POINT
// -----------------------------------------------------------------------------
// A switch sees two inputs and two outputs. If its two inputs address different
// output links, both proceed; if they address the same one, a per-switch
// round-robin bit picks the winner and the loser holds. There is no arbiter
// wider than two, anywhere, at any N — against the crossbar's N arbiters of
// width N. The round-robin bit toggles only on a RESOLVED conflict, so a switch
// that never conflicts never changes its preference and the policy costs one
// flip-flop per switch.
//
// -----------------------------------------------------------------------------
// 4. THE READY CHAIN IS COMBINATIONAL ACROSS THE STAGES, DELIBERATELY
// -----------------------------------------------------------------------------
// A link register is free when it is empty or is being emptied this cycle, and
// "being emptied" is decided by the next stage, whose own freedom is decided by
// the stage after it. So `in_ready` is a combinational function of `out_ready`
// through n stages of two-input arbitration.
//
// That is a real timing path and it is a deliberate, measured choice rather than
// an oversight. The alternative — a two-deep elastic buffer on every link, which
// makes "free" a local occupancy comparison and cuts the chain — DOUBLES the
// storage of the entire network, which is the resource this architecture exists
// to economise. Spending it to remove a path of n two-input gates would give
// away the comparison's own subject.
//
// The path is short (n = 3 at the full-scale width, each hop a handful of LUTs)
// and the SPEC 18 calibration records the critical path's endpoints for every
// point, so whether this is the limiter is a measurement in the record and not a
// claim in a comment.
//
// -----------------------------------------------------------------------------
// 5. WHAT THIS BLOCK DOES NOT DO
// -----------------------------------------------------------------------------
// The same disclaimer align_xbar carries, and for the same reason: it does not
// look at the word it routes. Identity checking, duplicate detection and the
// missing-sample timeout all live in rtl/align/align_collect.sv, so the two
// architectures can be swapped without touching a line of the detection logic.
//
// Lint contract: clean under `verilator --lint-only --Wall` with no waiver.
// -----------------------------------------------------------------------------

`default_nettype none

module align_clos #(
    // Network width. Power of two, at least 2 — an omega network has no meaning
    // at a non-power-of-two width, which is the reason align_pkg constrains
    // BIN_PAR to a power of two rather than merely preferring one.
    parameter int unsigned N = 4,

    // Width of the routed word. Opaque to this module.
    parameter int unsigned DATA_W = 32,

    // Accepted and ignored, so that this module is parameter-compatible with
    // align_xbar and rtl/align/align_switch.sv can instantiate either from one
    // parameter list. An omega network's stage count is log2(N) and is not a
    // knob; align_switch checks that the two latencies match at elaboration
    // rather than letting a caller assume they do.
    parameter int unsigned MUX_STAGES = 2,

    // DERIVED; never overridden. A port width must be a parameter expression.
    parameter int unsigned DST_W = (N <= 1) ? 1 : $clog2(N)
) (
    input  wire                  clk,
    input  wire                  rst_n,

    input  wire [N-1:0]          in_valid,
    output wire [N-1:0]          in_ready,
    input  wire [N*DATA_W-1:0]   in_data,
    input  wire [N*DST_W-1:0]    in_dst,

    output wire [N-1:0]          out_valid,
    input  wire [N-1:0]          out_ready,
    output wire [N*DATA_W-1:0]   out_data,

    // One cycle high whenever any switch, in any stage, had both inputs asking
    // for the same output link. This is the internal blocking rate — the
    // quantity that distinguishes this architecture from the crossbar under load
    // — and align_net counts it through the same port for both, so the two
    // numbers are directly comparable.
    output wire                  conflict_event
);

  localparam int unsigned STAGES = (N <= 1) ? 1 : $clog2(N);
  localparam int unsigned NSW    = N / 2;

  // ---------------------------------------------------------------------------
  // The shuffle, and the elaboration-time proof that it routes
  // ---------------------------------------------------------------------------

  // One-place left rotation of an n-bit index: link q of one stage feeds switch
  // input position rotl(q) of the next.
  function automatic int unsigned rotl(input int unsigned q);
    return ((q << 1) | (q >> (STAGES - 1))) % N;
  endfunction

  // Its inverse: switch input position j is fed by link rotr(j).
  function automatic int unsigned rotr(input int unsigned j);
    return ((j >> 1) | (j << (STAGES - 1))) % N;
  endfunction

  // Where a word entering at input `src` addressed to `dst` actually arrives,
  // computed by walking the same wiring the RTL builds.
  function automatic int unsigned route_end(input int unsigned src,
                                            input int unsigned dst);
    int unsigned pos;
    int unsigned rb;
    pos = src;
    for (int unsigned s = 0; s < STAGES; s++) begin
      pos = rotl(pos);                            // onto this stage's positions
      rb  = (dst >> (STAGES - 1 - s)) & 32'd1;    // this stage's address bit
      pos = (pos & ~32'd1) | rb;                  // 2*(pos>>1) + rb
    end
    return pos;
  endfunction

  function automatic logic route_ok();
    for (int unsigned i = 0; i < N; i++) begin
      for (int unsigned d = 0; d < N; d++) begin
        if (route_end(i, d) != d) return 1'b0;
      end
    end
    return 1'b1;
  endfunction

`ifndef SYNTHESIS
  initial begin
    if (N < 2 || ((N & (N - 1)) != 0)) begin
      $fatal(1, "align_clos: N=%0d must be a power of two and at least 2", N);
    end
    if (DATA_W < 1) begin
      $fatal(1, "align_clos: DATA_W=%0d must be at least 1", DATA_W);
    end
    if (MUX_STAGES < 1) begin
      $fatal(1, "align_clos: MUX_STAGES=%0d must be at least 1", MUX_STAGES);
    end
    if (DST_W != ((N <= 1) ? 1 : $clog2(N))) begin
      $fatal(1, "align_clos: DST_W is derived and must not be overridden");
    end
    if (!route_ok()) begin
      $fatal(1, "align_clos: the omega wiring does not deliver every (src,dst) pair at N=%0d", N);
    end
  end
`endif

  // ---------------------------------------------------------------------------
  // Inter-stage nets
  //
  // The DATA path is a module-scope array: it flows strictly forward, so it has
  // no dependency cycle for anything to trip over.
  //
  // THE CONTROL PATH IS NOT, AND THAT IS DELIBERATE. `free` flows backward and
  // `accept` flows forward, so as a per-ELEMENT graph the control is acyclic —
  // stage s's readiness depends on stage s+1's and nothing depends on its own
  // stage. As a per-ARRAY graph it looks circular, because `lnk_take[*]` would
  // depend on `pos_acc[*]` which depends on `lnk_free[*]` which depends on
  // `lnk_take[*]`, and Verilator's UNOPTFLAT analysis works on whole signals
  // rather than on elements. It reports the loop, correctly by its own rules,
  // and there is no waiver for it that would not also hide a real one.
  //
  // The fix is structural rather than a lint exemption: each stage owns its own
  // control vectors as separate signals, and a stage reads its neighbour's by
  // generate-block reference. Verilator then sees
  //
  //     g_stage[s].acc <- g_stage[s].free <- g_stage[s].take <- g_stage[s+1].acc
  //
  // which is a chain of distinct objects, terminating at the last stage on
  // `out_ready`. Nothing is hidden and nothing is waived; the dependency is
  // simply expressed at the granularity it actually has.
  // ---------------------------------------------------------------------------
  wire [DATA_W-1:0] lnk_data [STAGES][N];
  wire [DST_W-1:0]  lnk_dst  [STAGES][N];

  wire [STAGES-1:0] stage_conflict;

  assign conflict_event = |stage_conflict;

  // ---------------------------------------------------------------------------
  // The stages
  // ---------------------------------------------------------------------------
  for (genvar s = 0; s < int'(STAGES); s++) begin : g_stage

    // This stage's address bit, MSB first.
    localparam int unsigned RBIT = STAGES - 1 - s;

    // This stage's control vectors, as packed per-stage signals. See the note
    // above for why they are not one module-scope array.
    wire [N-1:0] lnk_v;     // link register occupied
    wire [N-1:0] lnk_take;  // link being emptied this cycle
    wire [N-1:0] lnk_free;  // link may be loaded this cycle
    wire [N-1:0] pos_acc;   // switch input position accepted this cycle

    // Switch input positions, after the shuffle.
    wire              src_valid [N];
    wire [DATA_W-1:0] src_data  [N];
    wire [DST_W-1:0]  src_dst   [N];

    for (genvar j = 0; j < int'(N); j++) begin : g_src
      localparam int unsigned Q = rotr(j);
      if (s == 0) begin : g_src_in
        assign src_valid[j] = in_valid[Q];
        assign src_data[j]  = in_data[Q*DATA_W +: DATA_W];
        assign src_dst[j]   = in_dst[Q*DST_W +: DST_W];
      end else begin : g_src_prev
        assign src_valid[j] = g_stage[s-1].lnk_v[Q];
        assign src_data[j]  = lnk_data[s-1][Q];
        assign src_dst[j]   = lnk_dst[s-1][Q];
      end
    end : g_src

    // "take" flows BACKWARD: link q is emptied when the switch input position it
    // feeds in the next stage accepts it. The last stage is emptied by the
    // module's master interface, which is where the chain terminates.
    for (genvar q = 0; q < int'(N); q++) begin : g_flow
      if (s == int'(STAGES) - 1) begin : g_last
        assign lnk_take[q] = lnk_v[q] && out_ready[q];
      end else begin : g_mid
        assign lnk_take[q] = g_stage[s+1].pos_acc[rotl(q)];
      end
      assign lnk_free[q] = !lnk_v[q] || lnk_take[q];
    end : g_flow

    wire [NSW-1:0] sw_conflict;
    assign stage_conflict[s] = |sw_conflict;

    for (genvar p = 0; p < int'(NSW); p++) begin : g_switch
      localparam int unsigned J0 = 2 * p;
      localparam int unsigned J1 = 2 * p + 1;

      // Routing bits: which of the switch's two output links each input wants.
      wire rb0 = src_dst[J0][RBIT];
      wire rb1 = src_dst[J1][RBIT];

      wire conflict = src_valid[J0] && src_valid[J1] && (rb0 == rb1);
      assign sw_conflict[p] = conflict;

      // Round-robin between this switch's own two inputs.
      logic rr;

      wire gnt0 = src_valid[J0] && (!conflict || (rr == 1'b0));
      wire gnt1 = src_valid[J1] && (!conflict || (rr == 1'b1));

      wire acc0 = gnt0 && (rb0 ? lnk_free[J1] : lnk_free[J0]);
      wire acc1 = gnt1 && (rb1 ? lnk_free[J1] : lnk_free[J0]);

      assign pos_acc[J0] = acc0;
      assign pos_acc[J1] = acc1;

      always_ff @(posedge clk) begin
        if (!rst_n) begin
          rr <= 1'b0;
        end else if (conflict && (acc0 || acc1)) begin
          rr <= ~rr;
        end
      end

      // ---- the two output links of this switch ----
      // At most one input can be accepted onto a given link: when both address
      // the same one, only one of gnt0/gnt1 is set.
      wire ld0 = (acc0 && !rb0) || (acc1 && !rb1);
      wire ld1 = (acc0 &&  rb0) || (acc1 &&  rb1);

      wire [DATA_W-1:0] dat0 = (acc0 && !rb0) ? src_data[J0] : src_data[J1];
      wire [DST_W-1:0]  dsx0 = (acc0 && !rb0) ? src_dst[J0]  : src_dst[J1];
      wire [DATA_W-1:0] dat1 = (acc0 &&  rb0) ? src_data[J0] : src_data[J1];
      wire [DST_W-1:0]  dsx1 = (acc0 &&  rb0) ? src_dst[J0]  : src_dst[J1];

      logic              v0_q, v1_q;
      logic [DATA_W-1:0] d0_q, d1_q;
      logic [DST_W-1:0]  s0_q, s1_q;

      always_ff @(posedge clk) begin
        if (!rst_n) begin
          v0_q <= 1'b0;
          v1_q <= 1'b0;
        end else begin
          if (ld0)                 v0_q <= 1'b1;
          else if (lnk_take[J0])   v0_q <= 1'b0;
          if (ld1)                 v1_q <= 1'b1;
          else if (lnk_take[J1])   v1_q <= 1'b0;
        end
      end

      // Payload registers are not reset (SPEC 23): a wide synchronous clear
      // distorts both the ALM count and what the retimer can do, and the value
      // is meaningless while the link is invalid.
      always_ff @(posedge clk) begin
        if (ld0) begin
          d0_q <= dat0;
          s0_q <= dsx0;
        end
        if (ld1) begin
          d1_q <= dat1;
          s1_q <= dsx1;
        end
      end

      assign lnk_v[J0]       = v0_q;
      assign lnk_data[s][J0] = d0_q;
      assign lnk_dst[s][J0]  = s0_q;
      assign lnk_v[J1]       = v1_q;
      assign lnk_data[s][J1] = d1_q;
      assign lnk_dst[s][J1]  = s1_q;
    end : g_switch
  end : g_stage

  // ---------------------------------------------------------------------------
  // Module boundary
  // ---------------------------------------------------------------------------
  for (genvar i = 0; i < int'(N); i++) begin : g_bound
    // Input i behaves as "link i of stage -1" and therefore feeds switch input
    // position rotl(i) of stage 0.
    assign in_ready[i] = g_stage[0].pos_acc[rotl(i)];

    assign out_valid[i]                 = g_stage[STAGES-1].lnk_v[i];
    assign out_data[i*DATA_W +: DATA_W] = lnk_data[STAGES-1][i];

`ifndef SYNTHESIS
    // SPEC 14. The destination travels all the way to the last link, so the
    // network can check its own topology on every delivered word: a word
    // presented at output `i` must be a word that asked for `i`. This is the
    // runtime companion to the elaboration-time `route_ok()` proof — that one
    // shows the wiring is a permutation, this one shows no arbiter, no stall and
    // no reset interaction ever moved a word off its route. It is also what
    // READS the last stage's stored destination, which nothing else needs.
    always_ff @(posedge clk) begin
      if (rst_n && g_stage[STAGES-1].lnk_v[i]) begin
        a_clos_arrived_at_destination :
          assert (lnk_dst[STAGES-1][i] == DST_W'(i))
          else $error("align_clos: a word addressed to %0d was presented at output %0d",
                      lnk_dst[STAGES-1][i], i);
      end
    end
`endif
  end : g_bound

endmodule : align_clos

`default_nettype wire
