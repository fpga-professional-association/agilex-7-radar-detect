// -----------------------------------------------------------------------------
// test_pipeline_runtime_update - runtime PFB coefficient-bank and beamformer
// weight-bank swaps at frame boundaries (issue #17, SPEC 7.1, 7.5, 13.2).
//
// Drives four continuous frames. Between frames 1 and 2 the test programs
// coefficient values into the INACTIVE PFB coefficient bank and weight
// values into the INACTIVE beamformer weight bank. Then it requests a
// pipeline swap (benchmark_pipeline_ctrl's cfg_pipe_swap_req). The controller
// waits for the next PFB-input end-of-frame boundary and pulses both banks
// on the same cycle.
//
// A run passes when:
//   * all frames drive and observe cleanly
//   * the per-block coeff_bank_checker assertions did not fire (mid-frame
//     swap would $error), which is the SPEC 13.2 "bank changes affect only
//     permitted frame boundaries" property
//   * stat_pipe_swap_count reads >= 1
//   * stat_pipe_swap_overrun_count reads 0
// -----------------------------------------------------------------------------

#include <cstdio>
#include <cstdint>
#include <memory>
#include <string>

#include "Vpipeline_top.h"
#include "verilated.h"

#include "config_sim.h"

#include "harness/error_collector.h"
#include "harness/random.h"
#include "harness/run_summary.h"
#include "harness/sim_args.h"

#include "harness/pipeline_tb.h"

namespace harness {

int sim_test_main(const SimArgs& args) {
  std::printf("[test_pipeline_runtime_update] starting seed=%llu\n",
              static_cast<unsigned long long>(args.seed));

  Verilated::commandArgs(0, static_cast<char**>(nullptr));
  std::unique_ptr<Vpipeline_top> top(new Vpipeline_top);

  pipeline_tb::Session sess(top.get(), args.seed);
  if (!sess.reset()) {
    std::fprintf(stderr, "[test_pipeline_runtime_update] reset failed\n");
    return 1;
  }

  sess.set_backpressure(pipeline_tb::BpProfile::kNone);
  sess.set_input_gap(0.0);
  sess.set_expect_detections(true);

  // Frame 0 and 1: bank 0 active.
  sess.queue_frame(pipeline_tb::random_tone(sess.rng()));
  sess.queue_frame(pipeline_tb::random_tone(sess.rng()));

  // Between-frame update: program the INACTIVE (bank 1) PFB coefficients
  // and beamformer weights, then request the pipeline swap.
  // The PFB has PHASES=2, TAPS=8 -> 16 addresses; sweep every one.
  for (unsigned addr = 0; addr < 16; ++addr) {
    const std::uint32_t val = 0x00010001u + (addr << 8);
    sess.program_pfb_coeff(/*bank=*/1, static_cast<std::uint16_t>(addr), val);
  }
  // Beamformer weights: N_BEAMS=4, N_ANT=4 -> 16 addresses.
  for (unsigned addr = 0; addr < 16; ++addr) {
    const std::uint32_t val = 0x00010001u + (addr << 4);
    sess.program_bf_weight(/*bank=*/1, static_cast<std::uint8_t>(addr), val);
  }

  sess.request_pipeline_swap();

  // Frame 2 and 3: bank 1 becomes active after the swap fires at the head
  // end-of-frame plane. The per-block checkers assert that no swap fires
  // mid-frame -- and the pipeline controller's own assertion in
  // benchmark_pipeline_ctrl.sv asserts that the pulses fire only in state
  // DISPATCHED. Both cases would be errors surfaced through error_collector.
  sess.queue_frame(pipeline_tb::random_tone(sess.rng()));
  sess.queue_frame(pipeline_tb::random_tone(sess.rng()));

  const bool ok = sess.run_until_idle(200000ULL);

  const std::uint64_t swap_count = sess.pipeline_swap_count();
  const std::uint64_t overrun    = sess.pipeline_swap_overrun_count();

  std::printf("[test_pipeline_runtime_update] pipe swap count=%llu overrun=%llu\n",
              static_cast<unsigned long long>(swap_count),
              static_cast<unsigned long long>(overrun));

  bool pass = ok && sess.errors().count() == 0 && swap_count >= 1 &&
              overrun == 0;

  RunSummary summary;
  summary.test_name = "test_pipeline_runtime_update";
  summary.config_name = args.config_name;
  summary.build_mode = args.build_mode;
  summary.seed = args.seed;
  summary.core_cycles = sess.core_cycles();
  summary.frames_driven = 4;
  summary.frames_observed = sess.frames_observed();
  summary.beats_driven = sess.beats_driven();
  summary.beats_observed = sess.beats_observed();
  summary.passed = pass;
  summary.stop_reason = pass ? "pass" : "fail";
  summary.absorb(sess.errors());
  summary.write(args.results_dir);

  std::printf("RESULT: %s (seed=%llu, swaps=%llu, overrun=%llu)\n",
              pass ? "PASS" : "FAIL",
              static_cast<unsigned long long>(args.seed),
              static_cast<unsigned long long>(swap_count),
              static_cast<unsigned long long>(overrun));
  return pass ? 0 : 1;
}

}  // namespace harness
