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

// Medium-config sizes, matching rtl/top/benchmark_sim_top.sv
constexpr unsigned kNAnt      = 4;
constexpr unsigned kSpc       = 2;
constexpr unsigned kFftSize   = 256;
constexpr unsigned kNBeams    = 4;

// Beats per frame at the PFB input: FFT_SIZE / SPC.
constexpr unsigned kBeatsPerFrame = kFftSize / kSpc;

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
  void set_input_gap(double p);   // Bernoulli gap probability per beat.
  void set_expect_detections(bool on) { expect_detections_ = on; }

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
  // Reads stat_cfar_det_count directly -- number of DETECT events fired
  // by the CFAR core, distinct from the number of output frame markers.
  std::uint64_t cfar_det_count() const;
  std::uint64_t pipeline_swap_count() const;
  std::uint64_t pipeline_swap_overrun_count() const;

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
  double input_gap_ = 0.0;
  bool expect_detections_ = false;

  // Detection output counters
  std::uint64_t beats_driven_ = 0;
  std::uint64_t beats_observed_ = 0;
  std::uint64_t frames_queued_ = 0;
  std::uint64_t frames_observed_ = 0;
  std::uint64_t detections_ = 0;

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
