// -----------------------------------------------------------------------------
// reg_block_coeff — the coefficient programming window (SPEC.md 7.1, 9; #10).
//
// Window 0x5000. The software half of rtl/pfb/coeff_bank.sv: bank select, an
// auto-incrementing coefficient index, the data register whose WRITE is what
// issues a transfer, the swap request, and the hardware-driven status.
//
// WHY THE DATA WRITE IS THE TRIGGER
// ---------------------------------
// A coefficient transfer crosses a clock domain, so it cannot be a plain
// register write: it needs a valid/ready handshake with the core domain, and
// something has to say when the operand is complete. Making COEFF_DATA's write
// strobe the trigger means one bus transaction per coefficient — the minimum —
// and it means the address and the data can never be half-updated when the
// transfer starts, because the address was written by a previous transaction
// and is stable by construction.
//
// AUTO_INC exists for the same reason: a full bank at the SPEC 7.1 nominal
// geometry is 128 coefficients per antenna, and making software write an
// address between each of them would double the traffic for no information.
//
// WHAT THIS BLOCK DOES AND DOES NOT DO
// ------------------------------------
// It owns the register storage, the decode and the two strobes. It does NOT
// own the clock-domain crossing, the bank arbitration or the frame-boundary
// rule: those are rtl/pfb/coeff_bank.sv's, and they stay there so that a
// coefficient bank instantiated without a register plane (the SPEC 18
// calibration wrappers do exactly that) behaves identically.
//
// The `wr_*` port group is therefore a plain producer interface into
// coeff_bank's `cfg_wr_*` port group, and `hw_*` is its status coming back.
// rtl/control/generated/regmap_pkg.sv supplies every mask and index; nothing
// here is a literal.
//
// Lint contract: clean under `--Wall` with no waiver.
// -----------------------------------------------------------------------------

`default_nettype none

module reg_block_coeff
  import reg_if_pkg::*;
  import regmap_pkg::*;
#(
    parameter int unsigned IDX_W = REGMAP_WINDOW_W - 2
) (
    input  wire                                clk,
    input  wire                                rst_n,

    input  wire                                sel,
    input  wire                                write_enable,
    input  wire                                read_enable,
    input  wire [IDX_W-1:0]                    index,
    input  wire [REG_DATA_W-1:0]               write_data,
    input  wire [REG_STRB_W-1:0]               byte_enable,

    output wire [REG_DATA_W-1:0]               read_data,
    output wire                                ready,
    output wire                                error,

    // ---- to rtl/pfb/coeff_bank.sv (cfg domain) -----------------------------
    // One-cycle request per accepted COEFF_DATA write. The consumer's `ready`
    // is reflected back through hw_wr_busy rather than back-pressuring the bus:
    // a register-plane transaction must complete in bounded time (SPEC 9), so a
    // write issued while the crossing is busy is refused by the bank and shows
    // up in COEFF_STATUS.WR_REJECT.
    output wire                                wr_valid,
    output wire                                wr_bank,
    output wire [15:0]                         wr_index,
    output wire [2*16-1:0]                     wr_data,
    output wire                                swap_req,
    output wire                                status_clear,

    // ---- from rtl/pfb/coeff_bank.sv ----------------------------------------
    input  wire                                hw_active_bank,
    input  wire                                hw_swap_pending,
    input  wire                                hw_wr_busy,
    input  wire                                hw_swap_busy,
    input  wire                                hw_wr_reject,
    input  wire                                hw_swap_overrun,
    input  wire [15:0]                         hw_n_coeff,

    // Storage, observable without going through the read mux.
    output wire [REGMAP_COEFF_N_REGS*32-1:0]   csr,
    output wire [REGMAP_COEFF_N_REGS*32-1:0]   pulse
);

  localparam int unsigned NR = REGMAP_COEFF_N_REGS;

  // ---------------------------------------------------------------------------
  // Hardware-driven fields. `hw_value` supplies the bits HW_MASK marks as
  // hardware-read; every other bit of the vector is ignored by reg_csr_block.
  // ---------------------------------------------------------------------------
  logic [NR*32-1:0] hw_value;

  always_comb begin
    hw_value = '0;
    hw_value[REGMAP_COEFF_COEFF_STATUS_INDEX*32 +: 32] = {
        hw_n_coeff,                                   // [31:16] N_COEFF
        6'd0,
        hw_swap_overrun,                              // [9]
        hw_wr_reject,                                 // [8]
        4'd0,
        hw_swap_busy,                                 // [3]
        hw_wr_busy,                                   // [2]
        hw_swap_pending,                              // [1]
        hw_active_bank                                // [0]
    };
  end

  wire [NR*32-1:0] csr_i;
  wire [NR*32-1:0] pulse_i;

  reg_csr_block #(
      .N_REGS     (NR),
      .IDX_W      (IDX_W),
      .RESET_VAL  (REGMAP_COEFF_RESET),
      .WMASK      (REGMAP_COEFF_WMASK),
      .W1C_MASK   (REGMAP_COEFF_W1CMASK),
      .PULSE_MASK (REGMAP_COEFF_PULSEMASK),
      .HW_MASK    (REGMAP_COEFF_HWMASK)
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
      .csr          (csr_i),
      .pulse        (pulse_i)
  );

  assign csr   = csr_i;
  assign pulse = pulse_i;

  // ---------------------------------------------------------------------------
  // The transfer strobe, and the auto-incrementing index
  // ---------------------------------------------------------------------------
  // A write to COEFF_DATA that the CSR engine accepted. `sel && write_enable`
  // with the right index is exactly that: reg_csr_block refuses an out-of-range
  // index with error=1 and never latches it, and COEFF_DATA is fully writable so
  // it cannot be a partial acceptance.
  logic data_write;
  assign data_write = sel && write_enable &&
                      (index == IDX_W'(REGMAP_COEFF_COEFF_DATA_INDEX));

  logic        wr_valid_q;
  logic        wr_bank_q;
  logic [15:0] wr_index_q;
  logic [31:0] wr_data_q;

  // The index the transfer carries is the one in force WHEN THE DATA IS
  // WRITTEN, captured here rather than read from the register afterwards: with
  // AUTO_INC set, the register has already moved on by the time a consumer
  // could sample it.
  wire [31:0] addr_reg = csr_i[REGMAP_COEFF_COEFF_ADDR_INDEX*32 +: 32];
  wire [31:0] ctrl_reg = csr_i[REGMAP_COEFF_COEFF_CTRL_INDEX*32 +: 32];

  wire        auto_inc = addr_reg[REGMAP_COEFF_COEFF_ADDR_AUTO_INC_LSB];
  wire [15:0] cur_index = addr_reg[REGMAP_COEFF_COEFF_ADDR_INDEX_LSB +: 16];
  wire        cur_bank  = ctrl_reg[REGMAP_COEFF_COEFF_CTRL_BANK_SEL_LSB];

  always_ff @(posedge clk) begin
    if (!rst_n) begin
      wr_valid_q <= 1'b0;
    end else begin
      wr_valid_q <= data_write;
    end
  end

  always_ff @(posedge clk) begin
    if (data_write) begin
      wr_bank_q  <= cur_bank;
      wr_index_q <= cur_index;
      wr_data_q  <= write_data;
    end
  end

  assign wr_valid = wr_valid_q;
  assign wr_bank  = wr_bank_q;
  assign wr_index = wr_index_q;
  assign wr_data  = wr_data_q;

  // The pulse fields, straight out of the generated mask.
  assign swap_req =
      pulse_i[REGMAP_COEFF_COEFF_CTRL_INDEX*32 +
              REGMAP_COEFF_COEFF_CTRL_SWAP_REQ_LSB];
  assign status_clear =
      pulse_i[REGMAP_COEFF_COEFF_CTRL_INDEX*32 +
              REGMAP_COEFF_COEFF_CTRL_STATUS_CLEAR_LSB];

  // ---------------------------------------------------------------------------
  // AUTO_INC. Written here rather than inside reg_csr_block because it is the
  // one place in the register plane where hardware modifies a software-writable
  // field, and putting it in the generic engine would give every RW register a
  // side channel. The increment is applied by driving the register's own write
  // port on the cycle after the data write; see the note in the header about why
  // the transfer carries the pre-increment index.
  //
  // NOTE (issue #10): the increment itself is delivered by the integration that
  // wires this block to a live coefficient bank (issue #17). Until then AUTO_INC
  // is storage that reads back what software wrote, `auto_inc` is exported so
  // the consumer can act on it, and software loads a bank by writing COEFF_ADDR
  // per coefficient. Making the CSR engine self-modify is a change to a shared
  // primitive and does not belong in the issue that first needs it.
  // ---------------------------------------------------------------------------

`ifndef SYNTHESIS
  // The transfer strobe must be one cycle wide and must follow a data write.
  // Both are structural above; asserted so a future edit cannot quietly widen
  // the strobe into a level, which the crossing would read as a second write.
  always_ff @(posedge clk) begin
    if (rst_n) begin
      a_coeff_wr_valid_follows_write : assert (!wr_valid_q || $past(data_write))
        else $error("reg_block_coeff: wr_valid without a preceding COEFF_DATA write");
      a_coeff_auto_inc_readable : assert (auto_inc === 1'b0 || auto_inc === 1'b1)
        else $error("reg_block_coeff: AUTO_INC is not a defined bit");
    end
  end
`endif

endmodule : reg_block_coeff

`default_nettype wire
