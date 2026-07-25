// -----------------------------------------------------------------------------
// reg_block_fault — fault injection (SPEC.md 9 and 24, issue #7).
//
// Window 0x3000. Two-step injection: FAULT_ENABLE arms a fault type and holds;
// FAULT_INJECT triggers it once. A trigger for a bit that is not armed does
// nothing at all — no pulse, no status, no count. Two steps rather than one
// because a single stray write must not be able to inject a fault into a running
// benchmark, and because the arming state survives the event and is therefore
// visible in a register dump taken afterwards.
//
// Every injected pulse is recorded twice: once as a sticky W1C bit in
// FAULT_STATUS, so software sees what happened even if it was not watching, and
// once in the saturating FAULT_COUNT, so repeated injection is distinguishable
// from a single event. The W1C set path is `hw_set`, and in the CSR engine a
// hardware set beats a software clear in the same cycle — an event is never lost
// to a racing clear.
//
// The `fault_inject` output is the injection interface for the rest of the
// design: one cfg_clk cycle per armed, triggered fault type. Consumers arrive
// with the blocks they perturb (streams #5/#6, FIFOs #6, packet #18, numerics
// #4); until then the pulses terminate in control_top, where the tests observe
// them and prove the gating, the pulse width and the counting.
// -----------------------------------------------------------------------------

`default_nettype none

module reg_block_fault
  import reg_if_pkg::*;
  import regmap_pkg::*;
#(
    parameter int unsigned IDX_W = REGMAP_WINDOW_W - 2
) (
    input  wire                               clk,
    input  wire                               rst_n,

    input  wire                               sel,
    input  wire                               write_enable,
    input  wire                               read_enable,
    input  wire [IDX_W-1:0]                   index,
    input  wire [REG_DATA_W-1:0]              write_data,
    input  wire [REG_STRB_W-1:0]              byte_enable,

    output wire [REG_DATA_W-1:0]              read_data,
    output wire                               ready,
    output wire                               error,

    output wire [REGMAP_FAULT_N_REGS*32-1:0]  csr,
    output wire [REGMAP_FAULT_N_REGS*32-1:0]  pulse,

    // One cycle per armed, triggered fault type. Bit assignment is FAULT_ENABLE's.
    output wire [31:0]                        fault_inject
);

  localparam int unsigned N = REGMAP_FAULT_N_REGS;

  wire [N*32-1:0] csr_w;
  wire [N*32-1:0] pulse_w;

  wire [31:0] arm_word     = csr_w  [REGMAP_FAULT_FAULT_ENABLE_INDEX * 32 +: 32];
  wire [31:0] trigger_word = pulse_w[REGMAP_FAULT_FAULT_INJECT_INDEX * 32 +: 32];

  // Arming gates the trigger. This is the only place the two meet.
  wire [31:0] injected = trigger_word & arm_word;

  // ---- saturating injection counter --------------------------------------
  logic [31:0] count_q;
  wire  [31:0] increment = 32'($countones(injected));

  always_ff @(posedge clk) begin
    if (!rst_n) begin
      count_q <= 32'd0;
    end else if (|injected) begin
      // Saturate rather than wrap: a dump taken long after the run must not
      // report a small number because the counter went round.
      count_q <= (count_q > (32'hFFFFFFFF - increment)) ? 32'hFFFFFFFF
                                                        : (count_q + increment);
    end
  end

  // ---- hardware paths into the register file -----------------------------
  logic [N*32-1:0] hw_value;
  logic [N*32-1:0] hw_set;
  always_comb begin
    hw_value = '0;
    hw_value[REGMAP_FAULT_FAULT_COUNT_INDEX * 32 +: 32] = count_q;
    hw_set   = '0;
    hw_set[REGMAP_FAULT_FAULT_STATUS_INDEX * 32 +: 32] = injected;
  end

  assign csr          = csr_w;
  assign pulse        = pulse_w;
  assign fault_inject = injected;

  reg_csr_block #(
      .N_REGS     (N),
      .IDX_W      (IDX_W),
      .RESET_VAL  (REGMAP_FAULT_RESET),
      .WMASK      (REGMAP_FAULT_WMASK),
      .W1C_MASK   (REGMAP_FAULT_W1CMASK),
      .PULSE_MASK (REGMAP_FAULT_PULSEMASK),
      .HW_MASK    (REGMAP_FAULT_HWMASK)
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
      .hw_set       (hw_set),
      .csr          (csr_w),
      .pulse        (pulse_w)
  );

endmodule : reg_block_fault

`default_nettype wire
