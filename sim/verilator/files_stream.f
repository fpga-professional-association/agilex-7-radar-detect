// -----------------------------------------------------------------------------
// files_stream.f — file list for the per-primitive unit-test build (SPEC 13.1).
//
// Verilates `stream_prims_top` instead of `benchmark_sim_top`, so the unit tests
// for rtl/stream/ do not depend on any other RTL existing, compiling or
// behaving: a failure in this build is always a stream-primitive failure. Same
// arrangement, for the same reason, as files_fxp.f and the numerics cross-check.
//
// Used by:
//   scripts/build_verilator.py --top stream_prims_top --files sim/verilator/files_stream.f
// which `make sim-tiny` invokes for test_stream_primitives. Paths are
// repo-relative; order matters (packages first).
// -----------------------------------------------------------------------------

+incdir+sim/assertions

// ---- generated configuration package -----------------------------------
sim/verilator/generated/config_pkg.sv

// ---- shared stream package (SPEC 5) ------------------------------------
rtl/packages/stream_pkg.sv

// ---- protocol assertions (SPEC 14) -------------------------------------
sim/assertions/stream_protocol_checker.sv

// ---- the primitives under test -----------------------------------------
rtl/stream/stream_skid_buffer.sv
rtl/stream/stream_elastic_buffer.sv
rtl/stream/stream_pipe.sv

// ---- unit-test top ------------------------------------------------------
sim/verilator/tops/stream_prims_top.sv
