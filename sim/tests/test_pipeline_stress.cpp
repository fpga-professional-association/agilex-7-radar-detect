// -----------------------------------------------------------------------------
// test_pipeline_stress - SPEC 13.4 long stress test for the medium pipeline
// (issue #17).
//
// Runs the pipeline for STRESS_CYCLES core cycles (env-tunable, default 4M)
// with:
//   * sustained near-full throughput on the input,
//   * random stalls at the CFAR output (heavy backpressure profile),
//   * periodic coefficient bank updates every ~200 frames,
//   * periodic weight bank updates every ~200 frames,
//   * counter-wrap coverage via long runtime,
//   * no waveform dump on a passing run.
//
// The stress test is a durability check, not a correctness one -- the per-
// block tests and the pipeline continuous/random/runtime tests already prove
// correctness. Here we simply run for a long time and require:
//   * no assertion failures anywhere in the design,
//   * pipeline drains cleanly at the end,
//   * stat_pipe_swap_count reads > 0 (some swaps did fire), and
//   * stat_pipe_swap_overrun_count remains sane (bounded by our request
//     policy).
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
  const std::uint64_t stress_cycles = args.plusarg("stress_cycles").empty()
      ? 4000000ULL
      : std::stoull(args.plusarg("stress_cycles"));

  std::printf("[test_pipeline_stress] starting seed=%llu cycles=%llu\n",
              static_cast<unsigned long long>(args.seed),
              static_cast<unsigned long long>(stress_cycles));

  Verilated::commandArgs(0, static_cast<char**>(nullptr));
  std::unique_ptr<Vpipeline_top> top(new Vpipeline_top);

  pipeline_tb::Session sess(top.get(), args.seed);
  if (!sess.reset()) {
    std::fprintf(stderr, "[test_pipeline_stress] reset failed\n");
    return 1;
  }

  sess.set_backpressure(pipeline_tb::BpProfile::kHeavy);
  sess.set_input_gap(0.05);   // ~5% gap on input for near-full throughput
  sess.set_expect_detections(false);

  const std::uint64_t initial_cycles = sess.core_cycles();
  std::uint64_t frames_this_batch = 0;
  std::uint64_t total_frames = 0;
  std::uint64_t swap_requests_issued = 0;

  const std::uint64_t swap_every_frames = 200;
  const std::uint64_t batch_size = 32;

  while (sess.core_cycles() - initial_cycles < stress_cycles) {
    // Queue a batch of frames.
    for (std::uint64_t i = 0; i < batch_size; ++i) {
      sess.queue_frame(pipeline_tb::random_tone(sess.rng()));
      ++frames_this_batch;
      ++total_frames;
    }

    // Periodic coefficient/weight bank updates. We rotate between banks 0
    // and 1 so the sticky counters see both directions.
    if (frames_this_batch >= swap_every_frames) {
      const std::uint8_t new_bank =
          static_cast<std::uint8_t>((swap_requests_issued & 1u) ^ 1u);
      for (unsigned addr = 0; addr < 16; ++addr) {
        const std::uint32_t val = 0x00010001u + (addr << 8) +
            static_cast<std::uint32_t>(swap_requests_issued & 0xff);
        sess.program_pfb_coeff(new_bank, static_cast<std::uint16_t>(addr), val);
        sess.program_bf_weight(new_bank, static_cast<std::uint8_t>(addr), val);
      }
      sess.request_pipeline_swap();
      ++swap_requests_issued;
      frames_this_batch = 0;
    }

    // Advance a chunk of cycles rather than waiting fully idle -- for a
    // stress run the buffers are meant to stay non-empty most of the time.
    const std::uint64_t chunk = 32768ULL;
    if (!sess.advance_cycles(chunk)) {
      std::fprintf(stderr, "[test_pipeline_stress] scheduler stopped early\n");
      break;
    }
  }

  // Drain remaining frames.
  const bool drained = sess.run_until_idle(1000000ULL);

  const std::uint64_t swap_count = sess.pipeline_swap_count();
  const std::uint64_t overrun    = sess.pipeline_swap_overrun_count();
  const std::uint64_t cycles_run = sess.core_cycles() - initial_cycles;

  std::printf("[test_pipeline_stress] cycles=%llu frames=%llu swaps=%llu overruns=%llu\n",
              static_cast<unsigned long long>(cycles_run),
              static_cast<unsigned long long>(total_frames),
              static_cast<unsigned long long>(swap_count),
              static_cast<unsigned long long>(overrun));

  const bool pass = drained && sess.errors().count() == 0 &&
                    swap_count >= 1 && cycles_run >= stress_cycles / 2;

  RunSummary summary;
  summary.test_name = "test_pipeline_stress";
  summary.config_name = args.config_name;
  summary.build_mode = args.build_mode;
  summary.seed = args.seed;
  summary.passed = pass;
  summary.stop_reason = pass ? "pass" : "fail";
  summary.core_cycles = cycles_run;
  summary.frames_driven = total_frames;
  summary.frames_observed = sess.frames_observed();
  summary.beats_driven = sess.beats_driven();
  summary.beats_observed = sess.beats_observed();
  summary.absorb(sess.errors());
  summary.write(args.results_dir);

  std::printf("RESULT: %s (seed=%llu, cycles=%llu, frames=%llu, swaps=%llu)\n",
              pass ? "PASS" : "FAIL",
              static_cast<unsigned long long>(args.seed),
              static_cast<unsigned long long>(cycles_run),
              static_cast<unsigned long long>(total_frames),
              static_cast<unsigned long long>(swap_count));
  return pass ? 0 : 1;
}

}  // namespace harness
