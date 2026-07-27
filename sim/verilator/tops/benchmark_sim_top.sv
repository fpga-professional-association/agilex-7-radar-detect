// -----------------------------------------------------------------------------
// benchmark_sim_top — Verilator simulation top (SPEC.md 4.1).
//
// SPEC 4.1 defines this variant as the pure-RTL, vendor-IP-free top the C++
// harness attaches to. As of issue #17 it contains the assembled SPEC 3
// pipeline — `rtl/top/benchmark_core.sv` — at the elaborated CONFIG size, plus
// the SPEC 5 stream loopback that issue #2 built the harness around.
//
// Why the loopback is still here
// ------------------------------
// It is not vestigial. `test_stream_loopback` is the test that proves the
// HARNESS: the clock scheduler, the reset sequencer, the stream driver and
// monitor, and — beat by beat against `m_payload` — that the C++ copy of the
// SPEC 5 packing agrees with the RTL's. Deleting it would move that proof into a
// test whose subject is an eight-stage pipeline, where a packing bug and a
// beamforming bug look the same. It costs three registers and it is the reason a
// failure in `test_pipeline_*` can be attributed to the design.
//
// It has no path to or from the pipeline, deliberately: a shared signal would
// make a harness failure and a design failure indistinguishable.
//
// What the harness can reach (SPEC 4.1: "Direct C++ access to ingress,
// configuration, and output streams")
// -----------------------------------------------------------------------
//   ingress        the synthetic sources are register programmed and their
//                  output is exported on `obs_adc_*` — so the harness reads the
//                  exact beats the pipeline admitted rather than the beats it
//                  believes it produced. There is no C++-driven sample port and
//                  that is deliberate: SPEC 3 puts the sources INSIDE the design,
//                  because `benchmark_fabric_top` has no pins to receive samples
//                  on, and a simulation-only injection port would make the
//                  simulated design and the synthesised one different designs.
//   configuration  the SPEC 9 register master port, driven by
//                  sim/verilator/harness/reg_driver.h.
//   output         `ev_*`, the detection-event stream.
//   internals      one observation tap per stage boundary, so a scoreboard can
//                  bind SPEC 12.5 transaction identity at each stage and say
//                  WHICH stage lost a transaction rather than only that one was.
//
// Clock domains: `core_clk`, `history_clk`, `cfg_clk`. The harness drives all
// three independently, which is what makes the SPEC 13.3 clock-phase
// randomisation and the SPEC 8 crossings observable.
//
// Parameters come from config_pkg, which scripts/build_verilator.py generates
// from config/<name>.json — never edit elaboration parameters here. The
// parameter list below is DERIVED payload arithmetic and nothing else: a port
// width must be a parameter expression, and SystemVerilog gives a port list no
// view of a body localparam.
//
// Layout consistency
// ------------------
// The SPEC 5 payload layout has one normative definition, rtl/packages/
// stream_pkg.sv, and one mirror — the constants scripts/build_verilator.py
// writes into the generated config package and the generated C++ header. The
// `initial` block at the bottom compares the two at time 0 on every run, and
// compares every derived width here against the instantiated core's own, so a
// mirror that drifts fails immediately and by name rather than as a corrupted
// payload a thousand cycles later.
// -----------------------------------------------------------------------------

`default_nettype none

module benchmark_sim_top
  import config_pkg::*;
  import reg_if_pkg::*;
#(
    // ---- DERIVED payload widths; never override ----
    parameter int unsigned META_W = 2 + STREAM_ID_W + STREAM_SEQ_W + STREAM_USER_W,
    parameter int unsigned FRONT_PAYLOAD_W = SAMPLES_PER_CYCLE * 2 * SAMPLE_W + META_W,
    parameter int unsigned ALIGN_PAYLOAD_W =
        PIPE_BIN_PAR * N_ANTENNAS * 2 * SAMPLE_W + META_W,
    parameter int unsigned BF_PAYLOAD_W =
        PIPE_BIN_PAR * PIPE_BEAM_PAR * 2 * SAMPLE_W + META_W,
    parameter int unsigned BIN_PAYLOAD_W = N_BEAMS * 2 * SAMPLE_W + META_W,
    parameter int unsigned PWR_PAYLOAD_W = N_BEAMS * POWER_W + META_W,
    parameter int unsigned EV_PAYLOAD_W  = PIPE_EVENT_DATA_W + META_W,
    parameter int unsigned HIST_RD_PAYLOAD_W =
        int'(history_pkg::hist_data_w(history_pkg::hist_geom(
                 history_pkg::hist_uint_t'(N_ANTENNAS),
                 history_pkg::hist_uint_t'(FFT_SIZE),
                 history_pkg::hist_uint_t'(SAMPLES_PER_CYCLE),
                 history_pkg::hist_uint_t'(HISTORY_FRAMES),
                 history_pkg::hist_uint_t'(SAMPLE_W)))) + META_W
) (
    // Core processing domain (SPEC 8: core_clk).
    input  logic                       core_clk,
    input  logic                       core_rst_n,

    // Corner-turn read domain (SPEC 8: history_clk). Asynchronous to core_clk.
    input  logic                       history_clk,
    input  logic                       history_rst_n,

    // Configuration domain (SPEC 8: cfg_clk). Asynchronous to both.
    input  logic                       cfg_clk,
    input  logic                       cfg_rst_n,

    // ---- SPEC 9 register master port (cfg_clk) ----
    input  logic [REG_ADDR_W-1:0]      reg_address,
    input  logic [REG_DATA_W-1:0]      reg_write_data,
    input  logic [REG_STRB_W-1:0]      reg_byte_enable,
    input  logic                       reg_write_enable,
    input  logic                       reg_read_enable,
    output logic [REG_DATA_W-1:0]      reg_read_data,
    output logic                       reg_ready,
    output logic                       reg_error,

    // ---- the detection-event stream (core_clk) ----
    output logic                       ev_valid,
    input  logic                       ev_ready,
    output logic [EV_PAYLOAD_W-1:0]    ev_payload,

    // ---- per-stage observation taps ----
    output logic [N_ANTENNAS-1:0]                 obs_adc_valid,
    output logic [N_ANTENNAS-1:0]                 obs_adc_ready,
    output logic [N_ANTENNAS*FRONT_PAYLOAD_W-1:0] obs_adc_payload,
    output logic [N_ANTENNAS-1:0]                 obs_fft_valid,
    output logic [N_ANTENNAS-1:0]                 obs_fft_ready,
    output logic [N_ANTENNAS*FRONT_PAYLOAD_W-1:0] obs_fft_payload,

    output logic                                  obs_hrsp_valid,
    output logic                                  obs_hrsp_ready,
    output logic [HIST_RD_PAYLOAD_W-1:0]          obs_hrsp_payload,

    output logic                                  obs_align_valid,
    output logic                                  obs_align_ready,
    output logic [ALIGN_PAYLOAD_W-1:0]            obs_align_payload,

    output logic                                  obs_bf_valid,
    output logic                                  obs_bf_ready,
    output logic [BF_PAYLOAD_W-1:0]               obs_bf_payload,

    output logic                                  obs_bin_valid,
    output logic                                  obs_bin_ready,
    output logic [BIN_PAYLOAD_W-1:0]              obs_bin_payload,

    output logic                                  obs_pwr_valid,
    output logic                                  obs_pwr_ready,
    output logic [PWR_PAYLOAD_W-1:0]              obs_pwr_payload,

    output logic [N_COVAR_PAIRS-1:0]              obs_covar_valid,
    output logic [N_COVAR_PAIRS*POWER_W-1:0]      obs_covar_re,
    output logic [N_COVAR_PAIRS*POWER_W-1:0]      obs_covar_im,
    output logic [N_BEAMS-1:0]                    obs_power_valid,
    output logic [N_BEAMS*POWER_W-1:0]            obs_power_acc,

    // ---- elaborated geometry and latency, read back from the design ----
    output logic [7:0]                 obs_lat_pfb_cycles,
    output logic [7:0]                 obs_lat_pfb_beats,
    output logic [15:0]                obs_lat_fft_beats,
    output logic [7:0]                 obs_lat_history,
    output logic [7:0]                 obs_lat_align,
    output logic [7:0]                 obs_lat_beamformer,
    output logic [7:0]                 obs_lat_power,
    output logic [7:0]                 obs_beam_mux,

    // ---- the issue #2 stream loopback: the harness's own proof ----
    input  logic                       s_valid,
    output logic                       s_ready,
    input  logic [STREAM_DATA_W-1:0]   s_data,
    input  logic                       s_start_of_frame,
    input  logic                       s_end_of_frame,
    input  logic [STREAM_ID_W-1:0]     s_stream_id,
    input  logic [STREAM_SEQ_W-1:0]    s_seq,
    input  logic [STREAM_USER_W-1:0]   s_user,

    output logic                       m_valid,
    input  logic                       m_ready,
    output logic [STREAM_DATA_W-1:0]   m_data,
    output logic                       m_start_of_frame,
    output logic                       m_end_of_frame,
    output logic [STREAM_ID_W-1:0]     m_stream_id,
    output logic [STREAM_SEQ_W-1:0]    m_seq,
    output logic [STREAM_USER_W-1:0]   m_user,
    output logic [STREAM_PAYLOAD_W-1:0] m_payload,

    // cfg_clk-domain liveness counter. Read by the harness to confirm the
    // scheduler is actually toggling the configuration clock at its own rate.
    output logic [31:0]                cfg_heartbeat
);

  // ---------------------------------------------------------------------------
  // The design (SPEC 3)
  // ---------------------------------------------------------------------------
  benchmark_core #(
      .N_ANT          (N_ANTENNAS),
      .LANES          (SAMPLES_PER_CYCLE),
      .FFT_SIZE       (FFT_SIZE),
      .PFB_TAPS       (PFB_TAPS),
      .N_BEAMS        (N_BEAMS),
      .HISTORY_FRAMES (HISTORY_FRAMES),
      .BIN_PAR        (PIPE_BIN_PAR),
      .BEAM_PAR       (PIPE_BEAM_PAR),
      .ALIGN_GROUPS   (PIPE_ALIGN_GROUPS),
      .NET_SEL        (PIPE_NET_SEL),
      .N_COVAR_PAIRS  (N_COVAR_PAIRS),
      .CFAR_MAX_GUARD (CFAR_MAX_GUARD),
      .CFAR_MAX_REF   (CFAR_MAX_REF),
      .POWER_PIPE     (PIPE_POWER_PIPE),
      .STREAM_ID_W    (STREAM_ID_W),
      .SEQ_W          (STREAM_SEQ_W),
      .USER_W         (STREAM_USER_W),
      .SYNC_STAGES    (CDC_SYNC_STAGES),
      .CDC_DEPTH      (PIPE_CDC_DEPTH),
      .TELEM_W        (TELEM_COUNT_W)
  ) u_core (
      .core_clk (core_clk), .core_rst_n (core_rst_n),
      .history_clk (history_clk), .history_rst_n (history_rst_n),
      .cfg_clk (cfg_clk), .cfg_rst_n (cfg_rst_n),

      .reg_address      (reg_address),
      .reg_write_data   (reg_write_data),
      .reg_byte_enable  (reg_byte_enable),
      .reg_write_enable (reg_write_enable),
      .reg_read_enable  (reg_read_enable),
      .reg_read_data    (reg_read_data),
      .reg_ready        (reg_ready),
      .reg_error        (reg_error),

      .ev_valid (ev_valid), .ev_ready (ev_ready), .ev_payload (ev_payload),

      .obs_adc_valid (obs_adc_valid), .obs_adc_ready (obs_adc_ready),
      .obs_adc_payload (obs_adc_payload),
      .obs_fft_valid (obs_fft_valid), .obs_fft_ready (obs_fft_ready),
      .obs_fft_payload (obs_fft_payload),
      .obs_hrsp_valid (obs_hrsp_valid), .obs_hrsp_ready (obs_hrsp_ready),
      .obs_hrsp_payload (obs_hrsp_payload),
      .obs_align_valid (obs_align_valid), .obs_align_ready (obs_align_ready),
      .obs_align_payload (obs_align_payload),
      .obs_bf_valid (obs_bf_valid), .obs_bf_ready (obs_bf_ready),
      .obs_bf_payload (obs_bf_payload),
      .obs_bin_valid (obs_bin_valid), .obs_bin_ready (obs_bin_ready),
      .obs_bin_payload (obs_bin_payload),
      .obs_pwr_valid (obs_pwr_valid), .obs_pwr_ready (obs_pwr_ready),
      .obs_pwr_payload (obs_pwr_payload),

      .obs_covar_valid (obs_covar_valid),
      .obs_covar_re (obs_covar_re), .obs_covar_im (obs_covar_im),
      .obs_power_valid (obs_power_valid), .obs_power_acc (obs_power_acc),

      .obs_lat_pfb_cycles (obs_lat_pfb_cycles),
      .obs_lat_pfb_beats  (obs_lat_pfb_beats),
      .obs_lat_fft_beats  (obs_lat_fft_beats),
      .obs_lat_history    (obs_lat_history),
      .obs_lat_align      (obs_lat_align),
      .obs_lat_beamformer (obs_lat_beamformer),
      .obs_lat_power      (obs_lat_power),
      .obs_beam_mux       (obs_beam_mux)
  );

  // ---------------------------------------------------------------------------
  // The issue #2 / #5 stream loopback (skid -> elastic -> skid).
  // ---------------------------------------------------------------------------
  stream_loopback #(
      .DATA_W        (STREAM_DATA_W),
      .STREAM_ID_W   (STREAM_ID_W),
      .SEQ_W         (STREAM_SEQ_W),
      .USER_W        (STREAM_USER_W),
      .ELASTIC_DEPTH (STREAM_LOOPBACK_ELASTIC_DEPTH)
  ) u_loopback (
      .clk              (core_clk),
      .rst_n            (core_rst_n),
      .s_valid          (s_valid),
      .s_ready          (s_ready),
      .s_data           (s_data),
      .s_start_of_frame (s_start_of_frame),
      .s_end_of_frame   (s_end_of_frame),
      .s_stream_id      (s_stream_id),
      .s_seq            (s_seq),
      .s_user           (s_user),
      .m_valid          (m_valid),
      .m_ready          (m_ready),
      .m_data           (m_data),
      .m_start_of_frame (m_start_of_frame),
      .m_end_of_frame   (m_end_of_frame),
      .m_stream_id      (m_stream_id),
      .m_seq            (m_seq),
      .m_user           (m_user),
      .m_payload        (m_payload)
  );

  // ---------------------------------------------------------------------------
  // Configuration domain: free-running heartbeat.
  // ---------------------------------------------------------------------------
  logic [31:0] cfg_heartbeat_q;

  // Synchronous reset, per SPEC 23.
  always_ff @(posedge cfg_clk) begin
    if (!cfg_rst_n) cfg_heartbeat_q <= 32'd0;
    else            cfg_heartbeat_q <= cfg_heartbeat_q + 32'd1;
  end

  assign cfg_heartbeat = cfg_heartbeat_q;

  // ---------------------------------------------------------------------------
  // Time-0 consistency checks
  // ---------------------------------------------------------------------------
`ifndef SYNTHESIS
  localparam stream_pkg::stream_geom_t GEOM = stream_pkg::stream_geom(
      STREAM_DATA_W, STREAM_ID_W, STREAM_SEQ_W, STREAM_USER_W);

  localparam int unsigned LOOPBACK_LATENCY = stream_pkg::stream_skid_latency() +
                                             stream_pkg::stream_elastic_latency() +
                                             stream_pkg::stream_skid_latency();

  initial begin
    if (int'(STREAM_PAYLOAD_W) != int'(stream_pkg::stream_payload_w(GEOM))) begin
      $fatal(1, "config/stream_pkg layout drift: STREAM_PAYLOAD_W=%0d, package says %0d",
             STREAM_PAYLOAD_W, int'(stream_pkg::stream_payload_w(GEOM)));
    end
    if (int'(STREAM_USER_LSB) != int'(stream_pkg::stream_user_lsb(GEOM))) begin
      $fatal(1, "config/stream_pkg layout drift: STREAM_USER_LSB=%0d, package says %0d",
             STREAM_USER_LSB, int'(stream_pkg::stream_user_lsb(GEOM)));
    end
    if (int'(STREAM_SEQ_LSB) != int'(stream_pkg::stream_seq_lsb(GEOM))) begin
      $fatal(1, "config/stream_pkg layout drift: STREAM_SEQ_LSB=%0d, package says %0d",
             STREAM_SEQ_LSB, int'(stream_pkg::stream_seq_lsb(GEOM)));
    end
    if (int'(STREAM_ID_LSB) != int'(stream_pkg::stream_id_lsb(GEOM))) begin
      $fatal(1, "config/stream_pkg layout drift: STREAM_ID_LSB=%0d, package says %0d",
             STREAM_ID_LSB, int'(stream_pkg::stream_id_lsb(GEOM)));
    end
    if (int'(STREAM_EOF_LSB) != int'(stream_pkg::stream_eof_lsb(GEOM))) begin
      $fatal(1, "config/stream_pkg layout drift: STREAM_EOF_LSB=%0d, package says %0d",
             STREAM_EOF_LSB, int'(stream_pkg::stream_eof_lsb(GEOM)));
    end
    if (int'(STREAM_SOF_LSB) != int'(stream_pkg::stream_sof_lsb(GEOM))) begin
      $fatal(1, "config/stream_pkg layout drift: STREAM_SOF_LSB=%0d, package says %0d",
             STREAM_SOF_LSB, int'(stream_pkg::stream_sof_lsb(GEOM)));
    end
    if (int'(STREAM_DATA_LSB) != int'(stream_pkg::stream_data_lsb(GEOM))) begin
      $fatal(1, "config/stream_pkg layout drift: STREAM_DATA_LSB=%0d, package says %0d",
             STREAM_DATA_LSB, int'(stream_pkg::stream_data_lsb(GEOM)));
    end
    if (int'(STREAM_LOOPBACK_LATENCY) != int'(LOOPBACK_LATENCY)) begin
      $fatal(1, "loopback latency drift: config says %0d, the instantiated structure is %0d",
             STREAM_LOOPBACK_LATENCY, LOOPBACK_LATENCY);
    end

    // The observation taps, against the core's own derived widths. Two files
    // repeating the same arithmetic is two places to get it wrong; this is the
    // check that says so.
    if (int'(FRONT_PAYLOAD_W) != int'(u_core.FRONT_PAYLOAD_W)) begin
      $fatal(1, "benchmark_sim_top: front payload %0d, core says %0d",
             FRONT_PAYLOAD_W, int'(u_core.FRONT_PAYLOAD_W));
    end
    if (int'(HIST_RD_PAYLOAD_W) != int'(u_core.HIST_RD_PAYLOAD_W)) begin
      $fatal(1, "benchmark_sim_top: history response payload %0d, core says %0d",
             HIST_RD_PAYLOAD_W, int'(u_core.HIST_RD_PAYLOAD_W));
    end
    if (int'(ALIGN_PAYLOAD_W) != int'(u_core.ALIGN_PAYLOAD_W)) begin
      $fatal(1, "benchmark_sim_top: alignment payload %0d, core says %0d",
             ALIGN_PAYLOAD_W, int'(u_core.ALIGN_PAYLOAD_W));
    end
    if (int'(BF_PAYLOAD_W) != int'(u_core.BF_PAYLOAD_W)) begin
      $fatal(1, "benchmark_sim_top: beamformer payload %0d, core says %0d",
             BF_PAYLOAD_W, int'(u_core.BF_PAYLOAD_W));
    end
    if (int'(BIN_PAYLOAD_W) != int'(u_core.BIN_PAYLOAD_W)) begin
      $fatal(1, "benchmark_sim_top: serialized payload %0d, core says %0d",
             BIN_PAYLOAD_W, int'(u_core.BIN_PAYLOAD_W));
    end
    if (int'(PWR_PAYLOAD_W) != int'(u_core.PWR_PAYLOAD_W)) begin
      $fatal(1, "benchmark_sim_top: power payload %0d, core says %0d",
             PWR_PAYLOAD_W, int'(u_core.PWR_PAYLOAD_W));
    end
    if (int'(EV_PAYLOAD_W) != int'(u_core.EV_PAYLOAD_W)) begin
      $fatal(1, "benchmark_sim_top: event payload %0d, core says %0d",
             EV_PAYLOAD_W, int'(u_core.EV_PAYLOAD_W));
    end
  end
`endif

endmodule : benchmark_sim_top

`default_nettype wire
