// -----------------------------------------------------------------------------
// cfar_core — one-dimensional CFAR detector over frequency bins (SPEC.md 7.7,
// issue #14).
//
// Consumes the integrated power stream of rtl/covariance/ — one non-negative
// COVAR_POWER_W value per frequency bin, in bin order, framed by
// start_of_frame / end_of_frame — and produces DETECTION EVENTS on a second
// SPEC 5 stream. Cell-averaging and greatest-of modes, programmable guard and
// reference counts on each side independently, a programmable threshold
// multiplier, edge suppression, and per-frame detection and suppression counts.
//
// The GEOMETRY of the reference window lives in rtl/cfar/cfar_window.sv and the
// FORMAT of everything — the threshold's fixed-point type, the event layout, the
// comparison itself — lives in rtl/packages/cfar_pkg.sv. What lives HERE is the
// framing, the flow control, the configuration timing and the arithmetic
// pipeline that turns a window into an event.
//
// -----------------------------------------------------------------------------
// 1. The decision, end to end
// -----------------------------------------------------------------------------
// For the cell under test C with reference sum S over N reference cells and
// threshold multiplier alpha (unsigned Q8.8, integer A = alpha * 2^F):
//
//     detect  <=>  C * N * 2^F  >  A * S                                 (*)
//
// No division, no rounding, no tolerance — cfar_pkg section 3 is the derivation
// and cfar_pkg::cfar_over_threshold() is the normative statement.
// sim/assertions/cfar_assertions.sv checks the sized datapath below against that
// function on every decision, so "the pipeline computes (*)" is a checked fact
// rather than a claim about this comment.
//
// The two modes differ only in which (S, N) pair enters (*):
//
//   CFAR_MODE_CA   S = S_lead + S_lag,  N = N_lead + N_lag
//   CFAR_MODE_GO   the side with the GREATER MEAN, i.e. (S_lead, N_lead) if
//                  S_lead * N_lag >= S_lag * N_lead, else (S_lag, N_lag)
//
// Greatest-of is one comparison, not two, because
//
//     C > alpha * max(S_lead/N_lead, S_lag/N_lag)
//
// is a single threshold test once the larger mean is identified — and
// identifying it is one cross-multiply of a SUM by a 6-bit COUNT, which is far
// cheaper than a second full threshold comparison. Selecting the side first also
// makes the emitted event self-consistent: the noise_sum and ref_count it
// carries are the ones the decision actually used, so a consumer that re-runs
// (*) on the event's own fields reproduces the detector's answer exactly. That
// property is what the packet network (issue #18) needs and it is why GO is
// implemented this way rather than as an AND of two comparisons.
//
// -----------------------------------------------------------------------------
// 2. Edge handling: SUPPRESS, and the accounting that makes it visible
// -----------------------------------------------------------------------------
// A bin whose complete window does not lie inside the frame raises no detection
// and is counted as suppressed. cfar_pkg section 4 is the argument against
// shrinking and against mirroring. The same rule covers every other incomplete
// or invalid case, with no special cases:
//
//   * the first and last (guard + reference) bins of every frame;
//   * every bin, while cfg_enable is low;
//   * every bin, when the selected mode has no usable reference count
//     (CA needs N_lead + N_lag >= 1; GO needs both sides >= 1);
//   * every bin of a frame shorter than the window.
//
// Each suppressed bin increments the frame's suppression count, which the
// end-of-frame summary event reports and the register plane accumulates. A
// detector that quietly declines to look at a third of the spectrum is a defect;
// one that says how many bins it declined to look at is a design.
//
// -----------------------------------------------------------------------------
// 3. Framing, and the D-advance tail flush
// -----------------------------------------------------------------------------
// A bin becomes the cell under test D = MAX_GUARD + MAX_REF advances after it is
// admitted, because that is when its leading reference cells have arrived
// (cfar_window section 1). The last D bins of a frame therefore still sit inside
// the window register file when end_of_frame is admitted, and they have to be
// pushed through: their windows may well be complete — only the last
// (guard + reference) of them are edge cases — and dropping them would suppress
// bins the policy says are fine.
//
// So every frame ends with D PHANTOM ADVANCES, which shift invalid entries in
// and let the tail reach the cell-under-test position, then a drain of the
// arithmetic pipeline, then exactly one SUMMARY event carrying end_of_frame.
// The cost is D + (pipeline depth) + 1 cycles per frame of dead input time; at
// the SPEC 11 tiny geometry (64 bins, D = 10) that is about a quarter of the
// frame period, and it is the largest single throughput claim this block makes.
// The alternative — overlapping the flush with the next frame's input — needs a
// second window bank and a per-slot frame tag so that two frames' cells can
// coexist in the register file without contaminating each other's noise
// estimate. It is a real optimisation and it is deliberately not taken here: a
// second bank doubles the widest register file in the block to buy back cycles
// on a stream whose frame rate is set by the FFT, and whether that trade is
// worth taking is a SPEC 18 measurement rather than an assumption.
//
// NO BEAT IS ACCEPTED BETWEEN THE end_of_frame BEAT AND THE SUMMARY. `s_ready`
// is a registered signal driven from the NEXT state, so it falls on the cycle
// after end_of_frame is admitted and does not rise again until the block is idle.
// That is not merely polite backpressure: it is what makes "a start_of_frame beat
// cannot arrive while a frame is open" a structural fact rather than an error
// case, so the block has no branch for interleaved frames and no way to
// half-abandon one. A source obeying SPEC 5 ("a source must hold payload and
// metadata stable while stalled") loses nothing.
//
// -----------------------------------------------------------------------------
// 4. Flow control: credits, exactly as pfb_bank argues them
// -----------------------------------------------------------------------------
// SPEC 5 forbids a combinational ready chain across module boundaries and SPEC
// 23 asks for elastic buffers at the seams. The interior here is a fixed-latency
// valid pipeline with no ready at all; backpressure is absorbed by an output
// elastic buffer, and `s_ready` is a flip-flop whose input depends only on this
// block's own credit counter.
//
// `cred_q` is the number of FREE SLOTS in that buffer: decremented on a push,
// incremented on a beat leaving. The rule is one line —
//
//     an ADVANCE is allowed only while cred_q >= (in-flight stages + 1)
//
// — and the argument for it is short. Let F be the number of decisions in flight
// that may still push; F is at most the number of pipeline stages, four. Every
// advance eventually produces at most one push, so allowing an advance only when
// cred_q >= F_max + 1 maintains cred_q >= F, and a decision that reaches the
// push point therefore always finds a free slot. `a_cfar_out_never_blocked`
// checks exactly that, every cycle.
//
// THE FIRST VERSION OF THIS RESERVED A SLOT PER ADMITTED BEAT and it deadlocked
// on the first frame. A beat's decision does not retire until D advances later,
// so the outstanding reservations grow to D + pipeline before the first one
// comes back; with an eight-deep buffer and D = 10 the block stopped accepting
// after six bins and never produced an end-of-frame summary to unblock itself.
// The lesson is worth the paragraph, because the arithmetic of the reservation
// scheme was correct IN TOTAL — every reservation was eventually returned — and
// what it got wrong was the LATENCY between taking one and returning it. Sizing
// against the pipeline instead of against the window makes the buffer depth
// independent of the window geometry, which matters: at the SPEC 11 full-scale
// size D is 36, and a buffer sized to cover it would be an M20K's worth of
// storage bought to solve an accounting problem.
//
// The end-of-frame FLUSH is stallable for the same reason. Its advances are
// driven by this block's own state machine rather than by an input beat, so they
// simply pause while cred_q is low; the summary event likewise waits for a free
// slot. A consumer that stops reading therefore stalls the detector rather than
// overflowing it, which is what SPEC 5 means by backpressure on every interface.
//
// -----------------------------------------------------------------------------
// 5. Configuration takes effect at a frame boundary, and only there
// -----------------------------------------------------------------------------
// Guard counts, reference counts, alpha, mode, output mode and enable are
// latched into an ACTIVE copy at the admitted start-of-frame beat, and at reset,
// and nowhere else. A frame is therefore processed under exactly one geometry —
// which is the only way a per-frame suppression count or a per-frame detection
// count means anything, and the only way an event's alpha field describes the
// comparison that produced it.
//
// This is deliberately stricter than the covariance engine's window-boundary
// rule (issue #13 decision 6) and for a stronger reason: the reference window
// spans 2D+1 bins, so a geometry change mid-frame would be evaluated against
// cells admitted under the OLD geometry for the following D bins. There is no
// instant at which the window is empty except a frame boundary, so a frame
// boundary is the only honest place to switch.
//
// `a_cfar_cfg_frame_boundary` asserts that the active copy changes only on a
// cycle in which a start-of-frame beat was admitted. `obs_cfg_pending` reports
// that a write is waiting, so software can see that its change has not taken
// effect rather than inferring it.
//
// A count above the elaborated maximum is CLAMPED to the maximum and raises
// CFAR_FAULT.CFG_CLAMPED. Out of range is defined rather than undefined, for the
// reason covar_engine gives for its source selector: a register plane can be
// programmed with anything, and "X" is not a behaviour.
//
// -----------------------------------------------------------------------------
// 6. Pipeline
// -----------------------------------------------------------------------------
//   advance     the window register file shifts                (cfar_window)
//   s1          the window's sums, counts, validity and cell under test
//   s2          the mode/greatest-of side selection -> (S, N)
//   s3          the two products of (*): C*N<<F and A*S
//   push        the comparison, the event, and the elastic buffer's own register
//
// Registers on both sides of the multipliers (SPEC 23), and nothing between a
// multiplier and its adder. The drain before the summary event waits for the
// pipeline to be EMPTY rather than for a constant number of cycles, so adding or
// removing a stage does not silently shorten it.
//
// Lint contract: clean under `verilator --lint-only --Wall` with no waiver.
// -----------------------------------------------------------------------------

`default_nettype none

module cfar_core
  import cfar_pkg::*;
  import stream_pkg::*;
#(
    // Elaborated window maxima. D = MAX_GUARD + MAX_REF sets the register-file
    // depth, the per-frame flush length and the number of bins suppressed at
    // each frame edge.
    parameter int unsigned MAX_GUARD = 2,
    parameter int unsigned MAX_REF   = 8,

    // Output elastic-buffer depth, in events. Must be at least 2: admitting the
    // start-of-frame beat reserves two slots at once (section 4).
    parameter int unsigned OUT_DEPTH = 8,

    // Stream geometry. Both interfaces share the metadata widths; only DATA_W
    // differs, because the input carries one power value and the output carries
    // one detection event.
    parameter int unsigned STREAM_ID_W = 8,
    parameter int unsigned SEQ_W       = 16,
    parameter int unsigned USER_W      = 4,

    parameter int unsigned IN_DATA_W  = CFAR_POWER_W,
    parameter int unsigned OUT_DATA_W = CFAR_EVENT_W,

    // Packed payload widths. The stream_pkg layout arithmetic is repeated here
    // once, and only here, because a port width cannot call a function of a
    // parameter declared in the same list on every tool; the elaboration check
    // below compares both against stream_payload_w(), so a divergence is a build
    // failure rather than a silently misaligned field.
    parameter int unsigned S_PAYLOAD_W =
        IN_DATA_W + 2 + STREAM_ID_W + SEQ_W + USER_W,
    parameter int unsigned M_PAYLOAD_W =
        OUT_DATA_W + 2 + STREAM_ID_W + SEQ_W + USER_W
) (
    input  wire                        clk,
    input  wire                        rst_n,

    // ---- SPEC 5 slave: the integrated power stream, one bin per beat --------
    input  wire                        s_valid,
    output wire                        s_ready,
    input  wire [S_PAYLOAD_W-1:0]      s_payload,

    // ---- SPEC 5 master: detection events ------------------------------------
    output wire                        m_valid,
    input  wire                        m_ready,
    output wire [M_PAYLOAD_W-1:0]      m_payload,

    // ---- configuration (rtl/control/reg_block_cfar.sv) ----------------------
    input  wire                        cfg_enable,
    input  wire [CFAR_MODE_W-1:0]      cfg_mode,        // cfar_mode_e
    input  wire                        cfg_out_mode,    // cfar_out_mode_e
    input  wire [CFAR_GUARD_CNT_W-1:0] cfg_guard_lead,
    input  wire [CFAR_GUARD_CNT_W-1:0] cfg_guard_lag,
    input  wire [CFAR_REF_CNT_W-1:0]   cfg_ref_lead,
    input  wire [CFAR_REF_CNT_W-1:0]   cfg_ref_lag,
    input  wire [CFAR_ALPHA_W-1:0]     cfg_alpha,
    input  wire                        cfg_status_clear,  // one-cycle pulse

    // ---- status -------------------------------------------------------------
    output wire [31:0]                 stat_det_count,
    output wire [31:0]                 stat_sup_count,
    output wire [31:0]                 stat_frame_count,
    output wire [5:0]                  stat_fault,       // sticky, see below
    output wire                        obs_cfg_pending,

    // Active geometry, so a test can prove the latched copy is what actually ran
    // rather than what was written.
    output wire                        obs_active_enable,
    output wire [CFAR_MODE_W-1:0]      obs_active_mode,
    output wire                        obs_active_out_mode,
    output wire [CFAR_GUARD_CNT_W-1:0] obs_active_guard_lead,
    output wire [CFAR_GUARD_CNT_W-1:0] obs_active_guard_lag,
    output wire [CFAR_REF_CNT_W-1:0]   obs_active_ref_lead,
    output wire [CFAR_REF_CNT_W-1:0]   obs_active_ref_lag,
    output wire [CFAR_ALPHA_W-1:0]     obs_active_alpha,
    output wire                        obs_frame_open,

    // Elaborated maxima, reported so software sizes its programming without a
    // compiled-in constant.
    output wire [CFAR_GUARD_CNT_W-1:0] obs_max_guard,
    output wire [CFAR_REF_CNT_W-1:0]   obs_max_ref,

    // Number of cells each reference mask is selecting right now. Equal to the
    // active counts by construction; exported so a test proves it rather than
    // assuming it, which is what makes an off-by-one in the guard indexing an
    // immediate named failure instead of a statistical one.
    output wire [CFAR_REF_CNT_W:0]     obs_n_lead,
    output wire [CFAR_REF_CNT_W:0]     obs_n_lag
);

  // ---------------------------------------------------------------------------
  // Geometry and widths
  // ---------------------------------------------------------------------------
  localparam int unsigned D_HALF = int'(cfar_half_window(cfar_uint_t'(MAX_GUARD),
                                                         cfar_uint_t'(MAX_REF)));
  localparam int unsigned SUM_W  = int'(cfar_sum_w(cfar_uint_t'(MAX_REF)));
  localparam int unsigned CMP_W  = int'(cfar_cmp_w(cfar_uint_t'(MAX_REF)));

  // Combined reference count, N_lead + N_lag.
  localparam int unsigned NTOT_W = CFAR_TOTREF_W;

  // Cross-multiply width for the greatest-of side selection: a SUM by a per-side
  // COUNT.
  localparam int unsigned XSEL_W = SUM_W + CFAR_REF_CNT_W;

  // Flush counter: D_HALF phantom advances per frame.
  localparam int unsigned FLUSH_W = (D_HALF <= 1) ? 1 : $clog2(D_HALF + 1);

  // Decision stages that may still push: adv_q, v1_q, v2_q, v3_q. Section 4's
  // F_max. Written here rather than as a literal so that adding a pipeline stage
  // for timing closure moves the flow-control bound with it.
  localparam int unsigned PIPE_INFLIGHT = 4;
  localparam int unsigned CRED_MIN      = PIPE_INFLIGHT + 1;

  // Free slots in the output elastic buffer (section 4).
  localparam int unsigned CRED_W = $clog2(OUT_DEPTH + 1);

  localparam stream_geom_t S_GEOM = stream_geom(stream_pkg::uint_t'(IN_DATA_W),
                                                stream_pkg::uint_t'(STREAM_ID_W),
                                                stream_pkg::uint_t'(SEQ_W),
                                                stream_pkg::uint_t'(USER_W));
  localparam stream_geom_t M_GEOM = stream_geom(stream_pkg::uint_t'(OUT_DATA_W),
                                                stream_pkg::uint_t'(STREAM_ID_W),
                                                stream_pkg::uint_t'(SEQ_W),
                                                stream_pkg::uint_t'(USER_W));

  // Sticky fault bits, in stat_fault order.
  localparam int unsigned FAULT_CFG_CLAMPED  = 0;
  localparam int unsigned FAULT_NEG_INPUT    = 1;
  localparam int unsigned FAULT_ORPHAN_BEAT  = 2;
  localparam int unsigned FAULT_SOF_IN_FRAME = 3;
  localparam int unsigned FAULT_NO_REF       = 4;
  localparam int unsigned FAULT_BIN_OVERFLOW = 5;
  localparam int unsigned N_FAULT            = 6;

`ifndef SYNTHESIS
  initial begin
    if (!cfar_widths_ok()) begin
      $fatal(1, "cfar_core: the widest legal CFAR geometry does not fit the %0d-bit comparison type",
             CFAR_WIDE_W);
    end
    if (int'(cfar_event_w()) != int'(CFAR_EVENT_W)) begin
      $fatal(1, "cfar_core: cfar_event_w()=%0d but CFAR_EVENT_W=%0d — the layout walk and the packed type disagree",
             int'(cfar_event_w()), int'(CFAR_EVENT_W));
    end
    if (OUT_DATA_W != int'(CFAR_EVENT_W)) begin
      $fatal(1, "cfar_core: OUT_DATA_W=%0d must be the event width %0d",
             OUT_DATA_W, int'(CFAR_EVENT_W));
    end
    if (IN_DATA_W != int'(cfar_power_w())) begin
      $fatal(1, "cfar_core: IN_DATA_W=%0d must be the power width %0d",
             IN_DATA_W, int'(cfar_power_w()));
    end
    if (OUT_DEPTH < CRED_MIN) begin
      $fatal(1, "cfar_core: OUT_DEPTH=%0d is below the %0d slots the decision pipeline can have in flight",
             OUT_DEPTH, CRED_MIN);
    end
    if (!stream_geom_ok(S_GEOM) || !stream_geom_ok(M_GEOM)) begin
      $fatal(1, "cfar_core: a stream geometry is outside the stream_pkg bounds");
    end
    if (int'(stream_payload_w(S_GEOM)) != S_PAYLOAD_W) begin
      $fatal(1, "cfar_core: stream_payload_w(S_GEOM)=%0d but S_PAYLOAD_W=%0d",
             int'(stream_payload_w(S_GEOM)), S_PAYLOAD_W);
    end
    if (int'(stream_payload_w(M_GEOM)) != M_PAYLOAD_W) begin
      $fatal(1, "cfar_core: stream_payload_w(M_GEOM)=%0d but M_PAYLOAD_W=%0d",
             int'(stream_payload_w(M_GEOM)), M_PAYLOAD_W);
    end
  end
`endif

  // ---------------------------------------------------------------------------
  // Input decode
  // ---------------------------------------------------------------------------
  stream_fields_t s_fields;
  assign s_fields = stream_unpack(S_GEOM, stream_payload_t'(s_payload));

  wire signed [IN_DATA_W-1:0] s_cell_signed = s_fields.data[IN_DATA_W-1:0];
  wire                        s_cell_neg    = s_cell_signed < 0;

  // A negative "power" is not physical (cfar_pkg section 1). Clamp to zero so
  // that every width below is an honest magnitude, and count it so the upstream
  // defect that produced it is visible rather than plausible.
  wire [IN_DATA_W-1:0] s_cell = s_cell_neg ? '0 : s_fields.data[IN_DATA_W-1:0];

  // ---------------------------------------------------------------------------
  // Frame state machine (section 3)
  // ---------------------------------------------------------------------------
  typedef enum logic [2:0] {
    ST_IDLE  = 3'd0,  // between frames; a start-of-frame beat opens one
    ST_RUN   = 3'd1,  // inside a frame, admitting bins
    ST_FLUSH = 3'd2,  // D phantom advances, pushing the tail to the CUT
    ST_DRAIN = 3'd3,  // waiting for the arithmetic pipeline to empty
    ST_SUM   = 3'd4   // emitting the end-of-frame summary
  } state_e;

  state_e state_q, state_d;

  logic [FLUSH_W-1:0] flush_q, flush_d;
  logic [CRED_W-1:0]  cred_q;
  wire  [CRED_W-1:0]  cred_d;
  logic               rdy_q;

  // Admission. `s_ready` is registered, so `admit` needs no combinational path
  // out of this block.
  wire accepting = (state_q == ST_IDLE) || (state_q == ST_RUN);
  wire admit     = s_valid && rdy_q && accepting;

  // A beat outside a frame with no start_of_frame has no defined bin index. It
  // is consumed and DISCARDED rather than stalled: a stalled CFAR backs pressure
  // into the FFT, and a frameless stream is an upstream defect that the fault
  // bit makes visible.
  wire orphan     = admit && (state_q == ST_IDLE) && !s_fields.sof;
  wire frame_open = admit && (state_q == ST_IDLE) && s_fields.sof;
  wire in_frame   = admit && (state_q == ST_RUN);
  wire bin_admit  = frame_open || in_frame;   // a real bin enters the window

  // A frame ends on the admitted beat carrying end_of_frame — INCLUDING the beat
  // that also carries start_of_frame. A one-bin frame is legal (SPEC 5 says
  // nothing that forbids it, and the corner-turn network can produce one), and
  // writing this as `in_frame && eof` would leave that frame open forever, which
  // is a hang rather than a wrong answer.
  wire frame_end  = bin_admit && s_fields.eof;

  // start_of_frame on a mid-frame beat is a source defect. The bit is IGNORED —
  // the beat is an ordinary bin — and the fault is raised.
  wire sof_in_frame = in_frame && s_fields.sof;

  // ---------------------------------------------------------------------------
  // Active configuration (section 5)
  // ---------------------------------------------------------------------------
  logic                        act_enable_q,   act_out_mode_q;
  logic [CFAR_MODE_W-1:0]      act_mode_q;
  logic [CFAR_GUARD_CNT_W-1:0] act_g_lead_q,   act_g_lag_q;
  logic [CFAR_REF_CNT_W-1:0]   act_r_lead_q,   act_r_lag_q;
  logic [CFAR_ALPHA_W-1:0]     act_alpha_q;
  logic [CFAR_FRAME_ID_W-1:0]  act_frame_id_q;
  logic [STREAM_ID_W-1:0]      act_beam_q;
  logic [USER_W-1:0]           act_user_q;

  // Clamp to the elaborated maxima.
  wire [CFAR_GUARD_CNT_W-1:0] g_lead_c =
      (cfg_guard_lead > CFAR_GUARD_CNT_W'(MAX_GUARD)) ? CFAR_GUARD_CNT_W'(MAX_GUARD)
                                                      : cfg_guard_lead;
  wire [CFAR_GUARD_CNT_W-1:0] g_lag_c =
      (cfg_guard_lag > CFAR_GUARD_CNT_W'(MAX_GUARD)) ? CFAR_GUARD_CNT_W'(MAX_GUARD)
                                                     : cfg_guard_lag;
  wire [CFAR_REF_CNT_W-1:0] r_lead_c =
      (cfg_ref_lead > CFAR_REF_CNT_W'(MAX_REF)) ? CFAR_REF_CNT_W'(MAX_REF) : cfg_ref_lead;
  wire [CFAR_REF_CNT_W-1:0] r_lag_c =
      (cfg_ref_lag > CFAR_REF_CNT_W'(MAX_REF)) ? CFAR_REF_CNT_W'(MAX_REF) : cfg_ref_lag;

  wire cfg_clamped = (g_lead_c != cfg_guard_lead) || (g_lag_c != cfg_guard_lag) ||
                     (r_lead_c != cfg_ref_lead)   || (r_lag_c != cfg_ref_lag);

  // A write is waiting for the next frame boundary.
  assign obs_cfg_pending = (act_enable_q   != cfg_enable)   ||
                           (act_mode_q     != cfg_mode)     ||
                           (act_out_mode_q != cfg_out_mode) ||
                           (act_g_lead_q   != g_lead_c)     ||
                           (act_g_lag_q    != g_lag_c)      ||
                           (act_r_lead_q   != r_lead_c)     ||
                           (act_r_lag_q    != r_lag_c)      ||
                           (act_alpha_q    != cfg_alpha);

  always_ff @(posedge clk) begin
    if (!rst_n) begin
      act_enable_q   <= 1'b0;
      act_mode_q     <= CFAR_MODE_W'(CFAR_MODE_CA);
      act_out_mode_q <= 1'b0;
      act_g_lead_q   <= CFAR_GUARD_CNT_W'(0);
      act_g_lag_q    <= CFAR_GUARD_CNT_W'(0);
      act_r_lead_q   <= CFAR_REF_CNT_W'(0);
      act_r_lag_q    <= CFAR_REF_CNT_W'(0);
      act_alpha_q    <= CFAR_ALPHA_W'(0);
      act_frame_id_q <= CFAR_FRAME_ID_W'(0);
      act_beam_q     <= STREAM_ID_W'(0);
      act_user_q     <= USER_W'(0);
    end else if (frame_open) begin
      act_enable_q   <= cfg_enable;
      act_mode_q     <= cfg_mode;
      act_out_mode_q <= cfg_out_mode;
      act_g_lead_q   <= g_lead_c;
      act_g_lag_q    <= g_lag_c;
      act_r_lead_q   <= r_lead_c;
      act_r_lag_q    <= r_lag_c;
      act_alpha_q    <= cfg_alpha;
      // Frame identity: the input stream's sequence number at the frame's first
      // beat, truncated to CFAR_FRAME_ID_W. Beam identity is the stream id, per
      // SPEC 5; it rides the output stream's own stream_id as well as being the
      // thing the packet network keys on.
      act_frame_id_q <= CFAR_FRAME_ID_W'(s_fields.seq);
      act_beam_q     <= s_fields.stream_id[STREAM_ID_W-1:0];
      act_user_q     <= s_fields.user[USER_W-1:0];
    end
  end

  assign obs_active_enable     = act_enable_q;
  assign obs_active_mode       = act_mode_q;
  assign obs_active_out_mode   = act_out_mode_q;
  assign obs_active_guard_lead = act_g_lead_q;
  assign obs_active_guard_lag  = act_g_lag_q;
  assign obs_active_ref_lead   = act_r_lead_q;
  assign obs_active_ref_lag    = act_r_lag_q;
  assign obs_active_alpha      = act_alpha_q;
  assign obs_frame_open        = (state_q != ST_IDLE);
  assign obs_max_guard         = CFAR_GUARD_CNT_W'(MAX_GUARD);
  assign obs_max_ref           = CFAR_REF_CNT_W'(MAX_REF);

  // Usable reference geometry for the ACTIVE mode (section 2).
  wire [NTOT_W-1:0] act_n_tot = NTOT_W'(act_r_lead_q) + NTOT_W'(act_r_lag_q);
  wire refs_usable = (act_mode_q == CFAR_MODE_W'(CFAR_MODE_GO))
                         ? ((act_r_lead_q != '0) && (act_r_lag_q != '0))
                         : (act_n_tot != '0);

  // ---------------------------------------------------------------------------
  // Bin index and frame length
  // ---------------------------------------------------------------------------
  logic [CFAR_BIN_W-1:0] bin_q;
  logic [CFAR_BIN_W-1:0] frame_len_q;
  logic                  bin_ovf;

  assign bin_ovf = in_frame && (&bin_q);

  // Index of the bin entering the window this cycle.
  wire [CFAR_BIN_W-1:0] in_bin = frame_open ? CFAR_BIN_W'(0) : bin_q;

  always_ff @(posedge clk) begin
    if (!rst_n) begin
      bin_q       <= CFAR_BIN_W'(0);
      frame_len_q <= CFAR_BIN_W'(0);
    end else begin
      if (frame_open) begin
        bin_q <= CFAR_BIN_W'(1);
      end else if (in_frame && !(&bin_q)) begin
        bin_q <= bin_q + CFAR_BIN_W'(1);
      end
      // The frame's length in bins, captured when end_of_frame is admitted: the
      // index of the beat carrying it, plus one. Taken from `in_bin` rather than
      // from `bin_q` so that the one-beat frame — where the same beat carries
      // start_of_frame and end_of_frame — reports 1 rather than 0.
      if (frame_end) frame_len_q <= in_bin + CFAR_BIN_W'(1);
    end
  end

  // ---------------------------------------------------------------------------
  // The sliding window
  // ---------------------------------------------------------------------------
  // An advance is allowed only while the output buffer can absorb everything the
  // pipeline may still push (section 4). `bin_admit` is already gated by
  // `rdy_q`, which carries the same condition one cycle earlier; the flush is
  // gated here, because it is driven by this block rather than by a beat.
  wire has_room   = (cred_q >= CRED_W'(CRED_MIN));
  wire flush_step = (state_q == ST_FLUSH) && has_room;
  wire advance    = bin_admit || flush_step;

  wire                   cut_valid_c;
  wire [IN_DATA_W-1:0]   cut_cell_c;
  wire [CFAR_BIN_W-1:0]  cut_bin_c;
  wire [SUM_W-1:0]       sum_lead_c, sum_lag_c;
  wire                   ok_lead_c,  ok_lag_c;

  cfar_window #(
      .POWER_W   (IN_DATA_W),
      .MAX_GUARD (MAX_GUARD),
      .MAX_REF   (MAX_REF),
      .BIN_W     (CFAR_BIN_W),
      .SUM_W     (SUM_W)
  ) u_window (
      .clk            (clk),
      .rst_n          (rst_n),
      .clear          (frame_open),
      .advance        (advance),
      .in_valid       (bin_admit),
      .in_cell        (s_cell),
      .in_bin         (in_bin),
      .cfg_guard_lead (act_g_lead_q),
      .cfg_guard_lag  (act_g_lag_q),
      .cfg_ref_lead   (act_r_lead_q),
      .cfg_ref_lag    (act_r_lag_q),
      .cut_valid      (cut_valid_c),
      .cut_cell       (cut_cell_c),
      .cut_bin        (cut_bin_c),
      .sum_lead       (sum_lead_c),
      .sum_lag        (sum_lag_c),
      .refs_ok_lead   (ok_lead_c),
      .refs_ok_lag    (ok_lag_c),
      .obs_n_lead     (obs_n_lead),
      .obs_n_lag      (obs_n_lag)
  );

  // ---------------------------------------------------------------------------
  // Stage 1 — capture the window one cycle after the advance that formed it
  // ---------------------------------------------------------------------------
  logic                 adv_q;
  logic                 v1_q, cut_v1_q, ok1_q;
  logic [IN_DATA_W-1:0] cell1_q;
  logic [CFAR_BIN_W-1:0] bin1_q;
  logic [SUM_W-1:0]     sum_lead1_q, sum_lag1_q;

  always_ff @(posedge clk) begin
    if (!rst_n) begin
      adv_q <= 1'b0;
      v1_q  <= 1'b0;
    end else begin
      adv_q <= advance;
      v1_q  <= adv_q;
      if (adv_q) begin
        cut_v1_q    <= cut_valid_c;
        cell1_q     <= cut_cell_c;
        bin1_q      <= cut_bin_c;
        sum_lead1_q <= sum_lead_c;
        sum_lag1_q  <= sum_lag_c;
        ok1_q       <= ok_lead_c && ok_lag_c;
      end
    end
  end

  // ---------------------------------------------------------------------------
  // Stage 2 — mode selection: which (S, N) pair enters the comparison
  //
  // The greatest-of cross-multiply is a SUM by a 6-bit COUNT, which is where the
  // cheap version of "greater mean" lives (section 1). In CA mode the two
  // products are formed anyway and their result is discarded; leaving them
  // unconditional keeps the mode off the multiplier's operand path, where a mux
  // would sit between a register and a DSP input.
  // ---------------------------------------------------------------------------
  wire [SUM_W-1:0]  sum_tot_c = sum_lead1_q + sum_lag1_q;
  wire [XSEL_W-1:0] x_lead_c  = XSEL_W'(sum_lead1_q) * XSEL_W'(act_r_lag_q);
  wire [XSEL_W-1:0] x_lag_c   = XSEL_W'(sum_lag1_q)  * XSEL_W'(act_r_lead_q);
  wire              take_lead = (x_lead_c >= x_lag_c);

  wire [SUM_W-1:0]  sel_sum_c =
      (act_mode_q == CFAR_MODE_W'(CFAR_MODE_GO))
          ? (take_lead ? sum_lead1_q : sum_lag1_q)
          : sum_tot_c;

  wire [NTOT_W-1:0] sel_n_c =
      (act_mode_q == CFAR_MODE_W'(CFAR_MODE_GO))
          ? (take_lead ? NTOT_W'(act_r_lead_q) : NTOT_W'(act_r_lag_q))
          : act_n_tot;

  logic                  v2_q, cut_v2_q, ok2_q;
  logic [IN_DATA_W-1:0]  cell2_q;
  logic [CFAR_BIN_W-1:0] bin2_q;
  logic [SUM_W-1:0]      sel_sum2_q;
  logic [NTOT_W-1:0]     sel_n2_q;

  always_ff @(posedge clk) begin
    if (!rst_n) begin
      v2_q <= 1'b0;
    end else begin
      v2_q <= v1_q;
      if (v1_q) begin
        cut_v2_q   <= cut_v1_q;
        cell2_q    <= cell1_q;
        bin2_q     <= bin1_q;
        ok2_q      <= ok1_q;
        sel_sum2_q <= sel_sum_c;
        sel_n2_q   <= sel_n_c;
      end
    end
  end

  // ---------------------------------------------------------------------------
  // Stage 3 — the two products of (*)
  // ---------------------------------------------------------------------------
  wire [CMP_W-1:0] lhs_c = CMP_W'(CMP_W'(cell2_q) * CMP_W'(sel_n2_q)) << CFAR_ALPHA_FRAC_W;
  wire [CMP_W-1:0] rhs_c = CMP_W'(act_alpha_q) * CMP_W'(sel_sum2_q);

  logic                  v3_q, cut_v3_q, ok3_q;
  logic [IN_DATA_W-1:0]  cell3_q;
  logic [CFAR_BIN_W-1:0] bin3_q;
  logic [SUM_W-1:0]      sel_sum3_q;
  logic [NTOT_W-1:0]     sel_n3_q;
  logic [CMP_W-1:0]      lhs3_q, rhs3_q;

  always_ff @(posedge clk) begin
    if (!rst_n) begin
      v3_q <= 1'b0;
    end else begin
      v3_q <= v2_q;
      if (v2_q) begin
        cut_v3_q   <= cut_v2_q;
        cell3_q    <= cell2_q;
        bin3_q     <= bin2_q;
        ok3_q      <= ok2_q;
        sel_sum3_q <= sel_sum2_q;
        sel_n3_q   <= sel_n2_q;
        lhs3_q     <= lhs_c;
        rhs3_q     <= rhs_c;
      end
    end
  end

  // ---------------------------------------------------------------------------
  // Decision
  // ---------------------------------------------------------------------------
  wire real_bin   = v3_q && cut_v3_q;
  wire evaluable  = real_bin && ok3_q && act_enable_q && refs_usable;
  wire over_thr   = lhs3_q > rhs3_q;
  wire detected   = evaluable && over_thr;
  wire suppressed = real_bin && !evaluable;

  wire emit_bin = real_bin &&
                  ((act_out_mode_q == CFAR_OUT_DENSE) || detected);

  // ---------------------------------------------------------------------------
  // Per-frame counters. Cleared at the frame boundary; complete by the time the
  // pipeline has drained, which is what ST_DRAIN waits for.
  // ---------------------------------------------------------------------------
  logic [CFAR_CNT_W-1:0] det_q, sup_q;

  always_ff @(posedge clk) begin
    if (!rst_n) begin
      det_q <= CFAR_CNT_W'(0);
      sup_q <= CFAR_CNT_W'(0);
    end else if (frame_open) begin
      det_q <= CFAR_CNT_W'(0);
      sup_q <= CFAR_CNT_W'(0);
    end else begin
      if (detected   && !(&det_q)) det_q <= det_q + CFAR_CNT_W'(1);
      if (suppressed && !(&sup_q)) sup_q <= sup_q + CFAR_CNT_W'(1);
    end
  end

  // ---------------------------------------------------------------------------
  // Event formation
  // ---------------------------------------------------------------------------
  // The summary needs only ONE free slot, not CRED_MIN: by the time the block
  // reaches ST_SUM the pipeline has drained, so nothing else can push.
  wire emit_summary = (state_q == ST_SUM) && (cred_q != CRED_W'(0));
  wire push         = emit_bin || emit_summary;

  cfar_event_t ev_c;

  always_comb begin
    ev_c = '0;
    if (emit_summary) begin
      ev_c.kind      = CFAR_EV_KIND_W'(CFAR_EV_SUMMARY);
      ev_c.bin       = frame_len_q;
      ev_c.frame_id  = act_frame_id_q;
      ev_c.alpha     = act_alpha_q;
      ev_c.det_count = det_q;
      ev_c.sup_count = sup_q;
    end else begin
      ev_c.kind     = detected ? CFAR_EV_KIND_W'(CFAR_EV_DETECT)
                    : suppressed ? CFAR_EV_KIND_W'(CFAR_EV_SUPPRESSED)
                                 : CFAR_EV_KIND_W'(CFAR_EV_BIN);
      ev_c.bin      = bin3_q;
      ev_c.frame_id = act_frame_id_q;
      ev_c.alpha    = act_alpha_q;
      ev_c.cut_power = CFAR_POWER_W'(cell3_q);
      // A suppressed bin has no valid reference window, so it reports none.
      ev_c.ref_count = suppressed ? CFAR_TOTREF_W'(0) : CFAR_TOTREF_W'(sel_n3_q);
      ev_c.noise_sum = suppressed ? CFAR_SUM_W'(0)    : CFAR_SUM_W'(sel_sum3_q);
    end
  end

  // Output framing: start_of_frame on the first emitted beat of a frame,
  // end_of_frame on the summary. A frame with no detections is therefore a
  // well-formed single-beat output frame.
  //
  // The sequence number is PER BEAM, not global. SPEC 5 requires the field to
  // permit end-to-end loss and ordering checks, and
  // sim/assertions/stream_protocol_checker.sv enforces exactly that — the field
  // must increment by one per beat WITHIN A stream_id. A single global counter
  // looks continuous only while one beam is running; interleave two beams'
  // frames and every frame boundary becomes an apparent discontinuity, which is
  // a false loss report on the one signal a consumer uses to detect real loss.
  // The table costs 2**STREAM_ID_W words of SEQ_W bits and is read at a frame
  // boundary and written on each emitted beat.
  localparam int unsigned N_SID = 1 << STREAM_ID_W;

  logic                   out_first_q;
  logic [SEQ_W-1:0]       out_seq_q;
  logic [SEQ_W-1:0]       seq_tab_q [N_SID];

  wire [STREAM_ID_W-1:0] in_beam = s_fields.stream_id[STREAM_ID_W-1:0];

  always_ff @(posedge clk) begin
    if (!rst_n) begin
      out_first_q <= 1'b1;
      out_seq_q   <= SEQ_W'(0);
      for (int unsigned i = 0; i < N_SID; i++) seq_tab_q[i] <= SEQ_W'(0);
    end else begin
      if (frame_open)   out_first_q <= 1'b1;
      else if (push)    out_first_q <= 1'b0;

      // A push cannot coincide with a start-of-frame beat: the block is in
      // ST_IDLE with an empty pipeline when it accepts one, so nothing is in
      // flight to emit. The priority below states that rather than relying on it.
      if (frame_open) begin
        out_seq_q <= seq_tab_q[in_beam];
      end else if (push) begin
        out_seq_q             <= out_seq_q + SEQ_W'(1);
        seq_tab_q[act_beam_q] <= out_seq_q + SEQ_W'(1);
      end
    end
  end

  stream_fields_t m_fields_c;

  always_comb begin
    m_fields_c           = '0;
    m_fields_c.data      = STREAM_MAX_DATA_W'(cfar_event_pack(ev_c));
    m_fields_c.sof       = out_first_q;
    m_fields_c.eof       = emit_summary;
    m_fields_c.stream_id = STREAM_MAX_ID_W'(act_beam_q);
    m_fields_c.seq       = STREAM_MAX_SEQ_W'(out_seq_q);
    m_fields_c.user      = STREAM_MAX_USER_W'(act_user_q);
  end

  wire [M_PAYLOAD_W-1:0] push_payload = M_PAYLOAD_W'(stream_pack(M_GEOM, m_fields_c));

  // ---------------------------------------------------------------------------
  // Output elastic buffer (SPEC 5, SPEC 23). The credit rule above guarantees a
  // slot, so `buf_ready` is high whenever `push` is — asserted below rather than
  // assumed.
  // ---------------------------------------------------------------------------
  wire buf_ready;
  wire [$clog2(OUT_DEPTH+1)-1:0] buf_occ_unused;

  stream_elastic_buffer #(
      .PAYLOAD_W   (M_PAYLOAD_W),
      .DEPTH       (OUT_DEPTH),
      .DATA_W      (OUT_DATA_W),
      .STREAM_ID_W (STREAM_ID_W),
      .SEQ_W       (SEQ_W),
      .USER_W      (USER_W)
  ) u_out (
      .clk       (clk),
      .rst_n     (rst_n),
      .s_valid   (push),
      .s_ready   (buf_ready),
      .s_payload (push_payload),
      .m_valid   (m_valid),
      .m_ready   (m_ready),
      .m_payload (m_payload),
      .occupancy (buf_occ_unused)
  );

  wire release_beat = m_valid && m_ready;

  // ---------------------------------------------------------------------------
  // Credits (section 4)
  // ---------------------------------------------------------------------------
  // cred_q mirrors the buffer's free-slot count exactly: it is decremented by
  // the same `push` the buffer accepts and incremented by the same beat the
  // buffer releases, so cred_q == OUT_DEPTH - occupancy at every instant. That
  // equality is what lets the state machine gate on cred_q rather than on the
  // buffer's registered `s_ready`, which is a cycle behind for the purpose of
  // deciding whether to START a multi-cycle flush.
  assign cred_d = cred_q - CRED_W'(push) + CRED_W'(release_beat);

  // ---------------------------------------------------------------------------
  // State
  // ---------------------------------------------------------------------------
  wire pipe_busy = adv_q || v1_q || v2_q || v3_q;

  always_comb begin
    state_d = state_q;
    flush_d = flush_q;
    case (state_q)
      ST_IDLE: begin
        // A one-beat frame carries both boundary bits, so it goes straight to
        // the flush without ever entering ST_RUN.
        if (frame_end) begin
          state_d = ST_FLUSH;
          flush_d = FLUSH_W'(D_HALF);
        end else if (frame_open) begin
          state_d = ST_RUN;
        end
      end
      ST_RUN: begin
        if (frame_end) begin
          // D_HALF >= 1 always: cfar_window rejects MAX_REF = 0 at elaboration,
          // so there is no "no flush needed" case to branch on.
          state_d = ST_FLUSH;
          flush_d = FLUSH_W'(D_HALF);
        end
      end
      ST_FLUSH: begin
        // Stallable: the flush pauses rather than overflowing the output buffer.
        if (has_room) begin
          flush_d = flush_q - FLUSH_W'(1);
          if (flush_q <= FLUSH_W'(1)) state_d = ST_DRAIN;
        end
      end
      ST_DRAIN: begin
        if (!pipe_busy) state_d = ST_SUM;
      end
      ST_SUM: begin
        if (emit_summary) state_d = ST_IDLE;
      end
      default: state_d = ST_IDLE;
    endcase
  end

  always_ff @(posedge clk) begin
    if (!rst_n) begin
      state_q <= ST_IDLE;
      flush_q <= FLUSH_W'(0);
      cred_q  <= CRED_W'(OUT_DEPTH);
      rdy_q   <= 1'b0;
    end else begin
      state_q <= state_d;
      flush_q <= flush_d;
      cred_q  <= cred_d;
      // Ready follows the NEXT state, which is what stops a beat being admitted
      // in the cycle after end_of_frame (section 3), and carries the same
      // free-slot condition `has_room` applies to the flush — one cycle earlier,
      // because it is a registered output.
      rdy_q   <= (cred_d >= CRED_W'(CRED_MIN)) &&
                 ((state_d == ST_IDLE) || (state_d == ST_RUN));
    end
  end

  assign s_ready = rdy_q;

  // ---------------------------------------------------------------------------
  // Sticky faults and the SPEC 9 counters
  // ---------------------------------------------------------------------------
  logic [N_FAULT-1:0] fault_q;
  logic [N_FAULT-1:0] fault_set;

  always_comb begin
    fault_set                     = '0;
    fault_set[FAULT_CFG_CLAMPED]  = frame_open && cfg_clamped;
    fault_set[FAULT_NEG_INPUT]    = bin_admit && s_cell_neg;
    fault_set[FAULT_ORPHAN_BEAT]  = orphan;
    fault_set[FAULT_SOF_IN_FRAME] = sof_in_frame;
    fault_set[FAULT_NO_REF]       = real_bin && !refs_usable;
    fault_set[FAULT_BIN_OVERFLOW] = bin_ovf;
  end

  always_ff @(posedge clk) begin
    if (!rst_n)                fault_q <= '0;
    else if (cfg_status_clear) fault_q <= fault_set;   // set beats clear
    else                       fault_q <= fault_q | fault_set;
  end

  assign stat_fault = fault_q;

  wire [31:0] det_total, sup_total, frame_total;
  wire        det_snap_unused, sup_snap_unused, frm_snap_unused;
  wire [31:0] det_shadow_unused, sup_shadow_unused, frm_shadow_unused;
  wire        det_wrap_p_unused, sup_wrap_p_unused, frm_wrap_p_unused;
  wire        det_wrapped_unused, sup_wrapped_unused, frm_wrapped_unused;

  perf_counter #(.WIDTH(32), .INCR_W(1), .SATURATE(1'b1)) u_cnt_det (
      .clk (clk), .rst_n (rst_n), .enable (1'b1), .event_i (detected),
      .incr (1'b1), .clear (cfg_status_clear), .snapshot (1'b0),
      .count (det_total), .snap (det_shadow_unused), .snap_valid (det_snap_unused),
      .wrap_pulse (det_wrap_p_unused), .wrapped (det_wrapped_unused)
  );

  perf_counter #(.WIDTH(32), .INCR_W(1), .SATURATE(1'b1)) u_cnt_sup (
      .clk (clk), .rst_n (rst_n), .enable (1'b1), .event_i (suppressed),
      .incr (1'b1), .clear (cfg_status_clear), .snapshot (1'b0),
      .count (sup_total), .snap (sup_shadow_unused), .snap_valid (sup_snap_unused),
      .wrap_pulse (sup_wrap_p_unused), .wrapped (sup_wrapped_unused)
  );

  perf_counter #(.WIDTH(32), .INCR_W(1), .SATURATE(1'b1)) u_cnt_frm (
      .clk (clk), .rst_n (rst_n), .enable (1'b1), .event_i (emit_summary),
      .incr (1'b1), .clear (cfg_status_clear), .snapshot (1'b0),
      .count (frame_total), .snap (frm_shadow_unused), .snap_valid (frm_snap_unused),
      .wrap_pulse (frm_wrap_p_unused), .wrapped (frm_wrapped_unused)
  );

  assign stat_det_count   = det_total;
  assign stat_sup_count   = sup_total;
  assign stat_frame_count = frame_total;

  // ---------------------------------------------------------------------------
  // SPEC 14 property set. Instantiated here rather than bound externally, for
  // the reason rtl/covariance/integrator.sv gives: the properties then hold
  // wherever this module is used, including in a Quartus calibration wrapper
  // that no testbench ever drives.
  // ---------------------------------------------------------------------------
`ifndef SYNTHESIS
  // The whole active configuration as one vector, so the "changes only at a
  // frame boundary" property is one comparison rather than eight.
  localparam int unsigned ACT_W = 1 + 1 + CFAR_MODE_W +
                                  2 * CFAR_GUARD_CNT_W + 2 * CFAR_REF_CNT_W +
                                  CFAR_ALPHA_W;

  wire [ACT_W-1:0] act_vec = {act_enable_q, act_out_mode_q, act_mode_q,
                              act_g_lead_q, act_g_lag_q,
                              act_r_lead_q, act_r_lag_q, act_alpha_q};

  cfar_assertions #(
      .POWER_W (IN_DATA_W),
      .SUM_W   (SUM_W),
      .CMP_W   (CMP_W),
      .NTOT_W  (NTOT_W),
      .ACT_W   (ACT_W)
  ) u_assert (
      .clk           (clk),
      .rst_n         (rst_n),
      .dec_valid     (v3_q),
      .dec_cut_valid (cut_v3_q),
      .dec_cell      (cell3_q),
      .dec_sum       (sel_sum3_q),
      .dec_n         (sel_n3_q),
      .dec_alpha     (act_alpha_q),
      .dec_lhs       (lhs3_q),
      .dec_rhs       (rhs3_q),
      .dec_detected  (detected),
      .dec_supp      (suppressed),
      .dec_evaluable (evaluable),
      .push          (push),
      .buf_ready     (buf_ready),
      .frame_start   (frame_open),
      .act_vec       (act_vec)
  );
`endif

endmodule : cfar_core

`default_nettype wire
