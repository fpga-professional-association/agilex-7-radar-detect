// -----------------------------------------------------------------------------
// align_net_wrap — SPEC.md 18 / SPEC.md 7.4 calibration wrapper: THE WHOLE
// alignment network (issue #16).
//
// Registered pins in, one `align_net` — scheduler, ingress decode, routing
// fabric, reassembly buffer, detector and counters — registered pins out. The
// instance is named `u_kernel` for the reason every other wrapper in this
// directory names its instance that: quartus/scripts/calibrate.tcl matches
// `*u_kernel*` to pull the per-entity resource row and to decide whether the
// worst register-to-register path is inside the kernel or in the harness.
//
// -----------------------------------------------------------------------------
// WHAT THIS ANSWERS THAT align_sw_wrap DOES NOT
// -----------------------------------------------------------------------------
// align_sw_wrap isolates the SPEC 7.4 architecture difference. This one prices
// THE BLOCK'S FIXED COST — the part that is identical in both builds and that
// the pull request's resource projection needs as a number rather than as a
// difference:
//
//   * the reassembly buffer, which is GROUPS x BIN_PAR x VEC_W flip-flops and is
//     the largest single thing in the block. Whether Quartus leaves it in ALM
//     registers or packs the columns into MLABs is a real question with a real
//     answer, and it is the answer that decides whether GROUPS can grow;
//   * the detector: BIN_PAR identity comparators against a GROUPS-entry table,
//     plus the present-bit and timeout bookkeeping;
//   * the scheduler's rotating bin arithmetic and its BIN_PAR request holds;
//   * the five saturating counters and the sticky fault word.
//
// Two points, one per architecture, so the fixed cost is measured in both
// contexts rather than assumed to be context-free — the same discipline
// history_core's two points use, and for the same reason: the Fitter is allowed
// to place shared logic differently around different neighbours.
//
// -----------------------------------------------------------------------------
// THE GEOMETRY IS 8 BINS x 4 ANTENNAS, AND THE REASON IS A BOUND
// -----------------------------------------------------------------------------
// The output beat is BIN_PAR * N_ANT * 32 bits and must fit
// `stream_pkg::STREAM_MAX_DATA_W`, which is 1024 since issue #12. 8 x 4 x 32 is
// exactly 1024: the widest beamformer beat the verified design can carry today,
// and the same geometry `align_top` verifies (DUTs 2 and 3), so this record
// describes a block that the test suite actually exercises.
//
// The full-scale 8 x 16 beat is 4096 bits and needs that bound raised. THAT IS
// DELIBERATELY NOT DONE HERE. Raising it multiplies the working type of every
// `stream_pack`/`stream_unpack` in the design by four, for a geometry nothing
// yet verifies, and issue #12 recorded the same reasoning when it raised 256 to
// 1024 and stopped. What this issue owes #20 instead is the routing fabric
// measured AT the full-scale width — which align_sw_wrap does, because the
// fabric carries no SPEC 5 payload — plus this block-level fixed cost, from
// which the full-scale figure is arithmetic rather than another compile.
//
// SPEC 24: nothing is tied off to make the block optimise away. The status
// outputs are folded into one registered word rather than dropped, so every
// counter still participates; the input stream and the request ports are genuine
// ports.
//
// Listed in sim/verilator/files_align.f so `make lint` covers it.
// -----------------------------------------------------------------------------

`default_nettype none

module align_net_wrap
  import align_pkg::*;
  import history_pkg::*;
  import stream_pkg::*;
#(
    parameter int unsigned N_ANT      = 4,
    parameter int unsigned FFT_SIZE   = 1024,
    parameter int unsigned LANES      = 8,
    parameter int unsigned FRAMES_MAX = 512,
    parameter int unsigned SAMPLE_W   = 16,
    parameter int unsigned BIN_PAR    = 8,
    parameter int unsigned GROUPS     = 4,

    parameter int unsigned NET_SEL    = 0,
    parameter int unsigned MUX_STAGES = 2,

    parameter int unsigned RD_ID_W     = 2,
    parameter int unsigned RD_SEQ_W    = 16,
    parameter int unsigned RD_USER_W   = 4,
    parameter int unsigned STREAM_ID_W = 2,
    parameter int unsigned SEQ_W       = 16,
    parameter int unsigned USER_W      = 4,

    // DERIVED; never overridden.
    parameter int unsigned RSP_PAYLOAD_W =
        int'(stream_payload_w(stream_geom(
            hist_data_w(hist_geom(N_ANT, FFT_SIZE, LANES, FRAMES_MAX, SAMPLE_W)),
            RD_ID_W, RD_SEQ_W, RD_USER_W))),
    parameter int unsigned M_PAYLOAD_W =
        int'(stream_payload_w(stream_geom(
            algn_out_data_w(algn_geom(N_ANT, FFT_SIZE, LANES, FRAMES_MAX,
                                      SAMPLE_W, BIN_PAR, GROUPS)),
            STREAM_ID_W, SEQ_W, USER_W)))
) (
    input  wire                             clk,
    input  wire                             rst_n,

    input  wire                             cfg_enable,
    input  wire                             cfg_run,
    input  wire [HIST_PORT_W-1:0]           cfg_frame_off,
    input  wire                             cfg_partial_pass,
    input  wire                             cfg_counter_clear,
    input  wire                             cfg_sticky_clear,
    input  wire [BIN_PAR-1:0]               cfg_lane_stall,
    input  wire                             cfg_force_unsafe,

    output wire [BIN_PAR-1:0]               rd_req_valid,
    input  wire [BIN_PAR-1:0]               rd_req_ready,
    output wire [BIN_PAR*HIST_PORT_W-1:0]   rd_req_bin,
    output wire [BIN_PAR*HIST_PORT_W-1:0]   rd_req_frame_off,

    input  wire [BIN_PAR-1:0]               rsp_valid,
    output wire [BIN_PAR-1:0]               rsp_ready,
    input  wire [BIN_PAR*RSP_PAYLOAD_W-1:0] rsp_payload,

    output wire                             m_valid,
    input  wire                             m_ready,
    output wire [M_PAYLOAD_W-1:0]           m_payload,

    // Every status word folded into one 64-bit output. Folded rather than
    // dropped: SPEC 24 forbids letting logic optimise away, and two hundred pins
    // of counters would dwarf the block being measured. All of them still
    // participate, so none of them optimises away. Same device, same reason, as
    // history_core_wrap.
    output wire [63:0]                      stat_fold
);

  // ---------------------------------------------------------------------------
  // Boundary input registers
  // ---------------------------------------------------------------------------
  logic                               en_q, rn_q, pp_q, cc_q, sc_q, fu_q;
  logic [HIST_PORT_W-1:0]             fo_q;
  logic [BIN_PAR-1:0]                 ls_q, rr_q, rv_q;
  logic                               mr_q;
  logic [BIN_PAR*RSP_PAYLOAD_W-1:0]   rp_q;

  always_ff @(posedge clk) begin
    if (!rst_n) begin
      en_q <= 1'b0;
      rn_q <= 1'b0;
      cc_q <= 1'b0;
      sc_q <= 1'b0;
      fu_q <= 1'b0;
      rr_q <= '0;
      rv_q <= '0;
      mr_q <= 1'b0;
    end else begin
      en_q <= cfg_enable;
      rn_q <= cfg_run;
      cc_q <= cfg_counter_clear;
      sc_q <= cfg_sticky_clear;
      fu_q <= cfg_force_unsafe;
      rr_q <= rd_req_ready;
      rv_q <= rsp_valid;
      mr_q <= m_ready;
    end
  end

  always_ff @(posedge clk) begin
    pp_q <= cfg_partial_pass;
    fo_q <= cfg_frame_off;
    ls_q <= cfg_lane_stall;
    rp_q <= rsp_payload;
  end

  // ---------------------------------------------------------------------------
  // The kernel under calibration
  // ---------------------------------------------------------------------------
  wire [BIN_PAR-1:0]              k_req_valid, k_rsp_ready;
  wire [BIN_PAR*HIST_PORT_W-1:0]  k_req_bin, k_req_foff;
  wire                            k_m_valid;
  wire [M_PAYLOAD_W-1:0]          k_m_payload;
  wire [31:0]                     k_beat, k_issue, k_stall, k_miss, k_dup,
                                  k_orph, k_to, k_conf, k_multi, k_lword, k_inj;
  wire [BIN_PAR-1:0]              k_lseen;
  wire [ALGN_FAULT_W-1:0]         k_fault;
  wire [7:0]                      k_sel, k_lat, k_blat, k_bp, k_grp;

  align_net #(
      .N_ANT       (N_ANT),
      .FFT_SIZE    (FFT_SIZE),
      .LANES       (LANES),
      .FRAMES_MAX  (FRAMES_MAX),
      .SAMPLE_W    (SAMPLE_W),
      .BIN_PAR     (BIN_PAR),
      .GROUPS      (GROUPS),
      .NET_SEL     (NET_SEL),
      .MUX_STAGES  (MUX_STAGES),
      .RD_ID_W     (RD_ID_W),
      .RD_SEQ_W    (RD_SEQ_W),
      .RD_USER_W   (RD_USER_W),
      .STREAM_ID_W (STREAM_ID_W),
      .SEQ_W       (SEQ_W),
      .USER_W      (USER_W),
      .OUT_DEPTH   (4),
      .TELEM_W     (32)
  ) u_kernel (
      .clk                    (clk),
      .rst_n                  (rst_n),
      .cfg_enable             (en_q),
      .cfg_run                (rn_q),
      .cfg_frame_off          (fo_q),
      .cfg_partial_pass       (pp_q),
      .cfg_counter_clear      (cc_q),
      .cfg_sticky_clear       (sc_q),
      .cfg_lane_stall         (ls_q),
      .cfg_force_unsafe       (fu_q),
      .rd_req_valid           (k_req_valid),
      .rd_req_ready           (rr_q),
      .rd_req_bin             (k_req_bin),
      .rd_req_frame_off       (k_req_foff),
      .rsp_valid              (rv_q),
      .rsp_ready              (k_rsp_ready),
      .rsp_payload            (rp_q),
      .m_valid                (k_m_valid),
      .m_ready                (mr_q),
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
      .obs_net_sel            (k_sel),
      .obs_net_latency        (k_lat),
      .obs_block_latency      (k_blat),
      .obs_bin_par            (k_bp),
      .obs_groups             (k_grp)
  );

  // ---------------------------------------------------------------------------
  // Boundary output registers
  // ---------------------------------------------------------------------------
  logic [BIN_PAR-1:0]             qv_q, qr_q;
  logic [BIN_PAR*HIST_PORT_W-1:0] qb_q, qf_q;
  logic                           mv_q;
  logic [M_PAYLOAD_W-1:0]         mp_q;
  logic [63:0]                    sf_q;

  always_ff @(posedge clk) begin
    if (!rst_n) begin
      qv_q <= '0;
      qr_q <= '0;
      mv_q <= 1'b0;
    end else begin
      qv_q <= k_req_valid;
      qr_q <= k_rsp_ready;
      mv_q <= k_m_valid;
    end
  end

  always_ff @(posedge clk) begin
    qb_q <= k_req_bin;
    qf_q <= k_req_foff;
    mp_q <= k_m_payload;
    sf_q <= {32'd0, k_beat ^ k_issue ^ k_stall ^ k_miss ^ k_dup ^ k_orph ^
                    k_to ^ k_conf ^ k_multi ^ k_lword ^ k_inj} ^
            {24'd0, k_sel, k_lat, k_blat, k_bp, k_grp} ^
            {56'd0, 4'd0, k_fault} ^
            {56'd0, 8'(k_lseen)};
  end

  assign rd_req_valid     = qv_q;
  assign rd_req_bin       = qb_q;
  assign rd_req_frame_off = qf_q;
  assign rsp_ready        = qr_q;
  assign m_valid          = mv_q;
  assign m_payload        = mp_q;
  assign stat_fold        = sf_q;

endmodule : align_net_wrap

`default_nettype wire
