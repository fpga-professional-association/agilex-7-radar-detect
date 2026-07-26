// -----------------------------------------------------------------------------
// files_history.f — Verilator file list for the SPEC.md 7.3 time-frequency
// history and corner turn (issue #15), top module `history_top`.
//
// Packages first, then the CDC and common primitives this block consumes, then
// the SPEC 14 property set (which rtl/memory/history_core.sv instantiates
// directly and which must therefore precede it), then the block, then the
// verification top and the Quartus calibration wrappers.
//
// The calibration wrappers are listed here for the reason files_fft.f and
// files_beamformer.f list theirs: RTL that no lint ever sees is RTL that rots,
// and a wrapper that stops elaborating is discovered on the next SPEC 18 sweep
// rather than on the next `make lint`.
// -----------------------------------------------------------------------------

// ---- include path for the shared assertion macros ---------------------------
+incdir+sim/assertions

// ---- generated configuration (scripts/build_verilator.py) -------------------
sim/verilator/generated/config_pkg.sv

// ---- packages ---------------------------------------------------------------
rtl/packages/fxp_pkg.sv
rtl/packages/stream_pkg.sv
rtl/packages/cdc_pkg.sv
rtl/packages/history_pkg.sv

// ---- CDC primitives (issue #6) ----------------------------------------------
rtl/cdc/cdc_sync2.sv
rtl/cdc/cdc_handshake.sv
rtl/cdc/cdc_pulse.sv

// ---- common primitives (issues #5, #8) --------------------------------------
rtl/common/sync_fifo.sv
rtl/common/perf_counter.sv

// ---- SPEC 14 property set ---------------------------------------------------
// Instantiated directly by rtl/memory/history_core.sv under `ifndef SYNTHESIS`.
// Must precede the module that instantiates it.
sim/assertions/history_wr_assertions.sv
sim/assertions/history_rd_assertions.sv

// ---- the block --------------------------------------------------------------
rtl/memory/history_bank.sv
rtl/memory/history_core.sv

// ---- verification top -------------------------------------------------------
sim/verilator/tops/history_top.sv

// ---- SPEC 18 calibration wrappers (Quartus-side, linted here) ---------------
quartus/calibration/history_bank_wrap.sv
quartus/calibration/history_core_wrap.sv
