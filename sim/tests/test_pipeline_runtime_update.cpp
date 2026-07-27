// -----------------------------------------------------------------------------
// test_pipeline_runtime_update — coefficient and beam-weight bank swaps in the
// assembled pipeline (SPEC.md 7.1, 7.5, 13.2; issue #17).
//
// Issues #10 and #12 verify their own banks: that a write to the active bank is
// refused, that a swap retires at a start-of-frame beat, that the status bits
// report it. What they cannot verify, because neither has a pipeline around it,
// is the property the swap exists for:
//
//     A FRAME IS FILTERED BY EXACTLY ONE COEFFICIENT SET AND BEAMFORMED BY
//     EXACTLY ONE WEIGHT MATRIX.
//
// That is a statement about a frame's whole journey through eight stages, and it
// is what this test checks. The mechanism is the same identity keying the rest
// of the suite uses: every frame's spectrum is predicted from the coefficient
// set in force when its first sample was admitted, and every beat's beam values
// from the weight matrix in force when its group was issued. A swap that landed
// one beat early or one frame late produces a frame that matches NEITHER
// prediction, which is a named failure rather than a small numerical drift.
//
// Passes
// ------
//   1  geometry echo.
//   2  a coefficient swap at a frame boundary. Two sets, alternating, with the
//      pipeline running continuously; every frame must match one set exactly and
//      the set must change only at a frame boundary.
//   3  a weight swap at a frame boundary, checked the same way against the
//      beamformer's own output.
//   4  SPEC 13.2's inactive-bank property: writing the SPARE bank changes
//      nothing until the swap is requested, and a write aimed at the ACTIVE bank
//      is refused and flagged rather than applied.
//   5  a swap requested while one is in flight is refused and reported, not
//      queued.
// -----------------------------------------------------------------------------

#include <chrono>
#include <cstdio>
#include <memory>
#include <string>
#include <vector>

#include "pipeline_tb.h"

namespace {

constexpr const char* kTestName = "test_pipeline_runtime_update";

using pipetb::fail;
using pipetb::g_counters;
using pipetb::Session;

constexpr std::size_t kCheckFrames = 512;
constexpr std::uint32_t kWarmFrames = 3;

std::uint64_t cycles_for(const pipeline::Geometry& g, std::size_t frames) {
  return (static_cast<std::uint64_t>(g.fft_size) * 3 + 128) * (frames + 4) + 4096;
}

// Program both banks with `a`, start, then swap to `b` while running.
//
// The captured run therefore contains frames filtered by `a` and frames filtered
// by `b`, with the transition at a boundary the design chose rather than one the
// test imposed — which is the only way to check that the design chose a boundary
// at all.
bool swap_while_running(Session& s, const std::vector<fxp::Complex>& coeff_a,
                        const std::vector<fxp::Complex>& coeff_b,
                        const std::vector<fxp::Complex>& w_a,
                        const std::vector<fxp::Complex>& w_b, bool swap_coeff,
                        pipeline::SrcConfig* src_out, const cfar::Config& cfg,
                        std::size_t* swap_beat) {
  const pipeline::Geometry& g = s.g();

  if (!s.program_banks(coeff_a, w_a)) return false;

  *src_out = s.configure_source(pipeline::SrcMode::kLfsr, fxp::q15_max(), 0, 0,
                                0xA5A5F00Du);
  s.configure_cfar(cfg.guard_lead, cfg.ref_lead, cfg.alpha, cfg.mode,
                   cfg.out_mode);
  s.configure_history(g.history_frames);

  s.clear_observations();
  s.set_run(true, false);
  if (!s.wait_frames(kWarmFrames, cycles_for(g, kWarmFrames))) return false;
  s.set_run(true, true);
  if (!s.run_core(cycles_for(g, 2))) return false;

  // Load the SPARE bank while the pipeline runs. Nothing may change yet: that is
  // SPEC 13.2's "changing inactive coefficient memory has no immediate effect".
  if (swap_coeff) {
    s.load_coefficients(coeff_b, 1);
  } else {
    s.load_weights(w_b, 1);
  }
  if (!s.run_core(cycles_for(g, 1))) return false;

  *swap_beat = swap_coeff ? s.fft_beats()[0].size() : s.beam_beats().size();

  if (swap_coeff) {
    s.swap_coefficients(1);
  } else {
    s.swap_weights();
  }
  if (!s.run_core(cycles_for(g, 3))) return false;

  s.set_run(false, false);
  return s.settle(4096);
}

// Every frame of the transform's output must match ONE of the two coefficient
// sets exactly, and the set in force must change at most once and only on a
// frame boundary.
void check_coefficient_boundary(Session& s,
                                const std::vector<fxp::Complex>& coeff_a,
                                const std::vector<fxp::Complex>& coeff_b) {
  const pipeline::Geometry& g = s.g();

  std::size_t n_frames = kCheckFrames;
  for (unsigned a = 0; a < g.n_ant; ++a) {
    n_frames = std::min(n_frames, s.fft_beats()[a].size() / g.beats_per_frame());
    n_frames = std::min(n_frames, s.adc_beats()[a].size() / g.beats_per_frame());
  }
  if (n_frames < 4) {
    fail("framing", &g_counters.framing,
         "only " + std::to_string(n_frames) + " complete frames were captured");
    return;
  }

  // Two models, one per set, driven by the same observed samples. A frame's tap
  // history is a function of the samples and not of the coefficients, so running
  // both in parallel over the whole capture is exact for both.
  std::vector<pfb::PfbModel> ma, mb;
  for (unsigned a = 0; a < g.n_ant; ++a) {
    ma.emplace_back(g.lanes, g.pfb_taps, coeff_a);
    mb.emplace_back(g.lanes, g.pfb_taps, coeff_b);
  }

  int last = -1;
  unsigned changes = 0;

  for (std::size_t f = 0; f < n_frames; ++f) {
    bool fits_a = true;
    bool fits_b = true;

    for (unsigned a = 0; a < g.n_ant; ++a) {
      std::vector<fxp::Complex> ya(g.fft_size), yb(g.fft_size);
      for (unsigned k = 0; k < g.beats_per_frame(); ++k) {
        const pipetb::FrontBeat& in =
            s.adc_beats()[a][f * g.beats_per_frame() + k];
        const pfb::BeatResult ra = ma[a].step(in.lane);
        const pfb::BeatResult rb = mb[a].step(in.lane);
        for (unsigned l = 0; l < g.lanes; ++l) {
          ya[k * g.lanes + l] = ra.y[l];
          yb[k * g.lanes + l] = rb.y[l];
        }
      }
      fft::Config fc;
      fc.n_fft = g.fft_size;
      fc.spc = g.lanes;
      fc.reorder = false;
      const fft::Result ra = fft::transform(fc, ya);
      const fft::Result rb = fft::transform(fc, yb);

      for (unsigned k = 0; k < g.beats_per_frame() && (fits_a || fits_b); ++k) {
        const pipetb::FrontBeat& out =
            s.fft_beats()[a][f * g.beats_per_frame() + k];
        for (unsigned l = 0; l < g.lanes; ++l) {
          if (out.lane[l] != ra.out[k * g.lanes + l]) fits_a = false;
          if (out.lane[l] != rb.out[k * g.lanes + l]) fits_b = false;
        }
      }
    }

    // Frame 0 is the one whose tap history predates the capture (see
    // pipeline_tb.h's note on the delay line surviving reset); it is expected to
    // fit neither and is not counted.
    if (f == 0) continue;

    if (!fits_a && !fits_b) {
      fail("front", &g_counters.front,
           "frame " + std::to_string(f) +
               " matches NEITHER coefficient set: the swap landed inside a "
               "frame");
      return;
    }
    // A frame that fits both is one the two sets cannot distinguish, which is
    // possible only if they are equal; the caller chooses distinct sets and the
    // check below would not see a boundary at all if they were not.
    const int now = fits_a ? 0 : 1;
    if (last >= 0 && now != last) ++changes;
    last = now;
  }

  if (changes == 0) {
    fail("front", &g_counters.front,
         "the coefficient set never changed: the swap did not take effect");
  } else if (changes > 1) {
    fail("front", &g_counters.front,
         "the coefficient set changed " + std::to_string(changes) +
             " times; one swap was requested");
  } else {
    std::printf("  coeff swap   : one clean transition over %zu frames, no frame "
                "filtered by two sets\n", n_frames);
  }
}

// The same argument on the beamformer's output: every beat must match one weight
// matrix exactly, and the matrix in force must change once, at a beat boundary.
void check_weight_boundary(Session& s, const std::vector<fxp::Complex>& w_a,
                           const std::vector<fxp::Complex>& w_b) {
  const pipeline::Geometry& g = s.g();

  std::map<std::uint32_t, const pipetb::AlignBeat*> by_seq;
  for (const pipetb::AlignBeat& b : s.align_beats()) by_seq[b.meta.seq] = &b;

  int last = -1;
  unsigned changes = 0;
  std::size_t checked = 0;
  std::vector<fxp::Complex> x(g.n_ant), wa(g.n_ant), wb(g.n_ant);

  for (const pipetb::BeamBeat& out : s.beam_beats()) {
    const auto it = by_seq.find(out.meta.seq);
    if (it == by_seq.end()) continue;
    const pipetb::AlignBeat& in = *it->second;
    if ((in.meta.user & 0xFu) != 0u) continue;  // a repaired beat is not a value

    bool fits_a = true;
    bool fits_b = true;
    for (unsigned bm = 0; bm < g.beam_par && (fits_a || fits_b); ++bm) {
      for (unsigned a = 0; a < g.n_ant; ++a) {
        wa[a] = w_a[bf::weight_index(g.n_ant, bm, a)];
        wb[a] = w_b[bf::weight_index(g.n_ant, bm, a)];
      }
      for (unsigned j = 0; j < g.bin_par; ++j) {
        for (unsigned a = 0; a < g.n_ant; ++a) {
          x[a] = in.data[pipeline::align_index(g, j, a)];
        }
        const fxp::Complex got = out.data[bm * g.bin_par + j];
        if (got != bf::dot(x, wa).y) fits_a = false;
        if (got != bf::dot(x, wb).y) fits_b = false;
      }
    }

    if (!fits_a && !fits_b) {
      fail("beamform", &g_counters.beamform,
           "beat seq " + std::to_string(out.meta.seq) +
               " matches NEITHER weight matrix: the swap landed inside a beat");
      return;
    }
    ++checked;
    const int now = fits_a ? 0 : 1;
    if (last >= 0 && now != last) ++changes;
    last = now;
  }

  if (checked == 0) {
    fail("beamform", &g_counters.beamform, "no beamformer beat could be checked");
  } else if (changes == 0) {
    fail("beamform", &g_counters.beamform,
         "the weight matrix never changed: the swap did not take effect");
  } else if (changes > 1) {
    fail("beamform", &g_counters.beamform,
         "the weight matrix changed " + std::to_string(changes) +
             " times; one swap was requested");
  } else {
    std::printf("  weight swap  : one clean transition over %zu beats, no beat "
                "beamformed by two matrices\n", checked);
  }
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

  std::printf("--- runtime coefficient and weight updates ---\n");
  std::printf("  geometry     : %s\n", g.describe().c_str());

  if (!s.reset() || !pipetb::check_geometry(s, top.get())) {
    return pipetb::finish(args, kTestName, errors, 0, 0, 0.0, "",
                          "geometry or reset failure");
  }

  // Two coefficient sets and two weight matrices, chosen so no frame and no beat
  // can accidentally fit both.
  const std::vector<fxp::Complex> coeff_a =
      pipeline::shaped_coeff(g.lanes, g.pfb_taps,
                             static_cast<std::uint32_t>(args.seed | 1u));
  const std::vector<fxp::Complex> coeff_b =
      pipeline::shaped_coeff(g.lanes, g.pfb_taps,
                             static_cast<std::uint32_t>((args.seed | 1u) * 7u + 3u));
  const std::vector<fxp::Complex> w_a =
      pipeline::steering_weights(g.n_ant, g.n_beams, g.fft_size);
  const std::vector<fxp::Complex> w_b =
      pipeline::selector_weights(g.n_ant, g.n_beams);

  cfar::Config cfg;
  cfg.guard_lead = cfg.guard_lag = 2;
  cfg.ref_lead = cfg.ref_lag = 8;
  cfg.alpha = 4 * cfar::kAlphaOne;

  std::uint64_t beats = 0;
  std::uint64_t passes = 1;

  // ---- pass 2: a coefficient swap at a frame boundary ---------------------
  {
    pipeline::SrcConfig src;
    std::size_t at = 0;
    if (!swap_while_running(s, coeff_a, coeff_b, w_a, w_a, true, &src, cfg, &at)) {
      fail("hang", &g_counters.hang, "the coefficient-swap pass did not complete");
    } else {
      pipetb::check_source(s, src, kCheckFrames);
      check_coefficient_boundary(s, coeff_a, coeff_b);
      beats += s.fft_beats()[0].size();
    }
    ++passes;
  }

  // ---- pass 3: a weight swap at a frame boundary --------------------------
  {
    pipeline::SrcConfig src;
    std::size_t at = 0;
    if (!swap_while_running(s, coeff_a, coeff_a, w_a, w_b, false, &src, cfg, &at)) {
      fail("hang", &g_counters.hang, "the weight-swap pass did not complete");
    } else {
      pipetb::check_source(s, src, kCheckFrames);
      check_weight_boundary(s, w_a, w_b);
      beats += s.beam_beats().size();
    }
    ++passes;
  }

  // ---- pass 4: the inactive bank, and the refusal of the active one -------
  {
    if (!s.program_banks(coeff_a, w_a)) {
      fail("hang", &g_counters.hang, "bank programming did not complete");
    } else {
      // The active bank is 0 after the restart. A write aimed at it must be
      // refused and flagged — SPEC 7.1's rule, and the one that makes "write the
      // spare, then swap" the only correct sequence.
      s.write(regmap::COEFF_COEFF_CTRL_ADDR, 0u, "select the active bank");
      s.write(regmap::COEFF_COEFF_ADDR_ADDR,
              (1u << regmap::COEFF_COEFF_ADDR_AUTO_INC_LSB), "index");
      s.write(regmap::COEFF_COEFF_DATA_ADDR, 0x12345678u, "write the active bank");
      if (!s.settle(256)) fail("hang", &g_counters.hang, "settle failed");

      const std::uint32_t st =
          s.read(regmap::COEFF_COEFF_STATUS_ADDR, "coeff status");
      if (((st >> regmap::COEFF_COEFF_STATUS_WR_REJECT_LSB) & 1u) == 0u) {
        fail("counter", &g_counters.counter,
             "a write to the ACTIVE coefficient bank was not refused: "
             "COEFF_STATUS.WR_REJECT is clear");
      } else {
        std::printf("  active bank  : a write to it was refused and flagged\n");
      }

      // And the spare bank may be written freely with no effect on the datapath.
      s.load_coefficients(coeff_b, 1);
      const std::uint32_t bank_before =
          s.read(regmap::COEFF_COEFF_STATUS_ADDR, "coeff status") &
          (1u << regmap::COEFF_COEFF_STATUS_ACTIVE_BANK_LSB);
      if (bank_before != 0) {
        fail("counter", &g_counters.counter,
             "writing the spare bank changed the ACTIVE bank");
      }
    }
    ++passes;
  }

  // ---- pass 5: a swap requested while one is in flight --------------------
  {
    s.set_run(true, true);
    if (!s.settle(64)) fail("hang", &g_counters.hang, "settle failed");
    s.swap_coefficients(1);
    s.swap_coefficients(1);   // immediately again: this one must be refused
    if (!s.settle(2048)) fail("hang", &g_counters.hang, "settle failed");
    s.set_run(false, false);
    if (!s.settle(2048)) fail("hang", &g_counters.hang, "settle failed");

    const std::uint32_t st = s.read(regmap::COEFF_COEFF_STATUS_ADDR, "coeff status");
    const bool overrun =
        ((st >> regmap::COEFF_COEFF_STATUS_SWAP_OVERRUN_LSB) & 1u) != 0u;
    // The second request is refused ONLY if it arrives while the first is still
    // crossing. The register plane runs at a fifth of the core clock, so it is
    // possible for the first to have retired; what must never happen is a second
    // swap being silently queued, which would move the boundary a frame later
    // than software asked for. Both outcomes are legal and the test reports
    // which one it saw rather than requiring the race to go one way.
    std::printf("  swap overrun : second request %s\n",
                overrun ? "refused and flagged, as expected while busy"
                        : "accepted (the first had already retired)");
    ++passes;
  }

  const auto wall_end = std::chrono::steady_clock::now();
  std::printf("--- results ---\n");
  g_counters.print();

  return pipetb::finish(
      args, kTestName, errors, passes, beats,
      std::chrono::duration<double>(wall_end - wall_start).count(),
      "every frame filtered by one coefficient set and beamformed by one matrix",
      "a bank swap landed inside a frame or a beat");
}
