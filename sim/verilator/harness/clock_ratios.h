// -----------------------------------------------------------------------------
// clock_ratios.h — the CDC clock-ratio sweep (SPEC.md 8, 12.3, 13.1).
//
// A clock-domain crossing that works at one frequency ratio tells you almost
// nothing. The defects live at the ratios where the pointer synchronizers' view
// of the other domain is most stale, where one domain's edges land arbitrarily
// close to the other's, and where the two drift slowly past each other rather
// than repeating a short pattern. This table is the set of ratios every CDC unit
// test sweeps, chosen so each entry covers a distinct hazard:
//
//   1:1 in phase     the degenerate case, and the one where a defect that
//                    depends on simultaneous edges shows up.
//   1:1 offset       same frequency, edges interleaved. A crossing that happens
//                    to work because both domains sample at the same instant
//                    fails here and nowhere else.
//   2:1 and 1:2      integer ratios in both directions, so both the "source
//                    faster" and "destination faster" staleness cases are hit.
//                    They are not symmetric: full is derived in the write domain
//                    and empty in the read domain.
//   7:3 and 3:7      non-integer ratios with a short repeat, which is where the
//                    edge alignment sweeps through every relative phase quickly.
//   100:99           a near-unity ratio with a very long repeat. The two clocks
//                    drift past each other over hundreds of cycles, so the
//                    crossing is exercised at a continuum of relative phases
//                    within one pass rather than at the handful a short repeat
//                    revisits. This is the case that catches a flag derivation
//                    which is correct except in a narrow alignment window.
//
// Everything is expressed as an integer half period in picoseconds, so the
// scheduler's edge times are exact and a run is bit-reproducible (SPEC 12.3:
// "integer simulation time units that represent all selected clock periods
// exactly enough for CDC testing"). No frequency here is one of the SPEC 8
// nominal frequencies, on purpose: the property under test is the crossing, and
// pinning the sweep to six named frequencies would fix the ratios at exactly the
// values least likely to expose a synchronizer defect. The nominal SPEC 8 pairs
// are exercised where those domains actually meet, in the pipeline integration
// tests.
//
// Header-only: it is a table and two accessors, and every CDC test includes it.
// -----------------------------------------------------------------------------
#ifndef HARNESS_CLOCK_RATIOS_H_
#define HARNESS_CLOCK_RATIOS_H_

#include <cstddef>
#include <vector>

#include "harness/sim_time.h"

namespace harness {

struct ClockRatio {
  const char* name;
  // Half periods, in picoseconds. Domain A and domain B.
  SimTime half_a;
  SimTime half_b;
  // Time of each clock's first edge. Equal values mean the two domains start in
  // phase; different values introduce a fixed phase offset.
  SimTime first_a;
  SimTime first_b;

  double ratio_a_over_b() const {
    return static_cast<double>(half_b) / static_cast<double>(half_a);
  }
};

// The sweep, in a fixed order. Deterministic by construction: no entry depends
// on a seed, so the same seed replays the same edge sequence.
inline const std::vector<ClockRatio>& clock_ratios() {
  static const std::vector<ClockRatio> table = {
      // name             half_a  half_b  first_a  first_b
      {"1to1_in_phase",     1000,   1000,    1000,    1000},
      {"1to1_offset",       1000,   1000,    1000,    1500},
      {"2to1_a_fast",       1000,   2000,    1000,    2000},
      {"1to2_b_fast",       2000,   1000,    2000,    1000},
      {"7to3_a_fast",       3000,   7000,    3000,    7000},
      {"3to7_b_fast",       7000,   3000,    7000,    3000},
      {"100to99_drift",      990,   1000,     990,    1000},
  };
  return table;
}

// The slower of the two half periods, for sizing a time limit that has to cover
// a fixed number of cycles of whichever domain is slowest.
inline SimTime slowest_half(const ClockRatio& r) {
  return r.half_a > r.half_b ? r.half_a : r.half_b;
}

}  // namespace harness

#endif  // HARNESS_CLOCK_RATIOS_H_
