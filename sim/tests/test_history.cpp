// -----------------------------------------------------------------------------
// test_history — SPEC.md 13 verification of the time-frequency history and
// corner turn (issue #15). Top: sim/verilator/tops/history_top.sv.
//
// The block under test is a memory, and a memory test that only writes and reads
// back proves almost nothing: every interesting property of this one is about
// WHICH word a request means, WHEN a frame becomes readable, and what happens at
// the boundaries of those two. The passes are organised around that.
//
//   1  geometry          the three DUTs report the geometries this file models
//   2  exact             write past the depth, quiesce, then read every bin at
//                        every readable offset and compare bit-exactly against
//                        model/cpp/history/history_model.hpp — values, flags,
//                        metadata and all six counters
//   3  ratio sweep       pass 2 again at five core:history clock ratios,
//                        including 9:8 and 8:9, which are the ratios closest to
//                        the SPEC 8 constraint pair and the ones a pointer
//                        crossing is least likely to be accidentally safe at
//   4  overwrite         a shallow depth, many frames, exact overwrite and
//                        occupancy counts through several full rotations
//   5  depth change      a change requested mid-frame must WAIT, land at the
//                        boundary, bump the epoch and discard the history
//   6  random            random bins and offsets including out-of-range ones,
//                        three seeds, exact against the model
//   7  collision         fault injection removes the readable-set clamp so the
//                        collision counter is proved reachable, not just present
//   8  concurrent        continuous full-rate writes WITH reads in flight, over
//                        several rotations, checked by transaction identity
//   9  backpressure      the same request sequence at four backpressure profiles
//                        must produce a byte-identical response sequence
//
// WHAT IS CHECKED EXACTLY AND WHAT IS CHECKED BY IDENTITY. The read side works
// from a frame pointer published across a clock-domain crossing, so how many
// frames it can see at any instant is a function of the clock ratio and not of
// the stimulus. Passes 2, 4, 5, 6 and 7 therefore QUIESCE first — writes stop,
// the pointer settles — and after that the model predicts every bit. Pass 8 does
// not quiesce, and checks instead that every response's ANTENNA VECTOR matches
// the frame its own metadata claims it came from, plus one response per request,
// in order, none lost, none duplicated. That is SPEC 12.5's transaction-identity
// rule applied to a crossing rather than to a FIFO.
//
// Build: sim/verilator/files_history.f, `make sim-tiny`.
// -----------------------------------------------------------------------------

#include <chrono>
#include <cstdint>
#include <cstdio>
#include <deque>
#include <memory>
#include <random>
#include <string>
#include <vector>

#include "Vhistory_top.h"
#include "verilated.h"

#include "config_sim.h"

#include "harness/clock_ratios.h"
#include "harness/clock_scheduler.h"
#include "harness/error_collector.h"
#include "harness/random.h"
#include "harness/reset_sequencer.h"
#include "harness/run_summary.h"
#include "harness/sim_args.h"

#include "history/history_model.hpp"

using harness::BackpressureConfig;
using harness::BackpressureGenerator;
using harness::ClockRatio;
using harness::ClockScheduler;
using harness::ErrorCollector;
using harness::ResetSequencer;
using harness::RunSummary;
using harness::SimArgs;
using harness::SimTime;
using harness::StopReason;

namespace {

constexpr const char* kTestName = "test_history";

// -----------------------------------------------------------------------------
// Failure accounting
// -----------------------------------------------------------------------------
struct Counters {
  std::size_t geometry = 0;
  std::size_t data     = 0;
  std::size_t meta     = 0;
  std::size_t flags    = 0;
  std::size_t counter  = 0;
  std::size_t rotation = 0;
  std::size_t depth    = 0;
  std::size_t protocol = 0;
  std::size_t identity = 0;
  std::size_t invariance = 0;
  std::size_t coverage = 0;
  std::size_t hang     = 0;

  std::size_t total() const {
    return geometry + data + meta + flags + counter + rotation + depth +
           protocol + identity + invariance + coverage + hang;
  }
};

Counters g_counters;
ErrorCollector* g_errors = nullptr;

void fail(const char* category, std::size_t* counter, const std::string& msg) {
  ++*counter;
  g_errors->error(category, msg);
}

// -----------------------------------------------------------------------------
// The three DUTs, mirroring the table in sim/verilator/tops/history_top.sv
// -----------------------------------------------------------------------------
struct DutSpec {
  unsigned     sel;
  hist::Config cfg;
  const char*  name;
};

const std::vector<DutSpec>& duts() {
  static const std::vector<DutSpec> table = {
      {0, hist::Config{2, 64, 1, 4, 16, false}, "2ant/64bin/1lane/4frames"},
      {1, hist::Config{2, 64, 2, 4, 16, true},  "2ant/64bin/2lane/4frames bitrev"},
      {2, hist::Config{4, 32, 1, 8, 16, false}, "4ant/32bin/1lane/8frames"},
  };
  return table;
}

// The clock-ratio set this block is swept over. The shared table in
// harness/clock_ratios.h is the project's canonical set and is reused for the
// gross ratios; 9:8 and 8:9 are added HERE rather than to that table because
// they are specific to this block's core:history pair (SPEC 8 constrains
// core_clk at 450 MHz and history_clk at 400 MHz, a ratio of 9:8) and because
// widening a shared table would lengthen every other CDC test in the suite for
// a ratio those tests have no particular reason to want.
const std::vector<ClockRatio>& history_ratios() {
  static const std::vector<ClockRatio> table = {
      {"1to1_in_phase", 1000, 1000, 1000, 1000},
      {"1to1_offset",   1000, 1000, 1000, 1500},
      {"9to8_core_fast", 800,  900,   800,  900},
      {"8to9_hist_fast", 900,  800,   900,  800},
      {"100to99_drift",  990, 1000,   990, 1000},
  };
  return table;
}

// -----------------------------------------------------------------------------
// Stimulus generator
//
// A pure function of (seed, antenna, frame, natural bin). Being pure is what
// lets the concurrent pass check a response against the frame its metadata
// claims, with no reference to any stored state — and what makes a wrong
// ADDRESS, as opposed to wrong data, impossible to hide.
// -----------------------------------------------------------------------------
std::uint64_t mix(std::uint64_t x) {
  x += 0x9E3779B97F4A7C15ull;
  x = (x ^ (x >> 30)) * 0xBF58476D1CE4E5B9ull;
  x = (x ^ (x >> 27)) * 0x94D049BB133111EBull;
  return x ^ (x >> 31);
}

fxp::Complex gen_sample(std::uint64_t seed, unsigned ant, std::uint32_t frame,
                        unsigned bin) {
  const std::uint64_t h =
      mix(seed ^ (static_cast<std::uint64_t>(ant) << 44) ^
          (static_cast<std::uint64_t>(frame) << 20) ^ bin);
  return fxp::Complex{static_cast<fxp::i16>(h & 0xFFFFu),
                      static_cast<fxp::i16>((h >> 16) & 0xFFFFu)};
}

// -----------------------------------------------------------------------------
// Driver state
// -----------------------------------------------------------------------------
struct WrBeat {
  unsigned      ant = 0;
  std::uint32_t word[2] = {0, 0};
  bool          sof = false;
  bool          eof = false;
};

struct ReqItem {
  unsigned bin = 0;
  unsigned off = 0;
};

struct RspItem {
  std::vector<std::uint32_t> vec;
  unsigned      bin = 0;
  unsigned      off = 0;
  std::uint32_t frame_id = 0;
  unsigned      flags = 0;
  unsigned      user = 0;
  unsigned      ident = 0;
  unsigned      seq = 0;
};

// -----------------------------------------------------------------------------
// One (DUT, clock ratio) session: a scheduler, a reset, and the four callbacks
// that drive and observe the two domains.
// -----------------------------------------------------------------------------
class Session {
 public:
  Session(Vhistory_top* top, const DutSpec& dut, const ClockRatio& ratio,
          ErrorCollector* errors)
      : top_(top),
        dut_(dut),
        model_(dut.cfg),
        sched_([top]() { top->eval(); }),
        errors_(errors) {
    top_->dut_sel = static_cast<std::uint8_t>(dut.sel);
    idle_inputs();

    core_ = sched_.add_clock("core_clk", ratio.half_a, &top_->core_clk,
                             ratio.first_a);
    hist_ = sched_.add_clock("history_clk", ratio.half_b, &top_->history_clk,
                             ratio.first_b);
    errors_->set_time_probe(sched_.time_ptr());

    limit_ = static_cast<SimTime>(4000000) * harness::slowest_half(ratio) * 2;

    reset_ = std::make_unique<ResetSequencer>(sched_);
    // Deliberately different release delays: the two domains leave reset at
    // different absolute times, which is the skew the crossings must absorb.
    reset_->add_domain("core_rst_n", core_, &top_->core_rst_n, 8);
    reset_->add_domain("history_rst_n", hist_, &top_->history_rst_n, 5);

    sched_.on_posedge_sample(core_, [this]() { core_sample(); });
    sched_.on_posedge_drive(core_, [this]() { core_drive(); });
    sched_.on_posedge_sample(hist_, [this]() { hist_sample(); });
    sched_.on_posedge_drive(hist_, [this]() { hist_drive(); });
  }

  bool reset() {
    idle_inputs();
    reset_->assert_all();
    if (reset_->release_all(limit_) != StopReason::kRunning) return false;
    top_->cfg_enable = 1;
    return settle(16);
  }

  hist::Model& model() { return model_; }
  const hist::Config& cfg() const { return dut_.cfg; }
  const DutSpec& dut() const { return dut_; }

  void set_write_gap(double p) { wr_gap_ = p; }
  void set_req_gap(double p) { req_gap_ = p; }
  void set_backpressure(const BackpressureConfig& c) {
    bp_ = std::make_unique<BackpressureGenerator>(bp_rng_, c);
  }
  void seed_backpressure(std::uint64_t s) { bp_rng_.seed(s); }
  void set_force_unsafe(bool on) { top_->cfg_force_unsafe = on ? 1 : 0; }

  // ---- stimulus -----------------------------------------------------------
  // Queue one whole frame for every antenna, in lockstep. The samples are
  // placed by (beat, lane) exactly where rtl/fft/ would place them, so the
  // natural bin of each one comes from history_pkg's own mapping.
  void queue_frame(std::uint64_t seed, std::uint32_t frame) {
    const hist::Config& c = dut_.cfg;
    for (unsigned k = 0; k < c.beats_per_frame(); ++k) {
      for (unsigned a = 0; a < c.n_ant; ++a) {
        WrBeat b;
        b.ant = a;
        b.sof = (k == 0);
        b.eof = (k == c.beats_per_frame() - 1);
        for (unsigned l = 0; l < c.lanes; ++l) {
          b.word[l] = gen_sample(seed, a, frame, hist::stored_bin(c, k, l)).packed();
        }
        wr_q_[a].push_back(b);
      }
    }
  }

  void queue_request(unsigned bin, unsigned off) {
    rd_q_.push_back(ReqItem{bin, off});
  }

  // Predict every queued request against the model, in order. Only valid in a
  // quiesced phase; see the file header.
  void predict_all() {
    for (const ReqItem& r : rd_q_) {
      expect_.push_back(model_.read(r.bin, r.off, top_->cfg_force_unsafe != 0));
    }
  }

  const std::vector<RspItem>& responses() const { return got_; }
  const std::vector<hist::Response>& expected() const { return expect_; }
  std::size_t requests_issued() const { return issued_; }

  void clear_traffic() {
    for (auto& q : wr_q_) q.clear();
    rd_q_.clear();
    got_.clear();
    expect_.clear();
    issued_ = 0;
  }

  // ---- running ------------------------------------------------------------
  bool settle(std::uint64_t cycles) {
    if (sched_.run_cycles(core_, cycles, limit_) != StopReason::kRunning) return false;
    return sched_.run_cycles(hist_, cycles, limit_) == StopReason::kRunning;
  }

  bool drain(std::uint64_t budget_core_cycles, const std::string& what) {
    std::uint64_t spent = 0;
    while (spent < budget_core_cycles) {
      if (idle()) return true;
      if (sched_.run_cycles(core_, 64, limit_) != StopReason::kRunning) break;
      spent += 64;
    }
    if (!idle()) {
      fail("hang", &g_counters.hang,
           what + ": " + std::to_string(pending_writes()) +
               " write beat(s), " + std::to_string(rd_q_.size()) +
               " request(s) and " + std::to_string(issued_ - got_.size()) +
               " response(s) still outstanding after " +
               std::to_string(budget_core_cycles) + " core cycles");
      return false;
    }
    return true;
  }

  bool idle() const {
    return pending_writes() == 0 && rd_q_.empty() && got_.size() == issued_;
  }

  std::size_t pending_writes() const {
    std::size_t n = 0;
    for (const auto& q : wr_q_) n += q.size();
    return n;
  }

  // ---- register-like access ----------------------------------------------
  // The control-plane strobes are RWP fields (control/regmap.json), which the
  // register block presents as EXACTLY ONE core cycle. Driving them as a level
  // would arm the request again on every cycle it stayed high, and a depth apply
  // that lands twice bumps the epoch twice — which is how this helper was
  // written the first time, and what the model promptly caught.
  void pulse_core(std::uint8_t* sig) {
    *sig = 1;
    sched_.run_cycles(core_, 1, limit_);
    *sig = 0;
    sched_.run_cycles(core_, 2, limit_);
  }

  void write_depth(unsigned d) {
    top_->cfg_depth = static_cast<std::uint16_t>(d);
    pulse_core(&top_->cfg_depth_apply);
    model_.request_depth(d);
  }

  void clear_counters() {
    pulse_core(&top_->cfg_counter_clear);
    // The read-domain counters are cleared through a pulse crossing; give it
    // room to land before anything reads them back.
    settle(24);
    model_.clear_counters();
  }

  std::uint64_t core_cycles() const { return sched_.cycles(core_); }
  std::uint64_t hist_cycles() const { return sched_.cycles(hist_); }

 private:
  void idle_inputs() {
    top_->wr_valid = 0;
    top_->wr_sof = 0;
    top_->wr_eof = 0;
    for (int i = 0; i < 8; ++i) top_->wr_data[i] = 0;
    top_->cfg_enable = 0;
    top_->cfg_depth = 0;
    top_->cfg_depth_apply = 0;
    top_->cfg_counter_clear = 0;
    top_->cfg_sticky_clear = 0;
    top_->cfg_force_unsafe = 0;
    top_->rd_req_valid = 0;
    top_->rd_req_bin = 0;
    top_->rd_req_frame_off = 0;
    top_->m_ready = 1;
  }

  void core_drive() {
    std::uint8_t v = 0, sof = 0, eof = 0;
    for (unsigned a = 0; a < dut_.cfg.n_ant; ++a) {
      if (wr_q_[a].empty()) continue;
      if (wr_gap_ > 0.0 && harness::bernoulli(gap_rng_, wr_gap_)) continue;
      const WrBeat& b = wr_q_[a].front();
      v |= static_cast<std::uint8_t>(1u << a);
      if (b.sof) sof |= static_cast<std::uint8_t>(1u << a);
      if (b.eof) eof |= static_cast<std::uint8_t>(1u << a);
      for (unsigned l = 0; l < dut_.cfg.lanes; ++l) {
        top_->wr_data[a * 2 + l] = b.word[l];
      }
    }
    top_->wr_valid = v;
    top_->wr_sof = sof;
    top_->wr_eof = eof;
  }

  void core_sample() {
    for (unsigned a = 0; a < dut_.cfg.n_ant; ++a) {
      const bool driven = (top_->wr_valid >> a) & 1u;
      const bool ready = (top_->wr_ready >> a) & 1u;
      if (!driven || !ready || wr_q_[a].empty()) continue;
      const WrBeat b = wr_q_[a].front();
      wr_q_[a].pop_front();
      std::vector<fxp::Complex> s(dut_.cfg.lanes);
      for (unsigned l = 0; l < dut_.cfg.lanes; ++l) {
        s[l] = fxp::Complex::from_packed(b.word[l]);
      }
      if (model_.write_beat(a, s, b.sof, b.eof)) {
        fail("protocol", &g_counters.protocol,
             "the stimulus itself produced a framing defect on antenna " +
                 std::to_string(a));
      }
    }
  }

  void hist_drive() {
    top_->m_ready = (bp_ && !bp_->allow()) ? 0 : 1;
    if (!rd_q_.empty() &&
        !(req_gap_ > 0.0 && harness::bernoulli(gap_rng_, req_gap_))) {
      top_->rd_req_valid = 1;
      top_->rd_req_bin = static_cast<std::uint16_t>(rd_q_.front().bin);
      top_->rd_req_frame_off = static_cast<std::uint16_t>(rd_q_.front().off);
    } else {
      top_->rd_req_valid = 0;
    }
  }

  void hist_sample() {
    if (top_->rd_req_valid && top_->rd_req_ready && !rd_q_.empty()) {
      rd_q_.pop_front();
      ++issued_;
    }
    if (top_->m_valid && top_->m_ready) {
      RspItem r;
      r.vec.resize(dut_.cfg.n_ant);
      for (unsigned a = 0; a < dut_.cfg.n_ant; ++a) r.vec[a] = top_->m_vec[a];
      r.bin      = top_->m_bin;
      r.off      = top_->m_frame_off;
      r.frame_id = top_->m_frame_id;
      r.flags    = top_->m_flags;
      r.user     = top_->m_user;
      r.ident    = top_->m_id;
      r.seq      = top_->m_seq;
      got_.push_back(r);
    }
  }

  Vhistory_top* top_;
  DutSpec dut_;
  hist::Model model_;
  ClockScheduler sched_;
  ErrorCollector* errors_;
  std::unique_ptr<ResetSequencer> reset_;
  std::unique_ptr<BackpressureGenerator> bp_;
  std::mt19937_64 bp_rng_{1};
  std::mt19937_64 gap_rng_{1};
  int core_ = 0, hist_ = 0;
  SimTime limit_ = 0;
  double wr_gap_ = 0.0, req_gap_ = 0.0;
  std::deque<WrBeat> wr_q_[4];
  std::deque<ReqItem> rd_q_;
  std::vector<RspItem> got_;
  std::vector<hist::Response> expect_;
  std::size_t issued_ = 0;
};

// -----------------------------------------------------------------------------
// Shared checks
// -----------------------------------------------------------------------------
void check_exact(Session& s, const std::string& where) {
  const std::vector<RspItem>& got = s.responses();
  const std::vector<hist::Response>& exp = s.expected();

  if (got.size() != exp.size()) {
    fail("protocol", &g_counters.protocol,
         where + ": " + std::to_string(exp.size()) + " requests produced " +
             std::to_string(got.size()) + " responses");
    return;
  }

  for (std::size_t i = 0; i < got.size(); ++i) {
    const RspItem& g = got[i];
    const hist::Response& e = exp[i];

    if (g.bin != e.bin || g.off != e.frame_off || g.frame_id != e.frame_id) {
      fail("meta", &g_counters.meta,
           where + " response " + std::to_string(i) + ": metadata (bin " +
               std::to_string(g.bin) + ", off " + std::to_string(g.off) +
               ", frame " + std::to_string(g.frame_id) + ") expected (bin " +
               std::to_string(e.bin) + ", off " + std::to_string(e.frame_off) +
               ", frame " + std::to_string(e.frame_id) + ")");
      continue;
    }
    if (g.flags != e.flags) {
      fail("flags", &g_counters.flags,
           where + " response " + std::to_string(i) + " bin " +
               std::to_string(g.bin) + ": flags 0x" + std::to_string(g.flags) +
               " expected 0x" + std::to_string(e.flags));
    }
    if (g.user != g.flags) {
      fail("meta", &g_counters.meta,
           where + " response " + std::to_string(i) +
               ": the stream's `user` mirror (0x" + std::to_string(g.user) +
               ") disagrees with the flags inside the metadata (0x" +
               std::to_string(g.flags) + ")");
    }
    if ((g.ident & 0xC0u) != 0xC0u) {
      fail("protocol", &g_counters.protocol,
           where + " response " + std::to_string(i) +
               ": a response must be a complete one-beat frame, but sof/eof "
               "read 0x" + std::to_string(g.ident));
    }
    for (unsigned a = 0; a < s.cfg().n_ant; ++a) {
      if (g.vec[a] != e.vec[a].packed()) {
        fail("data", &g_counters.data,
             where + " response " + std::to_string(i) + " bin " +
                 std::to_string(g.bin) + " frame " + std::to_string(g.frame_id) +
                 " antenna " + std::to_string(a) + ": got 0x" +
                 std::to_string(g.vec[a]) + " expected 0x" +
                 std::to_string(e.vec[a].packed()));
        break;
      }
    }
  }
}

void check_counters(Vhistory_top* top, hist::Model& m, const std::string& where) {
  struct Item {
    const char*   name;
    std::uint32_t rtl;
    std::uint32_t mdl;
  };
  const Item items[] = {
      {"depth_active", top->stat_depth_active, m.depth()},
      {"occupancy", top->stat_occupancy, m.occupancy()},
      {"frames_done", top->stat_frames_done, m.frames_done()},
      {"overwrite", top->stat_overwrite_count, m.overwrite_count()},
      {"skew", top->stat_skew_count, m.skew_count()},
      {"write_beats", top->stat_write_beat_count, m.write_beat_count()},
      {"reads", top->stat_read_count, m.read_count()},
      {"collisions", top->stat_collision_count, m.collision_count()},
      {"errors", top->stat_error_count, m.error_count()},
      {"epoch", top->stat_epoch, m.epoch() & 0xFFu},
  };
  for (const Item& it : items) {
    if (it.rtl != it.mdl) {
      fail("counter", &g_counters.counter,
           where + ": " + it.name + " reads " + std::to_string(it.rtl) +
               ", model says " + std::to_string(it.mdl));
    }
  }
}

// -----------------------------------------------------------------------------
// Pass 1 — geometry
// -----------------------------------------------------------------------------
void pass_geometry(Vhistory_top* top) {
  top->eval();
  if (top->geo_n_duts != duts().size()) {
    fail("geometry", &g_counters.geometry,
         "the top builds " + std::to_string(top->geo_n_duts) +
             " DUTs but this test models " + std::to_string(duts().size()));
    return;
  }
  if (top->geo_read_latency != 6) {
    fail("geometry", &g_counters.geometry,
         "hist_read_latency() reports " + std::to_string(top->geo_read_latency) +
             "; this test's timing budgets assume 6");
  }
  for (const DutSpec& d : duts()) {
    top->dut_sel = static_cast<std::uint8_t>(d.sel);
    top->eval();
    if (!d.cfg.valid()) {
      fail("geometry", &g_counters.geometry,
           std::string("DUT ") + d.name + " is not a legal geometry");
    }
    if (top->geo_n_ant != d.cfg.n_ant || top->geo_lanes != d.cfg.lanes ||
        top->geo_fft_size != d.cfg.fft_size ||
        top->geo_frames_max != d.cfg.frames_max ||
        (top->geo_bit_reversed != 0) != d.cfg.bit_reversed) {
      fail("geometry", &g_counters.geometry,
           std::string("DUT ") + d.name + ": the RTL reports " +
               std::to_string(top->geo_n_ant) + " antennas, " +
               std::to_string(top->geo_fft_size) + " bins, " +
               std::to_string(top->geo_lanes) + " lanes, " +
               std::to_string(top->geo_frames_max) + " frames, bitrev " +
               std::to_string(top->geo_bit_reversed));
    }
  }
  top->dut_sel = 0;
  top->eval();
}

// The address round trip, checked in the model alone before any RTL is driven.
// If this fails the RTL comparison would be comparing two wrongs.
void pass_model_selfcheck() {
  for (const DutSpec& d : duts()) {
    const hist::Config& c = d.cfg;
    std::vector<int> seen(c.fft_size, 0);
    for (unsigned k = 0; k < c.beats_per_frame(); ++k) {
      for (unsigned l = 0; l < c.lanes; ++l) {
        const unsigned b = hist::stored_bin(c, k, l);
        if (b >= c.fft_size) {
          fail("geometry", &g_counters.geometry,
               std::string(d.name) + ": stored_bin(" + std::to_string(k) + "," +
                   std::to_string(l) + ") = " + std::to_string(b) +
                   " is outside the frame");
          continue;
        }
        ++seen[b];
        if (hist::lane_of_bin(c, b) != l || hist::beat_of_bin(c, b) != k) {
          fail("geometry", &g_counters.geometry,
               std::string(d.name) + ": bin " + std::to_string(b) +
                   " stored at (beat " + std::to_string(k) + ", lane " +
                   std::to_string(l) + ") is located at (beat " +
                   std::to_string(hist::beat_of_bin(c, b)) + ", lane " +
                   std::to_string(hist::lane_of_bin(c, b)) + ")");
        }
      }
    }
    for (unsigned b = 0; b < c.fft_size; ++b) {
      if (seen[b] != 1) {
        fail("geometry", &g_counters.geometry,
             std::string(d.name) + ": bin " + std::to_string(b) + " is stored " +
                 std::to_string(seen[b]) + " times; the mapping is not a bijection");
      }
    }
  }
}

// -----------------------------------------------------------------------------
// Pass 2/3 — write past the depth, quiesce, read everything, compare exactly
// -----------------------------------------------------------------------------
bool pass_exact(Vhistory_top* top, const DutSpec& d, const ClockRatio& ratio,
                std::uint64_t seed, std::size_t* reads_out) {
  Session s(top, d, ratio, g_errors);
  const std::string where =
      std::string(d.name) + " @ " + ratio.name;
  if (!s.reset()) {
    fail("hang", &g_counters.hang, where + ": reset never completed");
    return false;
  }

  // Enough frames to rotate the buffer more than twice, so the overwrite path
  // and the slot wrap are both exercised rather than merely reachable.
  const std::uint32_t frames = d.cfg.frames_max * 2 + 3;
  for (std::uint32_t f = 0; f < frames; ++f) s.queue_frame(seed, f);
  if (!s.drain(200000, where + " write")) return false;
  if (!s.settle(64)) return false;

  check_counters(top, s.model(), where + " after writes");

  // Every bin at every readable offset. This is the corner turn's whole
  // contract: for each of them, all N_ANT antennas of one bin of one frame.
  const unsigned rd = s.model().readable();
  if (rd == 0) {
    fail("rotation", &g_counters.rotation,
         where + ": nothing readable after " + std::to_string(frames) + " frames");
    return false;
  }
  for (unsigned off = 0; off < rd; ++off) {
    for (unsigned b = 0; b < d.cfg.fft_size; ++b) s.queue_request(b, off);
  }
  s.predict_all();
  if (!s.drain(200000, where + " read")) return false;
  if (!s.settle(64)) return false;

  check_exact(s, where);
  check_counters(top, s.model(), where + " after reads");
  if (reads_out) *reads_out += s.responses().size();
  return true;
}

// -----------------------------------------------------------------------------
// Pass 4 — overwrite policy at a shallow depth
// -----------------------------------------------------------------------------
void pass_overwrite(Vhistory_top* top, const DutSpec& d, std::uint64_t seed) {
  Session s(top, d, history_ratios()[0], g_errors);
  const std::string where = std::string(d.name) + " overwrite";
  if (!s.reset()) {
    fail("hang", &g_counters.hang, where + ": reset never completed");
    return;
  }

  // Depth 3 is the shallowest that leaves anything readable, which makes it the
  // one where an off-by-one in the readable bound is most visible.
  s.write_depth(3);
  if (!s.settle(32)) return;
  if (top->stat_depth_active != 3) {
    fail("depth", &g_counters.depth,
         where + ": depth reads " + std::to_string(top->stat_depth_active) +
             " after programming 3");
  }

  const std::uint32_t frames = 12;
  for (std::uint32_t f = 0; f < frames; ++f) s.queue_frame(seed, f);
  if (!s.drain(200000, where)) return;
  if (!s.settle(64)) return;

  if (s.model().overwrite_count() != frames - 3) {
    fail("counter", &g_counters.counter,
         where + ": the model itself expected " + std::to_string(frames - 3) +
             " evictions, not " + std::to_string(s.model().overwrite_count()));
  }
  check_counters(top, s.model(), where);

  // and the one readable frame is still the newest complete one, bit-exactly.
  for (unsigned b = 0; b < d.cfg.fft_size; ++b) s.queue_request(b, 0);
  s.predict_all();
  if (!s.drain(200000, where + " read")) return;
  if (!s.settle(32)) return;
  check_exact(s, where);

  for (const RspItem& r : s.responses()) {
    if (r.frame_id != frames - 1) {
      fail("rotation", &g_counters.rotation,
           where + ": offset 0 served frame " + std::to_string(r.frame_id) +
               " where the newest complete frame is " + std::to_string(frames - 1));
      break;
    }
  }
}

// -----------------------------------------------------------------------------
// Pass 5 — a depth change must wait for a safe boundary
// -----------------------------------------------------------------------------
void pass_depth_change(Vhistory_top* top, const DutSpec& d, std::uint64_t seed) {
  Session s(top, d, history_ratios()[0], g_errors);
  const std::string where = std::string(d.name) + " depth change";
  if (!s.reset()) {
    fail("hang", &g_counters.hang, where + ": reset never completed");
    return;
  }

  for (std::uint32_t f = 0; f < 3; ++f) s.queue_frame(seed, f);
  if (!s.drain(200000, where + " prefill")) return;
  if (!s.settle(32)) return;

  const std::uint8_t epoch_before = top->stat_epoch;

  // Queue one frame, let it get partway in, and change the depth mid-frame. The
  // change must not land until the antennas are between frames.
  s.queue_frame(seed, 3);
  if (!s.settle(4)) return;
  if (s.pending_writes() == 0) {
    fail("depth", &g_counters.depth, where + ": the frame drained too fast to be mid-flight");
    return;
  }
  s.write_depth(d.cfg.frames_max);
  if (!s.settle(2)) return;

  if (!top->obs_depth_pending) {
    fail("depth", &g_counters.depth,
         where + ": a depth change requested mid-frame did not report as pending");
  }
  if (top->stat_epoch != epoch_before) {
    fail("depth", &g_counters.depth,
         where + ": the epoch moved before the safe boundary");
  }

  if (!s.drain(200000, where + " finish frame")) return;
  if (!s.settle(64)) return;

  if (top->obs_depth_pending) {
    fail("depth", &g_counters.depth,
         where + ": the depth change is still pending at a frame boundary");
  }
  if (top->stat_epoch == epoch_before) {
    fail("depth", &g_counters.depth, where + ": the epoch did not move");
  }
  if (top->stat_frames_done != 0 || top->stat_occupancy != 0) {
    fail("depth", &g_counters.depth,
         where + ": the history was not discarded — frames_done " +
             std::to_string(top->stat_frames_done) + ", occupancy " +
             std::to_string(top->stat_occupancy));
  }
  check_counters(top, s.model(), where);

  // The new depth must work from empty.
  const std::uint32_t frames = d.cfg.frames_max + 1;
  for (std::uint32_t f = 0; f < frames; ++f) s.queue_frame(seed + 1, f);
  if (!s.drain(200000, where + " refill")) return;
  if (!s.settle(64)) return;
  const unsigned rd = s.model().readable();
  for (unsigned off = 0; off < rd; ++off) {
    for (unsigned b = 0; b < d.cfg.fft_size; ++b) s.queue_request(b, off);
  }
  s.predict_all();
  if (!s.drain(200000, where + " reread")) return;
  if (!s.settle(32)) return;
  check_exact(s, where + " after change");
  check_counters(top, s.model(), where + " after change");
}

// -----------------------------------------------------------------------------
// Pass 6 — random bins and offsets, including out-of-range ones
// -----------------------------------------------------------------------------
void pass_random(Vhistory_top* top, const DutSpec& d, std::uint64_t seed,
                 std::mt19937_64 rng, std::size_t* oor_seen) {
  Session s(top, d, history_ratios()[2], g_errors);
  const std::string where = std::string(d.name) + " random";
  if (!s.reset()) {
    fail("hang", &g_counters.hang, where + ": reset never completed");
    return;
  }
  s.set_write_gap(0.15);
  s.set_req_gap(0.25);
  s.seed_backpressure(seed ^ 0x5A5Au);
  s.set_backpressure(BackpressureConfig::bursty());

  const std::uint32_t frames = d.cfg.frames_max + 2;
  for (std::uint32_t f = 0; f < frames; ++f) s.queue_frame(seed, f);
  if (!s.drain(400000, where + " write")) return;
  if (!s.settle(64)) return;

  const unsigned rd = s.model().readable();
  const unsigned n = 300;
  for (unsigned i = 0; i < n; ++i) {
    // One request in eight is deliberately out of range, so the error counter
    // and the clamp are exercised by the random pass and not only by a directed
    // one. The bin is occasionally past FFT_SIZE too.
    const bool wild = harness::uniform_u64(rng, 0, 7) == 0;
    const unsigned bin =
        wild && harness::uniform_u64(rng, 0, 1)
            ? static_cast<unsigned>(harness::uniform_u64(rng, d.cfg.fft_size, 4095))
            : static_cast<unsigned>(harness::uniform_u64(rng, 0, d.cfg.fft_size - 1));
    const unsigned off =
        wild ? static_cast<unsigned>(harness::uniform_u64(rng, rd, rd + 4))
             : static_cast<unsigned>(harness::uniform_u64(rng, 0, rd ? rd - 1 : 0));
    if (wild) ++*oor_seen;
    s.queue_request(bin, off);
  }
  s.predict_all();
  if (!s.drain(400000, where + " read")) return;
  if (!s.settle(64)) return;
  check_exact(s, where);
  check_counters(top, s.model(), where);
}

// -----------------------------------------------------------------------------
// Pass 7 — the collision counter, proved reachable by fault injection
// -----------------------------------------------------------------------------
void pass_collision(Vhistory_top* top, const DutSpec& d, std::uint64_t seed) {
  Session s(top, d, history_ratios()[0], g_errors);
  const std::string where = std::string(d.name) + " collision";
  if (!s.reset()) {
    fail("hang", &g_counters.hang, where + ": reset never completed");
    return;
  }

  const std::uint32_t frames = d.cfg.frames_max + 2;
  for (std::uint32_t f = 0; f < frames; ++f) s.queue_frame(seed, f);
  if (!s.drain(200000, where + " write")) return;
  if (!s.settle(64)) return;

  // In safe operation an out-of-range offset is clamped, so it can never reach
  // the in-flight slot and the collision counter must stay at zero.
  const unsigned rd = s.model().readable();
  for (unsigned b = 0; b < 8; ++b) s.queue_request(b, rd + 1);
  s.predict_all();
  if (!s.drain(200000, where + " clamped")) return;
  if (!s.settle(32)) return;
  check_exact(s, where + " clamped");
  if (top->stat_collision_count != 0) {
    fail("counter", &g_counters.counter,
         where + ": the clamp let " + std::to_string(top->stat_collision_count) +
             " request(s) reach the in-flight slot");
  }
  if (top->stat_error_count == 0) {
    fail("counter", &g_counters.counter,
         where + ": eight out-of-range requests advanced the error counter by zero");
  }

  // Now remove the clamp. The same offsets now address the slot being written,
  // which is exactly what the collision counter exists to report.
  s.clear_traffic();
  s.set_force_unsafe(true);
  if (!s.settle(32)) return;
  // The offset that lands on the write slot: readable frames occupy offsets
  // 0..readable-1, and the slot one further back in the rotation is the one the
  // writer is filling.
  const unsigned hit = d.cfg.frames_max - 1;
  for (unsigned b = 0; b < 8; ++b) s.queue_request(b, hit);
  s.predict_all();
  if (!s.drain(200000, where + " unsafe")) return;
  if (!s.settle(32)) return;
  check_exact(s, where + " unsafe");
  check_counters(top, s.model(), where + " unsafe");
  if (top->stat_collision_count == 0) {
    fail("coverage", &g_counters.coverage,
         where + ": fault injection did not make the collision counter reachable");
  }
  s.set_force_unsafe(false);
}

// -----------------------------------------------------------------------------
// Pass 8 — continuous writes with reads in flight, checked by identity
// -----------------------------------------------------------------------------
void pass_concurrent(Vhistory_top* top, const DutSpec& d, const ClockRatio& ratio,
                     std::uint64_t seed, std::mt19937_64 rng,
                     std::size_t* responses_out) {
  Session s(top, d, ratio, g_errors);
  const std::string where = std::string(d.name) + " concurrent @ " + ratio.name;
  if (!s.reset()) {
    fail("hang", &g_counters.hang, where + ": reset never completed");
    return;
  }

  // Full-rate writes: no gaps at all, which is the SPEC 7.3 "continuous writes"
  // case and the one where the write side's inability to stall is load-bearing.
  const std::uint32_t frames = d.cfg.frames_max * 3;
  for (std::uint32_t f = 0; f < frames; ++f) s.queue_frame(seed, f);

  // Reads at random bins, always at offset 0 or 1 so the request is legal
  // whatever the pointer happens to be.
  const unsigned n = 240;
  for (unsigned i = 0; i < n; ++i) {
    s.queue_request(static_cast<unsigned>(harness::uniform_u64(rng, 0, d.cfg.fft_size - 1)),
                    static_cast<unsigned>(harness::uniform_u64(rng, 0, 1)));
  }
  s.set_req_gap(0.4);
  if (!s.drain(400000, where)) return;
  if (!s.settle(64)) return;

  if (s.responses().size() != s.requests_issued()) {
    fail("protocol", &g_counters.protocol,
         where + ": " + std::to_string(s.requests_issued()) +
             " requests produced " + std::to_string(s.responses().size()) +
             " responses");
  }

  unsigned trustworthy = 0;
  unsigned last_seq = 0;
  bool first = true;
  for (const RspItem& r : s.responses()) {
    // One response per request, in order: the sequence number is the block's
    // own count and must advance by exactly one every time.
    if (!first && r.seq != ((last_seq + 1) & 0xFFFFu)) {
      fail("identity", &g_counters.identity,
           where + ": response sequence jumped from " + std::to_string(last_seq) +
               " to " + std::to_string(r.seq));
    }
    last_seq = r.seq;
    first = false;

    if (r.flags != 0) continue;   // untrustworthy by the block's own admission
    ++trustworthy;

    // THE CORNER-TURN CHECK. The response says which absolute frame it came
    // from; every antenna's word must be that frame's sample for that bin. A
    // wrong bank, a wrong slot, a wrong lane or a stale pointer all land here.
    for (unsigned a = 0; a < d.cfg.n_ant; ++a) {
      const std::uint32_t want = gen_sample(seed, a, r.frame_id, r.bin).packed();
      if (r.vec[a] != want) {
        fail("identity", &g_counters.identity,
             where + ": bin " + std::to_string(r.bin) + " of frame " +
                 std::to_string(r.frame_id) + ", antenna " + std::to_string(a) +
                 ": got 0x" + std::to_string(r.vec[a]) + " expected 0x" +
                 std::to_string(want));
        break;
      }
    }
  }

  if (trustworthy == 0) {
    fail("coverage", &g_counters.coverage,
         where + ": not one response was flagged trustworthy");
  }
  // Bits 3..1 are framing, skew and collision, and none of them may fire on
  // well-formed traffic. Bit 0 — an out-of-range request — legitimately CAN:
  // this pass issues reads from the first cycle, and until two frames have
  // completed there is nothing at offset 1 to read. That the block reports it
  // rather than answering with something plausible is the behaviour under test,
  // so the bit is excluded here and its responses are checked by their flags
  // above instead.
  if ((top->stat_fault & 0x0Eu) != 0) {
    fail("counter", &g_counters.counter,
         where + ": sticky faults 0x" + std::to_string(top->stat_fault) +
             " after clean concurrent traffic (framing/skew/collision must be clear)");
  }
  if (responses_out) *responses_out += s.responses().size();
}

// -----------------------------------------------------------------------------
// Pass 9 — backpressure invariance
// -----------------------------------------------------------------------------
void pass_backpressure(Vhistory_top* top, const DutSpec& d, std::uint64_t seed) {
  const BackpressureConfig profiles[] = {
      BackpressureConfig::none(), BackpressureConfig::light(),
      BackpressureConfig::heavy(), BackpressureConfig::bursty()};
  const char* names[] = {"none", "light", "heavy", "bursty"};

  std::vector<RspItem> reference;
  for (int p = 0; p < 4; ++p) {
    Session s(top, d, history_ratios()[1], g_errors);
    const std::string where =
        std::string(d.name) + " backpressure/" + names[p];
    if (!s.reset()) {
      fail("hang", &g_counters.hang, where + ": reset never completed");
      return;
    }
    s.seed_backpressure(seed + static_cast<std::uint64_t>(p));
    s.set_backpressure(profiles[p]);

    const std::uint32_t frames = d.cfg.frames_max + 2;
    for (std::uint32_t f = 0; f < frames; ++f) s.queue_frame(seed, f);
    if (!s.drain(400000, where + " write")) return;
    if (!s.settle(64)) return;

    const unsigned rd = s.model().readable();
    for (unsigned off = 0; off < rd; ++off) {
      for (unsigned b = 0; b < d.cfg.fft_size; ++b) s.queue_request(b, off);
    }
    s.predict_all();
    if (!s.drain(400000, where + " read")) return;
    if (!s.settle(64)) return;
    check_exact(s, where);

    if (p == 0) {
      reference = s.responses();
      continue;
    }
    const std::vector<RspItem>& got = s.responses();
    if (got.size() != reference.size()) {
      fail("invariance", &g_counters.invariance,
           where + ": " + std::to_string(got.size()) +
               " responses against the unstalled run's " +
               std::to_string(reference.size()));
      continue;
    }
    for (std::size_t i = 0; i < got.size(); ++i) {
      const bool same = got[i].bin == reference[i].bin &&
                        got[i].off == reference[i].off &&
                        got[i].frame_id == reference[i].frame_id &&
                        got[i].flags == reference[i].flags &&
                        got[i].seq == reference[i].seq &&
                        got[i].vec == reference[i].vec;
      if (!same) {
        fail("invariance", &g_counters.invariance,
             where + ": response " + std::to_string(i) +
                 " differs from the unstalled run. Backpressure changed WHEN a "
                 "response appears; it must never change WHAT it is");
        break;
      }
    }
  }
}

}  // namespace

// -----------------------------------------------------------------------------
int harness::sim_test_main(const SimArgs& args) {
  const auto wall_start = std::chrono::steady_clock::now();

  ErrorCollector errors;
  g_errors = &errors;
  g_counters = Counters{};

  auto top = std::make_unique<Vhistory_top>();
  const harness::SeedSource seeds(args.seed);

  // ---- pass 1: geometry, before any stimulus ----
  pass_model_selfcheck();
  pass_geometry(top.get());
  if (g_counters.geometry != 0) {
    std::printf("RESULT: FAIL seed=%llu test=%s config=%s reason=geometry\n",
                static_cast<unsigned long long>(args.seed), kTestName,
                sim_config::kName);
    return 1;
  }

  std::size_t reads = 0, concurrent_responses = 0, oor_seen = 0;
  std::uint64_t core_cycles = 0, hist_cycles = 0;

  // ---- pass 2/3: exact comparison across the clock-ratio sweep ----
  // DUT 0 sees every ratio, because the crossing is the same logic in all three
  // and sweeping all of them would triple the run for no new information. The
  // other two geometries see the ratio pair that bracket the SPEC 8 constraint.
  for (const ClockRatio& r : history_ratios()) {
    if (!pass_exact(top.get(), duts()[0], r, seeds.substream_seed("hist.exact"),
                    &reads)) {
      break;
    }
  }
  for (std::size_t i = 1; i < duts().size(); ++i) {
    pass_exact(top.get(), duts()[i], history_ratios()[2],
               seeds.substream_seed("hist.exact"), &reads);
    pass_exact(top.get(), duts()[i], history_ratios()[3],
               seeds.substream_seed("hist.exact"), &reads);
  }

  // ---- passes 4..7, on every geometry ----
  for (const DutSpec& d : duts()) {
    pass_overwrite(top.get(), d, seeds.substream_seed("hist.overwrite"));
    pass_depth_change(top.get(), d, seeds.substream_seed("hist.depth"));
    pass_collision(top.get(), d, seeds.substream_seed("hist.collision"));
  }

  // ---- pass 6: three independent random streams ----
  for (int k = 0; k < 3; ++k) {
    const std::string name = "hist.random." + std::to_string(k);
    pass_random(top.get(), duts()[k % duts().size()],
                seeds.substream_seed(name), seeds.engine(name), &oor_seen);
  }

  // ---- pass 8: concurrency, at the two ratios closest to SPEC 8 ----
  for (const DutSpec& d : duts()) {
    pass_concurrent(top.get(), d, history_ratios()[2],
                    seeds.substream_seed("hist.concurrent"),
                    seeds.engine("hist.concurrent"), &concurrent_responses);
  }
  pass_concurrent(top.get(), duts()[0], history_ratios()[3],
                  seeds.substream_seed("hist.concurrent2"),
                  seeds.engine("hist.concurrent2"), &concurrent_responses);

  // ---- pass 9: backpressure invariance ----
  pass_backpressure(top.get(), duts()[0], seeds.substream_seed("hist.bp"));

  if (reads == 0) {
    fail("coverage", &g_counters.coverage, "the run read nothing at all");
  }
  if (oor_seen == 0) {
    fail("coverage", &g_counters.coverage,
         "the random pass never generated an out-of-range request");
  }

  const bool passed = g_counters.total() == 0;

  std::printf("--- time-frequency history / corner turn ---\n");
  std::printf("  geometries       : %zu\n", duts().size());
  std::printf("  clock ratios     : %zu\n", history_ratios().size());
  std::printf("  exact reads      : %zu\n", reads);
  std::printf("  concurrent rsp   : %zu\n", concurrent_responses);
  std::printf("  out-of-range req : %zu\n", oor_seen);

  const auto wall_end = std::chrono::steady_clock::now();
  RunSummary summary;
  summary.test_name = kTestName;
  summary.config_name = sim_config::kName;
  summary.build_mode = args.build_mode;
  summary.seed = args.seed;
  summary.passed = passed;
  summary.stop_reason = passed ? "pass" : "error";
  summary.stop_detail =
      passed ? "every corner-turn read bit-exact against the C++ model"
             : "history mismatch; see errors_by_category";
  summary.passes = 9;
  summary.core_cycles = core_cycles;
  summary.cfg_cycles = hist_cycles;
  summary.beats_observed = reads + concurrent_responses;
  summary.absorb(errors);
  summary.wall_time_s =
      std::chrono::duration<double>(wall_end - wall_start).count();
  const std::string written = summary.write(args.results_dir);
  if (!written.empty()) std::printf("  summary json     : %s\n", written.c_str());

  top->final();

  if (passed) {
    std::printf("RESULT: PASS seed=%llu test=%s config=%s reads=%zu\n",
                static_cast<unsigned long long>(args.seed), kTestName,
                sim_config::kName, reads + concurrent_responses);
    return 0;
  }
  std::printf(
      "RESULT: FAIL seed=%llu test=%s config=%s geometry=%zu data=%zu meta=%zu "
      "flags=%zu counter=%zu rotation=%zu depth=%zu protocol=%zu identity=%zu "
      "invariance=%zu coverage=%zu hang=%zu\n",
      static_cast<unsigned long long>(args.seed), kTestName, sim_config::kName,
      g_counters.geometry, g_counters.data, g_counters.meta, g_counters.flags,
      g_counters.counter, g_counters.rotation, g_counters.depth,
      g_counters.protocol, g_counters.identity, g_counters.invariance,
      g_counters.coverage, g_counters.hang);
  return 1;
}
