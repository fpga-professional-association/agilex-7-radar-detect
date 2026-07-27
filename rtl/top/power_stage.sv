// -----------------------------------------------------------------------------
// power_stage — SPEC.md 7.6 power per beam, integrated, and re-framed as the
// CFAR detector's input stream (issue #17).
//
// What it is
// ----------
// The seam between the beamforming matrix and the detector. One beat in is one
// frequency bin's complete beam vector (rtl/top/bin_serializer.sv); one beat out
// is that bin's `N_BEAMS` power values, `POWER_W` each, on a SPEC 5 stream with
// the framing preserved exactly.
//
//     s_payload.data = { Y[N_BEAMS-1] , ... , Y[0] }        complex Q1.15
//                   |
//                   +--> power_calc x N_BEAMS  ---> m_payload.data =
//                   |      P[b] = I^2 + Q^2            { P[N_BEAMS-1] .. P[0] }
//                   |
//                   +--> integrator x N_BEAMS  ---> per-beam window results
//                          programmable window, block sum or exponential
//
// Two consumers of the same arithmetic, and they are different consumers on
// purpose:
//
//   * the CFAR detector wants the PER-BIN power, unintegrated, because its
//     reference window integrates across bins itself and integrating first
//     would apply the window twice;
//   * the register plane wants the INTEGRATED power per beam — SPEC 7.6's
//     "programmable integration window" over the time axis — which is a summary
//     of a frame rather than of a bin.
//
// Sharing one `power_calc` per beam between them is not an optimisation, it is
// the correctness argument: a second squarer would be a second implementation of
// `I^2 + Q^2` that could disagree with the first, and the detector's threshold
// and the reported power would then describe different signals.
//
// Flow control: a credit, because power_calc has no ready
// -------------------------------------------------------
// `power_calc` is a fixed-latency valid pipeline with no `ready` at all and no
// clock enable — deliberately, so that its two 16x16 squares and their sum map
// to one DSP block (ARCHITECTURE.md §3.5). A `ready` reaching into it would put
// the consumer's stall on a DSP register's enable, which is exactly the
// construction SPEC 23 warns about.
//
// So the stall is absorbed downstream and the input is admitted against a
// CREDIT: `s_ready` is a flip-flop whose input depends only on this block's own
// occupancy counter, and a beat is admitted only when the output buffer has a
// slot reserved for it. Nothing downstream reaches `s_ready` combinationally.
// The buffer is `PIPE_STAGES + 2` deep so that everything already in the
// squarer's pipeline still fits after the last admission — the same sizing rule,
// for the same reason, as `pfb_bank`'s and `beamformer`'s output boundaries.
//
// The integrators are fed from the squarer's output valid and NOT from the
// output buffer's pop, so integration counts the bins that were computed rather
// than the bins the detector happened to have drained. Those are the same bins
// in the same order; the distinction matters only at a reset boundary, where
// counting the computation is the honest choice.
//
// Numerics
// --------
// None of its own. `power_calc` owns `I^2 + Q^2` and its exactness proof;
// `integrator` owns the accumulator protection and the window metadata; this
// module owns the wiring, the framing and the credit. There is no arithmetic in
// this file, which is why there is no rounding rule in it either.
//
// Lint contract: clean under `verilator --lint-only --Wall` with no waiver.
// -----------------------------------------------------------------------------

`default_nettype none

module power_stage
  import fxp_pkg::*;
  import stream_pkg::*;
  import covar_pkg::*;
#(
    parameter int unsigned N_BEAMS = 4,

    // power_calc register stages; legal [1,3], 2 is the shape that fits one DSP.
    parameter int unsigned PIPE_STAGES = 2,

    parameter int unsigned STREAM_ID_W = 4,
    parameter int unsigned SEQ_W       = 16,
    parameter int unsigned USER_W      = 4,

    parameter int unsigned ACC_W       = COVAR_POWER_W,
    parameter int unsigned WINDOW_W    = COVAR_WINDOW_LEN_W,
    parameter int unsigned SAT_COUNT_W = 32,

    // Output elastic depth. Must cover the squarer's pipeline plus two.
    parameter int unsigned OUT_DEPTH = PIPE_STAGES + 2,

    // DERIVED, never overridden.
    parameter int unsigned S_PAYLOAD_W =
        N_BEAMS * 2 * fxp_pkg::FXP_SAMPLE_W + 2 + STREAM_ID_W + SEQ_W + USER_W,
    parameter int unsigned M_PAYLOAD_W =
        N_BEAMS * COVAR_POWER_W + 2 + STREAM_ID_W + SEQ_W + USER_W
) (
    input  wire                     clk,
    input  wire                     rst_n,

    input  wire                     s_valid,
    output wire                     s_ready,
    input  wire [S_PAYLOAD_W-1:0]   s_payload,

    output wire                     m_valid,
    input  wire                     m_ready,
    output wire [M_PAYLOAD_W-1:0]   m_payload,

    // ---- integration configuration (rtl/control/reg_block_covar.sv) ----
    input  wire [WINDOW_W-1:0]      cfg_window_len,
    input  wire                     cfg_mode,        // covar_mode_e
    input  wire [COVAR_EXP_K_W-1:0] cfg_exp_k,
    input  wire [N_BEAMS-1:0]       cfg_beam_enable,
    input  wire                     flush,
    input  wire                     sat_clear,

    // ---- per-beam window results ----
    output wire [N_BEAMS-1:0]                   pwr_valid,
    output wire [N_BEAMS*ACC_W-1:0]             pwr_acc,
    output wire [COVAR_WINDOW_ID_W-1:0]         pwr_window_id,
    output wire [N_BEAMS-1:0]                   pwr_flushed,
    output wire [N_BEAMS-1:0]                   pwr_truncated,
    output wire                                 pwr_sat_any,
    output wire [SAT_COUNT_W-1:0]               pwr_sat_count,

    // ---- observation ----
    output wire [7:0]                           obs_latency
);

  localparam int unsigned PAIR_W   = 2 * FXP_SAMPLE_W;
  localparam int unsigned S_DATA_W = N_BEAMS * PAIR_W;
  localparam int unsigned M_DATA_W = N_BEAMS * COVAR_POWER_W;
  localparam int unsigned META_W   = 2 + STREAM_ID_W + SEQ_W + USER_W;
  localparam int unsigned CRED_W   = $clog2(OUT_DEPTH + 1);

  localparam stream_geom_t S_GEOM =
      stream_geom(stream_pkg::uint_t'(S_DATA_W), stream_pkg::uint_t'(STREAM_ID_W),
                  stream_pkg::uint_t'(SEQ_W), stream_pkg::uint_t'(USER_W));
  localparam stream_geom_t M_GEOM =
      stream_geom(stream_pkg::uint_t'(M_DATA_W), stream_pkg::uint_t'(STREAM_ID_W),
                  stream_pkg::uint_t'(SEQ_W), stream_pkg::uint_t'(USER_W));

`ifndef SYNTHESIS
  initial begin
    if (PIPE_STAGES < 1 || PIPE_STAGES > 3) begin
      $fatal(1, "power_stage: PIPE_STAGES=%0d is outside power_calc's legal [1,3]", PIPE_STAGES);
    end
    if (OUT_DEPTH < PIPE_STAGES + 2) begin
      $fatal(1, "power_stage: OUT_DEPTH=%0d cannot hold the %0d beats the squarer has in flight plus two",
             OUT_DEPTH, PIPE_STAGES);
    end
    if (int'(S_PAYLOAD_W) != int'(stream_payload_w(S_GEOM))) begin
      $fatal(1, "power_stage: S_PAYLOAD_W=%0d but stream_pkg says %0d",
             S_PAYLOAD_W, int'(stream_payload_w(S_GEOM)));
    end
    if (int'(M_PAYLOAD_W) != int'(stream_payload_w(M_GEOM))) begin
      $fatal(1, "power_stage: M_PAYLOAD_W=%0d but stream_pkg says %0d",
             M_PAYLOAD_W, int'(stream_payload_w(M_GEOM)));
    end
  end
`endif

  // ---------------------------------------------------------------------------
  // Admission and credit
  // ---------------------------------------------------------------------------
  logic [CRED_W-1:0] cred_q;
  logic              rdy_q;

  wire eb_ready;
  wire eb_valid;
  wire push;
  wire pop;

  wire admit = s_valid && rdy_q;

  always_ff @(posedge clk) begin
    if (!rst_n) begin
      cred_q <= CRED_W'(OUT_DEPTH);
      rdy_q  <= 1'b0;
    end else begin
      cred_q <= cred_q - CRED_W'(admit) + CRED_W'(pop);
      rdy_q  <= (cred_q - CRED_W'(admit) + CRED_W'(pop)) != CRED_W'(0);
    end
  end

  assign s_ready = rdy_q;

  stream_fields_t in_f;
  assign in_f = stream_unpack(S_GEOM, STREAM_MAX_PAYLOAD_W'(s_payload));

  // ---------------------------------------------------------------------------
  // The squarers and the metadata pipeline
  //
  // The metadata rides the SAME `power_calc` the samples do, through its `tag`
  // port, rather than a parallel shift register: a tag that travels with the
  // data cannot drift from it however PIPE_STAGES changes, and a parallel delay
  // line sized from the same parameter is a second place to get the number
  // wrong. Beam 0 carries the tag; the others tie it off.
  // ---------------------------------------------------------------------------
  wire [META_W-1:0] tag_in = {in_f.sof, in_f.eof,
                              in_f.stream_id[STREAM_ID_W-1:0],
                              in_f.seq[SEQ_W-1:0],
                              in_f.user[USER_W-1:0]};

  wire [N_BEAMS-1:0]              p_valid;
  wire signed [COVAR_POWER_W-1:0] p_power [N_BEAMS];
  wire [META_W-1:0]               tag_out;

  // Per-beam saturation state, collected below. Declared here because a
  // generate block may only drive a net declared before it.
  logic [N_BEAMS-1:0]     beam_sat;
  logic [SAT_COUNT_W-1:0] beam_satc [N_BEAMS];

  for (genvar b = 0; b < int'(N_BEAMS); b++) begin : g_beam
    wire [META_W-1:0] tag_b;

    power_calc #(
        .PIPE_STAGES (PIPE_STAGES),
        .TAG_W       (META_W)
    ) u_pow (
        .clk       (clk),
        .rst_n     (rst_n),
        .valid_in  (admit),
        .sample    (fxp_complex_t'(in_f.data[b*PAIR_W +: PAIR_W])),
        .tag_in    (tag_in),
        .valid_out (p_valid[b]),
        .power     (p_power[b]),
        .tag_out   (tag_b)
    );

    if (b == 0) begin : g_tag
      assign tag_out = tag_b;
    end else begin : g_no_tag
      // Every beam's tag is the same value delayed by the same pipeline; only
      // one copy is read. Named so `--Wall` reports a genuinely dead signal and
      // not this deliberate redundancy.
      wire [META_W-1:0] unused_tag = tag_b;
    end

    // ---- SPEC 7.6 time integration of this beam's power ----
    wire [WINDOW_W-1:0]          unused_sc;
    wire signed [ACC_W-1:0]      unused_obs_acc;
    wire [WINDOW_W-1:0]          unused_obs_cnt, unused_obs_wl;
    wire                         unused_obs_mode, unused_obs_en;
    wire [COVAR_EXP_K_W-1:0]     unused_obs_k;
    fxp_flags_t                  unused_satf;
    wire [COVAR_WINDOW_ID_W-1:0] wid_b;
    wire                         sat_b;
    wire [SAT_COUNT_W-1:0]       satc_b;

    integrator #(
        .DATA_W      (COVAR_POWER_W),
        .ACC_W       (ACC_W),
        .WINDOW_W    (WINDOW_W),
        .SAT_COUNT_W (SAT_COUNT_W)
    ) u_int (
        .clk            (clk),
        .rst_n          (rst_n),
        .cfg_window_len (cfg_window_len),
        .cfg_mode       (cfg_mode),
        .cfg_exp_k      (cfg_exp_k),
        .cfg_enable     (cfg_beam_enable[b]),
        .flush          (flush),
        .sat_clear      (sat_clear),
        .valid_in       (p_valid[b]),
        .data_in        (p_power[b]),
        .valid_out      (pwr_valid[b]),
        .acc_out        (pwr_acc[b*ACC_W +: ACC_W]),
        .window_id      (wid_b),
        .sample_count   (unused_sc),
        .flushed        (pwr_flushed[b]),
        .truncated      (pwr_truncated[b]),
        .sat_flags      (unused_satf),
        .sat_sticky     (sat_b),
        .sat_count      (satc_b),
        .obs_acc        (unused_obs_acc),
        .obs_count      (unused_obs_cnt),
        .obs_window_len (unused_obs_wl),
        .obs_mode       (unused_obs_mode),
        .obs_exp_k      (unused_obs_k),
        .obs_enable     (unused_obs_en)
    );

    assign beam_sat[b]  = sat_b;
    assign beam_satc[b] = satc_b;

    // Every beam's window closes on the same cycle — they share one
    // configuration and one valid — so one window id describes all of them.
    // Reporting beam 0's rather than a vector keeps the register-plane word one
    // field wide, which is what reg_block_covar declares. The other beams' ids
    // are the same number and are deliberately not read.
    if (b == 0) begin : g_wid
      assign pwr_window_id = wid_b;
    end else begin : g_no_wid
      wire [COVAR_WINDOW_ID_W-1:0] unused_wid = wid_b;
    end
  end

  assign pwr_sat_any = |beam_sat;

  // The reported count is the WORST beam's, not their sum: the register-plane
  // field is "how bad did it get", and summing would make a build with more
  // beams look worse than the same signal in a build with fewer.
  logic [SAT_COUNT_W-1:0] pwr_sat_count_c;

  always_comb begin
    pwr_sat_count_c = '0;
    for (int unsigned b = 0; b < N_BEAMS; b++) begin
      if (beam_satc[b] > pwr_sat_count_c) pwr_sat_count_c = beam_satc[b];
    end
  end

  assign pwr_sat_count = pwr_sat_count_c;

  // ---------------------------------------------------------------------------
  // The output beat
  // ---------------------------------------------------------------------------
  logic [M_DATA_W-1:0] out_data;
  always_comb begin
    out_data = '0;
    for (int unsigned b = 0; b < N_BEAMS; b++) begin
      out_data[b*COVAR_POWER_W +: COVAR_POWER_W] = p_power[b];
    end
  end

  wire [M_PAYLOAD_W-1:0] push_payload = M_PAYLOAD_W'(stream_pack(M_GEOM, '{
      data      : {{(STREAM_MAX_DATA_W - M_DATA_W){1'b0}}, out_data},
      sof       : tag_out[META_W-1],
      eof       : tag_out[META_W-2],
      stream_id : STREAM_MAX_ID_W'(tag_out[SEQ_W+USER_W +: STREAM_ID_W]),
      seq       : STREAM_MAX_SEQ_W'(tag_out[USER_W +: SEQ_W]),
      user      : STREAM_MAX_USER_W'(tag_out[0 +: USER_W])
  }));

  assign push = p_valid[0];
  assign pop  = eb_valid && m_ready;

  wire [$clog2(OUT_DEPTH+1)-1:0] unused_occ;

  stream_elastic_buffer #(
      .PAYLOAD_W   (M_PAYLOAD_W),
      .DEPTH       (OUT_DEPTH),
      .RAM_STYLE   ("regs"),
      .DATA_W      (M_DATA_W),
      .STREAM_ID_W (STREAM_ID_W),
      .SEQ_W       (SEQ_W),
      .USER_W      (USER_W)
  ) u_out (
      .clk       (clk),
      .rst_n     (rst_n),
      .s_valid   (push),
      .s_ready   (eb_ready),
      .s_payload (push_payload),
      .m_valid   (eb_valid),
      .m_ready   (m_ready),
      .m_payload (m_payload),
      .occupancy (unused_occ)
  );

  assign m_valid = eb_valid;

  assign obs_latency = 8'(PIPE_STAGES + 1);

`ifndef SYNTHESIS
  // The credit argument, as a property rather than as a comment: a push must
  // never find the buffer full, because the credit reserved its slot at
  // admission. If this fires the credit accounting is wrong, which is silent
  // otherwise — the buffer would simply drop the beat.
  a_pwr_credit_holds:
    assert property (@(posedge clk) disable iff (!rst_n) push |-> eb_ready)
      else $error("power_stage: pushed into a full output buffer - credit accounting is wrong");

  // Every beam's squarer is fed by one `admit` and has one latency, so their
  // valids are one signal replicated. A build in which they diverge has a
  // pipeline that is not what this module thinks it is.
  a_pwr_valids_agree:
    assert property (@(posedge clk) disable iff (!rst_n)
                     (p_valid == '0) || (p_valid == {N_BEAMS{1'b1}}))
      else $error("power_stage: per-beam squarer valids diverged");
`endif

endmodule : power_stage

`default_nettype wire
