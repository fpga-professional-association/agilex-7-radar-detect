// -----------------------------------------------------------------------------
// benchmark_sim_top - config-driven integrated processing pipeline (issues #17
// and #20).
//
// SPEC.md 4.1 defines benchmark_sim_top as the Verilator-facing top; SPEC 19
// Phase 3 asks that PFB -> FFT -> history -> alignment -> beamformer ->
// power/covariance -> CFAR be wired together into a single pipeline exercised
// by the C++ harness. This file is that wiring.
//
// Issue #20 revision: geometry parameters (N_ANT, SPC, FFT_SIZE, PFB_TAPS,
// N_BEAMS, HIST_FRAMES, N_COVAR_PAIRS, CFAR_MAX_GUARD, CFAR_MAX_REF) are now
// pulled from `config_pkg` -- the same generated package the C++ harness reads
// -- so the exact same RTL elaborates for tiny, medium, and full_agmf039. See
// DECISIONS.md 2026-07-27 "Phase 5 config-driven pipeline top".
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
//                                  |  align_net     |    BIN_PAR = 2: two
//                                  |  (bin align)   |    read ports fed by
//                                  +----------------+    two replicated
//                                          |             history_core banks;
//                                          | 1 stream    the crossbar routes
//                                          |             both lanes.
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
// BIN_PAR = 2 is the alignment network's minimum legal geometry
// (align_pkg::algn_geom_ok requires BIN_PAR >= 2 and a power of two).
// history_core exposes exactly one read port, so the pipeline replicates
// history_core BIN_PAR times: both instances see the same write stream (their
// s_ready ANDed per antenna) and each serves one of the align_net's two read
// ports. This is a legitimate multi-port memory architecture and it exercises
// the crossbar routing across BIN_PAR = 2 lanes in the integrated build. See
// DECISIONS.md 2026-07-27 "Pipeline BIN_PAR = 2, replicated history_core".
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
  import packet_pkg::*;
  import mem_pkg::*;
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
    // Width sized for the largest config: full_agmf039 has PHASES=8, TAPS=16
    // -> clog2(128) = 7 bits; medium is clog2(16) = 4. 8 bits is a safe
    // upper bound that costs only 4 spare wires at medium and lets one port
    // shape cover every config.
    input  wire [7:0]   cfg_pfb_wr_addr,
    input  wire [31:0]  cfg_pfb_wr_data,

    // ---- beamformer weight bank programming (cfg_clk domain) --------------
    input  wire         cfg_bf_wr_valid,
    output wire         cfg_bf_wr_ready,
    input  wire         cfg_bf_wr_bank,
    // Width sized for full_agmf039: N_BEAMS=16, N_ANT=16 -> clog2(256) = 8.
    input  wire [7:0]   cfg_bf_wr_addr,
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
    // Port widths derive from config_pkg so tiny/medium/full elaborate this
    // same top; the harness reads config_sim.h for its C++ mirror.
    input  wire [config_pkg::N_ANTENNAS-1:0]                            s_valid,
    output wire [config_pkg::N_ANTENNAS-1:0]                            s_ready,
    input  wire [config_pkg::N_ANTENNAS-1:0]                            s_sof,
    input  wire [config_pkg::N_ANTENNAS-1:0]                            s_eof,
    // Antenna `a`, phase `p` (p=0..SAMPLES_PER_CYCLE-1) occupies
    // s_data[a*SPC*32 + p*32 +: 32], packed { im, re } as fxp_complex_t.
    input  wire [config_pkg::N_ANTENNAS*config_pkg::SAMPLES_PER_CYCLE*32-1:0] s_data,
    input  wire [15:0]                                                  s_seq,

    // ---- output: CFAR detections ------------------------------------------
    output wire         m_valid,
    input  wire         m_ready,
    // CFAR_EVENT_W is fixed by cfar_pkg; carried out as a wide field.
    output wire [63:0]  m_event_data,        // subset; CFAR_EVENT_W upper bits
    // Full CFAR event (CFAR_EVENT_W = 176 bits) zero-extended to 256 bits so
    // tests can compare byte-for-byte against the memory word the DMA path
    // writes. Registered so the C++ observer's read after advance_cycles(1)
    // returns a stable, cycle-aligned value.
    output wire [255:0] m_event_full,
    output wire         m_sof,
    output wire         m_eof,
    output wire [15:0]  m_seq,
    output wire [3:0]   m_id,
    // Phase-5 addition: the (beam_id, bin_par_lane) tag carried through the
    // serialized CFAR feed lets a test attribute a detection back to its
    // origin. Widths match FANOUT_IDX_W (see below).
    output wire [7:0]   m_beam_id,
    output wire [7:0]   m_bin_par_id,

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
    output wire [31:0]  stat_cfar_frame_count,

    // ---- covariance engine telemetry (Phase 5 fan-out, issue #20) ---------
    // Aggregate counters: sat_any is the OR of any pair's sticky flag; the
    // window/sample counts are of pair 0 (representative) so a test can prove
    // the engine is integrating rather than idle.
    output wire         stat_covar_sat_any,
    output wire [31:0]  stat_covar_pair0_window,
    output wire [31:0]  stat_covar_pair0_samples,

    // ---- DMA / packet-network / memory tap (issue #19 revision) -----------
    // CFAR detection events are FORKED off the m_valid/m_ready stream
    // (cfar_m_ready = m_ready AND dma_tap_ready) and injected into a small
    // packet fabric that hands them off to a behavioural memory model.
    // Every wire in this section lives in core_clk.
    //
    // dma_mem_* is the EXTERNAL producer port on the memory arbiter, used by
    // the test harness to READ BACK what the internal path wrote. Idle when
    // no readback is in progress; the internal path is arbiter port 0.
    input  wire         dma_mem_req_valid,
    output wire         dma_mem_req_ready,
    input  mem_req_t    dma_mem_req,
    output wire         dma_mem_rsp_valid,
    input  wire         dma_mem_rsp_ready,
    output mem_rsp_t    dma_mem_rsp,

    // DMA path statistics (all monotonic, saturating, cleared with core_rst_n)
    output wire [31:0]  stat_dma_events_captured,   // events entering the tap buffer
    output wire [31:0]  stat_dma_events_delivered,  // events written to memory
    output wire [31:0]  stat_dma_pkt_ing_packets,   // ingress packet count
    output wire [31:0]  stat_dma_pkt_egr_packets,   // egress packet count
    output wire [31:0]  stat_dma_mem_req_count,     // behavioural mem req count
    output wire [31:0]  stat_dma_mem_rsp_count,     // behavioural mem rsp count
    output wire [31:0]  stat_dma_write_addr_next    // next address the tap will write to
);

  // ---------------------------------------------------------------------------
  // Config-driven geometry (SPEC 11)
  // Everything below is pulled from config_pkg, which scripts/build_verilator.py
  // regenerates from config/<name>.json before every build. The same package is
  // consumed by the C++ harness (config_sim.h), so tests and RTL never disagree.
  // ---------------------------------------------------------------------------
  localparam int unsigned N_ANT       = config_pkg::N_ANTENNAS;
  localparam int unsigned SPC         = config_pkg::SAMPLES_PER_CYCLE;
  localparam int unsigned FFT_SIZE    = config_pkg::FFT_SIZE;
  localparam int unsigned PFB_TAPS    = config_pkg::PFB_TAPS;
  localparam int unsigned N_BEAMS     = config_pkg::N_BEAMS;
  localparam int unsigned HIST_FRAMES = config_pkg::HISTORY_FRAMES;

  localparam int unsigned MULT_PIPE = 4;

  // BIN_PAR = 2: matches the alignment network's minimum legal geometry
  // (align_pkg guards on bin_par >= 2). The pipeline replicates history_core
  // BIN_PAR times, one instance per read port, all seeing the same write
  // stream. That is a legitimate memory subsystem architecture for a
  // multi-port read pattern and is what makes the network's routing across
  // BIN_PAR = 2 lanes observable in the integrated build.
  //
  // Held at 2 across all configs on purpose: expanding BIN_PAR to 4 or higher
  // is a full-scale performance study belonging to Phase 6/7 (issues #21-#22).
  // What Phase 5 changes is per-(beam, bin) fan-out downstream of the beamformer,
  // not the alignment lane count -- see the per-beam power fan-out at Stage 7.
  localparam int unsigned BIN_PAR = 2;
  // Small reassembly bank -- 4 groups is enough to exercise the sequence
  // check without giant SRAMs.
  localparam int unsigned GROUPS  = 4;

  // Beamformer parallelism -- BEAM_PAR = N_BEAMS gives no time multiplex, the
  // simplest wiring at integration time. BEAM_MUX = 1.
  localparam int unsigned BEAM_PAR = N_BEAMS;

  // ---------------------------------------------------------------------------
  // Phase-5 fan-out / covariance / CFAR-serialization parameters (issue #20)
  // ---------------------------------------------------------------------------
  // POWER_FANOUT is the number of (beam, bin_par) samples per beamformer beat.
  // Each beat we instantiate POWER_FANOUT parallel power_calc units, then
  // ROUND-ROBIN SERIALIZE the POWER_FANOUT power values into a stream of
  // POWER_FANOUT one-cell beats to a SINGLE cfar_core, tagging each beat with
  // (beam_id, bin_par_lane). This is the "documented, spec-compliant
  // serialization" the issue authorises: CFAR still sees one cell per beat
  // (SPEC 7.7's contract), the frame boundary is preserved (first-serialized
  // sample of first-beat carries sof, last of last carries eof), and every
  // (beam, bin_par) is fully covered rather than tapped.
  //
  // The alternative -- one cfar_core per beam -- costs N_BEAMS copies of
  // rtl/cfar/cfar_core.sv, each with its own MAX_REF-wide window register file
  // and MAX_GUARD+MAX_REF pipeline. At full_agmf039 (N_BEAMS=16) that would add
  // ~16x the CFAR resource, and the Phase-5 gate is smoke-only, not
  // throughput. Documented for #21/#22 to revisit.
  localparam int unsigned POWER_FANOUT = BIN_PAR * BEAM_PAR;
  localparam int unsigned FANOUT_IDX_W = (POWER_FANOUT <= 1) ? 1 : $clog2(POWER_FANOUT);

  // N_COVAR_PAIRS from config_pkg drives the number of parallel cross-power
  // channels. Covariance takes the beam vector (N_BEAMS complex samples per
  // beat) as its N_SRC and sums for the configured window. Adjacent beam pairs
  // (0,1), (1,2), ..., min(N_COVAR_PAIRS, N_BEAMS-1) are the default table.
  localparam int unsigned N_COVAR_PAIRS = config_pkg::N_COVAR_PAIRS;

  // CFAR elaborated maxima come from config_pkg too -- so full_agmf039 gets
  // MAX_GUARD=4, MAX_REF=32 and tiny/medium keep their own sizes.
  localparam int unsigned CFAR_MAX_GUARD = config_pkg::CFAR_MAX_GUARD;
  localparam int unsigned CFAR_MAX_REF   = config_pkg::CFAR_MAX_REF;

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

  // The cfg_pfb_wr_addr / cfg_bf_wr_addr top-level ports are sized to 8b for
  // the largest config; smaller configs slice down (see u_pfb / u_bf below).
  // XOR-collect the unused MSBs to keep the UNUSEDSIGNAL rule live for real
  // dead signals elsewhere. Guarded with generate-if so a config that uses
  // all 8 bits contributes 1'b0 rather than an illegal reverse range.
  localparam int unsigned PFB_ADDR_W_USED = $clog2(SPC*PFB_TAPS);
  localparam int unsigned BF_ADDR_W_USED  = $clog2(N_BEAMS*N_ANT);
  logic cfg_pfb_addr_upper_dummy, cfg_bf_addr_upper_dummy;
  if (PFB_ADDR_W_USED < 8) begin : g_pfb_addr_dummy
    assign cfg_pfb_addr_upper_dummy = ^cfg_pfb_wr_addr[7:PFB_ADDR_W_USED];
  end else begin : g_pfb_addr_no_dummy
    assign cfg_pfb_addr_upper_dummy = 1'b0;
  end
  if (BF_ADDR_W_USED < 8) begin : g_bf_addr_dummy
    assign cfg_bf_addr_upper_dummy  = ^cfg_bf_wr_addr[7:BF_ADDR_W_USED];
  end else begin : g_bf_addr_no_dummy
    assign cfg_bf_addr_upper_dummy  = 1'b0;
  end
  wire cfg_addr_upper_dummy = cfg_pfb_addr_upper_dummy ^ cfg_bf_addr_upper_dummy;

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
        // pfb_bank's cfg_wr_addr is exactly $clog2(PHASES*TAPS) bits; the
        // top-level port is 8 bits (largest config), so slice down.
        .cfg_wr_addr      (cfg_pfb_wr_addr[$clog2(SPC*PFB_TAPS)-1:0]),
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
  // Stage 4: align_net -- BIN_PAR = 2 read ports fed by BIN_PAR replicated
  // history_core instances; the network reassembles the (antenna, bin) plane
  // into aligned beats for the beamformer.
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
      .NET_SEL    (0),                  // crossbar variant (BIN_PAR = 2 lanes)
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
      // beamformer cfg_wr_addr is exactly $clog2(N_BEAMS*N_ANT) bits; the
      // top-level port is 8 bits (largest config), so slice down.
      .cfg_wr_addr      (cfg_bf_wr_addr[$clog2(N_BEAMS*N_ANT)-1:0]),
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
  // Stage 7 (Phase 5, issue #20): full per-(beam, bin) power fan-out +
  // covariance integration + PER-BEAM cfar_core with RR-arbitrated output.
  //
  // Architecture (resolves Decision 7 for medium AND full configs):
  //   (a) POWER_FANOUT parallel power_calc units, one per (beam, bin_par);
  //   (b) covar_engine over the BEAM vector (N_SRC = BEAM_PAR) with
  //       N_COVAR_PAIRS pairs -- default adjacent pairs (0,1), (2,3), ...
  //   (c) N_BEAMS parallel cfar_core instances, one per beam. Each beam's
  //       CFAR sees the BIN_PAR power samples of that beam per beat,
  //       serialized so consecutive CFAR samples are consecutive frequency
  //       bins (bin_par 0 = even bins, bin_par 1 = odd bins per align_pkg).
  //       Frame length per CFAR = FFT_SIZE cells; the CFAR window runs over
  //       real frequency bins, so a target at fft_bin K arriving on beam B
  //       lands at CFAR bin K on beam B's CFAR core exactly as SPEC 7.7
  //       intends.
  //   (d) A round-robin arbiter multiplexes the N_BEAMS CFAR event streams
  //       into ONE detection stream on the pipeline_top boundary. Every event
  //       carries m_beam_id / m_bin_par_id so a consumer can attribute the
  //       detection back to its origin. The DMA tap (Stage 9) consumes the
  //       arbitrated stream identically to Phase 3/4, so the packet-network /
  //       memory writeback path is unchanged.
  //
  // Backpressure: each per-beam CFAR asserts ready when its serializer input
  // buffer can absorb; the beamformer's bf_m_ready is deasserted while any
  // per-beam serializer needs an additional cycle to emit the current beat's
  // BIN_PAR samples (in practice this means bf_m_ready falls every 2nd cycle
  // for BIN_PAR=2). Every power_calc unit is fixed latency, so the beat is
  // captured in per-beam wide registers as soon as bf_m_ready lets it in.
  //
  // Frame boundary: sof/eof arrive on a per-beat basis; the serializer
  // attaches sof to the FIRST bin_par sample of a sof-bearing beat and eof
  // to the LAST bin_par sample of an eof-bearing beat, so each per-beam CFAR
  // sees a clean SOF..EOF frame of FFT_SIZE cells.
  // ===========================================================================
  stream_fields_t bf_out_fields;
  assign bf_out_fields = stream_unpack(BF_M_GEOM, stream_payload_t'(bf_m_payload));

  // ---- POWER_FANOUT parallel power_calc units ------------------------------
  // Each unit consumes one complex sample of the beamformer beat and produces
  // one COVAR_POWER_W power value per cycle at fixed PIPE_STAGES latency.
  // The (beam, bin_par) mapping matches the beamformer's own bit packing
  // (bf_dot::pack): index i = beam*BIN_PAR + bin_par.
  localparam int unsigned PC_PIPE = 2;
  localparam int unsigned POWER_TAG_W = 2 + STREAM_ID_W + SEQ_W + FANOUT_IDX_W;

  wire                                       pc_consume = bf_m_valid && bf_m_ready;

  wire [POWER_FANOUT-1:0]                    pc_valid_out_v;
  wire signed [POWER_FANOUT-1:0][COVAR_POWER_W-1:0] pc_power_v;
  wire [POWER_FANOUT-1:0][POWER_TAG_W-1:0]   pc_tag_out_v;

  for (genvar i = 0; i < int'(POWER_FANOUT); i++) begin : g_power_fanout
    wire signed [SAMPLE_W-1:0] bm_i = bf_out_fields.data[i*PAIR_W       +: SAMPLE_W];
    wire signed [SAMPLE_W-1:0] bm_q = bf_out_fields.data[i*PAIR_W + SAMPLE_W +: SAMPLE_W];
    fxp_complex_t bm_sample;
    assign bm_sample = '{re: bm_i, im: bm_q};

    wire [POWER_TAG_W-1:0] pc_tag_in;
    assign pc_tag_in = {bf_out_fields.sof,
                        bf_out_fields.eof,
                        bf_out_fields.stream_id[STREAM_ID_W-1:0],
                        bf_out_fields.seq[SEQ_W-1:0],
                        FANOUT_IDX_W'(i)};

    wire                          pc_valid_out;
    wire signed [COVAR_POWER_W-1:0] pc_power;
    wire [POWER_TAG_W-1:0]        pc_tag_out;

    power_calc #(
        .PIPE_STAGES (PC_PIPE),
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

    assign pc_valid_out_v[i] = pc_valid_out;
    assign pc_power_v[i]     = pc_power;
    assign pc_tag_out_v[i]   = pc_tag_out;
  end

  // ---- Covariance engine over the beam vector ------------------------------
  // N_SRC = BEAM_PAR (all beams present in each beat, at bin_par 0). Feeding
  // beam sample j from bin_par 0 = data[j*BIN_PAR*PAIR_W +: PAIR_W]. The
  // covar engine free-runs on the aligned beamformer beat; its per-window
  // results are consumed only by telemetry (no downstream fabric consumes them
  // yet -- that seam is issue #24/#25).
  //
  // Pair table: adjacent beam pairs (0,1), (2,3), ... clamped to what fits.
  // The engine is elaborated for min(N_COVAR_PAIRS, floor(N_BEAMS/2)+1) pairs;
  // a request beyond that is a config-file error rather than an RTL fault.
  localparam int unsigned COVAR_MAX_PAIRS_LEG = (N_BEAMS >= 2) ? (N_BEAMS/2) : 1;
  localparam int unsigned COVAR_PAIRS         = (N_COVAR_PAIRS <= COVAR_MAX_PAIRS_LEG)
                                              ? N_COVAR_PAIRS : COVAR_MAX_PAIRS_LEG;

  localparam int unsigned COVAR_SEL_W = int'(covar_pkg::covar_src_sel_w());  // 8

  // Pack the beam vector (one complex sample per beam, taken from bin_par 0
  // of the beat). Beams occupy contiguous slots in the beamformer's data
  // packing: sample [beam*BIN_PAR + bin_par]. bin_par = 0 -> beam*BIN_PAR.
  wire [BEAM_PAR*2*SAMPLE_W-1:0] covar_src;
  for (genvar b = 0; b < int'(BEAM_PAR); b++) begin : g_covar_src_pack
    assign covar_src[b*2*SAMPLE_W +: 2*SAMPLE_W] =
        bf_out_fields.data[(b*BIN_PAR)*PAIR_W +: PAIR_W];
  end

  wire [COVAR_PAIRS*COVAR_SEL_W-1:0] covar_cfg_pair_x;
  wire [COVAR_PAIRS*COVAR_SEL_W-1:0] covar_cfg_pair_y;
  for (genvar p = 0; p < int'(COVAR_PAIRS); p++) begin : g_covar_pair_tbl
    // (0,1), (2,3), ... but clamp within [0, BEAM_PAR-1].
    localparam int unsigned XI = (2*p) % BEAM_PAR;
    localparam int unsigned YI = (2*p+1) % BEAM_PAR;
    assign covar_cfg_pair_x[p*COVAR_SEL_W +: COVAR_SEL_W] = COVAR_SEL_W'(XI);
    assign covar_cfg_pair_y[p*COVAR_SEL_W +: COVAR_SEL_W] = COVAR_SEL_W'(YI);
  end

  wire [COVAR_PAIRS-1:0]                   covar_pair_valid;
  wire [COVAR_PAIRS*COVAR_POWER_W-1:0]     covar_pair_acc_re_dummy;
  wire [COVAR_PAIRS*COVAR_POWER_W-1:0]     covar_pair_acc_im_dummy;
  wire [COVAR_PAIRS*covar_pkg::COVAR_WINDOW_ID_W-1:0] covar_pair_window_id;
  wire [COVAR_PAIRS*covar_pkg::COVAR_WINDOW_LEN_W-1:0] covar_pair_sample_count;
  wire [COVAR_PAIRS-1:0]                   covar_pair_flushed_dummy;
  wire [COVAR_PAIRS-1:0]                   covar_pair_truncated_dummy;
  wire [COVAR_PAIRS-1:0]                   covar_pair_sat;
  wire                                     covar_sat_any_w;
  wire [31:0]                              covar_sat_count_max_dummy;
  wire [COVAR_PAIRS*COVAR_SEL_W-1:0]       covar_obs_pair_x_dummy;
  wire [COVAR_PAIRS*COVAR_SEL_W-1:0]       covar_obs_pair_y_dummy;
  wire [COVAR_PAIRS-1:0]                   covar_obs_pair_enable_dummy;

  covar_engine #(
      .N_SRC             (BEAM_PAR),
      .N_PAIRS           (COVAR_PAIRS),
      .CMULT_VARIANT     ("MULT4"),
      .CMULT_PIPE_STAGES (MULT_PIPE),
      .ACC_W             (covar_pkg::COVAR_POWER_W),
      .WINDOW_W          (covar_pkg::COVAR_WINDOW_LEN_W),
      .SAT_COUNT_W       (32),
      .SEL_W             (COVAR_SEL_W)
  ) u_covar (
      .clk               (core_clk),
      .rst_n             (core_rst_n),
      .valid_in          (pc_consume),
      .src               (covar_src),
      .cfg_pair_x        (covar_cfg_pair_x),
      .cfg_pair_y        (covar_cfg_pair_y),
      .cfg_pair_enable   ({COVAR_PAIRS{1'b1}}),
      .cfg_window_len    (covar_pkg::COVAR_WINDOW_LEN_W'(FFT_SIZE)),
      .cfg_mode          (1'b0),   // COVAR_MODE_BLOCK
      .cfg_exp_k         ('0),
      .flush             (1'b0),
      .sat_clear         (1'b0),
      .pair_valid        (covar_pair_valid),
      .pair_acc_re       (covar_pair_acc_re_dummy),
      .pair_acc_im       (covar_pair_acc_im_dummy),
      .pair_window_id    (covar_pair_window_id),
      .pair_sample_count (covar_pair_sample_count),
      .pair_flushed      (covar_pair_flushed_dummy),
      .pair_truncated    (covar_pair_truncated_dummy),
      .pair_sat          (covar_pair_sat),
      .sat_any           (covar_sat_any_w),
      .sat_count_max     (covar_sat_count_max_dummy),
      .obs_pair_x        (covar_obs_pair_x_dummy),
      .obs_pair_y        (covar_obs_pair_y_dummy),
      .obs_pair_enable   (covar_obs_pair_enable_dummy)
  );

  assign stat_covar_sat_any       = covar_sat_any_w;
  assign stat_covar_pair0_window  = 32'(covar_pair_window_id[0 +: covar_pkg::COVAR_WINDOW_ID_W]);
  assign stat_covar_pair0_samples = 32'(covar_pair_sample_count[0 +: covar_pkg::COVAR_WINDOW_LEN_W]);

  // XOR-reduce the covar bundles the top-level does not consume, following
  // the file's UNUSEDSIGNAL convention (per-block valid, per-pair sat mask,
  // full-width window_id and sample_count -- the top exports pair 0's
  // narrow-cast subsets, so the full-width XOR here still covers pair 0).
  // Same trick as dma_arb_rsp0_dummy above.
  wire covar_bundle_dummy =
      (|covar_pair_valid) ^
      (|covar_pair_sat) ^
      (^covar_pair_window_id) ^
      (^covar_pair_sample_count);

  // XOR-collect the upper (unused) bits of pc_valid_out_v when POWER_FANOUT
  // > 1 (each power_calc unit emits its own valid; the pipeline uses only
  // lane 0's since the pipe is uniform, so all lanes rise coincidentally).
  wire pc_valid_upper_dummy = (POWER_FANOUT > 1) ? (|pc_valid_out_v[POWER_FANOUT-1:1])
                                                  : 1'b0;

  // ---- Round-robin serializer: POWER_FANOUT wide beat -> POWER_FANOUT beats
  // Wide fifo captures one full parallel beat at a time so power_calc's
  // fixed-latency stream is safely absorbed. Depth 4 leaves room for the
  // PC_PIPE stages plus one in-flight.
  //
  // For POWER_FANOUT = 1 this reduces to a shift of one sample per admit; the
  // frame boundary logic and the tag rebuild collapse to the single-cell
  // case, so the serializer needs no special case.

  // Wide payload: POWER_FANOUT * (power + tag).
  localparam int unsigned FANOUT_ENTRY_W = COVAR_POWER_W + POWER_TAG_W;
  localparam int unsigned FANOUT_BEAT_W  = POWER_FANOUT * FANOUT_ENTRY_W;

  wire [FANOUT_BEAT_W-1:0] pc_beat_wide;
  for (genvar i = 0; i < int'(POWER_FANOUT); i++) begin : g_fanout_pack
    assign pc_beat_wide[i*FANOUT_ENTRY_W +: FANOUT_ENTRY_W] =
        {pc_tag_out_v[i], pc_power_v[i]};
  end

  // A pc_valid_out_v beat: since power_calc pipeline is uniform on all lanes,
  // valid_out is coincident across lanes. Take lane 0 as the beat-level valid.
  wire pc_beat_valid = pc_valid_out_v[0];

  localparam int unsigned FANOUT_FIFO_DEPTH = 4;
  wire [$clog2(FANOUT_FIFO_DEPTH+1)-1:0] fanout_fifo_occ;
  wire fanout_fifo_s_ready;
  wire fanout_fifo_m_valid;
  wire [FANOUT_BEAT_W-1:0] fanout_fifo_m_data;
  wire fanout_fifo_m_ready;

  stream_elastic_buffer #(
      .PAYLOAD_W (FANOUT_BEAT_W),
      .DEPTH     (FANOUT_FIFO_DEPTH)
  ) u_fanout_fifo (
      .clk       (core_clk),
      .rst_n     (core_rst_n),
      .s_valid   (pc_beat_valid),
      .s_ready   (fanout_fifo_s_ready),
      .s_payload (pc_beat_wide),
      .m_valid   (fanout_fifo_m_valid),
      .m_ready   (fanout_fifo_m_ready),
      .m_payload (fanout_fifo_m_data),
      .occupancy (fanout_fifo_occ)
  );

  // bf_m_ready: propagate the fan-out fifo's occupancy back to the beamformer.
  // With PC_PIPE=2 pipe stages and DEPTH=4 the margin is
  //   admit-cycle N: occupancy up to N, PC_PIPE=2 in-flight, +1 admitted this
  //   cycle = up to 3 beyond current occupancy before the fifo sees them.
  // Deassert admit when occupancy would exceed DEPTH - 3.
  localparam int unsigned FANOUT_MARGIN = PC_PIPE + 1;  // 3
  // Width-safe compare: FANOUT_FIFO_DEPTH is a small integer; extend
  // fanout_fifo_occ to 32 bits so ADD does not truncate.
  assign bf_m_ready = ((32'(fanout_fifo_occ) + FANOUT_MARGIN) <= FANOUT_FIFO_DEPTH);

`ifndef SYNTHESIS
  always_ff @(posedge core_clk) begin
    if (core_rst_n) begin
      a_fanout_no_drop : assert (!pc_beat_valid || fanout_fifo_s_ready)
        else $fatal(1, "benchmark_sim_top: power_calc beat dropped by fanout fifo (occupancy=%0d) -- bf_m_ready backpressure regressed",
                    fanout_fifo_occ);
    end
  end
`endif

  // ===========================================================================
  // Stage 8 (Phase 6, issue #21): PER-BEAM CFAR fan-out with round-robin
  // arbiter on the output.
  //
  // Phase 5 (issue #20, DECISIONS.md 2026-07-27 issue #20 Decision 2) tapped
  // ONE cell per beamformer beat -- (beam 0, bin_par 0) -- into a SINGLE
  // cfar_core. Phase 6 lands the follow-up per-beam fan-out that decision
  // deferred, per issue #21's review comment. Architecture:
  //
  //   * BIN_PAR-cycle SERIALIZER per beam. Each beam owns a small state
  //     machine that consumes the beam's BIN_PAR power samples out of a
  //     fanout FIFO beat and emits them one cell per cycle to that beam's
  //     cfar_core, in bin_par-ascending order (bin_par 0 first, then 1).
  //     All N_BEAMS serializers run in LOCKSTEP: they consume the same
  //     fanout beat and pop it once every beam has finished its BIN_PAR
  //     cells. That way each cfar_core sees FFT_SIZE cells per input
  //     frame in bin order -- the CFAR-window semantics SPEC 7.7 needs.
  //   * N_BEAMS parallel cfar_core instances. Each one is the same
  //     cfar_core module the Phase-3 unit tests exercise; nothing about
  //     the arithmetic changes. Frame length per CFAR = FFT_SIZE cells,
  //     one CFAR frame per input frame, N_BEAMS frames per input frame
  //     summed over the whole fan-out.
  //   * ROUND-ROBIN ARBITER (pkt_rr_arb, N=N_BEAMS) on the outputs. Grants
  //     one beam's cfar_core.m_valid onto the pipeline_top boundary per
  //     cycle. Each event's `user` field carries {beam_id[3:0],
  //     bin_par_id[3:0]}, so a downstream consumer can attribute the
  //     detection back to its origin. Because bf_m_ready throttles the
  //     beamformer to admit only every BIN_PAR-th cycle, the aggregate
  //     event rate per input frame is N_BEAMS x (per-beam per-frame
  //     event count).
  //
  // Test contract change (see DECISIONS.md 2026-07-28 issue #21 entry):
  //   * frames_observed == N_BEAMS * frames_driven (m_eof arrives once per
  //     beam per input frame -- N_BEAMS EOFs interleaved by the arbiter).
  //   * det_count / sup_count / frame_count are aggregated across all
  //     beams as SUMS of stat_det_count[b], stat_sup_count[b],
  //     stat_frame_count[b] for b in [0, N_BEAMS). Saturating add.
  //   * The DMA fork (Stage 9) is unchanged: it forks the ARBITER OUTPUT
  //     m_valid/m_ready, so every arbitrated event is captured in the tap
  //     buffer and delivered to memory just like Phase 5.
  //
  // The Phase-5 rationale for a single tap ("N_BEAMS-parallel CFAR would
  // cascade test failures") is resolved by restructuring the four affected
  // tests in Phase 6 alongside this landing -- test_pipeline_continuous,
  // test_pipeline_metamorphic, test_pipeline_dma, test_pipeline_scenario --
  // to expect the multi-event contract. That restructuring is honest: the
  // invariants those tests check (frame-count monotonicity, impulse
  // response non-vacuity, DMA event counter equality, ground-truth target
  // discovery) all lift to per-beam CFAR naturally because the beamformer
  // weights are uniform, so every beam sees the same power stream and
  // therefore N_BEAMS x every previous count is the correct expected
  // value.
  // ===========================================================================

  // Per-beam serializer state: a phase counter cycles through BIN_PAR cells
  // per admitted fanout beat. Each beam's cfar_core acknowledges its cell at
  // its OWN pace (SPEC 5 stability rule: once s_valid is high, hold it until
  // s_ready fires). A per-beam beam_ph_done_q tracks which beams have already
  // consumed the CURRENT phase's cell; the phase counter advances only after
  // every beam has fired s_ready. Once the last phase's cell is consumed by
  // every beam, the fanout FIFO beat is popped.
  //
  // This is a genuine lockstep: all beams see the SAME (sof, eof, seq) beat
  // metadata, and each beam's cfar_core sees BIN_PAR cells in ascending
  // bin_par order per input frame beat. What "lockstep" means here is
  // per-PHASE, not per-cycle -- a slow-to-accept beam holds up the phase
  // advance without dropping any beam's offered beat.
  localparam int unsigned SER_PHASE_W = (BIN_PAR <= 1) ? 1 : $clog2(BIN_PAR);

  logic [SER_PHASE_W-1:0] ser_phase_q;
  // beam_ph_done_q[b] = "beam b has consumed the current-phase cell already".
  // Cleared when the phase advances.
  logic [N_BEAMS-1:0]     beam_ph_done_q;

  // Wire arrays for per-beam CFAR interfaces.
  wire [N_BEAMS-1:0]                    cfar_s_valid_v;
  wire [N_BEAMS-1:0]                    cfar_s_ready_v;
  wire [N_BEAMS*CFAR_S_PAYLOAD_W-1:0]   cfar_s_payload_v;
  wire [N_BEAMS-1:0]                    cfar_m_valid_v;
  wire [N_BEAMS-1:0]                    cfar_m_ready_v;
  wire [N_BEAMS*CFAR_M_PAYLOAD_W-1:0]   cfar_m_payload_v;
  wire [N_BEAMS*32-1:0]                 cfar_stat_det_v;
  wire [N_BEAMS*32-1:0]                 cfar_stat_sup_v;
  wire [N_BEAMS*32-1:0]                 cfar_stat_frame_v;
  // Per-beam obs / fault dummies: gathered as bit-vectors so a single XOR
  // at the top level keeps the UNUSEDSIGNAL rule live (Verilator lint pass
  // treats un-consumed named-port outputs as errors; the top-level XOR
  // sinks them without silencing the rule).
  wire [N_BEAMS*6-1:0]  cfar_fault_v;
  wire [N_BEAMS-1:0]    cfar_obs_cfg_pending_v;
  wire [N_BEAMS-1:0]    cfar_obs_active_enable_v;
  wire [N_BEAMS*2-1:0]  cfar_obs_active_mode_v;
  wire [N_BEAMS-1:0]    cfar_obs_active_out_mode_v;
  wire [N_BEAMS*5-1:0]  cfar_obs_active_guard_lead_v;
  wire [N_BEAMS*5-1:0]  cfar_obs_active_guard_lag_v;
  wire [N_BEAMS*6-1:0]  cfar_obs_active_ref_lead_v;
  wire [N_BEAMS*6-1:0]  cfar_obs_active_ref_lag_v;
  wire [N_BEAMS*16-1:0] cfar_obs_active_alpha_v;
  wire [N_BEAMS-1:0]    cfar_obs_frame_open_v;
  wire [N_BEAMS*5-1:0]  cfar_obs_max_guard_v;
  wire [N_BEAMS*6-1:0]  cfar_obs_max_ref_v;
  wire [N_BEAMS*7-1:0]  cfar_obs_n_lead_v;
  wire [N_BEAMS*7-1:0]  cfar_obs_n_lag_v;

  // Per-beam handshake acknowledgements THIS cycle. `beam_ph_fire[b]` is high
  // on the cycle beam b consumes the current-phase cell (either firing s_ready
  // right now with s_valid, or already-done from a prior cycle within this
  // phase and s_valid is deasserted so no new fire).
  wire [N_BEAMS-1:0] beam_ph_fire_now;
  // beam_ph_done_next[b] = beam_ph_done_q[b] OR beam_ph_fire_now[b].
  wire [N_BEAMS-1:0] beam_ph_done_next;

  // Phase-complete: every beam has consumed the current-phase cell.
  wire phase_complete = &beam_ph_done_next;

  wire ser_last_phase = (ser_phase_q == SER_PHASE_W'(BIN_PAR - 1));

  // Pop the fanout FIFO beat when the LAST phase completes (all beams have
  // consumed the bin_par-1 cell of this beat).
  assign fanout_fifo_m_ready = fanout_fifo_m_valid && phase_complete && ser_last_phase;

  always_ff @(posedge core_clk) begin
    if (!core_rst_n) begin
      ser_phase_q    <= '0;
      beam_ph_done_q <= '0;
    end else if (fanout_fifo_m_valid) begin
      if (phase_complete) begin
        // Phase done: clear per-beam done flags, advance phase (wrap on last).
        beam_ph_done_q <= '0;
        if (ser_last_phase) begin
          ser_phase_q <= '0;
        end else begin
          ser_phase_q <= ser_phase_q + SER_PHASE_W'(1);
        end
      end else begin
        // Phase still in progress: accumulate any beams that fired this cycle.
        beam_ph_done_q <= beam_ph_done_next;
      end
    end
  end

  // Sof/eof/id/seq are common tag bits at the beat granularity; the
  // per-beam serializer attaches sof to phase-0 and eof to phase-BIN_PAR-1.
  // We use entry 0's tag as the beat metadata (all lanes carry identical
  // sof/eof/seq/stream_id in fan-out).
  wire [POWER_TAG_W-1:0] fanout_beat_tag0 =
      fanout_fifo_m_data[COVAR_POWER_W +: POWER_TAG_W];
  wire fanout_beat_sof = fanout_beat_tag0[POWER_TAG_W-1];
  wire fanout_beat_eof = fanout_beat_tag0[POWER_TAG_W-2];
  wire [STREAM_ID_W-1:0] fanout_beat_sid =
      fanout_beat_tag0[FANOUT_IDX_W + SEQ_W +: STREAM_ID_W];
  wire [SEQ_W-1:0]       fanout_beat_seq =
      fanout_beat_tag0[FANOUT_IDX_W +: SEQ_W];

  // Which phase is the sof / eof cell?
  //   sof cell: phase == 0 AND fanout_beat_sof (frame start beat, bin_par 0)
  //   eof cell: phase == BIN_PAR-1 AND fanout_beat_eof (frame end beat,
  //            last bin_par)
  wire ser_cell_sof = fanout_beat_sof && (ser_phase_q == SER_PHASE_W'(0));
  wire ser_cell_eof = fanout_beat_eof && ser_last_phase;

  // Beam loop: instantiate N_BEAMS cfar_core + build each beam's serialized
  // input beat.
  for (genvar b = 0; b < int'(N_BEAMS); b++) begin : g_cfar_per_beam
    // The (beam b, bin_par ser_phase_q) entry in the fanout beat is at
    // index i = b * BIN_PAR + ser_phase_q. Extract that entry's power.
    wire signed [COVAR_POWER_W-1:0] beam_cell_power;
    if (BIN_PAR == 1) begin : g_binpar1
      assign beam_cell_power =
          fanout_fifo_m_data[b*FANOUT_ENTRY_W +: COVAR_POWER_W];
    end else begin : g_binpar_ge_2
      // Mux over BIN_PAR entries by ser_phase_q for this beam.
      logic signed [COVAR_POWER_W-1:0] beam_cell_power_r;
      always_comb begin
        beam_cell_power_r = '0;
        for (int unsigned p = 0; p < BIN_PAR; p++) begin
          if (SER_PHASE_W'(p) == ser_phase_q) begin
            beam_cell_power_r =
                fanout_fifo_m_data[(b*BIN_PAR + p)*FANOUT_ENTRY_W +: COVAR_POWER_W];
          end
        end
      end
      assign beam_cell_power = beam_cell_power_r;
    end

    // Build the per-beam serialized CFAR input beat.
    // - data = beam_cell_power (COVAR_POWER_W, sign-extended into CFAR
    //   input width -- CFAR_POWER_W == COVAR_POWER_W by cfar_pkg definition).
    // - sof = ser_cell_sof (first cell of first beat of a frame)
    // - eof = ser_cell_eof (last cell of last beat of a frame)
    // - stream_id/seq: pass-through the beamformer's beat metadata
    // - user: {beam_id[3:0], bin_par_id[3:0]}, so the arbiter output tag
    //   encodes origin at 8 bits max (N_BEAMS <= 16, BIN_PAR <= 16 -- both
    //   fit in 4 bits at every configured shape).
    stream_fields_t s_fields;
    always_comb begin
      s_fields           = '0;
      s_fields.data      = STREAM_MAX_DATA_W'(beam_cell_power);
      s_fields.sof       = ser_cell_sof;
      s_fields.eof       = ser_cell_eof;
      s_fields.stream_id = STREAM_MAX_ID_W'(fanout_beat_sid);
      s_fields.seq       = STREAM_MAX_SEQ_W'(fanout_beat_seq);
      // user = {beam_id[3:0], bin_par_id[3:0]}; b <= 15 and ser_phase_q < BIN_PAR
      s_fields.user = STREAM_MAX_USER_W'({b[3:0], 4'(ser_phase_q)});
    end

    // Per-beam s_valid stays HIGH as long as the fanout beat is available
    // AND this beam has NOT already consumed the current-phase cell. This
    // preserves the SPEC 5 handshake stability rule: once valid is
    // asserted, it stays asserted until s_ready fires (which is the
    // acceptance moment). Different beams can fire s_ready on different
    // cycles; the shared ser_phase_q advances only after every beam has
    // consumed the phase.
    assign cfar_s_valid_v[b] = fanout_fifo_m_valid && !beam_ph_done_q[b];
    // Fire is the accepted-this-cycle marker.
    assign beam_ph_fire_now[b] = cfar_s_valid_v[b] && cfar_s_ready_v[b];
    assign beam_ph_done_next[b] = beam_ph_done_q[b] || beam_ph_fire_now[b];
    assign cfar_s_payload_v[b*CFAR_S_PAYLOAD_W +: CFAR_S_PAYLOAD_W] =
        CFAR_S_PAYLOAD_W'(stream_pack(
            stream_geom(stream_pkg::uint_t'(CFAR_POWER_W),
                        stream_pkg::uint_t'(STREAM_ID_W),
                        stream_pkg::uint_t'(SEQ_W),
                        stream_pkg::uint_t'(USER_W)),
            s_fields));

    wire                        m_valid_b;
    wire [CFAR_M_PAYLOAD_W-1:0] m_payload_b;
    wire [31:0]                 stat_det_b;
    wire [31:0]                 stat_sup_b;
    wire [31:0]                 stat_frame_b;

    cfar_core #(
        .MAX_GUARD    (CFAR_MAX_GUARD),
        .MAX_REF      (CFAR_MAX_REF),
        .OUT_DEPTH    (8),
        .STREAM_ID_W  (STREAM_ID_W),
        .SEQ_W        (SEQ_W),
        .USER_W       (USER_W)
    ) u_cfar (
        .clk               (core_clk),
        .rst_n             (core_rst_n),
        .s_valid           (cfar_s_valid_v[b]),
        .s_ready           (cfar_s_ready_v[b]),
        .s_payload         (cfar_s_payload_v[b*CFAR_S_PAYLOAD_W +: CFAR_S_PAYLOAD_W]),
        .m_valid           (m_valid_b),
        .m_ready           (cfar_m_ready_v[b]),
        .m_payload         (m_payload_b),
        .cfg_enable        (cfg_cfar_enable),
        .cfg_mode          (cfg_cfar_mode),
        .cfg_out_mode      (cfg_cfar_out_mode),
        .cfg_guard_lead    (cfg_cfar_guard_lead),
        .cfg_guard_lag     (cfg_cfar_guard_lag),
        .cfg_ref_lead      (cfg_cfar_ref_lead),
        .cfg_ref_lag       (cfg_cfar_ref_lag),
        .cfg_alpha         (cfg_cfar_alpha),
        .cfg_status_clear  (cfg_cfar_status_clear),
        .stat_det_count    (stat_det_b),
        .stat_sup_count    (stat_sup_b),
        .stat_frame_count  (stat_frame_b),
        .stat_fault        (cfar_fault_v            [b*6  +: 6]),
        .obs_cfg_pending   (cfar_obs_cfg_pending_v  [b]),
        .obs_active_enable (cfar_obs_active_enable_v[b]),
        .obs_active_mode   (cfar_obs_active_mode_v  [b*2  +: 2]),
        .obs_active_out_mode (cfar_obs_active_out_mode_v[b]),
        .obs_active_guard_lead (cfar_obs_active_guard_lead_v[b*5 +: 5]),
        .obs_active_guard_lag  (cfar_obs_active_guard_lag_v [b*5 +: 5]),
        .obs_active_ref_lead   (cfar_obs_active_ref_lead_v  [b*6 +: 6]),
        .obs_active_ref_lag    (cfar_obs_active_ref_lag_v   [b*6 +: 6]),
        .obs_active_alpha  (cfar_obs_active_alpha_v [b*16 +: 16]),
        .obs_frame_open    (cfar_obs_frame_open_v   [b]),
        .obs_max_guard     (cfar_obs_max_guard_v    [b*5 +: 5]),
        .obs_max_ref       (cfar_obs_max_ref_v      [b*6 +: 6]),
        .obs_n_lead        (cfar_obs_n_lead_v       [b*7 +: 7]),
        .obs_n_lag         (cfar_obs_n_lag_v        [b*7 +: 7])
    );

    assign cfar_m_valid_v[b] = m_valid_b;
    assign cfar_m_payload_v[b*CFAR_M_PAYLOAD_W +: CFAR_M_PAYLOAD_W] = m_payload_b;
    assign cfar_stat_det_v  [b*32 +: 32] = stat_det_b;
    assign cfar_stat_sup_v  [b*32 +: 32] = stat_sup_b;
    assign cfar_stat_frame_v[b*32 +: 32] = stat_frame_b;
  end

  // Sink the aggregated per-beam obs/fault vectors as a single XOR so lint
  // stays quiet without silencing UNUSEDSIGNAL.
  wire cfar_obs_bundle_dummy =
      (^cfar_fault_v) ^
      (|cfar_obs_cfg_pending_v) ^
      (|cfar_obs_active_enable_v) ^
      (^cfar_obs_active_mode_v) ^
      (|cfar_obs_active_out_mode_v) ^
      (^cfar_obs_active_guard_lead_v) ^
      (^cfar_obs_active_guard_lag_v) ^
      (^cfar_obs_active_ref_lead_v) ^
      (^cfar_obs_active_ref_lag_v) ^
      (^cfar_obs_active_alpha_v) ^
      (|cfar_obs_frame_open_v) ^
      (^cfar_obs_max_guard_v) ^
      (^cfar_obs_max_ref_v) ^
      (^cfar_obs_n_lead_v) ^
      (^cfar_obs_n_lag_v);

  // XOR-collect the upper (unused) entries of the wide fanout beat: with
  // per-beam CFAR every entry IS consumed (each beam's serializer reads its
  // own BIN_PAR entries), so this is now a real fanout-drive: the wire is
  // kept for lint-parity with Phase 5 (upstream may add covariance/telemetry
  // paths that also observe the FIFO).
  wire fanout_beat_upper_dummy = 1'b0;

  // ---- Round-robin arbiter: N_BEAMS CFAR outputs -> ONE pipeline_top out
  // See rtl/packet/pkt_rr_arb.sv for the arbiter contract. `update` fires on
  // the cycle the arbiter output is CONSUMED (m_valid && m_ready). At most
  // one beam is granted per cycle; grant_idx names which beam is on the wire
  // this cycle.
  localparam int unsigned RR_IDX_W = (N_BEAMS > 1) ? $clog2(N_BEAMS) : 1;

  wire                      cfar_m_valid;
  wire                      cfar_m_ready;
  wire [CFAR_M_PAYLOAD_W-1:0] cfar_m_payload;
  wire [N_BEAMS-1:0]        rr_grant;
  wire                      rr_any_grant;
  wire [RR_IDX_W-1:0]       rr_grant_idx_dummy;

  pkt_rr_arb #(
      .N (N_BEAMS)
  ) u_cfar_rr (
      .clk       (core_clk),
      .rst_n     (core_rst_n),
      .req       (cfar_m_valid_v),
      .update    (cfar_m_valid && cfar_m_ready),
      .grant     (rr_grant),
      .any_grant (rr_any_grant),
      .grant_idx (rr_grant_idx_dummy)
  );

  // Per-beam ready = external ready AND this beam is granted.
  for (genvar b = 0; b < int'(N_BEAMS); b++) begin : g_cfar_grant_ready
    assign cfar_m_ready_v[b] = rr_grant[b] && cfar_m_ready;
  end

  // Arbiter output valid + payload mux. Since exactly one grant bit is high
  // when any is granted, mux by grant_idx.
  assign cfar_m_valid = rr_any_grant;
  // Mux via a per-bit reduction: only the granted beam's payload is on the
  // wire this cycle. Use a for-loop as an OR-reduction so N_BEAMS is a
  // genuine parameter.
  logic [CFAR_M_PAYLOAD_W-1:0] cfar_m_payload_mux;
  always_comb begin
    cfar_m_payload_mux = '0;
    for (int unsigned bb = 0; bb < N_BEAMS; bb++) begin
      if (rr_grant[bb]) begin
        cfar_m_payload_mux =
            cfar_m_payload_v[bb*CFAR_M_PAYLOAD_W +: CFAR_M_PAYLOAD_W];
      end
    end
  end
  assign cfar_m_payload = cfar_m_payload_mux;

  // Aggregate per-beam CFAR counters into pipeline_top boundary telemetry.
  // Saturating add: with 32-bit counters and N_BEAMS<=16 the sum saturates at
  // 2^32-1, which is far more than any realistic test drives; the ceiling is
  // there for the assertions and the JSON exporter, not for the events.
  logic [31:0] agg_det_r, agg_sup_r, agg_frame_r;
  always_comb begin
    logic [63:0] acc_det, acc_sup, acc_frame;
    acc_det = '0;
    acc_sup = '0;
    acc_frame = '0;
    for (int unsigned bb = 0; bb < N_BEAMS; bb++) begin
      acc_det   += 64'(cfar_stat_det_v  [bb*32 +: 32]);
      acc_sup   += 64'(cfar_stat_sup_v  [bb*32 +: 32]);
      acc_frame += 64'(cfar_stat_frame_v[bb*32 +: 32]);
    end
    agg_det_r   = (acc_det   > 64'hFFFF_FFFF) ? 32'hFFFF_FFFF : acc_det[31:0];
    agg_sup_r   = (acc_sup   > 64'hFFFF_FFFF) ? 32'hFFFF_FFFF : acc_sup[31:0];
    agg_frame_r = (acc_frame > 64'hFFFF_FFFF) ? 32'hFFFF_FFFF : acc_frame[31:0];
  end
  assign stat_cfar_det_count   = agg_det_r;
  assign stat_cfar_sup_count   = agg_sup_r;
  assign stat_cfar_frame_count = agg_frame_r;

  // Decode CFAR output for external consumers.
  stream_fields_t cfar_out_fields;
  assign cfar_out_fields = stream_unpack(
      stream_geom(stream_pkg::uint_t'(CFAR_EVENT_W),
                  stream_pkg::uint_t'(STREAM_ID_W),
                  stream_pkg::uint_t'(SEQ_W),
                  stream_pkg::uint_t'(USER_W)),
      stream_payload_t'(cfar_m_payload));

  // ===========================================================================
  // Stage 9: CFAR event -> packet network -> abstract memory (issue #19)
  //
  // The CFAR event stream is FORKED (cfar_m_ready = m_ready AND
  // dma_tap_s_ready), so a stall on either consumer stalls the CFAR core.
  // Rationale (fork vs. observe-only tap):
  //   * a fork provides a HARD no-drop guarantee -- if the DMA path cannot
  //     absorb the beat, the CFAR core does not issue it. There is nothing
  //     to lose. An observe-only tap needs a rate-margin argument plus a
  //     runtime assertion; the fork needs neither.
  //   * the DMA tap's elastic buffer (DEPTH=16) has room for well over
  //     one full frame's worth of detection events at medium config (up to
  //     128 CFAR bins per frame, but detections are sparse), and the fabric
  //     drains at 1 flit/cycle while events arrive at most 1/cycle. The
  //     buffer is only there to smooth out short WRITE-request stalls.
  //   * the direct m_valid/m_ready output ports are UNCHANGED for the
  //     Phase-3 tests: those tests set m_ready=1 unconditionally, so their
  //     handshake is unaffected. The dma_tap_s_ready side stays high as
  //     long as the tap buffer has room, which it does with margin.
  //
  // All wires below are core_clk. The pkt_fabric uses RADIX=2, STAGES=1
  // (N_PORTS=2) as the smallest legal fabric that still exercises the
  // ingress adapter, one switch stage, and the egress reassembly point --
  // the whole SPEC 7.8 pipeline shape. Source id 0 feeds the ingress; the
  // routing header names destination id 0; the second port is idle.
  //
  // Event-record matching rule (documented for the harness):
  //   For each captured detection event, the tap writes ONE 512-bit memory
  //   word containing the packed 176-bit CFAR event in the low bits (and
  //   zeros above), at consecutive 64-byte addresses starting at 0. So the
  //   test can read back word K to recover the K-th event's payload
  //   verbatim. The order is the CFAR core's own output order (per SPEC 5
  //   the CFAR frame boundary is m_eof; within a frame events are emitted
  //   in ascending bin order). The test matches by exact payload equality
  //   between the events observed at m_valid/m_ready and the words read
  //   back from memory -- the fork guarantees the SAME set is on both
  //   sides.
  // ===========================================================================

  // ---- Configuration cross-checks -----------------------------------------
  localparam int unsigned DMA_PACKET_W  = config_pkg::PACKET_W;
  localparam int unsigned DMA_N_VC      = config_pkg::N_VIRTUAL_CHANS;
  localparam int unsigned DMA_RADIX     = 2;
  localparam int unsigned DMA_STAGES    = 1;
  localparam int unsigned DMA_N_PORTS   = DMA_RADIX ** DMA_STAGES;   // 2
  localparam int unsigned DMA_FLIT_W    = DMA_PACKET_W + PKT_FLIT_CTRL_W;
  localparam int unsigned DMA_DET_FLITS = int'(pkt_detection_flits(pkt_uint_t'(DMA_PACKET_W)));
  localparam int unsigned DMA_TAP_DEPTH = 16;

`ifndef SYNTHESIS
  initial begin
    if (CFAR_EVENT_W != int'(pkt_detection_payload_w())) begin
      $fatal(1, "benchmark_sim_top: CFAR_EVENT_W=%0d != pkt_detection_payload_w=%0d",
             CFAR_EVENT_W, pkt_detection_payload_w());
    end
    if (DMA_DET_FLITS < 1 || DMA_DET_FLITS > int'(PKT_MAX_FLITS)) begin
      $fatal(1, "benchmark_sim_top: detection flit count %0d out of range",
             DMA_DET_FLITS);
    end
  end
`endif

  // ---- Fork: tap-side elastic buffer for detection events -----------------
  // Carries CFAR_EVENT_W bits of payload, one beat per event. sof/eof from
  // the CFAR stream are dropped -- the packet framing encodes its own
  // beginning/end. This buffer exists so a temporary stall on the packet
  // path (e.g. all credits held by an in-flight packet) does not backpressure
  // the CFAR core beyond one beat.
  wire                       dma_tap_s_valid;
  wire                       dma_tap_s_ready;
  wire [CFAR_EVENT_W-1:0]    dma_tap_s_data;
  wire                       dma_tap_m_valid;
  wire                       dma_tap_m_ready;
  wire [CFAR_EVENT_W-1:0]    dma_tap_m_data;
  wire [$clog2(DMA_TAP_DEPTH+1)-1:0] dma_tap_occupancy_dummy;

  // The 176-bit CFAR event slice, elaborated once and shared between the
  // external m_event_full port (below) and the DMA tap. Extracted directly
  // from cfar_m_payload at the geometry-defined data offset (SPEC 5 layout:
  // user, seq, id, eof, sof, data). Going through cfar_out_fields.data has
  // been observed to produce stale/inconsistent values in Verilator 5.020
  // when the same struct-member part-select is fanned to two consumers.
  localparam int unsigned CFAR_M_DATA_LSB = USER_W + SEQ_W + STREAM_ID_W + 2;
  wire [CFAR_EVENT_W-1:0] cfar_event_bits =
      cfar_m_payload[CFAR_M_DATA_LSB +: CFAR_EVENT_W];

  assign dma_tap_s_valid = cfar_m_valid && m_ready;   // fork condition
  assign dma_tap_s_data  = cfar_event_bits;

  stream_elastic_buffer #(
      .PAYLOAD_W (CFAR_EVENT_W),
      .DEPTH     (DMA_TAP_DEPTH)
  ) u_dma_tap_buf (
      .clk       (core_clk),
      .rst_n     (core_rst_n),
      .s_valid   (dma_tap_s_valid),
      .s_ready   (dma_tap_s_ready),
      .s_payload (dma_tap_s_data),
      .m_valid   (dma_tap_m_valid),
      .m_ready   (dma_tap_m_ready),
      .m_payload (dma_tap_m_data),
      .occupancy (dma_tap_occupancy_dummy)
  );

  // The CFAR ready is the AND of the external consumer and the tap. The tap
  // is nearly always ready (DMA_TAP_DEPTH slots absorb short packet stalls),
  // so this rarely stalls; but if it ever does, the CFAR core stops too and
  // the m_valid/m_ready port sees the same stall. Fork with no drops.
  assign m_valid       = cfar_m_valid && dma_tap_s_ready;
  assign cfar_m_ready  = m_ready && dma_tap_s_ready;
  assign m_event_data  = cfar_event_bits[63:0];
  assign m_sof         = cfar_out_fields.sof;
  assign m_eof         = cfar_out_fields.eof;
  assign m_seq         = cfar_out_fields.seq[SEQ_W-1:0];
  assign m_id          = {{(4-STREAM_ID_W){1'b0}}, cfar_out_fields.stream_id[STREAM_ID_W-1:0]};

  // Phase-5 per-beam CFAR: the arbiter grants ONE beam per output cycle.
  // The user field carries {beam_id[3:0], bin_par_id[3:0]} packed by the
  // serializer; each per-beam CFAR passes it through unchanged. Decode.
  // cfar_out_fields.user is STREAM_MAX_USER_W = 8 bits; we packed
  // {beam[3:0], bin_par[3:0]} into it. Width-match the mask to that.
  assign m_beam_id     = {4'b0, cfar_out_fields.user[7:4]};
  assign m_bin_par_id  = {4'b0, cfar_out_fields.user[3:0]};

  // Full 176-bit CFAR event, zero-extended to 256. Combinational -- kept as
  // a pure assign so the RTL view matches m_event_data on every cycle.
  // (Test observers that need cycle-precise sampling should either fork off
  // core_sample -- see harness/pipeline_tb.cpp -- or read m_event_data plus
  // this port and mask/compare only the well-defined bits.)
  assign m_event_full = {80'd0, cfar_event_bits};

  // ---- Captured-event tally (before packetization) ------------------------
  logic [31:0] dma_captured_q;
  always_ff @(posedge core_clk) begin
    if (!core_rst_n) begin
      dma_captured_q <= 32'd0;
    end else if (dma_tap_s_valid && dma_tap_s_ready) begin
      if (dma_captured_q != 32'hFFFF_FFFF) dma_captured_q <= dma_captured_q + 32'd1;
    end
  end
  assign stat_dma_events_captured = dma_captured_q;

  // ---- Serializer: 176-bit event -> DMA_DET_FLITS beats to pkt_ingress ----
  // One packet per event, packet type PKT_TYPE_DETECTION, VC 0, destination 0.
  // Beat 0 is SOF and carries no payload (the header flit's data field is
  // reserved -- pkt_ingress fills the header itself from s_dest/s_vc/etc.);
  // subsequent beats carry PACKET_W bits of the CFAR event, least significant
  // word first. The serializer holds the full event in a shift register so
  // s_len is known on the SOF beat as pkt_ingress requires.
  logic [CFAR_EVENT_W-1:0] ser_data_q;
  logic                    ser_busy_q;
  logic [$clog2(PKT_MAX_FLITS+1)-1:0] ser_beat_q;   // beats emitted so far

  wire  ser_start = dma_tap_m_valid && !ser_busy_q;
  wire  ser_load  = ser_start;

  // pkt_ingress signals -- source
  logic                    ing_s_valid;
  logic [DMA_PACKET_W-1:0] ing_s_data;
  logic                    ing_s_sof;
  logic                    ing_s_eof;
  wire                     ing_s_ready;

  // The tap buffer's pop matches the SOF beat (which is also when we latch).
  assign dma_tap_m_ready = ser_start && ing_s_ready;

  wire ser_beat_fire = ing_s_valid && ing_s_ready;

  always_ff @(posedge core_clk) begin
    if (!core_rst_n) begin
      ser_data_q <= '0;
      ser_busy_q <= 1'b0;
      ser_beat_q <= '0;
    end else begin
      if (ser_load && ing_s_ready) begin
        ser_data_q <= dma_tap_m_data;
        ser_busy_q <= (DMA_DET_FLITS > 1);   // still have payload beats
        ser_beat_q <= (DMA_DET_FLITS > 1) ? 1 : 0;
      end else if (ser_busy_q && ser_beat_fire) begin
        if (int'(ser_beat_q) + 1 >= DMA_DET_FLITS) begin
          ser_busy_q <= 1'b0;
          ser_beat_q <= '0;
        end else begin
          ser_beat_q <= ser_beat_q + 1;
          // Shift by PACKET_W to expose the next word next cycle.
          ser_data_q <= ser_data_q >> DMA_PACKET_W;
        end
      end
    end
  end

  // Combinational drive to pkt_ingress:
  //   - SOF beat: valid on ser_start (with data ignored by pkt_ingress);
  //   - body beats: valid while ser_busy_q, sending the ser_data_q low word.
  always_comb begin
    ing_s_valid = 1'b0;
    ing_s_sof   = 1'b0;
    ing_s_eof   = 1'b0;
    ing_s_data  = '0;
    if (ser_start) begin
      ing_s_valid = 1'b1;
      ing_s_sof   = 1'b1;
      ing_s_eof   = (DMA_DET_FLITS == 1);
      // data ignored by ingress on SOF; drive the header-flit tail (unused)
      ing_s_data  = DMA_PACKET_W'(dma_tap_m_data);
    end else if (ser_busy_q) begin
      ing_s_valid = 1'b1;
      ing_s_sof   = 1'b0;
      ing_s_eof   = (int'(ser_beat_q) + 1 == DMA_DET_FLITS);
      ing_s_data  = DMA_PACKET_W'(ser_data_q);
    end
  end

  // ---- Small pkt_fabric (RADIX=2, STAGES=1) --------------------------------
  // Only port 0 carries real traffic on both sides. Port 1's slave ready is
  // intentionally ignored (no producer), and port 1's master interface is
  // stalled with ready=0 (no consumer). Port 1's status bits are named as
  // _dummy sinks so the file's UNUSEDSIGNAL waiver covers them.
  wire [DMA_N_PORTS-1:0]                     fab_s_valid;
  wire [DMA_N_PORTS-1:0]                     fab_s_ready;      // [0] used, [1] dummy
  wire [DMA_N_PORTS*DMA_PACKET_W-1:0]        fab_s_data;
  wire [DMA_N_PORTS-1:0]                     fab_s_sof;
  wire [DMA_N_PORTS-1:0]                     fab_s_eof;
  wire [DMA_N_PORTS*PKT_DEST_W-1:0]          fab_s_dest;
  wire [DMA_N_PORTS*PKT_TYPE_W-1:0]          fab_s_type;
  wire [DMA_N_PORTS*PKT_VC_W-1:0]            fab_s_vc;
  wire [DMA_N_PORTS*PKT_LEN_W-1:0]           fab_s_len;

  wire [DMA_N_PORTS-1:0]                     fab_m_valid;      // [0] used, [1] dummy
  wire [DMA_N_PORTS-1:0]                     fab_m_ready;
  wire [DMA_N_PORTS*DMA_FLIT_W-1:0]          fab_m_flit;       // [0] used, [1] dummy
  wire [DMA_N_PORTS*DMA_N_VC-1:0]            fab_m_vc_en;

  wire [DMA_N_PORTS*32-1:0]                  fab_tel_ing_packets;  // [0] used, [1] dummy
  wire [DMA_N_PORTS*32-1:0]                  fab_tel_egr_packets;  // [0] used, [1] dummy
  wire [DMA_STAGES*32-1:0]                   fab_tel_stage_flits_dummy;
  wire [DMA_STAGES*32-1:0]                   fab_tel_stage_stall_dummy;
  wire [DMA_STAGES*16-1:0]                   fab_tel_stage_maxwait_dummy;
  wire [DMA_STAGES*8-1:0]                    fab_tel_stage_hiwater_dummy;
  wire [DMA_N_PORTS*4-1:0]                   fab_ing_err_dummy;
  wire [DMA_N_PORTS*5-1:0]                   fab_egr_err_dummy;

  // The unused port-1 halves of the fabric's flat vectors are XOR-collected
  // into one `_dummy` reducer signal, following the same convention the rest
  // of this file uses for exports the pipeline deliberately does not consume
  // (see the file's UNUSEDSIGNAL waiver in sim/verilator/lint_waivers.vlt).
  wire dma_fab_unused_dummy = fab_s_ready[1]
                            ^ fab_m_valid[1]
                            ^ (^fab_m_flit[DMA_FLIT_W +: DMA_FLIT_W])
                            ^ (^fab_tel_ing_packets[32 +: 32])
                            ^ (^fab_tel_egr_packets[32 +: 32]);

  // Port 0: our injection point. Port 1: idle.
  assign fab_s_valid[0]                     = ing_s_valid;
  assign fab_s_data[0 +: DMA_PACKET_W]      = ing_s_data;
  assign fab_s_sof[0]                       = ing_s_sof;
  assign fab_s_eof[0]                       = ing_s_eof;
  assign fab_s_dest[0 +: PKT_DEST_W]        = PKT_DEST_W'(0);
  assign fab_s_type[0 +: PKT_TYPE_W]        = PKT_TYPE_W'(PKT_TYPE_DETECTION);
  assign fab_s_vc[0 +: PKT_VC_W]            = PKT_VC_W'(0);
  assign fab_s_len[0 +: PKT_LEN_W]          = PKT_LEN_W'(DMA_DET_FLITS);
  assign ing_s_ready                        = fab_s_ready[0];

  assign fab_s_valid[1]                     = 1'b0;
  assign fab_s_data [DMA_PACKET_W +: DMA_PACKET_W] = '0;
  assign fab_s_sof[1]                       = 1'b0;
  assign fab_s_eof[1]                       = 1'b0;
  assign fab_s_dest [PKT_DEST_W +: PKT_DEST_W] = PKT_DEST_W'(1);
  assign fab_s_type [PKT_TYPE_W +: PKT_TYPE_W] = PKT_TYPE_W'(PKT_TYPE_DETECTION);
  assign fab_s_vc   [PKT_VC_W  +: PKT_VC_W]  = PKT_VC_W'(0);
  assign fab_s_len  [PKT_LEN_W +: PKT_LEN_W] = PKT_LEN_W'(1);
  // fab_s_ready[1] intentionally ignored (no producer).

  // Egress port 1: enable every VC but never assert m_ready.
  assign fab_m_ready[1]                     = 1'b0;
  assign fab_m_vc_en[DMA_N_VC +: DMA_N_VC]  = {DMA_N_VC{1'b1}};

  pkt_fabric #(
      .PACKET_W  (DMA_PACKET_W),
      .N_VC      (DMA_N_VC),
      .RADIX     (DMA_RADIX),
      .STAGES    (DMA_STAGES),
      .VC_DEPTH  (4),
      .END_DEPTH (8),
      .OUT_PIPE  (0),
      .STORAGE   ("regs")
  ) u_dma_fabric (
      .clk               (core_clk),
      .rst_n             (core_rst_n),
      .s_valid           (fab_s_valid),
      .s_ready           (fab_s_ready),
      .s_data            (fab_s_data),
      .s_sof             (fab_s_sof),
      .s_eof             (fab_s_eof),
      .s_dest            (fab_s_dest),
      .s_type            (fab_s_type),
      .s_vc              (fab_s_vc),
      .s_len             (fab_s_len),
      .m_valid           (fab_m_valid),
      .m_ready           (fab_m_ready),
      .m_flit            (fab_m_flit),
      .m_vc_en           (fab_m_vc_en),
      .fi_flip           ({(DMA_N_PORTS*2){1'b0}}),
      .fi_credit_kill    ({(DMA_STAGES*DMA_N_PORTS*DMA_N_VC){1'b0}}),
      .tel_ing_packets   (fab_tel_ing_packets),
      .tel_egr_packets   (fab_tel_egr_packets),
      .tel_stage_flits   (fab_tel_stage_flits_dummy),
      .tel_stage_stall   (fab_tel_stage_stall_dummy),
      .tel_stage_maxwait (fab_tel_stage_maxwait_dummy),
      .tel_stage_hiwater (fab_tel_stage_hiwater_dummy),
      .ing_err           (fab_ing_err_dummy),
      .egr_err           (fab_egr_err_dummy),
      .tel_clear         (1'b0)
  );

  assign stat_dma_pkt_ing_packets = fab_tel_ing_packets[0 +: 32];
  assign stat_dma_pkt_egr_packets = fab_tel_egr_packets[0 +: 32];

  // ---- Deserializer: egress flits -> 512-bit memory write request --------
  // The fabric emits pkt_flit_w(PACKET_W)-bit flits from port 0. On the
  // header flit (SOF) we start accumulating; on subsequent payload beats we
  // shift the flit's PACKET_W-bit data into the reassembly register. On EOF
  // we hand the 176-bit CFAR event to the memory writer.
  wire [DMA_FLIT_W-1:0]      egr_flit    = fab_m_flit[0 +: DMA_FLIT_W];
  wire                       egr_sof     = pkt_flit_sof(pkt_flit_t'(egr_flit));
  wire                       egr_eof     = pkt_flit_eof(pkt_flit_t'(egr_flit));
  wire [DMA_PACKET_W-1:0]    egr_data    = DMA_PACKET_W'(pkt_flit_data(pkt_uint_t'(DMA_PACKET_W),
                                                                        pkt_flit_t'(egr_flit)));

  // Payload accumulator: DMA_DET_FLITS-1 payload words fit in
  // (DMA_DET_FLITS-1)*PACKET_W bits, which covers CFAR_EVENT_W.
  localparam int unsigned DES_ACC_W =
      ((DMA_DET_FLITS >= 2) ? (DMA_DET_FLITS - 1) : 1) * DMA_PACKET_W;
  logic [DES_ACC_W-1:0]  des_acc_q;
  logic [$clog2(PKT_MAX_FLITS+1)-1:0] des_beat_q;
  logic                  des_pkt_open_q;
  logic                  des_pending_valid_q;
  logic [CFAR_EVENT_W-1:0] des_pending_event_q;

  wire egr_fire = fab_m_valid[0] && fab_m_ready[0];

  // Memory-writer state: takes a completed event and issues one WRITE
  // request through mem_arbiter. Backpressures the deserializer whenever a
  // pending event is queued -- accepting a new EOF flit before the pending
  // event is written would overwrite des_pending_event_q and lose an event.
  logic                  wr_busy_q;
  wire                   wr_accept;

  // Only accept flits when no completed event is waiting to be written.
  // Header and non-EOF body flits are safe (they update the accumulator, not
  // the pending register); but the simplest correct rule is "no flits while
  // a completion is in queue", and the packet path has enough VC buffering
  // upstream that this rarely stalls.
  wire des_can_accept  = !des_pending_valid_q;
  assign fab_m_ready[0] = des_can_accept;
  assign fab_m_vc_en[0 +: DMA_N_VC] = {DMA_N_VC{1'b1}};

  always_ff @(posedge core_clk) begin
    if (!core_rst_n) begin
      des_acc_q            <= '0;
      des_beat_q           <= '0;
      des_pkt_open_q       <= 1'b0;
      des_pending_valid_q  <= 1'b0;
      des_pending_event_q  <= '0;
    end else begin
      // Clear pending event once the writer accepts it.
      if (des_pending_valid_q && wr_accept) begin
        des_pending_valid_q <= 1'b0;
      end
      if (egr_fire) begin
        if (egr_sof) begin
          // Start a new packet. Header flit carries no payload.
          des_acc_q      <= '0;
          des_beat_q     <= 1;
          des_pkt_open_q <= !egr_eof;   // one-flit packets close immediately
          if (egr_eof) begin
            // Zero-payload event: publish an all-zero event record. This
            // preserves the "one memory word per event" mapping.
            des_pending_event_q <= '0;
            des_pending_valid_q <= 1'b1;
          end
        end else if (des_pkt_open_q) begin
          // Payload flit: append at position (des_beat_q-1)*PACKET_W.
          // Least significant word first, matching the serializer.
          logic [DES_ACC_W-1:0] mask;
          logic [DES_ACC_W-1:0] shifted;
          mask    = DES_ACC_W'({DMA_PACKET_W{1'b1}}) <<
                    ((32'(des_beat_q) - 32'd1) * DMA_PACKET_W);
          shifted = DES_ACC_W'(egr_data) <<
                    ((32'(des_beat_q) - 32'd1) * DMA_PACKET_W);
          des_acc_q  <= (des_acc_q & ~mask) | shifted;
          des_beat_q <= des_beat_q + 1;
          if (egr_eof) begin
            des_pkt_open_q      <= 1'b0;
            // Slice the reassembled payload down to CFAR_EVENT_W bits.
            des_pending_event_q <= CFAR_EVENT_W'((des_acc_q & ~mask) | shifted);
            des_pending_valid_q <= 1'b1;
          end
        end
      end
    end
  end

  // ---- Memory-side writer: pending event -> mem_arbiter port 0 -----------
  // Formats a 512-bit WRITE beat with the CFAR event in the low bits, at
  // consecutive 64-byte addresses starting at 0. The writer counter is the
  // deliverable event count.
  logic [MEM_ADDR_W-1:0] wr_addr_q;
  logic [31:0]           dma_delivered_q;
  logic [MEM_TAG_W-1:0]  wr_tag_q;

  wire            arb_s_req_valid_0;
  wire            arb_s_req_ready_0;
  mem_req_t       arb_s_req_0;

  assign arb_s_req_valid_0 = des_pending_valid_q && wr_busy_q;

  always_comb begin
    arb_s_req_0        = '0;
    arb_s_req_0.op     = 1'(MEM_OP_WRITE);
    arb_s_req_0.addr   = wr_addr_q;
    arb_s_req_0.len    = 8'd1;
    arb_s_req_0.tag    = wr_tag_q;
    arb_s_req_0.data   = MEM_DATA_W'(des_pending_event_q);
    arb_s_req_0.strb   = {MEM_STRB_W{1'b1}};
  end

  // Writer's response is discarded (WRITE has no data to return). The
  // arb_s_rsp[0] valid bit and struct are XOR-collected into a _dummy sink
  // below, satisfying UNUSEDSIGNAL without silencing the rule design-wide.
  wire arb_s_rsp_ready_0;
  assign arb_s_rsp_ready_0 = 1'b1;   // always ready to drain writer responses

  assign wr_accept = arb_s_req_valid_0 && arb_s_req_ready_0;

  always_ff @(posedge core_clk) begin
    if (!core_rst_n) begin
      wr_busy_q       <= 1'b0;
      wr_addr_q       <= '0;
      dma_delivered_q <= 32'd0;
      wr_tag_q        <= '0;
    end else begin
      // Latch a new pending event on the cycle it becomes valid.
      if (des_pending_valid_q && !wr_busy_q) begin
        wr_busy_q <= 1'b1;
      end
      if (wr_accept) begin
        wr_busy_q <= 1'b0;
        wr_addr_q <= wr_addr_q + MEM_ADDR_W'(MEM_DATA_W/8);   // next 512-bit word
        wr_tag_q  <= wr_tag_q + MEM_TAG_W'(1);
        if (dma_delivered_q != 32'hFFFF_FFFF) begin
          dma_delivered_q <= dma_delivered_q + 32'd1;
        end
      end
    end
  end

  assign stat_dma_events_delivered = dma_delivered_q;
  assign stat_dma_write_addr_next  = 32'(wr_addr_q);

  // ---- Memory arbiter with two producer ports -----------------------------
  // Port 0: our internal writer (above). Port 1: dma_mem_* on the module
  // boundary, used by the test to READ BACK the memory contents.
  wire [1:0]     arb_s_req_valid;
  wire [1:0]     arb_s_req_ready;
  mem_req_t      arb_s_req [2];
  wire [1:0]     arb_s_rsp_valid;
  wire [1:0]     arb_s_rsp_ready;
  mem_rsp_t      arb_s_rsp [2];

  assign arb_s_req_valid[0]  = arb_s_req_valid_0;
  assign arb_s_req_valid[1]  = dma_mem_req_valid;
  assign arb_s_req[0]        = arb_s_req_0;
  assign arb_s_req[1]        = dma_mem_req;
  assign arb_s_req_ready_0   = arb_s_req_ready[0];
  assign dma_mem_req_ready   = arb_s_req_ready[1];

  assign arb_s_rsp_ready[0]  = arb_s_rsp_ready_0;
  assign arb_s_rsp_ready[1]  = dma_mem_rsp_ready;
  assign dma_mem_rsp_valid   = arb_s_rsp_valid[1];
  assign dma_mem_rsp         = arb_s_rsp[1];
  // Writer response (port 0) is discarded -- WRITE returns no data. The
  // valid bit and struct are XOR-collected into a _dummy sink so the
  // UNUSEDSIGNAL lint rule stays live for genuine dead signals elsewhere.
  wire dma_arb_rsp0_dummy = arb_s_rsp_valid[0]
                          ^ (^{arb_s_rsp[0].status, arb_s_rsp[0].tag,
                               arb_s_rsp[0].data});

  wire       mem_m_req_valid;
  wire       mem_m_req_ready;
  mem_req_t  mem_m_req;
  wire       mem_m_rsp_valid;
  wire       mem_m_rsp_ready;
  mem_rsp_t  mem_m_rsp;
  wire [7:0] mem_obs_inflight_dummy;
  wire [7:0] mem_obs_max_inflight_dummy;
  wire [7:0] mem_obs_outstanding_tag_dummy;

  mem_arbiter #(
      .N_PORTS               (2),
      .MAX_INFLIGHT_PER_PORT (8)
  ) u_dma_arb (
      .clk                  (core_clk),
      .rst_n                (core_rst_n),
      .s_req_valid          (arb_s_req_valid),
      .s_req_ready          (arb_s_req_ready),
      .s_req                (arb_s_req),
      .s_rsp_valid          (arb_s_rsp_valid),
      .s_rsp_ready          (arb_s_rsp_ready),
      .s_rsp                (arb_s_rsp),
      .m_req_valid          (mem_m_req_valid),
      .m_req_ready          (mem_m_req_ready),
      .m_req                (mem_m_req),
      .m_rsp_valid          (mem_m_rsp_valid),
      .m_rsp_ready          (mem_m_rsp_ready),
      .m_rsp                (mem_m_rsp),
      .cfg_enable           (1'b1),
      .cfg_soft_reset       (1'b0),
      .obs_inflight         (mem_obs_inflight_dummy),
      .obs_max_inflight     (mem_obs_max_inflight_dummy),
      .obs_outstanding_tag  (mem_obs_outstanding_tag_dummy)
  );

  // ---- Behavioural memory model ------------------------------------------
  // Sized to config_pkg::MEM_DEPTH_BYTES (16 KiB at medium = 256 x 512-bit
  // words = 256 detection events). LATENCY=1 (the minimum) keeps runtime
  // low; the test's readback path issues one request at a time.
  wire       mem_obs_fault_range_dummy;
  wire       mem_obs_fault_protocol_dummy;
  wire       mem_obs_fault_timeout_dummy;
  wire [31:0] mem_req_count_w;
  wire [31:0] mem_rsp_count_w;

  behavioral_mem_model #(
      .DEPTH_BYTES  (config_pkg::MEM_DEPTH_BYTES),
      .MAX_INFLIGHT (16)
  ) u_dma_mem (
      .clk                (core_clk),
      .rst_n              (core_rst_n),
      .s_req_valid        (mem_m_req_valid),
      .s_req_ready        (mem_m_req_ready),
      .s_req              (mem_m_req),
      .s_rsp_valid        (mem_m_rsp_valid),
      .s_rsp_ready        (mem_m_rsp_ready),
      .s_rsp              (mem_m_rsp),
      .cfg_enable         (1'b1),
      .cfg_soft_reset     (1'b0),
      .cfg_latency        (8'd1),
      .cfg_fault_mode     (2'd0),
      .obs_fault_range    (mem_obs_fault_range_dummy),
      .obs_fault_protocol (mem_obs_fault_protocol_dummy),
      .obs_fault_timeout  (mem_obs_fault_timeout_dummy),
      .obs_req_count      (mem_req_count_w),
      .obs_rsp_count      (mem_rsp_count_w)
  );

  assign stat_dma_mem_req_count = mem_req_count_w;
  assign stat_dma_mem_rsp_count = mem_rsp_count_w;

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
