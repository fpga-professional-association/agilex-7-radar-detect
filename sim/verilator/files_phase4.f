// -----------------------------------------------------------------------------
// files_phase4.f -- Verilator file list for the phase-4 unit-test top (#19).
// -----------------------------------------------------------------------------

+incdir+sim/assertions

// ---- generated configuration package ----
sim/verilator/generated/config_pkg.sv

// ---- shared packages ----
rtl/packages/fxp_pkg.sv
rtl/packages/stream_pkg.sv
rtl/packages/cdc_pkg.sv

// ---- register-plane packages ----
rtl/control/reg_if_pkg.sv
rtl/control/generated/regmap_pkg.sv

// ---- SPEC 8 CDC primitives ----
rtl/cdc/cdc_sync2.sv
rtl/cdc/cdc_pulse.sv
rtl/cdc/cdc_handshake.sv

// ---- SPEC 14 checkers (only reg_fabric's is instantiated here) ----
sim/assertions/reg_if_checker.sv

// ---- SPEC 9 register plane ----
rtl/control/reg_csr_block.sv
rtl/control/reg_fabric.sv

// ---- Phase-4 control blocks (issue #19) ----
rtl/control/telemetry_regs.sv
rtl/control/snapshot_debug.sv
rtl/control/fault_injection.sv

// ---- Phase-4 abstract memory (issue #19) ----
rtl/memory/mem_req_rsp_if.sv
rtl/memory/mem_arbiter.sv
rtl/memory/behavioral_mem_model.sv

// ---- verification top ----
sim/verilator/tops/phase4_top.sv
