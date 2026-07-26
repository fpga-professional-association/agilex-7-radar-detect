// -----------------------------------------------------------------------------
// test_fft.cpp — streaming-FFT verification (issue #11; SPEC 6, 7.2, 13.1, 14).
//
// Closes the same triangle the numerics cross-check and the complex-multiplier
// test close, one level up. Every output beat is produced by:
//
//   * the RTL (sim/verilator/tops/fft_top.sv, five elaborations of
//     rtl/fft/streaming_fft.sv),
//   * the bit-accurate C++ model (model/cpp/fft/fft_ref.hpp), and
//   * for the directed set, the independent NumPy expectation committed in
//     model/vectors/fft64.vec,
//
// and all three must agree bit-for-bit. Which pair disagrees is reported
// separately, because that is the diagnosis.
//
// Passes (SPEC 7.2's verification list, in order)
// -----------------------------------------------
//   1. geometry        the test's mirror of the DUT grid against the RTL's own
//                      cfg_* echo, and the measured latency against
//                      fft_pkg::fft_total_latency() as the RTL reports it.
//   2. directed        every record of fft64.vec — impulse at each position
//                      class, DC, single-bin tones including Nyquist and its
//                      neighbours, negative-frequency tones, two tones, random
//                      frames and the maximum-amplitude saturation set — driven
//                      BACK TO BACK with no gap between frames, against both the
//                      vector and the model. Also checks that the metadata
//                      (sof/eof/stream_id/sequence/user) is carried through
//                      positionally.
//   3. flags           each record again, this time in isolation with the sticky
//                      flags cleared first, so the per-sub-stage saturation
//                      flags can be compared against what the model says for
//                      that frame alone. Requires the saturating records to
//                      actually saturate: a flag test that never fires passes
//                      vacuously.
//   4. random          fresh random frames per seed against the model, dense.
//   5. stalls          the SAME frames with bursty gaps on the input and bursty
//                      backpressure on the output. The outputs must be
//                      IDENTICAL to pass 4 — content invariance under
//                      backpressure is the property, and comparing against the
//                      model as well means a stall that corrupted both runs
//                      equally is still caught.
//   6. 256-point       impulse, tone and random frames through the FFT_SIZE=256
//                      elaboration, proving the parameterisation on data rather
//                      than only at elaboration.
//
// The RTL carries its own checks in parallel with all of it: streaming_fft
// asserts that the metadata and the transform stay in step (which is the check
// that the latency arithmetic in fft_pkg is right), fft_bf2 asserts that a
// scaled butterfly never saturates and that its sums fit the width fxp_pkg's
// growth rule predicts, fft_delay_line checks its pointer arithmetic against an
// independent shift register, fft_reorder checks that warmth arrives on a frame
// boundary, and the twiddle multipliers check their own rounding against
// fxp_pkg. A Verilator assertion failure aborts the run, so those are gates on
// this test even though nothing here references them.
//
// Built by `make sim-tiny` as:
//   scripts/build_verilator.py --mode fast --top fft_top
//       --files sim/verilator/files_fft.f --test test_fft
// -----------------------------------------------------------------------------

#include <chrono>
#include <cstdint>
#include <cstdio>
#include <memory>
#include <random>
#include <string>
#include <vector>

#include "Vfft_top.h"
#include "verilated.h"

#include "config_sim.h"
#include "harness/error_collector.h"
#include "harness/random.h"
#include "harness/run_summary.h"
#include "harness/sim_args.h"

#include "fft/fft_ref.hpp"
#include "fft/fft_vectors.hpp"
#include "fxp/fxp.hpp"

using harness::ErrorCollector;
using harness::RunSummary;
using harness::SimArgs;

namespace {

constexpr const char* kTestName = "test_fft";

// ---------------------------------------------------------------------------
// Mirror of the DUT grid in sim/verilator/tops/fft_top.sv. Checked against the
// RTL's cfg_* echo for every index before anything else runs, so a drift is a
// named failure rather than a silently wrong comparison.
// ---------------------------------------------------------------------------
struct DutSpec {
  unsigned n_fft;
  unsigned sched;
  bool reorder;
  const char* note;
};

constexpr unsigned kNDut = 5;
constexpr DutSpec kDut[kNDut] = {
    {64, 0xFFFFFFFFu, true, "reference"},
    {64, 0xFFFFFFFFu, false, "bit-reversed output"},
    {64, 0x00000000u, true, "no shifts — saturates everywhere"},
    {64, 0x00000003u, true, "shifts only on sub-stages 0 and 1"},
    {256, 0xFFFFFFFFu, true, "the same RTL at 256 points"},
};

constexpr unsigned kSpc = 2;
constexpr unsigned kTwPipe = 4;
constexpr unsigned kRomLat = 2;

// Random-pass sizes. Small on purpose: sim-tiny's budget is seconds, and every
// beat is checked against the model with the RTL's own assertions running.
constexpr unsigned kRandomFrames = 24;
constexpr unsigned kSmokeFrames = 6;

// ---------------------------------------------------------------------------
// Failure accounting. The relation that disagrees is the diagnosis, so the
// counts are kept apart rather than summed.
// ---------------------------------------------------------------------------
struct Counters {
  std::size_t rtl_vs_model = 0;
  std::size_t rtl_vs_vector = 0;
  std::size_t model_vs_vector = 0;
  std::size_t metadata = 0;
  std::size_t flags = 0;
  std::size_t stall_invariance = 0;
  std::size_t latency = 0;
  std::size_t config = 0;
  std::size_t coverage = 0;

  std::size_t total() const {
    return rtl_vs_model + rtl_vs_vector + model_vs_vector + metadata + flags +
           stall_invariance + latency + config + coverage;
  }
};

void report(ErrorCollector* errors, const char* category, std::size_t* counter,
            const std::string& message) {
  ++*counter;
  errors->error(category, message);
}

std::string cs(fxp::Complex c) {
  return "(" + std::to_string(c.re) + "," + std::to_string(c.im) + ")";
}

std::string fs(fxp::Flags f) {
  return std::string(f.sat_pos ? "+" : ".") + (f.sat_neg ? "-" : ".");
}

// ---------------------------------------------------------------------------
// One beat of the SPEC 5 stream, in fields
// ---------------------------------------------------------------------------
struct Beat {
  fxp::Complex s0, s1;
  bool sof = false;
  bool eof = false;
  unsigned id = 0;
  unsigned seq = 0;
  unsigned user = 0;
};

// A frame is n_fft samples; SAMPLES_PER_CYCLE of them per beat, in time order.
std::vector<Beat> frame_to_beats(const std::vector<fxp::Complex>& frame,
                                 unsigned* seq, unsigned id, unsigned user) {
  const unsigned m = static_cast<unsigned>(frame.size()) / kSpc;
  std::vector<Beat> beats;
  beats.reserve(m);
  for (unsigned b = 0; b < m; ++b) {
    Beat x;
    x.s0 = frame[b * kSpc + 0];
    x.s1 = frame[b * kSpc + 1];
    x.sof = (b == 0);
    x.eof = (b == m - 1);
    x.id = id;
    x.user = user;
    x.seq = (*seq)++ & 0xFFFFu;
    beats.push_back(x);
  }
  return beats;
}

// ---------------------------------------------------------------------------
// DUT interaction
// ---------------------------------------------------------------------------
void drive_idle(Vfft_top* top) {
  top->s_valid = 0;
  top->s_re0 = 0;
  top->s_im0 = 0;
  top->s_re1 = 0;
  top->s_im1 = 0;
  top->s_sof = 0;
  top->s_eof = 0;
  top->s_id = 0;
  top->s_seq = 0;
  top->s_user = 0;
}

void drive_beat(Vfft_top* top, const Beat& b) {
  top->s_valid = 1;
  top->s_re0 = static_cast<std::uint16_t>(b.s0.re);
  top->s_im0 = static_cast<std::uint16_t>(b.s0.im);
  top->s_re1 = static_cast<std::uint16_t>(b.s1.re);
  top->s_im1 = static_cast<std::uint16_t>(b.s1.im);
  top->s_sof = b.sof ? 1 : 0;
  top->s_eof = b.eof ? 1 : 0;
  top->s_id = static_cast<std::uint8_t>(b.id);
  top->s_seq = static_cast<std::uint16_t>(b.seq);
  top->s_user = static_cast<std::uint8_t>(b.user);
}

Beat sample_out(Vfft_top* top) {
  Beat b;
  b.s0 = fxp::Complex{static_cast<fxp::i16>(static_cast<std::uint16_t>(top->m_re0)),
                      static_cast<fxp::i16>(static_cast<std::uint16_t>(top->m_im0))};
  b.s1 = fxp::Complex{static_cast<fxp::i16>(static_cast<std::uint16_t>(top->m_re1)),
                      static_cast<fxp::i16>(static_cast<std::uint16_t>(top->m_im1))};
  b.sof = top->m_sof != 0;
  b.eof = top->m_eof != 0;
  b.id = top->m_id;
  b.seq = top->m_seq;
  b.user = top->m_user;
  return b;
}

void tick(Vfft_top* top) {
  top->clk = 0;
  top->eval();
  top->clk = 1;
  top->eval();
}

void reset(Vfft_top* top, unsigned dut) {
  drive_idle(top);
  top->dut_sel = static_cast<std::uint8_t>(dut);
  top->m_ready = 0;
  top->flags_clear = 0;
  top->rst_n = 0;
  for (int i = 0; i < 8; ++i) tick(top);
  top->rst_n = 1;
  tick(top);
}

void clear_flags(Vfft_top* top) {
  top->flags_clear = 1;
  tick(top);
  top->flags_clear = 0;
  tick(top);
}

// Result of one drive session.
struct Session {
  std::vector<Beat> out;              // output beats, in order
  std::size_t admitted_before_first = 0;  // input beats accepted before beat 0
  std::uint32_t stage_flags = 0;      // read after the session
  std::uint32_t ovf_events = 0;
  bool any_ovf = false;
};

// Drives `in` and captures output beats until `want_out` of them have been seen
// or the cycle budget runs out. `stall` and `backpressure` are the SPEC 12.2
// randomised generators; pass nullptr for none.
Session run_session(Vfft_top* top, unsigned dut, const std::vector<Beat>& in,
                    std::size_t want_out, harness::BackpressureGenerator* stall,
                    harness::BackpressureGenerator* backpressure) {
  Session s;
  top->dut_sel = static_cast<std::uint8_t>(dut);

  std::size_t next_in = 0;
  std::size_t admitted = 0;
  // Generous: every beat can be stalled for a long burst on both sides.
  const std::size_t budget = (in.size() + want_out) * 12 + 4096;

  for (std::size_t cyc = 0; cyc < budget && s.out.size() < want_out; ++cyc) {
    const bool have = next_in < in.size();
    const bool offer = have && (stall == nullptr || stall->allow());
    if (offer) {
      drive_beat(top, in[next_in]);
    } else {
      drive_idle(top);
    }
    top->m_ready = (backpressure == nullptr || backpressure->allow()) ? 1 : 0;
    top->eval();

    const bool accepted = offer && (top->s_ready != 0);
    const bool delivered = (top->m_valid != 0) && (top->m_ready != 0);

    if (delivered) {
      if (s.out.empty()) s.admitted_before_first = admitted;
      s.out.push_back(sample_out(top));
    }
    if (accepted) {
      ++next_in;
      ++admitted;
    }
    tick(top);
  }

  drive_idle(top);
  top->m_ready = 0;
  top->eval();
  s.stage_flags = static_cast<std::uint32_t>(top->stage_flags);
  s.ovf_events = static_cast<std::uint32_t>(top->ovf_events);
  s.any_ovf = top->any_ovf != 0;
  return s;
}

// ---------------------------------------------------------------------------
// Stimulus helpers
// ---------------------------------------------------------------------------
std::vector<fxp::Complex> zero_frame(unsigned n) {
  return std::vector<fxp::Complex>(n, fxp::Complex{});
}

std::vector<fxp::Complex> impulse_frame(unsigned n, unsigned pos) {
  std::vector<fxp::Complex> f = zero_frame(n);
  f[pos] = fxp::Complex{32767, 0};
  return f;
}

std::vector<fxp::Complex> tone_frame(unsigned n, unsigned k, fxp::i16 amp) {
  // Built from the same master table the transform multiplies by, exactly as
  // model/python/gen_fft_vectors.py builds its tones.
  std::vector<fxp::Complex> f(n);
  const unsigned step = fft::kTwN / n;
  for (unsigned t = 0; t < n; ++t) {
    const fxp::Complex w =
        fxp::Complex::from_packed(fft::kTw[((k * t) % n) * step]);
    const fxp::i16 im =
        static_cast<fxp::i16>(fxp::neg_sat(static_cast<fxp::wide_t>(w.im),
                                           fxp::kSampleW));
    f[t] = fxp::Complex{fxp::mul_q15_rs(w.re, amp), fxp::mul_q15_rs(im, amp)};
  }
  return f;
}

std::vector<fxp::Complex> random_frame(std::mt19937_64& rng, unsigned n,
                                       double edge_p) {
  static const fxp::i16 kEdge[] = {-32768, -32767, -16384, -1, 0,
                                   1,      16384,  32766,  32767};
  std::vector<fxp::Complex> f(n);
  for (unsigned i = 0; i < n; ++i) {
    fxp::i16 c[2];
    for (int j = 0; j < 2; ++j) {
      if (harness::bernoulli(rng, edge_p)) {
        c[j] = kEdge[harness::uniform_u64(rng, 0, 8)];
      } else {
        c[j] = static_cast<fxp::i16>(
            static_cast<std::int64_t>(harness::uniform_u64(rng, 0, 65535)) -
            32768);
      }
    }
    f[i] = fxp::Complex{c[0], c[1]};
  }
  return f;
}

// How many all-zero frames must follow the real ones for every real output to
// have emerged. A frame's output needs `latency` further beats to be admitted.
unsigned flush_frames(unsigned n_fft, bool reorder) {
  const unsigned m = n_fft / kSpc;
  const unsigned lat =
      fft::total_latency(n_fft, kSpc, kRomLat, kTwPipe, reorder);
  return (lat + m - 1) / m + 2;
}

// ---------------------------------------------------------------------------
// Comparison
// ---------------------------------------------------------------------------
void compare_frame(const std::string& where, const fft::Config& cfg,
                   const std::vector<fxp::Complex>& in,
                   const std::vector<Beat>& out, std::size_t base,
                   const std::vector<fxp::Complex>* vector_expect,
                   ErrorCollector* errors, Counters* c) {
  const fft::Result r = fft::transform(cfg, in);
  const unsigned m = cfg.lane();

  for (unsigned b = 0; b < m; ++b) {
    const Beat& got = out[base + b];
    const fxp::Complex e0 = r.out[b * kSpc + 0];
    const fxp::Complex e1 = r.out[b * kSpc + 1];
    if (got.s0 != e0 || got.s1 != e1) {
      report(errors, "rtl_vs_model", &c->rtl_vs_model,
             where + " beat " + std::to_string(b) + ": RTL " + cs(got.s0) + "," +
                 cs(got.s1) + " vs model " + cs(e0) + "," + cs(e1));
      return;  // one report per frame; the rest is the same defect
    }
    if (vector_expect != nullptr) {
      const fxp::Complex v0 = (*vector_expect)[b * kSpc + 0];
      const fxp::Complex v1 = (*vector_expect)[b * kSpc + 1];
      if (got.s0 != v0 || got.s1 != v1) {
        report(errors, "rtl_vs_vector", &c->rtl_vs_vector,
               where + " beat " + std::to_string(b) + ": RTL " + cs(got.s0) +
                   "," + cs(got.s1) + " vs vector " + cs(v0) + "," + cs(v1));
        return;
      }
      if (e0 != v0 || e1 != v1) {
        report(errors, "model_vs_vector", &c->model_vs_vector,
               where + " beat " + std::to_string(b) +
                   ": the C++ model disagrees with the vector");
        return;
      }
    }
  }
}

void compare_metadata(const std::string& where, const std::vector<Beat>& in,
                      const std::vector<Beat>& out, std::size_t count,
                      ErrorCollector* errors, Counters* c) {
  for (std::size_t k = 0; k < count; ++k) {
    const Beat& i = in[k];
    const Beat& o = out[k];
    if (o.sof != i.sof || o.eof != i.eof || o.seq != i.seq || o.id != i.id ||
        o.user != i.user) {
      report(errors, "metadata", &c->metadata,
             where + " beat " + std::to_string(k) + ": metadata sof/eof/seq/id/user " +
                 std::to_string(o.sof) + "/" + std::to_string(o.eof) + "/" +
                 std::to_string(o.seq) + "/" + std::to_string(o.id) + "/" +
                 std::to_string(o.user) + " does not match the input's " +
                 std::to_string(i.sof) + "/" + std::to_string(i.eof) + "/" +
                 std::to_string(i.seq) + "/" + std::to_string(i.id) + "/" +
                 std::to_string(i.user));
      return;
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
  const std::string vec_path = dir + "/fft64.vec";

  ErrorCollector errors;
  Counters counters;

  std::vector<fft::vectors::FftVector> vecs;
  fft::vectors::Header hdr;
  std::string err;
  if (!fft::vectors::load(vec_path, &vecs, &hdr, &err)) {
    std::fprintf(stderr, "ERROR: %s\n", err.c_str());
    std::printf("RESULT: FAIL seed=%llu test=%s reason=vector_load: %s\n",
                static_cast<unsigned long long>(args.seed), kTestName,
                err.c_str());
    return 2;
  }

  std::unique_ptr<Vfft_top> top(new Vfft_top);
  reset(top.get(), 0);

  // ---- pass 1: geometry ----------------------------------------------------
  top->eval();
  if (top->cfg_n_dut != kNDut) {
    std::printf("RESULT: FAIL seed=%llu test=%s reason=grid_mismatch (rtl %u duts, test expects %u)\n",
                static_cast<unsigned long long>(args.seed), kTestName,
                static_cast<unsigned>(top->cfg_n_dut), kNDut);
    return 2;
  }
  for (unsigned d = 0; d < kNDut; ++d) {
    top->dut_sel = static_cast<std::uint8_t>(d);
    top->eval();
    const unsigned n = top->cfg_fft_size;
    const unsigned spc = top->cfg_spc;
    const unsigned reorder = top->cfg_reorder;
    const unsigned sched = static_cast<std::uint32_t>(top->cfg_scale_sched);
    const unsigned lat = top->cfg_latency;
    const unsigned beats = top->cfg_frame_beats;
    const unsigned stages = top->cfg_stages;

    const unsigned want_lat = fft::total_latency(
        kDut[d].n_fft, kSpc, kRomLat, kTwPipe, kDut[d].reorder);
    if (n != kDut[d].n_fft || spc != kSpc || (reorder != 0) != kDut[d].reorder ||
        sched != kDut[d].sched) {
      report(&errors, "config", &counters.config,
             "dut" + std::to_string(d) + ": RTL reports n=" + std::to_string(n) +
                 " spc=" + std::to_string(spc) + " reorder=" +
                 std::to_string(reorder) + " sched=" + std::to_string(sched) +
                 ", the test's mirror disagrees");
    }
    if (lat != want_lat) {
      report(&errors, "config", &counters.config,
             "dut" + std::to_string(d) + ": RTL latency " + std::to_string(lat) +
                 ", the C++ mirror computes " + std::to_string(want_lat));
    }
    if (beats != kDut[d].n_fft / kSpc ||
        stages != fft::total_stages(kDut[d].n_fft)) {
      report(&errors, "config", &counters.config,
             "dut" + std::to_string(d) + ": frame beats " + std::to_string(beats) +
                 " / stages " + std::to_string(stages) + " disagree with the mirror");
    }
    if (top->cfg_tw_pipe != kTwPipe || top->cfg_rom_lat != kRomLat) {
      report(&errors, "config", &counters.config,
             "dut" + std::to_string(d) + ": multiplier depth / ROM latency echo "
             "disagrees with the mirror");
    }
  }

  // ---- pass 2: directed vectors, frames back to back ----------------------
  // Every record of the vector file, grouped by the DUT whose parameters match
  // it, driven with NO gap between frames. That is the SPEC 7.2 "back-to-back
  // frames" case and it is also the strongest test of the frame tracking: with
  // no gap there is nothing to resynchronise on but the metadata itself.
  std::size_t directed_frames = 0;
  for (unsigned d = 0; d < kNDut; ++d) {
    std::vector<const fft::vectors::FftVector*> mine;
    for (const fft::vectors::FftVector& v : vecs) {
      if (hdr.fft_size == kDut[d].n_fft && v.sched == kDut[d].sched &&
          v.reorder == kDut[d].reorder) {
        mine.push_back(&v);
      }
    }
    if (mine.empty()) continue;

    const unsigned n = kDut[d].n_fft;
    const unsigned m = n / kSpc;
    unsigned seq = 1;
    std::vector<Beat> in;
    for (const fft::vectors::FftVector* v : mine) {
      const std::vector<Beat> f = frame_to_beats(v->in, &seq, d & 0x3u, 5);
      in.insert(in.end(), f.begin(), f.end());
    }
    const unsigned flush = flush_frames(n, kDut[d].reorder);
    for (unsigned i = 0; i < flush; ++i) {
      const std::vector<Beat> f = frame_to_beats(zero_frame(n), &seq, d & 0x3u, 5);
      in.insert(in.end(), f.begin(), f.end());
    }

    reset(top.get(), d);
    const Session s = run_session(top.get(), d, in, mine.size() * m, nullptr,
                                 nullptr);
    if (s.out.size() < mine.size() * m) {
      report(&errors, "rtl_vs_model", &counters.rtl_vs_model,
             "dut" + std::to_string(d) + ": only " + std::to_string(s.out.size()) +
                 " output beats of " + std::to_string(mine.size() * m));
      continue;
    }

    // Latency, measured against the RTL's own report. Under no backpressure the
    // first beat leaves the output FIFO a couple of beats after the pipeline's
    // own latency; the bound is what is checked, and the exact alignment is what
    // streaming_fft's a_fft_meta_frame_aligned asserts on every beat.
    top->dut_sel = static_cast<std::uint8_t>(d);
    top->eval();
    const unsigned rtl_lat = top->cfg_latency;
    if (s.admitted_before_first < rtl_lat ||
        s.admitted_before_first > rtl_lat + 4) {
      report(&errors, "latency", &counters.latency,
             "dut" + std::to_string(d) + ": first output after " +
                 std::to_string(s.admitted_before_first) +
                 " admitted beats, the RTL reports a latency of " +
                 std::to_string(rtl_lat));
    }

    for (std::size_t f = 0; f < mine.size(); ++f) {
      const fft::vectors::FftVector& v = *mine[f];
      compare_frame("dut" + std::to_string(d) + " [" + v.id + "]",
                    v.config(hdr), v.in, s.out, f * m, &v.out, &errors,
                    &counters);
      ++directed_frames;
    }
    compare_metadata("dut" + std::to_string(d) + " directed", in, s.out,
                     mine.size() * m, &errors, &counters);
  }

  // ---- pass 3: per-sub-stage saturation flags -----------------------------
  // One record per session, with the sticky flags cleared first and the frame
  // flushed with zeros (which cannot saturate), so the flags read at the end
  // belong to that frame and to nothing else.
  fxp::Flags seen_any = fxp::flags_none();
  std::size_t flag_records = 0;
  for (unsigned d = 0; d < kNDut; ++d) {
    if (kDut[d].n_fft != hdr.fft_size) continue;
    for (const fft::vectors::FftVector& v : vecs) {
      if (v.sched != kDut[d].sched || v.reorder != kDut[d].reorder) continue;

      const unsigned n = kDut[d].n_fft;
      const unsigned m = n / kSpc;
      unsigned seq = 1;
      std::vector<Beat> in = frame_to_beats(v.in, &seq, 0, 0);
      const unsigned flush = flush_frames(n, kDut[d].reorder);
      for (unsigned i = 0; i < flush; ++i) {
        const std::vector<Beat> f = frame_to_beats(zero_frame(n), &seq, 0, 0);
        in.insert(in.end(), f.begin(), f.end());
      }

      reset(top.get(), d);
      clear_flags(top.get());
      const Session s = run_session(top.get(), d, in, m, nullptr, nullptr);
      ++flag_records;

      const fft::Result r = fft::transform(v.config(hdr), v.in);
      for (unsigned g = 0; g < hdr.stages; ++g) {
        const fxp::Flags got = fxp::Flags::from_packed((s.stage_flags >> (2 * g)) & 0x3u);
        const fxp::Flags want = r.stage_flags[g];
        if (!(got == want)) {
          report(&errors, "flags", &counters.flags,
                 "dut" + std::to_string(d) + " [" + v.id + "] sub-stage " +
                     std::to_string(g) + ": RTL flags " + fs(got) +
                     ", the model says " + fs(want));
        }
        if (!(want == v.stage_flags[g])) {
          report(&errors, "model_vs_vector", &counters.model_vs_vector,
                 "[" + v.id + "] sub-stage " + std::to_string(g) +
                     ": model flags " + fs(want) + " vs vector " +
                     fs(v.stage_flags[g]));
        }
        seen_any = fxp::flags_merge(seen_any, got);
      }

      // ovf_events counts saturating cycles; it must be non-zero exactly when
      // some sub-stage saturated, and zero when none did.
      const bool model_any = [&] {
        for (const fxp::Flags& f : r.stage_flags) {
          if (f.any()) return true;
        }
        return false;
      }();
      if (model_any != (s.ovf_events != 0) || model_any != s.any_ovf) {
        report(&errors, "flags", &counters.flags,
               "dut" + std::to_string(d) + " [" + v.id +
                   "]: any_ovf/ovf_events (" + std::to_string(s.any_ovf) + "/" +
                   std::to_string(s.ovf_events) + ") disagree with the model's " +
                   std::to_string(model_any));
      }
    }
  }
  if (!seen_any.sat_pos || !seen_any.sat_neg) {
    report(&errors, "coverage", &counters.coverage,
           std::string("the flag pass never observed both saturation directions (") +
               fs(seen_any) + "); the flag checks would have passed vacuously");
  }

  // ---- passes 4 and 5: random frames, dense then stalled ------------------
  harness::SeedSource seeds(args.seed);
  std::vector<std::vector<fxp::Complex>> frames;
  {
    std::mt19937_64 rng = seeds.engine("fft.random");
    for (unsigned i = 0; i < kRandomFrames; ++i) {
      frames.push_back(random_frame(rng, 64, 0.25));
    }
  }

  auto run_random = [&](const char* label, bool stalls) {
    const unsigned d = 0;
    const unsigned n = kDut[d].n_fft;
    const unsigned m = n / kSpc;
    unsigned seq = 100;
    std::vector<Beat> in;
    for (const std::vector<fxp::Complex>& f : frames) {
      const std::vector<Beat> b = frame_to_beats(f, &seq, 1, 9);
      in.insert(in.end(), b.begin(), b.end());
    }
    const unsigned flush = flush_frames(n, kDut[d].reorder);
    for (unsigned i = 0; i < flush; ++i) {
      const std::vector<Beat> b = frame_to_beats(zero_frame(n), &seq, 1, 9);
      in.insert(in.end(), b.begin(), b.end());
    }

    std::unique_ptr<harness::BackpressureGenerator> stall, bp;
    if (stalls) {
      // Bursty on both sides: a stall that starts mid-frame and one that starts
      // between frames are different cases, and a bursty generator reaches both
      // where independent per-cycle coin flips reach neither.
      stall.reset(new harness::BackpressureGenerator(
          seeds.engine("fft.stall"), harness::BackpressureConfig::bursty()));
      bp.reset(new harness::BackpressureGenerator(
          seeds.engine("fft.backpressure"), harness::BackpressureConfig::heavy()));
    }

    reset(top.get(), d);
    const Session s = run_session(top.get(), d, in, frames.size() * m,
                                 stall.get(), bp.get());
    if (s.out.size() < frames.size() * m) {
      report(&errors, "rtl_vs_model", &counters.rtl_vs_model,
             std::string(label) + ": only " + std::to_string(s.out.size()) +
                 " output beats of " + std::to_string(frames.size() * m));
      return s;
    }
    fft::Config cfg;
    cfg.n_fft = n;
    cfg.spc = kSpc;
    cfg.scale_sched = kDut[d].sched;
    cfg.reorder = kDut[d].reorder;
    for (std::size_t f = 0; f < frames.size(); ++f) {
      compare_frame(std::string(label) + " frame " + std::to_string(f), cfg,
                    frames[f], s.out, f * m, nullptr, &errors, &counters);
    }
    compare_metadata(std::string(label) + " metadata", in, s.out,
                     frames.size() * m, &errors, &counters);
    return s;
  };

  const Session dense = run_random("random-dense", false);
  const Session stalled = run_random("random-stalled", true);

  if (dense.out.size() == stalled.out.size()) {
    for (std::size_t k = 0; k < dense.out.size(); ++k) {
      if (dense.out[k].s0 != stalled.out[k].s0 ||
          dense.out[k].s1 != stalled.out[k].s1 ||
          dense.out[k].seq != stalled.out[k].seq ||
          dense.out[k].sof != stalled.out[k].sof ||
          dense.out[k].eof != stalled.out[k].eof) {
        report(&errors, "stall_invariance", &counters.stall_invariance,
               "beat " + std::to_string(k) +
                   " differs between the dense and the stalled run: content is "
                   "not invariant under backpressure");
        break;
      }
    }
  } else {
    report(&errors, "stall_invariance", &counters.stall_invariance,
           "the dense run produced " + std::to_string(dense.out.size()) +
               " beats and the stalled run " + std::to_string(stalled.out.size()));
  }

  // ---- pass 6: the 256-point elaboration ----------------------------------
  {
    const unsigned d = 4;
    const unsigned n = kDut[d].n_fft;
    const unsigned m = n / kSpc;
    std::vector<std::vector<fxp::Complex>> smoke;
    smoke.push_back(impulse_frame(n, 0));
    smoke.push_back(impulse_frame(n, 37));
    smoke.push_back(tone_frame(n, 9, 30000));
    smoke.push_back(tone_frame(n, n - 5, 30000));
    {
      std::mt19937_64 rng = seeds.engine("fft.smoke256");
      while (smoke.size() < kSmokeFrames) smoke.push_back(random_frame(rng, n, 0.2));
    }

    unsigned seq = 7;
    std::vector<Beat> in;
    for (const std::vector<fxp::Complex>& f : smoke) {
      const std::vector<Beat> b = frame_to_beats(f, &seq, 2, 3);
      in.insert(in.end(), b.begin(), b.end());
    }
    const unsigned flush = flush_frames(n, kDut[d].reorder);
    for (unsigned i = 0; i < flush; ++i) {
      const std::vector<Beat> b = frame_to_beats(zero_frame(n), &seq, 2, 3);
      in.insert(in.end(), b.begin(), b.end());
    }

    reset(top.get(), d);
    const Session s = run_session(top.get(), d, in, smoke.size() * m, nullptr,
                                 nullptr);
    if (s.out.size() < smoke.size() * m) {
      report(&errors, "rtl_vs_model", &counters.rtl_vs_model,
             "256-point: only " + std::to_string(s.out.size()) +
                 " output beats of " + std::to_string(smoke.size() * m));
    } else {
      fft::Config cfg;
      cfg.n_fft = n;
      cfg.spc = kSpc;
      cfg.scale_sched = kDut[d].sched;
      cfg.reorder = kDut[d].reorder;
      for (std::size_t f = 0; f < smoke.size(); ++f) {
        compare_frame("256-point frame " + std::to_string(f), cfg, smoke[f],
                      s.out, f * m, nullptr, &errors, &counters);
      }
      compare_metadata("256-point metadata", in, s.out, smoke.size() * m,
                       &errors, &counters);
    }
  }

  const bool passed = counters.total() == 0;

  std::printf("--- streaming FFT ---\n");
  std::printf("  vectors          : %s (%zu records, %u-point, %u samples/cycle)\n",
              vec_path.c_str(), vecs.size(), hdr.fft_size, hdr.spc);
  std::printf("  twiddle digest   : %s\n", hdr.twiddle_digest.c_str());
  std::printf("  DUTs             : %u (64-pt reference / bit-reversed / two "
              "saturating schedules, plus 256-pt)\n", kNDut);
  std::printf("  directed frames  : %zu back to back\n", directed_frames);
  std::printf("  flag sessions    : %zu (saturation seen: %s)\n", flag_records,
              fs(seen_any).c_str());
  std::printf("  random frames    : %u dense + %u stalled\n", kRandomFrames,
              kRandomFrames);
  std::printf("  256-point frames : %u\n", kSmokeFrames);
  std::printf("  RTL vs model     : %zu mismatches\n", counters.rtl_vs_model);
  std::printf("  RTL vs vectors   : %zu mismatches\n", counters.rtl_vs_vector);
  std::printf("  model vs vectors : %zu mismatches\n", counters.model_vs_vector);
  std::printf("  metadata errors  : %zu\n", counters.metadata);
  std::printf("  flag errors      : %zu\n", counters.flags);
  std::printf("  stall invariance : %zu\n", counters.stall_invariance);
  std::printf("  latency errors   : %zu\n", counters.latency);
  std::printf("  config errors    : %zu\n", counters.config);
  std::printf("  coverage errors  : %zu\n", counters.coverage);

  const auto wall_end = std::chrono::steady_clock::now();
  RunSummary summary;
  summary.test_name = kTestName;
  summary.config_name = sim_config::kName;
  summary.build_mode = args.build_mode;
  summary.seed = args.seed;
  summary.passed = passed;
  summary.stop_reason = passed ? "pass" : "error";
  summary.stop_detail =
      passed ? "every frame bit-exact against the C++ model and the vectors"
             : "streaming-FFT mismatch; see errors_by_category";
  summary.passes = 6;
  summary.frames_driven = directed_frames + 2 * kRandomFrames + kSmokeFrames;
  summary.frames_observed = summary.frames_driven;
  summary.beats_observed = dense.out.size() + stalled.out.size();
  summary.absorb(errors);
  summary.wall_time_s =
      std::chrono::duration<double>(wall_end - wall_start).count();
  const std::string written = summary.write(args.results_dir);
  if (!written.empty()) std::printf("  summary json     : %s\n", written.c_str());

  top->final();

  if (passed) {
    std::printf("RESULT: PASS seed=%llu test=%s config=%s frames=%llu\n",
                static_cast<unsigned long long>(args.seed), kTestName,
                sim_config::kName,
                static_cast<unsigned long long>(summary.frames_driven));
    return 0;
  }
  std::printf(
      "RESULT: FAIL seed=%llu test=%s config=%s rtl_vs_model=%zu "
      "rtl_vs_vector=%zu model_vs_vector=%zu metadata=%zu flags=%zu "
      "stall=%zu latency=%zu config=%zu coverage=%zu\n",
      static_cast<unsigned long long>(args.seed), kTestName, sim_config::kName,
      counters.rtl_vs_model, counters.rtl_vs_vector, counters.model_vs_vector,
      counters.metadata, counters.flags, counters.stall_invariance,
      counters.latency, counters.config, counters.coverage);
  return 1;
}
