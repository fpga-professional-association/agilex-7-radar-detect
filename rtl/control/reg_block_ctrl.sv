// -----------------------------------------------------------------------------
// reg_block_ctrl — per-block enable and soft reset (SPEC.md 9, issue #7).
//
// Window 0x2000. BLOCK_ENABLE is plain storage whose bits leave the block as
// `block_enable`; BLOCK_RESET and the GLOBAL_CTRL pulse bits leave as one-cycle
// pulses. Nothing downstream exists yet — the kernels land with issues #10-#15 —
// so today those outputs terminate at sim/verilator/tops/control_top.sv, where
// the tests observe them. The bit assignment is fixed now precisely so that each
// kernel can claim its bit later without renumbering anything.
//
// Domain seam. Everything here is cfg_clk. Distribution of an enable or a reset
// pulse into core_clk, packet_clk or telemetry_clk is a clock-domain crossing
// and belongs to the issue #6 primitives — a level for the enables, a
// toggle/handshake synchroniser for the pulses (SPEC 8). This block deliberately
// stops at the domain boundary rather than inventing a crossing here; the pulse
// outputs are one cfg_clk cycle wide, which is exactly what a toggle
// synchroniser wants at its input.
//
// CTRL_STATUS.ENABLED_COUNT is computed from the live BLOCK_ENABLE value rather
// than mirrored from storage, so the hardware read path (HW_MASK) is exercised
// by a value that changes with software writes.
// -----------------------------------------------------------------------------

`default_nettype none

module reg_block_ctrl
  import reg_if_pkg::*;
  import regmap_pkg::*;
#(
    parameter int unsigned IDX_W = REGMAP_WINDOW_W - 2
) (
    input  wire                              clk,
    input  wire                              rst_n,

    input  wire                              sel,
    input  wire                              write_enable,
    input  wire                              read_enable,
    input  wire [IDX_W-1:0]                  index,
    input  wire [REG_DATA_W-1:0]             write_data,
    input  wire [REG_STRB_W-1:0]             byte_enable,

    output wire [REG_DATA_W-1:0]             read_data,
    output wire                              ready,
    output wire                              error,

    output wire [REGMAP_CTRL_N_REGS*32-1:0]  csr,
    output wire [REGMAP_CTRL_N_REGS*32-1:0]  pulse,

    // ---- control outputs, cfg_clk domain ----
    output wire [31:0]                       block_enable,       // level
    output wire [31:0]                       block_reset_pulse,  // one cycle
    output wire                              global_enable,      // level
    output wire                              flush_pulse,        // one cycle
    output wire                              soft_reset_pulse    // one cycle
);

  localparam int unsigned N = REGMAP_CTRL_N_REGS;

  wire [N*32-1:0] csr_w;
  wire [N*32-1:0] pulse_w;

  wire [31:0] enable_word = csr_w  [REGMAP_CTRL_BLOCK_ENABLE_INDEX * 32 +: 32];
  wire [31:0] reset_word  = pulse_w[REGMAP_CTRL_BLOCK_RESET_INDEX  * 32 +: 32];
  wire [31:0] global_word = csr_w  [REGMAP_CTRL_GLOBAL_CTRL_INDEX  * 32 +: 32];
  wire [31:0] global_puls = pulse_w[REGMAP_CTRL_GLOBAL_CTRL_INDEX  * 32 +: 32];

  // ---- hardware-driven status --------------------------------------------
  logic [N*32-1:0] hw_value;
  always_comb begin
    hw_value = '0;
    hw_value[REGMAP_CTRL_CTRL_STATUS_INDEX * 32 + REGMAP_CTRL_CTRL_STATUS_ENABLED_COUNT_LSB
             +: REGMAP_CTRL_CTRL_STATUS_ENABLED_COUNT_WIDTH] =
        REGMAP_CTRL_CTRL_STATUS_ENABLED_COUNT_WIDTH'($countones(enable_word));
    hw_value[REGMAP_CTRL_CTRL_STATUS_INDEX * 32 + REGMAP_CTRL_CTRL_STATUS_ALIVE_LSB] = 1'b1;
  end

  assign csr               = csr_w;
  assign pulse             = pulse_w;
  assign block_enable      = enable_word;
  assign block_reset_pulse = reset_word;
  assign global_enable     = global_word[REGMAP_CTRL_GLOBAL_CTRL_GLOBAL_ENABLE_LSB];
  assign flush_pulse       = global_puls[REGMAP_CTRL_GLOBAL_CTRL_FLUSH_LSB];
  assign soft_reset_pulse  = global_puls[REGMAP_CTRL_GLOBAL_CTRL_SOFT_RESET_LSB];

  reg_csr_block #(
      .N_REGS     (N),
      .IDX_W      (IDX_W),
      .RESET_VAL  (REGMAP_CTRL_RESET),
      .WMASK      (REGMAP_CTRL_WMASK),
      .W1C_MASK   (REGMAP_CTRL_W1CMASK),
      .PULSE_MASK (REGMAP_CTRL_PULSEMASK),
      .HW_MASK    (REGMAP_CTRL_HWMASK)
  ) u_csr (
      .clk          (clk),
      .rst_n        (rst_n),
      .sel          (sel),
      .write_enable (write_enable),
      .read_enable  (read_enable),
      .index        (index),
      .write_data   (write_data),
      .byte_enable  (byte_enable),
      .read_data    (read_data),
      .ready        (ready),
      .error        (error),
      .hw_value     (hw_value),
      .hw_set       ('0),
      .csr          (csr_w),
      .pulse        (pulse_w)
  );

endmodule : reg_block_ctrl

`default_nettype wire
