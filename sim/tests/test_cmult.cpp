// -----------------------------------------------------------------------------
// test_cmult.cpp — complex-multiplier verification (issue #9; SPEC 6, 13.1, 14).
//
// Closes the same triangle the numerics cross-check closes, one level up. Every
// operand pair is evaluated by:
//
//   * twelve RTL instances — both VARIANTs at every legal PIPE_STAGES, plus the
//     ROUND_OUT=0 pair (sim/verilator/tops/cmult_top.sv),
//   * the bit-accurate C++ model (model/cpp/fxp/cmult.hpp), through BOTH of its
//     independently written arithmetic paths, and
//   * for the directed set, the independent NumPy expectation committed in
//     model/vectors/cmult.vec.
//
// and every one of those must agree bit-for-bit on the exact 33-bit product, the
// rounded Q1.15 product, both flag words and the overflow summary. Which pair
// disagrees is reported separately, because that is the diagnosis.
//
// Five passes:
//
//   1. directed vectors      model/vectors/cmult.vec, back to back. 864 records:
//                            the 144-pair corner grid (including (-1-1j)^2, the
//                            case that needs the 33rd bit), the round-then-
//                            saturate boundary swept one LSB at a time in both
//                            directions, the Karatsuba pre-adder extremes, and a
//                            seeded random set.
//   2. random, dense         >= 10 000 fresh pairs per seed with valid held high,
//                            drawn from the harness's named-substream generator
//                            so the stream depends only on +seed.
//   3. random, gapped        the same again with a bursty valid pattern. Gaps are
//                            what make the valid pipeline falsifiable: a beat
//                            emitted one cycle early or late lands against the
//                            wrong scoreboard entry and fails immediately, which
//                            a back-to-back stream cannot detect.
//   4. latency sweep         one isolated beat per DUT; the measured input-to-
//                            output delay must equal the PIPE_STAGES the RTL
//                            itself reports through cfg_pipe_stages.
//   5. flag audit            requires that the run actually observed saturation
//                            in both directions on both components. A flag test
//                            that never saturates passes vacuously.
//
// Observation. All twelve DUTs are stimulated in parallel; the top muxes one to
// the output ports and the test re-evaluates the model once per DUT per cycle.
// One stimulus stream is therefore observed by all twelve, so "the two variants
// agree" is a same-cycle comparison rather than a comparison of two runs.
//
// The RTL carries its own checks in parallel with this file: cmult_assertions
// watches every matched MULT4/MULT3 pair on every cycle, and complex_multiplier
// itself asserts its arithmetic core against fxp_pkg's canonical definition. A
// Verilator assertion failure aborts the run, so those are gates on this test
// even though nothing here references them.
//
// Built by `make sim-tiny` as:
//   scripts/build_verilator.py --mode fast --top cmult_top
//       --files sim/verilator/files_cmult.f --test test_cmult
// -----------------------------------------------------------------------------

#include <chrono>
#include <cstdint>
#include <cstdio>
#include <deque>
#include <memory>
#include <random>
#include <string>
#include <vector>

#include "Vcmult_top.h"
#include "verilated.h"

#include "config_sim.h"
#include "harness/error_collector.h"
#include "harness/random.h"
#include "harness/run_summary.h"
#include "harness/sim_args.h"

#include "fxp/cmult.hpp"
#include "fxp/fxp.hpp"
#include "fxp/fxp_vectors.hpp"

using harness::ErrorCollector;
using harness::RunSummary;
using harness::SimArgs;

namespace {

constexpr const char* kTestName = "test_cmult";

// Mirror of the DUT grid in sim/verilator/tops/cmult_top.sv. Checked against the
// RTL's own cfg_* echo for every index before anything else runs, so a drift is
// a named failure rather than a silently wrong comparison.
constexpr unsigned kNDut = 12;
constexpr unsigned kDutStages[kNDut] = {1, 2, 3, 4, 5, 1, 2, 3, 4, 5, 3, 3};
constexpr bool kDutMult3[kNDut] = {false, false, false, false, false,
                                   true,  true,  true,  true,  true,
                                   false, true};
constexpr bool kDutRound[kNDut] = {true, true, true, true, true, true,
                                   true, true, true, true, false, false};

// Random-pass sizes. The gate asks for at least ten thousand random inputs per
// seed; each of passes 2 and 3 exceeds that on its own, and every beat is
// checked against twelve RTL instances and two model paths.
constexpr std::size_t kDenseBeats = 12000;
constexpr std::size_t kGappedBeats = 12000;

// ---------------------------------------------------------------------------
// Failure accounting. The relation that disagrees is the diagnosis, so the
// counts are kept apart rather than summed (NUMERICS.md 10, triage procedure).
// ---------------------------------------------------------------------------
struct Counters {
  std::size_t rtl_vs_model = 0;
  std::size_t rtl_vs_vector = 0;
  std::size_t model_vs_vector = 0;
  std::size_t variant_mismatch = 0;
  std::size_t latency = 0;
  std::size_t alignment = 0;
  std::size_t config = 0;

  std::size_t total() const {
    return rtl_vs_model + rtl_vs_vector + model_vs_vector + variant_mismatch +
           latency + alignment + config;
  }
};

void report(ErrorCollector* errors, const char* category, std::size_t* counter,
            const std::string& message) {
  ++*counter;
  errors->error(category, message);
}

std::string cplx_str(fxp::Complex c) {
  return "(" + std::to_string(c.re) + "," + std::to_string(c.im) + ")";
}

std::string flags_str(unsigned packed) {
  const fxp::Flags f = fxp::Flags::from_packed(packed);
  return std::string(f.sat_pos ? "+" : ".") + (f.sat_neg ? "-" : ".");
}

std::string dut_str(unsigned i) {
  return std::string("dut") + std::to_string(i) + "[" +
         (kDutMult3[i] ? "MULT3" : "MULT4") + " stages=" +
         std::to_string(kDutStages[i]) + " round=" +
         std::to_string(kDutRound[i] ? 1 : 0) + "]";
}

// ---------------------------------------------------------------------------
// One observation of a DUT, as read through the top's mux.
// ---------------------------------------------------------------------------
struct Observation {
  bool valid = false;
  fxp::wide_t p_re = 0;
  fxp::wide_t p_im = 0;
  fxp::i16 y_re = 0;
  fxp::i16 y_im = 0;
  unsigned flags_re = 0;
  unsigned flags_im = 0;
  bool ovf = false;
};

// Sign-extends the 33-bit full-precision port out of its 64-bit carrier.
fxp::wide_t sext33(std::uint64_t raw) {
  constexpr unsigned w = fxp::cmult::kCmulProdW;  // 33
  const std::uint64_t masked = raw & ((1ULL << w) - 1ULL);
  const std::uint64_t sign = 1ULL << (w - 1);
  return fxp::from_bits((masked ^ sign) - sign);
}

Observation observe(Vcmult_top* top, unsigned dut) {
  top->dut_sel = static_cast<std::uint8_t>(dut);
  top->eval();
  Observation o;
  o.valid = top->valid_out != 0;
  o.p_re = sext33(top->p_re);
  o.p_im = sext33(top->p_im);
  o.y_re = static_cast<fxp::i16>(static_cast<std::uint16_t>(top->y_re));
  o.y_im = static_cast<fxp::i16>(static_cast<std::uint16_t>(top->y_im));
  o.flags_re = static_cast<unsigned>(top->flags_re);
  o.flags_im = static_cast<unsigned>(top->flags_im);
  o.ovf = top->ovf != 0;
  return o;
}

void drive(Vcmult_top* top, bool valid, fxp::Complex a, fxp::Complex b) {
  top->valid_in = valid ? 1 : 0;
  top->a_re = static_cast<std::uint16_t>(a.re);
  top->a_im = static_cast<std::uint16_t>(a.im);
  top->b_re = static_cast<std::uint16_t>(b.re);
  top->b_im = static_cast<std::uint16_t>(b.im);
}

// Settle combinationally, then take the clock edge. Everything observable is
// read BEFORE tick() so it reflects the beat the pipeline has already produced.
void tick(Vcmult_top* top) {
  top->clk = 0;
  top->eval();
  top->clk = 1;
  top->eval();
}

// ---------------------------------------------------------------------------
// Expected outputs for one operand pair, per DUT
// ---------------------------------------------------------------------------
struct Expectation {
  fxp::Complex a;
  fxp::Complex b;
  std::size_t index = 0;         // position in the stimulus stream
  const fxp::vectors::CmultVector* vec = nullptr;  // null for random beats
};

// Compares one DUT observation against the model (both arithmetic paths) and,
// when the beat came from the vector file, against the committed expectation.
void check_beat(unsigned dut, const Expectation& e, const Observation& o,
                ErrorCollector* errors, Counters* c,
                unsigned* seen_flags_re, unsigned* seen_flags_im) {
  const bool round_out = kDutRound[dut];
  const fxp::cmult::Variant primary = kDutMult3[dut]
                                          ? fxp::cmult::Variant::kMult3
                                          : fxp::cmult::Variant::kMult4;
  const fxp::cmult::Variant other = kDutMult3[dut]
                                        ? fxp::cmult::Variant::kMult4
                                        : fxp::cmult::Variant::kMult3;

  const fxp::cmult::Result m = fxp::cmult::eval(primary, e.a, e.b, round_out);
  const fxp::cmult::Result m2 = fxp::cmult::eval(other, e.a, e.b, round_out);

  const std::string where = dut_str(dut) + " beat " + std::to_string(e.index) +
                            " " + cplx_str(e.a) + "*" + cplx_str(e.b);

  // The model's own two paths must agree before either is used as an oracle.
  if (m != m2) {
    report(errors, "variant_mismatch", &c->variant_mismatch,
           where + ": the C++ model's MULT3 and MULT4 paths disagree");
  }

  if (o.p_re != m.p_re || o.p_im != m.p_im) {
    report(errors, "rtl_vs_model", &c->rtl_vs_model,
           where + ": full-precision RTL (" + std::to_string(o.p_re) + "," +
               std::to_string(o.p_im) + ") vs model (" +
               std::to_string(m.p_re) + "," + std::to_string(m.p_im) + ")");
  }
  if (o.y_re != m.y_re || o.y_im != m.y_im) {
    report(errors, "rtl_vs_model", &c->rtl_vs_model,
           where + ": rounded RTL (" + std::to_string(o.y_re) + "," +
               std::to_string(o.y_im) + ") vs model (" +
               std::to_string(m.y_re) + "," + std::to_string(m.y_im) + ")");
  }
  if (o.flags_re != m.f_re.packed() || o.flags_im != m.f_im.packed()) {
    report(errors, "rtl_vs_model", &c->rtl_vs_model,
           where + ": flags RTL " + flags_str(o.flags_re) + "/" +
               flags_str(o.flags_im) + " vs model " +
               flags_str(m.f_re.packed()) + "/" +
               flags_str(m.f_im.packed()));
  }
  if (o.ovf != m.ovf) {
    report(errors, "rtl_vs_model", &c->rtl_vs_model,
           where + ": ovf RTL " + std::to_string(o.ovf ? 1 : 0) + " vs model " +
               std::to_string(m.ovf ? 1 : 0));
  }

  *seen_flags_re |= o.flags_re;
  *seen_flags_im |= o.flags_im;

  if (e.vec == nullptr) return;

  // Directed beats additionally carry the independent NumPy expectation. The
  // vector file always states the ROUND_OUT=1 answer, so the rounded columns are
  // only compared against a DUT that rounds.
  const fxp::vectors::CmultVector& v = *e.vec;
  if (o.p_re != v.p_re || o.p_im != v.p_im) {
    report(errors, "rtl_vs_vector", &c->rtl_vs_vector,
           where + " [" + v.id + "]: full-precision RTL (" +
               std::to_string(o.p_re) + "," + std::to_string(o.p_im) +
               ") vs vector (" + std::to_string(v.p_re) + "," +
               std::to_string(v.p_im) + ")");
  }
  if (round_out &&
      (o.y_re != v.y_re || o.y_im != v.y_im || o.flags_re != v.flags_re ||
       o.flags_im != v.flags_im)) {
    report(errors, "rtl_vs_vector", &c->rtl_vs_vector,
           where + " [" + v.id + "]: rounded RTL (" + std::to_string(o.y_re) +
               "," + std::to_string(o.y_im) + ") " + flags_str(o.flags_re) +
               "/" + flags_str(o.flags_im) + " vs vector (" +
               std::to_string(v.y_re) + "," + std::to_string(v.y_im) + ") " +
               flags_str(v.flags_re) + "/" + flags_str(v.flags_im));
  }
  if (m.p_re != v.p_re || m.p_im != v.p_im ||
      (round_out && (m.y_re != v.y_re || m.y_im != v.y_im))) {
    report(errors, "model_vs_vector", &c->model_vs_vector,
           where + " [" + v.id + "]: the C++ model disagrees with the vector");
  }
}

// ---------------------------------------------------------------------------
// One stimulus pass. Drives `beats` (with their valid flags) and scoreboards
// every DUT's output stream against a per-DUT FIFO of expectations.
//
// The FIFO is what makes valid-pipeline misalignment detectable: an output beat
// is matched against the OLDEST outstanding input, so a result delivered one
// cycle early or late — or an extra or missing valid — lands against the wrong
// operands and fails on content, and the residual queue depth at the end of the
// pass fails on alignment.
// ---------------------------------------------------------------------------
struct Beat {
  bool valid = false;
  fxp::Complex a;
  fxp::Complex b;
  const fxp::vectors::CmultVector* vec = nullptr;
};

std::size_t run_pass(Vcmult_top* top, const char* pass_name,
                     const std::vector<Beat>& beats, ErrorCollector* errors,
                     Counters* c, unsigned* seen_flags_re,
                     unsigned* seen_flags_im) {
  std::deque<Expectation> pending[kNDut];
  std::size_t observed = 0;

  // Drain: the deepest pipeline is kDutStages max; a few extra idle cycles let
  // every DUT finish. Idle cycles carry valid low and are not scoreboarded.
  unsigned max_stages = 0;
  for (unsigned i = 0; i < kNDut; ++i) {
    if (kDutStages[i] > max_stages) max_stages = kDutStages[i];
  }
  const std::size_t total_cycles = beats.size() + max_stages + 4;

  std::size_t next_in = 0;
  for (std::size_t cyc = 0; cyc < total_cycles; ++cyc) {
    const bool have_input = next_in < beats.size();
    const Beat b = have_input ? beats[next_in] : Beat{};
    drive(top, have_input && b.valid, b.a, b.b);

    // Read every DUT's current output BEFORE the edge. The mux is combinational,
    // so re-selecting and re-evaluating does not disturb any sequential state.
    for (unsigned d = 0; d < kNDut; ++d) {
      const Observation o = observe(top, d);
      if (!o.valid) continue;
      ++observed;
      if (pending[d].empty()) {
        report(errors, "alignment", &c->alignment,
               std::string(pass_name) + ": " + dut_str(d) +
                   " produced a valid beat with no outstanding input");
        continue;
      }
      const Expectation e = pending[d].front();
      pending[d].pop_front();
      check_beat(d, e, o, errors, c, seen_flags_re, seen_flags_im);
    }

    // Restore the shared stimulus view before the edge (observe() left dut_sel
    // pointing at the last DUT; the value has no effect on sequential state, but
    // leaving it at 0 keeps a waveform readable).
    top->dut_sel = 0;
    top->eval();

    if (have_input && b.valid) {
      for (unsigned d = 0; d < kNDut; ++d) {
        pending[d].push_back(Expectation{b.a, b.b, next_in, b.vec});
      }
    }
    if (have_input) ++next_in;

    tick(top);
  }

  for (unsigned d = 0; d < kNDut; ++d) {
    if (!pending[d].empty()) {
      report(errors, "alignment", &c->alignment,
             std::string(pass_name) + ": " + dut_str(d) + " left " +
                 std::to_string(pending[d].size()) +
                 " input beats unanswered at the end of the pass");
    }
  }
  return observed;
}

// ---------------------------------------------------------------------------
// Reset
// ---------------------------------------------------------------------------
void reset(Vcmult_top* top) {
  drive(top, false, fxp::Complex{}, fxp::Complex{});
  top->dut_sel = 0;
  top->rst_n = 0;
  for (int i = 0; i < 8; ++i) tick(top);
  top->rst_n = 1;
  // One idle cycle after release so the valid chains are provably clear before
  // the first stimulus beat.
  tick(top);
}

// ---------------------------------------------------------------------------
// Pass 4 — latency sweep, measured against the RTL's own parameter echo
// ---------------------------------------------------------------------------
void run_latency_sweep(Vcmult_top* top, ErrorCollector* errors, Counters* c) {
  for (unsigned d = 0; d < kNDut; ++d) {
    reset(top);

    // Read the DUT's own view of its parameters and check the C++ mirror.
    top->dut_sel = static_cast<std::uint8_t>(d);
    top->eval();
    const unsigned rtl_stages = top->cfg_pipe_stages;
    const bool rtl_mult3 = top->cfg_variant_mult3 != 0;
    const bool rtl_round = top->cfg_round_out != 0;
    if (rtl_stages != kDutStages[d] || rtl_mult3 != kDutMult3[d] ||
        rtl_round != kDutRound[d]) {
      report(errors, "config", &c->config,
             dut_str(d) + ": RTL reports stages=" + std::to_string(rtl_stages) +
                 " mult3=" + std::to_string(rtl_mult3 ? 1 : 0) + " round=" +
                 std::to_string(rtl_round ? 1 : 0) +
                 ", the test's mirror disagrees");
      continue;
    }

    // One isolated valid beat, then idle. Count edges until valid_out rises.
    const fxp::Complex a{12345, -6789};
    const fxp::Complex b{-23456, 4321};

    drive(top, true, a, b);
    top->dut_sel = static_cast<std::uint8_t>(d);
    top->eval();
    tick(top);
    drive(top, false, fxp::Complex{}, fxp::Complex{});

    int measured = -1;
    for (unsigned k = 1; k <= 16; ++k) {
      const Observation o = observe(top, d);
      if (o.valid) {
        measured = static_cast<int>(k);
        const fxp::cmult::Result m = fxp::cmult::eval(
            rtl_mult3 ? fxp::cmult::Variant::kMult3
                      : fxp::cmult::Variant::kMult4,
            a, b, rtl_round);
        if (o.p_re != m.p_re || o.p_im != m.p_im || o.y_re != m.y_re ||
            o.y_im != m.y_im) {
          report(errors, "rtl_vs_model", &c->rtl_vs_model,
                 dut_str(d) + ": isolated beat content disagrees with the model");
        }
        break;
      }
      tick(top);
    }

    if (measured < 0) {
      report(errors, "latency", &c->latency,
             dut_str(d) + ": no output within 16 cycles of a single input beat");
    } else if (static_cast<unsigned>(measured) != rtl_stages) {
      report(errors, "latency", &c->latency,
             dut_str(d) + ": measured latency " + std::to_string(measured) +
                 " cycles, PIPE_STAGES is " + std::to_string(rtl_stages));
    }

    // The beat must be the ONLY output: a second valid would mean the valid
    // chain is generating beats the input never asked for.
    for (int k = 0; k < 8; ++k) {
      tick(top);
      if (observe(top, d).valid) {
        report(errors, "alignment", &c->alignment,
               dut_str(d) + ": a second output followed a single input beat");
        break;
      }
    }
  }
}

}  // namespace

// ---------------------------------------------------------------------------
// Test entry point (main() lives in sim/verilator/sim_main.cpp).
// ---------------------------------------------------------------------------
int harness::sim_test_main(const SimArgs& args) {
  const auto wall_start = std::chrono::steady_clock::now();

  const std::string dir = args.plusarg("vectors", "model/vectors");
  const std::string vec_path = dir + "/cmult.vec";

  ErrorCollector errors;
  Counters counters;

  std::vector<fxp::vectors::CmultVector> vecs;
  fxp::vectors::Header hdr;
  std::string err;
  if (!fxp::vectors::load_cmult(vec_path, &vecs, &hdr, &err)) {
    std::fprintf(stderr, "ERROR: %s\n", err.c_str());
    std::printf("RESULT: FAIL seed=%llu test=%s reason=vector_load: %s\n",
                static_cast<unsigned long long>(args.seed), kTestName,
                err.c_str());
    return 2;
  }
  if (hdr.rounding_mode != fxp::vectors::expected_rounding_mode() ||
      hdr.prod_w != fxp::cmult::kCmulProdW) {
    std::printf(
        "RESULT: FAIL seed=%llu test=%s reason=vector_header_mismatch "
        "(rounding_mode=%s prod_w=%u; build wants %s / %u)\n",
        static_cast<unsigned long long>(args.seed), kTestName,
        hdr.rounding_mode.c_str(), hdr.prod_w,
        fxp::vectors::expected_rounding_mode(), fxp::cmult::kCmulProdW);
    return 2;
  }

  std::unique_ptr<Vcmult_top> top(new Vcmult_top);
  reset(top.get());

  // The grid geometry the test assumes must be the grid that was elaborated.
  top->eval();
  if (top->cfg_n_dut != kNDut || top->cfg_prod_w != fxp::cmult::kCmulProdW) {
    std::printf(
        "RESULT: FAIL seed=%llu test=%s reason=grid_mismatch "
        "(rtl n_dut=%u prod_w=%u; test expects %u / %u)\n",
        static_cast<unsigned long long>(args.seed), kTestName,
        static_cast<unsigned>(top->cfg_n_dut),
        static_cast<unsigned>(top->cfg_prod_w), kNDut,
        fxp::cmult::kCmulProdW);
    return 2;
  }

  unsigned seen_flags_re = 0;
  unsigned seen_flags_im = 0;
  std::size_t observed = 0;

  // ---- pass 1: directed vectors, back to back -----------------------------
  {
    std::vector<Beat> beats;
    beats.reserve(vecs.size());
    for (const fxp::vectors::CmultVector& v : vecs) {
      beats.push_back(Beat{true, v.a, v.b, &v});
    }
    reset(top.get());
    observed += run_pass(top.get(), "directed", beats, &errors, &counters,
                         &seen_flags_re, &seen_flags_im);
  }

  // ---- passes 2 and 3: random, dense then gapped --------------------------
  harness::SeedSource seeds(args.seed);
  auto draw_q15 = [](std::mt19937_64& rng) {
    return static_cast<fxp::i16>(
        static_cast<std::int64_t>(harness::uniform_u64(rng, 0, 65535)) - 32768);
  };
  // A third of the random operands are drawn from the Q1.15 endpoints rather
  // than uniformly, so full-scale combinations — where saturation actually lives
  // — appear in the random stream too and not only in the directed set.
  static const fxp::i16 kEdge[] = {-32768, -32767, -16384, -1,   0,
                                   1,      16384,  32766,  32767};
  auto draw_operand = [&](std::mt19937_64& rng) {
    auto one = [&](void) -> fxp::i16 {
      if (harness::bernoulli(rng, 0.33)) {
        return kEdge[harness::uniform_u64(rng, 0, 8)];
      }
      return draw_q15(rng);
    };
    const fxp::i16 re = one();
    const fxp::i16 im = one();
    return fxp::Complex{re, im};
  };

  {
    std::mt19937_64 rng = seeds.engine("cmult.dense");
    std::vector<Beat> beats;
    beats.reserve(kDenseBeats);
    for (std::size_t i = 0; i < kDenseBeats; ++i) {
      beats.push_back(Beat{true, draw_operand(rng), draw_operand(rng), nullptr});
    }
    reset(top.get());
    observed += run_pass(top.get(), "random-dense", beats, &errors, &counters,
                         &seen_flags_re, &seen_flags_im);
  }

  {
    std::mt19937_64 rng = seeds.engine("cmult.gapped");
    harness::BackpressureGenerator gaps(seeds.engine("cmult.gaps"),
                                        harness::BackpressureConfig::bursty());
    std::vector<Beat> beats;
    beats.reserve(kGappedBeats * 2);
    std::size_t valid_beats = 0;
    while (valid_beats < kGappedBeats) {
      const bool v = gaps.allow();
      beats.push_back(Beat{v, draw_operand(rng), draw_operand(rng), nullptr});
      if (v) ++valid_beats;
    }
    reset(top.get());
    observed += run_pass(top.get(), "random-gapped", beats, &errors, &counters,
                         &seen_flags_re, &seen_flags_im);
  }

  // ---- pass 4: latency sweep ----------------------------------------------
  run_latency_sweep(top.get(), &errors, &counters);

  // ---- pass 5: flag audit -------------------------------------------------
  // Both saturation directions must have been observed on both components. A
  // flag check that never saturates proves nothing about the flags.
  const unsigned kSatPos = 2;
  const unsigned kSatNeg = 1;
  if ((seen_flags_re & kSatPos) == 0 || (seen_flags_re & kSatNeg) == 0 ||
      (seen_flags_im & kSatPos) == 0 || (seen_flags_im & kSatNeg) == 0) {
    report(&errors, "coverage", &counters.config,
           std::string("the run never observed all four saturation cases "
                       "(re=") +
               flags_str(seen_flags_re) + " im=" + flags_str(seen_flags_im) +
               "); the flag checks would have passed vacuously");
  }

  const bool passed = counters.total() == 0;

  std::printf("--- complex multiplier ---\n");
  std::printf("  vectors          : %s (%zu records, seed %llu, prod_w %u)\n",
              vec_path.c_str(), vecs.size(),
              static_cast<unsigned long long>(hdr.seed), hdr.prod_w);
  std::printf("  DUTs             : %u (MULT4 and MULT3 at PIPE_STAGES 1..5, "
              "plus the ROUND_OUT=0 pair)\n", kNDut);
  std::printf("  output beats     : %zu checked against RTL, C++ and vectors\n",
              observed);
  std::printf("  saturation seen  : re %s  im %s\n", flags_str(seen_flags_re).c_str(),
              flags_str(seen_flags_im).c_str());
  std::printf("  RTL vs model     : %zu mismatches\n", counters.rtl_vs_model);
  std::printf("  RTL vs vectors   : %zu mismatches\n", counters.rtl_vs_vector);
  std::printf("  model vs vectors : %zu mismatches\n", counters.model_vs_vector);
  std::printf("  variant disagree : %zu\n", counters.variant_mismatch);
  std::printf("  latency errors   : %zu\n", counters.latency);
  std::printf("  alignment errors : %zu\n", counters.alignment);
  std::printf("  config errors    : %zu\n", counters.config);

  const auto wall_end = std::chrono::steady_clock::now();
  RunSummary summary;
  summary.test_name = kTestName;
  summary.config_name = sim_config::kName;
  summary.build_mode = args.build_mode;
  summary.seed = args.seed;
  summary.passed = passed;
  summary.stop_reason = passed ? "pass" : "error";
  summary.stop_detail =
      passed ? "every DUT bit-exact against the C++ model and the vectors"
             : "complex-multiplier mismatch; see errors_by_category";
  summary.passes = 5;
  summary.beats_driven = vecs.size() + kDenseBeats + kGappedBeats;
  summary.beats_observed = observed;
  summary.absorb(errors);
  summary.wall_time_s =
      std::chrono::duration<double>(wall_end - wall_start).count();
  const std::string written = summary.write(args.results_dir);
  if (!written.empty()) std::printf("  summary json     : %s\n", written.c_str());

  top->final();

  if (passed) {
    std::printf("RESULT: PASS seed=%llu test=%s config=%s beats=%zu\n",
                static_cast<unsigned long long>(args.seed), kTestName,
                sim_config::kName, observed);
    return 0;
  }
  std::printf(
      "RESULT: FAIL seed=%llu test=%s config=%s rtl_vs_model=%zu "
      "rtl_vs_vector=%zu model_vs_vector=%zu variant=%zu latency=%zu "
      "alignment=%zu config=%zu\n",
      static_cast<unsigned long long>(args.seed), kTestName, sim_config::kName,
      counters.rtl_vs_model, counters.rtl_vs_vector, counters.model_vs_vector,
      counters.variant_mismatch, counters.latency, counters.alignment,
      counters.config);
  return 1;
}
