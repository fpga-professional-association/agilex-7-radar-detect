// -----------------------------------------------------------------------------
// control_top — register/control-plane unit-test top (SPEC 13.1, issue #7).
//
// Everything under rtl/control/ in one place, on one clock (cfg_clk, 100 MHz per
// SPEC 8), with the SPEC 9 master port brought straight to the boundary so the
// C++ register driver in sim/verilator/harness/reg_driver.h can talk to it.
//
//   u_fabric        the real fabric: every implemented block at the windows
//                   control/regmap.json declares.
//   u_fabric_stuck  a second, one-block fabric whose block never answers, so the
//                   watchdog escape is exercised as a path rather than asserted
//                   as a property of unreached code. Wholly independent of the
//                   first: separate ports, separate state, no shared signal but
//                   the clock and the reset.
//
// The counters window (issue #8)
// ------------------------------
// `u_counters` is the SPEC 9 counters block as a REGISTER FILE and nothing else:
// a bare reg_csr_block carrying the generated table for that window, with its
// hardware inputs tied off. The real block — rtl/common/telemetry_block.sv — is
// the same register file plus twenty counters, a high-water tracker and a
// sequence checker, and it needs a stream to measure, which is why it is
// verified in sim/verilator/tops/telemetry_top.sv against real traffic rather
// than here against none.
//
// What this instance is for is the other half: that the window decodes, that
// every access type in it behaves, that a write to a read-only counter is
// refused, and that the randomized soak covers it exactly like every other
// block. Those are properties of the plane, which is what control_top is the top
// for. The hardware-driven fields consequently read zero here and their real
// values in telemetry_top; both are checked, each in the top where it is the
// subject.
//
// A stub rather than the real block, because control_top's contract with
// test_control_regs is that a C++ model built purely from the generated tables
// predicts every response. A block whose read data depends on live traffic would
// have to be modelled a second time, inside a test about the register plane, to
// prove something the telemetry test already proves better.
//
// Observation outputs. The block storage (`obs_*_csr`) and the pulse vectors are
// exported so a test can see the register file WITHOUT going through the read
// mux. That is not a convenience: when a readback is wrong, it separates "the
// write did not land" from "the read path is broken", which is otherwise a
// guess. obs_build_storage_zero and obs_static_pulse_any are the two properties
// that hold for every register in a block with no writable or pulse bits, and
// the test checks them every cycle.
//
// Single clock domain, on purpose. The register plane is cfg_clk end to end; the
// crossings into core_clk, packet_clk and telemetry_clk belong to the issue #6
// primitives and to the blocks that consume enables and counters. This top is
// the clean seam: everything in it is synchronous to one clock, so a failure
// here is never a CDC question.
//
// Simulation only. Never synthesized, never in a Quartus source list.
// -----------------------------------------------------------------------------

`default_nettype none

module control_top
  import reg_if_pkg::*;
  import regmap_pkg::*;
(
    input  wire                                 clk,
    input  wire                                 rst_n,

    // ---- SPEC 9 master port ----
    input  wire [REG_ADDR_W-1:0]                address,
    input  wire [REG_DATA_W-1:0]                write_data,
    input  wire [REG_STRB_W-1:0]                byte_enable,
    input  wire                                 write_enable,
    input  wire                                 read_enable,
    output wire [REG_DATA_W-1:0]                read_data,
    output wire                                 ready,
    output wire                                 error,

    // ---- register-file observation ----
    output wire [REGMAP_ID_N_REGS*32-1:0]       obs_id_csr,
    output wire [REGMAP_CTRL_N_REGS*32-1:0]     obs_ctrl_csr,
    output wire [REGMAP_CTRL_N_REGS*32-1:0]     obs_ctrl_pulse,
    output wire [REGMAP_FAULT_N_REGS*32-1:0]    obs_fault_csr,
    output wire [REGMAP_FAULT_N_REGS*32-1:0]    obs_fault_pulse,
    output wire [REGMAP_SCRATCH_N_REGS*32-1:0]  obs_scratch_csr,
    output wire [REGMAP_COEFF_N_REGS*32-1:0]    obs_coeff_csr,
    output wire [REGMAP_COUNTERS_N_REGS*32-1:0] obs_counters_csr,
    // The counters window is the only block here carrying writable storage and
    // pulse bits in the same register, so it is the one place where "a pulse
    // fired" and "a bit was stored" have to be separable without the read mux.
    output wire [REGMAP_COUNTERS_N_REGS*32-1:0] obs_counters_pulse,

    // ---- control outputs the blocks drive ----
    output wire [31:0]                          obs_block_enable,
    output wire [31:0]                          obs_block_reset_pulse,
    output wire [31:0]                          obs_fault_inject,
    output wire [31:0]                          obs_param_checksum,
    output wire                                 obs_global_enable,
    output wire                                 obs_flush_pulse,
    output wire                                 obs_soft_reset_pulse,

    // Invariants of the blocks that have no writable or pulse bits. Both must
    // hold in every cycle of every test.
    output wire                                 obs_build_storage_zero,
    output wire                                 obs_static_pulse_any,

    // ---- second fabric: the never-answering block ----
    input  wire [REG_ADDR_W-1:0]                stuck_address,
    input  wire [REG_DATA_W-1:0]                stuck_write_data,
    input  wire [REG_STRB_W-1:0]                stuck_byte_enable,
    input  wire                                 stuck_write_enable,
    input  wire                                 stuck_read_enable,
    output wire [REG_DATA_W-1:0]                stuck_read_data,
    output wire                                 stuck_ready,
    output wire                                 stuck_error,
    output wire [31:0]                          stuck_swallowed
);

  localparam int unsigned NB    = REGMAP_N_BLOCKS_IMPL;
  localparam int unsigned IDX_W = REGMAP_WINDOW_W - 2;

  // ---------------------------------------------------------------------------
  // Fabric <-> block wiring
  // ---------------------------------------------------------------------------
  wire [NB-1:0]              blk_sel;
  wire                       blk_write_enable;
  wire                       blk_read_enable;
  wire [IDX_W-1:0]           blk_index;
  wire [REG_DATA_W-1:0]      blk_write_data;
  wire [REG_STRB_W-1:0]      blk_byte_enable;
  wire [NB*REG_DATA_W-1:0]   blk_read_data;
  wire [NB-1:0]              blk_ready;
  wire [NB-1:0]              blk_error;

  reg_fabric #(
      .N_BLOCKS   (NB),
      .WINDOW_W   (REGMAP_WINDOW_W),
      .BLOCK_BASE (REGMAP_IMPL_BASE)
  ) u_fabric (
      .clk              (clk),
      .rst_n            (rst_n),
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

  // ---------------------------------------------------------------------------
  // Blocks. Every port index comes from the generated map, never from a literal.
  // ---------------------------------------------------------------------------
  wire [REGMAP_ID_N_REGS*32-1:0]           id_pulse;
  wire [REGMAP_BUILD_PARAMS_N_REGS*32-1:0] build_csr;
  wire [REGMAP_BUILD_PARAMS_N_REGS*32-1:0] build_pulse;
  wire [REGMAP_SCRATCH_N_REGS*32-1:0]      scratch_pulse;

  reg_block_id #(
      .IDX_W (IDX_W)
  ) u_id (
      .clk          (clk),
      .rst_n        (rst_n),
      .sel          (blk_sel[REGMAP_ID_INDEX]),
      .write_enable (blk_write_enable),
      .read_enable  (blk_read_enable),
      .index        (blk_index),
      .write_data   (blk_write_data),
      .byte_enable  (blk_byte_enable),
      .read_data    (blk_read_data[REGMAP_ID_INDEX*REG_DATA_W +: REG_DATA_W]),
      .ready        (blk_ready[REGMAP_ID_INDEX]),
      .error        (blk_error[REGMAP_ID_INDEX]),
      .csr          (obs_id_csr),
      .pulse        (id_pulse)
  );

  reg_block_build_params #(
      .IDX_W (IDX_W)
  ) u_build (
      .clk            (clk),
      .rst_n          (rst_n),
      .sel            (blk_sel[REGMAP_BUILD_PARAMS_INDEX]),
      .write_enable   (blk_write_enable),
      .read_enable    (blk_read_enable),
      .index          (blk_index),
      .write_data     (blk_write_data),
      .byte_enable    (blk_byte_enable),
      .read_data      (blk_read_data[REGMAP_BUILD_PARAMS_INDEX*REG_DATA_W +: REG_DATA_W]),
      .ready          (blk_ready[REGMAP_BUILD_PARAMS_INDEX]),
      .error          (blk_error[REGMAP_BUILD_PARAMS_INDEX]),
      .csr            (build_csr),
      .pulse          (build_pulse),
      .param_checksum (obs_param_checksum)
  );

  reg_block_ctrl #(
      .IDX_W (IDX_W)
  ) u_ctrl (
      .clk               (clk),
      .rst_n             (rst_n),
      .sel               (blk_sel[REGMAP_CTRL_INDEX]),
      .write_enable      (blk_write_enable),
      .read_enable       (blk_read_enable),
      .index             (blk_index),
      .write_data        (blk_write_data),
      .byte_enable       (blk_byte_enable),
      .read_data         (blk_read_data[REGMAP_CTRL_INDEX*REG_DATA_W +: REG_DATA_W]),
      .ready             (blk_ready[REGMAP_CTRL_INDEX]),
      .error             (blk_error[REGMAP_CTRL_INDEX]),
      .csr               (obs_ctrl_csr),
      .pulse             (obs_ctrl_pulse),
      .block_enable      (obs_block_enable),
      .block_reset_pulse (obs_block_reset_pulse),
      .global_enable     (obs_global_enable),
      .flush_pulse       (obs_flush_pulse),
      .soft_reset_pulse  (obs_soft_reset_pulse)
  );

  reg_block_fault #(
      .IDX_W (IDX_W)
  ) u_fault (
      .clk          (clk),
      .rst_n        (rst_n),
      .sel          (blk_sel[REGMAP_FAULT_INDEX]),
      .write_enable (blk_write_enable),
      .read_enable  (blk_read_enable),
      .index        (blk_index),
      .write_data   (blk_write_data),
      .byte_enable  (blk_byte_enable),
      .read_data    (blk_read_data[REGMAP_FAULT_INDEX*REG_DATA_W +: REG_DATA_W]),
      .ready        (blk_ready[REGMAP_FAULT_INDEX]),
      .error        (blk_error[REGMAP_FAULT_INDEX]),
      .csr          (obs_fault_csr),
      .pulse        (obs_fault_pulse),
      .fault_inject (obs_fault_inject)
  );

  reg_block_scratch #(
      .IDX_W (IDX_W)
  ) u_scratch (
      .clk          (clk),
      .rst_n        (rst_n),
      .sel          (blk_sel[REGMAP_SCRATCH_INDEX]),
      .write_enable (blk_write_enable),
      .read_enable  (blk_read_enable),
      .index        (blk_index),
      .write_data   (blk_write_data),
      .byte_enable  (blk_byte_enable),
      .read_data    (blk_read_data[REGMAP_SCRATCH_INDEX*REG_DATA_W +: REG_DATA_W]),
      .ready        (blk_ready[REGMAP_SCRATCH_INDEX]),
      .error        (blk_error[REGMAP_SCRATCH_INDEX]),
      .csr          (obs_scratch_csr),
      .pulse        (scratch_pulse)
  );

  // The coefficient window (issue #10). A real block rather than a bare
  // register file, because it owns the two strobes — the COEFF_DATA write that
  // issues a transfer and the SWAP_REQ pulse — that a bare register file cannot
  // produce.
  //
  // Its hardware status inputs are tied off HERE, exactly as the counters
  // window's are and for the same reason: control_top is the register plane's
  // own test bench, and wiring a live rtl/pfb/coeff_bank.sv into it would make a
  // register-plane failure and a polyphase failure indistinguishable. The live
  // wiring arrives with the medium integration (issue #17);
  // sim/verilator/tops/pfb_top.sv drives the bank's configuration port directly
  // in the meantime.
  wire        coeff_wr_valid_unused, coeff_wr_bank_unused;
  wire [15:0] coeff_wr_index_unused;
  wire [31:0] coeff_wr_data_unused;
  wire        coeff_swap_req_unused, coeff_status_clear_unused;
  wire [REGMAP_COEFF_N_REGS*32-1:0] coeff_pulse;

  reg_block_coeff #(
      .IDX_W (IDX_W)
  ) u_coeff (
      .clk             (clk),
      .rst_n           (rst_n),
      .sel             (blk_sel[REGMAP_COEFF_INDEX]),
      .write_enable    (blk_write_enable),
      .read_enable     (blk_read_enable),
      .index           (blk_index),
      .write_data      (blk_write_data),
      .byte_enable     (blk_byte_enable),
      .read_data       (blk_read_data[REGMAP_COEFF_INDEX*REG_DATA_W +: REG_DATA_W]),
      .ready           (blk_ready[REGMAP_COEFF_INDEX]),
      .error           (blk_error[REGMAP_COEFF_INDEX]),
      .wr_valid        (coeff_wr_valid_unused),
      .wr_bank         (coeff_wr_bank_unused),
      .wr_index        (coeff_wr_index_unused),
      .wr_data         (coeff_wr_data_unused),
      .swap_req        (coeff_swap_req_unused),
      .status_clear    (coeff_status_clear_unused),
      .hw_active_bank  (1'b0),
      .hw_swap_pending (1'b0),
      .hw_wr_busy      (1'b0),
      .hw_swap_busy    (1'b0),
      .hw_wr_reject    (1'b0),
      .hw_swap_overrun (1'b0),
      .hw_n_coeff      (16'd0),
      .csr             (obs_coeff_csr),
      .pulse           (coeff_pulse)
  );

  // The counters window as a bare register file. See the header for why the
  // hardware side is tied off here.
  reg_csr_block #(
      .N_REGS     (REGMAP_COUNTERS_N_REGS),
      .IDX_W      (IDX_W),
      .RESET_VAL  (REGMAP_COUNTERS_RESET),
      .WMASK      (REGMAP_COUNTERS_WMASK),
      .W1C_MASK   (REGMAP_COUNTERS_W1CMASK),
      .PULSE_MASK (REGMAP_COUNTERS_PULSEMASK),
      .HW_MASK    (REGMAP_COUNTERS_HWMASK)
  ) u_counters (
      .clk          (clk),
      .rst_n        (rst_n),
      .sel          (blk_sel[REGMAP_COUNTERS_INDEX]),
      .write_enable (blk_write_enable),
      .read_enable  (blk_read_enable),
      .index        (blk_index),
      .write_data   (blk_write_data),
      .byte_enable  (blk_byte_enable),
      .read_data    (blk_read_data[REGMAP_COUNTERS_INDEX*REG_DATA_W +: REG_DATA_W]),
      .ready        (blk_ready[REGMAP_COUNTERS_INDEX]),
      .error        (blk_error[REGMAP_COUNTERS_INDEX]),
      .hw_value     ('0),
      .hw_set       ('0),
      .csr          (obs_counters_csr),
      .pulse        (obs_counters_pulse)
  );

  // Invariants of the blocks with no writable and no pulse bits.
  assign obs_build_storage_zero = ~(|build_csr);
  assign obs_static_pulse_any   = |{id_pulse, build_pulse, scratch_pulse};

  // COEFF_CTRL carries two RWP bits, so the coefficient window is deliberately
  // NOT part of obs_static_pulse_any; its pulses are observed through the
  // strobe ports above.
  wire coeff_pulse_any_unused = |coeff_pulse;

  // ---------------------------------------------------------------------------
  // Second fabric: one block, which never answers.
  // ---------------------------------------------------------------------------
  wire [0:0]            stuck_sel;
  wire                  stuck_blk_we;
  wire                  stuck_blk_re;
  wire [IDX_W-1:0]      stuck_blk_index;
  wire [REG_DATA_W-1:0] stuck_blk_wdata;
  wire [REG_STRB_W-1:0] stuck_blk_be;
  wire [REG_DATA_W-1:0] stuck_blk_rdata;
  wire                  stuck_blk_ready;
  wire                  stuck_blk_error;

  reg_fabric #(
      .N_BLOCKS   (1),
      .WINDOW_W   (REGMAP_WINDOW_W),
      .BLOCK_BASE (REG_ADDR_W'(0))
  ) u_fabric_stuck (
      .clk              (clk),
      .rst_n            (rst_n),
      .address          (stuck_address),
      .write_data       (stuck_write_data),
      .byte_enable      (stuck_byte_enable),
      .write_enable     (stuck_write_enable),
      .read_enable      (stuck_read_enable),
      .read_data        (stuck_read_data),
      .ready            (stuck_ready),
      .error            (stuck_error),
      .blk_sel          (stuck_sel),
      .blk_write_enable (stuck_blk_we),
      .blk_read_enable  (stuck_blk_re),
      .blk_index        (stuck_blk_index),
      .blk_write_data   (stuck_blk_wdata),
      .blk_byte_enable  (stuck_blk_be),
      .blk_read_data    (stuck_blk_rdata),
      .blk_ready        (stuck_blk_ready),
      .blk_error        (stuck_blk_error)
  );

  reg_block_dead #(
      .IDX_W (IDX_W)
  ) u_dead (
      .clk          (clk),
      .rst_n        (rst_n),
      .sel          (stuck_sel[0]),
      .write_enable (stuck_blk_we),
      .read_enable  (stuck_blk_re),
      .index        (stuck_blk_index),
      .write_data   (stuck_blk_wdata),
      .byte_enable  (stuck_blk_be),
      .read_data    (stuck_blk_rdata),
      .ready        (stuck_blk_ready),
      .error        (stuck_blk_error),
      .swallowed    (stuck_swallowed)
  );

  // ---------------------------------------------------------------------------
  // Elaboration-time agreement between the protocol definition and the map.
  // The same device benchmark_sim_top uses for the stream layout: a mismatch
  // between two independently maintained definitions must fail loudly at time 0
  // rather than as a mysterious decode failure at cycle 40000.
  // ---------------------------------------------------------------------------
`ifndef SYNTHESIS
  initial begin
    if (REGMAP_ADDR_W != REG_ADDR_W) begin
      $fatal(1, "control_top: regmap address width %0d != reg_if_pkg REG_ADDR_W %0d",
             REGMAP_ADDR_W, REG_ADDR_W);
    end
    if (REGMAP_DATA_W != REG_DATA_W) begin
      $fatal(1, "control_top: regmap data width %0d != reg_if_pkg REG_DATA_W %0d",
             REGMAP_DATA_W, REG_DATA_W);
    end
    if (REGMAP_STRB_W != REG_STRB_W) begin
      $fatal(1, "control_top: regmap strobe width %0d != reg_if_pkg REG_STRB_W %0d",
             REGMAP_STRB_W, REG_STRB_W);
    end
  end
`endif

endmodule : control_top

`default_nettype wire
