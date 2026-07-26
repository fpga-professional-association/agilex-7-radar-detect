// -----------------------------------------------------------------------------
// cfar_top — CFAR detector verification top (issue #14, SPEC 13.1).
//
// Holds rtl/cfar/ in one elaboration, on one clock, with flat scalar ports so
// the C++ test (sim/tests/test_cfar.cpp) can drive and observe every field
// without a stream fabric, a register plane or a clock scheduler in the way. A
// failure in this build is unambiguously a CFAR failure — the same arrangement,
// for the same reason, as cmult_top, pfb_top, fft_top and covar_top.
//
// TWO ELABORATIONS, driven from one stimulus port:
//
//   u_cfar_a   the configured geometry, MAX_GUARD / MAX_REF from
//              config/<name>.json. The main subject: every threshold, edge,
//              masking, mode and backpressure case runs here.
//
//   u_cfar_b   MAX_GUARD = 0, MAX_REF = 3. Two things this proves that the
//              first instance cannot. First, that MAX_GUARD = 0 ELABORATES —
//              the reference bands then start immediately beside the cell under
//              test, which is the case where an off-by-one in cfar_window's
//              band comparison puts the cell under test inside its own
//              reference window. Second, that a SHORT structural half-window
//              (D = 3 rather than 10) produces the same answers, so the
//              parameterisation is exercised rather than assumed.
//
// Both instances see the same payload fields and the same configuration, and
// each has its own `valid`/`ready` pair, so a pass drives whichever one it is
// about. Observation is muxed by `obs_sel`, which is exactly the pattern
// cmult_top uses for its twelve DUTs.
//
// The packed event is ALSO exported raw, as three 64-bit words, so the test can
// unpack it independently and compare against the field ports. That is the same
// check test_stream_loopback makes on the SPEC 5 payload: a pack/unpack pair
// that is only ever used against itself proves nothing.
//
// Simulation only. Not in files.f, never in a Quartus source list; the DUTs
// themselves are in files.f.
// -----------------------------------------------------------------------------

`default_nettype none

module cfar_top
  import cfar_pkg::*;
  import stream_pkg::*;
#(
    // Geometry, defaulted from the generated configuration package so the same
    // RTL elaborates at every SPEC 11 size.
    parameter int unsigned MAX_GUARD_A = config_pkg::CFAR_MAX_GUARD,
    parameter int unsigned MAX_REF_A   = config_pkg::CFAR_MAX_REF,

    // The second elaboration. Deliberately NOT from the configuration: its whole
    // purpose is to be a different shape from the first one.
    parameter int unsigned MAX_GUARD_B = 0,
    parameter int unsigned MAX_REF_B   = 3
) (
    input  wire        clk,
    input  wire        rst_n,

    // ---- stimulus: one power bin per beat, shared payload -------------------
    input  wire        s_valid_a,
    input  wire        s_valid_b,
    output wire        s_ready_a,
    output wire        s_ready_b,
    input  wire [39:0] s_data,
    input  wire        s_sof,
    input  wire        s_eof,
    input  wire [7:0]  s_id,
    input  wire [15:0] s_seq,
    input  wire [3:0]  s_user,

    // ---- detection-event stream ---------------------------------------------
    input  wire        m_ready_a,
    input  wire        m_ready_b,
    output wire        m_valid_a,
    output wire        m_valid_b,

    // Observation mux: 0 selects u_cfar_a, 1 selects u_cfar_b.
    input  wire        obs_sel,

    output wire        m_sof,
    output wire        m_eof,
    output wire [7:0]  m_id,
    output wire [15:0] m_seq,
    output wire [3:0]  m_user,

    // ---- the selected instance's event, unpacked ----------------------------
    output wire [1:0]  ev_kind,
    output wire [15:0] ev_bin,
    output wire [15:0] ev_frame,
    output wire [6:0]  ev_refcnt,
    output wire [15:0] ev_alpha,
    output wire [15:0] ev_det,
    output wire [15:0] ev_sup,
    output wire [39:0] ev_cut,
    output wire [46:0] ev_sum,

    // ---- and packed, unmodified, for the independent unpack cross-check -----
    output wire [63:0] ev_pack0,
    output wire [63:0] ev_pack1,
    output wire [63:0] ev_pack2,

    // ---- configuration, shared by both instances ----------------------------
    input  wire        cfg_enable,
    input  wire [1:0]  cfg_mode,
    input  wire        cfg_out_mode,
    input  wire [4:0]  cfg_guard_lead,
    input  wire [4:0]  cfg_guard_lag,
    input  wire [5:0]  cfg_ref_lead,
    input  wire [5:0]  cfg_ref_lag,
    input  wire [15:0] cfg_alpha,
    input  wire        cfg_status_clear,

    // ---- status, muxed by obs_sel -------------------------------------------
    output wire [31:0] stat_det_count,
    output wire [31:0] stat_sup_count,
    output wire [31:0] stat_frame_count,
    output wire [5:0]  stat_fault,
    output wire        obs_cfg_pending,
    output wire        obs_frame_open,
    output wire        obs_active_enable,
    output wire [1:0]  obs_active_mode,
    output wire        obs_active_out_mode,
    output wire [4:0]  obs_active_guard_lead,
    output wire [4:0]  obs_active_guard_lag,
    output wire [5:0]  obs_active_ref_lead,
    output wire [5:0]  obs_active_ref_lag,
    output wire [15:0] obs_active_alpha,
    output wire [6:0]  obs_n_lead,
    output wire [6:0]  obs_n_lag,

    // ---- geometry echo -------------------------------------------------------
    // Everything the C++ mirror has to agree with, checked before any stimulus.
    output wire [7:0]  cfg_max_guard_a,
    output wire [7:0]  cfg_max_ref_a,
    output wire [7:0]  cfg_max_guard_b,
    output wire [7:0]  cfg_max_ref_b,
    output wire [7:0]  cfg_power_w,
    output wire [7:0]  cfg_bin_w,
    output wire [7:0]  cfg_alpha_w,
    output wire [7:0]  cfg_alpha_frac_w,
    output wire [7:0]  cfg_guard_cnt_w,
    output wire [7:0]  cfg_ref_cnt_w,
    output wire [7:0]  cfg_totref_w,
    output wire [7:0]  cfg_event_sum_w,
    output wire [7:0]  cfg_cnt_w,
    output wire [15:0] cfg_event_w,
    output wire [7:0]  cfg_sum_w_a,
    output wire [7:0]  cfg_cmp_w_a,
    output wire [15:0] cfg_half_window_a,
    output wire [15:0] cfg_slots_a
);

  // ---------------------------------------------------------------------------
  // Stream geometry. One power value in, one detection event out; the metadata
  // widths are shared.
  // ---------------------------------------------------------------------------
  localparam int unsigned ID_W    = 4;
  localparam int unsigned SEQ_W   = 16;
  localparam int unsigned USER_W  = 4;
  localparam int unsigned IN_W    = int'(cfar_power_w());
  localparam int unsigned OUT_W   = int'(CFAR_EVENT_W);

  localparam int unsigned SPW = IN_W  + 2 + ID_W + SEQ_W + USER_W;
  localparam int unsigned MPW = OUT_W + 2 + ID_W + SEQ_W + USER_W;

  localparam stream_geom_t S_GEOM = stream_geom(stream_pkg::uint_t'(IN_W),
                                                stream_pkg::uint_t'(ID_W),
                                                stream_pkg::uint_t'(SEQ_W),
                                                stream_pkg::uint_t'(USER_W));
  localparam stream_geom_t M_GEOM = stream_geom(stream_pkg::uint_t'(OUT_W),
                                                stream_pkg::uint_t'(ID_W),
                                                stream_pkg::uint_t'(SEQ_W),
                                                stream_pkg::uint_t'(USER_W));

`ifndef SYNTHESIS
  initial begin
    if (config_pkg::POWER_W != int'(cfar_power_w())) begin
      $fatal(1, "cfar_top: config POWER_W=%0d disagrees with cfar_pkg=%0d",
             config_pkg::POWER_W, int'(cfar_power_w()));
    end
    if (MAX_GUARD_B != 0) begin
      $fatal(1, "cfar_top: the second elaboration exists to cover MAX_GUARD = 0");
    end
  end
`endif

  // ---------------------------------------------------------------------------
  // Stimulus packing
  // ---------------------------------------------------------------------------
  stream_fields_t s_fields;

  always_comb begin
    s_fields           = '0;
    s_fields.data      = STREAM_MAX_DATA_W'(s_data);
    s_fields.sof       = s_sof;
    s_fields.eof       = s_eof;
    s_fields.stream_id = STREAM_MAX_ID_W'(s_id);
    s_fields.seq       = STREAM_MAX_SEQ_W'(s_seq);
    s_fields.user      = STREAM_MAX_USER_W'(s_user);
  end

  wire [SPW-1:0] s_payload = SPW'(stream_pack(S_GEOM, s_fields));

  // ---------------------------------------------------------------------------
  // The two DUTs
  // ---------------------------------------------------------------------------
  wire [MPW-1:0] m_payload_a, m_payload_b;

  wire [31:0] det_a, sup_a, frm_a, det_b, sup_b, frm_b;
  wire [5:0]  fault_a, fault_b;
  wire        pend_a, pend_b, open_a, open_b;
  wire        en_a, en_b, om_a, om_b;
  wire [1:0]  mode_a, mode_b;
  wire [4:0]  gl_a, gg_a, gl_b, gg_b;
  wire [5:0]  rl_a, rg_a, rl_b, rg_b;
  wire [15:0] al_a, al_b;
  wire [6:0]  nl_a, ng_a, nl_b, ng_b;
  wire [4:0]  mg_a, mg_b;
  wire [5:0]  mr_a, mr_b;

  cfar_core #(
      .MAX_GUARD   (MAX_GUARD_A),
      .MAX_REF     (MAX_REF_A),
      .OUT_DEPTH   (8),
      .STREAM_ID_W (ID_W),
      .SEQ_W       (SEQ_W),
      .USER_W      (USER_W)
  ) u_cfar_a (
      .clk                   (clk),
      .rst_n                 (rst_n),
      .s_valid               (s_valid_a),
      .s_ready               (s_ready_a),
      .s_payload             (s_payload),
      .m_valid               (m_valid_a),
      .m_ready               (m_ready_a),
      .m_payload             (m_payload_a),
      .cfg_enable            (cfg_enable),
      .cfg_mode              (cfg_mode),
      .cfg_out_mode          (cfg_out_mode),
      .cfg_guard_lead        (cfg_guard_lead),
      .cfg_guard_lag         (cfg_guard_lag),
      .cfg_ref_lead          (cfg_ref_lead),
      .cfg_ref_lag           (cfg_ref_lag),
      .cfg_alpha             (cfg_alpha),
      .cfg_status_clear      (cfg_status_clear),
      .stat_det_count        (det_a),
      .stat_sup_count        (sup_a),
      .stat_frame_count      (frm_a),
      .stat_fault            (fault_a),
      .obs_cfg_pending       (pend_a),
      .obs_active_enable     (en_a),
      .obs_active_mode       (mode_a),
      .obs_active_out_mode   (om_a),
      .obs_active_guard_lead (gl_a),
      .obs_active_guard_lag  (gg_a),
      .obs_active_ref_lead   (rl_a),
      .obs_active_ref_lag    (rg_a),
      .obs_active_alpha      (al_a),
      .obs_frame_open        (open_a),
      .obs_max_guard         (mg_a),
      .obs_max_ref           (mr_a),
      .obs_n_lead            (nl_a),
      .obs_n_lag             (ng_a)
  );

  cfar_core #(
      .MAX_GUARD   (MAX_GUARD_B),
      .MAX_REF     (MAX_REF_B),
      .OUT_DEPTH   (8),
      .STREAM_ID_W (ID_W),
      .SEQ_W       (SEQ_W),
      .USER_W      (USER_W)
  ) u_cfar_b (
      .clk                   (clk),
      .rst_n                 (rst_n),
      .s_valid               (s_valid_b),
      .s_ready               (s_ready_b),
      .s_payload             (s_payload),
      .m_valid               (m_valid_b),
      .m_ready               (m_ready_b),
      .m_payload             (m_payload_b),
      .cfg_enable            (cfg_enable),
      .cfg_mode              (cfg_mode),
      .cfg_out_mode          (cfg_out_mode),
      .cfg_guard_lead        (cfg_guard_lead),
      .cfg_guard_lag         (cfg_guard_lag),
      .cfg_ref_lead          (cfg_ref_lead),
      .cfg_ref_lag           (cfg_ref_lag),
      .cfg_alpha             (cfg_alpha),
      .cfg_status_clear      (cfg_status_clear),
      .stat_det_count        (det_b),
      .stat_sup_count        (sup_b),
      .stat_frame_count      (frm_b),
      .stat_fault            (fault_b),
      .obs_cfg_pending       (pend_b),
      .obs_active_enable     (en_b),
      .obs_active_mode       (mode_b),
      .obs_active_out_mode   (om_b),
      .obs_active_guard_lead (gl_b),
      .obs_active_guard_lag  (gg_b),
      .obs_active_ref_lead   (rl_b),
      .obs_active_ref_lag    (rg_b),
      .obs_active_alpha      (al_b),
      .obs_frame_open        (open_b),
      .obs_max_guard         (mg_b),
      .obs_max_ref           (mr_b),
      .obs_n_lead            (nl_b),
      .obs_n_lag             (ng_b)
  );

  // ---------------------------------------------------------------------------
  // Observation mux
  // ---------------------------------------------------------------------------
  wire [MPW-1:0] m_payload_sel = obs_sel ? m_payload_b : m_payload_a;

  stream_fields_t m_fields;
  assign m_fields = stream_unpack(M_GEOM, stream_payload_t'(m_payload_sel));

  assign m_sof  = m_fields.sof;
  assign m_eof  = m_fields.eof;
  assign m_id   = 8'(m_fields.stream_id[ID_W-1:0]);
  assign m_seq  = m_fields.seq[15:0];
  assign m_user = m_fields.user[3:0];

  wire cfar_event_bits_t ev_bits = cfar_event_bits_t'(m_fields.data[OUT_W-1:0]);
  cfar_event_t ev;
  assign ev = cfar_event_unpack(ev_bits);

  assign ev_kind   = ev.kind;
  assign ev_bin    = ev.bin;
  assign ev_frame  = ev.frame_id;
  assign ev_refcnt = ev.ref_count;
  assign ev_alpha  = ev.alpha;
  assign ev_det    = ev.det_count;
  assign ev_sup    = ev.sup_count;
  assign ev_cut    = ev.cut_power;
  assign ev_sum    = ev.noise_sum;

  // The packed event, split into three 64-bit words so no port exceeds the
  // simulator's scalar boundary. 176 bits occupy words 0..2 with the top 16 bits
  // of word 2 unused.
  wire [191:0] ev_pack_pad = 192'(ev_bits);
  assign ev_pack0 = ev_pack_pad[63:0];
  assign ev_pack1 = ev_pack_pad[127:64];
  assign ev_pack2 = ev_pack_pad[191:128];

  assign stat_det_count        = obs_sel ? det_b   : det_a;
  assign stat_sup_count        = obs_sel ? sup_b   : sup_a;
  assign stat_frame_count      = obs_sel ? frm_b   : frm_a;
  assign stat_fault            = obs_sel ? fault_b : fault_a;
  assign obs_cfg_pending       = obs_sel ? pend_b  : pend_a;
  assign obs_frame_open        = obs_sel ? open_b  : open_a;
  assign obs_active_enable     = obs_sel ? en_b    : en_a;
  assign obs_active_mode       = obs_sel ? mode_b  : mode_a;
  assign obs_active_out_mode   = obs_sel ? om_b    : om_a;
  assign obs_active_guard_lead = obs_sel ? gl_b    : gl_a;
  assign obs_active_guard_lag  = obs_sel ? gg_b    : gg_a;
  assign obs_active_ref_lead   = obs_sel ? rl_b    : rl_a;
  assign obs_active_ref_lag    = obs_sel ? rg_b    : rg_a;
  assign obs_active_alpha      = obs_sel ? al_b    : al_a;
  assign obs_n_lead            = obs_sel ? nl_b    : nl_a;
  assign obs_n_lag             = obs_sel ? ng_b    : ng_a;

  // ---------------------------------------------------------------------------
  // Geometry echo
  // ---------------------------------------------------------------------------
  assign cfg_max_guard_a   = 8'(mg_a);
  assign cfg_max_ref_a     = 8'(mr_a);
  assign cfg_max_guard_b   = 8'(mg_b);
  assign cfg_max_ref_b     = 8'(mr_b);
  assign cfg_power_w       = 8'(cfar_power_w());
  assign cfg_bin_w         = 8'(cfar_bin_w());
  assign cfg_alpha_w       = 8'(cfar_alpha_w());
  assign cfg_alpha_frac_w  = 8'(cfar_alpha_frac_w());
  assign cfg_guard_cnt_w   = 8'(cfar_guard_cnt_w());
  assign cfg_ref_cnt_w     = 8'(cfar_ref_cnt_w());
  assign cfg_totref_w      = 8'(cfar_totref_w());
  assign cfg_event_sum_w   = 8'(cfar_event_sum_w());
  assign cfg_cnt_w         = 8'(cfar_cnt_w());
  assign cfg_event_w       = 16'(cfar_event_w());
  assign cfg_sum_w_a       = 8'(cfar_sum_w(cfar_uint_t'(MAX_REF_A)));
  assign cfg_cmp_w_a       = 8'(cfar_cmp_w(cfar_uint_t'(MAX_REF_A)));
  assign cfg_half_window_a = 16'(cfar_half_window(cfar_uint_t'(MAX_GUARD_A),
                                                  cfar_uint_t'(MAX_REF_A)));
  assign cfg_slots_a       = 16'(cfar_window_slots(cfar_uint_t'(MAX_GUARD_A),
                                                   cfar_uint_t'(MAX_REF_A)));

endmodule : cfar_top

`default_nettype wire
