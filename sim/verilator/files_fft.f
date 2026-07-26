// -----------------------------------------------------------------------------
// files_fft.f — RTL file list for the streaming-FFT build (issue #11).
//
// A self-contained file list, for the reason every other secondary list in this
// directory is self-contained: a failure in this build is then unambiguously a
// failure of the FFT and its numerics, not of the register plane or the CDC
// primitives, none of which appear here.
//
// Used by:
//   scripts/build_verilator.py --top fft_top --files sim/verilator/files_fft.f
// which `make lint` and `make sim-tiny` invoke. Paths are repo-relative; order
// matters (packages first, then the primitives the FFT instantiates, then the
// FFT itself, then the verification top).
//
// The generated config_pkg.sv is intentionally NOT listed: nothing in this build
// is configuration-dependent. The FFT's geometry comes from its own parameters
// and the verification top's grid, and its widths come from rtl/packages/, which
// are the same in every size configuration by definition.
//
// rtl/fft/*.sv is ALSO in files.f: it is design RTL, and files.f is the single
// definition of what "the design" is. This list adds only the simulation-only
// top and the calibration wrappers.
// -----------------------------------------------------------------------------

// ---- include path for the shared assertion macros ----------------------
+incdir+sim/assertions

// ---- shared packages (SPEC 5, SPEC 6) ----------------------------------
rtl/packages/fxp_pkg.sv
rtl/packages/stream_pkg.sv

// ---- the committed twiddle table (generated; see gen_fft_twiddles.py) ---
rtl/fft/generated/fft_twiddle_pkg.sv

// ---- FFT geometry and index arithmetic (SPEC 7.2) ----------------------
rtl/fft/fft_pkg.sv

// ---- SPEC 14 protocol checker, instantiated inside the primitives ------
sim/assertions/stream_protocol_checker.sv

// ---- primitives the FFT is built from ----------------------------------
rtl/common/fxp_sticky_flags.sv
rtl/common/complex_multiplier.sv
rtl/common/sync_fifo.sv
rtl/stream/stream_elastic_buffer.sv

// ---- the FFT (leaf to root) --------------------------------------------
rtl/fft/fft_delay_line.sv
rtl/fft/fft_bf2.sv
rtl/fft/fft_twiddle_rom.sv
rtl/fft/fft_radix22_stage.sv
rtl/fft/fft_sdf_path.sv
rtl/fft/fft_dit_merge.sv
rtl/fft/fft_reorder.sv
rtl/fft/fft_core.sv
rtl/fft/streaming_fft.sv

// ---- verification top ---------------------------------------------------
sim/verilator/tops/fft_top.sv

// ---- SPEC 18 calibration wrappers --------------------------------------
// Synthesis-only: the boundary-register wrappers the resource sweep compiles
// (quartus/calibration/fft_stage_calib.qsf, fft_core_calib.qsf). Listed HERE, at
// the end and outside fft_top's hierarchy, for one reason: they are real RTL
// that a Quartus compile depends on, and RTL that no lint ever sees is RTL that
// rots. Verilator lints every file in the list; the fast build simply does not
// elaborate a module the top never instantiates.
quartus/calibration/fft_stage_wrap.sv
quartus/calibration/fft_core_wrap.sv
