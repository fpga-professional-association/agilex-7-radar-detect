// -----------------------------------------------------------------------------
// cfar_model.hpp — bit-exact C++ twin of rtl/cfar/ (SPEC.md 7.7, 12.4).
//
// SPEC 12.4 requires a reference model for every kernel and SPEC 6 requires the
// model and the RTL to use identical numerical rules. This header is that model
// for the CFAR detector:
//
//   cfar::over_threshold()  rtl/packages/cfar_pkg.sv, cfar_over_threshold()
//   cfar::clamp_config()    rtl/cfar/cfar_core.sv, the geometry clamp
//   cfar::run_frame()       rtl/cfar/cfar_core.sv + cfar_window.sv, one frame in,
//                           the exact event sequence out
//
// FUNCTIONAL, NOT CYCLE-ACCURATE, and that is a deliberate difference from
// model/cpp/covariance/covar_model.hpp. The covariance model is stepped once per
// clock edge because its SUBJECT is window timing — when a window closes is the
// thing under test. The CFAR detector's subject is the detection ARITHMETIC and
// the event SEQUENCE; its pipeline depth is an implementation choice that
// SPEC 23 explicitly invites changing for timing closure. A cycle-accurate model
// would therefore have to be edited every time a register is added to the
// datapath, and each such edit is an opportunity to make the model agree with a
// bug. Modelling the frame -> event-sequence function instead means the oracle
// is invariant to pipeline depth, to backpressure, and to the phantom-flush
// mechanism, while still being EXACT on every value and every ordering:
//
//   * the detection set is compared bin for bin, not statistically;
//   * every emitted event is compared field for field, including the reference
//     sum, the reference count and the threshold multiplier;
//   * the order of events is compared, not just their membership.
//
// The one thing this model deliberately does NOT predict is WHICH CYCLE an event
// appears on. sim/tests/test_cfar.cpp checks that separately and structurally:
// the same stimulus under randomized backpressure must produce a byte-identical
// event sequence, which is a stronger statement about the pipeline than any
// single predicted latency would be.
//
// There is no floating point anywhere in this file. The threshold comparison is
// an integer inequality (cfar_pkg section 3), so "bit exact" is a property of
// the arithmetic rather than of a tolerance.
//
// Header-only. Build contract: g++ 13, -std=c++17 -O3 -Wall -Wextra -Werror.
// -----------------------------------------------------------------------------
#ifndef MODEL_CPP_CFAR_CFAR_MODEL_HPP_
#define MODEL_CPP_CFAR_CFAR_MODEL_HPP_

#include <cstdint>
#include <string>
#include <vector>

namespace cfar {

// ---------------------------------------------------------------------------
// Widths (cfar_pkg)
// ---------------------------------------------------------------------------
inline constexpr unsigned kPowerW = 40;      // CFAR_POWER_W (covar POWER_W)
inline constexpr unsigned kBinW = 16;        // CFAR_BIN_W
inline constexpr unsigned kFrameIdW = 16;    // CFAR_FRAME_ID_W
inline constexpr unsigned kCntW = 16;        // CFAR_CNT_W
inline constexpr unsigned kAlphaW = 16;      // CFAR_ALPHA_W
inline constexpr unsigned kAlphaFracW = 8;   // CFAR_ALPHA_FRAC_W
inline constexpr unsigned kGuardCntW = 5;    // CFAR_GUARD_CNT_W
inline constexpr unsigned kRefCntW = 6;      // CFAR_REF_CNT_W
inline constexpr unsigned kTotRefW = kRefCntW + 1;      // CFAR_TOTREF_W
inline constexpr unsigned kSumW = kPowerW + kTotRefW;   // CFAR_SUM_W == 47
inline constexpr unsigned kEvKindW = 2;      // CFAR_EV_KIND_W

// alpha = 1.0 exactly, in UQ8.8 — the identity multiplier.
inline constexpr unsigned kAlphaOne = 1u << kAlphaFracW;

// ---------------------------------------------------------------------------
// Event layout (cfar_pkg, NORMATIVE section). The offsets are accumulated in the
// same order the SystemVerilog layout walk uses, so a field inserted on one side
// and not the other fails the geometry check in sim/tests/test_cfar.cpp before
// any stimulus runs.
// ---------------------------------------------------------------------------
inline constexpr unsigned kEvKindLsb = 0;
inline constexpr unsigned kEvBinLsb = kEvKindLsb + kEvKindW;
inline constexpr unsigned kEvFrameIdLsb = kEvBinLsb + kBinW;
inline constexpr unsigned kEvRefCntLsb = kEvFrameIdLsb + kFrameIdW;
inline constexpr unsigned kEvAlphaLsb = kEvRefCntLsb + kTotRefW;
inline constexpr unsigned kEvDetLsb = kEvAlphaLsb + kAlphaW;
inline constexpr unsigned kEvSupLsb = kEvDetLsb + kCntW;
inline constexpr unsigned kEvCellLsb = kEvSupLsb + kCntW;
inline constexpr unsigned kEvSumLsb = kEvCellLsb + kPowerW;
inline constexpr unsigned kEventW = kEvSumLsb + kSumW;   // 176

// ---------------------------------------------------------------------------
// Modes and event kinds
// ---------------------------------------------------------------------------
enum class Mode : unsigned { kCA = 0, kGO = 1 };
enum class OutMode : unsigned { kEvents = 0, kDense = 1 };

enum Kind : unsigned {
  kEvDetect = 0,
  kEvBin = 1,
  kEvSuppressed = 2,
  kEvSummary = 3,
};

inline const char* kind_name(unsigned k) {
  switch (k) {
    case kEvDetect: return "DETECT";
    case kEvBin: return "BIN";
    case kEvSuppressed: return "SUPPRESSED";
    case kEvSummary: return "SUMMARY";
    default: return "?";
  }
}

// ---------------------------------------------------------------------------
// Configuration — the register plane's view, before clamping
// ---------------------------------------------------------------------------
struct Config {
  bool enable = true;
  Mode mode = Mode::kCA;
  OutMode out_mode = OutMode::kEvents;
  unsigned guard_lead = 2;
  unsigned guard_lag = 2;
  unsigned ref_lead = 8;
  unsigned ref_lag = 8;
  unsigned alpha = kAlphaOne;

  bool operator==(const Config& o) const {
    return enable == o.enable && mode == o.mode && out_mode == o.out_mode &&
           guard_lead == o.guard_lead && guard_lag == o.guard_lag &&
           ref_lead == o.ref_lead && ref_lag == o.ref_lag && alpha == o.alpha;
  }
  bool operator!=(const Config& o) const { return !(*this == o); }
};

// The geometry clamp of cfar_core section 5. Out of range is DEFINED — a
// register plane can be programmed with anything — and the clamp is applied at
// the frame boundary, so it is part of the active configuration rather than of
// the comparison.
inline Config clamp_config(const Config& c, unsigned max_guard, unsigned max_ref) {
  Config o = c;
  if (o.guard_lead > max_guard) o.guard_lead = max_guard;
  if (o.guard_lag > max_guard) o.guard_lag = max_guard;
  if (o.ref_lead > max_ref) o.ref_lead = max_ref;
  if (o.ref_lag > max_ref) o.ref_lag = max_ref;
  return o;
}

// True when the clamp changed anything — CFAR_FAULT.CFG_CLAMPED.
inline bool config_clamped(const Config& c, unsigned max_guard, unsigned max_ref) {
  return clamp_config(c, max_guard, max_ref) != c;
}

// Does the selected mode have a usable reference geometry (cfar_core section 2)?
inline bool refs_usable(const Config& c) {
  if (c.mode == Mode::kGO) return c.ref_lead != 0 && c.ref_lag != 0;
  return (c.ref_lead + c.ref_lag) != 0;
}

// ---------------------------------------------------------------------------
// The comparison  (cfar_pkg equation (*))
//
//     detect  <=>  C * N * 2^F  >  A * S
//
// Every operand is bounded so that both sides fit an unsigned 64-bit integer
// (cfar_pkg section 3), which is why this is one line and not a big-integer
// routine.
// ---------------------------------------------------------------------------
inline std::uint64_t cmp_lhs(std::uint64_t cut, std::uint64_t n_ref) {
  return (cut * n_ref) << kAlphaFracW;
}

inline std::uint64_t cmp_rhs(std::uint64_t alpha, std::uint64_t sum) {
  return alpha * sum;
}

inline bool over_threshold(std::uint64_t cut, std::uint64_t sum,
                           std::uint64_t n_ref, std::uint64_t alpha) {
  return cmp_lhs(cut, n_ref) > cmp_rhs(alpha, sum);
}

// ---------------------------------------------------------------------------
// One emitted event
// ---------------------------------------------------------------------------
struct Event {
  unsigned kind = kEvSummary;
  unsigned bin = 0;           // bin index; the frame LENGTH on a summary
  unsigned frame_id = 0;
  unsigned ref_count = 0;
  unsigned alpha = 0;
  unsigned det_count = 0;     // summary only
  unsigned sup_count = 0;     // summary only
  std::uint64_t cut_power = 0;
  std::uint64_t noise_sum = 0;

  // SPEC 5 framing of the OUTPUT stream.
  bool sof = false;
  bool eof = false;

  bool operator==(const Event& o) const {
    return kind == o.kind && bin == o.bin && frame_id == o.frame_id &&
           ref_count == o.ref_count && alpha == o.alpha &&
           det_count == o.det_count && sup_count == o.sup_count &&
           cut_power == o.cut_power && noise_sum == o.noise_sum &&
           sof == o.sof && eof == o.eof;
  }
  bool operator!=(const Event& o) const { return !(*this == o); }

  std::string str() const {
    std::string s = std::string(kind_name(kind)) + " bin=" + std::to_string(bin) +
                    " frame=" + std::to_string(frame_id) +
                    " alpha=" + std::to_string(alpha);
    if (kind == kEvSummary) {
      s += " det=" + std::to_string(det_count) + " sup=" + std::to_string(sup_count);
    } else {
      s += " cut=" + std::to_string(cut_power) + " sum=" + std::to_string(noise_sum) +
           " n=" + std::to_string(ref_count);
    }
    if (sof) s += " [sof]";
    if (eof) s += " [eof]";
    return s;
  }
};

// ---------------------------------------------------------------------------
// Per-bin decision, exposed so a test can inspect one bin without reconstructing
// the whole frame. This IS the body of run_frame()'s loop.
// ---------------------------------------------------------------------------
struct Decision {
  bool window_ok = false;   // the full programmed window lies inside the frame
  bool evaluable = false;   // window_ok AND enabled AND the mode has references
  bool detected = false;
  bool suppressed = false;
  std::uint64_t cut_power = 0;
  std::uint64_t sum_lead = 0;
  std::uint64_t sum_lag = 0;
  std::uint64_t sel_sum = 0;   // the sum the comparison actually used
  unsigned sel_n = 0;          // and its reference count
  bool take_lead = false;      // greatest-of: the leading side governed
};

// The input cell as the RTL sees it: a signed POWER_W field, clamped to zero if
// negative (cfar_pkg section 1). The caller passes the raw signed value.
inline std::uint64_t clamp_cell(std::int64_t raw) {
  return raw < 0 ? 0u : static_cast<std::uint64_t>(raw);
}

// Decide one bin of a frame. `bins` are already clamped magnitudes.
inline Decision decide(const std::vector<std::uint64_t>& bins, std::size_t i,
                       const Config& cfg) {
  Decision d;
  const std::int64_t n = static_cast<std::int64_t>(bins.size());
  const std::int64_t idx = static_cast<std::int64_t>(i);
  d.cut_power = bins[i];

  // Leading reference cells are at HIGHER bin indices, lagging at lower —
  // cfar_window section 1. The guard cells sit between the cell under test and
  // the reference cells and are skipped, not summed.
  bool ok = true;
  for (unsigned j = 1; j <= cfg.ref_lead; ++j) {
    const std::int64_t k = idx + static_cast<std::int64_t>(cfg.guard_lead + j);
    if (k >= n) { ok = false; break; }
    d.sum_lead += bins[static_cast<std::size_t>(k)];
  }
  if (ok) {
    for (unsigned j = 1; j <= cfg.ref_lag; ++j) {
      const std::int64_t k = idx - static_cast<std::int64_t>(cfg.guard_lag + j);
      if (k < 0) { ok = false; break; }
      d.sum_lag += bins[static_cast<std::size_t>(k)];
    }
  }
  d.window_ok = ok;

  if (cfg.mode == Mode::kGO) {
    // The greater MEAN, decided by one cross-multiply rather than a division.
    // Ties go to the leading side, exactly as the RTL's `>=` does.
    d.take_lead = (d.sum_lead * cfg.ref_lag) >= (d.sum_lag * cfg.ref_lead);
    d.sel_sum = d.take_lead ? d.sum_lead : d.sum_lag;
    d.sel_n = d.take_lead ? cfg.ref_lead : cfg.ref_lag;
  } else {
    d.take_lead = true;
    d.sel_sum = d.sum_lead + d.sum_lag;
    d.sel_n = cfg.ref_lead + cfg.ref_lag;
  }

  d.evaluable = d.window_ok && cfg.enable && refs_usable(cfg);
  d.detected = d.evaluable && over_threshold(d.cut_power, d.sel_sum, d.sel_n,
                                             cfg.alpha);
  d.suppressed = !d.evaluable;
  return d;
}

// ---------------------------------------------------------------------------
// One frame in, the exact event sequence out.
//
// `cfg` is the configuration as WRITTEN; the clamp is applied here because the
// RTL applies it when it latches at the frame boundary, so a test that programs
// an out-of-range geometry gets the same answer from both sides without having
// to clamp by hand.
// ---------------------------------------------------------------------------
inline std::vector<Event> run_frame(const std::vector<std::uint64_t>& bins,
                                    const Config& written, unsigned max_guard,
                                    unsigned max_ref, unsigned frame_id) {
  const Config cfg = clamp_config(written, max_guard, max_ref);
  std::vector<Event> out;
  out.reserve(bins.size() + 1);

  unsigned det = 0;
  unsigned sup = 0;

  for (std::size_t i = 0; i < bins.size(); ++i) {
    const Decision d = decide(bins, i, cfg);
    if (d.detected) ++det;
    if (d.suppressed) ++sup;

    const bool emit = d.detected || (cfg.out_mode == OutMode::kDense);
    if (!emit) continue;

    Event e;
    e.kind = d.detected ? kEvDetect : (d.suppressed ? kEvSuppressed : kEvBin);
    e.bin = static_cast<unsigned>(i);
    e.frame_id = frame_id;
    e.alpha = cfg.alpha;
    e.cut_power = d.cut_power;
    // A suppressed bin has no valid reference window, so it reports none.
    e.ref_count = d.suppressed ? 0u : d.sel_n;
    e.noise_sum = d.suppressed ? 0u : d.sel_sum;
    out.push_back(e);
  }

  Event s;
  s.kind = kEvSummary;
  s.bin = static_cast<unsigned>(bins.size());
  s.frame_id = frame_id;
  s.alpha = cfg.alpha;
  s.det_count = det;
  s.sup_count = sup;
  s.eof = true;
  out.push_back(s);

  // SPEC 5 framing: start_of_frame on the first emitted beat, end_of_frame on
  // the summary. A frame with no detections is a well-formed one-beat frame with
  // both bits set.
  out.front().sof = true;
  return out;
}

// Number of bins at each frame edge that no configuration can evaluate, at the
// ELABORATED maxima — the structural half-window. cfar_pkg::cfar_half_window().
inline constexpr unsigned half_window(unsigned max_guard, unsigned max_ref) {
  return max_guard + max_ref;
}

inline constexpr unsigned window_slots(unsigned max_guard, unsigned max_ref) {
  return 2u * half_window(max_guard, max_ref) + 1u;
}

// Internal reference-sum width for an elaboration — cfar_pkg::cfar_sum_w().
inline constexpr unsigned sum_w(unsigned max_ref) {
  const unsigned n = (max_ref == 0) ? 1u : 2u * max_ref;
  unsigned bits = 0;
  unsigned v = n;  // ceil(log2(n+1)) == $clog2(n+1) for n >= 1
  while (v != 0) {
    v >>= 1;
    ++bits;
  }
  return kPowerW + bits;
}

inline constexpr unsigned cmp_w(unsigned max_ref) {
  const unsigned lhs = kPowerW + kTotRefW + kAlphaFracW;
  const unsigned rhs = sum_w(max_ref) + kAlphaW;
  return lhs > rhs ? lhs : rhs;
}

}  // namespace cfar

#endif  // MODEL_CPP_CFAR_CFAR_MODEL_HPP_
