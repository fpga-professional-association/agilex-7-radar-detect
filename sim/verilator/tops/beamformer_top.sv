// -----------------------------------------------------------------------------
// beamformer_top — the beamforming matrix verification top (issue #12, SPEC 13.1).
//
// Holds THREE complete beamformers, identical in geometry and weights and
// differing only in the two things this issue has to defend, driven from ONE
// stimulus port and admitting exactly the same beats:
//
//   index  BIN_PAR  BEAM_PAR  BEAM_MUX  ADD_REG_EVERY   what it proves
//   -----  -------  --------  --------  -------------   -------------------------
//     0       2         4         1           1         the reference engine
//     1       2         2         2           1         time multiplexing produces
//                                                       the same beams, spread over
//                                                       twice as many output beats
//     2       2         4         1           2         two adders per register
//                                                       stage is the same integer
//
// Every instance has the SAME input payload width (2 bins x 4 antennas x 32 bits
// = 256), so one stimulus port drives all three and the equivalences above are
// same-cycle facts about one stream rather than comparisons of separate runs —
// the arrangement sim/verilator/tops/cmult_top.sv uses for MULT4 against MULT3
// and sim/verilator/tops/pfb_top.sv uses for TREE against SYSTOLIC, for the same
// reason.
//
// LOCKSTEP ADMISSION
// ------------------
// The three instances have different pipeline depths and different multiplex
// factors, so their `s_ready` differ — DUT 1 is ready only every other cycle by
// construction. Each instance's `s_valid` is gated by the OTHERS' readiness, so
// a beat is admitted by all three or by none and the three output streams stay
// beat-for-beat comparable. The top's own `s_ready` is the AND of the three.
// The visible consequence is that the whole top runs at DUT 1's rate, which is
// exactly the throughput statement SPEC 7.5 asks to be made visible.
//
// THE STANDALONE 16-ANTENNA DOT PRODUCTS
// --------------------------------------
// `u_dot16_r1` and `u_dot16_r2` are two rtl/beamformer/bf_dot.sv instances at
// N_ANT = 16 — the SPEC 7.5 nominal antenna count and the geometry
// quartus/calibration/bf_dot_calib.qsf compiles — sharing one operand port and
// differing only in ADD_REG_EVERY. They are outside the stream entirely, driven
// by their own valid, for two reasons: the matrix instances are kept small so
// three of them fit the sim-tiny time budget, and the SPEC 13.1 directed cases
// that matter for a dot product (unit weights select one antenna; orthogonal
// weight patterns; maximum-amplitude saturation) are statements about the dot
// product and do not need a stream around them.
//
// THE NEGATIVE-TEST WEIGHT BANK
// -----------------------------
// `u_unsafe` is a small weight_bank elaborated with ALLOW_UNSAFE_SWAP = 1, wired
// to its own ports and to nothing in the datapath. Its swap ignores the frame
// boundary, so driving it provokes a_coeff_swap_at_sof — the property
// rtl/beamformer/weight_bank.sv inherits from the store it reuses. It exists
// because an assertion nothing can provoke is an assertion nobody has tested;
// sim/tests/test_beamformer.cpp runs it last, with `Verilated::fatalOnError`
// cleared, and requires that exact property to fire by name.
//
// The metadata ports are unpacked (sof/eof/id/seq/user as separate ports) while
// the beamformers speak the packed SPEC 5 bundle. The packing and unpacking here
// is stream_pkg's, so the top exercises the canonical layout while the C++
// harness drives plain fields — the same split rtl/common/stream_loopback.sv
// makes.
//
// Simulation only. Not in files.f, never in a Quartus source list; the DUTs are
// in files.f and in quartus/calibration/.
// -----------------------------------------------------------------------------

`default_nettype none

module beamformer_top
  import fxp_pkg::*;
  import stream_pkg::*;
  import beamformer_pkg::*;
(
    input  wire         clk,
    input  wire         rst_n,

    // ---- weight programming, broadcast to all three beamformers -------------
    input  wire         cfg_wr_valid,
    output wire         cfg_wr_ready,
    input  wire         cfg_wr_bank,
    input  wire [3:0]   cfg_wr_addr,   // clog2(N_BEAMS*N_ANT); checked at time 0
    input  wire [31:0]  cfg_wr_data,
    input  wire         cfg_swap_req,
    output wire         cfg_swap_busy,
    output wire         cfg_swap_overrun,
    output wire         cfg_active_bank,
    output wire         cfg_swap_pending,
    output wire         cfg_wr_reject,

    // ---- stream in ----------------------------------------------------------
    // BIN_PAR bins x N_ANT antennas, bin-major and antenna-minor; see
    // rtl/beamformer/beamformer.sv section 1 and ARCHITECTURE.md.
    input  wire         s_valid,
    output wire         s_ready,
    input  wire [255:0] s_data,
    input  wire         s_sof,
    input  wire         s_eof,
    input  wire [1:0]   s_id,
    input  wire [15:0]  s_seq,
    input  wire [3:0]   s_user,

    // ---- stream out ---------------------------------------------------------
    // BEAM_PAR beams x BIN_PAR bins, beam-major and bin-minor.
    input  wire         m_ready,

    output wire         m0_valid,
    output wire [255:0] m0_data,
    output wire         m0_sof,
    output wire         m0_eof,
    output wire [1:0]   m0_id,
    output wire [15:0]  m0_seq,
    output wire [3:0]   m0_user,

    output wire         m1_valid,
    output wire [127:0] m1_data,
    output wire         m1_sof,
    output wire         m1_eof,
    output wire [1:0]   m1_id,
    output wire [15:0]  m1_seq,
    output wire [3:0]   m1_user,

    output wire         m2_valid,
    output wire [255:0] m2_data,
    output wire         m2_sof,
    output wire         m2_eof,
    output wire [1:0]   m2_id,
    output wire [15:0]  m2_seq,
    output wire [3:0]   m2_user,

    // ---- telemetry, from DUT 0 ----------------------------------------------
    input  wire         telem_clear,
    input  wire         telem_snapshot,
    output wire [1:0]   sat_sticky,        // {sat_pos, sat_neg}
    output wire         sat_any,
    output wire [31:0]  sat_event_count,
    output wire [31:0]  sat_event_snap,
    output wire [31:0]  frame_count,
    output wire [31:0]  frame_snap,

    // ---- reported throughput, from all three (SPEC 7.5) ---------------------
    output wire [7:0]   tput_n_ant,
    output wire [7:0]   tput_n_beams,
    output wire [7:0]   tput_bin_par0,
    output wire [7:0]   tput_beam_par0,
    output wire [7:0]   tput_beam_mux0,
    output wire [15:0]  tput_bb0,
    output wire [7:0]   tput_beam_par1,
    output wire [7:0]   tput_beam_mux1,
    output wire [15:0]  tput_bb1,

    // ---- the standalone 16-antenna dot products -----------------------------
    input  wire         d_valid_in,
    input  wire [511:0] d_x,        // 16 antennas x {im, re}
    input  wire [511:0] d_w,

    output wire         d0_valid_out,
    output wire [31:0]  d0_y,       // {im, re}
    output wire [3:0]   d0_flags,   // {re.sat_pos, re.sat_neg, im.sat_pos, im.sat_neg}
    output wire         d0_ovf,
    output wire [63:0]  d0_acc_re,
    output wire [63:0]  d0_acc_im,

    output wire         d1_valid_out,
    output wire [31:0]  d1_y,
    output wire [3:0]   d1_flags,
    output wire         d1_ovf,

    // ---- the negative-test weight bank --------------------------------------
    input  wire         unsafe_swap_req,
    input  wire         unsafe_beat,
    input  wire         unsafe_sof,
    output wire         unsafe_active_bank,
    output wire [127:0] unsafe_w,

    // ---- geometry echo, checked by the test against its own mirror ----------
    output wire [7:0]   cfg_n_ant,
    output wire [7:0]   cfg_n_beams,
    output wire [7:0]   cfg_mult_pipe,
    output wire [7:0]   cfg_weight_addr_w,
    output wire [7:0]   cfg_acc_w,
    output wire [7:0]   cfg_dot16_acc_w,
    output wire [7:0]   cfg_lat0,
    output wire [7:0]   cfg_lat1,
    output wire [7:0]   cfg_lat2,
    output wire [7:0]   cfg_dot16_lat_r1,
    output wire [7:0]   cfg_dot16_lat_r2,
    output wire [15:0]  cfg_s_payload_w,
    output wire [15:0]  cfg_m0_payload_w,
    output wire [15:0]  cfg_m1_payload_w
);

  // ---------------------------------------------------------------------------
  // Geometry. Mirrored in sim/tests/test_beamformer.cpp and checked against the
  // cfg_* echo before anything else runs, so a drift is a named failure rather
  // than a silently wrong comparison.
  //
  // 4 antennas x 4 beams x 2 bins rather than the SPEC 7.5 nominal 16 x 16 x 8:
  // the point of this top is the CONTRACT (the input vector convention, the
  // multiplex, the weight swap, alignment, backpressure, saturation), which is
  // geometry-independent, and three whole matrices at 4x4x2 is 80 complex
  // multipliers, which fits the sim-tiny budget. The 16-antenna dot product IS
  // exercised, standalone, below; the nominal matrix geometry is what the SPEC
  // 18 calibration projects compile.
  //
  // A further reason the matrices are 4x4x2 and not wider: an input beat is
  // BIN_PAR * N_ANT complex samples, and stream_pkg::STREAM_MAX_DATA_W bounds
  // the pack/unpack working type at 256 bits. 2 x 4 x 32 is exactly that bound.
  // The full-scale beat (8 bins x 16 antennas = 4096 bits) needs that bound
  // raised, which is a change to a package every block in the design calls and
  // therefore belongs to the issue that also builds the alignment network
  // producing such a beat (#16) and the one that freezes full scale (#20). See
  // DECISIONS.md (issue #12) and ARCHITECTURE.md.
  // ---------------------------------------------------------------------------
  localparam int unsigned N_ANT     = 4;
  localparam int unsigned N_BEAMS   = 4;
  localparam int unsigned BIN_PAR   = 2;
  localparam int unsigned MULT_PIPE = 4;

  localparam int unsigned STREAM_ID_W = 2;
  localparam int unsigned SEQ_W       = 16;
  localparam int unsigned USER_W      = 4;

  localparam int unsigned PAIR_W    = 2 * FXP_SAMPLE_W;                    // 32
  localparam int unsigned ADDR_W    = $clog2(N_BEAMS * N_ANT);             // 4
  localparam int unsigned S_DATA_W  = BIN_PAR * N_ANT * PAIR_W;            // 256
  localparam int unsigned META_W    = STREAM_FLAG_W + STREAM_ID_W + SEQ_W +
                                      USER_W;                              // 24
  localparam int unsigned S_PAYLOAD_W = S_DATA_W + META_W;                 // 280

  // DUT 0 and DUT 2 emit 4 beams x 2 bins; DUT 1 emits 2 beams x 2 bins.
  localparam int unsigned M04_DATA_W    = BIN_PAR * 4 * PAIR_W;            // 256
  localparam int unsigned M04_PAYLOAD_W = M04_DATA_W + META_W;             // 280
  localparam int unsigned M2_DATA_W     = BIN_PAR * 2 * PAIR_W;            // 128
  localparam int unsigned M2_PAYLOAD_W  = M2_DATA_W + META_W;              // 152

  // The standalone dot products.
  localparam int unsigned D_N_ANT  = 16;
  localparam int unsigned D_ACC_W  = int'(bf_acc_w(bf_uint_t'(D_N_ANT)));  // 37

  // Fully qualified: this top imports fxp_pkg, stream_pkg and beamformer_pkg,
  // and the first two both declare `uint_t`. See rtl/packages/pfb_pkg.sv and
  // DECISIONS.md (issue #10, decision 13).
  localparam stream_geom_t S_GEOM = stream_geom(stream_pkg::uint_t'(S_DATA_W),
                                                stream_pkg::uint_t'(STREAM_ID_W),
                                                stream_pkg::uint_t'(SEQ_W),
                                                stream_pkg::uint_t'(USER_W));
  localparam stream_geom_t M04_GEOM = stream_geom(stream_pkg::uint_t'(M04_DATA_W),
                                                  stream_pkg::uint_t'(STREAM_ID_W),
                                                  stream_pkg::uint_t'(SEQ_W),
                                                  stream_pkg::uint_t'(USER_W));
  localparam stream_geom_t M2_GEOM = stream_geom(stream_pkg::uint_t'(M2_DATA_W),
                                                 stream_pkg::uint_t'(STREAM_ID_W),
                                                 stream_pkg::uint_t'(SEQ_W),
                                                 stream_pkg::uint_t'(USER_W));

`ifndef SYNTHESIS
  initial begin
    if (int'(stream_payload_w(S_GEOM)) != S_PAYLOAD_W) begin
      $fatal(1, "beamformer_top: input payload mirror %0d != stream_pkg %0d",
             S_PAYLOAD_W, int'(stream_payload_w(S_GEOM)));
    end
    if (int'(stream_payload_w(M04_GEOM)) != M04_PAYLOAD_W) begin
      $fatal(1, "beamformer_top: 4-beam output payload mirror %0d != stream_pkg %0d",
             M04_PAYLOAD_W, int'(stream_payload_w(M04_GEOM)));
    end
    if (int'(stream_payload_w(M2_GEOM)) != M2_PAYLOAD_W) begin
      $fatal(1, "beamformer_top: 2-beam output payload mirror %0d != stream_pkg %0d",
             M2_PAYLOAD_W, int'(stream_payload_w(M2_GEOM)));
    end
    // The weight address port is declared at a literal width because a port
    // width cannot see a localparam; this is what keeps it honest.
    if ($bits(cfg_wr_addr) != ADDR_W) begin
      $fatal(1, "beamformer_top: cfg_wr_addr is %0d bits but the geometry needs %0d",
             $bits(cfg_wr_addr), ADDR_W);
    end
  end
`endif

  // ---------------------------------------------------------------------------
  // Stimulus packing
  // ---------------------------------------------------------------------------
  stream_fields_t s_fields;
  always_comb begin
    s_fields           = '0;
    s_fields.data      = STREAM_MAX_DATA_W'(s_data[S_DATA_W-1:0]);
    s_fields.sof       = s_sof;
    s_fields.eof       = s_eof;
    s_fields.stream_id = STREAM_MAX_ID_W'(s_id);
    s_fields.seq       = STREAM_MAX_SEQ_W'(s_seq);
    s_fields.user      = STREAM_MAX_USER_W'(s_user);
  end

  logic [S_PAYLOAD_W-1:0] s_payload;
  assign s_payload = S_PAYLOAD_W'(stream_pack(S_GEOM, s_fields));

  // ---------------------------------------------------------------------------
  // Lockstep admission and broadcast configuration. See the header.
  // ---------------------------------------------------------------------------
  logic rdy0, rdy1, rdy2;
  assign s_ready = rdy0 && rdy1 && rdy2;

  logic cfg_rdy0, cfg_rdy1, cfg_rdy2;
  assign cfg_wr_ready = cfg_rdy0 && cfg_rdy1 && cfg_rdy2;

  logic cfg_busy0, cfg_busy1, cfg_busy2;
  assign cfg_swap_busy = cfg_busy0 || cfg_busy1 || cfg_busy2;

  logic cfg_ovr0, cfg_ovr1, cfg_ovr2;
  assign cfg_swap_overrun = cfg_ovr0 || cfg_ovr1 || cfg_ovr2;

  logic [M04_PAYLOAD_W-1:0] m0_payload, m2_payload;
  logic [M2_PAYLOAD_W-1:0]  m1_payload;

  // Named sinks rather than `()`: an empty pin connection is a lint warning
  // (PINCONNECTEMPTY), and a named wire says which outputs this top deliberately
  // does not export. Same convention as rtl/cdc/stream_cdc.sv.
  logic        d0_core_active_unused, d0_core_pending_unused;
  logic        d1_cfg_active_unused, d1_cfg_pending_unused, d1_cfg_reject_unused;
  logic [1:0]  d1_sticky_unused, d2_sticky_unused;
  logic        d1_any_unused, d2_any_unused;
  logic [31:0] d1_c0_unused, d1_c1_unused, d1_c2_unused, d1_c3_unused;
  logic        d1_core_active_unused, d1_core_pending_unused;
  logic        d2_cfg_active_unused, d2_cfg_pending_unused, d2_cfg_reject_unused;
  logic [31:0] d2_c0_unused, d2_c1_unused, d2_c2_unused, d2_c3_unused;
  logic        d2_core_active_unused, d2_core_pending_unused;
  logic [7:0]  d1_nant_unused, d1_nbeams_unused, d1_binpar_unused;
  logic [7:0]  d2_nant_unused, d2_nbeams_unused, d2_binpar_unused,
               d2_beampar_unused, d2_beammux_unused;
  logic [15:0] d2_bb_unused;
  logic        u_cfg_rdy_unused, u_cfg_busy_unused, u_cfg_ovr_unused;
  logic        u_cfg_active_unused, u_cfg_pending_unused, u_cfg_reject_unused;
  logic        u_core_pending_unused;

  // ---------------------------------------------------------------------------
  // DUT 0 — the reference engine: BEAM_PAR = N_BEAMS, one adder per stage
  // ---------------------------------------------------------------------------
  beamformer #(
      .N_ANT            (N_ANT),
      .N_BEAMS          (N_BEAMS),
      .BIN_PAR          (BIN_PAR),
      .BEAM_PAR         (4),
      .MULT_PIPE_STAGES (MULT_PIPE),
      .MULT_VARIANT     ("MULT4"),
      .ADD_REG_EVERY    (1),
      .STREAM_ID_W      (STREAM_ID_W),
      .SEQ_W            (SEQ_W),
      .USER_W           (USER_W),
      .SYNC_STAGES      (2),
      .TELEM_COUNT_W    (32)
  ) u_bf0 (
      .core_clk         (clk),
      .core_rst_n       (rst_n),
      .cfg_clk          (clk),
      .cfg_rst_n        (rst_n),
      .cfg_wr_valid     (cfg_wr_valid && cfg_rdy1 && cfg_rdy2),
      .cfg_wr_ready     (cfg_rdy0),
      .cfg_wr_bank      (cfg_wr_bank),
      .cfg_wr_addr      (cfg_wr_addr),
      .cfg_wr_data      (cfg_wr_data),
      .cfg_swap_req     (cfg_swap_req),
      .cfg_swap_busy    (cfg_busy0),
      .cfg_swap_overrun (cfg_ovr0),
      .cfg_active_bank  (cfg_active_bank),
      .cfg_swap_pending (cfg_swap_pending),
      .cfg_wr_reject    (cfg_wr_reject),
      .s_valid          (s_valid && rdy1 && rdy2),
      .s_ready          (rdy0),
      .s_payload        (s_payload),
      .m_valid          (m0_valid),
      .m_ready          (m_ready),
      .m_payload        (m0_payload),
      .telem_clear      (telem_clear),
      .telem_snapshot   (telem_snapshot),
      .sat_sticky       (sat_sticky),
      .sat_any          (sat_any),
      .sat_event_count  (sat_event_count),
      .sat_event_snap   (sat_event_snap),
      .frame_count      (frame_count),
      .frame_snap       (frame_snap),
      .core_active_bank (d0_core_active_unused),
      .core_swap_pending(d0_core_pending_unused),
      .tput_n_ant       (tput_n_ant),
      .tput_n_beams     (tput_n_beams),
      .tput_bin_par     (tput_bin_par0),
      .tput_beam_par    (tput_beam_par0),
      .tput_beam_mux    (tput_beam_mux0),
      .tput_beam_bins_per_cycle (tput_bb0)
  );

  // ---------------------------------------------------------------------------
  // DUT 1 — the time-multiplexed engine: BEAM_PAR = N_BEAMS/2, BEAM_MUX = 2
  // ---------------------------------------------------------------------------
  beamformer #(
      .N_ANT            (N_ANT),
      .N_BEAMS          (N_BEAMS),
      .BIN_PAR          (BIN_PAR),
      .BEAM_PAR         (2),
      .MULT_PIPE_STAGES (MULT_PIPE),
      .MULT_VARIANT     ("MULT4"),
      .ADD_REG_EVERY    (1),
      .STREAM_ID_W      (STREAM_ID_W),
      .SEQ_W            (SEQ_W),
      .USER_W           (USER_W),
      .SYNC_STAGES      (2),
      .TELEM_COUNT_W    (32)
  ) u_bf1 (
      .core_clk         (clk),
      .core_rst_n       (rst_n),
      .cfg_clk          (clk),
      .cfg_rst_n        (rst_n),
      .cfg_wr_valid     (cfg_wr_valid && cfg_rdy0 && cfg_rdy2),
      .cfg_wr_ready     (cfg_rdy1),
      .cfg_wr_bank      (cfg_wr_bank),
      .cfg_wr_addr      (cfg_wr_addr),
      .cfg_wr_data      (cfg_wr_data),
      .cfg_swap_req     (cfg_swap_req),
      .cfg_swap_busy    (cfg_busy1),
      .cfg_swap_overrun (cfg_ovr1),
      .cfg_active_bank  (d1_cfg_active_unused),
      .cfg_swap_pending (d1_cfg_pending_unused),
      .cfg_wr_reject    (d1_cfg_reject_unused),
      .s_valid          (s_valid && rdy0 && rdy2),
      .s_ready          (rdy1),
      .s_payload        (s_payload),
      .m_valid          (m1_valid),
      .m_ready          (m_ready),
      .m_payload        (m1_payload),
      .telem_clear      (telem_clear),
      .telem_snapshot   (telem_snapshot),
      .sat_sticky       (d1_sticky_unused),
      .sat_any          (d1_any_unused),
      .sat_event_count  (d1_c0_unused),
      .sat_event_snap   (d1_c1_unused),
      .frame_count      (d1_c2_unused),
      .frame_snap       (d1_c3_unused),
      .core_active_bank (d1_core_active_unused),
      .core_swap_pending(d1_core_pending_unused),
      .tput_n_ant       (d1_nant_unused),
      .tput_n_beams     (d1_nbeams_unused),
      .tput_bin_par     (d1_binpar_unused),
      .tput_beam_par    (tput_beam_par1),
      .tput_beam_mux    (tput_beam_mux1),
      .tput_beam_bins_per_cycle (tput_bb1)
  );

  // ---------------------------------------------------------------------------
  // DUT 2 — the reference engine with two adders per register stage
  // ---------------------------------------------------------------------------
  beamformer #(
      .N_ANT            (N_ANT),
      .N_BEAMS          (N_BEAMS),
      .BIN_PAR          (BIN_PAR),
      .BEAM_PAR         (4),
      .MULT_PIPE_STAGES (MULT_PIPE),
      .MULT_VARIANT     ("MULT4"),
      .ADD_REG_EVERY    (2),
      .STREAM_ID_W      (STREAM_ID_W),
      .SEQ_W            (SEQ_W),
      .USER_W           (USER_W),
      .SYNC_STAGES      (2),
      .TELEM_COUNT_W    (32)
  ) u_bf2 (
      .core_clk         (clk),
      .core_rst_n       (rst_n),
      .cfg_clk          (clk),
      .cfg_rst_n        (rst_n),
      .cfg_wr_valid     (cfg_wr_valid && cfg_rdy0 && cfg_rdy1),
      .cfg_wr_ready     (cfg_rdy2),
      .cfg_wr_bank      (cfg_wr_bank),
      .cfg_wr_addr      (cfg_wr_addr),
      .cfg_wr_data      (cfg_wr_data),
      .cfg_swap_req     (cfg_swap_req),
      .cfg_swap_busy    (cfg_busy2),
      .cfg_swap_overrun (cfg_ovr2),
      .cfg_active_bank  (d2_cfg_active_unused),
      .cfg_swap_pending (d2_cfg_pending_unused),
      .cfg_wr_reject    (d2_cfg_reject_unused),
      .s_valid          (s_valid && rdy0 && rdy1),
      .s_ready          (rdy2),
      .s_payload        (s_payload),
      .m_valid          (m2_valid),
      .m_ready          (m_ready),
      .m_payload        (m2_payload),
      .telem_clear      (telem_clear),
      .telem_snapshot   (telem_snapshot),
      .sat_sticky       (d2_sticky_unused),
      .sat_any          (d2_any_unused),
      .sat_event_count  (d2_c0_unused),
      .sat_event_snap   (d2_c1_unused),
      .frame_count      (d2_c2_unused),
      .frame_snap       (d2_c3_unused),
      .core_active_bank (d2_core_active_unused),
      .core_swap_pending(d2_core_pending_unused),
      .tput_n_ant       (d2_nant_unused),
      .tput_n_beams     (d2_nbeams_unused),
      .tput_bin_par     (d2_binpar_unused),
      .tput_beam_par    (d2_beampar_unused),
      .tput_beam_mux    (d2_beammux_unused),
      .tput_beam_bins_per_cycle (d2_bb_unused)
  );

  // ---------------------------------------------------------------------------
  // Output unpacking
  // ---------------------------------------------------------------------------
  stream_fields_t m0_fields, m1_fields, m2_fields;
  assign m0_fields = stream_unpack(M04_GEOM, stream_payload_t'(m0_payload));
  assign m1_fields = stream_unpack(M2_GEOM,  stream_payload_t'(m1_payload));
  assign m2_fields = stream_unpack(M04_GEOM, stream_payload_t'(m2_payload));

  assign m0_data = 256'(m0_fields.data[M04_DATA_W-1:0]);
  assign m0_sof  = m0_fields.sof;
  assign m0_eof  = m0_fields.eof;
  assign m0_id   = m0_fields.stream_id[STREAM_ID_W-1:0];
  assign m0_seq  = m0_fields.seq[SEQ_W-1:0];
  assign m0_user = m0_fields.user[USER_W-1:0];

  assign m1_data = 128'(m1_fields.data[M2_DATA_W-1:0]);
  assign m1_sof  = m1_fields.sof;
  assign m1_eof  = m1_fields.eof;
  assign m1_id   = m1_fields.stream_id[STREAM_ID_W-1:0];
  assign m1_seq  = m1_fields.seq[SEQ_W-1:0];
  assign m1_user = m1_fields.user[USER_W-1:0];

  assign m2_data = 256'(m2_fields.data[M04_DATA_W-1:0]);
  assign m2_sof  = m2_fields.sof;
  assign m2_eof  = m2_fields.eof;
  assign m2_id   = m2_fields.stream_id[STREAM_ID_W-1:0];
  assign m2_seq  = m2_fields.seq[SEQ_W-1:0];
  assign m2_user = m2_fields.user[USER_W-1:0];

  // ---------------------------------------------------------------------------
  // The standalone 16-antenna dot products. One stimulus, two tree pipelinings.
  // ---------------------------------------------------------------------------
  fxp_complex_t             d0_y_w, d1_y_w;
  fxp_flags_t               d0_fre, d0_fim, d1_fre, d1_fim;
  logic signed [D_ACC_W-1:0] d0_acc_re_w, d0_acc_im_w;
  logic signed [D_ACC_W-1:0] d1_acc_re_unused, d1_acc_im_unused;

  bf_dot #(
      .N_ANT            (D_N_ANT),
      .MULT_PIPE_STAGES (MULT_PIPE),
      .MULT_VARIANT     ("MULT4"),
      .ADD_REG_EVERY    (1)
  ) u_dot16_r1 (
      .clk       (clk),
      .rst_n     (rst_n),
      .valid_in  (d_valid_in),
      .x         (d_x),
      .w         (d_w),
      .valid_out (d0_valid_out),
      .y         (d0_y_w),
      .flags_re  (d0_fre),
      .flags_im  (d0_fim),
      .ovf       (d0_ovf),
      .acc_re    (d0_acc_re_w),
      .acc_im    (d0_acc_im_w)
  );

  bf_dot #(
      .N_ANT            (D_N_ANT),
      .MULT_PIPE_STAGES (MULT_PIPE),
      .MULT_VARIANT     ("MULT4"),
      .ADD_REG_EVERY    (2)
  ) u_dot16_r2 (
      .clk       (clk),
      .rst_n     (rst_n),
      .valid_in  (d_valid_in),
      .x         (d_x),
      .w         (d_w),
      .valid_out (d1_valid_out),
      .y         (d1_y_w),
      .flags_re  (d1_fre),
      .flags_im  (d1_fim),
      .ovf       (d1_ovf),
      .acc_re    (d1_acc_re_unused),
      .acc_im    (d1_acc_im_unused)
  );

  assign d0_y     = 32'(d0_y_w);
  assign d0_flags = {d0_fre.sat_pos, d0_fre.sat_neg,
                     d0_fim.sat_pos, d0_fim.sat_neg};
  assign d1_y     = 32'(d1_y_w);
  assign d1_flags = {d1_fre.sat_pos, d1_fre.sat_neg,
                     d1_fim.sat_pos, d1_fim.sat_neg};

  // Sign-extended to a width the C++ harness reads as one 64-bit word.
  assign d0_acc_re = 64'(d0_acc_re_w);
  assign d0_acc_im = 64'(d0_acc_im_w);

  // ---------------------------------------------------------------------------
  // The negative-test weight bank. Outside the datapath; see the header.
  // 2 beams x 2 antennas = 4 weights, the smallest legal geometry.
  // ---------------------------------------------------------------------------
  weight_bank #(
      .N_BEAMS           (2),
      .N_ANT             (2),
      .SYNC_STAGES       (2),
      .ALLOW_UNSAFE_SWAP (1'b1)
  ) u_unsafe (
      .cfg_clk          (clk),
      .cfg_rst_n        (rst_n),
      .cfg_wr_valid     (1'b0),
      .cfg_wr_ready     (u_cfg_rdy_unused),
      .cfg_wr_bank      (1'b0),
      .cfg_wr_addr      (2'd0),
      .cfg_wr_data      (32'd0),
      .cfg_swap_req     (unsafe_swap_req),
      .cfg_swap_busy    (u_cfg_busy_unused),
      .cfg_swap_overrun (u_cfg_ovr_unused),
      .cfg_active_bank  (u_cfg_active_unused),
      .cfg_swap_pending (u_cfg_pending_unused),
      .cfg_wr_reject    (u_cfg_reject_unused),
      .core_clk         (clk),
      .core_rst_n       (rst_n),
      .core_beat        (unsafe_beat),
      .core_sof         (unsafe_sof),
      .core_active_bank (unsafe_active_bank),
      .core_swap_pending(u_core_pending_unused),
      .w_o              (unsafe_w)
  );

  // ---------------------------------------------------------------------------
  // Geometry echo
  // ---------------------------------------------------------------------------
  assign cfg_n_ant         = 8'(N_ANT);
  assign cfg_n_beams       = 8'(N_BEAMS);
  assign cfg_mult_pipe     = 8'(MULT_PIPE);
  assign cfg_weight_addr_w = 8'(ADDR_W);
  assign cfg_acc_w         = 8'(bf_acc_w(bf_uint_t'(N_ANT)));
  assign cfg_dot16_acc_w   = 8'(D_ACC_W);
  assign cfg_lat0          = 8'(bf_lat_cycles(bf_uint_t'(N_ANT),
                                              bf_uint_t'(MULT_PIPE),
                                              bf_uint_t'(1)));
  assign cfg_lat1          = 8'(bf_lat_cycles(bf_uint_t'(N_ANT),
                                              bf_uint_t'(MULT_PIPE),
                                              bf_uint_t'(1)));
  assign cfg_lat2          = 8'(bf_lat_cycles(bf_uint_t'(N_ANT),
                                              bf_uint_t'(MULT_PIPE),
                                              bf_uint_t'(2)));
  assign cfg_dot16_lat_r1  = 8'(bf_dot_lat(bf_uint_t'(D_N_ANT),
                                           bf_uint_t'(MULT_PIPE),
                                           bf_uint_t'(1)));
  assign cfg_dot16_lat_r2  = 8'(bf_dot_lat(bf_uint_t'(D_N_ANT),
                                           bf_uint_t'(MULT_PIPE),
                                           bf_uint_t'(2)));
  assign cfg_s_payload_w   = 16'(S_PAYLOAD_W);
  assign cfg_m0_payload_w  = 16'(M04_PAYLOAD_W);
  assign cfg_m1_payload_w  = 16'(M2_PAYLOAD_W);

endmodule : beamformer_top

`default_nettype wire
