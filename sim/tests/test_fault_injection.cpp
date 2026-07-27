// -----------------------------------------------------------------------------
// test_fault_injection.cpp -- per-block fault dispatch (issue #19).
//
// Drives phase4_top's DBG_FAULT_TARGET (the per-block mask) and an external
// fault-type pulse (the input from reg_block_fault at 0x3000). Verifies:
//   1. Safe-disable-by-default: TARGET=0 + pulse -> no fault delivered.
//   2. Bit-per-block: TARGET=0x01 (PFB) + pulse -> only PFB pulse, no others.
//   3. DBG_FAULT_REPORT tracks the delivered pulses in sticky W1C bits.
//   4. Simultaneous targets deliver simultaneously.
// -----------------------------------------------------------------------------

#include <chrono>
#include <cstdio>
#include <memory>
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
constexpr const char* kTestName = "test_fault_injection";
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
  (void)tel_clk;
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
      args.timeout_cycles != 0 ? args.timeout_cycles : 200000;
  TimeoutGuard timeout(sched, errors, hard_limit, 2000,
                       [&]() { return driver.transactions(); });
  sched.on_posedge_drive(cfg_clk, [&timeout]() { timeout.on_cycle(); });
  const SimTime time_limit = static_cast<SimTime>(hard_limit + 100000) * cfg_half * 2;

  // Idle all inputs.
  top->test_fault_type_pulse = 0;
  top->src_valid = 0; top->src_sof = 0; top->src_eof = 0;
  for (unsigned i = 0; i < 16; ++i) top->src_data[i] = 0;
  for (unsigned i = 0; i < 4; ++i) top->src_seq[i] = 0;
  top->src_id = 0;
  top->any_fault = 0;
  top->ev_detection = 0; top->ev_packet_delivery = 0; top->ev_packet_drop = 0;
  top->ev_fault_inject = 0; top->ev_cdc_error = 0; top->ev_overflow = 0;
  top->ev_saturate = 0; top->ev_seq_error = 0; top->ev_mem_error = 0;
  top->ev_cfar_fault = 0;
  top->mem_req_valid = 0; top->mem_rsp_ready = 1;
  for (unsigned i = 0; i < 20; ++i) top->mem_req[i] = 0;

  // Watch obs_block_fault_pulse cycle-by-cycle in cfg_clk.
  std::uint8_t seen_block_pulse_or = 0;
  std::uint64_t block_pulse_cycles = 0;
  sched.on_posedge_sample(cfg_clk, [&]() {
    if (top->cfg_rst_n == 0) return;
    if (top->obs_block_fault_pulse != 0) {
      seen_block_pulse_or |= top->obs_block_fault_pulse;
      ++block_pulse_cycles;
    }
  });

  auto run_reset = [&]() -> bool {
    driver.reset();
    sched.clear_stop();
    reset.assert_all();
    if (reset.release_all(time_limit) != StopReason::kRunning) return false;
    timeout.reset();
    seen_block_pulse_or = 0;
    block_pulse_cycles = 0;
    return true;
  };
  auto advance_cfg = [&](std::uint64_t n) { sched.run_cycles(cfg_clk, n, time_limit); };
  auto advance_core = [&](std::uint64_t n) { sched.run_cycles(core_clk, n, time_limit); };

  if (!run_reset()) { errors.error("reset", "reset failed"); return 1; }

  std::printf("=== simulation run ===\n");
  std::printf("  test  : %s\n", kTestName);
  std::printf("  seed  : %llu\n", (unsigned long long)args.seed);

  auto check = [&](bool ok, const std::string& cat, const std::string& msg) {
    if (!ok) errors.error(cat, msg);
    return ok;
  };

  // ---- Pass 1: safe-disable-by-default ----
  {
    std::printf("  pass 1/4 safe_disable      ");
    const std::size_t before = errors.count();
    // TARGET is 0 at reset. Drive fault_type_pulse.
    top->test_fault_type_pulse = 0x00000003u;  // STREAM_CORRUPT | SEQ_ERROR
    advance_cfg(2);
    advance_core(4);
    top->test_fault_type_pulse = 0;
    advance_cfg(10);
    check(seen_block_pulse_or == 0, "safe_disable",
          "TARGET=0 delivered a fault to " +
          std::to_string(seen_block_pulse_or));
    check(block_pulse_cycles == 0, "safe_disable_cycles",
          std::to_string(block_pulse_cycles) + " pulse cycles with TARGET=0");
    std::printf("-> %s\n", errors.count() == before ? "OK" : "FAILED");
  }

  // ---- Pass 2: single-block dispatch ----
  {
    std::printf("  pass 2/4 single_block     ");
    const std::size_t before = errors.count();
    if (!run_reset()) errors.error("reset", "reset failed pass 2");
    // Set TARGET.PFB=1.
    driver.write_field(regmap::DEBUG_DBG_FAULT_TARGET_ADDR,
                       regmap::DEBUG_DBG_FAULT_TARGET_PFB_LSB, 1, 1);
    top->test_fault_type_pulse = 0x00000001u;   // any one type is enough
    advance_cfg(2);
    top->test_fault_type_pulse = 0;
    advance_cfg(20);
    check((seen_block_pulse_or & 0x01) != 0, "pfb_pulse",
          "TARGET.PFB=1: no pulse delivered");
    check((seen_block_pulse_or & 0xFE) == 0, "no_other_pulse",
          "TARGET.PFB=1 leaked to other blocks: 0x" +
          std::to_string(seen_block_pulse_or));
    // Verify sticky report
    const std::uint32_t report = driver.read(regmap::DEBUG_DBG_FAULT_REPORT_ADDR).data;
    const std::uint32_t pfb_bit = regmap::field_get(
        report, regmap::DEBUG_DBG_FAULT_REPORT_PFB_LSB, 1);
    check(pfb_bit == 1, "report_pfb",
          "DBG_FAULT_REPORT.PFB not set after pulse");
    std::printf("-> %s\n", errors.count() == before ? "OK" : "FAILED");
  }

  // ---- Pass 3: multi-block dispatch ----
  {
    std::printf("  pass 3/4 multi_block      ");
    const std::size_t before = errors.count();
    if (!run_reset()) errors.error("reset", "reset failed pass 3");
    // Set TARGET to CFAR|PACKET|MEMORY (bits 4,5,6).
    driver.write(regmap::DEBUG_DBG_FAULT_TARGET_ADDR, 0x70);
    top->test_fault_type_pulse = 0x00000004u;
    advance_cfg(2);
    top->test_fault_type_pulse = 0;
    advance_cfg(20);
    check((seen_block_pulse_or & 0x70) == 0x70, "multi_block",
          "TARGET=0x70: expected pulse on bits 4,5,6, got 0x" +
          std::to_string(seen_block_pulse_or));
    check((seen_block_pulse_or & 0x8F) == 0, "no_other",
          "TARGET=0x70 leaked: 0x" + std::to_string(seen_block_pulse_or));
    const std::uint32_t report = driver.read(regmap::DEBUG_DBG_FAULT_REPORT_ADDR).data;
    check((report & 0x70) == 0x70, "report_multi",
          "DBG_FAULT_REPORT missing bits: 0x" + std::to_string(report));
    std::printf("-> %s\n", errors.count() == before ? "OK" : "FAILED");
  }

  // ---- Pass 4: W1C clear of DBG_FAULT_REPORT ----
  {
    std::printf("  pass 4/4 report_w1c       ");
    const std::size_t before = errors.count();
    // Continuing from pass 3, report has bits 4,5,6 set. Clear bit 4.
    driver.write(regmap::DEBUG_DBG_FAULT_REPORT_ADDR, 0x10);
    advance_cfg(4);
    const std::uint32_t report = driver.read(regmap::DEBUG_DBG_FAULT_REPORT_ADDR).data;
    check((report & 0x10) == 0, "w1c_bit4",
          "W1C bit 4 not cleared: 0x" + std::to_string(report));
    check((report & 0x60) == 0x60, "w1c_others",
          "W1C bit 4 clobbered bits 5,6: 0x" + std::to_string(report));
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
  summary.core_cycles = sched.cycles(core_clk);
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
