#include "harness/run_summary.h"

#include <cstdio>
#include <filesystem>
#include <sstream>

namespace harness {
namespace {

std::string json_escape(const std::string& s) {
  std::string out;
  out.reserve(s.size() + 8);
  for (char c : s) {
    switch (c) {
      case '"':  out += "\\\""; break;
      case '\\': out += "\\\\"; break;
      case '\n': out += "\\n";  break;
      case '\r': out += "\\r";  break;
      case '\t': out += "\\t";  break;
      default:
        if (static_cast<unsigned char>(c) < 0x20) {
          char buf[8];
          std::snprintf(buf, sizeof(buf), "\\u%04x",
                        static_cast<unsigned>(static_cast<unsigned char>(c)));
          out += buf;
        } else {
          out += c;
        }
    }
  }
  return out;
}

void kv_str(std::ostringstream& o, const char* k, const std::string& v,
            const char* indent, bool comma = true) {
  o << indent << '"' << k << "\": \"" << json_escape(v) << '"'
    << (comma ? "," : "") << '\n';
}

void kv_u64(std::ostringstream& o, const char* k, std::uint64_t v,
            const char* indent, bool comma = true) {
  o << indent << '"' << k << "\": " << v << (comma ? "," : "") << '\n';
}

void kv_bool(std::ostringstream& o, const char* k, bool v, const char* indent,
             bool comma = true) {
  o << indent << '"' << k << "\": " << (v ? "true" : "false")
    << (comma ? "," : "") << '\n';
}

// Fixed 6-decimal formatting: identical text for identical values on any libc.
void kv_fixed(std::ostringstream& o, const char* k, double v,
              const char* indent, bool comma = true) {
  char buf[64];
  std::snprintf(buf, sizeof(buf), "%.6f", v);
  o << indent << '"' << k << "\": " << buf << (comma ? "," : "") << '\n';
}

}  // namespace

void RunSummary::absorb(const ErrorCollector& errors) {
  error_count = errors.count();
  errors_by_category = errors.by_category();
  error_messages.clear();
  for (const ErrorEntry& e : errors.entries()) {
    if (error_messages.size() >= kMaxRecordedErrors) break;
    error_messages.push_back("[" + e.category + "] @" +
                             std::to_string(e.sim_time_ps) + "ps " + e.message);
  }
}

std::string RunSummary::to_json() const {
  std::ostringstream o;
  const char* i1 = "  ";
  const char* i2 = "    ";

  o << "{\n";
  kv_u64(o, "schema_version", static_cast<std::uint64_t>(schema_version), i1);
  kv_str(o, "test_name", test_name, i1);
  kv_str(o, "config", config_name, i1);
  kv_str(o, "build_mode", build_mode, i1);
  kv_u64(o, "seed", seed, i1);
  kv_bool(o, "passed", passed, i1);
  kv_str(o, "stop_reason", stop_reason, i1);
  kv_str(o, "stop_detail", stop_detail, i1);
  kv_u64(o, "passes", passes, i1);
  kv_u64(o, "core_cycles", core_cycles, i1);
  kv_u64(o, "cfg_cycles", cfg_cycles, i1);
  kv_u64(o, "sim_time_ps", sim_time_ps, i1);
  kv_u64(o, "beats_driven", beats_driven, i1);
  kv_u64(o, "beats_observed", beats_observed, i1);
  kv_u64(o, "frames_driven", frames_driven, i1);
  kv_u64(o, "frames_observed", frames_observed, i1);

  o << i1 << "\"scoreboard\": {\n";
  kv_u64(o, "expected", scoreboard.expected, i2);
  kv_u64(o, "observed", scoreboard.observed, i2);
  kv_u64(o, "matched", scoreboard.matched, i2);
  kv_u64(o, "lost", scoreboard.lost, i2);
  kv_u64(o, "duplicated", scoreboard.duplicated, i2);
  kv_u64(o, "misordered", scoreboard.misordered, i2);
  kv_u64(o, "content_mismatch", scoreboard.content_mismatch, i2);
  kv_u64(o, "unexpected", scoreboard.unexpected, i2);
  kv_u64(o, "latency_violation", scoreboard.latency_violation, i2);
  kv_u64(o, "latency_min_cycles", scoreboard.latency_min, i2);
  kv_u64(o, "latency_max_cycles", scoreboard.latency_max, i2);
  kv_fixed(o, "latency_mean_cycles", scoreboard.latency_mean(), i2, false);
  o << i1 << "},\n";

  kv_u64(o, "error_count", error_count, i1);

  o << i1 << "\"errors_by_category\": {";
  for (std::size_t n = 0; n < errors_by_category.size(); ++n) {
    o << (n ? "," : "") << "\n"
      << i2 << '"' << json_escape(errors_by_category[n].first) << "\": "
      << errors_by_category[n].second;
  }
  o << (errors_by_category.empty() ? "}" : "\n  }") << ",\n";

  o << i1 << "\"error_messages\": [";
  for (std::size_t n = 0; n < error_messages.size(); ++n) {
    o << (n ? "," : "") << "\n"
      << i2 << '"' << json_escape(error_messages[n]) << '"';
  }
  o << (error_messages.empty() ? "]" : "\n  ]") << ",\n";

  kv_str(o, "trace_path", trace_path, i1);

  // Last, and the only field that varies between identical-seed runs.
  kv_fixed(o, "wall_time_s", wall_time_s, i1, false);
  o << "}\n";
  return o.str();
}

std::string RunSummary::write(const std::string& dir) const {
  std::error_code ec;
  std::filesystem::create_directories(dir, ec);
  if (ec) {
    std::fprintf(stderr, "ERROR: cannot create results directory %s: %s\n",
                 dir.c_str(), ec.message().c_str());
    return {};
  }
  const std::string path = dir + "/" + test_name + "_" + config_name + "_seed" +
                           std::to_string(seed) + ".json";
  std::FILE* f = std::fopen(path.c_str(), "wb");
  if (f == nullptr) {
    std::fprintf(stderr, "ERROR: cannot write run summary %s\n", path.c_str());
    return {};
  }
  const std::string body = to_json();
  std::fwrite(body.data(), 1, body.size(), f);
  std::fclose(f);
  return path;
}

}  // namespace harness
