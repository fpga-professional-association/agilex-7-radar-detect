// -----------------------------------------------------------------------------
// sim_time.h — simulation time base for the C++ harness (SPEC.md 12.3).
//
// SPEC 12.3 requires "integer simulation time units that represent all selected
// clock periods exactly enough for CDC testing". The harness uses picoseconds:
// a 64-bit picosecond counter spans ~213 days of simulated time, and every
// SPEC 8 clock lands within 25 ppm of its nominal frequency (see
// realized_mhz()). No floating point is ever used to advance time.
//
// Clocks are described by their *half* period so that the toggle sequence is
// exact by construction; a clock's period is 2 * half_period_ps and can never
// drift by accumulating a rounded half.
// -----------------------------------------------------------------------------
#ifndef HARNESS_SIM_TIME_H_
#define HARNESS_SIM_TIME_H_

#include <cstdint>

namespace harness {

// Absolute simulation time, in picoseconds.
using SimTime = std::uint64_t;

inline constexpr SimTime kPs = 1;
inline constexpr SimTime kNs = 1000;
inline constexpr SimTime kUs = 1000 * kNs;

// Half period, in whole picoseconds, of a clock of `mhz` MHz, rounded to
// nearest. 450 MHz -> 1111 ps (realized 450.045 MHz, +100 ppm); 400 MHz ->
// 1250 ps (exact); 100 MHz -> 5000 ps (exact); 200 MHz -> 2500 ps (exact);
// 350 MHz -> 1429 ps (realized 349.895 MHz, -300 ppm). The residual error is
// far below anything a CDC test can observe, and it is deterministic.
constexpr SimTime half_period_ps(double mhz) {
  // 1e6 ps per us; half period in ps = 1e6 / (2 * mhz).
  return static_cast<SimTime>((1.0e6 / (2.0 * mhz)) + 0.5);
}

// Frequency a given half period actually realizes, for run-log reporting.
constexpr double realized_mhz(SimTime half_ps) {
  return 1.0e6 / (2.0 * static_cast<double>(half_ps));
}

// SPEC 8 clock domains. Only core_clk and cfg_clk are instantiated at Phase 0;
// the rest are listed here so later issues add domains without re-deriving the
// numbers.
inline constexpr double kCoreClkMhz      = 450.0;
inline constexpr double kHistoryClkMhz   = 400.0;
inline constexpr double kPacketClkMhz    = 400.0;
inline constexpr double kMemoryClkMhz    = 350.0;
inline constexpr double kCfgClkMhz       = 100.0;
inline constexpr double kTelemetryClkMhz = 200.0;

}  // namespace harness

#endif  // HARNESS_SIM_TIME_H_
