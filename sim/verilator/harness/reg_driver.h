// -----------------------------------------------------------------------------
// reg_driver.h — register read/write for the C++ harness (SPEC.md 12.2, #7).
//
// The line harness.h has carried since issue #2 — "register reads and writes:
// issue #7" — filled in. A RegDriver speaks the SPEC 9 protocol defined in
// rtl/control/reg_if_pkg.sv against any DUT that brings the eight signals to its
// boundary, and it is bound to those signals through a RegPort of pointers, so
// the harness library still never includes a Verilated model header.
//
// Blocking, and integrated with the clock scheduler
// ------------------------------------------------
// `write()` and `read()` return when the transaction has completed. They do that
// by pumping the scheduler themselves, one edge at a time, which is what makes a
// test read like the software it stands in for:
//
//     driver.write(regmap::SCRATCH_SCRATCH0_ADDR, 0xA5A5A5A5u);
//     const RegResult r = driver.read(regmap::SCRATCH_SCRATCH0_ADDR);
//
// while every other harness component registered on that clock — monitors, the
// timeout guard, the trace writer — keeps running underneath. The driver applies
// stimulus in Phase::kDrive and samples `ready` in Phase::kSample, the same split
// StreamDriver uses and for the same reason: sampling before the toggle observes
// exactly what the DUT is about to capture.
//
// Protocol obligations, structural rather than checked afterwards
// --------------------------------------------------------------
//   * the request is applied once and held bit-stable until `ready` is observed,
//     so the master half of the protocol cannot be violated by a test;
//   * exactly one request is outstanding at a time;
//   * the request is dropped in the drive phase of the response edge, so a
//     transaction is never issued twice.
// The RTL-side checker (sim/assertions/reg_if_checker.sv) verifies all three
// from inside the fabric, so a defect here is reported rather than believed.
//
// Never hangs
// -----------
// Every transaction carries a cycle budget. If it is exhausted the driver
// records an error, marks the result timed out and returns — it does not spin.
// A register plane that stops answering therefore fails the test with a
// register-plane message instead of running the whole simulation into the
// global timeout with nothing to point at.
//
// Illegal transactions are first-class: `transact()` will drive both enables at
// once, a zero byte-enable write, or an unaligned address on purpose, because
// the error responses those produce are part of the specification and have to be
// testable.
// -----------------------------------------------------------------------------
#ifndef HARNESS_REG_DRIVER_H_
#define HARNESS_REG_DRIVER_H_

#include <cstdint>
#include <string>

#include "harness/clock_scheduler.h"
#include "harness/error_collector.h"
#include "regmap/regmap.hpp"

namespace harness {

// The DUT's SPEC 9 master port. Widths follow Verilator's mapping of the port
// declarations in sim/verilator/tops/control_top.sv: 16-bit address -> SData,
// 32-bit data -> IData, everything narrow -> CData.
struct RegPort {
  std::uint16_t* address = nullptr;
  std::uint32_t* write_data = nullptr;
  std::uint8_t* byte_enable = nullptr;
  std::uint8_t* write_enable = nullptr;
  std::uint8_t* read_enable = nullptr;
  const std::uint32_t* read_data = nullptr;
  const std::uint8_t* ready = nullptr;
  const std::uint8_t* error = nullptr;
};

struct RegResult {
  std::uint32_t data = 0;      // read data in the response cycle (0 for writes)
  bool error = false;          // the DUT's error flag in the response cycle
  bool timed_out = false;      // no response within the cycle budget
  std::uint64_t cycles = 0;    // request cycle to response cycle, inclusive

  // A completed transaction that the DUT did not reject.
  bool ok() const { return !timed_out && !error; }
};

class RegDriver {
 public:
  RegDriver(std::string name, RegPort port, ClockScheduler& sched, int clk,
            ErrorCollector& errors);

  // Cycles a single transaction may take before it is declared hung. The
  // default is far above the fabric's own watchdog bound, so a driver timeout
  // means the fabric failed to bound the access, not that the budget was tight.
  void set_max_cycles(std::uint64_t cycles) { max_cycles_ = cycles; }

  // Drops the driven signals and abandons any in-flight request. Call around a
  // reset, exactly as StreamDriver::reset is called.
  void reset();

  // ---- transactions ------------------------------------------------------
  RegResult write(std::uint32_t address, std::uint32_t data,
                  std::uint8_t byte_enable = 0xF);
  RegResult read(std::uint32_t address);

  // The unrestricted form. Any combination of enables, byte enables and address
  // alignment, including the illegal ones the error responses are specified for.
  RegResult transact(std::uint32_t address, bool write_enable, bool read_enable,
                     std::uint32_t data, std::uint8_t byte_enable);

  // ---- field access, against the generated regmap.hpp constants ----------
  // read_field(ADDR, FIELD_LSB, FIELD_WIDTH) and the read-modify-write form.
  // The RMW is two transactions and is not atomic — nothing else drives this
  // port, and pretending otherwise would hide that from a future multi-master
  // design.
  std::uint32_t read_field(std::uint32_t address, unsigned lsb, unsigned width,
                           RegResult* result = nullptr);
  RegResult write_field(std::uint32_t address, unsigned lsb, unsigned width,
                        std::uint32_t value);

  // ---- statistics --------------------------------------------------------
  std::uint64_t transactions() const { return transactions_; }
  std::uint64_t writes() const { return writes_; }
  std::uint64_t reads() const { return reads_; }
  std::uint64_t error_responses() const { return error_responses_; }
  std::uint64_t timeouts() const { return timeouts_; }
  std::uint64_t max_response_cycles() const { return max_cycles_seen_; }
  const std::string& name() const { return name_; }

  // "id.MAGIC (0x0000)" for a mapped address, "0x5004 (unmapped)" otherwise.
  // Used in every failure message so a report names a register, not a number.
  static std::string describe(std::uint32_t address);

  // Scheduler callbacks. Registered by the constructor; public so a test can see
  // the wiring it gets rather than having it happen invisibly.
  void on_sample();
  void on_drive();

 private:
  void apply_pins();
  void clear_pins();

  std::string name_;
  RegPort port_;
  ClockScheduler& sched_;
  int clk_;
  ErrorCollector& errors_;

  // In-flight request.
  std::uint32_t addr_ = 0;
  std::uint32_t wdata_ = 0;
  std::uint8_t be_ = 0;
  bool we_ = false;
  bool re_ = false;
  bool active_ = false;   // a transaction is in progress
  bool applied_ = false;  // the request has reached the pins
  bool done_ = false;     // ready observed
  std::uint64_t cycles_ = 0;
  RegResult result_;

  std::uint64_t max_cycles_ = 64;
  std::uint64_t transactions_ = 0;
  std::uint64_t writes_ = 0;
  std::uint64_t reads_ = 0;
  std::uint64_t error_responses_ = 0;
  std::uint64_t timeouts_ = 0;
  std::uint64_t max_cycles_seen_ = 0;
};

}  // namespace harness

#endif  // HARNESS_REG_DRIVER_H_
