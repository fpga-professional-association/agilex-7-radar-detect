// -----------------------------------------------------------------------------
// test_covariance.cpp — power and covariance verification (issue #13; SPEC 6,
// 7.6, 13.1, 13.2, 13.3, 14).
//
// Every observable of every DUT in sim/verilator/tops/covar_top.sv is compared
// against model/cpp/covariance/covar_model.hpp ON EVERY CYCLE, bit for bit —
// not sampled at window boundaries, not compared as a summary. The model is
// cycle-accurate (one step() per clock edge), so an accumulator that is right at
// the end of a window but wrong in the middle, or a window that closes one cycle
// early, fails immediately rather than by luck.
//
// Ten passes:
//
//   1. geometry            the RTL's own cfg_* echo against this file's mirror.
//                          Nothing else runs until they agree, so a mismatch is
//                          a named failure instead of a wrong comparison.
//   2. power corners       the directed set SPEC 6 makes interesting:
//                          (-32768,-32768) — the 2^31 extreme that needs the
//                          33rd bit — zero, +/-1 on each component, +/-full
//                          scale, and the mixed-sign corners. Checked against
//                          covar::power() and against the closed-form 2^31.
//   3. power random        random samples through power_calc and the integrator
//                          behind it, dense.
//   4. windows             window lengths 1..N and reconfiguration: window_id
//                          sequencing, sample_count exactness, and the property
//                          that no result is ever short unless it is marked.
//   5. saturation          the narrow (ACC_W = 34) integrator driven past its
//                          exact bound: the clamp value, the direction flags,
//                          the sticky bit and the event counter, all against the
//                          model, plus the audit that the pass actually
//                          saturated in both directions.
//   6. exponential         COVAR_MODE_EXP at every k in 0..15, bit-exact against
//                          the model, plus the convergence property the RTL's
//                          truncation implies: y settles inside (x - 2^k, x] and
//                          never overshoots a constant target.
//   7. covariance directed X = Y gives a real Rxx equal to the power and an
//                          EXACTLY zero imaginary part; orthogonal operands give
//                          a zero real part. Both on the corners, which is where
//                          a conjugate implemented by negating y.im would fail.
//   8. covariance random   random source vectors through the whole engine, dense
//                          and again under bursty gaps, with the two runs
//                          required to produce identical result streams
//                          (backpressure invariance).
//   9. pair enable         the enable mask changed mid-run: a disabled pair must
//                          accumulate nothing and emit nothing, an enabled one
//                          must start a full-length window, and neither may
//                          produce a partial window as a side effect.
//  10. flush determinism   the same stimulus run twice — once from reset, once
//                          after a flush — required to produce byte-identical
//                          result streams including window ids. This is the
//                          operational meaning of "flush leaves the block in the
//                          post-reset state".
//
// The RTL carries its own checks in parallel: sim/assertions/covar_assertions.sv
// is instantiated inside every integrator, power_calc asserts its arithmetic
// against fxp_pkg every cycle, covar_engine asserts that a pair's two
// accumulators stay in step, and complex_multiplier asserts its own core. A
// Verilator assertion failure aborts the run, so all of those are gates on this
// test even though nothing here references them.
//
// Built by `make sim-tiny` as:
//   scripts/build_verilator.py --mode fast --top covar_top
//       --files sim/verilator/files_covar.f --test test_covariance
// -----------------------------------------------------------------------------

#include <chrono>
#include <cstdint>
#include <cstdio>
#include <deque>
#include <memory>
#include <random>
#include <string>
#include <type_traits>
#include <vector>

#include "Vcovar_top.h"
#include "verilated.h"

#include "config_sim.h"
#include "harness/error_collector.h"
#include "harness/random.h"
#include "harness/run_summary.h"
#include "harness/sim_args.h"

#include "covariance/covar_model.hpp"
#include "fxp/fxp.hpp"

using harness::ErrorCollector;
using harness::RunSummary;
using harness::SimArgs;

namespace {

constexpr const char* kTestName = "test_covariance";

// Mirror of sim/verilator/tops/covar_top.sv. Checked against the RTL's cfg_*
// echo in pass 1 before anything else runs.
constexpr unsigned kNSrc = sim_config::N_ANTENNAS;
constexpr unsigned kNPairs = sim_config::N_COVAR_PAIRS;
constexpr unsigned kAccW = covar::kPowerW;        // 40
constexpr unsigned kWindowW = covar::kWindowLenW; // 16
constexpr unsigned kNarrowAccW = covar::kTermW + 2;  // 34
constexpr unsigned kNarrowWindowW = 8;
constexpr unsigned kPowPipe = 2;
constexpr unsigned kCmultPipe = 4;

// ---------------------------------------------------------------------------
// Failure accounting. The relation that disagrees is the diagnosis, so the
// counts are kept apart rather than summed.
// ---------------------------------------------------------------------------
struct Counters {
  std::size_t config = 0;
  std::size_t power = 0;
  std::size_t integrate = 0;
  std::size_t metadata = 0;
  std::size_t saturation = 0;
  std::size_t exponential = 0;
  std::size_t cross = 0;
  std::size_t pair_enable = 0;
  std::size_t flush = 0;
  std::size_t invariance = 0;
  std::size_t coverage = 0;

  std::size_t total() const {
    return config + power + integrate + metadata + saturation + exponential +
           cross + pair_enable + flush + invariance + coverage;
  }
};

Counters g_counters;
ErrorCollector* g_errors = nullptr;

void fail(const char* category, std::size_t* counter, const std::string& msg) {
  ++*counter;
  g_errors->error(category, msg);
}

std::string cplx_str(fxp::Complex c) {
  return "(" + std::to_string(c.re) + "," + std::to_string(c.im) + ")";
}

std::string flags_str(unsigned packed) {
  return std::string((packed & 2U) ? "+" : ".") + ((packed & 1U) ? "-" : ".");
}

// Sign-extends a w-bit field out of its unsigned carrier.
fxp::wide_t sext(std::uint64_t raw, unsigned w) {
  const std::uint64_t mask = (w >= 64) ? ~0ULL : ((1ULL << w) - 1ULL);
  const std::uint64_t sign = 1ULL << (w - 1);
  return fxp::from_bits(((raw & mask) ^ sign) - sign);
}

// ---------------------------------------------------------------------------
// Everything the harness drives in one cycle, and everything it expects back.
// Keeping the stimulus in one struct is what lets every pass share one cycle
// engine, so the model and the DUT can never be stepped a different number of
// times.
// ---------------------------------------------------------------------------
struct Stim {
  // power path
  bool pw_valid = false;
  fxp::Complex pw_sample{};

  // power integrator
  covar::Config pi_cfg{};
  bool pi_flush = false;
  bool pi_sat_clear = false;

  // bare + narrow integrators (shared stimulus, own window lengths)
  bool bi_valid = false;
  fxp::wide_t bi_data = 0;
  covar::Config bi_cfg{};
  unsigned ni_window_len = 1;
  bool bi_flush = false;
  bool bi_sat_clear = false;

  // engine
  bool src_valid = false;
  std::vector<fxp::Complex> src;
  covar::Config ce_cfg{};
  std::vector<bool> pair_enable;
  bool ce_flush = false;
  bool ce_sat_clear = false;
};

// One observed window result, as read from the DUT.
struct Observed {
  fxp::wide_t acc = 0;
  unsigned window_id = 0;
  unsigned sample_count = 0;
  bool flushed = false;
  bool truncated = false;
};

std::string res_str(const covar::Result& r) {
  return "acc=" + std::to_string(r.acc) + " id=" + std::to_string(r.window_id) +
         " n=" + std::to_string(r.sample_count) +
         (r.flushed ? " flushed" : "") + (r.truncated ? " truncated" : "");
}

std::string obs_str(const Observed& o) {
  return "acc=" + std::to_string(o.acc) + " id=" + std::to_string(o.window_id) +
         " n=" + std::to_string(o.sample_count) +
         (o.flushed ? " flushed" : "") + (o.truncated ? " truncated" : "");
}

bool same(const Observed& o, const covar::Result& r) {
  return o.acc == r.acc && o.window_id == r.window_id &&
         o.sample_count == r.sample_count && o.flushed == r.flushed &&
         o.truncated == r.truncated;
}

// ---------------------------------------------------------------------------
// The device: RTL plus its cycle-accurate model twin, stepped together.
// ---------------------------------------------------------------------------
class Device {
 public:
  explicit Device(Vcovar_top* top)
      : top_(top),
        pi_(kAccW, kWindowW),
        bi_(kAccW, kWindowW),
        ni_(kNarrowAccW, kNarrowWindowW),
        eng_(kNSrc, kNPairs, kAccW, kWindowW, kCmultPipe) {
    clear_records();
  }

  // Streams of results, recorded for the passes that compare two runs.
  std::vector<Observed> pi_results, bi_results, ni_results;
  std::vector<std::vector<Observed>> ce_results_re, ce_results_im;

  covar::Engine& engine() { return eng_; }

  void clear_records() {
    pi_results.clear();
    bi_results.clear();
    ni_results.clear();
    ce_results_re.assign(kNPairs, {});
    ce_results_im.assign(kNPairs, {});
  }

  // Full reset. Drives the reset-time configuration so the model's active copy
  // and the RTL's latched copy start identical.
  void reset(const Stim& idle) {
    drive(idle);
    top_->rst_n = 0;
    for (int i = 0; i < 8; ++i) tick();
    top_->rst_n = 1;

    pi_.reset(idle.pi_cfg);
    bi_.reset(idle.bi_cfg);
    covar::Config ni_cfg = idle.bi_cfg;
    ni_cfg.window_len = idle.ni_window_len;
    ni_.reset(ni_cfg);
    eng_.reset(idle.ce_cfg);

    pow_pipe_.assign(kPowPipe, PowBeat{});
    pending_pi_.clear();
    pending_bi_.clear();
    pending_ni_.clear();
    pending_ce_.clear();

    // One idle cycle after release so every valid chain is provably clear.
    cycle(idle);
  }

  // Drive, observe, compare, step the model, tick. The whole test is this.
  void cycle(const Stim& s) {
    drive(s);
    top_->eval();

    observe();

    step_model(s);

    tick();
    ++cycles_;
  }

  void write_source(unsigned idx, fxp::Complex v, const Stim& base) {
    Stim s = base;
    s.pw_valid = false;
    s.bi_valid = false;
    s.src_valid = false;
    top_->src_wr_en = 1;
    top_->src_wr_idx = static_cast<std::uint8_t>(idx);
    top_->src_wr_re = static_cast<std::uint16_t>(v.re);
    top_->src_wr_im = static_cast<std::uint16_t>(v.im);
    cycle(s);
    top_->src_wr_en = 0;
  }

  void write_pair(unsigned idx, unsigned x, unsigned y, const Stim& base) {
    Stim s = base;
    s.pw_valid = false;
    s.bi_valid = false;
    s.src_valid = false;
    top_->pt_wr_en = 1;
    top_->pt_wr_idx = static_cast<std::uint8_t>(idx);
    top_->pt_wr_x = static_cast<std::uint8_t>(x);
    top_->pt_wr_y = static_cast<std::uint8_t>(y);
    eng_.set_table(idx, covar::PairEntry{x, y});
    cycle(s);
    top_->pt_wr_en = 0;
  }

  std::uint64_t cycles() const { return cycles_; }
  std::uint64_t observed() const { return observed_; }
  unsigned seen_sat_flags() const { return seen_sat_; }

 private:
  struct PowBeat {
    bool valid = false;
    fxp::Complex s{};
  };

  void drive(const Stim& s) {
    top_->pw_valid = s.pw_valid ? 1 : 0;
    top_->pw_re = static_cast<std::uint16_t>(s.pw_sample.re);
    top_->pw_im = static_cast<std::uint16_t>(s.pw_sample.im);

    top_->pi_window_len = static_cast<std::uint16_t>(s.pi_cfg.window_len);
    top_->pi_mode = (s.pi_cfg.mode == covar::Mode::kExp) ? 1 : 0;
    top_->pi_exp_k = static_cast<std::uint8_t>(s.pi_cfg.exp_k);
    top_->pi_enable = s.pi_cfg.enable ? 1 : 0;
    top_->pi_flush = s.pi_flush ? 1 : 0;
    top_->pi_sat_clear = s.pi_sat_clear ? 1 : 0;

    top_->bi_valid_in = s.bi_valid ? 1 : 0;
    top_->bi_data_in = fxp::bits_of(s.bi_data) & ((1ULL << kAccW) - 1ULL);
    top_->bi_window_len = static_cast<std::uint16_t>(s.bi_cfg.window_len);
    top_->bi_mode = (s.bi_cfg.mode == covar::Mode::kExp) ? 1 : 0;
    top_->bi_exp_k = static_cast<std::uint8_t>(s.bi_cfg.exp_k);
    top_->bi_enable = s.bi_cfg.enable ? 1 : 0;
    top_->bi_flush = s.bi_flush ? 1 : 0;
    top_->bi_sat_clear = s.bi_sat_clear ? 1 : 0;
    top_->ni_window_len = static_cast<std::uint8_t>(s.ni_window_len);

    top_->src_valid = s.src_valid ? 1 : 0;
    top_->ce_window_len = static_cast<std::uint16_t>(s.ce_cfg.window_len);
    top_->ce_mode = (s.ce_cfg.mode == covar::Mode::kExp) ? 1 : 0;
    top_->ce_exp_k = static_cast<std::uint8_t>(s.ce_cfg.exp_k);
    top_->ce_flush = s.ce_flush ? 1 : 0;
    top_->ce_sat_clear = s.ce_sat_clear ? 1 : 0;

    std::uint32_t mask = 0;
    for (unsigned p = 0; p < kNPairs && p < s.pair_enable.size(); ++p) {
      if (s.pair_enable[p]) mask |= (1U << p);
    }
    // The port is N_PAIRS bits wide, so its Verilated type depends on the
    // configuration (CData at tiny, IData at full scale). Assigning through a
    // std::remove_reference_t of the member keeps this line valid at every size.
    using PairMaskT = std::remove_reference_t<decltype(top_->ce_pair_enable)>;
    top_->ce_pair_enable = static_cast<PairMaskT>(mask);
  }

  void observe() {
    if (top_->pi_valid) {
      Observed o{sext(top_->pi_acc, kAccW), top_->pi_window_id, top_->pi_count,
                 top_->pi_flushed != 0, top_->pi_truncated != 0};
      pi_results.push_back(o);
      check_pending(&pending_pi_, o, "power-integrator");
    } else if (!pending_pi_.empty()) {
      fail("integrate", &g_counters.integrate,
           "power-integrator: the model expected a result the RTL did not emit ("
           + res_str(pending_pi_.front()) + ")");
      pending_pi_.clear();
    }

    if (top_->bi_valid) {
      Observed o{sext(top_->bi_acc, kAccW), top_->bi_window_id, top_->bi_count,
                 top_->bi_flushed != 0, top_->bi_truncated != 0};
      bi_results.push_back(o);
      check_pending(&pending_bi_, o, "bare-integrator");
    } else if (!pending_bi_.empty()) {
      fail("integrate", &g_counters.integrate,
           "bare-integrator: the model expected a result the RTL did not emit ("
           + res_str(pending_bi_.front()) + ")");
      pending_bi_.clear();
    }

    if (top_->ni_valid) {
      Observed o{sext(top_->ni_acc, kNarrowAccW), 0, top_->ni_count,
                 top_->ni_flushed != 0, top_->ni_truncated != 0};
      ni_results.push_back(o);
      check_pending(&pending_ni_, o, "narrow-integrator", /*ignore_id=*/true);
    } else if (!pending_ni_.empty()) {
      fail("saturation", &g_counters.saturation,
           "narrow-integrator: the model expected a result the RTL did not emit ("
           + res_str(pending_ni_.front()) + ")");
      pending_ni_.clear();
    }

    seen_sat_ |= top_->bi_sat_flags;
    seen_sat_ |= top_->ni_sat_flags;
    seen_sat_ |= top_->pi_sat_flags;

    // ---- engine, per pair through the observation mux ----------------------
    const std::uint32_t valid_mask = top_->ce_valid;
    for (unsigned p = 0; p < kNPairs; ++p) {
      const bool v = (valid_mask >> p) & 1U;
      const bool expect = p < pending_ce_.size() && pending_ce_[p].pending;
      if (!v) {
        if (expect) {
          fail("cross", &g_counters.cross,
               "pair " + std::to_string(p) +
                   ": the model expected a result the RTL did not emit");
          pending_ce_[p].pending = false;
        }
        continue;
      }
      top_->ce_sel = static_cast<std::uint8_t>(p);
      top_->eval();
      Observed ore{sext(top_->ce_acc_re, kAccW), top_->ce_window_id,
                   top_->ce_sample_count, ((top_->ce_flushed >> p) & 1U) != 0,
                   ((top_->ce_truncated >> p) & 1U) != 0};
      Observed oim = ore;
      oim.acc = sext(top_->ce_acc_im, kAccW);
      ce_results_re[p].push_back(ore);
      ce_results_im[p].push_back(oim);
      ++observed_;

      if (!expect) {
        fail("cross", &g_counters.cross,
             "pair " + std::to_string(p) +
                 ": the RTL emitted a result the model did not expect (" +
                 obs_str(ore) + ")");
        continue;
      }
      const covar::PairResult& e = pending_ce_[p].value;
      if (!same(ore, e.re)) {
        fail("cross", &g_counters.cross,
             "pair " + std::to_string(p) + " Rxy.re: RTL " + obs_str(ore) +
                 " vs model " + res_str(e.re));
      }
      if (!same(oim, e.im)) {
        fail("cross", &g_counters.cross,
             "pair " + std::to_string(p) + " Rxy.im: RTL " + obs_str(oim) +
                 " vs model " + res_str(e.im));
      }
      pending_ce_[p].pending = false;
    }
    top_->ce_sel = 0;
    top_->eval();

    // The engine's per-pair enable echo must match the model's view of which
    // pairs are admitting samples.
    for (unsigned p = 0; p < kNPairs; ++p) {
      const bool rtl_en = ((top_->ce_obs_enable >> p) & 1U) != 0;
      const bool mdl_en = eng_.re(p).active().enable;
      if (rtl_en != mdl_en) {
        fail("pair_enable", &g_counters.pair_enable,
             "pair " + std::to_string(p) + ": RTL active enable " +
                 std::to_string(rtl_en ? 1 : 0) + " vs model " +
                 std::to_string(mdl_en ? 1 : 0));
      }
    }
  }

  void check_pending(std::deque<covar::Result>* pending, const Observed& o,
                     const char* who, bool ignore_id = false) {
    ++observed_;
    if (pending->empty()) {
      fail("integrate", &g_counters.integrate,
           std::string(who) + ": the RTL emitted a result the model did not "
                              "expect (" + obs_str(o) + ")");
      return;
    }
    covar::Result e = pending->front();
    pending->pop_front();
    if (ignore_id) e.window_id = o.window_id;
    if (!same(o, e)) {
      fail("integrate", &g_counters.integrate,
           std::string(who) + ": RTL " + obs_str(o) + " vs model " + res_str(e));
    }
  }

  void step_model(const Stim& s) {
    // ---- power_calc ---------------------------------------------------------
    const PowBeat landed = pow_pipe_.front();
    pow_pipe_.erase(pow_pipe_.begin());
    pow_pipe_.push_back(PowBeat{s.pw_valid, s.pw_sample});

    if (landed.valid) {
      const fxp::wide_t exp = covar::power(landed.s);
      const fxp::wide_t got = sext(top_->pow_value, kAccW);
      if (top_->pow_valid == 0) {
        fail("power", &g_counters.power,
             "power_calc: expected a valid output for " + cplx_str(landed.s));
      } else if (got != exp) {
        fail("power", &g_counters.power,
             "power_calc " + cplx_str(landed.s) + ": RTL " +
                 std::to_string(got) + " vs model " + std::to_string(exp));
      }
      if (exp < 0 || exp > (fxp::wide_t{1} << 31)) {
        fail("power", &g_counters.power,
             "model power out of [0, 2^31] for " + cplx_str(landed.s));
      }
    } else if (top_->pow_valid != 0) {
      fail("power", &g_counters.power,
           "power_calc: unexpected valid output");
    }

    covar::Result r{};
    if (pi_.step(s.pi_cfg, landed.valid, landed.valid ? covar::power(landed.s) : 0,
                 s.pi_flush, s.pi_sat_clear, &r)) {
      pending_pi_.push_back(r);
    }

    // ---- bare and narrow integrators ---------------------------------------
    if (bi_.step(s.bi_cfg, s.bi_valid, s.bi_data, s.bi_flush, s.bi_sat_clear,
                 &r)) {
      pending_bi_.push_back(r);
    }
    covar::Config ni_cfg = s.bi_cfg;
    ni_cfg.window_len = s.ni_window_len;
    const fxp::wide_t ni_data = sext(fxp::bits_of(s.bi_data), kNarrowAccW);
    if (ni_.step(ni_cfg, s.bi_valid, ni_data, s.bi_flush, s.bi_sat_clear, &r)) {
      pending_ni_.push_back(r);
    }

    // ---- engine -------------------------------------------------------------
    const std::vector<covar::PairResult> pr =
        eng_.step(s.ce_cfg, s.pair_enable, s.src_valid, s.src, s.ce_flush,
                  s.ce_sat_clear);
    pending_ce_.assign(kNPairs, PendingPair{});
    for (unsigned p = 0; p < kNPairs; ++p) {
      if (pr[p].valid != pr[p].valid_im) {
        fail("cross", &g_counters.cross,
             "model pair " + std::to_string(p) +
                 ": the two accumulators disagree on when to emit");
      }
      pending_ce_[p].pending = pr[p].valid;
      pending_ce_[p].value = pr[p];
    }
  }

  void tick() {
    top_->clk = 0;
    top_->eval();
    top_->clk = 1;
    top_->eval();
  }

  struct PendingPair {
    bool pending = false;
    covar::PairResult value{};
  };

  Vcovar_top* top_;
  covar::Integrator pi_, bi_, ni_;
  covar::Engine eng_;
  std::vector<PowBeat> pow_pipe_;
  std::deque<covar::Result> pending_pi_, pending_bi_, pending_ni_;
  std::vector<PendingPair> pending_ce_;
  std::uint64_t cycles_ = 0;
  std::uint64_t observed_ = 0;
  unsigned seen_sat_ = 0;
};

// ---------------------------------------------------------------------------
// A quiescent stimulus: everything off, a legal configuration everywhere.
// ---------------------------------------------------------------------------
Stim idle_stim() {
  Stim s;
  s.pi_cfg = covar::Config{4, covar::Mode::kBlock, 0, true};
  s.bi_cfg = covar::Config{4, covar::Mode::kBlock, 0, true};
  s.ce_cfg = covar::Config{4, covar::Mode::kBlock, 0, true};
  s.ni_window_len = 4;
  s.src.assign(kNSrc, fxp::Complex{});
  s.pair_enable.assign(kNPairs, true);
  return s;
}

// Drains every pipeline: enough idle cycles for the deepest one.
void drain(Device* dev, const Stim& base, unsigned extra = 0) {
  Stim s = base;
  s.pw_valid = false;
  s.bi_valid = false;
  s.src_valid = false;
  s.pi_flush = false;
  s.bi_flush = false;
  s.ce_flush = false;
  for (unsigned i = 0; i < kCmultPipe + kPowPipe + 4 + extra; ++i) dev->cycle(s);
}

// ---------------------------------------------------------------------------
// Pass 1 — geometry
// ---------------------------------------------------------------------------
void pass_geometry(Vcovar_top* top) {
  struct Item {
    const char* name;
    unsigned rtl;
    unsigned mirror;
  };
  const Item items[] = {
      {"N_SRC", top->cfg_n_src, kNSrc},
      {"N_PAIRS", top->cfg_n_pairs, kNPairs},
      {"POWER_W", top->cfg_power_w, covar::kPowerW},
      {"ACC_W", top->cfg_acc_w, kAccW},
      {"WINDOW_W", top->cfg_window_w, kWindowW},
      {"SEL_W", top->cfg_sel_w, covar::kSelW},
      {"EXP_K_W", top->cfg_exp_k_w, covar::kExpKW},
      {"POW_PIPE", top->cfg_pow_pipe, kPowPipe},
      {"CMULT_PIPE", top->cfg_cmult_pipe, kCmultPipe},
      {"NARROW_ACC_W", top->cfg_narrow_acc_w, kNarrowAccW},
      {"NARROW_WINDOW_W", top->cfg_narrow_window_w, kNarrowWindowW},
  };
  for (const Item& i : items) {
    if (i.rtl != i.mirror) {
      fail("config", &g_counters.config,
           std::string("geometry: RTL ") + i.name + " = " +
               std::to_string(i.rtl) + " but this test mirrors " +
               std::to_string(i.mirror));
    }
  }

  // The exact-window bound is the load-bearing number of the whole design
  // (covar_pkg section 1). The RTL computes it with covar_window_max_exact();
  // the model computes it independently; both must say 255 at POWER_W = 40 and
  // 3 at the narrow width.
  const std::uint64_t rtl_exact = top->cfg_win_exact_max;
  const std::uint64_t mdl_exact = covar::window_max_exact(kAccW);
  if (rtl_exact != mdl_exact || mdl_exact != 255) {
    fail("config", &g_counters.config,
         "exact window bound: RTL " + std::to_string(rtl_exact) + ", model " +
             std::to_string(mdl_exact) + ", expected 255 at POWER_W=40");
  }
  const std::uint64_t rtl_narrow = top->cfg_narrow_win_exact_max;
  const std::uint64_t mdl_narrow = covar::window_max_exact(kNarrowAccW);
  if (rtl_narrow != mdl_narrow || mdl_narrow != 3) {
    fail("config", &g_counters.config,
         "narrow exact window bound: RTL " + std::to_string(rtl_narrow) +
             ", model " + std::to_string(mdl_narrow) + ", expected 3");
  }
  // The inverse function must agree with the forward one at the bound and one
  // past it.
  if (covar::acc_w_required(255) != 40 || covar::acc_w_required(256) != 41) {
    fail("config", &g_counters.config,
         "acc_w_required disagrees with window_max_exact at the boundary");
  }
}

// ---------------------------------------------------------------------------
// Pass 2 — power corners
// ---------------------------------------------------------------------------
const std::vector<fxp::Complex>& power_corners() {
  static const std::vector<fxp::Complex> v = {
      {0, 0},          {1, 0},          {0, 1},         {-1, 0},
      {0, -1},         {1, 1},          {-1, -1},       {1, -1},
      {-1, 1},         {32767, 0},      {0, 32767},     {32767, 32767},
      {-32768, 0},     {0, -32768},     {-32768, -32768},
      {-32768, 32767}, {32767, -32768}, {16384, 16384}, {-16384, 16384},
  };
  return v;
}

void pass_power_corners(Device* dev) {
  Stim s = idle_stim();
  s.pi_cfg.enable = false;  // isolate power_calc from the integrator here
  dev->reset(s);

  for (const fxp::Complex& c : power_corners()) {
    s.pw_valid = true;
    s.pw_sample = c;
    dev->cycle(s);
  }
  s.pw_valid = false;
  drain(dev, s);

  // The one closed-form claim in the whole block, checked directly rather than
  // only through the model: the extreme sample is exactly 2^31.
  if (covar::power(fxp::Complex{-32768, -32768}) != (fxp::wide_t{1} << 31)) {
    fail("power", &g_counters.power,
         "the model does not give 2^31 for (-32768,-32768)");
  }
  if (covar::power(fxp::Complex{0, 0}) != 0) {
    fail("power", &g_counters.power, "the model does not give 0 for (0,0)");
  }
  if (covar::power(fxp::Complex{1, 0}) != 1 ||
      covar::power(fxp::Complex{-1, 0}) != 1) {
    fail("power", &g_counters.power,
         "the model does not give 1 for a unit LSB in either sign");
  }
}

// ---------------------------------------------------------------------------
// Pass 3 — power through the integrator, random
// ---------------------------------------------------------------------------
fxp::i16 draw_q15(std::mt19937_64& rng) {
  // Corner-biased, exactly as the complex-multiplier test draws: a uniform draw
  // essentially never produces the endpoints, which are the interesting inputs.
  const std::uint64_t r = harness::uniform_u64(rng, 0, 99);
  if (r < 8) return fxp::q15_min();
  if (r < 16) return fxp::q15_max();
  if (r < 20) return 0;
  if (r < 24) return static_cast<fxp::i16>(harness::uniform_u64(rng, 0, 1) ? 1 : -1);
  return static_cast<fxp::i16>(
      static_cast<std::int32_t>(harness::uniform_u64(rng, 0, 65535)) - 32768);
}

fxp::Complex draw_sample(std::mt19937_64& rng) {
  return fxp::Complex{draw_q15(rng), draw_q15(rng)};
}

void pass_power_integrated(Device* dev, std::mt19937_64 rng) {
  Stim s = idle_stim();
  s.pi_cfg = covar::Config{7, covar::Mode::kBlock, 0, true};
  dev->reset(s);

  for (unsigned i = 0; i < 600; ++i) {
    s.pw_valid = true;
    s.pw_sample = draw_sample(rng);
    dev->cycle(s);
  }
  s.pw_valid = false;
  drain(dev, s);
}

// ---------------------------------------------------------------------------
// Pass 4 — window boundaries and reconfiguration
// ---------------------------------------------------------------------------
void pass_windows(Device* dev, std::mt19937_64 rng) {
  Stim s = idle_stim();
  s.bi_cfg = covar::Config{1, covar::Mode::kBlock, 0, true};
  s.ni_window_len = 1;
  dev->reset(s);

  const unsigned lengths[] = {1, 2, 3, 5, 8, 1, 16, 4};
  for (unsigned len : lengths) {
    // Reconfigure between windows, then drive an exact multiple of the length
    // plus a couple more, so the boundary is crossed and the sequencing is
    // visible.
    s.bi_cfg.window_len = len;
    s.ni_window_len = (len > 255) ? 255 : len;
    for (unsigned i = 0; i < 3 * len + 2; ++i) {
      s.bi_valid = true;
      s.bi_data = static_cast<fxp::wide_t>(
          static_cast<std::int64_t>(harness::uniform_u64(rng, 0, 1000000)) -
          500000);
      dev->cycle(s);
    }
    s.bi_valid = false;
    // Flush what is left, so the next length starts from a known state and the
    // partial window is emitted with its marker rather than silently dropped.
    s.bi_flush = true;
    dev->cycle(s);
    s.bi_flush = false;
    drain(dev, s);
  }

  // A reconfiguration written MID-window must not take effect until the window
  // closes. Drive three of a four-long window, change the length to one, and
  // require the running window to still close at four.
  s.bi_cfg.window_len = 4;
  s.ni_window_len = 4;
  drain(dev, s);
  for (unsigned i = 0; i < 3; ++i) {
    s.bi_valid = true;
    s.bi_data = 100 + i;
    dev->cycle(s);
  }
  s.bi_cfg.window_len = 1;  // must NOT apply yet
  s.ni_window_len = 1;
  s.bi_valid = true;
  s.bi_data = 103;
  dev->cycle(s);  // this is the fourth sample: the window closes at four
  s.bi_valid = false;
  drain(dev, s);
}

// ---------------------------------------------------------------------------
// Pass 5 — accumulator saturation and the sticky flag
// ---------------------------------------------------------------------------
void pass_saturation(Device* dev) {
  Stim s = idle_stim();
  // The narrow integrator is 34 bits: its exact bound is 3 samples of 2^31.
  // A window of 8 maximum-magnitude terms therefore clamps, in both directions.
  s.bi_cfg = covar::Config{8, covar::Mode::kBlock, 0, true};
  s.ni_window_len = 8;
  dev->reset(s);

  const fxp::wide_t kMax = fxp::wide_t{1} << 31;   // +2^31, the extreme term
  for (int sign = 0; sign < 2; ++sign) {
    const fxp::wide_t term = (sign == 0) ? kMax : -kMax;
    for (unsigned i = 0; i < 8; ++i) {
      s.bi_valid = true;
      s.bi_data = term;
      dev->cycle(s);
    }
    s.bi_valid = false;
    drain(dev, s);
  }

  // The clamp value itself, stated independently of the model: a signed 34-bit
  // field clamps at +2^33 - 1 and -2^33.
  if (fxp::sat(fxp::wide_t{1} << 40, kNarrowAccW) !=
      (fxp::wide_t{1} << (kNarrowAccW - 1)) - 1) {
    fail("saturation", &g_counters.saturation,
         "fxp::sat does not clamp to +2^33 - 1 at 34 bits");
  }

  // Now the WIDE accumulator at its own bound: 256 extreme terms is exactly one
  // LSB past what POWER_W = 40 holds (covar_pkg section 1), so this is the
  // cheapest proof that the documented bound is the real one.
  s.bi_cfg = covar::Config{256, covar::Mode::kBlock, 0, true};
  s.ni_window_len = 255;
  s.bi_sat_clear = true;
  dev->cycle(s);
  s.bi_sat_clear = false;
  for (unsigned i = 0; i < 256; ++i) {
    s.bi_valid = true;
    s.bi_data = kMax;
    dev->cycle(s);
  }
  s.bi_valid = false;
  drain(dev, s);

  if (dev->bi_results.empty()) {
    fail("saturation", &g_counters.saturation,
         "the 256-sample window produced no result");
  } else {
    const Observed& last = dev->bi_results.back();
    const fxp::wide_t expect = (fxp::wide_t{1} << (kAccW - 1)) - 1;
    if (last.acc != expect) {
      fail("saturation", &g_counters.saturation,
           "256 extreme terms should clamp to 2^39 - 1 = " +
               std::to_string(expect) + ", got " + std::to_string(last.acc));
    }
  }
  if (dev->seen_sat_flags() == 0) {
    fail("saturation", &g_counters.saturation,
         "the saturation pass never set a sticky flag");
  }

  // And 255 must NOT saturate: the bound is exact, not approximate.
  s.bi_sat_clear = true;
  dev->cycle(s);
  s.bi_sat_clear = false;
  s.bi_cfg.window_len = 255;
  drain(dev, s);
  for (unsigned i = 0; i < 255; ++i) {
    s.bi_valid = true;
    s.bi_data = kMax;
    dev->cycle(s);
  }
  s.bi_valid = false;
  drain(dev, s);
  if (!dev->bi_results.empty()) {
    const Observed& last = dev->bi_results.back();
    if (last.acc != 255 * kMax) {
      fail("saturation", &g_counters.saturation,
           "255 extreme terms must sum exactly to 255 * 2^31 = " +
               std::to_string(255 * kMax) + ", got " +
               std::to_string(last.acc));
    }
  }
}

// ---------------------------------------------------------------------------
// Pass 6 — exponential averaging
// ---------------------------------------------------------------------------
void pass_exponential(Device* dev) {
  // Every k is checked BIT-EXACTLY against the model by the per-cycle compare
  // that runs inside Device::cycle, whatever the sample budget. The convergence
  // property below is a different claim and needs the filter to have actually
  // settled, which takes O(2^k) samples — so it is asserted for the shifts a
  // test can settle in a bounded number of cycles (k <= kConvergeKMax) and the
  // remaining shifts are covered by the bit-exact comparison alone. Claiming
  // convergence for k = 15 inside a two-minute test would be claiming something
  // the run never observed.
  constexpr unsigned kConvergeKMax = 6;

  for (unsigned k = 0; k <= covar::kExpKMax; ++k) {
    Stim s = idle_stim();
    s.bi_cfg = covar::Config{4, covar::Mode::kExp, k, true};
    s.ni_window_len = 4;
    dev->reset(s);

    const bool converge = (k <= kConvergeKMax);
    // 30 time constants is comfortably past the point where the integer
    // recursion reaches its fixed set.
    const unsigned n = converge ? (30u << k) + 64u : 64u;

    // Rise from zero to a constant target, then fall to a lower one. The model
    // comparison is bit-exact on every cycle; what is checked HERE is the
    // convergence property the truncation implies (integrator.sv section 4).
    const fxp::wide_t target_hi = 1 << 20;
    const fxp::wide_t target_lo = -(1 << 18);

    for (unsigned i = 0; i < n; ++i) {
      s.bi_valid = true;
      s.bi_data = target_hi;
      dev->cycle(s);
    }
    s.bi_valid = false;
    drain(dev, s);

    const fxp::wide_t y_hi = dev->bi_results.empty()
                                 ? 0
                                 : dev->bi_results.back().acc;
    const fxp::wide_t quantum = fxp::wide_t{1} << k;
    if (converge && (y_hi > target_hi || y_hi <= target_hi - quantum)) {
      fail("exponential", &g_counters.exponential,
           "k=" + std::to_string(k) + ": rising convergence settled at " +
               std::to_string(y_hi) + ", outside (target - 2^k, target] = (" +
               std::to_string(target_hi - quantum) + ", " +
               std::to_string(target_hi) + "]");
    }

    for (unsigned i = 0; i < 2u * n; ++i) {
      s.bi_valid = true;
      s.bi_data = target_lo;
      dev->cycle(s);
    }
    s.bi_valid = false;
    drain(dev, s);

    const fxp::wide_t y_lo = dev->bi_results.back().acc;
    if (converge && (y_lo > target_lo || y_lo <= target_lo - quantum)) {
      fail("exponential", &g_counters.exponential,
           "k=" + std::to_string(k) + ": falling convergence settled at " +
               std::to_string(y_lo) + ", outside (target - 2^k, target]");
    }
    // k = 0 is a pass-through, and that must be exact rather than nearly so.
    if (k == 0 && y_lo != target_lo) {
      fail("exponential", &g_counters.exponential,
           "k=0 must track the input exactly; got " + std::to_string(y_lo));
    }
  }
}

// ---------------------------------------------------------------------------
// Pass 7 — covariance directed
// ---------------------------------------------------------------------------
void pass_cross_directed(Device* dev) {
  Stim s = idle_stim();
  s.ce_cfg = covar::Config{1, covar::Mode::kBlock, 0, true};
  dev->reset(s);

  // Pair 0 watches (0, 0) — an autocorrelation. Pair 1, when it exists, watches
  // (0, 1). Anything beyond that repeats pair 0's assignment; the table is
  // programmable, so the geometry of the tiny build does not limit the test.
  dev->write_pair(0, 0, 0, s);
  for (unsigned p = 1; p < kNPairs; ++p) {
    dev->write_pair(p, 0, (kNSrc > 1) ? 1U : 0U, s);
  }
  // The table latches on flush (covar_engine section 4).
  s.ce_flush = true;
  dev->cycle(s);
  s.ce_flush = false;
  drain(dev, s);

  for (const fxp::Complex& c : power_corners()) {
    // X = Y on every source, so every pair is an autocorrelation this round.
    for (unsigned i = 0; i < kNSrc; ++i) dev->write_source(i, c, s);
    Stim t = s;
    t.src.assign(kNSrc, c);
    t.src_valid = true;
    dev->cycle(t);
    s.src = t.src;
    drain(dev, s);

    // Rxx must be exactly the power, with a zero imaginary part. This is the
    // property that a conjugate implemented by negating y.im gets wrong at
    // y.im = -32768, which is why the corner list contains it.
    const covar::Cross direct = covar::cross_power_direct(c, c);
    const covar::Cross swap = covar::cross_power_swap(c, c);
    if (direct != swap) {
      fail("cross", &g_counters.cross,
           "the model's two cross-power paths disagree at " + cplx_str(c));
    }
    if (direct.re != covar::power(c) || direct.im != 0) {
      fail("cross", &g_counters.cross,
           "Rxx at " + cplx_str(c) + " is (" + std::to_string(direct.re) + "," +
               std::to_string(direct.im) + "), expected (" +
               std::to_string(covar::power(c)) + ",0)");
    }
  }

  // Orthogonal operands: X = (a, 0), Y = (0, b) gives Rxy = (0, -a*b)... i.e. a
  // purely imaginary cross-power. Checked in the model and driven through the
  // RTL, where the per-cycle comparison does the rest.
  if (kNSrc > 1) {
    const fxp::Complex x{20000, 0};
    const fxp::Complex y{0, 30000};
    const covar::Cross c = covar::cross_power(x, y);
    if (c.re != 0) {
      fail("cross", &g_counters.cross,
           "orthogonal operands must give a zero real cross-power, got " +
               std::to_string(c.re));
    }
    dev->write_source(0, x, s);
    dev->write_source(1, y, s);
    Stim t = s;
    t.src[0] = x;
    t.src[1] = y;
    t.src_valid = true;
    dev->cycle(t);
    s.src = t.src;
    drain(dev, s);
  }
}

// ---------------------------------------------------------------------------
// Pass 8 — covariance random, dense and gapped (backpressure invariance)
// ---------------------------------------------------------------------------
std::vector<std::vector<Observed>> run_cross_random(Device* dev,
                                                    std::mt19937_64 rng,
                                                    bool gapped,
                                                    std::mt19937_64 gap_rng) {
  harness::BackpressureGenerator gaps(gap_rng,
                                      harness::BackpressureConfig::bursty());
  Stim s = idle_stim();
  s.ce_cfg = covar::Config{5, covar::Mode::kBlock, 0, true};
  dev->reset(s);
  for (unsigned p = 0; p < kNPairs; ++p) {
    dev->write_pair(p, p % kNSrc, (p + 1) % kNSrc, s);
  }
  s.ce_flush = true;
  dev->cycle(s);
  s.ce_flush = false;
  drain(dev, s);
  dev->clear_records();

  for (unsigned beat = 0; beat < 400; ++beat) {
    std::vector<fxp::Complex> v(kNSrc);
    for (unsigned i = 0; i < kNSrc; ++i) v[i] = draw_sample(rng);
    for (unsigned i = 0; i < kNSrc; ++i) dev->write_source(i, v[i], s);
    s.src = v;

    if (gapped) {
      while (!gaps.allow()) {
        Stim t = s;
        t.src_valid = false;
        dev->cycle(t);
      }
    }
    Stim t = s;
    t.src_valid = true;
    dev->cycle(t);
  }
  drain(dev, s, 8);
  return dev->ce_results_re;
}

// ---------------------------------------------------------------------------
// Pass 9 — runtime pair enable
// ---------------------------------------------------------------------------
void pass_pair_enable(Device* dev, std::mt19937_64 rng) {
  if (kNPairs < 2) return;

  Stim s = idle_stim();
  s.ce_cfg = covar::Config{4, covar::Mode::kBlock, 0, true};
  dev->reset(s);
  for (unsigned p = 0; p < kNPairs; ++p) {
    dev->write_pair(p, p % kNSrc, (p + 1) % kNSrc, s);
  }
  s.ce_flush = true;
  dev->cycle(s);
  s.ce_flush = false;
  drain(dev, s);
  dev->clear_records();

  // Start with pair 1 disabled.
  s.pair_enable.assign(kNPairs, true);
  s.pair_enable[1] = false;

  for (unsigned beat = 0; beat < 120; ++beat) {
    // Flip the mask twice, mid-window both times, so the "takes effect at the
    // next boundary" rule is exercised rather than assumed.
    if (beat == 37) s.pair_enable[1] = true;
    if (beat == 74) s.pair_enable[0] = false;

    std::vector<fxp::Complex> v(kNSrc);
    for (unsigned i = 0; i < kNSrc; ++i) v[i] = draw_sample(rng);
    for (unsigned i = 0; i < kNSrc; ++i) dev->write_source(i, v[i], s);
    s.src = v;
    Stim t = s;
    t.src_valid = true;
    dev->cycle(t);
  }
  drain(dev, s, 8);

  // Pair 0 was disabled for the last third and pair 1 for the first third, so
  // both must have produced strictly fewer windows than a pair that ran the
  // whole time. Pair 2 is that reference when the configuration has one; with
  // only two pairs there is no always-on channel and the weaker claim — that a
  // re-enabled pair produces windows again at all — is what is available.
  const std::size_t n0 = dev->ce_results_re[0].size();
  const std::size_t n1 = dev->ce_results_re[1].size();
  if (kNPairs >= 3) {
    const std::size_t nref = dev->ce_results_re[2].size();
    if (n0 >= nref) {
      fail("pair_enable", &g_counters.pair_enable,
           "pair 0 was disabled for the last third of the run but produced " +
               std::to_string(n0) + " windows against the always-on pair's " +
               std::to_string(nref));
    }
    if (n1 >= nref) {
      fail("pair_enable", &g_counters.pair_enable,
           "pair 1 was disabled for the first third of the run but produced " +
               std::to_string(n1) + " windows against the always-on pair's " +
               std::to_string(nref));
    }
  }
  if (n1 == 0) {
    fail("pair_enable", &g_counters.pair_enable,
         "pair 1 was re-enabled mid-run but never produced a window");
  }
  for (unsigned p = 0; p < kNPairs; ++p) {
    for (const Observed& o : dev->ce_results_re[p]) {
      if (o.truncated && !o.flushed) {
        fail("pair_enable", &g_counters.pair_enable,
             "pair " + std::to_string(p) +
                 " produced a partial window that was not a flush");
      }
    }
  }
}

// ---------------------------------------------------------------------------
// Pass 10 — flush determinism
// ---------------------------------------------------------------------------
std::vector<Observed> run_flush_program(Device* dev, std::mt19937_64 rng,
                                        bool preload) {
  Stim s = idle_stim();
  s.bi_cfg = covar::Config{6, covar::Mode::kBlock, 0, true};
  s.ni_window_len = 3;
  dev->reset(s);

  if (preload) {
    // Dirty the state: partial window, non-zero accumulator, advanced window id,
    // sticky flags set. Then flush.
    for (unsigned i = 0; i < 47; ++i) {
      s.bi_valid = true;
      s.bi_data = fxp::wide_t{1} << 31;
      dev->cycle(s);
    }
    s.bi_valid = false;
    s.bi_flush = true;
    dev->cycle(s);
    s.bi_flush = false;
    drain(dev, s);
  }

  dev->clear_records();
  for (unsigned i = 0; i < 100; ++i) {
    s.bi_valid = true;
    s.bi_data = static_cast<fxp::wide_t>(
        static_cast<std::int64_t>(harness::uniform_u64(rng, 0, 2000000)) -
        1000000);
    dev->cycle(s);
  }
  s.bi_valid = false;
  drain(dev, s);
  return dev->bi_results;
}

}  // namespace

// -----------------------------------------------------------------------------
// Entry point
// -----------------------------------------------------------------------------
int harness::sim_test_main(const SimArgs& args) {
  const auto wall_start = std::chrono::steady_clock::now();

  ErrorCollector errors;
  g_errors = &errors;
  g_counters = Counters{};

  auto top = std::make_unique<Vcovar_top>();
  const SeedSource seeds(args.seed);

  // ---- pass 1: geometry ----------------------------------------------------
  top->eval();
  pass_geometry(top.get());
  if (g_counters.config != 0) {
    std::printf("RESULT: FAIL seed=%llu test=%s config=%s reason=geometry\n",
                static_cast<unsigned long long>(args.seed), kTestName,
                sim_config::kName);
    return 1;
  }

  Device dev(top.get());

  // ---- passes 2..7 ---------------------------------------------------------
  pass_power_corners(&dev);
  pass_power_integrated(&dev, seeds.engine("covar.power"));
  pass_windows(&dev, seeds.engine("covar.window"));
  pass_saturation(&dev);
  pass_exponential(&dev);
  pass_cross_directed(&dev);

  // ---- pass 8: random, dense vs gapped ------------------------------------
  const std::vector<std::vector<Observed>> dense =
      run_cross_random(&dev, seeds.engine("covar.cross"), false,
                       seeds.engine("covar.gaps"));
  const std::vector<std::vector<Observed>> gapped =
      run_cross_random(&dev, seeds.engine("covar.cross"), true,
                       seeds.engine("covar.gaps"));

  for (unsigned p = 0; p < kNPairs; ++p) {
    if (dense[p].size() != gapped[p].size()) {
      fail("invariance", &g_counters.invariance,
           "pair " + std::to_string(p) + ": dense produced " +
               std::to_string(dense[p].size()) + " windows, gapped " +
               std::to_string(gapped[p].size()));
      continue;
    }
    for (std::size_t i = 0; i < dense[p].size(); ++i) {
      if (!(dense[p][i].acc == gapped[p][i].acc &&
            dense[p][i].window_id == gapped[p][i].window_id &&
            dense[p][i].sample_count == gapped[p][i].sample_count)) {
        fail("invariance", &g_counters.invariance,
             "pair " + std::to_string(p) + " window " + std::to_string(i) +
                 ": dense " + obs_str(dense[p][i]) + " vs gapped " +
                 obs_str(gapped[p][i]));
        break;
      }
    }
  }
  if (dense[0].empty()) {
    fail("coverage", &g_counters.coverage,
         "the random cross-power pass produced no windows at all");
  }

  // ---- pass 9: pair enable -------------------------------------------------
  pass_pair_enable(&dev, seeds.engine("covar.enable"));

  // ---- pass 10: flush determinism -----------------------------------------
  const std::vector<Observed> fresh =
      run_flush_program(&dev, seeds.engine("covar.flush"), false);
  const std::vector<Observed> after_flush =
      run_flush_program(&dev, seeds.engine("covar.flush"), true);

  if (fresh.size() != after_flush.size()) {
    fail("flush", &g_counters.flush,
         "a fresh start produced " + std::to_string(fresh.size()) +
             " windows, a post-flush start " +
             std::to_string(after_flush.size()));
  } else {
    for (std::size_t i = 0; i < fresh.size(); ++i) {
      if (!(fresh[i].acc == after_flush[i].acc &&
            fresh[i].window_id == after_flush[i].window_id &&
            fresh[i].sample_count == after_flush[i].sample_count &&
            fresh[i].flushed == after_flush[i].flushed &&
            fresh[i].truncated == after_flush[i].truncated)) {
        fail("flush", &g_counters.flush,
             "window " + std::to_string(i) + ": fresh " + obs_str(fresh[i]) +
                 " vs post-flush " + obs_str(after_flush[i]));
        break;
      }
    }
  }
  if (fresh.empty()) {
    fail("coverage", &g_counters.coverage,
         "the flush-determinism pass produced no windows to compare");
  }

  // ---- coverage audit ------------------------------------------------------
  // A saturation test that never saturated proves nothing.
  if ((dev.seen_sat_flags() & 2U) == 0 || (dev.seen_sat_flags() & 1U) == 0) {
    fail("coverage", &g_counters.coverage,
         std::string("the run never observed both saturation directions (") +
             flags_str(dev.seen_sat_flags()) + ")");
  }

  const bool passed = g_counters.total() == 0;

  std::printf("--- power and covariance ---\n");
  std::printf("  geometry         : %u sources, %u pairs, ACC_W %u, exact window %llu\n",
              kNSrc, kNPairs, kAccW,
              static_cast<unsigned long long>(covar::window_max_exact(kAccW)));
  std::printf("  cycles           : %llu\n",
              static_cast<unsigned long long>(dev.cycles()));
  std::printf("  window results   : %llu checked against the C++ model\n",
              static_cast<unsigned long long>(dev.observed()));
  std::printf("  saturation seen  : %s\n", flags_str(dev.seen_sat_flags()).c_str());
  std::printf("  power            : %zu\n", g_counters.power);
  std::printf("  integration      : %zu\n", g_counters.integrate);
  std::printf("  metadata         : %zu\n", g_counters.metadata);
  std::printf("  saturation       : %zu\n", g_counters.saturation);
  std::printf("  exponential      : %zu\n", g_counters.exponential);
  std::printf("  cross power      : %zu\n", g_counters.cross);
  std::printf("  pair enable      : %zu\n", g_counters.pair_enable);
  std::printf("  flush            : %zu\n", g_counters.flush);
  std::printf("  invariance       : %zu\n", g_counters.invariance);
  std::printf("  coverage         : %zu\n", g_counters.coverage);
  std::printf("  config           : %zu\n", g_counters.config);

  const auto wall_end = std::chrono::steady_clock::now();
  RunSummary summary;
  summary.test_name = kTestName;
  summary.config_name = sim_config::kName;
  summary.build_mode = args.build_mode;
  summary.seed = args.seed;
  summary.passed = passed;
  summary.stop_reason = passed ? "pass" : "error";
  summary.stop_detail =
      passed ? "every window bit-exact against the C++ model"
             : "power/covariance mismatch; see errors_by_category";
  summary.passes = 10;
  summary.core_cycles = dev.cycles();
  summary.beats_observed = dev.observed();
  summary.absorb(errors);
  summary.wall_time_s =
      std::chrono::duration<double>(wall_end - wall_start).count();
  const std::string written = summary.write(args.results_dir);
  if (!written.empty()) std::printf("  summary json     : %s\n", written.c_str());

  top->final();

  if (passed) {
    std::printf("RESULT: PASS seed=%llu test=%s config=%s windows=%llu\n",
                static_cast<unsigned long long>(args.seed), kTestName,
                sim_config::kName,
                static_cast<unsigned long long>(dev.observed()));
    return 0;
  }
  std::printf(
      "RESULT: FAIL seed=%llu test=%s config=%s power=%zu integrate=%zu "
      "saturation=%zu exponential=%zu cross=%zu pair_enable=%zu flush=%zu "
      "invariance=%zu coverage=%zu config=%zu\n",
      static_cast<unsigned long long>(args.seed), kTestName, sim_config::kName,
      g_counters.power, g_counters.integrate, g_counters.saturation,
      g_counters.exponential, g_counters.cross, g_counters.pair_enable,
      g_counters.flush, g_counters.invariance, g_counters.coverage,
      g_counters.config);
  return 1;
}
