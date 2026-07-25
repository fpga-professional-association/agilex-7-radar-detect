// -----------------------------------------------------------------------------
// reg_block_scratch — software scratch registers (SPEC.md 9, issue #7).
//
// Window 0x4000. Four registers with no hardware effect whatsoever. They exist
// to test the fabric and the CSR engine against something with no other
// behaviour to confound the result:
//
//   SCRATCH0..2  plain 32-bit read-write, with three different reset values, so
//                a reset-default sweep can tell "reset works" from "the register
//                happens to be zero".
//   SCRATCH3     half writable, half constant. Its write must succeed (the
//                register is partially writable) and must leave RO_HIGH alone.
//                Partial writability is the case a generated mask gets wrong,
//                and this is the register that catches it.
//
// Byte-enable behaviour, walking ones and walking zeros are all exercised here
// by sim/tests/test_control_regs.cpp for the same reason: nothing else in this
// window can mask a defect.
// -----------------------------------------------------------------------------

`default_nettype none

module reg_block_scratch
  import reg_if_pkg::*;
  import regmap_pkg::*;
#(
    parameter int unsigned IDX_W = REGMAP_WINDOW_W - 2
) (
    input  wire                                 clk,
    input  wire                                 rst_n,

    input  wire                                 sel,
    input  wire                                 write_enable,
    input  wire                                 read_enable,
    input  wire [IDX_W-1:0]                     index,
    input  wire [REG_DATA_W-1:0]                write_data,
    input  wire [REG_STRB_W-1:0]                byte_enable,

    output wire [REG_DATA_W-1:0]                read_data,
    output wire                                 ready,
    output wire                                 error,

    // Storage, observable without going through the read mux.
    output wire [REGMAP_SCRATCH_N_REGS*32-1:0]  csr,
    output wire [REGMAP_SCRATCH_N_REGS*32-1:0]  pulse
);

  reg_csr_block #(
      .N_REGS     (REGMAP_SCRATCH_N_REGS),
      .IDX_W      (IDX_W),
      .RESET_VAL  (REGMAP_SCRATCH_RESET),
      .WMASK      (REGMAP_SCRATCH_WMASK),
      .W1C_MASK   (REGMAP_SCRATCH_W1CMASK),
      .PULSE_MASK (REGMAP_SCRATCH_PULSEMASK),
      .HW_MASK    (REGMAP_SCRATCH_HWMASK)
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
      .hw_value     ('0),
      .hw_set       ('0),
      .csr          (csr),
      .pulse        (pulse)
  );

endmodule : reg_block_scratch

`default_nettype wire
