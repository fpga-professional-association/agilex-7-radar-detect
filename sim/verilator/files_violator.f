// -----------------------------------------------------------------------------
// files_violator.f — file list for the negative assertion test (SPEC 14).
//
// Verilates `stream_violator_top`: a deliberately protocol-violating stage with
// the SPEC 14 checker attached by `bind`. Kept in its own file list because the
// RTL in it is knowingly wrong and must never reach the design build.
//
// Used by:
//   scripts/build_verilator.py --top stream_violator_top --files sim/verilator/files_violator.f
// which `make sim-tiny` invokes for test_stream_assertions. That test expects
// assertions to FAIL, and reports a run in which none fired as an error.
// -----------------------------------------------------------------------------

+incdir+sim/assertions

// ---- generated configuration package -----------------------------------
sim/verilator/generated/config_pkg.sv

// ---- shared stream package (SPEC 5) ------------------------------------
rtl/packages/stream_pkg.sv

// ---- protocol assertions (SPEC 14) -------------------------------------
sim/assertions/stream_protocol_checker.sv

// ---- the broken stage and its top ---------------------------------------
sim/verilator/tops/stream_violator.sv
sim/verilator/tops/stream_violator_top.sv
