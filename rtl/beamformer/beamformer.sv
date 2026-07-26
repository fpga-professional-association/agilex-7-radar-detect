// -----------------------------------------------------------------------------
// beamformer — the beamforming matrix (SPEC.md 5, 6, 7.5, 9, 23; issue #12).
//
//     Y[b][f] = sum over antennas a of X[a][f] * W[b][a]
//
// BIN_PAR x BEAM_PAR instances of rtl/beamformer/bf_dot.sv, one shared
// double-buffered weight store (rtl/beamformer/weight_bank.sv), a SPEC 5 stream
// in and out, and the SPEC 9 telemetry hooks. This is the design's dominant DSP
// consumer and the SPEC 18 item 7 calibration kernel.
//
// -----------------------------------------------------------------------------
// 1. THE INPUT CONTRACT — one beat is BIN_PAR aligned antenna vectors
// -----------------------------------------------------------------------------
// A beat's data field carries BIN_PAR consecutive frequency bins, each as the
// complete vector of N_ANT complex Q1.15 samples for that bin. Bin-major,
// antenna-minor:
//
//     data[(j*N_ANT + a) * 32 +: 32]   =  X[antenna a][bin_base + j]
//                                          packed {im, re}, Q1.15
//     j in [0, BIN_PAR)   a in [0, N_ANT)
//
// With BIN_PAR = 1 this is exactly "one beat is one bin's antenna vector".
//
// THE WORD "ALIGNED" IS THE WHOLE CONTRACT. Every antenna's sample in a beat
// must be the SAME frequency bin of the SAME frame. A beamformer sums across the
// antenna dimension, so a beat in which antenna 3 is one bin behind the others
// produces a result that is not a beam and is not detectably wrong from the
// output alone. Producing that alignment is issue #16's frequency alignment
// network, and it is the reason that issue exists; this module ASSUMES it and
// states the assumption here because an assumption stated only in a diagram is
// an assumption nobody checks.
//
// What this module does NOT assume, and therefore does not require of #16:
//   * that bins arrive in any particular order. `bin_base` is positional, not
//     decoded: bin j of the beat is bin j of the beat, and the frame's mapping
//     from beat index to absolute bin index is a frame-level convention carried
//     by the sequence number.
//   * that a frame contains a whole number of beats' worth of anything. Frames
//     are delimited by start_of_frame / end_of_frame exactly as SPEC 5 says.
//
// OUTPUT: one beat carries BIN_PAR bins x BEAM_PAR beams of ONE beam group,
// beam-major and bin-minor — the transpose of the input's nesting, because the
// output's slow axis is the beam where the input's is the bin:
//
//     data[(k*BIN_PAR + j) * 32 +: 32]  =  Y[group*BEAM_PAR + k][bin_base + j]
//
// -----------------------------------------------------------------------------
// 2. TIME MULTIPLEXING, IN PARAMETERS AND IN THE REPORTED THROUGHPUT
// -----------------------------------------------------------------------------
// SPEC 7.5: "Do not silently reduce throughput to meet utilization. Any time
// multiplexing must be visible in parameters and reported throughput."
//
// The engine builds BIN_PAR x BEAM_PAR dot products. When BEAM_PAR < N_BEAMS the
// remaining beams are computed on later cycles FROM THE SAME HELD INPUT BEAT, in
// BEAM_MUX = N_BEAMS / BEAM_PAR groups of BEAM_PAR beams. So:
//
//     BEAM_MUX = N_BEAMS / BEAM_PAR                (beamformer_pkg::bf_beam_mux)
//     input  beats accepted per cycle  =  1 / BEAM_MUX
//     output beats produced per cycle  =  1
//     bins  per input  beat            =  BIN_PAR
//     beams per output beat            =  BEAM_PAR
//     bins/cycle sustained             =  BIN_PAR / BEAM_MUX
//     beam-bins/cycle sustained        =  BIN_PAR * BEAM_PAR
//
// The last line is the one that matters: the engine's arithmetic throughput is
// BIN_PAR*BEAM_PAR beam-bins per cycle whatever the multiplex factor, because
// the multiplex trades input rate for engine reuse and nothing else. A
// configuration with BEAM_PAR = N_BEAMS runs at BIN_PAR bins/cycle and holds the
// full BIN_PAR*N_BEAMS engine; one with BEAM_PAR = N_BEAMS/2 runs at half the
// bin rate on half the engine.
//
// All six numbers are exported on the `tput_*` ports and are read back through
// the register plane's weight window, so the throughput claim is a measurement
// rather than a comment. `beamformer_assertions` additionally checks the
// admission rate against BEAM_MUX on live traffic, so a configuration that
// silently admitted faster than the engine can serve would fail rather than
// produce quiet nonsense.
//
// BEAM_MUX IS A POWER OF TWO, checked at elaboration. That buys the output
// sequence number: seq_out = {seq_in, group}, a free concatenation which is
// continuous beat-to-beat (which sim/assertions/stream_protocol_checker.sv
// requires on the master interface) and invertible (a consumer recovers the
// input beat index and the beam group by slicing). A non-power-of-two factor
// would need a multiply on the sequence field and would break the slice. When
// BEAM_MUX = 1 the shift is zero and the sequence passes through unchanged.
//
// -----------------------------------------------------------------------------
// 3. FLOW CONTROL: elastic at the boundary, fixed latency inside
// -----------------------------------------------------------------------------
// SPEC 23: "Break ready/valid feedback with elastic buffers", "keep pipeline
// stages latency-insensitive", "avoid one chip-wide clock enable". SPEC 5: "No
// combinational ready loop may cross more than one module boundary."
//
// The interior is a FIXED-LATENCY VALID PIPELINE with no ready at all: a ready
// chain into a bf_dot would land `m_ready` on the clock enable of every DSP
// register in the largest DSP array in the design. Backpressure is absorbed at
// the boundary by a credit scheme identical in shape to rtl/pfb/pfb_bank.sv and
// rtl/stream/stream_pipe.sv:
//
//     s_ready is a flip-flop whose input depends only on this block's own credit
//     counter and its own hold-register state. A beat is admitted only when
//     BEAM_MUX slots are reserved in the output elastic buffer — one per output
//     beat it will produce — so the buffer can never overflow and the interior
//     never has to stall.
//
// Reserving BEAM_MUX at once rather than one at a time is what makes the
// reservation sound: an input beat is an all-or-nothing commitment to BEAM_MUX
// outputs, and a per-output reservation could admit a beat whose later groups
// then have nowhere to go.
//
// -----------------------------------------------------------------------------
// 4. Metadata alignment
// -----------------------------------------------------------------------------
// Every register in this block free-runs, so the latency is a pure CYCLE count
// (beamformer_pkg, "Latency") — there is no sample history anywhere in a
// beamformer and therefore none of the beat-measured latency that
// rtl/packages/pfb_pkg.sv has to carry. Metadata is formed AT ISSUE (not at
// admission, which can be several cycles earlier when BEAM_MUX > 1) and travels
// bf_dot_lat() free-running register stages alongside the arithmetic.
//
// The output metadata convention, stated because output beat k is not "the same
// beat as" any input beat once BEAM_MUX > 1:
//
//     stream_id  unchanged.
//     seq        {seq_in, group}; see section 2.
//     sof        set on group 0 of an input beat that carried start_of_frame.
//     eof        set on the LAST group of an input beat that carried
//                end_of_frame, so a frame ends when its last beam group has
//                been delivered and not before.
//     user       THE BEAM GROUP INDEX. The beams in this beat are
//                [group*BEAM_PAR, (group+1)*BEAM_PAR).
//
// `user` carries the group rather than forwarding the input's `user` field
// because SPEC 12.5's transaction identity names `beam` as a dimension and this
// is the only field it can live in; the bin dimension is positional within the
// beat and needs no field. The precedent for choosing a convention here rather
// than pretending one is implied is issue #11 decision 8, which had to do the
// same thing for the FFT's output metadata.
//
// -----------------------------------------------------------------------------
// 5. Weights and the frame-boundary swap
// -----------------------------------------------------------------------------
// One rtl/beamformer/weight_bank.sv holds the whole N_BEAMS x N_ANT matrix,
// twice. Its swap point is the ADMITTED start-of-frame beat — the same
// `admit`/`sof` pair the datapath sees, taken at the same point in the pipeline
// — so a frame whose first beat entered under bank B is beamformed entirely
// under bank B, every beam group of every beat. Swap granularity is the whole
// array, for the reasons weight_bank section 2 gives.
//
// When BEAM_MUX > 1 the active bank's row for the current group is selected by
// `grp_q`. The mux is N_BEAMS*N_ANT*32 bits wide into BEAM_PAR*N_ANT*32 and sits
// ahead of complex_multiplier's own REG_IN, so it is a combinational cone into a
// register rather than a path between registers. It is one of the two things the
// SPEC 18 matrix calibration exists to price (the other being whether BIN_PAR
// dot products still cascade their DSPs at width).
//
// -----------------------------------------------------------------------------
// 6. Telemetry (SPEC 9, issue #8 primitives)
// -----------------------------------------------------------------------------
// Every dot product's saturation flags are merged into one direction-resolved
// pair and fed to rtl/common/fxp_sticky_flags.sv (sticky, plus a saturating
// event count) and to rtl/common/perf_counter.sv (snapshot-coherent). Output
// frames are counted the same way. Nothing here invents a counter.
//
// Lint contract: clean under `verilator --lint-only --Wall` with no waiver.
// -----------------------------------------------------------------------------

`default_nettype none

// (* cdc_primitive *) — this module has a configuration clock and a core clock,
// so the SPEC 8 inventory must be able to classify it. It is a COMPOSITE whose
// only crossing is the weight_bank instance below (itself a composite over
// coeff_bank over the issue #6 primitives); the datapath does not cross domains
// at all. Same arrangement, for the same reason, as rtl/pfb/pfb_bank.sv.
(* cdc_primitive = "beamformer_weight_plane", cdc_src_clk = "cfg_clk", cdc_dst_clk = "core_clk", cdc_width = "32", cdc_stages = "SYNC_STAGES" *)
module beamformer
  import fxp_pkg::*;
  import stream_pkg::*;
  import beamformer_pkg::*;
#(
    // SPEC 7.5 geometry.
    parameter int unsigned N_ANT    = 8,
    parameter int unsigned N_BEAMS  = 4,

    // Engine parallelism. BIN_PAR bins per beat; BEAM_PAR beams per cycle.
    // BEAM_PAR must divide N_BEAMS and the quotient must be a power of two.
    parameter int unsigned BIN_PAR  = 1,
    parameter int unsigned BEAM_PAR = 4,

    // Dot-product construction; see rtl/beamformer/bf_dot.sv.
    parameter int unsigned MULT_PIPE_STAGES = 4,
    parameter string       MULT_VARIANT     = "MULT4",
    parameter int unsigned ADD_REG_EVERY    = 1,

    // SPEC 5 metadata geometry. The two DATA widths are DERIVED, not
    // parameters: they are the payload contracts of section 1 and nothing else
    // may be put in them.
    parameter int unsigned STREAM_ID_W = 2,
    parameter int unsigned SEQ_W       = 16,
    parameter int unsigned USER_W      = 4,

    // Flip-flops per synchronizer chain in the weight crossing.
    parameter int unsigned SYNC_STAGES = 2,

    // Telemetry counter width (SPEC 9).
    parameter int unsigned TELEM_COUNT_W = 32,

    // DERIVED. Never override: a port width must be a parameter expression and
    // SystemVerilog gives a port list no view of a localparam, so the SPEC 5
    // layout arithmetic is repeated here once per interface.
    // stream_pkg::stream_payload_w() remains the normative statement of it and
    // the elaboration checks below compare the two — an override, or a change to
    // the field order, fails at time 0 rather than silently mis-slicing every
    // beat.
    parameter int unsigned S_PAYLOAD_W =
        BIN_PAR * N_ANT * 2 * fxp_pkg::FXP_SAMPLE_W +
        2 + STREAM_ID_W + SEQ_W + USER_W,
    parameter int unsigned M_PAYLOAD_W =
        BIN_PAR * BEAM_PAR * 2 * fxp_pkg::FXP_SAMPLE_W +
        2 + STREAM_ID_W + SEQ_W + USER_W
) (
    // ---- core (datapath) domain ---------------------------------------------
    input  wire                     core_clk,
    input  wire                     core_rst_n,

    // ---- configuration domain: weight programming ---------------------------
    input  wire                     cfg_clk,
    input  wire                     cfg_rst_n,
    input  wire                     cfg_wr_valid,
    output wire                     cfg_wr_ready,
    input  wire                     cfg_wr_bank,
    input  wire [$clog2(N_BEAMS*N_ANT)-1:0] cfg_wr_addr,
    input  wire [2*FXP_SAMPLE_W-1:0]        cfg_wr_data,
    input  wire                     cfg_swap_req,
    output wire                     cfg_swap_busy,
    output wire                     cfg_swap_overrun,
    output wire                     cfg_active_bank,
    output wire                     cfg_swap_pending,
    output wire                     cfg_wr_reject,

    // ---- SPEC 5 stream, slave side (section 1) ------------------------------
    input  wire                     s_valid,
    output wire                     s_ready,
    input  wire [S_PAYLOAD_W-1:0]   s_payload,

    // ---- SPEC 5 stream, master side (section 1) -----------------------------
    output wire                     m_valid,
    input  wire                     m_ready,
    output wire [M_PAYLOAD_W-1:0]   m_payload,

    // ---- telemetry (SPEC 9) --------------------------------------------------
    input  wire                     telem_clear,
    input  wire                     telem_snapshot,
    output wire fxp_flags_t         sat_sticky,
    output wire                     sat_any,
    output wire [TELEM_COUNT_W-1:0] sat_event_count,
    output wire [TELEM_COUNT_W-1:0] sat_event_snap,
    output wire [TELEM_COUNT_W-1:0] frame_count,
    output wire [TELEM_COUNT_W-1:0] frame_snap,

    // ---- status --------------------------------------------------------------
    output wire                     core_active_bank,
    output wire                     core_swap_pending,

    // ---- reported throughput (SPEC 7.5; see section 2) -----------------------
    // Read back through the register plane's weight window. Every one of these
    // is derived from the elaboration parameters, so a build cannot report a
    // throughput it does not have.
    output wire [7:0]               tput_n_ant,
    output wire [7:0]               tput_n_beams,
    output wire [7:0]               tput_bin_par,
    output wire [7:0]               tput_beam_par,
    output wire [7:0]               tput_beam_mux,
    output wire [15:0]              tput_beam_bins_per_cycle
);

  // ---------------------------------------------------------------------------
  // Geometry
  //
  // `uint_t` is FULLY QUALIFIED throughout. This module imports fxp_pkg,
  // stream_pkg and beamformer_pkg, and the first two both declare a type of that
  // name: an unqualified use is ambiguous under IEEE 1800 26.3 and Quartus
  // rejects it (DECISIONS.md, issue #10 decision 13).
  // ---------------------------------------------------------------------------
  localparam int unsigned PAIR_W   = 2 * FXP_SAMPLE_W;                     // 32
  localparam int unsigned ROW_W    = N_ANT * PAIR_W;      // one beam's weights
  localparam int unsigned VEC_W    = N_ANT * PAIR_W;      // one bin's samples

  // Width of the exact accumulator bf_dot exports. Named here so the named
  // sinks on that port have a width, and computed from the package rather than
  // repeated as arithmetic.
  localparam int unsigned DOT_ACC_W = int'(bf_acc_w(bf_uint_t'(N_ANT)));

  // Index width for a beam row of the weight bank. At least 1: a zero-width
  // index is not a legal declaration even when the only legal value is zero.
  localparam int unsigned ROW_IDX_W = (N_BEAMS <= 1) ? 1 : $clog2(N_BEAMS);

  localparam int unsigned S_DATA_W = int'(bf_in_data_w(bf_uint_t'(BIN_PAR),
                                                       bf_uint_t'(N_ANT)));
  localparam int unsigned M_DATA_W = int'(bf_out_data_w(bf_uint_t'(BIN_PAR),
                                                        bf_uint_t'(BEAM_PAR)));
  localparam int unsigned META_W   = STREAM_FLAG_W + STREAM_ID_W + SEQ_W +
                                     USER_W;

  localparam int unsigned BEAM_MUX = int'(bf_beam_mux(bf_uint_t'(N_BEAMS),
                                                      bf_uint_t'(BEAM_PAR)));
  localparam int unsigned GRP_W    = int'(bf_grp_w(bf_uint_t'(BEAM_MUX)));
  localparam int unsigned SEQ_SH   = int'(bf_seq_shift(bf_uint_t'(BEAM_MUX)));

  localparam int unsigned DOT_LAT  =
      int'(bf_dot_lat(bf_uint_t'(N_ANT), bf_uint_t'(MULT_PIPE_STAGES),
                      bf_uint_t'(ADD_REG_EVERY)));
  localparam int unsigned LAT_CYCLES =
      int'(bf_lat_cycles(bf_uint_t'(N_ANT), bf_uint_t'(MULT_PIPE_STAGES),
                         bf_uint_t'(ADD_REG_EVERY)));
  localparam int unsigned INFLIGHT =
      int'(bf_inflight_beats(bf_uint_t'(N_ANT), bf_uint_t'(MULT_PIPE_STAGES),
                             bf_uint_t'(ADD_REG_EVERY)));

  // Output elastic buffer depth == credit count. INFLIGHT covers the beats the
  // pipeline can be holding; the +BEAM_MUX covers the groups of one admitted
  // beat that have not been issued yet; the +2 is what sustains one beat per
  // cycle against the one-cycle registered ready, exactly as
  // rtl/stream/stream_pipe.sv argues it.
  localparam int unsigned OUT_DEPTH = INFLIGHT + BEAM_MUX + 2;
  localparam int unsigned CRED_W    = $clog2(OUT_DEPTH + 1);

  localparam stream_geom_t S_GEOM = stream_geom(stream_pkg::uint_t'(S_DATA_W),
                                                stream_pkg::uint_t'(STREAM_ID_W),
                                                stream_pkg::uint_t'(SEQ_W),
                                                stream_pkg::uint_t'(USER_W));
  localparam stream_geom_t M_GEOM = stream_geom(stream_pkg::uint_t'(M_DATA_W),
                                                stream_pkg::uint_t'(STREAM_ID_W),
                                                stream_pkg::uint_t'(SEQ_W),
                                                stream_pkg::uint_t'(USER_W));

`ifndef SYNTHESIS
  initial begin
    if (N_ANT < 1 || N_ANT > int'(bf_max_antennas())) begin
      $fatal(1, "beamformer: N_ANT=%0d outside [1, %0d]", N_ANT, bf_max_antennas());
    end
    if (N_BEAMS < 1 || N_BEAMS > int'(bf_max_beams())) begin
      $fatal(1, "beamformer: N_BEAMS=%0d outside [1, %0d]", N_BEAMS, bf_max_beams());
    end
    if (BIN_PAR < 1 || BIN_PAR > int'(bf_max_bin_par())) begin
      $fatal(1, "beamformer: BIN_PAR=%0d outside [1, %0d]", BIN_PAR, bf_max_bin_par());
    end
    if (BEAM_PAR < 1 || BEAM_PAR > int'(bf_max_beam_par())) begin
      $fatal(1, "beamformer: BEAM_PAR=%0d outside [1, %0d]",
             BEAM_PAR, bf_max_beam_par());
    end
    if (BEAM_PAR > N_BEAMS) begin
      $fatal(1, "beamformer: BEAM_PAR=%0d exceeds N_BEAMS=%0d", BEAM_PAR, N_BEAMS);
    end
    // Time multiplexing must divide exactly and must be a power of two. Both are
    // section 2's contract; the second is what makes seq_out = {seq_in, group}.
    if ((BEAM_PAR * BEAM_MUX) != N_BEAMS) begin
      $fatal(1, "beamformer: BEAM_PAR=%0d does not divide N_BEAMS=%0d",
             BEAM_PAR, N_BEAMS);
    end
    if (!bf_is_pow2(bf_uint_t'(BEAM_MUX))) begin
      $fatal(1, "beamformer: the beam time-multiplex factor N_BEAMS/BEAM_PAR=%0d is not a power of two",
             BEAM_MUX);
    end
    // The sequence field must have room for the group index it now carries in
    // its low bits, or two different input beats would produce the same output
    // sequence number and the SPEC 5 loss/ordering checks would stop working.
    if (SEQ_W <= SEQ_SH) begin
      $fatal(1, "beamformer: SEQ_W=%0d cannot carry a %0d-bit beam group index",
             SEQ_W, SEQ_SH);
    end
    if (USER_W < GRP_W) begin
      $fatal(1, "beamformer: USER_W=%0d cannot carry a %0d-bit beam group index",
             USER_W, GRP_W);
    end
    if (!stream_geom_ok(S_GEOM) || !stream_geom_ok(M_GEOM)) begin
      $fatal(1, "beamformer: stream geometry {in data=%0d out data=%0d id=%0d seq=%0d user=%0d} is outside the stream_pkg bounds — a wider beat needs stream_pkg::STREAM_MAX_DATA_W raised",
             S_DATA_W, M_DATA_W, STREAM_ID_W, SEQ_W, USER_W);
    end
    if (int'(stream_payload_w(S_GEOM)) != S_PAYLOAD_W) begin
      $fatal(1, "beamformer: stream_payload_w()=%0d but the S_PAYLOAD_W port width is %0d",
             int'(stream_payload_w(S_GEOM)), S_PAYLOAD_W);
    end
    if (int'(stream_payload_w(M_GEOM)) != M_PAYLOAD_W) begin
      $fatal(1, "beamformer: stream_payload_w()=%0d but the M_PAYLOAD_W port width is %0d",
             int'(stream_payload_w(M_GEOM)), M_PAYLOAD_W);
    end
    if (S_PAYLOAD_W != int'(S_DATA_W) + int'(META_W)) begin
      $fatal(1, "beamformer: input payload %0d != data %0d + metadata %0d",
             S_PAYLOAD_W, S_DATA_W, META_W);
    end
    if (M_PAYLOAD_W != int'(M_DATA_W) + int'(META_W)) begin
      $fatal(1, "beamformer: output payload %0d != data %0d + metadata %0d",
             M_PAYLOAD_W, M_DATA_W, META_W);
    end
    // The block's advertised latency must equal what it builds: one hold
    // register plus the dot product. The metadata path is DOT_LAT stages long
    // because it is formed at issue, i.e. downstream of the hold register, and
    // an edit to either side alone shifts every beam sample away from its
    // metadata — which the sequence-matched scoreboard would report as a
    // baffling content failure rather than as an alignment one.
    if (LAT_CYCLES != 1 + DOT_LAT) begin
      $fatal(1, "beamformer: bf_lat_cycles()=%0d but the block builds 1 + %0d stages",
             LAT_CYCLES, DOT_LAT);
    end
    if (INFLIGHT < LAT_CYCLES) begin
      $fatal(1, "beamformer: in-flight bound %0d is below the latency %0d",
             INFLIGHT, LAT_CYCLES);
    end
  end
`endif

  // ---------------------------------------------------------------------------
  // Input decode
  // ---------------------------------------------------------------------------
  stream_fields_t s_fields;
  assign s_fields = stream_unpack(S_GEOM, stream_payload_t'(s_payload));

  logic [META_W-1:0] s_meta;
  assign s_meta = {s_fields.sof, s_fields.eof,
                   s_fields.stream_id[STREAM_ID_W-1:0],
                   s_fields.seq[SEQ_W-1:0],
                   s_fields.user[USER_W-1:0]};

  // ---------------------------------------------------------------------------
  // Slave side: the credit gate and the hold register.
  //
  // The ONLY backward-facing logic in the block, and `s_ready` is a flip-flop
  // whose input depends on nothing outside this module (SPEC 5).
  // ---------------------------------------------------------------------------
  logic [CRED_W-1:0] credits_q, credits_d;
  logic              rdy_q,     rdy_d;

  logic admit;     // an input beat enters the hold register this cycle
  logic issue;     // a beam group is issued into the engine this cycle
  logic release_;  // an output beat leaves the elastic buffer this cycle

  // The held beat and the group counter. `hold_v_q` is the only reset state in
  // the front end besides the credit counter; the data register free-runs.
  logic                hold_v_q;
  logic [S_DATA_W-1:0] hold_data_q;
  logic [META_W-1:0]   hold_meta_q;
  logic [GRP_W-1:0]    grp_q;

  logic             grp_last;
  logic             hold_free;
  logic             hold_v_d;
  logic [GRP_W-1:0] grp_d;

  assign grp_last = (grp_q == GRP_W'(BEAM_MUX - 1));

  // The engine consumes one group per cycle unconditionally while a beat is
  // held: nothing downstream can stop it (section 3).
  assign issue = hold_v_q;

  // The hold register frees on the cycle the last group is issued. A beat can
  // therefore be admitted every cycle when BEAM_MUX == 1, and every BEAM_MUX
  // cycles otherwise, which is the throughput statement of section 2.
  assign hold_free = !hold_v_q || (issue && grp_last);

  assign admit = rdy_q && s_valid;

  always_comb begin
    // BEAM_MUX credits are reserved per admitted beat and returned one per
    // delivered output beat; see section 3 for why the reservation is
    // all-or-nothing.
    if (admit && release_)       credits_d = credits_q - CRED_W'(BEAM_MUX) +
                                             CRED_W'(1);
    else if (admit)              credits_d = credits_q - CRED_W'(BEAM_MUX);
    else if (release_)           credits_d = credits_q + CRED_W'(1);
    else                         credits_d = credits_q;

    hold_v_d = admit ? 1'b1 : (hold_free ? 1'b0 : hold_v_q);
    grp_d    = issue ? (grp_last ? GRP_W'(0) : (grp_q + GRP_W'(1))) : grp_q;

    // Registered ready, and it looks at the NEXT cycle's hold state, not this
    // one's. That distinction is the whole correctness argument for the
    // multiplexed case: `s_ready` is sampled by the source on the cycle AFTER
    // it is computed, so a ready derived from the current hold state would
    // admit a beat on top of one whose later groups have not been issued yet
    // and overwrite it. With BEAM_MUX == 1 both readings coincide, which is why
    // the defect would be invisible in the un-multiplexed configuration — and
    // is why the test elaborates a multiplexed instance.
    //
    // Both terms are this module's own state, so there is no combinational path
    // from m_ready to s_ready at all (SPEC 5).
    rdy_d = (credits_d >= CRED_W'(BEAM_MUX)) &&
            (!hold_v_d || (grp_d == GRP_W'(BEAM_MUX - 1)));
  end

  always_ff @(posedge core_clk) begin
    if (!core_rst_n) begin
      credits_q <= CRED_W'(OUT_DEPTH);
      rdy_q     <= 1'b0;
      hold_v_q  <= 1'b0;
      grp_q     <= '0;
    end else begin
      credits_q <= credits_d;
      rdy_q     <= rdy_d;
      hold_v_q  <= hold_v_d;
      grp_q     <= grp_d;
    end
  end

  // Free-running: no reset on the datapath hold (SPEC 23). Its contents are
  // don't-care while hold_v_q is low.
  always_ff @(posedge core_clk) begin
    if (admit) begin
      hold_data_q <= s_fields.data[S_DATA_W-1:0];
      hold_meta_q <= s_meta;
    end
  end

  assign s_ready = rdy_q;

  // The held beat's metadata, decoded once. Declared here rather than beside the
  // output assembly because the weight bank's swap point (below) reads `in_sof`,
  // and the swap has to be aligned to the issue of the held beat rather than to
  // the admission of the next one.
  logic                   in_sof, in_eof;
  logic [STREAM_ID_W-1:0] in_id;
  logic [SEQ_W-1:0]       in_seq;

  assign in_sof = hold_meta_q[META_W-1];
  assign in_eof = hold_meta_q[META_W-2];
  assign in_id  = hold_meta_q[SEQ_W+USER_W +: STREAM_ID_W];
  assign in_seq = hold_meta_q[USER_W +: SEQ_W];

  // ---------------------------------------------------------------------------
  // Weights: one bank for the whole matrix, swapped when the FIRST BEAM GROUP of
  // a start-of-frame beat is ISSUED (section 5).
  //
  // THE SWAP POINT IS THE ISSUE, NOT THE ADMISSION, and the difference is a real
  // defect rather than a stylistic choice. With BEAM_MUX > 1 a new beat is
  // admitted on the SAME CYCLE as the LAST group of the previous beat is issued
  // — that is precisely what `hold_free` allows and what sustains one beat every
  // BEAM_MUX cycles. Driving the bank's beat/sof from the admission therefore
  // swaps the matrix one cycle early, and the previous frame's final beat gets
  // its last BEAM_PAR beams computed with the NEXT frame's weights: a frame that
  // is beamformed with two different calibration solutions, in beams nobody is
  // looking at, on one beat per frame.
  //
  // It was found by the swap pass of sim/tests/test_beamformer.cpp, on the
  // multiplexed engine only, and it is invisible at BEAM_MUX = 1 because
  // admission and issue coincide there — which is exactly why the verification
  // top elaborates a multiplexed instance alongside the reference one.
  //
  // Aligning the swap to the issue also makes the property STATEABLE: the bank
  // in use changes on the cycle the datapath first reads it for the new frame,
  // which is what coeff_bank_checker's a_coeff_swap_at_sof asserts.
  // ---------------------------------------------------------------------------
  logic w_swap_beat, w_swap_sof;
  assign w_swap_beat = issue && (grp_q == GRP_W'(0));
  assign w_swap_sof  = in_sof;

  logic [N_BEAMS*N_ANT*PAIR_W-1:0] w_all;

  weight_bank #(
      .N_BEAMS           (N_BEAMS),
      .N_ANT             (N_ANT),
      .SYNC_STAGES       (SYNC_STAGES),
      .ALLOW_UNSAFE_SWAP (1'b0)
  ) u_weights (
      .cfg_clk          (cfg_clk),
      .cfg_rst_n        (cfg_rst_n),
      .cfg_wr_valid     (cfg_wr_valid),
      .cfg_wr_ready     (cfg_wr_ready),
      .cfg_wr_bank      (cfg_wr_bank),
      .cfg_wr_addr      (cfg_wr_addr),
      .cfg_wr_data      (cfg_wr_data),
      .cfg_swap_req     (cfg_swap_req),
      .cfg_swap_busy    (cfg_swap_busy),
      .cfg_swap_overrun (cfg_swap_overrun),
      .cfg_active_bank  (cfg_active_bank),
      .cfg_swap_pending (cfg_swap_pending),
      .cfg_wr_reject    (cfg_wr_reject),
      .core_clk         (core_clk),
      .core_rst_n       (core_rst_n),
      .core_beat        (w_swap_beat),
      .core_sof         (w_swap_sof),
      .core_active_bank (core_active_bank),
      .core_swap_pending(core_swap_pending),
      .w_o              (w_all)
  );

  // A row view of the flat bank, so a beam row is an array index rather than a
  // computed part-select. The bank is beam-major (weight_bank section 1), so
  // w_rows[b] IS beam b's N_ANT weights and the reshape is a rename.
  logic [N_BEAMS-1:0][ROW_W-1:0] w_rows;
  assign w_rows = w_all;

  // The BEAM_PAR weight rows this cycle's group needs. When BEAM_MUX == 1 this
  // is the whole bank and the mux disappears entirely.
  logic [BEAM_PAR-1:0][ROW_W-1:0] w_grp;

  for (genvar k = 0; k < int'(BEAM_PAR); k++) begin : g_wsel
    if (BEAM_MUX == 1) begin : g_direct
      assign w_grp[k] = w_rows[k];
    end else begin : g_muxed
      logic [ROW_IDX_W-1:0] row_idx;
      assign row_idx = ROW_IDX_W'(grp_q) * ROW_IDX_W'(BEAM_PAR) +
                       ROW_IDX_W'(k);
      assign w_grp[k] = w_rows[row_idx];
    end
  end

  // ---------------------------------------------------------------------------
  // The engine: BIN_PAR x BEAM_PAR dot products
  //
  // Bin j's antenna vector is shared by every beam; beam k's weight row is
  // shared by every bin. That sharing is the whole reason the matrix is cheaper
  // than BIN_PAR*BEAM_PAR independent dot products would be to feed.
  // ---------------------------------------------------------------------------
  logic [BEAM_PAR-1:0][BIN_PAR-1:0][PAIR_W-1:0] dot_y;
  logic [BEAM_PAR-1:0][BIN_PAR-1:0]             dot_sat_pos;
  logic [BEAM_PAR-1:0][BIN_PAR-1:0]             dot_sat_neg;
  logic [BEAM_PAR*BIN_PAR-1:0]                  dot_valid_all;

  for (genvar j = 0; j < int'(BIN_PAR); j++) begin : g_bin
    logic [VEC_W-1:0] xvec;
    assign xvec = hold_data_q[j*VEC_W +: VEC_W];

    for (genvar k = 0; k < int'(BEAM_PAR); k++) begin : g_beam
      logic         v_jk;
      fxp_complex_t y_jk;
      fxp_flags_t   fre_jk, fim_jk;

      // Named sinks rather than `()` (PINCONNECTEMPTY). The summary overflow bit
      // is recomputed across every dot product at once below, and the exact
      // accumulator port exists for issue #13 rather than for this block.
      logic                        ovf_unused;
      logic signed [DOT_ACC_W-1:0] acc_re_unused, acc_im_unused;

      bf_dot #(
          .N_ANT            (N_ANT),
          .MULT_PIPE_STAGES (MULT_PIPE_STAGES),
          .MULT_VARIANT     (MULT_VARIANT),
          .ADD_REG_EVERY    (ADD_REG_EVERY)
      ) u_dot (
          .clk       (core_clk),
          .rst_n     (core_rst_n),
          .valid_in  (issue),
          .x         (xvec),
          .w         (w_grp[k]),
          .valid_out (v_jk),
          .y         (y_jk),
          .flags_re  (fre_jk),
          .flags_im  (fim_jk),
          .ovf       (ovf_unused),
          .acc_re    (acc_re_unused),
          .acc_im    (acc_im_unused)
      );

      assign dot_y[k][j]                    = y_jk;
      assign dot_sat_pos[k][j]              = fre_jk.sat_pos | fim_jk.sat_pos;
      assign dot_sat_neg[k][j]              = fre_jk.sat_neg | fim_jk.sat_neg;
      assign dot_valid_all[k*BIN_PAR + j]   = v_jk;
    end
  end

  logic dot_valid;
  assign dot_valid = dot_valid_all[0];

  // ---------------------------------------------------------------------------
  // Metadata alignment: formed at ISSUE, delayed DOT_LAT cycles (section 4)
  // ---------------------------------------------------------------------------
  logic [META_W-1:0] issue_meta;
  logic [SEQ_W-1:0]  out_seq;

  // seq_out = {seq_in, group}. SEQ_SH is 0 when BEAM_MUX == 1, so this is the
  // identity in the un-multiplexed case.
  assign out_seq = (SEQ_SH == 0)
                     ? in_seq
                     : SEQ_W'((in_seq << SEQ_SH) | SEQ_W'(grp_q));

  assign issue_meta = {in_sof && (grp_q == GRP_W'(0)),  // sof on the first group
                       in_eof && grp_last,              // eof on the last group
                       in_id,
                       out_seq,
                       USER_W'(grp_q)};                 // user IS the beam group

  logic [DOT_LAT:0][META_W-1:0] meta_ch;
  assign meta_ch[0] = issue_meta;

  for (genvar s = 0; s < int'(DOT_LAT); s++) begin : g_meta
    logic [META_W-1:0] m_q;
    always_ff @(posedge core_clk) begin
      m_q <= meta_ch[s];
    end
    assign meta_ch[s+1] = m_q;
  end

  logic [META_W-1:0] out_meta;
  assign out_meta = meta_ch[DOT_LAT];

  // ---------------------------------------------------------------------------
  // Output assembly
  // ---------------------------------------------------------------------------
  stream_fields_t out_fields;
  always_comb begin
    out_fields           = '0;
    out_fields.data      = STREAM_MAX_DATA_W'(dot_y);
    out_fields.sof       = out_meta[META_W-1];
    out_fields.eof       = out_meta[META_W-2];
    out_fields.stream_id = STREAM_MAX_ID_W'(out_meta[SEQ_W+USER_W +: STREAM_ID_W]);
    out_fields.seq       = STREAM_MAX_SEQ_W'(out_meta[USER_W +: SEQ_W]);
    out_fields.user      = STREAM_MAX_USER_W'(out_meta[0 +: USER_W]);
  end

  logic [M_PAYLOAD_W-1:0] out_payload;
  assign out_payload = M_PAYLOAD_W'(stream_pack(M_GEOM, out_fields));

  logic out_buf_ready;

  // Named sinks rather than `()` (PINCONNECTEMPTY). Occupancy is exported by the
  // buffer for credit schemes; this block runs its own credit counter, and
  // beamformer_assertions compares the two obligations directly.
  logic [$clog2(OUT_DEPTH+1)-1:0] out_occ_unused;
  logic [TELEM_COUNT_W-1:0]       sat_live_unused;
  logic                           sat_snapv_unused, sat_wrapp_unused,
                                  sat_wrapped_unused;
  logic                           frm_snapv_unused, frm_wrapp_unused,
                                  frm_wrapped_unused;

  stream_elastic_buffer #(
      .PAYLOAD_W   (M_PAYLOAD_W),
      .DEPTH       (OUT_DEPTH),
      .DATA_W      (M_DATA_W),
      .STREAM_ID_W (STREAM_ID_W),
      .SEQ_W       (SEQ_W),
      .USER_W      (USER_W)
  ) u_out (
      .clk       (core_clk),
      .rst_n     (core_rst_n),
      .s_valid   (dot_valid),
      .s_ready   (out_buf_ready),
      .s_payload (out_payload),
      .m_valid   (m_valid),
      .m_ready   (m_ready),
      .m_payload (m_payload),
      .occupancy (out_occ_unused)
  );

  assign release_ = m_valid && m_ready;

  // ---------------------------------------------------------------------------
  // Telemetry (SPEC 9, issue #8 primitives)
  // ---------------------------------------------------------------------------
  fxp_flags_t merged_flags;
  assign merged_flags = '{sat_pos: |dot_sat_pos, sat_neg: |dot_sat_neg};

  fxp_sticky_flags #(
      .COUNT_W (TELEM_COUNT_W)
  ) u_sat (
      .clk          (core_clk),
      .rst_n        (core_rst_n),
      .clear        (telem_clear),
      .valid        (dot_valid),
      .flags_in     (merged_flags),
      .flags_sticky (sat_sticky),
      .any_sticky   (sat_any),
      .event_count  (sat_event_count)
  );

  perf_counter #(
      .WIDTH    (TELEM_COUNT_W),
      .INCR_W   (1),
      .SATURATE (1'b1)          // a health counter must never read small
  ) u_sat_cnt (
      .clk        (core_clk),
      .rst_n      (core_rst_n),
      .enable     (1'b1),
      .event_i    (dot_valid && fxp_flags_any(merged_flags)),
      .incr       (1'b1),
      .clear      (telem_clear),
      .snapshot   (telem_snapshot),
      .count      (sat_live_unused),
      .snap       (sat_event_snap),
      .snap_valid (sat_snapv_unused),
      .wrap_pulse (sat_wrapp_unused),
      .wrapped    (sat_wrapped_unused)
  );

  perf_counter #(
      .WIDTH    (TELEM_COUNT_W),
      .INCR_W   (1),
      .SATURATE (1'b0)          // traffic counter: the difference of two reads
  ) u_frame_cnt (               //                 is the quantity anyone wants
      .clk        (core_clk),
      .rst_n      (core_rst_n),
      .enable     (1'b1),
      .event_i    (dot_valid && out_fields.eof),
      .incr       (1'b1),
      .clear      (telem_clear),
      .snapshot   (telem_snapshot),
      .count      (frame_count),
      .snap       (frame_snap),
      .snap_valid (frm_snapv_unused),
      .wrap_pulse (frm_wrapp_unused),
      .wrapped    (frm_wrapped_unused)
  );

  // ---------------------------------------------------------------------------
  // Reported throughput (SPEC 7.5; section 2)
  // ---------------------------------------------------------------------------
  assign tput_n_ant               = 8'(N_ANT);
  assign tput_n_beams             = 8'(N_BEAMS);
  assign tput_bin_par             = 8'(BIN_PAR);
  assign tput_beam_par            = 8'(BEAM_PAR);
  assign tput_beam_mux            = 8'(BEAM_MUX);
  assign tput_beam_bins_per_cycle = 16'(BIN_PAR * BEAM_PAR);

  // ---------------------------------------------------------------------------
  // SPEC 14 property set for the block. Instantiated here rather than bound from
  // a test, so the credit argument of section 3 and the multiplex rate of
  // section 2 are checked in every build that uses this module rather than only
  // in the test that thought to attach a checker.
  // ---------------------------------------------------------------------------
`ifndef SYNTHESIS
  beamformer_assertions #(
      .N_DOT     (BEAM_PAR * BIN_PAR),
      .OUT_DEPTH (OUT_DEPTH),
      .CRED_W    (CRED_W),
      .BEAM_MUX  (BEAM_MUX),
      .GRP_W     (GRP_W)
  ) u_chk (
      .clk           (core_clk),
      .rst_n         (core_rst_n),
      .admit         (admit),
      .issue         (issue),
      .s_valid       (s_valid),
      .s_ready       (s_ready),
      .credits       (credits_q),
      .hold_valid    (hold_v_q),
      .grp           (grp_q),
      .dot_valid_all (dot_valid_all),
      .out_valid     (dot_valid),
      .out_buf_ready (out_buf_ready)
  );
`endif

endmodule : beamformer

`default_nettype wire
