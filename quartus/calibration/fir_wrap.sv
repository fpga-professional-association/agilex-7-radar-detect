// -----------------------------------------------------------------------------
// fir_wrap — synthesis wrapper for the SPEC 18 complex-FIR-lane calibration
// (issue #10, SPEC.md 18 item 2).
//
// SPEC 18 requires representative kernels to be synthesized on their own, before
// the full design, and swept over pipeline depth, register placement, memory
// geometry and parallelism, with DSP mapping, ALMs, M20K mapping, Fmax and
// retiming MEASURED rather than argued. This is the wrapper the FIR-lane sweep
// compiles; the sweep is scripts/run_calibration.py --kernel fir driving
// quartus/scripts/calibrate.tcl against quartus/calibration/fir_calib.qpf.
//
// Why a wrapper exists at all — same argument as quartus/calibration/cmult_wrap.sv:
// compiled as the top entity, every operand bit of the kernel would be a
// top-level port and, even as a virtual pin, would be analysed against
// set_input_delay / set_output_delay. The reported Fmax would then be a
// statement about the boundary budget. One register layer on each side makes
// every path the sweep cares about a genuine register-to-register fabric path.
//
// WHY THE COEFFICIENT BANK IS INSIDE THE MEASUREMENT
// --------------------------------------------------
// A 16-tap complex lane needs 16 x 32 bits of coefficient presented in parallel.
// Driving those from top-level ports would put 512 virtual pins on the boundary
// and would measure a lane whose coefficients arrive from nowhere. The real lane
// reads them from rtl/pfb/coeff_bank.sv, so the calibration point includes one —
// PHASES = 1, TAPS = 16, both banks — and the per-entity utilization table in
// the exported record separates the bank's cost from the lane's. That is also
// what makes "MLAB or ALM for the coefficient store?" a measured answer instead
// of an assumption.
//
// The coefficient bank's configuration port is driven from top-level ports and
// its clock is tied to the core clock here. That is a deliberate simplification
// of the calibration point, not of the RTL: the crossing primitives are still
// elaborated and still cost what they cost, and a single-clock calibration
// project keeps the measurement a fabric measurement rather than a two-domain
// timing exercise. quartus/calibration/fir_calib.sdc says the same thing.
//
// Integer parameters only, for the reason cmult_wrap gives: the sweep sets
// parameters with Quartus's `set_parameter`, whose handling of string values is
// not something a benchmark should depend on. The mapping from integer to the
// module's string parameter is a generate-if below, in RTL, checked by the same
// elaboration assertions every other instantiation gets.
//
// EVERY output is registered and driven out. Nothing is tied off or folded into
// a reduction tree: SPEC 24 forbids "constant-driving unused inputs so large
// blocks optimize away".
// -----------------------------------------------------------------------------

`default_nettype none

module fir_wrap
  import fxp_pkg::*;
  import pfb_pkg::*;
#(
    // Taps in the lane under calibration. 16 is the SPEC 7.1 nominal.
    parameter int unsigned TAPS = 16,

    // complex_multiplier PIPE_STAGES == its latency. Legal range [1, 5].
    parameter int unsigned MULT_PIPE_STAGES = 4,

    // 0 = ACC_STYLE "TREE" (balanced adder tree, fabric adders)
    // 1 = ACC_STYLE "SYSTOLIC" (linear cascade, the DSP-chainin shape)
    parameter int unsigned ACC_STYLE_SEL = 0,

    // 0 = MULT_VARIANT "MULT4", 1 = "MULT3" (Karatsuba). Bit-identical.
    parameter int unsigned VARIANT_SEL = 0
) (
    input  wire        clk,
    input  wire        rst_n,

    // ---- datapath ------------------------------------------------------------
    input  wire        valid_in,
    input  wire [15:0] x_re,
    input  wire [15:0] x_im,

    output wire        valid_out,
    output wire [15:0] y_re,
    output wire [15:0] y_im,
    output wire [1:0]  flags_re,
    output wire [1:0]  flags_im,
    output wire        ovf,

    // ---- coefficient programming --------------------------------------------
    input  wire        cfg_wr_valid,
    output wire        cfg_wr_ready,
    input  wire        cfg_wr_bank,
    input  wire [7:0]  cfg_wr_addr,
    input  wire [31:0] cfg_wr_data,
    input  wire        cfg_swap_req,
    output wire        cfg_swap_busy,
    output wire        cfg_status,
    input  wire        sof
);

  localparam int unsigned PAIR_W = 2 * FXP_SAMPLE_W;      // 32
  localparam int unsigned ADDR_W = $clog2(TAPS);

  // ---------------------------------------------------------------------------
  // Boundary input registers.
  //
  // The datapath registers are free-running and unreset, matching the kernel's
  // own policy (SPEC 23: reset validity, not every datapath bit). Only the valid
  // and the configuration handshake are reset, so the reset network the Fitter
  // sees is the one the real design will have rather than a wide synchronous
  // clear that would distort both the ALM count and the retiming result.
  // ---------------------------------------------------------------------------
  logic         vin_q, sof_q;
  fxp_complex_t x_q;

  always_ff @(posedge clk) begin
    if (!rst_n) begin
      vin_q <= 1'b0;
      sof_q <= 1'b0;
    end else begin
      vin_q <= valid_in;
      sof_q <= sof;
    end
  end

  always_ff @(posedge clk) begin
    x_q <= '{re: fxp16_t'(x_re), im: fxp16_t'(x_im)};
  end

  logic              cwr_v_q, cswap_q, cbank_q;
  logic [ADDR_W-1:0] caddr_q;
  logic [31:0]       cdata_q;

  always_ff @(posedge clk) begin
    if (!rst_n) begin
      cwr_v_q <= 1'b0;
      cswap_q <= 1'b0;
    end else begin
      cwr_v_q <= cfg_wr_valid;
      cswap_q <= cfg_swap_req;
    end
  end

  always_ff @(posedge clk) begin
    cbank_q <= cfg_wr_bank;
    caddr_q <= cfg_wr_addr[ADDR_W-1:0];
    cdata_q <= cfg_wr_data;
  end

  // ---------------------------------------------------------------------------
  // Coefficient bank for the lane under calibration
  // ---------------------------------------------------------------------------
  logic [TAPS*PAIR_W-1:0] coeff;
  logic                   c_rdy, c_busy, c_active, c_pending, c_reject;

  // Named sinks rather than `()` (PINCONNECTEMPTY); see rtl/cdc/stream_cdc.sv.
  logic c_overrun_unused, c_core_active_unused, c_core_pending_unused;

  coeff_bank #(
      .PHASES            (1),
      .TAPS              (TAPS),
      .SYNC_STAGES       (2),
      .ALLOW_UNSAFE_SWAP (1'b0)
  ) u_coeff (
      .cfg_clk          (clk),
      .cfg_rst_n        (rst_n),
      .cfg_wr_valid     (cwr_v_q),
      .cfg_wr_ready     (c_rdy),
      .cfg_wr_bank      (cbank_q),
      .cfg_wr_addr      (caddr_q),
      .cfg_wr_data      (cdata_q),
      .cfg_swap_req     (cswap_q),
      .cfg_swap_busy    (c_busy),
      .cfg_swap_overrun (c_overrun_unused),
      .cfg_active_bank  (c_active),
      .cfg_swap_pending (c_pending),
      .cfg_wr_reject    (c_reject),
      .core_clk         (clk),
      .core_rst_n       (rst_n),
      .core_beat        (vin_q),
      .core_sof         (sof_q),
      .core_active_bank (c_core_active_unused),
      .core_swap_pending(c_core_pending_unused),
      .coeff_o          (coeff)
  );

  // ---------------------------------------------------------------------------
  // The kernel under calibration. Instance name `u_kernel`: that is the name
  // quartus/scripts/calibrate.tcl matches in the per-entity utilization table,
  // and it is the same in every generate branch.
  // ---------------------------------------------------------------------------
  logic         k_valid;
  fxp_complex_t k_y;
  fxp_flags_t   k_fre, k_fim;
  logic         k_ovf;

  if (ACC_STYLE_SEL == 1) begin : g_systolic
    if (VARIANT_SEL == 1) begin : g_m3
      fir_lane #(.TAPS(TAPS), .MULT_PIPE_STAGES(MULT_PIPE_STAGES),
                 .MULT_VARIANT("MULT3"), .ACC_STYLE("SYSTOLIC"),
                 .DELAY_STYLE("AUTO")) u_kernel (
          .clk(clk), .rst_n(rst_n), .valid_in(vin_q), .x_in(x_q), .coeff(coeff),
          .valid_out(k_valid), .y_out(k_y), .flags_re(k_fre), .flags_im(k_fim),
          .ovf(k_ovf));
    end else begin : g_m4
      fir_lane #(.TAPS(TAPS), .MULT_PIPE_STAGES(MULT_PIPE_STAGES),
                 .MULT_VARIANT("MULT4"), .ACC_STYLE("SYSTOLIC"),
                 .DELAY_STYLE("AUTO")) u_kernel (
          .clk(clk), .rst_n(rst_n), .valid_in(vin_q), .x_in(x_q), .coeff(coeff),
          .valid_out(k_valid), .y_out(k_y), .flags_re(k_fre), .flags_im(k_fim),
          .ovf(k_ovf));
    end
  end else begin : g_tree
    if (VARIANT_SEL == 1) begin : g_m3
      fir_lane #(.TAPS(TAPS), .MULT_PIPE_STAGES(MULT_PIPE_STAGES),
                 .MULT_VARIANT("MULT3"), .ACC_STYLE("TREE"),
                 .DELAY_STYLE("AUTO")) u_kernel (
          .clk(clk), .rst_n(rst_n), .valid_in(vin_q), .x_in(x_q), .coeff(coeff),
          .valid_out(k_valid), .y_out(k_y), .flags_re(k_fre), .flags_im(k_fim),
          .ovf(k_ovf));
    end else begin : g_m4
      fir_lane #(.TAPS(TAPS), .MULT_PIPE_STAGES(MULT_PIPE_STAGES),
                 .MULT_VARIANT("MULT4"), .ACC_STYLE("TREE"),
                 .DELAY_STYLE("AUTO")) u_kernel (
          .clk(clk), .rst_n(rst_n), .valid_in(vin_q), .x_in(x_q), .coeff(coeff),
          .valid_out(k_valid), .y_out(k_y), .flags_re(k_fre), .flags_im(k_fim),
          .ovf(k_ovf));
    end
  end

  // ---------------------------------------------------------------------------
  // Boundary output registers
  // ---------------------------------------------------------------------------
  logic       vout_q, ovf_q, stat_q;
  fxp16_t     yre_q, yim_q;
  fxp_flags_t fre_q, fim_q;

  always_ff @(posedge clk) begin
    if (!rst_n) vout_q <= 1'b0;
    else        vout_q <= k_valid;
  end

  always_ff @(posedge clk) begin
    yre_q  <= k_y.re;
    yim_q  <= k_y.im;
    fre_q  <= k_fre;
    fim_q  <= k_fim;
    ovf_q  <= k_ovf;
    // One status pin rather than five: the configuration side is not what this
    // point measures, and five separate virtual pins would add five boundary
    // paths to the analysed graph for no information.
    stat_q <= c_rdy | c_busy | c_active | c_pending | c_reject;
  end

  assign valid_out    = vout_q;
  assign y_re         = yre_q;
  assign y_im         = yim_q;
  assign flags_re     = fre_q;
  assign flags_im     = fim_q;
  assign ovf          = ovf_q;
  assign cfg_wr_ready = c_rdy;
  assign cfg_swap_busy = c_busy;
  assign cfg_status   = stat_q;

endmodule : fir_wrap

`default_nettype wire
