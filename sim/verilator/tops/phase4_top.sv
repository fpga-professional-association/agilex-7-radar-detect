// -----------------------------------------------------------------------------
// phase4_top -- unit-test top for the phase-4 register/memory modules (#19).
//
// Holds:
//   * telemetry_regs.sv                cfg_clk register interface, tel_clk counters
//   * snapshot_debug.sv                one-clock ring buffer, driven by fault_injection
//   * fault_injection.sv               debug window register file + per-block dispatch
//   * mem_arbiter.sv                   N-to-1 abstract-memory arbiter
//   * behavioral_mem_model.sv          deterministic-latency responder
//
// The test drives:
//   * cfg_clk register plane through the reg_fabric that owns the debug + telemetry windows,
//   * telemetry_clk event inputs,
//   * one core_clk source stream into snapshot_debug,
//   * one abstract-memory producer into mem_arbiter (through the packet fabric in the
//     pipeline top, but here directly against the arbiter).
//
// One instance of each module keeps a phase-4 failure locatable to the module that
// caused it, exactly as every other top in this project isolates one thing.
// -----------------------------------------------------------------------------

`default_nettype none

module phase4_top
  import reg_if_pkg::*;
  import regmap_pkg::*;
  import mem_pkg::*;
(
    // ---- clocks and resets ----
    input  wire                     cfg_clk,
    input  wire                     cfg_rst_n,
    input  wire                     tel_clk,
    input  wire                     tel_rst_n,
    input  wire                     core_clk,
    input  wire                     core_rst_n,

    // ---- register-plane master port ----
    input  wire [REG_ADDR_W-1:0]    address,
    input  wire [REG_DATA_W-1:0]    write_data,
    input  wire [REG_STRB_W-1:0]    byte_enable,
    input  wire                     write_enable,
    input  wire                     read_enable,
    output wire [REG_DATA_W-1:0]    read_data,
    output wire                     ready,
    output wire                     error,

    // ---- telemetry_clk event pins ----
    input  wire                     ev_detection,
    input  wire                     ev_packet_delivery,
    input  wire                     ev_packet_drop,
    input  wire                     ev_fault_inject,
    input  wire                     ev_cdc_error,
    input  wire                     ev_overflow,
    input  wire                     ev_saturate,
    input  wire                     ev_seq_error,
    input  wire                     ev_mem_error,
    input  wire                     ev_cfar_fault,

    // ---- snapshot source ports (in core_clk) ----
    input  wire [7:0]               src_valid,
    input  wire [7:0]               src_sof,        // per source, packed into src_meta below
    input  wire [7:0]               src_eof,
    input  wire [8*64-1:0]          src_data,       // 64 bits per source
    input  wire [8*16-1:0]          src_seq,
    input  wire [8*4-1:0]           src_id,
    input  wire                     any_fault,

    // ---- abstract memory producer port (in core_clk) ----
    input  wire                     mem_req_valid,
    output wire                     mem_req_ready,
    input  mem_req_t                mem_req,
    output wire                     mem_rsp_valid,
    input  wire                     mem_rsp_ready,
    output mem_rsp_t                mem_rsp,

    // ---- fault-type pulse (simulates the 0x3000 output for the test) ----
    input  wire [31:0]              test_fault_type_pulse,

    // ---- observation ----
    output wire [7:0]               obs_block_fault_pulse,
    output wire [31:0]              obs_mem_req_count,
    output wire [31:0]              obs_mem_rsp_count
);

  // ---- fabric owning only the two Phase-4 windows ----
  localparam int unsigned NB    = 2;   // debug + telemetry
  localparam int unsigned IDX_W = REGMAP_WINDOW_W - 2;

  wire [NB-1:0]              blk_sel;
  wire                       blk_write_enable;
  wire                       blk_read_enable;
  wire [IDX_W-1:0]           blk_index;
  wire [REG_DATA_W-1:0]      blk_write_data;
  wire [REG_STRB_W-1:0]      blk_byte_enable;
  wire [NB*REG_DATA_W-1:0]   blk_read_data;
  wire [NB-1:0]              blk_ready;
  wire [NB-1:0]              blk_error;

  // Base for two blocks: debug @ 0x8000, telemetry @ 0xC000.
  localparam logic [NB*REG_ADDR_W-1:0] PHASE4_BASE =
      {REG_ADDR_W'(16'hC000), REG_ADDR_W'(16'h8000)};

  reg_fabric #(
      .N_BLOCKS   (NB),
      .WINDOW_W   (REGMAP_WINDOW_W),
      .BLOCK_BASE (PHASE4_BASE)
  ) u_fabric (
      .clk              (cfg_clk),
      .rst_n            (cfg_rst_n),
      .address          (address),
      .write_data       (write_data),
      .byte_enable      (byte_enable),
      .write_enable     (write_enable),
      .read_enable      (read_enable),
      .read_data        (read_data),
      .ready            (ready),
      .error            (error),
      .blk_sel          (blk_sel),
      .blk_write_enable (blk_write_enable),
      .blk_read_enable  (blk_read_enable),
      .blk_index        (blk_index),
      .blk_write_data   (blk_write_data),
      .blk_byte_enable  (blk_byte_enable),
      .blk_read_data    (blk_read_data),
      .blk_ready        (blk_ready),
      .blk_error        (blk_error)
  );

  // Fabric port 0: debug window, driven by fault_injection.sv.
  // Fabric port 1: telemetry window, driven by telemetry_regs.sv.
  localparam int unsigned P4_DEBUG_PORT     = 0;
  localparam int unsigned P4_TELEMETRY_PORT = 1;

  // ---- assemble source arrays for snapshot_debug ----
  // src_meta layout: {FAULT[27], VALID[26], EOF[25], SOF[24], ID[19:16], SEQ[15:0]}
  wire [8*32-1:0] src_meta;
  for (genvar s = 0; s < 8; s = s + 1) begin : g_src_meta
    assign src_meta[s*32 +: 32] = {
        4'd0,                         // reserved [31:28]
        1'b0,                         // FAULT [27] -- OR'd in by snapshot_debug
        src_valid[s],                 // VALID [26]
        src_eof[s],                   // EOF [25]
        src_sof[s],                   // SOF [24]
        4'd0,                         // reserved [23:20]
        src_id[s*4 +: 4],             // ID [19:16]
        src_seq[s*16 +: 16]           // SEQ [15:0]
    };
  end

  // ---- snapshot_debug ----
  // Wired to fault_injection via its csr word for SNAP_CTRL / SNAP_SOURCE / etc.
  wire [31:0] snap_hw_status;
  wire [31:0] snap_hw_data_lo;
  wire [31:0] snap_hw_data_hi;
  wire [31:0] snap_hw_data_meta;
  wire [7:0]  snap_hw_n_sources;
  wire [11:0] snap_hw_buf_depth;

  // Debug CSR outputs, used to drive snap control fields. Only a subset of
  // words is consumed here (unit-test top); the rest are named _dummy for the
  // lint waiver in sim/verilator/lint_waivers.vlt.
  /* verilator lint_off UNUSEDSIGNAL */
  wire [REGMAP_DEBUG_N_REGS*32-1:0] debug_csr;
  wire [REGMAP_DEBUG_N_REGS*32-1:0] debug_pulse;
  /* verilator lint_on UNUSEDSIGNAL */

  /* verilator lint_off UNUSEDSIGNAL */
  wire [31:0] snap_ctrl_word  = debug_csr  [REGMAP_DEBUG_DBG_SNAP_CTRL_INDEX  * 32 +: 32];
  wire [31:0] snap_ctrl_pulse = debug_pulse[REGMAP_DEBUG_DBG_SNAP_CTRL_INDEX  * 32 +: 32];
  wire [31:0] snap_source_word= debug_csr  [REGMAP_DEBUG_DBG_SNAP_SOURCE_INDEX* 32 +: 32];
  wire [31:0] snap_depth_word = debug_csr  [REGMAP_DEBUG_DBG_SNAP_DEPTH_INDEX * 32 +: 32];
  wire [31:0] snap_ptr_word   = debug_csr  [REGMAP_DEBUG_DBG_SNAP_POINTER_INDEX*32 +: 32];
  wire [31:0] mem_ctrl_word   = debug_csr  [REGMAP_DEBUG_DBG_MEM_CTRL_INDEX   * 32 +: 32];
  wire [31:0] mem_ctrl_pulse  = debug_pulse[REGMAP_DEBUG_DBG_MEM_CTRL_INDEX   * 32 +: 32];
  /* verilator lint_on UNUSEDSIGNAL */

  wire snap_arm      = snap_ctrl_word [REGMAP_DEBUG_DBG_SNAP_CTRL_ARM_LSB];
  wire snap_trigger  = snap_ctrl_pulse[REGMAP_DEBUG_DBG_SNAP_CTRL_TRIGGER_LSB];
  wire snap_stat_clr = snap_ctrl_pulse[REGMAP_DEBUG_DBG_SNAP_CTRL_STATUS_CLEAR_LSB];
  wire snap_one_shot = snap_ctrl_word [REGMAP_DEBUG_DBG_SNAP_CTRL_ONE_SHOT_LSB];
  wire [3:0]  snap_src_sel = snap_source_word[REGMAP_DEBUG_DBG_SNAP_SOURCE_SOURCE_SEL_LSB +:
                                              REGMAP_DEBUG_DBG_SNAP_SOURCE_SOURCE_SEL_WIDTH];
  wire [11:0] snap_depth   = snap_depth_word[REGMAP_DEBUG_DBG_SNAP_DEPTH_DEPTH_LSB +:
                                              REGMAP_DEBUG_DBG_SNAP_DEPTH_DEPTH_WIDTH];
  wire [11:0] snap_rd_index= snap_ptr_word[REGMAP_DEBUG_DBG_SNAP_POINTER_INDEX_LSB +:
                                            REGMAP_DEBUG_DBG_SNAP_POINTER_INDEX_WIDTH];
  wire        snap_auto_inc= snap_ptr_word[REGMAP_DEBUG_DBG_SNAP_POINTER_AUTO_INC_LSB];

  // Reading DBG_SNAP_DATA -- we detect the transaction by looking at fabric
  // access to that specific offset while ready is asserted. Simpler: pulse on
  // any read to DBG_SNAP_DATA_ADDR. We do not have that flag directly; use a
  // one-cycle read-fire detector from the fabric select and index.
  wire snap_rd_fire = (blk_sel[P4_DEBUG_PORT] && blk_read_enable
                      && (blk_index == IDX_W'(REGMAP_DEBUG_DBG_SNAP_DATA_INDEX)));

  // The snapshot ring is in core_clk. Drive its inputs directly here (unit
  // test); the pipeline top wraps this with source-side stream_cdc when needed.
  snapshot_debug #(
      .BUF_DEPTH (128),
      .N_SOURCES (8)
  ) u_snap (
      .clk               (core_clk),
      .rst_n             (core_rst_n),
      .snap_arm          (snap_arm),
      .snap_trigger      (snap_trigger),
      .snap_status_clear (snap_stat_clr),
      .snap_one_shot     (snap_one_shot),
      .source_sel        (snap_src_sel),
      .depth_req         (snap_depth),
      .rd_index          (snap_rd_index),
      .rd_auto_inc       (snap_auto_inc),
      .rd_pulse          (snap_rd_fire),
      .src_valid         (src_valid),
      .src_data          (src_data),
      .src_meta          (src_meta),
      .any_fault         (any_fault),
      .snap_hw_status    (snap_hw_status),
      .snap_hw_data_lo   (snap_hw_data_lo),
      .snap_hw_data_hi   (snap_hw_data_hi),
      .snap_hw_data_meta (snap_hw_data_meta),
      .snap_hw_n_sources (snap_hw_n_sources),
      .snap_hw_buf_depth (snap_hw_buf_depth)
  );

  // ---- Behavioural memory model + arbiter, wired to a single producer ----
  wire        cfg_mem_enable    = mem_ctrl_word [REGMAP_DEBUG_DBG_MEM_CTRL_ENABLE_LSB];
  wire        cfg_mem_soft_reset= mem_ctrl_pulse[REGMAP_DEBUG_DBG_MEM_CTRL_SOFT_RESET_LSB];
  wire [7:0]  cfg_mem_latency   = mem_ctrl_word [REGMAP_DEBUG_DBG_MEM_CTRL_LATENCY_LSB +:
                                                 REGMAP_DEBUG_DBG_MEM_CTRL_LATENCY_WIDTH];
  wire [1:0]  cfg_mem_fault_mode= mem_ctrl_word [REGMAP_DEBUG_DBG_MEM_CTRL_FAULT_MODE_LSB +:
                                                 REGMAP_DEBUG_DBG_MEM_CTRL_FAULT_MODE_WIDTH];

  // Bring memory-side observation into the debug register file via fault_injection.
  wire        mem_obs_fault_range;
  wire        mem_obs_fault_protocol;
  wire        mem_obs_fault_timeout;
  wire [31:0] mem_obs_req_count;
  wire [31:0] mem_obs_rsp_count;
  wire [7:0]  mem_obs_inflight;
  wire [7:0]  mem_obs_max_inflight;
  wire [7:0]  mem_obs_outstanding_tag;

  // arbiter <-> memory
  wire       arb_m_req_valid;
  wire       arb_m_req_ready;
  mem_req_t  arb_m_req;
  wire       arb_m_rsp_valid;
  wire       arb_m_rsp_ready;
  mem_rsp_t  arb_m_rsp;

  // Single producer: user's mem_req/mem_rsp
  wire [0:0] s_req_valid_v; assign s_req_valid_v[0] = mem_req_valid;
  wire [0:0] s_req_ready_v;
  assign mem_req_ready = s_req_ready_v[0];
  mem_req_t s_req_v [1]; assign s_req_v[0] = mem_req;
  wire [0:0] s_rsp_valid_v;
  assign mem_rsp_valid = s_rsp_valid_v[0];
  wire [0:0] s_rsp_ready_v; assign s_rsp_ready_v[0] = mem_rsp_ready;
  mem_rsp_t s_rsp_v [1]; assign mem_rsp = s_rsp_v[0];

  mem_arbiter #(
      .N_PORTS               (1),
      .MAX_INFLIGHT_PER_PORT (16)
  ) u_arb (
      .clk                  (core_clk),
      .rst_n                (core_rst_n),
      .s_req_valid          (s_req_valid_v),
      .s_req_ready          (s_req_ready_v),
      .s_req                (s_req_v),
      .s_rsp_valid          (s_rsp_valid_v),
      .s_rsp_ready          (s_rsp_ready_v),
      .s_rsp                (s_rsp_v),
      .m_req_valid          (arb_m_req_valid),
      .m_req_ready          (arb_m_req_ready),
      .m_req                (arb_m_req),
      .m_rsp_valid          (arb_m_rsp_valid),
      .m_rsp_ready          (arb_m_rsp_ready),
      .m_rsp                (arb_m_rsp),
      .cfg_enable           (cfg_mem_enable),
      .cfg_soft_reset       (cfg_mem_soft_reset),
      .obs_inflight         (mem_obs_inflight),
      .obs_max_inflight     (mem_obs_max_inflight),
      .obs_outstanding_tag  (mem_obs_outstanding_tag)
  );

  behavioral_mem_model #(
      .DEPTH_BYTES  (4096),
      .MAX_INFLIGHT (16)
  ) u_mem (
      .clk                (core_clk),
      .rst_n              (core_rst_n),
      .s_req_valid        (arb_m_req_valid),
      .s_req_ready        (arb_m_req_ready),
      .s_req              (arb_m_req),
      .s_rsp_valid        (arb_m_rsp_valid),
      .s_rsp_ready        (arb_m_rsp_ready),
      .s_rsp              (arb_m_rsp),
      .cfg_enable         (cfg_mem_enable),
      .cfg_soft_reset     (cfg_mem_soft_reset),
      .cfg_latency        (cfg_mem_latency),
      .cfg_fault_mode     (cfg_mem_fault_mode),
      .obs_fault_range    (mem_obs_fault_range),
      .obs_fault_protocol (mem_obs_fault_protocol),
      .obs_fault_timeout  (mem_obs_fault_timeout),
      .obs_req_count      (mem_obs_req_count),
      .obs_rsp_count      (mem_obs_rsp_count)
  );

  // ---- fault_injection: debug window register file, wired to snap + mem status ----
  wire [7:0]  block_fault_pulse;
  fault_injection #(
      .IDX_W (IDX_W)
  ) u_fault_inj (
      .clk                  (cfg_clk),
      .rst_n                (cfg_rst_n),
      .sel                  (blk_sel[P4_DEBUG_PORT]),
      .write_enable         (blk_write_enable),
      .read_enable          (blk_read_enable),
      .index                (blk_index),
      .write_data           (blk_write_data),
      .byte_enable          (blk_byte_enable),
      .read_data            (blk_read_data[P4_DEBUG_PORT*REG_DATA_W +: REG_DATA_W]),
      .ready                (blk_ready[P4_DEBUG_PORT]),
      .error                (blk_error[P4_DEBUG_PORT]),
      .csr                  (debug_csr),
      .pulse                (debug_pulse),
      .fault_type_pulse     (test_fault_type_pulse),
      .snap_hw_status       (snap_hw_status),
      .snap_hw_data_lo      (snap_hw_data_lo),
      .snap_hw_data_hi      (snap_hw_data_hi),
      .snap_hw_data_meta    (snap_hw_data_meta),
      .snap_hw_n_sources    (snap_hw_n_sources),
      .snap_hw_buf_depth    (snap_hw_buf_depth),
      .mem_hw_inflight      (mem_obs_inflight),
      .mem_hw_max_inflight  (mem_obs_max_inflight),
      .mem_hw_outstanding_tag(mem_obs_outstanding_tag),
      .mem_hw_fault_range   (mem_obs_fault_range),
      .mem_hw_fault_protocol(mem_obs_fault_protocol),
      .mem_hw_fault_timeout (mem_obs_fault_timeout),
      .mem_hw_req_count     (mem_obs_req_count),
      .mem_hw_rsp_count     (mem_obs_rsp_count),
      .block_fault_pulse    (block_fault_pulse)
  );

  assign obs_block_fault_pulse = block_fault_pulse;
  assign obs_mem_req_count     = mem_obs_req_count;
  assign obs_mem_rsp_count     = mem_obs_rsp_count;

  // ---- telemetry_regs ----
  wire [REGMAP_TELEMETRY_N_REGS*32-1:0] tel_csr_unused;
  wire [REGMAP_TELEMETRY_N_REGS*32-1:0] tel_pulse_unused;

  telemetry_regs #(
      .IDX_W     (IDX_W),
      .RATIO_NUM (5),   // tel:cfg = 5:2 for the test
      .RATIO_DEN (2)
  ) u_tel (
      .cfg_clk            (cfg_clk),
      .cfg_rst_n          (cfg_rst_n),
      .sel                (blk_sel[P4_TELEMETRY_PORT]),
      .write_enable       (blk_write_enable),
      .read_enable        (blk_read_enable),
      .index              (blk_index),
      .write_data         (blk_write_data),
      .byte_enable        (blk_byte_enable),
      .read_data          (blk_read_data[P4_TELEMETRY_PORT*REG_DATA_W +: REG_DATA_W]),
      .ready              (blk_ready[P4_TELEMETRY_PORT]),
      .error              (blk_error[P4_TELEMETRY_PORT]),
      .csr                (tel_csr_unused),
      .pulse              (tel_pulse_unused),
      .tel_clk            (tel_clk),
      .tel_rst_n          (tel_rst_n),
      .ev_detection       (ev_detection),
      .ev_packet_delivery (ev_packet_delivery),
      .ev_packet_drop     (ev_packet_drop),
      .ev_fault_inject    (ev_fault_inject),
      .ev_cdc_error       (ev_cdc_error),
      .ev_overflow        (ev_overflow),
      .ev_saturate        (ev_saturate),
      .ev_seq_error       (ev_seq_error),
      .ev_mem_error       (ev_mem_error),
      .ev_cfar_fault      (ev_cfar_fault)
  );

endmodule : phase4_top

`default_nettype wire
