// -----------------------------------------------------------------------------
// pfb_top — the polyphase FIR bank verification top (issue #10, SPEC 13.1).
//
// Holds TWO complete polyphase banks, identical in every parameter except the
// accumulation structure, driven from ONE stimulus port and admitting exactly
// the same beats:
//
//     index  ACC_STYLE   LAT_BEATS   LAT_CYCLES
//     -----  ---------   ---------   ----------
//       0    TREE            0        MULT_PIPE + clog2(TAPS) + 1
//       1    SYSTOLIC     TAPS-1      MULT_PIPE + 1
//
// "The two accumulation structures are bit-identical" is therefore a same-cycle
// fact about one stimulus stream rather than a comparison of two runs — the same
// arrangement sim/verilator/tops/cmult_top.sv uses for MULT4 against MULT3, and
// for the same reason.
//
// LOCKSTEP ADMISSION
// ------------------
// The two banks have different pipeline depths and therefore different credit
// counts, so their `s_ready` differ. Each bank's `s_valid` is gated by the
// OTHER's readiness, so a beat is admitted by both or by neither and the two
// output streams stay beat-for-beat comparable. The top's own `s_ready` is the
// AND of the two.
//
// Note that the SYSTOLIC bank emits TAPS-1 FEWER beats for a finite burst: its
// cascade warm-up holds the first TAPS-1 results, which is ordinary filter drain
// behaviour and not a difference in the output sequence. The test scoreboards
// each bank against the same model output list and simply reaches a different
// point in it.
//
// THE NEGATIVE-TEST COEFFICIENT BANK
// ----------------------------------
// `u_unsafe` is a small coeff_bank elaborated with ALLOW_UNSAFE_SWAP = 1, wired
// to its own ports and to nothing in the datapath. Its swap ignores the frame
// boundary, so driving it provokes a_coeff_swap_at_sof. It exists because an
// assertion nothing can provoke is an assertion nobody has tested; sim/tests/
// test_pfb_bank.cpp runs it last, with `Verilated::fatalOnError` cleared, and
// requires that exact property to fire by name.
//
// The metadata ports are unpacked (sof/eof/id/seq/user as separate ports) while
// the banks themselves speak the packed SPEC 5 bundle. The packing and unpacking
// here is stream_pkg's, so the top exercises the canonical layout while the C++
// harness drives plain fields — the same split rtl/common/stream_loopback.sv
// makes.
//
// Simulation only. Not in files.f, never in a Quartus source list; the DUTs are
// in files.f and in quartus/calibration/.
// -----------------------------------------------------------------------------

`default_nettype none

module pfb_top
  import fxp_pkg::*;
  import stream_pkg::*;
  import pfb_pkg::*;
(
    input  wire         clk,
    input  wire         rst_n,

    // ---- coefficient programming, broadcast to both banks -------------------
    input  wire         cfg_wr_valid,
    output wire         cfg_wr_ready,
    input  wire         cfg_wr_bank,
    input  wire [4:0]   cfg_wr_addr,   // clog2(PHASES*TAPS); checked at time 0
    input  wire [31:0]  cfg_wr_data,
    input  wire         cfg_swap_req,
    output wire         cfg_swap_busy,
    output wire         cfg_swap_overrun,
    output wire         cfg_active_bank,
    output wire         cfg_swap_pending,
    output wire         cfg_wr_reject,

    // ---- stream in -----------------------------------------------------------
    input  wire         s_valid,
    output wire         s_ready,
    input  wire [127:0] s_data,     // PHASES x {im, re}, phase 0 in the low word
    input  wire         s_sof,
    input  wire         s_eof,
    input  wire [1:0]   s_id,
    input  wire [15:0]  s_seq,
    input  wire [3:0]   s_user,

    // ---- stream out ----------------------------------------------------------
    input  wire         m_ready,

    output wire         m0_valid,
    output wire [127:0] m0_data,
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

    // ---- telemetry, from the TREE bank --------------------------------------
    input  wire         telem_clear,
    input  wire         telem_snapshot,
    output wire [1:0]   sat_sticky,        // {sat_pos, sat_neg}
    output wire         sat_any,
    output wire [31:0]  sat_event_count,
    output wire [31:0]  sat_event_snap,
    output wire [31:0]  frame_count,
    output wire [31:0]  frame_snap,

    // ---- the negative-test coefficient bank ---------------------------------
    input  wire         unsafe_swap_req,
    input  wire         unsafe_beat,
    input  wire         unsafe_sof,
    output wire         unsafe_active_bank,
    output wire [63:0]  unsafe_coeff,

    // ---- delay-line storage-style equivalence probe -------------------------
    // 0 while the two lines have not filled, 1 once they have and have agreed on
    // every enabled cycle since. Sticky low on any disagreement.
    output wire         dl_probe_valid,
    output wire         dl_probe_ok,

    // ---- geometry echo, checked by the test against its own mirror ----------
    output wire [7:0]   cfg_phases,
    output wire [7:0]   cfg_taps,
    output wire [7:0]   cfg_mult_pipe,
    output wire [7:0]   cfg_coeff_addr_w,
    output wire [7:0]   cfg_acc_w,
    output wire [7:0]   cfg_lat_beats0,
    output wire [7:0]   cfg_lat_cycles0,
    output wire [7:0]   cfg_lat_beats1,
    output wire [7:0]   cfg_lat_cycles1,
    output wire [15:0]  cfg_payload_w
);

  // ---------------------------------------------------------------------------
  // Geometry. Mirrored in sim/tests/test_pfb_bank.cpp and checked against the
  // cfg_* echo before anything else runs, so a drift is a named failure rather
  // than a silently wrong comparison.
  //
  // 4 phases x 8 taps rather than the SPEC 7.1 nominal 8 x 16: the point of this
  // top is the CONTRACT (alignment, swap, backpressure, saturation), which is
  // geometry-independent, and 4 x 8 keeps two whole banks — 256 real multipliers
  // — inside the sim-tiny time budget. The nominal geometry is what the SPEC 18
  // calibration project compiles.
  // ---------------------------------------------------------------------------
  localparam int unsigned PHASES      = 4;
  localparam int unsigned TAPS        = 8;
  localparam int unsigned MULT_PIPE   = 4;
  localparam int unsigned STREAM_ID_W = 2;
  localparam int unsigned SEQ_W       = 16;
  localparam int unsigned USER_W      = 4;

  localparam int unsigned PAIR_W   = 2 * FXP_SAMPLE_W;            // 32
  localparam int unsigned DATA_W   = PHASES * PAIR_W;             // 128
  localparam int unsigned ADDR_W   = $clog2(PHASES * TAPS);       // 5
  localparam int unsigned PAYLOAD_W =
      DATA_W + STREAM_FLAG_W + STREAM_ID_W + SEQ_W + USER_W;      // 152

  // Fully qualified: this top imports fxp_pkg, stream_pkg and pfb_pkg, and the
  // first two both declare `uint_t`. See rtl/packages/pfb_pkg.sv.
  localparam stream_geom_t GEOM = stream_geom(stream_pkg::uint_t'(DATA_W),
                                              stream_pkg::uint_t'(STREAM_ID_W),
                                              stream_pkg::uint_t'(SEQ_W),
                                              stream_pkg::uint_t'(USER_W));

`ifndef SYNTHESIS
  initial begin
    if (int'(stream_payload_w(GEOM)) != PAYLOAD_W) begin
      $fatal(1, "pfb_top: payload width mirror %0d != stream_pkg %0d",
             PAYLOAD_W, int'(stream_payload_w(GEOM)));
    end
    // The coefficient address port is declared at a literal width because a port
    // width cannot see a localparam; this is what keeps it honest.
    if ($bits(cfg_wr_addr) != ADDR_W) begin
      $fatal(1, "pfb_top: cfg_wr_addr is %0d bits but the geometry needs %0d",
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
    s_fields.data      = STREAM_MAX_DATA_W'(s_data[DATA_W-1:0]);
    s_fields.sof       = s_sof;
    s_fields.eof       = s_eof;
    s_fields.stream_id = STREAM_MAX_ID_W'(s_id);
    s_fields.seq       = STREAM_MAX_SEQ_W'(s_seq);
    s_fields.user      = STREAM_MAX_USER_W'(s_user);
  end

  logic [PAYLOAD_W-1:0] s_payload;
  assign s_payload = PAYLOAD_W'(stream_pack(GEOM, s_fields));

  // ---------------------------------------------------------------------------
  // Lockstep admission. See the header.
  // ---------------------------------------------------------------------------
  logic rdy0, rdy1;
  assign s_ready = rdy0 && rdy1;

  logic cfg_rdy0, cfg_rdy1;
  assign cfg_wr_ready = cfg_rdy0 && cfg_rdy1;

  logic cfg_busy0, cfg_busy1;
  assign cfg_swap_busy = cfg_busy0 || cfg_busy1;

  logic cfg_ovr0, cfg_ovr1;
  assign cfg_swap_overrun = cfg_ovr0 || cfg_ovr1;

  logic [PAYLOAD_W-1:0] m0_payload, m1_payload;

  // Named sinks rather than `()`: an empty pin connection is a lint warning
  // (PINCONNECTEMPTY), and a named wire says which outputs this top deliberately
  // does not export. Same convention as rtl/cdc/stream_cdc.sv.
  logic        t_core_active_unused, t_core_pending_unused;
  logic        y_cfg_active_unused, y_cfg_pending_unused, y_cfg_reject_unused;
  logic [1:0]  y_sat_sticky_unused;
  logic        y_sat_any_unused;
  logic [31:0] y_sat_count_unused, y_sat_snap_unused;
  logic [31:0] y_frame_count_unused, y_frame_snap_unused;
  logic        y_core_active_unused, y_core_pending_unused;
  logic        u_cfg_rdy_unused, u_cfg_busy_unused, u_cfg_ovr_unused;
  logic        u_cfg_active_unused, u_cfg_pending_unused, u_cfg_reject_unused;
  logic        u_core_pending_unused;

  // ---------------------------------------------------------------------------
  // DUT 0 — TREE
  // ---------------------------------------------------------------------------
  pfb_bank #(
      .PHASES           (PHASES),
      .TAPS             (TAPS),
      .MULT_PIPE_STAGES (MULT_PIPE),
      .MULT_VARIANT     ("MULT4"),
      .ACC_STYLE        ("TREE"),
      .DELAY_STYLE      ("AUTO"),
      .STREAM_ID_W      (STREAM_ID_W),
      .SEQ_W            (SEQ_W),
      .USER_W           (USER_W),
      .SYNC_STAGES      (2),
      .TELEM_COUNT_W    (32)
  ) u_tree (
      .core_clk         (clk),
      .core_rst_n       (rst_n),
      .cfg_clk          (clk),
      .cfg_rst_n        (rst_n),
      .cfg_wr_valid     (cfg_wr_valid && cfg_rdy1),
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
      .s_valid          (s_valid && rdy1),
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
      .core_active_bank (t_core_active_unused),
      .core_swap_pending(t_core_pending_unused)
  );

  // ---------------------------------------------------------------------------
  // DUT 1 — SYSTOLIC
  // ---------------------------------------------------------------------------
  pfb_bank #(
      .PHASES           (PHASES),
      .TAPS             (TAPS),
      .MULT_PIPE_STAGES (MULT_PIPE),
      .MULT_VARIANT     ("MULT4"),
      .ACC_STYLE        ("SYSTOLIC"),
      .DELAY_STYLE      ("AUTO"),
      .STREAM_ID_W      (STREAM_ID_W),
      .SEQ_W            (SEQ_W),
      .USER_W           (USER_W),
      .SYNC_STAGES      (2),
      .TELEM_COUNT_W    (32)
  ) u_sys (
      .core_clk         (clk),
      .core_rst_n       (rst_n),
      .cfg_clk          (clk),
      .cfg_rst_n        (rst_n),
      .cfg_wr_valid     (cfg_wr_valid && cfg_rdy0),
      .cfg_wr_ready     (cfg_rdy1),
      .cfg_wr_bank      (cfg_wr_bank),
      .cfg_wr_addr      (cfg_wr_addr),
      .cfg_wr_data      (cfg_wr_data),
      .cfg_swap_req     (cfg_swap_req),
      .cfg_swap_busy    (cfg_busy1),
      .cfg_swap_overrun (cfg_ovr1),
      .cfg_active_bank  (y_cfg_active_unused),
      .cfg_swap_pending (y_cfg_pending_unused),
      .cfg_wr_reject    (y_cfg_reject_unused),
      .s_valid          (s_valid && rdy0),
      .s_ready          (rdy1),
      .s_payload        (s_payload),
      .m_valid          (m1_valid),
      .m_ready          (m_ready),
      .m_payload        (m1_payload),
      .telem_clear      (telem_clear),
      .telem_snapshot   (telem_snapshot),
      .sat_sticky       (y_sat_sticky_unused),
      .sat_any          (y_sat_any_unused),
      .sat_event_count  (y_sat_count_unused),
      .sat_event_snap   (y_sat_snap_unused),
      .frame_count      (y_frame_count_unused),
      .frame_snap       (y_frame_snap_unused),
      .core_active_bank (y_core_active_unused),
      .core_swap_pending(y_core_pending_unused)
  );

  // ---------------------------------------------------------------------------
  // Output unpacking
  // ---------------------------------------------------------------------------
  stream_fields_t m0_fields, m1_fields;
  assign m0_fields = stream_unpack(GEOM, stream_payload_t'(m0_payload));
  assign m1_fields = stream_unpack(GEOM, stream_payload_t'(m1_payload));

  assign m0_data = 128'(m0_fields.data[DATA_W-1:0]);
  assign m0_sof  = m0_fields.sof;
  assign m0_eof  = m0_fields.eof;
  assign m0_id   = m0_fields.stream_id[STREAM_ID_W-1:0];
  assign m0_seq  = m0_fields.seq[SEQ_W-1:0];
  assign m0_user = m0_fields.user[USER_W-1:0];

  assign m1_data = 128'(m1_fields.data[DATA_W-1:0]);
  assign m1_sof  = m1_fields.sof;
  assign m1_eof  = m1_fields.eof;
  assign m1_id   = m1_fields.stream_id[STREAM_ID_W-1:0];
  assign m1_seq  = m1_fields.seq[SEQ_W-1:0];
  assign m1_user = m1_fields.user[USER_W-1:0];

  // ---------------------------------------------------------------------------
  // The negative-test coefficient bank. Outside the datapath; see the header.
  // ---------------------------------------------------------------------------
  coeff_bank #(
      .PHASES            (1),
      .TAPS              (2),
      .SYNC_STAGES       (2),
      .ALLOW_UNSAFE_SWAP (1'b1)
  ) u_unsafe (
      .cfg_clk          (clk),
      .cfg_rst_n        (rst_n),
      .cfg_wr_valid     (1'b0),
      .cfg_wr_ready     (u_cfg_rdy_unused),
      .cfg_wr_bank      (1'b0),
      .cfg_wr_addr      (1'b0),
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
      .coeff_o          (unsafe_coeff)
  );

  // ---------------------------------------------------------------------------
  // Delay-line storage-style equivalence probe
  //
  // pfb_pkg's AUTO threshold resolves EVERY delay line in the datapath to a
  // shift register at these geometries — correctly, because a FIR history is
  // tapped at every stage and a metadata path is shallow. The memory form would
  // therefore be code that no test ever runs, which is the same thing as code
  // that does not work.
  //
  // So two lines of identical geometry, one forced to each style, are fed the
  // live stream and compared on every enabled cycle once both have filled. A
  // pure delay is a pure delay: if the M20K form's pointer arithmetic or its
  // read-before-write ordering is wrong, this says so.
  //
  // 40 deep and 32 bits wide: past PFB_MEM_MIN_DEPTH but only 1280 bits, so AUTO
  // would still choose SRL. The MEM instance is therefore also a test that an
  // EXPLICIT style override is honoured.
  // ---------------------------------------------------------------------------
  localparam int unsigned DL_PROBE_W     = 32;
  localparam int unsigned DL_PROBE_DEPTH = 40;

  logic dl_en;
  assign dl_en = s_valid && s_ready;

  logic [DL_PROBE_W-1:0] dl_srl_q, dl_mem_q;
  logic [DL_PROBE_W-1:0] dl_srl_taps_unused, dl_mem_taps_unused;

  delay_line #(
      .WIDTH (DL_PROBE_W), .N_TAPS (1), .TAP_STRIDE (DL_PROBE_DEPTH),
      .STYLE ("SRL")
  ) u_dl_srl (
      .clk (clk), .en (dl_en), .d (s_data[DL_PROBE_W-1:0]),
      .taps (dl_srl_taps_unused), .q (dl_srl_q));

  delay_line #(
      .WIDTH (DL_PROBE_W), .N_TAPS (1), .TAP_STRIDE (DL_PROBE_DEPTH),
      .STYLE ("MEM")
  ) u_dl_mem (
      .clk (clk), .en (dl_en), .d (s_data[DL_PROBE_W-1:0]),
      .taps (dl_mem_taps_unused), .q (dl_mem_q));

  localparam int unsigned DL_CNT_W = $clog2(DL_PROBE_DEPTH + 1);
  logic [DL_CNT_W-1:0] dl_fill_q;
  logic                dl_ok_q;

  always_ff @(posedge clk) begin
    if (!rst_n) begin
      dl_fill_q <= '0;
      dl_ok_q   <= 1'b1;
    end else begin
      if (dl_en && (dl_fill_q != DL_CNT_W'(DL_PROBE_DEPTH))) begin
        dl_fill_q <= dl_fill_q + DL_CNT_W'(1);
      end
      if ((dl_fill_q == DL_CNT_W'(DL_PROBE_DEPTH)) && (dl_srl_q != dl_mem_q)) begin
        dl_ok_q <= 1'b0;
      end
    end
  end

  assign dl_probe_valid = (dl_fill_q == DL_CNT_W'(DL_PROBE_DEPTH));
  assign dl_probe_ok    = dl_ok_q;

`ifndef SYNTHESIS
  always_ff @(posedge clk) begin
    if (rst_n && dl_probe_valid) begin
      a_dl_styles_agree : assert (dl_srl_q == dl_mem_q)
        else $error("delay_line: the SRL and MEM forms disagree at depth %0d (srl=%h mem=%h)",
                    DL_PROBE_DEPTH, dl_srl_q, dl_mem_q);
    end
  end
`endif

  // ---------------------------------------------------------------------------
  // Geometry echo
  // ---------------------------------------------------------------------------
  assign cfg_phases       = 8'(PHASES);
  assign cfg_taps         = 8'(TAPS);
  assign cfg_mult_pipe    = 8'(MULT_PIPE);
  assign cfg_coeff_addr_w = 8'(ADDR_W);
  assign cfg_acc_w        = 8'(pfb_acc_w(pfb_uint_t'(TAPS)));
  assign cfg_lat_beats0   = 8'(pfb_lat_beats("TREE", pfb_uint_t'(TAPS)));
  assign cfg_lat_cycles0  = 8'(pfb_lat_cycles("TREE", pfb_uint_t'(TAPS),
                                              pfb_uint_t'(MULT_PIPE)));
  assign cfg_lat_beats1   = 8'(pfb_lat_beats("SYSTOLIC", pfb_uint_t'(TAPS)));
  assign cfg_lat_cycles1  = 8'(pfb_lat_cycles("SYSTOLIC", pfb_uint_t'(TAPS),
                                              pfb_uint_t'(MULT_PIPE)));
  assign cfg_payload_w    = 16'(PAYLOAD_W);

endmodule : pfb_top

`default_nettype wire
