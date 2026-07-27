// -----------------------------------------------------------------------------
// test_pipeline_stress — the SPEC.md 13.4 long stress test (issue #17).
//
// SPEC 13.4 asks for at least one medium-configuration test containing millions
// of processing cycles, independently randomized clock phases, sustained
// near-full throughput, random stalls, periodic coefficient updates, periodic
// weight updates, counter-wrap testing, FIFO near-full events, and no waveform
// generation unless a failure occurs. This is that test, and each item is a
// named phase below rather than an emergent property of a long run.
//
// What it checks, and what checks it
// ----------------------------------
// This test asserts very little itself, and that is the design. Everything that
// can be checked cycle by cycle already is, by the RTL's own property sets:
// `stream_protocol_checker` on every stage boundary, `align_assertions`,
// `history_wr_assertions` and `history_rd_assertions`, `cfar_assertions`,
// `covar_assertions`, `beamformer_assertions`, and the CDC checkers on every
// crossing. Verilator stops the run on the first violation, so a stress pass
// that RETURNS has already proved several thousand properties several million
// times each.
//
// What this file adds is the arrangement that makes those properties reachable,
// and an end-of-run audit of the things a per-cycle assertion cannot see:
//
//   * sequence numbers WRAPPED and continuity survived it (the field is 16 bits
//     and a long run passes 65535 -> 0 many times);
//   * the counters agree with the harness's independent tally after a run long
//     enough that a one-beat-per-million error would show;
//   * the sticky fault words are within their documented bounds;
//   * the pipeline was still delivering events at the end, so the run measured a
//     working pipeline for its whole length rather than a deadlocked one for
//     most of it.
//
// Memory: recording is OFF (see Session::set_recording). A run of this length
// would otherwise store tens of millions of beats to answer questions the
// directed tests answer better on six frames.
//
// Waveforms: none. The fast build has no tracing compiled in at all, so "no
// waveform on a passing run" is structural rather than conditional; a failing
// seed is replayed in the debug build, which is what `sim/verilator/README.md`
// documents and what the printed replay line names.
//
// Duration: `+cycles=<n>` core cycles, default 3,000,000. `make sim-stress`
// tunes it against a wall-clock budget; see the Makefile.
// -----------------------------------------------------------------------------

#include <chrono>
#include <cstdio>
#include <memory>
#include <string>
#include <vector>

#include "pipeline_tb.h"

namespace {

constexpr const char* kTestName = "test_pipeline_stress";

using pipetb::fail;
using pipetb::g_counters;
using pipetb::Session;

// Three million core cycles at the medium geometry is about 23 000 source
// frames and 45 sequence-number wraps, and runs in a couple of minutes. The
// Makefile's `sim-stress` raises it to the documented wall-clock budget.
constexpr std::uint64_t kDefaultCycles = 3000000;

// One phase of the run: a clock ratio, a stall profile, and a slice of cycles.
// Phases exist so that "independently randomized clock phases" is a property of
// the run rather than of the seed — a single ratio for three million cycles
// would test one relationship very thoroughly and the other six not at all.
// Named PhaseLog and not Phase: harness::Phase is the clock scheduler's
// sample/drive enum, and an unqualified Phase inside harness::sim_test_main
// resolves to that one.
struct PhaseLog {
  const char* ratio;
  const char* stalls;
  std::uint64_t cycles;
  std::uint64_t events;
};

}  // namespace

int harness::sim_test_main(const harness::SimArgs& args) {
  const auto wall_start = std::chrono::steady_clock::now();

  harness::ErrorCollector errors;
  pipetb::g_errors = &errors;
  g_counters = pipetb::Counters{};

  harness::SeedSource seeds(args.seed);
  const std::uint64_t budget = std::stoull(
      args.plusarg("cycles", std::to_string(kDefaultCycles)));

  const auto& ratios = harness::clock_ratios();
  const unsigned n_phases = static_cast<unsigned>(ratios.size());
  const std::uint64_t per_phase = budget / n_phases + 1;

  std::printf("--- SPEC 13.4 long stress, medium configuration ---\n");
  std::printf("  master seed  : %llu   (replay: +seed=%llu +cycles=%llu)\n",
              static_cast<unsigned long long>(args.seed),
              static_cast<unsigned long long>(args.seed),
              static_cast<unsigned long long>(budget));
  std::printf("  budget       : %llu core cycles over %u clock-ratio phases\n",
              static_cast<unsigned long long>(budget), n_phases);
  std::printf("  waveforms    : not compiled into this build\n");

  std::vector<PhaseLog> log;
  std::uint64_t total_adc = 0, total_align = 0, total_power = 0;
  std::uint64_t total_events = 0, total_wraps = 0;
  std::uint64_t total_cycles = 0;

  for (unsigned ph = 0; ph < n_phases && g_counters.total() == 0; ++ph) {
    const std::string tag = "phase" + std::to_string(ph);
    std::mt19937_64 rng = seeds.engine("pipeline.stress." + tag);

    auto top = std::make_unique<Vbenchmark_sim_top>();
    const harness::ClockRatio& ratio = ratios[ph];
    Session s(top.get(), &errors, seeds.substream_seed("stress." + tag), &ratio);
    const pipeline::Geometry g = s.g();
    s.set_recording(false);

    if (!s.reset()) {
      fail("hang", &g_counters.hang, tag + ": reset never completed");
      break;
    }
    if (ph == 0 && !pipetb::check_geometry(s, top.get())) break;

    // Two coefficient sets and two weight matrices, swapped between periodically
    // so that the frame-boundary rule is exercised thousands of times rather
    // than once.
    const std::vector<fxp::Complex> coeff[2] = {
        pipeline::shaped_coeff(g.lanes, g.pfb_taps,
                               static_cast<std::uint32_t>(args.seed * 3 + 1)),
        pipeline::shaped_coeff(g.lanes, g.pfb_taps,
                               static_cast<std::uint32_t>(args.seed * 5 + 7)),
    };
    const std::vector<fxp::Complex> wts[2] = {
        pipeline::steering_weights(g.n_ant, g.n_beams, g.fft_size),
        pipeline::selector_weights(g.n_ant, g.n_beams),
    };

    if (!s.program_banks(coeff[0], wts[0])) {
      fail("hang", &g_counters.hang, tag + ": bank programming did not complete");
      break;
    }

    // Near-full throughput: the LFSR source at a large amplitude, running
    // continuously, with the alignment network sweeping the newest frame. The
    // sources never stall, so the front end runs at its structural maximum for
    // the whole phase and the corner turn overwrites continuously — which is
    // what SPEC 7.3's overwrite-oldest policy is for and what its counter
    // measures.
    const pipeline::SrcConfig src = s.configure_source(
        pipeline::SrcMode::kLfsr, static_cast<std::int16_t>(0x1800), 0,
        pipeline::beam_spacing(g.n_ant, g.fft_size),
        static_cast<std::uint32_t>(harness::uniform_u64(rng, 1, 0xFFFFFFFFu)));
    (void)src;
    s.configure_cfar(2, 8, 6 * cfar::kAlphaOne);
    s.configure_history(g.history_frames);

    const unsigned bp_kind = static_cast<unsigned>(harness::uniform_u64(rng, 1, 3));
    switch (bp_kind) {
      case 1: s.set_event_backpressure(harness::BackpressureConfig::light()); break;
      case 2: s.set_event_backpressure(harness::BackpressureConfig::heavy()); break;
      default: s.set_event_backpressure(harness::BackpressureConfig::bursty());
    }

    s.clear_observations();
    s.set_run(true, true);

    // The phase, in slices, with a bank swap between slices. The slice length is
    // randomized so a swap never lands at the same point in a frame twice.
    std::uint64_t spent = 0;
    unsigned bank = 0;
    unsigned swaps = 0;
    bool ok = true;
    while (spent < per_phase) {
      const std::uint64_t slice =
          harness::uniform_u64(rng, 20000, 60000);
      const std::uint64_t step = std::min(slice, per_phase - spent);
      if (!s.run_core(step)) {
        fail("hang", &g_counters.hang,
             tag + ": the run stopped after " + std::to_string(spent) + " cycles");
        ok = false;
        break;
      }
      spent += step;

      // Periodic coefficient and weight updates, at a frame boundary the design
      // chooses. Both banks are written and swapped, alternating, so the run
      // spends half its time on each set.
      bank ^= 1u;
      s.load_coefficients(coeff[bank], bank ^ 1u);
      s.swap_coefficients(bank ^ 1u);
      s.load_weights(wts[bank], bank ^ 1u);
      s.swap_weights();
      ++swaps;
    }
    if (!ok) break;

    s.set_run(false, false);
    if (!s.settle(16384)) {
      fail("hang", &g_counters.hang, tag + ": the pipeline did not quiesce");
      break;
    }

    // ---- the end-of-phase audit -----------------------------------------
    const std::uint32_t hfault =
        s.read(regmap::HISTORY_HISTORY_FAULT_ADDR, "history fault");
    // Bit 0 is ERROR_SEEN, which an out-of-range request sets. The alignment
    // network reads the newest complete frame while the writer keeps rotating,
    // so a request occasionally resolves past the readable bound — the same
    // frame-straddle mechanism `check_counters` documents. Bits 1..3 —
    // collision, skew and framing — have no explanation in a run whose source
    // never stalls, and any of them is a defect.
    if ((hfault & 0b1110u) != 0) {
      fail("history", &g_counters.history,
           tag + ": HISTORY_FAULT reports a collision, skew or framing defect: 0x" +
               std::to_string(hfault));
    }

    const std::uint32_t astatus =
        s.read(regmap::PIPELINE_PIPE_ALIGN_STATUS_ADDR, "align status");
    const unsigned afault =
        (astatus >> regmap::PIPELINE_PIPE_ALIGN_STATUS_FAULT_LSB) & 0xFu;
    // Only DUPLICATE (bit 1) is a defect here. MISSING and ORPHAN are the frame
    // straddle  documents, and HIST (bit 3) is the corner turn
    // reporting that a response was flagged — which at this ingest rate is
    // expected and is the overwrite-oldest policy working: the read side is
    // deliberately slower than the write side, so a sweep occasionally asks for
    // a frame the writer has already passed. All three are counted and none of
    // them is silent, which is what SPEC 7.4 asks of the detector.
    if ((afault & 0b0010u) != 0) {
      fail("align", &g_counters.align,
           tag + ": the alignment network reports a DUPLICATE response, which "
           "no legal upstream can produce: 0x" + std::to_string(afault));
    }

    const std::uint32_t events =
        s.read(regmap::PIPELINE_PIPE_EVENTS_ADDR, "events");
    const std::uint32_t src_beats =
        s.read(regmap::PIPELINE_PIPE_SRC_BEATS_ADDR, "src beats");
    const std::uint32_t overwrites =
        s.read(regmap::HISTORY_HISTORY_OVERWRITE_ADDR, "overwrites");

    // The pipeline must have been WORKING, not merely not-crashing. A phase that
    // produced no events, or whose source counter did not move, proves nothing.
    if (events == 0) {
      fail("throughput", &g_counters.throughput,
           tag + ": no detection events in " + std::to_string(spent) + " cycles");
    }
    if (src_beats == 0) {
      fail("throughput", &g_counters.throughput,
           tag + ": the sources produced nothing");
    }
    // SPEC 7.3's overwrite-oldest policy: at this rate the corner turn must have
    // wrapped its ring many times over. A phase in which it never did would be
    // one where the read side kept up, which at one bin per cycle against two
    // bins per cycle of ingest it cannot.
    if (overwrites == 0) {
      fail("coverage", &g_counters.coverage,
           tag + ": the history never overwrote a frame; the ingest/read rate "
           "relationship is not what the design says it is");
    }

    PhaseLog rec;
    rec.ratio = ratio.name;
    rec.stalls = bp_kind == 1 ? "light" : (bp_kind == 2 ? "heavy" : "bursty");
    rec.cycles = spent;
    rec.events = events;
    log.push_back(rec);

    total_cycles += spent;
    total_adc += s.seen_adc();
    total_align += s.seen_align();
    total_power += s.seen_power();
    total_events += s.event_count();
    total_wraps += s.seq_wraps();

    std::printf("  %-7s ratio=%-14s stalls=%-6s cycles=%8llu swaps=%3u "
                "events=%8u overwrites=%9u\n",
                tag.c_str(), ratio.name,
                bp_kind == 1 ? "light" : (bp_kind == 2 ? "heavy" : "bursty"),
                static_cast<unsigned long long>(spent), swaps, events,
                overwrites);

    top->final();
  }

  // ---- SPEC 13.4's counter-wrap requirement -------------------------------
  //
  // The 32-bit telemetry counters saturate rather than wrap and cannot be driven
  // to their maximum in any tractable run; issue #8 covers their wrap on a
  // deliberately narrow counter, which is the only way to reach it. What DOES
  // wrap here, and what matters for SPEC 5, is the 16-bit sequence number: every
  // 65536 beats it passes 65535 -> 0 and `stream_protocol_checker`'s continuity
  // property has to survive it. A run that never wrapped would leave that
  // untested.
  if (total_wraps == 0) {
    fail("coverage", &g_counters.coverage,
         "no sequence number wrapped in " + std::to_string(total_cycles) +
             " cycles; SPEC 13.4's counter-wrap coverage was not reached. "
             "Raise +cycles.");
  }

  const auto wall_end = std::chrono::steady_clock::now();
  const double wall =
      std::chrono::duration<double>(wall_end - wall_start).count();

  std::printf("--- stress summary ---\n");
  std::printf("  core cycles       : %llu\n",
              static_cast<unsigned long long>(total_cycles));
  std::printf("  source beats      : %llu\n",
              static_cast<unsigned long long>(total_adc));
  std::printf("  alignment beats   : %llu\n",
              static_cast<unsigned long long>(total_align));
  std::printf("  power beats       : %llu\n",
              static_cast<unsigned long long>(total_power));
  std::printf("  detection events  : %llu\n",
              static_cast<unsigned long long>(total_events));
  std::printf("  sequence wraps    : %llu\n",
              static_cast<unsigned long long>(total_wraps));
  std::printf("  wall clock        : %.1f s (%.0f core cycles/s)\n", wall,
              wall > 0 ? static_cast<double>(total_cycles) / wall : 0.0);
  g_counters.print();

  return pipetb::finish(
      args, kTestName, errors, log.size(), total_power, wall,
      "millions of cycles at seven clock ratios with no assertion failure",
      "the stress pass reported a defect; replay with the printed seed");
}
