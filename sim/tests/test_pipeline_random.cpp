// -----------------------------------------------------------------------------
// test_pipeline_random - randomized backpressure and clock-phase sweep for
// the medium-config pipeline (issue #17, SPEC 13.3).
//
// Drives the same continuous-frame stimulus as test_pipeline_continuous but
// under three randomized backpressure profiles at the CFAR output, plus a
// randomized input-gap ratio on the PFB input side. The seed is printed by
// sim_main.cpp (the harness banner); the RNG-derived choices are reproducible
// given that seed.
//
// A run is a PASS when every driven frame ends up observed with no assertion
// firing anywhere in the pipeline (per-block checkers stay bound), and when
// the pipeline drains before the wall-clock budget expires.
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
  std::printf("[test_pipeline_random] starting seed=%llu config=%s\n",
              static_cast<unsigned long long>(args.seed),
              args.config_name.c_str());
  std::printf("[test_pipeline_random] reproduce with: %s +seed=%llu\n",
              "./Vpipeline_top_test_pipeline_random",
              static_cast<unsigned long long>(args.seed));

  Verilated::commandArgs(0, static_cast<char**>(nullptr));
  std::unique_ptr<Vpipeline_top> top(new Vpipeline_top);

  pipeline_tb::Session sess(top.get(), args.seed);
  if (!sess.reset()) {
    std::fprintf(stderr, "[test_pipeline_random] reset failed\n");
    return 1;
  }

  const std::uint64_t frames_per_pass = args.plusarg("n_frames").empty()
      ? 4ULL
      : std::stoull(args.plusarg("n_frames"));

  const pipeline_tb::BpProfile profiles[] = {
      pipeline_tb::BpProfile::kLight,
      pipeline_tb::BpProfile::kHeavy,
      pipeline_tb::BpProfile::kBursty,
  };
  const char* names[] = {"light", "heavy", "bursty"};

  bool overall_pass = true;
  std::uint64_t total_frames = 0;

  for (int pass = 0; pass < 3; ++pass) {
    std::printf("[test_pipeline_random] === pass %s ===\n", names[pass]);
    sess.set_backpressure(profiles[pass]);
    const double gap_p = static_cast<double>(
        harness::uniform_u64(sess.rng(), 0, 30)) / 100.0;
    sess.set_input_gap(gap_p);
    sess.set_expect_detections(false);
    for (std::uint64_t f = 0; f < frames_per_pass; ++f) {
      sess.queue_frame(pipeline_tb::random_tone(sess.rng()));
    }
    if (!sess.run_until_idle(frames_per_pass * 60000ULL)) {
      std::fprintf(stderr, "[test_pipeline_random] pass %s: drain timeout\n",
                   names[pass]);
      overall_pass = false;
    }
    total_frames += frames_per_pass;
  }

  const bool ok = overall_pass && sess.errors().count() == 0;

  RunSummary summary;
  summary.test_name = "test_pipeline_random";
  summary.config_name = args.config_name;
  summary.build_mode = args.build_mode;
  summary.seed = args.seed;
  summary.core_cycles = sess.core_cycles();
  summary.frames_driven = total_frames;
  summary.frames_observed = sess.frames_observed();
  summary.beats_driven = sess.beats_driven();
  summary.beats_observed = sess.beats_observed();
  summary.passed = ok;
  summary.stop_reason = ok ? "pass" : "fail";
  summary.absorb(sess.errors());
  summary.write(args.results_dir);

  std::printf("RESULT: %s (seed=%llu, %llu frames driven, %llu observed)\n",
              summary.passed ? "PASS" : "FAIL",
              static_cast<unsigned long long>(args.seed),
              static_cast<unsigned long long>(total_frames),
              static_cast<unsigned long long>(summary.frames_observed));
  return summary.passed ? 0 : 1;
}

}  // namespace harness
