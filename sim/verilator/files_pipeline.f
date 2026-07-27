// -----------------------------------------------------------------------------
// files_pipeline.f - RTL file list for the medium-config pipeline integration
// (issue #17), top module `pipeline_top`.
//
// This list unions the block-level file lists into a single Verilator build
// that compiles the full PFB -> FFT -> history -> alignment -> beamformer ->
// power -> CFAR chain, plus rtl/top/benchmark_sim_top.sv (module
// `benchmark_pipeline_top`) and rtl/top/benchmark_pipeline_ctrl.sv.
//
// Order matters: packages first, then the SPEC 14 assertion modules that the
// RTL instantiates under `ifndef SYNTHESIS`, then the primitives, then the
// blocks bottom-up, then the top-level pipeline module and its simulation
// wrapper.
//
// The generated config_pkg.sv is listed so the top's parameters can echo the
// medium config's SPEC 11 sizes.
// -----------------------------------------------------------------------------

// ---- include path for the shared assertion macros --------------------------
+incdir+sim/assertions

// ---- generated configuration package ---------------------------------------
sim/verilator/generated/config_pkg.sv

// ---- shared packages -------------------------------------------------------
rtl/packages/fxp_pkg.sv
rtl/packages/stream_pkg.sv
rtl/packages/cdc_pkg.sv
rtl/packages/pfb_pkg.sv
rtl/packages/covar_pkg.sv
rtl/packages/cfar_pkg.sv
rtl/packages/history_pkg.sv
rtl/packages/packet_pkg.sv
rtl/beamformer/beamformer_pkg.sv
rtl/align/align_pkg.sv

// ---- issue #19 abstract memory (Phase 4) ----------------------------------
rtl/memory/mem_req_rsp_if.sv

// ---- SPEC 14 checkers instantiated by the RTL ------------------------------
sim/assertions/stream_protocol_checker.sv
sim/assertions/telemetry_assertions.sv
sim/assertions/seq_checker_assertions.sv
sim/assertions/pfb_assertions.sv
sim/assertions/coeff_bank_checker.sv
sim/assertions/beamformer_assertions.sv
sim/assertions/covar_assertions.sv
sim/assertions/cfar_assertions.sv
sim/assertions/history_wr_assertions.sv
sim/assertions/history_rd_assertions.sv
sim/assertions/align_assertions.sv

// ---- SPEC 5 stream primitives ---------------------------------------------
rtl/stream/stream_skid_buffer.sv
rtl/stream/stream_elastic_buffer.sv
rtl/stream/stream_pipe.sv

// ---- SPEC 8 CDC primitives -------------------------------------------------
rtl/cdc/cdc_sync2.sv
rtl/cdc/cdc_pulse.sv
rtl/cdc/cdc_handshake.sv
rtl/cdc/async_fifo.sv
rtl/cdc/stream_cdc.sv

// ---- SPEC 6 / SPEC 9 common RTL --------------------------------------------
rtl/common/fxp_sticky_flags.sv
rtl/common/perf_counter.sv
rtl/common/seq_checker.sv
rtl/common/complex_multiplier.sv
rtl/common/sync_fifo.sv

// ---- kernels: PFB (SPEC 7.1) ----------------------------------------------
rtl/pfb/delay_line.sv
rtl/pfb/coeff_bank.sv
rtl/pfb/fir_lane.sv
rtl/pfb/pfb_bank.sv

// ---- kernels: streaming FFT (SPEC 7.2) ------------------------------------
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

// ---- kernels: banked history / corner turn (SPEC 7.3) ---------------------
rtl/memory/history_bank.sv
rtl/memory/history_core.sv

// ---- kernels: alignment network (SPEC 7.4) --------------------------------
rtl/align/align_xbar.sv
rtl/align/align_clos.sv
rtl/align/align_switch.sv
rtl/align/align_collect.sv
rtl/align/align_net.sv

// ---- kernels: beamformer (SPEC 7.5) ---------------------------------------
rtl/beamformer/bf_dot.sv
rtl/beamformer/weight_bank.sv
rtl/beamformer/beamformer.sv

// ---- kernels: power / covariance (SPEC 7.6) -------------------------------
rtl/covariance/power_calc.sv
rtl/covariance/integrator.sv
rtl/covariance/covar_engine.sv

// ---- kernels: CFAR (SPEC 7.7) ---------------------------------------------
rtl/cfar/cfar_window.sv
rtl/cfar/cfar_core.sv

// ---- issue #18 packet network (used by benchmark_pipeline_top's DMA tap) --
rtl/packet/pkt_rr_arb.sv
rtl/packet/pkt_ingress.sv
rtl/packet/pkt_switch_stage.sv
rtl/packet/pkt_egress.sv
rtl/packet/pkt_fabric.sv

// ---- issue #19 abstract memory backend (behavioural + arbiter) ------------
rtl/memory/mem_arbiter.sv
rtl/memory/behavioral_mem_model.sv

// ---- pipeline top and control ---------------------------------------------
rtl/top/benchmark_pipeline_ctrl.sv
rtl/top/benchmark_sim_top.sv

// ---- verification top ------------------------------------------------------
sim/verilator/tops/pipeline_top.sv
