// -----------------------------------------------------------------------------
// test_cfar.cpp — CFAR detector verification (issue #14; SPEC 6, 7.7, 13.1,
// 13.2, 13.3, 14).
//
// Every event the DUT emits is compared FIELD FOR FIELD against
// model/cpp/cfar/cfar_model.hpp, in order, for every frame this test drives.
// Not the detection count, not a tolerance, not a spot check: the kind, the bin
// index, the frame id, the reference sum, the reference count, the threshold
// multiplier, the cell power, the per-frame counts and the SPEC 5 framing bits
// of every beat.
//
// Twelve passes:
//
//   1. geometry        the RTL's cfg_* echo against this file's mirror and
//                      against cfar_model.hpp's constants. Nothing else runs
//                      until they agree, so a mismatch is a named failure rather
//                      than a wrong comparison.
//   2. injected target one target in flat noise: detected, at the right bin,
//                      with the right noise sum, and NOTHING else detected. Then
//                      the closely-spaced pair — two targets separated by
//                      exactly the guard spacing, so each sits in the other's
//                      first reference cell — which is the case that
//                      distinguishes a correct guard band from an off-by-one.
//   3. edges           targets at bins 0, 1, last-1 and last. Every one of them
//                      must be SUPPRESSED and none may raise a detection, which
//                      is SPEC 7.7's suppression requirement stated as a test.
//                      The suppressed-bin count is checked against the model's,
//                      so "suppressed" is a number rather than an absence.
//   4. threshold sweep alpha swept across the value at which a known target's
//                      decision flips. The flip must happen at EXACTLY the
//                      integer the model says, in both directions, which is only
//                      meaningful because the comparison is division-free
//                      (cfar_pkg section 3). Plus the two closed-form corners:
//                      a zero spectrum detects nothing at any alpha, and a flat
//                      spectrum detects nothing at alpha = 1.0 exactly.
//   5. masking         a strong target inside a weak target's reference window
//                      raises that window's noise estimate and hides it; moving
//                      the strong target one bin further out, past the reference
//                      band, un-hides it. Both against the model.
//   6. modes           cell-averaging and greatest-of over the same frames.
//                      GO must differ from CA exactly where the model says it
//                      does, and the pass fails if the two modes never disagree
//                      — a mode test in which both modes agree everywhere has
//                      tested one mode.
//   7. random          random power streams, dense and near the top of the
//                      40-bit range, in both modes and both output modes, every
//                      event bit-exact.
//   8. dense mode      every bin reported exactly once, kinds consistent with
//                      the detection set of the sparse run over the same frame.
//   9. invariance      the same frames under randomized input gaps and output
//                      stalls must produce a BYTE-IDENTICAL event sequence. This
//                      is the statement about the pipeline that a predicted
//                      latency would have made weaker.
//  10. reconfiguration a configuration written mid-frame must not affect that
//                      frame and must take effect on the next one, with
//                      obs_cfg_pending high in between. The RTL's own
//                      a_cfar_cfg_frame_boundary watches the same property from
//                      the inside on every cycle of every pass.
//  11. faults          the orphan beat, the negative input clamp, the
//                      out-of-range geometry clamp and the unusable reference
//                      geometry: each provoked deliberately and required to land
//                      in the right sticky bit with the right suppression
//                      behaviour.
//  12. second shape    the MAX_GUARD = 0, MAX_REF = 3 elaboration over random
//                      frames, so the parameterisation is exercised rather than
//                      assumed.
//
// The RTL carries its own checks in parallel: sim/assertions/cfar_assertions.sv
// is instantiated inside cfar_core and re-derives every decision from
// cfar_pkg::cfar_over_threshold(), cfar_window asserts its own mask geometry,
// and stream_elastic_buffer's SPEC 5 protocol checker watches the output stream
// — including the per-beam sequence continuity that the detector's sequence
// table exists to provide. A Verilator assertion failure aborts the run, so all
// of those gate this test even though nothing here references them.
//
// Built by `make sim-tiny` as:
//   scripts/build_verilator.py --mode fast --top cfar_top
//       --files sim/verilator/files_cfar.f --test test_cfar
// -----------------------------------------------------------------------------

#include <chrono>
#include <cstdint>
#include <cstdio>
#include <memory>
#include <random>
#include <string>
#include <vector>

#include "Vcfar_top.h"
#include "verilated.h"

#include "config_sim.h"
#include "harness/error_collector.h"
#include "harness/random.h"
#include "harness/run_summary.h"
#include "harness/sim_args.h"

#include "cfar/cfar_model.hpp"

using harness::BackpressureConfig;
using harness::BackpressureGenerator;
using harness::ErrorCollector;
using harness::RunSummary;
using harness::SimArgs;

namespace {

constexpr const char* kTestName = "test_cfar";

// Mirror of sim/verilator/tops/cfar_top.sv. Checked against the RTL's cfg_* echo
// in pass 1 before anything else runs.
constexpr unsigned kMaxGuardA = sim_config::CFAR_MAX_GUARD;
constexpr unsigned kMaxRefA = sim_config::CFAR_MAX_REF;
constexpr unsigned kMaxGuardB = 0;
constexpr unsigned kMaxRefB = 3;

// A frame long enough that the interior is much larger than the two suppressed
// edges at the tiny geometry (D = 10 of 64 bins each side).
constexpr unsigned kFrameBins = 64;

// Hard cycle budget per frame: bins + flush + pipeline + summary, with room for
// randomized stalls. A frame that does not complete inside it is a hang, and a
// hang must fail rather than run forever.
constexpr std::uint64_t kFrameTimeout = 20000;

// ---------------------------------------------------------------------------
// Failure accounting. The relation that disagrees is the diagnosis, so the
// counts are kept apart rather than summed.
// ---------------------------------------------------------------------------
struct Counters {
  std::size_t config = 0;
  std::size_t event = 0;
  std::size_t framing = 0;
  std::size_t edge = 0;
  std::size_t threshold = 0;
  std::size_t masking = 0;
  std::size_t mode = 0;
  std::size_t invariance = 0;
  std::size_t reconfig = 0;
  std::size_t fault = 0;
  std::size_t counters = 0;
  std::size_t packing = 0;
  std::size_t coverage = 0;
  std::size_t hang = 0;

  std::size_t total() const {
    return config + event + framing + edge + threshold + masking + mode +
           invariance + reconfig + fault + counters + packing + coverage + hang;
  }
};

Counters g_counters;
ErrorCollector* g_errors = nullptr;

void fail(const char* category, std::size_t* counter, const std::string& msg) {
  ++*counter;
  g_errors->error(category, msg);
}

// ---------------------------------------------------------------------------
// The device
// ---------------------------------------------------------------------------
struct FrameResult {
  std::vector<cfar::Event> events;
  bool timed_out = false;
};

class Device {
 public:
  explicit Device(Vcfar_top* top) : top_(top) { idle(); }

  void idle() {
    top_->s_valid_a = 0;
    top_->s_valid_b = 0;
    top_->s_data = 0;
    top_->s_sof = 0;
    top_->s_eof = 0;
    top_->s_id = 0;
    top_->s_seq = 0;
    top_->s_user = 0;
    top_->m_ready_a = 1;
    top_->m_ready_b = 1;
    top_->obs_sel = 0;
    top_->cfg_status_clear = 0;
  }

  void apply_config(const cfar::Config& c) {
    top_->cfg_enable = c.enable ? 1 : 0;
    top_->cfg_mode = static_cast<std::uint8_t>(c.mode);
    top_->cfg_out_mode = static_cast<std::uint8_t>(c.out_mode);
    top_->cfg_guard_lead = static_cast<std::uint8_t>(c.guard_lead);
    top_->cfg_guard_lag = static_cast<std::uint8_t>(c.guard_lag);
    top_->cfg_ref_lead = static_cast<std::uint8_t>(c.ref_lead);
    top_->cfg_ref_lag = static_cast<std::uint8_t>(c.ref_lag);
    top_->cfg_alpha = static_cast<std::uint16_t>(c.alpha);
  }

  void reset(const cfar::Config& c) {
    idle();
    apply_config(c);
    top_->rst_n = 0;
    for (int i = 0; i < 8; ++i) tick();
    top_->rst_n = 1;
    for (int i = 0; i < 4; ++i) tick();
  }

  void clear_status() {
    top_->cfg_status_clear = 1;
    tick();
    top_->cfg_status_clear = 0;
    tick();
  }

  std::uint64_t cycles() const { return cycles_; }
  std::uint64_t events_seen() const { return events_; }

  // Drive one frame of `raw` power values (already in their 40-bit unsigned
  // carrier) and collect every emitted event up to and including the summary.
  //
  // `mid_frame` — if non-null, this configuration is written to the register
  // ports once the frame is half consumed. The frame must complete under the
  // configuration in force at its start-of-frame beat.
  FrameResult run_frame(bool dut_b, const std::vector<std::uint64_t>& raw,
                        unsigned beam, unsigned seq0,
                        BackpressureGenerator* in_bp, BackpressureGenerator* out_bp,
                        const cfar::Config* mid_frame = nullptr) {
    FrameResult r;
    top_->obs_sel = dut_b ? 1 : 0;

    std::size_t sent = 0;
    bool got_eof = false;
    std::uint64_t budget = kFrameTimeout;
    bool wrote_mid = false;

    while (!got_eof && budget-- > 0) {
      const bool want = sent < raw.size();
      const bool allow_in = want && (in_bp == nullptr || in_bp->allow());
      const bool allow_out = (out_bp == nullptr) || out_bp->allow();

      if (allow_in) {
        top_->s_data = raw[sent];
        top_->s_sof = (sent == 0) ? 1 : 0;
        top_->s_eof = (sent + 1 == raw.size()) ? 1 : 0;
        top_->s_id = static_cast<std::uint8_t>(beam);
        top_->s_seq = static_cast<std::uint16_t>(seq0 + sent);
        top_->s_user = static_cast<std::uint8_t>(beam & 0xF);
      }
      set_valid(dut_b, allow_in);
      set_mready(dut_b, allow_out);

      top_->eval();

      // Handshakes are evaluated on the settled combinational state, before the
      // clock edge that commits them.
      const bool in_fire = allow_in && ready(dut_b);
      const bool out_fire = allow_out && mvalid(dut_b);

      if (out_fire) {
        const cfar::Event e = sample_event();
        check_packing(e);
        r.events.push_back(e);
        ++events_;
        if (e.eof) got_eof = true;
      }

      tick();

      if (in_fire) {
        ++sent;
        if (mid_frame != nullptr && !wrote_mid && sent * 2 >= raw.size()) {
          apply_config(*mid_frame);
          wrote_mid = true;
        }
      }
    }

    set_valid(dut_b, false);
    set_mready(dut_b, true);
    top_->s_sof = 0;
    top_->s_eof = 0;
    r.timed_out = !got_eof;
    if (r.timed_out) {
      fail("hang", &g_counters.hang,
           "a frame of " + std::to_string(raw.size()) +
               " bins never produced its end-of-frame summary");
    }
    return r;
  }

  // Drive `n` beats with no start-of-frame while the block is idle — the orphan
  // case. Returns the number actually accepted.
  unsigned drive_orphans(unsigned n) {
    top_->obs_sel = 0;
    unsigned accepted = 0;
    std::uint64_t budget = 1000;
    while (accepted < n && budget-- > 0) {
      top_->s_data = 12345;
      top_->s_sof = 0;
      top_->s_eof = 0;
      top_->s_valid_a = 1;
      top_->eval();
      const bool fire = top_->s_ready_a != 0;
      tick();
      if (fire) ++accepted;
    }
    top_->s_valid_a = 0;
    tick();
    return accepted;
  }

  Vcfar_top* raw_top() { return top_; }

  void tick() {
    top_->clk = 0;
    top_->eval();
    top_->clk = 1;
    top_->eval();
    ++cycles_;
  }

 private:
  void set_valid(bool dut_b, bool v) {
    top_->s_valid_a = (!dut_b && v) ? 1 : 0;
    top_->s_valid_b = (dut_b && v) ? 1 : 0;
  }
  void set_mready(bool dut_b, bool v) {
    if (dut_b) {
      top_->m_ready_b = v ? 1 : 0;
      top_->m_ready_a = 1;
    } else {
      top_->m_ready_a = v ? 1 : 0;
      top_->m_ready_b = 1;
    }
  }
  bool ready(bool dut_b) const {
    return (dut_b ? top_->s_ready_b : top_->s_ready_a) != 0;
  }
  bool mvalid(bool dut_b) const {
    return (dut_b ? top_->m_valid_b : top_->m_valid_a) != 0;
  }

  cfar::Event sample_event() const {
    cfar::Event e;
    e.kind = top_->ev_kind;
    e.bin = top_->ev_bin;
    e.frame_id = top_->ev_frame;
    e.ref_count = top_->ev_refcnt;
    e.alpha = top_->ev_alpha;
    e.det_count = top_->ev_det;
    e.sup_count = top_->ev_sup;
    e.cut_power = top_->ev_cut;
    e.noise_sum = top_->ev_sum;
    e.sof = top_->m_sof != 0;
    e.eof = top_->m_eof != 0;
    return e;
  }

  // The packed event, unpacked independently of the RTL's own unpack. A
  // pack/unpack pair only ever used against itself proves nothing.
  void check_packing(const cfar::Event& e) const {
    const std::uint64_t w[3] = {top_->ev_pack0, top_->ev_pack1, top_->ev_pack2};
    auto field = [&w](unsigned lsb, unsigned width) -> std::uint64_t {
      std::uint64_t v = 0;
      for (unsigned i = 0; i < width; ++i) {
        const unsigned b = lsb + i;
        const std::uint64_t bit = (w[b / 64] >> (b % 64)) & 1ULL;
        v |= bit << i;
      }
      return v;
    };
    struct Check {
      const char* name;
      std::uint64_t got;
      std::uint64_t want;
    };
    const Check checks[] = {
        {"kind", field(cfar::kEvKindLsb, cfar::kEvKindW), e.kind},
        {"bin", field(cfar::kEvBinLsb, cfar::kBinW), e.bin},
        {"frame_id", field(cfar::kEvFrameIdLsb, cfar::kFrameIdW), e.frame_id},
        {"ref_count", field(cfar::kEvRefCntLsb, cfar::kTotRefW), e.ref_count},
        {"alpha", field(cfar::kEvAlphaLsb, cfar::kAlphaW), e.alpha},
        {"det_count", field(cfar::kEvDetLsb, cfar::kCntW), e.det_count},
        {"sup_count", field(cfar::kEvSupLsb, cfar::kCntW), e.sup_count},
        {"cut_power", field(cfar::kEvCellLsb, cfar::kPowerW), e.cut_power},
        {"noise_sum", field(cfar::kEvSumLsb, cfar::kSumW), e.noise_sum},
    };
    for (const Check& c : checks) {
      if (c.got != c.want) {
        fail("packing", &g_counters.packing,
             std::string("packed event field ") + c.name + " is " +
                 std::to_string(c.got) + " but the unpacked port says " +
                 std::to_string(c.want));
        return;
      }
    }
  }

  Vcfar_top* top_;
  std::uint64_t cycles_ = 0;
  std::uint64_t events_ = 0;
};

// ---------------------------------------------------------------------------
// Comparison against the model
// ---------------------------------------------------------------------------
bool compare(const std::vector<cfar::Event>& got,
             const std::vector<cfar::Event>& want, const std::string& what,
             const char* category, std::size_t* counter) {
  if (got.size() != want.size()) {
    std::string detail = what + ": the RTL emitted " + std::to_string(got.size()) +
                         " events, the model expects " + std::to_string(want.size());
    // The first divergence is the diagnosis; print it rather than the counts
    // alone.
    const std::size_t n = got.size() < want.size() ? got.size() : want.size();
    for (std::size_t i = 0; i < n; ++i) {
      if (got[i] != want[i]) {
        detail += " (first difference at " + std::to_string(i) + ": RTL " +
                  got[i].str() + " vs model " + want[i].str() + ")";
        break;
      }
    }
    fail(category, counter, detail);
    return false;
  }
  for (std::size_t i = 0; i < got.size(); ++i) {
    if (got[i] != want[i]) {
      fail(category, counter,
           what + ": event " + std::to_string(i) + ": RTL " + got[i].str() +
               " vs model " + want[i].str());
      return false;
    }
  }
  return true;
}

// ---------------------------------------------------------------------------
// Stimulus helpers
// ---------------------------------------------------------------------------
std::vector<std::uint64_t> flat_noise(unsigned n, std::uint64_t level) {
  return std::vector<std::uint64_t>(n, level);
}

std::vector<std::uint64_t> random_noise(std::mt19937_64& rng, unsigned n,
                                        std::uint64_t lo, std::uint64_t hi) {
  std::vector<std::uint64_t> v(n);
  for (unsigned i = 0; i < n; ++i) v[i] = harness::uniform_u64(rng, lo, hi);
  return v;
}

cfar::Config base_config() {
  cfar::Config c;
  c.enable = true;
  c.mode = cfar::Mode::kCA;
  c.out_mode = cfar::OutMode::kEvents;
  c.guard_lead = 2;
  c.guard_lag = 2;
  c.ref_lead = 4;
  c.ref_lag = 4;
  c.alpha = 4 * cfar::kAlphaOne;  // 4.0
  return c;
}

// One frame driven and checked. Returns the RTL's events.
std::vector<cfar::Event> drive_and_check(Device* dev, bool dut_b,
                                         const std::vector<std::uint64_t>& bins,
                                         const cfar::Config& cfg, unsigned beam,
                                         unsigned frame_id, const std::string& what,
                                         const char* category, std::size_t* counter,
                                         BackpressureGenerator* in_bp = nullptr,
                                         BackpressureGenerator* out_bp = nullptr) {
  dev->apply_config(cfg);
  const FrameResult r =
      dev->run_frame(dut_b, bins, beam, frame_id, in_bp, out_bp);
  if (r.timed_out) return r.events;
  const unsigned max_guard = dut_b ? kMaxGuardB : kMaxGuardA;
  const unsigned max_ref = dut_b ? kMaxRefB : kMaxRefA;
  const std::vector<cfar::Event> want =
      cfar::run_frame(bins, cfg, max_guard, max_ref, frame_id);
  compare(r.events, want, what, category, counter);
  return r.events;
}

// ---------------------------------------------------------------------------
// Pass 1 — geometry
// ---------------------------------------------------------------------------
void pass_geometry(Vcfar_top* top) {
  struct Item {
    const char* name;
    unsigned got;
    unsigned want;
  };
  const Item items[] = {
      {"MAX_GUARD (A)", top->cfg_max_guard_a, kMaxGuardA},
      {"MAX_REF (A)", top->cfg_max_ref_a, kMaxRefA},
      {"MAX_GUARD (B)", top->cfg_max_guard_b, kMaxGuardB},
      {"MAX_REF (B)", top->cfg_max_ref_b, kMaxRefB},
      {"POWER_W", top->cfg_power_w, cfar::kPowerW},
      {"BIN_W", top->cfg_bin_w, cfar::kBinW},
      {"ALPHA_W", top->cfg_alpha_w, cfar::kAlphaW},
      {"ALPHA_FRAC_W", top->cfg_alpha_frac_w, cfar::kAlphaFracW},
      {"GUARD_CNT_W", top->cfg_guard_cnt_w, cfar::kGuardCntW},
      {"REF_CNT_W", top->cfg_ref_cnt_w, cfar::kRefCntW},
      {"TOTREF_W", top->cfg_totref_w, cfar::kTotRefW},
      {"event SUM_W", top->cfg_event_sum_w, cfar::kSumW},
      {"CNT_W", top->cfg_cnt_w, cfar::kCntW},
      {"EVENT_W", top->cfg_event_w, cfar::kEventW},
      {"internal sum_w(A)", top->cfg_sum_w_a, cfar::sum_w(kMaxRefA)},
      {"cmp_w(A)", top->cfg_cmp_w_a, cfar::cmp_w(kMaxRefA)},
      {"half_window(A)", top->cfg_half_window_a,
       cfar::half_window(kMaxGuardA, kMaxRefA)},
      {"window_slots(A)", top->cfg_slots_a,
       cfar::window_slots(kMaxGuardA, kMaxRefA)},
  };
  for (const Item& it : items) {
    if (it.got != it.want) {
      fail("config", &g_counters.config,
           std::string("geometry: RTL reports ") + it.name + " = " +
               std::to_string(it.got) + ", the C++ mirror says " +
               std::to_string(it.want));
    }
  }
}

// ---------------------------------------------------------------------------
// Pass 2 — injected targets
// ---------------------------------------------------------------------------
void pass_targets(Device* dev) {
  cfar::Config cfg = base_config();
  const std::uint64_t noise = 1000;

  // (a) one target, comfortably inside the frame.
  {
    std::vector<std::uint64_t> bins = flat_noise(kFrameBins, noise);
    bins[32] = noise * 40;
    const std::vector<cfar::Event> got = drive_and_check(
        dev, false, bins, cfg, 1, 100, "single target", "event", &g_counters.event);

    unsigned dets = 0;
    unsigned det_bin = 0;
    for (const cfar::Event& e : got) {
      if (e.kind == cfar::kEvDetect) {
        ++dets;
        det_bin = e.bin;
      }
    }
    if (dets != 1 || det_bin != 32) {
      fail("event", &g_counters.event,
           "single target: expected exactly one detection at bin 32, saw " +
               std::to_string(dets) + " (last at bin " + std::to_string(det_bin) + ")");
    }
  }

  // (b) closely-spaced pair straddling the guard spacing. The two targets are
  // guard+1 bins apart, so each sits in the OTHER's first reference cell. A
  // correct guard band keeps each target out of its OWN reference window; an
  // off-by-one puts it in, and the target then raises its own threshold.
  {
    const unsigned a = 30;
    const unsigned b = a + cfg.guard_lead + 1;
    std::vector<std::uint64_t> bins = flat_noise(kFrameBins, noise);
    bins[a] = noise * 40;
    bins[b] = noise * 40;
    drive_and_check(dev, false, bins, cfg, 1, 101, "close pair", "event",
                    &g_counters.event);
  }

  // (c) the same pair one bin closer — INSIDE the guard band, so neither target
  // contaminates the other's reference cells at all.
  {
    const unsigned a = 30;
    const unsigned b = a + cfg.guard_lead;
    std::vector<std::uint64_t> bins = flat_noise(kFrameBins, noise);
    bins[a] = noise * 40;
    bins[b] = noise * 40;
    drive_and_check(dev, false, bins, cfg, 1, 102, "pair inside the guard band",
                    "event", &g_counters.event);
  }
}

// ---------------------------------------------------------------------------
// Pass 3 — edges
// ---------------------------------------------------------------------------
void pass_edges(Device* dev) {
  cfar::Config cfg = base_config();
  const std::uint64_t noise = 1000;
  const unsigned last = kFrameBins - 1;
  const unsigned edge_bins[] = {0, 1, last - 1, last};

  for (unsigned t : edge_bins) {
    std::vector<std::uint64_t> bins = flat_noise(kFrameBins, noise);
    bins[t] = noise * 200;  // enormous: it would detect anywhere evaluable
    cfg.out_mode = cfar::OutMode::kDense;
    const std::vector<cfar::Event> got = drive_and_check(
        dev, false, bins, cfg, 2, 200 + t,
        "edge target at bin " + std::to_string(t), "edge", &g_counters.edge);

    // The target's own bin must be reported SUPPRESSED, never DETECT.
    bool seen = false;
    for (const cfar::Event& e : got) {
      if (e.kind == cfar::kEvSummary || e.bin != t) continue;
      seen = true;
      if (e.kind != cfar::kEvSuppressed) {
        fail("edge", &g_counters.edge,
             "a target at edge bin " + std::to_string(t) + " was reported " +
                 cfar::kind_name(e.kind) + ", not SUPPRESSED");
      }
      if (e.noise_sum != 0 || e.ref_count != 0) {
        fail("edge", &g_counters.edge,
             "suppressed bin " + std::to_string(t) +
                 " reported a reference window it does not have");
      }
    }
    if (!seen) {
      fail("edge", &g_counters.edge,
           "dense mode did not report edge bin " + std::to_string(t) + " at all");
    }

    // And the frame's suppression count must be the structural one: the first
    // and last (guard + reference) bins.
    const unsigned expect_sup = 2 * (cfg.guard_lead + cfg.ref_lead);
    for (const cfar::Event& e : got) {
      if (e.kind != cfar::kEvSummary) continue;
      if (e.sup_count != expect_sup) {
        fail("edge", &g_counters.edge,
             "frame suppression count is " + std::to_string(e.sup_count) +
                 ", expected " + std::to_string(expect_sup));
      }
      if (e.bin != kFrameBins) {
        fail("framing", &g_counters.framing,
             "summary reports a frame length of " + std::to_string(e.bin) +
                 ", expected " + std::to_string(kFrameBins));
      }
    }
  }

  // A frame SHORTER than the window: every bin is suppressed, nothing detects.
  {
    cfg.out_mode = cfar::OutMode::kDense;
    std::vector<std::uint64_t> bins = flat_noise(4, noise);
    bins[2] = noise * 500;
    const std::vector<cfar::Event> got =
        drive_and_check(dev, false, bins, cfg, 2, 299, "frame shorter than the window",
                        "edge", &g_counters.edge);
    for (const cfar::Event& e : got) {
      if (e.kind == cfar::kEvDetect) {
        fail("edge", &g_counters.edge,
             "a frame shorter than the reference window raised a detection");
      }
    }
  }
}

// ---------------------------------------------------------------------------
// Pass 4 — threshold sweep
// ---------------------------------------------------------------------------
void pass_threshold(Device* dev) {
  cfar::Config cfg = base_config();
  cfg.out_mode = cfar::OutMode::kEvents;
  const std::uint64_t noise = 997;   // not a power of two, so no shift aliases
  const unsigned t = 33;

  std::vector<std::uint64_t> bins = flat_noise(kFrameBins, noise);
  bins[t] = noise * 9;

  // The exact integer alpha at which this target's decision flips. With a flat
  // noise floor the reference sum is N*noise, so the condition
  //     C * N * 2^F > A * N * noise
  // reduces to A < C * 2^F / noise, i.e. the flip is at
  //     A_flip = floor((C * 2^F - 1) / noise) + 1
  // and the whole point of the division-free form is that this is an exact
  // integer rather than a rounded one.
  const std::uint64_t cut = bins[t];
  const std::uint64_t flip = ((cut << cfar::kAlphaFracW) - 1) / noise + 1;

  bool saw_detect = false;
  bool saw_miss = false;
  for (std::int64_t d = -2; d <= 2; ++d) {
    const std::int64_t a = static_cast<std::int64_t>(flip) + d;
    if (a < 0 || a > 0xFFFF) continue;
    cfg.alpha = static_cast<unsigned>(a);
    const std::vector<cfar::Event> got = drive_and_check(
        dev, false, bins, cfg, 3, 300 + static_cast<unsigned>(d + 2),
        "threshold sweep alpha=" + std::to_string(a), "threshold",
        &g_counters.threshold);

    bool detected = false;
    for (const cfar::Event& e : got) {
      if (e.kind == cfar::kEvDetect && e.bin == t) detected = true;
    }
    // Below the flip the target detects; at and above it does not.
    const bool expect = static_cast<std::uint64_t>(a) < flip;
    if (detected != expect) {
      fail("threshold", &g_counters.threshold,
           "alpha=" + std::to_string(a) + " (flip at " + std::to_string(flip) +
               "): the target " + (detected ? "detected" : "did not detect") +
               " but should " + (expect ? "have" : "not have"));
    }
    saw_detect |= detected;
    saw_miss |= !detected;
  }
  if (!saw_detect || !saw_miss) {
    fail("coverage", &g_counters.coverage,
         "the threshold sweep never observed the decision flipping");
  }

  // Closed-form corner 1: an identically-zero spectrum detects nothing, at any
  // alpha including zero, because the comparison is strict.
  {
    cfg.alpha = 0;
    const std::vector<cfar::Event> got = drive_and_check(
        dev, false, flat_noise(kFrameBins, 0), cfg, 3, 310,
        "zero spectrum at alpha=0", "threshold", &g_counters.threshold);
    for (const cfar::Event& e : got) {
      if (e.kind == cfar::kEvDetect) {
        fail("threshold", &g_counters.threshold,
             "a zero spectrum raised a detection at alpha = 0");
      }
    }
  }

  // Closed-form corner 2: a perfectly flat spectrum at alpha = 1.0 exactly.
  // C*N*2^F and A*S are then the same integer, and the strict comparison says no.
  {
    cfg.alpha = cfar::kAlphaOne;
    const std::vector<cfar::Event> got = drive_and_check(
        dev, false, flat_noise(kFrameBins, noise), cfg, 3, 311,
        "flat spectrum at alpha=1.0", "threshold", &g_counters.threshold);
    for (const cfar::Event& e : got) {
      if (e.kind == cfar::kEvDetect) {
        fail("threshold", &g_counters.threshold,
             "a flat spectrum raised a detection at alpha = 1.0 exactly");
      }
    }
  }

  // And one LSB below 1.0 the same flat spectrum detects EVERY evaluable bin,
  // which is what proves the previous case was a boundary rather than a floor.
  {
    cfg.alpha = cfar::kAlphaOne - 1;
    const std::vector<cfar::Event> got = drive_and_check(
        dev, false, flat_noise(kFrameBins, noise), cfg, 3, 312,
        "flat spectrum one LSB below 1.0", "threshold", &g_counters.threshold);
    unsigned dets = 0;
    for (const cfar::Event& e : got) {
      if (e.kind == cfar::kEvDetect) ++dets;
    }
    const unsigned evaluable = kFrameBins - 2 * (cfg.guard_lead + cfg.ref_lead);
    if (dets != evaluable) {
      fail("threshold", &g_counters.threshold,
           "one LSB below alpha = 1.0 a flat spectrum detected " +
               std::to_string(dets) + " bins, expected every evaluable one (" +
               std::to_string(evaluable) + ")");
    }
  }
}

// ---------------------------------------------------------------------------
// Pass 5 — masking
// ---------------------------------------------------------------------------
void pass_masking(Device* dev) {
  cfar::Config cfg = base_config();
  cfg.alpha = 3 * cfar::kAlphaOne;
  const std::uint64_t noise = 1000;
  const unsigned t = 32;

  // A weak target, chosen so that it detects against a clean noise floor.
  const std::uint64_t weak = noise * 5;

  // The strong target sits INSIDE the weak one's leading reference band, so it
  // inflates the noise estimate the weak target is measured against.
  const unsigned inside = t + cfg.guard_lead + 1;
  // ...and one bin past the band, where it cannot.
  const unsigned outside = t + cfg.guard_lead + cfg.ref_lead + 1;

  bool detected_alone = false;
  bool detected_masked = false;
  bool detected_unmasked = false;

  {
    std::vector<std::uint64_t> bins = flat_noise(kFrameBins, noise);
    bins[t] = weak;
    const std::vector<cfar::Event> got =
        drive_and_check(dev, false, bins, cfg, 4, 400, "weak target alone",
                        "masking", &g_counters.masking);
    for (const cfar::Event& e : got) {
      if (e.kind == cfar::kEvDetect && e.bin == t) detected_alone = true;
    }
  }

  {
    std::vector<std::uint64_t> bins = flat_noise(kFrameBins, noise);
    bins[t] = weak;
    bins[inside] = noise * 100;
    const std::vector<cfar::Event> got = drive_and_check(
        dev, false, bins, cfg, 4, 401, "strong target inside the reference band",
        "masking", &g_counters.masking);
    for (const cfar::Event& e : got) {
      if (e.kind == cfar::kEvDetect && e.bin == t) detected_masked = true;
    }
  }

  {
    std::vector<std::uint64_t> bins = flat_noise(kFrameBins, noise);
    bins[t] = weak;
    bins[outside] = noise * 100;
    const std::vector<cfar::Event> got = drive_and_check(
        dev, false, bins, cfg, 4, 402, "strong target outside the reference band",
        "masking", &g_counters.masking);
    for (const cfar::Event& e : got) {
      if (e.kind == cfar::kEvDetect && e.bin == t) detected_unmasked = true;
    }
  }

  if (!detected_alone) {
    fail("masking", &g_counters.masking,
         "the weak target does not detect even against a clean noise floor — the "
         "masking experiment has no baseline");
  }
  if (detected_masked) {
    fail("masking", &g_counters.masking,
         "a strong target inside the reference band did not raise the threshold: "
         "the weak target still detected");
  }
  if (!detected_unmasked) {
    fail("masking", &g_counters.masking,
         "a strong target OUTSIDE the reference band suppressed the weak target — "
         "the reference band extends further than the geometry says");
  }
}

// ---------------------------------------------------------------------------
// Pass 6 — modes
// ---------------------------------------------------------------------------
void pass_modes(Device* dev, std::mt19937_64 rng) {
  cfar::Config ca = base_config();
  ca.alpha = 3 * cfar::kAlphaOne;
  cfar::Config go = ca;
  go.mode = cfar::Mode::kGO;

  // A DIRECTED clutter edge, with arithmetic worked out in advance rather than
  // hoped for. Guard 2, reference 4 each side, alpha = 3.0 (A = 768):
  //
  //   bins below the step are 1000, bins above are 20000, and the cell under
  //   test sits exactly ON the step at bin 32, so its lagging references are all
  //   1000 and its leading references are all 20000.
  //
  //   cell averaging   S = 4*1000 + 4*20000 = 84000 over N = 8
  //                    detect iff C*8*256 > 768*84000, i.e. C > 31500
  //   greatest-of      the leading side has the greater mean, S = 80000, N = 4
  //                    detect iff C*4*256 > 768*80000, i.e. C > 60000
  //
  // A target of 40000 therefore detects under cell averaging and NOT under
  // greatest-of. That gap IS the reason greatest-of exists — the clutter edge
  // would otherwise produce a false alarm — and a mode test in which both modes
  // agree everywhere has tested one mode.
  const unsigned step = 32;
  std::vector<std::uint64_t> edge(kFrameBins, 1000);
  for (unsigned i = step + 1; i < kFrameBins; ++i) edge[i] = 20000;
  edge[step] = 40000;

  const std::vector<cfar::Event> got_ca = drive_and_check(
      dev, false, edge, ca, 5, 500, "CA over a clutter edge", "mode",
      &g_counters.mode);
  const std::vector<cfar::Event> got_go = drive_and_check(
      dev, false, edge, go, 5, 501, "GO over a clutter edge", "mode",
      &g_counters.mode);

  bool ca_hit = false;
  bool go_hit = false;
  for (const cfar::Event& e : got_ca) {
    if (e.kind == cfar::kEvDetect && e.bin == step) ca_hit = true;
  }
  for (const cfar::Event& e : got_go) {
    if (e.kind == cfar::kEvDetect && e.bin == step) go_hit = true;
  }
  if (!ca_hit) {
    fail("mode", &g_counters.mode,
         "cell averaging did not detect the clutter-edge target it must (the "
         "worked example in this pass says C = 40000 > 31500)");
  }
  if (go_hit) {
    fail("mode", &g_counters.mode,
         "greatest-of detected the clutter-edge target it must not (the worked "
         "example says the greater-mean side puts the threshold at C > 60000)");
  }

  // And random frames over the same shape, so the GO side selection is exercised
  // on data the test did not design.
  for (unsigned f = 0; f < 5; ++f) {
    std::vector<std::uint64_t> bins = random_noise(rng, kFrameBins, 900, 1100);
    for (unsigned i = kFrameBins / 2; i < kFrameBins; ++i) bins[i] *= 8;
    bins[20 + f] = 9000;
    bins[40 + f] = 90000;
    drive_and_check(dev, false, bins, ca, 5, 510 + f, "CA over random clutter",
                    "mode", &g_counters.mode);
    drive_and_check(dev, false, bins, go, 5, 520 + f, "GO over random clutter",
                    "mode", &g_counters.mode);
  }

  // Greatest-of with a zero reference count on one side has no usable geometry:
  // every bin must be suppressed and nothing may detect.
  {
    cfar::Config bad = go;
    bad.ref_lag = 0;
    bad.out_mode = cfar::OutMode::kDense;
    std::vector<std::uint64_t> bins = flat_noise(kFrameBins, 1000);
    bins[32] = 500000;
    const std::vector<cfar::Event> got =
        drive_and_check(dev, false, bins, bad, 5, 610,
                        "greatest-of with no lagging references", "mode",
                        &g_counters.mode);
    for (const cfar::Event& e : got) {
      if (e.kind == cfar::kEvDetect) {
        fail("mode", &g_counters.mode,
             "greatest-of detected with a zero lagging reference count");
      }
    }
  }
}

// ---------------------------------------------------------------------------
// Pass 7 — random streams
// ---------------------------------------------------------------------------
void pass_random(Device* dev, std::mt19937_64 rng, bool dut_b, unsigned n_frames,
                 const char* what) {
  const unsigned max_ref = dut_b ? kMaxRefB : kMaxRefA;
  const unsigned max_guard = dut_b ? kMaxGuardB : kMaxRefA;
  (void)max_guard;

  for (unsigned f = 0; f < n_frames; ++f) {
    cfar::Config cfg = base_config();
    cfg.mode = (f % 2) ? cfar::Mode::kGO : cfar::Mode::kCA;
    cfg.out_mode = (f % 3 == 0) ? cfar::OutMode::kDense : cfar::OutMode::kEvents;
    cfg.guard_lead = static_cast<unsigned>(harness::uniform_u64(rng, 0, 3));
    cfg.guard_lag = static_cast<unsigned>(harness::uniform_u64(rng, 0, 3));
    cfg.ref_lead =
        static_cast<unsigned>(harness::uniform_u64(rng, 1, max_ref));
    cfg.ref_lag = static_cast<unsigned>(harness::uniform_u64(rng, 1, max_ref));
    cfg.alpha = static_cast<unsigned>(harness::uniform_u64(rng, 0, 8 * cfar::kAlphaOne));

    // Every third frame runs near the top of the 40-bit power range, so the wide
    // end of the comparison is exercised rather than only the comfortable end.
    const bool big = (f % 3 == 1);
    const std::uint64_t lo = big ? (1ULL << 37) : 1;
    const std::uint64_t hi = big ? ((1ULL << 39) - 1) : 100000;
    const unsigned len =
        static_cast<unsigned>(harness::uniform_u64(rng, 8, kFrameBins));
    std::vector<std::uint64_t> bins = random_noise(rng, len, lo, hi);

    drive_and_check(dev, dut_b, bins, cfg, f % 8, 700 + f,
                    std::string(what) + " frame " + std::to_string(f), "event",
                    &g_counters.event);
  }
}

// ---------------------------------------------------------------------------
// Pass 9 — backpressure invariance
// ---------------------------------------------------------------------------
void pass_invariance(Device* dev, std::mt19937_64 rng, std::mt19937_64 bp_rng) {
  cfar::Config cfg = base_config();
  cfg.alpha = 2 * cfar::kAlphaOne;
  cfg.out_mode = cfar::OutMode::kDense;

  for (unsigned f = 0; f < 4; ++f) {
    std::vector<std::uint64_t> bins = random_noise(rng, kFrameBins, 1, 200000);

    dev->apply_config(cfg);
    const FrameResult dense =
        dev->run_frame(false, bins, 6, 800 + f, nullptr, nullptr);

    BackpressureGenerator in_bp(bp_rng, BackpressureConfig::bursty());
    BackpressureGenerator out_bp(bp_rng, BackpressureConfig::heavy());
    dev->apply_config(cfg);
    const FrameResult stalled =
        dev->run_frame(false, bins, 6, 900 + f, &in_bp, &out_bp);

    if (dense.timed_out || stalled.timed_out) continue;

    // The frame ids differ deliberately, so compare everything else.
    if (dense.events.size() != stalled.events.size()) {
      fail("invariance", &g_counters.invariance,
           "backpressure changed the event count: " +
               std::to_string(dense.events.size()) + " vs " +
               std::to_string(stalled.events.size()));
      continue;
    }
    for (std::size_t i = 0; i < dense.events.size(); ++i) {
      cfar::Event a = dense.events[i];
      cfar::Event b = stalled.events[i];
      a.frame_id = 0;
      b.frame_id = 0;
      if (a != b) {
        fail("invariance", &g_counters.invariance,
             "backpressure changed event " + std::to_string(i) + ": " + a.str() +
                 " vs " + b.str());
        break;
      }
    }
  }
}

// ---------------------------------------------------------------------------
// Pass 10 — reconfiguration at a frame boundary
// ---------------------------------------------------------------------------
void pass_reconfig(Device* dev) {
  cfar::Config first = base_config();
  first.alpha = 2 * cfar::kAlphaOne;
  first.ref_lead = 4;
  first.ref_lag = 4;

  cfar::Config second = first;
  second.alpha = 20 * cfar::kAlphaOne;
  second.ref_lead = 6;
  second.ref_lag = 6;
  second.guard_lead = 1;

  std::vector<std::uint64_t> bins = flat_noise(kFrameBins, 1000);
  for (unsigned i = 20; i < 44; i += 6) bins[i] = 8000;

  // The frame runs with `first`; `second` is written half way through and must
  // not affect it.
  dev->apply_config(first);
  const FrameResult r = dev->run_frame(false, bins, 7, 1000, nullptr, nullptr,
                                       &second);
  if (!r.timed_out) {
    const std::vector<cfar::Event> want =
        cfar::run_frame(bins, first, kMaxGuardA, kMaxRefA, 1000);
    compare(r.events, want, "frame straddling a configuration write", "reconfig",
            &g_counters.reconfig);
  }

  // The write is now pending: the active copy still holds `first`.
  dev->raw_top()->eval();
  if (dev->raw_top()->obs_cfg_pending == 0) {
    fail("reconfig", &g_counters.reconfig,
         "a configuration write is outstanding but obs_cfg_pending reads 0");
  }
  if (dev->raw_top()->obs_active_alpha != first.alpha) {
    fail("reconfig", &g_counters.reconfig,
         "the active alpha is " + std::to_string(dev->raw_top()->obs_active_alpha) +
             " but the frame ran with " + std::to_string(first.alpha));
  }

  // The next frame takes it, without the test writing anything more.
  const FrameResult r2 = dev->run_frame(false, bins, 7, 1001, nullptr, nullptr);
  if (!r2.timed_out) {
    const std::vector<cfar::Event> want2 =
        cfar::run_frame(bins, second, kMaxGuardA, kMaxRefA, 1001);
    compare(r2.events, want2, "frame after the configuration boundary", "reconfig",
            &g_counters.reconfig);
  }
  if (dev->raw_top()->obs_cfg_pending != 0) {
    fail("reconfig", &g_counters.reconfig,
         "obs_cfg_pending is still set after the configuration was taken");
  }
}

// ---------------------------------------------------------------------------
// Pass 11 — faults
// ---------------------------------------------------------------------------
constexpr unsigned kFaultCfgClamped = 1u << 0;
constexpr unsigned kFaultNegInput = 1u << 1;
constexpr unsigned kFaultOrphan = 1u << 2;
constexpr unsigned kFaultSofInFrame = 1u << 3;
constexpr unsigned kFaultNoRef = 1u << 4;

void expect_fault(Device* dev, unsigned mask, const char* what) {
  dev->raw_top()->eval();
  const unsigned got = dev->raw_top()->stat_fault;
  if ((got & mask) != mask) {
    fail("fault", &g_counters.fault,
         std::string(what) + ": expected fault mask 0x" + std::to_string(mask) +
             " but stat_fault reads 0x" + std::to_string(got));
  }
}

void pass_faults(Device* dev) {
  // (a) orphan beat: a beat outside a frame with no start_of_frame.
  dev->clear_status();
  const unsigned accepted = dev->drive_orphans(3);
  if (accepted != 3) {
    fail("fault", &g_counters.fault,
         "the block stalled on beats outside a frame instead of discarding them (" +
             std::to_string(accepted) + " of 3 accepted)");
  }
  expect_fault(dev, kFaultOrphan, "orphan beat");

  // (b) negative power input: clamped to zero, counted, and the frame still
  // matches the model computed on the clamped values.
  {
    dev->clear_status();
    cfar::Config cfg = base_config();
    cfg.out_mode = cfar::OutMode::kDense;
    std::vector<std::uint64_t> raw = flat_noise(kFrameBins, 1000);
    // Two's-complement -1 in the 40-bit carrier.
    raw[30] = (1ULL << 40) - 1ULL;
    raw[31] = 1ULL << 39;  // the most negative value

    std::vector<std::uint64_t> clamped = raw;
    clamped[30] = 0;
    clamped[31] = 0;

    dev->apply_config(cfg);
    const FrameResult r = dev->run_frame(false, raw, 0, 1100, nullptr, nullptr);
    if (!r.timed_out) {
      const std::vector<cfar::Event> want =
          cfar::run_frame(clamped, cfg, kMaxGuardA, kMaxRefA, 1100);
      compare(r.events, want, "negative power inputs clamped to zero", "fault",
              &g_counters.fault);
    }
    expect_fault(dev, kFaultNegInput, "negative power input");
  }

  // (c) out-of-range geometry: clamped to the elaborated maxima, flagged, and
  // the frame runs under the CLAMPED geometry.
  {
    dev->clear_status();
    cfar::Config cfg = base_config();
    cfg.ref_lead = 63;   // far beyond MAX_REF
    cfg.guard_lag = 31;  // far beyond MAX_GUARD
    std::vector<std::uint64_t> bins = flat_noise(kFrameBins, 1000);
    bins[32] = 60000;
    drive_and_check(dev, false, bins, cfg, 0, 1200, "out-of-range geometry",
                    "fault", &g_counters.fault);
    expect_fault(dev, kFaultCfgClamped, "out-of-range geometry");

    dev->raw_top()->eval();
    if (dev->raw_top()->obs_active_ref_lead != kMaxRefA ||
        dev->raw_top()->obs_active_guard_lag != kMaxGuardA) {
      fail("fault", &g_counters.fault,
           "an out-of-range geometry was not clamped to the elaborated maxima");
    }
  }

  // (d) no usable reference geometry: cell averaging with both counts zero.
  {
    dev->clear_status();
    cfar::Config cfg = base_config();
    cfg.ref_lead = 0;
    cfg.ref_lag = 0;
    cfg.out_mode = cfar::OutMode::kDense;
    std::vector<std::uint64_t> bins = flat_noise(kFrameBins, 1000);
    bins[32] = 999999;
    const std::vector<cfar::Event> got = drive_and_check(
        dev, false, bins, cfg, 0, 1300, "no reference cells at all", "fault",
        &g_counters.fault);
    for (const cfar::Event& e : got) {
      if (e.kind == cfar::kEvDetect) {
        fail("fault", &g_counters.fault,
             "a detection was raised with no reference cells");
      }
    }
    expect_fault(dev, kFaultNoRef, "no reference cells");
  }

  // (e) start_of_frame on a mid-frame beat: the bit is ignored, the frame runs
  // normally, and the fault is raised.
  {
    dev->clear_status();
    cfar::Config cfg = base_config();
    dev->apply_config(cfg);
    // Drive a frame by hand so the stray sof can be injected.
    Vcfar_top* top = dev->raw_top();
    top->obs_sel = 0;
    std::size_t sent = 0;
    const unsigned n = 24;
    std::uint64_t budget = 4000;
    bool got_eof = false;
    while (!got_eof && budget-- > 0) {
      const bool want = sent < n;
      if (want) {
        top->s_data = 1000;
        top->s_sof = (sent == 0 || sent == 5) ? 1 : 0;   // the stray one at 5
        top->s_eof = (sent + 1 == n) ? 1 : 0;
        top->s_id = 0;
        top->s_seq = static_cast<std::uint16_t>(1400 + sent);
        top->s_user = 0;
      }
      top->s_valid_a = want ? 1 : 0;
      top->m_ready_a = 1;
      top->eval();
      const bool in_fire = want && top->s_ready_a;
      if (top->m_valid_a && top->m_eof) got_eof = true;
      dev->tick();
      if (in_fire) ++sent;
    }
    top->s_valid_a = 0;
    top->s_sof = 0;
    top->s_eof = 0;
    dev->tick();
    if (!got_eof) {
      fail("hang", &g_counters.hang,
           "the frame carrying a stray start-of-frame never completed");
    }
    expect_fault(dev, kFaultSofInFrame, "stray start-of-frame");
  }

  // Clean up so the counter pass starts from a known state.
  dev->clear_status();
}

// ---------------------------------------------------------------------------
// Pass 12 — the SPEC 9 counters against an independent tally
// ---------------------------------------------------------------------------
void pass_counters(Device* dev, std::mt19937_64 rng) {
  dev->clear_status();

  cfar::Config cfg = base_config();
  cfg.alpha = 2 * cfar::kAlphaOne;

  std::uint64_t det = 0;
  std::uint64_t sup = 0;
  const unsigned n_frames = 5;

  for (unsigned f = 0; f < n_frames; ++f) {
    std::vector<std::uint64_t> bins = random_noise(rng, kFrameBins, 1, 50000);
    const std::vector<cfar::Event> got =
        drive_and_check(dev, false, bins, cfg, 0, 1500 + f,
                        "counter frame " + std::to_string(f), "event",
                        &g_counters.event);
    for (const cfar::Event& e : got) {
      if (e.kind != cfar::kEvSummary) continue;
      det += e.det_count;
      sup += e.sup_count;
    }
  }

  dev->raw_top()->eval();
  if (dev->raw_top()->stat_det_count != det) {
    fail("counters", &g_counters.counters,
         "CFAR_DET_COUNT reads " + std::to_string(dev->raw_top()->stat_det_count) +
             ", the summaries total " + std::to_string(det));
  }
  if (dev->raw_top()->stat_sup_count != sup) {
    fail("counters", &g_counters.counters,
         "CFAR_SUP_COUNT reads " + std::to_string(dev->raw_top()->stat_sup_count) +
             ", the summaries total " + std::to_string(sup));
  }
  if (dev->raw_top()->stat_frame_count != n_frames) {
    fail("counters", &g_counters.counters,
         "CFAR_FRAME_COUNT reads " +
             std::to_string(dev->raw_top()->stat_frame_count) + ", expected " +
             std::to_string(n_frames));
  }
  if (det == 0 || sup == 0) {
    fail("coverage", &g_counters.coverage,
         "the counter pass observed no detections or no suppressions, so the "
         "counters were compared against zero");
  }
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

  auto top = std::make_unique<Vcfar_top>();
  const harness::SeedSource seeds(args.seed);

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
  dev.reset(base_config());

  pass_targets(&dev);
  pass_edges(&dev);
  pass_threshold(&dev);
  pass_masking(&dev);
  pass_modes(&dev, seeds.engine("cfar.modes"));
  pass_random(&dev, seeds.engine("cfar.random"), false, 12, "random");
  pass_invariance(&dev, seeds.engine("cfar.invariance"), seeds.engine("cfar.bp"));
  pass_reconfig(&dev);
  pass_faults(&dev);
  pass_counters(&dev, seeds.engine("cfar.counters"));

  // ---- pass 12: the second elaboration -------------------------------------
  pass_random(&dev, seeds.engine("cfar.narrow"), true, 8, "narrow elaboration");

  if (dev.events_seen() == 0) {
    fail("coverage", &g_counters.coverage, "the run observed no events at all");
  }

  const bool passed = g_counters.total() == 0;

  std::printf("--- CFAR detector ---\n");
  std::printf("  geometry A       : MAX_GUARD %u, MAX_REF %u, half-window %u, slots %u\n",
              kMaxGuardA, kMaxRefA, cfar::half_window(kMaxGuardA, kMaxRefA),
              cfar::window_slots(kMaxGuardA, kMaxRefA));
  std::printf("  geometry B       : MAX_GUARD %u, MAX_REF %u\n", kMaxGuardB, kMaxRefB);
  std::printf("  event width      : %u bits\n", cfar::kEventW);
  std::printf("  cycles           : %llu\n",
              static_cast<unsigned long long>(dev.cycles()));
  std::printf("  events checked   : %llu against the C++ model\n",
              static_cast<unsigned long long>(dev.events_seen()));
  std::printf("  event mismatch   : %zu\n", g_counters.event);
  std::printf("  framing          : %zu\n", g_counters.framing);
  std::printf("  edge suppression : %zu\n", g_counters.edge);
  std::printf("  threshold        : %zu\n", g_counters.threshold);
  std::printf("  masking          : %zu\n", g_counters.masking);
  std::printf("  modes            : %zu\n", g_counters.mode);
  std::printf("  invariance       : %zu\n", g_counters.invariance);
  std::printf("  reconfiguration  : %zu\n", g_counters.reconfig);
  std::printf("  faults           : %zu\n", g_counters.fault);
  std::printf("  counters         : %zu\n", g_counters.counters);
  std::printf("  event packing    : %zu\n", g_counters.packing);
  std::printf("  coverage         : %zu\n", g_counters.coverage);
  std::printf("  hangs            : %zu\n", g_counters.hang);

  const auto wall_end = std::chrono::steady_clock::now();
  RunSummary summary;
  summary.test_name = kTestName;
  summary.config_name = sim_config::kName;
  summary.build_mode = args.build_mode;
  summary.seed = args.seed;
  summary.passed = passed;
  summary.stop_reason = passed ? "pass" : "error";
  summary.stop_detail =
      passed ? "every detection event bit-exact against the C++ model"
             : "CFAR mismatch; see errors_by_category";
  summary.passes = 12;
  summary.core_cycles = dev.cycles();
  summary.beats_observed = dev.events_seen();
  summary.absorb(errors);
  summary.wall_time_s =
      std::chrono::duration<double>(wall_end - wall_start).count();
  const std::string written = summary.write(args.results_dir);
  if (!written.empty()) std::printf("  summary json     : %s\n", written.c_str());

  top->final();

  if (passed) {
    std::printf("RESULT: PASS seed=%llu test=%s config=%s events=%llu\n",
                static_cast<unsigned long long>(args.seed), kTestName,
                sim_config::kName,
                static_cast<unsigned long long>(dev.events_seen()));
    return 0;
  }
  std::printf(
      "RESULT: FAIL seed=%llu test=%s config=%s event=%zu framing=%zu edge=%zu "
      "threshold=%zu masking=%zu mode=%zu invariance=%zu reconfig=%zu fault=%zu "
      "counters=%zu packing=%zu coverage=%zu hang=%zu\n",
      static_cast<unsigned long long>(args.seed), kTestName, sim_config::kName,
      g_counters.event, g_counters.framing, g_counters.edge, g_counters.threshold,
      g_counters.masking, g_counters.mode, g_counters.invariance,
      g_counters.reconfig, g_counters.fault, g_counters.counters,
      g_counters.packing, g_counters.coverage, g_counters.hang);
  return 1;
}
