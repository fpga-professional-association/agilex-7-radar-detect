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

// SPEC 8: the CDC parameter package (issue #6). Listed here because the
// coefficient bank below instantiates the crossing primitives that use it.
rtl/packages/cdc_pkg.sv

// SPEC 7.1: the polyphase-FIR package (issue #10). Accumulator width, the
// beat/cycle latency split, and the delay-line storage-style threshold, in one
// place so the lane, the coefficient bank, the polyphase bank and the C++ model
// cannot disagree.
rtl/packages/pfb_pkg.sv
rtl/packages/covar_pkg.sv

// SPEC 7.7: the CFAR package (issue #14). Widths, the threshold multiplier's
// fixed-point format, the detection-event bit layout and the normative
// comparison, in one place so the detector, the register block, the packet
// network and the C++ model cannot disagree. It takes its input width from
// covar_pkg above by reference, so it must follow it.
rtl/packages/cfar_pkg.sv

// SPEC 7.3: the time-frequency history package (issue #15). The bank geometry,
// the frame-pointer and epoch widths, the request/response field layout and the
// readable-set rule, in one place so the banks, the corner-turn core, the
// register block and the C++ model cannot disagree.
rtl/packages/history_pkg.sv

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

// The same arrangement again for the polyphase bank (issue #10): rtl/pfb/
// coeff_bank.sv and rtl/pfb/pfb_bank.sv each instantiate their checker under
// `ifndef SYNTHESIS`, so the SPEC 7.1 frame-boundary rule and the block's
// credit argument are checked wherever those modules are used.
sim/assertions/pfb_assertions.sv
sim/assertions/coeff_bank_checker.sv
sim/assertions/covar_assertions.sv

// And again for the CFAR detector (issue #14): rtl/cfar/cfar_core.sv
// instantiates its checker under `ifndef SYNTHESIS`, so the SPEC 7.7 suppression
// rule, the frame-boundary configuration rule and the agreement between the
// sized datapath and cfar_pkg's own comparison are checked wherever the detector
// is used.
sim/assertions/cfar_assertions.sv

// And again for the beamforming matrix (issue #12): rtl/beamformer/beamformer.sv
// instantiates its checker under `ifndef SYNTHESIS`, so the SPEC 7.5
// time-multiplex contract — a beat may not be admitted while a held beat still
// has beam groups outstanding — is checked wherever the module is used. The
// weight bank's frame-boundary rule needs no entry of its own: it is checked by
// coeff_bank_checker above, because rtl/beamformer/weight_bank.sv reuses the
// store issue #10 built rather than reimplementing it.
sim/assertions/beamformer_assertions.sv

// And again for the banked history (issue #15): rtl/memory/history_core.sv
// instantiates its checker under `ifndef SYNTHESIS`, so the SPEC 7.3 rules are
// checked wherever the block is used — including in the Quartus calibration
// wrapper no testbench ever drives. The two SPEC 7.3 PROHIBITIONS are the
// reason it exists: a_history_no_safe_collision is the claim that the readable
// set excludes the in-flight write slot by construction (the assertion that
// licenses no_rw_check on every M20K in the subsystem), and
// a_history_lane_onehot0 plus c_history_write_enables_differ are the ban on a
// single globally broadcast address and enable network turned into observable
// consequences a broadcast design could not produce. Must precede rtl/memory/
// below.
sim/assertions/history_wr_assertions.sv
sim/assertions/history_rd_assertions.sv

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

// ---- SPEC 8 CDC primitives (issue #6) ----------------------------------
// Listed here because rtl/pfb/coeff_bank.sv builds its configuration-to-core
// seam out of them. rtl/cdc/async_fifo.sv and rtl/cdc/stream_cdc.sv are not yet
// instantiated by anything in this list and stay in files_cdc.f.
rtl/cdc/cdc_sync2.sv
rtl/cdc/cdc_pulse.sv
rtl/cdc/cdc_handshake.sv

// ---- the polyphase FIR bank (SPEC 7.1, SPEC 19 Phase 2, issue #10) -----
// Design RTL: one complex FIR lane, the dual coefficient banks with their
// frame-aligned swap, the parameterised delay line, and the polyphase bank that
// puts SAMPLES_PER_CYCLE lanes behind one SPEC 5 stream interface. Not yet
// instantiated by benchmark_sim_top; the pipeline that consumes it arrives with
// the medium integration (issue #17), and until then `make lint` covers it here
// and sim/verilator/tops/pfb_top.sv verifies it.
rtl/pfb/delay_line.sv
rtl/pfb/coeff_bank.sv
rtl/pfb/fir_lane.sv
rtl/pfb/pfb_bank.sv

// The single-clock FIFO (SPEC 8, issue #6). Listed here as of issue #11: the
// streaming FFT instantiates it for its metadata and output buffers, so it is
// no longer only a CDC-build module. Its asynchronous sibling stays in
// files_cdc.f — nothing in files.f crosses a clock domain yet.
rtl/common/sync_fifo.sv

// ---- the streaming FFT (SPEC 7.2, issue #11) ---------------------------
// Design RTL, listed here for the reason complex_multiplier is: this list is the
// single definition of what "the design" is. Not yet instantiated by
// benchmark_sim_top — the pipeline that consumes it arrives with issues #15/#19
// — so until then `make lint` covers it here and sim/verilator/tops/fft_top.sv
// verifies it.
//
// fft_twiddle_pkg.sv is GENERATED AND COMMITTED, exactly like the register map:
// model/python/gen_fft_twiddles.py produces it, `make fft-check` (a prerequisite
// of both lint and sim-tiny) fails if it has drifted, and .gitignore
// deliberately does not ignore it. See that script's header for why the table is
// not computed at elaboration time.
rtl/fft/generated/fft_twiddle_pkg.sv
rtl/fft/fft_pkg.sv
rtl/fft/fft_delay_line.sv
rtl/fft/fft_bf2.sv
rtl/fft/fft_twiddle_rom.sv
rtl/fft/fft_radix22_stage.sv
rtl/fft/fft_sdf_path.sv
rtl/fft/fft_dit_merge.sv
rtl/fft/fft_reorder.sv
rtl/fft/fft_core.sv
rtl/fft/streaming_fft.sv

// ---- the beamforming matrix (SPEC 7.5, issue #12) ----------------------
// Design RTL, listed here for the reason the FFT is: this list is the single
// definition of what "the design" is. Not yet instantiated by
// benchmark_sim_top — the pipeline that consumes it arrives with issue #17 —
// so until then `make lint` covers it here and
// sim/verilator/tops/beamformer_top.sv verifies it.
//
// beamformer_pkg.sv lives with the block rather than in rtl/packages/,
// following rtl/fft/fft_pkg.sv: a package used by exactly one block belongs with
// the block, and rtl/packages/ holds the packages more than one block shares.
//
// rtl/beamformer/weight_bank.sv instantiates rtl/pfb/coeff_bank.sv (listed
// above) rather than containing a second copy of a dual-bank store with a
// clock-domain seam and a frame-aligned swap. See that file's section 1 for the
// reasoning and for the refactor that was deliberately not done.
rtl/beamformer/beamformer_pkg.sv
rtl/beamformer/bf_dot.sv
rtl/beamformer/weight_bank.sv
rtl/beamformer/beamformer.sv

// ---- power and covariance engine (SPEC 7.6, issue #13) -----------------
// power_calc and integrator first: covar_engine is built out of the second one
// and out of rtl/common/complex_multiplier.sv, already listed above.
rtl/covariance/power_calc.sv
rtl/covariance/integrator.sv
rtl/covariance/covar_engine.sv

// ---- the CFAR detector (SPEC 7.7, issue #14) ---------------------------
// Design RTL, listed here for the reason complex_multiplier is: this list is the
// single definition of what "the design" is. cfar_window first; cfar_core is
// built out of it, out of rtl/stream/stream_elastic_buffer.sv and out of
// rtl/common/perf_counter.sv, all already listed above. Not yet instantiated by
// benchmark_sim_top — the pipeline that consumes it arrives with issues #17/#18
// — so until then `make lint` covers it here and sim/verilator/tops/cfar_top.sv
// verifies it.
rtl/cfar/cfar_window.sv
rtl/cfar/cfar_core.sv

// ---- the banked time-frequency history (SPEC 7.3, issue #15) -----------
// Design RTL, listed here for the reason the FFT is: this list is the single
// definition of what "the design" is. history_bank first; history_core is built
// out of it, out of rtl/cdc/cdc_handshake.sv and rtl/cdc/cdc_pulse.sv, out of
// rtl/common/sync_fifo.sv and rtl/common/perf_counter.sv, and out of
// the two sim/assertions/history_*_assertions.sv checkers — all already listed
// above, which is why
// this section comes last among the design blocks. Not yet instantiated by
// benchmark_sim_top — the pipeline that consumes it arrives with issue #17 — so
// until then `make lint` covers it here and sim/verilator/tops/history_top.sv
// verifies it.
//
// This is the first block in files.f that carries a clock-domain seam of its
// own: the write plane runs in core_clk and the corner-turn read path in
// history_clk. Nothing in this list drives that second clock yet — benchmark_
// sim_top is still single-clock — so the crossing is proved by
// `make cdc-inventory`, which runs --strict over files_history.f, and by
// test_history's clock-ratio sweep, not by anything elaborated here.
//
// The quartus/calibration/history_*_wrap.sv wrappers are deliberately NOT here:
// they are SPEC 18 calibration harnesses, not design RTL, and files_history.f
// already lints them.
rtl/memory/history_bank.sv
rtl/memory/history_core.sv

// ---- simulation top (SPEC 4.1) -----------------------------------------
sim/verilator/tops/benchmark_sim_top.sv
