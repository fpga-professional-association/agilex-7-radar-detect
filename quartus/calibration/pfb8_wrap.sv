// -----------------------------------------------------------------------------
// pfb8_wrap — synthesis wrapper for the SPEC 18 eight-lane PFB calibration
// (issue #10, SPEC.md 18 item 3).
//
// SPEC 18 item 3 is "one eight-lane PFB". This wrapper compiles exactly that:
// rtl/pfb/pfb_bank.sv at the SPEC 7.1 nominal geometry — eight phases, sixteen
// taps per phase, one shared dual coefficient bank, the SPEC 5 stream interface
// with its elastic boundary, and the SPEC 9 telemetry — as one instance named
// `u_kernel`, with one register layer on each boundary.
//
// What the point is FOR, and why it is not just eight times the lane point
// -----------------------------------------------------------------------------
// The lane point (quartus/calibration/fir_wrap.sv) prices arithmetic. This one
// prices everything the lane point cannot see:
//
//   * whether eight lanes' DSPs still cascade, or whether the Fitter runs out of
//     column-adjacent blocks and falls back to fabric adders,
//   * what the 8 x 16 x 2 x 32-bit coefficient store maps to — registers, MLAB
//     or M20K — and what its 4096-bit output mux costs,
//   * the credit gate, the metadata alignment path and the output elastic
//     buffer, which are per-BLOCK costs that do not scale with lanes,
//   * whether the critical path is still inside a lane at eight-lane fanout.
//
// The last one is why scripts/run_calibration.py records the critical path's
// source and destination hierarchy for every point and flags a point whose
// register-to-register path does not touch `u_kernel`.
//
// Virtual pins carry the 280-bit stream payload (8 x 32 data + 24 metadata) in
// and out. That is a lot of boundary, which is exactly why the boundary
// registers below exist: without them the Fitter would be timing a virtual pin
// against set_input_delay rather than the bank.
//
// The configuration domain is tied to the core clock here, as in fir_wrap, and
// for the same reason: the crossing primitives are still elaborated and still
// cost what they cost, but the point stays a single-clock fabric measurement.
//
// SPEC 24: nothing is tied off to make the block optimise away. Every output is
// registered and driven to a pin, and the input stream is a genuine port rather
// than a constant.
// -----------------------------------------------------------------------------

`default_nettype none

module pfb8_wrap
  import fxp_pkg::*;
  import pfb_pkg::*;
#(
    parameter int unsigned PHASES = 8,
    parameter int unsigned TAPS   = 16,

    parameter int unsigned MULT_PIPE_STAGES = 4,

    // 0 = ACC_STYLE "TREE", 1 = ACC_STYLE "SYSTOLIC". See fir_wrap for why the
    // sweep sets an integer rather than the module's string parameter.
    parameter int unsigned ACC_STYLE_SEL = 0,

    // DERIVED; never overridden. See rtl/pfb/pfb_bank.sv for why a port width
    // has to be a parameter expression.
    parameter int unsigned STREAM_ID_W = 2,
    parameter int unsigned SEQ_W       = 16,
    parameter int unsigned USER_W      = 4,
    parameter int unsigned PAYLOAD_W =
        PHASES * 2 * fxp_pkg::FXP_SAMPLE_W + 2 + STREAM_ID_W + SEQ_W + USER_W
) (
    input  wire                  clk,
    input  wire                  rst_n,

    input  wire                  s_valid,
    output wire                  s_ready,
    input  wire [PAYLOAD_W-1:0]  s_payload,

    output wire                  m_valid,
    input  wire                  m_ready,
    output wire [PAYLOAD_W-1:0]  m_payload,

    input  wire                  cfg_wr_valid,
    output wire                  cfg_wr_ready,
    input  wire                  cfg_wr_bank,
    input  wire [7:0]            cfg_wr_addr,
    input  wire [31:0]           cfg_wr_data,
    input  wire                  cfg_swap_req,
    output wire                  cfg_status,

    input  wire                  telem_clear,
    input  wire                  telem_snapshot,
    output wire [31:0]           telem_status
);

  localparam int unsigned ADDR_W = $clog2(PHASES * TAPS);

  // ---------------------------------------------------------------------------
  // Boundary input registers. Valid and the configuration strobes are reset;
  // the payload is not (SPEC 23).
  // ---------------------------------------------------------------------------
  logic                 sv_q, mr_q, cwr_q, csw_q, cbank_q;
  logic [PAYLOAD_W-1:0] sp_q;
  logic [ADDR_W-1:0]    caddr_q;
  logic [31:0]          cdata_q;
  logic                 tclr_q, tsnap_q;

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
  logic                 k_sready, k_mvalid;
  logic [PAYLOAD_W-1:0] k_mpayload;
  logic                 k_cwr_ready, k_cbusy, k_covr, k_cactive, k_cpending,
                        k_creject, k_sat_any, k_core_active, k_core_pending;
  fxp_flags_t           k_sat_sticky;
  logic [31:0]          k_sat_count, k_sat_snap, k_frame_count, k_frame_snap;

  if (ACC_STYLE_SEL == 1) begin : g_systolic
    pfb_bank #(
        .PHASES(PHASES), .TAPS(TAPS), .MULT_PIPE_STAGES(MULT_PIPE_STAGES),
        .MULT_VARIANT("MULT4"), .ACC_STYLE("SYSTOLIC"), .DELAY_STYLE("AUTO"),
        .STREAM_ID_W(STREAM_ID_W), .SEQ_W(SEQ_W), .USER_W(USER_W),
        .SYNC_STAGES(2), .TELEM_COUNT_W(32)
    ) u_kernel (
        .core_clk(clk), .core_rst_n(rst_n), .cfg_clk(clk), .cfg_rst_n(rst_n),
        .cfg_wr_valid(cwr_q), .cfg_wr_ready(k_cwr_ready), .cfg_wr_bank(cbank_q),
        .cfg_wr_addr(caddr_q), .cfg_wr_data(cdata_q), .cfg_swap_req(csw_q),
        .cfg_swap_busy(k_cbusy), .cfg_swap_overrun(k_covr),
        .cfg_active_bank(k_cactive), .cfg_swap_pending(k_cpending),
        .cfg_wr_reject(k_creject),
        .s_valid(sv_q), .s_ready(k_sready), .s_payload(sp_q),
        .m_valid(k_mvalid), .m_ready(mr_q), .m_payload(k_mpayload),
        .telem_clear(tclr_q), .telem_snapshot(tsnap_q),
        .sat_sticky(k_sat_sticky), .sat_any(k_sat_any),
        .sat_event_count(k_sat_count), .sat_event_snap(k_sat_snap),
        .frame_count(k_frame_count), .frame_snap(k_frame_snap),
        .core_active_bank(k_core_active), .core_swap_pending(k_core_pending));
  end else begin : g_tree
    pfb_bank #(
        .PHASES(PHASES), .TAPS(TAPS), .MULT_PIPE_STAGES(MULT_PIPE_STAGES),
        .MULT_VARIANT("MULT4"), .ACC_STYLE("TREE"), .DELAY_STYLE("AUTO"),
        .STREAM_ID_W(STREAM_ID_W), .SEQ_W(SEQ_W), .USER_W(USER_W),
        .SYNC_STAGES(2), .TELEM_COUNT_W(32)
    ) u_kernel (
        .core_clk(clk), .core_rst_n(rst_n), .cfg_clk(clk), .cfg_rst_n(rst_n),
        .cfg_wr_valid(cwr_q), .cfg_wr_ready(k_cwr_ready), .cfg_wr_bank(cbank_q),
        .cfg_wr_addr(caddr_q), .cfg_wr_data(cdata_q), .cfg_swap_req(csw_q),
        .cfg_swap_busy(k_cbusy), .cfg_swap_overrun(k_covr),
        .cfg_active_bank(k_cactive), .cfg_swap_pending(k_cpending),
        .cfg_wr_reject(k_creject),
        .s_valid(sv_q), .s_ready(k_sready), .s_payload(sp_q),
        .m_valid(k_mvalid), .m_ready(mr_q), .m_payload(k_mpayload),
        .telem_clear(tclr_q), .telem_snapshot(tsnap_q),
        .sat_sticky(k_sat_sticky), .sat_any(k_sat_any),
        .sat_event_count(k_sat_count), .sat_event_snap(k_sat_snap),
        .frame_count(k_frame_count), .frame_snap(k_frame_snap),
        .core_active_bank(k_core_active), .core_swap_pending(k_core_pending));
  end

  // ---------------------------------------------------------------------------
  // Boundary output registers
  // ---------------------------------------------------------------------------
  logic                 srdy_q, mv_q, cstat_q;
  logic [PAYLOAD_W-1:0] mp_q;
  logic [31:0]          tstat_q;

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
    // sweep.
    tstat_q <= k_sat_count ^ k_sat_snap ^ k_frame_count ^ k_frame_snap ^
               {30'd0, k_sat_sticky.sat_pos | k_sat_any, k_sat_sticky.sat_neg};
  end

  assign s_ready      = srdy_q;
  assign m_valid      = mv_q;
  assign m_payload    = mp_q;
  assign cfg_wr_ready = k_cwr_ready;
  assign cfg_status   = cstat_q;
  assign telem_status = tstat_q;

endmodule : pfb8_wrap

`default_nettype wire
