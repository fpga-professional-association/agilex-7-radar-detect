// -----------------------------------------------------------------------------
// align_top — verification top for the SPEC.md 7.4 frequency-bin alignment
// network (issue #16).
//
// Simulation-only. Never synthesized, never listed in a Quartus source list. The
// Quartus view of this block is quartus/calibration/align_sw_wrap.sv and
// align_net_wrap.sv, which are different files for a different purpose.
//
// -----------------------------------------------------------------------------
// FOUR ELABORATIONS, TWO ARCHITECTURES, ONE PORT SET
// -----------------------------------------------------------------------------
// SPEC 7.4 requires two architectures to be compared, and a comparison is only
// worth having if both were held to the same standard. So both are built, at two
// widths each, behind ONE port set, and the C++ test runs its ENTIRE suite
// against each in turn:
//
//   sel  arch      BIN_PAR  MUX_STAGES  N_ANT  net stages  what it is for
//   ---  --------  -------  ----------  -----  ----------  -------------------
//    0   crossbar     4          1        2        2       the narrow pair,
//    1   omega        4          -        2        2       latency-matched
//    2   crossbar     8          2        4        3       the wide pair, and
//    3   omega        8          -        4        3       the widest beat that
//                                                          fits STREAM_MAX_DATA_W
//
// LATENCY MATCHING IS PART OF THE FIXTURE. `align_pkg::algn_xbar_latency(1)` is
// 2 and `algn_clos_latency(4)` is 2; `algn_xbar_latency(2)` is 3 and
// `algn_clos_latency(8)` is 3. The pairs are therefore comparable on throughput
// and on latency, not only on values — which is what lets the test assert that
// the two architectures produce the SAME beat sequence and report DIFFERENT
// blocking rates.
//
// The 8-bin, 4-antenna beat is 1024 bits, which is exactly
// `stream_pkg::STREAM_MAX_DATA_W`. That is deliberate: the widest beat the
// verified design can carry today is verified here, and the raise to 4096 that
// the full-scale 8-bin, 16-antenna beamformer beat will need is left to issue
// #20 with this block's measurements in hand. See DECISIONS.md.
//
// -----------------------------------------------------------------------------
// THE TOP PACKS AND UNPACKS; THE TEST DOES NOT
// -----------------------------------------------------------------------------
// The C++ test models BIN_PAR history read ports: it takes requests and returns
// responses, with whatever skew, loss or duplication the pass is testing. It
// supplies a response as FLAT FIELDS — antenna vector, bin, frame offset, frame
// id, flags — and this module builds the SPEC 5 payload with `stream_pack` and
// the metadata with `hist_meta_pack`.
//
// That is deliberate, and it is the same choice history_top made for the same
// reason: the packing is stream_pkg's and history_pkg's business, and a C++
// mirror of it in the test would be a second definition of the layout that could
// agree with itself while disagreeing with the design. What the test checks is
// VALUES; what this file checks, by construction, is that the values survive the
// canonical pack/unpack pair — including the one that matters most here, that
// the alignment network reads `bin` out of #15's metadata correctly.
//
// -----------------------------------------------------------------------------
// GEOMETRY ECHO
// -----------------------------------------------------------------------------
// `geo_*` reports the selected DUT's elaborated geometry and its two latencies.
// The C++ test compares them against its own `algn::Config` before any stimulus
// runs and aborts on a mismatch, so "the model was configured for a different
// DUT" fails in one line at time zero rather than as a thousand data mismatches.
//
// Lint contract: clean under `verilator --lint-only --Wall` with no waiver.
// -----------------------------------------------------------------------------

`default_nettype none

module align_top
  import align_pkg::*;
  import history_pkg::*;
  import stream_pkg::*;
(
    input  wire         clk,
    input  wire         rst_n,

    // Which DUT the stimulus reaches and which one is observed.
    input  wire [1:0]   dut_sel,

    // ---- configuration ----
    input  wire         cfg_enable,
    input  wire         cfg_run,
    input  wire [15:0]  cfg_frame_off,
    input  wire         cfg_partial_pass,
    input  wire         cfg_counter_clear,
    input  wire         cfg_sticky_clear,
    input  wire [7:0]   cfg_lane_stall,
    input  wire         cfg_force_unsafe,

    // ---- request masters, MAX_BP ports ----
    output wire [7:0]   rd_req_valid,
    input  wire [7:0]   rd_req_ready,
    output wire [127:0] rd_req_bin,        // port p at [p*16 +: 16]
    output wire [127:0] rd_req_frame_off,

    // ---- response slaves, MAX_BP ports, as flat fields ----
    input  wire [7:0]    rsp_valid,
    output wire [7:0]    rsp_ready,
    input  wire [1023:0] rsp_vec,          // port p at [p*128 +: 128]
    input  wire [127:0]  rsp_bin,          // port p at [p*16 +: 16]
    input  wire [127:0]  rsp_frame_off,
    input  wire [255:0]  rsp_frame_id,     // port p at [p*32 +: 32]
    input  wire [63:0]   rsp_flags,        // port p at [p*8  +: 8]

    // ---- the beamformer input beat, decoded ----
    output wire          m_valid,
    input  wire          m_ready,
    output wire [1023:0] m_data,           // (lane, antenna) per beamformer_pkg
    output wire          m_sof,
    output wire          m_eof,
    output wire [15:0]   m_seq,
    output wire [7:0]    m_user,
    // { sof, eof, 4'd0, stream_id[1:0] }. The frame flags are duplicated here
    // rather than trusted from m_sof/m_eof alone: this is the copy that comes
    // out of `stream_unpack`'s own view of the payload, so a packing mistake in
    // either field becomes visible as a disagreement between the two.
    output wire [7:0]    m_id,

    // ---- telemetry ----
    output wire [31:0]  stat_beat_count,
    output wire [31:0]  stat_issue_count,
    output wire [31:0]  stat_issue_stall_count,
    output wire [31:0]  stat_missing_count,
    output wire [31:0]  stat_dup_count,
    output wire [31:0]  stat_orphan_count,
    output wire [31:0]  stat_timeout_count,
    output wire [31:0]  stat_conflict_count,
    output wire [3:0]   stat_fault,

    // ---- delivery census (SPEC 7.4 throughput evidence) ----
    output wire [31:0]  stat_multi_lane_count,
    output wire [31:0]  stat_lane_word_count,
    output wire [7:0]   stat_lane_seen,
    output wire [31:0]  stat_inject_count,

    // ---- geometry echo for the selected DUT ----
    output wire [7:0]   geo_net_sel,
    output wire [7:0]   geo_bin_par,
    output wire [7:0]   geo_groups,
    output wire [7:0]   geo_n_ant,
    output wire [15:0]  geo_fft_size,
    output wire [15:0]  geo_frames_max,
    output wire [7:0]   geo_net_latency,
    output wire [7:0]   geo_block_latency,
    output wire [31:0]  geo_timeout,
    output wire [7:0]   geo_n_duts
);

  localparam int unsigned N_DUT    = 4;
  localparam int unsigned MAX_BP   = 8;
  localparam int unsigned MAX_ANT  = 4;
  localparam int unsigned SAMPLE_W = 16;
  localparam int unsigned WORD_W   = 2 * SAMPLE_W;
  localparam int unsigned MAX_VEC  = MAX_ANT * WORD_W;   // 128

  localparam int unsigned RD_ID_W   = 2;
  localparam int unsigned RD_SEQ_W  = 16;
  localparam int unsigned RD_USER_W = 4;
  localparam int unsigned OUT_ID_W  = 2;
  localparam int unsigned OUT_SEQ_W = 16;
  localparam int unsigned OUT_USER_W = 4;

  // The four elaborations, as parallel tables so the instantiation below is one
  // generate loop rather than four copies that can drift.
  localparam int unsigned SEL_OF [N_DUT] = '{0, 1, 0, 1};
  localparam int unsigned BP_OF  [N_DUT] = '{4, 4, 8, 8};
  localparam int unsigned MUX_OF [N_DUT] = '{1, 1, 2, 2};
  localparam int unsigned ANT_OF [N_DUT] = '{2, 2, 4, 4};
  localparam int unsigned FFT_OF [N_DUT] = '{64, 64, 64, 64};
  localparam int unsigned GRP_OF [N_DUT] = '{8, 8, 8, 8};
  localparam int unsigned FRM_OF [N_DUT] = '{4, 4, 4, 4};

  // Per-DUT observation buses, padded to the shared port widths.
  logic [7:0]    d_req_valid [N_DUT];
  logic [127:0]  d_req_bin   [N_DUT];
  logic [127:0]  d_req_foff  [N_DUT];
  logic [7:0]    d_rsp_ready [N_DUT];
  logic          d_m_valid   [N_DUT];
  logic [1023:0] d_m_data    [N_DUT];
  logic          d_m_sof     [N_DUT];
  logic          d_m_eof     [N_DUT];
  logic [15:0]   d_m_seq     [N_DUT];
  logic [7:0]    d_m_user    [N_DUT];
  logic [7:0]    d_m_id      [N_DUT];
  logic [31:0]   d_beat      [N_DUT];
  logic [31:0]   d_issue     [N_DUT];
  logic [31:0]   d_stall     [N_DUT];
  logic [31:0]   d_miss      [N_DUT];
  logic [31:0]   d_dup       [N_DUT];
  logic [31:0]   d_orph      [N_DUT];
  logic [31:0]   d_to        [N_DUT];
  logic [31:0]   d_conf      [N_DUT];
  logic [3:0]    d_fault     [N_DUT];
  logic [31:0]   d_multi     [N_DUT];
  logic [31:0]   d_lword     [N_DUT];
  logic [7:0]    d_lseen     [N_DUT];
  logic [31:0]   d_inject    [N_DUT];

  for (genvar k = 0; k < int'(N_DUT); k++) begin : g_dut
    localparam int unsigned NS = SEL_OF[k];
    localparam int unsigned BP = BP_OF[k];
    localparam int unsigned MX = MUX_OF[k];
    localparam int unsigned NA = ANT_OF[k];
    localparam int unsigned NF = FFT_OF[k];
    localparam int unsigned NG = GRP_OF[k];
    localparam int unsigned NM = FRM_OF[k];

    localparam hist_geom_t HGK = hist_geom(NA, NF, 1, NM, SAMPLE_W);
    localparam algn_geom_t AGK = algn_geom(NA, NF, 1, NM, SAMPLE_W, BP, NG);

    localparam int unsigned VEC_K  = int'(hist_vec_w(HGK));
    localparam int unsigned META_K = int'(hist_meta_w(HGK));
    localparam int unsigned DATA_K = int'(hist_data_w(HGK));
    localparam int unsigned OUT_K  = int'(algn_out_data_w(AGK));

    localparam stream_geom_t RGK =
        stream_geom(DATA_K, RD_ID_W, RD_SEQ_W, RD_USER_W);
    localparam stream_geom_t OGK =
        stream_geom(OUT_K, OUT_ID_W, OUT_SEQ_W, OUT_USER_W);

    localparam int unsigned RPW = int'(stream_payload_w(RGK));
    localparam int unsigned OPW = int'(stream_payload_w(OGK));

    wire sel = (dut_sel == 2'(k));

    // ---- response side: build one SPEC 5 payload per port ----
    logic [BP*RPW-1:0] s_payload;
    always_comb begin
      stream_fields_t    rf;
      hist_meta_fields_t mf;
      s_payload = '0;
      for (int unsigned p = 0; p < BP; p++) begin
        mf           = '0;
        mf.bin       = hist_idx_t'(rsp_bin[p*16 +: 16]);
        mf.frame_off = hist_idx_t'(rsp_frame_off[p*16 +: 16]);
        mf.frame_id  = rsp_frame_id[p*32 +: 32];
        mf.flags     = HIST_FLAGS_W'(rsp_flags[p*8 +: 8]);

        rf           = '0;
        rf.sof       = 1'b1;
        rf.eof       = 1'b1;
        rf.stream_id = STREAM_MAX_ID_W'(p);
        rf.seq       = '0;
        rf.user      = STREAM_MAX_USER_W'(mf.flags);
        rf.data[VEC_K-1:0]        = rsp_vec[p*MAX_VEC +: VEC_K];
        rf.data[VEC_K +: META_K]  = META_K'(hist_meta_pack(HGK, mf));

        s_payload[p*RPW +: RPW] = RPW'(stream_pack(RGK, rf));
      end
    end

    wire [BP-1:0]  k_req_valid, k_rsp_ready;
    wire [BP*HIST_PORT_W-1:0] k_req_bin, k_req_foff;
    wire           k_m_valid;
    wire [OPW-1:0] k_m_payload;
    wire [31:0]    k_beat, k_issue, k_stall, k_miss, k_dup, k_orph, k_to, k_conf;
    wire [31:0]    k_multi, k_lword, k_inj;
    wire [BP-1:0]  k_lseen;
    wire [3:0]     k_fault;
    wire [7:0]     k_sel_o, k_lat_o, k_blat_o, k_bp_o, k_grp_o;

    align_net #(
        .N_ANT          (NA),
        .FFT_SIZE       (NF),
        .LANES          (1),
        .FRAMES_MAX     (NM),
        .SAMPLE_W       (SAMPLE_W),
        .BIN_PAR        (BP),
        .GROUPS         (NG),
        .NET_SEL        (NS),
        .MUX_STAGES     (MX),
        .RD_ID_W        (RD_ID_W),
        .RD_SEQ_W       (RD_SEQ_W),
        .RD_USER_W      (RD_USER_W),
        .STREAM_ID_W    (OUT_ID_W),
        .SEQ_W          (OUT_SEQ_W),
        .USER_W         (OUT_USER_W),
        .OUT_DEPTH      (4),
        .TELEM_W        (32)
    ) u_dut (
        .clk                    (clk),
        .rst_n                  (rst_n),
        .cfg_enable             (cfg_enable && sel),
        .cfg_run                (cfg_run),
        .cfg_frame_off          (cfg_frame_off),
        .cfg_partial_pass       (cfg_partial_pass),
        .cfg_counter_clear      (cfg_counter_clear && sel),
        .cfg_sticky_clear       (cfg_sticky_clear && sel),
        .cfg_lane_stall         (cfg_lane_stall[BP-1:0]),
        .cfg_force_unsafe       (cfg_force_unsafe && sel),
        .rd_req_valid           (k_req_valid),
        .rd_req_ready           (rd_req_ready[BP-1:0]),
        .rd_req_bin             (k_req_bin),
        .rd_req_frame_off       (k_req_foff),
        .rsp_valid              (rsp_valid[BP-1:0] & {BP{sel}}),
        .rsp_ready              (k_rsp_ready),
        .rsp_payload            (s_payload),
        .m_valid                (k_m_valid),
        .m_ready                (m_ready && sel),
        .m_payload              (k_m_payload),
        .stat_beat_count        (k_beat),
        .stat_issue_count       (k_issue),
        .stat_issue_stall_count (k_stall),
        .stat_missing_count     (k_miss),
        .stat_dup_count         (k_dup),
        .stat_orphan_count      (k_orph),
        .stat_timeout_count     (k_to),
        .stat_conflict_count    (k_conf),
        .stat_multi_lane_count  (k_multi),
        .stat_lane_word_count   (k_lword),
        .stat_lane_seen         (k_lseen),
        .stat_inject_count      (k_inj),
        .stat_fault             (k_fault),
        .obs_net_sel            (k_sel_o),
        .obs_net_latency        (k_lat_o),
        .obs_block_latency      (k_blat_o),
        .obs_bin_par            (k_bp_o),
        .obs_groups             (k_grp_o)
    );

    // ---- output decode ----
    stream_fields_t of;
    assign of = stream_unpack(OGK, stream_payload_t'(k_m_payload));

    always_comb begin
      d_req_valid[k] = '0;
      d_req_bin[k]   = '0;
      d_req_foff[k]  = '0;
      d_rsp_ready[k] = '0;
      d_m_data[k]    = '0;
      d_req_valid[k][BP-1:0] = k_req_valid;
      d_rsp_ready[k][BP-1:0] = k_rsp_ready;
      for (int unsigned p = 0; p < BP; p++) begin
        d_req_bin[k][p*16 +: 16]  = k_req_bin[p*HIST_PORT_W +: 16];
        d_req_foff[k][p*16 +: 16] = k_req_foff[p*HIST_PORT_W +: 16];
      end
      d_m_data[k][OUT_K-1:0] = of.data[OUT_K-1:0];
      d_m_valid[k]   = k_m_valid;
      d_m_sof[k]     = of.sof;
      d_m_eof[k]     = of.eof;
      d_m_seq[k]     = 16'(of.seq[OUT_SEQ_W-1:0]);
      d_m_user[k]    = 8'(of.user[OUT_USER_W-1:0]);
      d_m_id[k]      = {of.sof, of.eof, 4'd0, of.stream_id[OUT_ID_W-1:0]};
      d_beat[k]      = k_beat;
      d_issue[k]     = k_issue;
      d_stall[k]     = k_stall;
      d_miss[k]      = k_miss;
      d_dup[k]       = k_dup;
      d_orph[k]      = k_orph;
      d_to[k]        = k_to;
      d_conf[k]      = k_conf;
      d_fault[k]     = k_fault;
      d_multi[k]     = k_multi;
      d_lword[k]     = k_lword;
      d_lseen[k]     = MAX_BP'(k_lseen);
      d_inject[k]    = k_inj;
    end

    // The DUT's own geometry echo must agree with this file's table, or the
    // C++ model would be configured from one and compared against the other.
    // Checked rather than trusted, at time 0, in one line.
    wire [7:0] echo_xor = k_sel_o  ^ 8'(NS) | k_bp_o   ^ 8'(BP) |
                          k_grp_o  ^ 8'(NG) |
                          k_lat_o  ^ 8'(algn_net_latency(algn_uint_t'(NS),
                                                         algn_uint_t'(BP),
                                                         algn_uint_t'(MX))) |
                          k_blat_o ^ 8'(algn_block_latency(algn_uint_t'(NS),
                                                           algn_uint_t'(BP),
                                                           algn_uint_t'(MX)));
`ifndef SYNTHESIS
    always_ff @(posedge clk) begin
      if (rst_n) begin
        a_align_geometry_echo : assert (echo_xor == 8'd0)
          else $error("align_top: DUT %0d's geometry echo disagrees with the table", k);
      end
    end
`endif
  end : g_dut

  // ---------------------------------------------------------------------------
  // Observation mux
  // ---------------------------------------------------------------------------
  // Every value of the two-bit selector names a real DUT (N_DUT is 4), so there
  // is no out-of-range case to clamp — and writing one would be a comparison
  // that is constant by construction, which `--Wall` correctly objects to.
  wire [1:0] sel_i = dut_sel;

  assign rd_req_valid           = d_req_valid[sel_i];
  assign rd_req_bin             = d_req_bin[sel_i];
  assign rd_req_frame_off       = d_req_foff[sel_i];
  assign rsp_ready              = d_rsp_ready[sel_i];
  assign m_valid                = d_m_valid[sel_i];
  assign m_data                 = d_m_data[sel_i];
  assign m_sof                  = d_m_sof[sel_i];
  assign m_eof                  = d_m_eof[sel_i];
  assign m_seq                  = d_m_seq[sel_i];
  assign m_user                 = d_m_user[sel_i];
  assign m_id                   = d_m_id[sel_i];
  assign stat_beat_count        = d_beat[sel_i];
  assign stat_issue_count       = d_issue[sel_i];
  assign stat_issue_stall_count = d_stall[sel_i];
  assign stat_missing_count     = d_miss[sel_i];
  assign stat_dup_count         = d_dup[sel_i];
  assign stat_orphan_count      = d_orph[sel_i];
  assign stat_timeout_count     = d_to[sel_i];
  assign stat_conflict_count    = d_conf[sel_i];
  assign stat_fault             = d_fault[sel_i];
  assign stat_multi_lane_count  = d_multi[sel_i];
  assign stat_lane_word_count   = d_lword[sel_i];
  assign stat_lane_seen         = d_lseen[sel_i];
  assign stat_inject_count      = d_inject[sel_i];

  assign geo_net_sel   = 8'(SEL_OF[sel_i]);
  assign geo_bin_par   = 8'(BP_OF[sel_i]);
  assign geo_groups    = 8'(GRP_OF[sel_i]);
  assign geo_n_ant     = 8'(ANT_OF[sel_i]);
  assign geo_fft_size  = 16'(FFT_OF[sel_i]);
  assign geo_frames_max= 16'(FRM_OF[sel_i]);
  assign geo_net_latency =
      8'(algn_net_latency(algn_uint_t'(SEL_OF[sel_i]),
                          algn_uint_t'(BP_OF[sel_i]),
                          algn_uint_t'(MUX_OF[sel_i])));
  assign geo_block_latency =
      8'(algn_block_latency(algn_uint_t'(SEL_OF[sel_i]),
                            algn_uint_t'(BP_OF[sel_i]),
                            algn_uint_t'(MUX_OF[sel_i])));
  assign geo_timeout =
      32'(algn_default_timeout(algn_geom(ANT_OF[sel_i], FFT_OF[sel_i], 1,
                                         FRM_OF[sel_i], SAMPLE_W,
                                         BP_OF[sel_i], GRP_OF[sel_i]),
                               algn_uint_t'(SEL_OF[sel_i]),
                               algn_uint_t'(MUX_OF[sel_i])));
  assign geo_n_duts = 8'(N_DUT);

endmodule : align_top

`default_nettype wire
