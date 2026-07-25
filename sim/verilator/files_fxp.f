// -----------------------------------------------------------------------------
// files_fxp.f — RTL file list for the numerics cross-check build (SPEC 12.4).
//
// A second, deliberately tiny file list. The numerics cross-check verilates
// `fxp_probe_top` instead of `benchmark_sim_top` so that the equivalence proof
// between rtl/packages/fxp_pkg.sv and model/cpp/fxp/ does not depend on any
// other RTL existing, compiling, or behaving — a failure here is always a
// numerics failure.
//
// Used by:
//   scripts/build_verilator.py --top fxp_probe_top --files sim/verilator/files_fxp.f
// which `make numerics-check` invokes. Paths are repo-relative; order matters
// (packages first).
//
// The generated config_pkg.sv is intentionally NOT listed: nothing here is
// configuration-dependent, and the fixed-point rules are the same in every size
// configuration by definition.
// -----------------------------------------------------------------------------

// ---- shared numerics package (SPEC 6) ----------------------------------
rtl/packages/fxp_pkg.sv

// ---- saturation-flag collector -----------------------------------------
rtl/common/fxp_sticky_flags.sv

// ---- probe top ---------------------------------------------------------
sim/verilator/tops/fxp_probe_top.sv
