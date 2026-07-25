#include "harness/reg_driver.h"

#include <cstdio>
#include <utility>

namespace harness {

RegDriver::RegDriver(std::string name, RegPort port, ClockScheduler& sched,
                     int clk, ErrorCollector& errors)
    : name_(std::move(name)),
      port_(port),
      sched_(sched),
      clk_(clk),
      errors_(errors) {
  clear_pins();
  sched_.on_posedge_sample(clk_, [this]() { on_sample(); });
  sched_.on_posedge_drive(clk_, [this]() { on_drive(); });
}

void RegDriver::clear_pins() {
  if (port_.write_enable != nullptr) *port_.write_enable = 0;
  if (port_.read_enable != nullptr) *port_.read_enable = 0;
  if (port_.address != nullptr) *port_.address = 0;
  if (port_.write_data != nullptr) *port_.write_data = 0;
  if (port_.byte_enable != nullptr) *port_.byte_enable = 0;
}

void RegDriver::apply_pins() {
  *port_.address = static_cast<std::uint16_t>(addr_);
  *port_.write_data = wdata_;
  *port_.byte_enable = static_cast<std::uint8_t>(be_ & 0xF);
  *port_.write_enable = we_ ? 1 : 0;
  *port_.read_enable = re_ ? 1 : 0;
}

void RegDriver::reset() {
  active_ = false;
  applied_ = false;
  done_ = false;
  cycles_ = 0;
  clear_pins();
}

// Sample phase: pre-toggle, so `ready` is read exactly as the DUT is presenting
// it for this edge. A response observed here belongs to the request that has
// been on the pins since the previous drive phase.
void RegDriver::on_sample() {
  if (!active_ || !applied_ || done_) return;
  if (*port_.ready != 0) {
    result_.data = *port_.read_data;
    result_.error = (*port_.error != 0);
    result_.cycles = cycles_;
    done_ = true;
  }
}

// Drive phase: post-toggle. Either present the request (and hold it bit-stable
// for the whole cycle) or drop it, in the same edge in which the response was
// sampled, so no transaction is ever issued twice.
void RegDriver::on_drive() {
  if (!active_) {
    clear_pins();
    return;
  }
  if (done_) {
    clear_pins();
    active_ = false;
    applied_ = false;
    return;
  }
  apply_pins();
  applied_ = true;
  ++cycles_;
}

RegResult RegDriver::transact(std::uint32_t address, bool write_enable,
                              bool read_enable, std::uint32_t data,
                              std::uint8_t byte_enable) {
  addr_ = address;
  wdata_ = data;
  be_ = byte_enable;
  we_ = write_enable;
  re_ = read_enable;
  active_ = true;
  applied_ = false;
  done_ = false;
  cycles_ = 0;
  result_ = RegResult{};

  // Per-transaction wall, in simulated time, well clear of the cycle budget.
  // Two limits rather than one because they fail differently: the cycle budget
  // catches a plane that stops answering, the time limit catches a scheduler
  // that stops advancing.
  const SimTime limit =
      sched_.time() + (max_cycles_ + 8) * 2 * sched_.half_period(clk_);

  while (!done_) {
    if (cycles_ > max_cycles_) {
      result_.timed_out = true;
      result_.cycles = cycles_;
      ++timeouts_;
      errors_.error("reg_timeout",
                    name_ + ": no response to " + (write_enable ? "write" : "read") +
                        " " + describe(address) + " after " +
                        std::to_string(cycles_) + " cycles");
      break;
    }
    if (sched_.run_cycles(clk_, 1, limit) != StopReason::kRunning) {
      // The scheduler was stopped by something else (a pass, a failure, the
      // global timeout guard). Report the transaction as incomplete and let the
      // test decide; do not keep pumping a stopped scheduler.
      result_.timed_out = true;
      result_.cycles = cycles_;
      ++timeouts_;
      break;
    }
  }

  // Whatever happened, stop driving.
  active_ = false;
  applied_ = false;
  clear_pins();

  ++transactions_;
  if (write_enable) ++writes_;
  if (read_enable) ++reads_;
  if (result_.error) ++error_responses_;
  if (result_.cycles > max_cycles_seen_) max_cycles_seen_ = result_.cycles;
  return result_;
}

RegResult RegDriver::write(std::uint32_t address, std::uint32_t data,
                           std::uint8_t byte_enable) {
  return transact(address, true, false, data, byte_enable);
}

RegResult RegDriver::read(std::uint32_t address) {
  return transact(address, false, true, 0, 0xF);
}

std::uint32_t RegDriver::read_field(std::uint32_t address, unsigned lsb,
                                    unsigned width, RegResult* result) {
  const RegResult r = read(address);
  if (result != nullptr) *result = r;
  if (!r.ok()) return 0;
  return regmap::field_get(r.data, lsb, width);
}

RegResult RegDriver::write_field(std::uint32_t address, unsigned lsb,
                                 unsigned width, std::uint32_t value) {
  const RegResult rd = read(address);
  if (!rd.ok()) return rd;
  return write(address, regmap::field_set(rd.data, lsb, width, value));
}

std::string RegDriver::describe(std::uint32_t address) {
  char buf[64];
  const regmap::RegInfo* info = regmap::find(address);
  if (info != nullptr) {
    std::snprintf(buf, sizeof(buf), "%s.%s (0x%04X)", info->block, info->name,
                  address);
    return std::string(buf);
  }
  std::snprintf(buf, sizeof(buf), "0x%04X (unmapped)", address);
  return std::string(buf);
}

}  // namespace harness
