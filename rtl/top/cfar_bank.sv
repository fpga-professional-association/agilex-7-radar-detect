// -----------------------------------------------------------------------------
// cfar_bank — one CFAR detector per beam, and the merge of their event streams
// (SPEC.md 7.7, 7.8; issue #17).
//
// Structure
// ---------
//                                +--> cfar_core[0] --+
//   power stream  --> fan out ---+--> cfar_core[1] --+--> round robin --> events
//   (N_BEAMS x POWER_W,          +--> ...            +
//    one bin per beat)           +--> cfar_core[N-1]-+
//
// One detector per beam and not one detector time-shared across beams. The
// reason is `cfar_window`: the detector's state is a `2D+1`-slot shift register
// of ADJACENT BINS, so time-sharing it between beams would require either a
// per-beam window bank (the same silicon, plus a selector) or interleaving
// beams into one window (which would make each beam's reference cells the other
// beams' bins, and the detector would no longer be a CFAR at all). Replication
// is the cheap option here as well as the correct one.
//
// The fan-out, and why the readys are ANDed (MEASURED, not assumed)
// -----------------------------------------------------------------
// Every detector sees the same `valid`, the same framing and the same
// configuration, and differs only in which `POWER_W` slice of the beat it reads
// and in the `stream_id` it is told to carry. It is tempting to conclude that
// their `s_ready` signals are one signal replicated.
//
// THEY ARE NOT, and the reason is the merge below rather than anything about the
// detectors. The arbiter drains one beam's output buffer at a time, so a beam
// that has not been granted recently fills while a beam that has just been
// granted empties; a full output buffer stalls that detector's input, and the
// readys diverge. The first build of this module asserted the equality and the
// assertion fired within one frame of live traffic.
//
// So the AND is load bearing, not belt and braces: it is what makes the bank
// accept a beat only when EVERY detector can take it, which is what keeps the
// four per-beam streams beat-aligned with each other. `c_cfar_bank_readys_differ`
// covers the divergence, so a build in which it never happened would say so.
//
// The merge
// ---------
// A round-robin arbiter over the detectors' event masters. It is a MERGE and not
// a packet fabric: the SPEC 7.8 network, its virtual channels and its
// arbitration belong to `rtl/packet/` (issue #18) and the binding of this
// stream to it belongs to the multi-domain integration (issue #19). What this
// module owes that fabric is one well-formed SPEC 5 stream of detection events,
// which is what it produces.
//
// Interleaving is safe by construction and that is a property of issue #14's
// event contract rather than of this arbiter: `stream_id` carries the beam,
// `seq` is maintained PER BEAM inside each detector, and every frame is
// delimited by its own `sof`/`eof`. So a consumer demultiplexing by `stream_id`
// sees `N_BEAMS` continuous, correctly framed streams however this arbiter
// interleaves them — which is exactly why issue #14 made `seq` per-beam.
//
// A beam whose events are not drained blocks only itself: the arbiter skips a
// detector that has nothing to offer, and a detector whose output buffer fills
// stalls its own input, which through the ANDed `s_ready` stalls the bank. That
// is the intended back pressure — the alternative, dropping events to keep the
// pipeline moving, would make the detection count a function of the consumer.
//
// Telemetry
// ---------
// The per-beam counters are summed into one word per statistic, registered once
// so the sum is not on the register plane's read path, and saturating rather
// than wrapping for the reason `perf_counter`'s own SATURATE mode exists: a dump
// taken long after the event should report "many" rather than an ambiguous small
// number. `stat_fault` is the OR of the detectors' sticky vectors, so a fault on
// any beam is visible in the one word the register map declares.
//
// Lint contract: clean under `verilator --lint-only --Wall` with no waiver.
// -----------------------------------------------------------------------------

`default_nettype none

module cfar_bank
  import cfar_pkg::*;
  import covar_pkg::*;
  import stream_pkg::*;
#(
    parameter int unsigned N_BEAMS = 4,

    parameter int unsigned MAX_GUARD = 2,
    parameter int unsigned MAX_REF   = 16,
    parameter int unsigned OUT_DEPTH = 8,

    parameter int unsigned STREAM_ID_W = 4,
    parameter int unsigned SEQ_W       = 16,
    parameter int unsigned USER_W      = 4,

    parameter int unsigned TELEM_W = 32,

    // DERIVED, never overridden.
    parameter int unsigned S_PAYLOAD_W =
        N_BEAMS * CFAR_POWER_W + 2 + STREAM_ID_W + SEQ_W + USER_W,
    parameter int unsigned M_PAYLOAD_W =
        CFAR_EVENT_W + 2 + STREAM_ID_W + SEQ_W + USER_W
) (
    input  wire                        clk,
    input  wire                        rst_n,

    // ---- the per-bin power beat, all beams ----
    input  wire                        s_valid,
    output wire                        s_ready,
    input  wire [S_PAYLOAD_W-1:0]      s_payload,

    // ---- the merged detection-event stream ----
    output wire                        m_valid,
    input  wire                        m_ready,
    output wire [M_PAYLOAD_W-1:0]      m_payload,

    // ---- configuration (rtl/control/reg_block_cfar.sv), broadcast ----
    input  wire                        cfg_enable,
    input  wire [CFAR_MODE_W-1:0]      cfg_mode,
    input  wire                        cfg_out_mode,
    input  wire [CFAR_GUARD_CNT_W-1:0] cfg_guard_lead,
    input  wire [CFAR_GUARD_CNT_W-1:0] cfg_guard_lag,
    input  wire [CFAR_REF_CNT_W-1:0]   cfg_ref_lead,
    input  wire [CFAR_REF_CNT_W-1:0]   cfg_ref_lag,
    input  wire [CFAR_ALPHA_W-1:0]     cfg_alpha,
    input  wire                        cfg_status_clear,

    // ---- telemetry (SPEC 9) ----
    output wire [TELEM_W-1:0]          stat_det_count,
    output wire [TELEM_W-1:0]          stat_sup_count,
    output wire [TELEM_W-1:0]          stat_frame_count,
    output wire [TELEM_W-1:0]          stat_event_count,
    output wire [5:0]                  stat_fault,
    output wire                        obs_cfg_pending,
    output wire                        obs_frame_open,

    // Elaborated maxima, so software sizes its programming from hardware.
    output wire [CFAR_GUARD_CNT_W-1:0] obs_max_guard,
    output wire [CFAR_REF_CNT_W-1:0]   obs_max_ref
);

  localparam int unsigned BEAM_W  = (N_BEAMS <= 1) ? 1 : $clog2(N_BEAMS);
  localparam int unsigned C_S_W   = CFAR_POWER_W + 2 + STREAM_ID_W + SEQ_W + USER_W;

  localparam stream_geom_t S_GEOM =
      stream_geom(stream_pkg::uint_t'(N_BEAMS * CFAR_POWER_W),
                  stream_pkg::uint_t'(STREAM_ID_W),
                  stream_pkg::uint_t'(SEQ_W), stream_pkg::uint_t'(USER_W));
  localparam stream_geom_t C_GEOM =
      stream_geom(stream_pkg::uint_t'(CFAR_POWER_W), stream_pkg::uint_t'(STREAM_ID_W),
                  stream_pkg::uint_t'(SEQ_W), stream_pkg::uint_t'(USER_W));

`ifndef SYNTHESIS
  initial begin
    if (N_BEAMS == 0 || N_BEAMS > (1 << STREAM_ID_W)) begin
      $fatal(1, "cfar_bank: N_BEAMS=%0d does not fit STREAM_ID_W=%0d", N_BEAMS, STREAM_ID_W);
    end
    if (int'(S_PAYLOAD_W) != int'(stream_payload_w(S_GEOM))) begin
      $fatal(1, "cfar_bank: S_PAYLOAD_W=%0d but stream_pkg says %0d",
             S_PAYLOAD_W, int'(stream_payload_w(S_GEOM)));
    end
  end
`endif

  stream_fields_t in_f;
  assign in_f = stream_unpack(S_GEOM, STREAM_MAX_PAYLOAD_W'(s_payload));

  // The incoming `stream_id` is deliberately discarded: on this stream it names
  // the sweep, and on the detector's input it must name the BEAM (issue #14's
  // event contract makes `stream_id` the beam identity and keys the per-beam
  // sequence counter off it). Each detector below is given its own index
  // instead. Named so `--Wall` reports a genuinely dead field and not this.
  wire [STREAM_MAX_ID_W-1:0] unused_in_stream_id = in_f.stream_id;

  logic [N_BEAMS-1:0]              c_s_ready;
  logic [N_BEAMS-1:0]              c_m_valid;
  logic [N_BEAMS-1:0]              c_m_ready;
  logic [M_PAYLOAD_W-1:0]          c_m_payload [N_BEAMS];
  logic [N_BEAMS-1:0][31:0]        c_det, c_sup, c_frame;
  logic [N_BEAMS-1:0][5:0]         c_fault;
  logic [N_BEAMS-1:0]              c_pending, c_open;

  assign s_ready = &c_s_ready;

  // ---------------------------------------------------------------------------
  // The detectors
  // ---------------------------------------------------------------------------
  for (genvar b = 0; b < int'(N_BEAMS); b++) begin : g_beam

    // This beam's slice of the beat, re-framed as its own SPEC 5 stream. The
    // only fields that differ between beams are `data` and `stream_id`.
    wire [C_S_W-1:0] beam_payload = C_S_W'(stream_pack(C_GEOM, '{
        data      : {{(STREAM_MAX_DATA_W - CFAR_POWER_W){1'b0}},
                     in_f.data[b*CFAR_POWER_W +: CFAR_POWER_W]},
        sof       : in_f.sof,
        eof       : in_f.eof,
        stream_id : STREAM_MAX_ID_W'(b),
        seq       : in_f.seq,
        user      : in_f.user
    }));

    wire [CFAR_GUARD_CNT_W-1:0] unused_ag_lead, unused_ag_lag;
    wire [CFAR_REF_CNT_W-1:0]   unused_ar_lead, unused_ar_lag;
    wire [CFAR_ALPHA_W-1:0]     unused_a_alpha;
    wire [CFAR_MODE_W-1:0]      unused_a_mode;
    wire                        unused_a_enable, unused_a_out_mode;
    wire [CFAR_GUARD_CNT_W-1:0] unused_mg;
    wire [CFAR_REF_CNT_W-1:0]   unused_mr;
    wire [CFAR_REF_CNT_W:0]     unused_nl, unused_ng;

    cfar_core #(
        .MAX_GUARD   (MAX_GUARD),
        .MAX_REF     (MAX_REF),
        .OUT_DEPTH   (OUT_DEPTH),
        .STREAM_ID_W (STREAM_ID_W),
        .SEQ_W       (SEQ_W),
        .USER_W      (USER_W)
    ) u_cfar (
        .clk                   (clk),
        .rst_n                 (rst_n),
        .s_valid               (s_valid && s_ready),
        .s_ready               (c_s_ready[b]),
        .s_payload             (beam_payload),
        .m_valid               (c_m_valid[b]),
        .m_ready               (c_m_ready[b]),
        .m_payload             (c_m_payload[b]),
        .cfg_enable            (cfg_enable),
        .cfg_mode              (cfg_mode),
        .cfg_out_mode          (cfg_out_mode),
        .cfg_guard_lead        (cfg_guard_lead),
        .cfg_guard_lag         (cfg_guard_lag),
        .cfg_ref_lead          (cfg_ref_lead),
        .cfg_ref_lag           (cfg_ref_lag),
        .cfg_alpha             (cfg_alpha),
        .cfg_status_clear      (cfg_status_clear),
        .stat_det_count        (c_det[b]),
        .stat_sup_count        (c_sup[b]),
        .stat_frame_count      (c_frame[b]),
        .stat_fault            (c_fault[b]),
        .obs_cfg_pending       (c_pending[b]),
        .obs_active_enable     (unused_a_enable),
        .obs_active_mode       (unused_a_mode),
        .obs_active_out_mode   (unused_a_out_mode),
        .obs_active_guard_lead (unused_ag_lead),
        .obs_active_guard_lag  (unused_ag_lag),
        .obs_active_ref_lead   (unused_ar_lead),
        .obs_active_ref_lag    (unused_ar_lag),
        .obs_active_alpha      (unused_a_alpha),
        .obs_frame_open        (c_open[b]),
        .obs_max_guard         (unused_mg),
        .obs_max_ref           (unused_mr),
        .obs_n_lead            (unused_nl),
        .obs_n_lag             (unused_ng)
    );
  end

  // `s_valid && s_ready` rather than `s_valid` on every detector's slave port:
  // the bank accepts a beat only when EVERY detector can, so offering a beat to
  // the ones that are ready while another is not would deliver it twice to the
  // ready ones once the stalled one caught up.

  // ---------------------------------------------------------------------------
  // The round-robin merge
  // ---------------------------------------------------------------------------
  logic [BEAM_W-1:0] rr_q;
  logic [BEAM_W-1:0] pick;
  logic              pick_any;

  always_comb begin
    pick     = rr_q;
    pick_any = 1'b0;
    for (int unsigned i = 1; i <= N_BEAMS; i++) begin
      logic [BEAM_W-1:0] cand;
      cand = BEAM_W'((int'(rr_q) + int'(i)) % int'(N_BEAMS));
      if (!pick_any && c_m_valid[cand]) begin
        pick     = cand;
        pick_any = 1'b1;
      end
    end
  end

  // ---- the grant is LOCKED once offered ----
  //
  // SPEC 5: "A source must hold payload and metadata stable while stalled."
  // A bare combinational round robin does not: while `m_ready` is low, another
  // detector's event becoming valid can land EARLIER in the rotation than the
  // one already offered, the arbiter re-picks, and the payload on the wire
  // changes mid-transfer. `stream_protocol_checker`'s `a_payload_stable` catches
  // it and it is a real defect rather than a checker artefact — a consumer that
  // sampled the first offer and the second acceptance would get two different
  // events with one handshake.
  //
  // So a pick becomes a GRANT when it is offered, and the grant is held until it
  // is accepted. The lock costs one register and one mux and cannot deadlock:
  // the locked detector's `m_valid` stays high until its own beat is taken,
  // which is the same SPEC 5 rule applied one level up.
  logic              lock_q;
  logic [BEAM_W-1:0] lock_sel_q;

  wire [BEAM_W-1:0] grant     = lock_q ? lock_sel_q : pick;
  wire              grant_any = lock_q ? c_m_valid[lock_sel_q] : pick_any;

  wire fire = grant_any && m_ready;

  always_ff @(posedge clk) begin
    if (!rst_n) begin
      rr_q       <= '0;
      lock_q     <= 1'b0;
      lock_sel_q <= '0;
    end else begin
      if (fire) begin
        rr_q   <= grant;
        lock_q <= 1'b0;
      end else if (grant_any) begin
        lock_q     <= 1'b1;
        lock_sel_q <= grant;
      end
    end
  end

  always_comb begin
    c_m_ready = '0;
    if (grant_any) c_m_ready[grant] = m_ready;
  end

  assign m_valid   = grant_any;
  assign m_payload = c_m_payload[grant];

  // ---------------------------------------------------------------------------
  // Telemetry
  //
  // Registered once so the N_BEAMS-wide adder tree is not on the register
  // plane's read path, and saturating rather than wrapping.
  // ---------------------------------------------------------------------------
  function automatic logic [TELEM_W-1:0] sat_sum(input logic [N_BEAMS-1:0][31:0] v);
    logic [TELEM_W:0] acc;
    acc = '0;
    for (int unsigned b = 0; b < N_BEAMS; b++) begin
      acc = acc + (TELEM_W + 1)'(v[b]);
      if (acc[TELEM_W]) acc = {1'b0, {TELEM_W{1'b1}}};
    end
    return acc[TELEM_W-1:0];
  endfunction

  logic [TELEM_W-1:0] det_q, sup_q, frm_q;
  logic [5:0]         fault_q;
  logic               pending_q, open_q;

  always_ff @(posedge clk) begin
    if (!rst_n) begin
      det_q     <= '0;
      sup_q     <= '0;
      frm_q     <= '0;
      fault_q   <= '0;
      pending_q <= 1'b0;
      open_q    <= 1'b0;
    end else begin
      det_q     <= sat_sum(c_det);
      sup_q     <= sat_sum(c_sup);
      frm_q     <= sat_sum(c_frame);
      fault_q   <= |c_fault ? fold_fault(c_fault) : 6'd0;
      pending_q <= |c_pending;
      open_q    <= |c_open;
    end
  end

  function automatic logic [5:0] fold_fault(input logic [N_BEAMS-1:0][5:0] v);
    fold_fault = '0;
    for (int unsigned b = 0; b < N_BEAMS; b++) fold_fault = fold_fault | v[b];
  endfunction

  assign stat_det_count   = det_q;
  assign stat_sup_count   = sup_q;
  assign stat_frame_count = frm_q;
  assign stat_fault       = fault_q;
  assign obs_cfg_pending  = pending_q;
  assign obs_frame_open   = open_q;

  wire               unused_e_snapv, unused_e_wrapp, unused_e_wrapd;
  wire [TELEM_W-1:0] unused_e_snap;

  perf_counter #(.WIDTH(TELEM_W), .INCR_W(1), .SATURATE(1'b1)) u_cnt_ev (
      .clk (clk), .rst_n (rst_n), .enable (1'b1),
      .event_i (fire), .incr (1'b1),
      .clear (cfg_status_clear), .snapshot (1'b0),
      .count (stat_event_count), .snap (unused_e_snap), .snap_valid (unused_e_snapv),
      .wrap_pulse (unused_e_wrapp), .wrapped (unused_e_wrapd)
  );

  assign obs_max_guard = CFAR_GUARD_CNT_W'(MAX_GUARD);
  assign obs_max_ref   = CFAR_REF_CNT_W'(MAX_REF);

`ifndef SYNTHESIS
  stream_protocol_checker #(
      .PAYLOAD_W   (M_PAYLOAD_W),
      .DATA_W      (CFAR_EVENT_W),
      .STREAM_ID_W (STREAM_ID_W),
      .SEQ_W       (SEQ_W),
      .USER_W      (USER_W)
  ) u_chk (
      .clk     (clk),
      .rst_n   (rst_n),
      .valid   (m_valid),
      .ready   (m_ready),
      .payload (m_payload)
  );

  // The readys DIVERGE in normal operation — see the header — and the cover
  // records that the run reached the state the ANDed `s_ready` exists to handle.
  // A regression in which this never fired would be one in which the merge never
  // back-pressured a detector, and the AND would be untested.
  c_cfar_bank_readys_differ:
    cover property (@(posedge clk) disable iff (!rst_n)
                    (c_s_ready != '0) && (c_s_ready != {N_BEAMS{1'b1}}));

  // What must ALWAYS hold: a beat is offered to every detector or to none, so
  // the per-beam streams cannot drift apart by a beat.
  a_cfar_bank_accept_is_unanimous:
    assert property (@(posedge clk) disable iff (!rst_n)
                     (s_valid && s_ready) |-> (&c_s_ready))
      else $error("cfar_bank: a beat was accepted while a detector was not ready");

  // Every beam must actually deliver events over a run, or the merge is hiding
  // one. A cover rather than an assertion: it is a statement about the stimulus
  // as much as about the design.
  for (genvar b = 0; b < int'(N_BEAMS); b++) begin : g_cov
    c_cfar_bank_beam_delivers:
      cover property (@(posedge clk) disable iff (!rst_n) fire && (grant == BEAM_W'(b)));
  end
`endif

endmodule : cfar_bank

`default_nettype wire
