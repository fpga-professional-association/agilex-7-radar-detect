// -----------------------------------------------------------------------------
// error_collector.h — assertion and error collection (SPEC.md 12.2).
//
// One collector per run. Every harness component reports through it instead of
// aborting, so a single run surfaces the whole failure pattern (e.g. "one lost
// beat, then 40 misordered") rather than only the first symptom, which is what
// makes SPEC 13.3 failure minimisation tractable.
//
// Errors carry a category so the JSON run summary and later triage tooling can
// group them without parsing free text. Printing is capped (default 20 per run)
// because a broken handshake can otherwise emit one line per cycle.
// -----------------------------------------------------------------------------
#ifndef HARNESS_ERROR_COLLECTOR_H_
#define HARNESS_ERROR_COLLECTOR_H_

#include <cstddef>
#include <cstdint>
#include <string>
#include <utility>
#include <vector>

namespace harness {

struct ErrorEntry {
  std::string category;  // e.g. "loss", "duplicate", "order", "content"
  std::string message;
  std::uint64_t sim_time_ps = 0;
};

class ErrorCollector {
 public:
  void set_time_probe(const std::uint64_t* now_ps) { now_ps_ = now_ps; }
  void set_print_limit(std::size_t n) { print_limit_ = n; }

  void error(std::string category, std::string message);

  bool ok() const { return entries_.empty(); }
  std::size_t count() const { return entries_.size(); }
  std::size_t count_of(const std::string& category) const;
  const std::vector<ErrorEntry>& entries() const { return entries_; }

  // Number of errors by category, in first-seen order (deterministic).
  std::vector<std::pair<std::string, std::size_t>> by_category() const;

  void clear() { entries_.clear(); printed_ = 0; }

 private:
  std::vector<ErrorEntry> entries_;
  const std::uint64_t* now_ps_ = nullptr;
  std::size_t print_limit_ = 20;
  std::size_t printed_ = 0;
};

}  // namespace harness

#endif  // HARNESS_ERROR_COLLECTOR_H_
