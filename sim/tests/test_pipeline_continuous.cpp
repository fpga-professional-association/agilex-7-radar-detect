// -----------------------------------------------------------------------------
// test_pipeline_continuous - continuous-frame integration test for the
// medium-config pipeline (issue #17, SPEC 13.1, SPEC 19 Phase 3).
//
// Drives a sustained run of frames (default 64, override with +n_frames=<N>)
// through the whole pipeline and checks END-TO-END SEQUENCE IDENTITY on the
// CFAR detection output:
//
//   * m_seq observed at m_eof handshakes must be non-decreasing (SPEC 5
//     seq propagation through PFB -> FFT -> history -> alignment ->
//     beamformer -> power -> CFAR). The Session's core_sample() monitor
//     counts violations; a nonzero count fails the run.
//   * frames_observed at drain must exactly equal frames_driven; a strict
//     equality, not a "at least this many". This catches frame loss inside
//     the pipeline that a >= check would silently accept.
//
// The per-block stream_protocol_checker instances (bound inside every block
// by their `ifndef SYNTHESIS` blocks) provide the per-hop seq continuity
// under the SPEC 5 stability rule; this test cross-checks the whole chain
// on the output side.
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

  // A sustained run per SPEC 13.1. Default 64 frames = 8192 input beats * 4
  // antennas + backpressure drain time, which still fits well under the
  // 5-minute sim-medium wall-clock budget.
  const std::uint64_t n_frames = args.plusarg("n_frames").empty()
      ? 64ULL
      : std::stoull(args.plusarg("n_frames"));

  sess.set_backpressure(pipeline_tb::BpProfile::kNone);
  sess.set_input_gap(0.0);
  sess.set_expect_detections(true);

  for (std::uint64_t f = 0; f < n_frames; ++f) {
    sess.queue_frame(pipeline_tb::random_tone(sess.rng()));
  }

  const bool drained = sess.run_until_idle(n_frames * 20000ULL);

  // Sequence-ID accounting on the output side. Per Phase 6 (issue #21) each
  // input frame produces one m_eof per beam on the CFAR boundary (per-beam
  // CFAR + round-robin arbiter -- see DECISIONS.md 2026-07-28 issue #21).
  // Exact accounting still: frames_observed must equal
  // kNBeams * frames_driven exactly, not >=.
  const std::uint64_t frames_driven   = sess.frames_driven();
  const std::uint64_t frames_observed = sess.frames_observed();
  const std::uint64_t seq_violations  = sess.m_seq_violations();
  const std::uint64_t expected_out =
      static_cast<std::uint64_t>(pipeline_tb::Session::frames_per_input_frame())
      * frames_driven;

  bool pass = drained && sess.errors().count() == 0;

  if (expected_out != frames_observed) {
    std::fprintf(stderr,
                 "[test_pipeline_continuous] FRAME ACCOUNTING MISMATCH: "
                 "driven=%llu expected=%llu (N_BEAMS=%u * driven) observed=%llu "
                 "(exact equality required)\n",
                 static_cast<unsigned long long>(frames_driven),
                 static_cast<unsigned long long>(expected_out),
                 pipeline_tb::Session::frames_per_input_frame(),
                 static_cast<unsigned long long>(frames_observed));
    pass = false;
  }
  if (seq_violations != 0) {
    std::fprintf(stderr,
                 "[test_pipeline_continuous] m_seq monotonicity VIOLATIONS=%llu "
                 "(end-to-end seq propagation broken)\n",
                 static_cast<unsigned long long>(seq_violations));
    pass = false;
  }

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
  summary.passed = pass;
  summary.stop_reason = pass ? "pass" : "fail";
  summary.absorb(sess.errors());
  const std::string path = summary.write(args.results_dir);
  if (!path.empty()) {
    std::printf("[test_pipeline_continuous] summary: %s\n", path.c_str());
  }

  std::printf("RESULT: %s (seed=%llu, %llu frames driven, %llu observed, seq_viol=%llu)\n",
              pass ? "PASS" : "FAIL",
              static_cast<unsigned long long>(args.seed),
              static_cast<unsigned long long>(n_frames),
              static_cast<unsigned long long>(summary.frames_observed),
              static_cast<unsigned long long>(seq_violations));

  return pass ? 0 : 1;
}

}  // namespace harness
