// -----------------------------------------------------------------------------
// cmult_wrap — synthesis wrapper for the SPEC 18 complex-multiplier calibration.
//
// SPEC 18 ("Resource-Calibration Phase") requires representative kernels to be
// synthesized on their own, before the full design, and swept over pipeline
// depth, register placement and multiplier implementation, with DSP mapping,
// ALMs, Fmax, retiming and routing delay MEASURED rather than argued. This is
// the wrapper the complex-multiplier sweep compiles; the sweep itself is
// scripts/run_calibration.py driving quartus/scripts/calibrate.tcl against
// quartus/calibration/cmult_calib.qpf.
//
// Why a wrapper exists at all
// ---------------------------
// If complex_multiplier were compiled as the top entity directly, every one of
// its operand bits would be a top-level port. Even as virtual pins those are
// analysed as I/O paths against set_input_delay / set_output_delay, so the
// reported Fmax would be a statement about the boundary budget rather than about
// the kernel. This wrapper puts ONE register layer on each side, which makes
// every path the sweep cares about a genuine register-to-register fabric path:
//
//     virtual pin -> in_q -> [ complex_multiplier ] -> out_q -> virtual pin
//                    \_______ measured reg-to-reg ________/
//
// The wrapper's own registers are a constant overhead across every point of the
// sweep — the port list does not change with the parameters — so differences
// between points remain differences in the kernel. The per-entity utilization
// table in the exported record separates them anyway.
//
// EVERY output is registered and driven out. Nothing is tied off, folded into an
// XOR tree or otherwise reduced: SPEC 24 forbids "constant-driving unused inputs
// so large blocks optimize away", and a reduction tree would add ALMs that are
// not the kernel's. The one thing that DOES legitimately disappear is the
// rounding network when ROUND_OUT = 0 — that is the point of the ROUND_OUT axis,
// and the register count difference is the measurement.
//
// Integer parameters only
// -----------------------
// VARIANT_SEL is an integer, not the module's "MULT4"/"MULT3" string, because
// the sweep sets parameters with Quartus's `set_parameter`, whose handling of
// string values is not something a benchmark should depend on. The mapping to
// the string is one generate-if below, in RTL, where it is checked by the same
// elaboration assertions every other instantiation gets.
//
// Not simulation RTL: nothing here has behaviour a testbench could check that
// rtl/common/complex_multiplier.sv does not already have checked. It is listed in
// sim/verilator/files_cmult.f all the same, at the end and outside cmult_top's
// hierarchy, so `make lint` covers it — RTL that no lint ever sees is RTL that
// rots, and a Quartus compile depends on this file. The fast simulation build
// simply does not elaborate a module the top never instantiates.
// -----------------------------------------------------------------------------

`default_nettype none

module cmult_wrap
  import fxp_pkg::*;
#(
    // 0 = VARIANT "MULT4" (four real multiplies), 1 = "MULT3" (Karatsuba).
    parameter int unsigned VARIANT_SEL = 0,

    // Register stages inside the kernel == its latency. Legal range [1, 5].
    parameter int unsigned PIPE_STAGES = 3,

    // 1 = produce the rounded Q1.15 output and its saturation flags.
    // 0 = full-precision output only; the rounding network is absent.
    parameter int unsigned ROUND_OUT   = 1
) (
    input  wire        clk,
    input  wire        rst_n,

    input  wire        valid_in,
    input  wire [15:0] a_re,
    input  wire [15:0] a_im,
    input  wire [15:0] b_re,
    input  wire [15:0] b_im,

    output wire        valid_out,
    output wire [32:0] p_re,
    output wire [32:0] p_im,
    output wire [15:0] y_re,
    output wire [15:0] y_im,
    output wire [1:0]  flags_re,
    output wire [1:0]  flags_im,
    output wire        ovf
);

  localparam int unsigned PROD_W = FXP_PROD_W + 1;   // 33

  // ---------------------------------------------------------------------------
  // Boundary input registers
  //
  // The datapath registers are free-running and unreset, matching the kernel's
  // own policy (SPEC 23: reset validity, not every datapath bit). Only valid is
  // reset, so the reset network the Fitter sees here is the one the real design
  // will have rather than a 64-bit-wide synchronous clear that would distort both
  // the ALM count and the retiming result.
  // ---------------------------------------------------------------------------
  logic         vin_q;
  fxp_complex_t a_q, b_q;

  always_ff @(posedge clk) begin
    if (!rst_n) vin_q <= 1'b0;
    else        vin_q <= valid_in;
  end

  always_ff @(posedge clk) begin
    a_q <= '{re: fxp16_t'(a_re), im: fxp16_t'(a_im)};
    b_q <= '{re: fxp16_t'(b_re), im: fxp16_t'(b_im)};
  end

  // ---------------------------------------------------------------------------
  // The kernel under calibration
  // ---------------------------------------------------------------------------
  logic                     k_valid;
  logic signed [PROD_W-1:0] k_p_re, k_p_im;
  fxp16_t                   k_y_re, k_y_im;
  fxp_flags_t               k_flags_re, k_flags_im;
  logic                     k_ovf;

  if (VARIANT_SEL == 1) begin : g_mult3
    complex_multiplier #(
        .VARIANT     ("MULT3"),
        .PIPE_STAGES (PIPE_STAGES),
        .ROUND_OUT   (ROUND_OUT)
    ) u_kernel (
        .clk       (clk),
        .rst_n     (rst_n),
        .valid_in  (vin_q),
        .a         (a_q),
        .b         (b_q),
        .valid_out (k_valid),
        .p_re      (k_p_re),
        .p_im      (k_p_im),
        .y_re      (k_y_re),
        .y_im      (k_y_im),
        .flags_re  (k_flags_re),
        .flags_im  (k_flags_im),
        .ovf       (k_ovf)
    );
  end else begin : g_mult4
    complex_multiplier #(
        .VARIANT     ("MULT4"),
        .PIPE_STAGES (PIPE_STAGES),
        .ROUND_OUT   (ROUND_OUT)
    ) u_kernel (
        .clk       (clk),
        .rst_n     (rst_n),
        .valid_in  (vin_q),
        .a         (a_q),
        .b         (b_q),
        .valid_out (k_valid),
        .p_re      (k_p_re),
        .p_im      (k_p_im),
        .y_re      (k_y_re),
        .y_im      (k_y_im),
        .flags_re  (k_flags_re),
        .flags_im  (k_flags_im),
        .ovf       (k_ovf)
    );
  end

  // ---------------------------------------------------------------------------
  // Boundary output registers
  // ---------------------------------------------------------------------------
  logic                     vout_q;
  logic signed [PROD_W-1:0] p_re_q, p_im_q;
  fxp16_t                   y_re_q, y_im_q;
  fxp_flags_t               flags_re_q, flags_im_q;
  logic                     ovf_q;

  always_ff @(posedge clk) begin
    if (!rst_n) vout_q <= 1'b0;
    else        vout_q <= k_valid;
  end

  always_ff @(posedge clk) begin
    p_re_q     <= k_p_re;
    p_im_q     <= k_p_im;
    y_re_q     <= k_y_re;
    y_im_q     <= k_y_im;
    flags_re_q <= k_flags_re;
    flags_im_q <= k_flags_im;
    ovf_q      <= k_ovf;
  end

  assign valid_out = vout_q;
  assign p_re      = p_re_q;
  assign p_im      = p_im_q;
  assign y_re      = y_re_q;
  assign y_im      = y_im_q;
  assign flags_re  = flags_re_q;
  assign flags_im  = flags_im_q;
  assign ovf       = ovf_q;

endmodule : cmult_wrap

`default_nettype wire
