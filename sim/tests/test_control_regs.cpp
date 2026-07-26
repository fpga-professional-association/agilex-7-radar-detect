// -----------------------------------------------------------------------------
// test_control_regs.cpp — register/control-plane tests (SPEC 13.1, issue #7).
//
// One binary, one seed, nine passes over sim/verilator/tops/control_top.sv,
// which holds the whole of rtl/control/ plus a second fabric whose block never
// answers. Everything is driven through harness::RegDriver, i.e. through the
// SPEC 9 protocol, exactly as software would drive it.
//
//   1  identification      MAGIC, VERSION, GEOMETRY, CAPABILITY against the
//                          generated map. Discovery must work with no prior
//                          knowledge but the block base.
//   2  build parameters    every parameter register against config_sim.h, which
//                          is generated from the same config/<name>.json the RTL
//                          elaborated from, plus the FNV-1a checksum computed
//                          independently on both sides.
//   3  reset defaults      every documented register read and compared with its
//                          generated reset value (storage) or its hardware value
//                          (ROHW), and the storage compared again through the
//                          observation ports, which do not use the read mux.
//   4  scratch read/write  walking ones, walking zeros, all fifteen non-zero
//                          byte-enable patterns, aliasing between registers, and
//                          the half-writable register.
//   5  read-only writes    a write to a register with no writable bit must be
//                          refused with error=1 and change nothing.
//   6  side effects        W1C set/clear semantics, write-1-pulse width and
//                          gating, the fault counter, and the hardware-computed
//                          status field.
//   7  illegal access      every malformed and unmapped form, each of which must
//                          answer error=1 in the same bounded time as a good
//                          access, and must leave the plane working.
//   8  watchdog            the second fabric, against a block that never
//                          answers: the transaction must still complete, with
//                          error=1, inside the watchdog bound. This is the
//                          "never hangs" proof.
//   9  randomized soak     random legal and illegal transactions against a C++
//                          model of the whole map, then a full register dump
//                          compared with the model. Seeded, so a failure
//                          replays.
//
// Reset is re-run before pass 3 and again in pass 4, so reset coverage is per
// pass per seed rather than once at time zero.
//
// Every access on the main port must complete in exactly two cycles. That is
// checked on every transaction rather than in one directed case: an access that
// silently costs a variable number of cycles is a defect the error paths would
// otherwise hide.
// -----------------------------------------------------------------------------

#include <algorithm>
#include <chrono>
#include <cstdio>
#include <cstring>
#include <memory>
#include <string>
#include <vector>

#include "Vcontrol_top.h"
#include "verilated.h"

#include "config_sim.h"
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

constexpr const char* kTestName = "test_control_regs";

// Every access through reg_fabric costs one cycle of decode plus one cycle in
// the block. reg_if_pkg::REG_ACCESS_LATENCY, seen from the master.
constexpr std::uint64_t kExpectedCycles = 2;

// FNV-1a 32. The same algorithm reg_block_build_params.sv implements; the point
// of computing it twice is that the two must agree.
std::uint32_t fnv1a32_word(std::uint32_t h, std::uint32_t word) {
  for (unsigned b = 0; b < 4; ++b) {
    h ^= (word >> (b * 8)) & 0xFFu;
    h *= 16777619u;
  }
  return h;
}

// ---------------------------------------------------------------------------
// The C++ model of the register map.
//
// Built entirely from the generated tables, so it models what the map says
// rather than what the RTL does. The two are independent implementations of one
// source of truth, which is the only arrangement in which agreement means
// anything.
// ---------------------------------------------------------------------------
struct Predicted {
  std::uint32_t data = 0;
  bool error = false;
};

class RegModel {
 public:
  RegModel() { reset(); }

  void reset() {
    storage_.assign(regmap::kRegisterTableSize, 0);
    for (std::size_t i = 0; i < regmap::kRegisterTableSize; ++i) {
      storage_[i] = regmap::kRegisters[i].reset;
    }
    fault_count_ = 0;
    last_pulse_ = 0;
  }

  // The value a read of `index` returns, hardware-driven fields included.
  std::uint32_t read_value(std::size_t index) const {
    const regmap::RegInfo& r = regmap::kRegisters[index];
    const std::uint32_t hw = hw_value(r);
    return (storage_[index] & ~r.hw_mask) | (hw & r.hw_mask);
  }

  std::uint32_t storage(std::size_t index) const { return storage_[index]; }
  std::uint32_t fault_inject_pulse() const { return last_pulse_; }

  // Predicts the response to any transaction, legal or not, and applies its
  // side effects. Mirrors reg_if_pkg's malformed test and reg_csr_block's
  // per-bit semantics.
  Predicted access(std::uint32_t address, bool we, bool re, std::uint32_t data,
                   std::uint8_t be) {
    last_pulse_ = 0;
    Predicted p;
    const bool malformed =
        (we && re) || ((address & 0x3u) != 0) || (we && !re && be == 0);
    if (malformed || !(we || re)) {
      p.error = we || re;
      return p;
    }
    const std::size_t index = index_of(address);
    if (index == kNoIndex) {
      p.error = true;
      return p;
    }
    const regmap::RegInfo& r = regmap::kRegisters[index];
    if (we && r.writable_mask == 0) {
      p.error = true;  // read-only register
      return p;
    }
    if (re) {
      p.data = read_value(index);
      return p;
    }
    apply_write(index, data, be);
    return p;
  }

  static std::size_t index_of(std::uint32_t address) {
    for (std::size_t i = 0; i < regmap::kRegisterTableSize; ++i) {
      if (regmap::kRegisters[i].address == address) return i;
    }
    return kNoIndex;
  }

  static constexpr std::size_t kNoIndex = static_cast<std::size_t>(-1);

 private:
  static std::uint32_t be_mask(std::uint8_t be) {
    std::uint32_t m = 0;
    for (unsigned b = 0; b < 4; ++b) {
      if ((be >> b) & 1u) m |= 0xFFu << (b * 8);
    }
    return m;
  }

  static bool same(const char* a, const char* b) { return std::strcmp(a, b) == 0; }

  std::uint32_t hw_value(const regmap::RegInfo& r) const {
    if (r.hw_mask == 0) return 0;
    if (same(r.block, "build_params")) return build_param(r.name);
    if (same(r.block, "ctrl") && same(r.name, "CTRL_STATUS")) {
      const std::size_t en = index_of(regmap::CTRL_BLOCK_ENABLE_ADDR);
      const unsigned count =
          static_cast<unsigned>(__builtin_popcount(storage_[en]));
      std::uint32_t v = 0;
      v = regmap::field_set(v, regmap::CTRL_CTRL_STATUS_ENABLED_COUNT_LSB,
                            regmap::CTRL_CTRL_STATUS_ENABLED_COUNT_WIDTH, count);
      v = regmap::field_set(v, regmap::CTRL_CTRL_STATUS_ALIVE_LSB,
                            regmap::CTRL_CTRL_STATUS_ALIVE_WIDTH, 1);
      return v;
    }
    if (same(r.block, "fault") && same(r.name, "FAULT_COUNT")) return fault_count_;
    return 0;
  }

  static std::uint32_t build_param(const char* name) {
    struct Entry {
      const char* name;
      std::uint32_t value;
    };
    static const Entry kEntries[] = {
        {"N_ANTENNAS", sim_config::N_ANTENNAS},
        {"SAMPLES_PER_CYCLE", sim_config::SAMPLES_PER_CYCLE},
        {"FFT_SIZE", sim_config::FFT_SIZE},
        {"PFB_TAPS", sim_config::PFB_TAPS},
        {"N_BEAMS", sim_config::N_BEAMS},
        {"HISTORY_FRAMES", sim_config::HISTORY_FRAMES},
        {"PACKET_W", sim_config::PACKET_W},
        {"SAMPLE_W", sim_config::SAMPLE_W},
        {"COEFF_W", sim_config::COEFF_W},
        {"POWER_W", sim_config::POWER_W},
        {"N_VIRTUAL_CHANS", sim_config::N_VIRTUAL_CHANS},
    };
    for (const Entry& e : kEntries) {
      if (same(e.name, name)) return e.value;
    }
    if (same(name, "PARAM_CHECKSUM")) {
      std::uint32_t h = 0x811C9DC5u;
      for (const Entry& e : kEntries) h = fnv1a32_word(h, e.value);
      return h;
    }
    return 0;
  }

  void apply_write(std::size_t index, std::uint32_t data, std::uint8_t be) {
    const regmap::RegInfo& r = regmap::kRegisters[index];
    const std::uint32_t m = be_mask(be);
    std::uint32_t v = storage_[index];
    v = (v & ~(r.wmask & m)) | (data & r.wmask & m);      // plain read-write
    v &= ~(data & r.w1c_mask & m);                        // write 1 to clear
    v &= ~r.pulse_mask;                                   // pulses never store
    storage_[index] = v;

    const std::uint32_t pulse = data & r.pulse_mask & m;
    if (pulse != 0 && same(r.block, "fault") && same(r.name, "FAULT_INJECT")) {
      // Injection is gated by the arming mask, and every injected pulse is
      // recorded twice: sticky in FAULT_STATUS and counted in FAULT_COUNT.
      const std::size_t arm = index_of(regmap::FAULT_FAULT_ENABLE_ADDR);
      const std::uint32_t injected = pulse & storage_[arm];
      last_pulse_ = injected;
      storage_[index_of(regmap::FAULT_FAULT_STATUS_ADDR)] |= injected;
      const std::uint32_t add =
          static_cast<std::uint32_t>(__builtin_popcount(injected));
      fault_count_ = (fault_count_ > 0xFFFFFFFFu - add) ? 0xFFFFFFFFu
                                                        : fault_count_ + add;
    }
  }

  std::vector<std::uint32_t> storage_;
  std::uint32_t fault_count_ = 0;
  std::uint32_t last_pulse_ = 0;
};

// ---------------------------------------------------------------------------
// Per-cycle observation of the control outputs. Registered in the sample phase,
// so what it sees is what the DUT held for a whole cycle.
// ---------------------------------------------------------------------------
struct PulseWatch {
  std::uint32_t block_reset_or = 0;
  std::uint64_t block_reset_cycles = 0;
  std::uint32_t fault_inject_or = 0;
  std::uint64_t fault_inject_cycles = 0;
  std::uint64_t flush_cycles = 0;
  std::uint64_t soft_reset_cycles = 0;
  std::uint64_t static_pulse_cycles = 0;   // must stay 0 for the whole run
  std::uint64_t build_nonzero_cycles = 0;  // must stay 0 for the whole run

  void clear() {
    block_reset_or = 0;
    block_reset_cycles = 0;
    fault_inject_or = 0;
    fault_inject_cycles = 0;
    flush_cycles = 0;
    soft_reset_cycles = 0;
  }
};

}  // namespace

int harness::sim_test_main(const SimArgs& args) {
  const auto wall_start = std::chrono::steady_clock::now();

  auto top = std::make_unique<Vcontrol_top>();
  ErrorCollector errors;
  errors.set_print_limit(30);

  ClockScheduler sched([&top]() { top->eval(); });
  errors.set_time_probe(sched.time_ptr());

  // SPEC 8: the register plane is cfg_clk, 100 MHz. One domain, end to end.
  const SimTime cfg_half = harness::half_period_ps(harness::kCfgClkMhz);
  const int cfg_clk = sched.add_clock("cfg_clk", cfg_half, &top->clk, cfg_half);

  ResetSequencer reset(sched);
  reset.add_domain("rst_n", cfg_clk, &top->rst_n, 8);

  std::uint64_t cfg_cycle = 0;
  sched.on_posedge_sample(cfg_clk, [&cfg_cycle]() { ++cfg_cycle; });

  SeedSource seeds(args.seed);

  // ---- drivers -----------------------------------------------------------
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

  RegPort stuck_port;
  stuck_port.address = &top->stuck_address;
  stuck_port.write_data = &top->stuck_write_data;
  stuck_port.byte_enable = &top->stuck_byte_enable;
  stuck_port.write_enable = &top->stuck_write_enable;
  stuck_port.read_enable = &top->stuck_read_enable;
  stuck_port.read_data = &top->stuck_read_data;
  stuck_port.ready = &top->stuck_ready;
  stuck_port.error = &top->stuck_error;
  RegDriver stuck("stuck", stuck_port, sched, cfg_clk, errors);

  RegModel model;
  PulseWatch watch;
  // Requests the dead block swallowed during pass 8. Recorded there because the
  // block's counter is reset state and pass 9 resets the DUT.
  std::uint64_t watchdog_swallowed = 0;

  // ---- per-cycle invariants ---------------------------------------------
  sched.on_posedge_sample(cfg_clk, [&]() {
    if (top->rst_n == 0) return;
    if (top->obs_block_reset_pulse != 0) {
      watch.block_reset_or |= top->obs_block_reset_pulse;
      ++watch.block_reset_cycles;
    }
    if (top->obs_fault_inject != 0) {
      watch.fault_inject_or |= top->obs_fault_inject;
      ++watch.fault_inject_cycles;
    }
    if (top->obs_flush_pulse != 0) ++watch.flush_cycles;
    if (top->obs_soft_reset_pulse != 0) ++watch.soft_reset_cycles;
    // Blocks with no writable and no pulse bits: their storage must never
    // change and they must never pulse, in any cycle of any pass.
    if (top->obs_static_pulse_any != 0) ++watch.static_pulse_cycles;
    if (top->obs_build_storage_zero == 0) ++watch.build_nonzero_cycles;
  });

  // ---- timeout guard -----------------------------------------------------
  const std::uint64_t hard_limit =
      args.timeout_cycles != 0 ? args.timeout_cycles : 400000;
  TimeoutGuard timeout(sched, errors, hard_limit, 2000,
                       [&]() { return driver.transactions() + stuck.transactions(); });
  sched.on_posedge_drive(cfg_clk, [&timeout]() { timeout.on_cycle(); });

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

  const SimTime time_limit = static_cast<SimTime>(hard_limit + 100000) * cfg_half * 2;

  // ---- small helpers -----------------------------------------------------
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
  auto hex = [](std::uint32_t v) {
    char buf[16];
    std::snprintf(buf, sizeof(buf), "0x%08X", v);
    return std::string(buf);
  };

  // Every access on the main port: check the response against the model, and
  // check the latency. Returns the result so a caller can look further.
  auto expect_read = [&](std::uint32_t address, std::uint32_t expected,
                         const std::string& what) {
    const RegResult r = driver.read(address);
    if (r.timed_out) {
      fail("reg_timeout", what + ": read " + RegDriver::describe(address) +
                              " never completed");
      return r;
    }
    check(!r.error, "reg_error",
          what + ": read " + RegDriver::describe(address) +
              " answered error=1, expected a normal response");
    check(r.data == expected, "reg_value",
          what + ": read " + RegDriver::describe(address) + " returned " +
              hex(r.data) + ", expected " + hex(expected));
    check(r.cycles == kExpectedCycles, "reg_latency",
          what + ": read " + RegDriver::describe(address) + " took " +
              std::to_string(r.cycles) + " cycles, expected " +
              std::to_string(kExpectedCycles));
    return r;
  };
  auto expect_write = [&](std::uint32_t address, std::uint32_t value,
                          std::uint8_t be, const std::string& what) {
    const RegResult r = driver.write(address, value, be);
    if (r.timed_out) {
      fail("reg_timeout", what + ": write " + RegDriver::describe(address) +
                              " never completed");
      return r;
    }
    check(!r.error, "reg_error",
          what + ": write " + RegDriver::describe(address) + " answered error=1");
    check(r.cycles == kExpectedCycles, "reg_latency",
          what + ": write " + RegDriver::describe(address) + " took " +
              std::to_string(r.cycles) + " cycles");
    return r;
  };
  auto expect_error = [&](std::uint32_t address, bool we, bool re,
                          std::uint32_t data, std::uint8_t be,
                          const std::string& what) {
    const RegResult r = driver.transact(address, we, re, data, be);
    if (r.timed_out) {
      fail("reg_hang", what + ": " + RegDriver::describe(address) +
                           " never answered — the fabric hung on an illegal access");
      return r;
    }
    check(r.error, "reg_error_missing",
          what + ": " + RegDriver::describe(address) +
              " answered error=0, expected an error response");
    check(r.data == 0, "reg_value",
          what + ": " + RegDriver::describe(address) +
              " returned data " + hex(r.data) + " with its error response");
    check(r.cycles == kExpectedCycles, "reg_latency",
          what + ": error response took " + std::to_string(r.cycles) +
              " cycles, expected " + std::to_string(kExpectedCycles));
    return r;
  };

  // 128-bit observation ports arrive as four 32-bit words.
  auto obs_word = [](const VlWide<4>& w, unsigned i) -> std::uint32_t {
    return w[i];
  };

  auto run_reset = [&]() {
    driver.reset();
    stuck.reset();
    sched.clear_stop();
    reset.assert_all();
    const StopReason r = reset.release_all(time_limit);
    model.reset();
    timeout.reset();
    return r == StopReason::kRunning;
  };

  if (!run_reset()) {
    fail("reset", "the reset sequence did not complete");
  }

  const bool quiet = args.quiet;
  auto banner = [&](int n, const char* name) {
    if (!quiet) std::printf("  pass %d/9 %-18s ", n, name);
    std::fflush(stdout);
  };
  auto verdict = [&](std::size_t before) {
    const bool ok = errors.count() == before;
    if (!quiet) std::printf("-> %s\n", ok ? "OK" : "FAILED");
    std::fflush(stdout);
    return ok;
  };

  // =========================================================================
  // Pass 1 — identification
  // =========================================================================
  {
    banner(1, "identification");
    const std::size_t before = errors.count();

    expect_read(regmap::ID_MAGIC_ADDR, 0x52414441u, "id");
    expect_read(regmap::ID_VERSION_ADDR, regmap::ID_VERSION_RESET, "id");
    expect_read(regmap::ID_GEOMETRY_ADDR, regmap::ID_GEOMETRY_RESET, "id");
    expect_read(regmap::ID_CAPABILITY_ADDR, regmap::kBlockMask, "id");

    // The map must describe itself consistently: the version fields, the block
    // count and the capability bitmap all come from the same source of truth,
    // and a discovery walk relies on them agreeing.
    const RegResult ver = driver.read(regmap::ID_VERSION_ADDR);
    check(regmap::field_get(ver.data, regmap::ID_VERSION_MAJOR_LSB,
                            regmap::ID_VERSION_MAJOR_WIDTH) == regmap::kVersionMajor,
          "reg_value", "id: VERSION.MAJOR disagrees with the generated map");
    const RegResult geo = driver.read(regmap::ID_GEOMETRY_ADDR);
    check(regmap::field_get(geo.data, regmap::ID_GEOMETRY_N_BLOCKS_LSB,
                            regmap::ID_GEOMETRY_N_BLOCKS_WIDTH) == regmap::kBlockCount,
          "reg_value", "id: GEOMETRY.N_BLOCKS disagrees with the generated map");
    check(regmap::field_get(geo.data, regmap::ID_GEOMETRY_N_REGS_LSB,
                            regmap::ID_GEOMETRY_N_REGS_WIDTH) == regmap::kRegisterCount,
          "reg_value", "id: GEOMETRY.N_REGS disagrees with the generated map");
    check(regmap::field_get(geo.data, regmap::ID_GEOMETRY_DATA_W_LSB,
                            regmap::ID_GEOMETRY_DATA_W_WIDTH) == regmap::kDataWidth,
          "reg_value", "id: GEOMETRY.DATA_W disagrees with the generated map");

    // The identification constants are storage, so they are also visible on the
    // observation port without touching the read mux.
    check(obs_word(top->obs_id_csr, 0) == 0x52414441u, "reg_storage",
          "id: MAGIC storage is " + hex(obs_word(top->obs_id_csr, 0)) +
              ", expected 0x52414441");

    verdict(before);
  }

  // =========================================================================
  // Pass 2 — build parameters against the configuration the RTL elaborated
  // =========================================================================
  {
    banner(2, "build_params");
    const std::size_t before = errors.count();

    struct ParamCheck {
      std::uint32_t address;
      std::uint32_t expected;
      const char* name;
    };
    const ParamCheck checks[] = {
        {regmap::BUILD_PARAMS_N_ANTENNAS_ADDR, sim_config::N_ANTENNAS, "N_ANTENNAS"},
        {regmap::BUILD_PARAMS_SAMPLES_PER_CYCLE_ADDR, sim_config::SAMPLES_PER_CYCLE,
         "SAMPLES_PER_CYCLE"},
        {regmap::BUILD_PARAMS_FFT_SIZE_ADDR, sim_config::FFT_SIZE, "FFT_SIZE"},
        {regmap::BUILD_PARAMS_PFB_TAPS_ADDR, sim_config::PFB_TAPS, "PFB_TAPS"},
        {regmap::BUILD_PARAMS_N_BEAMS_ADDR, sim_config::N_BEAMS, "N_BEAMS"},
        {regmap::BUILD_PARAMS_HISTORY_FRAMES_ADDR, sim_config::HISTORY_FRAMES,
         "HISTORY_FRAMES"},
        {regmap::BUILD_PARAMS_PACKET_W_ADDR, sim_config::PACKET_W, "PACKET_W"},
        {regmap::BUILD_PARAMS_SAMPLE_W_ADDR, sim_config::SAMPLE_W, "SAMPLE_W"},
        {regmap::BUILD_PARAMS_COEFF_W_ADDR, sim_config::COEFF_W, "COEFF_W"},
        {regmap::BUILD_PARAMS_POWER_W_ADDR, sim_config::POWER_W, "POWER_W"},
        {regmap::BUILD_PARAMS_N_VIRTUAL_CHANS_ADDR, sim_config::N_VIRTUAL_CHANS,
         "N_VIRTUAL_CHANS"},
    };
    std::uint32_t checksum = 0x811C9DC5u;
    for (const ParamCheck& c : checks) {
      expect_read(c.address, c.expected,
                  std::string("build_params.") + c.name);
      checksum = fnv1a32_word(checksum, c.expected);
    }
    expect_read(regmap::BUILD_PARAMS_PARAM_CHECKSUM_ADDR, checksum,
                "build_params.PARAM_CHECKSUM");
    check(top->obs_param_checksum == checksum, "reg_value",
          "build_params: the RTL's parameter checksum " +
              hex(top->obs_param_checksum) + " differs from the harness's " +
              hex(checksum) + " — RTL and harness were built from different "
              "configurations");

    verdict(before);
  }

  // =========================================================================
  // Pass 3 — reset defaults for every documented register
  // =========================================================================
  {
    banner(3, "reset_defaults");
    const std::size_t before = errors.count();
    if (!run_reset()) fail("reset", "the reset sequence did not complete");

    for (std::size_t i = 0; i < regmap::kRegisterTableSize; ++i) {
      const regmap::RegInfo& r = regmap::kRegisters[i];
      expect_read(r.address, model.read_value(i),
                  std::string("reset.") + r.block + "." + r.name);
    }
    check(regmap::kRegisterCount == regmap::kRegisterTableSize, "regmap",
          "the generated register count disagrees with the generated table");

    // Storage, seen without the read mux.
    const std::size_t s0 = RegModel::index_of(regmap::SCRATCH_SCRATCH0_ADDR);
    for (unsigned i = 0; i < 4; ++i) {
      const std::uint32_t want = regmap::kRegisters[s0 + i].reset;
      const std::uint32_t got = obs_word(top->obs_scratch_csr, i);
      check(got == want, "reg_storage",
            "reset: scratch storage word " + std::to_string(i) + " is " +
                hex(got) + ", expected " + hex(want));
    }
    verdict(before);
  }

  // =========================================================================
  // Pass 4 — scratch read/write, byte enables, aliasing, partial writability
  // =========================================================================
  {
    banner(4, "scratch_rw");
    const std::size_t before = errors.count();

    const std::uint32_t scratch[3] = {regmap::SCRATCH_SCRATCH0_ADDR,
                                      regmap::SCRATCH_SCRATCH1_ADDR,
                                      regmap::SCRATCH_SCRATCH2_ADDR};

    // Walking ones and walking zeros: every bit of every scratch register is
    // set and cleared independently, so a stuck or crossed bit is located.
    for (std::uint32_t addr : scratch) {
      for (unsigned bit = 0; bit < 32; ++bit) {
        const std::uint32_t ones = 1u << bit;
        expect_write(addr, ones, 0xF, "walking_ones");
        expect_read(addr, ones, "walking_ones");
        const std::uint32_t zeros = ~ones;
        expect_write(addr, zeros, 0xF, "walking_zeros");
        expect_read(addr, zeros, "walking_zeros");
      }
    }

    // Aliasing: writing one register must not disturb its neighbours.
    expect_write(scratch[0], 0x11111111u, 0xF, "alias");
    expect_write(scratch[1], 0x22222222u, 0xF, "alias");
    expect_write(scratch[2], 0x33333333u, 0xF, "alias");
    expect_read(scratch[0], 0x11111111u, "alias");
    expect_read(scratch[1], 0x22222222u, "alias");
    expect_read(scratch[2], 0x33333333u, "alias");

    // Byte enables: all fifteen non-zero patterns, from a known base.
    for (unsigned be = 1; be < 16; ++be) {
      const std::uint32_t base = 0x00000000u;
      const std::uint32_t pattern = 0xDEADBEEFu;
      expect_write(scratch[0], base, 0xF, "byte_enable_setup");
      expect_write(scratch[0], pattern, static_cast<std::uint8_t>(be),
                   "byte_enable");
      std::uint32_t want = base;
      for (unsigned b = 0; b < 4; ++b) {
        if ((be >> b) & 1u) {
          want &= ~(0xFFu << (b * 8));
          want |= pattern & (0xFFu << (b * 8));
        }
      }
      expect_read(scratch[0], want, "byte_enable be=" + std::to_string(be));
    }

    // The half-writable register: the write succeeds, the constant half does
    // not move.
    expect_write(regmap::SCRATCH_SCRATCH3_ADDR, 0xFFFFFFFFu, 0xF, "partial");
    expect_read(regmap::SCRATCH_SCRATCH3_ADDR,
                (0xDEADu << regmap::SCRATCH_SCRATCH3_RO_HIGH_LSB) | 0xFFFFu,
                "partial");
    expect_write(regmap::SCRATCH_SCRATCH3_ADDR, 0x00000000u, 0xF, "partial");
    expect_read(regmap::SCRATCH_SCRATCH3_ADDR,
                (0xDEADu << regmap::SCRATCH_SCRATCH3_RO_HIGH_LSB), "partial");

    // Reset restores every default, including the non-zero ones.
    if (!run_reset()) fail("reset", "the reset sequence did not complete");
    for (unsigned i = 0; i < 4; ++i) {
      const std::size_t idx = RegModel::index_of(regmap::SCRATCH_SCRATCH0_ADDR) + i;
      expect_read(regmap::kRegisters[idx].address, regmap::kRegisters[idx].reset,
                  "reset_after_write");
    }
    verdict(before);
  }

  // =========================================================================
  // Pass 5 — writes to read-only registers are refused
  // =========================================================================
  {
    banner(5, "read_only");
    const std::size_t before = errors.count();

    for (std::size_t i = 0; i < regmap::kRegisterTableSize; ++i) {
      const regmap::RegInfo& r = regmap::kRegisters[i];
      if (r.writable_mask != 0) continue;
      const std::uint32_t was = model.read_value(i);
      expect_error(r.address, true, false, 0xFFFFFFFFu, 0xF, "read_only");
      expect_read(r.address, was, "read_only");
    }
    verdict(before);
  }

  // =========================================================================
  // Pass 6 — side effects: W1C, write-1-pulse, gating, counters, status
  // =========================================================================
  {
    banner(6, "side_effects");
    const std::size_t before = errors.count();
    if (!run_reset()) fail("reset", "the reset sequence did not complete");

    // Unarmed injection does nothing at all.
    watch.clear();
    expect_write(regmap::FAULT_FAULT_INJECT_ADDR, 0x3Fu, 0xF, "fault_unarmed");
    expect_read(regmap::FAULT_FAULT_STATUS_ADDR, 0u, "fault_unarmed");
    expect_read(regmap::FAULT_FAULT_COUNT_ADDR, 0u, "fault_unarmed");
    check(watch.fault_inject_cycles == 0, "fault_gate",
          "fault: an unarmed trigger produced " +
              std::to_string(watch.fault_inject_cycles) + " injection cycles");

    // Armed injection: one cycle wide, gated by the arming mask, sticky and
    // counted.
    expect_write(regmap::FAULT_FAULT_ENABLE_ADDR, 0x05u, 0xF, "fault_arm");
    expect_read(regmap::FAULT_FAULT_ENABLE_ADDR, 0x05u, "fault_arm");
    watch.clear();
    expect_write(regmap::FAULT_FAULT_INJECT_ADDR, 0x07u, 0xF, "fault_inject");
    check(watch.fault_inject_cycles == 1, "fault_pulse",
          "fault: the injection pulse lasted " +
              std::to_string(watch.fault_inject_cycles) +
              " cycles, expected exactly 1");
    check(watch.fault_inject_or == 0x05u, "fault_gate",
          "fault: injected " + hex(watch.fault_inject_or) +
              ", expected 0x00000005 (trigger 0x07 gated by arming 0x05)");
    expect_read(regmap::FAULT_FAULT_INJECT_ADDR, 0u, "fault_inject");
    expect_read(regmap::FAULT_FAULT_STATUS_ADDR, 0x05u, "fault_status");
    expect_read(regmap::FAULT_FAULT_COUNT_ADDR, 2u, "fault_count");

    // W1C: writing 0 clears nothing, writing 1 clears exactly that bit.
    expect_write(regmap::FAULT_FAULT_STATUS_ADDR, 0x00u, 0xF, "w1c");
    expect_read(regmap::FAULT_FAULT_STATUS_ADDR, 0x05u, "w1c_zero_write");
    expect_write(regmap::FAULT_FAULT_STATUS_ADDR, 0x01u, 0xF, "w1c");
    expect_read(regmap::FAULT_FAULT_STATUS_ADDR, 0x04u, "w1c_one_bit");
    expect_write(regmap::FAULT_FAULT_STATUS_ADDR, 0xFFu, 0xF, "w1c");
    expect_read(regmap::FAULT_FAULT_STATUS_ADDR, 0x00u, "w1c_all");
    // Clearing the status must not disturb the count.
    expect_read(regmap::FAULT_FAULT_COUNT_ADDR, 2u, "fault_count");

    // Per-block soft reset pulses.
    watch.clear();
    expect_write(regmap::CTRL_BLOCK_RESET_ADDR, 0x0Fu, 0xF, "block_reset");
    check(watch.block_reset_cycles == 1, "pulse_width",
          "ctrl: the block-reset pulse lasted " +
              std::to_string(watch.block_reset_cycles) + " cycles, expected 1");
    check(watch.block_reset_or == 0x0Fu, "pulse_value",
          "ctrl: the block-reset pulse carried " + hex(watch.block_reset_or) +
              ", expected 0x0000000F");
    expect_read(regmap::CTRL_BLOCK_RESET_ADDR, 0u, "block_reset");

    // Global pulses, and the level bit beside them.
    watch.clear();
    expect_write(regmap::CTRL_GLOBAL_CTRL_ADDR,
                 (1u << regmap::CTRL_GLOBAL_CTRL_GLOBAL_ENABLE_LSB) |
                     (1u << regmap::CTRL_GLOBAL_CTRL_FLUSH_LSB),
                 0xF, "global_ctrl");
    check(watch.flush_cycles == 1, "pulse_width",
          "ctrl: the flush pulse lasted " + std::to_string(watch.flush_cycles) +
              " cycles, expected 1");
    check(watch.soft_reset_cycles == 0, "pulse_value",
          "ctrl: soft reset pulsed without being written");
    check(top->obs_global_enable == 1, "reg_value",
          "ctrl: GLOBAL_ENABLE did not survive the write that pulsed FLUSH");
    expect_read(regmap::CTRL_GLOBAL_CTRL_ADDR,
                1u << regmap::CTRL_GLOBAL_CTRL_GLOBAL_ENABLE_LSB, "global_ctrl");

    // The hardware-computed status field tracks the live enable word.
    const struct {
      std::uint32_t enables;
      std::uint32_t count;
    } enable_cases[] = {{0x00u, 0}, {0x0Fu, 4}, {0xFFu, 8}, {0x81u, 2}};
    for (const auto& c : enable_cases) {
      expect_write(regmap::CTRL_BLOCK_ENABLE_ADDR, c.enables, 0xF, "block_enable");
      expect_read(regmap::CTRL_BLOCK_ENABLE_ADDR, c.enables, "block_enable");
      check(top->obs_block_enable == c.enables, "reg_output",
            "ctrl: block_enable output is " + hex(top->obs_block_enable) +
                ", expected " + hex(c.enables));
      RegResult st;
      const std::uint32_t got =
          driver.read_field(regmap::CTRL_CTRL_STATUS_ADDR,
                            regmap::CTRL_CTRL_STATUS_ENABLED_COUNT_LSB,
                            regmap::CTRL_CTRL_STATUS_ENABLED_COUNT_WIDTH, &st);
      check(st.ok() && got == c.count, "reg_value",
            "ctrl: CTRL_STATUS.ENABLED_COUNT is " + std::to_string(got) +
                " for enables " + hex(c.enables) + ", expected " +
                std::to_string(c.count));
    }
    check(driver.read_field(regmap::CTRL_CTRL_STATUS_ADDR,
                            regmap::CTRL_CTRL_STATUS_ALIVE_LSB,
                            regmap::CTRL_CTRL_STATUS_ALIVE_WIDTH) == 1u,
          "reg_value", "ctrl: CTRL_STATUS.ALIVE does not read 1");

    // Read-modify-write through a field, the way software programs one field of
    // a shared register.
    driver.write_field(regmap::CTRL_BLOCK_ENABLE_ADDR,
                       regmap::CTRL_BLOCK_ENABLE_CFAR_LSB,
                       regmap::CTRL_BLOCK_ENABLE_CFAR_WIDTH, 1);
    expect_read(regmap::CTRL_BLOCK_ENABLE_ADDR,
                0x81u | (1u << regmap::CTRL_BLOCK_ENABLE_CFAR_LSB),
                "write_field");

    verdict(before);
  }

  // =========================================================================
  // Pass 7 — illegal and malformed access
  // =========================================================================
  {
    banner(7, "illegal_access");
    const std::size_t before = errors.count();

    struct Illegal {
      std::uint32_t address;
      bool we;
      bool re;
      std::uint8_t be;
      const char* what;
    };
    const Illegal cases[] = {
        // Declared but unimplemented windows: every planned block.
        // The coefficient window became implemented with issue #10, so what is
        // illegal there is now an address past its last register.
        {regmap::COEFF_BASE + 0x100u, false, true, 0xF, "coeff window, no register"},
        // The CFAR window became implemented with issue #14, so what is illegal
        // there is now an address past its last register rather than the window
        // itself. The debug window is the last one still planned.
        {regmap::CFAR_BASE + 0x100u, true, false, 0xF, "cfar window, no register"},
        {regmap::DEBUG_BASE, false, true, 0xF, "planned debug window"},
        // The counters window is implemented as of issue #8, so what is illegal
        // there is an address past its last register, not the window itself.
        {regmap::COUNTERS_BASE + 0x400u, false, true, 0xF,
         "counters window, no register"},
        // Outside every declared window.
        {0xF000u, false, true, 0xF, "address above every window"},
        {0xF004u, true, false, 0xF, "address above every window, write"},
        // 0x9000 was the gap above the last declared window until the SPEC 9
        // integration-settings window landed there with issue #13. The gap is
        // now the next window up, and what is illegal inside the covariance
        // window is an address past its last register.
        {0xA000u, false, true, 0xF, "gap above the last declared window"},
        {regmap::COVAR_BASE + 0x100u, false, true, 0xF,
         "covar window, no register"},
        // Inside an implemented window, past the block's last register.
        {regmap::ID_BASE + 0x100u, false, true, 0xF, "id window, no register"},
        {regmap::SCRATCH_BASE + 0x0F0u, true, false, 0xF, "scratch window, no register"},
        {regmap::BUILD_PARAMS_BASE + 0x800u, false, true, 0xF, "build window, no register"},
        // Malformed requests at a perfectly good address.
        {regmap::SCRATCH_SCRATCH0_ADDR + 1u, false, true, 0xF, "unaligned read"},
        {regmap::SCRATCH_SCRATCH0_ADDR + 2u, true, false, 0xF, "unaligned write"},
        {regmap::SCRATCH_SCRATCH0_ADDR, true, false, 0x0, "write with no byte enable"},
        {regmap::SCRATCH_SCRATCH0_ADDR, true, true, 0xF, "read and write together"},
    };

    const std::uint32_t sentinel = 0xC0FFEE00u;
    expect_write(regmap::SCRATCH_SCRATCH0_ADDR, sentinel, 0xF, "illegal_setup");

    for (const Illegal& c : cases) {
      expect_error(c.address, c.we, c.re, 0x5A5A5A5Au, c.be, c.what);
      // The plane still works, and nothing was written.
      expect_read(regmap::SCRATCH_SCRATCH0_ADDR, sentinel,
                  std::string("after ") + c.what);
    }
    verdict(before);
  }

  // =========================================================================
  // Pass 8 — watchdog: a block that never answers
  // =========================================================================
  {
    banner(8, "watchdog");
    const std::size_t before = errors.count();

    const std::uint32_t swallowed_before = top->stuck_swallowed;
    stuck.set_max_cycles(64);
    const RegResult r = stuck.read(0x0000u);
    check(!r.timed_out, "reg_hang",
          "watchdog: the fabric never answered a request to a dead block — it hung");
    check(r.error, "reg_error_missing",
          "watchdog: the rescued transaction reported error=0");
    check(r.cycles > kExpectedCycles, "watchdog",
          "watchdog: the transaction completed in " + std::to_string(r.cycles) +
              " cycles, which is too fast to have gone through the watchdog");
    check(r.cycles <= 20, "watchdog",
          "watchdog: the transaction took " + std::to_string(r.cycles) +
              " cycles, beyond the watchdog bound");
    check(top->stuck_swallowed == swallowed_before + 1, "watchdog",
          "watchdog: the dead block saw " +
              std::to_string(top->stuck_swallowed - swallowed_before) +
              " requests, expected exactly 1");

    watchdog_swallowed = top->stuck_swallowed;

    // The fabric returns to idle and takes the next request normally — the
    // escape must not leave it stuck in a broken state.
    const RegResult again = stuck.read(0x0004u);
    check(!again.timed_out && again.error, "watchdog",
          "watchdog: the fabric did not recover for the following transaction");

    // And the main fabric, which shares nothing but the clock, is unaffected.
    expect_read(regmap::ID_MAGIC_ADDR, 0x52414441u, "after_watchdog");
    verdict(before);
  }

  // =========================================================================
  // Pass 9 — randomized soak against the model
  // =========================================================================
  {
    banner(9, "random_soak");
    const std::size_t before = errors.count();
    if (!run_reset()) fail("reset", "the reset sequence did not complete");

    std::mt19937_64 rng = seeds.engine("control.soak");
    const std::uint64_t n_access =
        args.frames != 0 ? args.frames : 600;

    // The address pool: every documented register, plus addresses that are
    // deliberately not registers, so roughly a third of the traffic is illegal.
    std::vector<std::uint32_t> legal;
    for (std::size_t i = 0; i < regmap::kRegisterTableSize; ++i) {
      legal.push_back(regmap::kRegisters[i].address);
    }
    const std::vector<std::uint32_t> illegal = {
        regmap::COEFF_BASE + 0x200u, regmap::CFAR_BASE + 0x20u,
        regmap::COUNTERS_BASE + 0x800u, regmap::DEBUG_BASE + 0x10u,
        0xF000u,                     0xABCDu & ~0x3u,
        regmap::ID_BASE + 0x200u,    regmap::SCRATCH_BASE + 0x040u,
        regmap::CTRL_BASE + 0x100u,  regmap::FAULT_BASE + 0x400u,
    };

    std::uint64_t reads = 0;
    std::uint64_t writes = 0;
    std::uint64_t errs = 0;
    for (std::uint64_t i = 0; i < n_access && errors.count() == before; ++i) {
      const bool use_legal = harness::bernoulli(rng, 0.7);
      std::uint32_t address =
          use_legal ? legal[harness::uniform_u64(rng, 0, legal.size() - 1)]
                    : illegal[harness::uniform_u64(rng, 0, illegal.size() - 1)];

      bool we = harness::bernoulli(rng, 0.5);
      bool re = !we;
      std::uint8_t be = static_cast<std::uint8_t>(harness::uniform_u64(rng, 1, 15));
      const std::uint32_t data =
          static_cast<std::uint32_t>(harness::uniform_u64(rng, 0, 0xFFFFFFFFull));

      // One access in twenty is malformed on purpose, in one of the three ways
      // the specification names.
      if (harness::bernoulli(rng, 0.05)) {
        switch (harness::uniform_u64(rng, 0, 2)) {
          case 0: address |= 0x1u; break;              // unaligned
          case 1: we = true; re = true; break;         // both enables
          default: we = true; re = false; be = 0; break;  // no byte enable
        }
      }

      const Predicted want = model.access(address, we, re, data, be);
      const RegResult got = driver.transact(address, we, re, data, be);

      if (got.timed_out) {
        fail("reg_hang", "soak: access " + std::to_string(i) + " to " +
                             RegDriver::describe(address) + " never completed");
        break;
      }
      if (got.error != want.error) {
        fail("reg_error",
             "soak: access " + std::to_string(i) + " (" +
                 (we ? (re ? "read+write" : "write") : "read") + " " +
                 RegDriver::describe(address) + " be=" + std::to_string(be) +
                 ") answered error=" + std::to_string(got.error ? 1 : 0) +
                 ", model says " + std::to_string(want.error ? 1 : 0));
        break;
      }
      if (got.data != want.data) {
        fail("reg_value", "soak: access " + std::to_string(i) + " to " +
                              RegDriver::describe(address) + " returned " +
                              hex(got.data) + ", model says " + hex(want.data));
        break;
      }
      if (got.cycles != kExpectedCycles) {
        fail("reg_latency", "soak: access " + std::to_string(i) + " took " +
                                std::to_string(got.cycles) + " cycles");
        break;
      }
      if (want.error) ++errs;
      if (we && !re) ++writes;
      if (re && !we) ++reads;
    }

    // The soak leaves the register file in some state; every register must
    // still read exactly what the model says it holds.
    for (std::size_t i = 0; i < regmap::kRegisterTableSize; ++i) {
      const regmap::RegInfo& r = regmap::kRegisters[i];
      expect_read(r.address, model.read_value(i),
                  std::string("soak_dump.") + r.block + "." + r.name);
    }

    if (!quiet) {
      std::printf("[%llu reads, %llu writes, %llu errors] ",
                  static_cast<unsigned long long>(reads),
                  static_cast<unsigned long long>(writes),
                  static_cast<unsigned long long>(errs));
    }
    verdict(before);
  }

  // ---- run-wide invariants ----------------------------------------------
  check(watch.static_pulse_cycles == 0, "reg_pulse",
        "a block with no pulse bits pulsed in " +
            std::to_string(watch.static_pulse_cycles) + " cycles");
  check(watch.build_nonzero_cycles == 0, "reg_storage",
        "the hardware-driven build-parameter block stored a non-zero value in " +
            std::to_string(watch.build_nonzero_cycles) + " cycles");
  check(driver.timeouts() == 0, "reg_hang",
        std::to_string(driver.timeouts()) +
            " transactions on the main port never completed");
  check(driver.max_response_cycles() == kExpectedCycles, "reg_latency",
        "the slowest main-port access took " +
            std::to_string(driver.max_response_cycles()) + " cycles, expected " +
            std::to_string(kExpectedCycles));

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
  summary.core_cycles = 0;
  summary.cfg_cycles = sched.cycles(cfg_clk);
  summary.sim_time_ps = sched.time();
  // "beats" for this test are register transactions: the count that makes two
  // runs of one seed comparable.
  summary.beats_driven = driver.transactions() + stuck.transactions();
  summary.beats_observed = driver.transactions() + stuck.transactions();
  summary.trace_path = trace_path;
  summary.absorb(errors);
  summary.wall_time_s =
      std::chrono::duration<double>(wall_end - wall_start).count();

  const std::string written = summary.write(args.results_dir);

  std::printf("--- summary ---\n");
  std::printf("  registers      : %zu in %u implemented blocks (%u declared)\n",
              regmap::kRegisterTableSize, regmap::kBlockCountImplemented,
              regmap::kBlockCount);
  std::printf("  transactions   : %llu (%llu reads, %llu writes, %llu error responses)\n",
              static_cast<unsigned long long>(driver.transactions()),
              static_cast<unsigned long long>(driver.reads()),
              static_cast<unsigned long long>(driver.writes()),
              static_cast<unsigned long long>(driver.error_responses()));
  std::printf("  watchdog port  : %llu transactions, %llu rescued by the watchdog "
              "(dead block saw %llu)\n",
              static_cast<unsigned long long>(stuck.transactions()),
              static_cast<unsigned long long>(stuck.error_responses()),
              static_cast<unsigned long long>(watchdog_swallowed));
  std::printf("  cfg cycles     : %llu\n",
              static_cast<unsigned long long>(sched.cycles(cfg_clk)));
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
