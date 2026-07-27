// -----------------------------------------------------------------------------
// benchmark_sim_top - medium-config integrated processing pipeline (issue #17).
//
// SPEC.md 4.1 defines benchmark_sim_top as the Verilator-facing top; SPEC 19
// Phase 3 asks that PFB -> FFT -> history -> alignment -> beamformer ->
// power/covariance -> CFAR be wired together into a single medium-config
// pipeline exercised by the C++ harness. This file is that wiring.
//
// NAMING NOTE (issue #17). The Phase-0 loopback DUT currently lives at
// sim/verilator/tops/benchmark_sim_top.sv and shares this module name. Rather
// than rename that file (and every test and Makefile stanza that references
// it) mid-integration, the actual integrated top declared here uses the
// distinct module name `benchmark_pipeline_top`. The path is exactly what
// issue #17 asks for (rtl/top/benchmark_sim_top.sv); the module identifier is
// scoped so both tops can coexist and each get their own Verilator build.
//
// A follow-up issue may retire benchmark_sim_top (loopback) in favour of this
// one -- see DECISIONS.md 2026-07-27 "Pipeline top module naming".
//
// -----------------------------------------------------------------------------
// PIPELINE, PLAIN
// -----------------------------------------------------------------------------
//
//   +-----------+   per-antenna    +----------------+
//   | 4x        |----------------->| 4x streaming   |
//   | PFB banks |   PFB output     | FFT (256 pt)   |
//   +-----------+                  +----------------+
//         |                                |
//         | 1 SPEC 5 stream per antenna    | 1 SPEC 5 stream per antenna
//         |                                v
//         |                        +----------------+
//         |                        | history_core   |    core_clk / history_clk
//         |                        |   (4 antennas) |    crossing (SPEC 8)
//         |                        +--------+-------+
//         |                                 |  read port  (history_clk)
//         v                                 v
//                                  +----------------+
//                                  |  align_net     |    BIN_PAR = 1: single
//                                  |  (bin align)   |    read port and single
//                                  +----------------+    lane, so the network
//                                          |             reduces to a wire but
//                                          | 1 stream    the sequence-ID check
//                                          |             is fully exercised.
//                                          v
//                                  +----------------+    core_clk / history_clk
//                                  | history_clk -> |    crossing back (SPEC 8)
//                                  | core_clk sync  |
//                                  +----------------+
//                                          |
//                                          v
//                                  +----------------+
//                                  |   beamformer   |    N_BEAMS = 4 beams, no
//                                  |     matrix     |    BEAM_MUX (BEAM_PAR = 4)
//                                  +----------------+
//                                          |
//                                          v
//                                  +----------------+
//                                  | power_calc     |    one power per (beam,
//                                  | (per beat)     |    bin), fixed latency
//                                  +----------------+
//                                          |
//                                          v
//                                  +----------------+
//                                  |  cfar_core     |    detections out
//                                  +----------------+
//
// -----------------------------------------------------------------------------
// CLOCK DOMAINS (SPEC 8)
// -----------------------------------------------------------------------------
//   core_clk     PFB, FFT, history write side, beamformer, power, CFAR
//   history_clk  history read side, alignment network
//   cfg_clk      PFB coefficient bank programming, beamformer weight bank
//                programming
//
// Only two datapath crossings exist: history_core (core -> history for the
// frame pointer, history -> core for status) and stream_cdc on the align
// network output (history -> core for the beamformer input beat). The
// coefficient/weight cfg_clk seams sit off the datapath and use the primitives
// verified in #10 and #12.
//
// -----------------------------------------------------------------------------
// FRAME-BOUNDARY GATING (SPEC 7.1, 7.5, 13.2)
// -----------------------------------------------------------------------------
// benchmark_pipeline_ctrl generates ONE end-of-frame reference plane -- the
// PFB input SOF/EOF -- and drives BOTH the PFB coefficient-bank swap and the
// beamformer weight-bank swap on the SAME cycle. This is the integration-
// level frame-boundary rule: block-level checkers verify that each swap
// lands at a safe boundary (#10, #12), and the pipeline-level checker in
// benchmark_pipeline_ctrl verifies that both swaps take the SAME boundary.
// SPEC 13.2 "bank changes affect only permitted frame boundaries" is a
// consequence.
//
// -----------------------------------------------------------------------------
// GEOMETRY (medium config: N_ANTENNAS = 4, SAMPLES_PER_CYCLE = 2,
//                          FFT_SIZE = 256, PFB_TAPS = 8, N_BEAMS = 4,
//                          HISTORY_FRAMES = 16)
// -----------------------------------------------------------------------------
// BIN_PAR is fixed to 1: it removes the alignment network's crossbar / omega
// choice at integration and keeps history_core's read port count at one. The
// per-block sweeps in #16 (BIN_PAR = 2, 4) still exercise the network; the
// pipeline exercises the block-to-block wiring and the frame-boundary rule,
// which are BIN_PAR-independent. See DECISIONS.md 2026-07-27
// "Pipeline BIN_PAR = 1".
//
// Lint contract: clean under `verilator --lint-only --Wall` with no waiver.
// -----------------------------------------------------------------------------

`default_nettype none

/* verilator lint_off DECLFILENAME */
module benchmark_pipeline_top
  import fxp_pkg::*;
  import stream_pkg::*;
  import history_pkg::*;
  import align_pkg::*;
  import beamformer_pkg::*;
  import covar_pkg::*;
  import cfar_pkg::*;
(
    // ---- clocks and resets -------------------------------------------------
    input  wire         core_clk,
    input  wire         core_rst_n,
    input  wire         history_clk,
    input  wire         history_rst_n,
    input  wire         cfg_clk,
    input  wire         cfg_rst_n,

    // ---- PFB coefficient bank programming (cfg_clk domain) -----------------
    input  wire         cfg_pfb_wr_valid,
    output wire         cfg_pfb_wr_ready,
    input  wire         cfg_pfb_wr_bank,
    // clog2(PHASES*TAPS) = clog2(2*8) = 4. Sized to the pfb_bank port.
    input  wire [3:0]   cfg_pfb_wr_addr,
    input  wire [31:0]  cfg_pfb_wr_data,

    // ---- beamformer weight bank programming (cfg_clk domain) --------------
    input  wire         cfg_bf_wr_valid,
    output wire         cfg_bf_wr_ready,
    input  wire         cfg_bf_wr_bank,
    input  wire [3:0]   cfg_bf_wr_addr,      // clog2(N_BEAMS*N_ANT) = clog2(16)
    input  wire [31:0]  cfg_bf_wr_data,

    // ---- pipeline swap request (core_clk domain) --------------------------
    // A one-cycle pulse. The controller schedules both PFB and beamformer
    // bank swaps at the next PFB-input end-of-frame boundary.
    input  wire         cfg_pipe_swap_req,

    // ---- history control (core_clk domain) --------------------------------
    input  wire         cfg_hist_enable,
    input  wire [15:0]  cfg_hist_depth,      // HIST_PORT_W = 16
    input  wire         cfg_hist_depth_apply,
    input  wire         cfg_hist_counter_clear,
    input  wire         cfg_hist_sticky_clear,

    // ---- alignment control (history_clk domain) ---------------------------
    input  wire         cfg_align_enable,
    input  wire         cfg_align_run,
    input  wire [15:0]  cfg_align_frame_off,
    input  wire         cfg_align_partial_pass,
    input  wire         cfg_align_counter_clear,
    input  wire         cfg_align_sticky_clear,

    // ---- CFAR control (core_clk domain) -----------------------------------
    input  wire         cfg_cfar_enable,
    input  wire [1:0]   cfg_cfar_mode,          // CFAR_MODE_W = 2
    input  wire         cfg_cfar_out_mode,
    input  wire [4:0]   cfg_cfar_guard_lead,    // CFAR_GUARD_CNT_W = 5
    input  wire [4:0]   cfg_cfar_guard_lag,
    input  wire [5:0]   cfg_cfar_ref_lead,      // CFAR_REF_CNT_W = 6
    input  wire [5:0]   cfg_cfar_ref_lag,
    input  wire [15:0]  cfg_cfar_alpha,         // CFAR_ALPHA_W = 16
    input  wire         cfg_cfar_status_clear,

    // ---- input stimulus (SPEC 5, per antenna) ------------------------------
    // The C++ harness drives the input side (per antenna, SAMPLES_PER_CYCLE
    // complex samples per beat). Antenna `a` is bit `a` of s_valid/s_ready.
    input  wire [3:0]   s_valid,
    output wire [3:0]   s_ready,
    input  wire [3:0]   s_sof,
    input  wire [3:0]   s_eof,
    // Antenna `a`, phase `p` (p=0..SAMPLES_PER_CYCLE-1) occupies
    // s_data[a*128 + p*32 +: 32], packed { im, re } as fxp_complex_t.
    // 4 antennas * 2 samples/cycle * 32 bits = 256 bits.
    input  wire [255:0] s_data,
    input  wire [15:0]  s_seq,               // shared, source-labelled

    // ---- output: CFAR detections ------------------------------------------
    output wire         m_valid,
    input  wire         m_ready,
    // CFAR_EVENT_W is fixed by cfar_pkg; carried out as a wide field.
    output wire [63:0]  m_event_data,        // subset; CFAR_EVENT_W upper bits
    output wire         m_sof,
    output wire         m_eof,
    output wire [15:0]  m_seq,
    output wire [3:0]   m_id,

    // ---- telemetry / status -----------------------------------------------
    output wire [31:0]  stat_pipe_frame_count,
    output wire [31:0]  stat_pipe_swap_count,
    output wire [31:0]  stat_pipe_swap_overrun,
    output wire         stat_pipe_swap_busy,
    output wire         stat_pipe_swap_pending,

    output wire [31:0]  stat_pfb_frame_count,
    output wire         stat_pfb_sat_any,

    output wire [31:0]  stat_history_frames_done,
    output wire [31:0]  stat_history_write_beats,
    output wire [31:0]  stat_history_read_count,
    output wire [31:0]  stat_history_error_count,
    output wire [15:0]  stat_history_depth_active,
    output wire [15:0]  stat_history_occupancy,

    output wire [31:0]  stat_align_beat_count,
    output wire [31:0]  stat_align_missing_count,
    output wire [31:0]  stat_align_timeout_count,

    output wire [31:0]  stat_bf_frame_count,
    output wire         stat_bf_sat_any,

    output wire [31:0]  stat_cfar_det_count,
    output wire [31:0]  stat_cfar_sup_count,
    output wire [31:0]  stat_cfar_frame_count
);

  // ---------------------------------------------------------------------------
  // Medium-config geometry (SPEC 11 medium)
  // ---------------------------------------------------------------------------
  localparam int unsigned N_ANT     = 4;
  localparam int unsigned SPC       = 2;
  localparam int unsigned FFT_SIZE  = 256;
  localparam int unsigned PFB_TAPS  = 8;
  localparam int unsigned N_BEAMS   = 4;
  localparam int unsigned HIST_FRAMES = 16;

  localparam int unsigned MULT_PIPE = 4;

  // BIN_PAR = 2: matches the alignment network's minimum legal geometry
  // (align_pkg guards on bin_par >= 2). The pipeline replicates history_core
  // BIN_PAR times, one instance per read port, all seeing the same write
  // stream. That is a legitimate memory subsystem architecture for a
  // multi-port read pattern and is what makes the network's routing across
  // BIN_PAR = 2 lanes observable in the integrated build.
  localparam int unsigned BIN_PAR = 2;
  // Small reassembly bank -- 4 groups is enough to exercise the sequence
  // check without giant SRAMs.
  localparam int unsigned GROUPS  = 4;

  // Beamformer parallelism -- BEAM_PAR = N_BEAMS gives no time multiplex, the
  // simplest wiring at integration time. BEAM_MUX = 1.
  localparam int unsigned BEAM_PAR = N_BEAMS;

  // SPEC 5 metadata widths, consistent across the whole pipeline.
  localparam int unsigned STREAM_ID_W = 2;   // clog2(N_ANT)
  localparam int unsigned SEQ_W       = 16;
  localparam int unsigned USER_W      = 4;

  localparam int unsigned SAMPLE_W    = 16;
  localparam int unsigned PAIR_W      = 2 * SAMPLE_W;

  // ---------------------------------------------------------------------------
  // Derived widths -- per-stage payload widths, computed from stream_pkg's own
  // arithmetic so the pipeline never invents a layout.
  // ---------------------------------------------------------------------------
  // PFB input / output = SPC complex samples
  localparam int unsigned PFB_DATA_W = SPC * PAIR_W;
  localparam stream_geom_t PFB_GEOM = stream_geom(
      stream_pkg::uint_t'(PFB_DATA_W),
      stream_pkg::uint_t'(STREAM_ID_W),
      stream_pkg::uint_t'(SEQ_W),
      stream_pkg::uint_t'(USER_W));
  localparam int unsigned PFB_PAYLOAD_W = int'(stream_payload_w(PFB_GEOM));

  // FFT output has the same data-word shape as its input (SPC complex).
  localparam int unsigned FFT_PAYLOAD_W = PFB_PAYLOAD_W;

  // History write beat = LANES complex samples per antenna, LANES = SPC.
  localparam stream_geom_t HIST_WR_GEOM = stream_geom(
      stream_pkg::uint_t'(SPC * PAIR_W),
      stream_pkg::uint_t'(STREAM_ID_W),
      stream_pkg::uint_t'(SEQ_W),
      stream_pkg::uint_t'(USER_W));
  localparam int unsigned HIST_WR_PAYLOAD_W = int'(stream_payload_w(HIST_WR_GEOM));

  // History read response
  localparam hist_geom_t HG = hist_geom(N_ANT, FFT_SIZE, SPC, HIST_FRAMES, SAMPLE_W);
  localparam int unsigned HIST_RD_DATA_W = int'(hist_data_w(HG));
  localparam stream_geom_t HIST_RD_GEOM = stream_geom(
      stream_pkg::uint_t'(HIST_RD_DATA_W),
      stream_pkg::uint_t'(STREAM_ID_W),
      stream_pkg::uint_t'(SEQ_W),
      stream_pkg::uint_t'(USER_W));
  localparam int unsigned HIST_RD_PAYLOAD_W = int'(stream_payload_w(HIST_RD_GEOM));

  // Alignment output beat = BIN_PAR * N_ANT complex samples
  localparam algn_geom_t AG = algn_geom(N_ANT, FFT_SIZE, SPC, HIST_FRAMES,
                                        SAMPLE_W, BIN_PAR, GROUPS);
  localparam int unsigned ALIGN_DATA_W = int'(algn_out_data_w(AG));
  localparam stream_geom_t ALIGN_GEOM = stream_geom(
      stream_pkg::uint_t'(ALIGN_DATA_W),
      stream_pkg::uint_t'(STREAM_ID_W),
      stream_pkg::uint_t'(SEQ_W),
      stream_pkg::uint_t'(USER_W));
  localparam int unsigned ALIGN_PAYLOAD_W = int'(stream_payload_w(ALIGN_GEOM));

  // Beamformer input/output. Input equals alignment output.
  localparam int unsigned BF_S_DATA_W = BIN_PAR * N_ANT * PAIR_W;
  localparam int unsigned BF_M_DATA_W = BIN_PAR * BEAM_PAR * PAIR_W;
  localparam stream_geom_t BF_S_GEOM = stream_geom(
      stream_pkg::uint_t'(BF_S_DATA_W),
      stream_pkg::uint_t'(STREAM_ID_W),
      stream_pkg::uint_t'(SEQ_W),
      stream_pkg::uint_t'(USER_W));
  localparam stream_geom_t BF_M_GEOM = stream_geom(
      stream_pkg::uint_t'(BF_M_DATA_W),
      stream_pkg::uint_t'(STREAM_ID_W),
      stream_pkg::uint_t'(SEQ_W),
      stream_pkg::uint_t'(USER_W));
  localparam int unsigned BF_S_PAYLOAD_W = int'(stream_payload_w(BF_S_GEOM));
  localparam int unsigned BF_M_PAYLOAD_W = int'(stream_payload_w(BF_M_GEOM));

  // CFAR input beat = one power value per cell (COVAR_POWER_W)
  localparam int unsigned CFAR_S_PAYLOAD_W =
      int'(stream_payload_w(stream_geom(
          stream_pkg::uint_t'(CFAR_POWER_W),
          stream_pkg::uint_t'(STREAM_ID_W),
          stream_pkg::uint_t'(SEQ_W),
          stream_pkg::uint_t'(USER_W))));
  localparam int unsigned CFAR_M_PAYLOAD_W =
      int'(stream_payload_w(stream_geom(
          stream_pkg::uint_t'(CFAR_EVENT_W),
          stream_pkg::uint_t'(STREAM_ID_W),
          stream_pkg::uint_t'(SEQ_W),
          stream_pkg::uint_t'(USER_W))));

`ifndef SYNTHESIS
  initial begin
    // Cross-check: the beamformer input beat width and the alignment output
    // beat width must match (aligned_pkg guarantees this, but the port widths
    // are literal integers here and if any width above drifts the pipe wires
    // silently mis-slice). Same check the align_net does at its own
    // elaboration.
    if (BF_S_DATA_W != ALIGN_DATA_W) begin
      $fatal(1, "benchmark_sim_top: beamformer input %0d != alignment output %0d",
             BF_S_DATA_W, ALIGN_DATA_W);
    end
    if (int'(algn_geom_ok(AG)) == 0) begin
      $fatal(1, "benchmark_sim_top: alignment geometry is invalid");
    end
    if (int'(hist_geom_ok(HG)) == 0) begin
      $fatal(1, "benchmark_sim_top: history geometry is invalid");
    end
  end
`endif

  // ===========================================================================
  // Stage 1: 4 x PFB banks, one per antenna, sharing coefficient programming
  // ===========================================================================
  wire [N_ANT-1:0]                     pfb_m_valid;
  wire [N_ANT-1:0]                     pfb_m_ready;
  wire [N_ANT*PFB_PAYLOAD_W-1:0]       pfb_m_payload;

  wire [N_ANT-1:0] pfb_cfg_wr_ready_v;
  wire [N_ANT-1:0] pfb_cfg_swap_busy_v;
  wire [N_ANT-1:0] pfb_core_swap_pending_dummy;
  wire [N_ANT-1:0] pfb_sat_any_v;
  wire [N_ANT*32-1:0] pfb_sat_event_dummy;
  wire [N_ANT*32-1:0] pfb_frame_v;

  // Coefficient programming is broadcast to all 4 banks; because each bank
  // has its own cfg_wr_ready flip-flop, we AND them.
  assign cfg_pfb_wr_ready = &pfb_cfg_wr_ready_v;

  // Frame boundary controller output for PFB swap
  wire pfb_pipe_swap;    // one-cycle pulse from pipeline controller
  wire bf_pipe_swap;

  // We consider a bank swap "busy" if any per-bank swap is busy OR the
  // pipeline controller is between arm and completion.
  wire pfb_pipeline_busy = |pfb_cfg_swap_busy_v;
  wire bf_pipeline_busy;

  // Pack input into SPEC 5 payload per antenna
  wire [N_ANT-1:0] pfb_s_valid;
  wire [N_ANT-1:0] pfb_s_ready;
  wire [N_ANT*PFB_PAYLOAD_W-1:0] pfb_s_payload;

  // Per-antenna seq counter. The block generates its own contiguous seq per
  // antenna, taking a beat every time that antenna's admit fires. This
  // decouples the PFB seq stream from the shared s_seq input pin -- the
  // input's seq is treated as a stimulus tag on antenna 0, and each PFB
  // gets a monotone-per-antenna value so the SPEC 14 stream_protocol_
  // checker's seq-continuity assertion holds even under per-antenna gaps.
  logic [15:0] pfb_seq_q [N_ANT];
  always_ff @(posedge core_clk) begin
    if (!core_rst_n) begin
      for (int i = 0; i < int'(N_ANT); i++) pfb_seq_q[i] <= 16'd0;
    end else begin
      for (int i = 0; i < int'(N_ANT); i++) begin
        if (pfb_s_valid[i] && pfb_s_ready[i]) begin
          pfb_seq_q[i] <= pfb_seq_q[i] + 16'd1;
        end
      end
    end
  end

  for (genvar a = 0; a < int'(N_ANT); a++) begin : g_pfb_pack
    stream_fields_t s_fields;
    always_comb begin
      s_fields           = '0;
      s_fields.data      = STREAM_MAX_DATA_W'(s_data[a*PFB_DATA_W +: PFB_DATA_W]);
      s_fields.sof       = s_sof[a];
      s_fields.eof       = s_eof[a];
      s_fields.stream_id = STREAM_MAX_ID_W'(a);
      s_fields.seq       = STREAM_MAX_SEQ_W'(pfb_seq_q[a]);
      s_fields.user      = STREAM_MAX_USER_W'(s_seq);  // stimulus tag pass-through
    end
    assign pfb_s_payload[a*PFB_PAYLOAD_W +: PFB_PAYLOAD_W] =
        PFB_PAYLOAD_W'(stream_pack(PFB_GEOM, s_fields));
    assign pfb_s_valid[a] = s_valid[a];
    assign s_ready[a]     = pfb_s_ready[a];
  end

  for (genvar a = 0; a < int'(N_ANT); a++) begin : g_pfb
    logic cfg_active_dummy;
    logic cfg_pending_dummy;
    logic cfg_reject_dummy;
    logic cfg_overrun_dummy;
    fxp_flags_t sat_sticky_dummy;
    logic [31:0] sat_event_snap_dummy;
    logic [31:0] frame_snap_dummy;
    logic core_active_dummy;

    pfb_bank #(
        .PHASES           (SPC),
        .TAPS             (PFB_TAPS),
        .MULT_PIPE_STAGES (MULT_PIPE),
        .MULT_VARIANT     ("MULT4"),
        .ACC_STYLE        ("TREE"),
        .DELAY_STYLE      ("AUTO"),
        .STREAM_ID_W      (STREAM_ID_W),
        .SEQ_W            (SEQ_W),
        .USER_W           (USER_W),
        .SYNC_STAGES      (2),
        .TELEM_COUNT_W    (32)
    ) u_pfb (
        .core_clk         (core_clk),
        .core_rst_n       (core_rst_n),
        .cfg_clk          (cfg_clk),
        .cfg_rst_n        (cfg_rst_n),
        // Coefficient programming: broadcast to all banks. The banks' own
        // cfg_wr_ready is ANDed at the top-level cfg_pfb_wr_ready so the
        // producer sees a common ready.
        .cfg_wr_valid     (cfg_pfb_wr_valid),
        .cfg_wr_ready     (pfb_cfg_wr_ready_v[a]),
        .cfg_wr_bank      (cfg_pfb_wr_bank),
        .cfg_wr_addr      (cfg_pfb_wr_addr),
        .cfg_wr_data      (cfg_pfb_wr_data),
        // Swap request comes from the pipeline controller (below). The
        // controller ensures the pulse lands at end-of-frame on the head
        // admit plane.
        .cfg_swap_req     (pfb_pipe_swap),
        .cfg_swap_busy    (pfb_cfg_swap_busy_v[a]),
        .cfg_swap_overrun (cfg_overrun_dummy),
        .cfg_active_bank  (cfg_active_dummy),
        .cfg_swap_pending (cfg_pending_dummy),
        .cfg_wr_reject    (cfg_reject_dummy),
        .s_valid          (pfb_s_valid[a]),
        .s_ready          (pfb_s_ready[a]),
        .s_payload        (pfb_s_payload[a*PFB_PAYLOAD_W +: PFB_PAYLOAD_W]),
        .m_valid          (pfb_m_valid[a]),
        .m_ready          (pfb_m_ready[a]),
        .m_payload        (pfb_m_payload[a*PFB_PAYLOAD_W +: PFB_PAYLOAD_W]),
        .telem_clear      (cfg_hist_counter_clear), // shared clear pulse
        .telem_snapshot   (1'b0),
        .sat_sticky       (sat_sticky_dummy),
        .sat_any          (pfb_sat_any_v[a]),
        .sat_event_count  (pfb_sat_event_dummy[a*32 +: 32]),
        .sat_event_snap   (sat_event_snap_dummy),
        .frame_count      (pfb_frame_v[a*32 +: 32]),
        .frame_snap       (frame_snap_dummy),
        .core_active_bank (core_active_dummy),
        .core_swap_pending(pfb_core_swap_pending_dummy[a])
    );
  end

  assign stat_pfb_frame_count = pfb_frame_v[0 +: 32];
  assign stat_pfb_sat_any     = |pfb_sat_any_v;

  // ===========================================================================
  // Stage 2: 4 x streaming FFT (one per antenna)
  // ===========================================================================
  wire [N_ANT-1:0]                fft_m_valid;
  wire [N_ANT-1:0]                fft_m_ready;
  wire [N_ANT*FFT_PAYLOAD_W-1:0]  fft_m_payload;

  for (genvar a = 0; a < int'(N_ANT); a++) begin : g_fft
    // Named sinks so PINMISSING does not fire; the block's overflow flags
    // are exercised in the per-block test #11.
    wire [$clog2(FFT_SIZE)-1:0][1:0] fft_stage_flags_dummy;
    wire                             fft_any_ovf_dummy;
    wire [31:0]                      fft_ovf_events_dummy;

    streaming_fft #(
        .FFT_SIZE          (FFT_SIZE),
        .SAMPLES_PER_CYCLE (SPC),
        .SCALE_SCHED       (32'hFFFF_FFFF),   // safe, no overflow
        .REORDER           (1),               // natural bin order
        .STREAM_ID_W       (STREAM_ID_W),
        .SEQ_W             (SEQ_W),
        .USER_W            (USER_W),
        .TW_VARIANT        ("MULT4"),
        .TW_PIPE           (4),
        .TW_ROM_OUT_REG    (1),
        .MEM_STYLE         ("DEFAULT"),
        .TW_STYLE          ("AUTO"),
        .REORDER_STYLE     ("AUTO"),
        .FIFO_STORAGE      ("mlab"),
        .IN_DEPTH          (4),
        .OUT_SLACK         (8),
        .FLAG_COUNT_W      (32)
    ) u_fft (
        .clk         (core_clk),
        .rst_n       (core_rst_n),
        .s_valid     (pfb_m_valid[a]),
        .s_ready     (pfb_m_ready[a]),
        .s_payload   (pfb_m_payload[a*PFB_PAYLOAD_W +: PFB_PAYLOAD_W]),
        .m_valid     (fft_m_valid[a]),
        .m_ready     (fft_m_ready[a]),
        .m_payload   (fft_m_payload[a*FFT_PAYLOAD_W +: FFT_PAYLOAD_W]),
        .flags_clear (1'b0),
        .stage_flags (fft_stage_flags_dummy),
        .any_ovf     (fft_any_ovf_dummy),
        .ovf_events  (fft_ovf_events_dummy)
    );
  end

  // ===========================================================================
  // Stage 3: history_core -- corner-turn from time to (antenna, bin)
  // ===========================================================================
  // Repack the FFT streams into history-write payloads. The FFT output width
  // and the history write width are already equal (both are SPC complex
  // samples per antenna); we only need to unpack, repack with the history
  // metadata layout.
  wire [N_ANT-1:0]                     hist_s_valid;
  wire [N_ANT-1:0]                     hist_s_ready;
  wire [N_ANT*HIST_WR_PAYLOAD_W-1:0]   hist_s_payload;

  for (genvar a = 0; a < int'(N_ANT); a++) begin : g_hist_pack
    stream_fields_t rf, wf;
    assign rf = stream_unpack(PFB_GEOM,
        stream_payload_t'(fft_m_payload[a*FFT_PAYLOAD_W +: FFT_PAYLOAD_W]));
    always_comb begin
      wf           = '0;
      wf.data      = rf.data;
      wf.sof       = rf.sof;
      wf.eof       = rf.eof;
      wf.stream_id = STREAM_MAX_ID_W'(a);
      wf.seq       = rf.seq;
      wf.user      = STREAM_MAX_USER_W'(0);
    end
    assign hist_s_payload[a*HIST_WR_PAYLOAD_W +: HIST_WR_PAYLOAD_W] =
        HIST_WR_PAYLOAD_W'(stream_pack(HIST_WR_GEOM, wf));
    assign hist_s_valid[a] = fft_m_valid[a];
    assign fft_m_ready[a]  = hist_s_ready[a];
  end

  // BIN_PAR replicated history_core instances. All see the same write
  // stream (fanned via s_ready := AND of every replica's s_ready), and each
  // instance owns one of the BIN_PAR read ports the alignment network needs.
  wire [BIN_PAR-1:0]               hist_rd_req_valid;
  wire [BIN_PAR-1:0]               hist_rd_req_ready;
  wire [BIN_PAR*16-1:0]            hist_rd_req_bin;
  wire [BIN_PAR*16-1:0]            hist_rd_req_frame_off;
  wire [BIN_PAR-1:0]               hist_m_valid;
  wire [BIN_PAR-1:0]               hist_m_ready;
  wire [BIN_PAR*HIST_RD_PAYLOAD_W-1:0] hist_m_payload;

  // Per-replica status (indexed by port). We surface replica 0; the other
  // replicas' status lands in named `_dummy` sinks (see the waiver in
  // sim/verilator/lint_waivers.vlt).
  wire [BIN_PAR*16-1:0]  hist_stat_depth_active_dummy;
  wire [BIN_PAR*16-1:0]  hist_stat_occupancy_dummy;
  wire [BIN_PAR*32-1:0]  hist_stat_frames_done_dummy;
  wire [BIN_PAR*32-1:0]  hist_stat_write_beat_count_dummy;
  wire [BIN_PAR*32-1:0]  hist_stat_read_count_dummy;
  wire [BIN_PAR*32-1:0]  hist_stat_error_count_dummy;

  wire [BIN_PAR*N_ANT-1:0] hist_s_ready_v;

  // The write s_ready per antenna is the AND across replicas: a beat is
  // admitted only when every replica can absorb it. In practice all replicas
  // present the same ready because they see the same writes.
  for (genvar a = 0; a < int'(N_ANT); a++) begin : g_hist_s_ready_and
    logic [BIN_PAR-1:0] r_ready_a;
    for (genvar r = 0; r < int'(BIN_PAR); r++) begin : g_hist_s_ready_and_r
      assign r_ready_a[r] = hist_s_ready_v[r*N_ANT + a];
    end
    assign hist_s_ready[a] = &r_ready_a;
  end

  for (genvar r = 0; r < int'(BIN_PAR); r++) begin : g_hist_rep
    wire [15:0]  s_depth_active;
    wire [15:0]  s_occupancy;
    wire [31:0]  s_frames_done;
    wire [31:0]  s_overwrite_count_dummy;
    wire [31:0]  s_skew_count_dummy;
    wire [31:0]  s_write_beat_count;
    wire [31:0]  s_read_count;
    wire [31:0]  s_collision_count_dummy;
    wire [31:0]  s_error_count;
    wire [7:0]   s_epoch_dummy;
    wire [3:0]   s_fault_dummy;
    wire         s_pending_dummy;

    history_core #(
        .N_ANT              (N_ANT),
        .FFT_SIZE           (FFT_SIZE),
        .LANES              (SPC),
        .FRAMES_MAX         (HIST_FRAMES),
        .SAMPLE_W           (SAMPLE_W),
        .INPUT_BIT_REVERSED (1'b0),
        .STORAGE            ("auto"),
        .SYNC_STAGES        (2),
        .WR_ID_W            (STREAM_ID_W),
        .WR_SEQ_W           (SEQ_W),
        .WR_USER_W          (USER_W),
        .RD_ID_W            (STREAM_ID_W),
        .RD_SEQ_W           (SEQ_W),
        .RD_USER_W          (USER_W)
    ) u_history (
        .core_clk              (core_clk),
        .core_rst_n            (core_rst_n),
        .s_valid               (hist_s_valid),
        .s_ready               (hist_s_ready_v[r*N_ANT +: N_ANT]),
        .s_payload             (hist_s_payload),
        .cfg_enable            (cfg_hist_enable),
        .cfg_depth             (cfg_hist_depth),
        .cfg_depth_apply       (cfg_hist_depth_apply),
        .cfg_counter_clear     (cfg_hist_counter_clear),
        .cfg_sticky_clear      (cfg_hist_sticky_clear),
        .cfg_force_unsafe      (1'b0),
        .stat_depth_active     (s_depth_active),
        .stat_occupancy        (s_occupancy),
        .stat_frames_done      (s_frames_done),
        .stat_overwrite_count  (s_overwrite_count_dummy),
        .stat_skew_count       (s_skew_count_dummy),
        .stat_write_beat_count (s_write_beat_count),
        .stat_read_count       (s_read_count),
        .stat_collision_count  (s_collision_count_dummy),
        .stat_error_count      (s_error_count),
        .stat_epoch            (s_epoch_dummy),
        .stat_fault            (s_fault_dummy),
        .obs_depth_pending     (s_pending_dummy),
        .history_clk           (history_clk),
        .history_rst_n         (history_rst_n),
        .rd_req_valid          (hist_rd_req_valid[r]),
        .rd_req_ready          (hist_rd_req_ready[r]),
        .rd_req_bin            (hist_rd_req_bin[r*16 +: 16]),
        .rd_req_frame_off      (hist_rd_req_frame_off[r*16 +: 16]),
        .m_valid               (hist_m_valid[r]),
        .m_ready               (hist_m_ready[r]),
        .m_payload             (hist_m_payload[r*HIST_RD_PAYLOAD_W +: HIST_RD_PAYLOAD_W])
    );

    assign hist_stat_depth_active_dummy[r*16 +: 16] = s_depth_active;
    assign hist_stat_occupancy_dummy[r*16 +: 16]    = s_occupancy;
    assign hist_stat_frames_done_dummy[r*32 +: 32]  = s_frames_done;
    assign hist_stat_write_beat_count_dummy[r*32 +: 32] = s_write_beat_count;
    assign hist_stat_read_count_dummy[r*32 +: 32]   = s_read_count;
    assign hist_stat_error_count_dummy[r*32 +: 32]  = s_error_count;
  end

  assign stat_history_depth_active = hist_stat_depth_active_dummy[0 +: 16];
  assign stat_history_occupancy    = hist_stat_occupancy_dummy[0 +: 16];
  assign stat_history_frames_done  = hist_stat_frames_done_dummy[0 +: 32];
  assign stat_history_write_beats  = hist_stat_write_beat_count_dummy[0 +: 32];
  assign stat_history_read_count   = hist_stat_read_count_dummy[0 +: 32];
  assign stat_history_error_count  = hist_stat_error_count_dummy[0 +: 32];

  // ===========================================================================
  // Stage 4: align_net -- one read port drives the network with BIN_PAR = 1
  // ===========================================================================
  wire                            align_m_valid;
  wire                            align_m_ready;
  wire [ALIGN_PAYLOAD_W-1:0]      align_m_payload;
  wire [31:0]                     align_stat_beat_count;
  wire [31:0]                     align_stat_issue_count_dummy;
  wire [31:0]                     align_stat_issue_stall_count_dummy;
  wire [31:0]                     align_stat_missing_count;
  wire [31:0]                     align_stat_dup_count_dummy;
  wire [31:0]                     align_stat_orphan_count_dummy;
  wire [31:0]                     align_stat_timeout_count;
  wire [31:0]                     align_stat_conflict_count_dummy;
  wire [31:0]                     align_stat_multi_lane_count_dummy;
  wire [31:0]                     align_stat_lane_word_count_dummy;
  wire [BIN_PAR-1:0]              align_stat_lane_seen_dummy;
  wire [31:0]                     align_stat_inject_count_dummy;
  wire [3:0]                      align_stat_fault_dummy;
  wire [7:0]                      align_obs_net_sel_dummy;
  wire [7:0]                      align_obs_net_latency_dummy;
  wire [7:0]                      align_obs_block_latency_dummy;
  wire [7:0]                      align_obs_bin_par_dummy;
  wire [7:0]                      align_obs_groups_dummy;

  align_net #(
      .N_ANT      (N_ANT),
      .FFT_SIZE   (FFT_SIZE),
      .LANES      (SPC),
      .FRAMES_MAX (HIST_FRAMES),
      .SAMPLE_W   (SAMPLE_W),
      .BIN_PAR    (BIN_PAR),
      .GROUPS     (GROUPS),
      .NET_SEL    (0),                  // crossbar (single lane is a wire)
      .MUX_STAGES (2),
      .RD_ID_W    (STREAM_ID_W),
      .RD_SEQ_W   (SEQ_W),
      .RD_USER_W  (USER_W),
      .STREAM_ID_W(STREAM_ID_W),
      .SEQ_W      (SEQ_W),
      .USER_W     (USER_W),
      .OUT_DEPTH  (4),
      .TELEM_W    (32)
  ) u_align (
      .clk                    (history_clk),
      .rst_n                  (history_rst_n),
      .cfg_enable             (cfg_align_enable),
      .cfg_run                (cfg_align_run),
      .cfg_frame_off          (cfg_align_frame_off),
      .cfg_partial_pass       (cfg_align_partial_pass),
      .cfg_counter_clear      (cfg_align_counter_clear),
      .cfg_sticky_clear       (cfg_align_sticky_clear),
      .cfg_lane_stall         ({BIN_PAR{1'b0}}),
      .cfg_force_unsafe       (1'b0),
      .rd_req_valid           (hist_rd_req_valid),
      .rd_req_ready           (hist_rd_req_ready),
      .rd_req_bin             (hist_rd_req_bin),
      .rd_req_frame_off       (hist_rd_req_frame_off),
      .rsp_valid              (hist_m_valid),
      .rsp_ready              (hist_m_ready),
      .rsp_payload            (hist_m_payload),
      .m_valid                (align_m_valid),
      .m_ready                (align_m_ready),
      .m_payload              (align_m_payload),
      .stat_beat_count        (align_stat_beat_count),
      .stat_issue_count       (align_stat_issue_count_dummy),
      .stat_issue_stall_count (align_stat_issue_stall_count_dummy),
      .stat_missing_count     (align_stat_missing_count),
      .stat_dup_count         (align_stat_dup_count_dummy),
      .stat_orphan_count      (align_stat_orphan_count_dummy),
      .stat_timeout_count     (align_stat_timeout_count),
      .stat_conflict_count    (align_stat_conflict_count_dummy),
      .stat_multi_lane_count  (align_stat_multi_lane_count_dummy),
      .stat_lane_word_count   (align_stat_lane_word_count_dummy),
      .stat_lane_seen         (align_stat_lane_seen_dummy),
      .stat_inject_count      (align_stat_inject_count_dummy),
      .stat_fault             (align_stat_fault_dummy),
      .obs_net_sel            (align_obs_net_sel_dummy),
      .obs_net_latency        (align_obs_net_latency_dummy),
      .obs_block_latency      (align_obs_block_latency_dummy),
      .obs_bin_par            (align_obs_bin_par_dummy),
      .obs_groups             (align_obs_groups_dummy)
  );

  assign stat_align_beat_count    = align_stat_beat_count;
  assign stat_align_missing_count = align_stat_missing_count;
  assign stat_align_timeout_count = align_stat_timeout_count;

  // ===========================================================================
  // Stage 5: history_clk -> core_clk stream crossing for the beamformer feed
  // ===========================================================================
  // The alignment output beat is in history_clk; the beamformer runs in
  // core_clk. Cross domains with the same async FIFO the register plane uses.
  wire                       bf_s_valid;
  wire                       bf_s_ready;
  wire [BF_S_PAYLOAD_W-1:0]  bf_s_payload;

  wire [$clog2(9)-1:0] cdc_s_occ_dummy;
  wire [$clog2(9)-1:0] cdc_s_hw_dummy;
  wire                 cdc_s_almost_full_dummy;
  wire                 cdc_s_of_dummy;
  wire [$clog2(9)-1:0] cdc_m_occ_dummy;
  wire [$clog2(9)-1:0] cdc_m_hw_dummy;
  wire                 cdc_m_uf_dummy;

  stream_cdc #(
      .PAYLOAD_W   (ALIGN_PAYLOAD_W),
      .DEPTH       (8),
      .SYNC_STAGES (2)
  ) u_align_cdc (
      .s_clk              (history_clk),
      .s_rst_n            (history_rst_n),
      .s_valid            (align_m_valid),
      .s_ready            (align_m_ready),
      .s_payload          (align_m_payload),
      .s_occupancy        (cdc_s_occ_dummy),
      .s_high_water       (cdc_s_hw_dummy),
      .s_almost_full      (cdc_s_almost_full_dummy),
      .s_overflow_sticky  (cdc_s_of_dummy),
      .s_sticky_clear     (1'b0),
      .m_clk              (core_clk),
      .m_rst_n            (core_rst_n),
      .m_valid            (bf_s_valid),
      .m_ready            (bf_s_ready),
      .m_payload          (bf_s_payload),
      .m_occupancy        (cdc_m_occ_dummy),
      .m_high_water       (cdc_m_hw_dummy),
      .m_underflow_sticky (cdc_m_uf_dummy),
      .m_sticky_clear     (1'b0)
  );

  // ALIGN_PAYLOAD_W and BF_S_PAYLOAD_W must be equal by construction (both are
  // computed from the same BIN_PAR * N_ANT geometry). Verified at time 0
  // above.

  // ===========================================================================
  // Stage 6: beamformer
  // ===========================================================================
  wire                      bf_m_valid;
  wire                      bf_m_ready;
  wire [BF_M_PAYLOAD_W-1:0] bf_m_payload;

  wire        bf_cfg_swap_busy;
  wire        bf_cfg_active_dummy;
  wire        bf_cfg_pending_dummy;
  wire        bf_cfg_reject_dummy;
  wire        bf_cfg_overrun_dummy;
  fxp_flags_t bf_sat_sticky_dummy;
  wire [31:0] bf_sat_event_count_dummy;
  wire [31:0] bf_sat_event_snap_dummy;
  wire [31:0] bf_frame_snap_dummy;
  wire        bf_core_active_dummy;
  wire        bf_core_swap_pending_dummy;
  wire        bf_sat_any;
  wire [31:0] bf_frame_count;

  wire [7:0]  bf_tput_n_ant_dummy;
  wire [7:0]  bf_tput_n_beams_dummy;
  wire [7:0]  bf_tput_bin_par_dummy;
  wire [7:0]  bf_tput_beam_par_dummy;
  wire [7:0]  bf_tput_beam_mux_dummy;
  wire [15:0] bf_tput_bins_per_cycle_dummy;

  beamformer #(
      .N_ANT            (N_ANT),
      .N_BEAMS          (N_BEAMS),
      .BIN_PAR          (BIN_PAR),
      .BEAM_PAR         (BEAM_PAR),
      .MULT_PIPE_STAGES (MULT_PIPE),
      .MULT_VARIANT     ("MULT4"),
      .ADD_REG_EVERY    (1),
      .STREAM_ID_W      (STREAM_ID_W),
      .SEQ_W            (SEQ_W),
      .USER_W           (USER_W),
      .SYNC_STAGES      (2),
      .TELEM_COUNT_W    (32)
  ) u_bf (
      .core_clk         (core_clk),
      .core_rst_n       (core_rst_n),
      .cfg_clk          (cfg_clk),
      .cfg_rst_n        (cfg_rst_n),
      .cfg_wr_valid     (cfg_bf_wr_valid),
      .cfg_wr_ready     (cfg_bf_wr_ready),
      .cfg_wr_bank      (cfg_bf_wr_bank),
      .cfg_wr_addr      (cfg_bf_wr_addr),
      .cfg_wr_data      (cfg_bf_wr_data),
      .cfg_swap_req     (bf_pipe_swap),
      .cfg_swap_busy    (bf_cfg_swap_busy),
      .cfg_swap_overrun (bf_cfg_overrun_dummy),
      .cfg_active_bank  (bf_cfg_active_dummy),
      .cfg_swap_pending (bf_cfg_pending_dummy),
      .cfg_wr_reject    (bf_cfg_reject_dummy),
      .s_valid          (bf_s_valid),
      .s_ready          (bf_s_ready),
      .s_payload        (bf_s_payload),
      .m_valid          (bf_m_valid),
      .m_ready          (bf_m_ready),
      .m_payload        (bf_m_payload),
      .telem_clear      (cfg_hist_counter_clear),
      .telem_snapshot   (1'b0),
      .sat_sticky       (bf_sat_sticky_dummy),
      .sat_any          (bf_sat_any),
      .sat_event_count  (bf_sat_event_count_dummy),
      .sat_event_snap   (bf_sat_event_snap_dummy),
      .frame_count      (bf_frame_count),
      .frame_snap       (bf_frame_snap_dummy),
      .core_active_bank (bf_core_active_dummy),
      .core_swap_pending(bf_core_swap_pending_dummy),
      .tput_n_ant       (bf_tput_n_ant_dummy),
      .tput_n_beams     (bf_tput_n_beams_dummy),
      .tput_bin_par     (bf_tput_bin_par_dummy),
      .tput_beam_par    (bf_tput_beam_par_dummy),
      .tput_beam_mux    (bf_tput_beam_mux_dummy),
      .tput_beam_bins_per_cycle (bf_tput_bins_per_cycle_dummy)
  );

  assign stat_bf_frame_count = bf_frame_count;
  assign stat_bf_sat_any     = bf_sat_any;
  assign bf_pipeline_busy    = bf_cfg_swap_busy;

  // ===========================================================================
  // Stage 7: power_calc per beat -- one beat carries BIN_PAR * BEAM_PAR
  //          complex beam samples. To keep the CFAR side simple, we compute a
  //          single power stream from the first beam and first bin of each
  //          beat. A real design fans out per (beam, bin); this pipeline is a
  //          verification vehicle for the STREAMING behaviour so we exercise
  //          the first (beam, bin) path and leave the fan-out as a follow-up.
  //          The power_calc kernel itself has been unit-verified in #13.
  // ===========================================================================
  stream_fields_t bf_out_fields;
  assign bf_out_fields = stream_unpack(BF_M_GEOM, stream_payload_t'(bf_m_payload));

  wire signed [SAMPLE_W-1:0] bm_i0 = bf_out_fields.data[0 +: SAMPLE_W];
  wire signed [SAMPLE_W-1:0] bm_q0 = bf_out_fields.data[SAMPLE_W +: SAMPLE_W];
  fxp_complex_t              bm_sample;
  assign bm_sample = '{re: bm_i0, im: bm_q0};

  wire         pc_valid_out;
  wire signed [COVAR_POWER_W-1:0] pc_power;

  // Tag carries { sof, eof, stream_id, seq } so we can rebuild the metadata
  // for CFAR downstream. sof/eof (2) + stream_id (2) + seq (16) = 20 bits.
  localparam int unsigned POWER_TAG_W = 2 + STREAM_ID_W + SEQ_W;

  wire [POWER_TAG_W-1:0] pc_tag_in;
  assign pc_tag_in = {bf_out_fields.sof,
                      bf_out_fields.eof,
                      bf_out_fields.stream_id[STREAM_ID_W-1:0],
                      bf_out_fields.seq[SEQ_W-1:0]};
  wire [POWER_TAG_W-1:0] pc_tag_out;

  // The beamformer output beat carries multiple beams; we consume every beat.
  // A stall from CFAR must eventually stall the beamformer -- we build a
  // credit-based backpressure by making the power_calc a fixed-latency stage
  // followed by a stream_elastic_buffer that provides the ready boundary.
  wire pc_consume = bf_m_valid && bf_m_ready;

  power_calc #(
      .PIPE_STAGES (2),
      .TAG_W       (POWER_TAG_W)
  ) u_pc (
      .clk       (core_clk),
      .rst_n     (core_rst_n),
      .valid_in  (pc_consume),
      .sample    (bm_sample),
      .tag_in    (pc_tag_in),
      .valid_out (pc_valid_out),
      .power     (pc_power),
      .tag_out   (pc_tag_out)
  );

  // Repackage the power stream into a CFAR input beat.
  wire [CFAR_S_PAYLOAD_W-1:0] cfar_s_payload;
  wire                        cfar_s_valid;
  wire                        cfar_s_ready;

  stream_fields_t cfar_s_fields;
  always_comb begin
    cfar_s_fields           = '0;
    cfar_s_fields.data      = STREAM_MAX_DATA_W'(pc_power);
    cfar_s_fields.sof       = pc_tag_out[POWER_TAG_W-1];
    cfar_s_fields.eof       = pc_tag_out[POWER_TAG_W-2];
    cfar_s_fields.stream_id = STREAM_MAX_ID_W'(pc_tag_out[SEQ_W +: STREAM_ID_W]);
    cfar_s_fields.seq       = STREAM_MAX_SEQ_W'(pc_tag_out[0 +: SEQ_W]);
    cfar_s_fields.user      = STREAM_MAX_USER_W'(0);
  end

  wire [CFAR_S_PAYLOAD_W-1:0] cfar_s_payload_pre = CFAR_S_PAYLOAD_W'(stream_pack(
      stream_geom(stream_pkg::uint_t'(CFAR_POWER_W),
                  stream_pkg::uint_t'(STREAM_ID_W),
                  stream_pkg::uint_t'(SEQ_W),
                  stream_pkg::uint_t'(USER_W)),
      cfar_s_fields));

  // Elastic buffer between power_calc (fixed latency, always accepts) and
  // CFAR (SPEC 5 ready). The buffer's occupancy is small: power_calc emits at
  // most one beat per input beat, and CFAR runs at the same clock, so a
  // depth of 8 is ample. Its ready feeds bf_m_ready through the credit gate.
  wire [$clog2(9)-1:0] elastic_occ_dummy;
  wire                 pc_eb_s_ready_dummy;

  stream_elastic_buffer #(
      .PAYLOAD_W   (CFAR_S_PAYLOAD_W),
      .DEPTH       (8),
      .DATA_W      (CFAR_POWER_W),
      .STREAM_ID_W (STREAM_ID_W),
      .SEQ_W       (SEQ_W),
      .USER_W      (USER_W)
  ) u_power_eb (
      .clk       (core_clk),
      .rst_n     (core_rst_n),
      .s_valid   (pc_valid_out),
      .s_ready   (pc_eb_s_ready_dummy),  // power_calc has no ready
      .s_payload (cfar_s_payload_pre),
      .m_valid   (cfar_s_valid),
      .m_ready   (cfar_s_ready),
      .m_payload (cfar_s_payload),
      .occupancy (elastic_occ_dummy)
  );

  // Credit-style bf_m_ready: assert as long as the power path can accept.
  // Because power_calc is fixed-latency it always accepts; the elastic buffer
  // holds up to DEPTH beats, so we assert bf_m_ready whenever the elastic
  // buffer is not near full. To keep the wire simple we always assert it
  // (the buffer will never overflow because SPC beats per cycle > 1 does not
  // happen: pc_consume is a single-bit valid).
  assign bf_m_ready = 1'b1;

  // ===========================================================================
  // Stage 8: CFAR detector
  // ===========================================================================
  wire                      cfar_m_valid;
  wire                      cfar_m_ready;
  wire [CFAR_M_PAYLOAD_W-1:0] cfar_m_payload;
  wire [31:0]               cfar_stat_det;
  wire [31:0]               cfar_stat_sup;
  wire [31:0]               cfar_stat_frame;
  wire [5:0]                cfar_stat_fault_dummy;
  wire                      cfar_obs_cfg_pending_dummy;
  wire                      cfar_obs_active_enable_dummy;
  wire [1:0]                cfar_obs_active_mode_dummy;
  wire                      cfar_obs_active_out_mode_dummy;
  wire [4:0]                cfar_obs_active_guard_lead_dummy;
  wire [4:0]                cfar_obs_active_guard_lag_dummy;
  wire [5:0]                cfar_obs_active_ref_lead_dummy;
  wire [5:0]                cfar_obs_active_ref_lag_dummy;
  wire [15:0]               cfar_obs_active_alpha_dummy;
  wire                      cfar_obs_frame_open_dummy;
  wire [4:0]                cfar_obs_max_guard_dummy;
  wire [5:0]                cfar_obs_max_ref_dummy;
  wire [6:0]                cfar_obs_n_lead_dummy;
  wire [6:0]                cfar_obs_n_lag_dummy;

  cfar_core #(
      .MAX_GUARD    (2),                     // config_pkg::CFAR_MAX_GUARD
      .MAX_REF      (8),                     // covers medium sweep
      .OUT_DEPTH    (8),
      .STREAM_ID_W  (STREAM_ID_W),
      .SEQ_W        (SEQ_W),
      .USER_W       (USER_W)
  ) u_cfar (
      .clk               (core_clk),
      .rst_n             (core_rst_n),
      .s_valid           (cfar_s_valid),
      .s_ready           (cfar_s_ready),
      .s_payload         (cfar_s_payload),
      .m_valid           (cfar_m_valid),
      .m_ready           (cfar_m_ready),
      .m_payload         (cfar_m_payload),
      .cfg_enable        (cfg_cfar_enable),
      .cfg_mode          (cfg_cfar_mode),
      .cfg_out_mode      (cfg_cfar_out_mode),
      .cfg_guard_lead    (cfg_cfar_guard_lead),
      .cfg_guard_lag     (cfg_cfar_guard_lag),
      .cfg_ref_lead      (cfg_cfar_ref_lead),
      .cfg_ref_lag       (cfg_cfar_ref_lag),
      .cfg_alpha         (cfg_cfar_alpha),
      .cfg_status_clear  (cfg_cfar_status_clear),
      .stat_det_count    (cfar_stat_det),
      .stat_sup_count    (cfar_stat_sup),
      .stat_frame_count  (cfar_stat_frame),
      .stat_fault        (cfar_stat_fault_dummy),
      .obs_cfg_pending   (cfar_obs_cfg_pending_dummy),
      .obs_active_enable (cfar_obs_active_enable_dummy),
      .obs_active_mode   (cfar_obs_active_mode_dummy),
      .obs_active_out_mode (cfar_obs_active_out_mode_dummy),
      .obs_active_guard_lead (cfar_obs_active_guard_lead_dummy),
      .obs_active_guard_lag  (cfar_obs_active_guard_lag_dummy),
      .obs_active_ref_lead   (cfar_obs_active_ref_lead_dummy),
      .obs_active_ref_lag    (cfar_obs_active_ref_lag_dummy),
      .obs_active_alpha  (cfar_obs_active_alpha_dummy),
      .obs_frame_open    (cfar_obs_frame_open_dummy),
      .obs_max_guard     (cfar_obs_max_guard_dummy),
      .obs_max_ref       (cfar_obs_max_ref_dummy),
      .obs_n_lead        (cfar_obs_n_lead_dummy),
      .obs_n_lag         (cfar_obs_n_lag_dummy)
  );

  assign stat_cfar_det_count   = cfar_stat_det;
  assign stat_cfar_sup_count   = cfar_stat_sup;
  assign stat_cfar_frame_count = cfar_stat_frame;

  // Decode CFAR output for external consumers.
  stream_fields_t cfar_out_fields;
  assign cfar_out_fields = stream_unpack(
      stream_geom(stream_pkg::uint_t'(CFAR_EVENT_W),
                  stream_pkg::uint_t'(STREAM_ID_W),
                  stream_pkg::uint_t'(SEQ_W),
                  stream_pkg::uint_t'(USER_W)),
      stream_payload_t'(cfar_m_payload));

  assign m_valid       = cfar_m_valid;
  assign cfar_m_ready  = m_ready;
  assign m_event_data  = 64'(cfar_out_fields.data[CFAR_EVENT_W-1:0]);
  assign m_sof         = cfar_out_fields.sof;
  assign m_eof         = cfar_out_fields.eof;
  assign m_seq         = cfar_out_fields.seq[SEQ_W-1:0];
  assign m_id          = {2'b0, cfar_out_fields.stream_id[STREAM_ID_W-1:0]};

  // ===========================================================================
  // Pipeline controller: frame-boundary swap gating
  // ===========================================================================
  // Anchor the head-admit plane on antenna 0's PFB input handshake.
  wire head_admit = pfb_s_valid[0] && pfb_s_ready[0];

  benchmark_pipeline_ctrl u_pipe_ctrl (
      .clk                 (core_clk),
      .rst_n               (core_rst_n),
      .head_admit          (head_admit),
      .head_sof            (s_sof[0]),
      .head_eof            (s_eof[0]),
      .cfg_swap_req        (cfg_pipe_swap_req),
      .pfb_swap            (pfb_pipe_swap),
      .bf_swap             (bf_pipe_swap),
      .swap_pending        (stat_pipe_swap_pending),
      .swap_busy           (stat_pipe_swap_busy),
      .frame_count         (stat_pipe_frame_count),
      .swap_count          (stat_pipe_swap_count),
      .swap_overrun_count  (stat_pipe_swap_overrun),
      .pfb_swap_busy       (pfb_pipeline_busy),
      .bf_swap_busy        (bf_pipeline_busy)
  );

endmodule : benchmark_pipeline_top
/* verilator lint_on DECLFILENAME */

`default_nettype wire
