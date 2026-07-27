// -----------------------------------------------------------------------------
// fault_injection -- per-block fault-injection dispatcher (issue #19, SPEC 24).
//
// This module owns the DBG_FAULT_TARGET / DBG_FAULT_REPORT half of the debug
// window at 0x8000 (the snapshot half is snapshot_debug.sv). Given
//   * the arm+trigger pulse from reg_block_fault at 0x3000 (bit-per-type mask),
//   * a per-block target mask from DBG_FAULT_TARGET,
// it emits one cycle-wide fault pulse per block per triggered type, and sets
// sticky report bits per block. Safe-disable-by-default: all-zero writes to
// either window inject nothing.
//
// The choice to route both the type mask AND the block mask through separate
// registers is deliberate: two failed writes are less likely to converge on a
// coherent fault than one. A single-shot corruption at 0x3000 arms every block
// only if the target bit at 0x8020 is also set, and vice versa.
//
// Clock domain: cfg_clk. The per-block fault outputs are consumed by wrappers
// around the target blocks (see benchmark_sim_top wiring); each output is
// synchronized into the block's own domain by that wrapper's cdc_pulse. This
// keeps the fault dispatcher itself single-domain and testable at one clock.
// -----------------------------------------------------------------------------

`default_nettype none

module fault_injection
  import reg_if_pkg::*;
  import regmap_pkg::*;
#(
    parameter int unsigned IDX_W = REGMAP_WINDOW_W - 2
) (
    input  wire                                 clk,
    input  wire                                 rst_n,

    // ---- shared register-plane inputs (from reg_fabric) ----
    input  wire                                 sel,
    input  wire                                 write_enable,
    input  wire                                 read_enable,
    input  wire [IDX_W-1:0]                     index,
    input  wire [REG_DATA_W-1:0]                write_data,
    input  wire [REG_STRB_W-1:0]                byte_enable,

    output wire [REG_DATA_W-1:0]                read_data,
    output wire                                 ready,
    output wire                                 error,

    output wire [REGMAP_DEBUG_N_REGS*32-1:0]    csr,
    output wire [REGMAP_DEBUG_N_REGS*32-1:0]    pulse,

    // ---- fault-injection input from reg_block_fault at 0x3000 ----
    // Any non-zero bit means at least one fault type fired this cycle. We do
    // not distinguish types here; the type dimension is already sticky in
    // FAULT_STATUS at 0x3000.
    input  wire [31:0]                          fault_type_pulse,

    // ---- snapshot inputs (routed here so one CSR file owns the whole 0x8000
    //      window). See snapshot_debug.sv for the design of the ring buffer.
    // The status word is packed to match DBG_SNAP_STATUS's field layout: bits
    // [0:3] are the four control flags and bits [16:27] are WR_PTR. Reserved
    // bits are deliberately zero. ---- ----
    /* verilator lint_off UNUSEDSIGNAL */
    input  wire [31:0]                          snap_hw_status,     // CAPTURING/DONE/OVERRUN/SOURCE_INVALID/WR_PTR
    /* verilator lint_on UNUSEDSIGNAL */
    input  wire [31:0]                          snap_hw_data_lo,
    input  wire [31:0]                          snap_hw_data_hi,
    input  wire [31:0]                          snap_hw_data_meta,
    input  wire [7:0]                           snap_hw_n_sources,
    input  wire [11:0]                          snap_hw_buf_depth,

    // ---- memory-interface hw status (routed here for the same reason) ----
    input  wire [7:0]                           mem_hw_inflight,
    input  wire [7:0]                           mem_hw_max_inflight,
    input  wire [7:0]                           mem_hw_outstanding_tag,
    input  wire                                 mem_hw_fault_range,
    input  wire                                 mem_hw_fault_protocol,
    input  wire                                 mem_hw_fault_timeout,
    input  wire [31:0]                          mem_hw_req_count,
    input  wire [31:0]                          mem_hw_rsp_count,

    // ---- per-block fault pulses out ----
    // One cycle wide, in cfg_clk. A wrapper around each block synchronizes to
    // its domain and applies the fault. Bit assignment matches
    // DBG_FAULT_TARGET's field layout.
    output wire [7:0]                           block_fault_pulse
);

  localparam int unsigned N = REGMAP_DEBUG_N_REGS;

  wire [N*32-1:0] csr_w;
  wire [N*32-1:0] pulse_w;

  // ---- read DBG_FAULT_TARGET's mask (low 8 bits are the per-block mask) ----
  /* verilator lint_off UNUSEDSIGNAL */
  wire [31:0] target_word = csr_w[REGMAP_DEBUG_DBG_FAULT_TARGET_INDEX * 32 +: 32];
  /* verilator lint_on UNUSEDSIGNAL */
  wire [7:0]  target_mask = target_word[7:0];

  // ---- per-block pulse: any type fired AND that block is targeted ----
  wire any_type_pulse = |fault_type_pulse;
  assign block_fault_pulse = target_mask & {8{any_type_pulse}};

  // ---------------------------------------------------------------------------
  // Snapshot capture ring lives in snapshot_debug.sv; the DBG_SNAP_CTRL /
  // DBG_SNAP_SOURCE / DBG_SNAP_DEPTH / DBG_SNAP_POINTER registers here drive
  // that module. We use the CSR block's csr_w output to expose the current
  // values as OUTPUT ports of this module (snap_ctrl_out below), which the
  // snapshot_debug.sv module consumes.
  // ---------------------------------------------------------------------------

  // ---- hw_value / hw_set assembly ----
  logic [N*32-1:0] hw_value;
  logic [N*32-1:0] hw_set;
  always_comb begin
    hw_value = '0;
    hw_set   = '0;

    // ---- DBG_SNAP_SOURCE.N_SOURCES ----
    hw_value[REGMAP_DEBUG_DBG_SNAP_SOURCE_INDEX*32
             + REGMAP_DEBUG_DBG_SNAP_SOURCE_N_SOURCES_LSB
             +: REGMAP_DEBUG_DBG_SNAP_SOURCE_N_SOURCES_WIDTH] = snap_hw_n_sources;

    // ---- DBG_SNAP_DEPTH.BUF_DEPTH ----
    hw_value[REGMAP_DEBUG_DBG_SNAP_DEPTH_INDEX*32
             + REGMAP_DEBUG_DBG_SNAP_DEPTH_BUF_DEPTH_LSB
             +: REGMAP_DEBUG_DBG_SNAP_DEPTH_BUF_DEPTH_WIDTH] = snap_hw_buf_depth;

    // ---- DBG_SNAP_STATUS: driven by snapshot_debug via snap_hw_status ----
    // Bit layout: [0]=CAPTURING (ROHW), [1]=CAPTURE_DONE (W1C set),
    // [2]=OVERRUN (W1C set), [3]=SOURCE_INVALID (W1C set), [16..27]=WR_PTR.
    hw_value[REGMAP_DEBUG_DBG_SNAP_STATUS_INDEX*32
             + REGMAP_DEBUG_DBG_SNAP_STATUS_CAPTURING_LSB] = snap_hw_status[0];
    hw_set  [REGMAP_DEBUG_DBG_SNAP_STATUS_INDEX*32
             + REGMAP_DEBUG_DBG_SNAP_STATUS_CAPTURE_DONE_LSB] = snap_hw_status[1];
    hw_set  [REGMAP_DEBUG_DBG_SNAP_STATUS_INDEX*32
             + REGMAP_DEBUG_DBG_SNAP_STATUS_OVERRUN_LSB] = snap_hw_status[2];
    hw_set  [REGMAP_DEBUG_DBG_SNAP_STATUS_INDEX*32
             + REGMAP_DEBUG_DBG_SNAP_STATUS_SOURCE_INVALID_LSB] = snap_hw_status[3];
    hw_value[REGMAP_DEBUG_DBG_SNAP_STATUS_INDEX*32
             + REGMAP_DEBUG_DBG_SNAP_STATUS_WR_PTR_LSB
             +: REGMAP_DEBUG_DBG_SNAP_STATUS_WR_PTR_WIDTH] = snap_hw_status[27:16];

    // ---- DBG_SNAP_DATA / DATA_HI / DATA_META ----
    hw_value[REGMAP_DEBUG_DBG_SNAP_DATA_INDEX*32      +: 32] = snap_hw_data_lo;
    hw_value[REGMAP_DEBUG_DBG_SNAP_DATA_HI_INDEX*32   +: 32] = snap_hw_data_hi;
    hw_value[REGMAP_DEBUG_DBG_SNAP_DATA_META_INDEX*32 +: 32] = snap_hw_data_meta;

    // ---- DBG_FAULT_REPORT (W1C sticky): one bit per triggered pulse ----
    hw_set[REGMAP_DEBUG_DBG_FAULT_REPORT_INDEX*32
           + REGMAP_DEBUG_DBG_FAULT_REPORT_PFB_LSB]        = block_fault_pulse[0];
    hw_set[REGMAP_DEBUG_DBG_FAULT_REPORT_INDEX*32
           + REGMAP_DEBUG_DBG_FAULT_REPORT_FFT_LSB]        = block_fault_pulse[1];
    hw_set[REGMAP_DEBUG_DBG_FAULT_REPORT_INDEX*32
           + REGMAP_DEBUG_DBG_FAULT_REPORT_BEAMFORMER_LSB] = block_fault_pulse[2];
    hw_set[REGMAP_DEBUG_DBG_FAULT_REPORT_INDEX*32
           + REGMAP_DEBUG_DBG_FAULT_REPORT_COVARIANCE_LSB] = block_fault_pulse[3];
    hw_set[REGMAP_DEBUG_DBG_FAULT_REPORT_INDEX*32
           + REGMAP_DEBUG_DBG_FAULT_REPORT_CFAR_LSB]       = block_fault_pulse[4];
    hw_set[REGMAP_DEBUG_DBG_FAULT_REPORT_INDEX*32
           + REGMAP_DEBUG_DBG_FAULT_REPORT_PACKET_LSB]     = block_fault_pulse[5];
    hw_set[REGMAP_DEBUG_DBG_FAULT_REPORT_INDEX*32
           + REGMAP_DEBUG_DBG_FAULT_REPORT_MEMORY_LSB]     = block_fault_pulse[6];
    hw_set[REGMAP_DEBUG_DBG_FAULT_REPORT_INDEX*32
           + REGMAP_DEBUG_DBG_FAULT_REPORT_HISTORY_LSB]    = block_fault_pulse[7];

    // ---- DBG_MEM_STATUS ----
    hw_value[REGMAP_DEBUG_DBG_MEM_STATUS_INDEX*32
             + REGMAP_DEBUG_DBG_MEM_STATUS_INFLIGHT_LSB
             +: REGMAP_DEBUG_DBG_MEM_STATUS_INFLIGHT_WIDTH] = mem_hw_inflight;
    hw_value[REGMAP_DEBUG_DBG_MEM_STATUS_INDEX*32
             + REGMAP_DEBUG_DBG_MEM_STATUS_HW_MAX_INFLIGHT_LSB
             +: REGMAP_DEBUG_DBG_MEM_STATUS_HW_MAX_INFLIGHT_WIDTH] = mem_hw_max_inflight;
    hw_value[REGMAP_DEBUG_DBG_MEM_STATUS_INDEX*32
             + REGMAP_DEBUG_DBG_MEM_STATUS_OUTSTANDING_TAG_LSB
             +: REGMAP_DEBUG_DBG_MEM_STATUS_OUTSTANDING_TAG_WIDTH] = mem_hw_outstanding_tag;
    hw_set  [REGMAP_DEBUG_DBG_MEM_STATUS_INDEX*32
             + REGMAP_DEBUG_DBG_MEM_STATUS_FAULT_RANGE_LSB]    = mem_hw_fault_range;
    hw_set  [REGMAP_DEBUG_DBG_MEM_STATUS_INDEX*32
             + REGMAP_DEBUG_DBG_MEM_STATUS_FAULT_PROTOCOL_LSB] = mem_hw_fault_protocol;
    hw_set  [REGMAP_DEBUG_DBG_MEM_STATUS_INDEX*32
             + REGMAP_DEBUG_DBG_MEM_STATUS_FAULT_TIMEOUT_LSB]  = mem_hw_fault_timeout;

    // ---- DBG_MEM_REQ_COUNT / RSP_COUNT ----
    hw_value[REGMAP_DEBUG_DBG_MEM_REQ_COUNT_INDEX*32 +: 32] = mem_hw_req_count;
    hw_value[REGMAP_DEBUG_DBG_MEM_RSP_COUNT_INDEX*32 +: 32] = mem_hw_rsp_count;
  end

  assign csr   = csr_w;
  assign pulse = pulse_w;

  reg_csr_block #(
      .N_REGS     (N),
      .IDX_W      (IDX_W),
      .RESET_VAL  (REGMAP_DEBUG_RESET),
      .WMASK      (REGMAP_DEBUG_WMASK),
      .W1C_MASK   (REGMAP_DEBUG_W1CMASK),
      .PULSE_MASK (REGMAP_DEBUG_PULSEMASK),
      .HW_MASK    (REGMAP_DEBUG_HWMASK)
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

endmodule : fault_injection

`default_nettype wire
