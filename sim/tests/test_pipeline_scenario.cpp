// -----------------------------------------------------------------------------
// test_pipeline_scenario -- inject a generated scenario through the medium-
// config pipeline and check CFAR detections against ground truth
// (issue #44 part 2, SPEC.md §13.1 / §7.7).
//
// This is the sim-injection acceptance gate for the synthetic-target scenario
// generator (part 1, PR #45). The generator writes a multi-antenna Q1.15 IQ
// stream with N targets sitting in an AWGN floor (each at a chosen range
// FFT bin, Doppler frame-phase, angle_idx and SNR) plus a JSON ground-truth
// sidecar. This test:
//
//   1. loads scenario.iq + scenario.json (see harness/iq_loader.h);
//   2. programs the pipeline coefficient / weight banks so PFB is a
//      pass-through and the beamformer sums antennas uniformly (bank 1,
//      via Session::program_and_swap_to_active_banks);
//   3. queues every one of the scenario's HISTORY_FRAMES frames through
//      the pipeline and drains one core cycle at a time;
//   4. captures every CFAR DETECT event and records the (bin, frame_id)
//      of each one;
//   5. prints a ground-truth-vs-detected table like range_doppler.py's;
//   6. passes iff every ground-truth target sits at a detected CFAR bin
//      within the documented tolerance, the false-alarm count is under the
//      documented bound, and Session::errors().count() == 0.
//
// Tolerances and knobs are documented at the top of ``kCfar*`` /
// ``kBinTol`` / ``kFalseAlarmMax`` below and in DECISIONS.md 2026-07-27
// (Part-2 tolerances entry).
//
// The pipeline TAPS ONE SAMPLE per beamformer beat -- (beam 0, bin 0)
// (DECISIONS.md 2026-07-27 Decision 7). With BIN_PAR = 2 and lane = fft_bin
// mod BIN_PAR, lane 0 = EVEN FFT bins. So a target at fft_bin K sits at
// CFAR bin K/2 iff K is even; on odd bins it is invisible to the tap.
// The scenario 'three_targets_even' (added by part 2) places every target
// on an even FFT bin at angle_idx = 0 so uniform-weight beamforming
// coherently sums them to beam 0.
// -----------------------------------------------------------------------------

#include <algorithm>
#include <cmath>
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <memory>
#include <set>
#include <string>
#include <vector>

#include "Vpipeline_top.h"
#include "verilated.h"

#include "config_sim.h"

#include "harness/error_collector.h"
#include "harness/iq_loader.h"
#include "harness/run_summary.h"
#include "harness/sim_args.h"

#include "harness/pipeline_tb.h"

namespace harness {

namespace {

// -----------------------------------------------------------------------------
// CFAR configuration for scenario injection
// -----------------------------------------------------------------------------
// The pipeline runs at:
//   * PFB: 8-tap pass-through (bank 1 programmed by
//     Session::program_and_swap_to_active_banks); tap 0 = 0x7FFF Q1.15
//     (~1.0), other taps 0 => phase-preserving identity in the passband.
//   * FFT: SCALE_SCHED = 0xFFFF_FFFF (every stage divides by 2). A unit
//     tone of amplitude A hits its bin at magnitude A after the FFT.
//   * Beamformer: uniform weights bank 1 = 0x1000 Q1.15 (0.125) per lane.
//     A tone with angle_idx = 0 sums coherently across N_ANT = 4 antennas
//     to N_ANT * 0.125 * A = 0.5*A at beam 0.
//   * power_calc: |I|^2 + |Q|^2 into COVAR_POWER_W = 40 bit signed.
//
// So a target with generator amp = 0.03 * 10^(SNR/20) (capped at 0.3) and
// the noise floor sigma = 0.005 hit CFAR at:
//   target power at bin ~ (0.5 * amp * 32768)^2
//
// At SNR = 6 dB (weakest scenario target) amp = 0.06 -> target power ~
// (0.5*0.06*32768)^2 = 967_000. Noise-cell power (Rayleigh mean at that
// FFT scaling) sits far below the target's peak. Ratio > 5x, so alpha in
// the 4-16 range makes the strongest target detect on every seed while
// the weak target usually detects on average but may edge-fail on a seed.
//
// Choice: alpha = 0x0800 = 8.0 in UQ8.8. Cell-averaging (CFAR_MODE_CA),
// guard = 1 lead / 1 lag (minimal band to avoid target self-masking on
// the adjacent CFAR bin), ref = 8 lead / 8 lag (16 total; half of
// CFAR_MAX_REF=16 per side, matching the medium-config elaboration).
// With MAX_GUARD=2 the block is elaborated for guards up to 2; asking for
// 1 is legal and reports no clamping.
//
// See DECISIONS.md 2026-07-27 "Scenario-test tolerances" (part 2 of #44).
constexpr unsigned kCfarGuardLead = 1;
constexpr unsigned kCfarGuardLag  = 1;
constexpr unsigned kCfarRefLead   = 8;
constexpr unsigned kCfarRefLag    = 8;
constexpr unsigned kCfarAlpha     = 0x0800;   // 8.0 in UQ8.8

// -----------------------------------------------------------------------------
// Detection tolerances (documented; see DECISIONS.md 2026-07-27)
// -----------------------------------------------------------------------------
// Bin tolerance: ±1 CFAR bin around the ground-truth CFAR bin index.
// Two sources of ±1 shift add up here:
//   * quantisation of the pipeline's fixed-point path can nudge a bin's
//     magnitude by one comparison step and let the neighbour detect
//     instead;
//   * the CFAR window at the guard band's inner edge is off by one from
//     an idealized peak locator when the guard = 1 side happens to
//     capture the target's own leakage.
// Documented at ±1 rather than 0 for these reasons; range_doppler.py uses
// the same tolerance for the reference chain, so the criterion is
// consistent with what part 1 already asserts.
//
// False-alarm bound: any DETECT event that is NOT within ±kBinTol of any
// ground-truth CFAR bin (across frames) counts as a false alarm. The
// bound is 6 across all frames of the scenario -- see the alpha
// justification in DECISIONS.md.
constexpr int      kBinTol        = 1;
// Phase 6 (issue #21): per-beam CFAR emits detections on ALL N_BEAMS beams
// in parallel; a per-beam false-alarm rate that produced up to 6 false
// alarms under the single-CFAR tap now scales up to
// kFalseAlarmMaxPerBeam * N_BEAMS. The alpha and (guard, ref) settings are
// unchanged so the per-beam probability of a false alarm is identical to
// the Phase-5 setting.
constexpr unsigned kFalseAlarmMaxPerBeam = 6;

// -----------------------------------------------------------------------------
// CFAR event decoding
// -----------------------------------------------------------------------------
// The pipeline exposes m_event_data as a 64-bit truncation of the 176-bit
// CFAR event (see cfar_pkg.sv layout). The low-order fields fit in that
// slice: kind(2) at [0:1], bin(16) at [2:17], frame_id(16) at [18:33].
// Anything higher (ref_count/alpha/...) is in bits above 33; det_count
// straddles the 64-bit boundary. We only need kind and bin here.
constexpr unsigned kEventBitKind    = 0;
constexpr unsigned kEventBitBin     = 2;
constexpr unsigned kEventBitFrameId = 18;

constexpr std::uint64_t kEventMaskKind    = 0x3ULL;
constexpr std::uint64_t kEventMaskBin     = 0xFFFFULL;
constexpr std::uint64_t kEventMaskFrameId = 0xFFFFULL;

constexpr unsigned kKindDetect     = 0;
constexpr unsigned kKindBin        = 1;
constexpr unsigned kKindSuppressed = 2;
constexpr unsigned kKindSummary    = 3;

struct DetectEvent {
  unsigned frame_id;
  unsigned bin;
};

// -----------------------------------------------------------------------------
// Ground-truth check
// -----------------------------------------------------------------------------

struct CheckReport {
  unsigned detected_targets = 0;
  unsigned missed_targets   = 0;
  unsigned false_alarms     = 0;
  unsigned total_events     = 0;
  bool passed = false;
  std::string table;
};

CheckReport check_detections(const pipeline_tb::ScenarioMeta& meta,
                             const std::vector<DetectEvent>& events,
                             unsigned bin_par,
                             int bin_tol,
                             unsigned false_alarm_max) {
  CheckReport rep;
  rep.total_events = static_cast<unsigned>(events.size());

  // A scenario target is "detected" if any frame produced a DETECT within
  // bin_tol of its expected CFAR bin. False alarms are DETECT events
  // outside every target window (across all frames).
  //
  // We aggregate across frames because a range target's magnitude at bin
  // k_r is constant across frames (Doppler only modulates phase), while
  // the noise draw varies. So the target detects on some subset of
  // frames; a single detection sighting anywhere in the run at a bin near
  // k_r is the acceptance criterion (documented rule, DECISIONS.md
  // 2026-07-27 part-2 entry).
  std::vector<unsigned> detected_flags(meta.targets.size(), 0);
  std::vector<std::set<unsigned>> target_hits(meta.targets.size());

  auto is_target_bin = [&](unsigned bin, int& which) -> bool {
    for (std::size_t i = 0; i < meta.targets.size(); ++i) {
      int expected = pipeline_tb::cfar_bin_for_fft_bin(
          meta.targets[i].range_bin, bin_par);
      if (expected < 0) continue;   // target on untapped parity
      int dr = static_cast<int>(bin) - expected;
      if (std::abs(dr) <= bin_tol) {
        which = static_cast<int>(i);
        return true;
      }
    }
    return false;
  };

  for (const DetectEvent& e : events) {
    int which = -1;
    if (is_target_bin(e.bin, which) && which >= 0) {
      detected_flags[which] = 1;
      target_hits[which].insert(e.bin);
    } else {
      ++rep.false_alarms;
    }
  }

  std::string t;
  char line[192];
  std::snprintf(line, sizeof(line),
                "target       fft_bin  cfar_bin  hits/frames  detected?  hit-bins\n");
  t += line;
  t += "------------------------------------------------------------------------\n";
  for (std::size_t i = 0; i < meta.targets.size(); ++i) {
    const auto& tg = meta.targets[i];
    int exp_cfar = pipeline_tb::cfar_bin_for_fft_bin(tg.range_bin, bin_par);
    const bool tapped = (exp_cfar >= 0);
    unsigned in_window = 0;
    for (const DetectEvent& e : events) {
      if (tapped) {
        int dr = static_cast<int>(e.bin) - exp_cfar;
        if (std::abs(dr) <= bin_tol) ++in_window;
      }
    }
    std::string bins_seen;
    for (unsigned b : target_hits[i]) {
      char buf[16]; std::snprintf(buf, sizeof(buf), "%u ", b);
      bins_seen += buf;
    }
    std::string cfar_bin_str = tapped ? std::to_string(exp_cfar) : std::string("n/a");
    std::snprintf(line, sizeof(line),
                  "%-12s %5d    %5s     %3u/%3u        %s      %s\n",
                  tg.name.c_str(),
                  tg.range_bin,
                  cfar_bin_str.c_str(),
                  in_window,
                  static_cast<unsigned>(meta.history_frames),
                  detected_flags[i] ? "YES" : "NO ",
                  bins_seen.empty() ? "(none)" : bins_seen.c_str());
    t += line;
    if (detected_flags[i]) ++rep.detected_targets;
    else ++rep.missed_targets;
  }
  std::snprintf(line, sizeof(line),
                "total DETECT events: %u, false alarms: %u (bound %u)\n",
                rep.total_events, rep.false_alarms, false_alarm_max);
  t += line;
  rep.table = t;

  rep.passed = (rep.missed_targets == 0) && (rep.false_alarms <= false_alarm_max);
  return rep;
}

// -----------------------------------------------------------------------------
// Path resolution
// -----------------------------------------------------------------------------
// If +iq= and +json= are both given, use them directly. Otherwise fall back
// to a +scenario=<name> under results/scenarios/<name>_seed<SEED>/. Default
// scenario is `three_targets_even` -- the scenario designed around the
// pipeline's tap parity.
struct IqPaths {
  std::string iq_path;
  std::string json_path;
};

IqPaths resolve_paths(const SimArgs& args) {
  IqPaths p;
  const std::string iq = args.plusarg("iq");
  const std::string json = args.plusarg("json");
  if (!iq.empty() && !json.empty()) {
    p.iq_path = iq;
    p.json_path = json;
    return p;
  }
  const std::string scen = args.plusarg("scenario", "three_targets_even");
  std::string base = args.plusarg("scenario_dir");
  if (base.empty()) {
    base = "results/scenarios/" + scen + "_seed" + std::to_string(args.seed);
  }
  p.iq_path   = base + "/scenario.iq";
  p.json_path = base + "/scenario.json";
  return p;
}

// Sample the CFAR output. Called after every advance_cycles(1); returns
// true if a DETECT beat handshake was seen this cycle (and pushes the
// decoded event onto ``events``).
void sample_cfar_output(Vpipeline_top* top, std::vector<DetectEvent>& events) {
  if (top->m_valid && top->m_ready) {
    const std::uint64_t ev = top->m_event_data;
    const unsigned kind = static_cast<unsigned>((ev >> kEventBitKind) & kEventMaskKind);
    const unsigned bin  = static_cast<unsigned>((ev >> kEventBitBin ) & kEventMaskBin);
    const unsigned frid = static_cast<unsigned>((ev >> kEventBitFrameId) & kEventMaskFrameId);
    (void)kKindBin; (void)kKindSuppressed; (void)kKindSummary;
    if (kind == kKindDetect) {
      DetectEvent d;
      d.frame_id = frid;
      d.bin      = bin;
      events.push_back(d);
    }
  }
}

}  // namespace

int sim_test_main(const SimArgs& args) {
  std::printf("[test_pipeline_scenario] starting seed=%llu config=%s\n",
              static_cast<unsigned long long>(args.seed),
              args.config_name.c_str());

  const IqPaths paths = resolve_paths(args);
  std::printf("[test_pipeline_scenario] iq   : %s\n", paths.iq_path.c_str());
  std::printf("[test_pipeline_scenario] json : %s\n", paths.json_path.c_str());

  pipeline_tb::ScenarioMeta meta;
  std::vector<pipeline_tb::StimFrame> frames;
  if (!pipeline_tb::load_iq_file(paths.iq_path, meta, frames)) {
    std::fprintf(stderr, "[test_pipeline_scenario] IQ load failed\n");
    return 1;
  }
  if (!pipeline_tb::load_scenario_json(paths.json_path, meta)) {
    std::fprintf(stderr, "[test_pipeline_scenario] JSON load failed\n");
    return 1;
  }
  std::printf("[test_pipeline_scenario] loaded %zu frames x %u ant x %u samples "
              "(%zu targets)\n",
              frames.size(), meta.n_antennas, meta.fft_size,
              meta.targets.size());
  for (std::size_t i = 0; i < meta.targets.size(); ++i) {
    const auto& t = meta.targets[i];
    int cfar_bin = pipeline_tb::cfar_bin_for_fft_bin(t.range_bin, /*BIN_PAR=*/2);
    std::string cfar_str = (cfar_bin >= 0) ? std::to_string(cfar_bin)
                                           : std::string("untapped");
    std::printf("[test_pipeline_scenario]   target %zu %-14s fft_bin=%d "
                "cfar_bin=%s doppler_bin=%d angle_idx=%d snr=%.1fdB\n",
                i, t.name.c_str(), t.range_bin, cfar_str.c_str(),
                t.doppler_bin, t.angle_idx, t.snr_db);
  }

  Verilated::commandArgs(0, static_cast<char**>(nullptr));
  std::unique_ptr<Vpipeline_top> top(new Vpipeline_top);

  pipeline_tb::Session sess(top.get(), args.seed);
  if (!sess.reset()) {
    std::fprintf(stderr, "[test_pipeline_scenario] reset failed\n");
    return 1;
  }

  // Configure CFAR and swap to programmed banks so PFB and beamformer are
  // producing non-zero power. Documented alpha/guard/ref choice above.
  sess.configure_cfar(kCfarGuardLead, kCfarGuardLag,
                      kCfarRefLead, kCfarRefLag, kCfarAlpha);
  if (!sess.program_and_swap_to_active_banks()) {
    std::fprintf(stderr, "[test_pipeline_scenario] bank program+swap failed\n");
    return 1;
  }

  // Reconfigure CFAR after program_and_swap_to_active_banks (it uses
  // the Session's own configure_cfar defaults during the warm-up frame).
  sess.configure_cfar(kCfarGuardLead, kCfarGuardLag,
                      kCfarRefLead, kCfarRefLag, kCfarAlpha);

  // Queue every scenario frame; run the pipeline single-cycle-stepped so
  // the CFAR output sniffer sees every DETECT beat. The pipeline runs at
  // ~1 beat/cycle so budget is HISTORY_FRAMES * FFT_SIZE per antenna
  // multiplied by ~2x fudge for handshakes + drain.
  sess.set_expect_detections(true);
  sess.set_backpressure(pipeline_tb::BpProfile::kNone);
  sess.set_input_gap(0.0);
  for (const auto& f : frames) sess.queue_frame(f);

  std::vector<DetectEvent> events;
  const std::uint64_t expected_beats_in =
      static_cast<std::uint64_t>(frames.size()) *
      pipeline_tb::kBeatsPerFrame * pipeline_tb::kNAnt;
  // Phase 6 (issue #21): per-beam CFAR + RR arbiter emits kNBeams m_eof
  // markers per input frame.
  const std::uint64_t expected_output_frames =
      static_cast<std::uint64_t>(frames.size()) *
      pipeline_tb::Session::frames_per_input_frame();
  const std::uint64_t budget =
      static_cast<std::uint64_t>(frames.size()) * 20000ULL + 200000ULL;
  std::uint64_t elapsed = 0;
  bool drained = false;
  while (elapsed < budget) {
    if (!sess.advance_cycles(1)) break;
    ++elapsed;
    sample_cfar_output(top.get(), events);
    const bool inputs_done = sess.beats_driven() == expected_beats_in;
    const bool outputs_done = sess.frames_observed() >= expected_output_frames;
    if (inputs_done && outputs_done) { drained = true; break; }
  }
  // Drain a little more to catch trailing detection beats.
  for (int i = 0; i < 200; ++i) {
    if (!sess.advance_cycles(1)) break;
    ++elapsed;
    sample_cfar_output(top.get(), events);
  }

  if (!drained) {
    std::fprintf(stderr, "[test_pipeline_scenario] drain incomplete: "
                 "beats_driven=%llu expected=%llu frames_observed=%llu / %llu "
                 "elapsed=%llu\n",
                 static_cast<unsigned long long>(sess.beats_driven()),
                 static_cast<unsigned long long>(expected_beats_in),
                 static_cast<unsigned long long>(sess.frames_observed()),
                 static_cast<unsigned long long>(sess.frames_driven()),
                 static_cast<unsigned long long>(elapsed));
  }

  const unsigned kFalseAlarmMax =
      kFalseAlarmMaxPerBeam *
      pipeline_tb::Session::frames_per_input_frame();
  CheckReport rep = check_detections(meta, events, /*bin_par=*/2,
                                     kBinTol, kFalseAlarmMax);

  std::printf("\n[test_pipeline_scenario] ground-truth vs detected\n%s\n",
              rep.table.c_str());

  bool pass = rep.passed && drained && (sess.errors().count() == 0);
  if (!rep.passed) {
    std::fprintf(stderr,
                 "[test_pipeline_scenario] tolerance check failed: "
                 "detected=%u missed=%u false_alarms=%u (bound %u)\n",
                 rep.detected_targets, rep.missed_targets, rep.false_alarms,
                 kFalseAlarmMax);
  }
  if (sess.errors().count() != 0) {
    std::fprintf(stderr, "[test_pipeline_scenario] Session errors=%zu\n",
                 sess.errors().count());
  }

  RunSummary summary;
  summary.test_name = "test_pipeline_scenario";
  summary.config_name = args.config_name;
  summary.build_mode = args.build_mode;
  summary.seed = args.seed;
  summary.core_cycles = sess.core_cycles();
  summary.frames_driven = frames.size();
  summary.frames_observed = sess.frames_observed();
  summary.beats_driven = sess.beats_driven();
  summary.beats_observed = sess.beats_observed();
  summary.passed = pass;
  summary.stop_reason = pass ? "pass" : "fail";
  summary.absorb(sess.errors());
  const std::string path = summary.write(args.results_dir);
  if (!path.empty()) {
    std::printf("[test_pipeline_scenario] summary: %s\n", path.c_str());
  }

  std::printf("RESULT: %s (seed=%llu, targets=%zu detected=%u missed=%u "
              "false_alarms=%u events=%u)\n",
              pass ? "PASS" : "FAIL",
              static_cast<unsigned long long>(args.seed),
              meta.targets.size(),
              rep.detected_targets, rep.missed_targets,
              rep.false_alarms, rep.total_events);

  return pass ? 0 : 1;
}

}  // namespace harness
