// -----------------------------------------------------------------------------
// benchmark_core — the SPEC.md 3 processing pipeline, assembled (issue #17).
//
// This is the portable design. `benchmark_sim_top` wraps it for Verilator and
// `benchmark_fabric_top` will wrap it for Quartus (issue #20); neither adds
// processing, and nothing vendor-specific appears below this line or inside it.
//
// =============================================================================
// 1. The pipeline
// =============================================================================
//
//   core_clk (SPEC 8, 450 MHz)
//   -------------------------------------------------------------------------
//   adc_source        N_ANT synthetic converters, register programmable
//        | N_ANT x SPEC 5 streams, LANES complex samples per beat
//        v
//   pfb_bank          one per antenna, PFB_TAPS taps, dual coefficient banks
//        v
//   streaming_fft     one per antenna, FFT_SIZE points, REORDER = 0
//        v
//   history_core      write side: N_ANT x LANES banks, rotating frame slots
//   ......................... core_clk / history_clk seam (inside the block)
//   history_clk (SPEC 8, 400 MHz)
//   -------------------------------------------------------------------------
//   history_core      read side: one bin per cycle, antenna vector out
//        ^ |
//        | v          history_rd_mux: BIN_PAR requesters onto one port
//   align_net         reassembly, routing, missing/duplicate detection
//        | one beamformer input beat: BIN_PAR bins x N_ANT antennas
//        v
//   stream_cdc        ......... history_clk / core_clk seam (async FIFO)
//   core_clk
//   -------------------------------------------------------------------------
//   beamformer        BIN_PAR x BEAM_PAR dot products, dual weight banks
//        v
//   bin_serializer    one beat per frequency bin, all beams
//        +--------------------> covar_engine   (SPEC 7.6 cross-power)
//        v
//   power_stage       I^2 + Q^2 per beam, plus SPEC 7.6 time integration
//        v
//   cfar_bank         one CFAR detector per beam, events merged
//        v
//   ev_*              the SPEC 7.8 detection-event stream, out of this module
//
//   cfg_clk (SPEC 8, 100 MHz)
//   -------------------------------------------------------------------------
//   reg_fabric        the SPEC 9 register plane, every implemented window
//   cfg_bundle_cdc    configuration and status bundles across every seam
//
// =============================================================================
// 2. Clock domains, and the telemetry_clk decision (NORMATIVE)
// =============================================================================
// Three domains carry logic: `core_clk`, `history_clk`, `cfg_clk`. That is the
// minimum SPEC 8 asks of a Phase 3 pipeline and it is what ARCHITECTURE.md §4
// records as populated.
//
// **`telemetry_clk` is deliberately NOT instantiated, and this is the reason.**
// Every counter in this design already lives in the domain that measures it —
// `perf_counter` instances inside the blocks — and each group of them crosses
// into `cfg_clk` as ONE `cdc_handshake` payload, so a multi-register read is a
// coherent snapshot of a consistent instant (§4 below). Adding a `telemetry_clk`
// would insert a SECOND crossing between the counter and the register plane and
// buy nothing at Phase 3: the counters would be one further crossing stale, the
// snapshot coherence argument would have to be made twice, and the register plane
// they are read through would still be `cfg_clk`. The domain earns its place when
// there is a telemetry AGGREGATOR to put in it — a block that walks counters,
// timestamps them and emits records — and that block is issue #19's. Constraining
// an empty domain now would also mean `quartus/constraints/clocks.sdc` describing
// a clock with no register on it, which SPEC 24 would rightly call an invalid
// constraint.
//
// `packet_clk` and `memory_clk` are absent for the same kind of reason and are
// named by their owning issues (#18's fabric is built and verified but binding
// this event stream to it is #19's multi-domain integration; #24 owns memory).
//
// =============================================================================
// 3. Where every rate comes from (NORMATIVE — the throughput argument)
// =============================================================================
// The front end runs at full rate and the back end at one bin per cycle, and the
// two are decoupled by the history rather than by back pressure:
//
//   ingest   LANES bins/cycle/antenna. `history_core` ties `s_ready` high and
//            SPEC 7.3 requires exactly that ("supports continuous writes"), so
//            nothing downstream can stall the converters, the filters or the
//            transforms. A back end that cannot keep up reads FEWER FRAMES of a
//            history that keeps filling, and `HISTORY_OVERWRITE` counts the
//            frames it did not read. That decoupling is what a corner-turn
//            memory is for.
//
//   read     ONE bin/cycle. Set by `history_core`'s read port, not by this
//            module; rtl/top/history_rd_mux.sv §1 records why widening it is
//            arithmetically impossible for BIN_PAR consecutive bins.
//
//   align    one beat (BIN_PAR bins) every BIN_PAR cycles = one bin/cycle.
//
//   beamform BIN_PAR bins per beat at BEAM_MUX = 1, one beat every BIN_PAR
//            cycles = one bin/cycle. Arithmetic throughput BIN_PAR x BEAM_PAR
//            beam-bins per cycle, invariant and reported on the register plane.
//
//   power    one bin/cycle. N_BEAMS squarers, no multiplex.
//
//   CFAR     one bin/cycle within a frame, plus D + 5 dead cycles per frame
//            boundary where D = CFAR_MAX_GUARD + CFAR_MAX_REF. THIS is the
//            back end's binding constraint, and it is a measured consequence of
//            the window depth rather than of the integration.
//
// So the sustained end-to-end rate is one bin per cycle less the CFAR frame
// overhead, the whole back end is rate matched, and the only place a stall
// originates is the detector. Nothing in this file throttles anything.
//
// =============================================================================
// 4. Configuration and status crossings
// =============================================================================
// The register plane is `cfg_clk` end to end (ARCHITECTURE.md §6.2 is normative
// on this) and every block's `cfg_*` ports are in the block's own domain. The
// crossings are therefore in THIS module and nowhere else:
//
//   direction        mechanism                    payload
//   ---------------  ---------------------------  ----------------------------
//   cfg -> core      cfg_bundle_cdc (handshake)   the whole core config word
//   cfg -> history   cfg_bundle_cdc (handshake)   the whole align config word
//   core -> cfg      cfg_bundle_cdc (handshake)   the whole core status word
//   history -> cfg   cfg_bundle_cdc (handshake)   the whole align status word
//   cfg -> core      cdc_pulse (toggle), one each  every one-cycle strobe
//   cfg -> history   cdc_pulse (toggle), one each  every one-cycle strobe
//   history -> core  stream_cdc (async FIFO)       the beamformer input beat
//   coefficients     inside coeff_bank / weight_bank (issues #10, #12)
//   frame pointer    inside history_core (issue #15)
//
// **Bundles, not per-signal synchronisers.** SPEC 8 forbids synchronising a
// multibit bus bit by bit, and the prohibition has teeth here: a write that
// changes `cfar_ref_lead` from 7 to 8 moves four bits at once, and independent
// synchronisers could land any subset of them on any cycle — the detector would
// then run a frame against a reference count nobody programmed. One handshake
// per direction per domain also makes every multi-register read a coherent
// snapshot, which is what SPEC 9's counter groups need and what issue #8's
// snapshot mechanism provides within a domain.
//
// **The register blocks are all in cfg_clk, including reg_block_history.** That
// block's own header describes its `clk` as core_clk; ARCHITECTURE.md §6.2 says
// the plane is cfg_clk throughout and the crossings belong to the primitives.
// The two disagree and the architecture document wins: a register block clocked
// by core_clk would take `blk_sel`, `index` and `write_data` from a cfg_clk
// fabric across an unsynchronised boundary, which is a CDC violation the
// inventory would not even see because the fabric is not a tagged primitive.
// The block is unchanged; only the clock it is given is. See DECISIONS.md.
//
// =============================================================================
// 5. What is deliberately not here
// =============================================================================
//   * the packet fabric (rtl/packet/, issue #18). It is built and verified; the
//     detection-event stream leaves this module on `ev_*` so that #19's
//     multi-domain integration can bind it to `pkt_ingress` in `packet_clk`.
//     Its register window is instantiated with its hardware inputs tied off so
//     the window decodes and answers rather than falling to the fabric watchdog.
//   * the abstract memory interface (issue #24).
//   * the telemetry aggregator and the snapshot/debug window (issue #19).
//
// Lint contract: clean under `verilator --lint-only --Wall` with no waiver.
// -----------------------------------------------------------------------------

`default_nettype none

// (* cdc_primitive *) — this module owns three clock domains and every crossing
// between them, so scripts/cdc_inventory.py --strict requires it to declare
// itself. It is tagged as a COMPOSITE, the same arrangement rtl/cdc/stream_cdc.sv
// uses over `async_fifo` and rtl/memory/history_core.sv over its banks: the
// report lists this entry and then every real primitive nested under it, so the
// SPEC 8 inventory shows the design-level seam and its implementation together.
//
// The declared pair is the PRINCIPAL one — the beamformer input beat crossing
// from history_clk into core_clk through `u_cdc_align`, which is the design's
// only bulk datapath crossing and the widest thing that moves between domains.
// The configuration and status bundles and the strobes cross too and are listed
// individually; a tag names one pair because the attribute has one pair to name,
// not because the others are hidden.
(* cdc_primitive = "benchmark_pipeline", cdc_src_clk = "history_clk", cdc_dst_clk = "core_clk", cdc_width = "ALIGN_PAYLOAD_W", cdc_stages = "SYNC_STAGES" *)
module benchmark_core
  import fxp_pkg::*;
  import stream_pkg::*;
  import pfb_pkg::*;
  import fft_pkg::*;
  import history_pkg::*;
  import align_pkg::*;
  import beamformer_pkg::*;
  import covar_pkg::*;
  import cfar_pkg::*;
  import reg_if_pkg::*;
  import regmap_pkg::*;
#(
    // ---- SPEC 11 geometry ----
    parameter int unsigned N_ANT          = 4,
    parameter int unsigned LANES          = 2,    // SAMPLES_PER_CYCLE
    parameter int unsigned FFT_SIZE       = 256,
    parameter int unsigned PFB_TAPS       = 8,
    parameter int unsigned N_BEAMS        = 4,
    parameter int unsigned HISTORY_FRAMES = 16,

    // ---- integration parallelism ----
    parameter int unsigned BIN_PAR      = 2,
    parameter int unsigned BEAM_PAR     = 4,
    parameter int unsigned ALIGN_GROUPS = 4,
    parameter int unsigned NET_SEL      = 1,      // measured default: omega
    parameter int unsigned MUX_STAGES   = 2,

    // ---- kernel construction (issue #9/#10/#12 measured defaults) ----
    parameter int unsigned MULT_PIPE_STAGES = 4,
    parameter string       MULT_VARIANT     = "MULT4",
    parameter string       ACC_STYLE        = "TREE",
    parameter string       DELAY_STYLE      = "AUTO",
    parameter int unsigned ADD_REG_EVERY    = 1,
    parameter int unsigned FFT_SCALE_SCHED  = 32'hFFFF_FFFF,
    parameter int unsigned FFT_REORDER      = 0,  // absorbed by the history

    // ---- SPEC 7.6 / 7.7 ----
    parameter int unsigned N_COVAR_PAIRS  = 6,
    parameter int unsigned CFAR_MAX_GUARD = 2,
    parameter int unsigned CFAR_MAX_REF   = 16,
    parameter int unsigned POWER_PIPE     = 2,

    // ---- SPEC 5 field geometry, uniform through the pipeline ----
    parameter int unsigned STREAM_ID_W = 4,
    parameter int unsigned SEQ_W       = 16,
    parameter int unsigned USER_W      = 4,

    parameter int unsigned SYNC_STAGES = 2,
    parameter int unsigned CDC_DEPTH   = 16,
    parameter int unsigned TELEM_W     = 32,

    // ---- DERIVED; never override ----
    //
    // A port width must be a parameter expression and SystemVerilog gives a port
    // list no view of a body localparam, so the payload arithmetic is repeated
    // here once. The elaboration checks below compare every one of them against
    // the package function that defines it, so an override or a layout change
    // fails at time 0 rather than silently mis-slicing a beat — the same device,
    // for the same reason, as pfb_bank's and beamformer's own derived widths.
    parameter int unsigned EV_PAYLOAD_W =
        cfar_pkg::CFAR_EVENT_W + 2 + STREAM_ID_W + SEQ_W + USER_W,
    parameter int unsigned FRONT_PAYLOAD_W =
        LANES * 2 * fxp_pkg::FXP_SAMPLE_W + 2 + STREAM_ID_W + SEQ_W + USER_W,
    parameter int unsigned HIST_RD_PAYLOAD_W =
        int'(history_pkg::hist_data_w(history_pkg::hist_geom(
                 history_pkg::hist_uint_t'(N_ANT),
                 history_pkg::hist_uint_t'(FFT_SIZE),
                 history_pkg::hist_uint_t'(LANES),
                 history_pkg::hist_uint_t'(HISTORY_FRAMES),
                 history_pkg::hist_uint_t'(fxp_pkg::FXP_SAMPLE_W))))
        + 2 + STREAM_ID_W + SEQ_W + USER_W,
    parameter int unsigned ALIGN_PAYLOAD_W =
        BIN_PAR * N_ANT * 2 * fxp_pkg::FXP_SAMPLE_W + 2 + STREAM_ID_W + SEQ_W + USER_W,
    parameter int unsigned BF_PAYLOAD_W =
        BIN_PAR * BEAM_PAR * 2 * fxp_pkg::FXP_SAMPLE_W + 2 + STREAM_ID_W + SEQ_W + USER_W,
    parameter int unsigned BIN_PAYLOAD_W =
        N_BEAMS * 2 * fxp_pkg::FXP_SAMPLE_W + 2 + STREAM_ID_W + SEQ_W + USER_W,
    parameter int unsigned PWR_PAYLOAD_W =
        N_BEAMS * covar_pkg::COVAR_POWER_W + 2 + STREAM_ID_W + SEQ_W + USER_W
) (
    // ---- clocks and resets (SPEC 8) ----
    input  wire                       core_clk,
    input  wire                       core_rst_n,
    input  wire                       history_clk,
    input  wire                       history_rst_n,
    input  wire                       cfg_clk,
    input  wire                       cfg_rst_n,

    // ---- SPEC 9 register master port (cfg_clk) ----
    input  wire [REG_ADDR_W-1:0]      reg_address,
    input  wire [REG_DATA_W-1:0]      reg_write_data,
    input  wire [REG_STRB_W-1:0]      reg_byte_enable,
    input  wire                       reg_write_enable,
    input  wire                       reg_read_enable,
    output wire [REG_DATA_W-1:0]      reg_read_data,
    output wire                       reg_ready,
    output wire                       reg_error,

    // ---- the SPEC 7.7 detection-event stream (core_clk) ----
    output wire                       ev_valid,
    input  wire                       ev_ready,
    output wire [EV_PAYLOAD_W-1:0]    ev_payload,

    // =========================================================================
    // Observation. Every port below is an OUTPUT of a stage boundary that
    // already exists; nothing here changes the datapath and nothing consumes
    // them inside this module.
    //
    // They exist because a scoreboard that can only see the two ends of an
    // eight-stage pipeline can tell you that the answer is wrong and nothing
    // else. SPEC 12.5 asks for transaction identity end to end; these taps are
    // what let the harness bind an identity at each stage and say WHICH stage
    // lost it. `benchmark_fabric_top` leaves them unconnected, which costs
    // nothing because every one of them is a wire off an existing register.
    // =========================================================================
    output wire [N_ANT-1:0]                   obs_adc_valid,
    output wire [N_ANT-1:0]                   obs_adc_ready,
    output wire [N_ANT*FRONT_PAYLOAD_W-1:0]   obs_adc_payload,

    output wire [N_ANT-1:0]                   obs_fft_valid,
    output wire [N_ANT-1:0]                   obs_fft_ready,
    output wire [N_ANT*FRONT_PAYLOAD_W-1:0]   obs_fft_payload,

    output wire                               obs_hrsp_valid,
    output wire                               obs_hrsp_ready,
    output wire [HIST_RD_PAYLOAD_W-1:0]       obs_hrsp_payload,

    output wire                               obs_align_valid,
    output wire                               obs_align_ready,
    output wire [ALIGN_PAYLOAD_W-1:0]         obs_align_payload,

    output wire                               obs_bf_valid,
    output wire                               obs_bf_ready,
    output wire [BF_PAYLOAD_W-1:0]            obs_bf_payload,

    output wire                               obs_bin_valid,
    output wire                               obs_bin_ready,
    output wire [BIN_PAYLOAD_W-1:0]           obs_bin_payload,

    output wire                               obs_pwr_valid,
    output wire                               obs_pwr_ready,
    output wire [PWR_PAYLOAD_W-1:0]           obs_pwr_payload,

    // Per-pair covariance window results (SPEC 7.6), and the per-beam power
    // windows. Read directly rather than through the register plane because the
    // plane reports one pair at a time and a test wants the whole vector of a
    // closed window in one place.
    output wire [N_COVAR_PAIRS-1:0]           obs_covar_valid,
    output wire [N_COVAR_PAIRS*COVAR_POWER_W-1:0] obs_covar_re,
    output wire [N_COVAR_PAIRS*COVAR_POWER_W-1:0] obs_covar_im,
    output wire [N_BEAMS-1:0]                 obs_power_valid,
    output wire [N_BEAMS*COVAR_POWER_W-1:0]   obs_power_acc,

    // The elaborated geometry and latency, so a test proves the numbers it
    // reports rather than recomputing them from the same parameters the design
    // used. Also readable through the register plane (PIPE_GEOMETRY, PIPE_LAT_*).
    output wire [7:0]                         obs_lat_pfb_cycles,
    output wire [7:0]                         obs_lat_pfb_beats,
    output wire [15:0]                        obs_lat_fft_beats,
    output wire [7:0]                         obs_lat_history,
    output wire [7:0]                         obs_lat_align,
    output wire [7:0]                         obs_lat_beamformer,
    output wire [7:0]                         obs_lat_power,
    output wire [7:0]                         obs_beam_mux
);

  // ===========================================================================
  // Geometry, derived once
  // ===========================================================================
  localparam int unsigned SAMPLE_W = FXP_SAMPLE_W;

  localparam int unsigned FRONT_DATA_W = LANES * 2 * SAMPLE_W;

  localparam hist_geom_t HGEOM =
      hist_geom(hist_uint_t'(N_ANT), hist_uint_t'(FFT_SIZE), hist_uint_t'(LANES),
                hist_uint_t'(HISTORY_FRAMES), hist_uint_t'(SAMPLE_W));

  localparam int unsigned HIST_RD_DATA_W = int'(hist_data_w(HGEOM));

  localparam algn_geom_t AGEOM =
      algn_geom(algn_uint_t'(N_ANT), algn_uint_t'(FFT_SIZE), algn_uint_t'(LANES),
                algn_uint_t'(HISTORY_FRAMES), algn_uint_t'(SAMPLE_W),
                algn_uint_t'(BIN_PAR), algn_uint_t'(ALIGN_GROUPS));

  localparam int unsigned ALIGN_DATA_W = int'(algn_out_data_w(AGEOM));
  localparam int unsigned BF_DATA_W    = BIN_PAR * BEAM_PAR * 2 * SAMPLE_W;
  localparam int unsigned BIN_DATA_W   = N_BEAMS * 2 * SAMPLE_W;
  localparam int unsigned PWR_DATA_W   = N_BEAMS * COVAR_POWER_W;

  // The alignment network's missing-sample timeout.
  //
  // `algn_default_timeout` is `GROUPS * (read_latency + net_latency) + 16`,
  // derived on issue #16's assumption of BIN_PAR INDEPENDENT history read ports.
  // This design has ONE, multiplexed (rtl/top/history_rd_mux.sv 1), so a group's
  // requests queue behind every other open group's and the worst wait is
  // `GROUPS * BIN_PAR` forwarded requests plus a round trip rather than one
  // round trip per group. At the medium geometry the default is 44 cycles; a
  // live run reported 36 missing-sample timeouts and 36 orphaned responses in
  // twenty-four sweeps, which is the detector firing on this block's own
  // arbitration rather than on a lost sample.
  //
  // The bound below is that arithmetic with a factor of eight, which is large
  // because the cost of being generous is a slower report of a genuinely lost
  // sample and the cost of being tight is a false one. It is stated here rather
  // than changed in align_pkg because it is a property of how THIS top wires the
  // block, not of the block.
  //
  // The factor is TWO and not eight, and that is a measured trade. A straddled
  // group (see the note on the frame straddle in DECISIONS.md) never completes,
  // so its entry occupies one of `GROUPS` until the timeout retires it: a
  // generous timeout turns a one-beat repair into hundreds of cycles of
  // head-of-line blocking, and a run with eight times this bound delivered a
  // quarter of the sweeps a run with two times it did. Two is comfortably above
  // the worst legitimate wait and comfortably below the point where the cure
  // costs more than the disease.
  localparam int unsigned ALIGN_TIMEOUT =
      2 * (ALIGN_GROUPS * BIN_PAR + 1) *
      (int'(hist_read_latency()) +
       int'(algn_net_latency(algn_uint_t'(NET_SEL), algn_uint_t'(BIN_PAR),
                             algn_uint_t'(MUX_STAGES))) + 4) + 64;

  localparam int unsigned COEFF_ADDR_W = $clog2(LANES * PFB_TAPS);
  localparam int unsigned WGT_ADDR_W   = $clog2(N_BEAMS * N_ANT);

  localparam int unsigned BEAM_MUX = int'(bf_beam_mux(bf_uint_t'(N_BEAMS),
                                                      bf_uint_t'(BEAM_PAR)));

  // Latency, from the packages the blocks themselves elaborate from.
  localparam int unsigned LAT_PFB_CYC =
      int'(pfb_lat_cycles(ACC_STYLE, pfb_uint_t'(PFB_TAPS),
                          pfb_uint_t'(MULT_PIPE_STAGES))) + 1;
  localparam int unsigned LAT_PFB_BEAT =
      int'(pfb_lat_beats(ACC_STYLE, pfb_uint_t'(PFB_TAPS)));
  localparam int unsigned LAT_FFT_BEAT =
      int'(fft_total_latency(fft_uint_t'(FFT_SIZE), fft_uint_t'(LANES),
                             fft_tw_rom_latency(1), fft_uint_t'(4),
                             FFT_REORDER != 0));
  localparam int unsigned LAT_HIST  = int'(hist_read_latency());
  localparam int unsigned LAT_ALIGN = int'(algn_block_latency(algn_uint_t'(NET_SEL),
                                                             algn_uint_t'(BIN_PAR),
                                                             algn_uint_t'(MUX_STAGES)));
  localparam int unsigned LAT_BF    = int'(bf_lat_cycles(bf_uint_t'(N_ANT),
                                                         bf_uint_t'(MULT_PIPE_STAGES),
                                                         bf_uint_t'(ADD_REG_EVERY))) + 1;
  localparam int unsigned LAT_PWR   = POWER_PIPE + 1;

`ifndef SYNTHESIS
  initial begin
    if (!hist_geom_ok(HGEOM))  $fatal(1, "benchmark_core: illegal history geometry");
    if (!algn_geom_ok(AGEOM))  $fatal(1, "benchmark_core: illegal alignment geometry");
    if (BEAM_MUX != 1) begin
      $fatal(1, "benchmark_core: BEAM_PAR=%0d gives BEAM_MUX=%0d; rtl/top/bin_serializer.sv reads one bin's beams from ONE beat and needs BEAM_MUX=1",
             BEAM_PAR, BEAM_MUX);
    end
    if (USER_W < ALGN_USER_W) begin
      $fatal(1, "benchmark_core: USER_W=%0d cannot carry the alignment network's %0d status bits",
             USER_W, ALGN_USER_W);
    end
    if (N_BEAMS > (1 << STREAM_ID_W)) begin
      $fatal(1, "benchmark_core: N_BEAMS=%0d does not fit STREAM_ID_W=%0d", N_BEAMS, STREAM_ID_W);
    end
    if (N_ANT > (1 << STREAM_ID_W)) begin
      $fatal(1, "benchmark_core: N_ANT=%0d does not fit STREAM_ID_W=%0d", N_ANT, STREAM_ID_W);
    end
    if (int'(ALIGN_DATA_W) != int'(bf_in_data_w(bf_uint_t'(BIN_PAR), bf_uint_t'(N_ANT)))) begin
      $fatal(1, "benchmark_core: alignment beat %0d bits, beamformer wants %0d",
             ALIGN_DATA_W, int'(bf_in_data_w(bf_uint_t'(BIN_PAR), bf_uint_t'(N_ANT))));
    end
    // The derived port widths, each against the package function that defines it.
    if (int'(FRONT_PAYLOAD_W) != int'(stream_payload_w(
            stream_geom(stream_pkg::uint_t'(FRONT_DATA_W), stream_pkg::uint_t'(STREAM_ID_W),
                        stream_pkg::uint_t'(SEQ_W), stream_pkg::uint_t'(USER_W))))) begin
      $fatal(1, "benchmark_core: FRONT_PAYLOAD_W=%0d disagrees with stream_pkg", FRONT_PAYLOAD_W);
    end
    if (int'(HIST_RD_PAYLOAD_W) != int'(stream_payload_w(
            stream_geom(stream_pkg::uint_t'(HIST_RD_DATA_W), stream_pkg::uint_t'(STREAM_ID_W),
                        stream_pkg::uint_t'(SEQ_W), stream_pkg::uint_t'(USER_W))))) begin
      $fatal(1, "benchmark_core: HIST_RD_PAYLOAD_W=%0d disagrees with stream_pkg", HIST_RD_PAYLOAD_W);
    end
    if (int'(ALIGN_PAYLOAD_W) != int'(stream_payload_w(
            stream_geom(stream_pkg::uint_t'(ALIGN_DATA_W), stream_pkg::uint_t'(STREAM_ID_W),
                        stream_pkg::uint_t'(SEQ_W), stream_pkg::uint_t'(USER_W))))) begin
      $fatal(1, "benchmark_core: ALIGN_PAYLOAD_W=%0d disagrees with stream_pkg", ALIGN_PAYLOAD_W);
    end
    if (int'(BF_PAYLOAD_W) != int'(stream_payload_w(
            stream_geom(stream_pkg::uint_t'(BF_DATA_W), stream_pkg::uint_t'(STREAM_ID_W),
                        stream_pkg::uint_t'(SEQ_W), stream_pkg::uint_t'(USER_W))))) begin
      $fatal(1, "benchmark_core: BF_PAYLOAD_W=%0d disagrees with stream_pkg", BF_PAYLOAD_W);
    end
    if (int'(BIN_PAYLOAD_W) != int'(stream_payload_w(
            stream_geom(stream_pkg::uint_t'(BIN_DATA_W), stream_pkg::uint_t'(STREAM_ID_W),
                        stream_pkg::uint_t'(SEQ_W), stream_pkg::uint_t'(USER_W))))) begin
      $fatal(1, "benchmark_core: BIN_PAYLOAD_W=%0d disagrees with stream_pkg", BIN_PAYLOAD_W);
    end
    if (int'(PWR_PAYLOAD_W) != int'(stream_payload_w(
            stream_geom(stream_pkg::uint_t'(PWR_DATA_W), stream_pkg::uint_t'(STREAM_ID_W),
                        stream_pkg::uint_t'(SEQ_W), stream_pkg::uint_t'(USER_W))))) begin
      $fatal(1, "benchmark_core: PWR_PAYLOAD_W=%0d disagrees with stream_pkg", PWR_PAYLOAD_W);
    end
  end
`endif

  // ===========================================================================
  // The register plane (cfg_clk)
  // ===========================================================================
  localparam int unsigned NB    = REGMAP_N_BLOCKS_IMPL;
  localparam int unsigned IDX_W = REGMAP_WINDOW_W - 2;

  wire [NB-1:0]            blk_sel;
  wire                     blk_write_enable;
  wire                     blk_read_enable;
  wire [IDX_W-1:0]         blk_index;
  wire [REG_DATA_W-1:0]    blk_write_data;
  wire [REG_STRB_W-1:0]    blk_byte_enable;
  wire [NB*REG_DATA_W-1:0] blk_read_data;
  wire [NB-1:0]            blk_ready;
  wire [NB-1:0]            blk_error;

  reg_fabric #(
      .N_BLOCKS   (NB),
      .WINDOW_W   (REGMAP_WINDOW_W),
      .BLOCK_BASE (REGMAP_IMPL_BASE)
  ) u_fabric (
      .clk              (cfg_clk),
      .rst_n            (cfg_rst_n),
      .address          (reg_address),
      .write_data       (reg_write_data),
      .byte_enable      (reg_byte_enable),
      .write_enable     (reg_write_enable),
      .read_enable      (reg_read_enable),
      .read_data        (reg_read_data),
      .ready            (reg_ready),
      .error            (reg_error),
      .blk_sel          (blk_sel),
      .blk_write_enable (blk_write_enable),
      .blk_read_enable  (blk_read_enable),
      .blk_index        (blk_index),
      .blk_write_data   (blk_write_data),
      .blk_byte_enable  (blk_byte_enable),
      .blk_read_data    (blk_read_data),
      .blk_ready        (blk_ready),
      .blk_error        (blk_error)
  );

  // ---- identification, build parameters, scratch: no hardware side ----
  wire [REGMAP_ID_N_REGS*32-1:0]           unused_id_csr, unused_id_pulse;
  wire [REGMAP_BUILD_PARAMS_N_REGS*32-1:0] unused_bp_csr, unused_bp_pulse;
  wire [REGMAP_SCRATCH_N_REGS*32-1:0]      unused_sc_csr, unused_sc_pulse;
  wire [31:0]                              unused_param_checksum;

  reg_block_id #(.IDX_W (IDX_W)) u_reg_id (
      .clk (cfg_clk), .rst_n (cfg_rst_n),
      .sel (blk_sel[REGMAP_ID_INDEX]),
      .write_enable (blk_write_enable), .read_enable (blk_read_enable),
      .index (blk_index), .write_data (blk_write_data), .byte_enable (blk_byte_enable),
      .read_data (blk_read_data[REGMAP_ID_INDEX*REG_DATA_W +: REG_DATA_W]),
      .ready (blk_ready[REGMAP_ID_INDEX]), .error (blk_error[REGMAP_ID_INDEX]),
      .csr (unused_id_csr), .pulse (unused_id_pulse)
  );

  reg_block_build_params #(.IDX_W (IDX_W)) u_reg_bp (
      .clk (cfg_clk), .rst_n (cfg_rst_n),
      .sel (blk_sel[REGMAP_BUILD_PARAMS_INDEX]),
      .write_enable (blk_write_enable), .read_enable (blk_read_enable),
      .index (blk_index), .write_data (blk_write_data), .byte_enable (blk_byte_enable),
      .read_data (blk_read_data[REGMAP_BUILD_PARAMS_INDEX*REG_DATA_W +: REG_DATA_W]),
      .ready (blk_ready[REGMAP_BUILD_PARAMS_INDEX]),
      .error (blk_error[REGMAP_BUILD_PARAMS_INDEX]),
      .csr (unused_bp_csr), .pulse (unused_bp_pulse),
      .param_checksum (unused_param_checksum)
  );

  reg_block_scratch #(.IDX_W (IDX_W)) u_reg_scratch (
      .clk (cfg_clk), .rst_n (cfg_rst_n),
      .sel (blk_sel[REGMAP_SCRATCH_INDEX]),
      .write_enable (blk_write_enable), .read_enable (blk_read_enable),
      .index (blk_index), .write_data (blk_write_data), .byte_enable (blk_byte_enable),
      .read_data (blk_read_data[REGMAP_SCRATCH_INDEX*REG_DATA_W +: REG_DATA_W]),
      .ready (blk_ready[REGMAP_SCRATCH_INDEX]), .error (blk_error[REGMAP_SCRATCH_INDEX]),
      .csr (unused_sc_csr), .pulse (unused_sc_pulse)
  );

  // ---- per-block enable and soft reset ----
  wire [REGMAP_CTRL_N_REGS*32-1:0] unused_ctrl_csr, unused_ctrl_pulse;
  wire [31:0] blk_enable_cfg;
  wire [31:0] unused_blk_reset_pulse;
  wire        global_enable_cfg;
  wire        unused_flush_pulse, unused_soft_reset_pulse;

  reg_block_ctrl #(.IDX_W (IDX_W)) u_reg_ctrl (
      .clk (cfg_clk), .rst_n (cfg_rst_n),
      .sel (blk_sel[REGMAP_CTRL_INDEX]),
      .write_enable (blk_write_enable), .read_enable (blk_read_enable),
      .index (blk_index), .write_data (blk_write_data), .byte_enable (blk_byte_enable),
      .read_data (blk_read_data[REGMAP_CTRL_INDEX*REG_DATA_W +: REG_DATA_W]),
      .ready (blk_ready[REGMAP_CTRL_INDEX]), .error (blk_error[REGMAP_CTRL_INDEX]),
      .csr (unused_ctrl_csr), .pulse (unused_ctrl_pulse),
      .block_enable (blk_enable_cfg),
      .block_reset_pulse (unused_blk_reset_pulse),
      .global_enable (global_enable_cfg),
      .flush_pulse (unused_flush_pulse),
      .soft_reset_pulse (unused_soft_reset_pulse)
  );

  // The soft-reset and flush pulses are declared by SPEC 9 and are NOT wired.
  // A soft reset that reached a block would have to be sequenced against the
  // frames in flight in every other block, and getting that wrong silently
  // corrupts a frame rather than failing; the sequencing belongs to the block
  // that owns the producers, which is issue #19's multi-domain integration. The
  // register bits exist, read back correctly and are tested by the register
  // plane's own suite; nothing in this pipeline claims to act on them.

  // ---- fault injection ----
  wire [REGMAP_FAULT_N_REGS*32-1:0] unused_flt_csr, unused_flt_pulse;
  wire [31:0] fault_inject_cfg;

  reg_block_fault #(.IDX_W (IDX_W)) u_reg_fault (
      .clk (cfg_clk), .rst_n (cfg_rst_n),
      .sel (blk_sel[REGMAP_FAULT_INDEX]),
      .write_enable (blk_write_enable), .read_enable (blk_read_enable),
      .index (blk_index), .write_data (blk_write_data), .byte_enable (blk_byte_enable),
      .read_data (blk_read_data[REGMAP_FAULT_INDEX*REG_DATA_W +: REG_DATA_W]),
      .ready (blk_ready[REGMAP_FAULT_INDEX]), .error (blk_error[REGMAP_FAULT_INDEX]),
      .csr (unused_flt_csr), .pulse (unused_flt_pulse),
      .fault_inject (fault_inject_cfg)
  );

  // ---- the SPEC 9 counters window, as a register file ----
  // The real block is rtl/common/telemetry_block.sv and it needs a stream of its
  // own to measure; binding it belongs to issue #19 along with telemetry_clk.
  // The window decodes and answers here, which is what keeps a discovery walk
  // over the map from hitting the fabric watchdog.
  wire [REGMAP_COUNTERS_N_REGS*32-1:0] unused_cnt_csr, unused_cnt_pulse;

  reg_csr_block #(
      .N_REGS     (REGMAP_COUNTERS_N_REGS),
      .IDX_W      (IDX_W),
      .RESET_VAL  (REGMAP_COUNTERS_RESET),
      .WMASK      (REGMAP_COUNTERS_WMASK),
      .W1C_MASK   (REGMAP_COUNTERS_W1CMASK),
      .PULSE_MASK (REGMAP_COUNTERS_PULSEMASK),
      .HW_MASK    (REGMAP_COUNTERS_HWMASK)
  ) u_reg_counters (
      .clk (cfg_clk), .rst_n (cfg_rst_n),
      .sel (blk_sel[REGMAP_COUNTERS_INDEX]),
      .write_enable (blk_write_enable), .read_enable (blk_read_enable),
      .index (blk_index), .write_data (blk_write_data), .byte_enable (blk_byte_enable),
      .read_data (blk_read_data[REGMAP_COUNTERS_INDEX*REG_DATA_W +: REG_DATA_W]),
      .ready (blk_ready[REGMAP_COUNTERS_INDEX]), .error (blk_error[REGMAP_COUNTERS_INDEX]),
      .hw_value ('0), .hw_set ('0),
      .csr (unused_cnt_csr), .pulse (unused_cnt_pulse)
  );

  // ---- the packet window, hardware side tied off (see header §5) ----
  wire [REGMAP_PACKET_N_REGS*32-1:0] unused_pk_csr, unused_pk_pulse;
  wire unused_pk_enable, unused_pk_tel_clear, unused_pk_kill_en;
  wire [1:0] unused_pk_flip_mask, unused_pk_kill_vc;
  wire [4:0] unused_pk_flip_port, unused_pk_kill_port, unused_pk_obs_port;
  wire [3:0] unused_pk_kill_stage, unused_pk_obs_stage;

  reg_block_packet #(.IDX_W (IDX_W)) u_reg_packet (
      .clk (cfg_clk), .rst_n (cfg_rst_n),
      .sel (blk_sel[REGMAP_PACKET_INDEX]),
      .write_enable (blk_write_enable), .read_enable (blk_read_enable),
      .index (blk_index), .write_data (blk_write_data), .byte_enable (blk_byte_enable),
      .read_data (blk_read_data[REGMAP_PACKET_INDEX*REG_DATA_W +: REG_DATA_W]),
      .ready (blk_ready[REGMAP_PACKET_INDEX]), .error (blk_error[REGMAP_PACKET_INDEX]),
      .cfg_enable (unused_pk_enable), .cfg_tel_clear (unused_pk_tel_clear),
      .cfg_flip_mask (unused_pk_flip_mask), .cfg_flip_port (unused_pk_flip_port),
      .cfg_kill_en (unused_pk_kill_en), .cfg_kill_stage (unused_pk_kill_stage),
      .cfg_kill_port (unused_pk_kill_port), .cfg_kill_vc (unused_pk_kill_vc),
      .cfg_observe_port (unused_pk_obs_port), .cfg_observe_stage (unused_pk_obs_stage),
      .hw_n_ports (8'd0), .hw_n_vc (8'd0), .hw_radix (8'd0), .hw_stages (8'd0),
      .hw_packet_w (16'd0), .hw_flit_w (16'd0), .hw_hdr_w (8'd0),
      .hw_max_flits (8'd0), .hw_seq_w (8'd0), .hw_dest_w (4'd0), .hw_src_w (4'd0),
      .hw_err (9'd0), .hw_flits (32'd0), .hw_stalls (32'd0), .hw_max_wait (16'd0),
      .hw_hiwater (8'd0), .hw_pkt_in (32'd0), .hw_pkt_out (32'd0),
      .csr (unused_pk_csr), .pulse (unused_pk_pulse)
  );

  // ===========================================================================
  // Configuration bundles, cfg_clk -> core_clk and cfg_clk -> history_clk
  // ===========================================================================
  //
  // Everything the core domain needs is packed into ONE word, crossed as one
  // handshake payload, and unpacked on the far side. The packing is a
  // concatenation written once in each direction; a field added to it appears at
  // the top so no existing offset moves.

  // ---- coefficient / weight window (cfg_clk on both sides) ----
  wire [REGMAP_COEFF_N_REGS*32-1:0] unused_co_csr, unused_co_pulse;
  wire        coeff_wr_valid, coeff_wr_bank, coeff_swap_req, coeff_status_clear;
  wire [15:0] coeff_wr_index;
  wire [31:0] coeff_wr_data;
  wire        wgt_wr_valid, wgt_wr_bank, wgt_swap_req, wgt_status_clear;
  wire [15:0] wgt_wr_index;
  wire [31:0] wgt_wr_data;

  // ---- covariance window ----
  wire [REGMAP_COVAR_N_REGS*32-1:0] unused_cv_csr, unused_cv_pulse;
  wire                              cv_enable_cfg, cv_mode_cfg;
  wire [COVAR_EXP_K_W-1:0]          cv_exp_k_cfg;
  wire [COVAR_WINDOW_LEN_W-1:0]     cv_window_cfg;
  wire [31:0]                       cv_pair_en_cfg;
  wire                              cv_flush_cfg, cv_sat_clear_cfg;
  wire                              cv_pt_wr;
  wire [7:0]                        cv_pt_idx, cv_pt_x, cv_pt_y;

  // ---- CFAR window ----
  wire [REGMAP_CFAR_N_REGS*32-1:0]  unused_cf_csr, unused_cf_pulse;
  wire                              cf_enable_cfg, cf_out_mode_cfg;
  wire [CFAR_MODE_W-1:0]            cf_mode_cfg;
  wire [CFAR_GUARD_CNT_W-1:0]       cf_g_lead_cfg, cf_g_lag_cfg;
  wire [CFAR_REF_CNT_W-1:0]         cf_r_lead_cfg, cf_r_lag_cfg;
  wire [CFAR_ALPHA_W-1:0]           cf_alpha_cfg;
  wire                              cf_status_clear_cfg;

  // ---- history window ----
  wire [REGMAP_HISTORY_N_REGS*32-1:0] unused_hi_csr, unused_hi_pulse;
  wire                                hi_enable_cfg, hi_unsafe_cfg;
  wire [HIST_PORT_W-1:0]              hi_depth_cfg;
  wire                                hi_apply_cfg, hi_cnt_clear_cfg, hi_stky_clear_cfg;

  // ---- pipeline window ----
  wire [REGMAP_PIPELINE_N_REGS*32-1:0] unused_pl_csr, unused_pl_pulse;
  wire        pl_src_enable_cfg, pl_src_run_cfg;
  wire [2:0]  pl_src_mode_cfg;
  wire [31:0] pl_src_gain_cfg, pl_src_seed_cfg;
  wire [15:0] pl_src_tone_cfg, pl_src_ant_cfg;
  wire        pl_src_reseed_cfg;
  wire        pl_algn_enable_cfg, pl_algn_run_cfg, pl_algn_partial_cfg, pl_algn_unsafe_cfg;
  wire [15:0] pl_algn_foff_cfg;
  wire [7:0]  pl_algn_stall_cfg;
  wire        pl_cnt_clear_cfg, pl_stky_clear_cfg;

  // ---------------------------------------------------------------------------
  // The covariance pair table lives in cfg_clk
  //
  // `reg_block_covar` emits one pair-table WRITE at a time. Crossing each write
  // as its own event would need flow control the register map does not declare,
  // and a dropped write would silently re-point one pair. So the whole table is
  // held here, in the register plane's own domain, and crossed as part of the
  // configuration bundle — a table that is always internally consistent, at the
  // cost of `N_COVAR_PAIRS * 16` bits of the bundle.
  // ---------------------------------------------------------------------------
  logic [7:0] pt_x_q [N_COVAR_PAIRS];
  logic [7:0] pt_y_q [N_COVAR_PAIRS];

  always_ff @(posedge cfg_clk) begin
    if (!cfg_rst_n) begin
      // The default table is the upper triangle in index order, so a build with
      // no software present measures a real covariance matrix rather than
      // N_COVAR_PAIRS copies of pair (0,0).
      for (int unsigned p = 0; p < N_COVAR_PAIRS; p++) begin
        pt_x_q[p] <= 8'(default_pair_x(p));
        pt_y_q[p] <= 8'(default_pair_y(p));
      end
    end else if (cv_pt_wr && (cv_pt_idx < 8'(N_COVAR_PAIRS))) begin
      pt_x_q[cv_pt_idx[$clog2(N_COVAR_PAIRS)-1:0]] <= cv_pt_x;
      pt_y_q[cv_pt_idx[$clog2(N_COVAR_PAIRS)-1:0]] <= cv_pt_y;
    end
  end

  function automatic int unsigned default_pair_x(input int unsigned p);
    int unsigned k, x, y;
    k = 0;
    default_pair_x = 0;
    for (x = 0; x < N_BEAMS; x++) begin
      for (y = x + 1; y < N_BEAMS; y++) begin
        if (k == p) default_pair_x = x;
        k = k + 1;
      end
    end
  endfunction

  function automatic int unsigned default_pair_y(input int unsigned p);
    int unsigned k, x, y;
    k = 0;
    default_pair_y = 1;
    for (x = 0; x < N_BEAMS; x++) begin
      for (y = x + 1; y < N_BEAMS; y++) begin
        if (k == p) default_pair_y = y;
        k = k + 1;
      end
    end
  endfunction

  // ---------------------------------------------------------------------------
  // cfg -> core bundle
  // ---------------------------------------------------------------------------
  localparam int unsigned CORE_CFG_W =
      1 + 1 + 3 + 32 + 16 + 16 + 32                       // sources
    + 1 + int'(HIST_PORT_W) + 1                           // history
    + 1 + 1 + int'(COVAR_EXP_K_W) + int'(COVAR_WINDOW_LEN_W)
    + N_COVAR_PAIRS + 2 * N_COVAR_PAIRS * 8               // covariance
    + 1 + int'(CFAR_MODE_W) + 1 + 2 * int'(CFAR_GUARD_CNT_W)
    + 2 * int'(CFAR_REF_CNT_W) + int'(CFAR_ALPHA_W)       // CFAR
    + 1 + 8                                               // global/block enable
    + CORE_STROBES;                                       // section 4a

  // ---------------------------------------------------------------------------
  // 4a. Strobes travel INSIDE the bundle, as toggles (NORMATIVE)
  //
  // A one-cycle strobe and the levels it acts on must not cross independently.
  // `HISTORY_CTRL.DEPTH_APPLY` acts on `HISTORY_DEPTH`; `COVAR_CTRL.FLUSH` acts
  // on the pair table; a `cdc_pulse` is two synchroniser stages and a
  // `cdc_handshake` is a four-phase round trip, so the strobe ALWAYS arrives
  // first and latches the value that was there BEFORE the write. The observed
  // symptom was a history that applied its reset depth of 1 instead of the 16
  // software had just written, and then answered every read out of range — a
  // failure a mile downstream of its cause.
  //
  // So each strobe is a TOGGLE BIT in the configuration bundle. The register
  // plane flips the bit when its pulse fires; the destination edge-detects the
  // bit it received. The strobe and its operands are then one payload of one
  // handshake and cannot be reordered, by construction rather than by timing.
  //
  // The cost is one register per strobe on each side and one bit of bundle. What
  // it buys is that "write the value, then pulse apply" — the sequence every
  // register-map description in this repository tells software to use — means
  // what it says across a clock boundary.
  //
  // Two strobes DELIBERATELY stay outside: `cfg_clk`'s own counter and status
  // clears for blocks in the same domain need no crossing at all. Everything
  // that crosses is here.
  localparam int unsigned CORE_STROBES = 8;
  localparam int unsigned HIST_STROBES = 2;

  logic [CORE_STROBES-1:0] core_tog_q;
  logic [HIST_STROBES-1:0] hist_tog_q;

  wire [CORE_STROBES-1:0] core_pulse_cfg = {
      cf_status_clear_cfg, cv_sat_clear_cfg, cv_flush_cfg, hi_stky_clear_cfg,
      hi_cnt_clear_cfg, hi_apply_cfg, pl_cnt_clear_cfg, pl_src_reseed_cfg
  };
  wire [HIST_STROBES-1:0] hist_pulse_cfg = {pl_stky_clear_cfg, pl_cnt_clear_cfg};

  always_ff @(posedge cfg_clk) begin
    if (!cfg_rst_n) begin
      core_tog_q <= '0;
      hist_tog_q <= '0;
    end else begin
      core_tog_q <= core_tog_q ^ core_pulse_cfg;
      hist_tog_q <= hist_tog_q ^ hist_pulse_cfg;
    end
  end

  logic [CORE_CFG_W-1:0] core_cfg_src;

  always_comb begin
    logic [2*N_COVAR_PAIRS*8-1:0] pt_flat;
    pt_flat = '0;
    for (int unsigned p = 0; p < N_COVAR_PAIRS; p++) begin
      pt_flat[p*8 +: 8]                       = pt_x_q[p];
      pt_flat[N_COVAR_PAIRS*8 + p*8 +: 8]     = pt_y_q[p];
    end
    core_cfg_src = {
        core_tog_q,
        blk_enable_cfg[7:0], global_enable_cfg,
        cf_alpha_cfg, cf_r_lag_cfg, cf_r_lead_cfg, cf_g_lag_cfg, cf_g_lead_cfg,
        cf_out_mode_cfg, cf_mode_cfg, cf_enable_cfg,
        pt_flat, cv_pair_en_cfg[N_COVAR_PAIRS-1:0],
        cv_window_cfg, cv_exp_k_cfg, cv_mode_cfg, cv_enable_cfg,
        hi_unsafe_cfg, hi_depth_cfg, hi_enable_cfg,
        pl_src_seed_cfg, pl_src_ant_cfg, pl_src_tone_cfg, pl_src_gain_cfg,
        pl_src_mode_cfg, pl_src_run_cfg, pl_src_enable_cfg
    };
  end

  wire [CORE_CFG_W-1:0] core_cfg;
  wire                  unused_core_cfg_busy, unused_core_cfg_valid;

  cfg_bundle_cdc #(
      .WIDTH       (CORE_CFG_W),
      .SYNC_STAGES (SYNC_STAGES)
  ) u_cfg_core (
      .src_clk (cfg_clk), .src_rst_n (cfg_rst_n), .src_data (core_cfg_src),
      .src_busy (unused_core_cfg_busy),
      .dst_clk (core_clk), .dst_rst_n (core_rst_n),
      .dst_data (core_cfg), .dst_valid (unused_core_cfg_valid)
  );

  // Unpacking, in the same order as the packing above.
  localparam int unsigned O_SRC_EN   = 0;
  localparam int unsigned O_SRC_RUN  = O_SRC_EN + 1;
  localparam int unsigned O_SRC_MODE = O_SRC_RUN + 1;
  localparam int unsigned O_SRC_GAIN = O_SRC_MODE + 3;
  localparam int unsigned O_SRC_TONE = O_SRC_GAIN + 32;
  localparam int unsigned O_SRC_ANT  = O_SRC_TONE + 16;
  localparam int unsigned O_SRC_SEED = O_SRC_ANT + 16;
  localparam int unsigned O_HI_EN    = O_SRC_SEED + 32;
  localparam int unsigned O_HI_DEPTH = O_HI_EN + 1;
  localparam int unsigned O_HI_UNSAFE= O_HI_DEPTH + int'(HIST_PORT_W);
  localparam int unsigned O_CV_EN    = O_HI_UNSAFE + 1;
  localparam int unsigned O_CV_MODE  = O_CV_EN + 1;
  localparam int unsigned O_CV_K     = O_CV_MODE + 1;
  localparam int unsigned O_CV_WIN   = O_CV_K + int'(COVAR_EXP_K_W);
  localparam int unsigned O_CV_PEN   = O_CV_WIN + int'(COVAR_WINDOW_LEN_W);
  localparam int unsigned O_CV_PT    = O_CV_PEN + N_COVAR_PAIRS;
  localparam int unsigned O_CF_EN    = O_CV_PT + 2 * N_COVAR_PAIRS * 8;
  localparam int unsigned O_CF_MODE  = O_CF_EN + 1;
  localparam int unsigned O_CF_OUT   = O_CF_MODE + int'(CFAR_MODE_W);
  localparam int unsigned O_CF_GLEAD = O_CF_OUT + 1;
  localparam int unsigned O_CF_GLAG  = O_CF_GLEAD + int'(CFAR_GUARD_CNT_W);
  localparam int unsigned O_CF_RLEAD = O_CF_GLAG + int'(CFAR_GUARD_CNT_W);
  localparam int unsigned O_CF_RLAG  = O_CF_RLEAD + int'(CFAR_REF_CNT_W);
  localparam int unsigned O_CF_ALPHA = O_CF_RLAG + int'(CFAR_REF_CNT_W);
  localparam int unsigned O_GLOBAL   = O_CF_ALPHA + int'(CFAR_ALPHA_W);
  localparam int unsigned O_BLK_EN   = O_GLOBAL + 1;
  localparam int unsigned O_STROBE   = O_BLK_EN + 8;

`ifndef SYNTHESIS
  initial begin
    if (O_STROBE + CORE_STROBES != CORE_CFG_W) begin
      $fatal(1, "benchmark_core: core config bundle offsets sum to %0d, width is %0d",
             O_STROBE + CORE_STROBES, CORE_CFG_W);
    end
  end
`endif

  wire        g_en          = core_cfg[O_GLOBAL];
  wire [7:0]  blk_en        = core_cfg[O_BLK_EN +: 8];

  wire        src_enable    = core_cfg[O_SRC_EN] && g_en;
  wire        src_run       = core_cfg[O_SRC_RUN];
  wire [2:0]  src_mode      = core_cfg[O_SRC_MODE +: 3];
  wire [31:0] src_gain      = core_cfg[O_SRC_GAIN +: 32];
  wire [15:0] src_tone      = core_cfg[O_SRC_TONE +: 16];
  wire [15:0] src_ant       = core_cfg[O_SRC_ANT  +: 16];
  wire [31:0] src_seed      = core_cfg[O_SRC_SEED +: 32];

  wire        hi_enable     = core_cfg[O_HI_EN] && g_en && blk_en[6];
  wire [HIST_PORT_W-1:0] hi_depth = core_cfg[O_HI_DEPTH +: HIST_PORT_W];
  wire        hi_unsafe     = core_cfg[O_HI_UNSAFE];

  wire        cv_enable     = core_cfg[O_CV_EN] && g_en && blk_en[3];
  wire        cv_mode       = core_cfg[O_CV_MODE];
  wire [COVAR_EXP_K_W-1:0]      cv_exp_k  = core_cfg[O_CV_K   +: COVAR_EXP_K_W];
  wire [COVAR_WINDOW_LEN_W-1:0] cv_window = core_cfg[O_CV_WIN +: COVAR_WINDOW_LEN_W];
  wire [N_COVAR_PAIRS-1:0]      cv_pair_en_raw = core_cfg[O_CV_PEN +: N_COVAR_PAIRS];
  wire [N_COVAR_PAIRS-1:0]      cv_pair_en = cv_enable ? cv_pair_en_raw : '0;
  wire [2*N_COVAR_PAIRS*8-1:0]  cv_pt      = core_cfg[O_CV_PT  +: 2*N_COVAR_PAIRS*8];

  wire        cf_enable     = core_cfg[O_CF_EN] && g_en && blk_en[4];
  wire [CFAR_MODE_W-1:0]      cf_mode   = core_cfg[O_CF_MODE  +: CFAR_MODE_W];
  wire        cf_out_mode   = core_cfg[O_CF_OUT];
  wire [CFAR_GUARD_CNT_W-1:0] cf_g_lead = core_cfg[O_CF_GLEAD +: CFAR_GUARD_CNT_W];
  wire [CFAR_GUARD_CNT_W-1:0] cf_g_lag  = core_cfg[O_CF_GLAG  +: CFAR_GUARD_CNT_W];
  wire [CFAR_REF_CNT_W-1:0]   cf_r_lead = core_cfg[O_CF_RLEAD +: CFAR_REF_CNT_W];
  wire [CFAR_REF_CNT_W-1:0]   cf_r_lag  = core_cfg[O_CF_RLAG  +: CFAR_REF_CNT_W];
  wire [CFAR_ALPHA_W-1:0]     cf_alpha  = core_cfg[O_CF_ALPHA +: CFAR_ALPHA_W];

  // ---------------------------------------------------------------------------
  // cfg -> history bundle
  // ---------------------------------------------------------------------------
  localparam int unsigned HCFG_W = 1 + 1 + 1 + 1 + 16 + 8 + HIST_STROBES;

  wire [HCFG_W-1:0] hist_cfg_src = {hist_tog_q,
                                    pl_algn_stall_cfg, pl_algn_foff_cfg,
                                    pl_algn_unsafe_cfg, pl_algn_partial_cfg,
                                    pl_algn_run_cfg, pl_algn_enable_cfg};
  wire [HCFG_W-1:0] hist_cfg;
  wire unused_hcfg_busy, unused_hcfg_valid;

  cfg_bundle_cdc #(
      .WIDTH       (HCFG_W),
      .SYNC_STAGES (SYNC_STAGES)
  ) u_cfg_hist (
      .src_clk (cfg_clk), .src_rst_n (cfg_rst_n), .src_data (hist_cfg_src),
      .src_busy (unused_hcfg_busy),
      .dst_clk (history_clk), .dst_rst_n (history_rst_n),
      .dst_data (hist_cfg), .dst_valid (unused_hcfg_valid)
  );

  wire        algn_enable  = hist_cfg[0];
  wire        algn_run     = hist_cfg[1];
  wire        algn_partial = hist_cfg[2];
  wire        algn_unsafe  = hist_cfg[3];
  wire [15:0] algn_foff    = hist_cfg[4 +: 16];
  wire [7:0]  algn_stall   = hist_cfg[20 +: 8];

  // ---------------------------------------------------------------------------
  // One-cycle strobes: one cdc_pulse each, in both directions that need them
  // ---------------------------------------------------------------------------
  // Destination-side edge detection. One register per toggle per domain; a
  // change since the last cycle is the strobe. Every one of them is therefore
  // simultaneous with the levels it acts on (section 4a).
  logic [CORE_STROBES-1:0] core_tog_d_q;
  logic [HIST_STROBES-1:0] hist_tog_d_q;

  wire [CORE_STROBES-1:0] core_tog_rx = core_cfg[O_STROBE +: CORE_STROBES];
  wire [HIST_STROBES-1:0] hist_tog_rx = hist_cfg[HCFG_W-HIST_STROBES +: HIST_STROBES];

  always_ff @(posedge core_clk) begin
    if (!core_rst_n) core_tog_d_q <= '0;
    else             core_tog_d_q <= core_tog_rx;
  end

  always_ff @(posedge history_clk) begin
    if (!history_rst_n) hist_tog_d_q <= '0;
    else                hist_tog_d_q <= hist_tog_rx;
  end

  wire [CORE_STROBES-1:0] core_strobe = core_tog_rx ^ core_tog_d_q;
  wire [HIST_STROBES-1:0] hist_strobe = hist_tog_rx ^ hist_tog_d_q;

  wire src_reseed      = core_strobe[0];
  wire core_cnt_clear  = core_strobe[1];
  wire hi_apply        = core_strobe[2];
  wire hi_cnt_clear    = core_strobe[3];
  wire hi_stky_clear   = core_strobe[4];
  wire cv_flush        = core_strobe[5];
  wire cv_sat_clear    = core_strobe[6];
  wire cf_status_clear = core_strobe[7];

  wire algn_cnt_clear  = hist_strobe[0];
  wire algn_stky_clear = hist_strobe[1];

  // ===========================================================================
  // Front end: sources -> polyphase -> transform -> history write (core_clk)
  // ===========================================================================
  wire [N_ANT-1:0]                 adc_valid, adc_ready;
  wire [N_ANT*FRONT_PAYLOAD_W-1:0] adc_payload;
  wire [TELEM_W-1:0]               src_beats, src_frames, src_stalls;
  wire [7:0]                       unused_src_lanes;
  wire [15:0]                      unused_src_bpf;

  adc_source #(
      .N_ANT       (N_ANT),
      .LANES       (LANES),
      .FFT_SIZE    (FFT_SIZE),
      .STREAM_ID_W (STREAM_ID_W),
      .SEQ_W       (SEQ_W),
      .USER_W      (USER_W),
      .TELEM_W     (TELEM_W)
  ) u_src (
      .clk (core_clk), .rst_n (core_rst_n),
      .cfg_enable        (src_enable),
      .cfg_run           (src_run),
      .cfg_mode          (src_mode),
      .cfg_gain          (src_gain),
      .cfg_tone_step     (src_tone),
      .cfg_ant_step      (src_ant),
      .cfg_lfsr_seed     (src_seed),
      .cfg_lfsr_reseed   (src_reseed),
      .cfg_counter_clear (core_cnt_clear),
      .m_valid (adc_valid), .m_ready (adc_ready), .m_payload (adc_payload),
      .stat_beat_count  (src_beats),
      .stat_frame_count (src_frames),
      .stat_stall_count (src_stalls),
      .obs_lanes (unused_src_lanes), .obs_beats_per_frame (unused_src_bpf)
  );

  wire [N_ANT-1:0]                 fft_valid, fft_ready;
  wire [N_ANT*FRONT_PAYLOAD_W-1:0] fft_payload;
  wire [N_ANT-1:0]                 pfb_wr_ready, pfb_active_bank, pfb_swap_pending;
  wire [N_ANT-1:0]                 pfb_swap_busy, pfb_swap_overrun, pfb_wr_reject;

  for (genvar a = 0; a < int'(N_ANT); a++) begin : g_front
    wire                         p_valid, p_ready;
    wire [FRONT_PAYLOAD_W-1:0]   p_payload;
    wire                         s_valid_i, s_ready_i;
    wire [FRONT_PAYLOAD_W-1:0]   s_payload_i;

    // A skid on the way in to every block boundary, per the ARCHITECTURE.md §6.1
    // elastic-buffer placement rule.
    stream_skid_buffer #(
        .PAYLOAD_W   (FRONT_PAYLOAD_W),
        .DATA_W      (FRONT_DATA_W),
        .STREAM_ID_W (STREAM_ID_W),
        .SEQ_W       (SEQ_W),
        .USER_W      (USER_W)
    ) u_skid_in (
        .clk (core_clk), .rst_n (core_rst_n),
        .s_valid (adc_valid[a]), .s_ready (adc_ready[a]),
        .s_payload (adc_payload[a*FRONT_PAYLOAD_W +: FRONT_PAYLOAD_W]),
        .m_valid (s_valid_i), .m_ready (s_ready_i), .m_payload (s_payload_i)
    );

    wire fxp_flags_t   unused_pfb_sat;
    wire               unused_pfb_satany;
    wire [TELEM_W-1:0] unused_pfb_satc, unused_pfb_sats;
    wire [TELEM_W-1:0] unused_pfb_frm, unused_pfb_frms;

    pfb_bank #(
        .PHASES           (LANES),
        .TAPS             (PFB_TAPS),
        .MULT_PIPE_STAGES (MULT_PIPE_STAGES),
        .MULT_VARIANT     (MULT_VARIANT),
        .ACC_STYLE        (ACC_STYLE),
        .DELAY_STYLE      (DELAY_STYLE),
        .STREAM_ID_W      (STREAM_ID_W),
        .SEQ_W            (SEQ_W),
        .USER_W           (USER_W),
        .SYNC_STAGES      (SYNC_STAGES),
        .TELEM_COUNT_W    (TELEM_W)
    ) u_pfb (
        .core_clk (core_clk), .core_rst_n (core_rst_n),
        .cfg_clk (cfg_clk), .cfg_rst_n (cfg_rst_n),
        .cfg_wr_valid      (coeff_wr_valid),
        .cfg_wr_ready      (pfb_wr_ready[a]),
        .cfg_wr_bank       (coeff_wr_bank),
        .cfg_wr_addr       (coeff_wr_index[COEFF_ADDR_W-1:0]),
        .cfg_wr_data       (coeff_wr_data),
        .cfg_swap_req      (coeff_swap_req),
        .cfg_swap_busy     (pfb_swap_busy[a]),
        .cfg_swap_overrun  (pfb_swap_overrun[a]),
        .cfg_active_bank   (pfb_active_bank[a]),
        .cfg_swap_pending  (pfb_swap_pending[a]),
        .cfg_wr_reject     (pfb_wr_reject[a]),
        .s_valid (s_valid_i), .s_ready (s_ready_i), .s_payload (s_payload_i),
        .m_valid (p_valid), .m_ready (p_ready), .m_payload (p_payload),
        .telem_clear (core_cnt_clear), .telem_snapshot (1'b0),
        .sat_sticky (unused_pfb_sat), .sat_any (unused_pfb_satany),
        .sat_event_count (unused_pfb_satc), .sat_event_snap (unused_pfb_sats),
        .frame_count (unused_pfb_frm), .frame_snap (unused_pfb_frms),
        .core_active_bank  (unused_pfb_core_bank[a]),
        .core_swap_pending (unused_pfb_core_pend[a])
    );

    wire [$clog2(FFT_SIZE)-1:0][1:0] unused_fft_flags;
    wire                             unused_fft_ovf;
    wire [TELEM_W-1:0]               unused_fft_ovfe;

    streaming_fft #(
        .FFT_SIZE          (FFT_SIZE),
        .SAMPLES_PER_CYCLE (LANES),
        .SCALE_SCHED       (FFT_SCALE_SCHED),
        .REORDER           (FFT_REORDER),
        .STREAM_ID_W       (STREAM_ID_W),
        .SEQ_W             (SEQ_W),
        .USER_W            (USER_W),
        .TW_VARIANT        (MULT_VARIANT),
        .TW_PIPE           (MULT_PIPE_STAGES),
        .FLAG_COUNT_W      (TELEM_W)
    ) u_fft (
        .clk (core_clk), .rst_n (core_rst_n),
        .s_valid (p_valid), .s_ready (p_ready), .s_payload (p_payload),
        .m_valid (fft_valid[a]), .m_ready (fft_ready[a]),
        .m_payload (fft_payload[a*FRONT_PAYLOAD_W +: FRONT_PAYLOAD_W]),
        .flags_clear (core_cnt_clear),
        .stage_flags (unused_fft_flags),
        .any_ovf (unused_fft_ovf), .ovf_events (unused_fft_ovfe)
    );
  end

  // The coefficient plane's status reaches software as an OR across antennas
  // (see the `reg_block_coeff` instantiation below). Every antenna holds an
  // identical bank and is written by the same pulse, so the bits are one signal
  // replicated — which `a_bc_coeff_banks_agree` checks — but a build in which one
  // antenna diverged must report busy and reject rather than the majority verdict.

  // ===========================================================================
  // Corner turn and alignment (core_clk write side, history_clk read side)
  // ===========================================================================
  wire [HIST_PORT_W-1:0] hist_depth_active, hist_occupancy;
  wire [31:0] hist_frames_done, hist_overwrite, hist_skew, hist_wbeats;
  wire [31:0] hist_reads, hist_collision, hist_error;
  wire [7:0]  hist_epoch;
  wire [3:0]  hist_fault;
  wire        hist_depth_pending;

  wire                          h_req_valid, h_req_ready;
  wire [HIST_PORT_W-1:0]        h_req_bin, h_req_foff;
  wire                          h_rsp_valid, h_rsp_ready;
  wire [HIST_RD_PAYLOAD_W-1:0]  h_rsp_payload;

  history_core #(
      .N_ANT              (N_ANT),
      .FFT_SIZE           (FFT_SIZE),
      .LANES              (LANES),
      .FRAMES_MAX         (HISTORY_FRAMES),
      .SAMPLE_W           (SAMPLE_W),
      .INPUT_BIT_REVERSED (FFT_REORDER == 0),
      .STORAGE            ("auto"),
      .SYNC_STAGES        (SYNC_STAGES),
      .WR_ID_W            (STREAM_ID_W),
      .WR_SEQ_W           (SEQ_W),
      .WR_USER_W          (USER_W),
      .RD_ID_W            (STREAM_ID_W),
      .RD_SEQ_W           (SEQ_W),
      .RD_USER_W          (USER_W)
  ) u_history (
      .core_clk (core_clk), .core_rst_n (core_rst_n),
      .s_valid (fft_valid), .s_ready (fft_ready), .s_payload (fft_payload),
      .cfg_enable        (hi_enable),
      .cfg_depth         (hi_depth),
      .cfg_depth_apply   (hi_apply),
      .cfg_counter_clear (hi_cnt_clear),
      .cfg_sticky_clear  (hi_stky_clear),
      .cfg_force_unsafe  (hi_unsafe),
      .stat_depth_active     (hist_depth_active),
      .stat_occupancy        (hist_occupancy),
      .stat_frames_done      (hist_frames_done),
      .stat_overwrite_count  (hist_overwrite),
      .stat_skew_count       (hist_skew),
      .stat_write_beat_count (hist_wbeats),
      .stat_read_count       (hist_reads),
      .stat_collision_count  (hist_collision),
      .stat_error_count      (hist_error),
      .stat_epoch            (hist_epoch),
      .stat_fault            (hist_fault),
      .obs_depth_pending     (hist_depth_pending),
      .history_clk (history_clk), .history_rst_n (history_rst_n),
      .rd_req_valid (h_req_valid), .rd_req_ready (h_req_ready),
      .rd_req_bin (h_req_bin), .rd_req_frame_off (h_req_foff),
      .m_valid (h_rsp_valid), .m_ready (h_rsp_ready), .m_payload (h_rsp_payload)
  );

  wire [BIN_PAR-1:0]                    a_req_valid, a_req_ready;
  wire [BIN_PAR*HIST_PORT_W-1:0]        a_req_bin, a_req_foff;
  wire [BIN_PAR-1:0]                    a_rsp_valid, a_rsp_ready;
  wire [BIN_PAR*HIST_RD_PAYLOAD_W-1:0]  a_rsp_payload;
  wire [TELEM_W-1:0]                    rdmux_grants, rdmux_qstall, rdmux_rstall;

  history_rd_mux #(
      .N_PORTS       (BIN_PAR),
      .REQ_DEPTH     (2),
      .ID_DEPTH      (16),
      .RSP_PAYLOAD_W (HIST_RD_PAYLOAD_W),
      .TELEM_W       (TELEM_W)
  ) u_rdmux (
      .clk (history_clk), .rst_n (history_rst_n),
      .s_req_valid (a_req_valid), .s_req_ready (a_req_ready),
      .s_req_bin (a_req_bin), .s_req_frame_off (a_req_foff),
      .s_rsp_valid (a_rsp_valid), .s_rsp_ready (a_rsp_ready),
      .s_rsp_payload (a_rsp_payload),
      .h_req_valid (h_req_valid), .h_req_ready (h_req_ready),
      .h_req_bin (h_req_bin), .h_req_frame_off (h_req_foff),
      .h_rsp_valid (h_rsp_valid), .h_rsp_ready (h_rsp_ready),
      .h_rsp_payload (h_rsp_payload),
      .stat_grant_count     (rdmux_grants),
      .stat_req_stall_count (rdmux_qstall),
      .stat_rsp_stall_count (rdmux_rstall)
  );

  wire                        algn_valid, algn_ready;
  wire [ALIGN_PAYLOAD_W-1:0]  algn_payload;
  wire [TELEM_W-1:0] algn_beats, algn_issues, algn_istall, algn_missing;
  wire [TELEM_W-1:0] algn_dup, algn_orphan, algn_timeout, algn_conflict;
  wire [TELEM_W-1:0] algn_multi, algn_lanewords, algn_inject;
  wire [BIN_PAR-1:0] unused_algn_laneseen;
  wire [ALGN_FAULT_W-1:0] algn_fault;
  wire [7:0] algn_net_sel, algn_net_lat, algn_blk_lat;
  wire [7:0] unused_algn_binpar, unused_algn_groups;

  align_net #(
      .N_ANT       (N_ANT),
      .FFT_SIZE    (FFT_SIZE),
      .LANES       (LANES),
      .FRAMES_MAX  (HISTORY_FRAMES),
      .SAMPLE_W    (SAMPLE_W),
      .BIN_PAR     (BIN_PAR),
      .GROUPS      (ALIGN_GROUPS),
      .NET_SEL     (NET_SEL),
      .MUX_STAGES  (MUX_STAGES),
      // THE DEFAULT TIMEOUT IS WRONG FOR THIS TOPOLOGY, and this is the
      // measurement rather than a precaution. `algn_default_timeout` is
      // `GROUPS * (read_latency + net_latency) + 16`, derived on issue #16's
      // assumption of BIN_PAR INDEPENDENT history read ports. This design has
      // one, multiplexed (rtl/top/history_rd_mux.sv 1), so a group's requests
      // are served one per cycle behind every other open group's: the worst wait
      // is `GROUPS * BIN_PAR` forwarded requests plus one round trip, not one
      // round trip per group. At the medium geometry the default is 44 cycles
      // against a worst case near 90, and a live run reported 36 missing-sample
      // timeouts and 36 orphaned responses in twenty-four sweeps — the detector
      // firing on its own arbitration rather than on a lost sample.
      //
      // The bound below is that arithmetic with a factor of safety, and it is
      // stated here rather than changed in align_pkg because it is a property of
      // how THIS top wires the block, not of the block.
      .TIMEOUT_CYCLES (ALIGN_TIMEOUT),
      .RD_ID_W     (STREAM_ID_W),
      .RD_SEQ_W    (SEQ_W),
      .RD_USER_W   (USER_W),
      .STREAM_ID_W (STREAM_ID_W),
      .SEQ_W       (SEQ_W),
      .USER_W      (USER_W),
      .TELEM_W     (TELEM_W)
  ) u_align (
      .clk (history_clk), .rst_n (history_rst_n),
      .cfg_enable        (algn_enable),
      .cfg_run           (algn_run),
      .cfg_frame_off     (algn_foff),
      .cfg_partial_pass  (algn_partial),
      .cfg_counter_clear (algn_cnt_clear),
      .cfg_sticky_clear  (algn_stky_clear),
      .cfg_lane_stall    (algn_stall[BIN_PAR-1:0]),
      .cfg_force_unsafe  (algn_unsafe),
      .rd_req_valid (a_req_valid), .rd_req_ready (a_req_ready),
      .rd_req_bin (a_req_bin), .rd_req_frame_off (a_req_foff),
      .rsp_valid (a_rsp_valid), .rsp_ready (a_rsp_ready), .rsp_payload (a_rsp_payload),
      .m_valid (algn_valid), .m_ready (algn_ready), .m_payload (algn_payload),
      .stat_beat_count         (algn_beats),
      .stat_issue_count        (algn_issues),
      .stat_issue_stall_count  (algn_istall),
      .stat_missing_count      (algn_missing),
      .stat_dup_count          (algn_dup),
      .stat_orphan_count       (algn_orphan),
      .stat_timeout_count      (algn_timeout),
      .stat_conflict_count     (algn_conflict),
      .stat_multi_lane_count   (algn_multi),
      .stat_lane_word_count    (algn_lanewords),
      .stat_lane_seen          (unused_algn_laneseen),
      .stat_inject_count       (algn_inject),
      .stat_fault              (algn_fault),
      .obs_net_sel       (algn_net_sel),
      .obs_net_latency   (algn_net_lat),
      .obs_block_latency (algn_blk_lat),
      .obs_bin_par       (unused_algn_binpar),
      .obs_groups        (unused_algn_groups)
  );

  // ---- the history_clk / core_clk datapath seam ----
  wire                       bf_in_valid, bf_in_ready;
  wire [ALIGN_PAYLOAD_W-1:0] bf_in_payload;
  wire [$clog2(CDC_DEPTH+1)-1:0] unused_cdc_socc, unused_cdc_shw;
  wire [$clog2(CDC_DEPTH+1)-1:0] unused_cdc_mocc, unused_cdc_mhw;
  wire unused_cdc_af, unused_cdc_ovf, unused_cdc_unf;

  stream_cdc #(
      .PAYLOAD_W   (ALIGN_PAYLOAD_W),
      .DEPTH       (CDC_DEPTH),
      .SYNC_STAGES (SYNC_STAGES),
      .OUT_REG     (1'b1),
      .STORAGE     ("regs"),
      .DATA_W      (ALIGN_DATA_W),
      .STREAM_ID_W (STREAM_ID_W),
      .SEQ_W       (SEQ_W),
      .USER_W      (USER_W)
  ) u_cdc_align (
      .s_clk (history_clk), .s_rst_n (history_rst_n),
      .s_valid (algn_valid), .s_ready (algn_ready), .s_payload (algn_payload),
      .s_occupancy (unused_cdc_socc), .s_high_water (unused_cdc_shw),
      .s_almost_full (unused_cdc_af), .s_overflow_sticky (unused_cdc_ovf),
      .s_sticky_clear (algn_stky_clear),
      .m_clk (core_clk), .m_rst_n (core_rst_n),
      .m_valid (bf_in_valid), .m_ready (bf_in_ready), .m_payload (bf_in_payload),
      .m_occupancy (unused_cdc_mocc), .m_high_water (unused_cdc_mhw),
      .m_underflow_sticky (unused_cdc_unf), .m_sticky_clear (hi_stky_clear)
  );

  // ===========================================================================
  // Back end: beamformer -> serializer -> power/covariance -> CFAR (core_clk)
  // ===========================================================================
  wire                     bf_valid, bf_ready;
  wire [BF_PAYLOAD_W-1:0]  bf_payload;
  wire fxp_flags_t         unused_bf_sat;
  wire                     unused_bf_satany;
  wire [TELEM_W-1:0]       unused_bf_satc, unused_bf_sats;
  wire [TELEM_W-1:0]       unused_bf_frm, unused_bf_frms;
  wire                     wgt_active_bank, wgt_swap_pending, wgt_swap_busy;
  wire                     wgt_wr_ready;
  wire                     wgt_swap_overrun, wgt_wr_reject;
  wire [7:0]               tput_n_ant, tput_n_beams, tput_bin_par, tput_beam_par;
  wire [7:0]               tput_beam_mux;
  wire [15:0]              tput_bbpc;

  beamformer #(
      .N_ANT            (N_ANT),
      .N_BEAMS          (N_BEAMS),
      .BIN_PAR          (BIN_PAR),
      .BEAM_PAR         (BEAM_PAR),
      .MULT_PIPE_STAGES (MULT_PIPE_STAGES),
      .MULT_VARIANT     (MULT_VARIANT),
      .ADD_REG_EVERY    (ADD_REG_EVERY),
      .STREAM_ID_W      (STREAM_ID_W),
      .SEQ_W            (SEQ_W),
      .USER_W           (USER_W),
      .SYNC_STAGES      (SYNC_STAGES),
      .TELEM_COUNT_W    (TELEM_W)
  ) u_bf (
      .core_clk (core_clk), .core_rst_n (core_rst_n),
      .cfg_clk (cfg_clk), .cfg_rst_n (cfg_rst_n),
      .cfg_wr_valid     (wgt_wr_valid),
      .cfg_wr_ready     (wgt_wr_ready),
      .cfg_wr_bank      (wgt_wr_bank),
      .cfg_wr_addr      (wgt_wr_index[WGT_ADDR_W-1:0]),
      .cfg_wr_data      (wgt_wr_data),
      .cfg_swap_req     (wgt_swap_req),
      .cfg_swap_busy    (wgt_swap_busy),
      .cfg_swap_overrun (wgt_swap_overrun),
      .cfg_active_bank  (wgt_active_bank),
      .cfg_swap_pending (wgt_swap_pending),
      .cfg_wr_reject    (wgt_wr_reject),
      .s_valid (bf_in_valid), .s_ready (bf_in_ready), .s_payload (bf_in_payload),
      .m_valid (bf_valid), .m_ready (bf_ready), .m_payload (bf_payload),
      .telem_clear (core_cnt_clear), .telem_snapshot (1'b0),
      .sat_sticky (unused_bf_sat), .sat_any (unused_bf_satany),
      .sat_event_count (unused_bf_satc), .sat_event_snap (unused_bf_sats),
      .frame_count (unused_bf_frm), .frame_snap (unused_bf_frms),
      .core_active_bank (unused_bf_core_bank),
      .core_swap_pending (unused_bf_core_pend),
      .tput_n_ant (tput_n_ant), .tput_n_beams (tput_n_beams),
      .tput_bin_par (tput_bin_par), .tput_beam_par (tput_beam_par),
      .tput_beam_mux (tput_beam_mux), .tput_beam_bins_per_cycle (tput_bbpc)
  );

  wire                     bin_valid, bin_ready;
  wire [BIN_PAYLOAD_W-1:0] bin_payload;
  wire [15:0]              unused_bin_index;

  bin_serializer #(
      .N_BEAMS     (N_BEAMS),
      .BEAM_PAR    (BEAM_PAR),
      .BIN_PAR     (BIN_PAR),
      .STREAM_ID_W (STREAM_ID_W),
      .SEQ_W       (SEQ_W),
      .USER_W      (USER_W)
  ) u_binser (
      .clk (core_clk), .rst_n (core_rst_n),
      .s_valid (bf_valid), .s_ready (bf_ready), .s_payload (bf_payload),
      .m_valid (bin_valid), .m_ready (bin_ready), .m_payload (bin_payload),
      .obs_bin_index (unused_bin_index)
  );

  stream_fields_t bin_f;
  assign bin_f = stream_unpack(
      stream_geom(stream_pkg::uint_t'(BIN_DATA_W), stream_pkg::uint_t'(STREAM_ID_W),
                  stream_pkg::uint_t'(SEQ_W), stream_pkg::uint_t'(USER_W)),
      STREAM_MAX_PAYLOAD_W'(bin_payload));

  // ---- SPEC 7.6 cross-power, tapped off the serialized beat ----
  //
  // A TAP and not a stage: `covar_engine` has no `ready` and never back
  // pressures (ARCHITECTURE.md §3.5, "Flow control"), so it observes the beats
  // the power stage accepts and cannot alter the pipeline's rate. Its sources
  // are the BEAMS of one frequency bin, which is the parallel source vector its
  // input contract asks for.
  wire [N_COVAR_PAIRS-1:0]  cv_valid;
  wire [N_COVAR_PAIRS*COVAR_POWER_W-1:0] cv_acc_re, cv_acc_im;
  wire [N_COVAR_PAIRS*COVAR_WINDOW_ID_W-1:0] unused_cv_wid;
  wire [N_COVAR_PAIRS*COVAR_WINDOW_LEN_W-1:0] unused_cv_sc;
  wire [N_COVAR_PAIRS-1:0]  unused_cv_flushed, unused_cv_trunc, unused_cv_sat;
  wire                      cv_sat_any;
  wire [TELEM_W-1:0]        cv_sat_count;
  wire [N_COVAR_PAIRS*8-1:0] unused_cv_obs_x, unused_cv_obs_y;
  wire [N_COVAR_PAIRS-1:0]  unused_cv_obs_en;

  covar_engine #(
      .N_SRC             (N_BEAMS),
      .N_PAIRS           (N_COVAR_PAIRS),
      .CMULT_VARIANT     (MULT_VARIANT),
      .CMULT_PIPE_STAGES (MULT_PIPE_STAGES),
      .ACC_W             (COVAR_POWER_W),
      .WINDOW_W          (COVAR_WINDOW_LEN_W),
      .SAT_COUNT_W       (TELEM_W),
      .SEL_W             (8)
  ) u_covar (
      .clk (core_clk), .rst_n (core_rst_n),
      .valid_in (bin_valid && bin_ready),
      .src      (bin_f.data[BIN_DATA_W-1:0]),
      .cfg_pair_x (cv_pt[N_COVAR_PAIRS*8-1:0]),
      .cfg_pair_y (cv_pt[2*N_COVAR_PAIRS*8-1:N_COVAR_PAIRS*8]),
      .cfg_pair_enable (cv_pair_en),
      .cfg_window_len (cv_window),
      .cfg_mode (cv_mode),
      .cfg_exp_k (cv_exp_k),
      .flush (cv_flush),
      .sat_clear (cv_sat_clear),
      .pair_valid (cv_valid),
      .pair_acc_re (cv_acc_re), .pair_acc_im (cv_acc_im),
      .pair_window_id (unused_cv_wid), .pair_sample_count (unused_cv_sc),
      .pair_flushed (unused_cv_flushed), .pair_truncated (unused_cv_trunc),
      .pair_sat (unused_cv_sat), .sat_any (cv_sat_any), .sat_count_max (cv_sat_count),
      .obs_pair_x (unused_cv_obs_x), .obs_pair_y (unused_cv_obs_y),
      .obs_pair_enable (unused_cv_obs_en)
  );

  // ---- power and its time integration ----
  wire                     pwr_valid, pwr_ready;
  wire [PWR_PAYLOAD_W-1:0] pwr_payload;
  wire [N_BEAMS-1:0]       pw_valid, pw_flushed, pw_trunc;
  wire [N_BEAMS*COVAR_POWER_W-1:0] pw_acc;
  wire [COVAR_WINDOW_ID_W-1:0]     pw_wid;
  wire                     pw_sat_any;
  wire [TELEM_W-1:0]       pw_sat_count;
  wire [7:0]               unused_pw_lat;

  power_stage #(
      .N_BEAMS     (N_BEAMS),
      .PIPE_STAGES (POWER_PIPE),
      .STREAM_ID_W (STREAM_ID_W),
      .SEQ_W       (SEQ_W),
      .USER_W      (USER_W),
      .ACC_W       (COVAR_POWER_W),
      .WINDOW_W    (COVAR_WINDOW_LEN_W),
      .SAT_COUNT_W (TELEM_W)
  ) u_power (
      .clk (core_clk), .rst_n (core_rst_n),
      .s_valid (bin_valid), .s_ready (bin_ready), .s_payload (bin_payload),
      .m_valid (pwr_valid), .m_ready (pwr_ready), .m_payload (pwr_payload),
      .cfg_window_len  (cv_window),
      .cfg_mode        (cv_mode),
      .cfg_exp_k       (cv_exp_k),
      .cfg_beam_enable ({N_BEAMS{cv_enable}}),
      .flush           (cv_flush),
      .sat_clear       (cv_sat_clear),
      .pwr_valid (pw_valid), .pwr_acc (pw_acc), .pwr_window_id (pw_wid),
      .pwr_flushed (pw_flushed), .pwr_truncated (pw_trunc),
      .pwr_sat_any (pw_sat_any), .pwr_sat_count (pw_sat_count),
      .obs_latency (unused_pw_lat)
  );

  // ---- detection ----
  wire [TELEM_W-1:0] cf_det, cf_sup, cf_frames, cf_events;
  wire [5:0]         cf_fault;
  wire               cf_pending, cf_open;
  wire [CFAR_GUARD_CNT_W-1:0] unused_cf_mg;
  wire [CFAR_REF_CNT_W-1:0]   unused_cf_mr;

  cfar_bank #(
      .N_BEAMS     (N_BEAMS),
      .MAX_GUARD   (CFAR_MAX_GUARD),
      .MAX_REF     (CFAR_MAX_REF),
      .OUT_DEPTH   (8),
      .STREAM_ID_W (STREAM_ID_W),
      .SEQ_W       (SEQ_W),
      .USER_W      (USER_W),
      .TELEM_W     (TELEM_W)
  ) u_cfar (
      .clk (core_clk), .rst_n (core_rst_n),
      .s_valid (pwr_valid), .s_ready (pwr_ready), .s_payload (pwr_payload),
      .m_valid (ev_valid), .m_ready (ev_ready), .m_payload (ev_payload),
      .cfg_enable       (cf_enable),
      .cfg_mode         (cf_mode),
      .cfg_out_mode     (cf_out_mode),
      .cfg_guard_lead   (cf_g_lead),
      .cfg_guard_lag    (cf_g_lag),
      .cfg_ref_lead     (cf_r_lead),
      .cfg_ref_lag      (cf_r_lag),
      .cfg_alpha        (cf_alpha),
      .cfg_status_clear (cf_status_clear),
      .stat_det_count   (cf_det),
      .stat_sup_count   (cf_sup),
      .stat_frame_count (cf_frames),
      .stat_event_count (cf_events),
      .stat_fault       (cf_fault),
      .obs_cfg_pending  (cf_pending),
      .obs_frame_open   (cf_open),
      .obs_max_guard    (unused_cf_mg),
      .obs_max_ref      (unused_cf_mr)
  );

  // ===========================================================================
  // Status bundles back to cfg_clk
  // ===========================================================================
  localparam int unsigned CORE_ST_W =
      2 * int'(HIST_PORT_W) + 7 * 32 + 8 + 4 + 1     // history
    + 3 * 32                                          // source counters
    + 3 * 32 + 32 + 6 + 1 + 1                        // CFAR
    + int'(COVAR_WINDOW_ID_W) + 1 + 1 + 1 + 32;      // covariance and power

  wire [CORE_ST_W-1:0] core_st_src = {
      pw_sat_count, (|pw_trunc), pw_sat_any, cv_sat_any, pw_wid,
      cf_open, cf_pending, cf_fault, cf_events, cf_frames, cf_sup, cf_det,
      src_stalls, src_frames, src_beats,
      hist_depth_pending, hist_fault, hist_epoch,
      hist_error, hist_collision, hist_reads, hist_wbeats,
      hist_skew, hist_overwrite, hist_frames_done,
      hist_occupancy, hist_depth_active
  };

  wire [CORE_ST_W-1:0] core_st;
  wire unused_core_st_busy, unused_core_st_valid;

  cfg_bundle_cdc #(
      .WIDTH       (CORE_ST_W),
      .SYNC_STAGES (SYNC_STAGES)
  ) u_st_core (
      .src_clk (core_clk), .src_rst_n (core_rst_n), .src_data (core_st_src),
      .src_busy (unused_core_st_busy),
      .dst_clk (cfg_clk), .dst_rst_n (cfg_rst_n),
      .dst_data (core_st), .dst_valid (unused_core_st_valid)
  );

  localparam int unsigned S_HDA   = 0;
  localparam int unsigned S_HOCC  = S_HDA + int'(HIST_PORT_W);
  localparam int unsigned S_HFD   = S_HOCC + int'(HIST_PORT_W);
  localparam int unsigned S_HOVR  = S_HFD + 32;
  localparam int unsigned S_HSKW  = S_HOVR + 32;
  localparam int unsigned S_HWB   = S_HSKW + 32;
  localparam int unsigned S_HRD   = S_HWB + 32;
  localparam int unsigned S_HCOL  = S_HRD + 32;
  localparam int unsigned S_HERR  = S_HCOL + 32;
  localparam int unsigned S_HEPO  = S_HERR + 32;
  localparam int unsigned S_HFLT  = S_HEPO + 8;
  localparam int unsigned S_HPEND = S_HFLT + 4;
  localparam int unsigned S_SBEAT = S_HPEND + 1;
  localparam int unsigned S_SFRM  = S_SBEAT + 32;
  localparam int unsigned S_SSTL  = S_SFRM + 32;
  localparam int unsigned S_CDET  = S_SSTL + 32;
  localparam int unsigned S_CSUP  = S_CDET + 32;
  localparam int unsigned S_CFRM  = S_CSUP + 32;
  localparam int unsigned S_CEV   = S_CFRM + 32;
  localparam int unsigned S_CFLT  = S_CEV + 32;
  localparam int unsigned S_CPEND = S_CFLT + 6;
  localparam int unsigned S_COPEN = S_CPEND + 1;
  localparam int unsigned S_PWID  = S_COPEN + 1;
  localparam int unsigned S_CVSAT = S_PWID + int'(COVAR_WINDOW_ID_W);
  localparam int unsigned S_PWSAT = S_CVSAT + 1;
  localparam int unsigned S_PWTRC = S_PWSAT + 1;
  localparam int unsigned S_PWCNT = S_PWTRC + 1;

`ifndef SYNTHESIS
  initial begin
    if (S_PWCNT + 32 != CORE_ST_W) begin
      $fatal(1, "benchmark_core: core status bundle offsets sum to %0d, width is %0d",
             S_PWCNT + 32, CORE_ST_W);
    end
  end
`endif

  // ---- history_clk -> cfg_clk ----
  localparam int unsigned HIST_ST_W = 9 * 32 + int'(ALGN_FAULT_W) + 2 * 32;

  wire [HIST_ST_W-1:0] hist_st_src = {
      rdmux_qstall, rdmux_grants, algn_fault,
      algn_multi, algn_conflict, algn_timeout, algn_orphan,
      algn_dup, algn_missing, algn_istall, algn_issues, algn_beats
  };
  wire [HIST_ST_W-1:0] hist_st;
  wire unused_hist_st_busy, unused_hist_st_valid;

  cfg_bundle_cdc #(
      .WIDTH       (HIST_ST_W),
      .SYNC_STAGES (SYNC_STAGES)
  ) u_st_hist (
      .src_clk (history_clk), .src_rst_n (history_rst_n), .src_data (hist_st_src),
      .src_busy (unused_hist_st_busy),
      .dst_clk (cfg_clk), .dst_rst_n (cfg_rst_n),
      .dst_data (hist_st), .dst_valid (unused_hist_st_valid)
  );

  localparam int unsigned A_BEAT = 0;
  localparam int unsigned A_ISS  = A_BEAT + 32;
  localparam int unsigned A_STL  = A_ISS  + 32;
  localparam int unsigned A_MIS  = A_STL  + 32;
  localparam int unsigned A_DUP  = A_MIS  + 32;
  localparam int unsigned A_ORP  = A_DUP  + 32;
  localparam int unsigned A_TO   = A_ORP  + 32;
  localparam int unsigned A_CONF = A_TO   + 32;
  localparam int unsigned A_MULT = A_CONF + 32;
  localparam int unsigned A_FLT  = A_MULT + 32;
  localparam int unsigned A_GRNT = A_FLT  + int'(ALGN_FAULT_W);
  localparam int unsigned A_QSTL = A_GRNT + 32;

  // The alignment network's own architecture echo is elaboration-constant, so it
  // is read directly rather than crossed: a constant has no coherence problem.
  wire [31:0] unused_algn_conflict_cfg = hist_st[A_CONF +: 32];

  // ===========================================================================
  // The remaining register windows (cfg_clk), now that their hardware sides exist
  // ===========================================================================
  reg_block_coeff #(.IDX_W (IDX_W)) u_reg_coeff (
      .clk (cfg_clk), .rst_n (cfg_rst_n),
      .sel (blk_sel[REGMAP_COEFF_INDEX]),
      .write_enable (blk_write_enable), .read_enable (blk_read_enable),
      .index (blk_index), .write_data (blk_write_data), .byte_enable (blk_byte_enable),
      .read_data (blk_read_data[REGMAP_COEFF_INDEX*REG_DATA_W +: REG_DATA_W]),
      .ready (blk_ready[REGMAP_COEFF_INDEX]), .error (blk_error[REGMAP_COEFF_INDEX]),
      .wr_valid (coeff_wr_valid), .wr_bank (coeff_wr_bank),
      .wr_index (coeff_wr_index), .wr_data (coeff_wr_data),
      .swap_req (coeff_swap_req), .status_clear (coeff_status_clear),
      .hw_active_bank  (pfb_active_bank[0]),
      .hw_swap_pending (|pfb_swap_pending),
      .hw_wr_busy      (~(&pfb_wr_ready)),
      .hw_swap_busy    (|pfb_swap_busy),
      .hw_wr_reject    (|pfb_wr_reject),
      .hw_swap_overrun (|pfb_swap_overrun),
      .hw_n_coeff      (16'(LANES * PFB_TAPS)),
      .wwr_valid (wgt_wr_valid), .wwr_bank (wgt_wr_bank),
      .wwr_index (wgt_wr_index), .wwr_data (wgt_wr_data),
      .wswap_req (wgt_swap_req), .wstatus_clear (wgt_status_clear),
      .hw_w_active_bank  (wgt_active_bank),
      .hw_w_swap_pending (wgt_swap_pending),
      // WEIGHT_STATUS.WR_BUSY is the weight plane's FLOW CONTROL, not decoration:
      // a write crosses cfg_clk to core_clk on a four-phase handshake, and a
      // second WEIGHT_DATA write issued while the first is still in flight is
      // DROPPED by the bank. Tying this to zero told software the plane was
      // always free, so a bank load wrote its first weight and silently lost
      // every one after it — a beamformer whose matrix was one weight and
      // fifteen zeros, which looks exactly like a beam that does not steer.
      .hw_w_wr_busy      (~wgt_wr_ready),
      .hw_w_swap_busy    (wgt_swap_busy),
      .hw_w_wr_reject    (wgt_wr_reject),
      .hw_w_swap_overrun (wgt_swap_overrun),
      .hw_n_weights      (16'(N_BEAMS * N_ANT)),
      .hw_n_antennas     (tput_n_ant),
      .hw_n_beams        (tput_n_beams),
      .hw_bin_par        (tput_bin_par),
      .hw_beam_par       (tput_beam_par),
      .hw_beam_mux       (tput_beam_mux),
      .hw_beam_bins_per_cycle (tput_bbpc),
      .csr (unused_co_csr), .pulse (unused_co_pulse)
  );

  reg_block_covar #(.IDX_W (IDX_W)) u_reg_covar (
      .clk (cfg_clk), .rst_n (cfg_rst_n),
      .sel (blk_sel[REGMAP_COVAR_INDEX]),
      .write_enable (blk_write_enable), .read_enable (blk_read_enable),
      .index (blk_index), .write_data (blk_write_data), .byte_enable (blk_byte_enable),
      .read_data (blk_read_data[REGMAP_COVAR_INDEX*REG_DATA_W +: REG_DATA_W]),
      .ready (blk_ready[REGMAP_COVAR_INDEX]), .error (blk_error[REGMAP_COVAR_INDEX]),
      .cfg_enable (cv_enable_cfg), .cfg_mode (cv_mode_cfg), .cfg_exp_k (cv_exp_k_cfg),
      .cfg_window_len (cv_window_cfg), .cfg_pair_enable (cv_pair_en_cfg),
      .cfg_flush (cv_flush_cfg), .cfg_sat_clear (cv_sat_clear_cfg),
      .pt_wr_valid (cv_pt_wr), .pt_wr_index (cv_pt_idx),
      .pt_wr_x (cv_pt_x), .pt_wr_y (cv_pt_y),
      .hw_window_id (core_st[S_PWID +: COVAR_WINDOW_ID_W]),
      .hw_n_pairs   (8'(N_COVAR_PAIRS)),
      .hw_acc_w     (8'(COVAR_POWER_W)),
      .hw_sat_power (core_st[S_PWSAT]),
      .hw_sat_cross (core_st[S_CVSAT]),
      .hw_truncated (core_st[S_PWTRC]),
      .hw_sat_count (core_st[S_PWCNT +: 32]),
      .csr (unused_cv_csr), .pulse (unused_cv_pulse)
  );

  reg_block_cfar #(.IDX_W (IDX_W)) u_reg_cfar (
      .clk (cfg_clk), .rst_n (cfg_rst_n),
      .sel (blk_sel[REGMAP_CFAR_INDEX]),
      .write_enable (blk_write_enable), .read_enable (blk_read_enable),
      .index (blk_index), .write_data (blk_write_data), .byte_enable (blk_byte_enable),
      .read_data (blk_read_data[REGMAP_CFAR_INDEX*REG_DATA_W +: REG_DATA_W]),
      .ready (blk_ready[REGMAP_CFAR_INDEX]), .error (blk_error[REGMAP_CFAR_INDEX]),
      .cfg_enable (cf_enable_cfg), .cfg_mode (cf_mode_cfg),
      .cfg_out_mode (cf_out_mode_cfg),
      .cfg_guard_lead (cf_g_lead_cfg), .cfg_guard_lag (cf_g_lag_cfg),
      .cfg_ref_lead (cf_r_lead_cfg), .cfg_ref_lag (cf_r_lag_cfg),
      .cfg_alpha (cf_alpha_cfg), .cfg_status_clear (cf_status_clear_cfg),
      .hw_max_guard    (8'(CFAR_MAX_GUARD)),
      .hw_max_ref      (8'(CFAR_MAX_REF)),
      .hw_cfg_pending  (core_st[S_CPEND]),
      .hw_frame_open   (core_st[S_COPEN]),
      .hw_alpha_frac_w (8'(CFAR_ALPHA_FRAC_W)),
      .hw_event_w      (16'(CFAR_EVENT_W)),
      .hw_power_w      (8'(CFAR_POWER_W)),
      .hw_sum_w        (8'(cfar_sum_w(cfar_uint_t'(CFAR_MAX_REF)))),
      .hw_det_count    (core_st[S_CDET +: 32]),
      .hw_sup_count    (core_st[S_CSUP +: 32]),
      .hw_frame_count  (core_st[S_CFRM +: 32]),
      .hw_fault        (core_st[S_CFLT +: 6]),
      .csr (unused_cf_csr), .pulse (unused_cf_pulse)
  );

  reg_block_history #(
      .IDX_W      (IDX_W),
      .FRAMES_MAX (HISTORY_FRAMES),
      .FFT_SIZE   (FFT_SIZE),
      .N_ANT      (N_ANT),
      .LANES      (LANES)
  ) u_reg_history (
      .clk (cfg_clk), .rst_n (cfg_rst_n),
      .sel (blk_sel[REGMAP_HISTORY_INDEX]),
      .write_enable (blk_write_enable), .read_enable (blk_read_enable),
      .index (blk_index), .write_data (blk_write_data), .byte_enable (blk_byte_enable),
      .read_data (blk_read_data[REGMAP_HISTORY_INDEX*REG_DATA_W +: REG_DATA_W]),
      .ready (blk_ready[REGMAP_HISTORY_INDEX]), .error (blk_error[REGMAP_HISTORY_INDEX]),
      .cfg_enable (hi_enable_cfg), .cfg_depth (hi_depth_cfg),
      .cfg_depth_apply (hi_apply_cfg), .cfg_counter_clear (hi_cnt_clear_cfg),
      .cfg_sticky_clear (hi_stky_clear_cfg), .cfg_force_unsafe (hi_unsafe_cfg),
      .hw_depth_active     (core_st[S_HDA  +: REGMAP_HISTORY_HISTORY_STATUS_DEPTH_ACTIVE_WIDTH]),
      .hw_occupancy        (core_st[S_HOCC +: REGMAP_HISTORY_HISTORY_STATUS_OCCUPANCY_WIDTH]),
      .hw_epoch            (core_st[S_HEPO +: 8]),
      .hw_depth_pending    (core_st[S_HPEND]),
      .hw_n_ant            (8'(N_ANT)),
      .hw_lanes            (8'(LANES)),
      .hw_frames_max       (REGMAP_HISTORY_HISTORY_GEOMETRY_FRAMES_MAX_WIDTH'(HISTORY_FRAMES)),
      .hw_bit_reversed     (FFT_REORDER == 0),
      .hw_fft_size         (16'(FFT_SIZE)),
      .hw_n_banks          (16'(N_ANT * LANES)),
      .hw_frames_done      (core_st[S_HFD  +: 32]),
      .hw_overwrite_count  (core_st[S_HOVR +: 32]),
      .hw_collision_count  (core_st[S_HCOL +: 32]),
      .hw_error_count      (core_st[S_HERR +: 32]),
      .hw_read_count       (core_st[S_HRD  +: 32]),
      .hw_write_beat_count (core_st[S_HWB  +: 32]),
      .hw_skew_count       (core_st[S_HSKW +: 32]),
      .hw_fault            (core_st[S_HFLT +: 4]),
      .csr (unused_hi_csr), .pulse (unused_hi_pulse)
  );

  reg_block_pipeline #(
      .IDX_W        (IDX_W),
      .BIN_PAR      (BIN_PAR),
      .ALIGN_GROUPS (ALIGN_GROUPS),
      .LANES        (LANES)
  ) u_reg_pipeline (
      .clk (cfg_clk), .rst_n (cfg_rst_n),
      .sel (blk_sel[REGMAP_PIPELINE_INDEX]),
      .write_enable (blk_write_enable), .read_enable (blk_read_enable),
      .index (blk_index), .write_data (blk_write_data), .byte_enable (blk_byte_enable),
      .read_data (blk_read_data[REGMAP_PIPELINE_INDEX*REG_DATA_W +: REG_DATA_W]),
      .ready (blk_ready[REGMAP_PIPELINE_INDEX]), .error (blk_error[REGMAP_PIPELINE_INDEX]),
      .cfg_src_enable (pl_src_enable_cfg), .cfg_src_run (pl_src_run_cfg),
      .cfg_src_mode (pl_src_mode_cfg), .cfg_src_gain (pl_src_gain_cfg),
      .cfg_src_tone_step (pl_src_tone_cfg), .cfg_src_ant_step (pl_src_ant_cfg),
      .cfg_src_seed (pl_src_seed_cfg), .cfg_src_reseed (pl_src_reseed_cfg),
      .cfg_align_enable (pl_algn_enable_cfg), .cfg_align_run (pl_algn_run_cfg),
      .cfg_align_partial (pl_algn_partial_cfg), .cfg_align_unsafe (pl_algn_unsafe_cfg),
      .cfg_align_frame_off (pl_algn_foff_cfg), .cfg_align_lane_stall (pl_algn_stall_cfg),
      .cfg_counter_clear (pl_cnt_clear_cfg), .cfg_status_clear (pl_stky_clear_cfg),
      .hw_src_beats  (core_st[S_SBEAT +: 32]),
      .hw_src_frames (core_st[S_SFRM  +: 32]),
      .hw_src_stalls (core_st[S_SSTL  +: 32]),
      .hw_align_beats   (hist_st[A_BEAT +: 32]),
      .hw_align_stalls  (hist_st[A_STL  +: 32]),
      .hw_align_missing (hist_st[A_MIS  +: 32]),
      .hw_align_dup     (hist_st[A_DUP  +: 32]),
      .hw_align_orphan  (hist_st[A_ORP  +: 32]),
      .hw_align_timeout (hist_st[A_TO   +: 32]),
      .hw_align_multi   (hist_st[A_MULT +: 32]),
      .hw_align_fault   (hist_st[A_FLT  +: ALGN_FAULT_W]),
      .hw_net_sel       (algn_net_sel),
      .hw_net_latency   (algn_net_lat),
      .hw_block_latency (algn_blk_lat),
      .hw_rdmux_grants  (hist_st[A_GRNT +: 32]),
      .hw_rdmux_stalls  (hist_st[A_QSTL +: 32]),
      .hw_events        (core_st[S_CEV  +: 32]),
      .hw_bin_par      (8'(BIN_PAR)),
      .hw_align_groups (8'(ALIGN_GROUPS)),
      .hw_lanes        (8'(LANES)),
      .hw_rd_ports     (8'd1),
      .hw_lat_pfb_cycles (8'(LAT_PFB_CYC)),
      .hw_lat_pfb_beats  (8'(LAT_PFB_BEAT)),
      .hw_lat_fft_beats  (16'(LAT_FFT_BEAT)),
      .hw_lat_history    (8'(LAT_HIST)),
      .hw_lat_align      (8'(LAT_ALIGN)),
      .hw_lat_beamformer (8'(LAT_BF)),
      .hw_lat_power      (8'(LAT_PWR)),
      .csr (unused_pl_csr), .pulse (unused_pl_pulse)
  );

  // ===========================================================================
  // Observation
  // ===========================================================================
  assign obs_adc_valid   = adc_valid;
  assign obs_adc_ready   = adc_ready;
  assign obs_adc_payload = adc_payload;
  assign obs_fft_valid   = fft_valid;
  assign obs_fft_ready   = fft_ready;
  assign obs_fft_payload = fft_payload;

  assign obs_hrsp_valid   = h_rsp_valid;
  assign obs_hrsp_ready   = h_rsp_ready;
  assign obs_hrsp_payload = h_rsp_payload;

  assign obs_align_valid   = algn_valid;
  assign obs_align_ready   = algn_ready;
  assign obs_align_payload = algn_payload;

  assign obs_bf_valid   = bf_valid;
  assign obs_bf_ready   = bf_ready;
  assign obs_bf_payload = bf_payload;

  assign obs_bin_valid   = bin_valid;
  assign obs_bin_ready   = bin_ready;
  assign obs_bin_payload = bin_payload;

  assign obs_pwr_valid   = pwr_valid;
  assign obs_pwr_ready   = pwr_ready;
  assign obs_pwr_payload = pwr_payload;

  assign obs_covar_valid = cv_valid;
  assign obs_covar_re    = cv_acc_re;
  assign obs_covar_im    = cv_acc_im;
  assign obs_power_valid = pw_valid;
  assign obs_power_acc   = pw_acc;

  assign obs_lat_pfb_cycles = 8'(LAT_PFB_CYC);
  assign obs_lat_pfb_beats  = 8'(LAT_PFB_BEAT);
  assign obs_lat_fft_beats  = 16'(LAT_FFT_BEAT);
  assign obs_lat_history    = 8'(LAT_HIST);
  assign obs_lat_align      = 8'(LAT_ALIGN);
  assign obs_lat_beamformer = 8'(LAT_BF);
  assign obs_lat_power      = 8'(LAT_PWR);
  assign obs_beam_mux       = 8'(BEAM_MUX);

  // Declared by SPEC 9 and not acted on at Phase 3; see the note on the soft
  // reset above. Read here so `--Wall` reports a genuinely dead register field
  // rather than this deliberate non-binding.
  // Deliberate non-uses, named so `--Wall` reports a genuinely dead signal
  // rather than one of these. Each is a field the register map declares and this
  // phase does not act on, or a slice wider than the geometry that addresses it.
  wire [31:0] unused_fault_inject = fault_inject_cfg;
  wire [23:0] unused_blk_enable_hi = blk_enable_cfg[31:8];
  // COEFF_CTRL.STATUS_CLEAR: rtl/pfb/coeff_bank.sv clears its own sticky reject
  // on a COMPLETED SWAP rather than on a register write, and has no clear input.
  // The bit exists, pulses correctly and is exercised by the register plane's own
  // suite; nothing in the coefficient bank claims to act on it.
  wire        unused_coeff_status_clear = coeff_status_clear;
  // The register-plane index and enable fields are fixed width; how much of
  // each the elaborated geometry can address is a function of that geometry, so
  // the discarded slice is sized from it rather than from a literal.
  wire [15:COEFF_ADDR_W] unused_coeff_index_hi = coeff_wr_index[15:COEFF_ADDR_W];
  wire [15:WGT_ADDR_W]   unused_wgt_index_hi   = wgt_wr_index[15:WGT_ADDR_W];
  wire [31:N_COVAR_PAIRS] unused_pair_en_hi    = cv_pair_en_cfg[31:N_COVAR_PAIRS];
  // Per-block enables this phase does not gate individually: the polyphase bank
  // and the transform are gated by the source's enable (a block with no input
  // does nothing), the beamformer by the alignment network's, the packet fabric
  // is not instantiated here and telemetry has no block yet.
  wire [4:0]  unused_blk_en = {blk_en[7], blk_en[5], blk_en[2:0]};
  wire [5:0]  unused_algn_stall_hi = algn_stall[7:2];
  wire [49:0] unused_bin_meta = bin_f[49:0];
  wire [31:0] unused_algn_issues_cfg = hist_st[A_ISS +: 32];
  wire [N_ANT-1:0] unused_pfb_core_bank, unused_pfb_core_pend;
  wire        unused_bf_core_bank, unused_bf_core_pend;
  wire        unused_wgt_status_clear = wgt_status_clear;
  wire [TELEM_W-1:0] unused_algn_lanewords = algn_lanewords;
  wire [TELEM_W-1:0] unused_algn_inject    = algn_inject;
  wire [TELEM_W-1:0] unused_rdmux_rstall   = rdmux_rstall;
  wire [TELEM_W-1:0] unused_cv_satcount    = cv_sat_count;
  wire [N_BEAMS-1:0] unused_pw_flushed     = pw_flushed;

`ifndef SYNTHESIS
  // Every antenna's coefficient bank is written by the same pulse and holds the
  // same values, so their status is one signal replicated. A build in which they
  // diverge has an antenna whose filter is not the filter the register plane
  // reports, which is silent otherwise.
  a_bc_coeff_banks_agree:
    assert property (@(posedge cfg_clk) disable iff (!cfg_rst_n)
                     (pfb_active_bank == '0) || (pfb_active_bank == {N_ANT{1'b1}}))
      else $error("benchmark_core: per-antenna coefficient banks diverged");

  a_bc_coeff_ready_agree:
    assert property (@(posedge cfg_clk) disable iff (!cfg_rst_n)
                     (pfb_wr_ready == '0) || (pfb_wr_ready == {N_ANT{1'b1}}))
      else $error("benchmark_core: per-antenna coefficient write readys diverged");

  // The whole point of the assembly: an event came out of the far end. A cover
  // rather than an assertion, because it is a statement about the stimulus as
  // much as about the design, and a regression in which it never fires has
  // proved nothing about the pipeline.
  c_bc_event_delivered:
    cover property (@(posedge core_clk) disable iff (!core_rst_n) ev_valid && ev_ready);
`endif

endmodule : benchmark_core

`default_nettype wire
