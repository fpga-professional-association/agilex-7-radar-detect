// -----------------------------------------------------------------------------
// files_cdc.f — file list for the CDC / FIFO unit-test build (SPEC 8, 13.1).
//
// Verilates `cdc_prims_top` instead of `benchmark_sim_top`, so the unit tests
// for rtl/cdc/ and rtl/common/sync_fifo.sv do not depend on any other RTL
// existing, compiling or behaving: a failure in this build is always a CDC or
// FIFO failure. Same arrangement, for the same reason, as files_stream.f and
// files_fxp.f.
//
// Used by:
//   scripts/build_verilator.py --top cdc_prims_top --files sim/verilator/files_cdc.f
// which `make sim-tiny` invokes for test_sync_fifo, test_async_fifo and
// test_cdc_synchronizers, and by scripts/cdc_inventory.py, which elaborates this
// same list to produce the SPEC 8 CDC inventory report. Paths are repo-relative;
// order matters (packages first, then the assertion checkers the primitives
// instantiate, then the primitives, then the top).
// -----------------------------------------------------------------------------

// ---- include path for the shared assertion macros ----------------------
+incdir+sim/assertions

// ---- generated configuration package -----------------------------------
sim/verilator/generated/config_pkg.sv

// ---- shared packages ---------------------------------------------------
// SPEC 8: one shared CDC package, the single definition of the Gray code and of
// the default synchronizer depth.
rtl/packages/cdc_pkg.sv

// SPEC 5: the stream bundle's packed layout, used by stream_cdc and by the
// protocol checkers.
rtl/packages/stream_pkg.sv

// ---- assertion checkers (SPEC 14) --------------------------------------
// Simulation-only. Instantiated inside the primitives under `ifndef SYNTHESIS`,
// so a design built from them is checked everywhere in the fast build with no
// test-side wiring. Must precede the RTL that instantiates them.
sim/assertions/cdc_gray_checker.sv
sim/assertions/cdc_handshake_checker.sv
sim/assertions/stream_protocol_checker.sv

// ---- CDC primitives (SPEC 8) -------------------------------------------
// cdc_sync2 first: every other crossing is built out of instances of it.
rtl/cdc/cdc_sync2.sv
rtl/cdc/cdc_pulse.sv
rtl/cdc/cdc_handshake.sv
rtl/cdc/async_fifo.sv
rtl/cdc/stream_cdc.sv

// ---- common RTL --------------------------------------------------------
rtl/common/sync_fifo.sv

// ---- unit-test top ------------------------------------------------------
sim/verilator/tops/cdc_prims_top.sv
