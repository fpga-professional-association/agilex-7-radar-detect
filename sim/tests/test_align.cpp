// -----------------------------------------------------------------------------
// test_align — SPEC.md 13 verification of the frequency-bin alignment network
// (issue #16). Top: sim/verilator/tops/align_top.sv.
//
// SPEC 7.4 asks for TWO architectures and a comparison. The organising principle
// of this file is therefore that the two are never tested differently: one suite
// runs, unchanged, against each of `align_top`'s four DUTs — crossbar and omega,
// at two widths — and the pass criteria are identical. Anything that differs
// between them is a MEASUREMENT (blocking rate, throughput), not an expectation.
//
//   1  geometry        every DUT reports the geometry and the two latencies this
//                      file models, before any stimulus runs
//   2  in-order        zero-skew responses, several frames, every beat compared
//                      bit-for-bit against model/cpp/align/align_model.hpp
//   3  skew            randomized per-port response delay, so the responses for
//                      one beat arrive on different cycles and in an order the
//                      schedule's rotation makes different every group
//   4  reorder stress  wide skew plus request-port stalls: the case where two
//                      responses collide on one lane, which is the only thing
//                      that distinguishes the two architectures
//   5  missing         one response never returned. The beat is emitted with its
//                      absent lanes zeroed and ALGN_USER_MISSING set, and the
//                      counters are exact
//   6  duplicate       one response returned twice. The second is counted and
//                      DROPPED — the first copy is the one in the beat
//   7  backpressure    the same stimulus at four stall profiles must produce a
//                      BYTE-IDENTICAL beat sequence and identical counters
//   8  tag collision   SPEC 9 injection: one group's entry is opened under the
//                      wrong label, and every one of its responses is rejected
//   9  frame identity  one response carries a different absolute frame id. It is
//                      rejected, because a beat assembled across a rotation is
//                      the failure SPEC 7.4 exists to prevent
//  10  throughput      beats per cycle with nothing stalled, measured and
//                      reported for both architectures
//  11  coverage        the run must have exercised the network: multi-lane
//                      cycles, every lane used, and a non-trivial blocking count
//
// Build: sim/verilator/files_align.f, `make sim-tiny`.
// -----------------------------------------------------------------------------

#include <algorithm>
#include <chrono>
#include <cstdint>
#include <cstdio>
#include <deque>
#include <map>
#include <memory>
#include <random>
#include <string>
#include <vector>

#include "Valign_top.h"
#include "verilated.h"

#include "config_sim.h"

#include "harness/error_collector.h"
#include "harness/clock_scheduler.h"
#include "harness/random.h"
#include "harness/reset_sequencer.h"
#include "harness/run_summary.h"
#include "harness/sim_args.h"
#include "harness/sim_time.h"

#include "align/align_model.hpp"

using harness::BackpressureConfig;
using harness::BackpressureGenerator;
using harness::ErrorCollector;
using harness::ClockScheduler;
using harness::ResetSequencer;
using harness::RunSummary;
using harness::SimArgs;
using harness::SimTime;
using harness::StopReason;

namespace {

constexpr const char* kTestName = "test_align";

// The absolute frame number the modelled history serves for frame offset 0.
// Arbitrary and large, so a frame id can never be confused with a bin, a group
// or a counter in a failure message.
constexpr std::uint32_t kFrameBase = 0x0A5A0000u;

struct Counters {
  std::size_t geometry   = 0;
  std::size_t data       = 0;
  std::size_t framing    = 0;
  std::size_t counter    = 0;
  std::size_t protocol   = 0;
  std::size_t detection  = 0;
  std::size_t invariance = 0;
  std::size_t throughput = 0;
  std::size_t coverage   = 0;
  std::size_t hang       = 0;

  std::size_t total() const {
    return geometry + data + framing + counter + protocol + detection +
           invariance + throughput + coverage + hang;
  }
};

Counters g_counters;
ErrorCollector* g_errors = nullptr;

void fail(const char* category, std::size_t* counter, const std::string& msg) {
  ++*counter;
  g_errors->error(category, msg);
}

// ---------------------------------------------------------------------------
// The four DUTs, mirroring align_top's table exactly.
// ---------------------------------------------------------------------------
struct DutSpec {
  unsigned      sel;
  algn::Config  cfg;
  unsigned      mux_stages;
  const char*   name;
};

const std::vector<DutSpec>& duts() {
  static const std::vector<DutSpec> table = {
      {0, algn::Config{2, 64, 1, 4, 16, 4, 8, 0, 1}, 1, "crossbar 4bin/2ant"},
      {1, algn::Config{2, 64, 1, 4, 16, 4, 8, 1, 1}, 1, "omega    4bin/2ant"},
      {2, algn::Config{4, 64, 1, 4, 16, 8, 8, 0, 2}, 2, "crossbar 8bin/4ant"},
      {3, algn::Config{4, 64, 1, 4, 16, 8, 8, 1, 2}, 2, "omega    8bin/4ant"},
  };
  return table;
}

// align_pkg's latency arithmetic, mirrored so the geometry pass can check the
// DUT's echo against this file rather than against itself.
unsigned xbar_latency(unsigned mux_stages) { return 1 + (mux_stages ? mux_stages : 1); }
unsigned clos_latency(unsigned width) {
  unsigned w = 0;
  while ((1u << w) < width) ++w;
  return w == 0 ? 1u : w;
}
unsigned net_latency(const DutSpec& d) {
  return d.cfg.net_sel == 1 ? clos_latency(d.cfg.bin_par)
                            : xbar_latency(d.mux_stages);
}
unsigned block_latency(const DutSpec& d) { return 1 + net_latency(d) + 1 + 1; }

// The response value the modelled history returns. A pure function of what the
// request asked for, so a sample that arrives at the wrong beat position, the
// wrong antenna slot or from the wrong frame is a different number.
fxp::Complex gen_sample(unsigned bin, unsigned ant, std::uint32_t frame_id) {
  std::uint64_t h = 0x9E3779B97F4A7C15ULL;
  h ^= static_cast<std::uint64_t>(bin) * 0x0000000100000001ULL;
  h ^= static_cast<std::uint64_t>(ant) * 0xFF51AFD7ED558CCDULL;
  h ^= static_cast<std::uint64_t>(frame_id) * 0xC4CEB9FE1A85EC53ULL;
  h ^= h >> 29;
  h *= 0xBF58476D1CE4E5B9ULL;
  h ^= h >> 32;
  return fxp::Complex{static_cast<fxp::i16>(h & 0xFFFFU),
                      static_cast<fxp::i16>((h >> 16) & 0xFFFFU)};
}

// A response waiting in a modelled history read port.
struct PortRsp {
  unsigned      bin      = 0;
  unsigned      foff     = 0;
  std::uint32_t frame_id = 0;
  unsigned      flags    = 0;
  std::uint64_t due      = 0;   // cycle at which it becomes presentable
};

// ---------------------------------------------------------------------------
// One DUT session: the clock, the reset, the modelled history ports, the model
// and the scoreboard.
// ---------------------------------------------------------------------------
class Session {
 public:
  Session(Valign_top* top, const DutSpec& d, ErrorCollector* errors,
          std::uint64_t seed)
      : top_(top),
        dut_(d),
        model_(d.cfg),
        sched_([top]() { top->eval(); }),
        errors_(errors),
        skew_rng_(seed ^ 0xA11602ULL),
        bp_rng_(seed ^ 0xB1160DULL),
        req_rng_(seed ^ 0xC1160EULL) {
    top_->dut_sel = static_cast<std::uint8_t>(d.sel);
    idle_inputs();
    clk_ = sched_.add_clock("clk", harness::half_period_ps(harness::kHistoryClkMhz),
                            &top_->clk, true);
    errors_->set_time_probe(sched_.time_ptr());
    limit_ = static_cast<SimTime>(4000000) *
             harness::half_period_ps(harness::kHistoryClkMhz) * 2;
    reset_ = std::make_unique<ResetSequencer>(sched_);
    reset_->add_domain("rst_n", clk_, &top_->rst_n, 8);
    sched_.on_posedge_sample(clk_, [this]() { sample(); });
    sched_.on_posedge_drive(clk_, [this]() { drive(); });
  }

  // ---- setup -------------------------------------------------------------
  bool reset() {
    idle_inputs();
    clear_state();
    reset_->assert_all();
    if (reset_->release_all(limit_) != StopReason::kRunning) return false;
    top_->cfg_enable = 1;
    model_.reset();
    return settle(8);
  }

  void clear_state() {
    for (auto& q : pend_) q.clear();
    grp_seen_.clear();
    grp_foff_.clear();
    obs_.clear();
    exp_.clear();
    opened_   = 0;
    beats_    = 0;
    mismatch_ = 0;
    drop_bin_  = kNone;
    dup_bin_   = kNone;
    fid_bin_   = kNone;
    fast_port_ = kNone;
    mislabel_next_ = false;
  }

  const DutSpec& dut() const { return dut_; }
  const algn::Config& cfg() const { return dut_.cfg; }
  algn::Model& model() { return model_; }

  void set_run(bool on) { top_->cfg_run = on ? 1 : 0; }
  void set_partial_pass(bool on) { top_->cfg_partial_pass = on ? 1 : 0; }
  void set_skew(unsigned lo, unsigned hi) { skew_lo_ = lo; skew_hi_ = hi; }
  void set_req_stall(double p) { req_stall_ = p; }
  void set_lane_stall(unsigned mask) {
    top_->cfg_lane_stall = static_cast<std::uint8_t>(mask);
  }
  void set_backpressure(const BackpressureConfig& c) {
    bp_ = std::make_unique<BackpressureGenerator>(bp_rng_, c);
  }
  void reseed(std::uint64_t s) {
    skew_rng_.seed(s ^ 0xA11602ULL);
    bp_rng_.seed(s ^ 0xB1160DULL);
    req_rng_.seed(s ^ 0xC1160EULL);
  }

  void inject_drop(unsigned bin) { drop_bin_ = bin; }
  void inject_bad_fid(unsigned bin) { fid_bin_ = bin; }

  // Duplicate the response for `bin`. Every port except the one that bin is
  // requested on is slowed down, so the duplicate is guaranteed to reach the
  // collector while its entry is still open.
  void inject_dup(unsigned bin) {
    dup_bin_ = bin;
    const unsigned grp  = algn::group_of_bin(cfg(), bin);
    const unsigned lane = algn::lane_of_bin(cfg(), bin);
    fast_port_ = algn::port_of(cfg(), grp, lane);
    set_skew(8, 8);
  }
  void clear_inject() {
    drop_bin_  = kNone;
    dup_bin_   = kNone;
    fid_bin_   = kNone;
    fast_port_ = kNone;
  }

  // SPEC 9 tag-collision injection. Armed while the sweep gate is closed, so
  // the group it corrupts is unambiguously the next one issued.
  bool arm_force_unsafe() {
    top_->cfg_force_unsafe = 1;
    if (!settle(1)) return false;
    top_->cfg_force_unsafe = 0;
    mislabel_next_ = true;
    return settle(2);
  }

  // ---- running -----------------------------------------------------------
  bool settle(std::uint64_t n) {
    return sched_.run_cycles(clk_, n, limit_) == StopReason::kRunning;
  }

  // Run until `n` beats have been observed, or give up.
  bool run_to_beats(std::size_t n, std::uint64_t budget) {
    std::uint64_t spent = 0;
    while (beats_ < n && spent < budget) {
      if (!settle(64)) return false;
      spent += 64;
    }
    if (beats_ < n) {
      fail("hang", &g_counters.hang,
           std::string(dut_.name) + ": only " + std::to_string(beats_) +
               " of " + std::to_string(n) + " beats appeared in " +
               std::to_string(budget) + " cycles");
      return false;
    }
    return true;
  }

  // Close the tap at the next frame boundary and run until everything the block
  // opened has retired. `cfg_enable` stays high throughout — see align_net's
  // `cfg_run` comment for why disabling instead would strand the in-flight work.
  bool quiesce(std::uint64_t budget) {
    set_run(false);
    std::uint64_t spent = 0;
    while (spent < budget) {
      if (idle()) return settle(8);
      if (!settle(64)) return false;
      spent += 64;
    }
    fail("hang", &g_counters.hang,
         std::string(dut_.name) + ": did not quiesce — " +
             std::to_string(opened_) + " groups opened, " +
             std::to_string(beats_) + " beats out, " +
             std::to_string(pending()) + " responses still queued");
    return false;
  }

  bool idle() const {
    return pending() == 0 && beats_ == opened_ && grp_seen_.empty();
  }

  std::size_t pending() const {
    std::size_t n = 0;
    for (const auto& q : pend_) n += q.size();
    return n;
  }

  std::size_t beats() const { return beats_; }
  std::size_t opened() const { return opened_; }
  std::size_t mismatches() const { return mismatch_; }
  const std::vector<algn::Beat>& observed() const { return obs_; }
  std::uint64_t cycles() const { return sched_.cycles(clk_); }

  // ---- DUT counters ------------------------------------------------------
  algn::Model::Counters dut_counters() const {
    algn::Model::Counters c;
    c.beats   = top_->stat_beat_count;
    c.missing = top_->stat_missing_count;
    c.dup     = top_->stat_dup_count;
    c.orphan  = top_->stat_orphan_count;
    c.timeout = top_->stat_timeout_count;
    return c;
  }
  std::uint32_t dut_fault() const { return top_->stat_fault; }
  std::uint32_t dut_conflicts() const { return top_->stat_conflict_count; }
  std::uint32_t dut_multi_lane() const { return top_->stat_multi_lane_count; }
  std::uint32_t dut_lane_words() const { return top_->stat_lane_word_count; }
  std::uint32_t dut_lane_seen() const { return top_->stat_lane_seen; }
  std::uint32_t dut_inject() const { return top_->stat_inject_count; }
  std::uint32_t dut_issues() const { return top_->stat_issue_count; }
  std::uint32_t dut_stalls() const { return top_->stat_issue_stall_count; }

 private:
  static constexpr unsigned kNone = 0xFFFFFFFFu;

  void idle_inputs() {
    top_->cfg_enable        = 0;
    top_->cfg_run           = 0;
    top_->cfg_frame_off     = 0;
    top_->cfg_partial_pass  = 0;
    top_->cfg_counter_clear = 0;
    top_->cfg_sticky_clear  = 0;
    top_->cfg_lane_stall    = 0;
    top_->cfg_force_unsafe  = 0;
    top_->rd_req_ready      = 0;
    top_->rsp_valid         = 0;
    top_->m_ready           = 1;
    for (int i = 0; i < 32; ++i) top_->rsp_vec[i] = 0;
    for (int i = 0; i < 4; ++i) {
      top_->rsp_bin[i] = 0;
      top_->rsp_frame_off[i] = 0;
    }
    for (int i = 0; i < 8; ++i) top_->rsp_frame_id[i] = 0;
    top_->rsp_flags = 0;
  }

  // ---- drive -------------------------------------------------------------
  void drive() {
    const unsigned bp = cfg().bin_par;

    // Request ports: accept unless this pass is stalling them.
    std::uint8_t rdy = 0;
    for (unsigned p = 0; p < bp; ++p) {
      const bool stall = req_stall_ > 0.0 && harness::bernoulli(req_rng_, req_stall_);
      if (!stall) rdy |= static_cast<std::uint8_t>(1u << p);
    }
    top_->rd_req_ready = rdy;

    // Response ports: present the head of each queue once it is due.
    std::uint8_t rv = 0;
    std::uint64_t flags = 0;
    for (unsigned p = 0; p < bp; ++p) {
      if (pend_[p].empty()) continue;
      const PortRsp& r = pend_[p].front();
      if (r.due > sched_.cycles(clk_)) continue;
      rv |= static_cast<std::uint8_t>(1u << p);
      set16(top_->rsp_bin, p, r.bin);
      set16(top_->rsp_frame_off, p, r.foff);
      top_->rsp_frame_id[p] = r.frame_id;
      flags |= static_cast<std::uint64_t>(r.flags & 0xFFu) << (p * 8);
      for (unsigned a = 0; a < 4; ++a) {
        top_->rsp_vec[p * 4 + a] =
            a < cfg().n_ant ? gen_sample(r.bin, a, r.frame_id).packed() : 0u;
      }
    }
    top_->rsp_valid = rv;
    top_->rsp_flags = flags;

    top_->m_ready = (bp_ && !bp_->allow()) ? 0 : 1;
  }

  // ---- sample ------------------------------------------------------------
  void sample() {
    const unsigned bp = cfg().bin_par;
    const std::uint64_t now = sched_.cycles(clk_);

    // 1. Requests accepted -> queue responses, and open groups in the model.
    for (unsigned p = 0; p < bp; ++p) {
      const bool v = (top_->rd_req_valid >> p) & 1u;
      const bool r = (top_->rd_req_ready >> p) & 1u;
      if (!v || !r) continue;
      const unsigned bin  = get16(top_->rd_req_bin, p);
      const unsigned foff = get16(top_->rd_req_frame_off, p);
      accept_request(p, bin, foff, now);
    }

    // 2. Responses accepted -> feed the model, IN LANE ORDER.
    //
    // Sorted, not taken in port order, and it matters: when several responses
    // reach one entry in the same cycle before it has fixed a frame number, the
    // RTL's reference is the lowest-numbered LANE (align_collect, "The
    // absolute-frame test"). The rotating schedule means port order and lane
    // order differ on every group but the first, so feeding the model in port
    // order would give it a different reference and a different verdict — and
    // the disagreement would look like an RTL defect.
    {
      std::vector<PortRsp> arrived;
      for (unsigned p = 0; p < bp; ++p) {
        const bool v = (top_->rsp_valid >> p) & 1u;
        const bool r = (top_->rsp_ready >> p) & 1u;
        if (!v || !r || pend_[p].empty()) continue;
        arrived.push_back(pend_[p].front());
        pend_[p].pop_front();
      }
      std::sort(arrived.begin(), arrived.end(),
                [this](const PortRsp& a, const PortRsp& b) {
                  return algn::lane_of_bin(cfg(), a.bin) <
                         algn::lane_of_bin(cfg(), b.bin);
                });
      for (const PortRsp& got : arrived) {
        algn::Word w;
        w.vec.resize(cfg().n_ant);
        for (unsigned a = 0; a < cfg().n_ant; ++a) {
          w.vec[a] = gen_sample(got.bin, a, got.frame_id);
        }
        w.bin       = got.bin;
        w.frame_off = got.foff;
        w.frame_id  = got.frame_id;
        w.flags     = got.flags;
        model_.deliver(w);
      }
    }

    // 3. A beat left the block -> retire in the model and compare.
    if (top_->m_valid && top_->m_ready) check_beat();
  }

  void accept_request(unsigned port, unsigned bin, unsigned foff,
                      std::uint64_t now) {
    // The request must be one the rotating schedule would have put on this
    // port. Checking it here is what makes the schedule itself verified rather
    // than merely assumed by the response model.
    const unsigned grp  = algn::group_of_bin(cfg(), bin);
    const unsigned lane = algn::lane_of_bin(cfg(), bin);
    if (algn::port_of(cfg(), grp, lane) != port) {
      fail("protocol", &g_counters.protocol,
           std::string(dut_.name) + ": bin " + std::to_string(bin) +
               " (group " + std::to_string(grp) + ", lane " +
               std::to_string(lane) + ") was requested on port " +
               std::to_string(port) + ", but the schedule puts it on port " +
               std::to_string(algn::port_of(cfg(), grp, lane)));
    }

    const std::uint32_t fid = kFrameBase - foff;

    // THE MODEL OPENS THE GROUP ON THE FIRST REQUEST OF IT THAT IS TAKEN, not on
    // the last. The block allocates its reassembly entry at ISSUE — all BIN_PAR
    // requests are loaded into their port holds in one cycle — so with the
    // request ports stalling independently, the response to the first request
    // can be back before the last one has even been accepted. Opening on the
    // last would make the model reject that response as an orphan while the DUT
    // correctly writes it. Opening on the first is exact: the scheduler cannot
    // issue group g+1 until every port has taken group g's request, so first
    // acceptances are strictly in group order.
    if (grp_seen_.find(grp) == grp_seen_.end()) {
      model_.open(grp, foff, mislabel_next_);
      mislabel_next_ = false;
      ++opened_;
    }
    ++grp_seen_[grp];
    if (grp_seen_[grp] == cfg().bin_par) grp_seen_.erase(grp);

    if (bin == drop_bin_) {
      // One-shot: the sweep runs more than one frame, and an injection that
      // repeated every frame would make "exactly one missing sample" untrue.
      drop_bin_ = kNone;
      return;
    }

    PortRsp r;
    r.bin      = bin;
    r.foff     = foff;
    r.frame_id = fid;
    r.flags    = 0;
    r.due      = now + 1 + skew(port);
    if (bin == fid_bin_) {
      r.frame_id = fid ^ 0x1u;
      fid_bin_   = kNone;
    }
    pend_[port].push_back(r);

    if (bin == dup_bin_) {
      // The duplicate is queued immediately behind the original on the same
      // port. It must reach the collector BEFORE the entry retires, or it is an
      // orphan rather than a duplicate — a real and different condition with its
      // own pass. `fast_port_` is what guarantees that: every OTHER port is held
      // back, so the group cannot be complete when the duplicate arrives.
      PortRsp d = r;
      d.due     = r.due + 1;
      pend_[port].push_back(d);
      dup_bin_ = kNone;
    }
  }

  void check_beat() {
    algn::Beat obs;
    obs.data.assign(static_cast<std::size_t>(cfg().bin_par) * cfg().n_ant,
                    fxp::Complex{});
    for (unsigned l = 0; l < cfg().bin_par; ++l) {
      for (unsigned a = 0; a < cfg().n_ant; ++a) {
        const std::size_t idx = static_cast<std::size_t>(l) * cfg().n_ant + a;
        obs.data[idx] = fxp::Complex::from_packed(top_->m_data[idx]);
      }
    }
    obs.sof  = top_->m_sof != 0;
    obs.eof  = top_->m_eof != 0;
    obs.seq  = top_->m_seq;
    obs.user = top_->m_user & 0xFu;

    // The top's second view of the framing bits, decoded straight out of the
    // packed payload. Disagreement means a packing defect, not a data defect.
    const bool id_sof = (top_->m_id >> 7) & 1u;
    const bool id_eof = (top_->m_id >> 6) & 1u;
    if (id_sof != obs.sof || id_eof != obs.eof) {
      fail("framing", &g_counters.framing,
           std::string(dut_.name) + ": beat " + std::to_string(beats_) +
               " disagrees with itself about sof/eof");
    }

    const algn::Beat expv = model_.retire(top_->cfg_partial_pass != 0);
    obs_.push_back(obs);
    exp_.push_back(expv);
    ++beats_;

    if (obs != expv) {
      ++mismatch_;
      if (mismatch_ <= 8) {
        fail("data", &g_counters.data, describe_mismatch(obs, expv));
      }
    }
  }

  std::string describe_mismatch(const algn::Beat& o, const algn::Beat& e) const {
    std::string s = std::string(dut_.name) + ": beat " + std::to_string(beats_ - 1);
    if (o.seq != e.seq)  s += " seq " + std::to_string(o.seq) + " != " + std::to_string(e.seq);
    if (o.sof != e.sof)  s += " sof " + std::to_string(o.sof) + " != " + std::to_string(e.sof);
    if (o.eof != e.eof)  s += " eof " + std::to_string(o.eof) + " != " + std::to_string(e.eof);
    if (o.user != e.user) s += " user 0x" + std::to_string(o.user) + " != 0x" + std::to_string(e.user);
    for (std::size_t i = 0; i < o.data.size() && i < e.data.size(); ++i) {
      if (o.data[i] != e.data[i]) {
        s += " first sample mismatch at (lane " +
             std::to_string(i / cfg().n_ant) + ", antenna " +
             std::to_string(i % cfg().n_ant) + ")";
        break;
      }
    }
    return s;
  }

  unsigned skew(unsigned port) {
    if (port == fast_port_) return 0;
    if (skew_hi_ <= skew_lo_) return skew_lo_;
    return static_cast<unsigned>(
        harness::uniform_u64(skew_rng_, skew_lo_, skew_hi_));
  }

  static unsigned get16(const VlWide<4>& w, unsigned p) {
    return static_cast<unsigned>((w[p / 2] >> ((p % 2) * 16)) & 0xFFFFu);
  }
  static void set16(VlWide<4>& w, unsigned p, unsigned v) {
    const unsigned sh = (p % 2) * 16;
    w[p / 2] = (w[p / 2] & ~(0xFFFFu << sh)) |
               ((static_cast<std::uint32_t>(v) & 0xFFFFu) << sh);
  }

  Valign_top*   top_;
  DutSpec       dut_;
  algn::Model   model_;
  ClockScheduler sched_;
  ErrorCollector* errors_;
  std::unique_ptr<ResetSequencer> reset_;
  std::unique_ptr<BackpressureGenerator> bp_;
  std::mt19937_64 skew_rng_, bp_rng_, req_rng_;
  int           clk_ = 0;
  SimTime       limit_ = 0;

  std::deque<PortRsp> pend_[8];
  std::map<unsigned, unsigned> grp_seen_;
  std::map<unsigned, unsigned> grp_foff_;
  std::vector<algn::Beat> obs_, exp_;
  std::size_t opened_ = 0, beats_ = 0, mismatch_ = 0;
  unsigned    skew_lo_ = 0, skew_hi_ = 0;
  double      req_stall_ = 0.0;
  unsigned    drop_bin_ = kNone, dup_bin_ = kNone, fid_bin_ = kNone;
  unsigned    fast_port_ = kNone;
  bool        mislabel_next_ = false;
};

// ---------------------------------------------------------------------------
// Helpers shared by the passes
// ---------------------------------------------------------------------------
void compare_counters(Session& s, const char* what) {
  const algn::Model::Counters m = s.model().counters();
  const algn::Model::Counters d = s.dut_counters();
  auto one = [&](const char* name, std::uint32_t mv, std::uint32_t dv) {
    if (mv != dv) {
      fail("counter", &g_counters.counter,
           std::string(s.dut().name) + " " + what + ": " + name +
               " is " + std::to_string(dv) + ", the model says " +
               std::to_string(mv));
    }
  };
  one("beat_count", m.beats, d.beats);
  one("missing_count", m.missing, d.missing);
  one("dup_count", m.dup, d.dup);
  one("orphan_count", m.orphan, d.orphan);
  one("timeout_count", m.timeout, d.timeout);
  if (s.model().fault() != s.dut_fault()) {
    fail("counter", &g_counters.counter,
         std::string(s.dut().name) + " " + what + ": sticky fault is 0x" +
             std::to_string(s.dut_fault()) + ", the model says 0x" +
             std::to_string(s.model().fault()));
  }
}

// One clean run: reset, sweep `frames` frames, quiesce, compare counters.
bool sweep(Session& s, unsigned frames, const char* what) {
  if (!s.reset()) return false;
  s.set_run(true);
  const std::size_t want =
      static_cast<std::size_t>(frames) * s.cfg().groups_per_frame();
  if (!s.run_to_beats(want, 200000)) return false;
  if (!s.quiesce(200000)) return false;
  compare_counters(s, what);
  return true;
}

}  // namespace

// ---------------------------------------------------------------------------
int harness::sim_test_main(const SimArgs& args) {
  const auto wall_start = std::chrono::steady_clock::now();

  ErrorCollector errors;
  g_errors = &errors;
  g_counters = Counters{};

  auto top = std::make_unique<Valign_top>();
  harness::SeedSource seeds(args.seed);

  std::size_t beats_total = 0;
  std::uint32_t conflicts[4] = {0, 0, 0, 0};
  double efficiency[4] = {0.0, 0.0, 0.0, 0.0};

  // ---- pass 1: geometry ---------------------------------------------------
  for (const DutSpec& d : duts()) {
    top->dut_sel = static_cast<std::uint8_t>(d.sel);
    top->eval();
    auto chk = [&](const char* name, unsigned got, unsigned want) {
      if (got != want) {
        fail("geometry", &g_counters.geometry,
             std::string(d.name) + ": " + name + " is " + std::to_string(got) +
                 ", this test models " + std::to_string(want));
      }
    };
    chk("net_sel", top->geo_net_sel, d.cfg.net_sel);
    chk("bin_par", top->geo_bin_par, d.cfg.bin_par);
    chk("groups", top->geo_groups, d.cfg.groups);
    chk("n_ant", top->geo_n_ant, d.cfg.n_ant);
    chk("fft_size", top->geo_fft_size, d.cfg.fft_size);
    chk("net_latency", top->geo_net_latency, net_latency(d));
    chk("block_latency", top->geo_block_latency, block_latency(d));
    chk("n_duts", top->geo_n_duts, static_cast<unsigned>(duts().size()));
    if (!d.cfg.valid()) {
      fail("geometry", &g_counters.geometry,
           std::string(d.name) + ": the modelled geometry is illegal");
    }
  }
  // The pairs must be latency-matched, or the comparison in the pull request is
  // between two pipeline depths rather than two topologies.
  for (std::size_t i = 0; i + 1 < duts().size(); i += 2) {
    if (net_latency(duts()[i]) != net_latency(duts()[i + 1])) {
      fail("geometry", &g_counters.geometry,
           std::string("the ") + duts()[i].name + " / " + duts()[i + 1].name +
               " pair is not latency-matched (" +
               std::to_string(net_latency(duts()[i])) + " vs " +
               std::to_string(net_latency(duts()[i + 1])) + ")");
    }
  }
  if (g_counters.geometry != 0) {
    std::printf("RESULT: FAIL seed=%llu test=%s config=%s geometry=%zu\n",
                static_cast<unsigned long long>(args.seed), kTestName,
                sim_config::kName, g_counters.geometry);
    return 1;
  }

  // ---- passes 2..11, per DUT ---------------------------------------------
  for (std::size_t di = 0; di < duts().size(); ++di) {
    const DutSpec& d = duts()[di];
    Session s(top.get(), d, &errors, seeds.substream_seed("align.dut"));

    // -- pass 2: in-order, zero skew --------------------------------------
    s.set_skew(0, 0);
    if (!sweep(s, 2, "in-order")) break;
    beats_total += s.beats();
    if (s.mismatches() != 0) {
      fail("data", &g_counters.data,
           std::string(d.name) + ": in-order pass had " +
               std::to_string(s.mismatches()) + " mismatched beats");
    }

    // -- pass 3: randomized skew, three seeds ------------------------------
    for (unsigned k = 0; k < 3; ++k) {
      s.reseed(seeds.substream_seed("align.skew") + k);
      s.set_skew(0, 6);
      if (!sweep(s, 2, "skew")) break;
      beats_total += s.beats();
      if (s.model().counters().timeout != 0) {
        fail("detection", &g_counters.detection,
             std::string(d.name) +
                 ": ordinary skew produced a timeout, so the timeout bound is "
                 "too tight for the honest round trip");
      }
    }

    // -- pass 4: reorder stress -------------------------------------------
    s.reseed(seeds.substream_seed("align.stress"));
    s.set_skew(0, 12);
    s.set_req_stall(0.25);
    s.set_backpressure(BackpressureConfig::light());
    if (!sweep(s, 2, "stress")) break;
    beats_total += s.beats();
    conflicts[di] = s.dut_conflicts();
    s.set_req_stall(0.0);
    s.set_backpressure(BackpressureConfig::none());

    // -- pass 5: missing response ------------------------------------------
    {
      s.set_skew(0, 0);
      if (!s.reset()) break;
      // A bin in the second group of the frame, so the loss is not confused
      // with a start-up effect.
      const unsigned lost = d.cfg.bin_par + 1;
      s.inject_drop(lost);
      s.set_run(true);
      if (!s.run_to_beats(d.cfg.groups_per_frame(), 200000)) break;
      if (!s.quiesce(200000)) break;
      compare_counters(s, "missing");
      const algn::Model::Counters c = s.dut_counters();
      if (c.missing != 1) {
        fail("detection", &g_counters.detection,
             std::string(d.name) + ": one dropped response produced " +
                 std::to_string(c.missing) + " missing samples, expected 1");
      }
      if (c.timeout != 1) {
        fail("detection", &g_counters.detection,
             std::string(d.name) + ": one dropped response produced " +
                 std::to_string(c.timeout) + " timeouts, expected 1");
      }
      if ((s.dut_fault() & 0x1u) == 0) {
        fail("detection", &g_counters.detection,
             std::string(d.name) + ": the sticky MISSING fault did not set");
      }
      beats_total += s.beats();
      s.clear_inject();
    }

    // -- pass 6: duplicated response ---------------------------------------
    {
      if (!s.reset()) break;
      const unsigned twice = d.cfg.bin_par + 2;
      s.inject_dup(twice);
      s.set_run(true);
      if (!s.run_to_beats(d.cfg.groups_per_frame(), 200000)) break;
      if (!s.quiesce(200000)) break;
      compare_counters(s, "duplicate");
      const algn::Model::Counters c = s.dut_counters();
      if (c.dup != 1) {
        fail("detection", &g_counters.detection,
             std::string(d.name) + ": one duplicated response produced " +
                 std::to_string(c.dup) + " duplicate reports, expected 1");
      }
      if (c.missing != 0) {
        fail("detection", &g_counters.detection,
             std::string(d.name) +
                 ": a duplicate must not cost a sample, but " +
                 std::to_string(c.missing) + " were reported missing");
      }
      beats_total += s.beats();
      s.clear_inject();
    }

    // -- pass 7: backpressure invariance -----------------------------------
    {
      const BackpressureConfig profiles[4] = {
          BackpressureConfig::none(), BackpressureConfig::light(),
          BackpressureConfig::heavy(), BackpressureConfig::bursty()};
      // The number of beats a run produces past its target depends on exactly
      // when the sweep gate closes, which backpressure legitimately moves. What
      // must not move is the CONTENT: the first `want` beats have to be
      // byte-identical, and every run's counters have to agree with the model
      // (which `sweep` already checks). Comparing whole vectors instead would be
      // testing when the test decided to stop.
      const std::size_t want = 2 * s.cfg().groups_per_frame();
      std::vector<algn::Beat> reference;
      bool ok = true;
      for (int pi = 0; pi < 4 && ok; ++pi) {
        s.reseed(seeds.substream_seed("align.bp") + static_cast<unsigned>(pi));
        s.set_skew(0, 4);
        s.set_backpressure(profiles[pi]);
        if (!sweep(s, 2, "backpressure")) { ok = false; break; }
        beats_total += s.beats();
        std::vector<algn::Beat> got = s.observed();
        if (got.size() > want) got.resize(want);
        if (pi == 0) {
          reference = got;
        } else if (got != reference) {
          fail("invariance", &g_counters.invariance,
               std::string(d.name) +
                   ": the beat sequence changed under backpressure profile " +
                   std::to_string(pi));
        }
      }
      s.set_backpressure(BackpressureConfig::none());
      if (!ok) break;
    }

    // -- pass 8: SPEC 9 tag collision --------------------------------------
    {
      if (!s.reset()) break;
      s.set_skew(0, 0);
      if (!s.arm_force_unsafe()) break;
      s.set_run(true);
      if (!s.run_to_beats(d.cfg.groups_per_frame(), 200000)) break;
      if (!s.quiesce(200000)) break;
      compare_counters(s, "tag collision");
      const algn::Model::Counters c = s.dut_counters();
      if (c.orphan != d.cfg.bin_par) {
        fail("detection", &g_counters.detection,
             std::string(d.name) + ": the injected tag collision produced " +
                 std::to_string(c.orphan) + " orphans, expected " +
                 std::to_string(d.cfg.bin_par));
      }
      if (c.missing != d.cfg.bin_par) {
        fail("detection", &g_counters.detection,
             std::string(d.name) + ": the injected tag collision left " +
                 std::to_string(c.missing) + " samples missing, expected " +
                 std::to_string(d.cfg.bin_par));
      }
      if (s.dut_inject() != 1) {
        fail("detection", &g_counters.detection,
             std::string(d.name) + ": the injection fired " +
                 std::to_string(s.dut_inject()) +
                 " times, and it is specified to be one-shot");
      }
      // Everything after the injected group must be clean, which is what makes
      // this an injection rather than damage.
      if (c.beats < 2 || s.mismatches() != 0) {
        fail("detection", &g_counters.detection,
             std::string(d.name) +
                 ": the run did not recover cleanly after the injected fault");
      }
      beats_total += s.beats();
    }

    // -- pass 9: frame identity --------------------------------------------
    {
      if (!s.reset()) break;
      s.set_skew(0, 0);
      const unsigned wrong = d.cfg.bin_par + 3;
      s.inject_bad_fid(wrong);
      s.set_run(true);
      if (!s.run_to_beats(d.cfg.groups_per_frame(), 200000)) break;
      if (!s.quiesce(200000)) break;
      compare_counters(s, "frame identity");
      const algn::Model::Counters c = s.dut_counters();
      if (c.orphan + c.missing == 0) {
        fail("detection", &g_counters.detection,
             std::string(d.name) +
                 ": a response from a different absolute frame was accepted "
                 "into a beat");
      }
      beats_total += s.beats();
      s.clear_inject();
    }

    // -- pass 10: throughput ------------------------------------------------
    {
      if (!s.reset()) break;
      s.set_skew(0, 0);
      s.set_run(true);
      const std::uint64_t c0 = s.cycles();
      const std::size_t want = 4 * d.cfg.groups_per_frame();
      if (!s.run_to_beats(want, 200000)) break;
      const std::uint64_t spent = s.cycles() - c0;
      efficiency[di] = spent ? static_cast<double>(s.beats()) /
                                   static_cast<double>(spent)
                             : 0.0;
      if (!s.quiesce(200000)) break;
      beats_total += s.beats();
      if (efficiency[di] < 0.50) {
        fail("throughput", &g_counters.throughput,
             std::string(d.name) + ": sustained only " +
                 std::to_string(efficiency[di]) +
                 " beats per cycle with nothing stalled");
      }
    }

    // -- pass 11: coverage --------------------------------------------------
    if (s.dut_multi_lane() == 0) {
      fail("coverage", &g_counters.coverage,
           std::string(d.name) +
               ": no cycle ever delivered two lanes at once, so the network was "
               "never asked to do anything a bundle of wires could not do");
    }
    const std::uint32_t all_lanes = (1u << d.cfg.bin_par) - 1u;
    if ((s.dut_lane_seen() & all_lanes) != all_lanes) {
      fail("coverage", &g_counters.coverage,
           std::string(d.name) + ": only lanes 0x" +
               std::to_string(s.dut_lane_seen()) + " of 0x" +
               std::to_string(all_lanes) + " were ever used");
    }
  }

  // The two architectures must not have been silently identical: if neither ever
  // blocked, the comparison in the pull request has nothing to compare.
  if (conflicts[0] + conflicts[1] + conflicts[2] + conflicts[3] == 0) {
    fail("coverage", &g_counters.coverage,
         "no architecture ever reported a routing conflict under the stress "
         "pass; the blocking-rate comparison would be vacuous");
  }

  const bool passed = g_counters.total() == 0;

  std::printf("--- frequency-bin alignment network ---\n");
  std::printf("  DUTs             : %zu\n", duts().size());
  std::printf("  beats compared   : %zu\n", beats_total);
  for (std::size_t i = 0; i < duts().size(); ++i) {
    std::printf("  %-20s blocking=%-8u efficiency=%.3f beats/cycle\n",
                duts()[i].name, conflicts[i], efficiency[i]);
  }
  std::printf("  data             : %zu\n", g_counters.data);
  std::printf("  detection        : %zu\n", g_counters.detection);
  std::printf("  invariance       : %zu\n", g_counters.invariance);
  std::printf("  counters         : %zu\n", g_counters.counter);
  std::printf("  coverage         : %zu\n", g_counters.coverage);

  const auto wall_end = std::chrono::steady_clock::now();
  RunSummary summary;
  summary.test_name   = kTestName;
  summary.config_name = sim_config::kName;
  summary.build_mode  = args.build_mode;
  summary.seed        = args.seed;
  summary.passed      = passed;
  summary.stop_reason = passed ? "pass" : "error";
  summary.stop_detail =
      passed ? "every beat of both architectures bit-exact against the C++ model"
             : "alignment mismatch; see errors_by_category";
  summary.passes         = 11;
  summary.core_cycles    = 0;
  summary.beats_observed = beats_total;
  summary.absorb(errors);
  summary.wall_time_s =
      std::chrono::duration<double>(wall_end - wall_start).count();
  const std::string written = summary.write(args.results_dir);
  if (!written.empty()) std::printf("  summary json     : %s\n", written.c_str());

  top->final();

  if (passed) {
    std::printf("RESULT: PASS seed=%llu test=%s config=%s beats=%zu\n",
                static_cast<unsigned long long>(args.seed), kTestName,
                sim_config::kName, beats_total);
    return 0;
  }
  std::printf(
      "RESULT: FAIL seed=%llu test=%s config=%s geometry=%zu data=%zu "
      "framing=%zu counter=%zu protocol=%zu detection=%zu invariance=%zu "
      "throughput=%zu coverage=%zu hang=%zu\n",
      static_cast<unsigned long long>(args.seed), kTestName, sim_config::kName,
      g_counters.geometry, g_counters.data, g_counters.framing,
      g_counters.counter, g_counters.protocol, g_counters.detection,
      g_counters.invariance, g_counters.throughput, g_counters.coverage,
      g_counters.hang);
  return 1;
}
