// -----------------------------------------------------------------------------
// files_cdc_violator.f — file list for the CDC negative assertion test (SPEC 14).
//
// Verilates `cdc_violator_top`: a deliberately broken crossing with the SPEC 14
// CDC checkers attached by `bind`. Kept in its own file list because the RTL in
// it is knowingly wrong and must never reach the design build.
//
// Used by:
//   scripts/build_verilator.py --top cdc_violator_top --files sim/verilator/files_cdc_violator.f
// which `make sim-tiny` invokes for test_cdc_assertions. That test expects
// assertions to FAIL, and reports a run in which the named one did not fire as
// an error.
// -----------------------------------------------------------------------------

+incdir+sim/assertions

// ---- generated configuration package -----------------------------------
sim/verilator/generated/config_pkg.sv

// ---- shared CDC package (SPEC 8) ---------------------------------------
// The violator calls cdc_pkg::cdc_bin2gray for its correct modes, so the same
// encoding is under test as the one async_fifo uses.
rtl/packages/cdc_pkg.sv

// ---- CDC assertion checkers (SPEC 14) ----------------------------------
sim/assertions/cdc_gray_checker.sv
sim/assertions/cdc_handshake_checker.sv

// ---- the broken crossing and its top -------------------------------------
sim/verilator/tops/cdc_violator.sv
sim/verilator/tops/cdc_violator_top.sv
