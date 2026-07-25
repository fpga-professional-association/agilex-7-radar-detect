#include "harness/error_collector.h"

#include <algorithm>
#include <cstdio>
#include <utility>

namespace harness {

void ErrorCollector::error(std::string category, std::string message) {
  ErrorEntry e;
  e.category = std::move(category);
  e.message = std::move(message);
  e.sim_time_ps = now_ps_ ? *now_ps_ : 0;

  if (printed_ < print_limit_) {
    std::fprintf(stderr, "ERROR [%s] @%llu ps: %s\n", e.category.c_str(),
                 static_cast<unsigned long long>(e.sim_time_ps),
                 e.message.c_str());
    ++printed_;
    if (printed_ == print_limit_) {
      std::fprintf(stderr,
                   "ERROR: print limit (%zu) reached; further errors are "
                   "counted but not printed\n",
                   print_limit_);
    }
  }
  entries_.push_back(std::move(e));
}

std::size_t ErrorCollector::count_of(const std::string& category) const {
  return static_cast<std::size_t>(std::count_if(
      entries_.begin(), entries_.end(),
      [&](const ErrorEntry& e) { return e.category == category; }));
}

std::vector<std::pair<std::string, std::size_t>> ErrorCollector::by_category()
    const {
  std::vector<std::pair<std::string, std::size_t>> out;
  for (const ErrorEntry& e : entries_) {
    auto it = std::find_if(out.begin(), out.end(),
                           [&](const auto& p) { return p.first == e.category; });
    if (it == out.end()) {
      out.emplace_back(e.category, 1);
    } else {
      ++it->second;
    }
  }
  return out;
}

}  // namespace harness
