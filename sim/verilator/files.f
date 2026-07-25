// -----------------------------------------------------------------------------
// files.f — RTL file list for every Verilator build mode (SPEC 12.1).
//
// Passed to verilator as `-f sim/verilator/files.f` by scripts/build_verilator.py,
// which runs with the repository root as its working directory, so every path
// here is repo-relative.
//
// Order matters: packages must precede the modules that import them. Verilator
// does not reorder.
//
// This list is the single definition of what "the design" is for simulation.
// Adding RTL means adding it here; a file that is not listed is not linted, not
// simulated, and not covered.
// -----------------------------------------------------------------------------

// ---- generated configuration package -----------------------------------
// Written by scripts/build_verilator.py from config/<name>.json before every
// build. Not committed (see .gitignore).
sim/verilator/generated/config_pkg.sv

// ---- shared packages ---------------------------------------------------
// SPEC 6: one shared fixed-point package, the single source of rounding,
// saturation, truncation and accumulator-width rules. Listed here so `make lint`
// covers it on every run and so every module below can import it.
rtl/packages/fxp_pkg.sv

// ---- common RTL --------------------------------------------------------
// PROVISIONAL loopback DUT for the Phase 0 harness; replaced by the real
// stream interface and elastic buffers in issue #5.
rtl/common/stream_loopback.sv

// The sanctioned saturation-flag collector (SPEC 6 "overflow flags"). Not yet
// instantiated by the datapath — it is exercised by the numerics cross-check
// build (sim/verilator/files_fxp.f) and adopted by each kernel as it lands.
rtl/common/fxp_sticky_flags.sv

// ---- simulation top (SPEC 4.1) -----------------------------------------
sim/verilator/tops/benchmark_sim_top.sv
