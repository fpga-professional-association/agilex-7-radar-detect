// -----------------------------------------------------------------------------
// reg_block_cfar — the CFAR settings window (SPEC.md 7.7, 9; issue #14).
//
// Window 0x6000. The software half of rtl/cfar/: the detection mode, the guard
// and reference cell counts on each side, the threshold multiplier, the output
// mode, the sticky fault bits and the detection/suppression/frame counters
// coming back the other way.
//
// This is the SPEC 9 register group "CFAR settings", which until now was only
// DECLARED. The window's second declared group, "Integration settings", was
// implemented by the covariance window at 0x9000 (issue #13 decision 11), so
// this block claims only the first.
//
// WHAT THIS BLOCK DOES AND DOES NOT DO
// ------------------------------------
// It owns the register storage, the decode and the STATUS_CLEAR strobe. It does
// NOT own the configuration semantics: "a write takes effect at a frame boundary
// and only there" is rtl/cfar/cfar_core.sv's rule and stays there, so a detector
// instantiated without a register plane — which is exactly what
// sim/verilator/tops/cfar_top.sv and any future calibration wrapper do — behaves
// identically. The `cfg_*` port group is a plain configuration bus into the
// detector's own cfg_* ports, and `hw_*` is its status coming back.
//
// The GEOMETRY registers are reported by hardware rather than being constants in
// the map, for the reason the coefficient window reports its coefficient count:
// the elaborated maxima are SPEC 11 sizing parameters, and a register map that
// baked them in would be a different map at every configuration.
//
// rtl/control/generated/regmap_pkg.sv supplies every mask and index; nothing
// here is a literal. The reset values the generator computed are additionally
// checked against rtl/packages/cfar_pkg.sv at elaboration, so the register map
// and the RTL cannot drift apart silently — control/regmap.json and cfar_pkg.sv
// are two files, and two files drift.
//
// Lint contract: clean under `--Wall` with no waiver.
// -----------------------------------------------------------------------------

`default_nettype none

module reg_block_cfar
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

    // ---- to rtl/cfar/ (core domain) ----------------------------------------
    output wire                              cfg_enable,
    output wire [1:0]                        cfg_mode,        // cfar_pkg::cfar_mode_e
    output wire                              cfg_out_mode,    // cfar_pkg::cfar_out_mode_e
    output wire [4:0]                        cfg_guard_lead,
    output wire [4:0]                        cfg_guard_lag,
    output wire [5:0]                        cfg_ref_lead,
    output wire [5:0]                        cfg_ref_lag,
    output wire [15:0]                       cfg_alpha,
    output wire                              cfg_status_clear,  // one-cycle pulse

    // ---- from rtl/cfar/ -----------------------------------------------------
    input  wire [7:0]                        hw_max_guard,
    input  wire [7:0]                        hw_max_ref,
    input  wire                              hw_cfg_pending,
    input  wire                              hw_frame_open,
    input  wire [7:0]                        hw_alpha_frac_w,
    input  wire [15:0]                       hw_event_w,
    input  wire [7:0]                        hw_power_w,
    input  wire [7:0]                        hw_sum_w,
    input  wire [31:0]                       hw_det_count,
    input  wire [31:0]                       hw_sup_count,
    input  wire [31:0]                       hw_frame_count,
    input  wire [5:0]                        hw_fault,

    // Storage, observable without going through the read mux.
    output wire [REGMAP_CFAR_N_REGS*32-1:0]  csr,
    output wire [REGMAP_CFAR_N_REGS*32-1:0]  pulse
);

  localparam int unsigned NR = REGMAP_CFAR_N_REGS;

  // ---------------------------------------------------------------------------
  // Hardware-driven fields and the W1C set inputs
  // ---------------------------------------------------------------------------
  logic [NR*32-1:0] hw_value;
  logic [NR*32-1:0] hw_set;

  always_comb begin
    // Every field is written through its own generated LSB rather than as one
    // concatenation, so a field that moves in control/regmap.json moves here
    // with it instead of silently landing on its neighbour. (reg_block_covar
    // uses a concatenation for its status register; this is the safer of the two
    // idioms and is what a new block should copy.)
    hw_value = '0;
    hw_value[REGMAP_CFAR_CFAR_STATUS_INDEX*32 +
             REGMAP_CFAR_CFAR_STATUS_MAX_GUARD_LSB +:
             REGMAP_CFAR_CFAR_STATUS_MAX_GUARD_WIDTH] = hw_max_guard;
    hw_value[REGMAP_CFAR_CFAR_STATUS_INDEX*32 +
             REGMAP_CFAR_CFAR_STATUS_MAX_REF_LSB +:
             REGMAP_CFAR_CFAR_STATUS_MAX_REF_WIDTH] = hw_max_ref;
    hw_value[REGMAP_CFAR_CFAR_STATUS_INDEX*32 +
             REGMAP_CFAR_CFAR_STATUS_ALPHA_FRAC_W_LSB +:
             REGMAP_CFAR_CFAR_STATUS_ALPHA_FRAC_W_WIDTH] = hw_alpha_frac_w;
    hw_value[REGMAP_CFAR_CFAR_STATUS_INDEX*32 +
             REGMAP_CFAR_CFAR_STATUS_CFG_PENDING_LSB] = hw_cfg_pending;
    hw_value[REGMAP_CFAR_CFAR_STATUS_INDEX*32 +
             REGMAP_CFAR_CFAR_STATUS_FRAME_OPEN_LSB] = hw_frame_open;

    hw_value[REGMAP_CFAR_CFAR_GEOMETRY_INDEX*32 +
             REGMAP_CFAR_CFAR_GEOMETRY_EVENT_W_LSB +:
             REGMAP_CFAR_CFAR_GEOMETRY_EVENT_W_WIDTH] = hw_event_w;
    hw_value[REGMAP_CFAR_CFAR_GEOMETRY_INDEX*32 +
             REGMAP_CFAR_CFAR_GEOMETRY_POWER_W_LSB +:
             REGMAP_CFAR_CFAR_GEOMETRY_POWER_W_WIDTH] = hw_power_w;
    hw_value[REGMAP_CFAR_CFAR_GEOMETRY_INDEX*32 +
             REGMAP_CFAR_CFAR_GEOMETRY_SUM_W_LSB +:
             REGMAP_CFAR_CFAR_GEOMETRY_SUM_W_WIDTH] = hw_sum_w;

    hw_value[REGMAP_CFAR_CFAR_DET_COUNT_INDEX*32 +: 32]   = hw_det_count;
    hw_value[REGMAP_CFAR_CFAR_SUP_COUNT_INDEX*32 +: 32]   = hw_sup_count;
    hw_value[REGMAP_CFAR_CFAR_FRAME_COUNT_INDEX*32 +: 32] = hw_frame_count;

    // Sticky faults. Hardware sets, software clears by writing 1
    // (reg_csr_block resolves a simultaneous set and clear in favour of the set,
    // which is what stops a read-then-clear from losing an event).
    hw_set = '0;
    hw_set[REGMAP_CFAR_CFAR_FAULT_INDEX*32 +
           REGMAP_CFAR_CFAR_FAULT_CFG_CLAMPED_LSB]  = hw_fault[0];
    hw_set[REGMAP_CFAR_CFAR_FAULT_INDEX*32 +
           REGMAP_CFAR_CFAR_FAULT_NEG_INPUT_LSB]    = hw_fault[1];
    hw_set[REGMAP_CFAR_CFAR_FAULT_INDEX*32 +
           REGMAP_CFAR_CFAR_FAULT_ORPHAN_BEAT_LSB]  = hw_fault[2];
    hw_set[REGMAP_CFAR_CFAR_FAULT_INDEX*32 +
           REGMAP_CFAR_CFAR_FAULT_SOF_IN_FRAME_LSB] = hw_fault[3];
    hw_set[REGMAP_CFAR_CFAR_FAULT_INDEX*32 +
           REGMAP_CFAR_CFAR_FAULT_NO_REF_LSB]       = hw_fault[4];
    hw_set[REGMAP_CFAR_CFAR_FAULT_INDEX*32 +
           REGMAP_CFAR_CFAR_FAULT_BIN_OVERFLOW_LSB] = hw_fault[5];
  end

  wire [NR*32-1:0] csr_i;
  wire [NR*32-1:0] pulse_i;

  reg_csr_block #(
      .N_REGS     (NR),
      .IDX_W      (IDX_W),
      .RESET_VAL  (REGMAP_CFAR_RESET),
      .WMASK      (REGMAP_CFAR_WMASK),
      .W1C_MASK   (REGMAP_CFAR_W1CMASK),
      .PULSE_MASK (REGMAP_CFAR_PULSEMASK),
      .HW_MASK    (REGMAP_CFAR_HWMASK)
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
  // Field extraction. Every offset comes from the generated map. Field slices are
  // taken straight out of the flat storage rather than through a whole-register
  // wire, so no bit of a partially populated register is declared and left unread.
  // ---------------------------------------------------------------------------
  localparam int unsigned CTRL_BIT = REGMAP_CFAR_CFAR_CTRL_INDEX*32;
  localparam int unsigned WIN_BIT  = REGMAP_CFAR_CFAR_WINDOW_INDEX*32;
  localparam int unsigned THR_BIT  = REGMAP_CFAR_CFAR_THRESHOLD_INDEX*32;

  assign cfg_enable   = csr_i[CTRL_BIT + REGMAP_CFAR_CFAR_CTRL_ENABLE_LSB];
  assign cfg_mode     = csr_i[CTRL_BIT + REGMAP_CFAR_CFAR_CTRL_MODE_LSB +:
                              REGMAP_CFAR_CFAR_CTRL_MODE_WIDTH];
  assign cfg_out_mode = csr_i[CTRL_BIT + REGMAP_CFAR_CFAR_CTRL_OUT_MODE_LSB];

  assign cfg_status_clear =
      pulse_i[CTRL_BIT + REGMAP_CFAR_CFAR_CTRL_STATUS_CLEAR_LSB];

  assign cfg_guard_lead = csr_i[WIN_BIT + REGMAP_CFAR_CFAR_WINDOW_GUARD_LEAD_LSB +:
                                REGMAP_CFAR_CFAR_WINDOW_GUARD_LEAD_WIDTH];
  assign cfg_guard_lag  = csr_i[WIN_BIT + REGMAP_CFAR_CFAR_WINDOW_GUARD_LAG_LSB +:
                                REGMAP_CFAR_CFAR_WINDOW_GUARD_LAG_WIDTH];
  assign cfg_ref_lead   = csr_i[WIN_BIT + REGMAP_CFAR_CFAR_WINDOW_REF_LEAD_LSB +:
                                REGMAP_CFAR_CFAR_WINDOW_REF_LEAD_WIDTH];
  assign cfg_ref_lag    = csr_i[WIN_BIT + REGMAP_CFAR_CFAR_WINDOW_REF_LAG_LSB +:
                                REGMAP_CFAR_CFAR_WINDOW_REF_LAG_WIDTH];

  assign cfg_alpha = csr_i[THR_BIT + REGMAP_CFAR_CFAR_THRESHOLD_ALPHA_LSB +:
                           REGMAP_CFAR_CFAR_THRESHOLD_ALPHA_WIDTH];

  // ---------------------------------------------------------------------------
  // The generated reset values and field widths must agree with the RTL's own
  // package. Checked at elaboration rather than by inspection.
  // ---------------------------------------------------------------------------
`ifndef SYNTHESIS
  initial begin
    if (((REGMAP_CFAR_RESET[THR_BIT +: 32] & REGMAP_CFAR_CFAR_THRESHOLD_ALPHA_MASK) >>
         REGMAP_CFAR_CFAR_THRESHOLD_ALPHA_LSB) !=
        32'(cfar_pkg::cfar_alpha_default())) begin
      $fatal(1, "reg_block_cfar: CFAR_THRESHOLD.ALPHA resets to 0x%0h but cfar_pkg says 0x%0h",
             (REGMAP_CFAR_RESET[THR_BIT +: 32] & REGMAP_CFAR_CFAR_THRESHOLD_ALPHA_MASK) >>
                 REGMAP_CFAR_CFAR_THRESHOLD_ALPHA_LSB,
             cfar_pkg::cfar_alpha_default());
    end
    if (((REGMAP_CFAR_RESET[WIN_BIT +: 32] & REGMAP_CFAR_CFAR_WINDOW_GUARD_LEAD_MASK) >>
         REGMAP_CFAR_CFAR_WINDOW_GUARD_LEAD_LSB) !=
        32'(cfar_pkg::cfar_guard_default())) begin
      $fatal(1, "reg_block_cfar: CFAR_WINDOW.GUARD_LEAD resets to a value cfar_pkg does not agree with");
    end
    if (((REGMAP_CFAR_RESET[WIN_BIT +: 32] & REGMAP_CFAR_CFAR_WINDOW_REF_LEAD_MASK) >>
         REGMAP_CFAR_CFAR_WINDOW_REF_LEAD_LSB) !=
        32'(cfar_pkg::cfar_ref_default())) begin
      $fatal(1, "reg_block_cfar: CFAR_WINDOW.REF_LEAD resets to a value cfar_pkg does not agree with");
    end
    if (REGMAP_CFAR_CFAR_THRESHOLD_ALPHA_WIDTH != int'(cfar_pkg::cfar_alpha_w())) begin
      $fatal(1, "reg_block_cfar: CFAR_THRESHOLD.ALPHA is %0d bits but cfar_pkg says %0d",
             REGMAP_CFAR_CFAR_THRESHOLD_ALPHA_WIDTH, int'(cfar_pkg::cfar_alpha_w()));
    end
    if (REGMAP_CFAR_CFAR_WINDOW_GUARD_LEAD_WIDTH != int'(cfar_pkg::cfar_guard_cnt_w()) ||
        REGMAP_CFAR_CFAR_WINDOW_GUARD_LAG_WIDTH  != int'(cfar_pkg::cfar_guard_cnt_w())) begin
      $fatal(1, "reg_block_cfar: a guard-count field is not %0d bits",
             int'(cfar_pkg::cfar_guard_cnt_w()));
    end
    if (REGMAP_CFAR_CFAR_WINDOW_REF_LEAD_WIDTH != int'(cfar_pkg::cfar_ref_cnt_w()) ||
        REGMAP_CFAR_CFAR_WINDOW_REF_LAG_WIDTH  != int'(cfar_pkg::cfar_ref_cnt_w())) begin
      $fatal(1, "reg_block_cfar: a reference-count field is not %0d bits",
             int'(cfar_pkg::cfar_ref_cnt_w()));
    end
    if (REGMAP_CFAR_CFAR_CTRL_MODE_WIDTH != int'(cfar_pkg::cfar_mode_w())) begin
      $fatal(1, "reg_block_cfar: CFAR_CTRL.MODE is %0d bits but cfar_pkg says %0d",
             REGMAP_CFAR_CFAR_CTRL_MODE_WIDTH, int'(cfar_pkg::cfar_mode_w()));
    end
    // The geometry echo has to be able to REPORT the event width; a field too
    // narrow would report a truncated number that a packet decoder would then
    // parse with.
    if (int'(cfar_pkg::cfar_event_w()) >=
        (1 << REGMAP_CFAR_CFAR_GEOMETRY_EVENT_W_WIDTH)) begin
      $fatal(1, "reg_block_cfar: CFAR_GEOMETRY.EVENT_W (%0d bits) cannot report a %0d-bit event",
             REGMAP_CFAR_CFAR_GEOMETRY_EVENT_W_WIDTH, int'(cfar_pkg::cfar_event_w()));
    end
    if (int'(cfar_pkg::cfar_event_sum_w()) >=
        (1 << REGMAP_CFAR_CFAR_GEOMETRY_SUM_W_WIDTH)) begin
      $fatal(1, "reg_block_cfar: CFAR_GEOMETRY.SUM_W cannot report a %0d-bit sum",
             int'(cfar_pkg::cfar_event_sum_w()));
    end
  end
`endif

endmodule : reg_block_cfar

`default_nettype wire
