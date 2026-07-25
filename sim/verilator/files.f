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

// ---- include path for the shared assertion macros ----------------------
+incdir+sim/assertions

// ---- generated configuration package -----------------------------------
// Written by scripts/build_verilator.py from config/<name>.json before every
// build. Not committed (see .gitignore).
sim/verilator/generated/config_pkg.sv

// ---- shared packages ---------------------------------------------------
// SPEC 6: one shared fixed-point package, the single source of rounding,
// saturation, truncation and accumulator-width rules. Listed here so `make lint`
// covers it on every run and so every module below can import it.
rtl/packages/fxp_pkg.sv

// SPEC 5: one shared stream package, the single source of the bundle's field
// set, field order and packed layout. Everything under rtl/stream/ resolves
// field positions through it, as does the generated configuration mirror.
rtl/packages/stream_pkg.sv

// ---- protocol assertions (SPEC 14) -------------------------------------
// Simulation-only. Instantiated inside every stream primitive under
// `ifndef SYNTHESIS`, so the protocol is checked everywhere the primitives are
// used, in the fast build, with no test-side wiring. Must precede the RTL that
// instantiates it.
sim/assertions/stream_protocol_checker.sv

// The same arrangement for the telemetry primitives below: perf_counter and
// seq_checker each instantiate their checker under `ifndef SYNTHESIS`, so every
// counter and every sequence classifier in the design is checked wherever it is
// used (SPEC 14 "arithmetic overflow where overflow is forbidden", "sequence
// discontinuity").
sim/assertions/telemetry_assertions.sv
sim/assertions/seq_checker_assertions.sv

// ---- stream primitives (SPEC 5) ----------------------------------------
rtl/stream/stream_skid_buffer.sv
rtl/stream/stream_elastic_buffer.sv
rtl/stream/stream_pipe.sv

// ---- common RTL --------------------------------------------------------
// SPEC 19 Phase 0 loopback DUT, rebuilt on the canonical primitives by issue #5.
rtl/common/stream_loopback.sv

// The sanctioned saturation-flag collector (SPEC 6 "overflow flags"). Not yet
// instantiated by the datapath — it is exercised by the numerics cross-check
// build (sim/verilator/files_fxp.f) and adopted by each kernel as it lands.
rtl/common/fxp_sticky_flags.sv

// The telemetry primitives (SPEC 9, issue #8). perf_counter first: seq_checker
// is built out of it. Both are listed here — rather than only in
// files_telemetry.f — because they are design RTL that every kernel from Phase 2
// onward instantiates, and this list is the single definition of what "the
// design" is. rtl/common/telemetry_block.sv is deliberately NOT here: it is the
// counters block of the register plane and needs rtl/control/, which files.f
// does not carry until the multi-domain integration (issue #19) brings the whole
// plane into benchmark_sim_top. It is linted through files_telemetry.f.
rtl/common/perf_counter.sv
rtl/common/seq_checker.sv

// The first Phase 2 DSP kernel (SPEC 6, issue #9). Listed here — rather than
// only in files_cmult.f — for the same reason perf_counter and seq_checker are:
// it is design RTL that every later kernel (FIR lane, PFB, FFT butterfly,
// beamformer dot product) instantiates, and this list is the single definition
// of what "the design" is. It is not yet instantiated by benchmark_sim_top; the
// pipeline that consumes it arrives with issues #10-#12, and until then `make
// lint` covers it here and sim/verilator/tops/cmult_top.sv verifies it.
rtl/common/complex_multiplier.sv

// ---- simulation top (SPEC 4.1) -----------------------------------------
sim/verilator/tops/benchmark_sim_top.sv
