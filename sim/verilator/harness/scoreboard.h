// -----------------------------------------------------------------------------
// scoreboard.h — transaction-identity scoreboard (SPEC.md 12.5).
//
// SPEC 12.5 is explicit that a fixed end-to-end latency must not be assumed once
// elastic buffering exists, and that checking is done on transaction identity:
//
//     stream_id / frame_id / sequence / antenna / frequency_bin / beam
//
// At Phase 0 the identity is the subset the provisional bundle carries —
// (stream_id, frame_id, sequence). The remaining fields are named in
// TransactionId::kFutureFields so the widening in issues #10-#14 is a field
// addition, not a redesign.
//
// Model: one expected-transaction queue per stream_id, plus a retired-identity
// set. That combination is what separates the four failure modes SPEC 12.5
// requires distinguishing:
//
//   loss        an identity still queued when the run drains
//   duplicate   an identity observed after it was already retired
//   order       an identity observed while a different one is at its queue head
//   content     the identity matched but a payload field differs
//
// Bounded latency (SPEC 12.5) is checked as cycles between the beat being
// accepted by the DUT and the beat being observed at the output, against a
// caller-supplied bound. Latency is *reported*, never used to key the match —
// PLAN.md standing rule #5.
// -----------------------------------------------------------------------------
#ifndef HARNESS_SCOREBOARD_H_
#define HARNESS_SCOREBOARD_H_

#include <cstdint>
#include <deque>
#include <map>
#include <set>
#include <string>

#include "harness/error_collector.h"
#include "harness/stream_types.h"

namespace harness {

struct TransactionId {
  std::uint32_t stream_id = 0;
  std::uint32_t frame_id = 0;
  std::uint32_t sequence = 0;

  // SPEC 12.5 identity fields not carried by the Phase 0 provisional bundle.
  // Added by the issues that introduce the corresponding datapath dimension:
  // antenna (#10), frequency_bin (#11), beam (#12).
  static constexpr const char* kFutureFields = "antenna,frequency_bin,beam";

  bool operator<(const TransactionId& o) const {
    if (stream_id != o.stream_id) return stream_id < o.stream_id;
    if (frame_id != o.frame_id) return frame_id < o.frame_id;
    return sequence < o.sequence;
  }
  bool operator==(const TransactionId& o) const {
    return stream_id == o.stream_id && frame_id == o.frame_id &&
           sequence == o.sequence;
  }
  std::string to_string() const;
};

struct ScoreboardStats {
  std::uint64_t expected = 0;
  std::uint64_t observed = 0;
  std::uint64_t matched = 0;
  std::uint64_t lost = 0;
  std::uint64_t duplicated = 0;
  std::uint64_t misordered = 0;
  std::uint64_t content_mismatch = 0;
  std::uint64_t unexpected = 0;      // observed identity never expected
  std::uint64_t latency_violation = 0;
  std::uint64_t latency_min = 0;
  std::uint64_t latency_max = 0;
  std::uint64_t latency_sum = 0;

  bool clean() const {
    return lost == 0 && duplicated == 0 && misordered == 0 &&
           content_mismatch == 0 && unexpected == 0 && latency_violation == 0;
  }
  double latency_mean() const {
    return matched ? static_cast<double>(latency_sum) /
                         static_cast<double>(matched)
                   : 0.0;
  }
};

class Scoreboard {
 public:
  Scoreboard(std::string name, ErrorCollector& errors);

  // Maximum permitted output-minus-input latency, in cycles of the output
  // clock. 0 disables the check.
  void set_latency_bound(std::uint64_t cycles) { latency_bound_ = cycles; }

  // Records what the DUT was given, at the cycle it was accepted.
  void expect(const TransactionId& id, const StreamBeat& beat,
              std::uint64_t cycle);
  // Records what the DUT produced, at the cycle it was observed.
  void observe(const TransactionId& id, const StreamBeat& beat,
               std::uint64_t cycle);

  // Every still-queued identity is a lost transaction. Call once the run has
  // drained; safe to call more than once (each queue is emptied as reported).
  void finalize();

  void reset();

  const ScoreboardStats& stats() const { return stats_; }
  const std::string& name() const { return name_; }
  // Identities expected but not yet observed, across all streams.
  std::size_t outstanding() const;

 private:
  struct Entry {
    TransactionId id;
    StreamBeat beat;
    std::uint64_t cycle = 0;
  };

  void note_latency(std::uint64_t in_cycle, std::uint64_t out_cycle,
                    const TransactionId& id);

  std::string name_;
  ErrorCollector& errors_;
  // std::map keeps stream iteration deterministic for finalize()'s error order.
  std::map<std::uint32_t, std::deque<Entry>> expected_;
  std::set<TransactionId> retired_;
  ScoreboardStats stats_;
  std::uint64_t latency_bound_ = 0;
  bool have_latency_ = false;
};

}  // namespace harness

#endif  // HARNESS_SCOREBOARD_H_
