// -----------------------------------------------------------------------------
// harness.h — umbrella include for the Phase 0 C++ simulation harness.
//
// SPEC 12.2 lists what the harness must provide. Coverage as of issue #2:
//
//   multiple clock generation      clock_scheduler.h
//   event scheduling               clock_scheduler.h
//   reset sequencing               reset_sequencer.h
//   stream drivers                 stream_driver.h
//   randomized backpressure        random.h  (BackpressureGenerator)
//   scoreboards                    scoreboard.h
//   timeout detection              timeout.h
//   assertion and error collection error_collector.h
//   failure minimization metadata  run_summary.h  (seed + per-category errors)
//   optional FST tracing           trace.h
//   deterministic random seeds     random.h  (SeedSource)
//
// Not yet provided, and owned elsewhere by design:
//
//   register reads and writes      issue #7 (register/control plane)
//   memory model                   issue #15 / #24 (history memory, HBM2e)
//   reference-model invocation     issue #4 (bit-accurate C++ model)
//
// Include this from tests; include the individual headers from harness sources.
// -----------------------------------------------------------------------------
#ifndef HARNESS_HARNESS_H_
#define HARNESS_HARNESS_H_

#include "harness/clock_scheduler.h"
#include "harness/error_collector.h"
#include "harness/random.h"
#include "harness/reset_sequencer.h"
#include "harness/run_summary.h"
#include "harness/scoreboard.h"
#include "harness/sim_args.h"
#include "harness/sim_time.h"
#include "harness/stream_driver.h"
#include "harness/stream_monitor.h"
#include "harness/stream_types.h"
#include "harness/timeout.h"
#include "harness/trace.h"

#endif  // HARNESS_HARNESS_H_
