// -----------------------------------------------------------------------------
// fft_vectors.hpp — loader for model/vectors/fft*.vec (issue #11).
//
// The FFT half of what model/cpp/fxp/fxp_vectors.hpp does for the numerics
// vectors, and it follows the same rules for the same reasons:
//
//   * line-oriented ASCII, parsed with three lines of code and no dependency, so
//     the same file is read by a Verilator test binary, a standalone C++ unit
//     test and a Python script (SPEC 16: a clean checkout must build);
//   * the HEADER IS PARSED, NOT SKIPPED. A file whose rounding mode, geometry or
//     twiddle digest does not match the build is REJECTED rather than compared
//     against. A stale vector set silently agreeing with whichever
//     implementation happens to match it is the failure this prevents.
//
// The twiddle digest is the FFT-specific member of that list. The coefficients
// are a committed generated artefact (model/python/gen_fft_twiddles.py), so a
// regenerated table and an un-regenerated vector file would produce a diff of
// thousands of "wrong" samples with no indication of the cause. Comparing the
// digest in the file against fft::kTwDigest turns that into one line.
//
// Format
// ------
//   # key: value                              header comments, parsed
//   vec <id> <sched_hex> <reorder> <flags_hex>   one record
//   s <i> <in_re> <in_im> <out_re> <out_im>      one sample of that record
//
// Samples are in BEAT ORDER: index i is beat i/spc, slot i%spc (fft_core's
// normative layout). `flags_hex` packs one {sat_pos<<1|sat_neg} field per
// butterfly sub-stage, sub-stage g at bits [2g+1:2g].
//
// Header-only. Build contract: g++ 13, -std=c++17 -O3 -Wall -Wextra -Werror.
// -----------------------------------------------------------------------------
#ifndef MODEL_CPP_FFT_FFT_VECTORS_HPP_
#define MODEL_CPP_FFT_FFT_VECTORS_HPP_

#include <cstdint>
#include <cstdlib>
#include <fstream>
#include <sstream>
#include <string>
#include <vector>

#include "fft/fft_ref.hpp"
#include "fxp/fxp.hpp"

namespace fft {
namespace vectors {

inline constexpr int kSchema = 1;

// The rounding mode this build was compiled with, in the vector file's spelling.
inline const char* expected_rounding_mode() {
  return fxp::kRoundMode == fxp::RoundMode::kHalfUp ? "half_up"
                                                    : "nearest_even";
}

struct Header {
  int schema = 0;
  std::string kind;
  std::string rounding_mode;
  std::uint64_t seed = 0;
  unsigned count = 0;
  unsigned fft_size = 0;
  unsigned spc = 0;
  unsigned stages = 0;
  std::string twiddle_digest;
};

struct FftVector {
  std::string id;
  unsigned sched = 0;
  bool reorder = true;
  std::vector<fxp::Complex> in;   // beat order
  std::vector<fxp::Complex> out;  // beat order
  std::vector<fxp::Flags> stage_flags;

  // The configuration this record was produced with, ready to hand to
  // fft::transform.
  Config config(const Header& h) const {
    Config c;
    c.n_fft = h.fft_size;
    c.spc = h.spc;
    c.scale_sched = sched;
    c.reorder = reorder;
    return c;
  }
};

namespace detail {

inline bool header_line(const std::string& line, const std::string& key,
                        std::string* value) {
  // "# key: value"
  const std::string prefix = "# " + key + ":";
  if (line.compare(0, prefix.size(), prefix) != 0) return false;
  std::string v = line.substr(prefix.size());
  const std::size_t b = v.find_first_not_of(" \t");
  if (b == std::string::npos) {
    value->clear();
    return true;
  }
  const std::size_t e = v.find_last_not_of(" \t\r");
  *value = v.substr(b, e - b + 1);
  return true;
}

}  // namespace detail

// Loads `path`. On failure returns false and fills `err` with a message that
// names the file and the line.
inline bool load(const std::string& path, std::vector<FftVector>* out,
                 Header* hdr, std::string* err) {
  std::ifstream fh(path);
  if (!fh) {
    *err = "cannot open FFT vector file: " + path;
    return false;
  }

  out->clear();
  *hdr = Header{};

  std::string line;
  std::size_t lineno = 0;
  FftVector* cur = nullptr;
  unsigned packed_flags = 0;

  while (std::getline(fh, line)) {
    ++lineno;
    if (!line.empty() && line.back() == '\r') line.pop_back();
    if (line.empty()) continue;

    if (line[0] == '#') {
      std::string v;
      if (detail::header_line(line, "schema", &v)) hdr->schema = std::atoi(v.c_str());
      else if (detail::header_line(line, "kind", &v)) hdr->kind = v;
      else if (detail::header_line(line, "rounding_mode", &v)) hdr->rounding_mode = v;
      else if (detail::header_line(line, "seed", &v))
        hdr->seed = std::strtoull(v.c_str(), nullptr, 10);
      else if (detail::header_line(line, "count", &v))
        hdr->count = static_cast<unsigned>(std::atoi(v.c_str()));
      else if (detail::header_line(line, "fft_size", &v))
        hdr->fft_size = static_cast<unsigned>(std::atoi(v.c_str()));
      else if (detail::header_line(line, "spc", &v))
        hdr->spc = static_cast<unsigned>(std::atoi(v.c_str()));
      else if (detail::header_line(line, "stages", &v))
        hdr->stages = static_cast<unsigned>(std::atoi(v.c_str()));
      else if (detail::header_line(line, "twiddle_digest", &v))
        hdr->twiddle_digest = v;
      continue;
    }

    std::istringstream is(line);
    std::string tag;
    is >> tag;

    if (tag == "vec") {
      std::string id, sched_hex, flags_hex;
      int reorder = 1;
      if (!(is >> id >> sched_hex >> reorder >> flags_hex)) {
        *err = path + ":" + std::to_string(lineno) + ": malformed 'vec' line";
        return false;
      }
      FftVector rec;
      rec.id = id;
      rec.sched = static_cast<unsigned>(std::strtoul(sched_hex.c_str(), nullptr, 16));
      rec.reorder = reorder != 0;
      out->push_back(rec);
      cur = &out->back();
      packed_flags =
          static_cast<unsigned>(std::strtoul(flags_hex.c_str(), nullptr, 16));
      cur->stage_flags.assign(hdr->stages, fxp::flags_none());
      for (unsigned g = 0; g < hdr->stages; ++g) {
        cur->stage_flags[g] = fxp::Flags::from_packed((packed_flags >> (2 * g)) & 0x3u);
      }
      continue;
    }

    if (tag == "s") {
      if (cur == nullptr) {
        *err = path + ":" + std::to_string(lineno) + ": sample before any 'vec'";
        return false;
      }
      long i = 0, ire = 0, iim = 0, ore = 0, oim = 0;
      if (!(is >> i >> ire >> iim >> ore >> oim)) {
        *err = path + ":" + std::to_string(lineno) + ": malformed 's' line";
        return false;
      }
      if (static_cast<std::size_t>(i) != cur->in.size()) {
        *err = path + ":" + std::to_string(lineno) + ": sample index " +
               std::to_string(i) + " out of order in record " + cur->id;
        return false;
      }
      cur->in.push_back(fxp::Complex{static_cast<fxp::i16>(ire),
                                     static_cast<fxp::i16>(iim)});
      cur->out.push_back(fxp::Complex{static_cast<fxp::i16>(ore),
                                      static_cast<fxp::i16>(oim)});
      continue;
    }

    *err = path + ":" + std::to_string(lineno) + ": unknown record tag '" + tag + "'";
    return false;
  }

  // Everything the header claims must be true of what was read. A truncated
  // file must fail, not pass short.
  if (hdr->schema != kSchema) {
    *err = path + ": schema " + std::to_string(hdr->schema) + ", this build reads " +
           std::to_string(kSchema);
    return false;
  }
  if (hdr->kind != "fft") {
    *err = path + ": kind '" + hdr->kind + "', expected 'fft'";
    return false;
  }
  if (hdr->rounding_mode != expected_rounding_mode()) {
    *err = path + ": rounding mode '" + hdr->rounding_mode + "', this build uses '" +
           expected_rounding_mode() + "'";
    return false;
  }
  if (hdr->twiddle_digest != kTwDigest) {
    *err = path + ": twiddle digest '" + hdr->twiddle_digest +
           "', this build was compiled against '" + std::string(kTwDigest) +
           "'. Regenerate the vectors after regenerating the table.";
    return false;
  }
  if (hdr->stages != total_stages(hdr->fft_size)) {
    *err = path + ": header says " + std::to_string(hdr->stages) +
           " sub-stages, an " + std::to_string(hdr->fft_size) +
           "-point transform has " + std::to_string(total_stages(hdr->fft_size));
    return false;
  }
  if (out->size() != hdr->count) {
    *err = path + ": header says " + std::to_string(hdr->count) +
           " records, found " + std::to_string(out->size());
    return false;
  }
  for (const FftVector& r : *out) {
    if (r.in.size() != hdr->fft_size || r.out.size() != hdr->fft_size) {
      *err = path + ": record '" + r.id + "' has " + std::to_string(r.in.size()) +
             " samples, expected " + std::to_string(hdr->fft_size);
      return false;
    }
  }
  return true;
}

}  // namespace vectors
}  // namespace fft

#endif  // MODEL_CPP_FFT_FFT_VECTORS_HPP_
