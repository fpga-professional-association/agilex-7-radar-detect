// -----------------------------------------------------------------------------
// test_pipeline_continuous — the SPEC.md 19 Phase 3 end-to-end regression
// (issue #17).
//
// Continuous frames through the whole SPEC 3 pipeline, with every stage checked
// against the C++ model applied to that stage's own observed input, and the
// chain checked end to end on top of that. Build:
// sim/verilator/files.f, top `benchmark_sim_top`, `make sim-medium`.
//
// Passes
// ------
//   1  geometry echo. The design's own report of BIN_PAR, ALIGN_GROUPS, LANES
//      and BEAM_MUX against what the model is about to assume. An early return
//      on failure: every later comparison would be against the wrong shape.
//   2  impulse chain-through. One impulse per frame per antenna, a
//      pass-through filter and selector weights, so the value that comes out of
//      the far end is traceable to the sample that went in. The SPEC 13.2
//      impulse-response property, applied to eight stages at once.
//   3  a tone lands in the bin both the design and the model say it does, and
//      the beam it lands in is the beam steered to its wavefront. The SPEC 7.5
//      claim, checked as a ratio rather than as a detection so that the answer
//      does not depend on the threshold.
//   4  an injected target is DETECTED, at the right bin, in the right beam,
//      with the detector's own event fields reproducing its decision.
//   5  continuous pseudo-random frames, every stage bit-exact, with the SPEC 9
//      counters cross-checked against the harness's independent tally.
//   6  the same stimulus under output backpressure: every observed transaction
//      identical, which is SPEC 13.2's backpressure-invariance property.
//
// Why the impulse pass uses a pass-through filter
// -----------------------------------------------
// A polyphase bank whose tap 0 is unity and whose other taps are zero has a
// one-beat impulse response, so the transform sees exactly the impulse the
// source produced and its output is flat with a known phase ramp. Any other
// filter would make the expected spectrum a function of the coefficient set, and
// the pass would then be checking the coefficient generator rather than the
// chain. The filter's own arithmetic is issue #10's subject and is verified
// there against every tap set the vectors carry.
// -----------------------------------------------------------------------------

#include <chrono>
#include <cstdio>
#include <memory>
#include <string>
#include <vector>

#include "pipeline_tb.h"

namespace {

constexpr const char* kTestName = "test_pipeline_continuous";

using pipetb::fail;
using pipetb::g_counters;
using pipetb::Session;

// Frames the harness models per pass. Enough that the history has rotated at
// least once at the medium depth, so the read side is exercised against a
// wrapped ring rather than a filling one.
constexpr std::size_t kModelFrames = 6;

// Frames the corner turn must hold before the alignment network is opened.
// Three is the smallest number for which `readable = depth - 2` is positive at
// the tiny geometry's four-frame depth, and the medium geometry's sixteen makes
// it comfortable rather than marginal.
constexpr std::uint32_t kWarmFrames = 3;

// Frames the checks model. It must cover every frame a sweep could have read —
// the alignment network reads the NEWEST complete frame, and the capture runs
// past the warm-up — so it is the warm-up plus the measured window rather than
// the measured window alone. Modelling too many frames costs a little time;
// modelling too few makes `check_alignment` fail to find the frame a beat came
// from and report a defect that is not there.
constexpr std::size_t kCheckFrames = 512;

// Core cycles per pass. One sweep is FFT_SIZE bins at one bin per cycle plus
// the detectors' per-frame overhead, so this is generous by construction rather
// than by tuning; a pass that needs more says so by producing no complete frame,
// which every check reports by name.
std::uint64_t cycles_for(const pipeline::Geometry& g, std::size_t frames) {
  const std::uint64_t per_sweep =
      static_cast<std::uint64_t>(g.fft_size) * 3 +
      static_cast<std::uint64_t>(g.cfar_max_guard + g.cfar_max_ref + 32);
  return per_sweep * (frames + 4) + 4096;
}

// One configured run: program, let it fill, capture. Returns false on a hang.
// `quiesce` closes the source's tap before the alignment network is opened, so
// the sweeps read a history that is not rotating.
//
// It matters for two properties that are otherwise not testable here. A rotating
// history means successive sweeps read DIFFERENT absolute frames, so two runs at
// different speeds legitimately produce different values — which makes SPEC
// 13.2's backpressure invariance unmeasurable, because the thing that changed
// was which frame was read and not what the pipeline did to it. It also means a
// group's requests can straddle a frame completion (see check_counters), which
// zeroes a lane and puts a hole in a spectrum that is supposed to be flat.
//
// With the source stopped both go away: every sweep reads the same frame, the
// straddle window does not exist, and a difference between two runs is a
// difference in the design.
bool run_pass(Session& s, pipeline::SrcMode mode, unsigned tone_step,
              unsigned ant_step, std::uint32_t seed,
              const std::vector<fxp::Complex>& coeff,
              const std::vector<fxp::Complex>& weights, const cfar::Config& cfg,
              pipeline::SrcConfig* src_out, bool quiesce = false,
              unsigned cycle_mul = 1) {
  const pipeline::Geometry& g = s.g();

  // Both banks loaded and the design restarted, so frame 0 of the captured run
  // is filtered by the programmed set and the tap history starts empty. See
  // Session::program_banks for why this needs a restart.
  if (!s.program_banks(coeff, weights)) return false;

  // `program_banks` ends with a full reset, and PIPE_CTRL's two sweep gates reset
  // CLOSED, so nothing has flowed since: the polyphase tap history, the
  // transform's delay feedbacks, the corner turn and every counter are empty and
  // stay empty until the tap below is opened. That is what makes frame 0 of this
  // capture a frame the model can predict exactly.
  *src_out = s.configure_source(mode, fxp::q15_max(), tone_step, ant_step, seed);
  const cfar::Config used =
      s.configure_cfar(cfg.guard_lead, cfg.ref_lead, cfg.alpha, cfg.mode,
                       cfg.out_mode);
  (void)used;
  s.configure_history(g.history_frames);

  // Fill the corner turn with the alignment network CLOSED. A sweep issued
  // against a history with no complete frame is answered out-of-range on every
  // response — correct behaviour, and not what any of these passes is about.
  s.clear_observations();
  s.set_run(true, false);
  if (!s.wait_frames(kWarmFrames, cycles_for(g, kWarmFrames))) return false;
  // Mark the harness's tallies BEFORE the clear, not after: the clear crosses
  // into the datapath and lands while the register writes that requested it are
  // still going, so a mark taken afterwards is later than the clear and the
  // design's counter would legitimately read AHEAD of the harness's. Marking
  // first makes "ahead" a hard error and "behind" the bounded crossing lag.
  s.mark_counter_epoch();
  s.clear_telemetry();

  if (quiesce) {
    s.set_run(false, false);
    if (!s.settle(2 * g.beats_per_frame() + 1024)) return false;
    // The observations are NOT cleared here. The alignment network has been shut
    // all through the warm-up, so nothing downstream has been captured yet, and
    // the source and transform beats already recorded are exactly what the
    // front-end model needs in order to say what the history now holds.
    s.mark_counter_epoch();
  }

  s.set_run(quiesce ? false : true, true);
  if (!s.run_core(cycles_for(g, kModelFrames) * cycle_mul)) return false;

  // Quiesce before anything is read: a counter compared against a tally taken
  // while both were still moving would be a race the test would lose
  // intermittently.
  s.set_run(false, false);
  return s.settle(4096);
}

// The bin a spectral line must land in, and the beam it must land in, are both
// functions of the programmed stimulus. Stated once.
struct Target {
  unsigned bin = 0;
  unsigned beam = 0;
  unsigned tone_step = 0;
  unsigned ant_step = 0;
};

Target target_for(const pipeline::Geometry& g, unsigned bin, unsigned beam) {
  Target t;
  t.bin = bin;
  t.beam = beam;
  t.tone_step = pipeline::step_for_bin(g.fft_size, bin);
  t.ant_step = beam * pipeline::beam_spacing(g.n_ant, g.fft_size);
  return t;
}

// The mean power a beam saw at a bin, over the complete frames observed.
std::uint64_t beam_power_at(Session& s, unsigned beam, unsigned bin) {
  const pipeline::Geometry& g = s.g();
  std::uint64_t best = 0;
  unsigned idx = 0;
  bool open = false;
  for (const pipetb::PowerBeat& b : s.power_beats()) {
    if (b.meta.sof) {
      idx = 0;
      open = true;
    }
    if (!open) continue;
    if (idx == bin && b.beam[beam] > best) best = b.beam[beam];
    ++idx;
    if (b.meta.eof) open = false;
    if (idx > g.fft_size) open = false;
  }
  return best;
}

}  // namespace

int harness::sim_test_main(const harness::SimArgs& args) {
  const auto wall_start = std::chrono::steady_clock::now();

  harness::ErrorCollector errors;
  pipetb::g_errors = &errors;
  g_counters = pipetb::Counters{};

  auto top = std::make_unique<Vbenchmark_sim_top>();
  Session s(top.get(), &errors, args.seed);
  const pipeline::Geometry g = s.g();

  std::printf("--- medium-configuration pipeline, continuous frames ---\n");
  std::printf("  geometry     : %s\n", g.describe().c_str());
  std::printf("  clock ratio  : %s\n", s.ratio_name().c_str());

  // ---- pass 1: geometry ---------------------------------------------------
  if (!s.reset()) {
    fail("hang", &g_counters.hang, "reset never completed");
    return pipetb::finish(args, kTestName, errors, 0, 0, 0.0, "", "reset hang");
  }
  if (!pipetb::check_geometry(s, top.get())) {
    return pipetb::finish(args, kTestName, errors, 1, 0, 0.0, "",
                          "the design's geometry is not the model's");
  }
  pipetb::print_latency(top.get());

  const std::vector<fxp::Complex> pass_coeff =
      pipeline::passthrough_coeff(g.lanes, g.pfb_taps);
  const std::vector<fxp::Complex> steer =
      pipeline::steering_weights(g.n_ant, g.n_beams, g.fft_size);
  const std::vector<fxp::Complex> select =
      pipeline::selector_weights(g.n_ant, g.n_beams);

  cfar::Config cfg;
  cfg.enable = true;
  cfg.mode = cfar::Mode::kCA;
  cfg.out_mode = cfar::OutMode::kEvents;
  cfg.guard_lead = cfg.guard_lag = 2;
  cfg.ref_lead = cfg.ref_lag = 8;
  cfg.alpha = 4 * cfar::kAlphaOne;

  std::uint64_t beats = 0;
  std::uint64_t passes = 1;

  // ---- pass 2: impulse chain-through --------------------------------------
  {
    pipeline::SrcConfig src;
    if (!run_pass(s, pipeline::SrcMode::kImpulse, 0, 0, 0x1u, pass_coeff, select,
                  cfg, &src, /*quiesce=*/true)) {
      fail("hang", &g_counters.hang, "impulse pass did not complete");
    } else {
      pipetb::check_source(s, src, kCheckFrames);
      const auto bins = pipetb::check_front_end(s, pass_coeff, kCheckFrames);
      pipetb::check_history(s, bins);
      pipetb::check_alignment(s, bins);
      pipetb::check_back_end(s, select);

      // An impulse of amplitude A at sample 0 has a FLAT spectrum: every bin
      // must carry the same magnitude. That is the whole chain's impulse
      // response in one sentence, and it is checked here rather than left to
      // the per-stage comparisons because a chain that dropped a stage
      // altogether could still pass those.
      std::uint64_t lo = ~0ULL, hi = 0;
      unsigned counted = 0;
      bool open = false;
      unsigned idx = 0;
      for (const pipetb::PowerBeat& b : s.power_beats()) {
        if (b.meta.sof) { open = true; idx = 0; }
        if (!open) continue;
        if (idx > 0 && idx + 1 < g.fft_size) {
          lo = std::min(lo, b.beam[0]);
          hi = std::max(hi, b.beam[0]);
          ++counted;
        }
        ++idx;
        if (b.meta.eof) break;
      }
      if (counted == 0) {
        fail("detection", &g_counters.detection,
             "the impulse pass produced no complete power frame");
      } else if (hi == 0) {
        fail("detection", &g_counters.detection,
             "the impulse produced an identically zero spectrum: the chain is "
             "broken somewhere between the source and the power stage");
      } else if (hi - lo > hi / 64) {
        // The spread is the transform's own quantisation, not a signal.
        fail("detection", &g_counters.detection,
             "the impulse response is not flat: min=" + std::to_string(lo) +
                 " max=" + std::to_string(hi));
      } else {
        std::printf("  impulse      : flat spectrum, %u bins, |X|^2 in [%llu, %llu]\n",
                    counted, static_cast<unsigned long long>(lo),
                    static_cast<unsigned long long>(hi));
      }
      beats += s.power_beats().size();
    }
    ++passes;
  }

  // ---- pass 3: a tone in the right bin and the right beam -----------------
  {
    const unsigned bin = g.fft_size / 4;
    for (unsigned beam = 0; beam < g.n_beams; ++beam) {
      const Target t = target_for(g, bin, beam);
      pipeline::SrcConfig src;
      if (!run_pass(s, pipeline::SrcMode::kTone, t.tone_step, t.ant_step, 0x1u,
                    pass_coeff, steer, cfg, &src)) {
        fail("hang", &g_counters.hang, "tone pass did not complete");
        break;
      }
      pipetb::check_source(s, src, kCheckFrames);

      const std::uint64_t on_beam = beam_power_at(s, beam, bin);
      if (on_beam == 0) {
        fail("beamform", &g_counters.beamform,
             "tone at bin " + std::to_string(bin) + " steered to beam " +
                 std::to_string(beam) + " produced no power in that beam");
        break;
      }
      // Every other beam is orthogonal to this wavefront and must see a small
      // fraction of it. The bound is 1/1000 rather than zero because the
      // steering weights are Q1.15 quantised and the cancellation is therefore
      // not exact; it is three orders of magnitude, which no wiring error
      // survives.
      bool ok = true;
      for (unsigned other = 0; other < g.n_beams; ++other) {
        if (other == beam) continue;
        const std::uint64_t off = beam_power_at(s, other, bin);
        if (off * 1000 > on_beam) {
          fail("beamform", &g_counters.beamform,
               "tone steered to beam " + std::to_string(beam) +
                   " leaks into beam " + std::to_string(other) + ": " +
                   std::to_string(off) + " against " + std::to_string(on_beam));
          ok = false;
          break;
        }
      }
      // And the line is in the right bin of the right beam.
      std::uint64_t elsewhere = 0;
      for (unsigned k = 0; k < g.fft_size; ++k) {
        if (k == bin) continue;
        elsewhere = std::max(elsewhere, beam_power_at(s, beam, k));
      }
      if (ok && elsewhere * 100 > on_beam) {
        fail("beamform", &g_counters.beamform,
             "the tone is not confined to bin " + std::to_string(bin) +
                 ": strongest other bin is " + std::to_string(elsewhere) +
                 " against " + std::to_string(on_beam));
        ok = false;
      }
      if (!ok) break;
      if (beam == 0) {
        std::printf("  tone         : bin %u, on-beam |Y|^2 = %llu, best other "
                    "bin = %llu\n",
                    bin, static_cast<unsigned long long>(on_beam),
                    static_cast<unsigned long long>(elsewhere));
      }
    }
    ++passes;
  }

  // ---- pass 4: an injected target is detected -----------------------------
  {
    const unsigned bin = g.fft_size / 2;
    const unsigned beam = g.n_beams / 2;
    const Target t = target_for(g, bin, beam);
    if (!pipeline::bin_is_evaluable(g, cfg, bin)) {
      fail("detection", &g_counters.detection,
           "the chosen target bin is inside the frame's suppressed edge");
    } else {
      pipeline::SrcConfig src;
      if (!run_pass(s, pipeline::SrcMode::kTone, t.tone_step, t.ant_step, 0x1u,
                    pass_coeff, steer, cfg, &src)) {
        fail("hang", &g_counters.hang, "detection pass did not complete");
      } else {
        pipetb::check_source(s, src, kCheckFrames);
        const std::size_t compared = pipetb::check_detection(s, cfg, 0);

        // The detector's own arithmetic, re-run on the event's own fields. This
        // is what makes a detection event self-verifying (ARCHITECTURE.md 6.4)
        // and it is checked here on live events rather than assumed.
        std::size_t detects = 0;
        bool at_bin = false;
        for (const auto& e : s.events()) {
          if (e.second.kind != cfar::kEvDetect) continue;
          ++detects;
          if (e.first == beam && e.second.bin == bin) at_bin = true;
          if (!cfar::over_threshold(e.second.cut_power, e.second.noise_sum,
                                    e.second.ref_count, e.second.alpha)) {
            fail("detection", &g_counters.detection,
                 "an emitted DETECT does not satisfy its own comparison: " +
                     e.second.str());
            break;
          }
        }
        if (!at_bin) {
          fail("detection", &g_counters.detection,
               "no detection at bin " + std::to_string(bin) + " in beam " +
                   std::to_string(beam));
        }
        std::printf("  detection    : %zu DETECT events, %zu frames compared "
                    "field-for-field against the model\n",
                    detects, compared);
      }
    }
    ++passes;
  }

  // ---- pass 5: continuous pseudo-random frames ----------------------------
  std::vector<pipetb::PowerBeat> quiet_reference;
  {
    const std::vector<fxp::Complex> shaped =
        pipeline::shaped_coeff(g.lanes, g.pfb_taps,
                           static_cast<std::uint32_t>(args.seed | 1u));
    pipeline::SrcConfig src;
    if (!run_pass(s, pipeline::SrcMode::kLfsr, 0, 0,
                  static_cast<std::uint32_t>(args.seed * 2654435761u + 1u),
                  shaped, steer, cfg, &src)) {
      fail("hang", &g_counters.hang, "random-frame pass did not complete");
    } else {
      pipetb::check_source(s, src, kCheckFrames);
      const auto bins = pipetb::check_front_end(s, shaped, kCheckFrames);
      pipetb::check_history(s, bins);
      pipetb::check_alignment(s, bins);
      pipetb::check_back_end(s, steer);
      pipetb::check_detection(s, cfg, 0);
      pipetb::check_counters(s);
      std::printf("  network      : %u cycles delivered more than one lane at once\n                 (zero is expected here; the read port is multiplexed)\n",
                  pipetb::report_network_simultaneity(s));
      quiet_reference.assign(s.power_beats().begin(), s.power_beats().end());
      beats += s.power_beats().size();
      std::printf("  continuous   : %zu source beats, %zu history responses, "
                  "%zu alignment beats, %llu events\n",
                  s.adc_beats()[0].size(), s.hist_responses().size(),
                  s.align_beats().size(),
                  static_cast<unsigned long long>(s.event_count()));
    }
    ++passes;
  }

  // ---- pass 6: SPEC 13.2 backpressure invariance --------------------------
  //
  // Both halves sweep a QUIESCED history — see run_pass's `quiesce` — so the two
  // runs read the same frame and any difference between them is a difference in
  // what the pipeline did, not in what it was given.
  {
    const std::vector<fxp::Complex> shaped =
        pipeline::shaped_coeff(g.lanes, g.pfb_taps,
                               static_cast<std::uint32_t>(args.seed | 1u));
    const std::uint32_t bp_seed =
        static_cast<std::uint32_t>(args.seed * 2654435761u + 1u);

    std::vector<pipetb::PowerBeat> quiet;
    pipeline::SrcConfig src;

    s.set_event_backpressure(harness::BackpressureConfig::none());
    if (!run_pass(s, pipeline::SrcMode::kLfsr, 0, 0, bp_seed, shaped, steer, cfg,
                  &src, /*quiesce=*/true)) {
      fail("hang", &g_counters.hang, "the unstalled reference did not complete");
    } else {
      pipetb::check_back_end(s, steer);
      pipetb::check_detection(s, cfg, 0);
      quiet.assign(s.power_beats().begin(), s.power_beats().end());
    }

    // A budget six times the unstalled one: `heavy()` stalls the event consumer
    // half the time in bursts of up to eight, and the whole back end is behind
    // that consumer. The pass is about what comes out, not how fast.
    s.set_event_backpressure(harness::BackpressureConfig::heavy());
    if (!run_pass(s, pipeline::SrcMode::kLfsr, 0, 0, bp_seed, shaped, steer, cfg,
                  &src, /*quiesce=*/true, /*cycle_mul=*/6)) {
      fail("hang", &g_counters.hang, "the stalled run did not complete");
    } else {
      pipetb::check_back_end(s, steer);
      pipetb::check_detection(s, cfg, 0);

      const std::size_t n = std::min(quiet.size(), s.power_beats().size());
      if (n == 0) {
        fail("invariance", &g_counters.invariance,
             "the backpressure pair produced nothing to compare");
      }
      std::size_t same = 0;
      for (std::size_t i = 0; i < n; ++i) {
        const pipetb::PowerBeat& a = quiet[i];
        const pipetb::PowerBeat& b = s.power_beats()[i];
        if (a.meta.sof != b.meta.sof || a.meta.eof != b.meta.eof ||
            a.meta.seq != b.meta.seq || a.beam != b.beam) {
          fail("invariance", &g_counters.invariance,
               "backpressure changed power beat " + std::to_string(i) +
                   " (seq " + std::to_string(a.meta.seq) + " against " +
                   std::to_string(b.meta.seq) + ")");
          break;
        }
        ++same;
      }
      std::printf("  backpressure : %zu beats byte-identical with and without a "
                  "stalled event consumer\n", same);
      beats += s.power_beats().size();
    }
    s.set_event_backpressure(harness::BackpressureConfig::none());
    ++passes;
  }

  const auto wall_end = std::chrono::steady_clock::now();
  std::printf("--- results ---\n");
  g_counters.print();

  return pipetb::finish(
      args, kTestName, errors, passes, beats,
      std::chrono::duration<double>(wall_end - wall_start).count(),
      "every stage bit-exact against the C++ model, end to end",
      "pipeline mismatch; see errors_by_category");
}
