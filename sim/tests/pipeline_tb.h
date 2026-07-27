// -----------------------------------------------------------------------------
// pipeline_tb.h — the shared session for the SPEC.md 19 Phase 3 pipeline tests
// (issue #17).
//
// Five tests drive the same DUT — `benchmark_sim_top` at the CONFIG size — and
// differ in what they do to it, not in how they reach it. This header is the
// "how": three clocks, the reset sequence, the register programming, the
// per-stage monitors, and the bridge from an observed beat to the C++ model's
// view of it.
//
//   test_pipeline_continuous      continuous frames, end-to-end identity
//   test_pipeline_runtime_update  coefficient and weight bank swaps
//   test_pipeline_metamorphic     the SPEC 13.2 property set
//   test_pipeline_random          SPEC 13.3 randomisation
//   test_pipeline_stress          SPEC 13.4 long stress
//
// 1. Why the monitors tap every stage
// -----------------------------------
// SPEC 12.5 asks for transaction identity end to end. Against an eight-stage
// pipeline, a scoreboard that sees only the two ends can report that the answer
// is wrong and nothing else. Every stage boundary of `benchmark_core` is
// exported (see its port list), and this session records each one, so a failure
// names the stage that produced it. The end-to-end check still runs — a set of
// individually correct stages wired together wrongly must still fail — but it is
// the second check rather than the only one.
//
// 2. No fixed latency, anywhere
// -----------------------------
// Nothing here counts cycles from an input to an output. Every comparison is
// keyed by identity:
//
//   front end      antenna + frame index + sample index, from the source's own
//                  beat counter
//   history        the ABSOLUTE frame_id the response carries, which is the only
//                  field that survives rotation (ARCHITECTURE.md 3.4)
//   alignment      the bin index inside the beat's own metadata
//   back end       stream_id (the beam) + seq, per SPEC 5
//
// That is what lets the same session run at four clock ratios and under four
// backpressure profiles without a single expected number changing.
//
// 3. The one thing the harness may NOT do
// ---------------------------------------
// It cannot inject samples. SPEC 3 puts the synthetic sources inside the design
// — `benchmark_fabric_top` has no pins to receive samples on — so stimulus is
// programmed, not driven. The session therefore configures a source and then
// PREDICTS what it must have produced, and checks that prediction against
// `obs_adc_*` before it trusts anything downstream. If that first check fails,
// nothing else in the run means anything, and every test says so by running it
// first.
//
// Build contract: g++ 13, -std=c++17 -O3 -Wall -Wextra -Werror.
// -----------------------------------------------------------------------------
#ifndef SIM_TESTS_PIPELINE_TB_H_
#define SIM_TESTS_PIPELINE_TB_H_

#include <algorithm>
#include <cstdint>
#include <cstdio>
#include <deque>
#include <map>
#include <memory>
#include <string>
#include <type_traits>
#include <vector>

#include "Vbenchmark_sim_top.h"
#include "verilated.h"

#include "config_sim.h"
#include "harness/clock_ratios.h"
#include "harness/clock_scheduler.h"
#include "harness/error_collector.h"
#include "harness/random.h"
#include "harness/reg_driver.h"
#include "harness/reset_sequencer.h"
#include "harness/run_summary.h"
#include "harness/sim_args.h"
#include "harness/sim_time.h"

#include "cfar/cfar_model.hpp"
#include "pipeline/pipeline_model.hpp"
#include "regmap/regmap.hpp"

namespace pipetb {

using harness::ErrorCollector;
using harness::RegDriver;
using harness::ResetSequencer;
using harness::SimTime;
using harness::StopReason;

// ---------------------------------------------------------------------------
// 1. Reading a Verilated signal of any width
//
// Verilator presents a signal as an integral type up to 64 bits and as an array
// of 32-bit words above it. Every payload this session reads is wider than 64
// bits at some SPEC 11 size and narrower at another, so the extraction has to be
// width-agnostic or every test would carry a `#if` on the configuration.
// ---------------------------------------------------------------------------
template <typename T>
inline std::uint64_t sig_bits(const T& s, unsigned lsb, unsigned width) {
  const std::uint64_t mask =
      width >= 64 ? ~0ULL : ((1ULL << width) - 1ULL);
  if constexpr (std::is_integral_v<T>) {
    return (static_cast<std::uint64_t>(s) >> lsb) & mask;
  } else {
    std::uint64_t out = 0;
    for (unsigned i = 0; i < width; ++i) {
      const unsigned bit = lsb + i;
      const std::uint64_t w = static_cast<std::uint64_t>(s[bit >> 5]);
      out |= ((w >> (bit & 31u)) & 1ULL) << i;
    }
    return out & mask;
  }
}

// ---------------------------------------------------------------------------
// 2. The elaborated geometry, read from the generated configuration
//
// Never written down twice: `sim_config` is the same generated mirror the RTL
// elaborates from, so a test cannot model a geometry the design was not built
// with. `benchmark_sim_top` additionally compares its own derived widths against
// the instantiated core's at time 0.
// ---------------------------------------------------------------------------
inline pipeline::Geometry geometry() {
  pipeline::Geometry g;
  g.n_ant = sim_config::N_ANTENNAS;
  g.lanes = sim_config::SAMPLES_PER_CYCLE;
  g.fft_size = sim_config::FFT_SIZE;
  g.pfb_taps = sim_config::PFB_TAPS;
  g.n_beams = sim_config::N_BEAMS;
  g.history_frames = sim_config::HISTORY_FRAMES;
  g.bin_par = sim_config::PIPE_BIN_PAR;
  g.beam_par = sim_config::PIPE_BEAM_PAR;
  g.align_groups = sim_config::PIPE_ALIGN_GROUPS;
  g.covar_pairs = sim_config::N_COVAR_PAIRS;
  g.cfar_max_guard = sim_config::CFAR_MAX_GUARD;
  g.cfar_max_ref = sim_config::CFAR_MAX_REF;
  return g;
}

// SPEC 5 field offsets, shared by every stream in the pipeline: only DATA_W
// differs between them, so the metadata offsets are a function of the data width
// alone.
struct Layout {
  unsigned data_w = 0;
  unsigned user_lsb = 0;
  unsigned seq_lsb = 0;
  unsigned id_lsb = 0;
  unsigned eof_lsb = 0;
  unsigned sof_lsb = 0;
  unsigned data_lsb = 0;
  unsigned payload_w = 0;

  static Layout of(unsigned data_bits) {
    Layout l;
    l.data_w = data_bits;
    l.user_lsb = 0;
    l.seq_lsb = sim_config::STREAM_USER_W;
    l.id_lsb = l.seq_lsb + sim_config::STREAM_SEQ_W;
    l.eof_lsb = l.id_lsb + sim_config::STREAM_ID_W;
    l.sof_lsb = l.eof_lsb + 1;
    l.data_lsb = l.sof_lsb + 1;
    l.payload_w = l.data_lsb + data_bits;
    return l;
  }
};

struct Meta {
  bool sof = false;
  bool eof = false;
  std::uint32_t stream_id = 0;
  std::uint32_t seq = 0;
  std::uint32_t user = 0;
};

template <typename T>
inline Meta read_meta(const T& sig, const Layout& l, unsigned base = 0) {
  Meta m;
  m.user = static_cast<std::uint32_t>(
      sig_bits(sig, base + l.user_lsb, sim_config::STREAM_USER_W));
  m.seq = static_cast<std::uint32_t>(
      sig_bits(sig, base + l.seq_lsb, sim_config::STREAM_SEQ_W));
  m.stream_id = static_cast<std::uint32_t>(
      sig_bits(sig, base + l.id_lsb, sim_config::STREAM_ID_W));
  m.eof = sig_bits(sig, base + l.eof_lsb, 1) != 0;
  m.sof = sig_bits(sig, base + l.sof_lsb, 1) != 0;
  return m;
}

// ---------------------------------------------------------------------------
// 3. Observed beats
// ---------------------------------------------------------------------------
struct FrontBeat {
  unsigned ant = 0;
  Meta meta;
  std::vector<fxp::Complex> lane;   // `lanes` samples
};

struct HistResponse {
  std::vector<fxp::Complex> vec;    // one sample per antenna
  unsigned bin = 0;
  unsigned frame_off = 0;
  std::uint32_t frame_id = 0;
  unsigned flags = 0;
};

struct AlignBeat {
  Meta meta;
  std::vector<fxp::Complex> data;   // bin_par * n_ant, [lane*n_ant + ant]
};

struct BeamBeat {
  Meta meta;
  std::vector<fxp::Complex> data;   // bin_par * beam_par, [beam*bin_par + bin]
};

struct BinBeat {
  Meta meta;
  std::vector<fxp::Complex> beam;   // n_beams
};

struct PowerBeat {
  Meta meta;
  std::vector<std::uint64_t> beam;  // n_beams
};

// ---------------------------------------------------------------------------
// 4. The session
// ---------------------------------------------------------------------------
class Session {
 public:
  Session(Vbenchmark_sim_top* top, ErrorCollector* errors, std::uint64_t seed,
          const harness::ClockRatio* ratio = nullptr)
      : top_(top),
        g_(geometry()),
        errors_(errors),
        sched_([top]() { top->eval(); }),
        bp_rng_(harness::splitmix64(seed ^ 0x9E3779B97F4A7C15ULL)),
        seed_(seed) {
    idle_inputs();

    // SPEC 8 constraint targets. A test that wants a different relationship
    // passes a ClockRatio; the default is the specified one, which is the
    // 9:8 core/history pair issue #15's own suite sweeps around.
    SimTime core_half = harness::half_period_ps(harness::kCoreClkMhz);
    SimTime hist_half = harness::half_period_ps(harness::kHistoryClkMhz);
    SimTime core_first = 0;
    SimTime hist_first = 0;
    if (ratio != nullptr) {
      core_half = ratio->half_a;
      hist_half = ratio->half_b;
      core_first = ratio->first_a;
      hist_first = ratio->first_b;
      ratio_name_ = ratio->name;
    } else {
      ratio_name_ = "spec 450:400";
    }

    core_clk_ = sched_.add_clock("core_clk", core_half, &top_->core_clk, core_first);
    hist_clk_ =
        sched_.add_clock("history_clk", hist_half, &top_->history_clk, hist_first);
    cfg_clk_ = sched_.add_clock(
        "cfg_clk", harness::half_period_ps(harness::kCfgClkMhz), &top_->cfg_clk, 0);

    errors_->set_time_probe(sched_.time_ptr());
    // The scheduler's global time limit, not a cycle budget: every pass bounds its
    // own work in cycles, and this is the backstop that turns a genuine deadlock
    // into a reported timeout rather than a run that never returns. 100 ms of
    // simulated time is about 45 million core cycles — comfortably above the
    // SPEC 13.4 stress pass and far below anything a wall clock would tolerate.
    limit_ = static_cast<SimTime>(100000000000) * 1000;

    reset_ = std::make_unique<ResetSequencer>(sched_);
    reset_->add_domain("core_rst_n", core_clk_, &top_->core_rst_n, 8);
    reset_->add_domain("history_rst_n", hist_clk_, &top_->history_rst_n, 8);
    reset_->add_domain("cfg_rst_n", cfg_clk_, &top_->cfg_rst_n, 4);

    harness::RegPort port;
    port.address = &top_->reg_address;
    port.write_data = &top_->reg_write_data;
    port.byte_enable = &top_->reg_byte_enable;
    port.write_enable = &top_->reg_write_enable;
    port.read_enable = &top_->reg_read_enable;
    port.read_data = &top_->reg_read_data;
    port.ready = &top_->reg_ready;
    port.error = &top_->reg_error;
    reg_ = std::make_unique<RegDriver>("cfg", port, sched_, cfg_clk_, *errors_);

    sched_.on_posedge_sample(core_clk_, [this]() { sample_core(); });
    sched_.on_posedge_drive(core_clk_, [this]() { drive_core(); });
    sched_.on_posedge_sample(hist_clk_, [this]() { sample_hist(); });
  }

  const pipeline::Geometry& g() const { return g_; }
  ErrorCollector& errors() { return *errors_; }
  RegDriver& reg() { return *reg_; }
  const std::string& ratio_name() const { return ratio_name_; }
  std::uint64_t core_cycles() const { return sched_.cycles(core_clk_); }

  // ---- lifecycle ---------------------------------------------------------
  bool reset() {
    idle_inputs();
    clear_observations();
    reset_->assert_all();
    if (reset_->release_all(limit_) != StopReason::kRunning) return false;
    reg_->reset();
    return settle(16);
  }

  bool settle(std::uint64_t cycles) {
    return sched_.run_cycles(core_clk_, cycles, limit_) == StopReason::kRunning;
  }

  bool run_core(std::uint64_t cycles) { return settle(cycles); }

  // ---- output backpressure ------------------------------------------------
  void set_event_backpressure(const harness::BackpressureConfig& cfg) {
    ev_bp_ = std::make_unique<harness::BackpressureGenerator>(
        std::mt19937_64(harness::splitmix64(seed_ ^ 0xEEEE1234ULL)), cfg);
  }

  // ---- register programming ----------------------------------------------
  void write(std::uint32_t addr, std::uint32_t value, const char* what) {
    const harness::RegResult r = reg_->write(addr, value);
    if (!r.ok()) {
      errors_->error("register", std::string("write failed: ") + what);
    }
  }

  std::uint32_t read(std::uint32_t addr, const char* what) {
    const harness::RegResult r = reg_->read(addr);
    if (!r.ok()) {
      errors_->error("register", std::string("read failed: ") + what);
      return 0;
    }
    return r.data;
  }

  // Program the synthetic sources. Returns the SrcConfig the model must use, so
  // the two cannot be programmed differently by accident.
  pipeline::SrcConfig configure_source(pipeline::SrcMode mode, std::int16_t gain,
                                   unsigned tone_step, unsigned ant_step,
                                   std::uint32_t lfsr_seed) {
    pipeline::SrcConfig c;
    c.mode = mode;
    c.gain = gain;
    c.tone_step = tone_step;
    c.ant_step = ant_step;
    c.seed = lfsr_seed;

    write(regmap::PIPELINE_PIPE_SRC_MODE_ADDR,
          static_cast<std::uint32_t>(mode), "src mode");
    write(regmap::PIPELINE_PIPE_SRC_GAIN_ADDR,
          static_cast<std::uint32_t>(static_cast<std::uint16_t>(gain)), "src gain");
    write(regmap::PIPELINE_PIPE_SRC_TONE_ADDR,
          (tone_step & 0xFFFFu) | ((ant_step & 0xFFFFu) << 16), "src tone");
    write(regmap::PIPELINE_PIPE_SRC_SEED_ADDR, lfsr_seed, "src seed");
    pulse(regmap::PIPELINE_PIPE_CTRL_ADDR,
          regmap::PIPELINE_PIPE_CTRL_SRC_RESEED_LSB, "src reseed");
    return c;
  }

  // Detection settings. Returns the config the model must use.
  cfar::Config configure_cfar(unsigned guard, unsigned ref, unsigned alpha,
                              cfar::Mode mode = cfar::Mode::kCA,
                              cfar::OutMode out = cfar::OutMode::kEvents) {
    cfar::Config c;
    c.enable = true;
    c.mode = mode;
    c.out_mode = out;
    c.guard_lead = guard;
    c.guard_lag = guard;
    c.ref_lead = ref;
    c.ref_lag = ref;
    c.alpha = alpha;

    std::uint32_t ctrl = 0;
    ctrl |= 1u << regmap::CFAR_CFAR_CTRL_ENABLE_LSB;
    ctrl |= static_cast<std::uint32_t>(mode) << regmap::CFAR_CFAR_CTRL_MODE_LSB;
    ctrl |= static_cast<std::uint32_t>(out) << regmap::CFAR_CFAR_CTRL_OUT_MODE_LSB;
    write(regmap::CFAR_CFAR_CTRL_ADDR, ctrl, "cfar ctrl");
    write(regmap::CFAR_CFAR_WINDOW_ADDR,
          (guard << regmap::CFAR_CFAR_WINDOW_GUARD_LEAD_LSB) |
              (guard << regmap::CFAR_CFAR_WINDOW_GUARD_LAG_LSB) |
              (ref << regmap::CFAR_CFAR_WINDOW_REF_LEAD_LSB) |
              (ref << regmap::CFAR_CFAR_WINDOW_REF_LAG_LSB), "cfar window");
    write(regmap::CFAR_CFAR_THRESHOLD_ADDR, alpha, "cfar alpha");
    return c;
  }

  void configure_history(unsigned depth) {
    write(regmap::HISTORY_HISTORY_DEPTH_ADDR, depth, "history depth");
    pulse(regmap::HISTORY_HISTORY_CTRL_ADDR,
          regmap::HISTORY_HISTORY_CTRL_DEPTH_APPLY_LSB, "history depth apply");
  }

  void set_run(bool src_run, bool align_run) {
    std::uint32_t v = 0;
    v |= 1u << regmap::PIPELINE_PIPE_CTRL_SRC_ENABLE_LSB;
    v |= 1u << regmap::PIPELINE_PIPE_CTRL_ALIGN_ENABLE_LSB;
    if (src_run) v |= 1u << regmap::PIPELINE_PIPE_CTRL_SRC_RUN_LSB;
    if (align_run) v |= 1u << regmap::PIPELINE_PIPE_CTRL_ALIGN_RUN_LSB;
    write(regmap::PIPELINE_PIPE_CTRL_ADDR, v, "pipe run");
  }

  void pulse(std::uint32_t addr, unsigned lsb, const char* what) {
    // A pulse field reads back zero, so the surrounding level bits have to be
    // re-supplied on the same write or they would be cleared. Read-modify-write
    // is the only correct sequence and it is done here once rather than in
    // every caller.
    const std::uint32_t cur = read(addr, what);
    write(addr, cur | (1u << lsb), what);
  }

  // Load a coefficient bank and swap it in at the next frame boundary.
  void load_coefficients(const std::vector<fxp::Complex>& coeff, unsigned bank) {
    write(regmap::COEFF_COEFF_CTRL_ADDR,
          (bank & 1u) << regmap::COEFF_COEFF_CTRL_BANK_SEL_LSB, "coeff bank");
    write(regmap::COEFF_COEFF_ADDR_ADDR,
          (1u << regmap::COEFF_COEFF_ADDR_AUTO_INC_LSB), "coeff index");
    for (const fxp::Complex& c : coeff) {
      wait_not_busy(regmap::COEFF_COEFF_STATUS_ADDR,
                    regmap::COEFF_COEFF_STATUS_WR_BUSY_LSB, "coeff");
      write(regmap::COEFF_COEFF_DATA_ADDR, c.packed(), "coeff data");
    }
    // The LAST write is still in flight when its register access returns: the
    // transfer crosses cfg_clk to core_clk on a four-phase handshake that
    // outlives the write. Anything the caller does next — request a swap, reset
    // the design — happens on top of it, and the symptom is one bank whose last
    // few entries are whatever was there before. Waiting here rather than in
    // every caller is what makes "the bank is loaded" true when this returns.
    wait_not_busy(regmap::COEFF_COEFF_STATUS_ADDR,
                  regmap::COEFF_COEFF_STATUS_WR_BUSY_LSB, "coeff drain");
  }

  void swap_coefficients(unsigned bank) {
    pulse(regmap::COEFF_COEFF_CTRL_ADDR,
          regmap::COEFF_COEFF_CTRL_SWAP_REQ_LSB, "coeff swap");
    (void)bank;
  }

  void load_weights(const std::vector<fxp::Complex>& w, unsigned bank) {
    write(regmap::COEFF_WEIGHT_CTRL_ADDR,
          (bank & 1u) << regmap::COEFF_WEIGHT_CTRL_BANK_SEL_LSB, "weight bank");
    write(regmap::COEFF_WEIGHT_ADDR_ADDR,
          (1u << regmap::COEFF_WEIGHT_ADDR_AUTO_INC_LSB), "weight index");
    for (const fxp::Complex& c : w) {
      wait_not_busy(regmap::COEFF_WEIGHT_STATUS_ADDR,
                    regmap::COEFF_WEIGHT_STATUS_WR_BUSY_LSB, "weight");
      write(regmap::COEFF_WEIGHT_DATA_ADDR, c.packed(), "weight data");
    }
    wait_not_busy(regmap::COEFF_WEIGHT_STATUS_ADDR,
                  regmap::COEFF_WEIGHT_STATUS_WR_BUSY_LSB, "weight drain");
  }

  void swap_weights() {
    pulse(regmap::COEFF_WEIGHT_CTRL_ADDR,
          regmap::COEFF_WEIGHT_CTRL_SWAP_REQ_LSB, "weight swap");
  }


  // -------------------------------------------------------------------------
  // Programming both coefficient banks, and why it takes a restart
  //
  // A coefficient or weight bank swap takes effect at a start-of-frame beat and
  // not before (SPEC 7.1, 7.5), a write aimed at the ACTIVE bank is refused, and
  // both stores power up as zeros. Those three rules together mean there is no
  // way to have the very first frame filtered by a programmed set in one pass:
  // bank 0 is active at reset and cannot be written, and bank 1 cannot become
  // active until a frame boundary has gone by — which is one frame filtered by
  // zeros.
  //
  // A test that ignored this would have its model and the design disagree on
  // frame 0 and on the polyphase tap history of every frame after it. The
  // sequence below removes the ambiguity instead of tolerating it:
  //
  //   1  load bank 1 and request the swap;
  //   2  run the sources with the alignment network CLOSED, long enough for a
  //      start-of-frame beat to retire both swaps;
  //   3  stop, and load bank 0 — now the inactive one — with the same values;
  //   4  reset. The active bank returns to 0, which now holds the programmed
  //      set, and the polyphase tap history and every counter start empty.
  //
  // Coefficient STORAGE survives a reset by design (rtl/pfb/coeff_bank.sv: only
  // the control state resets), which is what makes step 4 work rather than undo
  // steps 1-3. The cost is one extra warm-up run per pass and the benefit is
  // that frame 0 of the captured run is a frame the model can predict exactly.
  bool program_banks(const std::vector<fxp::Complex>& coeff,
                     const std::vector<fxp::Complex>& weights) {
    if (!reset()) return false;

    load_coefficients(coeff, 1);
    swap_coefficients(1);
    load_weights(weights, 1);
    swap_weights();

    // The alignment network is OPEN during this warm-up, and it has to be: the
    // beam-weight bank swaps when the beamformer ISSUES its first beam group of
    // a start-of-frame beat (issue #12, decision 4), and the beamformer issues
    // nothing until the alignment network delivers. A warm-up with the tap
    // closed would leave the weight swap pending forever, which is what this
    // sequence looked like before it was written down. The responses it reads
    // are out-of-range and flagged, and none of them matters: everything this
    // pass produces is discarded by the reset at the end of it.
    set_run(true, true);
    if (!settle(64)) return false;
    if (!wait_bank_active()) return false;

    set_run(false, false);
    if (!settle(256)) return false;

    load_coefficients(coeff, 0);
    load_weights(weights, 0);

    return reset();
  }

  // Poll until both stores report the bank they were told to swap to. The poll
  // pumps the scheduler, so the design runs while it waits.
  bool wait_bank_active() {
    for (int i = 0; i < 512; ++i) {
      const std::uint32_t cs = read(regmap::COEFF_COEFF_STATUS_ADDR, "coeff status");
      const std::uint32_t ws = read(regmap::COEFF_WEIGHT_STATUS_ADDR, "weight status");
      const bool cb = ((cs >> regmap::COEFF_COEFF_STATUS_ACTIVE_BANK_LSB) & 1u) != 0;
      const bool wb = ((ws >> regmap::COEFF_WEIGHT_STATUS_ACTIVE_BANK_LSB) & 1u) != 0;
      if (cb && wb) return true;
      if (!settle(32)) return false;
    }
    errors_->error("register", "a coefficient or weight swap never retired");
    return false;
  }

  // Frames the corner turn reports complete. The alignment network must not be
  // opened before there is something to read: a sweep against an empty history
  // is answered with HIST_FLAG_OUT_OF_RANGE on every response, which is correct
  // behaviour and is not what any of these tests is about.
  std::uint32_t frames_done() {
    return read(regmap::HISTORY_HISTORY_FRAMES_DONE_ADDR, "frames done");
  }

  bool wait_frames(std::uint32_t n, std::uint64_t budget) {
    std::uint64_t spent = 0;
    while (frames_done() < n) {
      if (!settle(256)) return false;
      spent += 256;
      if (spent > budget) {
        errors_->error("timeout",
                       "only " + std::to_string(frames_done()) +
                           " frames completed; wanted " + std::to_string(n));
        return false;
      }
    }
    return true;
  }

  // Zero every counter and sticky fault the warm-up legitimately set, so the
  // measured run starts from a clean slate. Two windows own them.
  void clear_telemetry() {
    pulse(regmap::PIPELINE_PIPE_CTRL_ADDR,
          regmap::PIPELINE_PIPE_CTRL_COUNTER_CLEAR_LSB, "pipe counter clear");
    pulse(regmap::PIPELINE_PIPE_CTRL_ADDR,
          regmap::PIPELINE_PIPE_CTRL_STATUS_CLEAR_LSB, "pipe status clear");
    pulse(regmap::HISTORY_HISTORY_CTRL_ADDR,
          regmap::HISTORY_HISTORY_CTRL_COUNTER_CLEAR_LSB, "history counter clear");
    pulse(regmap::HISTORY_HISTORY_CTRL_ADDR,
          regmap::HISTORY_HISTORY_CTRL_STATUS_CLEAR_LSB, "history status clear");
    write(regmap::PIPELINE_PIPE_ALIGN_STATUS_ADDR, 0xFu, "align fault w1c");
    write(regmap::HISTORY_HISTORY_FAULT_ADDR, 0xFu, "history fault w1c");
  }

  // Recording off, tallies on.
  //
  // The SPEC 13.4 stress pass runs for millions of cycles and would otherwise
  // fill memory with beats nobody reads: the directed passes check every value,
  // and what the stress pass checks is that nothing broke over a long run. With
  // recording off the monitors still count every transfer, still watch every
  // sequence number for a wrap, and still hand every beat to the protocol
  // checkers inside the RTL — they simply do not keep it.
  void set_recording(bool on) { record_ = on; }

  std::uint64_t seen_adc() const { return n_adc_; }
  std::uint64_t seen_align() const { return n_align_; }
  std::uint64_t seen_power() const { return n_power_; }
  std::uint64_t seq_wraps() const { return n_seq_wrap_; }

  // Record the harness's own tallies at the instant the design's counters were
  // cleared, so `check_counters` compares two numbers measured from the same
  // starting point. Without it a mid-run `COUNTER_CLEAR` — which every pass
  // issues, to discard the warm-up — makes the design's counter look thousands
  // of beats behind the harness's, which is arithmetic rather than a defect.
  void mark_counter_epoch() {
    epoch_adc_ = 0;
    for (unsigned a = 0; a < g_.n_ant; ++a) epoch_adc_ += front_[a].size();
    epoch_align_ = align_.size();
  }
  std::uint64_t epoch_adc() const { return epoch_adc_; }
  std::uint64_t epoch_align() const { return epoch_align_; }

  // ---- observations -------------------------------------------------------
  void clear_observations() {
    front_.assign(g_.n_ant, {});
    fft_.assign(g_.n_ant, {});
    hist_.clear();
    align_.clear();
    beam_.clear();
    bin_.clear();
    power_.clear();
    events_.clear();
    ev_count_ = 0;
    epoch_adc_ = 0;
    epoch_align_ = 0;
    n_adc_ = 0;
    n_align_ = 0;
    n_power_ = 0;
    n_seq_wrap_ = 0;
    last_align_seq_ = 0;
    have_align_seq_ = false;
  }

  const std::vector<std::deque<FrontBeat>>& adc_beats() const { return front_; }
  const std::vector<std::deque<FrontBeat>>& fft_beats() const { return fft_; }
  const std::deque<HistResponse>& hist_responses() const { return hist_; }
  const std::deque<AlignBeat>& align_beats() const { return align_; }
  const std::deque<BeamBeat>& beam_beats() const { return beam_; }
  const std::deque<BinBeat>& bin_beats() const { return bin_; }
  const std::deque<PowerBeat>& power_beats() const { return power_; }
  const std::deque<std::pair<std::uint32_t, cfar::Event>>& events() const {
    return events_;
  }
  std::uint64_t event_count() const { return ev_count_; }

  // The events of one beam, in the order that beam's detector emitted them.
  // Demultiplexing by `stream_id` is what makes the merge order irrelevant, and
  // it is the reason issue #14 made `seq` per-beam.
  std::vector<cfar::Event> beam_events(std::uint32_t beam) const {
    std::vector<cfar::Event> out;
    for (const auto& e : events_) {
      if (e.first == beam) out.push_back(e.second);
    }
    return out;
  }

 private:
  // ---- signal idling ------------------------------------------------------
  void idle_inputs() {
    top_->core_clk = 0;
    top_->history_clk = 0;
    top_->cfg_clk = 0;
    top_->core_rst_n = 0;
    top_->history_rst_n = 0;
    top_->cfg_rst_n = 0;
    top_->reg_address = 0;
    top_->reg_write_data = 0;
    top_->reg_byte_enable = 0;
    top_->reg_write_enable = 0;
    top_->reg_read_enable = 0;
    top_->ev_ready = 1;
    top_->s_valid = 0;
    top_->s_data = 0;
    top_->s_start_of_frame = 0;
    top_->s_end_of_frame = 0;
    top_->s_stream_id = 0;
    top_->s_seq = 0;
    top_->s_user = 0;
    top_->m_ready = 1;
    top_->eval();
  }

  void wait_not_busy(std::uint32_t addr, unsigned lsb, const char* what) {
    for (int i = 0; i < 4096; ++i) {
      if (((read(addr, what) >> lsb) & 1u) == 0u) return;
    }
    errors_->error("register",
                   std::string("busy never cleared for ") + what);
  }

  // ---- per-cycle sampling -------------------------------------------------
  void sample_core() {
    const Layout front = Layout::of(g_.lanes * 32);
    for (unsigned a = 0; a < g_.n_ant; ++a) {
      if (((top_->obs_adc_valid >> a) & 1u) && ((top_->obs_adc_ready >> a) & 1u)) {
        ++n_adc_;
        if (record_) front_[a].push_back(read_front(top_->obs_adc_payload, front, a));
      }
      if (((top_->obs_fft_valid >> a) & 1u) && ((top_->obs_fft_ready >> a) & 1u)) {
        if (record_) fft_[a].push_back(read_front(top_->obs_fft_payload, front, a));
      }
    }

    if (top_->obs_bf_valid && top_->obs_bf_ready) {
      const Layout l = Layout::of(g_.bin_par * g_.beam_par * 32);
      BeamBeat b;
      b.meta = read_meta(top_->obs_bf_payload, l);
      b.data.resize(static_cast<std::size_t>(g_.bin_par) * g_.beam_par);
      for (std::size_t i = 0; i < b.data.size(); ++i) {
        b.data[i] = fxp::Complex::from_packed(static_cast<std::uint32_t>(
            sig_bits(top_->obs_bf_payload, l.data_lsb + 32u * i, 32)));
      }
      if (record_) {
        beam_.push_back(std::move(b));
        if (beam_.size() > kMaxHist) beam_.pop_front();
      }
    }

    if (top_->obs_bin_valid && top_->obs_bin_ready) {
      const Layout l = Layout::of(g_.n_beams * 32);
      BinBeat b;
      b.meta = read_meta(top_->obs_bin_payload, l);
      b.beam.resize(g_.n_beams);
      for (unsigned k = 0; k < g_.n_beams; ++k) {
        b.beam[k] = fxp::Complex::from_packed(static_cast<std::uint32_t>(
            sig_bits(top_->obs_bin_payload, l.data_lsb + 32u * k, 32)));
      }
      if (record_) {
        bin_.push_back(std::move(b));
        if (bin_.size() > kMaxHist) bin_.pop_front();
      }
    }

    if (top_->obs_pwr_valid && top_->obs_pwr_ready) {
      const Layout l = Layout::of(g_.n_beams * covar::kPowerW);
      PowerBeat b;
      b.meta = read_meta(top_->obs_pwr_payload, l);
      b.beam.resize(g_.n_beams);
      for (unsigned k = 0; k < g_.n_beams; ++k) {
        b.beam[k] = sig_bits(top_->obs_pwr_payload,
                             l.data_lsb + covar::kPowerW * k, covar::kPowerW);
      }
      ++n_power_;
      if (record_) power_.push_back(std::move(b));
    }

    if (top_->ev_valid && top_->ev_ready) {
      const Layout l = Layout::of(cfar::kEventW);
      const Meta m = read_meta(top_->ev_payload, l);
      cfar::Event e;
      const unsigned d = l.data_lsb;
      e.kind = static_cast<unsigned>(
          sig_bits(top_->ev_payload, d + cfar::kEvKindLsb, cfar::kEvKindW));
      e.bin = static_cast<unsigned>(
          sig_bits(top_->ev_payload, d + cfar::kEvBinLsb, cfar::kBinW));
      e.frame_id = static_cast<unsigned>(
          sig_bits(top_->ev_payload, d + cfar::kEvFrameIdLsb, cfar::kFrameIdW));
      e.ref_count = static_cast<unsigned>(
          sig_bits(top_->ev_payload, d + cfar::kEvRefCntLsb, cfar::kTotRefW));
      e.alpha = static_cast<unsigned>(
          sig_bits(top_->ev_payload, d + cfar::kEvAlphaLsb, cfar::kAlphaW));
      e.det_count = static_cast<unsigned>(
          sig_bits(top_->ev_payload, d + cfar::kEvDetLsb, cfar::kCntW));
      e.sup_count = static_cast<unsigned>(
          sig_bits(top_->ev_payload, d + cfar::kEvSupLsb, cfar::kCntW));
      e.cut_power = sig_bits(top_->ev_payload, d + cfar::kEvCellLsb, cfar::kPowerW);
      e.noise_sum = sig_bits(top_->ev_payload, d + cfar::kEvSumLsb, cfar::kSumW);
      e.sof = m.sof;
      e.eof = m.eof;
      ++ev_count_;
      if (record_) {
        events_.emplace_back(m.stream_id, e);
        if (events_.size() > kMaxEvents) events_.pop_front();
      }
    }
  }

  void drive_core() {
    top_->ev_ready = (ev_bp_ == nullptr) ? 1 : (ev_bp_->allow() ? 1 : 0);
  }

  void sample_hist() {
    if (top_->obs_align_valid && top_->obs_align_ready) {
      const Layout l = Layout::of(g_.bin_par * g_.n_ant * 32);
      AlignBeat b;
      b.meta = read_meta(top_->obs_align_payload, l);
      b.data.resize(static_cast<std::size_t>(g_.bin_par) * g_.n_ant);
      for (std::size_t i = 0; i < b.data.size(); ++i) {
        b.data[i] = fxp::Complex::from_packed(static_cast<std::uint32_t>(
            sig_bits(top_->obs_align_payload, l.data_lsb + 32u * i, 32)));
      }
      ++n_align_;
      // SPEC 5 sequence continuity across a WRAP. The field is 16 bits, so a
      // long run passes 65535 -> 0 tens of times; the protocol checkers inside
      // the RTL enforce continuity through it, and this counts the wraps so a
      // stress run can say it reached one rather than assuming it did.
      if (have_align_seq_ && b.meta.seq < last_align_seq_) ++n_seq_wrap_;
      last_align_seq_ = b.meta.seq;
      have_align_seq_ = true;
      if (record_) {
        align_.push_back(std::move(b));
        if (align_.size() > kMaxHist) align_.pop_front();
      }
    }

    if (top_->obs_hrsp_valid && top_->obs_hrsp_ready) {
      const unsigned vec_w = g_.n_ant * 32;
      const unsigned bin_w = clog2_at_least1(g_.fft_size);
      const unsigned foff_w = clog2_at_least1(g_.history_frames);
      const Layout l = Layout::of(vec_w + bin_w + foff_w + 32 + 3);
      HistResponse r;
      r.vec.resize(g_.n_ant);
      for (unsigned a = 0; a < g_.n_ant; ++a) {
        r.vec[a] = fxp::Complex::from_packed(static_cast<std::uint32_t>(
            sig_bits(top_->obs_hrsp_payload, l.data_lsb + 32u * a, 32)));
      }
      const unsigned meta = l.data_lsb + vec_w;
      r.bin = static_cast<unsigned>(sig_bits(top_->obs_hrsp_payload, meta, bin_w));
      r.frame_off = static_cast<unsigned>(
          sig_bits(top_->obs_hrsp_payload, meta + bin_w, foff_w));
      r.frame_id = static_cast<std::uint32_t>(
          sig_bits(top_->obs_hrsp_payload, meta + bin_w + foff_w, 32));
      r.flags = static_cast<unsigned>(
          sig_bits(top_->obs_hrsp_payload, meta + bin_w + foff_w + 32, 3));
      if (record_) {
        hist_.push_back(std::move(r));
        if (hist_.size() > kMaxHist) hist_.pop_front();
      }
    }
  }

  template <typename T>
  FrontBeat read_front(const T& sig, const Layout& l, unsigned ant) const {
    FrontBeat b;
    b.ant = ant;
    const unsigned base = ant * l.payload_w;
    b.meta = read_meta(sig, l, base);
    b.lane.resize(g_.lanes);
    for (unsigned k = 0; k < g_.lanes; ++k) {
      b.lane[k] = fxp::Complex::from_packed(static_cast<std::uint32_t>(
          sig_bits(sig, base + l.data_lsb + 32u * k, 32)));
    }
    return b;
  }

  static unsigned clog2_at_least1(unsigned v) {
    unsigned n = 0;
    while ((1u << n) < v) ++n;
    return n == 0 ? 1 : n;
  }

  // Bounded histories: a stress run produces millions of beats and the session
  // must not grow without limit. The bound is generous enough that every
  // directed pass fits entirely and a stress pass keeps a long tail.
  static constexpr std::size_t kMaxHist = 1u << 18;
  static constexpr std::size_t kMaxEvents = 1u << 18;

  Vbenchmark_sim_top* top_;
  pipeline::Geometry g_;
  ErrorCollector* errors_;
  harness::ClockScheduler sched_;
  std::unique_ptr<ResetSequencer> reset_;
  std::unique_ptr<RegDriver> reg_;
  std::unique_ptr<harness::BackpressureGenerator> ev_bp_;
  std::mt19937_64 bp_rng_;
  std::uint64_t seed_;
  std::string ratio_name_;
  int core_clk_ = 0, hist_clk_ = 0, cfg_clk_ = 0;
  SimTime limit_ = 0;

  std::vector<std::deque<FrontBeat>> front_;
  std::vector<std::deque<FrontBeat>> fft_;
  std::deque<HistResponse> hist_;
  std::deque<AlignBeat> align_;
  std::deque<BeamBeat> beam_;
  std::deque<BinBeat> bin_;
  std::deque<PowerBeat> power_;
  std::deque<std::pair<std::uint32_t, cfar::Event>> events_;
  std::uint64_t ev_count_ = 0;
  std::uint64_t epoch_adc_ = 0;
  std::uint64_t epoch_align_ = 0;
  bool record_ = true;
  std::uint64_t n_adc_ = 0;
  std::uint64_t n_align_ = 0;
  std::uint64_t n_power_ = 0;
  std::uint64_t n_seq_wrap_ = 0;
  std::uint32_t last_align_seq_ = 0;
  bool have_align_seq_ = false;
};

// ---------------------------------------------------------------------------
// 5. Shared failure accounting
//
// One category per kind of defect, so a `RESULT: FAIL` line says what broke
// rather than how many things did. Every pipeline test uses the same set, which
// is what lets the Makefile's summary of five runs be read as one table.
// ---------------------------------------------------------------------------
struct Counters {
  std::size_t geometry = 0;
  std::size_t source = 0;
  std::size_t front = 0;
  std::size_t history = 0;
  std::size_t align = 0;
  std::size_t beamform = 0;
  std::size_t power = 0;
  std::size_t detection = 0;
  std::size_t framing = 0;
  std::size_t counter = 0;
  std::size_t invariance = 0;
  std::size_t throughput = 0;
  std::size_t coverage = 0;
  std::size_t hang = 0;

  std::size_t total() const {
    return geometry + source + front + history + align + beamform + power +
           detection + framing + counter + invariance + throughput + coverage +
           hang;
  }

  void print() const {
    std::printf("  geometry   : %zu\n", geometry);
    std::printf("  source     : %zu\n", source);
    std::printf("  front end  : %zu\n", front);
    std::printf("  history    : %zu\n", history);
    std::printf("  alignment  : %zu\n", align);
    std::printf("  beamform   : %zu\n", beamform);
    std::printf("  power      : %zu\n", power);
    std::printf("  detection  : %zu\n", detection);
    std::printf("  framing    : %zu\n", framing);
    std::printf("  counters   : %zu\n", counter);
    std::printf("  invariance : %zu\n", invariance);
    std::printf("  throughput : %zu\n", throughput);
    std::printf("  coverage   : %zu\n", coverage);
    std::printf("  hang       : %zu\n", hang);
  }
};

inline Counters g_counters;
inline ErrorCollector* g_errors = nullptr;

inline void fail(const char* category, std::size_t* counter,
                 const std::string& msg) {
  ++*counter;
  if (g_errors != nullptr) g_errors->error(category, msg);
}

// The `RESULT:` contract every test in this repository obeys, in one place.
inline int finish(const harness::SimArgs& args, const char* test_name,
                  ErrorCollector& errors, std::uint64_t passes,
                  std::uint64_t beats, double wall_s,
                  const std::string& detail_pass,
                  const std::string& detail_fail) {
  const bool passed = g_counters.total() == 0;

  harness::RunSummary summary;
  summary.test_name = test_name;
  summary.config_name = sim_config::kName;
  summary.build_mode = args.build_mode;
  summary.seed = args.seed;
  summary.passed = passed;
  summary.stop_reason = passed ? "pass" : "error";
  summary.stop_detail = passed ? detail_pass : detail_fail;
  summary.passes = passes;
  summary.beats_observed = beats;
  summary.absorb(errors);
  summary.wall_time_s = wall_s;
  const std::string written = summary.write(args.results_dir);
  if (!written.empty()) {
    std::printf("  summary json : %s\n", written.c_str());
  }

  if (passed) {
    std::printf("RESULT: PASS seed=%llu test=%s config=%s beats=%llu\n",
                static_cast<unsigned long long>(args.seed), test_name,
                sim_config::kName, static_cast<unsigned long long>(beats));
    return 0;
  }
  std::printf(
      "RESULT: FAIL seed=%llu test=%s config=%s geometry=%zu source=%zu "
      "front=%zu history=%zu align=%zu beamform=%zu power=%zu detection=%zu "
      "framing=%zu counter=%zu invariance=%zu throughput=%zu coverage=%zu "
      "hang=%zu\n",
      static_cast<unsigned long long>(args.seed), test_name, sim_config::kName,
      g_counters.geometry, g_counters.source, g_counters.front,
      g_counters.history, g_counters.align, g_counters.beamform,
      g_counters.power, g_counters.detection, g_counters.framing,
      g_counters.counter, g_counters.invariance, g_counters.throughput,
      g_counters.coverage, g_counters.hang);
  return 1;
}

// ---------------------------------------------------------------------------
// 6. Checks shared by more than one test
// ---------------------------------------------------------------------------

// Pass 1 of every pipeline test: the DUT's own elaborated geometry against what
// the model is about to assume. An early return on failure, because every later
// comparison would be against the wrong shape.
inline bool check_geometry(Session& s, Vbenchmark_sim_top* top) {
  bool ok = true;
  const pipeline::Geometry& g = s.g();

  const std::uint32_t geo = s.read(regmap::PIPELINE_PIPE_GEOMETRY_ADDR, "geometry");
  const unsigned bin_par = (geo >> regmap::PIPELINE_PIPE_GEOMETRY_BIN_PAR_LSB) & 0xFFu;
  const unsigned groups =
      (geo >> regmap::PIPELINE_PIPE_GEOMETRY_ALIGN_GROUPS_LSB) & 0xFFu;
  const unsigned lanes = (geo >> regmap::PIPELINE_PIPE_GEOMETRY_LANES_LSB) & 0xFFu;

  if (bin_par != g.bin_par) {
    fail("geometry", &g_counters.geometry,
         "BIN_PAR: design reports " + std::to_string(bin_par) + ", model uses " +
             std::to_string(g.bin_par));
    ok = false;
  }
  if (groups != g.align_groups) {
    fail("geometry", &g_counters.geometry,
         "ALIGN_GROUPS: design reports " + std::to_string(groups));
    ok = false;
  }
  if (lanes != g.lanes) {
    fail("geometry", &g_counters.geometry,
         "LANES: design reports " + std::to_string(lanes));
    ok = false;
  }
  if (top->obs_beam_mux != 1) {
    fail("geometry", &g_counters.geometry,
         "BEAM_MUX is " + std::to_string(top->obs_beam_mux) +
             "; the bin serializer requires 1");
    ok = false;
  }

  const std::uint32_t bp = s.read(regmap::BUILD_PARAMS_N_ANTENNAS_ADDR, "n_ant");
  if (bp != g.n_ant) {
    fail("geometry", &g_counters.geometry,
         "BUILD_PARAMS.N_ANTENNAS is " + std::to_string(bp));
    ok = false;
  }
  return ok;
}

// The per-stage latency table, read out of the design rather than recomputed.
inline void print_latency(Vbenchmark_sim_top* top) {
  std::printf("  latency (from the design's own package arithmetic):\n");
  std::printf("    pfb        : %u cycles + %u beats\n",
              static_cast<unsigned>(top->obs_lat_pfb_cycles),
              static_cast<unsigned>(top->obs_lat_pfb_beats));
  std::printf("    fft        : %u beats\n",
              static_cast<unsigned>(top->obs_lat_fft_beats));
  std::printf("    history    : %u cycles (history_clk)\n",
              static_cast<unsigned>(top->obs_lat_history));
  std::printf("    alignment  : %u cycles (history_clk)\n",
              static_cast<unsigned>(top->obs_lat_align));
  std::printf("    beamformer : %u cycles\n",
              static_cast<unsigned>(top->obs_lat_beamformer));
  std::printf("    power      : %u cycles\n",
              static_cast<unsigned>(top->obs_lat_power));
}

// ---------------------------------------------------------------------------
// 7. The per-stage checks
//
// Every one of these compares a stage's OBSERVED OUTPUT against the model
// applied to that stage's OBSERVED INPUT. That is what makes a failure name a
// stage instead of naming the pipeline: if the alignment network is wrong, the
// beamformer check still passes, because it is checked against what the
// alignment network actually produced.
//
// The end-to-end check is separate and is the last one, because a set of
// individually correct stages wired together in the wrong order would pass every
// check above and must still fail.
// ---------------------------------------------------------------------------

inline std::string cx(const fxp::Complex& c) {
  return "(" + std::to_string(c.re) + "," + std::to_string(c.im) + ")";
}

// Pass: the sources produced exactly what the programmed configuration says.
// Runs before anything else in every test — see the header, 3.
inline void check_source(Session& s, const pipeline::SrcConfig& src,
                         std::size_t max_frames) {
  const pipeline::Geometry& g = s.g();
  for (unsigned a = 0; a < g.n_ant; ++a) {
    const auto& beats = s.adc_beats()[a];
    const std::size_t n_frames =
        std::min(max_frames, beats.size() / g.beats_per_frame());
    for (std::size_t f = 0; f < n_frames; ++f) {
      const std::vector<fxp::Complex> want =
          pipeline::frame_samples(g, src, a, static_cast<unsigned>(f));
      for (unsigned k = 0; k < g.beats_per_frame(); ++k) {
        const FrontBeat& b = beats[f * g.beats_per_frame() + k];
        const bool want_sof = (k == 0);
        const bool want_eof = (k + 1 == g.beats_per_frame());
        if (b.meta.sof != want_sof || b.meta.eof != want_eof) {
          fail("framing", &g_counters.framing,
               "adc antenna " + std::to_string(a) + " frame " +
                   std::to_string(f) + " beat " + std::to_string(k) +
                   ": framing is (" + std::to_string(b.meta.sof) + "," +
                   std::to_string(b.meta.eof) + ")");
          return;
        }
        if (b.meta.stream_id != a) {
          fail("framing", &g_counters.framing,
               "adc beat carries stream_id " + std::to_string(b.meta.stream_id) +
                   " on antenna " + std::to_string(a));
          return;
        }
        for (unsigned l = 0; l < g.lanes; ++l) {
          const fxp::Complex& w = want[k * g.lanes + l];
          if (b.lane[l] != w) {
            fail("source", &g_counters.source,
                 "adc antenna " + std::to_string(a) + " frame " +
                     std::to_string(f) + " sample " +
                     std::to_string(k * g.lanes + l) + ": got " + cx(b.lane[l]) +
                     " want " + cx(w));
            return;
          }
        }
      }
    }
  }
}

// The transform's output, against the polyphase model driven by the OBSERVED
// samples. Returns the natural-order bins of every complete frame, per antenna,
// which the history and alignment checks then key against.
inline std::vector<std::vector<std::vector<fxp::Complex>>> check_front_end(
    Session& s, const std::vector<fxp::Complex>& coeff, std::size_t max_frames) {
  const pipeline::Geometry& g = s.g();
  std::vector<std::vector<std::vector<fxp::Complex>>> bins;  // [frame][ant][bin]

  std::size_t n_frames = max_frames;
  for (unsigned a = 0; a < g.n_ant; ++a) {
    n_frames = std::min(n_frames, s.fft_beats()[a].size() / g.beats_per_frame());
    n_frames = std::min(n_frames, s.adc_beats()[a].size() / g.beats_per_frame());
  }
  if (n_frames == 0) return bins;

  bins.assign(n_frames, std::vector<std::vector<fxp::Complex>>(g.n_ant));

  for (unsigned a = 0; a < g.n_ant; ++a) {
    pfb::PfbModel bank(g.lanes, g.pfb_taps, coeff);
    for (std::size_t f = 0; f < n_frames; ++f) {
      // Polyphase over the beats the DUT actually admitted.
      std::vector<fxp::Complex> filtered(g.fft_size);
      for (unsigned k = 0; k < g.beats_per_frame(); ++k) {
        const FrontBeat& b = s.adc_beats()[a][f * g.beats_per_frame() + k];
        const pfb::BeatResult r = bank.step(b.lane);
        for (unsigned l = 0; l < g.lanes; ++l) {
          filtered[k * g.lanes + l] = r.y[l];
        }
      }

      fft::Config fc;
      fc.n_fft = g.fft_size;
      fc.spc = g.lanes;
      fc.reorder = false;  // benchmark_core elaborates REORDER = 0
      const fft::Result r = fft::transform(fc, filtered);
      bins[f][a] = r.bins;

      // FRAME 0 IS NOT COMPARED, and the reason is SPEC 23 rather than an
      // approximation. The polyphase delay line is a datapath array and is
      // deliberately NOT reset (\"Avoid resetting every datapath register\"), so
      // after a reset it still holds the samples of whatever ran before it,
      // while the model starts empty. The two agree from the moment the line has
      // been refilled, which is TAPS samples per branch — inside frame 0. From
      // frame 1 both have exactly the tail of frame 0 and every beat is exact.
      //
      // bins[0] is left EMPTY rather than filled with an unchecked value, so the
      // history and alignment checks skip it too instead of matching against a
      // number nobody verified.
      if (f == 0) {
        bins[0][a].clear();
        continue;
      }
      for (unsigned k = 0; k < g.beats_per_frame(); ++k) {
        const FrontBeat& b = s.fft_beats()[a][f * g.beats_per_frame() + k];
        for (unsigned l = 0; l < g.lanes; ++l) {
          const fxp::Complex& w = r.out[k * g.lanes + l];
          if (b.lane[l] != w) {
            fail("front", &g_counters.front,
                 "fft antenna " + std::to_string(a) + " frame " +
                     std::to_string(f) + " beat " + std::to_string(k) +
                     " lane " + std::to_string(l) + ": got " + cx(b.lane[l]) +
                     " want " + cx(w));
            return bins;
          }
        }
      }
    }
  }
  return bins;
}

// The corner turn: every response must be the antenna vector of its own
// (frame_id, bin), taken from the transform output the front-end check already
// validated. Keyed by the response's OWN absolute frame_id, which is the only
// field that survives rotation.
inline void check_history(
    Session& s,
    const std::vector<std::vector<std::vector<fxp::Complex>>>& bins) {
  const pipeline::Geometry& g = s.g();
  std::size_t checked = 0;
  for (const HistResponse& r : s.hist_responses()) {
    if (r.flags != 0) continue;               // a flagged response is not a value
    if (r.frame_id >= bins.size()) continue;  // outside the window we modelled
    if (bins[r.frame_id][0].empty()) continue;  // frame 0: see check_front_end
    if (r.bin >= g.fft_size) {
      fail("history", &g_counters.history,
           "response bin " + std::to_string(r.bin) + " is out of range");
      return;
    }
    for (unsigned a = 0; a < g.n_ant; ++a) {
      const fxp::Complex& w = bins[r.frame_id][a][r.bin];
      if (r.vec[a] != w) {
        fail("history", &g_counters.history,
             "frame " + std::to_string(r.frame_id) + " bin " +
                 std::to_string(r.bin) + " antenna " + std::to_string(a) +
                 ": got " + cx(r.vec[a]) + " want " + cx(w));
        return;
      }
    }
    ++checked;
  }
  if (checked == 0) {
    fail("history", &g_counters.history,
         "no history response could be checked; the read path produced nothing");
  }
}

// SPEC 7.4's whole purpose, checked directly: every lane of an output beat must
// carry the bin its position says, and every lane must be from the SAME frame.
//
// The frame is recovered rather than assumed: the beat carries no frame id (it
// does not need one — every lane agreeing is the property), so the check finds
// the set of modelled frames consistent with each lane and requires the
// intersection over the beat to be non-empty.
inline void check_alignment(
    Session& s,
    const std::vector<std::vector<std::vector<fxp::Complex>>>& bins) {
  const pipeline::Geometry& g = s.g();
  if (bins.empty()) return;

  unsigned group = 0;
  bool in_frame = false;
  std::size_t checked = 0;
  std::size_t flagged = 0;
  std::size_t unmatched = 0;

  for (const AlignBeat& b : s.align_beats()) {
    if (b.meta.sof) {
      group = 0;
      in_frame = true;
    } else if (!in_frame) {
      continue;  // a partial sweep at the start of the capture
    }

    if ((b.meta.user & 0xFu) != 0u) {
      // A flagged beat is a REPORTED defect, not a silent one, and during the
      // first sweep after the network is opened it can be legitimate: the
      // history may retire a frame between the sweep's first and last request.
      // The whole sweep is skipped rather than failed, and `check_counters`
      // fails the run if any flag survived into the measured window.
      ++flagged;
      in_frame = !b.meta.eof;
      ++group;
      continue;
    }

    // Frames consistent with this beat, lane by lane.
    std::vector<bool> ok(bins.size(), true);
    for (unsigned j = 0; j < g.bin_par; ++j) {
      const unsigned bin = pipeline::align_bin_of(g, group, j);
      if (bin >= g.fft_size) break;
      for (std::size_t f = 0; f < bins.size(); ++f) {
        if (!ok[f]) continue;
        if (bins[f][0].empty()) { ok[f] = false; continue; }
        for (unsigned a = 0; a < g.n_ant; ++a) {
          if (b.data[pipeline::align_index(g, j, a)] != bins[f][a][bin]) {
            ok[f] = false;
            break;
          }
        }
      }
    }
    if (std::find(ok.begin(), ok.end(), true) == ok.end()) {
      // Either the beat is wrong, or it came from a frame the caller did not
      // model. The two are told apart by the caller: it models every frame the
      // capture contains, so an unmatched beat inside that window is a defect
      // and one past it is arithmetic. `unmatched` is reported and the bound
      // below turns a systematic failure into a named one.
      ++unmatched;
      in_frame = !b.meta.eof;
      ++group;
      continue;
    }
    ++checked;

    const unsigned groups_per_frame = g.fft_size / g.bin_par;
    const bool want_eof = (group + 1 == groups_per_frame);
    if (b.meta.eof != want_eof) {
      fail("framing", &g_counters.framing,
           "alignment beat at group " + std::to_string(group) +
               " has eof=" + std::to_string(b.meta.eof));
      return;
    }
    if (want_eof) in_frame = false;
    ++group;
  }

  if (checked == 0) {
    fail("align", &g_counters.align,
         "no alignment beat could be checked; the network produced no complete "
         "sweep");
  }
  // A flagged beat is the frame straddle described in `check_counters`, and a
  // few per sweep are expected. A quarter of them would not be.
  if (flagged * 4 > checked) {
    fail("align", &g_counters.align,
         std::to_string(flagged) + " of " + std::to_string(flagged + checked) +
             " alignment beats were flagged; that is not a warm-up transient");
  }
  if (unmatched > checked) {
    fail("align", &g_counters.align,
         std::to_string(unmatched) + " alignment beats matched no modelled "
         "frame against " + std::to_string(checked) + " that did; their lanes "
         "are not one frame's consecutive bins");
  }
}

// The beamformer, the serializer and the power stage, each against the beat
// their own upstream actually delivered. Zipped by position, which is legal
// because every one of these stages is order-preserving and lossless — a
// property the sequence numbers below check rather than assume.
inline void check_back_end(Session& s, const std::vector<fxp::Complex>& weights) {
  const pipeline::Geometry& g = s.g();

  // SPEC 12.5: keyed by IDENTITY, not by position.
  //
  // The alignment beats are observed in history_clk and the beamformer beats in
  // core_clk with an async FIFO between them, so the two monitors are not at the
  // same point in the stream at any instant. Comparing them by index assumes the
  // crossing is empty, which it is not, and produces a mismatch on the first beat
  // that says nothing about the arithmetic. `seq` is continuous through the
  // beamformer at BEAM_MUX = 1 (beamformer_pkg: `seq_out = seq_in`), so it is the
  // key both sides already carry.
  std::map<std::uint32_t, const AlignBeat*> by_seq;
  for (const AlignBeat& b : s.align_beats()) by_seq[b.meta.seq] = &b;

  std::size_t matched = 0;
  for (const BeamBeat& out : s.beam_beats()) {
    const auto it = by_seq.find(out.meta.seq);
    if (it == by_seq.end()) continue;   // its input is outside the capture
    const AlignBeat& in = *it->second;
    ++matched;
    if (in.meta.sof != out.meta.sof || in.meta.eof != out.meta.eof) {
      fail("framing", &g_counters.framing,
           "beamformer beat seq " + std::to_string(out.meta.seq) +
               " framing does not match its input beat");
      return;
    }
    std::vector<fxp::Complex> x(g.n_ant);
    std::vector<fxp::Complex> w(g.n_ant);
    for (unsigned bm = 0; bm < g.beam_par; ++bm) {
      for (unsigned a = 0; a < g.n_ant; ++a) {
        w[a] = weights[bf::weight_index(g.n_ant, bm, a)];
      }
      for (unsigned j = 0; j < g.bin_par; ++j) {
        for (unsigned a = 0; a < g.n_ant; ++a) {
          x[a] = in.data[pipeline::align_index(g, j, a)];
        }
        const fxp::Complex want = bf::dot(x, w).y;
        const fxp::Complex got = out.data[bm * g.bin_par + j];
        if (got != want) {
          fail("beamform", &g_counters.beamform,
               "beat seq " + std::to_string(out.meta.seq) + " beam " +
                   std::to_string(bm) + " bin " + std::to_string(j) + ": got " +
                   cx(got) + " want " + cx(want));
          return;
        }
      }
    }
  }
  if (matched == 0 && !s.beam_beats().empty()) {
    fail("beamform", &g_counters.beamform,
         "no beamformer beat could be matched to an alignment beat by sequence "
         "number; the two monitors saw disjoint parts of the stream");
  }

  // The serializer: one beamformer beat becomes BIN_PAR bin beats, and bin beat
  // j carries every beam's sample at bin j of the group.
  // `seq_out = {seq_in, j}` (bin_serializer), so the serialized beat's own
  // sequence number names both the beamformer beat it came from and its position
  // inside it. The key is a slice, not a count.
  unsigned jw = 0;
  while ((1u << jw) < g.bin_par) ++jw;
  std::map<std::uint32_t, const BeamBeat*> bf_by_seq;
  for (const BeamBeat& b : s.beam_beats()) bf_by_seq[b.meta.seq] = &b;

  for (const BinBeat& out : s.bin_beats()) {
    const std::uint32_t parent = out.meta.seq >> jw;
    const unsigned j = out.meta.seq & ((1u << jw) - 1u);
    const auto it = bf_by_seq.find(parent);
    if (it == bf_by_seq.end()) continue;
    for (unsigned bm = 0; bm < g.n_beams; ++bm) {
      const fxp::Complex want = it->second->data[bm * g.bin_par + j];
      if (out.beam[bm] != want) {
        fail("beamform", &g_counters.beamform,
             "serialized beat seq " + std::to_string(out.meta.seq) + " beam " +
                 std::to_string(bm) + ": got " + cx(out.beam[bm]) + " want " +
                 cx(want));
        return;
      }
    }
  }

  // The power stage: I^2 + Q^2, exact, per beam.
  std::map<std::uint32_t, const BinBeat*> bin_by_seq;
  for (const BinBeat& b : s.bin_beats()) bin_by_seq[b.meta.seq] = &b;

  for (const PowerBeat& out : s.power_beats()) {
    const auto it = bin_by_seq.find(out.meta.seq);
    if (it == bin_by_seq.end()) continue;
    for (unsigned bm = 0; bm < g.n_beams; ++bm) {
      const std::uint64_t want =
          static_cast<std::uint64_t>(covar::power(it->second->beam[bm]));
      if (out.beam[bm] != want) {
        fail("power", &g_counters.power,
             "power beat seq " + std::to_string(out.meta.seq) + " beam " +
                 std::to_string(bm) + ": got " + std::to_string(out.beam[bm]) +
                 " want " + std::to_string(want));
        return;
      }
    }
  }
}

// The detectors, against `cfar::run_frame` driven by the power sequence the
// power stage actually produced. Every event is compared field for field and in
// order, per beam; the merge order across beams is deliberately not predicted
// (see pipeline_model.hpp 4).
inline std::size_t check_detection(Session& s, const cfar::Config& cfg,
                                   unsigned first_frame_id) {
  const pipeline::Geometry& g = s.g();

  // Group the power beats into frames.
  std::vector<std::vector<std::vector<std::uint64_t>>> frames;  // [f][beam][bin]
  std::vector<std::uint64_t> cur_bins;
  bool open = false;
  std::vector<std::vector<std::uint64_t>> cur;

  for (const PowerBeat& b : s.power_beats()) {
    if (b.meta.sof) {
      cur.assign(g.n_beams, {});
      open = true;
    }
    if (!open) continue;
    for (unsigned bm = 0; bm < g.n_beams; ++bm) cur[bm].push_back(b.beam[bm]);
    if (b.meta.eof) {
      if (cur[0].size() == g.fft_size) frames.push_back(cur);
      open = false;
    }
  }
  (void)cur_bins;

  if (frames.empty()) {
    fail("detection", &g_counters.detection,
         "no complete power frame was observed; the detectors had nothing to do");
    return 0;
  }

  // Observed events, demultiplexed by beam and split into frames at each `eof`
  // (the summary beat), which is the framing rule issue #14 states.
  std::vector<std::vector<std::vector<cfar::Event>>> obs(g.n_beams);
  for (unsigned bm = 0; bm < g.n_beams; ++bm) {
    std::vector<cfar::Event> run;
    for (const auto& e : s.events()) {
      if (e.first != bm) continue;
      run.push_back(e.second);
      if (e.second.eof) {
        obs[bm].push_back(run);
        run.clear();
      }
    }
  }

  std::size_t compared = 0;
  for (std::size_t f = 0; f < frames.size(); ++f) {
    for (unsigned bm = 0; bm < g.n_beams; ++bm) {
      if (f >= obs[bm].size()) continue;
      const std::vector<cfar::Event> want = cfar::run_frame(
          frames[f][bm], cfg, g.cfar_max_guard, g.cfar_max_ref,
          static_cast<unsigned>(first_frame_id + f));
      const std::vector<cfar::Event>& got = obs[bm][f];
      if (got.size() != want.size()) {
        fail("detection", &g_counters.detection,
             "beam " + std::to_string(bm) + " frame " + std::to_string(f) +
                 ": " + std::to_string(got.size()) + " events, model says " +
                 std::to_string(want.size()));
        return compared;
      }
      for (std::size_t i = 0; i < got.size(); ++i) {
        // `frame_id` is the detector's own copy of the input frame's `seq` at
        // its start-of-frame beat and is not predicted here: the sweep the
        // detector saw is a function of the history's rotation, not of the
        // model. Everything else is exact.
        cfar::Event w = want[i];
        w.frame_id = got[i].frame_id;
        if (got[i] != w) {
          fail("detection", &g_counters.detection,
               "beam " + std::to_string(bm) + " frame " + std::to_string(f) +
                   " event " + std::to_string(i) + ": got " + got[i].str() +
                   " want " + w.str());
          return compared;
        }
      }
      ++compared;
    }
  }
  return compared;
}

// The SPEC 9 counters, against the harness's own independent tally. A counter
// that agrees with the traffic is the only evidence that the telemetry crossing
// carried a consistent snapshot rather than a plausible one.
inline void check_counters(Session& s) {
  const pipeline::Geometry& g = s.g();

  std::uint64_t adc_beats = 0;
  for (unsigned a = 0; a < g.n_ant; ++a) adc_beats += s.adc_beats()[a].size();
  adc_beats -= std::min(adc_beats, s.epoch_adc());
  const std::size_t align_beats_obs =
      s.align_beats().size() - std::min(s.align_beats().size(), s.epoch_align());

  const std::uint32_t src_beats =
      s.read(regmap::PIPELINE_PIPE_SRC_BEATS_ADDR, "src beats");
  const std::uint32_t align_beats =
      s.read(regmap::PIPELINE_PIPE_ALIGN_BEATS_ADDR, "align beats");
  const std::uint32_t missing =
      s.read(regmap::PIPELINE_PIPE_ALIGN_MISSING_ADDR, "align missing");
  const std::uint32_t dup =
      s.read(regmap::PIPELINE_PIPE_ALIGN_DUP_ADDR, "align dup");
  const std::uint32_t orphan =
      s.read(regmap::PIPELINE_PIPE_ALIGN_ORPHAN_ADDR, "align orphan");
  const std::uint32_t timeout =
      s.read(regmap::PIPELINE_PIPE_ALIGN_TIMEOUT_ADDR, "align timeout");

  // The counters are read through a crossing and are therefore at most one
  // publication stale; the harness's tally is exact. A counter that has fallen
  // BEHIND is expected, one that has run AHEAD is a defect.
  // The counters cross into cfg_clk as one published bundle, so they are at
  // most one publication stale relative to the harness's exact tally. The
  // caller quiesces the traffic first, so what is left is that lag alone: a
  // counter BEHIND by a bounded amount is expected, one AHEAD of the traffic is
  // a defect, and one that never moved at all means the crossing is dead.
  const std::uint64_t lag = static_cast<std::uint64_t>(g.n_ant) * 64;
  if (src_beats > adc_beats) {
    fail("counter", &g_counters.counter,
         "PIPE_SRC_BEATS is " + std::to_string(src_beats) +
             " but the harness saw only " + std::to_string(adc_beats));
  }
  if (adc_beats > lag && src_beats + lag < adc_beats) {
    fail("counter", &g_counters.counter,
         "PIPE_SRC_BEATS is " + std::to_string(src_beats) +
             ", too far behind the harness's " + std::to_string(adc_beats));
  }
  if (align_beats > align_beats_obs + g.align_groups) {
    fail("counter", &g_counters.counter,
         "PIPE_ALIGN_BEATS is " + std::to_string(align_beats) +
             " but the harness saw " + std::to_string(align_beats_obs));
  }
  // DUPLICATES MUST BE ZERO. A duplicate means the same response reached the
  // same lane twice, which no legal upstream can produce and which nothing in
  // the design's arbitration can explain.
  if (dup != 0) {
    fail("align", &g_counters.align,
         "the alignment network saw " + std::to_string(dup) +
             " duplicate responses; no legal upstream can produce one");
  }

  // MISSING, ORPHAN and TIMEOUT ARE BOUNDED, NOT ZERO, and the bound is a
  // measured property of this topology rather than a tolerance.
  //
  // The corner turn resolves a RELATIVE frame offset — "frames back from the
  // newest complete frame" — at the instant each request is ACCEPTED
  // (ARCHITECTURE.md 3.4). The alignment network issues a group's BIN_PAR
  // requests in one cycle, but they reach the memory on CONSECUTIVE cycles,
  // because they are multiplexed onto one read port
  // (rtl/top/history_rd_mux.sv 1). If a frame completes in the one cycle
  // between them, the two requests resolve to two different ABSOLUTE frames;
  // the second response's `frame_id` disagrees with the entry's, and the
  // alignment network does exactly what SPEC 7.4 built it to do — it counts an
  // ORPHAN, refuses to write it over a live beat, and reports the lane as
  // MISSING when the entry times out.
  //
  // So this is the detector working, not failing. What must hold is that it
  // happens at most about once per frame completion and never silently: every
  // affected beat carries `ALGN_USER_MISSING` and is counted here. Removing it
  // entirely needs an ABSOLUTE-frame request mode on the read port, which is a
  // change to issue #15's and #16's contracts and is recorded in DECISIONS.md
  // as work for the full-scale freeze.
  const std::uint32_t straddle_bound =
      2 * s.read(regmap::HISTORY_HISTORY_FRAMES_DONE_ADDR, "frames done") + 8;
  if (missing > straddle_bound || orphan > straddle_bound ||
      timeout > straddle_bound) {
    fail("align", &g_counters.align,
         "alignment error counters exceed the frame-straddle bound of " +
             std::to_string(straddle_bound) + ": missing=" +
             std::to_string(missing) + " orphan=" + std::to_string(orphan) +
             " timeout=" + std::to_string(timeout));
  }

  const std::uint32_t status =
      s.read(regmap::PIPELINE_PIPE_ALIGN_STATUS_ADDR, "align status");
  const unsigned fault =
      (status >> regmap::PIPELINE_PIPE_ALIGN_STATUS_FAULT_LSB) & 0xFu;
  // Bit 1 is DUPLICATE and bit 3 is a history-flagged response; neither has an
  // explanation in this topology. Bits 0 and 2 — MISSING and ORPHAN — are the
  // frame straddle above and are bounded by the counter check rather than
  // forbidden here.
  if ((fault & 0b1010u) != 0) {
    fail("align", &g_counters.align,
         "PIPE_ALIGN_STATUS.FAULT reports a duplicate or a flagged history "
         "response: 0x" + std::to_string(fault));
  }

  const std::uint32_t hfault =
      s.read(regmap::HISTORY_HISTORY_FAULT_ADDR, "history fault");
  if (hfault != 0) {
    fail("history", &g_counters.history,
         "HISTORY_FAULT is 0x" + std::to_string(hfault));
  }
}

// The SPEC 7.4 multi-lane statistic, REPORTED rather than required.
//
// `test_align` fails a run in which this stayed at zero, and is right to: its
// DUT has BIN_PAR genuinely independent history read ports, so a network that
// never delivered two lanes at once was never asked to route anything.
//
// In the assembled pipeline the same number is expected to be ZERO and its being
// zero is not a gap in coverage. The BIN_PAR request ports are multiplexed onto
// the corner turn's single read port (rtl/top/history_rd_mux.sv 1), so responses
// return strictly one per cycle and two lanes cannot arrive together however the
// network is built. The routing fabric's simultaneity is exercised where the
// ports are independent — at the unit level — and what the pipeline exercises is
// the reassembly, the identity keying and the detector, which the per-beat
// checks cover directly.
//
// Reported so the number is in the log and the argument above is falsifiable: a
// build that later gives the network independent ports should see this become
// nonzero, and a reader can tell which topology produced a given run.
inline std::uint32_t report_network_simultaneity(Session& s) {
  return s.read(regmap::PIPELINE_PIPE_ALIGN_MULTI_ADDR, "align multi-lane");
}

}  // namespace pipetb

#endif  // SIM_TESTS_PIPELINE_TB_H_
