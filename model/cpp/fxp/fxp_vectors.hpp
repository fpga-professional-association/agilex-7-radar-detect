// -----------------------------------------------------------------------------
// fxp_vectors.hpp — reader for the golden vector files under model/vectors/.
//
// The files are written by model/python/gen_fxp_vectors.py from an independent
// NumPy model (model/python/fxp_reference.py) and are the source of truth both
// the C++ library and the RTL package are measured against. SPEC 12.4: the C++
// model must be validated against Python/NumPy vectors before it is trusted as
// the RTL oracle.
//
// Format (DECISIONS.md 2026-07-25, "vector file format"): line-oriented ASCII,
// `#` comments, whitespace-separated fields, integers in signed decimal.
//
//   # fxp vector file
//   # schema: 1
//   # kind: ops
//   # rounding_mode: nearest_even
//   # seed: 20260725
//   # count: 1234
//   # columns: id op a b sh w y flags
//   sat_q15_max_pos sat 32767 0 0 16 32767 0
//
// `count` is checked against the number of records read, so a truncated file is
// a failure rather than a short but passing run.
//
// This reader is deliberately dependency-free and dumb: `std::strtoll` and
// whitespace splitting. It is used by a Verilator test binary as well as by the
// standalone unit test, and neither may drag in a JSON library that a clean
// checkout would have to vendor (SPEC 16).
// -----------------------------------------------------------------------------
#ifndef MODEL_CPP_FXP_FXP_VECTORS_HPP_
#define MODEL_CPP_FXP_FXP_VECTORS_HPP_

#include <cstdint>
#include <cstdlib>
#include <fstream>
#include <sstream>
#include <string>
#include <vector>

#include "fxp/fxp.hpp"
#include "fxp/fxp_ops.hpp"

namespace fxp {
namespace vectors {

inline constexpr int kSchemaVersion = 1;

struct Header {
  int schema = 0;
  std::string kind;
  std::string rounding_mode;
  std::uint64_t seed = 0;
  std::size_t declared_count = 0;
  // `cmult` files only: the declared width of the exact full-precision product.
  // Checked against fxp::cmult::kCmulProdW by the loader's caller, so a vector
  // set generated for a different product width cannot be silently accepted.
  unsigned prod_w = 0;
};

// One record of model/vectors/fxp_ops.vec.
struct OpVector {
  std::string id;
  std::string op;
  unsigned code = ops::kOpCount;
  wide_t a = 0;
  wide_t b = 0;
  unsigned sh = 0;
  unsigned w = 0;
  wide_t y = 0;           // expected result
  unsigned flags = 0;     // expected packed Flags
};

// One step of model/vectors/fxp_accum.vec. Each line is a full observation of
// the accumulator after applying `x`, so an intermediate divergence is caught at
// the step it happens rather than at the end of the sequence.
struct AccumStep {
  std::string id;         // sequence name; steps of one sequence are contiguous
  unsigned step = 0;      // 0 = first step after clear
  unsigned acc_w = 0;
  wide_t x = 0;
  wide_t y = 0;           // expected accumulator value after the step
  unsigned step_flags = 0;    // expected packed Flags for this step
  unsigned sticky_flags = 0;  // expected packed sticky Flags after this step
  std::uint32_t count = 0;    // expected saturating-event count after this step
};

// One record of model/vectors/cmult.vec (issue #9). Carries BOTH observable
// output formats of rtl/common/complex_multiplier.sv, so one file proves the
// ROUND_OUT=1 and the ROUND_OUT=0 build.
struct CmultVector {
  std::string id;
  Complex a;
  Complex b;
  wide_t p_re = 0;        // exact full-precision product, prod_w bits
  wide_t p_im = 0;
  i16 y_re = 0;           // rounded Q1.15 product
  i16 y_im = 0;
  unsigned flags_re = 0;  // packed Flags
  unsigned flags_im = 0;
};

namespace detail {

inline bool parse_i64(const std::string& s, wide_t* out) {
  if (s.empty()) return false;
  char* end = nullptr;
  const long long v = std::strtoll(s.c_str(), &end, 10);
  if (end == s.c_str() || *end != '\0') return false;
  *out = static_cast<wide_t>(v);
  return true;
}

inline bool parse_u32(const std::string& s, std::uint32_t* out) {
  wide_t v = 0;
  if (!parse_i64(s, &v) || v < 0 || v > 0xFFFFFFFFLL) return false;
  *out = static_cast<std::uint32_t>(v);
  return true;
}

inline bool parse_unsigned(const std::string& s, unsigned* out) {
  std::uint32_t v = 0;
  if (!parse_u32(s, &v)) return false;
  *out = static_cast<unsigned>(v);
  return true;
}

// Reads `# key: value` header comments into `h`.
inline void absorb_header(const std::string& line, Header* h) {
  const std::size_t colon = line.find(':');
  if (colon == std::string::npos) return;
  std::string key = line.substr(1, colon - 1);
  std::string value = line.substr(colon + 1);
  auto strip = [](std::string& s) {
    const std::size_t b = s.find_first_not_of(" \t\r");
    const std::size_t e = s.find_last_not_of(" \t\r");
    s = (b == std::string::npos) ? std::string() : s.substr(b, e - b + 1);
  };
  strip(key);
  strip(value);
  if (key == "schema") h->schema = std::atoi(value.c_str());
  else if (key == "kind") h->kind = value;
  else if (key == "rounding_mode") h->rounding_mode = value;
  else if (key == "seed") h->seed = std::strtoull(value.c_str(), nullptr, 10);
  else if (key == "count")
    h->declared_count = static_cast<std::size_t>(
        std::strtoull(value.c_str(), nullptr, 10));
  else if (key == "prod_w")
    h->prod_w = static_cast<unsigned>(std::atoi(value.c_str()));
}

inline std::vector<std::string> split(const std::string& line) {
  std::istringstream is(line);
  std::vector<std::string> f;
  std::string tok;
  while (is >> tok) f.push_back(tok);
  return f;
}

}  // namespace detail

// Loads fxp_ops.vec. Returns false and fills `err` on any malformed line;
// there is no "skip what we cannot parse" path, because a silently skipped
// vector is a silently unproven case.
inline bool load_ops(const std::string& path, std::vector<OpVector>* out,
                     Header* header, std::string* err) {
  std::ifstream in(path);
  if (!in) {
    *err = "cannot open " + path;
    return false;
  }
  Header h;
  std::string line;
  std::size_t lineno = 0;
  while (std::getline(in, line)) {
    ++lineno;
    if (!line.empty() && line[0] == '#') {
      detail::absorb_header(line, &h);
      continue;
    }
    const std::vector<std::string> f = detail::split(line);
    if (f.empty()) continue;
    if (f.size() != 8) {
      *err = path + ":" + std::to_string(lineno) + ": expected 8 fields, got " +
             std::to_string(f.size());
      return false;
    }
    OpVector v;
    v.id = f[0];
    v.op = f[1];
    v.code = ops::code_of(v.op.c_str());
    if (v.code == ops::kOpCount) {
      *err = path + ":" + std::to_string(lineno) + ": unknown op '" + v.op +
             "' (op table drift between the generator, fxp_ops.hpp and "
             "fxp_probe_top.sv)";
      return false;
    }
    if (!detail::parse_i64(f[2], &v.a) || !detail::parse_i64(f[3], &v.b) ||
        !detail::parse_unsigned(f[4], &v.sh) ||
        !detail::parse_unsigned(f[5], &v.w) || !detail::parse_i64(f[6], &v.y) ||
        !detail::parse_unsigned(f[7], &v.flags)) {
      *err = path + ":" + std::to_string(lineno) + ": malformed field";
      return false;
    }
    out->push_back(v);
  }
  if (h.schema != kSchemaVersion) {
    *err = path + ": schema " + std::to_string(h.schema) + ", expected " +
           std::to_string(kSchemaVersion);
    return false;
  }
  if (h.declared_count != out->size()) {
    *err = path + ": header declares " + std::to_string(h.declared_count) +
           " records, read " + std::to_string(out->size());
    return false;
  }
  if (header != nullptr) *header = h;
  return true;
}

// Loads fxp_accum.vec.
inline bool load_accum(const std::string& path, std::vector<AccumStep>* out,
                       Header* header, std::string* err) {
  std::ifstream in(path);
  if (!in) {
    *err = "cannot open " + path;
    return false;
  }
  Header h;
  std::string line;
  std::size_t lineno = 0;
  while (std::getline(in, line)) {
    ++lineno;
    if (!line.empty() && line[0] == '#') {
      detail::absorb_header(line, &h);
      continue;
    }
    const std::vector<std::string> f = detail::split(line);
    if (f.empty()) continue;
    if (f.size() != 8) {
      *err = path + ":" + std::to_string(lineno) + ": expected 8 fields, got " +
             std::to_string(f.size());
      return false;
    }
    AccumStep s;
    s.id = f[0];
    if (!detail::parse_unsigned(f[1], &s.step) ||
        !detail::parse_unsigned(f[2], &s.acc_w) ||
        !detail::parse_i64(f[3], &s.x) || !detail::parse_i64(f[4], &s.y) ||
        !detail::parse_unsigned(f[5], &s.step_flags) ||
        !detail::parse_unsigned(f[6], &s.sticky_flags) ||
        !detail::parse_u32(f[7], &s.count)) {
      *err = path + ":" + std::to_string(lineno) + ": malformed field";
      return false;
    }
    out->push_back(s);
  }
  if (h.schema != kSchemaVersion) {
    *err = path + ": schema " + std::to_string(h.schema) + ", expected " +
           std::to_string(kSchemaVersion);
    return false;
  }
  if (h.declared_count != out->size()) {
    *err = path + ": header declares " + std::to_string(h.declared_count) +
           " records, read " + std::to_string(out->size());
    return false;
  }
  if (header != nullptr) *header = h;
  return true;
}

// Loads cmult.vec. Same contract as the two loaders above: a malformed line, an
// unexpected schema or a record count that disagrees with the header is a
// failure, never a quiet skip.
inline bool load_cmult(const std::string& path, std::vector<CmultVector>* out,
                       Header* header, std::string* err) {
  std::ifstream in(path);
  if (!in) {
    *err = "cannot open " + path;
    return false;
  }
  Header h;
  std::string line;
  std::size_t lineno = 0;
  while (std::getline(in, line)) {
    ++lineno;
    if (!line.empty() && line[0] == '#') {
      detail::absorb_header(line, &h);
      continue;
    }
    const std::vector<std::string> f = detail::split(line);
    if (f.empty()) continue;
    if (f.size() != 11) {
      *err = path + ":" + std::to_string(lineno) +
             ": expected 11 fields, got " + std::to_string(f.size());
      return false;
    }
    wide_t a_re = 0, a_im = 0, b_re = 0, b_im = 0, y_re = 0, y_im = 0;
    CmultVector v;
    v.id = f[0];
    if (!detail::parse_i64(f[1], &a_re) || !detail::parse_i64(f[2], &a_im) ||
        !detail::parse_i64(f[3], &b_re) || !detail::parse_i64(f[4], &b_im) ||
        !detail::parse_i64(f[5], &v.p_re) ||
        !detail::parse_i64(f[6], &v.p_im) || !detail::parse_i64(f[7], &y_re) ||
        !detail::parse_i64(f[8], &y_im) ||
        !detail::parse_unsigned(f[9], &v.flags_re) ||
        !detail::parse_unsigned(f[10], &v.flags_im)) {
      *err = path + ":" + std::to_string(lineno) + ": malformed field";
      return false;
    }
    v.a = Complex{static_cast<i16>(a_re), static_cast<i16>(a_im)};
    v.b = Complex{static_cast<i16>(b_re), static_cast<i16>(b_im)};
    v.y_re = static_cast<i16>(y_re);
    v.y_im = static_cast<i16>(y_im);
    out->push_back(v);
  }
  if (h.schema != kSchemaVersion) {
    *err = path + ": schema " + std::to_string(h.schema) + ", expected " +
           std::to_string(kSchemaVersion);
    return false;
  }
  if (h.declared_count != out->size()) {
    *err = path + ": header declares " + std::to_string(h.declared_count) +
           " records, read " + std::to_string(out->size());
    return false;
  }
  if (header != nullptr) *header = h;
  return true;
}

// The rounding-mode tag the vectors must carry for this build of fxp.hpp. A
// vector set generated under the other mode must not silently be accepted.
inline const char* expected_rounding_mode() {
  return kRoundMode == RoundMode::kHalfUp ? "half_up" : "nearest_even";
}

}  // namespace vectors
}  // namespace fxp

#endif  // MODEL_CPP_FXP_FXP_VECTORS_HPP_
