// -----------------------------------------------------------------------------
// pipeline_tb.cpp -- shared C++ scaffolding for the issue #17 pipeline tests.
// -----------------------------------------------------------------------------

#include "pipeline_tb.h"

#include <cmath>
#include <cstdint>
#include <cstdio>
#include <cstring>
#include <string>

using harness::BackpressureConfig;
using harness::BackpressureGenerator;
using harness::ClockScheduler;
using harness::ErrorCollector;
using harness::ResetSequencer;
using harness::SeedSource;
using harness::SimTime;
using harness::StopReason;

namespace pipeline_tb {

// ---------------------------------------------------------------------------
// Stimulus generators
// ---------------------------------------------------------------------------

StimFrame zero_frame() {
  return StimFrame{};
}

StimFrame impulse_frame() {
  StimFrame f;
  f.at_re(0, 0, 0) = 8000;
  f.at_im(0, 0, 0) = 0;
  return f;
}

StimFrame random_tone(std::mt19937_64& rng) {
  StimFrame f;
  // One tone per antenna at a random even bin (even so it maps into the
  // (beam 0, bin 0)-per-beat CFAR tap; odd bins live on the untapped lane
  // in the alignment output). Bins spread across the middle of the FFT
  // range so guard/reference cells fit without truncation at either edge.
  for (unsigned a = 0; a < kNAnt; ++a) {
    unsigned bin = static_cast<unsigned>(
        harness::uniform_u64(rng, 8, kFftSize / 2 - 8));
    bin &= ~1u;   // even bins only
    const double omega = 2.0 * 3.14159265358979323846 * bin /
                         static_cast<double>(kFftSize);
    const double amp   = 6000.0;
    const unsigned samples_per_frame = kBeatsPerFrame * kSpc;
    for (unsigned n = 0; n < samples_per_frame; ++n) {
      const double th = omega * n;
      const std::int16_t re = static_cast<std::int16_t>(amp * std::cos(th));
      const std::int16_t im = static_cast<std::int16_t>(amp * std::sin(th));
      const unsigned beat = n / kSpc;
      const unsigned phase = n % kSpc;
      f.at_re(a, beat, phase) = re;
      f.at_im(a, beat, phase) = im;
    }
  }
  return f;
}

StimFrame permute_frame(const StimFrame& base,
                        const std::vector<unsigned>& perm) {
  StimFrame out;
  for (unsigned a = 0; a < kNAnt; ++a) {
    const unsigned src = perm[a];
    for (unsigned n = 0; n < kBeatsPerFrame * kSpc; ++n) {
      const unsigned beat = n / kSpc;
      const unsigned phase = n % kSpc;
      out.at_re(a, beat, phase) =
          const_cast<StimFrame&>(base).at_re(src, beat, phase);
      out.at_im(a, beat, phase) =
          const_cast<StimFrame&>(base).at_im(src, beat, phase);
    }
  }
  return out;
}

// ---------------------------------------------------------------------------
// Session
// ---------------------------------------------------------------------------

Session::Session(Vpipeline_top* top, std::uint64_t seed)
    : top_(top),
      seeds_(seed),
      rng_(seeds_.engine("pipeline_stim")),
      stall_rng_(seeds_.engine("pipeline_stall")),
      gap_rng_(seeds_.engine("pipeline_gap")),
      sched_([top]() { top->eval(); }) {
  idle_inputs();

  // Three clocks with distinct periods so the CDCs are actually crossed
  // rather than aliasing to a single edge -- SPEC 8. Values here are the
  // measured-scheduler-time analogs of the SPEC 8 targets (core 450 MHz,
  // history 400 MHz, cfg 100 MHz). We express them as integer half-periods
  // in picoseconds (SPEC 12.3 "integer simulation time").
  //
  // core_clk    half period 1111 ps
  // history_clk half period 1250 ps
  // cfg_clk     half period 5000 ps
  //
  // These are ratios, not physical times; the scheduler is unaffected.
  core_ = sched_.add_clock("core_clk", 1111, &top_->core_clk, 0);
  hist_ = sched_.add_clock("history_clk", 1250, &top_->history_clk, 0);
  cfg_  = sched_.add_clock("cfg_clk", 5000, &top_->cfg_clk, 0);

  errors_.set_time_probe(sched_.time_ptr());

  time_limit_ = static_cast<SimTime>(30) * 1000000ULL * 1000ULL;  // 30 ms

  reset_ = std::make_unique<ResetSequencer>(sched_);
  reset_->add_domain("core_rst_n",    core_, &top_->core_rst_n,    8);
  reset_->add_domain("history_rst_n", hist_, &top_->history_rst_n, 6);
  reset_->add_domain("cfg_rst_n",     cfg_,  &top_->cfg_rst_n,     4);

  sched_.on_posedge_sample(core_, [this]() { core_sample(); });
  sched_.on_posedge_drive (core_, [this]() { core_drive();  });
  sched_.on_posedge_sample(hist_, [this]() { hist_sample(); });
  sched_.on_posedge_drive (hist_, [this]() { hist_drive();  });
}

void Session::idle_inputs() {
  top_->s_valid = 0;
  top_->s_sof   = 0;
  top_->s_eof   = 0;
  // Total 32-bit words in s_data: N_ANTENNAS * SAMPLES_PER_CYCLE
  constexpr unsigned kSDataWords = kNAnt * kSpc;
  for (unsigned i = 0; i < kSDataWords; ++i) top_->s_data[i] = 0;
  top_->s_seq   = 0;

  top_->cfg_pfb_wr_valid = 0;
  top_->cfg_pfb_wr_bank  = 0;
  top_->cfg_pfb_wr_addr  = 0;
  top_->cfg_pfb_wr_data  = 0;

  top_->cfg_bf_wr_valid  = 0;
  top_->cfg_bf_wr_bank   = 0;
  top_->cfg_bf_wr_addr   = 0;
  top_->cfg_bf_wr_data   = 0;

  top_->cfg_pipe_swap_req = 0;

  top_->cfg_hist_enable         = 0;
  top_->cfg_hist_depth          = 0;
  top_->cfg_hist_depth_apply    = 0;
  top_->cfg_hist_counter_clear  = 0;
  top_->cfg_hist_sticky_clear   = 0;

  top_->cfg_align_enable         = 0;
  top_->cfg_align_run            = 0;
  top_->cfg_align_frame_off      = 0;
  top_->cfg_align_partial_pass   = 0;
  top_->cfg_align_counter_clear  = 0;
  top_->cfg_align_sticky_clear   = 0;

  top_->cfg_cfar_enable          = 0;
  top_->cfg_cfar_mode            = 0;
  top_->cfg_cfar_out_mode        = 0;
  top_->cfg_cfar_guard_lead      = 0;
  top_->cfg_cfar_guard_lag       = 0;
  top_->cfg_cfar_ref_lead        = 0;
  top_->cfg_cfar_ref_lag         = 0;
  top_->cfg_cfar_alpha           = 0;
  top_->cfg_cfar_status_clear    = 0;

  top_->m_ready = 1;
}

bool Session::reset() {
  idle_inputs();
  reset_->assert_all();
  if (reset_->release_all(time_limit_) != StopReason::kRunning) return false;
  enable_pipeline();
  // History depth: 4 frames of retention, well under HISTORY_FRAMES=16.
  // Enough for alignment's frame_off=0 lookback (reads newest complete
  // frame) while keeping the initial fill short.
  configure_history(4);
  configure_align(0);
  configure_cfar(1, 1, 4, 4, 0x2000); // conservative default settings
  return advance_cycles(64);
}

void Session::enable_pipeline() {
  top_->cfg_hist_enable  = 1;
  top_->cfg_align_enable = 1;
  top_->cfg_align_run    = 1;
  top_->cfg_cfar_enable  = 1;
}

void Session::configure_history(unsigned depth) {
  top_->cfg_hist_depth = static_cast<std::uint16_t>(depth);
  pulse_core(&top_->cfg_hist_depth_apply);
}

void Session::configure_align(unsigned frame_off) {
  top_->cfg_align_frame_off = static_cast<std::uint16_t>(frame_off);
}

void Session::configure_cfar(unsigned guard_lead, unsigned guard_lag,
                             unsigned ref_lead, unsigned ref_lag,
                             unsigned alpha) {
  top_->cfg_cfar_guard_lead = static_cast<std::uint8_t>(guard_lead & 0x1f);
  top_->cfg_cfar_guard_lag  = static_cast<std::uint8_t>(guard_lag  & 0x1f);
  top_->cfg_cfar_ref_lead   = static_cast<std::uint8_t>(ref_lead   & 0x3f);
  top_->cfg_cfar_ref_lag    = static_cast<std::uint8_t>(ref_lag    & 0x3f);
  top_->cfg_cfar_alpha      = static_cast<std::uint16_t>(alpha);
  top_->cfg_cfar_mode       = 0;
  top_->cfg_cfar_out_mode   = 0;
}

void Session::pulse_core(std::uint8_t* sig) {
  *sig = 1;
  sched_.run_cycles(core_, 1, time_limit_);
  *sig = 0;
  sched_.run_cycles(core_, 1, time_limit_);
}

void Session::queue_frame(const StimFrame& frame) {
  ++frames_queued_;
  for (unsigned beat = 0; beat < kBeatsPerFrame; ++beat) {
    for (unsigned a = 0; a < kNAnt; ++a) {
      InBeat b;
      b.sof = (beat == 0);
      b.eof = (beat == kBeatsPerFrame - 1);
      b.seq = next_seq_;
      for (unsigned p = 0; p < kSpc; ++p) {
        const std::uint16_t re = static_cast<std::uint16_t>(
            const_cast<StimFrame&>(frame).at_re(a, beat, p));
        const std::uint16_t im = static_cast<std::uint16_t>(
            const_cast<StimFrame&>(frame).at_im(a, beat, p));
        b.phase[p] = (static_cast<std::uint32_t>(im) << 16) |
                     static_cast<std::uint32_t>(re);
      }
      in_q_[a].push_back(b);
    }
    ++next_seq_;
  }
}

void Session::set_backpressure(BpProfile p) {
  bp_profile_ = p;
  BackpressureConfig cfg;
  switch (p) {
    case BpProfile::kNone:   cfg = BackpressureConfig::none();   break;
    case BpProfile::kLight:  cfg = BackpressureConfig::light();  break;
    case BpProfile::kHeavy:  cfg = BackpressureConfig::heavy();  break;
    case BpProfile::kBursty: cfg = BackpressureConfig::bursty(); break;
  }
  bp_ = std::make_unique<BackpressureGenerator>(stall_rng_, cfg);
}

void Session::set_input_gap(double p) { input_gap_ = p; }
void Session::set_global_input_gap(double p) { global_gap_ = p; }

void Session::core_drive() {
  // Drive input beats to each antenna. Each antenna gets its own front-of-
  // queue beat (so per-antenna seq stays contiguous even under the input
  // gap policy). The gap policy stops that antenna's beat for one cycle,
  // not the whole beat set -- otherwise a per-antenna stream_protocol_
  // checker would see a seq discontinuity as antennas fall out of sync.
  std::uint8_t v = 0, sof = 0, eof = 0;
  // The shared s_seq wire carries the front-of-queue seq of antenna 0; each
  // antenna's own seq is set inside its history metadata by the block. To
  // keep every per-antenna stream_protocol_checker happy the seq wire must
  // be consistent; here we simply track antenna 0's seq. The block's own
  // seq path is tied to the per-antenna input handshake, not to this bit.
  std::uint16_t seq_bits = 0;

  // Global gap: one Bernoulli draw for the whole beat set. All antennas idle
  // together on a gap cycle, preserving per-antenna phasing. This is the
  // right stimulus for SPEC 13.2 "delay invariance".
  const bool global_stall =
      (global_gap_ > 0.0) && harness::bernoulli(gap_rng_, global_gap_);
  if (global_stall) {
    top_->s_valid = 0;
    top_->s_sof   = 0;
    top_->s_eof   = 0;
    top_->s_seq   = 0;
    top_->m_ready = m_ready_next() ? 1 : 0;
    return;
  }

  // s_data layout matches benchmark_pipeline_top's port declaration:
  //   antenna a, phase p occupies bits [a*SPC*32 + p*32 +: 32]
  // In the Verilator wide vector (32-bit little-endian words) that maps to
  // s_data[a*SPC + p] for phase p of antenna a. No padding between antennas.
  //
  // The RTL port `s_valid` and `s_sof`/`s_eof` are N_ANTENNAS bits wide;
  // Verilator represents them as an integer that fits their width. On the
  // full config N_ANTENNAS=16 -> 16 bits, so we widen the temporary to
  // uint32_t and mask before assignment (top_->s_valid is a CData for <=8
  // bits, SData for 9..16). Assigning through the pointer variant lets the
  // same code handle both.
  std::uint32_t v32 = 0, sof32 = 0, eof32 = 0;
  for (unsigned a = 0; a < kNAnt; ++a) {
    if (in_q_[a].empty()) continue;
    if (input_gap_ > 0.0 && harness::bernoulli(gap_rng_, input_gap_)) continue;
    const InBeat& b = in_q_[a].front();
    v32 |= (1u << a);
    if (b.sof) sof32 |= (1u << a);
    if (b.eof) eof32 |= (1u << a);
    for (unsigned p = 0; p < kSpc; ++p) {
      top_->s_data[a * kSpc + p] = b.phase[p];
    }
    if (a == 0) seq_bits = b.seq;
  }
  // Implicit narrowing on assignment: Verilator's CData / SData is unsigned,
  // so assigning a uint32_t truncates to the port width. Medium N_ANT=4
  // picks CData (8b); full N_ANT=16 picks SData (16b). Both work.
  top_->s_valid = v32;
  top_->s_sof   = sof32;
  top_->s_eof   = eof32;
  top_->s_seq   = seq_bits;
  (void)v; (void)sof; (void)eof;  // legacy locals, kept unused for continuity

  // Detection output ready, subject to backpressure profile.
  top_->m_ready = m_ready_next() ? 1 : 0;
}

bool Session::m_ready_next() {
  if (!bp_) return true;
  return bp_->allow();
}

void Session::core_sample() {
  // On accepted beats, pop from the input queue.
  for (unsigned a = 0; a < kNAnt; ++a) {
    const bool driven = (top_->s_valid >> a) & 1u;
    const bool ready  = (top_->s_ready >> a) & 1u;
    if (driven && ready && !in_q_[a].empty()) {
      const InBeat& b = in_q_[a].front();
      if (b.eof && a == 0) {
        // Nothing to do here; frame accounting is via s_eof observation.
      }
      in_q_[a].pop_front();
      ++beats_driven_;
    }
  }

  // Observe CFAR output.
  if (top_->m_valid && top_->m_ready) {
    ++beats_observed_;
    if (top_->m_eof) {
      ++frames_observed_;
      // End-to-end seq monotonicity on the m_eof beat. m_seq is the SPEC 5
      // sequence field carried through PFB -> FFT -> history -> align ->
      // beamformer (BEAM_MUX=1, unchanged) -> power -> CFAR; a non-monotone
      // step here means a block downstream reordered or dropped a frame.
      const std::uint16_t s = static_cast<std::uint16_t>(top_->m_seq);
      if (m_seq_seen_) {
        // Treat 16-bit wrap correctly: a step is a violation only if the
        // signed difference (s - last) mod 2^16 as an int16_t is negative.
        const std::int16_t diff =
            static_cast<std::int16_t>(static_cast<std::uint16_t>(s - m_seq_last_));
        if (diff < 0) {
          ++m_seq_violations_;
          errors_.error("m_seq",
                        std::string("m_seq non-monotone at m_eof: last=") +
                            std::to_string(m_seq_last_) + " now=" +
                            std::to_string(s));
        }
      }
      m_seq_seen_ = true;
      m_seq_last_ = s;
    }
    ++detections_;
  }
}

void Session::hist_drive() {
  // Nothing driven from the history-clock domain in this test (align_net's
  // request stream is fully internal).
}

void Session::hist_sample() {
  // No sink to sample in the history-clock domain.
}

bool Session::run_until_idle(std::uint64_t budget_core_cycles) {
  const std::uint64_t start = sched_.cycles(core_);
  while (sched_.cycles(core_) - start < budget_core_cycles) {
    bool any_pending = false;
    for (unsigned a = 0; a < kNAnt; ++a) {
      if (!in_q_[a].empty()) { any_pending = true; break; }
    }
    // Wait until all input drained AND at least frames_queued_ output frames
    // observed OR expect_detections_ is false and inputs drained. (Some
    // configurations produce no CFAR output because the tones do not exceed
    // the threshold; in that case we don't require a detection.)
    const bool inputs_done = !any_pending;
    const bool outputs_done = (frames_observed_ >= frames_queued_) ||
                              !expect_detections_;
    if (inputs_done && outputs_done) return true;
    if (sched_.run_cycles(core_, 128, time_limit_) != StopReason::kRunning) {
      return false;
    }
  }
  errors_.error("timeout",
                std::string("run_until_idle: budget exceeded after ") +
                std::to_string(budget_core_cycles) + " cycles");
  return false;
}

bool Session::advance_cycles(std::uint64_t cycles) {
  return sched_.run_cycles(core_, cycles, time_limit_) == StopReason::kRunning;
}

void Session::program_pfb_coeff(std::uint8_t bank, std::uint16_t addr,
                                std::uint32_t val) {
  top_->cfg_pfb_wr_valid = 1;
  top_->cfg_pfb_wr_bank  = bank;
  // Port is 8 bits (full config), sliced to $clog2(PHASES*TAPS) inside the top.
  top_->cfg_pfb_wr_addr  = static_cast<std::uint8_t>(addr & 0xff);
  top_->cfg_pfb_wr_data  = val;
  // Wait for cfg_pfb_wr_ready; the coefficient bank crosses cfg_clk boundary
  // so we advance both clocks a few cycles.
  for (int i = 0; i < 64; ++i) {
    sched_.run_cycles(cfg_, 1, time_limit_);
    if (top_->cfg_pfb_wr_ready) break;
  }
  top_->cfg_pfb_wr_valid = 0;
}

void Session::program_bf_weight(std::uint8_t bank, std::uint8_t addr,
                                std::uint32_t val) {
  top_->cfg_bf_wr_valid = 1;
  top_->cfg_bf_wr_bank  = bank;
  // Port is 8 bits (full config), sliced to $clog2(N_BEAMS*N_ANT) inside the top.
  top_->cfg_bf_wr_addr  = static_cast<std::uint8_t>(addr);
  top_->cfg_bf_wr_data  = val;
  for (int i = 0; i < 64; ++i) {
    sched_.run_cycles(cfg_, 1, time_limit_);
    if (top_->cfg_bf_wr_ready) break;
  }
  top_->cfg_bf_wr_valid = 0;
}

void Session::request_pipeline_swap() {
  pulse_core(&top_->cfg_pipe_swap_req);
}

bool Session::program_and_swap_to_active_banks() {
  // PFB coefficient bank 1: PHASES=SPC, TAPS from config. Address in
  // phase-major order (address = phase * TAPS + tap). Program tap 0 of each
  // phase with a large-but-safe real coefficient and every other tap with
  // zero -- makes the filter a phase-preserving identity in the passband.
  const std::uint32_t pfb_active = 0x00007FFFu;
  const std::uint32_t pfb_zero   = 0x00000000u;
  const unsigned pfb_taps      = sim_config::PFB_TAPS;
  const unsigned pfb_addr_count = kSpc * pfb_taps;
  for (unsigned addr = 0; addr < pfb_addr_count; ++addr) {
    const unsigned tap = addr % pfb_taps;
    program_pfb_coeff(/*bank=*/1, static_cast<std::uint16_t>(addr),
                      tap == 0 ? pfb_active : pfb_zero);
  }
  // Beamformer weights bank 1: N_BEAMS * N_ANT addresses. Uniform weights.
  // Scale down enough that N_ANT * weight * sample stays in range: use
  //   weight ~= 0.5 / N_ANT scaled to Q1.15.
  // At medium (N_ANT=4) that is 0.125 = 0x1000; at full (N_ANT=16) it is
  // 0.03125 = 0x0400. This keeps power_calc's saturation bound satisfied at
  // every config without changing the CFAR test's arithmetic beyond N_ANT.
  const std::uint32_t bf_val = static_cast<std::uint32_t>(0x8000u / kNAnt / 2u);
  const unsigned bf_addr_count = sim_config::N_BEAMS * kNAnt;
  for (unsigned addr = 0; addr < bf_addr_count; ++addr) {
    program_bf_weight(/*bank=*/1, static_cast<std::uint8_t>(addr), bf_val);
  }
  request_pipeline_swap();
  // Drive one warm-up frame so the swap fires at the next end-of-frame.
  const std::uint64_t swap_before = pipeline_swap_count();
  set_expect_detections(true);   // wait for the warm-up frame's CFAR output
  queue_frame(zero_frame());
  const bool ok = run_until_idle(40000ULL);
  const bool swap_fired = pipeline_swap_count() > swap_before;

  // Extra drain cycles so any residual pipeline state (align FIFO, elastic
  // buffer, CFAR output eof) reaches quiescence before the caller starts.
  advance_cycles(2000);

  // Clear CFAR sticky counters so cfar_det_count() reflects only what the
  // caller drives after this returns.
  top_->cfg_cfar_status_clear = 1;
  advance_cycles(2);
  top_->cfg_cfar_status_clear = 0;
  advance_cycles(2);

  // Reset host-side accounting so the caller's frames start from zero.
  frames_queued_ = 0;
  frames_observed_ = 0;
  beats_driven_ = 0;
  beats_observed_ = 0;
  detections_ = 0;
  m_seq_seen_ = false;
  m_seq_last_ = 0;
  m_seq_violations_ = 0;
  next_seq_ = 0;
  return ok && swap_fired;
}

std::uint64_t Session::pipeline_swap_count() const {
  return top_->stat_pipe_swap_count;
}

std::uint64_t Session::pipeline_swap_overrun_count() const {
  return top_->stat_pipe_swap_overrun;
}

std::uint64_t Session::cfar_det_count() const {
  return top_->stat_cfar_det_count;
}

void Session::assert_reset() {
  reset_->assert_all();
  advance_cycles(4);
}

void reset_run_state(Session& s) {
  (void)s;
}

}  // namespace pipeline_tb
