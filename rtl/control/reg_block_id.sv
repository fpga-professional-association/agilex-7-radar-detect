// -----------------------------------------------------------------------------
// reg_block_id — global identification block (SPEC.md 9, issue #7).
//
// Window 0x0000. Four constants: MAGIC, VERSION, GEOMETRY and CAPABILITY, all
// folded in at elaboration from rtl/control/generated/regmap_pkg.sv, which
// scripts/gen_regmap.py derives from control/regmap.json.
//
// Every value is static build data. VERSION in particular is NOT a git describe:
// the generated artefacts must be a pure function of the source tree, or the
// regeneration check (`make regmap-check`) would fail on a clean checkout with a
// different VCS state, and two people building the same commit would get
// different register contents. The register-map version is bumped by hand in the
// source of truth, which is also the only place a reviewer would look for it.
//
// The block is nothing but the shared CSR engine with a table whose writable
// masks are all zero, so every write to this window answers error=1 with no side
// effect — a property of the table, not of code written here.
// -----------------------------------------------------------------------------

`default_nettype none

module reg_block_id
  import reg_if_pkg::*;
  import regmap_pkg::*;
#(
    parameter int unsigned IDX_W = REGMAP_WINDOW_W - 2
) (
    input  wire                            clk,
    input  wire                            rst_n,

    input  wire                            sel,
    input  wire                            write_enable,
    input  wire                            read_enable,
    input  wire [IDX_W-1:0]                index,
    input  wire [REG_DATA_W-1:0]           write_data,
    input  wire [REG_STRB_W-1:0]           byte_enable,

    output wire [REG_DATA_W-1:0]           read_data,
    output wire                            ready,
    output wire                            error,

    // Live register contents, for observation. Nothing in the design consumes
    // an identification constant, but exporting the storage gives a test a view
    // of the register file that does not go through the read mux, which is the
    // only way to tell "the reset value is wrong" from "the read path is wrong".
    output wire [REGMAP_ID_N_REGS*32-1:0]  csr,
    output wire [REGMAP_ID_N_REGS*32-1:0]  pulse
);

  reg_csr_block #(
      .N_REGS     (REGMAP_ID_N_REGS),
      .IDX_W      (IDX_W),
      .RESET_VAL  (REGMAP_ID_RESET),
      .WMASK      (REGMAP_ID_WMASK),
      .W1C_MASK   (REGMAP_ID_W1CMASK),
      .PULSE_MASK (REGMAP_ID_PULSEMASK),
      .HW_MASK    (REGMAP_ID_HWMASK)
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

endmodule : reg_block_id

`default_nettype wire
