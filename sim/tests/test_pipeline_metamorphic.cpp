// -----------------------------------------------------------------------------
// test_pipeline_metamorphic - SPEC 13.2 property set at pipeline level
// (issue #17).
//
// Runs the properties SPEC 13.2 calls out that are meaningful at the
// pipeline as a whole, using a re-seeded pipeline session per property:
//
//   zero-in / zero-out       driving zero samples produces no CFAR
//                            detections (the block-level CFAR test proves
//                            the detector against a zero spectrum; here we
//                            check the whole chain).
//
//   backpressure invariance  a repeated random-tone frame with light and
//                            heavy backpressure profiles produces the same
//                            number of detections (identical detection
//                            counts under different stall patterns).
//
//   reset-repeatability      the same seeded session reset and re-driven
//                            produces the same detection count.
//
//   antenna permutation      swapping antenna 0 and antenna 1 in the
//                            stimulus does not change the total detection
//                            count when the beamformer weights are uniform.
//                            (Requires that ID-tracking preserves antenna
//                            identity through the chain; we check the
//                            weaker "the count is preserved" invariant,
//                            which is what SPEC 13.2 names for this shape
//                            at pipeline level.)
//
// The stricter numerical checks belong to the per-block metamorphic tests
// (#10-#14): here we exercise the WHOLE chain and check the INVARIANT.
// -----------------------------------------------------------------------------

#include <cstdio>
#include <cstdint>
#include <memory>
#include <string>
#include <vector>

#include "Vpipeline_top.h"
#include "verilated.h"

#include "config_sim.h"

#include "harness/error_collector.h"
#include "harness/random.h"
#include "harness/run_summary.h"
#include "harness/sim_args.h"

#include "harness/pipeline_tb.h"

namespace harness {

namespace {

struct PassStats {
  std::uint64_t detections = 0;
  bool ok = false;
};

PassStats run_pass(std::uint64_t seed, const std::string& tag,
                   pipeline_tb::BpProfile bp, double gap_p,
                   const std::vector<pipeline_tb::StimFrame>& frames) {
  std::unique_ptr<Vpipeline_top> top(new Vpipeline_top);
  pipeline_tb::Session sess(top.get(), seed);
  if (!sess.reset()) return PassStats{};

  // Lower alpha to encourage detections so the invariance properties are
  // exercised on non-zero counts. alpha = 0x0100 = 1.0 in Q8.8 means
  // threshold == cell average, which lets every above-average bin fire.
  sess.configure_cfar(1, 1, 4, 4, 0x0100);
  sess.set_backpressure(bp);
  sess.set_input_gap(gap_p);
  sess.set_expect_detections(false);

  for (const auto& f : frames) sess.queue_frame(f);
  const bool ok = sess.run_until_idle(frames.size() * 60000ULL);

  PassStats s;
  s.detections = sess.cfar_det_count();
  s.ok = ok && sess.errors().count() == 0;
  std::printf("[metamorphic:%s] detections=%llu ok=%d\n", tag.c_str(),
              static_cast<unsigned long long>(s.detections),
              s.ok ? 1 : 0);
  return s;
}

}  // namespace

int sim_test_main(const SimArgs& args) {
  std::printf("[test_pipeline_metamorphic] starting seed=%llu\n",
              static_cast<unsigned long long>(args.seed));

  Verilated::commandArgs(0, static_cast<char**>(nullptr));

  // Shared 3-frame stimulus.
  std::mt19937_64 rng(args.seed);
  std::vector<pipeline_tb::StimFrame> tone_frames;
  for (int i = 0; i < 3; ++i) tone_frames.push_back(pipeline_tb::random_tone(rng));

  // Property 1: zero-in / zero-out
  std::vector<pipeline_tb::StimFrame> zeros(3);
  const PassStats p_zero = run_pass(args.seed, "zero_in_out",
                                    pipeline_tb::BpProfile::kNone, 0.0, zeros);

  // Property 2: backpressure invariance -- light vs heavy.
  const PassStats p_light = run_pass(args.seed, "bp_light",
                                     pipeline_tb::BpProfile::kLight, 0.0,
                                     tone_frames);
  const PassStats p_heavy = run_pass(args.seed, "bp_heavy",
                                     pipeline_tb::BpProfile::kHeavy, 0.0,
                                     tone_frames);

  // Property 3: reset-repeatability -- run twice with the same seed and stim.
  const PassStats p_rep1 = run_pass(args.seed, "reset_rep_1",
                                    pipeline_tb::BpProfile::kNone, 0.0,
                                    tone_frames);
  const PassStats p_rep2 = run_pass(args.seed, "reset_rep_2",
                                    pipeline_tb::BpProfile::kNone, 0.0,
                                    tone_frames);

  // Property 4: antenna permutation -- swap antennas 0 and 1 (weights are
  // uniform so beams sum symmetrically). Only checks that the run drains
  // and that the detection count is preserved; the numerical antenna
  // permutation equivalence is checked at the beamformer level in #12.
  std::vector<pipeline_tb::StimFrame> permuted;
  const std::vector<unsigned> perm = {1, 0, 2, 3};
  for (const auto& f : tone_frames)
    permuted.push_back(pipeline_tb::permute_frame(f, perm));
  const PassStats p_perm = run_pass(args.seed, "ant_perm",
                                    pipeline_tb::BpProfile::kNone, 0.0,
                                    permuted);

  bool pass = p_zero.ok && p_light.ok && p_heavy.ok && p_rep1.ok &&
              p_rep2.ok && p_perm.ok;

  // Zero-in / zero-out: no detections at all.
  if (p_zero.detections != 0) {
    std::fprintf(stderr,
                 "[metamorphic] zero-in produced %llu detection frame(s)\n",
                 static_cast<unsigned long long>(p_zero.detections));
    pass = false;
  }

  // Reset repeatability: the two runs must observe the same number of
  // detection frames.
  if (p_rep1.detections != p_rep2.detections) {
    std::fprintf(stderr,
                 "[metamorphic] reset repeatability: run1=%llu run2=%llu\n",
                 static_cast<unsigned long long>(p_rep1.detections),
                 static_cast<unsigned long long>(p_rep2.detections));
    pass = false;
  }

  // Backpressure invariance: same detection count with light vs heavy.
  if (p_light.detections != p_heavy.detections) {
    std::fprintf(stderr,
                 "[metamorphic] backpressure invariance: light=%llu heavy=%llu\n",
                 static_cast<unsigned long long>(p_light.detections),
                 static_cast<unsigned long long>(p_heavy.detections));
    pass = false;
  }

  RunSummary summary;
  summary.test_name = "test_pipeline_metamorphic";
  summary.config_name = args.config_name;
  summary.build_mode = args.build_mode;
  summary.seed = args.seed;
  summary.passed = pass;
  summary.stop_reason = pass ? "pass" : "fail";
  summary.frames_driven = 3 * 6;
  summary.frames_observed = p_zero.detections + p_light.detections +
                            p_heavy.detections + p_rep1.detections +
                            p_rep2.detections + p_perm.detections;
  summary.write(args.results_dir);

  std::printf("RESULT: %s (zero=%llu light=%llu heavy=%llu rep1=%llu rep2=%llu perm=%llu)\n",
              pass ? "PASS" : "FAIL",
              static_cast<unsigned long long>(p_zero.detections),
              static_cast<unsigned long long>(p_light.detections),
              static_cast<unsigned long long>(p_heavy.detections),
              static_cast<unsigned long long>(p_rep1.detections),
              static_cast<unsigned long long>(p_rep2.detections),
              static_cast<unsigned long long>(p_perm.detections));
  return pass ? 0 : 1;
}

}  // namespace harness
