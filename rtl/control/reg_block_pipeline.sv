// -----------------------------------------------------------------------------
// reg_block_pipeline — the SPEC.md 9 register window for the Phase 3 integration
// (issue #17). Window base 0xC000.
//
// What this module owns: the decode of one 4 KiB window into the twenty-three
// registers control/regmap.json declares for it, the storage behind the writable
// fields, and the wiring of two blocks that have no window of their own —
// rtl/top/adc_source.sv (the SPEC 3 synthetic sources) and rtl/align/align_net.sv
// (the SPEC 7.4 alignment network) — plus the integration-level telemetry that
// belongs to no single block.
//
// What it does NOT own: any policy. It does not decide when a sweep gate takes
// effect (the blocks stop at their own frame boundaries and say so), it does not
// clamp a tone step (the source takes it modulo FFT_SIZE, which is a property of
// the table rather than of a register), and it holds no counter (every one of
// them is a `perf_counter` in the block that measures it). A register block that
// reimplemented any of that would be a second, differently-wrong copy of a rule.
//
// EVERY MASK, INDEX AND RESET VALUE COMES FROM regmap_pkg. Nothing here is a
// literal, for the reason every other block in this directory states: the source
// of truth is control/regmap.json and a literal here is a place for the two to
// disagree silently.
//
// CLOCK DOMAIN. `clk` is cfg_clk. Unlike reg_block_history, whose window sits in
// the domain it controls, this one straddles two: the source counters are
// produced in core_clk and the alignment counters in history_clk. NEITHER
// crossing is here. Both arrive already crossed, as whole consistent bundles,
// through rtl/top/cfg_bundle_cdc.sv instances in benchmark_core — so this module
// contains no synchroniser, carries no `(* cdc_primitive *)` tag, and does not
// appear in the SPEC 8 inventory. The bundling is what makes a multi-register
// read of, say, the four alignment error counters a coherent snapshot rather
// than four independently stale numbers.
//
// Lint contract: clean under `--Wall` with no waiver.
// -----------------------------------------------------------------------------

`default_nettype none

module reg_block_pipeline
  import reg_if_pkg::*;
  import regmap_pkg::*;
#(
    parameter int unsigned IDX_W = REGMAP_WINDOW_W - 2,

    // The elaborated integration geometry. Used ONLY by the elaboration checks
    // below: the block reports geometry through its `hw_*` inputs, exactly as
    // reg_block_history and reg_block_cfar do, so that a register-plane test can
    // tie them off and still predict every response from the generated tables.
    parameter int unsigned BIN_PAR      = 2,
    parameter int unsigned ALIGN_GROUPS = 4,
    parameter int unsigned LANES        = 2
) (
    input  wire                                  clk,
    input  wire                                  rst_n,

    // ---- register-plane port, from reg_fabric ----
    input  wire                                  sel,
    input  wire                                  write_enable,
    input  wire                                  read_enable,
    input  wire [IDX_W-1:0]                      index,
    input  wire [REG_DATA_W-1:0]                 write_data,
    input  wire [REG_STRB_W-1:0]                 byte_enable,
    output wire [REG_DATA_W-1:0]                 read_data,
    output wire                                  ready,
    output wire                                  error,

    // ---- configuration out (cfg_clk; crossed by the integration) ----
    output wire                                  cfg_src_enable,
    output wire                                  cfg_src_run,
    output wire [2:0]                            cfg_src_mode,
    output wire [31:0]                           cfg_src_gain,
    output wire [15:0]                           cfg_src_tone_step,
    output wire [15:0]                           cfg_src_ant_step,
    output wire [31:0]                           cfg_src_seed,
    output wire                                  cfg_src_reseed,     // one-cycle pulse

    output wire                                  cfg_align_enable,
    output wire                                  cfg_align_run,
    output wire                                  cfg_align_partial,
    output wire                                  cfg_align_unsafe,
    output wire [15:0]                           cfg_align_frame_off,
    output wire [7:0]                            cfg_align_lane_stall,

    output wire                                  cfg_counter_clear,  // one-cycle pulse
    output wire                                  cfg_status_clear,   // one-cycle pulse

    // ---- hardware-driven status in (already crossed into cfg_clk) ----
    input  wire [31:0]                           hw_src_beats,
    input  wire [31:0]                           hw_src_frames,
    input  wire [31:0]                           hw_src_stalls,

    input  wire [31:0]                           hw_align_beats,
    input  wire [31:0]                           hw_align_stalls,
    input  wire [31:0]                           hw_align_missing,
    input  wire [31:0]                           hw_align_dup,
    input  wire [31:0]                           hw_align_orphan,
    input  wire [31:0]                           hw_align_timeout,
    input  wire [31:0]                           hw_align_multi,
    input  wire [3:0]                            hw_align_fault,
    input  wire [7:0]                            hw_net_sel,
    input  wire [7:0]                            hw_net_latency,
    input  wire [7:0]                            hw_block_latency,

    input  wire [31:0]                           hw_rdmux_grants,
    input  wire [31:0]                           hw_rdmux_stalls,
    input  wire [31:0]                           hw_events,

    input  wire [7:0]                            hw_bin_par,
    input  wire [7:0]                            hw_align_groups,
    input  wire [7:0]                            hw_lanes,
    input  wire [7:0]                            hw_rd_ports,

    input  wire [7:0]                            hw_lat_pfb_cycles,
    input  wire [7:0]                            hw_lat_pfb_beats,
    input  wire [15:0]                           hw_lat_fft_beats,
    input  wire [7:0]                            hw_lat_history,
    input  wire [7:0]                            hw_lat_align,
    input  wire [7:0]                            hw_lat_beamformer,
    input  wire [7:0]                            hw_lat_power,

    output wire [REGMAP_PIPELINE_N_REGS*32-1:0]  csr,
    output wire [REGMAP_PIPELINE_N_REGS*32-1:0]  pulse
);

  localparam int unsigned NR = REGMAP_PIPELINE_N_REGS;

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

    hw_value[REGMAP_PIPELINE_PIPE_SRC_BEATS_INDEX*32   +: 32] = hw_src_beats;
    hw_value[REGMAP_PIPELINE_PIPE_SRC_FRAMES_INDEX*32  +: 32] = hw_src_frames;
    hw_value[REGMAP_PIPELINE_PIPE_SRC_STALLS_INDEX*32  +: 32] = hw_src_stalls;

    hw_value[REGMAP_PIPELINE_PIPE_ALIGN_BEATS_INDEX*32   +: 32] = hw_align_beats;
    hw_value[REGMAP_PIPELINE_PIPE_ALIGN_STALLS_INDEX*32  +: 32] = hw_align_stalls;
    hw_value[REGMAP_PIPELINE_PIPE_ALIGN_MISSING_INDEX*32 +: 32] = hw_align_missing;
    hw_value[REGMAP_PIPELINE_PIPE_ALIGN_DUP_INDEX*32     +: 32] = hw_align_dup;
    hw_value[REGMAP_PIPELINE_PIPE_ALIGN_ORPHAN_INDEX*32  +: 32] = hw_align_orphan;
    hw_value[REGMAP_PIPELINE_PIPE_ALIGN_TIMEOUT_INDEX*32 +: 32] = hw_align_timeout;
    hw_value[REGMAP_PIPELINE_PIPE_ALIGN_MULTI_INDEX*32   +: 32] = hw_align_multi;

    hw_value[REGMAP_PIPELINE_PIPE_ALIGN_STATUS_INDEX*32 +
             REGMAP_PIPELINE_PIPE_ALIGN_STATUS_NET_SEL_LSB +:
             REGMAP_PIPELINE_PIPE_ALIGN_STATUS_NET_SEL_WIDTH] = hw_net_sel;
    hw_value[REGMAP_PIPELINE_PIPE_ALIGN_STATUS_INDEX*32 +
             REGMAP_PIPELINE_PIPE_ALIGN_STATUS_NET_LATENCY_LSB +:
             REGMAP_PIPELINE_PIPE_ALIGN_STATUS_NET_LATENCY_WIDTH] = hw_net_latency;
    hw_value[REGMAP_PIPELINE_PIPE_ALIGN_STATUS_INDEX*32 +
             REGMAP_PIPELINE_PIPE_ALIGN_STATUS_BLOCK_LATENCY_LSB +:
             REGMAP_PIPELINE_PIPE_ALIGN_STATUS_BLOCK_LATENCY_WIDTH] = hw_block_latency;

    hw_value[REGMAP_PIPELINE_PIPE_RDMUX_GRANTS_INDEX*32 +: 32] = hw_rdmux_grants;
    hw_value[REGMAP_PIPELINE_PIPE_RDMUX_STALLS_INDEX*32 +: 32] = hw_rdmux_stalls;
    hw_value[REGMAP_PIPELINE_PIPE_EVENTS_INDEX*32       +: 32] = hw_events;

    hw_value[REGMAP_PIPELINE_PIPE_GEOMETRY_INDEX*32 +
             REGMAP_PIPELINE_PIPE_GEOMETRY_BIN_PAR_LSB +:
             REGMAP_PIPELINE_PIPE_GEOMETRY_BIN_PAR_WIDTH] = hw_bin_par;
    hw_value[REGMAP_PIPELINE_PIPE_GEOMETRY_INDEX*32 +
             REGMAP_PIPELINE_PIPE_GEOMETRY_ALIGN_GROUPS_LSB +:
             REGMAP_PIPELINE_PIPE_GEOMETRY_ALIGN_GROUPS_WIDTH] = hw_align_groups;
    hw_value[REGMAP_PIPELINE_PIPE_GEOMETRY_INDEX*32 +
             REGMAP_PIPELINE_PIPE_GEOMETRY_LANES_LSB +:
             REGMAP_PIPELINE_PIPE_GEOMETRY_LANES_WIDTH] = hw_lanes;
    hw_value[REGMAP_PIPELINE_PIPE_GEOMETRY_INDEX*32 +
             REGMAP_PIPELINE_PIPE_GEOMETRY_RD_PORTS_LSB +:
             REGMAP_PIPELINE_PIPE_GEOMETRY_RD_PORTS_WIDTH] = hw_rd_ports;

    hw_value[REGMAP_PIPELINE_PIPE_LAT_FRONT_INDEX*32 +
             REGMAP_PIPELINE_PIPE_LAT_FRONT_PFB_CYCLES_LSB +:
             REGMAP_PIPELINE_PIPE_LAT_FRONT_PFB_CYCLES_WIDTH] = hw_lat_pfb_cycles;
    hw_value[REGMAP_PIPELINE_PIPE_LAT_FRONT_INDEX*32 +
             REGMAP_PIPELINE_PIPE_LAT_FRONT_PFB_BEATS_LSB +:
             REGMAP_PIPELINE_PIPE_LAT_FRONT_PFB_BEATS_WIDTH] = hw_lat_pfb_beats;
    hw_value[REGMAP_PIPELINE_PIPE_LAT_FRONT_INDEX*32 +
             REGMAP_PIPELINE_PIPE_LAT_FRONT_FFT_BEATS_LSB +:
             REGMAP_PIPELINE_PIPE_LAT_FRONT_FFT_BEATS_WIDTH] = hw_lat_fft_beats;

    hw_value[REGMAP_PIPELINE_PIPE_LAT_BACK_INDEX*32 +
             REGMAP_PIPELINE_PIPE_LAT_BACK_HISTORY_LSB +:
             REGMAP_PIPELINE_PIPE_LAT_BACK_HISTORY_WIDTH] = hw_lat_history;
    hw_value[REGMAP_PIPELINE_PIPE_LAT_BACK_INDEX*32 +
             REGMAP_PIPELINE_PIPE_LAT_BACK_ALIGN_LSB +:
             REGMAP_PIPELINE_PIPE_LAT_BACK_ALIGN_WIDTH] = hw_lat_align;
    hw_value[REGMAP_PIPELINE_PIPE_LAT_BACK_INDEX*32 +
             REGMAP_PIPELINE_PIPE_LAT_BACK_BEAMFORMER_LSB +:
             REGMAP_PIPELINE_PIPE_LAT_BACK_BEAMFORMER_WIDTH] = hw_lat_beamformer;
    hw_value[REGMAP_PIPELINE_PIPE_LAT_BACK_INDEX*32 +
             REGMAP_PIPELINE_PIPE_LAT_BACK_POWER_LSB +:
             REGMAP_PIPELINE_PIPE_LAT_BACK_POWER_WIDTH] = hw_lat_power;

    // The sticky alignment faults are W1C on top of the block's own sticky
    // state, exactly as HISTORY_FAULT is: clearing a bit the block still holds
    // set has no lasting effect until PIPE_CTRL.STATUS_CLEAR is pulsed too.
    hw_set = '0;
    for (int unsigned i = 0; i < 4; i++) begin
      hw_set[REGMAP_PIPELINE_PIPE_ALIGN_STATUS_INDEX*32 +
             REGMAP_PIPELINE_PIPE_ALIGN_STATUS_FAULT_LSB + i] = hw_align_fault[i];
    end
  end

  // ---------------------------------------------------------------------------
  // The engine. Identical in every block; only the REGMAP_<BLOCK>_* tables change.
  // ---------------------------------------------------------------------------
  wire [NR*32-1:0] csr_i;
  wire [NR*32-1:0] pulse_i;

  reg_csr_block #(
      .N_REGS     (NR),
      .IDX_W      (IDX_W),
      .RESET_VAL  (REGMAP_PIPELINE_RESET),
      .WMASK      (REGMAP_PIPELINE_WMASK),
      .W1C_MASK   (REGMAP_PIPELINE_W1CMASK),
      .PULSE_MASK (REGMAP_PIPELINE_PULSEMASK),
      .HW_MASK    (REGMAP_PIPELINE_HWMASK)
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
  // Field extraction
  // ---------------------------------------------------------------------------
  localparam int unsigned CTRL_BIT  = REGMAP_PIPELINE_PIPE_CTRL_INDEX      * 32;
  localparam int unsigned MODE_BIT  = REGMAP_PIPELINE_PIPE_SRC_MODE_INDEX  * 32;
  localparam int unsigned GAIN_BIT  = REGMAP_PIPELINE_PIPE_SRC_GAIN_INDEX  * 32;
  localparam int unsigned TONE_BIT  = REGMAP_PIPELINE_PIPE_SRC_TONE_INDEX  * 32;
  localparam int unsigned SEED_BIT  = REGMAP_PIPELINE_PIPE_SRC_SEED_INDEX  * 32;
  localparam int unsigned ALGN_BIT  = REGMAP_PIPELINE_PIPE_ALIGN_CFG_INDEX * 32;

  assign cfg_src_enable    = csr_i[CTRL_BIT + REGMAP_PIPELINE_PIPE_CTRL_SRC_ENABLE_LSB];
  assign cfg_src_run       = csr_i[CTRL_BIT + REGMAP_PIPELINE_PIPE_CTRL_SRC_RUN_LSB];
  assign cfg_align_enable  = csr_i[CTRL_BIT + REGMAP_PIPELINE_PIPE_CTRL_ALIGN_ENABLE_LSB];
  assign cfg_align_run     = csr_i[CTRL_BIT + REGMAP_PIPELINE_PIPE_CTRL_ALIGN_RUN_LSB];
  assign cfg_align_partial = csr_i[CTRL_BIT + REGMAP_PIPELINE_PIPE_CTRL_ALIGN_PARTIAL_LSB];
  assign cfg_align_unsafe  = csr_i[CTRL_BIT + REGMAP_PIPELINE_PIPE_CTRL_ALIGN_FORCE_UNSAFE_LSB];

  assign cfg_counter_clear = pulse_i[CTRL_BIT + REGMAP_PIPELINE_PIPE_CTRL_COUNTER_CLEAR_LSB];
  assign cfg_status_clear  = pulse_i[CTRL_BIT + REGMAP_PIPELINE_PIPE_CTRL_STATUS_CLEAR_LSB];
  assign cfg_src_reseed    = pulse_i[CTRL_BIT + REGMAP_PIPELINE_PIPE_CTRL_SRC_RESEED_LSB];

  assign cfg_src_mode = 3'(csr_i[MODE_BIT + REGMAP_PIPELINE_PIPE_SRC_MODE_MODE_LSB +:
                                  REGMAP_PIPELINE_PIPE_SRC_MODE_MODE_WIDTH]);

  assign cfg_src_gain = csr_i[GAIN_BIT +: 32];

  assign cfg_src_tone_step =
      16'(csr_i[TONE_BIT + REGMAP_PIPELINE_PIPE_SRC_TONE_TONE_STEP_LSB +:
                 REGMAP_PIPELINE_PIPE_SRC_TONE_TONE_STEP_WIDTH]);
  assign cfg_src_ant_step =
      16'(csr_i[TONE_BIT + REGMAP_PIPELINE_PIPE_SRC_TONE_ANT_STEP_LSB +:
                 REGMAP_PIPELINE_PIPE_SRC_TONE_ANT_STEP_WIDTH]);

  assign cfg_src_seed = csr_i[SEED_BIT +: 32];

  assign cfg_align_frame_off =
      16'(csr_i[ALGN_BIT + REGMAP_PIPELINE_PIPE_ALIGN_CFG_FRAME_OFF_LSB +:
                 REGMAP_PIPELINE_PIPE_ALIGN_CFG_FRAME_OFF_WIDTH]);
  assign cfg_align_lane_stall =
      8'(csr_i[ALGN_BIT + REGMAP_PIPELINE_PIPE_ALIGN_CFG_LANE_STALL_LSB +:
                REGMAP_PIPELINE_PIPE_ALIGN_CFG_LANE_STALL_WIDTH]);

  // ---------------------------------------------------------------------------
  // Elaboration checks against the geometry this instance was built for.
  //
  // The generated map fixes the field widths; the parameters fix what has to fit
  // in them. A configuration that outgrows a field fails at time zero with the
  // number that outgrew it, rather than by silently truncating a lane count in a
  // status register nobody reads carefully.
  // ---------------------------------------------------------------------------
`ifndef SYNTHESIS
  initial begin
    if (BIN_PAR > (1 << REGMAP_PIPELINE_PIPE_GEOMETRY_BIN_PAR_WIDTH) - 1) begin
      $fatal(1, "reg_block_pipeline: BIN_PAR=%0d does not fit PIPE_GEOMETRY.BIN_PAR (%0d bits)",
             BIN_PAR, REGMAP_PIPELINE_PIPE_GEOMETRY_BIN_PAR_WIDTH);
    end
    if (ALIGN_GROUPS > (1 << REGMAP_PIPELINE_PIPE_GEOMETRY_ALIGN_GROUPS_WIDTH) - 1) begin
      $fatal(1, "reg_block_pipeline: ALIGN_GROUPS=%0d does not fit PIPE_GEOMETRY.ALIGN_GROUPS (%0d bits)",
             ALIGN_GROUPS, REGMAP_PIPELINE_PIPE_GEOMETRY_ALIGN_GROUPS_WIDTH);
    end
    if (LANES > (1 << REGMAP_PIPELINE_PIPE_GEOMETRY_LANES_WIDTH) - 1) begin
      $fatal(1, "reg_block_pipeline: LANES=%0d does not fit PIPE_GEOMETRY.LANES (%0d bits)",
             LANES, REGMAP_PIPELINE_PIPE_GEOMETRY_LANES_WIDTH);
    end
    // The lane-stall mask is a test hook; a build with more lanes than the mask
    // can name would leave the top lanes unstallable and the hook would quietly
    // stop covering them.
    if (BIN_PAR > REGMAP_PIPELINE_PIPE_ALIGN_CFG_LANE_STALL_WIDTH) begin
      $fatal(1, "reg_block_pipeline: BIN_PAR=%0d exceeds PIPE_ALIGN_CFG.LANE_STALL (%0d bits)",
             BIN_PAR, REGMAP_PIPELINE_PIPE_ALIGN_CFG_LANE_STALL_WIDTH);
    end
  end
`endif

endmodule : reg_block_pipeline

`default_nettype wire
