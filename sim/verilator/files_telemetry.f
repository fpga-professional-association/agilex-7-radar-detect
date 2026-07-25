// -----------------------------------------------------------------------------
// files_telemetry.f — file list for the telemetry unit-test build (issue #8).
//
// Verilates `telemetry_top` rather than `benchmark_sim_top`, so the telemetry
// tests do not depend on any other RTL existing, compiling or behaving: a
// failure in this build is always a telemetry failure. Same arrangement, for the
// same reason, as files_stream.f, files_cdc.f, files_control.f and files_fxp.f.
//
// Used by:
//   scripts/build_verilator.py --top telemetry_top --files sim/verilator/files_telemetry.f
// which `make lint` and `make sim-tiny` invoke for test_perf_counters and
// test_seq_checker. Paths are repo-relative; order matters (packages first, then
// the assertion checkers the RTL instantiates, then the RTL, then the top).
//
// This list is longer than the other unit-test lists on purpose. Telemetry is
// the one block that touches everything: it measures a real stream (rtl/stream/,
// rtl/common/sync_fifo.sv) and answers the register plane (rtl/control/), and a
// test that measured a fake stream through a fake register interface would prove
// nothing about either connection.
// -----------------------------------------------------------------------------

// ---- include path for the shared assertion macros ----------------------
+incdir+sim/assertions

// ---- generated configuration package -----------------------------------
// Written by scripts/build_verilator.py from config/<name>.json before every
// build. Not committed (see .gitignore). Carries the TELEM_* geometry the top
// and the tests share.
sim/verilator/generated/config_pkg.sv

// ---- shared packages ---------------------------------------------------
rtl/packages/stream_pkg.sv
rtl/control/reg_if_pkg.sv
rtl/control/generated/regmap_pkg.sv

// ---- assertion checkers (SPEC 14) --------------------------------------
// Simulation-only, instantiated inside the RTL under `ifndef SYNTHESIS`, so
// everything built from these primitives is checked in the fast build with no
// test-side wiring. Must precede the RTL that instantiates them.
sim/assertions/stream_protocol_checker.sv
sim/assertions/reg_if_checker.sv
sim/assertions/telemetry_assertions.sv
sim/assertions/seq_checker_assertions.sv

// ---- telemetry primitives (SPEC 9, issue #8) ---------------------------
// perf_counter first: seq_checker and telemetry_block are both built out of it.
rtl/common/perf_counter.sv
rtl/common/seq_checker.sv

// ---- register plane (SPEC 9, issue #7) ---------------------------------
rtl/control/reg_csr_block.sv
rtl/control/reg_fabric.sv

// telemetry_block is the counters block of the register plane, so it follows
// the engine it is built on.
rtl/common/telemetry_block.sv

// ---- the datapath being measured ---------------------------------------
rtl/stream/stream_skid_buffer.sv
rtl/common/sync_fifo.sv

// ---- unit-test top ------------------------------------------------------
sim/verilator/tops/telemetry_top.sv
