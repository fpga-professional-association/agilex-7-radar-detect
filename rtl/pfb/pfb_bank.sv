// -----------------------------------------------------------------------------
// pfb_bank — the polyphase FIR bank (SPEC.md 5, 7.1, 9, 23; issue #10).
//
// PHASES lanes of rtl/pfb/fir_lane.sv, TAPS taps per phase, one shared dual
// coefficient bank, a SPEC 5 stream in and out, and the SPEC 9 telemetry hooks.
// One instance per antenna; the antenna dimension is a top-level concern and
// deliberately does not appear here.
//
// -----------------------------------------------------------------------------
// 1. What the polyphase decomposition actually is
// -----------------------------------------------------------------------------
// A beat carries PHASES consecutive complex samples. Sample p of beat m is
//
//     x[m*PHASES + p]
//
// and the prototype filter h of length PHASES*TAPS is decomposed phase-wise:
//
//     h_p[k] = h[k*PHASES + p]           k = 0 .. TAPS-1
//
// so lane p is an ordinary TAPS-tap complex FIR running on the DECIMATED
// substream x_p[m] = x[m*PHASES + p]:
//
//     y_p[m] = sum_k h_p[k] * x_p[m-k]
//
// and beat m of the output carries y_0[m] .. y_{PHASES-1}[m]. That is the
// critically-decimated polyphase front end a channelizer feeds its DFT with, and
// it is NOT the same thing as one PHASES*TAPS-tap filter evaluated at PHASES
// samples per cycle — the lanes do not share history. model/cpp/pfb/pfb_model.hpp
// and model/python/pfb_model.py implement exactly this, and
// scripts/generate_coefficients.py writes the coefficients already decomposed,
// phase-major, so no consumer has to re-derive the mapping.
//
// -----------------------------------------------------------------------------
// 2. Flow control: elastic at the boundary, fixed latency inside
// -----------------------------------------------------------------------------
// SPEC 23: "Break ready/valid feedback with elastic buffers", and "keep pipeline
// stages latency-insensitive". SPEC 5: "No combinational ready loop may cross
// more than one module boundary."
//
// The interior of this block is a FIXED-LATENCY VALID PIPELINE with no ready at
// all: putting a ready chain into a lane would land `m_ready` on the clock
// enable of every DSP register in the design. Backpressure is absorbed at the
// boundary by a credit scheme identical in shape to rtl/stream/stream_pipe.sv:
//
//     s_ready is a flip-flop whose input depends only on this block's own credit
//     counter. A beat is admitted only when a slot is reserved in the output
//     elastic buffer, so the buffer can never overflow and the interior never
//     has to stall.
//
// The credit count is pfb_pkg::pfb_inflight_beats() + 2. The +2 is what sustains
// one beat per cycle against the one-cycle registered ready, exactly as
// stream_pipe argues it.
//
// A SYSTOLIC lane permanently retains TAPS-1 credits: its first TAPS-1 admitted
// beats produce no output (the cascade warm-up, see fir_lane section 3), so
// those credits are never returned. The count above covers that by construction
// — pfb_inflight_beats() includes the beat-measured latency — which is why the
// warm-up is a throughput non-event rather than a deadlock.
//
// -----------------------------------------------------------------------------
// 3. Metadata alignment — beats first, then cycles
// -----------------------------------------------------------------------------
// SPEC 7.1: "Valid metadata must travel with the corresponding samples."
//
// A lane's latency is partly beats and partly cycles (pfb_pkg, "Beats and
// cycles"), so the metadata path is two delays in series and in that order:
//
//     LAT_BEATS stages advanced by `admit`      (delay_line, en = admit)
//     LAT_CYCLES free-running register stages
//
// Collapsing those into one delay in either unit is correct only on a gapless
// stream, and is the defect this structure exists to prevent. The
// random-backpressure pass in sim/tests/test_pfb_bank.cpp is what makes it
// falsifiable.
//
// Only the metadata travels this path — sof, eof, stream_id, seq, user. The data
// field is REPLACED by the lane outputs, so nothing carries PHASES*32 bits of
// sample through a delay line that would only throw them away.
//
// -----------------------------------------------------------------------------
// 4. Coefficients and the frame-boundary swap
// -----------------------------------------------------------------------------
// One rtl/pfb/coeff_bank.sv holds every phase's coefficients, twice. Its swap
// point is the admitted start-of-frame beat — the same `admit`/`sof` pair the
// lanes see, taken at the same point in the pipeline — so the frame whose first
// sample entered under bank B is filtered entirely under bank B. The frames
// before and after a swap are checked against their own coefficient set in
// sim/tests/test_pfb_bank.cpp, with no corrupted beat permitted at the seam.
//
// -----------------------------------------------------------------------------
// 5. Telemetry (SPEC 9, issue #8 primitives)
// -----------------------------------------------------------------------------
// The lanes' saturation flags are merged into one direction-resolved pair and
// fed to rtl/common/fxp_sticky_flags.sv (sticky, plus a saturating event count)
// and to rtl/common/perf_counter.sv (snapshot-coherent, so the register plane
// reads a set of counters that describe one instant). Output frames are counted
// the same way. Nothing here invents a counter.
//
// Lint contract: clean under `verilator --lint-only --Wall` with no waiver.
// -----------------------------------------------------------------------------

`default_nettype none

// (* cdc_primitive *) — this module has a configuration clock and a core clock,
// so the SPEC 8 inventory must be able to classify it. It is a COMPOSITE whose
// only crossing is the rtl/pfb/coeff_bank.sv instance below (itself a composite
// of the issue #6 primitives); the datapath does not cross domains at all. Same
// arrangement, for the same reason, as rtl/cdc/stream_cdc.sv over async_fifo.
(* cdc_primitive = "pfb_coeff_plane", cdc_src_clk = "cfg_clk", cdc_dst_clk = "core_clk", cdc_width = "32", cdc_stages = "SYNC_STAGES" *)
module pfb_bank
  import fxp_pkg::*;
  import stream_pkg::*;
  import pfb_pkg::*;
#(
    // Polyphase geometry (SPEC 11 SAMPLES_PER_CYCLE / PFB_TAPS).
    parameter int unsigned PHASES = 8,
    parameter int unsigned TAPS   = 16,

    // Lane construction; see rtl/pfb/fir_lane.sv.
    parameter int unsigned MULT_PIPE_STAGES = 4,
    parameter string       MULT_VARIANT     = "MULT4",
    parameter string       ACC_STYLE        = "TREE",
    parameter string       DELAY_STYLE      = "AUTO",

    // SPEC 5 metadata geometry. DATA_W is derived, not a parameter: it is
    // PHASES complex samples and nothing else may be put in it.
    parameter int unsigned STREAM_ID_W = 2,
    parameter int unsigned SEQ_W       = 16,
    parameter int unsigned USER_W      = 4,

    // Flip-flops per synchronizer chain in the coefficient crossing.
    parameter int unsigned SYNC_STAGES = 2,

    // Telemetry counter width (SPEC 9).
    parameter int unsigned TELEM_COUNT_W = 32,

    // DERIVED. Never override: a port width must be a parameter expression and
    // SystemVerilog has no localparam a port list can see, so the SPEC 5 layout
    // arithmetic is repeated here once. stream_pkg::stream_payload_w() remains
    // the normative statement of it and the elaboration check below compares the
    // two — an override, or a change to the field order, fails at time 0 rather
    // than silently mis-slicing every beat.
    parameter int unsigned PAYLOAD_W =
        PHASES * 2 * fxp_pkg::FXP_SAMPLE_W + 2 + STREAM_ID_W + SEQ_W + USER_W
) (
    // ---- core (datapath) domain --------------------------------------------
    input  wire                     core_clk,
    input  wire                     core_rst_n,

    // ---- configuration domain: coefficient programming ---------------------
    input  wire                     cfg_clk,
    input  wire                     cfg_rst_n,
    input  wire                     cfg_wr_valid,
    output wire                     cfg_wr_ready,
    input  wire                     cfg_wr_bank,
    input  wire [$clog2(PHASES*TAPS)-1:0] cfg_wr_addr,
    input  wire [2*FXP_SAMPLE_W-1:0]      cfg_wr_data,
    input  wire                     cfg_swap_req,
    output wire                     cfg_swap_busy,
    output wire                     cfg_swap_overrun,
    output wire                     cfg_active_bank,
    output wire                     cfg_swap_pending,
    output wire                     cfg_wr_reject,

    // ---- SPEC 5 stream, slave side -----------------------------------------
    input  wire                     s_valid,
    output wire                     s_ready,
    input  wire [PAYLOAD_W-1:0]     s_payload,

    // ---- SPEC 5 stream, master side ----------------------------------------
    output wire                     m_valid,
    input  wire                     m_ready,
    output wire [PAYLOAD_W-1:0]     m_payload,

    // ---- telemetry (SPEC 9) -------------------------------------------------
    input  wire                     telem_clear,
    input  wire                     telem_snapshot,
    output wire fxp_flags_t         sat_sticky,
    output wire                     sat_any,
    output wire [TELEM_COUNT_W-1:0] sat_event_count,
    output wire [TELEM_COUNT_W-1:0] sat_event_snap,
    output wire [TELEM_COUNT_W-1:0] frame_count,
    output wire [TELEM_COUNT_W-1:0] frame_snap,

    // ---- status -------------------------------------------------------------
    output wire                     core_active_bank,
    output wire                     core_swap_pending
);

  // ---------------------------------------------------------------------------
  // Geometry. PFB_PAYLOAD_W is a parameter-visible expression because a port
  // width must be one; every other derived width is a localparam below.
  // ---------------------------------------------------------------------------
  localparam int unsigned SAMPLE_PAIR_W = 2 * FXP_SAMPLE_W;             // 32
  localparam int unsigned DATA_W        = PHASES * SAMPLE_PAIR_W;
  localparam int unsigned META_W        = STREAM_FLAG_W + STREAM_ID_W +
                                          SEQ_W + USER_W;

  // `uint_t` is FULLY QUALIFIED here and below. This module imports fxp_pkg,
  // stream_pkg and pfb_pkg, and the first two both declare a type of that name:
  // an unqualified use is ambiguous under IEEE 1800 26.3 and Quartus rejects it
  // (see the note in rtl/packages/pfb_pkg.sv).
  localparam stream_geom_t GEOM = stream_geom(stream_pkg::uint_t'(DATA_W),
                                              stream_pkg::uint_t'(STREAM_ID_W),
                                              stream_pkg::uint_t'(SEQ_W),
                                              stream_pkg::uint_t'(USER_W));

  localparam int unsigned LAT_BEATS =
      int'(pfb_lat_beats(ACC_STYLE, pfb_uint_t'(TAPS)));
  localparam int unsigned LAT_CYCLES =
      int'(pfb_lat_cycles(ACC_STYLE, pfb_uint_t'(TAPS), pfb_uint_t'(MULT_PIPE_STAGES)));
  localparam int unsigned INFLIGHT =
      int'(pfb_inflight_beats(ACC_STYLE, pfb_uint_t'(TAPS),
                              pfb_uint_t'(MULT_PIPE_STAGES)));

  // Output elastic buffer depth == credit count. See section 2.
  localparam int unsigned OUT_DEPTH = INFLIGHT + 2;
  localparam int unsigned CRED_W    = $clog2(OUT_DEPTH + 1);

`ifndef SYNTHESIS
  initial begin
    if (PHASES < 1 || PHASES > int'(pfb_max_phases())) begin
      $fatal(1, "pfb_bank: PHASES=%0d outside [1, %0d]", PHASES, pfb_max_phases());
    end
    if (!stream_geom_ok(GEOM)) begin
      $fatal(1, "pfb_bank: stream geometry {data=%0d id=%0d seq=%0d user=%0d} is outside the stream_pkg bounds",
             DATA_W, STREAM_ID_W, SEQ_W, USER_W);
    end
    // The port width expression and the geometry must agree. They are computed
    // two different ways on purpose: the port cannot call a function, so if the
    // layout ever changes this catches the drift at time 0.
    if (int'(stream_payload_w(GEOM)) != PAYLOAD_W) begin
      $fatal(1, "pfb_bank: stream_payload_w()=%0d but the PAYLOAD_W port width is %0d",
             int'(stream_payload_w(GEOM)), PAYLOAD_W);
    end
    if (PAYLOAD_W != int'(DATA_W) + int'(META_W)) begin
      $fatal(1, "pfb_bank: payload %0d != data %0d + metadata %0d",
             PAYLOAD_W, DATA_W, META_W);
    end
  end
`endif

  // ---------------------------------------------------------------------------
  // Slave side: the credit gate. The ONLY backward-facing logic in the block.
  // ---------------------------------------------------------------------------
  logic [CRED_W-1:0] credits_q, credits_d;
  logic              rdy_q,     rdy_d;

  logic admit;     // a beat enters the datapath this cycle
  logic release_;  // a beat leaves the output buffer this cycle

  assign admit = rdy_q && s_valid;

  always_comb begin
    if (admit && !release_)      credits_d = credits_q - CRED_W'(1);
    else if (release_ && !admit) credits_d = credits_q + CRED_W'(1);
    else                         credits_d = credits_q;
    rdy_d = (credits_d != CRED_W'(0));
  end

  always_ff @(posedge core_clk) begin
    if (!core_rst_n) begin
      credits_q <= CRED_W'(OUT_DEPTH);
      rdy_q     <= 1'b0;
    end else begin
      credits_q <= credits_d;
      rdy_q     <= rdy_d;
    end
  end

  assign s_ready = rdy_q;

  // ---------------------------------------------------------------------------
  // Input decode
  // ---------------------------------------------------------------------------
  stream_fields_t s_fields;
  assign s_fields = stream_unpack(GEOM, stream_payload_t'(s_payload));

  logic [META_W-1:0] s_meta;
  assign s_meta = {s_fields.sof, s_fields.eof,
                   s_fields.stream_id[STREAM_ID_W-1:0],
                   s_fields.seq[SEQ_W-1:0],
                   s_fields.user[USER_W-1:0]};

  // ---------------------------------------------------------------------------
  // Coefficient bank. One for the whole polyphase bank; swap at the admitted
  // start-of-frame beat.
  // ---------------------------------------------------------------------------
  logic [PHASES*TAPS*SAMPLE_PAIR_W-1:0] coeff_all;

  coeff_bank #(
      .PHASES            (PHASES),
      .TAPS              (TAPS),
      .SYNC_STAGES       (SYNC_STAGES),
      .ALLOW_UNSAFE_SWAP (1'b0)
  ) u_coeff (
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
      .core_beat        (admit),
      .core_sof         (s_fields.sof),
      .core_active_bank (core_active_bank),
      .core_swap_pending(core_swap_pending),
      .coeff_o          (coeff_all)
  );

  // ---------------------------------------------------------------------------
  // The lanes
  // ---------------------------------------------------------------------------
  logic [PHASES-1:0]                    lane_valid;
  logic [PHASES-1:0][SAMPLE_PAIR_W-1:0] lane_y;
  logic [PHASES-1:0]                    lane_sat_pos;
  logic [PHASES-1:0]                    lane_sat_neg;

  for (genvar p = 0; p < int'(PHASES); p++) begin : g_lane
    fxp_complex_t x_p, y_p;
    logic         v_p;
    fxp_flags_t   fre_p, fim_p;
    // Named sink rather than `()`; the summary bit is recomputed from the
    // direction-resolved flags below, across every lane at once.
    logic         ovf_unused;

    assign x_p = fxp_complex_t'(s_fields.data[p*SAMPLE_PAIR_W +: SAMPLE_PAIR_W]);

    fir_lane #(
        .TAPS             (TAPS),
        .MULT_PIPE_STAGES (MULT_PIPE_STAGES),
        .MULT_VARIANT     (MULT_VARIANT),
        .ACC_STYLE        (ACC_STYLE),
        .DELAY_STYLE      (DELAY_STYLE)
    ) u_lane (
        .clk       (core_clk),
        .rst_n     (core_rst_n),
        .valid_in  (admit),
        .x_in      (x_p),
        .coeff     (coeff_all[p*TAPS*SAMPLE_PAIR_W +: TAPS*SAMPLE_PAIR_W]),
        .valid_out (v_p),
        .y_out     (y_p),
        .flags_re  (fre_p),
        .flags_im  (fim_p),
        .ovf       (ovf_unused)
    );

    assign lane_valid[p]   = v_p;
    assign lane_y[p]       = y_p;
    assign lane_sat_pos[p] = fre_p.sat_pos | fim_p.sat_pos;
    assign lane_sat_neg[p] = fre_p.sat_neg | fim_p.sat_neg;
  end

  // ---------------------------------------------------------------------------
  // Metadata alignment: LAT_BEATS beats, then LAT_CYCLES cycles (section 3)
  // ---------------------------------------------------------------------------
  logic [META_W-1:0] meta_beats;

  if (LAT_BEATS == 0) begin : g_no_beat_delay
    assign meta_beats = s_meta;
  end else begin : g_beat_delay
    // N_TAPS = 1, so `taps` is the same wire as `q`. Named sink; see
    // rtl/cdc/stream_cdc.sv for the convention.
    logic [META_W-1:0] meta_taps_unused;

    delay_line #(
        .WIDTH      (META_W),
        .N_TAPS     (1),
        .TAP_STRIDE (LAT_BEATS),
        .STYLE      ("AUTO")
    ) u_meta_beats (
        .clk  (core_clk),
        .en   (admit),
        .d    (s_meta),
        .taps (meta_taps_unused),
        .q    (meta_beats)
    );
  end

  logic [LAT_CYCLES:0][META_W-1:0] meta_cyc;
  assign meta_cyc[0] = meta_beats;

  for (genvar s = 0; s < int'(LAT_CYCLES); s++) begin : g_meta_cyc
    logic [META_W-1:0] m_q;
    always_ff @(posedge core_clk) begin
      m_q <= meta_cyc[s];
    end
    assign meta_cyc[s+1] = m_q;
  end

  logic [META_W-1:0] out_meta;
  assign out_meta = meta_cyc[LAT_CYCLES];

  // ---------------------------------------------------------------------------
  // Output assembly
  // ---------------------------------------------------------------------------
  logic out_valid;
  assign out_valid = lane_valid[0];

  stream_fields_t out_fields;
  always_comb begin
    out_fields           = '0;
    out_fields.data      = STREAM_MAX_DATA_W'(lane_y);
    out_fields.sof       = out_meta[META_W-1];
    out_fields.eof       = out_meta[META_W-2];
    out_fields.stream_id = STREAM_MAX_ID_W'(out_meta[SEQ_W+USER_W +: STREAM_ID_W]);
    out_fields.seq       = STREAM_MAX_SEQ_W'(out_meta[USER_W +: SEQ_W]);
    out_fields.user      = STREAM_MAX_USER_W'(out_meta[0 +: USER_W]);
  end

  logic [PAYLOAD_W-1:0] out_payload;
  assign out_payload = PAYLOAD_W'(stream_pack(GEOM, out_fields));

  logic out_buf_ready;

  // Named sinks rather than `()` (PINCONNECTEMPTY). Occupancy is exported by
  // the buffer for credit schemes; this block runs its own credit counter, and
  // pfb_bank_checker compares the two obligations directly.
  logic [$clog2(OUT_DEPTH+1)-1:0] out_occ_unused;
  logic [TELEM_COUNT_W-1:0]       sat_live_unused;
  logic                           sat_snapv_unused, sat_wrapp_unused,
                                  sat_wrapped_unused;
  logic                           frm_snapv_unused, frm_wrapp_unused,
                                  frm_wrapped_unused;

  stream_elastic_buffer #(
      .PAYLOAD_W   (PAYLOAD_W),
      .DEPTH       (OUT_DEPTH),
      .DATA_W      (DATA_W),
      .STREAM_ID_W (STREAM_ID_W),
      .SEQ_W       (SEQ_W),
      .USER_W      (USER_W)
  ) u_out (
      .clk       (core_clk),
      .rst_n     (core_rst_n),
      .s_valid   (out_valid),
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
  assign merged_flags = '{sat_pos: |lane_sat_pos, sat_neg: |lane_sat_neg};

  fxp_sticky_flags #(
      .COUNT_W (TELEM_COUNT_W)
  ) u_sat (
      .clk          (core_clk),
      .rst_n        (core_rst_n),
      .clear        (telem_clear),
      .valid        (out_valid),
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
      .event_i    (out_valid && fxp_flags_any(merged_flags)),
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
  ) u_frame_cnt (                //                 is the quantity anyone wants
      .clk        (core_clk),
      .rst_n      (core_rst_n),
      .enable     (1'b1),
      .event_i    (out_valid && out_fields.eof),
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
  // SPEC 14 property set for the block. Instantiated rather than bound, so the
  // credit argument of section 2 is checked in every build that uses this
  // module rather than only in the test that thought to attach a checker.
  // ---------------------------------------------------------------------------
`ifndef SYNTHESIS
  pfb_assertions #(
      .PHASES    (PHASES),
      .OUT_DEPTH (OUT_DEPTH),
      .CRED_W    (CRED_W)
  ) u_chk (
      .clk           (core_clk),
      .rst_n         (core_rst_n),
      .admit         (admit),
      .s_valid       (s_valid),
      .s_ready       (s_ready),
      .credits       (credits_q),
      .lane_valid    (lane_valid),
      .out_valid     (out_valid),
      .out_buf_ready (out_buf_ready)
  );
`endif

endmodule : pfb_bank

`default_nettype wire
