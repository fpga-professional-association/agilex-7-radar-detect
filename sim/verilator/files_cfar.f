// -----------------------------------------------------------------------------
// files_cfar.f — RTL file list for the CFAR build (issue #14).
//
// A self-contained file list, for the reason every other secondary list in this
// directory is self-contained: a failure in this build is then unambiguously a
// failure of the SPEC 7.7 detector and its numerics, not of the stream fabric,
// the register plane, the FFT, the polyphase bank or the covariance engine, none
// of whose datapaths appear here.
//
// Used by:
//   scripts/build_verilator.py --top cfar_top --files sim/verilator/files_cfar.f
// which `make lint` and `make sim-tiny` invoke. Paths are repo-relative; order
// matters (packages first, then the checker the RTL instantiates, then the DUT
// modules bottom-up, then the top).
//
// The generated config_pkg.sv IS listed: the detector's window maxima are a
// SPEC 11 sizing question and come from config/<name>.json (CFAR_MAX_GUARD,
// CFAR_MAX_REF). The WIDTHS do not — POWER_W is invariant across every
// configuration by SPEC 3, and cfar_pkg derives everything else from covar_pkg
// and fxp_pkg.
//
// covar_pkg is here because cfar_pkg takes its input width from it BY REFERENCE
// rather than by copy (cfar_pkg section 1), and fxp_pkg because covar_pkg is
// derived from it. No covariance DATAPATH is in this build.
//
// rtl/cfar/*.sv and rtl/packages/cfar_pkg.sv are ALSO in files.f: they are
// design RTL, and files.f is the single definition of what "the design" is. This
// list adds only the simulation-only top and its checker.
// -----------------------------------------------------------------------------

// ---- include path for the shared assertion macros ----------------------
+incdir+sim/assertions

// ---- generated configuration package -----------------------------------
// Written by scripts/build_verilator.py from config/<name>.json before every
// build. Not committed (see .gitignore).
sim/verilator/generated/config_pkg.sv

// ---- shared packages ---------------------------------------------------
rtl/packages/fxp_pkg.sv
rtl/packages/covar_pkg.sv
rtl/packages/stream_pkg.sv
rtl/packages/cfar_pkg.sv

// ---- SPEC 14 property set for the detector -----------------------------
// Instantiated directly by rtl/cfar/cfar_core.sv under `ifndef SYNTHESIS`. Must
// precede the module that instantiates it.
sim/assertions/cfar_assertions.sv

// ---- shared primitives the kernel is built on --------------------------
rtl/stream/stream_elastic_buffer.sv
rtl/common/perf_counter.sv

// ---- the kernel (SPEC 7.7, SPEC 19 Phase 2) ----------------------------
rtl/cfar/cfar_window.sv
rtl/cfar/cfar_core.sv

// ---- verification top --------------------------------------------------
sim/verilator/tops/cfar_top.sv
