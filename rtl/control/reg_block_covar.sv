// -----------------------------------------------------------------------------
// reg_block_covar — the integration-settings window (SPEC.md 7.6, 9; issue #13).
//
// Window 0x9000. The software half of rtl/covariance/: the programmable window
// length, the exponential-averaging mode and shift, the per-pair enable mask,
// the pair table, the deterministic flush, and the accumulator-protection
// status coming back the other way.
//
// This is the SPEC 9 register group "Integration settings", which until now was
// only DECLARED (claimed by the planned CFAR window) and implemented nowhere.
//
// WHAT THIS BLOCK DOES AND DOES NOT DO
// ------------------------------------
// It owns the register storage, the decode, and the two strobes — the FLUSH
// pulse and the pair-table WRITE pulse. It does NOT own the window semantics:
// "configuration takes effect at a window boundary and never mid-window" is
// rtl/covariance/integrator.sv's rule and stays there, so a covariance engine
// instantiated without a register plane — which is exactly what
// sim/verilator/tops/covar_top.sv and the SPEC 18 calibration wrappers do —
// behaves identically. The `cfg_*` port group is therefore a plain
// configuration bus into the engine's own cfg_* ports, and `hw_*` is its status
// coming back.
//
// The PAIR TABLE is a programming port rather than N registers, for the reason
// the coefficient window is one (rtl/control/reg_block_coeff.sv): a table sized
// by N_PAIRS would make the register map depend on an elaboration parameter,
// and the map is a fixed, generated, machine-readable artefact. One write per
// entry — INDEX, X_SEL, Y_SEL, then WRITE — costs two bus transactions per pair
// at configuration time and nothing at all at run time.
//
// rtl/control/generated/regmap_pkg.sv supplies every mask and index; nothing
// here is a literal. The reset values the generator computed are additionally
// checked against rtl/packages/covar_pkg.sv at elaboration, so the register
// map and the RTL cannot drift apart silently.
//
// Lint contract: clean under `--Wall` with no waiver.
// -----------------------------------------------------------------------------

`default_nettype none

module reg_block_covar
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

    // ---- to rtl/covariance/ (core domain) ----------------------------------
    output wire                                cfg_enable,
    output wire                                cfg_mode,       // covar_pkg::covar_mode_e
    output wire [3:0]                          cfg_exp_k,
    output wire [15:0]                         cfg_window_len,
    output wire [31:0]                         cfg_pair_enable,
    output wire                                cfg_flush,      // one-cycle pulse
    output wire                                cfg_sat_clear,  // one-cycle pulse

    // Pair-table programming strobe. One-cycle request per accepted
    // COVAR_PAIR_TABLE write whose WRITE bit was set.
    output wire                                pt_wr_valid,
    output wire [7:0]                          pt_wr_index,
    output wire [7:0]                          pt_wr_x,
    output wire [7:0]                          pt_wr_y,

    // ---- from rtl/covariance/ ----------------------------------------------
    input  wire [15:0]                         hw_window_id,
    input  wire [7:0]                          hw_n_pairs,
    input  wire [7:0]                          hw_acc_w,
    input  wire                                hw_sat_power,
    input  wire                                hw_sat_cross,
    input  wire                                hw_truncated,
    input  wire [31:0]                         hw_sat_count,

    // Storage, observable without going through the read mux.
    output wire [REGMAP_COVAR_N_REGS*32-1:0]   csr,
    output wire [REGMAP_COVAR_N_REGS*32-1:0]   pulse
);

  localparam int unsigned NR = REGMAP_COVAR_N_REGS;

  // ---------------------------------------------------------------------------
  // Hardware-driven fields and the W1C set inputs
  // ---------------------------------------------------------------------------
  logic [NR*32-1:0] hw_value;
  logic [NR*32-1:0] hw_set;

  always_comb begin
    hw_value = '0;
    hw_value[REGMAP_COVAR_COVAR_STATUS_INDEX*32 +: 32] = {
        hw_acc_w,        // [31:24] ACC_W
        hw_n_pairs,      // [23:16] N_PAIRS
        hw_window_id     // [15:0]  WINDOW_ID
    };
    hw_value[REGMAP_COVAR_COVAR_SAT_COUNT_INDEX*32 +: 32] = hw_sat_count;

    // Sticky saturation. Hardware sets, software clears by writing 1
    // (reg_csr_block resolves a simultaneous set and clear in favour of the
    // set, which is what stops a read-then-clear from losing an event).
    hw_set = '0;
    hw_set[REGMAP_COVAR_COVAR_SAT_STATUS_INDEX*32 +
           REGMAP_COVAR_COVAR_SAT_STATUS_POWER_LSB]     = hw_sat_power;
    hw_set[REGMAP_COVAR_COVAR_SAT_STATUS_INDEX*32 +
           REGMAP_COVAR_COVAR_SAT_STATUS_CROSS_LSB]     = hw_sat_cross;
    hw_set[REGMAP_COVAR_COVAR_SAT_STATUS_INDEX*32 +
           REGMAP_COVAR_COVAR_SAT_STATUS_TRUNCATED_LSB] = hw_truncated;
  end

  wire [NR*32-1:0] csr_i;
  wire [NR*32-1:0] pulse_i;

  reg_csr_block #(
      .N_REGS     (NR),
      .IDX_W      (IDX_W),
      .RESET_VAL  (REGMAP_COVAR_RESET),
      .WMASK      (REGMAP_COVAR_WMASK),
      .W1C_MASK   (REGMAP_COVAR_W1CMASK),
      .PULSE_MASK (REGMAP_COVAR_PULSEMASK),
      .HW_MASK    (REGMAP_COVAR_HWMASK)
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
      .csr          (csr_i),
      .pulse        (pulse_i)
  );

  assign csr   = csr_i;
  assign pulse = pulse_i;

  // ---------------------------------------------------------------------------
  // Field extraction. Every offset comes from the generated map.
  // ---------------------------------------------------------------------------
  wire [31:0] ctrl_q  = csr_i[REGMAP_COVAR_COVAR_CTRL_INDEX*32 +: 32];
  wire [31:0] ctrl_p  = pulse_i[REGMAP_COVAR_COVAR_CTRL_INDEX*32 +: 32];
  wire [31:0] pen_q   = csr_i[REGMAP_COVAR_COVAR_PAIR_ENABLE_INDEX*32 +: 32];
  wire [31:0] pt_p    = pulse_i[REGMAP_COVAR_COVAR_PAIR_TABLE_INDEX*32 +: 32];

  // Field slices are taken straight out of the flat storage rather than through
  // a whole-register wire, so no bit of a partially populated register is
  // declared and left unread.
  localparam int unsigned WIN_BIT = REGMAP_COVAR_COVAR_WINDOW_INDEX*32 +
                                    REGMAP_COVAR_COVAR_WINDOW_LENGTH_LSB;
  localparam int unsigned PT_BIT  = REGMAP_COVAR_COVAR_PAIR_TABLE_INDEX*32;

  assign cfg_enable = ctrl_q[REGMAP_COVAR_COVAR_CTRL_ENABLE_LSB];
  assign cfg_mode   = ctrl_q[REGMAP_COVAR_COVAR_CTRL_EXP_MODE_LSB];
  assign cfg_exp_k  = ctrl_q[REGMAP_COVAR_COVAR_CTRL_EXP_K_LSB +:
                             REGMAP_COVAR_COVAR_CTRL_EXP_K_WIDTH];

  assign cfg_flush     = ctrl_p[REGMAP_COVAR_COVAR_CTRL_FLUSH_LSB];
  assign cfg_sat_clear = ctrl_p[REGMAP_COVAR_COVAR_CTRL_SAT_CLEAR_LSB];

  assign cfg_window_len  = csr_i[WIN_BIT +: REGMAP_COVAR_COVAR_WINDOW_LENGTH_WIDTH];
  assign cfg_pair_enable = pen_q;

  assign pt_wr_valid = pt_p[REGMAP_COVAR_COVAR_PAIR_TABLE_WRITE_LSB];
  assign pt_wr_index = csr_i[PT_BIT + REGMAP_COVAR_COVAR_PAIR_TABLE_INDEX_LSB +:
                             REGMAP_COVAR_COVAR_PAIR_TABLE_INDEX_WIDTH];
  assign pt_wr_x     = csr_i[PT_BIT + REGMAP_COVAR_COVAR_PAIR_TABLE_X_SEL_LSB +:
                             REGMAP_COVAR_COVAR_PAIR_TABLE_X_SEL_WIDTH];
  assign pt_wr_y     = csr_i[PT_BIT + REGMAP_COVAR_COVAR_PAIR_TABLE_Y_SEL_LSB +:
                             REGMAP_COVAR_COVAR_PAIR_TABLE_Y_SEL_WIDTH];

  // ---------------------------------------------------------------------------
  // The generated reset values must agree with the RTL's own defaults. Checked
  // at elaboration rather than by inspection: control/regmap.json and
  // rtl/packages/covar_pkg.sv are two files, and two files drift.
  // ---------------------------------------------------------------------------
`ifndef SYNTHESIS
  initial begin
    if ((REGMAP_COVAR_RESET[REGMAP_COVAR_COVAR_WINDOW_INDEX*32 +: 32] &
         REGMAP_COVAR_COVAR_WINDOW_LENGTH_MASK) !=
        32'(covar_pkg::covar_window_len_default())) begin
      $fatal(1, "reg_block_covar: COVAR_WINDOW.LENGTH resets to %0d but covar_pkg says %0d",
             REGMAP_COVAR_RESET[REGMAP_COVAR_COVAR_WINDOW_INDEX*32 +: 32] &
                 REGMAP_COVAR_COVAR_WINDOW_LENGTH_MASK,
             covar_pkg::covar_window_len_default());
    end
    if (((REGMAP_COVAR_RESET[REGMAP_COVAR_COVAR_CTRL_INDEX*32 +: 32] &
          REGMAP_COVAR_COVAR_CTRL_EXP_K_MASK) >>
         REGMAP_COVAR_COVAR_CTRL_EXP_K_LSB) !=
        32'(covar_pkg::covar_exp_k_default())) begin
      $fatal(1, "reg_block_covar: COVAR_CTRL.EXP_K resets to a value covar_pkg does not agree with");
    end
    if (REGMAP_COVAR_COVAR_PAIR_TABLE_X_SEL_WIDTH !=
        int'(covar_pkg::covar_src_sel_w())) begin
      $fatal(1, "reg_block_covar: PAIR_TABLE.X_SEL is %0d bits but covar_pkg says %0d",
             REGMAP_COVAR_COVAR_PAIR_TABLE_X_SEL_WIDTH,
             int'(covar_pkg::covar_src_sel_w()));
    end
    if (REGMAP_COVAR_COVAR_WINDOW_LENGTH_WIDTH !=
        int'(covar_pkg::COVAR_WINDOW_LEN_W)) begin
      $fatal(1, "reg_block_covar: COVAR_WINDOW.LENGTH is %0d bits but covar_pkg says %0d",
             REGMAP_COVAR_COVAR_WINDOW_LENGTH_WIDTH,
             int'(covar_pkg::COVAR_WINDOW_LEN_W));
    end
    if (REGMAP_COVAR_COVAR_STATUS_WINDOW_ID_WIDTH !=
        int'(covar_pkg::COVAR_WINDOW_ID_W)) begin
      $fatal(1, "reg_block_covar: COVAR_STATUS.WINDOW_ID is %0d bits but covar_pkg says %0d",
             REGMAP_COVAR_COVAR_STATUS_WINDOW_ID_WIDTH,
             int'(covar_pkg::COVAR_WINDOW_ID_W));
    end
    // The geometry echo has to be able to REPORT the accumulator width; a field
    // too narrow to hold POWER_W would report a truncated number that software
    // would then size its buffers from.
    if (int'(covar_pkg::COVAR_POWER_W) >=
        (1 << REGMAP_COVAR_COVAR_STATUS_ACC_W_WIDTH)) begin
      $fatal(1, "reg_block_covar: COVAR_STATUS.ACC_W (%0d bits) cannot report POWER_W=%0d",
             REGMAP_COVAR_COVAR_STATUS_ACC_W_WIDTH, int'(covar_pkg::COVAR_POWER_W));
    end
  end
`endif

endmodule : reg_block_covar

`default_nettype wire
