// -----------------------------------------------------------------------------
// files_covar.f — RTL file list for the power/covariance build (issue #13).
//
// A self-contained file list, for the reason every other secondary list in this
// directory is self-contained: a failure in this build is then unambiguously a
// failure of the SPEC 7.6 power and covariance engine and its numerics, not of
// the stream fabric, the register plane, the FFT or the polyphase bank, none of
// which appear here.
//
// Used by:
//   scripts/build_verilator.py --top covar_top --files sim/verilator/files_covar.f
// which `make lint` and `make sim-tiny` invoke. Paths are repo-relative; order
// matters (packages first, then the checkers the RTL instantiates, then the DUT
// modules bottom-up, then the top).
//
// The generated config_pkg.sv IS listed, unlike files_cmult.f: the covariance
// engine's geometry — how many parallel sources, how many pairs — is a SPEC 11
// sizing question and comes from config/<name>.json (N_ANTENNAS,
// N_COVAR_PAIRS). The widths do not: POWER_W is invariant across every
// configuration by SPEC 3, and covar_pkg derives everything else from fxp_pkg.
//
// rtl/covariance/*.sv and rtl/packages/covar_pkg.sv are ALSO in files.f: they
// are design RTL, and files.f is the single definition of what "the design" is.
// This list adds only the simulation-only top and its checker.
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

// ---- SPEC 14 property set for the integration window -------------------
// Instantiated directly by rtl/covariance/integrator.sv under `ifndef
// SYNTHESIS`. Must precede the module that instantiates it.
sim/assertions/covar_assertions.sv

// ---- shared primitives the kernel is built on --------------------------
rtl/common/fxp_sticky_flags.sv
rtl/common/complex_multiplier.sv

// ---- the kernel (SPEC 7.6, SPEC 19 Phase 2) ----------------------------
rtl/covariance/power_calc.sv
rtl/covariance/integrator.sv
rtl/covariance/covar_engine.sv

// ---- verification top --------------------------------------------------
sim/verilator/tops/covar_top.sv
