// -----------------------------------------------------------------------------
// covar_top — power / covariance verification top (issue #13, SPEC 13.1).
//
// Holds every piece of rtl/covariance/ in one elaboration, on one clock, with
// flat scalar ports so the C++ test (sim/tests/test_covariance.cpp) can drive
// and observe each one without a stream fabric, a register plane or a clock
// scheduler in the way. A failure in this build is unambiguously a covariance
// failure — the same arrangement, for the same reason, as cmult_top, pfb_top and
// fft_top.
//
// Four DUT groups, each independently drivable:
//
//   u_pow                power_calc on a direct 16-bit sample port. The
//                        corner-case vehicle: (-32768, -32768), zero, +/-1.
//   u_pow_int            an integrator behind u_pow. Proves the COMPOSITION —
//                        that a POWER_W power feeds a POWER_W accumulator with
//                        no width or sign surprise at the seam — which testing
//                        the two separately cannot.
//   u_int_bare           an integrator on a direct 40-bit data port. The window,
//                        exponential-mode and flush vehicle: arbitrary terms can
//                        be injected without having to find a sample that
//                        squares to them.
//   u_int_narrow         a SECOND bare integrator, elaborated at ACC_W = 34, so
//                        its exact-window bound (covar_pkg: 2^(34-32) - 1 = 3)
//                        is reached in four samples instead of 256. Saturation
//                        and the sticky flag are then a four-beat directed test
//                        rather than a long one, and the narrow instance is also
//                        what exercises the "windows above the exact bound may
//                        saturate" elaboration note.
//   u_engine             covar_engine at the configured geometry, with a pair
//                        observation mux.
//
// Source register file. The covariance engine takes a parallel vector of N_SRC
// complex samples, whose flat width grows with the configuration and crosses the
// simulator's 64-bit scalar port boundary at N_SRC = 4. The vector is therefore
// written one source at a time through `src_wr_*` and launched with `src_valid`,
// which keeps every port of this module 32 bits or less and makes the C++ side
// identical at every configuration. It costs the test one cycle per source
// before each beat and nothing at all in the DUT.
//
// Pair observation mux. All N_PAIRS channels run always; `ce_sel` chooses which
// one drives the scalar result ports. The per-pair bit vectors (valid, flushed,
// truncated, saturated, enabled) are exported whole, so the test can see which
// pairs produced a result this cycle and then read each one through the mux —
// the same pattern cmult_top uses for its twelve DUTs.
//
// Simulation only. Not in files.f, never in a Quartus source list; the DUTs
// themselves are in files.f.
// -----------------------------------------------------------------------------

`default_nettype none

module covar_top
  import fxp_pkg::*;
  import covar_pkg::*;
#(
    // Geometry, defaulted from the generated configuration package so the same
    // RTL elaborates at every SPEC 11 size. They are PARAMETERS rather than body
    // localparams only because the pair-enable port width has to reference
    // N_PAIRS, and a port width cannot see a localparam declared in the body.
    parameter int unsigned N_SRC   = config_pkg::N_ANTENNAS,
    parameter int unsigned N_PAIRS = config_pkg::N_COVAR_PAIRS
) (
    input  wire        clk,
    input  wire        rst_n,

    // ---- power_calc, direct sample port -------------------------------------
    input  wire        pw_valid,
    input  wire [15:0] pw_re,
    input  wire [15:0] pw_im,
    output wire        pow_valid,
    output wire [39:0] pow_value,

    // ---- integrator behind power_calc ---------------------------------------
    input  wire [15:0] pi_window_len,
    input  wire        pi_mode,
    input  wire [3:0]  pi_exp_k,
    input  wire        pi_enable,
    input  wire        pi_flush,
    input  wire        pi_sat_clear,
    output wire        pi_valid,
    output wire [39:0] pi_acc,
    output wire [15:0] pi_window_id,
    output wire [15:0] pi_count,
    output wire        pi_flushed,
    output wire        pi_truncated,
    output wire [1:0]  pi_sat_flags,     // {sat_pos, sat_neg}
    output wire        pi_sat_sticky,
    output wire [31:0] pi_sat_count,
    output wire [39:0] pi_obs_acc,
    output wire [15:0] pi_obs_count,

    // ---- bare integrator, direct data port ----------------------------------
    input  wire        bi_valid_in,
    input  wire [39:0] bi_data_in,
    input  wire [15:0] bi_window_len,
    input  wire        bi_mode,
    input  wire [3:0]  bi_exp_k,
    input  wire        bi_enable,
    input  wire        bi_flush,
    input  wire        bi_sat_clear,
    output wire        bi_valid,
    output wire [39:0] bi_acc,
    output wire [15:0] bi_window_id,
    output wire [15:0] bi_count,
    output wire        bi_flushed,
    output wire        bi_truncated,
    output wire [1:0]  bi_sat_flags,
    output wire        bi_sat_sticky,
    output wire [31:0] bi_sat_count,
    output wire [39:0] bi_obs_acc,
    output wire [15:0] bi_obs_count,
    output wire [15:0] bi_obs_len,
    output wire        bi_obs_mode,
    output wire [3:0]  bi_obs_k,
    output wire        bi_obs_enable,

    // ---- narrow integrator (ACC_W = 34), same stimulus, own window ----------
    input  wire [7:0]  ni_window_len,
    output wire        ni_valid,
    output wire [33:0] ni_acc,
    output wire [7:0]  ni_count,
    output wire        ni_flushed,
    output wire        ni_truncated,
    output wire [1:0]  ni_sat_flags,
    output wire        ni_sat_sticky,
    output wire [31:0] ni_sat_count,

    // ---- covariance engine: source vector write port ------------------------
    input  wire        src_wr_en,
    input  wire [7:0]  src_wr_idx,
    input  wire [15:0] src_wr_re,
    input  wire [15:0] src_wr_im,
    input  wire        src_valid,

    // ---- covariance engine: configuration -----------------------------------
    // The pair table is written one entry at a time, for the same width reason
    // the source vector is.
    input  wire        pt_wr_en,
    input  wire [7:0]  pt_wr_idx,
    input  wire [7:0]  pt_wr_x,
    input  wire [7:0]  pt_wr_y,
    input  wire [N_PAIRS-1:0] ce_pair_enable,
    input  wire [15:0] ce_window_len,
    input  wire        ce_mode,
    input  wire [3:0]  ce_exp_k,
    input  wire        ce_flush,
    input  wire        ce_sat_clear,

    // ---- covariance engine: results -----------------------------------------
    input  wire [7:0]  ce_sel,           // pair observation mux
    output wire [31:0] ce_valid,
    output wire [31:0] ce_flushed,
    output wire [31:0] ce_truncated,
    output wire [31:0] ce_sat,
    output wire [31:0] ce_obs_enable,
    output wire        ce_sat_any,
    output wire [31:0] ce_sat_count_max,
    output wire [39:0] ce_acc_re,        // selected pair
    output wire [39:0] ce_acc_im,
    output wire [15:0] ce_window_id,
    output wire [15:0] ce_sample_count,
    output wire [7:0]  ce_obs_x,
    output wire [7:0]  ce_obs_y,

    // ---- geometry echo -------------------------------------------------------
    // Everything the C++ mirror has to agree with. Checked before any stimulus.
    output wire [7:0]  cfg_n_src,
    output wire [7:0]  cfg_n_pairs,
    output wire [7:0]  cfg_power_w,
    output wire [7:0]  cfg_acc_w,
    output wire [7:0]  cfg_window_w,
    output wire [7:0]  cfg_sel_w,
    output wire [7:0]  cfg_exp_k_w,
    output wire [7:0]  cfg_pow_pipe,
    output wire [7:0]  cfg_cmult_pipe,
    output wire [7:0]  cfg_narrow_acc_w,
    output wire [7:0]  cfg_narrow_window_w,
    output wire [31:0] cfg_win_exact_max,
    output wire [31:0] cfg_narrow_win_exact_max
);

  // ---------------------------------------------------------------------------
  // Geometry. Sized from the generated configuration package so the same RTL
  // elaborates at every SPEC 11 size (SPEC 11: "never create a separate
  // hand-written implementation for the small configurations").
  // ---------------------------------------------------------------------------
  localparam int unsigned ACC_W     = COVAR_POWER_W;          // 40
  localparam int unsigned WINDOW_W  = COVAR_WINDOW_LEN_W;     // 16
  localparam int unsigned SEL_W     = int'(covar_src_sel_w()); // 8
  localparam int unsigned SRC_W     = 2 * FXP_SAMPLE_W;       // 32

  localparam int unsigned POW_PIPE   = 2;
  localparam int unsigned CMULT_PIPE = 4;

  // The narrow instance: ACC_W = 34 gives an exact window of 2^(34-32) - 1 = 3,
  // so the fourth maximum-magnitude sample saturates.
  localparam int unsigned NARROW_ACC_W    = COVAR_TERM_W + 2;  // 34
  localparam int unsigned NARROW_WINDOW_W = 8;

`ifndef SYNTHESIS
  initial begin
    if (config_pkg::POWER_W != COVAR_POWER_W) begin
      $fatal(1, "covar_top: config POWER_W=%0d disagrees with covar_pkg COVAR_POWER_W=%0d",
             config_pkg::POWER_W, COVAR_POWER_W);
    end
    if (N_PAIRS > 32) begin
      $fatal(1, "covar_top: N_PAIRS=%0d exceeds the 32-bit observation vectors", N_PAIRS);
    end
  end
`endif

  // ---------------------------------------------------------------------------
  // power_calc, and the integrator behind it
  // ---------------------------------------------------------------------------
  fxp_complex_t pw_sample;
  assign pw_sample = '{re: fxp16_t'(pw_re), im: fxp16_t'(pw_im)};

  wire        pow_v;
  wire signed [ACC_W-1:0] pow_val;
  wire        pow_tag_unused;

  power_calc #(
      .PIPE_STAGES (POW_PIPE),
      .TAG_W       (1)
  ) u_pow (
      .clk       (clk),
      .rst_n     (rst_n),
      .valid_in  (pw_valid),
      .sample    (pw_sample),
      .tag_in    (1'b0),
      .valid_out (pow_v),
      .power     (pow_val),
      .tag_out   (pow_tag_unused)
  );

  assign pow_valid = pow_v;
  assign pow_value = pow_val;

  wire fxp_flags_t pi_flags;
  wire [ACC_W-1:0] pi_obs_acc_w;
  wire [WINDOW_W-1:0] pi_obs_len_unused;
  wire pi_obs_mode_unused;
  wire [COVAR_EXP_K_W-1:0] pi_obs_k_unused;
  wire pi_obs_en_unused;

  integrator #(
      .DATA_W   (ACC_W),
      .ACC_W    (ACC_W),
      .WINDOW_W (WINDOW_W)
  ) u_pow_int (
      .clk            (clk),
      .rst_n          (rst_n),
      .cfg_window_len (pi_window_len),
      .cfg_mode       (pi_mode),
      .cfg_exp_k      (pi_exp_k),
      .cfg_enable     (pi_enable),
      .flush          (pi_flush),
      .sat_clear      (pi_sat_clear),
      .valid_in       (pow_v),
      .data_in        (pow_val),
      .valid_out      (pi_valid),
      .acc_out        (pi_acc),
      .window_id      (pi_window_id),
      .sample_count   (pi_count),
      .flushed        (pi_flushed),
      .truncated      (pi_truncated),
      .sat_flags      (pi_flags),
      .sat_sticky     (pi_sat_sticky),
      .sat_count      (pi_sat_count),
      .obs_acc        (pi_obs_acc_w),
      .obs_count      (pi_obs_count),
      .obs_window_len (pi_obs_len_unused),
      .obs_mode       (pi_obs_mode_unused),
      .obs_exp_k      (pi_obs_k_unused),
      .obs_enable     (pi_obs_en_unused)
  );

  assign pi_sat_flags = {pi_flags.sat_pos, pi_flags.sat_neg};
  assign pi_obs_acc   = pi_obs_acc_w;

  // ---------------------------------------------------------------------------
  // Bare integrator, direct data
  // ---------------------------------------------------------------------------
  wire fxp_flags_t bi_flags;
  wire [ACC_W-1:0] bi_obs_acc_w;

  integrator #(
      .DATA_W   (ACC_W),
      .ACC_W    (ACC_W),
      .WINDOW_W (WINDOW_W)
  ) u_int_bare (
      .clk            (clk),
      .rst_n          (rst_n),
      .cfg_window_len (bi_window_len),
      .cfg_mode       (bi_mode),
      .cfg_exp_k      (bi_exp_k),
      .cfg_enable     (bi_enable),
      .flush          (bi_flush),
      .sat_clear      (bi_sat_clear),
      .valid_in       (bi_valid_in),
      .data_in        (bi_data_in),
      .valid_out      (bi_valid),
      .acc_out        (bi_acc),
      .window_id      (bi_window_id),
      .sample_count   (bi_count),
      .flushed        (bi_flushed),
      .truncated      (bi_truncated),
      .sat_flags      (bi_flags),
      .sat_sticky     (bi_sat_sticky),
      .sat_count      (bi_sat_count),
      .obs_acc        (bi_obs_acc_w),
      .obs_count      (bi_obs_count),
      .obs_window_len (bi_obs_len),
      .obs_mode       (bi_obs_mode),
      .obs_exp_k      (bi_obs_k),
      .obs_enable     (bi_obs_enable)
  );

  assign bi_sat_flags = {bi_flags.sat_pos, bi_flags.sat_neg};
  assign bi_obs_acc   = bi_obs_acc_w;

  // ---------------------------------------------------------------------------
  // Narrow integrator. Same stimulus, truncated to its own width, its own
  // window length, everything else shared with the bare instance.
  // ---------------------------------------------------------------------------
  wire fxp_flags_t ni_flags;
  wire signed [NARROW_ACC_W-1:0] ni_data;
  assign ni_data = NARROW_ACC_W'(signed'(bi_data_in));

  wire [COVAR_WINDOW_ID_W-1:0] ni_wid_unused;
  wire [NARROW_ACC_W-1:0]  ni_obs_acc_unused;
  wire [NARROW_WINDOW_W-1:0] ni_obs_cnt_unused, ni_obs_len_unused;
  wire ni_obs_mode_unused;
  wire [COVAR_EXP_K_W-1:0] ni_obs_k_unused;
  wire ni_obs_en_unused;

  integrator #(
      .DATA_W   (NARROW_ACC_W),
      .ACC_W    (NARROW_ACC_W),
      .WINDOW_W (NARROW_WINDOW_W)
  ) u_int_narrow (
      .clk            (clk),
      .rst_n          (rst_n),
      .cfg_window_len (ni_window_len),
      .cfg_mode       (bi_mode),
      .cfg_exp_k      (bi_exp_k),
      .cfg_enable     (bi_enable),
      .flush          (bi_flush),
      .sat_clear      (bi_sat_clear),
      .valid_in       (bi_valid_in),
      .data_in        (ni_data),
      .valid_out      (ni_valid),
      .acc_out        (ni_acc),
      .window_id      (ni_wid_unused),
      .sample_count   (ni_count),
      .flushed        (ni_flushed),
      .truncated      (ni_truncated),
      .sat_flags      (ni_flags),
      .sat_sticky     (ni_sat_sticky),
      .sat_count      (ni_sat_count),
      .obs_acc        (ni_obs_acc_unused),
      .obs_count      (ni_obs_cnt_unused),
      .obs_window_len (ni_obs_len_unused),
      .obs_mode       (ni_obs_mode_unused),
      .obs_exp_k      (ni_obs_k_unused),
      .obs_enable     (ni_obs_en_unused)
  );

  assign ni_sat_flags = {ni_flags.sat_pos, ni_flags.sat_neg};

  // ---------------------------------------------------------------------------
  // Source vector and pair table, written one entry at a time
  // ---------------------------------------------------------------------------
  logic [N_SRC-1:0][SRC_W-1:0] src_q;
  logic [N_PAIRS-1:0][SEL_W-1:0] pt_x_q, pt_y_q;

  always_ff @(posedge clk) begin
    if (!rst_n) begin
      for (int unsigned s = 0; s < N_SRC; s++)   src_q[s] <= '0;
      for (int unsigned p = 0; p < N_PAIRS; p++) begin
        pt_x_q[p] <= SEL_W'(0);
        pt_y_q[p] <= SEL_W'(0);
      end
    end else begin
      if (src_wr_en) begin
        for (int unsigned s = 0; s < N_SRC; s++) begin
          if (32'(src_wr_idx) == s) src_q[s] <= {src_wr_im, src_wr_re};
        end
      end
      if (pt_wr_en) begin
        for (int unsigned p = 0; p < N_PAIRS; p++) begin
          if (32'(pt_wr_idx) == p) begin
            pt_x_q[p] <= pt_wr_x;
            pt_y_q[p] <= pt_wr_y;
          end
        end
      end
    end
  end

  wire [N_SRC*SRC_W-1:0]   src_flat;
  wire [N_PAIRS*SEL_W-1:0] pt_x_flat, pt_y_flat;

  for (genvar s = 0; s < int'(N_SRC); s++) begin : g_src_flat
    assign src_flat[s*SRC_W +: SRC_W] = src_q[s];
  end
  for (genvar p = 0; p < int'(N_PAIRS); p++) begin : g_pt_flat
    assign pt_x_flat[p*SEL_W +: SEL_W] = pt_x_q[p];
    assign pt_y_flat[p*SEL_W +: SEL_W] = pt_y_q[p];
  end

  // ---------------------------------------------------------------------------
  // The engine
  // ---------------------------------------------------------------------------
  wire [N_PAIRS-1:0]              e_valid, e_flushed, e_trunc, e_sat, e_en;
  wire [N_PAIRS*ACC_W-1:0]        e_acc_re, e_acc_im;
  wire [N_PAIRS*COVAR_WINDOW_ID_W-1:0] e_wid;
  wire [N_PAIRS*WINDOW_W-1:0]     e_cnt;
  wire [N_PAIRS*SEL_W-1:0]        e_obs_x, e_obs_y;

  covar_engine #(
      .N_SRC             (N_SRC),
      .N_PAIRS           (N_PAIRS),
      .CMULT_VARIANT     ("MULT4"),
      .CMULT_PIPE_STAGES (CMULT_PIPE),
      .ACC_W             (ACC_W),
      .WINDOW_W          (WINDOW_W)
  ) u_engine (
      .clk               (clk),
      .rst_n             (rst_n),
      .valid_in          (src_valid),
      .src               (src_flat),
      .cfg_pair_x        (pt_x_flat),
      .cfg_pair_y        (pt_y_flat),
      .cfg_pair_enable   (ce_pair_enable),
      .cfg_window_len    (ce_window_len),
      .cfg_mode          (ce_mode),
      .cfg_exp_k         (ce_exp_k),
      .flush             (ce_flush),
      .sat_clear         (ce_sat_clear),
      .pair_valid        (e_valid),
      .pair_acc_re       (e_acc_re),
      .pair_acc_im       (e_acc_im),
      .pair_window_id    (e_wid),
      .pair_sample_count (e_cnt),
      .pair_flushed      (e_flushed),
      .pair_truncated    (e_trunc),
      .pair_sat          (e_sat),
      .sat_any           (ce_sat_any),
      .sat_count_max     (ce_sat_count_max),
      .obs_pair_x        (e_obs_x),
      .obs_pair_y        (e_obs_y),
      .obs_pair_enable   (e_en)
  );

  assign ce_valid      = 32'(e_valid);
  assign ce_flushed    = 32'(e_flushed);
  assign ce_truncated  = 32'(e_trunc);
  assign ce_sat        = 32'(e_sat);
  assign ce_obs_enable = 32'(e_en);

  // ---- pair observation mux. Out of range selects pair 0. --------------------
  logic [ACC_W-1:0]              m_acc_re, m_acc_im;
  logic [COVAR_WINDOW_ID_W-1:0]  m_wid;
  logic [WINDOW_W-1:0]           m_cnt;
  logic [SEL_W-1:0]              m_x, m_y;

  always_comb begin
    m_acc_re = e_acc_re[0 +: ACC_W];
    m_acc_im = e_acc_im[0 +: ACC_W];
    m_wid    = e_wid[0 +: COVAR_WINDOW_ID_W];
    m_cnt    = e_cnt[0 +: WINDOW_W];
    m_x      = e_obs_x[0 +: SEL_W];
    m_y      = e_obs_y[0 +: SEL_W];
    for (int unsigned p = 0; p < N_PAIRS; p++) begin
      if (32'(ce_sel) == p) begin
        m_acc_re = e_acc_re[p*ACC_W +: ACC_W];
        m_acc_im = e_acc_im[p*ACC_W +: ACC_W];
        m_wid    = e_wid[p*COVAR_WINDOW_ID_W +: COVAR_WINDOW_ID_W];
        m_cnt    = e_cnt[p*WINDOW_W +: WINDOW_W];
        m_x      = e_obs_x[p*SEL_W +: SEL_W];
        m_y      = e_obs_y[p*SEL_W +: SEL_W];
      end
    end
  end

  assign ce_acc_re       = m_acc_re;
  assign ce_acc_im       = m_acc_im;
  assign ce_window_id    = m_wid;
  assign ce_sample_count = m_cnt;
  assign ce_obs_x        = m_x;
  assign ce_obs_y        = m_y;

  // ---------------------------------------------------------------------------
  // Geometry echo
  // ---------------------------------------------------------------------------
  assign cfg_n_src                = 8'(N_SRC);
  assign cfg_n_pairs              = 8'(N_PAIRS);
  assign cfg_power_w              = 8'(COVAR_POWER_W);
  assign cfg_acc_w                = 8'(ACC_W);
  assign cfg_window_w             = 8'(WINDOW_W);
  assign cfg_sel_w                = 8'(SEL_W);
  assign cfg_exp_k_w              = 8'(COVAR_EXP_K_W);
  assign cfg_pow_pipe             = 8'(POW_PIPE);
  assign cfg_cmult_pipe           = 8'(CMULT_PIPE);
  assign cfg_narrow_acc_w         = 8'(NARROW_ACC_W);
  assign cfg_narrow_window_w      = 8'(NARROW_WINDOW_W);
  assign cfg_win_exact_max        = 32'(covar_window_max_exact(covar_uint_t'(ACC_W)));
  assign cfg_narrow_win_exact_max = 32'(covar_window_max_exact(covar_uint_t'(NARROW_ACC_W)));

endmodule : covar_top

`default_nettype wire
