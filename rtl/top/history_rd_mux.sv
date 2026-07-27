// -----------------------------------------------------------------------------
// history_rd_mux — the alignment network's BIN_PAR request ports onto the
// history's ONE read port (SPEC.md 7.3, 7.4; issue #17).
//
// 1. Why this module exists (NORMATIVE — read before changing BIN_PAR)
// -------------------------------------------------------------------
// `align_net` (issue #16) declares `BIN_PAR` request masters and `BIN_PAR`
// response slaves, and ARCHITECTURE.md §3.4a describes them as "BIN_PAR
// independent history read ports", spending the read-bandwidth headroom §3.4
// recorded. `history_core` (issue #15) exposes exactly ONE read port. Something
// has to reconcile the two, and this is the module that does it.
//
// The obvious reading — instantiate `BIN_PAR` `history_core` instances — is
// wrong, and expensively so: each instance is a complete `N_ANT x LANES` bank
// array holding a complete copy of the history, so `BIN_PAR = 2` doubles the
// design's M20K count to store the same samples twice. The full-scale
// projection in DECISIONS.md (issue #15) is already the design's largest memory
// consumer.
//
// The less obvious reading — widen the history's read port to serve `BIN_PAR`
// bins per cycle from the headroom §3.4 measured — is ALSO wrong, and the reason
// is arithmetic rather than economic. §3.4's headroom is real but it is headroom
// on bins that fall on DISTINCT MEMORY LANES, and a group is `BIN_PAR`
// CONSECUTIVE bins:
//
//     lane(b) = b / M          M = FFT_SIZE / LANES        (history_pkg §3)
//
// so at the medium geometry (FFT_SIZE 256, LANES 2, M 128) bins 0 and 1 are both
// in lane 0, both in the same bank of every antenna, and a `history_bank` is a
// SIMPLE dual port with one read port. Two consecutive bins cannot be read in
// the same cycle by any amount of widening. The headroom exists for a consumer
// that asks for bins a lane apart; the alignment network, by the definition of a
// group, never does.
//
// What is left is the honest arrangement: one read port serving `BIN_PAR`
// requesters at **one bin per cycle**, which is exactly the rate ARCHITECTURE.md
// §3.4 states the port serves. The consequences are stated rather than hidden:
//
//   * the alignment network emits one beat every `BIN_PAR` cycles rather than
//     one per cycle, so its `stat_issue_stall_count` is nonzero by construction
//     and the number is a property of this module, not a defect in that one;
//   * the whole back end downstream of it runs at **one bin per cycle**, which
//     at `BIN_PAR = 2`, `BEAM_PAR = N_BEAMS` is exactly the rate the beamformer,
//     the power stage and the CFAR detectors sustain. The pipeline is rate
//     matched end to end at the medium configuration and nothing is throttled
//     by anything but the memory;
//   * the ingest side is unaffected. `history_core` never stalls its writes
//     (SPEC 7.3 requires continuous writes and it obeys), so a slower read side
//     reads fewer frames of a history that keeps filling. That decoupling is
//     precisely what a corner-turn memory is FOR, and it is why the read rate
//     being below the write rate is an architecture rather than a bottleneck.
//
// 2. The all-or-nothing issue, and why per-port queues are required
// -----------------------------------------------------------------
// `align_net` issues all `BIN_PAR` requests of a group in ONE cycle or none of
// them — its `ports_free` term is `&rd_req_ready`. A bare round-robin
// multiplexer, which can grant one port per cycle, would therefore never present
// all `BIN_PAR` readys at once and the network would deadlock at time zero.
//
// So every port gets its own small request queue. `s_req_ready[p]` is "this
// port's queue has room", the queues fill in one cycle, and the arbiter drains
// them to the history one per cycle afterwards. `REQ_DEPTH = 2` lets the
// network issue the NEXT group while the previous one is still draining, which
// is what keeps the history's request port busy every cycle rather than
// `BIN_PAR-1` cycles in `BIN_PAR`.
//
// 3. Responses: order, and the one assumption this module makes
// -------------------------------------------------------------
// ARCHITECTURE.md §3.4: *"Ordering is request order, always: the read path is a
// fixed-latency pipeline with an elastic output, so there is no reordering
// mechanism to go wrong and no tag to match."* This module relies on exactly
// that one sentence and on nothing else: it pushes the granted port index into
// a FIFO on every forwarded request and pops it on every returned response.
//
// It is worth being explicit that this is the tag-FIFO construction issue #16
// deliberately REJECTED for its own routing key, and that the rejection does not
// apply here. #16's objection is that a tag FIFO mislabels every response after
// the first lost one — but that failure mode is what `align_collect` detects,
// from each response's OWN identity, one level up. A response mis-delivered by
// this module arrives at a lane whose bin index disagrees with the beat position
// it was routed to, and `a_align_route_correct` fires. The detector is upstream-
// agnostic by construction (§3.4a), so it covers this module too.
//
// A response is offered to its owning port and to no other, and the history's
// `m_ready` is that port's `rsp_ready`. Head-of-line blocking is therefore
// possible and is correct: `align_collect`'s lane ports are ready whenever the
// block is enabled (§3.4a, "the lane ports into the reassembly buffer are always
// ready"), so a port that stalls is a port whose entry is already open and which
// will accept.
//
// 4. What bounds the outstanding set
// ----------------------------------
// A request is forwarded only when the identity FIFO has room, so the number of
// responses in flight can never exceed `ID_DEPTH`. `history_core`'s own read
// path is credit-limited to eight in flight, so `ID_DEPTH = 16` is twice the
// bound rather than a guess; the elaboration check below refuses a depth that
// could not cover it.
//
// Lint contract: clean under `verilator --lint-only --Wall` with no waiver.
// -----------------------------------------------------------------------------

`default_nettype none

module history_rd_mux
  import history_pkg::*;
#(
    // Requester count. Equal to align_net's BIN_PAR.
    parameter int unsigned N_PORTS = 2,

    // Entries in each port's request queue. 2 is the smallest depth that lets a
    // group be accepted while the previous one drains; 1 would serialise the
    // groups and cost `BIN_PAR` cycles of dead time per group.
    parameter int unsigned REQ_DEPTH = 2,

    // Entries in the response-identity FIFO. See header §4.
    parameter int unsigned ID_DEPTH = 16,

    // Response payload width. Must equal history_core's RD_PAYLOAD_W.
    parameter int unsigned RSP_PAYLOAD_W = 32,

    parameter int unsigned TELEM_W = 32
) (
    input  wire                              clk,
    input  wire                              rst_n,

    // ---- requester side: N_PORTS request slaves (from align_net) ----
    input  wire [N_PORTS-1:0]                s_req_valid,
    output wire [N_PORTS-1:0]                s_req_ready,
    input  wire [N_PORTS*HIST_PORT_W-1:0]    s_req_bin,
    input  wire [N_PORTS*HIST_PORT_W-1:0]    s_req_frame_off,

    // ---- requester side: N_PORTS response masters (to align_net) ----
    output wire [N_PORTS-1:0]                s_rsp_valid,
    input  wire [N_PORTS-1:0]                s_rsp_ready,
    output wire [N_PORTS*RSP_PAYLOAD_W-1:0]  s_rsp_payload,

    // ---- memory side: the one history_core read port ----
    output wire                              h_req_valid,
    input  wire                              h_req_ready,
    output wire [HIST_PORT_W-1:0]            h_req_bin,
    output wire [HIST_PORT_W-1:0]            h_req_frame_off,

    input  wire                              h_rsp_valid,
    output wire                              h_rsp_ready,
    input  wire [RSP_PAYLOAD_W-1:0]          h_rsp_payload,

    // ---- telemetry (SPEC 9) ----
    output wire [TELEM_W-1:0]                stat_grant_count,
    output wire [TELEM_W-1:0]                stat_req_stall_count,
    output wire [TELEM_W-1:0]                stat_rsp_stall_count
);

  localparam int unsigned PORT_W = (N_PORTS <= 1) ? 1 : $clog2(N_PORTS);
  localparam int unsigned REQ_W  = 2 * HIST_PORT_W;

`ifndef SYNTHESIS
  initial begin
    if (N_PORTS < 1) $fatal(1, "history_rd_mux: N_PORTS must be at least 1");
    if (REQ_DEPTH < 2) begin
      $fatal(1, "history_rd_mux: REQ_DEPTH=%0d is below the 2 the all-or-nothing issue needs",
             REQ_DEPTH);
    end
    // history_core's read path holds at most eight responses in flight; a FIFO
    // that could not cover them would bound the design below the memory's own
    // capability for no reason.
    if (ID_DEPTH < 8) begin
      $fatal(1, "history_rd_mux: ID_DEPTH=%0d cannot cover history_core's eight in-flight responses",
             ID_DEPTH);
    end
  end
`endif

  // ---------------------------------------------------------------------------
  // Per-port request queues
  // ---------------------------------------------------------------------------
  wire [N_PORTS-1:0]  q_valid;
  wire [REQ_W-1:0]    q_data [N_PORTS];
  logic [N_PORTS-1:0] q_pop;

  for (genvar p = 0; p < int'(N_PORTS); p++) begin : g_req_q
    wire [$clog2(REQ_DEPTH+1)-1:0] unused_occ, unused_hw;
    wire unused_full, unused_empty, unused_af, unused_ae;
    wire unused_ovf, unused_unf;

    sync_fifo #(
        .WIDTH      (REQ_W),
        .DEPTH      (REQ_DEPTH),
        .SHOW_AHEAD (1'b1),
        .STORAGE    ("regs")
    ) u_q (
        .clk              (clk),
        .rst_n            (rst_n),
        .s_valid          (s_req_valid[p]),
        .s_ready          (s_req_ready[p]),
        .s_data           ({s_req_frame_off[p*HIST_PORT_W +: HIST_PORT_W],
                            s_req_bin      [p*HIST_PORT_W +: HIST_PORT_W]}),
        .m_valid          (q_valid[p]),
        .m_ready          (q_pop[p]),
        .m_data           (q_data[p]),
        .occupancy        (unused_occ),
        .full             (unused_full),
        .empty            (unused_empty),
        .almost_full      (unused_af),
        .almost_empty     (unused_ae),
        .high_water       (unused_hw),
        .overflow_sticky  (unused_ovf),
        .underflow_sticky (unused_unf),
        .sticky_clear     (1'b0)
    );
  end

  // ---------------------------------------------------------------------------
  // Round-robin arbitration
  //
  // `rr_q` is the port served most recently; the grant goes to the first pending
  // port strictly after it, wrapping. A rotating priority rather than a fixed
  // one because a fixed one would starve the high-numbered ports whenever the
  // network ran below full rate, and the alignment network's own routing
  // schedule already rotates which lane a port carries — a second fixed
  // asymmetry on top of that would be invisible in the average and visible in
  // the tail.
  // ---------------------------------------------------------------------------
  logic [PORT_W-1:0] rr_q;

  wire id_room;

  logic [PORT_W-1:0] pick_idx;
  logic              pick_any;

  always_comb begin
    pick_idx = rr_q;
    pick_any = 1'b0;
    for (int unsigned i = 1; i <= N_PORTS; i++) begin
      logic [PORT_W-1:0] cand;
      cand = PORT_W'((int'(rr_q) + int'(i)) % int'(N_PORTS));
      if (!pick_any && q_valid[cand]) begin
        pick_idx = cand;
        pick_any = 1'b1;
      end
    end
  end

  // ---- the grant is LOCKED once offered ----
  //
  // The same stability rule SPEC 5 states for a stream applies to this request
  // port: `history_core` samples `rd_req_bin` on the cycle it asserts
  // `rd_req_ready`, and a request whose address changed between being offered
  // and being taken would read a bin nobody asked for. A bare combinational
  // round robin can do exactly that — while `h_req_ready` is low, another port's
  // queue becoming non-empty earlier in the rotation re-picks the grant.
  //
  // Locking also makes the identity FIFO's contract exact rather than nearly
  // exact: the port index pushed on the forwarded cycle is the port whose
  // address was on the wire, by construction and not by timing.
  logic              lock_q;
  logic [PORT_W-1:0] lock_idx_q;

  wire [PORT_W-1:0] grant_idx = lock_q ? lock_idx_q : pick_idx;
  wire              grant_any = lock_q ? q_valid[lock_idx_q] : pick_any;

  wire fwd = grant_any && h_req_ready && id_room;

  always_comb begin
    q_pop = '0;
    if (fwd) q_pop[grant_idx] = 1'b1;
  end

  always_ff @(posedge clk) begin
    if (!rst_n) begin
      rr_q       <= '0;
      lock_q     <= 1'b0;
      lock_idx_q <= '0;
    end else begin
      if (fwd) begin
        rr_q   <= grant_idx;
        lock_q <= 1'b0;
      end else if (grant_any) begin
        lock_q     <= 1'b1;
        lock_idx_q <= grant_idx;
      end
    end
  end

  assign h_req_valid     = grant_any && id_room;
  assign h_req_bin       = q_data[grant_idx][HIST_PORT_W-1:0];
  assign h_req_frame_off = q_data[grant_idx][2*HIST_PORT_W-1:HIST_PORT_W];

  // ---------------------------------------------------------------------------
  // Response identity FIFO and the response demultiplexer
  // ---------------------------------------------------------------------------
  wire [PORT_W-1:0] rsp_port;
  wire              id_valid;
  wire              id_ready;

  wire [$clog2(ID_DEPTH+1)-1:0] unused_id_occ, unused_id_hw;
  wire unused_id_empty, unused_id_af, unused_id_ae, unused_id_ovf, unused_id_unf;
  wire id_full;

  sync_fifo #(
      .WIDTH      (PORT_W),
      .DEPTH      (ID_DEPTH),
      .SHOW_AHEAD (1'b1),
      .STORAGE    ("regs")
  ) u_id (
      .clk              (clk),
      .rst_n            (rst_n),
      .s_valid          (fwd),
      .s_ready          (id_ready),
      .s_data           (grant_idx),
      .m_valid          (id_valid),
      .m_ready          (h_rsp_valid && h_rsp_ready),
      .m_data           (rsp_port),
      .occupancy        (unused_id_occ),
      .full             (id_full),
      .empty            (unused_id_empty),
      .almost_full      (unused_id_af),
      .almost_empty     (unused_id_ae),
      .high_water       (unused_id_hw),
      .overflow_sticky  (unused_id_ovf),
      .underflow_sticky (unused_id_unf),
      .sticky_clear     (1'b0)
  );

  // `id_room` is read before the grant is committed, so it must be the FIFO's
  // own accept condition and not a derived one.
  assign id_room = id_ready && !id_full;

  for (genvar p = 0; p < int'(N_PORTS); p++) begin : g_rsp
    assign s_rsp_valid[p] = h_rsp_valid && id_valid && (rsp_port == PORT_W'(p));
    // Every port sees the same payload; only one of them sees it with `valid`.
    // Broadcasting the bus rather than gating it keeps the response path free of
    // a `N_PORTS`-wide mux on the widest signal in the block.
    assign s_rsp_payload[p*RSP_PAYLOAD_W +: RSP_PAYLOAD_W] = h_rsp_payload;
  end

  assign h_rsp_ready = id_valid && s_rsp_ready[rsp_port];

  // ---------------------------------------------------------------------------
  // Telemetry (SPEC 9)
  // ---------------------------------------------------------------------------
  wire req_stall = grant_any && !fwd;
  wire rsp_stall = h_rsp_valid && !h_rsp_ready;

  wire               unused_g_snapv, unused_q_snapv, unused_r_snapv;
  wire               unused_g_wrapp, unused_q_wrapp, unused_r_wrapp;
  wire               unused_g_wrapd, unused_q_wrapd, unused_r_wrapd;
  wire [TELEM_W-1:0] unused_g_snap,  unused_q_snap,  unused_r_snap;

  perf_counter #(.WIDTH(TELEM_W), .INCR_W(1), .SATURATE(1'b1)) u_cnt_grant (
      .clk (clk), .rst_n (rst_n), .enable (1'b1),
      .event_i (fwd), .incr (1'b1), .clear (1'b0), .snapshot (1'b0),
      .count (stat_grant_count), .snap (unused_g_snap), .snap_valid (unused_g_snapv),
      .wrap_pulse (unused_g_wrapp), .wrapped (unused_g_wrapd)
  );

  perf_counter #(.WIDTH(TELEM_W), .INCR_W(1), .SATURATE(1'b1)) u_cnt_qstall (
      .clk (clk), .rst_n (rst_n), .enable (1'b1),
      .event_i (req_stall), .incr (1'b1), .clear (1'b0), .snapshot (1'b0),
      .count (stat_req_stall_count), .snap (unused_q_snap), .snap_valid (unused_q_snapv),
      .wrap_pulse (unused_q_wrapp), .wrapped (unused_q_wrapd)
  );

  perf_counter #(.WIDTH(TELEM_W), .INCR_W(1), .SATURATE(1'b1)) u_cnt_rstall (
      .clk (clk), .rst_n (rst_n), .enable (1'b1),
      .event_i (rsp_stall), .incr (1'b1), .clear (1'b0), .snapshot (1'b0),
      .count (stat_rsp_stall_count), .snap (unused_r_snap), .snap_valid (unused_r_snapv),
      .wrap_pulse (unused_r_wrapp), .wrapped (unused_r_wrapd)
  );

`ifndef SYNTHESIS
  // A response with no outstanding identity is a lost request or a memory that
  // answered twice; either way the routing key of everything after it is wrong.
  // SPEC 14: "Memory response without a request."
  a_hrm_response_has_identity:
    assert property (@(posedge clk) disable iff (!rst_n) h_rsp_valid |-> id_valid)
      else $error("history_rd_mux: response with no outstanding request identity");

  // The all-or-nothing issue of align_net depends on every port becoming ready
  // together once the queues drain. A port whose queue never empties would
  // deadlock the network, which is silent otherwise.
  c_hrm_all_ports_ready:
    cover property (@(posedge clk) disable iff (!rst_n) &s_req_ready);
`endif

endmodule : history_rd_mux

`default_nettype wire
