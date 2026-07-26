// -----------------------------------------------------------------------------
// bf_matrix_wrap — synthesis wrapper for the SPEC 18 beamforming-matrix
// calibration (issue #12, SPEC.md 18 item 7: "One complete beam").
//
// Wraps ONE rtl/beamformer/beamformer.sv as a MATRIX SLICE — BIN_PAR = 2 bins
// per beat x BEAM_PAR = 4 beams per cycle, over N_ANT = 16 antennas, out of
// N_BEAMS = 8 — in boundary registers, as one instance named `u_kernel`.
//
// WHY A SLICE, AND WHY THIS SLICE
// -------------------------------
// SPEC 18 item 7 names "one complete beam". A complete beam at full scale is one
// row of the matrix evaluated at 8 bins per cycle: 8 dot products of 16
// antennas. This slice is 8 dot products of 16 antennas (2 bins x 4 beams), so
// it prices the same amount of arithmetic — and it prices it in the shape the
// design actually builds, which one isolated beam row would not:
//
//   * whether BIN_PAR dot products sharing one antenna vector and BEAM_PAR
//     sharing one weight row still map two multiplies per DSP block at width, or
//     whether the Fitter runs out of column-adjacent blocks,
//   * what the 8 x 16 x 2 x 32-bit weight store maps to — registers, MLAB or
//     M20K — and what the beam-group output mux over it costs,
//   * the per-BLOCK costs that do not scale with dot products: the credit gate,
//     the hold register, the metadata alignment path and the output elastic
//     buffer,
//   * whether the critical path is still inside the arithmetic at this fanout,
//     or has moved into the weight mux or the frame-boundary swap cone. Issue
//     #10 found the swap cone on the critical path of a FIR lane, so this is a
//     measurement rather than a worry.
//
// scripts/run_calibration.py records the critical path's source and destination
// hierarchy for every point and flags one whose register-to-register path does
// not touch `u_kernel`.
//
// N_BEAMS = 8 with BEAM_PAR = 4 gives BEAM_MUX = 2, so this point ALSO prices
// the time-multiplex machinery SPEC 7.5 requires to be visible: the hold
// register, the group counter and the weight mux are all present and all cost
// what they cost. A point at BEAM_PAR = N_BEAMS would optimise the mux away and
// report a matrix that the full-scale design will not build.
//
// THE 1024-BIT INPUT BEAT is the point of the whole exercise and is why
// stream_pkg::STREAM_MAX_DATA_W was raised to 1024 by this issue. A beamformer
// beat carries BIN_PAR bins each with the WHOLE antenna vector, because a beam
// is a sum across antennas; 2 x 16 x 32 = 1024. With the bound left at 256 the
// pack/unpack would silently truncate and three quarters of the multipliers
// would optimise away, which SPEC 24 forbids and which would make this record a
// resource figure for a block that does not exist.
//
// Virtual pins carry the 1048-bit input payload and the 280-bit output payload.
// That is a lot of boundary, which is exactly why the boundary registers below
// exist: without them the Fitter would be timing a virtual pin against
// set_input_delay rather than the matrix.
//
// The configuration domain is tied to the core clock here, as in pfb8_wrap, and
// for the same reason: the crossing primitives are still elaborated and still
// cost what they cost, but the point stays a single-clock fabric measurement.
//
// SPEC 24: nothing is tied off to make the block optimise away. Every output is
// registered and driven to a pin, and the input stream is a genuine port rather
// than a constant.
//
// Listed in sim/verilator/files_beamformer.f so `make lint` covers it.
// -----------------------------------------------------------------------------

`default_nettype none

module bf_matrix_wrap
  import fxp_pkg::*;
  import beamformer_pkg::*;
#(
    parameter int unsigned N_ANT    = 16,
    parameter int unsigned N_BEAMS  = 8,
    parameter int unsigned BIN_PAR  = 2,
    parameter int unsigned BEAM_PAR = 4,

    parameter int unsigned MULT_PIPE_STAGES = 4,

    // Adder-tree pipelining stride, swept against the dot-product point so the
    // block-level answer can be compared with the atom-level one.
    parameter int unsigned ADD_REG_EVERY = 1,

    // 0 = complex_multiplier "MULT4", 1 = "MULT3". See bf_dot_wrap for why the
    // sweep sets an integer rather than the module's string parameter.
    parameter int unsigned VARIANT_SEL = 0,

    // DERIVED; never overridden. See rtl/beamformer/beamformer.sv for why a port
    // width has to be a parameter expression.
    parameter int unsigned STREAM_ID_W = 2,
    parameter int unsigned SEQ_W       = 16,
    parameter int unsigned USER_W      = 4,
    parameter int unsigned S_PAYLOAD_W =
        BIN_PAR * N_ANT * 2 * fxp_pkg::FXP_SAMPLE_W +
        2 + STREAM_ID_W + SEQ_W + USER_W,
    parameter int unsigned M_PAYLOAD_W =
        BIN_PAR * BEAM_PAR * 2 * fxp_pkg::FXP_SAMPLE_W +
        2 + STREAM_ID_W + SEQ_W + USER_W
) (
    input  wire                     clk,
    input  wire                     rst_n,

    input  wire                     s_valid,
    output wire                     s_ready,
    input  wire [S_PAYLOAD_W-1:0]   s_payload,

    output wire                     m_valid,
    input  wire                     m_ready,
    output wire [M_PAYLOAD_W-1:0]   m_payload,

    input  wire                     cfg_wr_valid,
    output wire                     cfg_wr_ready,
    input  wire                     cfg_wr_bank,
    input  wire [7:0]               cfg_wr_addr,
    input  wire [31:0]              cfg_wr_data,
    input  wire                     cfg_swap_req,
    output wire                     cfg_status,

    input  wire                     telem_clear,
    input  wire                     telem_snapshot,
    output wire [31:0]              telem_status,

    // The SPEC 7.5 reported-throughput surface, driven to pins so that it is
    // part of the measured design rather than an output nothing reads.
    output wire [31:0]              tput_status
);

  localparam string       VARIANT = (VARIANT_SEL == 1) ? "MULT3" : "MULT4";
  localparam int unsigned ADDR_W  = $clog2(N_BEAMS * N_ANT);

  // ---------------------------------------------------------------------------
  // Boundary input registers. Valid and the configuration strobes are reset;
  // the payload is not (SPEC 23).
  // ---------------------------------------------------------------------------
  logic                   sv_q, mr_q, cwr_q, csw_q, cbank_q;
  logic [S_PAYLOAD_W-1:0] sp_q;
  logic [ADDR_W-1:0]      caddr_q;
  logic [31:0]            cdata_q;
  logic                   tclr_q, tsnap_q;

  always_ff @(posedge clk) begin
    if (!rst_n) begin
      sv_q    <= 1'b0;
      mr_q    <= 1'b0;
      cwr_q   <= 1'b0;
      csw_q   <= 1'b0;
      tclr_q  <= 1'b0;
      tsnap_q <= 1'b0;
    end else begin
      sv_q    <= s_valid;
      mr_q    <= m_ready;
      cwr_q   <= cfg_wr_valid;
      csw_q   <= cfg_swap_req;
      tclr_q  <= telem_clear;
      tsnap_q <= telem_snapshot;
    end
  end

  always_ff @(posedge clk) begin
    sp_q    <= s_payload;
    cbank_q <= cfg_wr_bank;
    caddr_q <= cfg_wr_addr[ADDR_W-1:0];
    cdata_q <= cfg_wr_data;
  end

  // ---------------------------------------------------------------------------
  // The kernel under calibration
  // ---------------------------------------------------------------------------
  logic                   k_sready, k_mvalid;
  logic [M_PAYLOAD_W-1:0] k_mpayload;
  logic                   k_cwr_ready, k_cbusy, k_covr, k_cactive, k_cpending,
                          k_creject, k_sat_any, k_core_active, k_core_pending;
  fxp_flags_t             k_sat_sticky;
  logic [31:0]            k_sat_count, k_sat_snap, k_frame_count, k_frame_snap;
  logic [7:0]             k_nant, k_nbeams, k_binpar, k_beampar, k_beammux;
  logic [15:0]            k_bb;

  beamformer #(
      .N_ANT            (N_ANT),
      .N_BEAMS          (N_BEAMS),
      .BIN_PAR          (BIN_PAR),
      .BEAM_PAR         (BEAM_PAR),
      .MULT_PIPE_STAGES (MULT_PIPE_STAGES),
      .MULT_VARIANT     (VARIANT),
      .ADD_REG_EVERY    (ADD_REG_EVERY),
      .STREAM_ID_W      (STREAM_ID_W),
      .SEQ_W            (SEQ_W),
      .USER_W           (USER_W),
      .SYNC_STAGES      (2),
      .TELEM_COUNT_W    (32)
  ) u_kernel (
      .core_clk         (clk),
      .core_rst_n       (rst_n),
      .cfg_clk          (clk),
      .cfg_rst_n        (rst_n),
      .cfg_wr_valid     (cwr_q),
      .cfg_wr_ready     (k_cwr_ready),
      .cfg_wr_bank      (cbank_q),
      .cfg_wr_addr      (caddr_q),
      .cfg_wr_data      (cdata_q),
      .cfg_swap_req     (csw_q),
      .cfg_swap_busy    (k_cbusy),
      .cfg_swap_overrun (k_covr),
      .cfg_active_bank  (k_cactive),
      .cfg_swap_pending (k_cpending),
      .cfg_wr_reject    (k_creject),
      .s_valid          (sv_q),
      .s_ready          (k_sready),
      .s_payload        (sp_q),
      .m_valid          (k_mvalid),
      .m_ready          (mr_q),
      .m_payload        (k_mpayload),
      .telem_clear      (tclr_q),
      .telem_snapshot   (tsnap_q),
      .sat_sticky       (k_sat_sticky),
      .sat_any          (k_sat_any),
      .sat_event_count  (k_sat_count),
      .sat_event_snap   (k_sat_snap),
      .frame_count      (k_frame_count),
      .frame_snap       (k_frame_snap),
      .core_active_bank (k_core_active),
      .core_swap_pending(k_core_pending),
      .tput_n_ant       (k_nant),
      .tput_n_beams     (k_nbeams),
      .tput_bin_par     (k_binpar),
      .tput_beam_par    (k_beampar),
      .tput_beam_mux    (k_beammux),
      .tput_beam_bins_per_cycle (k_bb)
  );

  // ---------------------------------------------------------------------------
  // Boundary output registers
  // ---------------------------------------------------------------------------
  logic                   srdy_q, mv_q, cstat_q;
  logic [M_PAYLOAD_W-1:0] mp_q;
  logic [31:0]            tstat_q, tput_q;

  always_ff @(posedge clk) begin
    if (!rst_n) begin
      srdy_q <= 1'b0;
      mv_q   <= 1'b0;
    end else begin
      srdy_q <= k_sready;
      mv_q   <= k_mvalid;
    end
  end

  always_ff @(posedge clk) begin
    mp_q    <= k_mpayload;
    cstat_q <= k_cwr_ready | k_cbusy | k_covr | k_cactive | k_cpending |
               k_creject | k_core_active | k_core_pending;
    // The telemetry outputs are combined into one 32-bit registered word rather
    // than given 130 pins of their own. Every bit still participates, so nothing
    // optimises away (SPEC 24), and the boundary stays a fixed cost across the
    // sweep. Same device, same reason, as pfb8_wrap.
    tstat_q <= k_sat_count ^ k_sat_snap ^ k_frame_count ^ k_frame_snap ^
               {30'd0, k_sat_sticky.sat_pos | k_sat_any, k_sat_sticky.sat_neg};
    tput_q  <= {k_nant, k_nbeams, k_binpar, k_beampar} ^
               {8'd0, k_beammux, k_bb};
  end

  assign s_ready      = srdy_q;
  assign m_valid      = mv_q;
  assign m_payload    = mp_q;
  assign cfg_wr_ready = k_cwr_ready;
  assign cfg_status   = cstat_q;
  assign telem_status = tstat_q;
  assign tput_status  = tput_q;

endmodule : bf_matrix_wrap

`default_nettype wire
