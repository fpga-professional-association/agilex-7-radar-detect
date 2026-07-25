#include "harness/scoreboard.h"

#include <algorithm>
#include <utility>

namespace harness {

std::string TransactionId::to_string() const {
  return "{stream=" + std::to_string(stream_id) +
         " frame=" + std::to_string(frame_id) +
         " seq=" + std::to_string(sequence) + "}";
}

Scoreboard::Scoreboard(std::string name, ErrorCollector& errors)
    : name_(std::move(name)), errors_(errors) {}

void Scoreboard::expect(const TransactionId& id, const StreamBeat& beat,
                        std::uint64_t cycle) {
  expected_[id.stream_id].push_back(Entry{id, beat, cycle});
  ++stats_.expected;
}

void Scoreboard::note_latency(std::uint64_t in_cycle, std::uint64_t out_cycle,
                              const TransactionId& id) {
  const std::uint64_t lat = out_cycle >= in_cycle ? out_cycle - in_cycle : 0;
  if (!have_latency_) {
    stats_.latency_min = lat;
    stats_.latency_max = lat;
    have_latency_ = true;
  } else {
    stats_.latency_min = std::min(stats_.latency_min, lat);
    stats_.latency_max = std::max(stats_.latency_max, lat);
  }
  stats_.latency_sum += lat;
  if (latency_bound_ != 0 && lat > latency_bound_) {
    ++stats_.latency_violation;
    errors_.error("latency", name_ + ": " + id.to_string() + " latency " +
                                 std::to_string(lat) + " cycles exceeds bound " +
                                 std::to_string(latency_bound_));
  }
}

void Scoreboard::observe(const TransactionId& id, const StreamBeat& beat,
                         std::uint64_t cycle) {
  ++stats_.observed;

  if (retired_.count(id) != 0) {
    ++stats_.duplicated;
    errors_.error("duplicate",
                  name_ + ": " + id.to_string() + " observed again");
    return;
  }

  auto qit = expected_.find(id.stream_id);
  if (qit == expected_.end() || qit->second.empty()) {
    ++stats_.unexpected;
    errors_.error("unexpected", name_ + ": " + id.to_string() +
                                    " observed with no outstanding expectation "
                                    "on that stream");
    return;
  }

  std::deque<Entry>& q = qit->second;
  if (!(q.front().id == id)) {
    // Ordering is required on a single stream (SPEC 5: sequence numbers permit
    // ordering checks). Look further down the queue: finding it there is a
    // reorder; not finding it is an unexpected transaction.
    auto found = std::find_if(q.begin(), q.end(), [&](const Entry& e) {
      return e.id == id;
    });
    if (found == q.end()) {
      ++stats_.unexpected;
      errors_.error("unexpected", name_ + ": " + id.to_string() +
                                      " not among outstanding expectations");
      return;
    }
    ++stats_.misordered;
    errors_.error("order", name_ + ": " + id.to_string() +
                               " arrived out of order; head of queue is " +
                               q.front().id.to_string());
    // Consume it where it was found so the run keeps checking the rest.
    const Entry e = *found;
    q.erase(found);
    retired_.insert(id);
    if (e.beat != beat) {
      ++stats_.content_mismatch;
      errors_.error("content", name_ + ": " + id.to_string() +
                                   " payload mismatch; expected " +
                                   e.beat.to_string() + ", observed " +
                                   beat.to_string());
    }
    note_latency(e.cycle, cycle, id);
    return;
  }

  const Entry e = q.front();
  q.pop_front();
  retired_.insert(id);

  if (e.beat != beat) {
    ++stats_.content_mismatch;
    errors_.error("content", name_ + ": " + id.to_string() +
                                 " payload mismatch; expected " +
                                 e.beat.to_string() + ", observed " +
                                 beat.to_string());
  } else {
    ++stats_.matched;
  }
  note_latency(e.cycle, cycle, id);
}

void Scoreboard::finalize() {
  for (auto& kv : expected_) {
    while (!kv.second.empty()) {
      const Entry e = kv.second.front();
      kv.second.pop_front();
      ++stats_.lost;
      errors_.error("loss", name_ + ": " + e.id.to_string() +
                                " never observed (accepted at cycle " +
                                std::to_string(e.cycle) + ")");
    }
  }
}

void Scoreboard::reset() {
  expected_.clear();
  retired_.clear();
  stats_ = ScoreboardStats{};
  have_latency_ = false;
}

std::size_t Scoreboard::outstanding() const {
  std::size_t n = 0;
  for (const auto& kv : expected_) n += kv.second.size();
  return n;
}

}  // namespace harness
