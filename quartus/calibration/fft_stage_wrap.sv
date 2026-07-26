// -----------------------------------------------------------------------------
// fft_stage_wrap — synthesis wrapper for the SPEC 18 FFT-stage calibration
// (issue #11, SPEC 18 item 4: "One FFT stage").
//
// Wraps ONE rtl/fft/fft_radix22_stage.sv — two delay-feedback butterflies, a
// twiddle ROM and a complex_multiplier — in boundary registers, so the sweep
// measures a genuine register-to-register fabric path rather than the I/O
// budget. Same arrangement, and the same reasoning, as
// quartus/calibration/cmult_wrap.sv:
//
//     virtual pin -> in_q -> [ fft_radix22_stage ] -> out_q -> virtual pin
//                    \_________ measured reg-to-reg _________/
//
// One radix-2^2 stage is the right unit for this measurement because it is the
// SMALLEST piece of the FFT that contains all four cost classes at once:
// delay-feedback memory (two lines, M/2 and M/4 words), a twiddle ROM, a
// DSP-mapped complex multiply, and the fixed-point quantisation network. A
// measurement of a butterfly alone would price none of the memory questions, and
// a measurement of the whole FFT (fft_core_wrap) cannot separate them.
//
// The default parameters are the FIRST group of a 64-point / 2-samples-per-cycle
// lane: N_LANE = 5, S = 0, so DELAY_A = 16, DELAY_B = 8 and the twiddle ROM has
// L = 32 entries. That is the group with the largest memories in the shipped
// configuration, which is the one whose mapping the calibration has to answer.
//
// Integer parameters only. VARIANT_SEL, MEM_SEL and TW_SEL are integers rather
// than the modules' string parameters, because the sweep sets parameters with
// Quartus's `set_parameter`, whose handling of string values is not something a
// benchmark should depend on. The mapping to the strings is one conditional
// localparam below, in RTL, where the same elaboration assertions every other
// instantiation gets apply to it.
//
// Ports are sized independently of the parameters — the position tag is a fixed
// 16 bits and is sliced inside — so that the virtual-pin assignments in
// fft_stage_calib.qsf name the same pins at every point of the sweep.
//
// Listed in sim/verilator/files_fft.f so `make lint` covers it: RTL that no lint
// ever sees is RTL that rots, and a Quartus compile depends on this file.
// -----------------------------------------------------------------------------

`default_nettype none

module fft_stage_wrap
  import fxp_pkg::*;
#(
    // Sub-stages in the lane this group belongs to, and the group's BF2I index.
    parameter int unsigned N_LANE      = 5,
    parameter int unsigned S           = 0,

    // Scaling schedule bits for the two butterflies.
    parameter int unsigned SHIFT_A     = 1,
    parameter int unsigned SHIFT_B     = 1,

    // 1: the group ends with a twiddle multiplier (the usual case).
    parameter int unsigned HAS_TWIDDLE = 1,

    // 0 = complex_multiplier "MULT4", 1 = "MULT3".
    parameter int unsigned VARIANT_SEL = 0,
    parameter int unsigned TW_PIPE     = 4,
    parameter int unsigned TW_ROM_OUT_REG = 1,

    // 0 = AUTO (no attribute, the tool chooses), 1 = M20K, 2 = MLAB,
    // 3 = LOGIC, 4 = DEFAULT (the project rule measured by this sweep;
    // see fft_pkg "Delay-feedback placement"). Delay feedback / twiddle ROM.
    parameter int unsigned MEM_SEL     = 0,
    parameter int unsigned TW_SEL      = 0
) (
    input  wire        clk,
    input  wire        rst_n,

    input  wire        vld_in,
    input  wire [15:0] din_re,
    input  wire [15:0] din_im,
    input  wire [15:0] idx_in,
    input  wire        warm_in,

    output wire        vld_out,
    output wire [15:0] dout_re,
    output wire [15:0] dout_im,
    output wire [15:0] idx_out,
    output wire        warm_out,
    output wire [5:0]  flags
);

  localparam string VARIANT = (VARIANT_SEL == 1) ? "MULT3" : "MULT4";
  localparam string MEM_STYLE =
      (MEM_SEL == 1) ? "M20K" : (MEM_SEL == 2) ? "MLAB" :
      (MEM_SEL == 3) ? "LOGIC" : (MEM_SEL == 4) ? "DEFAULT" : "AUTO";
  localparam string TW_STYLE =
      (TW_SEL == 1) ? "M20K" : (TW_SEL == 2) ? "MLAB" :
      (TW_SEL == 3) ? "LOGIC" : "AUTO";

  // ---------------------------------------------------------------------------
  // Boundary input registers
  //
  // The datapath registers are free-running and unreset, matching the kernel's
  // own policy (SPEC 23: reset validity, not every datapath bit). Only the beat
  // valid is reset, so the reset network the Fitter sees is the one the real
  // design has rather than a wide synchronous clear that would distort both the
  // ALM count and the retiming result.
  // ---------------------------------------------------------------------------
  logic              vin_q, warm_q;
  fxp_complex_t      din_q;
  logic [N_LANE-1:0] idx_q;

  always_ff @(posedge clk) begin
    if (!rst_n) begin
      vin_q  <= 1'b0;
      warm_q <= 1'b0;
    end else begin
      vin_q  <= vld_in;
      warm_q <= warm_in;
    end
  end

  always_ff @(posedge clk) begin
    din_q <= '{re: fxp16_t'(din_re), im: fxp16_t'(din_im)};
    idx_q <= idx_in[N_LANE-1:0];
  end

  // ---------------------------------------------------------------------------
  // The kernel under calibration. The instance MUST be named u_kernel:
  // quartus/scripts/calibrate.tcl extracts the per-entity utilisation row and
  // decides whether the critical path is inside the kernel by that name.
  // ---------------------------------------------------------------------------
  logic              k_vld, k_warm;
  fxp_complex_t      k_dout;
  logic [N_LANE-1:0] k_idx;
  fxp_flags_t        k_fa, k_fb, k_ftw;
  logic              k_va, k_vb, k_vtw;

  fft_radix22_stage #(
      .IDX_W          (N_LANE),
      .N_LANE         (N_LANE),
      .S              (S),
      .SHIFT_A        (SHIFT_A),
      .SHIFT_B        (SHIFT_B),
      .HAS_TWIDDLE    (HAS_TWIDDLE),
      .TW_VARIANT     (VARIANT),
      .TW_PIPE        (TW_PIPE),
      .TW_ROM_OUT_REG (TW_ROM_OUT_REG),
      .MEM_STYLE      (MEM_STYLE),
      .TW_STYLE       (TW_STYLE)
  ) u_kernel (
      .clk            (clk),
      .rst_n          (rst_n),
      .vld_in         (vin_q),
      .din            (din_q),
      .idx_in         (idx_q),
      .warm_in        (warm_q),
      .vld_out        (k_vld),
      .dout           (k_dout),
      .idx_out        (k_idx),
      .warm_out       (k_warm),
      .flags_a        (k_fa),
      .flags_a_valid  (k_va),
      .flags_b        (k_fb),
      .flags_b_valid  (k_vb),
      .flags_tw       (k_ftw),
      .flags_tw_valid (k_vtw)
  );

  // ---------------------------------------------------------------------------
  // Boundary output registers
  //
  // EVERY output is registered and driven out. Nothing is tied off or folded
  // into a reduction tree: SPEC 24 forbids "constant-driving unused inputs so
  // large blocks optimize away", and a reduction tree would add ALMs that are
  // not the kernel's.
  // ---------------------------------------------------------------------------
  logic              vout_q, warmout_q;
  fxp_complex_t      dout_q;
  logic [N_LANE-1:0] idxout_q;
  logic [5:0]        flags_q;

  always_ff @(posedge clk) begin
    if (!rst_n) vout_q <= 1'b0;
    else        vout_q <= k_vld;
  end

  always_ff @(posedge clk) begin
    dout_q    <= k_dout;
    idxout_q  <= k_idx;
    warmout_q <= k_warm;
    flags_q   <= {k_vtw ? k_ftw : 2'b00,
                  k_vb  ? k_fb  : 2'b00,
                  k_va  ? k_fa  : 2'b00};
  end

  assign vld_out  = vout_q;
  assign dout_re  = dout_q.re;
  assign dout_im  = dout_q.im;
  assign idx_out  = 16'(idxout_q);
  assign warm_out = warmout_q;
  assign flags    = flags_q;

endmodule : fft_stage_wrap

`default_nettype wire
