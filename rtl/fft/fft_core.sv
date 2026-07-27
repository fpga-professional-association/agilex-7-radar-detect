// -----------------------------------------------------------------------------
// fft_core — the FFT_SIZE-point transform: SAMPLES_PER_CYCLE radix-2^2 SDF lanes
// and the decimation-in-time merge that reassembles them.
//
// This is the arithmetic of SPEC 7.2 with no stream protocol attached: a
// valid-tagged, fixed-latency, gap-tolerant pipeline. rtl/fft/streaming_fft.sv
// wraps it in the SPEC 5 interface, owns the frame tracking and the elastic
// boundary, and optionally reorders its output. Splitting the two is what makes
// the calibration project (quartus/calibration/fft_core_calib.qsf) a measurement
// of the transform rather than of a FIFO.
//
// -----------------------------------------------------------------------------
// Beat layout (NORMATIVE — the C++ model and the vectors use the same)
// -----------------------------------------------------------------------------
// INPUT   beat t, slot p  =  x[SPC*t + p]
//         i.e. the samples of a beat are in time order, so lane p is exactly the
//         subsequence x[SPC*n + p] and the decimation-in-time split costs no
//         memory and no wiring — it is how the samples already arrive.
//
// OUTPUT  beat j, slot 0  =  X[m]         m = bitrev_{N_LANE}(j)
//         beat j, slot 1  =  X[m + N/2]
//         i.e. two bins half a spectrum apart, in bit-reversed beat order. With
//         rtl/fft/fft_reorder.sv ahead of the output the beat order becomes
//         natural (beat j carries X[j] and X[j + N/2]); the SLOT relation is the
//         same either way, because the reorder permutes beats and never moves a
//         sample between lanes. That is not an accident — it is why the split
//         and the merge were arranged this way round. See streaming_fft.
//
// -----------------------------------------------------------------------------
// Position tags and warmth
// -----------------------------------------------------------------------------
// `idx_in` is the beat's position within its frame, 0..M-1, supplied by the
// wrapper from the frame's start-of-frame. It travels with the data and is what
// every sub-stage reads its control out of (fft_pkg section 3). `idx_out` is the
// output beat's position within ITS frame, and streaming_fft asserts that it is
// zero exactly when the delayed start-of-frame arrives — which is what makes the
// latency arithmetic in fft_pkg a checked fact rather than a comment.
//
// `warm_out` marks output beats whose delay feedbacks were full when they were
// computed. The first fft_core_latency() beats after reset are not: an SDF path
// necessarily emits its fill before it emits a transform.
//
// -----------------------------------------------------------------------------
// Saturation flags (SPEC 6 "overflow flags", SPEC 9 telemetry)
// -----------------------------------------------------------------------------
// One fxp_sticky_flags per BUTTERFLY SUB-STAGE of the whole transform — the same
// index the scaling schedule uses — fed by every quantisation site that belongs
// to that sub-stage: the butterfly in each lane, and the twiddle multiplier that
// closes the sub-stage's group. Sticky rather than pulsed, so a saturation on
// beat 3 of a frame is still readable when the frame ends, and cleared
// explicitly by `flags_clear`.
//
// The per-stage granularity is the point. "The FFT overflowed" is not actionable;
// "sub-stage 4 overflowed and nothing before it did" says the scaling schedule
// needs its shift moved one stage earlier, which is the decision the flags exist
// to inform.
//
// Lint contract: clean under `verilator --lint-only --Wall` with no waiver.
// -----------------------------------------------------------------------------

`default_nettype none

module fft_core
  import fxp_pkg::*;
  import fft_pkg::*;
#(
    parameter int unsigned FFT_SIZE          = 64,
    parameter int unsigned SAMPLES_PER_CYCLE = 2,

    // One bit per butterfly sub-stage: lane sub-stages 0..N_LANE-1, then merge
    // level L at index N_LANE+L. 1 = shift right one place (see fft_pkg 4).
    parameter int unsigned SCALE_SCHED       = 32'hFFFF_FFFF,

    parameter string       TW_VARIANT        = "MULT4",
    parameter int unsigned TW_PIPE           = 4,
    parameter int unsigned TW_ROM_OUT_REG    = 1,
    parameter string       MEM_STYLE         = "DEFAULT",
    parameter string       TW_STYLE          = "AUTO",

    // Width of the per-stage saturation-event counters.
    parameter int unsigned FLAG_COUNT_W      = 32
) (
    input  wire                clk,
    input  wire                rst_n,

    // Synchronous clear of every sticky flag and every event counter.
    input  wire                flags_clear,

    input  wire                vld_in,
    input  wire [SAMPLES_PER_CYCLE*32-1:0] din,
    input  wire [$clog2(FFT_SIZE/SAMPLES_PER_CYCLE)-1:0] idx_in,

    output wire                vld_out,
    output wire [SAMPLES_PER_CYCLE*32-1:0] dout,
    output wire [$clog2(FFT_SIZE/SAMPLES_PER_CYCLE)-1:0] idx_out,
    output wire                warm_out,

    // Per-sub-stage sticky saturation, {sat_pos, sat_neg}. Index g is the same g
    // the scaling schedule indexes.
    output wire [$clog2(FFT_SIZE)-1:0][1:0]  stage_flags,
    output wire                              any_ovf,
    output wire [FLAG_COUNT_W-1:0]           ovf_events
);

  // ---------------------------------------------------------------------------
  // Geometry
  // ---------------------------------------------------------------------------
  localparam int unsigned P      = SAMPLES_PER_CYCLE;
  localparam int unsigned M      = FFT_SIZE / P;
  localparam int unsigned N_LANE = $clog2(M);
  localparam int unsigned LEVELS = $clog2(P);
  localparam int unsigned NSTAGE = N_LANE + LEVELS;
  localparam int unsigned CPLX_W = 32;

`ifndef SYNTHESIS
  initial begin
    if (!fft_size_ok(fft_uint_t'(FFT_SIZE), fft_uint_t'(P))) begin
      $fatal(1, "fft_core: FFT_SIZE=%0d / SAMPLES_PER_CYCLE=%0d is not a legal geometry",
             FFT_SIZE, P);
    end
    if (!fft_spc_supported(fft_uint_t'(P))) begin
      $fatal(1, "fft_core: SAMPLES_PER_CYCLE=%0d is not verified by issue #11 (1 or 2 are)",
             P);
    end
    if (NSTAGE != int'(fft_total_stages(fft_uint_t'(FFT_SIZE)))) begin
      $fatal(1, "fft_core: %0d sub-stages built, fft_total_stages(%0d)=%0d",
             NSTAGE, FFT_SIZE, fft_total_stages(fft_uint_t'(FFT_SIZE)));
    end
    if (CPLX_W != $bits(fxp_complex_t)) begin
      $fatal(1, "fft_core: complex sample is %0d bits, the beat layout assumes %0d",
             $bits(fxp_complex_t), CPLX_W);
    end
  end
`endif

  // ---------------------------------------------------------------------------
  // Lanes
  // ---------------------------------------------------------------------------
  logic [P-1:0]              lane_vld;
  logic [P-1:0][CPLX_W-1:0]  lane_data;
  logic [P-1:0][N_LANE-1:0]  lane_idx;
  logic [P-1:0]              lane_warm;

  // Per-lane, per-sub-stage flag sites.
  logic [P-1:0][N_LANE-1:0][1:0] lane_bf_f, lane_tw_f;
  logic [P-1:0][N_LANE-1:0]      lane_bf_v, lane_tw_v;

  for (genvar p = 0; p < int'(P); p++) begin : g_lane
    fxp_complex_t l_din, l_dout;
    logic         l_vld, l_warm;
    logic [N_LANE-1:0] l_idx;
    logic [N_LANE-1:0][1:0] l_bf_f, l_tw_f;
    logic [N_LANE-1:0]      l_bf_v, l_tw_v;

    assign l_din = fxp_complex_t'(din[p*CPLX_W +: CPLX_W]);

    fft_sdf_path #(
        .N_LANE         (N_LANE),
        .SCALE_SCHED    (SCALE_SCHED),
        .TW_VARIANT     (TW_VARIANT),
        .TW_PIPE        (TW_PIPE),
        .TW_ROM_OUT_REG (TW_ROM_OUT_REG),
        .MEM_STYLE      (MEM_STYLE),
        .TW_STYLE       (TW_STYLE)
    ) u_path (
        .clk            (clk),
        .rst_n          (rst_n),
        .vld_in         (vld_in),
        .din            (l_din),
        .idx_in         (idx_in),
        .warm_in        (1'b1),
        .vld_out        (l_vld),
        .dout           (l_dout),
        .idx_out        (l_idx),
        .warm_out       (l_warm),
        .bf_flags       (l_bf_f),
        .bf_flags_valid (l_bf_v),
        .tw_flags       (l_tw_f),
        .tw_flags_valid (l_tw_v)
    );

    assign lane_vld[p]   = l_vld;
    assign lane_data[p]  = CPLX_W'(l_dout);
    assign lane_idx[p]   = l_idx;
    assign lane_warm[p]  = l_warm;
    assign lane_bf_f[p]  = l_bf_f;
    assign lane_bf_v[p]  = l_bf_v;
    assign lane_tw_f[p]  = l_tw_f;
    assign lane_tw_v[p]  = l_tw_v;
  end

  // ---------------------------------------------------------------------------
  // Merge
  // ---------------------------------------------------------------------------
  logic                     out_vld, out_warm;
  logic [N_LANE-1:0]        out_idx;
  logic [P-1:0][CPLX_W-1:0] out_data;

  // Merge-level flag sites. Sized to LEVELS, which is zero for P = 1; a
  // zero-width bus is not portable, so the arrays are sized to at least one
  // element and the extra is tied off and never read.
  localparam int unsigned LVL_ARR = (LEVELS == 0) ? 1 : LEVELS;
  logic [LVL_ARR-1:0][1:0] lvl_bf_f, lvl_tw_f;
  logic [LVL_ARR-1:0]      lvl_bf_v, lvl_tw_v;

  if (P == 1) begin : g_no_merge
    // One lane: the transform is already complete and its output beat holds one
    // sample. Nothing to merge, and LEVELS = 0 so no schedule bit is consumed.
    assign out_vld     = lane_vld[0];
    assign out_data[0] = lane_data[0];
    assign out_idx     = lane_idx[0];
    assign out_warm    = lane_warm[0];
    assign lvl_bf_f    = '0;
    assign lvl_bf_v    = '0;
    assign lvl_tw_f    = '0;
    assign lvl_tw_v    = '0;

    // The flag sites are declared for the merge and there is no merge here, so
    // nothing reads them. Named sinks rather than nothing, because `--Wall`
    // otherwise reports four dead signals at P = 1 — which no build reached
    // until issue #17 elaborated the pipeline at the SPEC 11 `tiny` size, where
    // SAMPLES_PER_CYCLE is 1. No functional change: the values are constant zero
    // on both sides of this assignment.
    wire [LVL_ARR-1:0][1:0] unused_lvl_f = lvl_bf_f | lvl_tw_f;
    wire [LVL_ARR-1:0]      unused_lvl_v = lvl_bf_v | lvl_tw_v;
  end else begin : g_merge
    fxp_complex_t m_lo, m_hi;
    fxp_flags_t   m_f_bf, m_f_tw;
    logic         m_v_bf, m_v_tw;

    fft_dit_merge #(
        .N_LANE         (N_LANE),
        .LEVEL          (0),
        .SHIFT          (int'(fft_shift(fft_uint_t'(SCALE_SCHED), fft_uint_t'(N_LANE)))),
        .TW_VARIANT     (TW_VARIANT),
        .TW_PIPE        (TW_PIPE),
        .TW_ROM_OUT_REG (TW_ROM_OUT_REG),
        .TW_STYLE       (TW_STYLE)
    ) u_merge (
        .clk            (clk),
        .rst_n          (rst_n),
        .vld_in         (lane_vld[0]),
        .e_in           (fxp_complex_t'(lane_data[0])),
        .o_in           (fxp_complex_t'(lane_data[1])),
        .idx_in         (lane_idx[0]),
        .warm_in        (lane_warm[0]),
        .vld_out        (out_vld),
        .y_lo           (m_lo),
        .y_hi           (m_hi),
        .idx_out        (out_idx),
        .warm_out       (out_warm),
        .flags_bf       (m_f_bf),
        .flags_bf_valid (m_v_bf),
        .flags_tw       (m_f_tw),
        .flags_tw_valid (m_v_tw)
    );

    assign out_data[0] = CPLX_W'(m_lo);
    assign out_data[1] = CPLX_W'(m_hi);
    assign lvl_bf_f[0] = m_f_bf;
    assign lvl_bf_v[0] = m_v_bf;
    assign lvl_tw_f[0] = m_f_tw;
    assign lvl_tw_v[0] = m_v_tw;

    // The two lanes are structurally identical and are driven by the same
    // valid, so they must stay in lockstep. If they ever did not, the merge
    // would silently combine two different beats.
`ifndef SYNTHESIS
    always_ff @(posedge clk) begin
      if (rst_n) begin
        a_fft_lanes_in_lockstep : assert (
            (lane_vld[0] == lane_vld[1]) &&
            (lane_idx[0] == lane_idx[1]) &&
            (lane_warm[0] == lane_warm[1]))
          else $error("fft_core: lanes are not in lockstep (vld %0b/%0b idx %0d/%0d warm %0b/%0b)",
                      lane_vld[0], lane_vld[1], lane_idx[0], lane_idx[1],
                      lane_warm[0], lane_warm[1]);
      end
    end
`endif
  end

  // ---------------------------------------------------------------------------
  // Per-sub-stage sticky saturation
  //
  // Every site that belongs to sub-stage g is folded into one (valid, flags)
  // pair before the collector: sticky-OR is associative, so folding first and
  // collecting once is exactly the same answer as one collector per site, for a
  // fraction of the flops. `ovf_events` then counts CYCLES in which some site of
  // some sub-stage saturated, which is the quantity the telemetry plane wants.
  // ---------------------------------------------------------------------------
  logic [NSTAGE-1:0][1:0]             st_flags;
  logic [NSTAGE-1:0]                  st_any;
  logic [NSTAGE-1:0][FLAG_COUNT_W-1:0] st_count;

  for (genvar g = 0; g < int'(NSTAGE); g++) begin : g_flags
    logic [1:0] site_f;
    logic       site_v;

    // Generate-if, not a run-time if: for P = 1 there are no merge levels and
    // the level index below would be out of range even though the branch could
    // never execute. Which sites a sub-stage owns is elaboration data.
    if (g < int'(N_LANE)) begin : g_lane_site
      always_comb begin
        site_f = 2'b00;
        site_v = 1'b0;
        for (int unsigned p = 0; p < P; p++) begin
          if (lane_bf_v[p][g]) begin
            site_f = site_f | lane_bf_f[p][g];
            site_v = 1'b1;
          end
          if (lane_tw_v[p][g]) begin
            site_f = site_f | lane_tw_f[p][g];
            site_v = 1'b1;
          end
        end
      end
    end else begin : g_level_site
      localparam int unsigned L = g - int'(N_LANE);
      always_comb begin
        site_f = 2'b00;
        site_v = 1'b0;
        if (lvl_bf_v[L]) begin
          site_f = site_f | lvl_bf_f[L];
          site_v = 1'b1;
        end
        if (lvl_tw_v[L]) begin
          site_f = site_f | lvl_tw_f[L];
          site_v = 1'b1;
        end
      end
    end

    fxp_flags_t collected;
    logic       any_g;
    logic [FLAG_COUNT_W-1:0] count_g;

    fxp_sticky_flags #(
        .COUNT_W (FLAG_COUNT_W)
    ) u_sticky (
        .clk          (clk),
        .rst_n        (rst_n),
        .clear        (flags_clear),
        .valid        (site_v),
        .flags_in     (fxp_flags_t'(site_f)),
        .flags_sticky (collected),
        .any_sticky   (any_g),
        .event_count  (count_g)
    );

    assign st_flags[g] = collected;
    assign st_any[g]   = any_g;
    assign st_count[g] = count_g;
  end

  // Total saturating-event count across the transform. Saturates rather than
  // wraps, for the reason fxp_sticky_flags gives: a wrapped counter can read
  // zero on a permanently saturating datapath.
  // Wide enough that the SUM cannot wrap: NSTAGE <= FFT_MAX_STAGES = 10 terms,
  // so four extra bits are more than the ceil(log2 10) the sum can carry.
  localparam int unsigned ACC_W = FLAG_COUNT_W + 4;

  logic [ACC_W-1:0]        acc_c;
  logic [FLAG_COUNT_W-1:0] total_c;

  always_comb begin
    acc_c = '0;
    for (int unsigned g = 0; g < NSTAGE; g++) begin
      acc_c = acc_c + ACC_W'(st_count[g]);
    end
    total_c = (acc_c > ACC_W'({FLAG_COUNT_W{1'b1}})) ? '1
                                                     : acc_c[FLAG_COUNT_W-1:0];
  end

  assign vld_out     = out_vld;
  assign dout        = out_data;
  assign idx_out     = out_idx;
  assign warm_out    = out_warm;
  assign stage_flags = st_flags;
  assign any_ovf     = |st_any;
  assign ovf_events  = total_c;

endmodule : fft_core

`default_nettype wire
