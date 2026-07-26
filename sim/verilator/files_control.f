// -----------------------------------------------------------------------------
// files_control.f — file list for the register/control-plane build (issue #7).
//
// Verilates `control_top` rather than `benchmark_sim_top`, so the register-plane
// tests depend on no other RTL existing, compiling or behaving: a failure in this
// build is always a control-plane failure. Same arrangement, for the same reason,
// as files_fxp.f (numerics) and files_stream.f (stream primitives).
//
// Used by:
//   scripts/build_verilator.py --top control_top --files sim/verilator/files_control.f
// which `make lint` and `make sim-tiny` invoke for test_control_regs. Paths are
// repo-relative; order matters (packages first).
//
// rtl/control/generated/regmap_pkg.sv is produced by scripts/gen_regmap.py from
// control/regmap.json and IS committed, unlike the generated configuration
// package: a clean checkout must lint without running a generator first, and a
// register-map change should be a reviewable diff. `make regmap-check` proves it
// still matches the source of truth, and both `make lint` and `make sim-tiny`
// depend on that check.
// -----------------------------------------------------------------------------

// ---- generated configuration package -----------------------------------
// Written by scripts/build_verilator.py from config/<name>.json before every
// build. Not committed (see .gitignore). reg_block_build_params reads it.
sim/verilator/generated/config_pkg.sv

// ---- register-plane packages -------------------------------------------
// The protocol definition (hand written, normative) and the register map
// (generated from control/regmap.json). Packages precede their consumers.
rtl/control/reg_if_pkg.sv
rtl/control/generated/regmap_pkg.sv

// The covariance window's block checks its generated reset values against the
// kernel's own package at elaboration (issue #13), so that package - and the
// numerics package it is derived from - is part of this build even though no
// covariance datapath is.
rtl/packages/fxp_pkg.sv
rtl/packages/covar_pkg.sv

// ---- protocol assertions (SPEC 14) -------------------------------------
// Instantiated inside reg_fabric under `ifndef SYNTHESIS`, so the protocol is
// checked everywhere the fabric is used. Must precede the RTL that instantiates
// it.
sim/assertions/reg_if_checker.sv

// ---- control plane (SPEC 9) --------------------------------------------
rtl/control/reg_csr_block.sv
rtl/control/reg_block_id.sv
rtl/control/reg_block_build_params.sv
rtl/control/reg_block_ctrl.sv
rtl/control/reg_block_fault.sv
rtl/control/reg_block_scratch.sv
rtl/control/reg_block_coeff.sv
rtl/control/reg_block_covar.sv
rtl/control/reg_fabric.sv

// ---- deliberately dead block (simulation only) -------------------------
// Never answers. Attached to a second fabric instance in control_top so the
// watchdog escape is an exercised path. Knowingly wrong RTL: it appears in no
// other file list and can never reach a synthesis build.
sim/verilator/tops/reg_block_dead.sv

// ---- unit-test top ------------------------------------------------------
sim/verilator/tops/control_top.sv
