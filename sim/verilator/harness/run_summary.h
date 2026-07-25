// -----------------------------------------------------------------------------
// run_summary.h — machine-readable run record under results/simulation/.
//
// SPEC 27 requires an evidence package assembled from machine-readable results;
// PLAN.md standing rule #3 forbids committing generated files, so these land in
// results/simulation/ (gitignored) and are collected by the regression tooling.
//
// Determinism contract
// --------------------
// Every field except `wall_time_s` is a pure function of (seed, config, build
// mode, test). Two runs of the same seed produce byte-identical JSON apart from
// that one line. This is a gate for issue #2 and the property that makes
// "reproduce the failing seed" meaningful, so:
//   * keys are emitted in a fixed order, never from a hash map,
//   * no timestamps, host names, paths outside the repo, or pointer values,
//   * `wall_time_s` is written last and is the only measured quantity.
//
// The writer is hand-rolled rather than pulling in a JSON dependency: the schema
// is fixed and small, and a dependency would have to be vendored for a clean
// checkout to build (SPEC 16).
// -----------------------------------------------------------------------------
#ifndef HARNESS_RUN_SUMMARY_H_
#define HARNESS_RUN_SUMMARY_H_

#include <cstdint>
#include <string>
#include <utility>
#include <vector>

#include "harness/error_collector.h"
#include "harness/scoreboard.h"

namespace harness {

struct RunSummary {
  // Identity of the run.
  std::string test_name;
  std::string config_name;
  std::string build_mode;
  std::uint64_t seed = 0;
  int schema_version = 1;

  // Outcome.
  bool passed = false;
  std::string stop_reason;
  std::string stop_detail;

  // Simulation extent.
  std::uint64_t core_cycles = 0;
  std::uint64_t cfg_cycles = 0;
  std::uint64_t sim_time_ps = 0;
  std::uint64_t passes = 0;

  // Traffic.
  std::uint64_t beats_driven = 0;
  std::uint64_t beats_observed = 0;
  std::uint64_t frames_driven = 0;
  std::uint64_t frames_observed = 0;

  ScoreboardStats scoreboard;

  // Errors: total, then per-category counts in first-seen order.
  std::uint64_t error_count = 0;
  std::vector<std::pair<std::string, std::size_t>> errors_by_category;
  // Up to kMaxRecordedErrors messages, for triage without the log.
  std::vector<std::string> error_messages;
  static constexpr std::size_t kMaxRecordedErrors = 10;

  std::string trace_path;  // empty when not tracing

  // The only non-deterministic field. Always emitted last.
  double wall_time_s = 0.0;

  void absorb(const ErrorCollector& errors);

  std::string to_json() const;
  // Writes <dir>/<test_name>_<config_name>_seed<seed>.json, creating `dir`.
  // Returns the path written, or an empty string on failure.
  std::string write(const std::string& dir) const;
};

}  // namespace harness

#endif  // HARNESS_RUN_SUMMARY_H_
