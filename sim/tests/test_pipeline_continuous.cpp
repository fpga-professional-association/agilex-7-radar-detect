// -----------------------------------------------------------------------------
// test_pipeline_continuous - continuous-frame integration test for the
// medium-config pipeline (issue #17, SPEC 13, SPEC 19 Phase 3).
//
// STUB IMPLEMENTATION -- returns success once the RTL elaborates and one
// frame worth of stimulus has been driven end-to-end without an assertion
// firing. Extended in the sequence check and runtime-update tests.
// -----------------------------------------------------------------------------

#include <cstdio>
#include <cstdint>
#include <cstring>
#include <memory>
#include <string>
#include <vector>

#include "Vpipeline_top.h"
#include "verilated.h"

#include "config_sim.h"

#include "harness/clock_scheduler.h"
#include "harness/error_collector.h"
#include "harness/random.h"
#include "harness/reset_sequencer.h"
#include "harness/run_summary.h"
#include "harness/sim_args.h"

#include "harness/pipeline_tb.h"

namespace harness {

int sim_test_main(const SimArgs& args) {
  std::printf("[test_pipeline_continuous] starting seed=%llu config=%s\n",
              static_cast<unsigned long long>(args.seed),
              args.config_name.c_str());

  Verilated::commandArgs(0, static_cast<char**>(nullptr));

  std::unique_ptr<Vpipeline_top> top(new Vpipeline_top);

  pipeline_tb::Session sess(top.get(), args.seed);
  if (!sess.reset()) {
    std::fprintf(stderr, "[test_pipeline_continuous] reset failed\n");
    return 1;
  }

  // Drive a modest number of continuous frames end-to-end.
  const std::uint64_t n_frames = args.plusarg("n_frames").empty()
      ? 8ULL
      : std::stoull(args.plusarg("n_frames"));

  sess.set_backpressure(pipeline_tb::BpProfile::kNone);
  sess.set_input_gap(0.0);
  sess.set_expect_detections(true);

  for (std::uint64_t f = 0; f < n_frames; ++f) {
    sess.queue_frame(pipeline_tb::random_tone(sess.rng()));
  }

  const bool ok = sess.run_until_idle(n_frames * 20000ULL);

  RunSummary summary;
  summary.test_name = "test_pipeline_continuous";
  summary.config_name = args.config_name;
  summary.build_mode = args.build_mode;
  summary.seed = args.seed;
  summary.core_cycles = sess.core_cycles();
  summary.frames_driven = n_frames;
  summary.frames_observed = sess.frames_observed();
  summary.beats_driven = sess.beats_driven();
  summary.beats_observed = sess.beats_observed();
  summary.passed = ok && sess.errors().count() == 0;
  summary.stop_reason = summary.passed ? "pass" : "fail";
  summary.absorb(sess.errors());
  const std::string path = summary.write(args.results_dir);
  if (!path.empty()) {
    std::printf("[test_pipeline_continuous] summary: %s\n", path.c_str());
  }

  std::printf("RESULT: %s (seed=%llu, %llu frames driven, %llu observed)\n",
              summary.passed ? "PASS" : "FAIL",
              static_cast<unsigned long long>(args.seed),
              static_cast<unsigned long long>(n_frames),
              static_cast<unsigned long long>(summary.frames_observed));

  return summary.passed ? 0 : 1;
}

}  // namespace harness
