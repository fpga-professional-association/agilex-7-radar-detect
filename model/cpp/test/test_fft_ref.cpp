// -----------------------------------------------------------------------------
// test_fft_ref.cpp — the C++ FFT model against the golden vectors (issue #11).
//
// SPEC 12.4: the C++ reference model must be "validated independently against
// Python, NumPy, or MATLAB-generated vectors before using it as the RTL oracle".
// This is that validation, and it runs BEFORE any Verilator build, exactly as
// model/cpp/test/test_fxp_vectors.cpp does for the numerics package. The order
// matters: an oracle that has not been checked against anything is not an
// oracle, and a failure here means the MODEL is wrong, not the RTL.
//
// Three things are checked:
//
//   1. every record of model/vectors/fft64.vec, sample for sample and flag for
//      flag, against model/cpp/fft/fft_ref.hpp;
//   2. the output permutation as a PROPERTY rather than as data: running the
//      same input with reorder on and off must give the same beats in the two
//      orders bitrev relates. A model that applied the permutation twice, or
//      not at all, passes (1) against vectors it produced and fails this;
//   3. the geometry helpers against each other — the sub-stage count, the
//      multiplier count and the latency decomposition — so a change to one
//      formula in fft_pkg's C++ mirror cannot quietly disagree with another.
//
// Standalone: no Verilator, no RTL. Build contract from the issue #4 gate,
//   g++ -std=c++17 -O3 -Wall -Wextra -Werror -Imodel/cpp
// because this file is compiled into the harness of the RTL test as well, and a
// warning in the oracle is a numerics warning.
//
//   ./test_fft_ref --vectors model/vectors
// -----------------------------------------------------------------------------

#include <cstdio>
#include <cstring>
#include <string>
#include <vector>

#include "fft/fft_ref.hpp"
#include "fft/fft_vectors.hpp"

namespace {

std::size_t g_failures = 0;
std::size_t g_checked = 0;

void fail(const std::string& what) {
  ++g_failures;
  if (g_failures <= 20) std::fprintf(stderr, "FAIL: %s\n", what.c_str());
}

std::string cs(fxp::Complex c) {
  return "(" + std::to_string(c.re) + "," + std::to_string(c.im) + ")";
}

std::string fs(fxp::Flags f) {
  return std::string(f.sat_pos ? "+" : ".") + (f.sat_neg ? "-" : ".");
}

// ---------------------------------------------------------------------------
// 1. Vectors
// ---------------------------------------------------------------------------
void check_vectors(const std::vector<fft::vectors::FftVector>& vecs,
                   const fft::vectors::Header& hdr) {
  for (const fft::vectors::FftVector& v : vecs) {
    const fft::Config cfg = v.config(hdr);
    if (!cfg.valid()) {
      fail("record " + v.id + ": geometry is not legal for this model");
      continue;
    }
    const fft::Result r = fft::transform(cfg, v.in);
    ++g_checked;

    if (r.out.size() != v.out.size()) {
      fail("record " + v.id + ": model produced " + std::to_string(r.out.size()) +
           " samples, the vector has " + std::to_string(v.out.size()));
      continue;
    }
    for (std::size_t i = 0; i < r.out.size(); ++i) {
      if (r.out[i] != v.out[i]) {
        fail("record " + v.id + " sample " + std::to_string(i) + ": model " +
             cs(r.out[i]) + " vs vector " + cs(v.out[i]));
        break;  // one report per record; the rest would be the same defect
      }
    }
    for (std::size_t g = 0; g < v.stage_flags.size(); ++g) {
      if (!(r.stage_flags[g] == v.stage_flags[g])) {
        fail("record " + v.id + " sub-stage " + std::to_string(g) +
             ": model flags " + fs(r.stage_flags[g]) + " vs vector " +
             fs(v.stage_flags[g]));
      }
    }
  }
}

// ---------------------------------------------------------------------------
// 2. The output permutation, as a property
// ---------------------------------------------------------------------------
void check_permutation(const std::vector<fft::vectors::FftVector>& vecs,
                       const fft::vectors::Header& hdr) {
  for (const fft::vectors::FftVector& v : vecs) {
    fft::Config a = v.config(hdr);
    fft::Config b = a;
    a.reorder = false;
    b.reorder = true;

    const fft::Result ra = fft::transform(a, v.in);
    const fft::Result rb = fft::transform(b, v.in);
    const unsigned m = a.lane();
    const unsigned nl = a.n_lane();
    ++g_checked;

    for (unsigned j = 0; j < m; ++j) {
      const unsigned src = fft::bitrev(j, nl);
      for (unsigned p = 0; p < a.spc; ++p) {
        if (rb.out[j * a.spc + p] != ra.out[src * a.spc + p]) {
          fail("record " + v.id + ": reordered beat " + std::to_string(j) +
               " slot " + std::to_string(p) + " is not bit-reversed beat " +
               std::to_string(src));
          return;
        }
      }
    }

    // The natural-bin view must agree with the reordered beats: beat j slot 0
    // is bin j, slot 1 is bin j + N/2.
    for (unsigned j = 0; j < m; ++j) {
      for (unsigned p = 0; p < a.spc; ++p) {
        const unsigned bin = j + p * (a.n_fft / a.spc);
        if (rb.bins[bin] != rb.out[j * a.spc + p]) {
          fail("record " + v.id + ": bin " + std::to_string(bin) +
               " disagrees with reordered beat " + std::to_string(j) + " slot " +
               std::to_string(p));
          return;
        }
      }
    }
  }
}

// ---------------------------------------------------------------------------
// 3. Geometry
// ---------------------------------------------------------------------------
void check_geometry() {
  for (unsigned n : {8u, 16u, 32u, 64u, 128u, 256u, 512u, 1024u}) {
    for (unsigned p : {1u, 2u}) {
      fft::Config c;
      c.n_fft = n;
      c.spc = p;
      if (!c.valid()) continue;
      ++g_checked;

      const unsigned nl = c.n_lane();
      if ((1u << nl) != c.lane()) {
        fail("geometry " + std::to_string(n) + "/" + std::to_string(p) +
             ": lane length is not 2^n_lane");
      }
      if (nl + fft::merge_levels(p) != c.stages()) {
        fail("geometry " + std::to_string(n) + "/" + std::to_string(p) +
             ": lane sub-stages plus merge levels != log2(N)");
      }

      // The twiddle-multiplier count the structure produces must be the count
      // the closed form predicts.
      unsigned mults = 0;
      for (unsigned s = 0; s < nl; ++s) {
        if (fft::stage_has_twiddle(nl, s)) ++mults;
      }
      if (mults != fft::lane_mults(nl)) {
        fail("geometry " + std::to_string(n) + "/" + std::to_string(p) +
             ": counted " + std::to_string(mults) + " multipliers, formula says " +
             std::to_string(fft::lane_mults(nl)));
      }

      // The delays of one lane must sum to M-1: that is the whole memory of an
      // SDF path, and the position offset the latency arithmetic uses.
      unsigned sum_delay = 0;
      for (unsigned s = 0; s < nl; ++s) sum_delay += fft::bf_delay(nl, s);
      if (sum_delay != fft::lane_pos_offset(nl)) {
        fail("geometry " + std::to_string(n) + "/" + std::to_string(p) +
             ": delays sum to " + std::to_string(sum_delay) + ", expected " +
             std::to_string(fft::lane_pos_offset(nl)));
      }

      // Every twiddle exponent a stage can produce must be inside its table.
      for (unsigned s = 0; s < nl; ++s) {
        if (!fft::stage_has_twiddle(nl, s)) continue;
        const unsigned l2l = fft::group_l2l(nl, s);
        const unsigned l = 1u << l2l;
        for (unsigned q = 0; q < l; ++q) {
          if (fft::r22_tw_exp(l2l, q) >= l) {
            fail("geometry " + std::to_string(n) + ": sub-stage " +
                 std::to_string(s) + " position " + std::to_string(q) +
                 " needs exponent " + std::to_string(fft::r22_tw_exp(l2l, q)) +
                 " of a " + std::to_string(l) + "-entry table");
            break;
          }
        }
      }
    }
  }

  // The four axis points of the master table must be exact: the radix-2^2
  // structure's trivial twiddles depend on it.
  ++g_checked;
  const fxp::Complex w0 = fft::tw(fft::kMaxStages, 0);
  const fxp::Complex wq = fft::tw(fft::kMaxStages, fft::kTwN / 4);
  const fxp::Complex wh = fft::tw(fft::kMaxStages, fft::kTwN / 2);
  if (w0.re != 32767 || w0.im != 0) {
    fail("twiddle W^0 is " + cs(w0) + ", expected (32767,0) — cos(0)=1 saturates");
  }
  if (wq.re != 0 || wq.im != -32768) {
    fail("twiddle W^(N/4) is " + cs(wq) + ", expected (0,-32768) = -j");
  }
  if (wh.re != -32768 || wh.im != 0) {
    fail("twiddle W^(N/2) is " + cs(wh) + ", expected (-32768,0) = -1");
  }
}

}  // namespace

int main(int argc, char** argv) {
  std::string dir = "model/vectors";
  for (int i = 1; i < argc; ++i) {
    if (std::strcmp(argv[i], "--vectors") == 0 && i + 1 < argc) dir = argv[++i];
  }
  const std::string path = dir + "/fft64.vec";

  std::vector<fft::vectors::FftVector> vecs;
  fft::vectors::Header hdr;
  std::string err;
  if (!fft::vectors::load(path, &vecs, &hdr, &err)) {
    std::fprintf(stderr, "ERROR: %s\n", err.c_str());
    std::printf("RESULT: FAIL test=test_fft_ref reason=vector_load\n");
    return 2;
  }

  check_vectors(vecs, hdr);
  check_permutation(vecs, hdr);
  check_geometry();

  std::printf("--- FFT reference model ---\n");
  std::printf("  vectors        : %s (%zu records, %u-point, %u samples/cycle)\n",
              path.c_str(), vecs.size(), hdr.fft_size, hdr.spc);
  std::printf("  twiddle digest : %s\n", hdr.twiddle_digest.c_str());
  std::printf("  checks run     : %zu\n", g_checked);
  std::printf("  failures       : %zu\n", g_failures);

  if (g_failures != 0) {
    std::printf("RESULT: FAIL test=test_fft_ref failures=%zu\n", g_failures);
    return 1;
  }
  std::printf("RESULT: PASS test=test_fft_ref records=%zu\n", vecs.size());
  return 0;
}
