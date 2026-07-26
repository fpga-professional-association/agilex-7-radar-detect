// -----------------------------------------------------------------------------
// history_top — verification top for the SPEC.md 7.3 time-frequency history and
// corner turn (issue #15).
//
// Simulation-only. Never synthesized, never listed in a Quartus source list. The
// Quartus view of this block is quartus/calibration/history_bank_wrap.sv and
// history_core_wrap.sv, which are different files for a different purpose.
//
// -----------------------------------------------------------------------------
// THREE ELABORATIONS, ONE PORT SET
// -----------------------------------------------------------------------------
// The block's behaviour depends on its geometry in ways that a single
// elaboration cannot exercise: whether there is more than one lane decides
// whether the bank-select is a real decode, and whether the input is bit-reversed
// decides whether the read address is a permutation. So three DUTs are built:
//
//   sel  antennas  bins  lanes  frames_max  bit-reversed   what it is for
//   ---  --------  ----  -----  ----------  ------------   --------------------
//    0      2       64     1        4           no         the SPEC 11 tiny
//                                                          geometry, verbatim
//    1      2       64     2        4          YES         lanes > 1 AND the
//                                                          bit-reversal
//                                                          absorption, together
//    2      4       32     1        8           no         four antennas and a
//                                                          deeper rotation
//
// They share ONE port set, sized to the widest of them, and `dut_sel` says which
// one the stimulus reaches and whose status is observed. The unselected DUTs are
// held with `cfg_enable` low, so they neither accept beats nor advance state, and
// a test that forgets to select is not silently testing DUT 0's leftovers.
//
// Sharing the port set is what keeps the C++ driver written once. The
// alternative — a suffixed port group per geometry — triples the test code and
// makes it possible for two geometries to be driven by two subtly different
// drivers, which is a way to pass a test the RTL should fail.
//
// -----------------------------------------------------------------------------
// THE TOP PACKS AND UNPACKS; THE TEST DOES NOT
// -----------------------------------------------------------------------------
// The write stimulus arrives as flat sample words plus start/end flags, and this
// module builds the SPEC 5 payload with `stream_pack`. The response leaves as
// flat vector words plus decoded metadata, built with `stream_unpack` and
// `hist_meta_unpack`.
//
// That is deliberate: the packing is stream_pkg's and history_pkg's business,
// and a C++ mirror of it in the test would be a second definition of the layout
// that could agree with itself while disagreeing with the design. What the test
// checks is VALUES; what this file checks, by construction, is that the values
// survive the canonical pack/unpack pair.
//
// -----------------------------------------------------------------------------
// GEOMETRY ECHO
// -----------------------------------------------------------------------------
// `geo_*` reports the selected DUT's elaborated geometry. The C++ test compares
// it against its own `hist::Config` before any stimulus runs and aborts on a
// mismatch, so "the model was configured for a different DUT" fails in one line
// at time zero rather than as a thousand data mismatches.
//
// Lint contract: clean under `verilator --lint-only --Wall` with no waiver.
// -----------------------------------------------------------------------------

`default_nettype none

module history_top
  import history_pkg::*;
  import stream_pkg::*;
(
    input  wire         core_clk,
    input  wire         core_rst_n,
    input  wire         history_clk,
    input  wire         history_rst_n,

    // Which DUT the stimulus reaches and which one is observed.
    input  wire [1:0]   dut_sel,

    // ---- write stimulus, shared ----
    // Antenna `a` lane `l` occupies wr_data[(a*MAX_LANES + l)*32 +: 32], packed
    // {im, re} exactly as fxp_pkg::fxp_complex_t. Antennas past the selected
    // DUT's N_ANT are ignored.
    input  wire [3:0]   wr_valid,
    output wire [3:0]   wr_ready,
    input  wire [3:0]   wr_sof,
    input  wire [3:0]   wr_eof,
    input  wire [255:0] wr_data,

    // ---- configuration ----
    input  wire         cfg_enable,
    input  wire [15:0]  cfg_depth,
    input  wire         cfg_depth_apply,
    input  wire         cfg_counter_clear,
    input  wire         cfg_sticky_clear,
    input  wire         cfg_force_unsafe,

    // ---- status ----
    output wire [15:0]  stat_depth_active,
    output wire [15:0]  stat_occupancy,
    output wire [31:0]  stat_frames_done,
    output wire [31:0]  stat_overwrite_count,
    output wire [31:0]  stat_skew_count,
    output wire [31:0]  stat_write_beat_count,
    output wire [31:0]  stat_read_count,
    output wire [31:0]  stat_collision_count,
    output wire [31:0]  stat_error_count,
    output wire [7:0]   stat_epoch,
    output wire [3:0]   stat_fault,
    output wire         obs_depth_pending,

    // ---- read request ----
    input  wire         rd_req_valid,
    output wire         rd_req_ready,
    input  wire [15:0]  rd_req_bin,
    input  wire [15:0]  rd_req_frame_off,

    // ---- read response, decoded ----
    output wire         m_valid,
    input  wire         m_ready,
    output wire [127:0] m_vec,        // antenna a at m_vec[a*32 +: 32]
    output wire [15:0]  m_bin,
    output wire [15:0]  m_frame_off,
    output wire [31:0]  m_frame_id,
    output wire [7:0]   m_flags,
    output wire [15:0]  m_seq,
    // The stream's own identity fields, brought out so the C++ test can check
    // that the block's `user` mirror of the flags agrees with the flags inside
    // the metadata — two statements of the same fact, from two different parts
    // of the payload, which is the only way a packing mistake in either one
    // becomes visible.
    output wire [7:0]   m_user,
    // { sof, eof, 4'd0, stream_id[1:0] }. The frame flags are here rather than
    // on their own pins because a response is a complete one-beat frame and the
    // test's job is to confirm that both bits are set on every one of them; a
    // response that arrived with either clear would be a beat of a frame that
    // has no other beats.
    output wire [7:0]   m_id,

    // ---- geometry echo for the selected DUT ----
    output wire [7:0]   geo_n_ant,
    output wire [7:0]   geo_lanes,
    output wire [15:0]  geo_fft_size,
    output wire [15:0]  geo_frames_max,
    output wire         geo_bit_reversed,
    output wire [7:0]   geo_read_latency,
    output wire [7:0]   geo_n_duts
);

  localparam int unsigned N_DUT     = 3;
  localparam int unsigned MAX_ANT   = 4;
  localparam int unsigned MAX_LANES = 2;
  localparam int unsigned SAMPLE_W  = 16;
  localparam int unsigned WORD_W    = 2 * SAMPLE_W;

  localparam int unsigned WR_ID_W   = 2;
  localparam int unsigned WR_SEQ_W  = 16;
  localparam int unsigned WR_USER_W = 4;
  localparam int unsigned RD_ID_W   = 2;
  localparam int unsigned RD_SEQ_W  = 16;
  localparam int unsigned RD_USER_W = 4;

  // The three geometries, as parallel tables so the instantiation below is one
  // generate loop rather than three copies that can drift.
  //
  // Every geometry keeps BEATS_PER_FRAME at 32 or more. That is not cosmetic:
  // history_core's readable bound absorbs one frame of publication lag, and a
  // frame shorter than a handshake round trip would break the margin the bound
  // is sized against (history_core header section 5). 32 beats against a round
  // trip of roughly eight is the smallest ratio worth testing at.
  localparam int unsigned ANT_OF   [N_DUT] = '{2, 2, 4};
  localparam int unsigned FFT_OF   [N_DUT] = '{64, 64, 32};
  localparam int unsigned LANE_OF  [N_DUT] = '{1, 2, 1};
  localparam int unsigned FRAME_OF [N_DUT] = '{4, 4, 8};
  localparam bit          REV_OF   [N_DUT] = '{1'b0, 1'b1, 1'b0};

  // Per-DUT observation buses, padded to the shared port widths.
  logic [3:0]   d_wr_ready   [N_DUT];
  logic [15:0]  d_depth      [N_DUT];
  logic [15:0]  d_occ        [N_DUT];
  logic [31:0]  d_frames     [N_DUT];
  logic [31:0]  d_overwrite  [N_DUT];
  logic [31:0]  d_skew       [N_DUT];
  logic [31:0]  d_wbeat      [N_DUT];
  logic [31:0]  d_read       [N_DUT];
  logic [31:0]  d_coll       [N_DUT];
  logic [31:0]  d_err        [N_DUT];
  logic [7:0]   d_epoch      [N_DUT];
  logic [3:0]   d_fault      [N_DUT];
  logic         d_pending    [N_DUT];
  logic         d_req_ready  [N_DUT];
  logic         d_m_valid    [N_DUT];
  logic [MAX_ANT*WORD_W-1:0] d_m_vec [N_DUT];
  logic [15:0]  d_m_bin      [N_DUT];
  logic [15:0]  d_m_foff     [N_DUT];
  logic [31:0]  d_m_frame    [N_DUT];
  logic [7:0]   d_m_flags    [N_DUT];
  logic [15:0]  d_m_seq      [N_DUT];
  logic [7:0]   d_m_user     [N_DUT];
  logic [7:0]   d_m_id       [N_DUT];

  for (genvar k = 0; k < int'(N_DUT); k++) begin : g_dut
    localparam int unsigned NA = ANT_OF[k];
    localparam int unsigned NF = FFT_OF[k];
    localparam int unsigned NL = LANE_OF[k];
    localparam int unsigned NM = FRAME_OF[k];
    localparam bit          BR = REV_OF[k];

    localparam hist_geom_t GK = hist_geom(NA, NF, NL, NM, SAMPLE_W);
    localparam int unsigned VEC_W_K  = int'(hist_vec_w(GK));
    localparam int unsigned META_W_K = int'(hist_meta_w(GK));
    localparam int unsigned DATA_W_K = int'(hist_data_w(GK));

    localparam stream_geom_t WGK =
        stream_geom(NL * WORD_W, WR_ID_W, WR_SEQ_W, WR_USER_W);
    localparam stream_geom_t RGK =
        stream_geom(DATA_W_K, RD_ID_W, RD_SEQ_W, RD_USER_W);

    localparam int unsigned WPW = int'(stream_payload_w(WGK));
    localparam int unsigned RPW = int'(stream_payload_w(RGK));

    wire sel = (dut_sel == 2'(k));

    // ---- write side: build one SPEC 5 payload per antenna ----
    logic [NA*WPW-1:0] s_payload;
    always_comb begin
      stream_fields_t wf;
      s_payload = '0;
      for (int unsigned a = 0; a < NA; a++) begin
        wf           = '0;
        wf.sof       = wr_sof[a];
        wf.eof       = wr_eof[a];
        wf.stream_id = STREAM_MAX_ID_W'(a);
        wf.seq       = '0;
        wf.user      = '0;
        for (int unsigned l = 0; l < NL; l++) begin
          wf.data[l*WORD_W +: WORD_W] =
              wr_data[(a*MAX_LANES + l)*WORD_W +: WORD_W];
        end
        s_payload[a*WPW +: WPW] = WPW'(stream_pack(WGK, wf));
      end
    end

    wire [NA-1:0]  s_valid_k = wr_valid[NA-1:0] & {NA{sel}};
    wire [NA-1:0]  s_ready_k;

    wire [15:0] depth_k, occ_k;
    wire [31:0] frames_k, ovw_k, skw_k, wbt_k, rdc_k, col_k, err_k;
    wire [7:0]  epoch_k;
    wire [3:0]  fault_k;
    wire        pending_k, req_ready_k, mv_k;
    wire [RPW-1:0] m_payload_k;

    history_core #(
        .N_ANT              (NA),
        .FFT_SIZE           (NF),
        .LANES              (NL),
        .FRAMES_MAX         (NM),
        .SAMPLE_W           (SAMPLE_W),
        .INPUT_BIT_REVERSED (BR),
        .STORAGE            ("auto"),
        .SYNC_STAGES        (2),
        .WR_ID_W            (WR_ID_W),
        .WR_SEQ_W           (WR_SEQ_W),
        .WR_USER_W          (WR_USER_W),
        .RD_ID_W            (RD_ID_W),
        .RD_SEQ_W           (RD_SEQ_W),
        .RD_USER_W          (RD_USER_W)
    ) u_core (
        .core_clk              (core_clk),
        .core_rst_n            (core_rst_n),
        .s_valid               (s_valid_k),
        .s_ready               (s_ready_k),
        .s_payload             (s_payload),
        .cfg_enable            (cfg_enable && sel),
        .cfg_depth             (cfg_depth),
        .cfg_depth_apply       (cfg_depth_apply && sel),
        .cfg_counter_clear     (cfg_counter_clear && sel),
        .cfg_sticky_clear      (cfg_sticky_clear && sel),
        .cfg_force_unsafe      (cfg_force_unsafe && sel),
        .stat_depth_active     (depth_k),
        .stat_occupancy        (occ_k),
        .stat_frames_done      (frames_k),
        .stat_overwrite_count  (ovw_k),
        .stat_skew_count       (skw_k),
        .stat_write_beat_count (wbt_k),
        .stat_read_count       (rdc_k),
        .stat_collision_count  (col_k),
        .stat_error_count      (err_k),
        .stat_epoch            (epoch_k),
        .stat_fault            (fault_k),
        .obs_depth_pending     (pending_k),
        .history_clk           (history_clk),
        .history_rst_n         (history_rst_n),
        .rd_req_valid          (rd_req_valid && sel),
        .rd_req_ready          (req_ready_k),
        .rd_req_bin            (rd_req_bin),
        .rd_req_frame_off      (rd_req_frame_off),
        .m_valid               (mv_k),
        .m_ready               (m_ready && sel),
        .m_payload             (m_payload_k)
    );

    // ---- response decode ----
    stream_fields_t rf;
    assign rf = stream_unpack(RGK, stream_payload_t'(m_payload_k));

    hist_meta_fields_t mf;
    assign mf = hist_meta_unpack(GK,
        hist_meta_t'(rf.data[VEC_W_K +: META_W_K]));

    always_comb begin
      d_wr_ready[k]  = '0;
      d_wr_ready[k][NA-1:0] = s_ready_k;
      d_depth[k]     = depth_k;
      d_occ[k]       = occ_k;
      d_frames[k]    = frames_k;
      d_overwrite[k] = ovw_k;
      d_skew[k]      = skw_k;
      d_wbeat[k]     = wbt_k;
      d_read[k]      = rdc_k;
      d_coll[k]      = col_k;
      d_err[k]       = err_k;
      d_epoch[k]     = epoch_k;
      d_fault[k]     = fault_k;
      d_pending[k]   = pending_k;
      d_req_ready[k] = req_ready_k;
      d_m_valid[k]   = mv_k;
      d_m_vec[k]     = (MAX_ANT*WORD_W)'(rf.data[VEC_W_K-1:0]);
      d_m_bin[k]     = 16'(mf.bin);
      d_m_foff[k]    = 16'(mf.frame_off);
      d_m_frame[k]   = mf.frame_id;
      d_m_flags[k]   = 8'(mf.flags);
      d_m_seq[k]     = 16'(rf.seq[RD_SEQ_W-1:0]);
      d_m_user[k]    = 8'(rf.user[RD_USER_W-1:0]);
      d_m_id[k]      = {rf.sof, rf.eof, 4'd0, rf.stream_id[RD_ID_W-1:0]};
    end
  end

  // ---------------------------------------------------------------------------
  // Observation mux
  // ---------------------------------------------------------------------------
  wire [1:0] sel_i = (dut_sel < 2'(N_DUT)) ? dut_sel : 2'd0;

  assign wr_ready             = d_wr_ready[sel_i];
  assign stat_depth_active    = d_depth[sel_i];
  assign stat_occupancy       = d_occ[sel_i];
  assign stat_frames_done     = d_frames[sel_i];
  assign stat_overwrite_count = d_overwrite[sel_i];
  assign stat_skew_count      = d_skew[sel_i];
  assign stat_write_beat_count= d_wbeat[sel_i];
  assign stat_read_count      = d_read[sel_i];
  assign stat_collision_count = d_coll[sel_i];
  assign stat_error_count     = d_err[sel_i];
  assign stat_epoch           = d_epoch[sel_i];
  assign stat_fault           = d_fault[sel_i];
  assign obs_depth_pending    = d_pending[sel_i];
  assign rd_req_ready         = d_req_ready[sel_i];
  assign m_valid              = d_m_valid[sel_i];
  assign m_vec                = d_m_vec[sel_i];
  assign m_bin                = d_m_bin[sel_i];
  assign m_frame_off          = d_m_foff[sel_i];
  assign m_frame_id           = d_m_frame[sel_i];
  assign m_flags              = d_m_flags[sel_i];
  assign m_seq                = d_m_seq[sel_i];
  assign m_user               = d_m_user[sel_i];
  assign m_id                 = d_m_id[sel_i];

  assign geo_n_ant        = 8'(ANT_OF[sel_i]);
  assign geo_lanes        = 8'(LANE_OF[sel_i]);
  assign geo_fft_size     = 16'(FFT_OF[sel_i]);
  assign geo_frames_max   = 16'(FRAME_OF[sel_i]);
  assign geo_bit_reversed = REV_OF[sel_i];
  assign geo_read_latency = 8'(hist_read_latency());
  assign geo_n_duts       = 8'(N_DUT);

`ifndef SYNTHESIS
  initial begin
    // DUT 0 must be the SPEC 11 tiny geometry, verbatim, or the tiny
    // configuration is not what this suite is testing.
    if (ANT_OF[0] != config_pkg::N_ANTENNAS ||
        FFT_OF[0] != config_pkg::FFT_SIZE   ||
        LANE_OF[0] != config_pkg::SAMPLES_PER_CYCLE ||
        FRAME_OF[0] != config_pkg::HISTORY_FRAMES) begin
      $display("[history_top] NOTE: DUT 0 (%0d ant, %0d bins, %0d lanes, %0d frames) is not the '%s' configuration (%0d, %0d, %0d, %0d)",
               ANT_OF[0], FFT_OF[0], LANE_OF[0], FRAME_OF[0],
               config_pkg::CONFIG_NAME, config_pkg::N_ANTENNAS,
               config_pkg::FFT_SIZE, config_pkg::SAMPLES_PER_CYCLE,
               config_pkg::HISTORY_FRAMES);
    end
  end
`endif

endmodule : history_top

`default_nettype wire
