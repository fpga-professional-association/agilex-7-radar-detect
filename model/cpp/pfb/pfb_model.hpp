// -----------------------------------------------------------------------------
// pfb_model.hpp — the bit-accurate C++ reference for the SPEC 7.1 polyphase FIR
// bank (issue #10).
//
// Governing spec: SPEC.md 6 (numerics), 7.1 (polyphase FIR bank), 12.4
// (reference model). Normative numeric prose: NUMERICS.md.
//
// This is the ORACLE sim/tests/test_pfb_bank.cpp checks the RTL against on every
// beat. It is written entirely in terms of model/cpp/fxp/fxp.hpp — the issue #4
// library that is already proven bit-identical to rtl/packages/fxp_pkg.sv and to
// the independent NumPy model — so it inherits that proof rather than restating
// it. There is no floating point anywhere below.
//
// The third corner of the triangle is model/python/pfb_model.py, which produces
// the committed golden vectors this header also loads. The three agree or the
// test fails; an oracle that agrees only with itself is not an oracle.
//
// -----------------------------------------------------------------------------
// The computation, stated once
// -----------------------------------------------------------------------------
// A beat carries PHASES consecutive complex samples. Branch p filters the
// decimated substream x_p[m] = x[m*PHASES + p] with its own TAPS-tap complex
// FIR:
//
//     y_p[m] = sum_k h_p[k] * x_p[m-k]
//
// Per output component the branch accumulates 2*TAPS EXACT Q1.15 x Q1.15
// products at full precision and quantises ONCE, at the end, round-to-nearest-
// even then saturate. No intermediate rounding, no intermediate saturation:
// fxp::mac_q15_acc_w(2*TAPS) is wide enough that the accumulation cannot
// overflow, which is also what makes the RTL's adder tree and its systolic
// cascade bit-identical to each other and to this.
//
// The accumulator here is fxp::wide_t (signed 64-bit) rather than a
// width-limited type, and that is deliberate: the model must never be the thing
// that saturates. TAPS <= 64 and each partial sum is at most 2^31 in magnitude,
// so the worst-case accumulator magnitude is 2^37 — 26 bits of headroom.
//
// -----------------------------------------------------------------------------
// What this model does NOT model
// -----------------------------------------------------------------------------
// Timing. It has no notion of cycles, beats-in-flight, credit or backpressure.
// It is a pure sequence transformer: feed it the beats the RTL admitted, in
// order, and compare its outputs against the beats the RTL emitted, in order.
// That separation is what lets one model check both accumulation styles, whose
// latencies differ in kind (see rtl/packages/pfb_pkg.sv, "Beats and cycles").
//
// Header-only, dependency-free, and compiled with -Wall -Wextra -Werror by both
// the standalone unit test and the Verilator harness.
// -----------------------------------------------------------------------------
#ifndef MODEL_CPP_PFB_PFB_MODEL_HPP_
#define MODEL_CPP_PFB_PFB_MODEL_HPP_

#include <cstddef>
#include <cstdint>
#include <cstdlib>
#include <fstream>
#include <sstream>
#include <string>
#include <vector>

#include "fxp/fxp.hpp"

namespace pfb {

inline constexpr int kSchemaVersion = 1;

using fxp::Complex;
using fxp::Flags;
using fxp::i16;
using fxp::wide_t;

// ---------------------------------------------------------------------------
// Geometry helpers — the SystemVerilog pfb_pkg functions, in C++
//
// Mirrors, not copies-with-opinions: each one is the same expression as its
// SystemVerilog twin, and sim/tests/test_pfb_bank.cpp checks the values against
// the RTL's own cfg_* echo before it checks anything else.
// ---------------------------------------------------------------------------

// Accumulator width for one component of a TAPS-tap complex FIR.
constexpr unsigned acc_w(unsigned taps) { return fxp::mac_q15_acc_w(2u * taps); }

constexpr unsigned tree_levels(unsigned taps) {
  if (taps <= 1) return 0;
  unsigned b = 0;
  unsigned v = taps - 1u;
  while (v != 0u) {
    v >>= 1;
    ++b;
  }
  return b;  // ceil(log2 taps), matching $clog2
}

// Beat- and cycle-measured latency. See rtl/packages/pfb_pkg.sv.
constexpr unsigned lat_beats(bool systolic, unsigned taps) {
  return systolic ? (taps - 1u) : 0u;
}

constexpr unsigned lat_cycles(bool systolic, unsigned taps,
                              unsigned mult_pipe) {
  return systolic ? (mult_pipe + 2u) : (mult_pipe + tree_levels(taps) + 1u);
}

// Phase-major, tap-minor. The one place the coefficient ordering is written in
// C++; rtl/pfb/coeff_bank.sv and scripts/generate_coefficients.py write the
// same expression.
constexpr std::size_t coeff_index(unsigned taps, unsigned phase,
                                  unsigned tap) {
  return static_cast<std::size_t>(phase) * taps + tap;
}

// ---------------------------------------------------------------------------
// One branch
// ---------------------------------------------------------------------------

class LaneModel {
 public:
  LaneModel() = default;

  LaneModel(unsigned taps, const Complex* coeff)
      : taps_(taps), coeff_(coeff, coeff + taps), history_(taps_, Complex{}) {}

  // Clears the history to zero — the state the RTL's delay line is in once its
  // valid pipeline says enough beats have been admitted. Coefficients survive.
  void reset() { history_.assign(taps_, Complex{}); }

  void set_coeff(const Complex* coeff) {
    coeff_.assign(coeff, coeff + taps_);
  }

  unsigned taps() const { return taps_; }
  const std::vector<Complex>& coeff() const { return coeff_; }

  // The exact accumulators for one sample, WITHOUT quantising. Exposed because
  // a mismatch in the accumulator and a mismatch in the rounding are different
  // defects, and a test that can only see the rounded answer cannot tell them
  // apart.
  void accumulate(Complex x, wide_t* acc_re, wide_t* acc_im) const {
    wide_t re = 0;
    wide_t im = 0;
    for (unsigned k = 0; k < taps_; ++k) {
      // history_[k] holds x[n-k] for k >= 1; k == 0 is the live sample.
      const Complex s = (k == 0) ? x : history_[k - 1];
      const Complex h = coeff_[k];
      re = fxp::add_wrap(re, fxp::cmul_q15_re_raw(s, h));
      im = fxp::add_wrap(im, fxp::cmul_q15_im_raw(s, h));
    }
    *acc_re = re;
    *acc_im = im;
  }

  // Consume one sample. Returns the quantised output; the direction-resolved
  // saturation flags land in *f_re / *f_im (either may be null).
  Complex step(Complex x, Flags* f_re = nullptr, Flags* f_im = nullptr) {
    wide_t acc_re = 0;
    wide_t acc_im = 0;
    accumulate(x, &acc_re, &acc_im);

    const Complex y{
        static_cast<i16>(fxp::round_sat(acc_re, fxp::kProdShift,
                                        fxp::kSampleW)),
        static_cast<i16>(fxp::round_sat(acc_im, fxp::kProdShift,
                                        fxp::kSampleW))};
    if (f_re) *f_re = fxp::round_sat_flags(acc_re, fxp::kProdShift,
                                           fxp::kSampleW);
    if (f_im) *f_im = fxp::round_sat_flags(acc_im, fxp::kProdShift,
                                           fxp::kSampleW);

    // Advance AFTER the evaluation: the sample being consumed is tap 0 of this
    // beat and tap 1 of the next.
    if (taps_ > 1) {
      for (unsigned k = taps_ - 1; k > 0; --k) history_[k] = history_[k - 1];
      history_[0] = x;
    }
    return y;
  }

 private:
  unsigned taps_ = 0;
  std::vector<Complex> coeff_;
  std::vector<Complex> history_;  // history_[k-1] == x[n-k]
};

// ---------------------------------------------------------------------------
// One beat of the bank
// ---------------------------------------------------------------------------

struct BeatResult {
  std::vector<Complex> y;
  std::vector<Flags> flags_re;
  std::vector<Flags> flags_im;

  // The OR of every lane's flags, which is what rtl/pfb/pfb_bank.sv feeds its
  // telemetry. Kept as a function rather than a member so it cannot drift out
  // of date with the vectors above.
  Flags merged() const {
    Flags m;
    for (std::size_t i = 0; i < flags_re.size(); ++i) {
      m = fxp::flags_merge(m, flags_re[i]);
      m = fxp::flags_merge(m, flags_im[i]);
    }
    return m;
  }
};

class PfbModel {
 public:
  PfbModel() = default;

  // `coeff` holds phases*taps entries in phase-major, tap-minor order.
  PfbModel(unsigned phases, unsigned taps, const std::vector<Complex>& coeff)
      : phases_(phases), taps_(taps) {
    set_coeff(coeff);
  }

  void set_coeff(const std::vector<Complex>& coeff) {
    lanes_.clear();
    lanes_.reserve(phases_);
    for (unsigned p = 0; p < phases_; ++p) {
      lanes_.emplace_back(taps_, &coeff[coeff_index(taps_, p, 0)]);
    }
  }

  // Replace the coefficients WITHOUT touching the history. This is what a
  // coefficient-bank swap does: the filter state is continuous across a swap and
  // only the taps change, which is the behaviour the mid-stream swap test
  // depends on.
  void swap_coeff(const std::vector<Complex>& coeff) {
    for (unsigned p = 0; p < phases_; ++p) {
      lanes_[p].set_coeff(&coeff[coeff_index(taps_, p, 0)]);
    }
  }

  void reset() {
    for (auto& lane : lanes_) lane.reset();
  }

  unsigned phases() const { return phases_; }
  unsigned taps() const { return taps_; }

  BeatResult step(const std::vector<Complex>& beat) {
    BeatResult r;
    r.y.resize(phases_);
    r.flags_re.resize(phases_);
    r.flags_im.resize(phases_);
    for (unsigned p = 0; p < phases_; ++p) {
      r.y[p] = lanes_[p].step(beat[p], &r.flags_re[p], &r.flags_im[p]);
    }
    return r;
  }

 private:
  unsigned phases_ = 0;
  unsigned taps_ = 0;
  std::vector<LaneModel> lanes_;
};

// ---------------------------------------------------------------------------
// File loaders
//
// Both formats are line-oriented ASCII with parsed `#` header comments — the
// same shape model/cpp/fxp/fxp_vectors.hpp reads, and dependency-free for the
// same reason: this header is compiled into a Verilator test binary as well as
// into a standalone unit test, and neither may drag in a JSON library a clean
// checkout would have to vendor (SPEC 16).
//
// The declared counts and the declared geometry are CHECKED, not assumed. A
// truncated file, or one generated for a different geometry, is an error rather
// than a short-but-passing run.
// ---------------------------------------------------------------------------

struct CoeffHeader {
  int schema = 0;
  std::string kind;
  std::string set;
  std::string window;
  std::string rounding_mode;
  unsigned phases = 0;
  unsigned taps = 0;
  unsigned coeff_w = 0;
  unsigned frac_w = 0;
  std::uint64_t seed = 0;
  std::size_t declared_count = 0;
};

struct IoHeader {
  int schema = 0;
  std::string kind;
  std::string set;
  std::string coeff_file;
  std::string rounding_mode;
  unsigned phases = 0;
  unsigned taps = 0;
  unsigned acc_w = 0;
  std::uint64_t seed = 0;
  std::size_t declared_count = 0;
};

// One beat of a golden vector file: the stimulus, the expected outputs and the
// expected packed flag words.
struct IoVector {
  std::size_t beat = 0;
  std::vector<Complex> x;
  std::vector<Complex> y;
  std::vector<unsigned> f_re;
  std::vector<unsigned> f_im;
};

namespace detail {

inline std::vector<std::string> split(const std::string& line) {
  std::vector<std::string> out;
  std::istringstream is(line);
  std::string tok;
  while (is >> tok) out.push_back(tok);
  return out;
}

inline bool parse_i64(const std::string& s, long long* out) {
  char* end = nullptr;
  const long long v = std::strtoll(s.c_str(), &end, 10);
  if (end == s.c_str() || *end != '\0') return false;
  *out = v;
  return true;
}

// `# key: value` -> (key, value). Returns false for a non-header comment.
inline bool header_kv(const std::string& line, std::string* key,
                      std::string* value) {
  if (line.empty() || line[0] != '#') return false;
  const std::size_t colon = line.find(':');
  if (colon == std::string::npos) return false;
  std::size_t ks = 1;
  while (ks < colon && std::isspace(static_cast<unsigned char>(line[ks]))) ++ks;
  std::size_t ke = colon;
  while (ke > ks && std::isspace(static_cast<unsigned char>(line[ke - 1]))) --ke;
  std::size_t vs = colon + 1;
  while (vs < line.size() &&
         std::isspace(static_cast<unsigned char>(line[vs]))) ++vs;
  std::size_t ve = line.size();
  while (ve > vs && std::isspace(static_cast<unsigned char>(line[ve - 1]))) --ve;
  *key = line.substr(ks, ke - ks);
  *value = line.substr(vs, ve - vs);
  return true;
}

inline unsigned to_u(const std::string& s) {
  return static_cast<unsigned>(std::strtoul(s.c_str(), nullptr, 10));
}

}  // namespace detail

// Loads a `.coeff` file into phase-major order. `err` receives a diagnosis on
// failure and is left untouched on success.
inline bool load_coeff(const std::string& path, std::vector<Complex>* out,
                       CoeffHeader* header, std::string* err) {
  std::ifstream f(path);
  if (!f) {
    *err = "cannot open " + path;
    return false;
  }
  CoeffHeader h;
  std::vector<Complex> values;
  std::string line;
  std::size_t records = 0;

  while (std::getline(f, line)) {
    if (!line.empty() && line.back() == '\r') line.pop_back();
    std::string k, v;
    if (detail::header_kv(line, &k, &v)) {
      if (k == "schema") h.schema = static_cast<int>(detail::to_u(v));
      else if (k == "kind") h.kind = v;
      else if (k == "set") h.set = v;
      else if (k == "window") h.window = v;
      else if (k == "rounding_mode") h.rounding_mode = v;
      else if (k == "phases") h.phases = detail::to_u(v);
      else if (k == "taps") h.taps = detail::to_u(v);
      else if (k == "coeff_w") h.coeff_w = detail::to_u(v);
      else if (k == "frac_w") h.frac_w = detail::to_u(v);
      else if (k == "seed") h.seed = std::strtoull(v.c_str(), nullptr, 10);
      else if (k == "count") h.declared_count = detail::to_u(v);
      continue;
    }
    if (line.empty() || line[0] == '#') continue;

    const std::vector<std::string> fields = detail::split(line);
    if (fields.size() != 5) {
      *err = path + ": expected 5 fields, got " +
             std::to_string(fields.size()) + " in \"" + line + "\"";
      return false;
    }
    long long idx = 0, phase = 0, tap = 0, re = 0, im = 0;
    if (!detail::parse_i64(fields[0], &idx) ||
        !detail::parse_i64(fields[1], &phase) ||
        !detail::parse_i64(fields[2], &tap) ||
        !detail::parse_i64(fields[3], &re) ||
        !detail::parse_i64(fields[4], &im)) {
      *err = path + ": cannot parse \"" + line + "\"";
      return false;
    }
    // The index column is redundant with the row order, which is exactly why it
    // is checked: a file whose rows were reordered by a well-meaning edit would
    // otherwise load a silently different filter.
    if (static_cast<std::size_t>(idx) != records) {
      *err = path + ": row " + std::to_string(records) +
             " declares index " + std::to_string(idx);
      return false;
    }
    if (h.taps != 0 &&
        static_cast<std::size_t>(idx) !=
            coeff_index(h.taps, static_cast<unsigned>(phase),
                        static_cast<unsigned>(tap))) {
      *err = path + ": index " + std::to_string(idx) +
             " does not match (phase " + std::to_string(phase) + ", tap " +
             std::to_string(tap) + ")";
      return false;
    }
    values.push_back(Complex{static_cast<i16>(re), static_cast<i16>(im)});
    ++records;
  }

  if (h.schema != kSchemaVersion) {
    *err = path + ": schema " + std::to_string(h.schema) + ", expected " +
           std::to_string(kSchemaVersion);
    return false;
  }
  if (h.kind != "pfb_coeff") {
    *err = path + ": kind \"" + h.kind + "\", expected \"pfb_coeff\"";
    return false;
  }
  if (h.declared_count != records) {
    *err = path + ": declares " + std::to_string(h.declared_count) +
           " records but holds " + std::to_string(records);
    return false;
  }
  if (static_cast<std::size_t>(h.phases) * h.taps != records) {
    *err = path + ": " + std::to_string(records) + " records for a " +
           std::to_string(h.phases) + "x" + std::to_string(h.taps) + " bank";
    return false;
  }
  *out = values;
  if (header) *header = h;
  return true;
}

inline bool load_io(const std::string& path, std::vector<IoVector>* out,
                    IoHeader* header, std::string* err) {
  std::ifstream f(path);
  if (!f) {
    *err = "cannot open " + path;
    return false;
  }
  IoHeader h;
  std::vector<IoVector> values;
  std::string line;

  while (std::getline(f, line)) {
    if (!line.empty() && line.back() == '\r') line.pop_back();
    std::string k, v;
    if (detail::header_kv(line, &k, &v)) {
      if (k == "schema") h.schema = static_cast<int>(detail::to_u(v));
      else if (k == "kind") h.kind = v;
      else if (k == "set") h.set = v;
      else if (k == "coeff_file") h.coeff_file = v;
      else if (k == "rounding_mode") h.rounding_mode = v;
      else if (k == "phases") h.phases = detail::to_u(v);
      else if (k == "taps") h.taps = detail::to_u(v);
      else if (k == "acc_w") h.acc_w = detail::to_u(v);
      else if (k == "seed") h.seed = std::strtoull(v.c_str(), nullptr, 10);
      else if (k == "count") h.declared_count = detail::to_u(v);
      continue;
    }
    if (line.empty() || line[0] == '#') continue;

    const std::vector<std::string> fields = detail::split(line);
    // beat + (x, y) as 2 columns per phase each + (f_re, f_im) per phase.
    const std::size_t want = 1 + 6u * h.phases;
    if (h.phases == 0 || fields.size() != want) {
      *err = path + ": expected " + std::to_string(want) + " fields, got " +
             std::to_string(fields.size());
      return false;
    }
    IoVector r;
    std::size_t c = 0;
    long long tmp = 0;
    if (!detail::parse_i64(fields[c++], &tmp)) {
      *err = path + ": cannot parse beat index";
      return false;
    }
    r.beat = static_cast<std::size_t>(tmp);

    auto take_complex = [&](std::vector<Complex>* dst) -> bool {
      for (unsigned p = 0; p < h.phases; ++p) {
        long long re = 0, im = 0;
        if (!detail::parse_i64(fields[c++], &re)) return false;
        if (!detail::parse_i64(fields[c++], &im)) return false;
        dst->push_back(Complex{static_cast<i16>(re), static_cast<i16>(im)});
      }
      return true;
    };

    if (!take_complex(&r.x) || !take_complex(&r.y)) {
      *err = path + ": cannot parse sample columns of beat " +
             std::to_string(r.beat);
      return false;
    }
    for (unsigned p = 0; p < h.phases; ++p) {
      long long fr = 0, fi = 0;
      if (!detail::parse_i64(fields[c++], &fr) ||
          !detail::parse_i64(fields[c++], &fi)) {
        *err = path + ": cannot parse flag columns of beat " +
               std::to_string(r.beat);
        return false;
      }
      r.f_re.push_back(static_cast<unsigned>(fr));
      r.f_im.push_back(static_cast<unsigned>(fi));
    }
    values.push_back(std::move(r));
  }

  if (h.schema != kSchemaVersion) {
    *err = path + ": schema " + std::to_string(h.schema) + ", expected " +
           std::to_string(kSchemaVersion);
    return false;
  }
  if (h.kind != "pfb_io") {
    *err = path + ": kind \"" + h.kind + "\", expected \"pfb_io\"";
    return false;
  }
  if (h.declared_count != values.size()) {
    *err = path + ": declares " + std::to_string(h.declared_count) +
           " beats but holds " + std::to_string(values.size());
    return false;
  }
  if (h.acc_w != 0 && h.acc_w != acc_w(h.taps)) {
    *err = path + ": declares acc_w " + std::to_string(h.acc_w) +
           " but the C++ model computes " + std::to_string(acc_w(h.taps));
    return false;
  }
  *out = values;
  if (header) *header = h;
  return true;
}

// The rounding mode this build was compiled for, as it appears in a file
// header. A vector set produced under the other mode must fail immediately
// rather than "pass" against whichever implementation happens to match.
inline const char* expected_rounding_mode() {
  return fxp::kRoundMode == fxp::RoundMode::kHalfUp ? "half_up"
                                                    : "nearest_even";
}

}  // namespace pfb

#endif  // MODEL_CPP_PFB_PFB_MODEL_HPP_
