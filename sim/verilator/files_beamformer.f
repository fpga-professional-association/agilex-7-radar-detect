// -----------------------------------------------------------------------------
// files_beamformer.f — RTL file list for the beamforming-matrix build (issue #12).
//
// A self-contained file list, for the reason every other secondary list in this
// directory is self-contained: a failure in this build is then unambiguously a
// failure of the dot product, the weight bank or the matrix, and not of the
// register plane or the CDC unit tests, neither of which appears here.
//
// Used by:
//   scripts/build_verilator.py --top beamformer_top
//       --files sim/verilator/files_beamformer.f
// which `make lint` and `make sim-tiny` invoke. Paths are repo-relative; order
// matters (packages first, then the checkers the RTL instantiates, then the
// primitives, then the DUT, then the top).
//
// The generated config_pkg.sv is intentionally NOT listed: nothing in this build
// is configuration-dependent. The matrix geometry under test is a property of
// sim/verilator/tops/beamformer_top.sv (4 antennas x 4 beams x 2 bins, chosen
// for simulation time), and the SPEC 11 sizes reach the design as elaboration
// parameters at integration rather than through this unit build.
//
// rtl/pfb/coeff_bank.sv AND rtl/packages/pfb_pkg.sv appear here, and that is not
// an accident of copy-paste. rtl/beamformer/weight_bank.sv REUSES the dual-bank
// store issue #10 built rather than containing a second copy of a clock-domain
// seam and a swap state machine; see that file's section 1 for the reasoning and
// for what was deliberately not refactored. The polyphase package comes with it
// because coeff_bank imports it for its bounds.
//
// The rtl/beamformer/ modules are ALSO in files.f: they are design RTL, and
// files.f is the single definition of what "the design" is. This list adds the
// simulation-only top and the checkers the RTL instantiates under
// `ifndef SYNTHESIS`, plus the two SPEC 18 calibration wrappers so that
// `make lint` covers them.
// -----------------------------------------------------------------------------

// ---- include path for the shared assertion macros ----------------------
+incdir+sim/assertions

// ---- shared packages ---------------------------------------------------
rtl/packages/fxp_pkg.sv
rtl/packages/stream_pkg.sv
rtl/packages/cdc_pkg.sv
rtl/packages/pfb_pkg.sv

// ---- beamformer geometry and latency arithmetic (SPEC 7.5) -------------
// Lives under rtl/beamformer/ rather than rtl/packages/, following
// rtl/fft/fft_pkg.sv: a package used by exactly one block belongs with the
// block. rtl/packages/ holds the packages more than one block shares.
rtl/beamformer/beamformer_pkg.sv

// ---- SPEC 14 checkers instantiated by the RTL --------------------------
// Must precede the RTL that instantiates them.
sim/assertions/stream_protocol_checker.sv
sim/assertions/telemetry_assertions.sv
sim/assertions/coeff_bank_checker.sv
sim/assertions/beamformer_assertions.sv

// ---- SPEC 5 stream primitives (issue #5) -------------------------------
rtl/stream/stream_skid_buffer.sv
rtl/stream/stream_elastic_buffer.sv

// ---- SPEC 8 CDC primitives (issue #6) ----------------------------------
// The weight bank's configuration-to-core seam is built from these.
rtl/cdc/cdc_sync2.sv
rtl/cdc/cdc_pulse.sv
rtl/cdc/cdc_handshake.sv

// ---- SPEC 6 / SPEC 9 common RTL (issues #8, #9) ------------------------
rtl/common/fxp_sticky_flags.sv
rtl/common/perf_counter.sv
rtl/common/complex_multiplier.sv

// ---- the reused dual-bank store (issue #10) ----------------------------
rtl/pfb/coeff_bank.sv

// ---- the kernel under test (SPEC 7.5, SPEC 19 Phase 2) -----------------
rtl/beamformer/bf_dot.sv
rtl/beamformer/weight_bank.sv
rtl/beamformer/beamformer.sv

// ---- verification top --------------------------------------------------
sim/verilator/tops/beamformer_top.sv

// ---- SPEC 18 calibration wrappers --------------------------------------
// Synthesis-only: the boundary-register wrappers the resource sweep compiles
// (quartus/calibration/bf_dot_calib.qsf, quartus/calibration/bf_matrix_calib.qsf).
// Listed HERE, at the end and outside beamformer_top's hierarchy, for the same
// reason quartus/calibration/cmult_wrap.sv is listed in files_cmult.f: they are
// real RTL that a Quartus compile depends on, and RTL that no lint ever sees is
// RTL that rots. The fast build simply does not elaborate a module the top never
// instantiates.
quartus/calibration/bf_dot_wrap.sv
quartus/calibration/bf_matrix_wrap.sv
