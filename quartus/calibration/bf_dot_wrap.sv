// -----------------------------------------------------------------------------
// bf_dot_wrap — synthesis wrapper for the SPEC 18 beamforming dot-product
// calibration (issue #12, SPEC.md 18 item 6: "One beamforming dot product").
//
// Wraps ONE rtl/beamformer/bf_dot.sv at N_ANT = 16 — the SPEC 7.5 nominal
// antenna count — in boundary registers, so the sweep measures a genuine
// register-to-register fabric path rather than the I/O budget. Same arrangement,
// and the same reasoning, as quartus/calibration/cmult_wrap.sv and fir_wrap.sv:
//
//     virtual pin -> in_q -> [ bf_dot ] -> out_q -> virtual pin
//                    \______ measured reg-to-reg ______/
//
// WHY THIS IS THE RIGHT UNIT TO MEASURE
// -------------------------------------
// A 16-antenna complex dot product is the beamformer's ATOM: the full-scale
// matrix is BIN_PAR x BEAM_PAR copies of exactly this module and nothing else in
// the datapath. It is also the design's dominant DSP consumer, so the projection
// SPEC 18 exists to produce — how many DSP blocks a 16-beam by 8-bin by
// 16-antenna matrix costs — is this point's DSP count times BIN_PAR*BEAM_PAR.
// Measuring it standalone rather than inferring it from the complex-multiplier
// point is the whole difference between arithmetic and calibration: sixteen
// multipliers plus a 37-bit adder tree may or may not still map two multiplies
// per DSP block once the tree is competing for the same block's adder, and issue
// #10 found exactly that kind of surprise (a systolic FIR buys no DSP cascade
// because the complex multiply has already consumed the block's adder).
//
// THE AXIS THIS POINT SWEEPS: ADD_REG_EVERY, 1 against 2.
// A register after every tree level (four stages for 16 antennas) against a
// register after every second level (two stages, two 37-bit adders in series).
// The two produce the SAME INTEGER — there is no saturation inside the tree, so
// addition is associative — which is what makes this a pure cost comparison. The
// question is whether the retimer can recover the second configuration's Fmax
// from half the flip-flops, and it is not answerable by inspection.
//
// The multiplier pipeline depth is deliberately NOT swept here: issue #9 swept
// it exhaustively on the multiplier in isolation and issue #10 confirmed at the
// FIR lane that the calibrated default of 4 carries into an accumulating kernel
// at no cost. Repeating it would be sixteen copies of an answered question.
//
// Integer parameters only. VARIANT_SEL is an integer rather than the module's
// string parameter, because the sweep sets parameters with Quartus's
// `set_parameter`, whose handling of string values is not something a benchmark
// should depend on. The mapping to the string is one conditional localparam
// below, in RTL, where the same elaboration assertions every other instantiation
// gets apply to it.
//
// Ports are sized independently of the parameters — the operand ports are a
// fixed 16 antennas wide and the accumulator port a fixed 64 bits — so that the
// virtual-pin assignments in bf_dot_calib.qsf name the same pins at every point
// of the sweep.
//
// SPEC 24: nothing is tied off to make the block optimise away. Every output is
// registered and driven to a pin, including the exact accumulator, and both
// operand vectors are genuine ports rather than constants.
//
// Listed in sim/verilator/files_beamformer.f so `make lint` covers it: RTL that
// no lint ever sees is RTL that rots, and a Quartus compile depends on this file.
// -----------------------------------------------------------------------------

`default_nettype none

module bf_dot_wrap
  import fxp_pkg::*;
  import beamformer_pkg::*;
#(
    // SPEC 7.5 nominal antenna count.
    parameter int unsigned N_ANT = 16,

    // complex_multiplier depth; issue #9's calibrated default.
    parameter int unsigned MULT_PIPE_STAGES = 4,

    // 0 = complex_multiplier "MULT4", 1 = "MULT3".
    parameter int unsigned VARIANT_SEL = 0,

    // Adder-tree pipelining stride: 1 = a register per level, 2 = a register per
    // two levels. THE axis this point sweeps.
    parameter int unsigned ADD_REG_EVERY = 1
) (
    input  wire         clk,
    input  wire         rst_n,

    input  wire         vld_in,
    input  wire [511:0] x_in,     // 16 antennas x {im, re}, Q1.15
    input  wire [511:0] w_in,     // 16 weights  x {im, re}, Q1.15

    output wire         vld_out,
    output wire [31:0]  y_out,    // {im, re}, Q1.15
    output wire [3:0]   flags,    // {re.pos, re.neg, im.pos, im.neg}
    output wire [63:0]  acc_out   // the exact accumulator, sign-extended
);

  localparam string       VARIANT = (VARIANT_SEL == 1) ? "MULT3" : "MULT4";
  localparam int unsigned PAIR_W  = 2 * FXP_SAMPLE_W;
  localparam int unsigned VEC_W   = N_ANT * PAIR_W;
  localparam int unsigned ACC_W   = int'(bf_acc_w(bf_uint_t'(N_ANT)));

  // ---------------------------------------------------------------------------
  // Boundary input registers
  //
  // The datapath registers are free-running and unreset, matching the kernel's
  // own policy (SPEC 23: reset validity, not every datapath bit). Only the beat
  // valid is reset, so the reset network the Fitter sees is the one the real
  // design has rather than a wide synchronous clear that would distort both the
  // ALM count and the retiming result.
  // ---------------------------------------------------------------------------
  logic             vin_q;
  logic [VEC_W-1:0] x_q, w_q;

  always_ff @(posedge clk) begin
    if (!rst_n) vin_q <= 1'b0;
    else        vin_q <= vld_in;
  end

  always_ff @(posedge clk) begin
    x_q <= x_in[VEC_W-1:0];
    w_q <= w_in[VEC_W-1:0];
  end

  // ---------------------------------------------------------------------------
  // The kernel under calibration. The instance MUST be named u_kernel:
  // quartus/scripts/calibrate.tcl extracts the per-entity utilisation row and
  // decides whether the critical path is inside the kernel by that name.
  // ---------------------------------------------------------------------------
  logic                    k_vld, k_ovf;
  fxp_complex_t            k_y;
  fxp_flags_t              k_fre, k_fim;
  logic signed [ACC_W-1:0] k_acc_re, k_acc_im;

  bf_dot #(
      .N_ANT            (N_ANT),
      .MULT_PIPE_STAGES (MULT_PIPE_STAGES),
      .MULT_VARIANT     (VARIANT),
      .ADD_REG_EVERY    (ADD_REG_EVERY)
  ) u_kernel (
      .clk       (clk),
      .rst_n     (rst_n),
      .valid_in  (vin_q),
      .x         (x_q),
      .w         (w_q),
      .valid_out (k_vld),
      .y         (k_y),
      .flags_re  (k_fre),
      .flags_im  (k_fim),
      .ovf       (k_ovf),
      .acc_re    (k_acc_re),
      .acc_im    (k_acc_im)
  );

  // ---------------------------------------------------------------------------
  // Boundary output registers
  //
  // EVERY output is registered and driven out. Nothing is tied off or folded
  // into a reduction tree: SPEC 24 forbids "constant-driving unused inputs so
  // large blocks optimize away", and a reduction tree would add ALMs that are
  // not the kernel's. The two accumulator components are XORed into one 64-bit
  // word only because they are 37 bits each and 74 pins of accumulator would
  // dwarf the block; both still participate, so neither optimises away.
  // ---------------------------------------------------------------------------
  logic        vout_q;
  logic [31:0] y_q;
  logic [3:0]  flags_q;
  logic [63:0] acc_q;

  always_ff @(posedge clk) begin
    if (!rst_n) vout_q <= 1'b0;
    else        vout_q <= k_vld;
  end

  always_ff @(posedge clk) begin
    y_q     <= 32'(k_y);
    flags_q <= {k_fre.sat_pos, k_fre.sat_neg, k_fim.sat_pos, k_fim.sat_neg} |
               {3'd0, k_ovf};
    acc_q   <= 64'(k_acc_re) ^ 64'(k_acc_im);
  end

  assign vld_out = vout_q;
  assign y_out   = y_q;
  assign flags   = flags_q;
  assign acc_out = acc_q;

endmodule : bf_dot_wrap

`default_nettype wire
