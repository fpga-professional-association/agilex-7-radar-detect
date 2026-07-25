// -----------------------------------------------------------------------------
// test_seq_checker.cpp — sequence loss / duplication / reorder (SPEC 13.1, #8).
//
// One binary, one seed, nine passes over sim/verilator/tops/telemetry_top.sv.
// The sequence checker in that top watches the real datapath by default and a
// test-driven stimulus when `sq_override` is high, and BOTH are exercised here
// against the same instance — see telemetry_top's header for why injecting a
// fault into the datapath itself is not an option (the stream primitives'
// own `a_seq_continuous` assertion would fire first, correctly, and abort).
//
//   1  nominal          real traffic through the FIFO at real backpressure:
//                       every counter must stay at zero. A detector that cannot
//                       stay quiet on good data is worse than no detector.
//   2  gap              a number skipped. The category must be GAP, the size
//                       must be the number of beats actually missing, and the
//                       checker must resynchronise so one lost burst is one
//                       report rather than one per beat forever after.
//   3  duplicate        the beat just accepted, again.
//   4  reorder          a beat from behind the current position that is not the
//                       immediately preceding one. Distinguishing this from a
//                       duplicate is the whole reason the two have separate
//                       counters.
//   5  untracked        a beat on a stream this instance does not track. Counted,
//                       not ignored: silence there would be a clean report on
//                       traffic that was never looked at.
//   6  init_resync      the three ways an expectation is (re)established —
//                       first beat, ENABLE reasserted, start_of_frame with
//                       SEQ_SOF_RESYNC — and the proof that with resync OFF the
//                       same start_of_frame does NOT hide a real loss.
//   7  seq_wrap         0xFFFF -> 0x0000 must be in order, and a gap that
//                       straddles the wrap must still be a gap of the right
//                       size. This is where a checker written with a naive
//                       comparison breaks, and where this one must not.
//   8  registers        the same faults read back through the SPEC 9 plane:
//                       SEQ_*_COUNT after a snapshot, SEQ_STATUS's W1C bits and
//                       the checker's own sticky mirror beside them.
//   9  random_faults    a randomized stream of in-order beats, gaps, duplicates,
//                       reorders and untracked beats against
//                       telemetry::SeqTrackerModel.
//
// RUNNING CHECK, every cycle of every pass: the classification and all five
// counts against the C++ model in model/cpp/telemetry/telemetry_model.hpp, which
// is written from the NORMATIVE table in rtl/common/seq_checker.sv rather than
// from its logic. The directed passes additionally state the expected category
// in the test itself, so a shared misreading of the specification cannot pass
// both sides.
// -----------------------------------------------------------------------------

#include <algorithm>
#include <chrono>
#include <cstdio>
#include <cstring>
#include <deque>
#include <memory>
#include <string>
#include <vector>

#include "Vtelemetry_top.h"
#include "verilated.h"

#include "config_sim.h"
#include "harness/harness.h"
#include "regmap/regmap.hpp"
#include "telemetry/telemetry_model.hpp"

using harness::BackpressureConfig;
using harness::ClockScheduler;
using harness::ErrorCollector;
using harness::RegDriver;
using harness::RegPort;
using harness::RegResult;
using harness::ResetSequencer;
using harness::RunSummary;
using harness::Scoreboard;
using harness::SeedSource;
using harness::SimArgs;
using harness::SimTime;
using harness::StopReason;
using harness::StreamBeat;
using harness::StreamDriver;
using harness::StreamLayout;
using harness::StreamMonitor;
using harness::TimeoutGuard;
using harness::TransactionId;

using telemetry::SeqCounts;
using telemetry::SeqTrackerModel;
using telemetry::Verdict;

namespace {

constexpr const char* kTestName = "test_seq_checker";
constexpr std::uint64_t kExpectedCycles = 2;

constexpr unsigned kSeqW = sim_config::STREAM_SEQ_W;
constexpr unsigned kTracked = sim_config::TELEM_TRACKED_IDS;
constexpr std::uint32_t kSeqMask =
    static_cast<std::uint32_t>((1ull << kSeqW) - 1ull);

static_assert(kTracked < (1u << sim_config::STREAM_ID_W),
              "an untracked stream_id must exist for pass 5 to be reachable");

StreamLayout payload_layout() {
  StreamLayout l;
  l.data_w = sim_config::STREAM_DATA_W;
  l.id_w = sim_config::STREAM_ID_W;
  l.seq_w = sim_config::STREAM_SEQ_W;
  l.user_w = sim_config::STREAM_USER_W;
  l.user_lsb = sim_config::STREAM_USER_LSB;
  l.seq_lsb = sim_config::STREAM_SEQ_LSB;
  l.id_lsb = sim_config::STREAM_ID_LSB;
  l.eof_lsb = sim_config::STREAM_EOF_LSB;
  l.sof_lsb = sim_config::STREAM_SOF_LSB;
  l.data_lsb = sim_config::STREAM_DATA_LSB;
  l.payload_w = sim_config::STREAM_PAYLOAD_W;
  return l;
}

// One beat presented to the checker's override port.
struct SqStim {
  bool beat = false;
  std::uint32_t stream_id = 0;
  std::uint32_t seq = 0;
  bool sof = false;
};

// What the harness has watched the checker report, from the pins.
struct Seen {
  std::uint64_t gap = 0;
  std::uint64_t dup = 0;
  std::uint64_t reorder = 0;
  std::uint64_t untracked = 0;
  std::uint64_t lost = 0;       // sum of reported gap sizes
  std::uint32_t last_gap = 0;
};

TransactionId identity_of(const StreamBeat& b) {
  TransactionId id;
  id.stream_id = b.stream_id;
  id.frame_id = b.user;
  id.sequence = b.seq;
  return id;
}

std::string hex32(std::uint32_t v) {
  char buf[16];
  std::snprintf(buf, sizeof(buf), "0x%08X", v);
  return std::string(buf);
}

}  // namespace

int harness::sim_test_main(const SimArgs& args) {
  const auto wall_start = std::chrono::steady_clock::now();

  const StreamLayout layout = payload_layout();

  auto top = std::make_unique<Vtelemetry_top>();
  ErrorCollector errors;
  errors.set_print_limit(30);

  ClockScheduler sched([&top]() { top->eval(); });
  errors.set_time_probe(sched.time_ptr());

  const SimTime half = harness::half_period_ps(harness::kCoreClkMhz);
  const int clk = sched.add_clock("clk", half, &top->clk, half);

  ResetSequencer reset(sched);
  reset.add_domain("rst_n", clk, &top->rst_n, 8);

  std::uint64_t cycle = 0;
  sched.on_posedge_sample(clk, [&cycle]() { ++cycle; });

  SeedSource seeds(args.seed);

  RegPort port;
  port.address = &top->address;
  port.write_data = &top->write_data;
  port.byte_enable = &top->byte_enable;
  port.write_enable = &top->write_enable;
  port.read_enable = &top->read_enable;
  port.read_data = &top->read_data;
  port.ready = &top->ready;
  port.error = &top->error;
  RegDriver driver("reg", port, sched, clk, errors);

  harness::PackedSourcePort src(&top->s_valid, &top->s_ready, &top->s_payload,
                                layout);
  harness::PackedSinkPort snk(&top->m_valid, &top->m_ready, &top->m_payload,
                              layout);
  Scoreboard board("telemetry_path", errors);
  std::unique_ptr<StreamDriver> stream_drv;
  std::unique_ptr<StreamMonitor> stream_mon;
  bool stimulus_enabled = false;
  bool stop_on_drain = false;

  SeqTrackerModel model(kSeqW, kTracked, sim_config::TELEM_COUNT_W);
  Seen seen{};
  std::deque<SqStim> sq_queue;
  bool sq_override = false;
  bool model_active = false;
  std::uint64_t divergences = 0;

  std::string first_failure;
  auto fail = [&](const std::string& category, const std::string& message) {
    errors.error(category, message);
    if (first_failure.empty()) first_failure = message;
  };
  auto check = [&](bool ok, const std::string& category,
                   const std::string& message) {
    if (!ok) fail(category, message);
    return ok;
  };

  // Compare-then-advance. The registered outputs hold the state produced by the
  // previous edge; the classification pins are combinational from this cycle's
  // inputs, so they are compared against a fresh classify() of the same inputs.
  sched.on_posedge_sample(clk, [&]() {
    if (top->rst_n == 0) {
      model.reset();
      seen = Seen{};
      model_active = true;
      return;
    }
    if (!model_active) return;

    const SeqCounts want = model.counts();
    const SeqCounts got{top->sq_cnt_gap, top->sq_cnt_lost, top->sq_cnt_dup,
                        top->sq_cnt_reorder, top->sq_cnt_untracked};
    if (!(got == want) && divergences < 8) {
      ++divergences;
      fail("seq_count", "at cycle " + std::to_string(cycle) + " the checker has " +
                            got.to_string() + " and the model has " +
                            want.to_string());
    }
    if (top->sq_sticky != model.sticky() && divergences < 8) {
      ++divergences;
      fail("seq_sticky",
           "at cycle " + std::to_string(cycle) + " the sticky flags are " +
               hex32(top->sq_sticky) + " and the model says " +
               hex32(model.sticky()));
    }

    // This cycle's inputs, exactly as the RTL's mux presents them.
    const StreamBeat out = layout.unpack(top->m_payload);
    const bool enable = top->obs_seq_enable != 0;
    const bool resync_en = top->obs_seq_sof_resync != 0;
    const bool beat =
        top->sq_override ? (top->sq_beat != 0) : (top->obs_beat != 0);
    const std::uint32_t id = top->sq_override ? top->sq_stream_id : out.stream_id;
    const std::uint32_t sq = top->sq_override ? top->sq_seq : out.seq;
    const bool sof = top->sq_override ? (top->sq_sof != 0) : out.start_of_frame;

    std::uint32_t predicted_gap = 0;
    const Verdict v =
        model.classify(enable, beat, id, sq, sof, resync_en, &predicted_gap);
    const bool rtl_gap = top->sq_err_gap != 0;
    const bool rtl_dup = top->sq_err_dup != 0;
    const bool rtl_ror = top->sq_err_reorder != 0;
    const bool rtl_unt = top->sq_err_untracked != 0;

    const bool want_gap = (v == Verdict::kGap);
    const bool want_dup = (v == Verdict::kDuplicate);
    const bool want_ror = (v == Verdict::kReorder);
    const bool want_unt = (v == Verdict::kUntracked);
    if ((rtl_gap != want_gap || rtl_dup != want_dup || rtl_ror != want_ror ||
         rtl_unt != want_unt ||
         (want_gap && top->sq_gap_size != predicted_gap)) &&
        divergences < 8) {
      ++divergences;
      fail("seq_classify",
           "at cycle " + std::to_string(cycle) + " stream " +
               std::to_string(id) + " seq " + std::to_string(sq) +
               ": the checker reported gap=" + std::to_string(rtl_gap ? 1 : 0) +
               " dup=" + std::to_string(rtl_dup ? 1 : 0) + " reorder=" +
               std::to_string(rtl_ror ? 1 : 0) + " untracked=" +
               std::to_string(rtl_unt ? 1 : 0) + " size=" +
               std::to_string(top->sq_gap_size) + "; the model says " +
               telemetry::to_string(v) + " size " +
               std::to_string(predicted_gap));
    }

    if (rtl_gap) {
      ++seen.gap;
      seen.lost += top->sq_gap_size;
      seen.last_gap = top->sq_gap_size;
    }
    if (rtl_dup) ++seen.dup;
    if (rtl_ror) ++seen.reorder;
    if (rtl_unt) ++seen.untracked;

    model.tick(enable, beat, id, sq, sof, resync_en, top->obs_sticky_clear != 0,
               top->obs_counter_clear != 0, top->obs_snapshot_strobe != 0);

    if (stimulus_enabled) {
      stream_drv->on_sample();
      stream_mon->on_sample();
    }
  });

  sched.on_posedge_drive(clk, [&]() {
    SqStim s{};
    if (!sq_queue.empty()) {
      s = sq_queue.front();
      sq_queue.pop_front();
    }
    top->sq_override = sq_override ? 1 : 0;
    top->sq_beat = s.beat ? 1 : 0;
    top->sq_stream_id = static_cast<std::uint8_t>(s.stream_id);
    top->sq_seq = static_cast<std::uint16_t>(s.seq);
    top->sq_sof = s.sof ? 1 : 0;
    top->inj_overflow = 0;
    top->inj_saturate = 0;
    top->inj_cdc_error = 0;
    top->pc_enable = 0;
    top->pc_event = 0;
    top->pc_clear = 0;
    top->pc_snapshot = 0;
    top->pc_incr = 1;
    if (stimulus_enabled) {
      stream_drv->on_drive();
      stream_mon->on_drive();
    }
  });

  sched.on_posedge_drive(clk, [&]() {
    if (!stimulus_enabled || !stop_on_drain) return;
    if (!stream_drv->idle() || board.outstanding() != 0) return;
    sched.stop_pass("pass drained");
  });

  const std::uint64_t hard_limit =
      args.timeout_cycles != 0 ? args.timeout_cycles : 400000;
  TimeoutGuard timeout(sched, errors, hard_limit, 6000, [&]() {
    return driver.transactions() + seen.gap + seen.dup + seen.reorder +
           seen.untracked + cycle / 512 +
           (stream_mon ? stream_mon->beats_received() : 0);
  });
  sched.on_posedge_drive(clk, [&timeout]() { timeout.on_cycle(); });

  harness::TraceControl trace;
  std::string trace_path;
  if (args.trace) {
    trace_path = args.trace_file.empty()
                     ? harness::default_trace_path(kTestName, args.seed)
                     : args.trace_file;
    if (trace.open(top.get(), trace_path, harness::kDefaultTraceDepth)) {
      sched.set_step_hook([&trace](SimTime t) { trace.dump(t); });
      std::printf("  trace      : %s\n", trace_path.c_str());
    } else {
      trace_path.clear();
    }
  }

  const SimTime time_limit = static_cast<SimTime>(hard_limit + 200000) * half * 2;

  auto step = [&](std::uint64_t n) {
    sched.clear_stop();
    sched.run_cycles(clk, n, time_limit);
  };

  // Presents one beat to the override port. The scheduler applies stimulus after
  // the edge, so the beat is on the pins for the cycle after the queue is
  // popped; two steps take it from "queued" to "seen and acted on".
  auto sq_beat = [&](std::uint32_t id, std::uint32_t seq, bool sof) {
    sq_queue.push_back(SqStim{true, id, seq & kSeqMask, sof});
    step(2);
  };
  auto sq_run = [&](std::uint32_t id, std::uint32_t first, std::uint32_t n) {
    for (std::uint32_t i = 0; i < n; ++i) sq_beat(id, first + i, i == 0);
  };

  auto run_reset = [&]() {
    driver.reset();
    sq_queue.clear();
    sched.clear_stop();
    reset.assert_all();
    const StopReason r = reset.release_all(time_limit);
    timeout.reset();
    return r == StopReason::kRunning;
  };

  // ---- register helpers --------------------------------------------------
  auto rd = [&](std::uint32_t address, const std::string& what) {
    const RegResult r = driver.read(address);
    if (r.timed_out) {
      fail("reg_timeout", what + ": read " + RegDriver::describe(address) +
                              " never completed");
      return static_cast<std::uint32_t>(0);
    }
    check(!r.error, "reg_error",
          what + ": read " + RegDriver::describe(address) + " answered error=1");
    check(r.cycles == kExpectedCycles, "reg_latency",
          what + ": read " + RegDriver::describe(address) + " took " +
              std::to_string(r.cycles) + " cycles");
    return r.data;
  };
  auto expect_read = [&](std::uint32_t address, std::uint32_t want,
                         const std::string& what) {
    const std::uint32_t got = rd(address, what);
    check(got == want, "reg_value",
          what + ": " + RegDriver::describe(address) + " returned " + hex32(got) +
              ", expected " + hex32(want));
  };
  std::uint32_t ctrl_levels =
      (1u << regmap::COUNTERS_TELEM_CTRL_ENABLE_LSB) |
      (1u << regmap::COUNTERS_TELEM_CTRL_SEQ_ENABLE_LSB);
  auto ctrl_write = [&](std::uint32_t pulses, const std::string& what) {
    const RegResult r =
        driver.write(regmap::COUNTERS_TELEM_CTRL_ADDR, ctrl_levels | pulses, 0xF);
    check(!r.error && !r.timed_out, "reg_error",
          what + ": the control write did not complete cleanly");
  };
  auto snapshot = [&](const std::string& what) {
    ctrl_write(1u << regmap::COUNTERS_TELEM_CTRL_SNAPSHOT_LSB, what);
  };

  // Checks a directed case: exactly one fault, of the named kind, since `base`.
  auto expect_one = [&](const Seen& base, Verdict kind, std::uint32_t gap_size,
                        const std::string& what) {
    const std::uint64_t d_gap = seen.gap - base.gap;
    const std::uint64_t d_dup = seen.dup - base.dup;
    const std::uint64_t d_ror = seen.reorder - base.reorder;
    const std::uint64_t d_unt = seen.untracked - base.untracked;
    const std::uint64_t total = d_gap + d_dup + d_ror + d_unt;
    const std::string got = "gap=" + std::to_string(d_gap) + " dup=" +
                            std::to_string(d_dup) + " reorder=" +
                            std::to_string(d_ror) + " untracked=" +
                            std::to_string(d_unt);
    check(total == 1, "seq_classify",
          what + ": expected exactly one " + telemetry::to_string(kind) +
              ", the checker reported " + got);
    const bool right = (kind == Verdict::kGap && d_gap == 1) ||
                       (kind == Verdict::kDuplicate && d_dup == 1) ||
                       (kind == Verdict::kReorder && d_ror == 1) ||
                       (kind == Verdict::kUntracked && d_unt == 1);
    check(right, "seq_classify",
          what + ": expected " + telemetry::to_string(kind) +
              ", the checker reported " + got);
    if (kind == Verdict::kGap) {
      check(seen.last_gap == gap_size, "seq_gap_size",
            what + ": the gap was reported as " + std::to_string(seen.last_gap) +
                " beats, " + std::to_string(gap_size) + " were missing");
    }
  };
  auto expect_none = [&](const Seen& base, const std::string& what) {
    const std::uint64_t total = (seen.gap - base.gap) + (seen.dup - base.dup) +
                                (seen.reorder - base.reorder) +
                                (seen.untracked - base.untracked);
    check(total == 0, "seq_classify",
          what + ": " + std::to_string(total) +
              " faults were reported on a stream that has none");
  };

  if (!run_reset()) fail("reset", "the reset sequence did not complete");

  const bool quiet = args.quiet;
  auto banner = [&](int n, const char* name) {
    if (!quiet) std::printf("  pass %d/9 %-16s ", n, name);
    std::fflush(stdout);
  };
  auto verdict_of = [&](std::size_t before) {
    const bool ok = errors.count() == before;
    if (!quiet) std::printf("-> %s\n", ok ? "OK" : "FAILED");
    std::fflush(stdout);
    return ok;
  };

  // =========================================================================
  // Pass 1 — real traffic, real backpressure, zero faults
  // =========================================================================
  {
    banner(1, "nominal");
    const std::size_t before = errors.count();
    sq_override = false;

    stream_drv = std::make_unique<StreamDriver>(
        "src", src, seeds.engine("seq.src"), BackpressureConfig::heavy(), errors);
    stream_mon = std::make_unique<StreamMonitor>(
        "snk", snk, seeds.engine("seq.snk"), BackpressureConfig::bursty(), errors);
    stream_mon->set_sequence_width(layout.seq_w);
    stream_drv->set_cycle_probe(&cycle);
    stream_mon->set_cycle_probe(&cycle);
    stream_drv->set_accept_hook([&](const StreamBeat& b, std::uint64_t c) {
      board.expect(identity_of(b), b, c);
    });
    stream_mon->set_observe_hook([&](const StreamBeat& b, std::uint64_t c) {
      board.observe(identity_of(b), b, c);
    });
    board.reset();
    stream_drv->reset(true);
    stream_mon->reset();

    std::mt19937_64 rng = seeds.engine("seq.traffic");
    std::uint32_t next_seq[kTracked] = {0};
    std::uint32_t tag = 0;
    for (int f = 0; f < 40; ++f) {
      const std::uint32_t id =
          static_cast<std::uint32_t>(harness::uniform_u64(rng, 0, kTracked - 1));
      const std::uint32_t len =
          static_cast<std::uint32_t>(harness::uniform_u64(rng, 1, 8));
      std::vector<StreamBeat> frame;
      for (std::uint32_t i = 0; i < len; ++i) {
        StreamBeat b;
        b.data = harness::uniform_u64(rng, 0, StreamLayout::mask_of(layout.data_w));
        b.start_of_frame = (i == 0);
        b.end_of_frame = (i + 1 == len);
        b.stream_id = id;
        b.seq = next_seq[id] & kSeqMask;
        b.user =
            tag & static_cast<std::uint32_t>(StreamLayout::mask_of(layout.user_w));
        next_seq[id] = (next_seq[id] + 1) & kSeqMask;
        frame.push_back(b);
      }
      ++tag;
      stream_drv->queue_frame(frame);
    }

    const Seen base = seen;
    stimulus_enabled = true;
    stop_on_drain = true;
    sched.clear_stop();
    const StopReason r = sched.run(time_limit);
    stop_on_drain = false;
    stimulus_enabled = false;
    sched.clear_stop();

    check(r == StopReason::kPass, "traffic", "the nominal traffic did not drain");
    board.finalize();
    stream_mon->check_drained();
    check(board.stats().clean(), "scoreboard",
          "the measured path lost, duplicated or reordered traffic");
    check(stream_mon->beats_received() > 20, "coverage",
          "too little traffic flowed to prove the checker stays quiet");
    expect_none(base, "nominal");
    check(top->sq_sticky == 0, "seq_sticky",
          "the checker set a sticky flag on continuous traffic");
    verdict_of(before);
  }

  // =========================================================================
  // Pass 2 — a gap
  // =========================================================================
  {
    banner(2, "gap");
    const std::size_t before = errors.count();
    if (!run_reset()) fail("reset", "the reset sequence did not complete");
    sq_override = true;

    sq_run(0, 100, 3);           // 100, 101, 102 -> expect 103
    Seen base = seen;
    sq_beat(0, 105, false);      // 103 and 104 never arrived
    expect_one(base, Verdict::kGap, 2, "gap");

    // Resynchronised: the beat after the gap is in order again. Without the
    // forward resync every subsequent beat would be a fresh gap, and one lost
    // burst would look like a permanently broken stream.
    base = seen;
    sq_beat(0, 106, false);
    sq_beat(0, 107, false);
    expect_none(base, "gap.resync");

    // A gap of one, the smallest there is.
    base = seen;
    sq_beat(0, 109, false);
    expect_one(base, Verdict::kGap, 1, "gap.one");
    verdict_of(before);
  }

  // =========================================================================
  // Pass 3 — a duplicate
  // =========================================================================
  {
    banner(3, "duplicate");
    const std::size_t before = errors.count();
    if (!run_reset()) fail("reset", "the reset sequence did not complete");
    sq_override = true;

    sq_run(1, 40, 3);            // 40, 41, 42 -> expect 43
    Seen base = seen;
    sq_beat(1, 42, false);       // the beat just accepted, again
    expect_one(base, Verdict::kDuplicate, 0, "duplicate");

    // The expectation must NOT have moved: 43 is still the next beat in order.
    base = seen;
    sq_beat(1, 43, false);
    expect_none(base, "duplicate.expectation_held");

    // Two duplicates in a row are two duplicates.
    base = seen;
    sq_beat(1, 43, false);
    sq_beat(1, 43, false);
    check(seen.dup - base.dup == 2, "seq_classify",
          "two repeats of one beat were counted as " +
              std::to_string(seen.dup - base.dup));
    verdict_of(before);
  }

  // =========================================================================
  // Pass 4 — a reordered beat
  // =========================================================================
  {
    banner(4, "reorder");
    const std::size_t before = errors.count();
    if (!run_reset()) fail("reset", "the reset sequence did not complete");
    sq_override = true;

    sq_run(0, 500, 5);           // 500..504 -> expect 505
    Seen base = seen;
    sq_beat(0, 501, false);      // four behind: late, not a repeat
    expect_one(base, Verdict::kReorder, 0, "reorder");

    // As with a duplicate, the expectation stands: a late beat says nothing
    // about where the stream is now.
    base = seen;
    sq_beat(0, 505, false);
    expect_none(base, "reorder.expectation_held");

    // The boundary between the two backward categories: exactly one behind is a
    // duplicate, exactly two behind is a reorder. Getting this edge wrong is the
    // most likely way to build a checker that looks right.
    base = seen;
    sq_beat(0, 505, false);
    expect_one(base, Verdict::kDuplicate, 0, "reorder.boundary_one_back");
    base = seen;
    sq_beat(0, 504, false);
    expect_one(base, Verdict::kReorder, 0, "reorder.boundary_two_back");
    verdict_of(before);
  }

  // =========================================================================
  // Pass 5 — a beat on an untracked stream
  // =========================================================================
  {
    banner(5, "untracked");
    const std::size_t before = errors.count();
    if (!run_reset()) fail("reset", "the reset sequence did not complete");
    sq_override = true;

    sq_run(0, 0, 3);
    Seen base = seen;
    sq_beat(kTracked, 7, true);
    expect_one(base, Verdict::kUntracked, 0, "untracked");

    // An untracked beat must not disturb a tracked stream's expectation.
    base = seen;
    sq_beat(0, 3, false);
    expect_none(base, "untracked.no_side_effect");

    // Every id at or above the tracked count behaves the same way.
    base = seen;
    for (std::uint32_t id = kTracked; id < (1u << sim_config::STREAM_ID_W); ++id) {
      sq_beat(id, 1234, false);
    }
    check(seen.untracked - base.untracked ==
              (1u << sim_config::STREAM_ID_W) - kTracked,
          "seq_classify", "not every untracked stream_id was counted");
    verdict_of(before);
  }

  // =========================================================================
  // Pass 6 — initialisation and the two resync mechanisms
  // =========================================================================
  {
    banner(6, "init_resync");
    const std::size_t before = errors.count();
    if (!run_reset()) fail("reset", "the reset sequence did not complete");
    sq_override = true;

    // The first beat of a stream establishes the expectation and is never an
    // error, whatever it carries.
    Seen base = seen;
    sq_beat(0, 0xABC, true);
    expect_none(base, "init.first_beat");
    base = seen;
    sq_beat(0, 0xABD, false);
    expect_none(base, "init.second_beat");

    // ENABLE low drops every expectation; the first beat after it rises
    // re-initialises rather than reporting the traffic that flowed meanwhile.
    ctrl_levels &= ~(1u << regmap::COUNTERS_TELEM_CTRL_SEQ_ENABLE_LSB);
    ctrl_write(0, "init.disable");
    check(top->obs_seq_enable == 0, "reg_output",
          "SEQ_ENABLE was cleared but the checker still reports enabled");
    base = seen;
    sq_beat(0, 0x100, false);  // wildly out of sequence, and ignored
    expect_none(base, "init.disabled");
    ctrl_levels |= (1u << regmap::COUNTERS_TELEM_CTRL_SEQ_ENABLE_LSB);
    ctrl_write(0, "init.enable");
    base = seen;
    sq_beat(0, 0x200, false);  // re-initialises: no error
    expect_none(base, "init.after_reenable");
    base = seen;
    sq_beat(0, 0x201, false);
    expect_none(base, "init.after_reenable_continues");

    // With SEQ_SOF_RESYNC off, a start_of_frame does NOT excuse a jump.
    base = seen;
    sq_beat(0, 0x300, true);
    expect_one(base, Verdict::kGap, 0x300 - 0x202, "resync.off");

    // With it on, the same beat re-establishes the expectation silently.
    ctrl_levels |= (1u << regmap::COUNTERS_TELEM_CTRL_SEQ_SOF_RESYNC_LSB);
    ctrl_write(0, "resync.enable");
    check(top->obs_seq_sof_resync != 0, "reg_output",
          "SEQ_SOF_RESYNC was set but the checker still reports it off");
    base = seen;
    sq_beat(0, 0x900, true);
    expect_none(base, "resync.on");
    base = seen;
    sq_beat(0, 0x901, false);
    expect_none(base, "resync.on_continues");
    // And a beat WITHOUT start_of_frame is still judged normally, so the option
    // relaxes exactly one thing.
    base = seen;
    sq_beat(0, 0x910, false);
    expect_one(base, Verdict::kGap, 0x910 - 0x902, "resync.on_midframe");

    ctrl_levels &= ~(1u << regmap::COUNTERS_TELEM_CTRL_SEQ_SOF_RESYNC_LSB);
    ctrl_write(0, "resync.disable");
    verdict_of(before);
  }

  // =========================================================================
  // Pass 7 — the sequence wrap
  // =========================================================================
  {
    banner(7, "seq_wrap");
    const std::size_t before = errors.count();
    if (!run_reset()) fail("reset", "the reset sequence did not complete");
    sq_override = true;

    // Walk across the top of the range in order. Nothing here may be a fault.
    Seen base = seen;
    for (std::uint32_t i = 0; i < 6; ++i) {
      sq_beat(0, (kSeqMask - 2 + i) & kSeqMask, i == 0);
    }
    expect_none(base, "wrap.in_order");

    // A gap that straddles the wrap. The walk above ended at 0x0002, so the
    // expectation is 0x0003 and 0x0007 leaves 0x0003..0x0006 missing: four
    // beats, computed with no special case for the wrap anywhere.
    base = seen;
    sq_beat(0, 0x0007, false);
    expect_one(base, Verdict::kGap, 4, "wrap.gap");

    // A duplicate across the wrap: expectation is 8, so 7 is one behind.
    base = seen;
    sq_beat(0, 0x0007, false);
    expect_one(base, Verdict::kDuplicate, 0, "wrap.duplicate");

    // And a reorder from the far side of the wrap.
    base = seen;
    sq_beat(0, kSeqMask - 1, false);
    expect_one(base, Verdict::kReorder, 0, "wrap.reorder");
    verdict_of(before);
  }

  // =========================================================================
  // Pass 8 — the same faults through the SPEC 9 register plane
  // =========================================================================
  {
    banner(8, "registers");
    const std::size_t before = errors.count();
    if (!run_reset()) fail("reset", "the reset sequence did not complete");
    sq_override = true;
    ctrl_levels = (1u << regmap::COUNTERS_TELEM_CTRL_ENABLE_LSB) |
                  (1u << regmap::COUNTERS_TELEM_CTRL_SEQ_ENABLE_LSB);

    snapshot("registers.initial");
    expect_read(regmap::COUNTERS_SEQ_GAP_COUNT_ADDR, 0u, "registers");
    expect_read(regmap::COUNTERS_SEQ_DUP_COUNT_ADDR, 0u, "registers");
    expect_read(regmap::COUNTERS_SEQ_REORDER_COUNT_ADDR, 0u, "registers");
    expect_read(regmap::COUNTERS_SEQ_LOST_BEATS_ADDR, 0u, "registers");
    expect_read(regmap::COUNTERS_SEQ_UNTRACKED_COUNT_ADDR, 0u, "registers");
    expect_read(regmap::COUNTERS_SEQ_STATUS_ADDR, 0u, "registers");

    const Seen base = seen;
    sq_run(0, 10, 3);        // 10, 11, 12
    sq_beat(0, 20, false);   // gap of 7
    sq_beat(0, 20, false);   // duplicate
    sq_beat(0, 15, false);   // reorder
    sq_beat(kTracked, 3, false);  // untracked
    sq_beat(0, 25, false);   // gap of 4

    check(seen.gap - base.gap == 2 && seen.dup - base.dup == 1 &&
              seen.reorder - base.reorder == 1 &&
              seen.untracked - base.untracked == 1,
          "seq_classify",
          "the directed fault sequence produced gap=" +
              std::to_string(seen.gap - base.gap) + " dup=" +
              std::to_string(seen.dup - base.dup) + " reorder=" +
              std::to_string(seen.reorder - base.reorder) + " untracked=" +
              std::to_string(seen.untracked - base.untracked));

    snapshot("registers.after");
    expect_read(regmap::COUNTERS_SEQ_GAP_COUNT_ADDR,
                static_cast<std::uint32_t>(seen.gap), "registers.gap");
    expect_read(regmap::COUNTERS_SEQ_DUP_COUNT_ADDR,
                static_cast<std::uint32_t>(seen.dup), "registers.dup");
    expect_read(regmap::COUNTERS_SEQ_REORDER_COUNT_ADDR,
                static_cast<std::uint32_t>(seen.reorder), "registers.reorder");
    expect_read(regmap::COUNTERS_SEQ_LOST_BEATS_ADDR,
                static_cast<std::uint32_t>(seen.lost), "registers.lost");
    expect_read(regmap::COUNTERS_SEQ_UNTRACKED_COUNT_ADDR,
                static_cast<std::uint32_t>(seen.untracked),
                "registers.untracked");
    check(seen.lost == 11, "seq_gap_size",
          "the two gaps lost " + std::to_string(seen.lost) +
              " beats between them, 11 were missing");

    // SEQ_STATUS: this block's own W1C copy, and the checker's sticky mirror.
    const std::uint32_t status = rd(regmap::COUNTERS_SEQ_STATUS_ADDR, "registers");
    const std::uint32_t w1c = status & 0xFu;
    const std::uint32_t mirror =
        regmap::field_get(status, regmap::COUNTERS_SEQ_STATUS_CHECKER_STICKY_LSB,
                          regmap::COUNTERS_SEQ_STATUS_CHECKER_STICKY_WIDTH);
    check(w1c == 0xFu, "seq_sticky",
          "SEQ_STATUS reports " + hex32(w1c) +
              " after all four kinds of fault; every bit should be set");
    check(mirror == top->sq_sticky, "seq_sticky",
          "SEQ_STATUS.CHECKER_STICKY reads " + hex32(mirror) +
              " and the checker's own flags are " + hex32(top->sq_sticky));

    // Writing 1 clears this block's copy and leaves the checker's alone; the
    // counts are untouched by either.
    const RegResult wc =
        driver.write(regmap::COUNTERS_SEQ_STATUS_ADDR, 0xFu, 0xF);
    check(!wc.error, "reg_error", "clearing SEQ_STATUS answered error=1");
    const std::uint32_t after = rd(regmap::COUNTERS_SEQ_STATUS_ADDR, "registers");
    check((after & 0xFu) == 0, "seq_sticky",
          "SEQ_STATUS still reads " + hex32(after) + " after a write-1-to-clear");
    check(regmap::field_get(after,
                            regmap::COUNTERS_SEQ_STATUS_CHECKER_STICKY_LSB,
                            regmap::COUNTERS_SEQ_STATUS_CHECKER_STICKY_WIDTH) ==
              0xFu,
          "seq_sticky",
          "clearing this block's copy also cleared the checker's own flags");
    expect_read(regmap::COUNTERS_SEQ_GAP_COUNT_ADDR,
                static_cast<std::uint32_t>(seen.gap), "registers.count_held");

    // TELEM_CTRL.STICKY_CLEAR is what clears the checker's flags.
    ctrl_write(1u << regmap::COUNTERS_TELEM_CTRL_STICKY_CLEAR_LSB,
               "registers.sticky_clear");
    check(top->sq_sticky == 0, "seq_sticky",
          "STICKY_CLEAR left the checker's flags at " + hex32(top->sq_sticky));
    verdict_of(before);
  }

  // =========================================================================
  // Pass 9 — randomized fault injection
  // =========================================================================
  {
    banner(9, "random_faults");
    const std::size_t before = errors.count();
    if (!run_reset()) fail("reset", "the reset sequence did not complete");
    sq_override = true;

    std::mt19937_64 rng = seeds.engine("seq.random");
    const std::uint64_t beats = args.frames != 0 ? args.frames * 8 : 500;

    std::uint32_t pos[kTracked] = {0};
    for (std::uint32_t i = 0; i < kTracked; ++i) {
      pos[i] = static_cast<std::uint32_t>(
          harness::uniform_u64(rng, 0, kSeqMask));
    }

    std::uint64_t injected = 0;
    for (std::uint64_t i = 0; i < beats && errors.count() == before; ++i) {
      const std::uint32_t id =
          static_cast<std::uint32_t>(harness::uniform_u64(rng, 0, kTracked - 1));
      std::uint32_t seq = pos[id];
      bool advance = true;

      // Roughly one beat in six is a deliberate fault, in one of four ways.
      if (harness::bernoulli(rng, 0.16)) {
        ++injected;
        switch (harness::uniform_u64(rng, 0, 3)) {
          case 0: {  // gap
            const std::uint32_t skip = static_cast<std::uint32_t>(
                harness::uniform_u64(rng, 1, 32));
            seq = (pos[id] + skip) & kSeqMask;
            break;
          }
          case 1:  // duplicate
            seq = (pos[id] - 1) & kSeqMask;
            advance = false;
            break;
          case 2: {  // reorder
            const std::uint32_t back = static_cast<std::uint32_t>(
                harness::uniform_u64(rng, 2, 64));
            seq = (pos[id] - back) & kSeqMask;
            advance = false;
            break;
          }
          default: {  // untracked stream
            const std::uint32_t bad_id = static_cast<std::uint32_t>(
                harness::uniform_u64(rng, kTracked,
                                     (1u << sim_config::STREAM_ID_W) - 1));
            sq_beat(bad_id, seq, false);
            continue;
          }
        }
      }

      sq_beat(id, seq, harness::bernoulli(rng, 0.1));
      if (advance) pos[id] = (seq + 1) & kSeqMask;
    }

    check(injected > 20, "coverage",
          "only " + std::to_string(injected) +
              " faults were injected; the randomized pass proves little");

    snapshot("random.final");
    const SeqCounts shadows = model.shadows();
    expect_read(regmap::COUNTERS_SEQ_GAP_COUNT_ADDR,
                static_cast<std::uint32_t>(shadows.gap), "random.gap");
    expect_read(regmap::COUNTERS_SEQ_DUP_COUNT_ADDR,
                static_cast<std::uint32_t>(shadows.dup), "random.dup");
    expect_read(regmap::COUNTERS_SEQ_REORDER_COUNT_ADDR,
                static_cast<std::uint32_t>(shadows.reorder), "random.reorder");
    expect_read(regmap::COUNTERS_SEQ_LOST_BEATS_ADDR,
                static_cast<std::uint32_t>(shadows.lost), "random.lost");
    expect_read(regmap::COUNTERS_SEQ_UNTRACKED_COUNT_ADDR,
                static_cast<std::uint32_t>(shadows.untracked),
                "random.untracked");
    check(shadows.gap == seen.gap && shadows.dup == seen.dup &&
              shadows.reorder == seen.reorder &&
              shadows.untracked == seen.untracked && shadows.lost == seen.lost,
          "seq_count",
          "the model's shadows (" + shadows.to_string() +
              ") disagree with what the harness watched the pins report");
    verdict_of(before);
  }

  // ---- run-wide invariants ----------------------------------------------
  check(driver.timeouts() == 0, "reg_hang",
        std::to_string(driver.timeouts()) + " register accesses never completed");
  check(seen.gap > 0 && seen.dup > 0 && seen.reorder > 0 && seen.untracked > 0,
        "coverage",
        "not every fault category was exercised: gap=" +
            std::to_string(seen.gap) + " dup=" + std::to_string(seen.dup) +
            " reorder=" + std::to_string(seen.reorder) + " untracked=" +
            std::to_string(seen.untracked));

  const bool passed = errors.ok();

  const auto wall_end = std::chrono::steady_clock::now();
  RunSummary summary;
  summary.test_name = kTestName;
  summary.config_name = sim_config::kName;
  summary.build_mode = args.build_mode;
  summary.seed = args.seed;
  summary.passed = passed;
  summary.stop_reason = harness::to_string(sched.stop_reason());
  summary.stop_detail = passed ? sched.stop_detail() : first_failure;
  summary.passes = 9;
  summary.core_cycles = sched.cycles(clk);
  summary.cfg_cycles = sched.cycles(clk);
  summary.sim_time_ps = sched.time();
  summary.beats_driven = stream_drv ? stream_drv->beats_sent() : 0;
  summary.beats_observed = stream_mon ? stream_mon->beats_received() : 0;
  summary.scoreboard = board.stats();
  summary.trace_path = trace_path;
  summary.absorb(errors);
  summary.wall_time_s =
      std::chrono::duration<double>(wall_end - wall_start).count();

  const std::string written = summary.write(args.results_dir);

  std::printf("--- summary ---\n");
  std::printf("  tracked streams: %u of %u addressable\n", kTracked,
              1u << sim_config::STREAM_ID_W);
  std::printf("  faults detected: gap %llu (%llu beats lost), duplicate %llu, "
              "reorder %llu, untracked %llu\n",
              static_cast<unsigned long long>(seen.gap),
              static_cast<unsigned long long>(seen.lost),
              static_cast<unsigned long long>(seen.dup),
              static_cast<unsigned long long>(seen.reorder),
              static_cast<unsigned long long>(seen.untracked));
  std::printf("  transactions   : %llu\n",
              static_cast<unsigned long long>(driver.transactions()));
  std::printf("  cycles         : %llu\n",
              static_cast<unsigned long long>(sched.cycles(clk)));
  std::printf("  errors         : %zu\n", errors.count());
  if (!written.empty()) std::printf("  summary json   : %s\n", written.c_str());

  trace.close();
  top->final();

  if (passed) {
    std::printf("RESULT: PASS seed=%llu test=%s config=%s\n",
                static_cast<unsigned long long>(args.seed), kTestName,
                sim_config::kName);
    return 0;
  }
  std::printf("RESULT: FAIL seed=%llu test=%s config=%s errors=%zu reason=%s\n",
              static_cast<unsigned long long>(args.seed), kTestName,
              sim_config::kName, errors.count(),
              first_failure.empty() ? "see log" : first_failure.c_str());
  return 1;
}
