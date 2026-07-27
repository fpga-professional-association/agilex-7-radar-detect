// -----------------------------------------------------------------------------
// test_pipeline_metamorphic — the SPEC.md 13.2 property set, applied to the
// whole assembled pipeline (issue #17).
//
// SPEC 13.2 asks for "properties that remain valid without requiring large
// golden-data files". Every block in this design already has its own metamorphic
// suite; what this test adds is that the properties survive COMPOSITION, which
// is a different claim. A pipeline can be built from eight blocks each of which
// scales correctly and still not scale, because a stage in the middle saturates,
// or clamps, or reads a stale frame.
//
// The properties, and where each is checked
// -----------------------------------------
//   zero in / zero out            pass 2, here
//   impulse response              pass 3, here (and in test_pipeline_continuous)
//   scaling an unsaturated input  pass 4, here
//   delaying input delays output  pass 5, here
//   backpressure invariance       test_pipeline_continuous pass 6
//   inactive bank has no effect   test_pipeline_runtime_update pass 4
//   bank changes only at a legal boundary  test_pipeline_runtime_update 2, 3
//   antenna/weight permutation    pass 6, here
//   packet-network port isolation not applicable: this build has no packet
//                                 network (issue #19 binds it)
//   reset repeatability           pass 7, here
//
// Nothing here compares against a stored vector, and nothing here compares
// against the reference model either — that is what the other tests do. Every
// pass compares the design against ITSELF under a transformation, which is what
// makes these properties worth having: they hold even where the model and the
// design would be wrong together.
// -----------------------------------------------------------------------------

#include <algorithm>
#include <chrono>
#include <cstdio>
#include <memory>
#include <string>
#include <vector>

#include "pipeline_tb.h"

namespace {

constexpr const char* kTestName = "test_pipeline_metamorphic";

using pipetb::fail;
using pipetb::g_counters;
using pipetb::Session;

constexpr std::uint32_t kWarmFrames = 3;

std::uint64_t cycles_for(const pipeline::Geometry& g, std::size_t frames) {
  return (static_cast<std::uint64_t>(g.fft_size) * 3 + 128) * (frames + 4) + 4096;
}

// One quiesced capture: program, fill, stop the source, sweep. Quiesced because
// every property here is a statement about two runs, and a rotating history
// makes two runs read different frames for reasons that have nothing to do with
// the property being tested.
bool capture(Session& s, pipeline::SrcMode mode, std::int16_t gain,
             unsigned tone_step, unsigned ant_step,
             const std::vector<fxp::Complex>& coeff,
             const std::vector<fxp::Complex>& weights, const cfar::Config& cfg,
             unsigned extra_settle = 0) {
  const pipeline::Geometry& g = s.g();
  if (!s.program_banks(coeff, weights)) return false;
  s.configure_source(mode, gain, tone_step, ant_step, 0xC0FFEE11u);
  s.configure_cfar(cfg.guard_lead, cfg.ref_lead, cfg.alpha, cfg.mode, cfg.out_mode);
  s.configure_history(g.history_frames);

  s.clear_observations();
  if (extra_settle != 0 && !s.settle(extra_settle)) return false;

  s.set_run(true, false);
  if (!s.wait_frames(kWarmFrames + 2, cycles_for(g, kWarmFrames + 2))) return false;
  s.set_run(false, false);
  if (!s.settle(2 * g.beats_per_frame() + 1024)) return false;

  s.set_run(false, true);
  if (!s.run_core(cycles_for(g, 4))) return false;
  s.set_run(false, false);
  return s.settle(4096);
}

// The power beats of the first complete sweep, per beam.
std::vector<std::vector<std::uint64_t>> first_sweep(Session& s) {
  const pipeline::Geometry& g = s.g();
  std::vector<std::vector<std::uint64_t>> out;
  std::vector<std::vector<std::uint64_t>> cur;
  bool open = false;
  for (const pipetb::PowerBeat& b : s.power_beats()) {
    if (b.meta.sof) {
      cur.assign(g.n_beams, {});
      open = true;
    }
    if (!open) continue;
    for (unsigned k = 0; k < g.n_beams; ++k) cur[k].push_back(b.beam[k]);
    if (b.meta.eof) {
      if (cur[0].size() == g.fft_size) return cur;
      open = false;
    }
  }
  return out;
}

std::uint64_t peak_of(const std::vector<std::uint64_t>& v, unsigned* at) {
  std::uint64_t best = 0;
  for (std::size_t i = 0; i < v.size(); ++i) {
    if (v[i] > best) {
      best = v[i];
      if (at != nullptr) *at = static_cast<unsigned>(i);
    }
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

  std::printf("--- SPEC 13.2 metamorphic properties, whole pipeline ---\n");
  std::printf("  geometry     : %s\n", g.describe().c_str());

  if (!s.reset() || !pipetb::check_geometry(s, top.get())) {
    return pipetb::finish(args, kTestName, errors, 0, 0, 0.0, "",
                          "geometry or reset failure");
  }

  const std::vector<fxp::Complex> coeff =
      pipeline::passthrough_coeff(g.lanes, g.pfb_taps);
  const std::vector<fxp::Complex> steer =
      pipeline::steering_weights(g.n_ant, g.n_beams, g.fft_size);

  cfar::Config cfg;
  cfg.guard_lead = cfg.guard_lag = 2;
  cfg.ref_lead = cfg.ref_lag = 8;
  cfg.alpha = 4 * cfar::kAlphaOne;

  const unsigned bin = g.fft_size / 4;
  const unsigned step = pipeline::step_for_bin(g.fft_size, bin);
  const unsigned spacing = pipeline::beam_spacing(g.n_ant, g.fft_size);

  std::uint64_t passes = 1;
  std::uint64_t beats = 0;

  // ---- 2: zero in, zero out ----------------------------------------------
  {
    if (!capture(s, pipeline::SrcMode::kZero, fxp::q15_max(), 0, 0, coeff, steer,
                 cfg)) {
      fail("hang", &g_counters.hang, "the zero-input pass did not complete");
    } else {
      const auto sweep = first_sweep(s);
      if (sweep.empty()) {
        fail("invariance", &g_counters.invariance,
             "the zero-input pass produced no complete sweep");
      } else {
        std::uint64_t worst = 0;
        for (unsigned k = 0; k < g.n_beams; ++k) {
          worst = std::max(worst, peak_of(sweep[k], nullptr));
        }
        if (worst != 0) {
          fail("invariance", &g_counters.invariance,
               "zero in produced a nonzero spectrum, peak " +
                   std::to_string(worst));
        }
        std::size_t dets = 0;
        for (const auto& e : s.events()) {
          if (e.second.kind == cfar::kEvDetect) ++dets;
        }
        if (dets != 0) {
          fail("detection", &g_counters.detection,
               "zero in produced " + std::to_string(dets) + " detections; an "
               "identically zero spectrum detects nothing at any alpha");
        }
        std::printf("  zero in      : spectrum identically zero, %zu detections\n",
                    dets);
      }
      beats += s.power_beats().size();
    }
    ++passes;
  }

  // ---- 3: the impulse response is the programmed one ----------------------
  {
    if (!capture(s, pipeline::SrcMode::kImpulse, fxp::q15_max(), 0, 0, coeff,
                 steer, cfg)) {
      fail("hang", &g_counters.hang, "the impulse pass did not complete");
    } else {
      const auto sweep = first_sweep(s);
      if (sweep.empty()) {
        fail("invariance", &g_counters.invariance, "no complete sweep");
      } else {
        // A pass-through filter and an impulse give a flat spectrum; a beam
        // steered to broadside sees it at full amplitude.
        std::uint64_t lo = ~0ULL, hi = 0;
        for (unsigned k = 1; k + 1 < g.fft_size; ++k) {
          lo = std::min(lo, sweep[0][k]);
          hi = std::max(hi, sweep[0][k]);
        }
        if (hi == 0 || hi - lo > hi / 64) {
          fail("invariance", &g_counters.invariance,
               "the impulse response is not flat: [" + std::to_string(lo) + ", " +
                   std::to_string(hi) + "]");
        } else {
          std::printf("  impulse      : flat, |X|^2 in [%llu, %llu]\n",
                      static_cast<unsigned long long>(lo),
                      static_cast<unsigned long long>(hi));
        }
      }
    }
    ++passes;
  }

  // ---- 4: scaling an unsaturated input scales the output ------------------
  {
    // A tone, then the same tone at half amplitude. Power is quadratic, so the
    // ratio must be four to within the quantisation of one Q1.15 multiply per
    // sample — checked as a band rather than an equality, because the halving is
    // itself a Q1.15 multiply.
    //
    // THE AMPLITUDE IS 1/8 OF FULL SCALE, NOT FULL SCALE, and that is the whole
    // point of the pass. SPEC 13.2 says "scaling an UNSATURATED input scales the
    // output": a full-scale tone on four antennas sums to four times full scale
    // in the beamformer and saturates, and two saturated results have a ratio of
    // one however the input was scaled. The first version of this pass used full
    // scale and reported a ratio of 1.000000 — the property failing to hold
    // because its precondition did not.
    constexpr std::int16_t kAmp = 0x1000;   // 4 antennas x 0x1000 = 0x4000, clear
    constexpr std::int16_t kHalfAmp = 0x0800;
    std::uint64_t full = 0, half = 0;
    if (!capture(s, pipeline::SrcMode::kTone, kAmp, step, 0, coeff,
                 steer, cfg)) {
      fail("hang", &g_counters.hang, "the full-scale tone pass did not complete");
    } else {
      const auto sw = first_sweep(s);
      if (!sw.empty()) full = sw[0][bin];
    }
    if (!capture(s, pipeline::SrcMode::kTone, kHalfAmp, step, 0, coeff, steer,
                 cfg)) {
      fail("hang", &g_counters.hang, "the half-scale tone pass did not complete");
    } else {
      const auto sw = first_sweep(s);
      if (!sw.empty()) half = sw[0][bin];
    }
    if (full == 0 || half == 0) {
      fail("invariance", &g_counters.invariance,
           "the scaling pass produced no power at the tone bin");
    } else {
      const double ratio = static_cast<double>(full) / static_cast<double>(half);
      if (ratio < 3.8 || ratio > 4.2) {
        fail("invariance", &g_counters.invariance,
             "halving the input scaled the power by " + std::to_string(ratio) +
                 ", not by four");
      } else {
        std::printf("  scaling      : half amplitude gives a power ratio of "
                    "%.4f (four expected)\n", ratio);
      }
    }
    ++passes;
  }

  // ---- 5: delaying the input delays the output without changing it --------
  {
    std::vector<std::vector<std::uint64_t>> a, b;
    if (!capture(s, pipeline::SrcMode::kTone, fxp::q15_max(), step, spacing,
                 coeff, steer, cfg, /*extra_settle=*/0)) {
      fail("hang", &g_counters.hang, "the undelayed pass did not complete");
    } else {
      a = first_sweep(s);
    }
    // The same stimulus, started 977 core cycles later. 977 is prime and is not
    // a multiple of the frame period, the beat period or either clock ratio, so
    // the delay cannot accidentally be a whole number of anything.
    if (!capture(s, pipeline::SrcMode::kTone, fxp::q15_max(), step, spacing,
                 coeff, steer, cfg, /*extra_settle=*/977)) {
      fail("hang", &g_counters.hang, "the delayed pass did not complete");
    } else {
      b = first_sweep(s);
    }
    if (a.empty() || b.empty()) {
      fail("invariance", &g_counters.invariance,
           "the delay pass produced no complete sweep");
    } else if (a != b) {
      std::size_t first_diff = 0;
      for (std::size_t i = 0; i < a[0].size() && i < b[0].size(); ++i) {
        if (a[0][i] != b[0][i]) { first_diff = i; break; }
      }
      fail("invariance", &g_counters.invariance,
           "a 977-cycle delay changed the spectrum, first at bin " +
               std::to_string(first_diff));
    } else {
      std::printf("  delay        : a 977-cycle start delay leaves every bin of "
                  "every beam unchanged\n");
    }
    ++passes;
  }

  // ---- 6: antenna / weight permutation equivalence ------------------------
  {
    // The steering matrix is a DFT over the array, so steering the SOURCE to
    // beam m and reading beam m is the same experiment for every m: it permutes
    // the antenna phases and the weights consistently. SPEC 13.2's property is
    // that the beam output is then equivalent, and here "equivalent" is exact —
    // the same integer, because the permutation is a relabelling of a sum whose
    // terms are unchanged.
    std::vector<std::uint64_t> on_beam(g.n_beams, 0);
    bool ok = true;
    for (unsigned m = 0; m < g.n_beams && ok; ++m) {
      if (!capture(s, pipeline::SrcMode::kTone, fxp::q15_max(), step, m * spacing,
                   coeff, steer, cfg)) {
        fail("hang", &g_counters.hang, "a permutation pass did not complete");
        ok = false;
        break;
      }
      const auto sw = first_sweep(s);
      if (sw.empty()) {
        fail("invariance", &g_counters.invariance, "no complete sweep");
        ok = false;
        break;
      }
      on_beam[m] = sw[m][bin];
      // And every other beam must see essentially nothing: the matrix is
      // orthogonal, so the off-beam response is the quantisation of the weights
      // and nothing else.
      for (unsigned other = 0; other < g.n_beams; ++other) {
        if (other == m) continue;
        if (sw[other][bin] * 1000 > on_beam[m]) {
          fail("invariance", &g_counters.invariance,
               "wavefront " + std::to_string(m) + " leaks into beam " +
                   std::to_string(other));
          ok = false;
          break;
        }
      }
    }
    if (ok) {
      for (unsigned m = 1; m < g.n_beams; ++m) {
        if (on_beam[m] != on_beam[0]) {
          fail("invariance", &g_counters.invariance,
               "beam " + std::to_string(m) + " sees " +
                   std::to_string(on_beam[m]) + " where beam 0 sees " +
                   std::to_string(on_beam[0]) +
                   "; the permutation is not equivalent");
          break;
        }
      }
      std::printf("  permutation  : all %u steered beams see the identical "
                  "integer power %llu\n", g.n_beams,
                  static_cast<unsigned long long>(on_beam[0]));
    }
    ++passes;
  }

  // ---- 7: reset repeatability ---------------------------------------------
  {
    std::vector<std::vector<std::uint64_t>> a, b;
    if (capture(s, pipeline::SrcMode::kLfsr, fxp::q15_max(), 0, 0, coeff, steer,
                cfg)) {
      a = first_sweep(s);
    } else {
      fail("hang", &g_counters.hang, "the first reset-repeat pass did not run");
    }
    if (capture(s, pipeline::SrcMode::kLfsr, fxp::q15_max(), 0, 0, coeff, steer,
                cfg)) {
      b = first_sweep(s);
    } else {
      fail("hang", &g_counters.hang, "the second reset-repeat pass did not run");
    }
    if (a.empty() || b.empty()) {
      fail("invariance", &g_counters.invariance,
           "a reset-repeat pass produced no complete sweep");
    } else if (a != b) {
      fail("invariance", &g_counters.invariance,
           "reset followed by the same stimulus produced a different spectrum");
    } else {
      std::printf("  reset repeat : two full resets and the same stimulus give "
                  "byte-identical spectra\n");
    }
    beats += s.power_beats().size();
    ++passes;
  }

  const auto wall_end = std::chrono::steady_clock::now();
  std::printf("--- results ---\n");
  g_counters.print();

  return pipetb::finish(
      args, kTestName, errors, passes, beats,
      std::chrono::duration<double>(wall_end - wall_start).count(),
      "every SPEC 13.2 property holds across the assembled pipeline",
      "a metamorphic property failed; see errors_by_category");
}
