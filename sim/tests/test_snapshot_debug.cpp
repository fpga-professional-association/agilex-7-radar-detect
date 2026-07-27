// -----------------------------------------------------------------------------
// test_snapshot_debug.cpp -- arm/trigger/capture-done sequencing (issue #19).
//
// Drives phase4_top's DBG_SNAP_* registers through the register plane, streams
// a known source into snapshot_debug's ring, and verifies:
//   1. Unarmed trigger does nothing (no CAPTURING, no CAPTURE_DONE).
//   2. Armed + triggered captures exactly DEPTH beats and stops.
//   3. Continuous mode (ONE_SHOT=0) never sets CAPTURE_DONE.
//   4. Read-back through DBG_SNAP_DATA / DATA_HI / DATA_META returns the beats
//      in the recorded order.
// -----------------------------------------------------------------------------

#include <chrono>
#include <cstdio>
#include <cstring>
#include <memory>
#include <vector>

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

constexpr const char* kTestName = "test_snapshot_debug";

}  // namespace

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

  ResetSequencer reset(sched);
  reset.add_domain("cfg_rst_n",  cfg_clk,  &top->cfg_rst_n,  4);
  reset.add_domain("tel_rst_n",  tel_clk,  &top->tel_rst_n,  4);
  reset.add_domain("core_rst_n", core_clk, &top->core_rst_n, 6);

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
  RegDriver driver("reg", port, sched, cfg_clk, errors);

  const std::uint64_t hard_limit =
      args.timeout_cycles != 0 ? args.timeout_cycles : 200000;
  TimeoutGuard timeout(sched, errors, hard_limit, 2000,
                       [&]() { return driver.transactions(); });
  sched.on_posedge_drive(cfg_clk, [&timeout]() { timeout.on_cycle(); });

  const SimTime time_limit = static_cast<SimTime>(hard_limit + 100000) * cfg_half * 2;

  // ---- source stream setup: drive source 0 into snapshot_debug via core_clk. ----
  // We produce a stream of 64-bit patterns on core_clk, one beat per cycle,
  // holding valid low unless we're actively feeding the ring.
  std::uint16_t seq_ctr = 0;
  bool feed_active = false;
  std::vector<std::uint32_t> recorded_lo;
  std::vector<std::uint32_t> recorded_meta;

  sched.on_posedge_drive(core_clk, [&]() {
    if (feed_active) {
      // Idle all sources, then drive source 0 with a rolling pattern.
      // src_valid is a WData<8>, one bit per source.
      top->src_valid = 0x01;
      top->src_sof   = (seq_ctr == 0) ? 0x01 : 0x00;
      top->src_eof   = 0x00;
      // Data pattern: pattern[0] = seq_ctr | (seq_ctr<<16), pattern[1] = 0xDEADBEEF
      // src_data is 8*64 = 512 bits packed; source 0 lives at bits [63:0].
      // src_data is expressed as VlWide<16> (16 x 32-bit words).
      top->src_data[0] = 0xDEAD0000u | seq_ctr;
      top->src_data[1] = 0xBEEF0000u | seq_ctr;
      for (unsigned i = 2; i < 16; ++i) top->src_data[i] = 0;
      // meta: SEQ[15:0]=seq_ctr, ID[19:16]=0, SOF[24], EOF[25]=0, VALID[26]=1
      // src_seq is VlWide<4> (packed 8*16 bits = 128 bits).
      top->src_seq[0] = seq_ctr;
      for (unsigned i = 1; i < 4; ++i) top->src_seq[i] = 0;
      top->src_id  = 0;
      seq_ctr++;
    } else {
      top->src_valid = 0;
      top->src_sof   = 0;
      top->src_eof   = 0;
      top->src_seq[0] = 0;
      top->src_id  = 0;
      for (unsigned i = 0; i < 16; ++i) top->src_data[i] = 0;
    }
  });

  // Idle other inputs
  top->any_fault = 0;
  top->ev_detection = 0;
  top->ev_packet_delivery = 0;
  top->ev_packet_drop = 0;
  top->ev_fault_inject = 0;
  top->ev_cdc_error = 0;
  top->ev_overflow = 0;
  top->ev_saturate = 0;
  top->ev_seq_error = 0;
  top->ev_mem_error = 0;
  top->ev_cfar_fault = 0;
  top->mem_req_valid = 0;
  top->mem_rsp_ready = 1;
  for (unsigned i = 0; i < 20; ++i) top->mem_req[i] = 0;

  auto run_reset = [&]() -> bool {
    driver.reset();
    sched.clear_stop();
    reset.assert_all();
    if (reset.release_all(time_limit) != StopReason::kRunning) return false;
    timeout.reset();
    seq_ctr = 0;
    feed_active = false;
    return true;
  };

  auto advance_core_cycles = [&](std::uint64_t n) {
    sched.run_cycles(core_clk, n, time_limit);
  };
  auto advance_cfg_cycles = [&](std::uint64_t n) {
    sched.run_cycles(cfg_clk, n, time_limit);
  };

  if (!run_reset()) {
    errors.error("reset", "reset failed");
    return 1;
  }

  std::printf("=== simulation run ===\n");
  std::printf("  build_mode : %s\n", args.build_mode.c_str());
  std::printf("  config     : %s\n", args.config_name.c_str());
  std::printf("  seed       : %llu\n", (unsigned long long)args.seed);

  auto check = [&](bool ok, const std::string& cat, const std::string& msg) {
    if (!ok) errors.error(cat, msg);
    return ok;
  };

  // ---- Pass 1: unarmed trigger does nothing ----
  {
    std::printf("  pass 1/4 unarmed_trigger  ");
    const std::size_t before = errors.count();
    // Configure source and depth first.
    driver.write_field(regmap::DEBUG_DBG_SNAP_SOURCE_ADDR,
                       regmap::DEBUG_DBG_SNAP_SOURCE_SOURCE_SEL_LSB,
                       regmap::DEBUG_DBG_SNAP_SOURCE_SOURCE_SEL_WIDTH, 0);
    driver.write_field(regmap::DEBUG_DBG_SNAP_DEPTH_ADDR,
                       regmap::DEBUG_DBG_SNAP_DEPTH_DEPTH_LSB,
                       regmap::DEBUG_DBG_SNAP_DEPTH_DEPTH_WIDTH, 8);
    // Trigger with ARM=0.
    driver.write_field(regmap::DEBUG_DBG_SNAP_CTRL_ADDR,
                       regmap::DEBUG_DBG_SNAP_CTRL_TRIGGER_LSB, 1, 1);
    // Feed source but nothing should be captured.
    feed_active = true;
    advance_core_cycles(20);
    feed_active = false;
    advance_cfg_cycles(10);
    const std::uint32_t status = driver.read(regmap::DEBUG_DBG_SNAP_STATUS_ADDR).data;
    const std::uint32_t capturing = regmap::field_get(
        status, regmap::DEBUG_DBG_SNAP_STATUS_CAPTURING_LSB,
        regmap::DEBUG_DBG_SNAP_STATUS_CAPTURING_WIDTH);
    const std::uint32_t done = regmap::field_get(
        status, regmap::DEBUG_DBG_SNAP_STATUS_CAPTURE_DONE_LSB,
        regmap::DEBUG_DBG_SNAP_STATUS_CAPTURE_DONE_WIDTH);
    check(capturing == 0, "unarmed_capturing",
          "unarmed trigger: CAPTURING=" + std::to_string(capturing));
    check(done == 0, "unarmed_done",
          "unarmed trigger: CAPTURE_DONE=" + std::to_string(done));
    std::printf("-> %s\n", errors.count() == before ? "OK" : "FAILED");
  }

  // ---- Pass 2: armed + triggered capture stops at DEPTH ----
  {
    std::printf("  pass 2/4 armed_trigger    ");
    const std::size_t before = errors.count();
    seq_ctr = 0;   // reset the source seq so captured seq is deterministic
    // Reset the DUT to guarantee no residual state from pass 1.
    if (!run_reset()) errors.error("reset", "reset failed pass 2");
    driver.write_field(regmap::DEBUG_DBG_SNAP_SOURCE_ADDR,
                       regmap::DEBUG_DBG_SNAP_SOURCE_SOURCE_SEL_LSB,
                       regmap::DEBUG_DBG_SNAP_SOURCE_SOURCE_SEL_WIDTH, 0);
    driver.write_field(regmap::DEBUG_DBG_SNAP_DEPTH_ADDR,
                       regmap::DEBUG_DBG_SNAP_DEPTH_DEPTH_LSB,
                       regmap::DEBUG_DBG_SNAP_DEPTH_DEPTH_WIDTH, 8);
    // Turn off AUTO_INC so we address the ring explicitly (avoids a CDC race
    // between cfg-domain read pulses and core-domain rd_ptr updates).
    driver.write_field(regmap::DEBUG_DBG_SNAP_POINTER_ADDR,
                       regmap::DEBUG_DBG_SNAP_POINTER_AUTO_INC_LSB, 1, 0);
    // Arm.
    driver.write_field(regmap::DEBUG_DBG_SNAP_CTRL_ADDR,
                       regmap::DEBUG_DBG_SNAP_CTRL_ARM_LSB, 1, 1);
    driver.write_field(regmap::DEBUG_DBG_SNAP_CTRL_ADDR,
                       regmap::DEBUG_DBG_SNAP_CTRL_ONE_SHOT_LSB, 1, 1);
    // Trigger.
    driver.write_field(regmap::DEBUG_DBG_SNAP_CTRL_ADDR,
                       regmap::DEBUG_DBG_SNAP_CTRL_TRIGGER_LSB, 1, 1);
    // Feed 40 core beats -- ring should fill to DEPTH=8 and stop.
    feed_active = true;
    advance_core_cycles(40);
    feed_active = false;
    advance_cfg_cycles(20);
    advance_core_cycles(20);

    const std::uint32_t status = driver.read(regmap::DEBUG_DBG_SNAP_STATUS_ADDR).data;
    const std::uint32_t capturing = regmap::field_get(
        status, regmap::DEBUG_DBG_SNAP_STATUS_CAPTURING_LSB,
        regmap::DEBUG_DBG_SNAP_STATUS_CAPTURING_WIDTH);
    const std::uint32_t done = regmap::field_get(
        status, regmap::DEBUG_DBG_SNAP_STATUS_CAPTURE_DONE_LSB,
        regmap::DEBUG_DBG_SNAP_STATUS_CAPTURE_DONE_WIDTH);
    check(capturing == 0, "armed_capturing",
          "armed trigger: CAPTURING remained set after fill");
    check(done == 1, "armed_done",
          "armed trigger: CAPTURE_DONE not set after fill");

    // Read out captured beats and confirm they are 8 CONSECUTIVE beats with
    // the correlated data_lo/seq pattern. The exact starting seq depends on
    // the latency between register write and the FSM transition into
    // CAPTURING, which is not fixed and not the property under test.
    std::uint32_t last_seq = 0;
    for (std::uint32_t i = 0; i < 8; ++i) {
      driver.write_field(regmap::DEBUG_DBG_SNAP_POINTER_ADDR,
                         regmap::DEBUG_DBG_SNAP_POINTER_INDEX_LSB,
                         regmap::DEBUG_DBG_SNAP_POINTER_INDEX_WIDTH, i);
      const std::uint32_t data_lo = driver.read(regmap::DEBUG_DBG_SNAP_DATA_ADDR).data;
      const std::uint32_t meta    = driver.read(regmap::DEBUG_DBG_SNAP_DATA_META_ADDR).data;
      const std::uint32_t seq = regmap::field_get(
          meta, regmap::DEBUG_DBG_SNAP_DATA_META_SEQ_LSB,
          regmap::DEBUG_DBG_SNAP_DATA_META_SEQ_WIDTH);
      // data_lo pattern: 0xDEAD0000 | seq
      check((data_lo & 0xFFFF) == seq, "captured_data",
            "captured beat " + std::to_string(i) +
            " data_lo low=" + std::to_string(data_lo & 0xFFFF) +
            " but meta.seq=" + std::to_string(seq));
      check((data_lo & 0xFFFF0000) == 0xDEAD0000, "captured_data_hi",
            "captured beat " + std::to_string(i) +
            " data_lo high=0x" + std::to_string(data_lo >> 16));
      if (i > 0) {
        check(seq == last_seq + 1, "captured_seq_consecutive",
              "captured beats not consecutive: beat " + std::to_string(i) +
              " seq=" + std::to_string(seq) +
              ", prev seq=" + std::to_string(last_seq));
      }
      last_seq = seq;
    }
    std::printf("-> %s\n", errors.count() == before ? "OK" : "FAILED");
  }

  // ---- Pass 3: status clear + rearm lets a fresh capture fire ----
  {
    std::printf("  pass 3/4 status_clear     ");
    const std::size_t before = errors.count();
    // Disarm first so the FSM leaves S_DONE.
    driver.write_field(regmap::DEBUG_DBG_SNAP_CTRL_ADDR,
                       regmap::DEBUG_DBG_SNAP_CTRL_ARM_LSB, 1, 0);
    // Pulse the block-level STATUS_CLEAR: clears done_q in the core-clk domain
    // and the sticky W1C bit at the register level (via hw_set falling).
    driver.write_field(regmap::DEBUG_DBG_SNAP_CTRL_ADDR,
                       regmap::DEBUG_DBG_SNAP_CTRL_STATUS_CLEAR_LSB, 1, 1);
    advance_cfg_cycles(4);
    advance_core_cycles(8);
    advance_cfg_cycles(4);
    // W1C the sticky bit at the register level too (belt+suspenders).
    driver.write(regmap::DEBUG_DBG_SNAP_STATUS_ADDR,
                 (1u << regmap::DEBUG_DBG_SNAP_STATUS_CAPTURE_DONE_LSB));
    advance_cfg_cycles(4);
    advance_core_cycles(4);
    advance_cfg_cycles(4);
    const std::uint32_t status = driver.read(regmap::DEBUG_DBG_SNAP_STATUS_ADDR).data;
    const std::uint32_t done = regmap::field_get(
        status, regmap::DEBUG_DBG_SNAP_STATUS_CAPTURE_DONE_LSB,
        regmap::DEBUG_DBG_SNAP_STATUS_CAPTURE_DONE_WIDTH);
    const std::uint32_t wr_ptr = regmap::field_get(
        status, regmap::DEBUG_DBG_SNAP_STATUS_WR_PTR_LSB,
        regmap::DEBUG_DBG_SNAP_STATUS_WR_PTR_WIDTH);
    check(done == 0, "status_clear_done",
          "STATUS_CLEAR: CAPTURE_DONE still set");
    check(wr_ptr == 0, "status_clear_ptr",
          "STATUS_CLEAR: WR_PTR not zero (" + std::to_string(wr_ptr) + ")");
    std::printf("-> %s\n", errors.count() == before ? "OK" : "FAILED");
  }

  // ---- Pass 4: continuous mode never sets DONE ----
  {
    std::printf("  pass 4/4 continuous       ");
    const std::size_t before = errors.count();
    if (!run_reset()) errors.error("reset", "reset failed pass 4");
    driver.write_field(regmap::DEBUG_DBG_SNAP_SOURCE_ADDR,
                       regmap::DEBUG_DBG_SNAP_SOURCE_SOURCE_SEL_LSB,
                       regmap::DEBUG_DBG_SNAP_SOURCE_SOURCE_SEL_WIDTH, 0);
    driver.write_field(regmap::DEBUG_DBG_SNAP_DEPTH_ADDR,
                       regmap::DEBUG_DBG_SNAP_DEPTH_DEPTH_LSB,
                       regmap::DEBUG_DBG_SNAP_DEPTH_DEPTH_WIDTH, 4);
    // Continuous: ONE_SHOT=0
    driver.write_field(regmap::DEBUG_DBG_SNAP_CTRL_ADDR,
                       regmap::DEBUG_DBG_SNAP_CTRL_ARM_LSB, 1, 1);
    driver.write_field(regmap::DEBUG_DBG_SNAP_CTRL_ADDR,
                       regmap::DEBUG_DBG_SNAP_CTRL_ONE_SHOT_LSB, 1, 0);
    driver.write_field(regmap::DEBUG_DBG_SNAP_CTRL_ADDR,
                       regmap::DEBUG_DBG_SNAP_CTRL_TRIGGER_LSB, 1, 1);
    feed_active = true;
    advance_core_cycles(30);
    feed_active = false;
    advance_cfg_cycles(10);
    const std::uint32_t status = driver.read(regmap::DEBUG_DBG_SNAP_STATUS_ADDR).data;
    const std::uint32_t done = regmap::field_get(
        status, regmap::DEBUG_DBG_SNAP_STATUS_CAPTURE_DONE_LSB,
        regmap::DEBUG_DBG_SNAP_STATUS_CAPTURE_DONE_WIDTH);
    check(done == 0, "continuous_done",
          "continuous mode: CAPTURE_DONE set (" + std::to_string(done) + ")");
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
  summary.beats_observed = driver.transactions();
  summary.absorb(errors);
  summary.wall_time_s =
      std::chrono::duration<double>(wall_end - wall_start).count();
  summary.write(args.results_dir);
  std::printf("--- summary ---\n");
  std::printf("  wall time : %.2fs\n", summary.wall_time_s);
  std::printf("  errors    : %zu\n", errors.count());
  std::printf("RESULT: %s seed=%llu test=%s config=%s errors=%zu\n",
              passed ? "PASS" : "FAIL",
              (unsigned long long)args.seed, kTestName,
              args.config_name.c_str(), errors.count());
  top->final();
  return passed ? 0 : 1;
}
