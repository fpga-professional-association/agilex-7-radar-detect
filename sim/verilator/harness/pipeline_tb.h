// -----------------------------------------------------------------------------
// pipeline_tb.h -- shared C++ scaffolding for the issue #17 pipeline tests
// (continuous, random, runtime_update, metamorphic, stress).
//
// One Session owns:
//   * a Vpipeline_top instance provided by the caller
//   * three clocks (core_clk, history_clk, cfg_clk) driven by the SPEC 12.3
//     multi-clock scheduler
//   * reset sequencing for all three domains
//   * per-antenna input drivers with random-gap / random-backpressure
//     policies
//   * a detection-output monitor
//   * counters that feed the RunSummary
//
// The block-level tests (test_pfb_bank etc.) each own their own DUT specific
// wiring; this header exists because the pipeline uses seven blocks together
// and duplicating wire-up per test is a good way to write four subtly
// different pipelines. The C++ side is the SPEC 12.5 scoreboard's oracle for
// end-to-end sequence identity; correctness against a bit-accurate model is
// covered per block in #10-#16 and this header does not repeat those checks.
// -----------------------------------------------------------------------------
#ifndef HARNESS_PIPELINE_TB_H_
#define HARNESS_PIPELINE_TB_H_

#include <cstdint>
#include <cstdio>
#include <deque>
#include <memory>
#include <random>
#include <string>
#include <vector>

#include "Vpipeline_top.h"
#include "verilated.h"

#include "config_sim.h"

#include "harness/clock_scheduler.h"
#include "harness/error_collector.h"
#include "harness/random.h"
#include "harness/reset_sequencer.h"
#include "harness/sim_args.h"

namespace pipeline_tb {

// Config-driven sizes, pulled from sim_config (generated from
// config/<name>.json by scripts/build_verilator.py, mirrored by
// benchmark_pipeline_top's config_pkg import). Same generated numbers are
// used by the RTL, so tiny/medium/full_agmf039 all elaborate this same
// harness against the same top.
constexpr unsigned kNAnt      = sim_config::N_ANTENNAS;
constexpr unsigned kSpc       = sim_config::SAMPLES_PER_CYCLE;
constexpr unsigned kFftSize   = sim_config::FFT_SIZE;
constexpr unsigned kNBeams    = sim_config::N_BEAMS;

// Beats per frame at the PFB input: FFT_SIZE / SPC.
constexpr unsigned kBeatsPerFrame = kFftSize / kSpc;

// Serialized-fanout constants used by Phase-5 tests. POWER_FANOUT is the
// number of (beam, bin_par) cells per beamformer beat; BIN_PAR is held at 2
// in the RTL. These match the RTL's own localparam values.
constexpr unsigned kBinPar     = 2;
constexpr unsigned kBeamPar    = kNBeams;
constexpr unsigned kPowerFanout = kBinPar * kBeamPar;

enum class BpProfile {
  kNone,
  kLight,
  kHeavy,
  kBursty,
};

struct StimFrame {
  // Per (antenna, beat, phase) complex Q1.15 sample. 4 antennas * 128 beats
  // * 2 samples/beat = 1024 samples per frame.
  std::vector<std::int16_t> re;
  std::vector<std::int16_t> im;

  StimFrame() : re(kNAnt * kBeatsPerFrame * kSpc, 0),
                im(kNAnt * kBeatsPerFrame * kSpc, 0) {}

  std::int16_t& at_re(unsigned ant, unsigned beat, unsigned phase) {
    return re[(ant * kBeatsPerFrame + beat) * kSpc + phase];
  }
  std::int16_t& at_im(unsigned ant, unsigned beat, unsigned phase) {
    return im[(ant * kBeatsPerFrame + beat) * kSpc + phase];
  }
};

// A pure-sinusoid stimulus, one tone per antenna, with a random amplitude and
// bin. Amplitude is limited to 1/4 full-scale so the PFB and FFT do not
// saturate at the tone bin. Deterministic given the RNG.
StimFrame random_tone(std::mt19937_64& rng);

// A zero-input frame -- for metamorphic zero-in/zero-out and for stress
// warm-up bookends.
StimFrame zero_frame();

// A frame containing a complex impulse on antenna 0 (i.e. sample 0 of beat 0
// is 8000+0j and every other sample is zero).
StimFrame impulse_frame();

// A frame whose per-antenna samples are permutations of a base pattern -- for
// the metamorphic antenna-permutation test.
StimFrame permute_frame(const StimFrame& base, const std::vector<unsigned>& perm);

class Session {
 public:
  Session(Vpipeline_top* top, std::uint64_t seed);
  ~Session() = default;

  bool reset();

  // ---- stimulus queueing ---------------------------------------------------
  // Queue one frame for driving on all 4 antennas.
  void queue_frame(const StimFrame& frame);

  // ---- knobs --------------------------------------------------------------
  void set_backpressure(BpProfile p);
  // Bernoulli gap probability per beat. Applies independently PER ANTENNA:
  // one draw per antenna per cycle so a "gap" is a per-antenna stall, not a
  // global stall. Useful for backpressure / stall stimulus, less useful for
  // "delay invariance" -- see set_global_input_gap.
  void set_input_gap(double p);
  // Bernoulli gap probability SHARED across antennas: on a gap cycle NO
  // antenna presents a beat. This preserves per-antenna phasing (all
  // antennas see the same delay pattern) and is the right stimulus for
  // the SPEC 13.2 "delay invariance" metamorphic property.
  void set_global_input_gap(double p);
  void set_expect_detections(bool on) { expect_detections_ = on; }
  // Force m_ready low so the CFAR output stream halts. Used by the DMA test
  // during readback to keep the pipeline QUIESCENT while it reads memory back
  // through the arbiter -- otherwise residual pipeline state (align_net
  // timeout, fanout FIFO drain, covar/CFAR SUMMARY per frame boundary) would
  // continue to emit CFAR events that the tap would keep writing, and the
  // reader's arbitration would starve behind that continuous writer traffic.
  // See DECISIONS.md 2026-07-28 "Phase 5 revision: DMA test freeze".
  void hold_output_stalled(bool on) { output_stalled_ = on; }

  // ---- pipeline configuration --------------------------------------------
  void enable_pipeline();
  void configure_cfar(unsigned guard_lead, unsigned guard_lag,
                      unsigned ref_lead, unsigned ref_lag, unsigned alpha);
  void configure_align(unsigned frame_off);
  void configure_history(unsigned depth);

  // ---- runtime updates ---------------------------------------------------
  // Program the PFB coefficient bank at address `addr` with the packed
  // {im, re} value `val` into the inactive bank.
  void program_pfb_coeff(std::uint8_t bank, std::uint16_t addr,
                         std::uint32_t val);
  void program_bf_weight(std::uint8_t bank, std::uint8_t addr,
                         std::uint32_t val);
  // Request the pipeline controller to swap both banks at the next frame
  // boundary. A single 1-cycle pulse on cfg_pipe_swap_req.
  void request_pipeline_swap();

  // Program bank 1 of both the PFB coefficients and the beamformer weights
  // with a fixed pass-through pattern that yields non-zero CFAR power,
  // request one pipeline swap, and drive one warm-up frame so the swap
  // fires and the bank-1 coefficients become active. Callers that want
  // meaningful (non-zero) CFAR detections in subsequent frames use this.
  // Returns true if the swap fired (swap_count >= 1 afterwards).
  bool program_and_swap_to_active_banks();

  // ---- running ------------------------------------------------------------
  // Advance until every queued beat has been driven, every detection frame
  // that would be produced has left the pipeline, or `budget` core cycles
  // elapse.
  bool run_until_idle(std::uint64_t budget);
  bool advance_cycles(std::uint64_t cycles);

  // ---- accessors ---------------------------------------------------------
  std::mt19937_64& rng() { return rng_; }
  harness::ErrorCollector& errors() { return errors_; }
  std::uint64_t core_cycles() const { return sched_.cycles(core_); }
  std::uint64_t history_cycles() const { return sched_.cycles(hist_); }
  std::uint64_t beats_driven() const { return beats_driven_; }
  std::uint64_t beats_observed() const { return beats_observed_; }
  std::uint64_t frames_driven() const { return frames_queued_; }
  std::uint64_t frames_observed() const { return frames_observed_; }
  std::uint64_t detections() const { return detections_; }
  // Per-input-frame output frame count on the CFAR boundary. Phase 6 lands
  // per-beam CFAR (issue #21): every input frame produces N_BEAMS output
  // frame markers (one m_eof per beam per input frame, interleaved by the
  // round-robin arbiter). Tests that ran under the Phase-5 single-CFAR
  // contract expected frames_observed == frames_driven; the multi-beam
  // contract is frames_observed == frames_per_input_frame() * frames_driven.
  // The constant is kNBeams (16 at full_agmf039, 4 at medium, 2 at tiny),
  // but callers should use this accessor so any future refactor to a
  // different fan-out only edits the harness.
  static constexpr unsigned frames_per_input_frame() { return kNBeams; }
  // Reads stat_cfar_det_count directly -- number of DETECT events fired
  // by the CFAR core, distinct from the number of output frame markers.
  std::uint64_t cfar_det_count() const;
  std::uint64_t pipeline_swap_count() const;
  std::uint64_t pipeline_swap_overrun_count() const;

  // Number of end-of-frame m_seq monotonicity violations observed on the
  // detection output stream. Non-decreasing across the run is the SPEC 5
  // invariant end-to-end through the pipeline; a nonzero value here means
  // the sequence ID propagation between blocks lost or reordered frames.
  std::uint64_t m_seq_violations() const { return m_seq_violations_; }
  std::uint64_t m_seq_last() const       { return m_seq_last_; }
  bool          m_seq_seen() const       { return m_seq_seen_; }

  // Cause reset again mid-run.
  void assert_reset();

  // The Verilator DUT (for direct status probing where useful).
  Vpipeline_top* top() { return top_; }

 private:
  Vpipeline_top* top_;
  harness::ErrorCollector errors_;
  harness::SeedSource seeds_;
  std::mt19937_64 rng_;
  std::mt19937_64 stall_rng_;
  std::mt19937_64 gap_rng_;

  harness::ClockScheduler sched_;
  int core_ = -1;
  int hist_ = -1;
  int cfg_  = -1;
  std::unique_ptr<harness::ResetSequencer> reset_;
  harness::SimTime time_limit_ = 0;

  // Per-antenna input queues (SPC samples per beat).
  struct InBeat {
    std::uint32_t phase[kSpc];   // packed {im, re} per phase
    bool sof = false;
    bool eof = false;
    std::uint16_t seq = 0;
  };
  std::deque<InBeat> in_q_[kNAnt];

  // Backpressure and gap knobs
  BpProfile bp_profile_ = BpProfile::kNone;
  double input_gap_ = 0.0;         // per-antenna independent
  double global_gap_ = 0.0;        // shared across antennas
  bool expect_detections_ = false;
  bool output_stalled_ = false;    // when true, force m_ready = 0

  // Detection output counters
  std::uint64_t beats_driven_ = 0;
  std::uint64_t beats_observed_ = 0;
  std::uint64_t frames_queued_ = 0;
  std::uint64_t frames_observed_ = 0;
  std::uint64_t detections_ = 0;

  // End-of-frame m_seq monotonicity monitor. m_seq_last_ records the last
  // seq value observed at an m_eof handshake; m_seq_violations_ counts any
  // (m_eof)-to-(next m_eof) transition that decreased the seq. Because the
  // SEQ_W = 16 field wraps, the check uses signed difference modulo 2^16.
  bool          m_seq_seen_       = false;
  std::uint16_t m_seq_last_       = 0;
  std::uint64_t m_seq_violations_ = 0;

  // Callback wiring
  void core_sample();
  void core_drive();
  void hist_sample();
  void hist_drive();
  void idle_inputs();
  void pulse_core(std::uint8_t* sig);
  bool m_ready_next();

  // Sequence counter across all queued frames (shared across antennas
  // because the pipeline anchors its frame boundaries on antenna 0).
  std::uint16_t next_seq_ = 0;

  // Backpressure generator for the detection output
  std::unique_ptr<harness::BackpressureGenerator> bp_;
};

// Reset all counters and clear per-run state, without recompiling the DUT.
void reset_run_state(Session& s);

}  // namespace pipeline_tb

// The sim_main entry point calls this.
namespace harness {
int sim_test_main(const SimArgs& args);
}

#endif  // HARNESS_PIPELINE_TB_H_
