// -----------------------------------------------------------------------------
// files_cmult.f — RTL file list for the complex-multiplier build (issue #9).
//
// A self-contained file list, for the reason every other secondary list in this
// directory is self-contained: a failure in this build is then unambiguously a
// failure of the complex multiplier and its numerics, not of the stream fabric,
// the register plane or the CDC primitives, none of which appear here.
//
// Used by:
//   scripts/build_verilator.py --top cmult_top --files sim/verilator/files_cmult.f
// which `make lint` (step 8 of 8) and `make sim-tiny` invoke. Paths are
// repo-relative; order matters (packages first, then the checker the top
// instantiates, then the DUT, then the top).
//
// The generated config_pkg.sv is intentionally NOT listed: nothing in this build
// is configuration-dependent. The complex multiplier's widths come from
// rtl/packages/fxp_pkg.sv and are the same in every size configuration by
// definition, and the DUT grid is a property of the verification top rather than
// of config/<name>.json.
//
// rtl/common/complex_multiplier.sv is ALSO in files.f: it is design RTL that
// every Phase 2 kernel instantiates, and files.f is the single definition of what
// "the design" is. This list adds only the simulation-only top and its checker.
// -----------------------------------------------------------------------------

// ---- include path for the shared assertion macros ----------------------
+incdir+sim/assertions

// ---- shared numerics package (SPEC 6) ----------------------------------
rtl/packages/fxp_pkg.sv

// ---- SPEC 14 property set for the kernel -------------------------------
// Instantiated directly by cmult_top, one per matched MULT4/MULT3 pair. Must
// precede the top that instantiates it.
sim/assertions/cmult_assertions.sv

// ---- the kernel (SPEC 6, SPEC 19 Phase 2) ------------------------------
rtl/common/complex_multiplier.sv

// ---- verification top --------------------------------------------------
sim/verilator/tops/cmult_top.sv

// ---- SPEC 18 calibration wrapper ---------------------------------------
// Synthesis-only: the boundary-register wrapper the resource sweep compiles
// (quartus/calibration/cmult_calib.qsf). It is listed HERE, at the end and
// outside cmult_top's hierarchy, for one reason: it is real RTL that a Quartus
// compile depends on, and RTL that no lint ever sees is RTL that rots. Verilator
// lints every file in the list; the fast build simply does not elaborate a module
// the top never instantiates, so it costs nothing at simulation time.
quartus/calibration/cmult_wrap.sv
