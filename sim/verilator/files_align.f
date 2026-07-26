// -----------------------------------------------------------------------------
// files_align.f — Verilator file list for the SPEC.md 7.4 frequency-bin
// alignment network (issue #16), top module `align_top`.
//
// Packages first, then the primitives this block consumes, then the SPEC 14
// property set (which rtl/align/align_net.sv instantiates directly and which
// must therefore precede it), then the block, then the verification top and the
// Quartus calibration wrappers.
//
// history_pkg is here because it is not optional: SPEC 7.4's input IS SPEC 7.3's
// read contract, and this block unpacks the response metadata with #15's own
// `hist_meta_unpack` rather than with a second copy of the layout. Same reason
// for beamformer_pkg: align_net checks its output beat width against
// `bf_in_data_w` at elaboration, so the two definitions of "a beamformer input
// beat" cannot drift apart silently.
//
// The generated config_pkg.sv is intentionally NOT listed, following
// files_beamformer.f: nothing in this build is configuration-dependent. The four
// geometries under test are a property of sim/verilator/tops/align_top.sv
// (chosen for simulation time and to cover both a 2-stage and a 3-stage
// network), and the SPEC 11 sizes reach the design as elaboration parameters at
// integration rather than through this unit build.
//
// The calibration wrappers are listed for the reason files_history.f and
// files_beamformer.f list theirs: RTL that no lint ever sees is RTL that rots,
// and a wrapper that stops elaborating should be discovered on the next
// `make lint` rather than on the next SPEC 18 sweep.
// -----------------------------------------------------------------------------

// ---- include path for the shared assertion macros ---------------------------
+incdir+sim/assertions

// ---- packages ---------------------------------------------------------------
rtl/packages/fxp_pkg.sv
rtl/packages/stream_pkg.sv
rtl/packages/history_pkg.sv
rtl/beamformer/beamformer_pkg.sv
rtl/align/align_pkg.sv

// ---- common primitives (issues #5, #8) --------------------------------------
rtl/common/perf_counter.sv

// ---- SPEC 14 property sets --------------------------------------------------
// Instantiated directly by the RTL under `ifndef SYNTHESIS. Must precede the
// modules that instantiate them.
sim/assertions/telemetry_assertions.sv
sim/assertions/stream_protocol_checker.sv
sim/assertions/align_assertions.sv

// ---- SPEC 5 stream primitives (issue #5) ------------------------------------
rtl/stream/stream_skid_buffer.sv
rtl/stream/stream_elastic_buffer.sv

// ---- the block (SPEC 7.4) ---------------------------------------------------
rtl/align/align_xbar.sv
rtl/align/align_clos.sv
rtl/align/align_switch.sv
rtl/align/align_collect.sv
rtl/align/align_net.sv

// ---- verification top -------------------------------------------------------
sim/verilator/tops/align_top.sv

// ---- SPEC 18 calibration wrappers (Quartus-side, linted here) ---------------
quartus/calibration/align_sw_wrap.sv
quartus/calibration/align_net_wrap.sv
