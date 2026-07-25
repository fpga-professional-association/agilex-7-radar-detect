// -----------------------------------------------------------------------------
// test_perf_counters.cpp — counter and telemetry tests (SPEC 13.1/13.4, #8).
//
// One binary, one seed, nine passes over sim/verilator/tops/telemetry_top.sv,
// which holds the SPEC 9 counters block watching a real stream through a real
// FIFO, plus three deliberately narrow perf_counter probes. Every register
// access goes through harness::RegDriver, i.e. through the SPEC 9 protocol,
// exactly as software would drive it.
//
//   1  reset_defaults    every register in the window against the generated map;
//                        SNAP_VALID low, so "no snapshot yet" is distinguishable
//                        from "no events"; a write to a counter is refused.
//   2  probe_directed    count, gate, clear and snapshot on the 8-bit probes:
//                        the four things a counter does, checked where the
//                        numbers are small enough to be read by eye.
//   3  probe_wrap        SPEC 13.4. Three hundred events into an 8-bit counter:
//                        the modulo probe must report 300 mod 256 with its wrap
//                        flag set, the saturating probe must hold 0xFF, and the
//                        weighted probe must cross the boundary without landing
//                        on it and still be right.
//   4  telem_traffic     randomized traffic with random stalls, then SNAPSHOT
//                        and read: BEAT, STALL, IDLE, FRAME and FRAME_START must
//                        equal the harness's own cycle-by-cycle tally EXACTLY.
//   5  snapshot_coherence  the same, but the sweep of twenty-one registers is
//                        performed WHILE traffic runs. Every value must belong
//                        to the one instant the strobe named, SNAPSHOT_ID must
//                        be unchanged across the sweep, and the live counters
//                        must have moved during it — otherwise the test proves
//                        only that nothing was happening.
//   6  enable_clear      the measurement window: ENABLE gates every counter,
//                        CLEAR zeroes counters, shadows, the high-water mark and
//                        SNAP_VALID.
//   7  high_water        telemetry's FIFO high-water mark against the FIFO's own
//                        independent tracker. Two implementations agreeing is
//                        worth more than either asserted.
//   8  injected_events   overflow, saturation and CDC events counted, and the
//                        error counters' saturating mode confirmed by TELEM_
//                        STATUS rather than assumed.
//   9  random_soak       randomized traffic, randomized register access,
//                        randomized strobes; the whole window dumped at the end
//                        and compared with the tally.
//
// RUNNING CHECKS, every cycle of every pass
// ----------------------------------------
//   * the live counter outputs against an independent tally the harness keeps
//     from the same observed signals, so a divergence is caught at the cycle it
//     happens rather than at the next register read;
//   * the three probes against telemetry::CounterModel, the cycle-accurate C++
//     mirror in model/cpp/telemetry/, in both arithmetic modes;
//   * the stream scoreboard (SPEC 12.5), because a telemetry block that
//     corrupted the traffic it measures would otherwise pass every count check.
//
// Reset is re-run between passes, so reset coverage is per pass per seed.
// -----------------------------------------------------------------------------

#include <algorithm>
#include <chrono>
#include <cstdio>
#include <cstring>
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

using telemetry::CounterModel;

namespace {

constexpr const char* kTestName = "test_perf_counters";

// reg_if_pkg::REG_ACCESS_LATENCY seen from the master: one cycle of decode plus
// one in the block.
constexpr std::uint64_t kExpectedCycles = 2;

static_assert(sim_config::STREAM_PAYLOAD_W <= 64,
              "packed payload exceeds the 64-bit host transport");
static_assert(sim_config::TELEM_PROBE_W < 16,
              "the narrow probes must be narrow enough to wrap in a unit test");

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

// The harness's own count of what the telemetry block is watching. Not a model
// of the counters — a tally of the events, kept from the same signals the RTL
// counts, so "the register says what happened" is checkable without trusting
// any part of the implementation under test.
struct Tally {
  std::uint64_t beat = 0;
  std::uint64_t stall = 0;
  std::uint64_t idle = 0;
  std::uint64_t frame = 0;
  std::uint64_t frame_start = 0;
  std::uint64_t overflow = 0;
  std::uint64_t saturate = 0;
  std::uint64_t cdc_error = 0;
  std::uint64_t snapshot_id = 0;
  std::uint32_t high_water = 0;
};

// Levels the test drives into telemetry_top, applied once per cycle in the
// scheduler's drive phase so they are stable for the whole cycle the DUT
// samples them in.
struct Stimulus {
  bool inj_overflow = false;
  bool inj_saturate = false;
  bool inj_cdc_error = false;
  bool pc_enable = false;
  bool pc_event = false;
  bool pc_clear = false;
  bool pc_snapshot = false;
  std::uint8_t pc_incr = 1;
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
  {
    const std::string bad = layout.self_check();
    if (!bad.empty()) {
      std::fprintf(stderr, "ERROR: generated stream layout is inconsistent: %s\n",
                   bad.c_str());
      std::printf("RESULT: FAIL seed=%llu test=%s reason=layout_inconsistent\n",
                  static_cast<unsigned long long>(args.seed), kTestName);
      return 2;
    }
  }

  auto top = std::make_unique<Vtelemetry_top>();
  ErrorCollector errors;
  errors.set_print_limit(30);

  ClockScheduler sched([&top]() { top->eval(); });
  errors.set_time_probe(sched.time_ptr());

  // One domain: the telemetry block counts in the domain it observes, and the
  // register plane is brought to it here. See telemetry_top's header.
  const SimTime half = harness::half_period_ps(harness::kCoreClkMhz);
  const int clk = sched.add_clock("clk", half, &top->clk, half);

  ResetSequencer reset(sched);
  reset.add_domain("rst_n", clk, &top->rst_n, 8);

  std::uint64_t cycle = 0;
  sched.on_posedge_sample(clk, [&cycle]() { ++cycle; });

  SeedSource seeds(args.seed);

  // ---- register driver ---------------------------------------------------
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

  // ---- stream driver / monitor / scoreboard ------------------------------
  harness::PackedSourcePort src(&top->s_valid, &top->s_ready, &top->s_payload,
                                layout);
  harness::PackedSinkPort snk(&top->m_valid, &top->m_ready, &top->m_payload,
                              layout);
  Scoreboard board("telemetry_path", errors);
  std::unique_ptr<StreamDriver> stream_drv;
  std::unique_ptr<StreamMonitor> stream_mon;
  bool stimulus_enabled = false;
  // Armed only inside drain_traffic(). A latched "pass complete" flag would
  // stop the scheduler once and then never again, and every later register
  // access — which pumps the scheduler itself — would find it stopped and
  // report a timeout that never happened.
  bool stop_on_drain = false;

  // ---- running state -----------------------------------------------------
  Tally live{};
  Tally shadow{};
  bool shadow_valid = false;
  Stimulus stim;

  CounterModel probe_mod(sim_config::TELEM_PROBE_W, false);
  CounterModel probe_sat(sim_config::TELEM_PROBE_W, true);
  CounterModel probe_inc(sim_config::TELEM_PROBE_W, false);
  // Events the probes have been shown since the last clear, tallied
  // independently of both the RTL and the model.
  std::uint64_t probe_events = 0;
  std::uint64_t probe_weight = 0;

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

  // Compare-then-advance, every cycle. The pins hold the state produced by the
  // previous edge, so the comparison happens before this cycle's tally update.
  bool model_active = false;
  std::uint64_t live_mismatch = 0;

  sched.on_posedge_sample(clk, [&]() {
    if (top->rst_n == 0) {
      live = Tally{};
      shadow = Tally{};
      shadow_valid = false;
      probe_mod.reset();
      probe_sat.reset();
      probe_inc.reset();
      probe_events = 0;
      probe_weight = 0;
      model_active = true;
      return;
    }
    if (!model_active) return;

    // ---- live telemetry counters against the harness tally ----
    const std::uint64_t mask32 = 0xFFFFFFFFull;
    struct LiveCheck {
      const char* name;
      std::uint64_t got;
      std::uint64_t want;
    };
    const LiveCheck lives[] = {
        {"BEAT", top->live_beat_count, live.beat},
        {"STALL", top->live_stall_count, live.stall},
        {"IDLE", top->live_idle_count, live.idle & mask32},
        {"FRAME", top->live_frame_count, live.frame & mask32},
        {"FRAME_START", top->live_frame_start_count, live.frame_start & mask32},
        {"OVERFLOW", top->live_overflow_count, live.overflow & mask32},
        {"SATURATE", top->live_saturate_count, live.saturate & mask32},
        {"CDC_ERROR", top->live_cdc_error_count, live.cdc_error & mask32},
        {"SNAPSHOT_ID", top->live_snapshot_id, live.snapshot_id & mask32},
        {"HIGH_WATER", top->live_fifo_high_water, live.high_water},
    };
    for (const LiveCheck& c : lives) {
      if (c.got != c.want && live_mismatch < 8) {
        ++live_mismatch;
        fail("counter_live",
             std::string("live ") + c.name + " counter is " +
                 std::to_string(c.got) + ", the harness tally says " +
                 std::to_string(c.want) + " at cycle " + std::to_string(cycle));
      }
    }

    // ---- the three probes against the C++ counter model ----
    struct ProbeCheck {
      const char* name;
      std::uint64_t count;
      std::uint64_t snap;
      bool wrap_pulse;
      bool wrapped;
      const CounterModel* model;
    };
    const ProbeCheck probes[] = {
        {"modulo", top->pcw_count, top->pcw_snap, top->pcw_wrap_pulse != 0,
         top->pcw_wrapped != 0, &probe_mod},
        {"saturating", top->pcs_count, top->pcs_snap, top->pcs_wrap_pulse != 0,
         top->pcs_wrapped != 0, &probe_sat},
        {"weighted", top->pci_count, top->pci_snap, top->pci_wrap_pulse != 0,
         top->pci_wrapped != 0, &probe_inc},
    };
    for (const ProbeCheck& p : probes) {
      if (live_mismatch >= 8) break;
      const bool ok = p.count == p.model->count() && p.snap == p.model->snap() &&
                      p.wrap_pulse == p.model->wrap_pulse() &&
                      p.wrapped == p.model->wrapped();
      if (!ok) {
        ++live_mismatch;
        fail("counter_model",
             std::string("probe ") + p.name + " at cycle " +
                 std::to_string(cycle) + ": RTL count=" +
                 std::to_string(p.count) + " snap=" + std::to_string(p.snap) +
                 " wrap=" + std::to_string(p.wrap_pulse ? 1 : 0) + " sticky=" +
                 std::to_string(p.wrapped ? 1 : 0) + "; model count=" +
                 std::to_string(p.model->count()) + " snap=" +
                 std::to_string(p.model->snap()) + " wrap=" +
                 std::to_string(p.model->wrap_pulse() ? 1 : 0) + " sticky=" +
                 std::to_string(p.model->wrapped() ? 1 : 0));
      }
    }

    // ---- advance the tally with this cycle's events ----
    const StreamBeat out = layout.unpack(top->m_payload);
    const bool en = top->obs_count_enable != 0;
    const bool beat = top->obs_beat != 0;
    if (en) {
      if (beat) ++live.beat;
      if (top->obs_stall) ++live.stall;
      if (top->obs_idle) ++live.idle;
      if (beat && out.end_of_frame) ++live.frame;
      if (beat && out.start_of_frame) ++live.frame_start;
      if (top->inj_overflow) ++live.overflow;
      if (top->inj_saturate) ++live.saturate;
      if (top->inj_cdc_error) ++live.cdc_error;
      if (top->fifo_occupancy > live.high_water) {
        live.high_water = top->fifo_occupancy;
      }
    }
    // SNAPSHOT_ID is not gated by ENABLE: a reader must be able to prove a
    // sweep was coherent even with the measurement window shut.
    if (top->obs_snapshot_strobe) ++live.snapshot_id;

    // Clear beats every event in the same cycle; the shadow then latches what
    // the counter itself takes, which is zero.
    if (top->obs_counter_clear) {
      live = Tally{};
      shadow = Tally{};
      shadow_valid = false;
    }
    if (top->obs_snapshot_strobe) {
      shadow = live;
      shadow_valid = true;
    }

    // ---- advance the probe models and their tallies ----
    if (top->pc_enable && top->pc_event) {
      ++probe_events;
      probe_weight += top->pc_incr;
    }
    if (top->pc_clear) {
      probe_events = 0;
      probe_weight = 0;
    }
    probe_mod.tick(top->pc_enable != 0, top->pc_event != 0, 1,
                   top->pc_clear != 0, top->pc_snapshot != 0);
    probe_sat.tick(top->pc_enable != 0, top->pc_event != 0, 1,
                   top->pc_clear != 0, top->pc_snapshot != 0);
    probe_inc.tick(top->pc_enable != 0, top->pc_event != 0, top->pc_incr,
                   top->pc_clear != 0, top->pc_snapshot != 0);

    if (stimulus_enabled) {
      stream_drv->on_sample();
      stream_mon->on_sample();
    }
  });

  sched.on_posedge_drive(clk, [&]() {
    top->inj_overflow = stim.inj_overflow ? 1 : 0;
    top->inj_saturate = stim.inj_saturate ? 1 : 0;
    top->inj_cdc_error = stim.inj_cdc_error ? 1 : 0;
    top->pc_enable = stim.pc_enable ? 1 : 0;
    top->pc_event = stim.pc_event ? 1 : 0;
    top->pc_clear = stim.pc_clear ? 1 : 0;
    top->pc_snapshot = stim.pc_snapshot ? 1 : 0;
    top->pc_incr = stim.pc_incr;
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
      args.timeout_cycles != 0 ? args.timeout_cycles : 600000;
  TimeoutGuard timeout(sched, errors, hard_limit, 6000, [&]() {
    return driver.transactions() + live.beat + probe_events +
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

  // This test never drives the sequence checker's override; it watches the real
  // datapath, where a fault would be a defect. test_seq_checker owns the
  // injected cases.
  top->sq_override = 0;
  top->sq_beat = 0;
  top->sq_stream_id = 0;
  top->sq_seq = 0;
  top->sq_sof = 0;

  auto step = [&](std::uint64_t n) {
    sched.clear_stop();
    sched.run_cycles(clk, n, time_limit);
  };

  // A one-cycle strobe on a level the drive phase applies.
  //
  // The scheduler applies stimulus AFTER the edge, so a value set here is on the
  // pins for the following cycle and is sampled at the edge after that. One
  // step() therefore only presents the strobe; the second is the cycle in which
  // the DUT sees it. Writing that out once, here, is why no directed case below
  // has to reason about it.
  auto strobe = [&](bool* level) {
    *level = true;
    step(1);
    *level = false;
    step(1);
  };

  auto run_reset = [&]() {
    driver.reset();
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
    return got;
  };
  auto wr = [&](std::uint32_t address, std::uint32_t value,
                const std::string& what) {
    const RegResult r = driver.write(address, value, 0xF);
    if (r.timed_out) {
      fail("reg_timeout", what + ": write " + RegDriver::describe(address) +
                              " never completed");
      return;
    }
    check(!r.error, "reg_error",
          what + ": write " + RegDriver::describe(address) + " answered error=1");
  };
  // TELEM_CTRL is read-modify-write for the level bits and write-1-pulse for the
  // strobes, so every control write goes through one helper that keeps the
  // levels and pulses exactly what the caller asked for.
  std::uint32_t ctrl_levels =
      (1u << regmap::COUNTERS_TELEM_CTRL_ENABLE_LSB) |
      (1u << regmap::COUNTERS_TELEM_CTRL_SEQ_ENABLE_LSB);
  auto ctrl_write = [&](std::uint32_t pulses, const std::string& what) {
    wr(regmap::COUNTERS_TELEM_CTRL_ADDR, ctrl_levels | pulses, what);
  };
  auto snapshot = [&](const std::string& what) {
    ctrl_write(1u << regmap::COUNTERS_TELEM_CTRL_SNAPSHOT_LSB, what);
  };
  auto clear_all = [&](const std::string& what) {
    ctrl_write(1u << regmap::COUNTERS_TELEM_CTRL_CLEAR_LSB, what);
  };

  // Reads a 64-bit counter as the LO/HI pair the map defines.
  auto read_wide = [&](std::uint32_t lo_addr, std::uint32_t hi_addr,
                       const std::string& what) {
    const std::uint64_t lo = rd(lo_addr, what);
    const std::uint64_t hi = rd(hi_addr, what);
    return (hi << 32) | lo;
  };

  const std::uint32_t kStatusExpected =
      (static_cast<std::uint32_t>(sim_config::TELEM_COUNT_W)
       << regmap::COUNTERS_TELEM_STATUS_COUNT_W_LSB) |
      (static_cast<std::uint32_t>(sim_config::TELEM_WIDE_W)
       << regmap::COUNTERS_TELEM_STATUS_WIDE_W_LSB) |
      (static_cast<std::uint32_t>(sim_config::TELEM_TRACKED_IDS)
       << regmap::COUNTERS_TELEM_STATUS_TRACKED_IDS_LSB) |
      (1u << regmap::COUNTERS_TELEM_STATUS_ERROR_SATURATE_LSB);

  // Compares every count register against the harness tally's shadow.
  auto check_shadow = [&](const std::string& what) {
    const std::uint64_t beat =
        read_wide(regmap::COUNTERS_BEAT_COUNT_LO_ADDR,
                  regmap::COUNTERS_BEAT_COUNT_HI_ADDR, what);
    const std::uint64_t stall =
        read_wide(regmap::COUNTERS_STALL_COUNT_LO_ADDR,
                  regmap::COUNTERS_STALL_COUNT_HI_ADDR, what);
    check(beat == shadow.beat, "counter_value",
          what + ": BEAT_COUNT reads " + std::to_string(beat) +
              ", the harness counted " + std::to_string(shadow.beat));
    check(stall == shadow.stall, "counter_value",
          what + ": STALL_COUNT reads " + std::to_string(stall) +
              ", the harness counted " + std::to_string(shadow.stall));
    expect_read(regmap::COUNTERS_IDLE_COUNT_ADDR,
                static_cast<std::uint32_t>(shadow.idle), what + ".IDLE");
    expect_read(regmap::COUNTERS_FRAME_COUNT_ADDR,
                static_cast<std::uint32_t>(shadow.frame), what + ".FRAME");
    expect_read(regmap::COUNTERS_FRAME_START_COUNT_ADDR,
                static_cast<std::uint32_t>(shadow.frame_start),
                what + ".FRAME_START");
    expect_read(regmap::COUNTERS_OVERFLOW_COUNT_ADDR,
                static_cast<std::uint32_t>(shadow.overflow), what + ".OVERFLOW");
    expect_read(regmap::COUNTERS_SATURATE_COUNT_ADDR,
                static_cast<std::uint32_t>(shadow.saturate), what + ".SATURATE");
    expect_read(regmap::COUNTERS_CDC_ERROR_COUNT_ADDR,
                static_cast<std::uint32_t>(shadow.cdc_error), what + ".CDC");
    expect_read(regmap::COUNTERS_SNAPSHOT_ID_ADDR,
                static_cast<std::uint32_t>(shadow.snapshot_id), what + ".SNAP_ID");
    const std::uint32_t hw = rd(regmap::COUNTERS_FIFO_HIGH_WATER_ADDR, what);
    check(regmap::field_get(hw, regmap::COUNTERS_FIFO_HIGH_WATER_HIGH_LSB,
                            regmap::COUNTERS_FIFO_HIGH_WATER_HIGH_WIDTH) ==
              shadow.high_water,
          "counter_value",
          what + ": FIFO_HIGH_WATER.HIGH reads " + hex32(hw) +
              ", the harness saw a maximum fill of " +
              std::to_string(shadow.high_water));
    check(regmap::field_get(hw, regmap::COUNTERS_FIFO_HIGH_WATER_DEPTH_LSB,
                            regmap::COUNTERS_FIFO_HIGH_WATER_DEPTH_WIDTH) ==
              sim_config::TELEM_FIFO_DEPTH,
          "counter_value",
          what + ": FIFO_HIGH_WATER.DEPTH does not report the elaborated depth");
  };

  // ---- traffic helper ----------------------------------------------------
  std::uint32_t next_seq[1u << sim_config::STREAM_ID_W] = {0};
  std::uint32_t frame_tag = 0;
  std::mt19937_64 gen_rng = seeds.engine("telemetry.traffic");

  auto start_traffic = [&](const char* tag, BackpressureConfig source,
                           BackpressureConfig sink, std::uint32_t frames,
                           std::uint32_t max_len) {
    stream_drv = std::make_unique<StreamDriver>(
        "src", src, seeds.engine(std::string("telemetry.src.") + tag), source,
        errors);
    stream_mon = std::make_unique<StreamMonitor>(
        "snk", snk, seeds.engine(std::string("telemetry.snk.") + tag), sink,
        errors);
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

    const std::uint32_t seq_mask =
        static_cast<std::uint32_t>(StreamLayout::mask_of(layout.seq_w));
    for (std::uint32_t f = 0; f < frames; ++f) {
      // Only tracked stream ids: an untracked beat is a sequence-checker case
      // and belongs to test_seq_checker, not to a counting test.
      const std::uint32_t id = static_cast<std::uint32_t>(
          harness::uniform_u64(gen_rng, 0, sim_config::TELEM_TRACKED_IDS - 1));
      const std::uint32_t len =
          static_cast<std::uint32_t>(harness::uniform_u64(gen_rng, 1, max_len));
      std::vector<StreamBeat> frame;
      for (std::uint32_t i = 0; i < len; ++i) {
        StreamBeat b;
        b.data = harness::uniform_u64(gen_rng, 0,
                                      StreamLayout::mask_of(layout.data_w));
        b.start_of_frame = (i == 0);
        b.end_of_frame = (i + 1 == len);
        b.stream_id = id;
        b.seq = next_seq[id] & seq_mask;
        b.user = frame_tag &
                 static_cast<std::uint32_t>(StreamLayout::mask_of(layout.user_w));
        next_seq[id] = (next_seq[id] + 1) & seq_mask;
        frame.push_back(b);
      }
      ++frame_tag;
      stream_drv->queue_frame(frame);
    }
    stimulus_enabled = true;
  };

  auto drain_traffic = [&](const std::string& what) {
    sched.clear_stop();
    stop_on_drain = true;
    const StopReason r = sched.run(time_limit);
    stop_on_drain = false;
    if (r != StopReason::kPass) {
      fail("traffic", what + ": traffic did not drain (" +
                          std::string(harness::to_string(r)) + ")");
    }
    board.finalize();
    stream_mon->check_drained();
    stimulus_enabled = false;
    sched.clear_stop();
  };

  if (!run_reset()) fail("reset", "the reset sequence did not complete");

  const bool quiet = args.quiet;
  auto banner = [&](int n, const char* name) {
    if (!quiet) std::printf("  pass %d/9 %-20s ", n, name);
    std::fflush(stdout);
  };
  auto verdict = [&](std::size_t before) {
    const bool ok = errors.count() == before;
    if (!quiet) std::printf("-> %s\n", ok ? "OK" : "FAILED");
    std::fflush(stdout);
    return ok;
  };

  // =========================================================================
  // Pass 1 — reset defaults
  // =========================================================================
  {
    banner(1, "reset_defaults");
    const std::size_t before = errors.count();

    expect_read(regmap::COUNTERS_TELEM_CTRL_ADDR,
                regmap::COUNTERS_TELEM_CTRL_RESET, "reset");
    expect_read(regmap::COUNTERS_TELEM_STATUS_ADDR, kStatusExpected, "reset");
    check((rd(regmap::COUNTERS_TELEM_STATUS_ADDR, "reset") &
           (1u << regmap::COUNTERS_TELEM_STATUS_SNAP_VALID_LSB)) == 0,
          "snapshot",
          "SNAP_VALID is set before any snapshot was taken, so a zero count "
          "cannot be distinguished from an unread one");

    // Every counter register reads zero, and refuses a write.
    for (std::size_t i = 0; i < regmap::kRegisterTableSize; ++i) {
      const regmap::RegInfo& r = regmap::kRegisters[i];
      if (std::strcmp(r.block, "counters") != 0) continue;
      if (r.writable_mask != 0) continue;
      expect_read(r.address, r.name == std::string("FIFO_HIGH_WATER")
                                 ? (static_cast<std::uint32_t>(
                                        sim_config::TELEM_FIFO_DEPTH)
                                    << regmap::COUNTERS_FIFO_HIGH_WATER_DEPTH_LSB)
                                 : (r.name == std::string("TELEM_STATUS")
                                        ? kStatusExpected
                                        : 0u),
                  std::string("reset.") + r.name);
      const RegResult w = driver.write(r.address, 0xFFFFFFFFu, 0xF);
      check(w.error, "reg_error_missing",
            std::string("a write to the read-only counter ") + r.name +
                " was accepted");
    }
    verdict(before);
  }

  // =========================================================================
  // Pass 2 — the four things a counter does, at a width readable by eye
  // =========================================================================
  {
    banner(2, "probe_directed");
    const std::size_t before = errors.count();

    stim.pc_enable = true;
    stim.pc_event = false;
    stim.pc_incr = 1;
    strobe(&stim.pc_clear);
    check(probe_events == 0 && top->pcw_count == 0, "counter_clear",
          "the modulo probe did not start from zero after a clear");

    // Count: events while enabled.
    stim.pc_event = true;
    step(20);
    stim.pc_event = false;
    step(2);
    const std::uint64_t counted = probe_events;
    check(counted > 0, "counter_count", "no events reached the probe at all");
    check(top->pcw_count == (counted & 0xFFu), "counter_count",
          "the modulo probe counted " + std::to_string(top->pcw_count) +
              " of " + std::to_string(counted) + " events");

    // Gate: events while disabled must not be counted.
    const std::uint64_t before_gate = probe_events;
    const std::uint32_t count_before_gate = top->pcw_count;
    stim.pc_enable = false;
    stim.pc_event = true;
    step(30);
    stim.pc_event = false;
    stim.pc_enable = true;
    step(2);
    check(probe_events == before_gate, "counter_gate",
          "the harness tally advanced while the counter was gated off");
    check(top->pcw_count == count_before_gate, "counter_gate",
          "the probe advanced while gated off: " +
              std::to_string(top->pcw_count) + " vs " +
              std::to_string(count_before_gate));

    // Snapshot: the shadow freezes while the counter keeps moving.
    stim.pc_event = true;
    strobe(&stim.pc_snapshot);
    const std::uint32_t frozen = top->pcw_snap;
    check(top->pcw_snap_valid != 0, "snapshot",
          "the probe's shadow-valid flag is clear after a snapshot");
    step(25);
    check(top->pcw_snap == frozen, "snapshot",
          "the probe's shadow moved without a strobe: " +
              std::to_string(top->pcw_snap) + " was " + std::to_string(frozen));
    check(top->pcw_count != frozen, "snapshot",
          "the probe's live count did not move while its shadow was held, so "
          "the coherence check proved nothing");
    stim.pc_event = false;
    step(2);

    // Clear takes the shadow and the valid flag with it.
    strobe(&stim.pc_clear);
    check(top->pcw_snap == 0 && top->pcw_snap_valid == 0, "counter_clear",
          "a clear left the probe's shadow or its valid flag behind");
    verdict(before);
  }

  // =========================================================================
  // Pass 3 — SPEC 13.4 wrap testing
  // =========================================================================
  {
    banner(3, "probe_wrap");
    const std::size_t before = errors.count();

    const std::uint64_t span = 1ull << sim_config::TELEM_PROBE_W;

    stim.pc_enable = true;
    stim.pc_incr = 1;
    strobe(&stim.pc_clear);

    // Three hundred single events into an eight-bit counter.
    stim.pc_event = true;
    step(300);
    stim.pc_event = false;
    step(2);

    check(probe_events >= span + 40, "counter_wrap",
          "only " + std::to_string(probe_events) +
              " events reached the probes; the wrap case needs more than " +
              std::to_string(span));
    check(top->pcw_count == (probe_events % span), "counter_wrap",
          "the modulo probe reads " + std::to_string(top->pcw_count) +
              " after " + std::to_string(probe_events) + " events; " +
              std::to_string(probe_events % span) + " was expected");
    check(top->pcw_wrapped != 0, "counter_wrap",
          "the modulo probe wrapped but did not report it");
    check(top->pcs_count == span - 1, "counter_saturate",
          "the saturating probe reads " + std::to_string(top->pcs_count) +
              " instead of holding at " + std::to_string(span - 1));
    check(top->pcs_wrapped != 0, "counter_saturate",
          "the saturating probe reached its limit but did not report it");

    // The weighted probe crossed the boundary by threes, so it stepped over the
    // maximum rather than landing on it — the case a naive equality test for
    // "counter == all ones" misses entirely.
    check(top->pci_count == (probe_weight % span), "counter_wrap",
          "the weighted probe reads " + std::to_string(top->pci_count) +
              " after accumulating " + std::to_string(probe_weight) +
              "; " + std::to_string(probe_weight % span) + " was expected");

    // A clear restores both, and the sticky flags go with the count.
    strobe(&stim.pc_clear);
    check(top->pcw_count == 0 && top->pcs_count == 0 && top->pcw_wrapped == 0 &&
              top->pcs_wrapped == 0,
          "counter_clear", "a clear did not reset the probes and their flags");

    // And the weighted case again with a step that steps over the top.
    stim.pc_incr = 3;
    stim.pc_event = true;
    step(200);
    stim.pc_event = false;
    stim.pc_incr = 1;
    step(2);
    check(top->pci_count == (probe_weight % span), "counter_wrap",
          "the weighted probe is " + std::to_string(top->pci_count) +
              " after " + std::to_string(probe_weight) + " accumulated units");
    check(top->pci_wrapped != 0, "counter_wrap",
          "the weighted probe stepped over its maximum without reporting a wrap");
    stim.pc_enable = false;
    verdict(before);
  }

  // =========================================================================
  // Pass 4 — traffic counted exactly
  // =========================================================================
  {
    banner(4, "telem_traffic");
    const std::size_t before = errors.count();
    if (!run_reset()) fail("reset", "the reset sequence did not complete");

    start_traffic("directed", BackpressureConfig::light(),
                  BackpressureConfig::heavy(), 30, 8);
    drain_traffic("telem_traffic");

    snapshot("telem_traffic");
    check(shadow_valid, "snapshot", "the harness never observed a snapshot strobe");
    check((rd(regmap::COUNTERS_TELEM_STATUS_ADDR, "telem_traffic") &
           (1u << regmap::COUNTERS_TELEM_STATUS_SNAP_VALID_LSB)) != 0,
          "snapshot", "SNAP_VALID is clear after a snapshot");
    check_shadow("telem_traffic");

    check(shadow.beat == stream_mon->beats_received(), "counter_value",
          "BEAT_COUNT tallied " + std::to_string(shadow.beat) +
              " but the monitor observed " +
              std::to_string(stream_mon->beats_received()) + " beats");
    check(shadow.frame == stream_mon->frames_received(), "counter_value",
          "FRAME_COUNT tallied " + std::to_string(shadow.frame) +
              " but the monitor observed " +
              std::to_string(stream_mon->frames_received()) + " frames");
    check(shadow.stall > 0, "coverage",
          "no stall cycle occurred, so the stall counter was never exercised");
    check(board.stats().clean(), "scoreboard",
          "the telemetry path lost, duplicated, reordered or corrupted traffic");
    verdict(before);
  }

  // =========================================================================
  // Pass 5 — a coherent sweep taken while the counters are running
  // =========================================================================
  {
    banner(5, "snapshot_coherence");
    const std::size_t before = errors.count();

    start_traffic("coherent", BackpressureConfig::light(),
                  BackpressureConfig::heavy(), 60, 8);

    // Let the traffic get going, then sweep the whole window while it runs.
    step(300);
    snapshot("coherence");
    const Tally frozen = shadow;
    const std::uint64_t live_at_snapshot = live.beat;

    const std::uint32_t id_before =
        rd(regmap::COUNTERS_SNAPSHOT_ID_ADDR, "coherence");
    check_shadow("coherence");
    const std::uint32_t id_after =
        rd(regmap::COUNTERS_SNAPSHOT_ID_ADDR, "coherence");

    check(id_before == id_after, "snapshot",
          "SNAPSHOT_ID changed during the sweep: " + std::to_string(id_before) +
              " then " + std::to_string(id_after) +
              " — the values read do not describe one instant");
    check(std::memcmp(&frozen, &shadow, sizeof(Tally)) == 0, "snapshot",
          "the harness's shadow changed during the sweep, so the DUT was asked "
          "for a moving target and the comparison would be meaningless");
    check(live.beat > live_at_snapshot, "coverage",
          "the beat counter did not advance during the register sweep, so this "
          "pass did not actually test coherence under traffic");

    drain_traffic("coherence");
    check(board.stats().clean(), "scoreboard",
          "reading telemetry while traffic ran disturbed the traffic");
    verdict(before);
  }

  // =========================================================================
  // Pass 6 — the measurement window
  // =========================================================================
  {
    banner(6, "enable_clear");
    const std::size_t before = errors.count();

    clear_all("enable_clear");
    snapshot("enable_clear");
    // No traffic flows between the clear and the snapshot, so the transfer
    // counters must be exactly zero. IDLE is deliberately not in this list: the
    // sink holds `ready` high between passes, so every cycle spent issuing the
    // two register writes is a legitimate starved cycle and counting it is
    // correct behaviour, not leakage. check_shadow() below compares it against
    // the harness tally, which counts those cycles too.
    check(shadow.beat == 0 && shadow.stall == 0 && shadow.frame == 0,
          "counter_clear", "a clear left transfer counters behind");
    check_shadow("enable_clear");

    // Close the window and run traffic through it: nothing may be counted.
    ctrl_levels &= ~(1u << regmap::COUNTERS_TELEM_CTRL_ENABLE_LSB);
    ctrl_write(0, "enable_clear.disable");
    check(top->obs_count_enable == 0, "reg_output",
          "ENABLE was cleared but the block still reports counting");

    const Tally before_gated = live;
    start_traffic("gated", BackpressureConfig::none(),
                  BackpressureConfig::light(), 12, 6);
    drain_traffic("enable_clear");
    check(std::memcmp(&before_gated, &live, sizeof(Tally)) == 0, "counter_gate",
          "the harness tally advanced while the measurement window was shut, "
          "which means the tally is gated differently from the DUT");
    snapshot("enable_clear.gated");
    check_shadow("enable_clear.gated");
    check(stream_mon->beats_received() > 0, "coverage",
          "no traffic flowed while the window was shut, so gating was not tested");

    // SNAPSHOT_ID must keep counting even with the window shut.
    check(shadow.snapshot_id > 0, "snapshot",
          "SNAPSHOT_ID stopped counting while ENABLE was low, so a coherent "
          "sweep is impossible on a stopped block");

    ctrl_levels |= (1u << regmap::COUNTERS_TELEM_CTRL_ENABLE_LSB);
    ctrl_write(0, "enable_clear.enable");
    check(top->obs_count_enable != 0, "reg_output",
          "ENABLE was set but the block still reports not counting");
    verdict(before);
  }

  // =========================================================================
  // Pass 7 — high-water mark against the FIFO's own tracker
  // =========================================================================
  {
    banner(7, "high_water");
    const std::size_t before = errors.count();

    clear_all("high_water");
    // A fast source into a bursty sink is what fills a FIFO.
    start_traffic("highwater", BackpressureConfig::none(),
                  BackpressureConfig::bursty(), 40, 8);
    drain_traffic("high_water");
    snapshot("high_water");

    const std::uint32_t hw = rd(regmap::COUNTERS_FIFO_HIGH_WATER_ADDR, "high_water");
    const std::uint32_t high =
        regmap::field_get(hw, regmap::COUNTERS_FIFO_HIGH_WATER_HIGH_LSB,
                          regmap::COUNTERS_FIFO_HIGH_WATER_HIGH_WIDTH);
    check(high == top->fifo_high_water, "high_water",
          "telemetry reports a high-water mark of " + std::to_string(high) +
              " and the FIFO's own tracker says " +
              std::to_string(top->fifo_high_water));
    check(high == shadow.high_water, "high_water",
          "telemetry reports " + std::to_string(high) +
              " and the harness saw a maximum fill of " +
              std::to_string(shadow.high_water));
    check(high > 1, "coverage",
          "the FIFO never filled beyond " + std::to_string(high) +
              ", so the high-water mark was not exercised");
    check(high <= sim_config::TELEM_FIFO_DEPTH, "high_water",
          "the reported high-water mark exceeds the FIFO's depth");
    check(top->fifo_overflow_sticky == 0 && top->fifo_underflow_sticky == 0,
          "fifo", "the measured FIFO reported an overflow or an underflow");
    verdict(before);
  }

  // =========================================================================
  // Pass 8 — the injected event counters
  // =========================================================================
  {
    banner(8, "injected_events");
    const std::size_t before = errors.count();

    clear_all("injected");
    const Tally base = live;

    // Separate one-cycle events on each input, plus one multi-cycle assertion
    // on the CDC input: an event input held high for N cycles is N events, and
    // an edge detector that quietly counted it once would be wrong.
    for (int i = 0; i < 3; ++i) strobe(&stim.inj_overflow);
    for (int i = 0; i < 5; ++i) strobe(&stim.inj_saturate);
    stim.inj_cdc_error = true;
    step(4);
    stim.inj_cdc_error = false;
    step(2);

    snapshot("injected");
    check(live.overflow > base.overflow && live.saturate > base.saturate &&
              live.cdc_error > base.cdc_error,
          "coverage", "no injected event was tallied at all");
    check_shadow("injected");

    // The error counters saturate rather than wrap: the map says so, and the
    // block must report the same thing.
    const std::uint32_t status = rd(regmap::COUNTERS_TELEM_STATUS_ADDR, "injected");
    check((status & (1u << regmap::COUNTERS_TELEM_STATUS_ERROR_SATURATE_LSB)) != 0,
          "counter_mode", "TELEM_STATUS does not report saturating error counters");
    check((status & (1u << regmap::COUNTERS_TELEM_STATUS_TRAFFIC_SATURATE_LSB)) == 0,
          "counter_mode", "TELEM_STATUS does not report modulo traffic counters");
    expect_read(regmap::COUNTERS_WRAP_STATUS_ADDR, 0u, "injected.wrap_status");
    verdict(before);
  }

  // =========================================================================
  // Pass 9 — randomized soak
  // =========================================================================
  {
    banner(9, "random_soak");
    const std::size_t before = errors.count();
    if (!run_reset()) fail("reset", "the reset sequence did not complete");
    ctrl_levels = (1u << regmap::COUNTERS_TELEM_CTRL_ENABLE_LSB) |
                  (1u << regmap::COUNTERS_TELEM_CTRL_SEQ_ENABLE_LSB);

    std::mt19937_64 rng = seeds.engine("telemetry.soak");
    const std::uint64_t frames = args.frames != 0 ? args.frames : 40;

    start_traffic("soak", BackpressureConfig::heavy(),
                  BackpressureConfig::bursty(),
                  static_cast<std::uint32_t>(frames), 8);

    // Register traffic interleaved with the stream, including strobes, so the
    // counters are read, snapshotted and occasionally cleared while running.
    for (int i = 0; i < 40 && errors.count() == before; ++i) {
      step(static_cast<std::uint64_t>(harness::uniform_u64(rng, 1, 40)));
      switch (harness::uniform_u64(rng, 0, 5)) {
        case 0:
          snapshot("soak");
          break;
        case 1:
          clear_all("soak");
          break;
        case 2:
          strobe(&stim.inj_overflow);
          break;
        case 3:
          strobe(&stim.inj_saturate);
          break;
        default: {
          const std::size_t idx = static_cast<std::size_t>(
              harness::uniform_u64(rng, 0, regmap::kRegisterTableSize - 1));
          const regmap::RegInfo& r = regmap::kRegisters[idx];
          if (std::strcmp(r.block, "counters") == 0) {
            driver.read(r.address);
          }
          break;
        }
      }
    }

    drain_traffic("soak");
    snapshot("soak.final");
    check_shadow("soak.final");
    check(board.stats().clean(), "scoreboard",
          "the soak lost, duplicated, reordered or corrupted traffic");
    verdict(before);
  }

  // ---- run-wide invariants ----------------------------------------------
  check(driver.timeouts() == 0, "reg_hang",
        std::to_string(driver.timeouts()) + " register accesses never completed");
  check(driver.max_response_cycles() == kExpectedCycles, "reg_latency",
        "the slowest counter access took " +
            std::to_string(driver.max_response_cycles()) + " cycles, expected " +
            std::to_string(kExpectedCycles));
  check(top->sq_sticky == 0, "sequence",
        "the sequence checker reported a fault on the real datapath, where the "
        "traffic is continuous by construction");

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
  summary.beats_driven = live.beat;
  summary.beats_observed = live.beat;
  summary.frames_driven = live.frame_start;
  summary.frames_observed = live.frame;
  summary.scoreboard = board.stats();
  summary.trace_path = trace_path;
  summary.absorb(errors);
  summary.wall_time_s =
      std::chrono::duration<double>(wall_end - wall_start).count();

  const std::string written = summary.write(args.results_dir);

  unsigned counter_regs = 0;
  for (std::size_t i = 0; i < regmap::kBlockTableSize; ++i) {
    if (std::strcmp(regmap::kBlocks[i].name, "counters") == 0) {
      counter_regs = regmap::kBlocks[i].reg_count;
    }
  }

  std::printf("--- summary ---\n");
  std::printf("  counters block : %u registers at 0x%04X\n", counter_regs,
              regmap::COUNTERS_BASE);
  std::printf("  beats/stalls   : %llu / %llu (idle %llu)\n",
              static_cast<unsigned long long>(live.beat),
              static_cast<unsigned long long>(live.stall),
              static_cast<unsigned long long>(live.idle));
  std::printf("  frames         : %llu started, %llu completed\n",
              static_cast<unsigned long long>(live.frame_start),
              static_cast<unsigned long long>(live.frame));
  std::printf("  snapshots      : %llu\n",
              static_cast<unsigned long long>(live.snapshot_id));
  std::printf("  transactions   : %llu (%llu error responses)\n",
              static_cast<unsigned long long>(driver.transactions()),
              static_cast<unsigned long long>(driver.error_responses()));
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
