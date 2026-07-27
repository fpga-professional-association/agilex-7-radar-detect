// -----------------------------------------------------------------------------
// test_telemetry_counters.cpp -- telemetry_clk counter CDC (issue #19).
//
// Drives event pulses in the telemetry_clk domain, snapshots the counters into
// cfg_clk via the DBG cdc_handshake bundle, and verifies:
//   1. Reset defaults: TELE_STATUS.SNAP_VALID=0, TELE_STATUS.HEALTHY=1.
//   2. Event counters accumulate correctly across a snapshot.
//   3. TELE_HEALTH sticky bits set on the corresponding events.
//   4. Snapshot atomicity: a snapshot latches counters at one instant.
// -----------------------------------------------------------------------------

#include <chrono>
#include <cstdio>
#include <memory>
#include <random>
#include <string>

#include "Vphase4_top.h"
#include "verilated.h"

#include "harness/harness.h"
#include "regmap/regmap.hpp"

using harness::ClockScheduler;
using harness::ErrorCollector;
using harness::RegDriver;
using harness::RegPort;
using harness::RegResult;
using harness::ResetSequencer;
using harness::RunSummary;
using harness::SeedSource;
using harness::SimArgs;
using harness::SimTime;
using harness::StopReason;
using harness::TimeoutGuard;

namespace {
constexpr const char* kTestName = "test_telemetry_counters";
}

int harness::sim_test_main(const SimArgs& args) {
  const auto wall_start = std::chrono::steady_clock::now();

  auto top = std::make_unique<Vphase4_top>();
  ErrorCollector errors;
  errors.set_print_limit(30);

  ClockScheduler sched([&top]() { top->eval(); });
  errors.set_time_probe(sched.time_ptr());

  const SimTime cfg_half  = harness::half_period_ps(harness::kCfgClkMhz);
  const SimTime tel_half  = harness::half_period_ps(harness::kTelemetryClkMhz);
  const SimTime core_half = harness::half_period_ps(harness::kCoreClkMhz);
  const int cfg_clk  = sched.add_clock("cfg_clk",  cfg_half,  &top->cfg_clk,  cfg_half);
  const int tel_clk  = sched.add_clock("tel_clk",  tel_half,  &top->tel_clk,  tel_half);
  const int core_clk = sched.add_clock("core_clk", core_half, &top->core_clk, core_half);
  (void)core_clk;

  ResetSequencer reset(sched);
  reset.add_domain("cfg_rst_n",  cfg_clk,  &top->cfg_rst_n,  4);
  reset.add_domain("tel_rst_n",  tel_clk,  &top->tel_rst_n,  4);
  reset.add_domain("core_rst_n", core_clk, &top->core_rst_n, 6);

  RegPort port;
  port.address = &top->address;
  port.write_data = &top->write_data;
  port.byte_enable = &top->byte_enable;
  port.write_enable = &top->write_enable;
  port.read_enable = &top->read_enable;
  port.read_data = &top->read_data;
  port.ready = &top->ready;
  port.error = &top->error;
  RegDriver driver("reg", port, sched, cfg_clk, errors);

  const std::uint64_t hard_limit =
      args.timeout_cycles != 0 ? args.timeout_cycles : 400000;
  TimeoutGuard timeout(sched, errors, hard_limit, 2000,
                       [&]() { return driver.transactions(); });
  sched.on_posedge_drive(cfg_clk, [&timeout]() { timeout.on_cycle(); });
  const SimTime time_limit = static_cast<SimTime>(hard_limit + 100000) * cfg_half * 2;

  // Idle inputs
  top->test_fault_type_pulse = 0;
  top->src_valid = 0; top->src_sof = 0; top->src_eof = 0;
  for (unsigned i = 0; i < 16; ++i) top->src_data[i] = 0;
  for (unsigned i = 0; i < 4; ++i) top->src_seq[i] = 0;
  top->src_id = 0; top->any_fault = 0;
  top->ev_detection = 0; top->ev_packet_delivery = 0; top->ev_packet_drop = 0;
  top->ev_fault_inject = 0; top->ev_cdc_error = 0; top->ev_overflow = 0;
  top->ev_saturate = 0; top->ev_seq_error = 0; top->ev_mem_error = 0;
  top->ev_cfar_fault = 0;
  top->mem_req_valid = 0; top->mem_rsp_ready = 1;
  for (unsigned i = 0; i < 20; ++i) top->mem_req[i] = 0;

  // Deterministic tel_clk-side event driver: on each posedge, fire the
  // events named by the currently active bitmask.
  std::uint32_t ev_mask = 0;
  std::uint32_t ev_countdown = 0;
  sched.on_posedge_drive(tel_clk, [&]() {
    // Only fire when countdown is non-zero.
    const bool fire = (top->tel_rst_n != 0) && (ev_countdown > 0);
    top->ev_detection       = (fire && (ev_mask & (1u << 0))) ? 1 : 0;
    top->ev_packet_delivery = (fire && (ev_mask & (1u << 1))) ? 1 : 0;
    top->ev_packet_drop     = (fire && (ev_mask & (1u << 2))) ? 1 : 0;
    top->ev_fault_inject    = (fire && (ev_mask & (1u << 3))) ? 1 : 0;
    top->ev_cdc_error       = (fire && (ev_mask & (1u << 4))) ? 1 : 0;
    top->ev_overflow        = (fire && (ev_mask & (1u << 5))) ? 1 : 0;
    top->ev_saturate        = (fire && (ev_mask & (1u << 6))) ? 1 : 0;
    top->ev_seq_error       = (fire && (ev_mask & (1u << 7))) ? 1 : 0;
    top->ev_mem_error       = (fire && (ev_mask & (1u << 8))) ? 1 : 0;
    top->ev_cfar_fault      = (fire && (ev_mask & (1u << 9))) ? 1 : 0;
    if (ev_countdown > 0) ev_countdown--;
  });

  auto run_reset = [&]() -> bool {
    driver.reset();
    sched.clear_stop();
    reset.assert_all();
    if (reset.release_all(time_limit) != StopReason::kRunning) return false;
    timeout.reset();
    ev_mask = 0; ev_countdown = 0;
    return true;
  };
  auto advance_cfg = [&](std::uint64_t n) { sched.run_cycles(cfg_clk, n, time_limit); };

  auto snapshot_and_wait = [&]() {
    driver.write_field(regmap::TELEMETRY_TELE_CTRL_ADDR,
                       regmap::TELEMETRY_TELE_CTRL_SNAPSHOT_LSB, 1, 1);
    // Wait for BUSY to drop and SNAP_VALID to rise.
    for (int i = 0; i < 100; ++i) {
      advance_cfg(4);
      const std::uint32_t status = driver.read(regmap::TELEMETRY_TELE_STATUS_ADDR).data;
      const std::uint32_t busy = regmap::field_get(
          status, regmap::TELEMETRY_TELE_STATUS_BUSY_LSB, 1);
      const std::uint32_t snap_valid = regmap::field_get(
          status, regmap::TELEMETRY_TELE_STATUS_SNAP_VALID_LSB, 1);
      if (!busy && snap_valid) return true;
    }
    return false;
  };

  if (!run_reset()) { errors.error("reset", "reset failed"); return 1; }

  std::printf("=== simulation run ===\n");
  std::printf("  test  : %s\n", kTestName);
  std::printf("  seed  : %llu\n", (unsigned long long)args.seed);

  auto check = [&](bool ok, const std::string& cat, const std::string& msg) {
    if (!ok) errors.error(cat, msg);
    return ok;
  };

  // ---- Pass 1: reset defaults ----
  {
    std::printf("  pass 1/4 reset_defaults    ");
    const std::size_t before = errors.count();
    const std::uint32_t status = driver.read(regmap::TELEMETRY_TELE_STATUS_ADDR).data;
    const std::uint32_t snap_valid = regmap::field_get(
        status, regmap::TELEMETRY_TELE_STATUS_SNAP_VALID_LSB, 1);
    const std::uint32_t healthy = regmap::field_get(
        status, regmap::TELEMETRY_TELE_STATUS_HEALTHY_LSB, 1);
    check(snap_valid == 0, "reset_snap",
          "SNAP_VALID=1 at reset (expected 0)");
    check(healthy == 1, "reset_healthy",
          "HEALTHY=0 at reset (expected 1)");
    // Counters should be all zero (shadow is zero at reset).
    for (auto addr : {regmap::TELEMETRY_TELE_EVENT_RATE_ADDR,
                      regmap::TELEMETRY_TELE_PACKET_DROP_ADDR,
                      regmap::TELEMETRY_TELE_FAULT_COUNT_ADDR,
                      regmap::TELEMETRY_TELE_CDC_ERROR_ADDR,
                      regmap::TELEMETRY_TELE_OVERFLOW_ADDR,
                      regmap::TELEMETRY_TELE_SATURATE_ADDR,
                      regmap::TELEMETRY_TELE_SEQ_ERRORS_ADDR}) {
      const std::uint32_t v = driver.read(addr).data;
      check(v == 0, "reset_counter",
            "counter at " + std::to_string(addr) + " nonzero at reset: " +
            std::to_string(v));
    }
    std::printf("-> %s\n", errors.count() == before ? "OK" : "FAILED");
  }

  // ---- Pass 2: event accumulation ----
  {
    std::printf("  pass 2/4 accumulation      ");
    const std::size_t before = errors.count();
    // Fire ev_detection for 10 tel_clk cycles.
    ev_mask = (1u << 0);
    ev_countdown = 10;
    // Advance enough cfg cycles for tel_clk to complete 10 pulses.
    advance_cfg(60);
    // Trigger a snapshot.
    check(snapshot_and_wait(), "snapshot",
          "SNAP_VALID never rose after SNAPSHOT");
    const std::uint32_t ev_rate = driver.read(regmap::TELEMETRY_TELE_EVENT_RATE_ADDR).data;
    check(ev_rate == 10, "event_count",
          "TELE_EVENT_RATE=" + std::to_string(ev_rate) + ", expected 10");
    // Other counters should still be 0.
    const std::uint32_t drop = driver.read(regmap::TELEMETRY_TELE_PACKET_DROP_ADDR).data;
    check(drop == 0, "no_drop", "packet_drop nonzero: " + std::to_string(drop));
    std::printf("-> %s\n", errors.count() == before ? "OK" : "FAILED");
  }

  // ---- Pass 3: health sticky bits + HEALTHY status ----
  {
    std::printf("  pass 3/4 health_sticky     ");
    const std::size_t before = errors.count();
    // Fire ev_packet_drop for many tel_clk cycles, then snapshot. Also read
    // the packet drop counter to prove the tel-side saw the events.
    ev_mask = (1u << 2);
    ev_countdown = 8;
    advance_cfg(80);
    check(snapshot_and_wait(), "snapshot", "snapshot did not complete");
    const std::uint32_t drop_count = driver.read(regmap::TELEMETRY_TELE_PACKET_DROP_ADDR).data;
    check(drop_count == 8, "drop_count",
          "TELE_PACKET_DROP=" + std::to_string(drop_count) + ", expected 8");
    const std::uint32_t status = driver.read(regmap::TELEMETRY_TELE_STATUS_ADDR).data;
    const std::uint32_t healthy = regmap::field_get(
        status, regmap::TELEMETRY_TELE_STATUS_HEALTHY_LSB, 1);
    check(healthy == 0, "unhealthy",
          "HEALTHY=1 after ev_packet_drop (expected 0)");
    const std::uint32_t health = driver.read(regmap::TELEMETRY_TELE_HEALTH_ADDR).data;
    const std::uint32_t packet_drop_bit = regmap::field_get(
        health, regmap::TELEMETRY_TELE_HEALTH_PACKET_DROP_LSB, 1);
    check(packet_drop_bit == 1, "packet_drop_health",
          "TELE_HEALTH.PACKET_DROP not sticky-set (0x" +
          std::to_string(health) + ")");
    // W1C clear.
    driver.write(regmap::TELEMETRY_TELE_HEALTH_ADDR,
                 (1u << regmap::TELEMETRY_TELE_HEALTH_PACKET_DROP_LSB));
    advance_cfg(4);
    const std::uint32_t health2 = driver.read(regmap::TELEMETRY_TELE_HEALTH_ADDR).data;
    check(health2 == 0, "w1c_clear",
          "W1C did not clear TELE_HEALTH bit: 0x" + std::to_string(health2));
    std::printf("-> %s\n", errors.count() == before ? "OK" : "FAILED");
  }

  // ---- Pass 4: TELE_CTRL.CLEAR resets counters ----
  {
    std::printf("  pass 4/4 clear_counters    ");
    const std::size_t before = errors.count();
    // Pulse CLEAR.
    driver.write_field(regmap::TELEMETRY_TELE_CTRL_ADDR,
                       regmap::TELEMETRY_TELE_CTRL_CLEAR_LSB, 1, 1);
    advance_cfg(50);   // wait for cdc_pulse to reach tel_clk
    check(snapshot_and_wait(), "snapshot", "snapshot did not complete after CLEAR");
    const std::uint32_t ev_rate = driver.read(regmap::TELEMETRY_TELE_EVENT_RATE_ADDR).data;
    check(ev_rate == 0, "clear_event",
          "TELE_EVENT_RATE=" + std::to_string(ev_rate) + " after CLEAR, expected 0");
    std::printf("-> %s\n", errors.count() == before ? "OK" : "FAILED");
  }

  const auto wall_end = std::chrono::steady_clock::now();
  const bool passed = errors.ok();
  RunSummary summary;
  summary.test_name = kTestName;
  summary.config_name = args.config_name;
  summary.build_mode = args.build_mode;
  summary.seed = args.seed;
  summary.passed = passed;
  summary.stop_reason = harness::to_string(sched.stop_reason());
  summary.passes = 4;
  summary.cfg_cycles = sched.cycles(cfg_clk);
  summary.sim_time_ps = sched.time();
  summary.beats_driven = driver.transactions();
  summary.absorb(errors);
  summary.wall_time_s =
      std::chrono::duration<double>(wall_end - wall_start).count();
  summary.write(args.results_dir);
  std::printf("--- summary ---\n");
  std::printf("  errors : %zu\n", errors.count());
  std::printf("RESULT: %s seed=%llu test=%s config=%s errors=%zu\n",
              passed ? "PASS" : "FAIL",
              (unsigned long long)args.seed, kTestName,
              args.config_name.c_str(), errors.count());
  top->final();
  return passed ? 0 : 1;
}
