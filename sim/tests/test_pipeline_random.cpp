// -----------------------------------------------------------------------------
// test_pipeline_random — SPEC.md 13.3 randomized end-to-end regression
// (issue #17).
//
// SPEC 13.3 lists what must be randomized: input samples, amplitudes, tone
// frequencies, coefficients, beam weights, output stalls, clock-phase
// relationships, configuration access timing, coefficient-bank changes and FIFO
// pressure. This test randomizes every one of them that the assembled pipeline
// exposes, and then applies the SAME per-stage bit-exact comparison the directed
// regression uses — so a randomized run is not a smoke test, it is the directed
// test at a point nobody chose.
//
// What is randomized, per pass
// ----------------------------
//   clock ratio       drawn from the shared sweep in harness/clock_ratios.h, so
//                     core_clk and history_clk are related by 1:1 in phase, 1:1
//                     offset, 2:1, 1:2, 7:3, 3:7 and 100:99 across the passes.
//                     The last is the interesting one: a pointer crossing is
//                     least likely to be accidentally safe at a ratio close to,
//                     but not equal to, one.
//   stimulus          mode, amplitude, tone frequency, per-antenna phase and
//                     LFSR seed
//   coefficients      a fresh shaped set per pass, every tap distinct
//   weights           steering or selector, chosen at random
//   detector          guard, reference and threshold, within the elaborated
//                     maxima
//   output stalls     none / light / heavy / bursty
//   history depth     a legal value in [4, FRAMES_MAX]
//
// Reproducibility (SPEC 13.3: "Every test must print a reproducible seed")
// -----------------------------------------------------------------------
// Every draw comes from `harness::SeedSource`, whose substreams are named. The
// banner prints the master seed and the replay command; adding a pass or a draw
// changes only the substream it belongs to, so an existing failure stays
// reproducible when the test grows.
//
// Duration: `+passes=<n>` overrides the default. `make sim-random` sweeps SEEDS.
// -----------------------------------------------------------------------------

#include <chrono>
#include <cstdio>
#include <memory>
#include <string>
#include <vector>

#include "pipeline_tb.h"

namespace {

constexpr const char* kTestName = "test_pipeline_random";

using pipetb::fail;
using pipetb::g_counters;
using pipetb::Session;

constexpr std::size_t kCheckFrames = 512;
constexpr std::uint32_t kWarmFrames = 3;
constexpr unsigned kDefaultPasses = 4;

std::uint64_t cycles_for(const pipeline::Geometry& g, std::size_t frames) {
  return (static_cast<std::uint64_t>(g.fft_size) * 3 + 128) * (frames + 4) + 4096;
}

harness::BackpressureConfig bp_of(unsigned k) {
  switch (k & 3u) {
    case 0: return harness::BackpressureConfig::none();
    case 1: return harness::BackpressureConfig::light();
    case 2: return harness::BackpressureConfig::heavy();
    default: return harness::BackpressureConfig::bursty();
  }
}

const char* bp_name(unsigned k) {
  switch (k & 3u) {
    case 0: return "none";
    case 1: return "light";
    case 2: return "heavy";
    default: return "bursty";
  }
}

const char* mode_name(pipeline::SrcMode m) {
  switch (m) {
    case pipeline::SrcMode::kZero: return "zero";
    case pipeline::SrcMode::kImpulse: return "impulse";
    case pipeline::SrcMode::kConst: return "const";
    case pipeline::SrcMode::kTone: return "tone";
    default: return "lfsr";
  }
}

}  // namespace

int harness::sim_test_main(const harness::SimArgs& args) {
  const auto wall_start = std::chrono::steady_clock::now();

  harness::ErrorCollector errors;
  pipetb::g_errors = &errors;
  g_counters = pipetb::Counters{};

  harness::SeedSource seeds(args.seed);
  const unsigned n_passes = static_cast<unsigned>(
      std::stoul(args.plusarg("passes", std::to_string(kDefaultPasses))));

  std::printf("--- SPEC 13.3 randomized pipeline regression ---\n");
  std::printf("  master seed  : %llu   (replay: +seed=%llu +passes=%u)\n",
              static_cast<unsigned long long>(args.seed),
              static_cast<unsigned long long>(args.seed), n_passes);

  std::uint64_t beats = 0;
  const auto& ratios = harness::clock_ratios();

  for (unsigned pass = 0; pass < n_passes; ++pass) {
    const std::string tag = "pass" + std::to_string(pass);
    std::mt19937_64 rng = seeds.engine("pipeline.random." + tag);

    auto top = std::make_unique<Vbenchmark_sim_top>();
    const harness::ClockRatio& ratio =
        ratios[harness::uniform_u64(rng, 0, ratios.size() - 1)];
    Session s(top.get(), &errors, seeds.substream_seed("session." + tag), &ratio);
    const pipeline::Geometry g = s.g();

    if (!s.reset()) {
      fail("hang", &g_counters.hang, tag + ": reset never completed");
      break;
    }
    if (pass == 0 && !pipetb::check_geometry(s, top.get())) break;

    // ---- the draw --------------------------------------------------------
    const pipeline::SrcMode mode = static_cast<pipeline::SrcMode>(
        harness::uniform_u64(rng, 0, 4));
    // Amplitudes are drawn below full scale on purpose: a full-scale tone on
    // N_ANT antennas saturates the beamformer, and a saturated output is a
    // legitimate result that carries no information about the arithmetic. The
    // saturation path has its own directed coverage in issue #12's suite.
    const std::int16_t gain = static_cast<std::int16_t>(
        harness::uniform_u64(rng, 0x0400, 0x2000));
    const unsigned bin =
        static_cast<unsigned>(harness::uniform_u64(rng, 1, g.fft_size - 2));
    const unsigned tone = pipeline::step_for_bin(g.fft_size, bin);
    const unsigned ant_step = static_cast<unsigned>(
        harness::uniform_u64(rng, 0, g.n_beams - 1)) *
        pipeline::beam_spacing(g.n_ant, g.fft_size);
    const std::uint32_t lfsr_seed =
        static_cast<std::uint32_t>(harness::uniform_u64(rng, 1, 0xFFFFFFFFu));

    const std::vector<fxp::Complex> coeff = pipeline::shaped_coeff(
        g.lanes, g.pfb_taps,
        static_cast<std::uint32_t>(harness::uniform_u64(rng, 1, 0xFFFFFFFFu)));
    const bool steer_weights = harness::bernoulli(rng, 0.5);
    const std::vector<fxp::Complex> weights =
        steer_weights ? pipeline::steering_weights(g.n_ant, g.n_beams, g.fft_size)
                      : pipeline::selector_weights(g.n_ant, g.n_beams);

    cfar::Config cfg;
    cfg.enable = true;
    cfg.mode = harness::bernoulli(rng, 0.3) ? cfar::Mode::kGO : cfar::Mode::kCA;
    cfg.out_mode = cfar::OutMode::kEvents;
    cfg.guard_lead = cfg.guard_lag =
        static_cast<unsigned>(harness::uniform_u64(rng, 0, g.cfar_max_guard));
    cfg.ref_lead = cfg.ref_lag =
        static_cast<unsigned>(harness::uniform_u64(rng, 1, g.cfar_max_ref));
    cfg.alpha = static_cast<unsigned>(
        harness::uniform_u64(rng, cfar::kAlphaOne, 32u * cfar::kAlphaOne));

    const unsigned bp = static_cast<unsigned>(harness::uniform_u64(rng, 0, 3));
    const unsigned depth = static_cast<unsigned>(
        harness::uniform_u64(rng, 4, g.history_frames));

    std::printf("  %-6s ratio=%-14s mode=%-7s gain=0x%04X bin=%3u antstep=%3u "
                "guard=%u ref=%2u alpha=%5u %s stalls=%s depth=%2u\n",
                tag.c_str(), ratio.name, mode_name(mode),
                static_cast<unsigned>(static_cast<std::uint16_t>(gain)), bin,
                ant_step, cfg.guard_lead, cfg.ref_lead, cfg.alpha,
                steer_weights ? "steer " : "select", bp_name(bp), depth);

    // ---- the run ---------------------------------------------------------
    s.set_event_backpressure(bp_of(bp));
    if (!s.program_banks(coeff, weights)) {
      fail("hang", &g_counters.hang, tag + ": bank programming did not complete");
      break;
    }
    const pipeline::SrcConfig src =
        s.configure_source(mode, gain, tone, ant_step, lfsr_seed);
    s.configure_cfar(cfg.guard_lead, cfg.ref_lead, cfg.alpha, cfg.mode,
                     cfg.out_mode);
    s.configure_history(depth);

    s.clear_observations();
    s.set_run(true, false);
    if (!s.wait_frames(kWarmFrames, cycles_for(g, kWarmFrames))) {
      fail("hang", &g_counters.hang, tag + ": the history never filled");
      break;
    }
    s.mark_counter_epoch();
    s.clear_telemetry();
    s.set_run(true, true);
    if (!s.run_core(cycles_for(g, 6) * (bp == 0 ? 1 : 4))) {
      fail("hang", &g_counters.hang, tag + ": the measured run did not complete");
      break;
    }
    s.set_run(false, false);
    if (!s.settle(8192)) {
      fail("hang", &g_counters.hang, tag + ": the pipeline did not quiesce");
      break;
    }

    // ---- the same checks the directed regression uses --------------------
    pipetb::check_source(s, src, kCheckFrames);
    const auto bins = pipetb::check_front_end(s, coeff, kCheckFrames);
    pipetb::check_history(s, bins);
    pipetb::check_alignment(s, bins);
    pipetb::check_back_end(s, weights);
    const std::size_t frames = pipetb::check_detection(s, cfg, 0);
    pipetb::check_counters(s);

    std::printf("         -> %zu source beats, %zu history responses, %zu "
                "alignment beats, %llu events, %zu detector frames compared\n",
                s.adc_beats()[0].size(), s.hist_responses().size(),
                s.align_beats().size(),
                static_cast<unsigned long long>(s.event_count()), frames);
    beats += s.power_beats().size();

    top->final();
    if (g_counters.total() != 0) break;   // stop at the first failing point
  }

  const auto wall_end = std::chrono::steady_clock::now();
  std::printf("--- results ---\n");
  g_counters.print();

  return pipetb::finish(
      args, kTestName, errors, n_passes, beats,
      std::chrono::duration<double>(wall_end - wall_start).count(),
      "every randomized pass bit-exact against the C++ model at every stage",
      "a randomized pass diverged; replay with the printed seed");
}
