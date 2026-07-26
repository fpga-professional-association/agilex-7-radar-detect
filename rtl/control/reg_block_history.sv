// -----------------------------------------------------------------------------
// reg_block_history — the SPEC.md 9 register window for the SPEC 7.3
// time-frequency history and corner turn (issue #15). Window base 0xA000.
//
// What this module owns: the decode of one 4 KiB window into the thirteen
// registers control/regmap.json declares for it, the storage behind the writable
// fields, and the wiring of rtl/memory/history_core.sv's `cfg_*` inputs and
// `stat_*` outputs to them.
//
// What it does NOT own, and deliberately: any policy. It does not clamp the
// requested depth (history_core does, and states why), it does not decide when a
// depth change lands (history_core waits for a frame boundary), and it does not
// hold the counters (the kernel's own perf_counter instances do, and three of
// them live in the other clock domain). A register block that reimplemented any
// of that would be a second, differently-wrong copy of the rule.
//
// EVERY MASK, INDEX AND RESET VALUE COMES FROM regmap_pkg. Nothing here is a
// literal, because control/regmap.json is the source of truth and a literal in
// this file is a place for the two to disagree silently. What the file DOES
// check by hand is the other direction: that the generated field widths are wide
// enough for the geometry this instance was elaborated with. `control/regmap.json`
// and `rtl/packages/history_pkg.sv` are two files, and two files drift — the same
// argument, and the same device, as rtl/control/reg_block_cfar.sv.
//
// CLOCK DOMAIN. `clk` here is core_clk, the WRITE side of the subsystem. That is
// where the frame sequencers and the rotation policy live, so it is where the
// controls belong. The three read-side counters arrive already crossed, as one
// consistent bundle, from history_core's own cdc_handshake; this module never
// synchronises anything and contains no crossing of its own, which is why it
// carries no `(* cdc_primitive *)` tag and does not appear in the SPEC 8
// inventory.
//
// Lint contract: clean under `--Wall` with no waiver.
// -----------------------------------------------------------------------------

`default_nettype none

module reg_block_history
  import reg_if_pkg::*;
  import regmap_pkg::*;
#(
    parameter int unsigned IDX_W = REGMAP_WINDOW_W - 2,

    // The elaborated geometry of the history_core this block is wired to. Used
    // ONLY by the elaboration checks below: the block reports geometry through
    // its `hw_*` inputs, exactly as reg_block_cfar does, so that control_top can
    // tie them off and test_control_regs can predict every response from the
    // generated tables alone.
    parameter int unsigned FRAMES_MAX = 4,
    parameter int unsigned FFT_SIZE   = 64,
    parameter int unsigned N_ANT      = 2,
    parameter int unsigned LANES      = 1
) (
    input  wire                                 clk,
    input  wire                                 rst_n,

    // ---- register-plane port, from reg_fabric ----
    input  wire                                 sel,
    input  wire                                 write_enable,
    input  wire                                 read_enable,
    input  wire [IDX_W-1:0]                     index,
    input  wire [REG_DATA_W-1:0]                write_data,
    input  wire [REG_STRB_W-1:0]                byte_enable,

    output wire [REG_DATA_W-1:0]                read_data,
    output wire                                 ready,
    output wire                                 error,

    // ---- to rtl/memory/history_core.sv (core_clk) ----
    output wire                                 cfg_enable,
    output wire [15:0]                          cfg_depth,
    output wire                                 cfg_depth_apply,
    output wire                                 cfg_counter_clear,
    output wire                                 cfg_sticky_clear,
    output wire                                 cfg_force_unsafe,

    // ---- from rtl/memory/history_core.sv ----
    // Widths come from the generated map, not from a round number: a status
    // port wider than the field it feeds is a place to truncate silently.
    input  wire [REGMAP_HISTORY_HISTORY_STATUS_DEPTH_ACTIVE_WIDTH-1:0] hw_depth_active,
    input  wire [REGMAP_HISTORY_HISTORY_STATUS_OCCUPANCY_WIDTH-1:0]    hw_occupancy,
    input  wire [7:0]                           hw_epoch,
    input  wire                                 hw_depth_pending,
    input  wire [7:0]                           hw_n_ant,
    input  wire [7:0]                           hw_lanes,
    input  wire [REGMAP_HISTORY_HISTORY_GEOMETRY_FRAMES_MAX_WIDTH-1:0] hw_frames_max,
    input  wire                                 hw_bit_reversed,
    input  wire [15:0]                          hw_fft_size,
    input  wire [15:0]                          hw_n_banks,
    input  wire [31:0]                          hw_frames_done,
    input  wire [31:0]                          hw_overwrite_count,
    input  wire [31:0]                          hw_collision_count,
    input  wire [31:0]                          hw_error_count,
    input  wire [31:0]                          hw_read_count,
    input  wire [31:0]                          hw_write_beat_count,
    input  wire [31:0]                          hw_skew_count,
    // Sticky, from the kernel: {framing, skew, collision, error}. Drives the
    // W1C set inputs, so a bit the kernel still holds set re-asserts after a
    // software clear until HISTORY_CTRL.STATUS_CLEAR is pulsed. Same arrangement,
    // and same reason, as reg_block_cfar's `hw_fault`.
    input  wire [3:0]                           hw_fault,

    // Storage, observable without going through the read mux.
    output wire [REGMAP_HISTORY_N_REGS*32-1:0]  csr,
    output wire [REGMAP_HISTORY_N_REGS*32-1:0]  pulse
);

  localparam int unsigned NR = REGMAP_HISTORY_N_REGS;

  // ---------------------------------------------------------------------------
  // Hardware-driven read values and W1C set strobes
  //
  // Every field is written through its own generated LSB rather than as one
  // concatenation, so a field that moves in control/regmap.json moves here with
  // it instead of silently landing on its neighbour.
  // ---------------------------------------------------------------------------
  logic [NR*32-1:0] hw_value;
  logic [NR*32-1:0] hw_set;

  always_comb begin
    hw_value = '0;

    hw_value[REGMAP_HISTORY_HISTORY_STATUS_INDEX*32 +
             REGMAP_HISTORY_HISTORY_STATUS_DEPTH_ACTIVE_LSB +:
             REGMAP_HISTORY_HISTORY_STATUS_DEPTH_ACTIVE_WIDTH] =
        hw_depth_active;
    hw_value[REGMAP_HISTORY_HISTORY_STATUS_INDEX*32 +
             REGMAP_HISTORY_HISTORY_STATUS_OCCUPANCY_LSB +:
             REGMAP_HISTORY_HISTORY_STATUS_OCCUPANCY_WIDTH] =
        hw_occupancy;
    hw_value[REGMAP_HISTORY_HISTORY_STATUS_INDEX*32 +
             REGMAP_HISTORY_HISTORY_STATUS_EPOCH_LSB +:
             REGMAP_HISTORY_HISTORY_STATUS_EPOCH_WIDTH] = hw_epoch;
    hw_value[REGMAP_HISTORY_HISTORY_STATUS_INDEX*32 +
             REGMAP_HISTORY_HISTORY_STATUS_DEPTH_PENDING_LSB] = hw_depth_pending;

    hw_value[REGMAP_HISTORY_HISTORY_GEOMETRY_INDEX*32 +
             REGMAP_HISTORY_HISTORY_GEOMETRY_N_ANT_LSB +:
             REGMAP_HISTORY_HISTORY_GEOMETRY_N_ANT_WIDTH] = hw_n_ant;
    hw_value[REGMAP_HISTORY_HISTORY_GEOMETRY_INDEX*32 +
             REGMAP_HISTORY_HISTORY_GEOMETRY_LANES_LSB +:
             REGMAP_HISTORY_HISTORY_GEOMETRY_LANES_WIDTH] = hw_lanes;
    hw_value[REGMAP_HISTORY_HISTORY_GEOMETRY_INDEX*32 +
             REGMAP_HISTORY_HISTORY_GEOMETRY_FRAMES_MAX_LSB +:
             REGMAP_HISTORY_HISTORY_GEOMETRY_FRAMES_MAX_WIDTH] =
        hw_frames_max;
    hw_value[REGMAP_HISTORY_HISTORY_GEOMETRY_INDEX*32 +
             REGMAP_HISTORY_HISTORY_GEOMETRY_BIT_REVERSED_LSB] = hw_bit_reversed;

    hw_value[REGMAP_HISTORY_HISTORY_GEOMETRY2_INDEX*32 +
             REGMAP_HISTORY_HISTORY_GEOMETRY2_FFT_SIZE_LSB +:
             REGMAP_HISTORY_HISTORY_GEOMETRY2_FFT_SIZE_WIDTH] = hw_fft_size;
    hw_value[REGMAP_HISTORY_HISTORY_GEOMETRY2_INDEX*32 +
             REGMAP_HISTORY_HISTORY_GEOMETRY2_N_BANKS_LSB +:
             REGMAP_HISTORY_HISTORY_GEOMETRY2_N_BANKS_WIDTH] = hw_n_banks;

    hw_value[REGMAP_HISTORY_HISTORY_FRAMES_DONE_INDEX*32 +: 32] = hw_frames_done;
    hw_value[REGMAP_HISTORY_HISTORY_OVERWRITE_INDEX*32 +: 32]   = hw_overwrite_count;
    hw_value[REGMAP_HISTORY_HISTORY_COLLISION_INDEX*32 +: 32]   = hw_collision_count;
    hw_value[REGMAP_HISTORY_HISTORY_ERROR_INDEX*32 +: 32]       = hw_error_count;
    hw_value[REGMAP_HISTORY_HISTORY_READS_INDEX*32 +: 32]       = hw_read_count;
    hw_value[REGMAP_HISTORY_HISTORY_WRITE_BEATS_INDEX*32 +: 32] = hw_write_beat_count;
    hw_value[REGMAP_HISTORY_HISTORY_SKEW_INDEX*32 +: 32]        = hw_skew_count;

    hw_set = '0;
    hw_set[REGMAP_HISTORY_HISTORY_FAULT_INDEX*32 +
           REGMAP_HISTORY_HISTORY_FAULT_ERROR_SEEN_LSB]     = hw_fault[0];
    hw_set[REGMAP_HISTORY_HISTORY_FAULT_INDEX*32 +
           REGMAP_HISTORY_HISTORY_FAULT_COLLISION_SEEN_LSB] = hw_fault[1];
    hw_set[REGMAP_HISTORY_HISTORY_FAULT_INDEX*32 +
           REGMAP_HISTORY_HISTORY_FAULT_SKEW_SEEN_LSB]      = hw_fault[2];
    hw_set[REGMAP_HISTORY_HISTORY_FAULT_INDEX*32 +
           REGMAP_HISTORY_HISTORY_FAULT_FRAMING_SEEN_LSB]   = hw_fault[3];
  end

  // ---------------------------------------------------------------------------
  // The engine. Identical in every block; only the REGMAP_<BLOCK>_* tables change.
  // ---------------------------------------------------------------------------
  wire [NR*32-1:0] csr_i;
  wire [NR*32-1:0] pulse_i;

  reg_csr_block #(
      .N_REGS     (NR),
      .IDX_W      (IDX_W),
      .RESET_VAL  (REGMAP_HISTORY_RESET),
      .WMASK      (REGMAP_HISTORY_WMASK),
      .W1C_MASK   (REGMAP_HISTORY_W1CMASK),
      .PULSE_MASK (REGMAP_HISTORY_PULSEMASK),
      .HW_MASK    (REGMAP_HISTORY_HWMASK)
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
  // Field extraction. Slices are taken straight out of the flat storage rather
  // than through a whole-register wire, which is what keeps --Wall quiet about
  // the unpopulated bits of a partially used register.
  // ---------------------------------------------------------------------------
  localparam int unsigned CTRL_BIT  = REGMAP_HISTORY_HISTORY_CTRL_INDEX * 32;
  localparam int unsigned DEPTH_BIT = REGMAP_HISTORY_HISTORY_DEPTH_INDEX * 32;

  assign cfg_enable       = csr_i[CTRL_BIT + REGMAP_HISTORY_HISTORY_CTRL_ENABLE_LSB];
  assign cfg_force_unsafe = csr_i[CTRL_BIT + REGMAP_HISTORY_HISTORY_CTRL_FORCE_UNSAFE_LSB];

  assign cfg_depth_apply   = pulse_i[CTRL_BIT + REGMAP_HISTORY_HISTORY_CTRL_DEPTH_APPLY_LSB];
  assign cfg_counter_clear = pulse_i[CTRL_BIT + REGMAP_HISTORY_HISTORY_CTRL_COUNTER_CLEAR_LSB];
  assign cfg_sticky_clear  = pulse_i[CTRL_BIT + REGMAP_HISTORY_HISTORY_CTRL_STATUS_CLEAR_LSB];

  // Zero-extended to the kernel's fixed control-port width. The kernel clamps
  // the value; this module does not, because the clamp is a property of the
  // geometry and the geometry belongs to the kernel.
  assign cfg_depth = 16'(csr_i[DEPTH_BIT + REGMAP_HISTORY_HISTORY_DEPTH_DEPTH_LSB +:
                               REGMAP_HISTORY_HISTORY_DEPTH_DEPTH_WIDTH]);

  // ---------------------------------------------------------------------------
  // Elaboration checks against the geometry this instance was built for.
  //
  // The generated map fixes the field widths; the parameters fix what has to fit
  // in them. If a future configuration outgrows a field, this fails at time zero
  // with the number that outgrew it rather than by silently truncating a depth,
  // a bin count or a bank count in a status register nobody reads carefully.
  // ---------------------------------------------------------------------------
`ifndef SYNTHESIS
  initial begin
    if (FRAMES_MAX > (1 << REGMAP_HISTORY_HISTORY_DEPTH_DEPTH_WIDTH) - 1) begin
      $fatal(1, "reg_block_history: FRAMES_MAX=%0d does not fit HISTORY_DEPTH.DEPTH (%0d bits)",
             FRAMES_MAX, REGMAP_HISTORY_HISTORY_DEPTH_DEPTH_WIDTH);
    end
    if (FRAMES_MAX > (1 << REGMAP_HISTORY_HISTORY_STATUS_OCCUPANCY_WIDTH) - 1) begin
      $fatal(1, "reg_block_history: FRAMES_MAX=%0d does not fit HISTORY_STATUS.OCCUPANCY (%0d bits)",
             FRAMES_MAX, REGMAP_HISTORY_HISTORY_STATUS_OCCUPANCY_WIDTH);
    end
    if (FFT_SIZE > (1 << REGMAP_HISTORY_HISTORY_GEOMETRY2_FFT_SIZE_WIDTH) - 1) begin
      $fatal(1, "reg_block_history: FFT_SIZE=%0d does not fit HISTORY_GEOMETRY2.FFT_SIZE (%0d bits)",
             FFT_SIZE, REGMAP_HISTORY_HISTORY_GEOMETRY2_FFT_SIZE_WIDTH);
    end
    if (N_ANT * LANES > (1 << REGMAP_HISTORY_HISTORY_GEOMETRY2_N_BANKS_WIDTH) - 1) begin
      $fatal(1, "reg_block_history: %0d banks do not fit HISTORY_GEOMETRY2.N_BANKS (%0d bits)",
             N_ANT * LANES, REGMAP_HISTORY_HISTORY_GEOMETRY2_N_BANKS_WIDTH);
    end
    if (N_ANT > (1 << REGMAP_HISTORY_HISTORY_GEOMETRY_N_ANT_WIDTH) - 1) begin
      $fatal(1, "reg_block_history: N_ANT=%0d does not fit HISTORY_GEOMETRY.N_ANT (%0d bits)",
             N_ANT, REGMAP_HISTORY_HISTORY_GEOMETRY_N_ANT_WIDTH);
    end
    // The window has to be able to say what is in force, so the status field
    // must be at least as wide as the request field it reports back.
    if (REGMAP_HISTORY_HISTORY_STATUS_DEPTH_ACTIVE_WIDTH <
        REGMAP_HISTORY_HISTORY_DEPTH_DEPTH_WIDTH) begin
      $fatal(1, "reg_block_history: HISTORY_STATUS.DEPTH_ACTIVE (%0d bits) is narrower than HISTORY_DEPTH.DEPTH (%0d bits)",
             REGMAP_HISTORY_HISTORY_STATUS_DEPTH_ACTIVE_WIDTH,
             REGMAP_HISTORY_HISTORY_DEPTH_DEPTH_WIDTH);
    end
  end
`endif

endmodule : reg_block_history

`default_nettype wire
