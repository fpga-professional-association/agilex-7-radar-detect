// -----------------------------------------------------------------------------
// iq_loader.cpp -- convert an ``iq_ascii_v1`` scenario file to Session
// stimulus. Companion to ``iq_loader.h``; see that header for the format.
// -----------------------------------------------------------------------------
#include "iq_loader.h"

#include <cctype>
#include <cerrno>
#include <cinttypes>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <fstream>
#include <sstream>
#include <string>
#include <unordered_map>
#include <vector>

namespace pipeline_tb {

namespace {

// Strip leading and trailing whitespace.
std::string trim(const std::string& s) {
  auto not_ws = [](int c) { return !std::isspace(c); };
  auto b = std::find_if(s.begin(), s.end(), not_ws);
  auto e = std::find_if(s.rbegin(), s.rend(), not_ws).base();
  if (b >= e) return {};
  return std::string(b, e);
}

// Parse ``# key: value`` header lines. Only lines starting with ``#`` are
// examined, and the first key wins on collision (same policy as
// ``range_doppler._parse_header_kv``).
void parse_header_kv(const std::string& line, std::unordered_map<std::string, std::string>& kv) {
  std::string s = trim(line);
  if (s.empty() || s[0] != '#') return;
  std::size_t p = s.find_first_not_of("# \t");
  if (p == std::string::npos) return;
  std::string body = s.substr(p);
  std::size_t colon = body.find(':');
  if (colon == std::string::npos) return;
  std::string key = trim(body.substr(0, colon));
  std::string val = trim(body.substr(colon + 1));
  // Well-formed keys are C identifiers; skip anything else (e.g. "targets
  // (ground truth)" and the "columns:" line, which do not describe a scalar).
  if (key.empty()) return;
  for (char c : key) {
    if (!(std::isalnum(static_cast<unsigned char>(c)) || c == '_')) return;
  }
  // First-wins on collision.
  if (kv.find(key) == kv.end()) kv[key] = val;
}

// String -> unsigned; on failure returns false. Trailing whitespace is ignored.
bool parse_unsigned(const std::string& s, unsigned& out) {
  if (s.empty()) return false;
  errno = 0;
  char* end = nullptr;
  unsigned long v = std::strtoul(s.c_str(), &end, 10);
  if (errno != 0 || end == s.c_str()) return false;
  while (*end && std::isspace(static_cast<unsigned char>(*end))) ++end;
  if (*end != '\0') return false;
  out = static_cast<unsigned>(v);
  return true;
}

bool parse_u64(const std::string& s, std::uint64_t& out) {
  if (s.empty()) return false;
  errno = 0;
  char* end = nullptr;
  unsigned long long v = std::strtoull(s.c_str(), &end, 10);
  if (errno != 0 || end == s.c_str()) return false;
  while (*end && std::isspace(static_cast<unsigned char>(*end))) ++end;
  if (*end != '\0') return false;
  out = static_cast<std::uint64_t>(v);
  return true;
}

bool parse_double(const std::string& s, double& out) {
  if (s.empty()) return false;
  errno = 0;
  char* end = nullptr;
  double v = std::strtod(s.c_str(), &end);
  if (errno != 0 || end == s.c_str()) return false;
  while (*end && std::isspace(static_cast<unsigned char>(*end))) ++end;
  if (*end != '\0') return false;
  out = v;
  return true;
}

// Read the whole file into a string. Returns false on any I/O failure.
bool slurp_file(const std::string& path, std::string& out) {
  std::ifstream in(path);
  if (!in.is_open()) {
    std::fprintf(stderr, "[iq_loader] cannot open %s\n", path.c_str());
    return false;
  }
  std::ostringstream ss;
  ss << in.rdbuf();
  out = ss.str();
  return true;
}

// Read a value from a JSON object body (as one big string). Only the exact
// key ``"key"`` at the outer object level is matched; nested objects are not
// searched. Returns the raw token after the colon (with surrounding quotes
// preserved if the value is a string) or the empty string if not found.
//
// This is deliberately narrow: the generator writes a fixed layout and this
// parser owns the same schema by construction. It is NOT a general JSON
// parser and it does not handle escaped quotes.
std::string json_scalar(const std::string& body, const std::string& key) {
  const std::string needle = "\"" + key + "\"";
  std::size_t p = body.find(needle);
  if (p == std::string::npos) return {};
  p = body.find(':', p + needle.size());
  if (p == std::string::npos) return {};
  ++p;
  while (p < body.size() && std::isspace(static_cast<unsigned char>(body[p]))) ++p;
  if (p >= body.size()) return {};
  // Value is a string?
  if (body[p] == '"') {
    std::size_t q = body.find('"', p + 1);
    if (q == std::string::npos) return {};
    return body.substr(p + 1, q - p - 1);
  }
  // Value is a number, true, false, or null. Read up to the next comma or }.
  std::size_t q = body.find_first_of(",}]\n", p);
  if (q == std::string::npos) return {};
  return trim(body.substr(p, q - p));
}

// Extract the ``[ { ... }, { ... }, ... ]`` array under key at the outer
// level. Returns the vector of raw inner object bodies (still bracketed).
std::vector<std::string> json_array_objects(const std::string& body, const std::string& key) {
  std::vector<std::string> out;
  const std::string needle = "\"" + key + "\"";
  std::size_t p = body.find(needle);
  if (p == std::string::npos) return out;
  p = body.find('[', p + needle.size());
  if (p == std::string::npos) return out;
  int depth = 1;
  ++p;
  while (p < body.size() && depth > 0) {
    // Skip whitespace and separators.
    while (p < body.size() && (std::isspace(static_cast<unsigned char>(body[p])) || body[p] == ',')) ++p;
    if (p >= body.size()) break;
    if (body[p] == ']') { --depth; ++p; break; }
    if (body[p] != '{') { ++p; continue; }
    // Read one object.
    int od = 1;
    std::size_t start = p;
    ++p;
    while (p < body.size() && od > 0) {
      if (body[p] == '{') ++od;
      else if (body[p] == '}') --od;
      ++p;
    }
    out.push_back(body.substr(start, p - start));
  }
  return out;
}

}  // namespace

int cfar_bin_for_fft_bin(int fft_bin, unsigned bin_par) {
  // Phase 6 (issue #21): per-beam CFAR + BIN_PAR-cycle serializer feeds
  // each per-beam cfar_core with cells in FFT-bin order (bin_par 0 first,
  // then bin_par 1, then next beat's bin_par 0, ...). Each cfar_core's
  // frame has FFT_SIZE cells, so CFAR bin index = FFT bin index directly.
  // Every FFT bin -- even and odd -- reaches SOME cfar_core cell; there is
  // no "untapped parity" restriction anymore.
  //
  // Phase 5 behaviour (superseded): the single-CFAR tap at (beam 0, bin_par
  // 0) mapped fft_bin -> fft_bin/bin_par on even fft_bins and -1 on odd
  // ones. Callers that need the OLD behaviour for a reference-chain-only
  // scenario should call cfar_bin_for_fft_bin_p5() instead (kept for the
  // `three_targets_even` reference verification path in
  // range_doppler.py -- see the harness header).
  (void)bin_par;
  if (fft_bin < 0) return -1;
  return fft_bin;
}

int cfar_bin_for_fft_bin_p5(int fft_bin, unsigned bin_par) {
  if (bin_par == 0) return -1;
  if ((fft_bin % static_cast<int>(bin_par)) != 0) return -1;  // untapped
  return fft_bin / static_cast<int>(bin_par);
}

bool load_scenario_json(const std::string& path, ScenarioMeta& meta) {
  std::string body;
  if (!slurp_file(path, body)) return false;

  meta.name = json_scalar(body, "scenario");
  std::string seed_s = json_scalar(body, "seed");
  if (!seed_s.empty()) (void)parse_u64(seed_s, meta.seed);
  std::string ns_s = json_scalar(body, "noise_sigma");
  if (!ns_s.empty()) (void)parse_double(ns_s, meta.noise_sigma);
  std::string ta_s = json_scalar(body, "target_amp");
  if (!ta_s.empty()) (void)parse_double(ta_s, meta.target_amp);

  meta.targets.clear();
  for (const auto& obj : json_array_objects(body, "targets")) {
    ScenarioTarget t;
    t.name = json_scalar(obj, "name");
    unsigned tmp = 0;
    if (parse_unsigned(json_scalar(obj, "range_bin"), tmp))
      t.range_bin = static_cast<int>(tmp);
    if (parse_unsigned(json_scalar(obj, "doppler_bin"), tmp))
      t.doppler_bin = static_cast<int>(tmp);
    if (parse_unsigned(json_scalar(obj, "angle_idx"), tmp))
      t.angle_idx = static_cast<int>(tmp);
    (void)parse_double(json_scalar(obj, "snr_db"), t.snr_db);
    meta.targets.push_back(std::move(t));
  }
  return true;
}

bool load_iq_file(const std::string& path,
                  ScenarioMeta& meta,
                  std::vector<StimFrame>& frames) {
  std::ifstream in(path);
  if (!in.is_open()) {
    std::fprintf(stderr, "[iq_loader] cannot open %s\n", path.c_str());
    return false;
  }

  std::unordered_map<std::string, std::string> hdr;
  std::vector<std::string> body_lines;
  body_lines.reserve(1 << 14);

  std::string line;
  while (std::getline(in, line)) {
    std::string t = trim(line);
    if (t.empty()) continue;
    if (t[0] == '#') { parse_header_kv(line, hdr); continue; }
    body_lines.push_back(std::move(line));
  }

  auto need = [&](const char* key, unsigned& out) -> bool {
    auto it = hdr.find(key);
    if (it == hdr.end() || !parse_unsigned(it->second, out)) {
      std::fprintf(stderr, "[iq_loader] header missing/invalid '%s' in %s\n",
                   key, path.c_str());
      return false;
    }
    return true;
  };

  if (!need("FFT_SIZE", meta.fft_size)) return false;
  if (!need("HISTORY_FRAMES", meta.history_frames)) return false;
  if (!need("N_ANTENNAS", meta.n_antennas)) return false;
  if (!need("SAMPLES_PER_CYCLE", meta.samples_per_cycle)) return false;
  if (!need("SAMPLE_W", meta.sample_w)) return false;
  if (auto it = hdr.find("scenario"); it != hdr.end()) meta.name = it->second;
  if (auto it = hdr.find("seed"); it != hdr.end()) (void)parse_u64(it->second, meta.seed);
  if (auto it = hdr.find("noise_sigma"); it != hdr.end())
    (void)parse_double(it->second, meta.noise_sigma);

  // Cross-check against the medium-config sizes the harness assumes.
  if (meta.n_antennas != kNAnt || meta.samples_per_cycle != kSpc ||
      meta.fft_size != kFftSize) {
    std::fprintf(stderr,
                 "[iq_loader] geometry mismatch: file has N_ANTENNAS=%u SPC=%u "
                 "FFT_SIZE=%u; harness expects %u/%u/%u\n",
                 meta.n_antennas, meta.samples_per_cycle, meta.fft_size,
                 kNAnt, kSpc, kFftSize);
    return false;
  }

  const unsigned beats_per_frame = meta.fft_size / meta.samples_per_cycle;
  const std::uint64_t expected_rows =
      static_cast<std::uint64_t>(meta.history_frames) *
      meta.n_antennas * beats_per_frame;
  if (body_lines.size() != expected_rows) {
    std::fprintf(stderr,
                 "[iq_loader] row count %zu != expected %llu "
                 "(%u frames * %u antennas * %u beats)\n",
                 body_lines.size(),
                 static_cast<unsigned long long>(expected_rows),
                 meta.history_frames, meta.n_antennas, beats_per_frame);
    return false;
  }

  frames.assign(meta.history_frames, StimFrame{});

  for (const std::string& row : body_lines) {
    std::istringstream ss(row);
    unsigned frame = 0, ant = 0, beat = 0, sof = 0, eof = 0;
    if (!(ss >> frame >> ant >> beat >> sof >> eof)) {
      std::fprintf(stderr, "[iq_loader] malformed row: %s\n", row.c_str());
      return false;
    }
    if (frame >= meta.history_frames || ant >= meta.n_antennas ||
        beat >= beats_per_frame) {
      std::fprintf(stderr,
                   "[iq_loader] out-of-range indices frame=%u ant=%u beat=%u\n",
                   frame, ant, beat);
      return false;
    }
    const unsigned expected_sof = (beat == 0) ? 1u : 0u;
    const unsigned expected_eof = (beat == beats_per_frame - 1) ? 1u : 0u;
    if (sof != expected_sof || eof != expected_eof) {
      std::fprintf(stderr,
                   "[iq_loader] framing mismatch at frame %u ant %u beat %u: "
                   "sof=%u eof=%u expected sof=%u eof=%u\n",
                   frame, ant, beat, sof, eof, expected_sof, expected_eof);
      return false;
    }
    for (unsigned p = 0; p < meta.samples_per_cycle; ++p) {
      int re = 0, im = 0;
      if (!(ss >> re >> im)) {
        std::fprintf(stderr,
                     "[iq_loader] truncated sample pair p=%u at frame %u ant %u beat %u\n",
                     p, frame, ant, beat);
        return false;
      }
      frames[frame].at_re(ant, beat, p) = static_cast<std::int16_t>(re);
      frames[frame].at_im(ant, beat, p) = static_cast<std::int16_t>(im);
    }
  }

  return true;
}

bool load_scenario(const std::string& base_dir,
                   ScenarioMeta& meta,
                   std::vector<StimFrame>& frames) {
  const std::string iq_path   = base_dir + "/scenario.iq";
  const std::string json_path = base_dir + "/scenario.json";

  ScenarioMeta iq_meta;
  if (!load_iq_file(iq_path, iq_meta, frames)) return false;

  ScenarioMeta json_meta;
  if (!load_scenario_json(json_path, json_meta)) {
    // Missing JSON is a soft error -- keep the loaded IQ + a warning so the
    // test can still run against a scenario without ground truth. But if it
    // exists it must parse.
    std::fprintf(stderr,
                 "[iq_loader] warning: no ground-truth JSON at %s; running "
                 "without target list\n",
                 json_path.c_str());
    meta = iq_meta;
    return true;
  }

  // Prefer IQ header for geometry (cross-checked); fill targets and name from
  // the JSON sidecar.
  meta = iq_meta;
  if (meta.name.empty()) meta.name = json_meta.name;
  if (json_meta.seed != 0) meta.seed = json_meta.seed;
  meta.noise_sigma = json_meta.noise_sigma;
  meta.target_amp  = json_meta.target_amp;
  meta.targets     = json_meta.targets;
  return true;
}

}  // namespace pipeline_tb
