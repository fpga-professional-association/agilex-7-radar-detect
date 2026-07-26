// -----------------------------------------------------------------------------
// test_beamformer.cpp — beamforming matrix verification (issue #12; SPEC 6, 7.5,
// 13.1, 13.2, 13.3, 14).
//
// Drives sim/verilator/tops/beamformer_top.sv, which holds THREE complete
// beamformers admitting exactly the same beats — the reference engine, the
// time-multiplexed engine (BEAM_PAR = N_BEAMS/2) and the reference engine with
// two adders per register stage — plus TWO standalone 16-antenna dot products
// differing only in adder-tree pipelining. Every output beat of all three
// matrices and both dot products is checked against the bit-accurate C++ model
// (model/cpp/beamformer/beamformer_model.hpp).
//
// THE SPEC 7.5 / 13.1 VERIFICATION LIST, AND WHERE EACH CASE LIVES
// ----------------------------------------------------------------
//   unit weights -> passthrough .. pass 2 (dot) and pass 4 (matrix). Beam b is
//                                  programmed to select antenna sel[b] and
//                                  nothing else, so the expected output is that
//                                  antenna's sample scaled by 0x7FFF — a value
//                                  written down WITHOUT the general model, which
//                                  is what makes it the right first failure to
//                                  look at when everything disagrees.
//   zero weights / zero input .... pass 2. Both directions of the SPEC 13.2
//                                  zero relation.
//   orthogonal weight patterns ... pass 2. A Hadamard-style +/-1 pattern: the
//                                  beams are mutually orthogonal, so a stimulus
//                                  matching one beam's pattern lands entirely in
//                                  that beam and exactly zero in every other.
//                                  That is an expectation with no model in it at
//                                  all, and it is the case a transposed weight
//                                  index cannot survive.
//   max-amplitude saturation ..... pass 3. Full-scale weights against full-scale
//                                  input, in both directions, with the flags
//                                  audited and a coverage check that refuses to
//                                  pass if both directions were not observed.
//   random, >= 3 seeds ........... passes 3 and 5, seeded from +seed, checked
//                                  bit-exactly against the model AND against an
//                                  independent double-precision evaluation.
//   weight-bank swap ............. pass 6: two frames, a swap requested
//                                  MID-FRAME, each frame checked against its own
//                                  weight set with no corrupted beat at the seam;
//                                  plus mid-stream writes to the inactive bank,
//                                  which must not move a single output bit.
//   backpressure invariance ...... pass 5: the same beats and the same
//                                  expectations under three stall profiles, all
//                                  scoreboarded by sequence number.
//   time multiplexing ............ every matrix pass. DUT 1 emits two output
//                                  beats per input beat and they must together
//                                  equal DUT 0's one, which makes "multiplexing
//                                  changes the schedule and not the answer" a
//                                  same-run fact.
//   adder-tree pipelining ........ every pass. DUT 2 and u_dot16_r2 use
//                                  ADD_REG_EVERY = 2 and must be bit-identical
//                                  to their ADD_REG_EVERY = 1 twins.
//
// plus the SPEC 13.2 metamorphic relations, in pass 7:
//
//   PERMUTATION . permuting the antenna inputs AND the antenna axis of the
//                 weights by the same permutation must leave every beam output
//                 BIT-IDENTICAL. This is the relation SPEC 13.2 names for the
//                 beamformer specifically, it needs no oracle, and it is exact
//                 rather than approximate because the accumulation has no
//                 intermediate saturation and integer addition is commutative.
//   negation .... y(-x) == -y(x) wherever -y is representable.
//   scaling ..... doubling an unsaturated input doubles the output to within the
//                 one LSB rounding may move it.
//
// THE INDEPENDENT CROSS-CHECK, AND WHY IT IS IN C++ RATHER THAN NUMPY
// ------------------------------------------------------------------
// SPEC 12.4: an oracle that agrees only with itself is not an oracle. The C++
// model and the RTL share fxp_pkg's definitions BY DESIGN — that is what makes
// them bit-exact — so agreement between them proves the wiring, not the
// arithmetic. Every non-saturating beat is therefore ALSO checked against
// bf::dot_float(), a double-precision evaluation of the same sum through no
// shared code, and required to agree to within a small LSB budget.
//
// Issues #4, #9, #10 and #11 discharge this obligation with a committed NumPy
// vector set. This issue does not ship one, and that is a deliberate, recorded
// deviation rather than an oversight: the beamformer is STATELESS — there is no
// history, no schedule and no twiddle table, so a golden file would carry no
// information the weight set and the input beat do not already carry — and the
// two error classes a vector file exists to catch here are covered more directly
// by the orthogonality case (an expectation with no model in it) and the float
// cross-check (an independent number system). See VERIFICATION_PLAN.md.
//
// MATCHING BY SEQUENCE NUMBER, NOT BY POSITION
// --------------------------------------------
// Every beat carries seq, stream_id and user, and every output is matched to its
// input BY SEQ. That is what makes "valid metadata travels with the
// corresponding samples" a checked property rather than an assumption. It is
// also what lets one expectation list serve three engines whose output RATES
// differ: DUT 1's output sequence is {seq_in, group}, so its two beats per input
// land on two distinct, predictable keys.
//
// THE NEGATIVE TEST RUNS LAST
// ---------------------------
// `a_coeff_swap_at_sof` — the frame-boundary rule rtl/beamformer/weight_bank.sv
// inherits from the store it reuses — is only worth having if it can fire.
// beamformer_top carries one weight_bank elaborated with ALLOW_UNSAFE_SWAP = 1,
// outside the datapath, whose swap ignores the frame boundary. The final mode
// drives it with `Verilated::fatalOnError` cleared and stdout captured, and
// REQUIRES that exact property to fire by name. It runs last because clearing
// fatalOnError weakens every assertion in the build.
//
// Built by `make sim-tiny` as:
//   scripts/build_verilator.py --mode fast --top beamformer_top
//       --files sim/verilator/files_beamformer.f --test test_beamformer
// -----------------------------------------------------------------------------

#include <unistd.h>

#include <algorithm>
#include <chrono>
#include <cstdint>
#include <cstdio>
#include <cstring>
#include <map>
#include <memory>
#include <random>
#include <string>
#include <vector>

#include "Vbeamformer_top.h"
#include "verilated.h"

#include "config_sim.h"
#include "harness/error_collector.h"
#include "harness/random.h"
#include "harness/run_summary.h"
#include "harness/sim_args.h"

#include "beamformer/beamformer_model.hpp"
#include "fxp/fxp.hpp"

using harness::BackpressureConfig;
using harness::BackpressureGenerator;
using harness::ErrorCollector;
using harness::RunSummary;
using harness::SeedSource;
using harness::SimArgs;

namespace {

constexpr const char* kTestName = "test_beamformer";

// ---------------------------------------------------------------------------
// Mirror of the geometry in sim/verilator/tops/beamformer_top.sv. Checked
// against the RTL's own cfg_* echo before anything else runs, so a drift is a
// named failure rather than a silently wrong comparison.
// ---------------------------------------------------------------------------
constexpr unsigned kNAnt = 4;
constexpr unsigned kNBeams = 4;
constexpr unsigned kBinPar = 2;
constexpr unsigned kMultPipe = 4;
constexpr unsigned kAddrW = 4;             // clog2(kNBeams * kNAnt)
constexpr unsigned kNWeight = kNBeams * kNAnt;

constexpr unsigned kDot16Ant = 16;

// The three matrix DUTs.
constexpr unsigned kNDut = 3;
constexpr unsigned kBeamPar[kNDut] = {4, 2, 4};
constexpr unsigned kRegEvery[kNDut] = {1, 1, 2};
const char* const kDutName[kNDut] = {"ref", "mux2", "reg2"};

constexpr unsigned kMetaW = 2 + 2 + 16 + 4;                        // 24
constexpr unsigned kSPayloadW = kBinPar * kNAnt * 32 + kMetaW;     // 280
constexpr unsigned kM04PayloadW = kBinPar * 4 * 32 + kMetaW;       // 280
constexpr unsigned kM2PayloadW = kBinPar * 2 * 32 + kMetaW;        // 152

// Cycles allowed after the last input before a pass gives up waiting for output.
constexpr unsigned kDrainCycles = 4000;

// The double-precision cross-check budget, in output LSB. A Q1.15 output rounded
// once from an exact 37-bit accumulator differs from the real-valued sum by at
// most half an LSB, and the double evaluation of a sum of at most 32 products of
// 16-bit integers is exact (every partial sum is far inside 2^53). Two LSB is
// therefore generous by a factor of four and still tight enough to catch a
// misrouted antenna.
constexpr double kFloatBudgetLsb = 2.0;

// ---------------------------------------------------------------------------
// Failure accounting. The relation that disagrees is the diagnosis, so the
// counts are kept apart rather than summed (NUMERICS.md 10, triage procedure).
// ---------------------------------------------------------------------------
struct Counters {
  std::size_t config = 0;
  std::size_t rtl_vs_model = 0;
  std::size_t rtl_vs_float = 0;
  std::size_t rtl_vs_directed = 0;
  std::size_t metadata = 0;
  std::size_t alignment = 0;
  std::size_t metamorphic = 0;
  std::size_t telemetry = 0;
  std::size_t throughput = 0;
  std::size_t coverage = 0;
  std::size_t assertion = 0;

  std::size_t total() const {
    return config + rtl_vs_model + rtl_vs_float + rtl_vs_directed + metadata +
           alignment + metamorphic + telemetry + throughput + coverage +
           assertion;
  }
};

void report(ErrorCollector* errors, const char* category, std::size_t* counter,
            const std::string& message) {
  ++*counter;
  errors->error(category, message);
}

std::string cx(fxp::Complex c) {
  return "(" + std::to_string(c.re) + "," + std::to_string(c.im) + ")";
}

std::string flags_str(unsigned packed) {
  return std::string((packed & 2u) ? "+" : ".") + ((packed & 1u) ? "-" : ".");
}

// ---------------------------------------------------------------------------
// DUT driving
// ---------------------------------------------------------------------------

using Top = Vbeamformer_top;

void tick(Top* top) {
  top->clk = 0;
  top->eval();
  top->clk = 1;
  top->eval();
}

// Settles combinationally with the current inputs applied, WITHOUT taking the
// edge. Everything observable must be read here, so it reflects the state the
// edge is about to act on.
void settle(Top* top) {
  top->clk = 0;
  top->eval();
}

void idle_inputs(Top* top) {
  top->s_valid = 0;
  top->s_sof = 0;
  top->s_eof = 0;
  top->s_id = 0;
  top->s_seq = 0;
  top->s_user = 0;
  for (unsigned i = 0; i < kBinPar * kNAnt; ++i) top->s_data[i] = 0;
  top->m_ready = 1;
  top->cfg_wr_valid = 0;
  top->cfg_wr_bank = 0;
  top->cfg_wr_addr = 0;
  top->cfg_wr_data = 0;
  top->cfg_swap_req = 0;
  top->telem_clear = 0;
  top->telem_snapshot = 0;
  top->d_valid_in = 0;
  for (unsigned i = 0; i < kDot16Ant; ++i) {
    top->d_x[i] = 0;
    top->d_w[i] = 0;
  }
  top->unsafe_swap_req = 0;
  top->unsafe_beat = 0;
  top->unsafe_sof = 0;
}

void reset_dut(Top* top) {
  idle_inputs(top);
  top->rst_n = 0;
  for (int i = 0; i < 8; ++i) tick(top);
  top->rst_n = 1;
  for (int i = 0; i < 4; ++i) tick(top);
}

// The SPEC 7.5 input contract: bin-major, antenna-minor. `x[bin][antenna]`.
void set_beat(Top* top, const std::vector<std::vector<fxp::Complex>>& x) {
  for (unsigned j = 0; j < kBinPar; ++j) {
    for (unsigned a = 0; a < kNAnt; ++a) {
      top->s_data[j * kNAnt + a] = static_cast<std::uint32_t>(x[j][a].packed());
    }
  }
}

// The output contract: beam-major, bin-minor, within one beam group.
std::vector<fxp::Complex> get_out(const Top* top, unsigned dut) {
  const unsigned n = kBeamPar[dut] * kBinPar;
  std::vector<fxp::Complex> out(n);
  for (unsigned i = 0; i < n; ++i) {
    std::uint32_t wrd = 0;
    if (dut == 0) wrd = top->m0_data[i];
    else if (dut == 1) wrd = top->m1_data[i];
    else wrd = top->m2_data[i];
    out[i] = fxp::Complex::from_packed(wrd);
  }
  return out;
}

// One weight write through the configuration port. Returns false only if the
// crossing never accepted it, which would be a defect in the handshake rather
// than in this test.
bool cfg_write(Top* top, unsigned bank, unsigned addr, fxp::Complex value) {
  top->cfg_wr_valid = 1;
  top->cfg_wr_bank = static_cast<std::uint8_t>(bank & 1u);
  top->cfg_wr_addr = static_cast<std::uint8_t>(addr);
  top->cfg_wr_data = static_cast<std::uint32_t>(value.packed());
  for (unsigned guard = 0; guard < 2000; ++guard) {
    settle(top);
    const bool accepted = top->cfg_wr_ready != 0;
    tick(top);
    if (accepted) {
      top->cfg_wr_valid = 0;
      return true;
    }
  }
  top->cfg_wr_valid = 0;
  return false;
}

bool program_bank(Top* top, unsigned bank, const std::vector<fxp::Complex>& w) {
  for (unsigned i = 0; i < kNWeight; ++i) {
    if (!cfg_write(top, bank, i, w[i])) return false;
  }
  return true;
}

// Requests a bank swap and waits for the crossing to accept the pulse. The swap
// itself does NOT happen here: it happens at the next admitted start-of-frame
// beat, which is the property under test.
bool request_swap(Top* top) {
  for (unsigned guard = 0; guard < 2000; ++guard) {
    settle(top);
    if (top->cfg_swap_busy == 0) break;
    tick(top);
  }
  top->cfg_swap_req = 1;
  tick(top);
  top->cfg_swap_req = 0;
  for (unsigned guard = 0; guard < 2000; ++guard) {
    settle(top);
    if (top->cfg_swap_pending != 0) return true;
    tick(top);
  }
  return false;
}

// ---------------------------------------------------------------------------
// The standalone 16-antenna dot products
//
// No stream, no ready: bf_dot is a fixed-latency kernel, so the operands are
// driven back to back and the results are collected in order as `valid_out`
// rises. Both instances are driven from one operand port and differ only in
// ADD_REG_EVERY, so their latencies differ and their VALUE streams must not.
// ---------------------------------------------------------------------------

struct DotOps {
  std::vector<fxp::Complex> x;
  std::vector<fxp::Complex> w;
};

struct DotObs {
  fxp::Complex y;
  unsigned flags = 0;  // {re.pos, re.neg, im.pos, im.neg}
  bool ovf = false;
  std::int64_t acc_re = 0;
  std::int64_t acc_im = 0;
};

struct DotPass {
  std::vector<DotObs> obs[2];  // [0] = ADD_REG_EVERY 1, [1] = ADD_REG_EVERY 2
};

DotPass run_dot(Top* top, const std::vector<DotOps>& ops) {
  DotPass r;
  idle_inputs(top);

  // Latency is at most mult_pipe + clog2(16) + 1 = 9; drain generously.
  const std::size_t total = ops.size() + 64;
  for (std::size_t i = 0; i < total; ++i) {
    if (i < ops.size()) {
      top->d_valid_in = 1;
      for (unsigned a = 0; a < kDot16Ant; ++a) {
        top->d_x[a] = static_cast<std::uint32_t>(ops[i].x[a].packed());
        top->d_w[a] = static_cast<std::uint32_t>(ops[i].w[a].packed());
      }
    } else {
      top->d_valid_in = 0;
    }

    settle(top);

    if (top->d0_valid_out) {
      DotObs o;
      o.y = fxp::Complex::from_packed(top->d0_y);
      o.flags = top->d0_flags;
      o.ovf = top->d0_ovf != 0;
      o.acc_re = static_cast<std::int64_t>(top->d0_acc_re);
      o.acc_im = static_cast<std::int64_t>(top->d0_acc_im);
      r.obs[0].push_back(o);
    }
    if (top->d1_valid_out) {
      DotObs o;
      o.y = fxp::Complex::from_packed(top->d1_y);
      o.flags = top->d1_flags;
      o.ovf = top->d1_ovf != 0;
      r.obs[1].push_back(o);
    }

    tick(top);
  }

  top->d_valid_in = 0;
  return r;
}

// ---------------------------------------------------------------------------
// The matrix pass engine
// ---------------------------------------------------------------------------

struct InBeat {
  std::vector<std::vector<fxp::Complex>> x;  // [bin][antenna]
  bool sof = false;
  bool eof = false;
  std::uint16_t seq = 0;
  std::uint8_t id = 0;
  std::uint8_t user = 0;
};

struct OutBeat {
  std::uint16_t seq = 0;
  std::vector<fxp::Complex> y;
  bool sof = false;
  bool eof = false;
  std::uint8_t id = 0;
  std::uint8_t user = 0;
};

struct CfgAction {
  std::size_t at_beat = 0;
  bool swap = false;
  bool write = false;
  unsigned bank = 0;
  unsigned addr = 0;
  fxp::Complex value{};
};

struct PassResult {
  std::vector<OutBeat> out[kNDut];
  std::size_t admitted = 0;
  bool timed_out = false;
  std::uint64_t cycles = 0;
  std::uint64_t offer_cycles = 0;
};

PassResult run_pass(Top* top, const std::vector<InBeat>& beats,
                    BackpressureConfig gap_cfg, BackpressureConfig bp_cfg,
                    SeedSource& seeds, const std::string& tag,
                    std::vector<CfgAction> actions) {
  PassResult r;
  BackpressureGenerator gaps(seeds.engine(tag + ".gaps"), gap_cfg);
  BackpressureGenerator bp(seeds.engine(tag + ".bp"), bp_cfg);

  std::size_t next_in = 0;
  std::size_t next_action = 0;
  bool cfg_busy = false;
  bool swap_pulse_pending = false;
  std::uint64_t idle_cycles = 0;

  idle_inputs(top);

  while (true) {
    // ---- configuration activity, interleaved with the stream ---------------
    if (!cfg_busy && !swap_pulse_pending && next_action < actions.size() &&
        actions[next_action].at_beat <= next_in) {
      const CfgAction& a = actions[next_action];
      if (a.swap) {
        swap_pulse_pending = true;
      } else if (a.write) {
        top->cfg_wr_valid = 1;
        top->cfg_wr_bank = static_cast<std::uint8_t>(a.bank & 1u);
        top->cfg_wr_addr = static_cast<std::uint8_t>(a.addr);
        top->cfg_wr_data = static_cast<std::uint32_t>(a.value.packed());
        cfg_busy = true;
      }
      ++next_action;
    }
    top->cfg_swap_req = swap_pulse_pending ? 1 : 0;

    // ---- slave side ---------------------------------------------------------
    const bool offer = (next_in < beats.size()) && gaps.allow();
    if (offer) {
      const InBeat& b = beats[next_in];
      top->s_valid = 1;
      top->s_sof = b.sof ? 1 : 0;
      top->s_eof = b.eof ? 1 : 0;
      top->s_id = static_cast<std::uint8_t>(b.id);
      top->s_seq = static_cast<std::uint16_t>(b.seq);
      top->s_user = static_cast<std::uint8_t>(b.user);
      set_beat(top, b.x);
      ++r.offer_cycles;
    } else {
      top->s_valid = 0;
    }

    // ---- master side --------------------------------------------------------
    top->m_ready = bp.allow() ? 1 : 0;

    // ---- settle and observe -------------------------------------------------
    settle(top);

    const bool transferred = offer && (top->s_ready != 0);
    const bool cfg_taken = cfg_busy && (top->cfg_wr_ready != 0);

    for (unsigned d = 0; d < kNDut; ++d) {
      const bool v = (d == 0) ? (top->m0_valid != 0)
                              : ((d == 1) ? (top->m1_valid != 0)
                                          : (top->m2_valid != 0));
      if (!v || top->m_ready == 0) continue;
      OutBeat o;
      o.y = get_out(top, d);
      if (d == 0) {
        o.seq = static_cast<std::uint16_t>(top->m0_seq);
        o.sof = top->m0_sof != 0;
        o.eof = top->m0_eof != 0;
        o.id = static_cast<std::uint8_t>(top->m0_id);
        o.user = static_cast<std::uint8_t>(top->m0_user);
      } else if (d == 1) {
        o.seq = static_cast<std::uint16_t>(top->m1_seq);
        o.sof = top->m1_sof != 0;
        o.eof = top->m1_eof != 0;
        o.id = static_cast<std::uint8_t>(top->m1_id);
        o.user = static_cast<std::uint8_t>(top->m1_user);
      } else {
        o.seq = static_cast<std::uint16_t>(top->m2_seq);
        o.sof = top->m2_sof != 0;
        o.eof = top->m2_eof != 0;
        o.id = static_cast<std::uint8_t>(top->m2_id);
        o.user = static_cast<std::uint8_t>(top->m2_user);
      }
      r.out[d].push_back(std::move(o));
      idle_cycles = 0;
    }

    // ---- edge ---------------------------------------------------------------
    tick(top);
    ++r.cycles;

    if (transferred) {
      ++next_in;
      ++r.admitted;
      idle_cycles = 0;
    }
    if (cfg_taken) {
      top->cfg_wr_valid = 0;
      cfg_busy = false;
    }
    if (swap_pulse_pending) {
      swap_pulse_pending = false;
      top->cfg_swap_req = 0;
    }

    if (next_in >= beats.size()) {
      ++idle_cycles;
      if (idle_cycles > kDrainCycles) {
        r.timed_out = true;
        break;
      }
      if (idle_cycles > 64 && top->m0_valid == 0 && top->m1_valid == 0 &&
          top->m2_valid == 0) {
        break;
      }
    }

    if (r.cycles > 4000000ull) {
      r.timed_out = true;
      break;
    }
  }

  idle_inputs(top);
  return r;
}

// ---------------------------------------------------------------------------
// Expectations
//
// One expectation MAP per DUT, keyed by the OUTPUT sequence number. A map rather
// than a positional list because DUT 1 emits two beats per input beat with
// seq = {seq_in, group}: the keys are still unique and still predictable, but
// they are no longer a dense range starting at the pass's first beat.
// ---------------------------------------------------------------------------

struct ExpBeat {
  std::vector<fxp::Complex> y;
  std::vector<unsigned> f_re;   // per output slot, packed
  std::vector<unsigned> f_im;
  std::vector<bf::DotFloat> yf;
  bool sof = false;
  bool eof = false;
  std::uint8_t id = 0;
  std::uint8_t user = 0;
  bool saturating = false;
  std::size_t in_index = 0;
};

using ExpMap = std::map<std::uint16_t, ExpBeat>;

// Builds the expectation for one DUT over `beats`. `swap_at` (if non-zero) names
// the ADMITTED BEAT INDEX at which the weights are replaced — the model twin of
// a bank swap, which is instantaneous because a beamformer has no history.
ExpMap expect_for(const std::vector<InBeat>& beats,
                  const std::vector<fxp::Complex>& w, std::size_t swap_at,
                  const std::vector<fxp::Complex>& w2, unsigned dut) {
  const unsigned beam_par = kBeamPar[dut];
  bf::BeamformerModel model(kNAnt, kNBeams, kBinPar, w);
  ExpMap out;

  for (std::size_t i = 0; i < beats.size(); ++i) {
    if (swap_at != 0 && i == swap_at) model.swap_weights(w2);
    const bf::BeamBeat r = model.step(beats[i].x);
    const auto yf = model.step_float(beats[i].x);
    const auto split = bf::split_beat(r, beam_par, beats[i].seq, beats[i].id,
                                      beats[i].sof, beats[i].eof);
    const unsigned mux = bf::beam_mux(kNBeams, beam_par);
    for (unsigned g = 0; g < mux; ++g) {
      ExpBeat e;
      e.y = split[g].data;
      e.sof = split[g].sof;
      e.eof = split[g].eof;
      e.id = static_cast<std::uint8_t>(split[g].stream_id);
      e.user = static_cast<std::uint8_t>(split[g].user);
      e.saturating = split[g].saturating;
      e.in_index = i;
      e.f_re.resize(e.y.size());
      e.f_im.resize(e.y.size());
      e.yf.resize(e.y.size());
      for (unsigned k = 0; k < beam_par; ++k) {
        const unsigned b = g * beam_par + k;
        for (unsigned j = 0; j < kBinPar; ++j) {
          const std::size_t slot = static_cast<std::size_t>(k) * kBinPar + j;
          e.f_re[slot] = r.f_re[b][j].packed();
          e.f_im[slot] = r.f_im[b][j].packed();
          e.yf[slot] = yf[b][j];
        }
      }
      out[static_cast<std::uint16_t>(split[g].seq)] = std::move(e);
    }
  }
  return out;
}

struct CheckStats {
  std::size_t checked = 0;
  std::size_t saturating_seen = 0;
  unsigned flag_union = 0;
  std::size_t frames = 0;
};

CheckStats check_outputs(const std::string& where, unsigned dut,
                         const std::vector<OutBeat>& out, const ExpMap& expect,
                         ErrorCollector* errors, Counters* c) {
  CheckStats st;
  std::map<std::uint16_t, bool> seen;

  for (const OutBeat& o : out) {
    const auto it = expect.find(o.seq);
    if (it == expect.end()) {
      report(errors, "metadata", &c->metadata,
             where + ": output seq " + std::to_string(o.seq) +
                 " was never driven");
      continue;
    }
    if (seen[o.seq]) {
      report(errors, "alignment", &c->alignment,
             where + ": output seq " + std::to_string(o.seq) + " arrived twice");
      continue;
    }
    seen[o.seq] = true;
    ++st.checked;

    const ExpBeat& e = it->second;
    if (e.eof) ++st.frames;
    if (e.saturating) ++st.saturating_seen;

    for (std::size_t s = 0; s < e.y.size(); ++s) {
      st.flag_union |= e.f_re[s] | e.f_im[s];
      if (o.y[s] != e.y[s]) {
        const unsigned k = static_cast<unsigned>(s / kBinPar);
        const unsigned j = static_cast<unsigned>(s % kBinPar);
        report(errors, "rtl_vs_model", &c->rtl_vs_model,
               where + " seq " + std::to_string(o.seq) + " beam+" +
                   std::to_string(k) + " bin " + std::to_string(j) + ": RTL " +
                   cx(o.y[s]) + " vs model " + cx(e.y[s]) + " (flags " +
                   flags_str(e.f_re[s]) + "/" + flags_str(e.f_im[s]) + ")");
      }

      // The independent double-precision leg. Only meaningful where nothing
      // clamped: a saturating output is a clamp, and a clamp is not an
      // approximation of the real sum.
      if (e.f_re[s] == 0 && e.f_im[s] == 0) {
        const double dre = static_cast<double>(o.y[s].re) - e.yf[s].re;
        const double dim = static_cast<double>(o.y[s].im) - e.yf[s].im;
        if (dre > kFloatBudgetLsb || dre < -kFloatBudgetLsb ||
            dim > kFloatBudgetLsb || dim < -kFloatBudgetLsb) {
          report(errors, "rtl_vs_float", &c->rtl_vs_float,
                 where + " seq " + std::to_string(o.seq) + " slot " +
                     std::to_string(s) + ": RTL " + cx(o.y[s]) +
                     " is more than " + std::to_string(kFloatBudgetLsb) +
                     " LSB from the double-precision sum (" +
                     std::to_string(e.yf[s].re) + "," +
                     std::to_string(e.yf[s].im) + ")");
        }
      }
    }

    if (o.sof != e.sof || o.eof != e.eof || o.id != e.id || o.user != e.user) {
      report(errors, "metadata", &c->metadata,
             where + " seq " + std::to_string(o.seq) + ": metadata RTL {sof=" +
                 std::to_string(o.sof ? 1 : 0) + " eof=" +
                 std::to_string(o.eof ? 1 : 0) + " id=" + std::to_string(o.id) +
                 " user=" + std::to_string(o.user) + "} vs expected {sof=" +
                 std::to_string(e.sof ? 1 : 0) + " eof=" +
                 std::to_string(e.eof ? 1 : 0) + " id=" + std::to_string(e.id) +
                 " user=" + std::to_string(e.user) + "}");
    }
  }

  // Nothing may be lost: the beamformer has no warm-up and no drain state, so
  // every driven beat must produce every one of its beam groups.
  std::size_t missing = 0;
  for (const auto& kv : expect) {
    if (!seen[kv.first]) ++missing;
  }
  if (missing != 0) {
    report(errors, "alignment", &c->alignment,
           where + ": " + std::to_string(missing) + " of " +
               std::to_string(expect.size()) +
               " expected output beats never arrived");
  }
  return st;
}

// ---------------------------------------------------------------------------
// Stimulus construction
//
// ONE stream id and a GLOBALLY monotonic sequence number for the whole run.
// sim/assertions/stream_protocol_checker.sv checks SPEC 5 sequence continuity
// per stream id on each beamformer's master interface and is watching
// throughout; restarting the count per pass would make the DUT's own protocol
// checker fire on the testbench's stimulus rather than on a defect. DUT 1's
// output sequence is {seq_in, group}, which is continuous exactly when the input
// sequence is.
// ---------------------------------------------------------------------------
constexpr std::uint8_t kStreamId = 1;
std::uint16_t g_seq = 0;

fxp::i16 rand_q15(std::mt19937_64& rng, std::int64_t lo, std::int64_t hi) {
  return static_cast<fxp::i16>(
      static_cast<std::int64_t>(harness::uniform_u64(
          rng, 0, static_cast<std::uint64_t>(hi - lo))) +
      lo);
}

std::vector<std::vector<fxp::Complex>> rand_beat(std::mt19937_64& rng,
                                                 std::int64_t lo,
                                                 std::int64_t hi) {
  std::vector<std::vector<fxp::Complex>> x(kBinPar,
                                           std::vector<fxp::Complex>(kNAnt));
  for (unsigned j = 0; j < kBinPar; ++j) {
    for (unsigned a = 0; a < kNAnt; ++a) {
      x[j][a] = fxp::Complex{rand_q15(rng, lo, hi), rand_q15(rng, lo, hi)};
    }
  }
  return x;
}

void tag_metadata(std::vector<InBeat>* beats, std::size_t first,
                  std::size_t last) {
  for (std::size_t i = first; i <= last && i < beats->size(); ++i) {
    (*beats)[i].id = kStreamId;
    (*beats)[i].user = static_cast<std::uint8_t>((*beats)[i].seq & 0xFu);
    (*beats)[i].sof = (i == first);
    (*beats)[i].eof = (i == last);
  }
}

// ---------------------------------------------------------------------------
// The expected-failure mode. See the header for why it runs last.
// ---------------------------------------------------------------------------

struct Capture {
  int saved_fd = -1;
  FILE* tmp = nullptr;
  std::string text;

  void begin() {
    std::fflush(stdout);
    saved_fd = dup(1);
    tmp = std::tmpfile();
    if (tmp) dup2(fileno(tmp), 1);
  }

  void end() {
    std::fflush(stdout);
    if (saved_fd >= 0) {
      dup2(saved_fd, 1);
      close(saved_fd);
      saved_fd = -1;
    }
    if (tmp) {
      std::rewind(tmp);
      char buf[4096];
      std::size_t n;
      while ((n = std::fread(buf, 1, sizeof(buf), tmp)) > 0) {
        text.append(buf, n);
      }
      std::fclose(tmp);
      tmp = nullptr;
    }
  }
};

}  // namespace

// ---------------------------------------------------------------------------

int harness::sim_test_main(const SimArgs& args) {
  const auto wall_start = std::chrono::steady_clock::now();
  ErrorCollector errors;
  // A matrix mismatch is BEAM_PAR*BIN_PAR errors wide by construction, so the
  // default limit of twenty shows two and a half beats. Sixty shows the shape of
  // the failure — which beams, which bins, which DUT — which is what triage
  // needs.
  errors.set_print_limit(60);
  Counters counters;
  SeedSource seeds(args.seed);

  std::unique_ptr<Top> top(new Top);
  reset_dut(top.get());
  settle(top.get());

  unsigned flag_union = 0;
  std::size_t beats_checked = 0;
  std::size_t frames_checked = 0;
  std::size_t dots_checked = 0;
  unsigned active_bank = 0;   // the bank the RTL is currently beamforming with

  // =========================================================================
  // Pass 0 — geometry echo, and the SPEC 7.5 reported throughput
  // =========================================================================
  {
    struct Field { const char* name; unsigned rtl; unsigned mirror; };
    const Field fields[] = {
        {"n_ant", top->cfg_n_ant, kNAnt},
        {"n_beams", top->cfg_n_beams, kNBeams},
        {"mult_pipe", top->cfg_mult_pipe, kMultPipe},
        {"weight_addr_w", top->cfg_weight_addr_w, kAddrW},
        {"acc_w", top->cfg_acc_w, bf::acc_w(kNAnt)},
        {"dot16_acc_w", top->cfg_dot16_acc_w, bf::acc_w(kDot16Ant)},
        {"lat[ref]", top->cfg_lat0, bf::lat_cycles(kNAnt, kMultPipe, 1)},
        {"lat[mux2]", top->cfg_lat1, bf::lat_cycles(kNAnt, kMultPipe, 1)},
        {"lat[reg2]", top->cfg_lat2, bf::lat_cycles(kNAnt, kMultPipe, 2)},
        {"dot16_lat[r1]", top->cfg_dot16_lat_r1,
         bf::dot_lat(kDot16Ant, kMultPipe, 1)},
        {"dot16_lat[r2]", top->cfg_dot16_lat_r2,
         bf::dot_lat(kDot16Ant, kMultPipe, 2)},
        {"s_payload_w", top->cfg_s_payload_w, kSPayloadW},
        {"m0_payload_w", top->cfg_m0_payload_w, kM04PayloadW},
        {"m1_payload_w", top->cfg_m1_payload_w, kM2PayloadW},
    };
    for (const Field& f : fields) {
      if (f.rtl != f.mirror) {
        report(&errors, "config", &counters.config,
               std::string("geometry ") + f.name + ": RTL " +
                   std::to_string(f.rtl) + " vs test mirror " +
                   std::to_string(f.mirror));
      }
    }

    // SPEC 7.5: "Do not silently reduce throughput to meet utilization. Any time
    // multiplexing must be visible in parameters and reported throughput." The
    // reported numbers must be non-zero, must agree with the elaborated
    // parallelism, and — the point of the check — the multiplexed engine must
    // REPORT its multiplex factor rather than claiming the reference engine's
    // input rate.
    const Field tput[] = {
        {"tput_n_ant", top->tput_n_ant, kNAnt},
        {"tput_n_beams", top->tput_n_beams, kNBeams},
        {"tput_bin_par[ref]", top->tput_bin_par0, kBinPar},
        {"tput_beam_par[ref]", top->tput_beam_par0, kBeamPar[0]},
        {"tput_beam_mux[ref]", top->tput_beam_mux0,
         bf::beam_mux(kNBeams, kBeamPar[0])},
        {"tput_beam_bins[ref]", top->tput_bb0, kBinPar * kBeamPar[0]},
        {"tput_beam_par[mux2]", top->tput_beam_par1, kBeamPar[1]},
        {"tput_beam_mux[mux2]", top->tput_beam_mux1,
         bf::beam_mux(kNBeams, kBeamPar[1])},
        {"tput_beam_bins[mux2]", top->tput_bb1, kBinPar * kBeamPar[1]},
    };
    for (const Field& f : tput) {
      if (f.rtl != f.mirror) {
        report(&errors, "throughput", &counters.throughput,
               std::string("reported ") + f.name + ": RTL " +
                   std::to_string(f.rtl) + " vs expected " +
                   std::to_string(f.mirror));
      }
      if (f.rtl == 0) {
        report(&errors, "throughput", &counters.throughput,
               std::string("reported ") + f.name + " is zero");
      }
    }
    if (top->tput_beam_mux1 <= top->tput_beam_mux0) {
      report(&errors, "throughput", &counters.throughput,
             "the multiplexed engine reports a multiplex factor of " +
                 std::to_string(top->tput_beam_mux1) +
                 ", no larger than the reference engine's " +
                 std::to_string(top->tput_beam_mux0) +
                 "; time multiplexing is not visible in the reported throughput");
    }
  }
  if (counters.config != 0) {
    std::printf("RESULT: FAIL seed=%llu test=%s reason=geometry_mirror\n",
                static_cast<unsigned long long>(args.seed), kTestName);
    return 2;
  }

  // =========================================================================
  // Pass 1 — the SPEC 13.2 zero relations on the 16-antenna dot product
  //
  // Zero weights against any input, and any weights against zero input. Both
  // must be exactly zero with no saturation flag. Written first because its
  // expected value can be stated without any model at all.
  // =========================================================================
  {
    std::mt19937_64 rng = seeds.engine("dot.zero");
    std::vector<DotOps> ops;
    for (unsigned i = 0; i < 32; ++i) {
      DotOps o;
      o.x.resize(kDot16Ant);
      o.w.resize(kDot16Ant);
      for (unsigned a = 0; a < kDot16Ant; ++a) {
        const fxp::Complex v{rand_q15(rng, -32768, 32767),
                             rand_q15(rng, -32768, 32767)};
        if (i < 16) {
          o.x[a] = v;                 // random input, zero weights
        } else {
          o.w[a] = v;                 // zero input, random weights
        }
      }
      ops.push_back(std::move(o));
    }
    const DotPass p = run_dot(top.get(), ops);
    for (unsigned inst = 0; inst < 2; ++inst) {
      if (p.obs[inst].size() != ops.size()) {
        report(&errors, "alignment", &counters.alignment,
               std::string("dot.zero[r") + std::to_string(inst + 1) + "]: " +
                   std::to_string(p.obs[inst].size()) + " results for " +
                   std::to_string(ops.size()) + " operand pairs");
        continue;
      }
      for (std::size_t i = 0; i < ops.size(); ++i) {
        const DotObs& o = p.obs[inst][i];
        if (o.y.re != 0 || o.y.im != 0 || o.flags != 0 || o.ovf) {
          report(&errors, "rtl_vs_directed", &counters.rtl_vs_directed,
                 std::string("dot.zero[r") + std::to_string(inst + 1) +
                     "] beat " + std::to_string(i) + ": a zero operand gave " +
                     cx(o.y) + " flags " + std::to_string(o.flags));
        }
        ++dots_checked;
      }
    }
  }

  // =========================================================================
  // Pass 2 — directed dot products: unit weights, orthogonal patterns
  //
  // UNIT WEIGHTS. w[a] = 0x7FFF for one antenna and zero elsewhere, so the
  // result IS that antenna's sample scaled by 32767/32768. The expectation is
  // computed by bf::unit_weight_expect(), a ONE-TERM dot product — so if the
  // sixteen-term path is wired wrong this fails, and it fails naming the
  // antenna.
  //
  // ORTHOGONAL PATTERNS. Rows of a 16x16 Hadamard-style matrix scaled to
  // +/-1/16: with the input equal to row p, the dot product against row q is
  // (1/16) * sum_a H[p][a]*H[q][a], which is 1 for p == q and EXACTLY 0
  // otherwise. Zero is the interesting half: it is an expectation with no model
  // in it and it exercises every antenna at full weight.
  //
  // WHAT IT DOES NOT CATCH, stated because the opposite is the natural
  // assumption: a TRANSPOSED weight index. The Sylvester Hadamard matrix is
  // symmetric — H[p][a] depends only on popcount(p & a), which is symmetric in
  // its arguments — so H == H^T and this pass is blind to a transpose by
  // construction. That is not a defect in the pass; orthogonality is what it is
  // for. The transpose is caught by the cyclic-shift unit-weight pass below and,
  // decisively, by the SPEC 13.2 permutation relation in pass 7.
  // =========================================================================
  {
    // --- unit weights ------------------------------------------------------
    std::mt19937_64 rng = seeds.engine("dot.unit");
    std::vector<DotOps> ops;
    std::vector<unsigned> sel_of;
    std::vector<fxp::Complex> src_of;
    for (unsigned a = 0; a < kDot16Ant; ++a) {
      for (unsigned rep = 0; rep < 4; ++rep) {
        DotOps o;
        o.x.resize(kDot16Ant);
        o.w.assign(kDot16Ant, fxp::Complex{});
        for (unsigned i = 0; i < kDot16Ant; ++i) {
          o.x[i] = fxp::Complex{rand_q15(rng, -32768, 32767),
                                rand_q15(rng, -32768, 32767)};
        }
        o.w[a] = fxp::Complex{fxp::q15_max(), 0};
        sel_of.push_back(a);
        src_of.push_back(o.x[a]);
        ops.push_back(std::move(o));
      }
    }
    const DotPass p = run_dot(top.get(), ops);
    for (unsigned inst = 0; inst < 2; ++inst) {
      if (p.obs[inst].size() != ops.size()) {
        report(&errors, "alignment", &counters.alignment,
               std::string("dot.unit[r") + std::to_string(inst + 1) + "]: " +
                   std::to_string(p.obs[inst].size()) + " results for " +
                   std::to_string(ops.size()) + " operand pairs");
        continue;
      }
      for (std::size_t i = 0; i < ops.size(); ++i) {
        const fxp::Complex want = bf::unit_weight_expect(src_of[i]);
        if (p.obs[inst][i].y != want) {
          report(&errors, "rtl_vs_directed", &counters.rtl_vs_directed,
                 std::string("dot.unit[r") + std::to_string(inst + 1) +
                     "] antenna " + std::to_string(sel_of[i]) + ": RTL " +
                     cx(p.obs[inst][i].y) + " vs passthrough " + cx(want) +
                     " of " + cx(src_of[i]));
        }
        ++dots_checked;
      }
    }
  }
  {
    // --- orthogonal (Hadamard) patterns ------------------------------------
    // H[p][a] = +/-1 from the parity of popcount(p & a); the Sylvester
    // construction, so H*H^T = 16*I exactly.
    auto hval = [](unsigned p, unsigned a) -> int {
      unsigned v = p & a;
      unsigned bits = 0;
      while (v) { bits += v & 1u; v >>= 1; }
      return (bits & 1u) ? -1 : +1;
    };
    // 1/16 in Q1.15 is 2048, exactly representable, so the scaled rows carry no
    // quantisation error and the orthogonality is exact in fixed point too.
    constexpr fxp::i16 kScale = 2048;

    std::vector<DotOps> ops;
    std::vector<unsigned> row_of, col_of;
    for (unsigned q = 0; q < kDot16Ant; ++q) {
      for (unsigned p = 0; p < kDot16Ant; ++p) {
        DotOps o;
        o.x.resize(kDot16Ant);
        o.w.resize(kDot16Ant);
        for (unsigned a = 0; a < kDot16Ant; ++a) {
          o.x[a] = fxp::Complex{static_cast<fxp::i16>(hval(p, a) * 32767), 0};
          o.w[a] = fxp::Complex{static_cast<fxp::i16>(hval(q, a) * kScale), 0};
        }
        row_of.push_back(p);
        col_of.push_back(q);
        ops.push_back(std::move(o));
      }
    }
    const DotPass p = run_dot(top.get(), ops);
    std::size_t diag = 0, offdiag = 0;
    for (unsigned inst = 0; inst < 2; ++inst) {
      if (p.obs[inst].size() != ops.size()) {
        report(&errors, "alignment", &counters.alignment,
               std::string("dot.orth[r") + std::to_string(inst + 1) + "]: " +
                   std::to_string(p.obs[inst].size()) + " results for " +
                   std::to_string(ops.size()) + " operand pairs");
        continue;
      }
      for (std::size_t i = 0; i < ops.size(); ++i) {
        const bf::DotResult want = bf::dot(ops[i].x, ops[i].w);
        const fxp::Complex got = p.obs[inst][i].y;
        if (got != want.y) {
          report(&errors, "rtl_vs_model", &counters.rtl_vs_model,
                 std::string("dot.orth[r") + std::to_string(inst + 1) +
                     "] row " + std::to_string(row_of[i]) + " vs " +
                     std::to_string(col_of[i]) + ": RTL " + cx(got) +
                     " vs model " + cx(want.y));
        }
        // The oracle-free half: off-diagonal products must be EXACTLY zero.
        if (row_of[i] != col_of[i]) {
          ++offdiag;
          if (got.re != 0 || got.im != 0) {
            report(&errors, "rtl_vs_directed", &counters.rtl_vs_directed,
                   std::string("dot.orth[r") + std::to_string(inst + 1) +
                       "]: rows " + std::to_string(row_of[i]) + " and " +
                       std::to_string(col_of[i]) +
                       " are orthogonal but the beam output is " + cx(got));
          }
        } else {
          ++diag;
          if (got.re == 0) {
            report(&errors, "rtl_vs_directed", &counters.rtl_vs_directed,
                   std::string("dot.orth[r") + std::to_string(inst + 1) +
                       "]: row " + std::to_string(row_of[i]) +
                       " against itself gave zero; the matched beam is empty");
          }
        }
        ++dots_checked;
      }
    }
    if (diag == 0 || offdiag == 0) {
      report(&errors, "coverage", &counters.coverage,
             "the orthogonality pass saw " + std::to_string(diag) +
                 " matched and " + std::to_string(offdiag) +
                 " unmatched pairs; the relation would have passed vacuously");
    }
  }

  // =========================================================================
  // Pass 3 — random 16-antenna dot products, and the saturation case
  //
  // The two adder-tree pipelinings are checked against the model AND against
  // each other, on the same operand stream, in the same run. "ADD_REG_EVERY is a
  // cost parameter and not a numerical one" is therefore a measured fact rather
  // than an argument from associativity.
  // =========================================================================
  {
    std::mt19937_64 rng = seeds.engine("dot.random");
    std::vector<DotOps> ops;
    // Three amplitude regimes so the saturation flags are exercised in both
    // directions rather than hoped for: small (nothing clamps), mid, and
    // full-scale weights against full-scale input (nearly everything clamps).
    for (unsigned i = 0; i < 2400; ++i) {
      DotOps o;
      o.x.resize(kDot16Ant);
      o.w.resize(kDot16Ant);
      const bool big = (i >= 1600);
      const bool mid = (i >= 800) && (i < 1600);
      for (unsigned a = 0; a < kDot16Ant; ++a) {
        if (big) {
          o.x[a] = fxp::Complex{rand_q15(rng, -32768, 32767),
                                rand_q15(rng, -32768, 32767)};
          o.w[a] = fxp::Complex{rand_q15(rng, -32768, 32767),
                                rand_q15(rng, -32768, 32767)};
        } else if (mid) {
          o.x[a] = fxp::Complex{rand_q15(rng, -32768, 32767),
                                rand_q15(rng, -32768, 32767)};
          o.w[a] = fxp::Complex{rand_q15(rng, -4096, 4095),
                                rand_q15(rng, -4096, 4095)};
        } else {
          o.x[a] = fxp::Complex{rand_q15(rng, -32768, 32767),
                                rand_q15(rng, -32768, 32767)};
          o.w[a] = fxp::Complex{rand_q15(rng, -2047, 2047),
                                rand_q15(rng, -2047, 2047)};
        }
      }
      ops.push_back(std::move(o));
    }
    const DotPass p = run_dot(top.get(), ops);
    unsigned dot_flag_union = 0;
    std::size_t sat_beats = 0;
    for (std::size_t i = 0; i < ops.size(); ++i) {
      const bf::DotResult want = bf::dot(ops[i].x, ops[i].w);
      const unsigned want_flags = (want.f_re.packed() << 2) | want.f_im.packed();
      dot_flag_union |= want.f_re.packed() | want.f_im.packed();
      if (want.saturating()) ++sat_beats;

      for (unsigned inst = 0; inst < 2; ++inst) {
        if (i >= p.obs[inst].size()) continue;
        const DotObs& o = p.obs[inst][i];
        if (o.y != want.y) {
          report(&errors, "rtl_vs_model", &counters.rtl_vs_model,
                 std::string("dot.random[r") + std::to_string(inst + 1) +
                     "] beat " + std::to_string(i) + ": RTL " + cx(o.y) +
                     " vs model " + cx(want.y));
        }
        if (o.flags != want_flags) {
          report(&errors, "rtl_vs_model", &counters.rtl_vs_model,
                 std::string("dot.random[r") + std::to_string(inst + 1) +
                     "] beat " + std::to_string(i) + ": RTL flags " +
                     std::to_string(o.flags) + " vs model " +
                     std::to_string(want_flags));
        }
        if (o.ovf != want.saturating()) {
          report(&errors, "rtl_vs_model", &counters.rtl_vs_model,
                 std::string("dot.random[r") + std::to_string(inst + 1) +
                     "] beat " + std::to_string(i) + ": RTL ovf " +
                     std::to_string(o.ovf ? 1 : 0) + " vs model " +
                     std::to_string(want.saturating() ? 1 : 0));
        }
        ++dots_checked;
      }

      // The two pipelinings must agree bit for bit with each other, not just
      // with the model.
      if (i < p.obs[0].size() && i < p.obs[1].size() &&
          p.obs[0][i].y != p.obs[1][i].y) {
        report(&errors, "rtl_vs_model", &counters.rtl_vs_model,
               "dot.random beat " + std::to_string(i) +
                   ": ADD_REG_EVERY=1 gave " + cx(p.obs[0][i].y) +
                   " and ADD_REG_EVERY=2 gave " + cx(p.obs[1][i].y));
      }

      // The exact accumulator port, which issue #13's power engine will consume.
      if (i < p.obs[0].size()) {
        if (p.obs[0][i].acc_re != static_cast<std::int64_t>(want.acc_re) ||
            p.obs[0][i].acc_im != static_cast<std::int64_t>(want.acc_im)) {
          report(&errors, "rtl_vs_model", &counters.rtl_vs_model,
                 "dot.random beat " + std::to_string(i) +
                     ": exact accumulator RTL (" +
                     std::to_string(p.obs[0][i].acc_re) + "," +
                     std::to_string(p.obs[0][i].acc_im) + ") vs model (" +
                     std::to_string(static_cast<long long>(want.acc_re)) + "," +
                     std::to_string(static_cast<long long>(want.acc_im)) + ")");
        }
      }

      // The independent double-precision leg, where nothing clamped.
      if (!want.saturating() && i < p.obs[0].size()) {
        const bf::DotFloat f =
            bf::dot_float(ops[i].x.data(), ops[i].w.data(), kDot16Ant);
        const double dre = static_cast<double>(p.obs[0][i].y.re) - f.re;
        const double dim = static_cast<double>(p.obs[0][i].y.im) - f.im;
        if (dre > kFloatBudgetLsb || dre < -kFloatBudgetLsb ||
            dim > kFloatBudgetLsb || dim < -kFloatBudgetLsb) {
          report(&errors, "rtl_vs_float", &counters.rtl_vs_float,
                 "dot.random beat " + std::to_string(i) + ": RTL " +
                     cx(p.obs[0][i].y) + " is more than " +
                     std::to_string(kFloatBudgetLsb) +
                     " LSB from the double-precision sum (" +
                     std::to_string(f.re) + "," + std::to_string(f.im) + ")");
        }
      }
    }
    flag_union |= dot_flag_union;
    if (sat_beats == 0) {
      report(&errors, "coverage", &counters.coverage,
             "the dot-product random pass saw no saturating beat; the flag "
             "checks would have passed vacuously");
    }
  }

  // =========================================================================
  // Pass 4 — the matrix under unit weights: each beam IS one antenna
  //
  // Beam b selects antenna (b+1) mod N_ANT. The expected output beat can be
  // written down from the stimulus alone — beam b, bin j is antenna (b+1) of
  // bin j scaled by 0x7FFF — so this is the case to read first when the general
  // comparison disagrees.
  //
  // (b+1) RATHER THAN b, AND THE REASON IS A MEASUREMENT RATHER THAN A HUNCH.
  // The obvious choice — beam b selects antenna b — makes W the IDENTITY, which
  // is symmetric and therefore unchanged by a transpose. A transposed weight
  // index is the most likely defect in a beamformer, and the injected-fault
  // experiment for this issue (a transposed index in
  // rtl/beamformer/beamformer.sv) showed this pass reporting ZERO failures while
  // 38 400 model comparisons failed around it. A cyclic shift is asymmetric for
  // every N_ANT > 2, so this pass now fails on a transpose as well, and it fails
  // naming the beam and the antenna. The same trap applies to the Hadamard pass
  // above and is recorded there.
  // =========================================================================
  {
    std::vector<unsigned> sel(kNBeams);
    for (unsigned b = 0; b < kNBeams; ++b) sel[b] = (b + 1u) % kNAnt;
    const std::vector<fxp::Complex> w = bf::unit_weights(kNAnt, kNBeams, sel);

    const unsigned spare = active_bank ^ 1u;
    if (!program_bank(top.get(), spare, w)) {
      report(&errors, "config", &counters.config,
             "unit: the weight crossing never accepted a write");
    }
    if (!request_swap(top.get())) {
      report(&errors, "config", &counters.config,
             "unit: the swap request never reached the core domain");
    }

    std::mt19937_64 rng = seeds.engine("matrix.unit");
    std::vector<InBeat> beats;
    for (unsigned i = 0; i < 128; ++i) {
      InBeat b;
      b.x = rand_beat(rng, -32768, 32767);
      b.seq = g_seq++;
      beats.push_back(std::move(b));
    }
    tag_metadata(&beats, 0, beats.size() - 1);

    const PassResult pr =
        run_pass(top.get(), beats, BackpressureConfig::none(),
                 BackpressureConfig::none(), seeds, "matrix.unit", {});
    active_bank = spare;

    if (pr.timed_out) {
      report(&errors, "alignment", &counters.alignment,
             "unit: pass timed out with outputs outstanding");
    }

    for (unsigned dut = 0; dut < kNDut; ++dut) {
      const ExpMap expect = expect_for(beats, w, 0, w, dut);
      const CheckStats st =
          check_outputs(std::string("unit.") + kDutName[dut], dut, pr.out[dut],
                        expect, &errors, &counters);
      flag_union |= st.flag_union;
      beats_checked += st.checked;
      frames_checked += st.frames;
    }

    // The model-free half: every observed slot must be the passthrough of the
    // antenna its beam selects.
    std::map<std::uint16_t, std::size_t> in_of_seq;
    for (std::size_t i = 0; i < beats.size(); ++i) in_of_seq[beats[i].seq] = i;
    std::size_t direct_checked = 0;
    for (const OutBeat& o : pr.out[0]) {
      const auto it = in_of_seq.find(o.seq);
      if (it == in_of_seq.end()) continue;
      const InBeat& in = beats[it->second];
      for (unsigned k = 0; k < kBeamPar[0]; ++k) {
        for (unsigned j = 0; j < kBinPar; ++j) {
          const fxp::Complex want = bf::unit_weight_expect(in.x[j][sel[k]]);
          const fxp::Complex got = o.y[k * kBinPar + j];
          if (got != want) {
            report(&errors, "rtl_vs_directed", &counters.rtl_vs_directed,
                   "unit seq " + std::to_string(o.seq) + " beam " +
                       std::to_string(k) + " bin " + std::to_string(j) +
                       ": RTL " + cx(got) + " but beam " + std::to_string(k) +
                       " selects antenna " + std::to_string(sel[k]) +
                       " whose passthrough is " + cx(want));
          }
          ++direct_checked;
        }
      }
    }
    if (direct_checked == 0) {
      report(&errors, "coverage", &counters.coverage,
             "the unit-weight pass checked no slot directly");
    }
  }

  // =========================================================================
  // Pass 5 — random beats under three backpressure profiles
  //
  // The same beats, the same expectations, three different stall patterns. The
  // scoreboard is by sequence number, so "content is invariant under
  // backpressure" is checked rather than asserted: a beam whose value depended
  // on when it was drained would fail against the model it was compared to in
  // the un-stalled run.
  // =========================================================================
  {
    // Weights small enough that most beats do not clamp — saturation has its own
    // pass — but large enough that every antenna contributes.
    std::mt19937_64 wrng = seeds.engine("matrix.random.weights");
    std::vector<fxp::Complex> w(kNWeight);
    for (unsigned i = 0; i < kNWeight; ++i) {
      w[i] = fxp::Complex{rand_q15(wrng, -6000, 6000),
                          rand_q15(wrng, -6000, 6000)};
    }
    const unsigned spare = active_bank ^ 1u;
    program_bank(top.get(), spare, w);
    request_swap(top.get());

    struct Profile { const char* name; BackpressureConfig gap, bp; };
    const Profile profiles[] = {
        {"dense", BackpressureConfig::none(), BackpressureConfig::none()},
        {"light", BackpressureConfig::light(), BackpressureConfig::light()},
        {"heavy", BackpressureConfig::bursty(), BackpressureConfig::heavy()},
    };

    // ONE stimulus, driven three times. The sequence numbers differ between runs
    // — they are globally monotonic so the SPEC 5 protocol checker stays happy —
    // but the DATA is identical, which is what turns "adding legal backpressure
    // does not change transaction content" (SPEC 13.2) into a direct comparison
    // rather than two independent comparisons against the model.
    std::mt19937_64 xrng = seeds.engine("matrix.random.data");
    std::vector<std::vector<std::vector<fxp::Complex>>> base_x;
    for (unsigned i = 0; i < 192; ++i) base_x.push_back(rand_beat(xrng, -32768, 32767));

    bool first_profile = true;
    // DUT 0's output content under the dense profile, by beat position, so the
    // stalled runs can be required to be IDENTICAL rather than merely both
    // correct.
    std::vector<std::vector<fxp::Complex>> dense_ref;

    for (const Profile& prof : profiles) {
      std::vector<InBeat> beats;
      for (const auto& x : base_x) {
        InBeat b;
        b.x = x;
        b.seq = g_seq++;
        beats.push_back(std::move(b));
      }
      // Six frames of 32 beats, so backpressure has to survive frame
      // boundaries as well as beats (SPEC 5).
      for (unsigned f = 0; f < 6; ++f) {
        tag_metadata(&beats, f * 32, f * 32 + 31);
      }

      const PassResult pr =
          run_pass(top.get(), beats, prof.gap, prof.bp, seeds,
                   std::string("matrix.random.") + prof.name, {});
      if (first_profile) {
        active_bank = spare;
        first_profile = false;
      }
      if (pr.timed_out) {
        report(&errors, "alignment", &counters.alignment,
               std::string("random/") + prof.name +
                   ": pass timed out with outputs outstanding");
      }
      for (unsigned dut = 0; dut < kNDut; ++dut) {
        const ExpMap expect = expect_for(beats, w, 0, w, dut);
        const CheckStats st = check_outputs(
            std::string("random[") + prof.name + "]." + kDutName[dut], dut,
            pr.out[dut], expect, &errors, &counters);
        flag_union |= st.flag_union;
        beats_checked += st.checked;
        frames_checked += st.frames;
      }

      // Cross-DUT equivalence: DUT 1's two output beats per input beat must
      // together carry the same four beams DUT 0 emits in one, and DUT 2 must
      // equal DUT 0 outright. This is the same-run fact the top exists to make.
      std::map<std::uint16_t, const OutBeat*> by_seq0, by_seq2;
      for (const OutBeat& o : pr.out[0]) by_seq0[o.seq] = &o;
      for (const OutBeat& o : pr.out[2]) by_seq2[o.seq] = &o;
      for (const OutBeat& o : pr.out[1]) {
        // seq_out = (seq_in << 1) | group for BEAM_MUX = 2.
        const std::uint16_t in_seq = static_cast<std::uint16_t>(o.seq >> 1);
        const unsigned grp = o.seq & 1u;
        const auto it = by_seq0.find(in_seq);
        if (it == by_seq0.end()) continue;
        for (unsigned k = 0; k < kBeamPar[1]; ++k) {
          for (unsigned j = 0; j < kBinPar; ++j) {
            const fxp::Complex mux_y = o.y[k * kBinPar + j];
            const fxp::Complex ref_y =
                it->second->y[(grp * kBeamPar[1] + k) * kBinPar + j];
            if (mux_y != ref_y) {
              report(&errors, "metamorphic", &counters.metamorphic,
                     std::string("random[") + prof.name + "]: multiplexed beam " +
                         std::to_string(grp * kBeamPar[1] + k) + " bin " +
                         std::to_string(j) + " of input seq " +
                         std::to_string(in_seq) + " is " + cx(mux_y) +
                         " but the reference engine produced " + cx(ref_y));
            }
          }
        }
      }
      for (const OutBeat& o : pr.out[0]) {
        const auto it = by_seq2.find(o.seq);
        if (it == by_seq2.end()) continue;
        if (o.y != it->second->y) {
          report(&errors, "metamorphic", &counters.metamorphic,
                 std::string("random[") + prof.name + "]: ADD_REG_EVERY=2 seq " +
                     std::to_string(o.seq) +
                     " differs from ADD_REG_EVERY=1 on the same beat");
        }
      }

      // Content invariance under backpressure (SPEC 13.2), as a DIRECT
      // comparison against the dense run. DUT 0 is a pipeline, not a reorder
      // buffer, so its output beats arrive in input order and position i of the
      // output list is input beat i in every profile.
      std::vector<std::vector<fxp::Complex>> here(pr.out[0].size());
      for (std::size_t i = 0; i < pr.out[0].size(); ++i) here[i] = pr.out[0][i].y;
      if (dense_ref.empty()) {
        dense_ref = here;
      } else {
        if (here.size() != dense_ref.size()) {
          report(&errors, "metamorphic", &counters.metamorphic,
                 std::string("backpressure[") + prof.name + "]: " +
                     std::to_string(here.size()) +
                     " output beats against the dense run's " +
                     std::to_string(dense_ref.size()) +
                     "; stalling changed the transaction count");
        }
        const std::size_t n = std::min(here.size(), dense_ref.size());
        for (std::size_t i = 0; i < n; ++i) {
          if (here[i] != dense_ref[i]) {
            report(&errors, "metamorphic", &counters.metamorphic,
                   std::string("backpressure[") + prof.name + "]: beat " +
                       std::to_string(i) +
                       " differs from the dense run on identical stimulus; "
                       "content is not invariant under backpressure");
            break;   // one report per profile: the shape is the diagnosis
          }
        }
      }

      const std::size_t produced = pr.out[0].size();
      if (produced != beats.size()) {
        report(&errors, "alignment", &counters.alignment,
               std::string("random[") + prof.name + "]: " +
                   std::to_string(produced) + " output beats for " +
                   std::to_string(beats.size()) + " input beats");
      }
      if (pr.out[1].size() != beats.size() * bf::beam_mux(kNBeams, kBeamPar[1])) {
        report(&errors, "throughput", &counters.throughput,
               std::string("random[") + prof.name + "]: the multiplexed engine "
               "produced " + std::to_string(pr.out[1].size()) +
                   " output beats for " + std::to_string(beats.size()) +
                   " input beats; " +
                   std::to_string(beats.size() *
                                  bf::beam_mux(kNBeams, kBeamPar[1])) +
                   " were expected");
      }
    }
  }

  // =========================================================================
  // Pass 6 — weight-bank swap at a frame boundary, requested MID-FRAME
  //
  // Frame A under weight set A, frame B under weight set B. The swap is
  // requested in the middle of frame A and must take effect on frame B's first
  // beat, not before. Writes to the SPARE bank are interleaved with frame A and
  // must not move a single output bit — the inactive-bank-write-has-no-effect
  // property, checked here on the data and continuously by
  // a_coeff_stable_between inside the store.
  //
  // THE PREDICTED TRANSITION BEHAVIOUR IS "NONE", and that is a claim rather
  // than an absence. A beamformer has no sample history, so every dot product of
  // a beat reads the weight bank on the same cycle: the swap is atomic at the
  // beat that carries it and there is no transition window at all. Contrast the
  // polyphase bank's systolic cascade, whose taps sample the coefficient set up
  // to TAPS-1 beats apart and which therefore HAS a predicted mixed window
  // (model/cpp/pfb/pfb_model.hpp, per_tap_skew). The expectation below is built
  // with a hard switch at the swap beat, so if the RTL had a transition window
  // this pass would fail on every beat of it.
  // =========================================================================
  {
    std::mt19937_64 wrng = seeds.engine("matrix.swap.weights");
    std::vector<fxp::Complex> wa(kNWeight), wb(kNWeight);
    for (unsigned i = 0; i < kNWeight; ++i) {
      wa[i] = fxp::Complex{rand_q15(wrng, -6000, 6000),
                           rand_q15(wrng, -6000, 6000)};
      wb[i] = fxp::Complex{rand_q15(wrng, -6000, 6000),
                           rand_q15(wrng, -6000, 6000)};
    }

    const unsigned bank_a = active_bank ^ 1u;
    program_bank(top.get(), bank_a, wa);
    request_swap(top.get());

    // Long frames on purpose. The whole of set B is written into the spare bank
    // WHILE frame A streams, and one weight write is a four-phase clock-domain
    // crossing — about eight cycles each, sixteen of them. A short frame A would
    // leave the reprogramming unfinished when frame B opened, and the pass would
    // be testing nothing but its own impatience.
    constexpr unsigned kFrame = 192;
    std::mt19937_64 rng = seeds.engine("matrix.swap.data");
    std::vector<InBeat> beats;
    for (unsigned i = 0; i < 2 * kFrame; ++i) {
      InBeat b;
      b.x = rand_beat(rng, -20000, 20000);
      b.seq = g_seq++;
      beats.push_back(std::move(b));
    }
    tag_metadata(&beats, 0, kFrame - 1);
    tag_metadata(&beats, kFrame, 2 * kFrame - 1);

    const std::size_t swap_beat = kFrame;

    std::vector<CfgAction> actions;
    const unsigned bank_b = bank_a ^ 1u;
    for (unsigned i = 0; i < kNWeight; ++i) {
      CfgAction wr;
      wr.at_beat = 8 + i * 6;
      wr.write = true;
      wr.bank = bank_b;
      wr.addr = i;
      wr.value = wb[i];
      actions.push_back(wr);
    }
    // The swap request, still mid-frame: it must be REMEMBERED and applied at
    // the next start of frame, which is the property under test.
    CfgAction sw;
    sw.at_beat = kFrame - 16;
    sw.swap = true;
    actions.push_back(sw);

    const PassResult pr =
        run_pass(top.get(), beats, BackpressureConfig::light(),
                 BackpressureConfig::light(), seeds, "matrix.swap", actions);
    active_bank = bank_b;

    if (pr.timed_out) {
      report(&errors, "alignment", &counters.alignment,
             "swap: pass timed out with outputs outstanding");
    }
    for (unsigned dut = 0; dut < kNDut; ++dut) {
      const ExpMap expect = expect_for(beats, wa, swap_beat, wb, dut);
      const CheckStats st =
          check_outputs(std::string("swap.") + kDutName[dut], dut, pr.out[dut],
                        expect, &errors, &counters);
      flag_union |= st.flag_union;
      beats_checked += st.checked;
      frames_checked += st.frames;
    }

    settle(top.get());
    if (top->cfg_wr_reject != 0) {
      report(&errors, "config", &counters.config,
             "swap: the weight bank rejected a write; every write in this pass "
             "targeted the spare bank");
    }
    if (top->cfg_active_bank != bank_b) {
      report(&errors, "config", &counters.config,
             "swap: the active bank is " +
                 std::to_string(top->cfg_active_bank) + " but frame B was "
                 "streamed expecting bank " + std::to_string(bank_b) +
                 "; the mid-frame swap request never took effect");
    }
    if (top->cfg_swap_pending != 0) {
      report(&errors, "config", &counters.config,
             "swap: a swap is still pending after the pass; it was requested "
             "mid-frame and two start-of-frame beats have gone by");
    }
  }

  // =========================================================================
  // Pass 7 — metamorphic relations (SPEC 13.2)
  //
  // THE PERMUTATION RELATION IS THE ONE SPEC 13.2 NAMES FOR THIS BLOCK:
  // "Permuting antenna inputs and weights consistently produces equivalent beam
  // outputs." It is checked here as BIT-IDENTICAL rather than approximate,
  // because the accumulation carries no intermediate saturation and integer
  // addition is commutative — so "equivalent" is stronger than SPEC 13.2 asks
  // for, and stating it weakly would let a real defect through.
  //
  // It is also the strongest available check on the weight INDEX. A transposed
  // or rotated weight index still produces beams, still saturates plausibly and
  // still passes every protocol check; what it cannot do is commute with a
  // permutation applied to both operands.
  // =========================================================================
  {
    std::mt19937_64 wrng = seeds.engine("metamorphic.weights");
    std::vector<fxp::Complex> w(kNWeight);
    for (unsigned i = 0; i < kNWeight; ++i) {
      w[i] = fxp::Complex{rand_q15(wrng, -5000, 5000),
                          rand_q15(wrng, -5000, 5000)};
    }

    // A non-trivial permutation of the antenna axis. Fixed rather than random so
    // a failure is reproducible from the message alone; a rotation by one is the
    // permutation a transposed or off-by-one index is least able to survive.
    std::vector<unsigned> perm(kNAnt);
    for (unsigned a = 0; a < kNAnt; ++a) perm[a] = (a + 1u) % kNAnt;
    const std::vector<fxp::Complex> wp =
        bf::permute_weights(w, kNAnt, kNBeams, perm);

    // Base stimulus, deliberately at half scale so that DOUBLING it is still a
    // legal Q1.15 input and the weights above cannot saturate on either.
    std::mt19937_64 rng = seeds.engine("metamorphic.base");
    std::vector<std::vector<std::vector<fxp::Complex>>> base;
    for (unsigned i = 0; i < 128; ++i) base.push_back(rand_beat(rng, -8191, 8191));

    enum Variant { kBase = 0, kPermuted, kNegated, kScaled, kDelayed, kNVariant };
    const char* const vname[kNVariant] = {"base", "permuted", "negated",
                                          "scaled", "delayed"};
    constexpr unsigned kDelay = 5;

    std::vector<std::vector<fxp::Complex>> got[kNVariant];

    for (unsigned v = 0; v < kNVariant; ++v) {
      const std::vector<fxp::Complex>& wv = (v == kPermuted) ? wp : w;
      const unsigned spare = active_bank ^ 1u;
      program_bank(top.get(), spare, wv);
      request_swap(top.get());
      active_bank = spare;

      std::vector<InBeat> beats;
      if (v == kDelayed) {
        // D extra zero beats in front: the response must be the same sequence,
        // D beats later.
        for (unsigned i = 0; i < kDelay; ++i) {
          InBeat z;
          z.x.assign(kBinPar, std::vector<fxp::Complex>(kNAnt, fxp::Complex{}));
          z.seq = g_seq++;
          beats.push_back(std::move(z));
        }
      }
      for (const auto& src : base) {
        InBeat b;
        b.x.assign(kBinPar, std::vector<fxp::Complex>(kNAnt));
        for (unsigned j = 0; j < kBinPar; ++j) {
          for (unsigned a = 0; a < kNAnt; ++a) {
            if (v == kPermuted) {
              // The SAME permutation applied to the antenna axis of the input.
              b.x[j][perm[a]] = src[j][a];
            } else if (v == kNegated) {
              b.x[j][a] = fxp::Complex{static_cast<fxp::i16>(-src[j][a].re),
                                       static_cast<fxp::i16>(-src[j][a].im)};
            } else if (v == kScaled) {
              b.x[j][a] = fxp::Complex{static_cast<fxp::i16>(src[j][a].re * 2),
                                       static_cast<fxp::i16>(src[j][a].im * 2)};
            } else {
              b.x[j][a] = src[j][a];
            }
          }
        }
        b.seq = g_seq++;
        beats.push_back(std::move(b));
      }
      tag_metadata(&beats, 0, beats.size() - 1);

      const PassResult pr =
          run_pass(top.get(), beats, BackpressureConfig::none(),
                   BackpressureConfig::none(), seeds,
                   std::string("metamorphic.") + vname[v], {});
      for (unsigned dut = 0; dut < kNDut; ++dut) {
        const ExpMap expect = expect_for(beats, wv, 0, wv, dut);
        const CheckStats st = check_outputs(
            std::string("metamorphic[") + vname[v] + "]." + kDutName[dut], dut,
            pr.out[dut], expect, &errors, &counters);
        flag_union |= st.flag_union;
        beats_checked += st.checked;
        frames_checked += st.frames;
      }

      // Collect DUT 0's response, indexed by the position of the corresponding
      // BASE beat, so the five runs are directly comparable.
      got[v].assign(base.size(), std::vector<fxp::Complex>());
      const std::size_t offset = (v == kDelayed) ? kDelay : 0;
      std::map<std::uint16_t, std::size_t> idx_of_seq;
      for (std::size_t i = offset; i < beats.size(); ++i) {
        idx_of_seq[beats[i].seq] = i - offset;
      }
      for (const OutBeat& o : pr.out[0]) {
        const auto it = idx_of_seq.find(o.seq);
        if (it != idx_of_seq.end() && it->second < base.size()) {
          got[v][it->second] = o.y;
        }
      }
    }

    // --- the relations ------------------------------------------------------
    std::size_t compared = 0;
    std::size_t perm_compared = 0;
    for (std::size_t i = 0; i < base.size(); ++i) {
      if (got[kBase][i].empty()) continue;
      for (std::size_t s = 0; s < got[kBase][i].size(); ++s) {
        const fxp::Complex y = got[kBase][i][s];

        // PERMUTATION (SPEC 13.2). Bit-identical, not approximate.
        if (!got[kPermuted][i].empty()) {
          const fxp::Complex p = got[kPermuted][i][s];
          if (p != y) {
            report(&errors, "metamorphic", &counters.metamorphic,
                   "permutation beat " + std::to_string(i) + " slot " +
                       std::to_string(s) +
                       ": permuting the antenna inputs and the antenna axis of "
                       "the weights consistently gave " + cx(p) +
                       " where the unpermuted run gave " + cx(y));
          }
          ++perm_compared;
        }

        // Negation: exact, because round-to-nearest-even is symmetric about
        // zero. The one exception is -32768, whose negation is not
        // representable and saturates; the base stimulus is half scale under
        // small weights, so it cannot occur, and if it does the run should fail
        // rather than quietly skip it.
        if (!got[kNegated][i].empty()) {
          const fxp::Complex n = got[kNegated][i][s];
          if (n.re != -y.re || n.im != -y.im) {
            report(&errors, "metamorphic", &counters.metamorphic,
                   "negation beat " + std::to_string(i) + " slot " +
                       std::to_string(s) + ": y(-x)=" + cx(n) + " but -y(x)=(" +
                       std::to_string(-y.re) + "," + std::to_string(-y.im) +
                       ")");
          }
        }

        // Scaling: doubling the input doubles the exact accumulator, so the
        // output doubles to within the one LSB rounding may move it.
        if (!got[kScaled][i].empty()) {
          const fxp::Complex sc = got[kScaled][i][s];
          const long dre = static_cast<long>(sc.re) - 2L * y.re;
          const long dim = static_cast<long>(sc.im) - 2L * y.im;
          if (dre < -1 || dre > 1 || dim < -1 || dim > 1) {
            report(&errors, "metamorphic", &counters.metamorphic,
                   "scaling beat " + std::to_string(i) + " slot " +
                       std::to_string(s) + ": y(2x)=" + cx(sc) +
                       " is not 2*y(x)=(" + std::to_string(2 * y.re) + "," +
                       std::to_string(2 * y.im) + ") to within 1 LSB");
          }
        }

        // Delay: a delayed input produces the identical sequence, delayed.
        if (!got[kDelayed][i].empty()) {
          const fxp::Complex t = got[kDelayed][i][s];
          if (t != y) {
            report(&errors, "metamorphic", &counters.metamorphic,
                   "delay beat " + std::to_string(i) + " slot " +
                       std::to_string(s) + ": delayed run gave " + cx(t) +
                       " where the base run gave " + cx(y));
          }
        }
        ++compared;
      }
    }
    if (compared < base.size() || perm_compared < base.size()) {
      report(&errors, "coverage", &counters.coverage,
             "the metamorphic pass compared only " + std::to_string(compared) +
                 " slots (" + std::to_string(perm_compared) +
                 " under permutation); the relations would have passed "
                 "vacuously");
    }
  }

  // =========================================================================
  // Pass 8 — saturation and telemetry (SPEC 9 counters, SPEC 7.5 reporting)
  // =========================================================================
  {
    const std::vector<fxp::Complex> w = bf::max_weights(kNAnt, kNBeams);
    const unsigned spare = active_bank ^ 1u;
    program_bank(top.get(), spare, w);
    request_swap(top.get());
    active_bank = spare;

    // The swap takes effect on the first beat of the measured pass, and a
    // beamformer has no history, so unlike the polyphase bank there is no
    // residual to flush: the very first beat of this pass is already computed
    // with the new weights from a state the model shares. The counters are
    // cleared here and everything counted after this point is predictable.
    top->telem_clear = 1;
    tick(top.get());
    top->telem_clear = 0;
    tick(top.get());

    std::mt19937_64 rng = seeds.engine("matrix.telemetry");
    std::vector<InBeat> beats;
    for (unsigned i = 0; i < 129; ++i) {
      InBeat b;
      // Full scale against full-scale weights: nearly every beat clamps, and
      // the sign of the clamp varies, so both directions are observed.
      b.x = rand_beat(rng, -32768, 32767);
      b.seq = g_seq++;
      beats.push_back(std::move(b));
    }
    constexpr unsigned kFrames = 3;
    const unsigned per = static_cast<unsigned>(beats.size()) / kFrames;
    for (unsigned f = 0; f < kFrames; ++f) {
      tag_metadata(&beats, f * per,
                   (f == kFrames - 1) ? (beats.size() - 1)
                                      : ((f + 1) * per - 1));
    }

    const PassResult pr =
        run_pass(top.get(), beats, BackpressureConfig::none(),
                 BackpressureConfig::none(), seeds, "matrix.telemetry", {});

    const ExpMap expect0 = expect_for(beats, w, 0, w, 0);
    std::size_t model_sat_beats = 0;
    std::size_t model_frames = 0;
    for (const auto& kv : expect0) {
      if (kv.second.saturating) ++model_sat_beats;
      if (kv.second.eof) ++model_frames;
    }

    for (unsigned dut = 0; dut < kNDut; ++dut) {
      const ExpMap expect = expect_for(beats, w, 0, w, dut);
      const CheckStats st =
          check_outputs(std::string("telemetry.") + kDutName[dut], dut,
                        pr.out[dut], expect, &errors, &counters);
      flag_union |= st.flag_union;
      beats_checked += st.checked;
      frames_checked += st.frames;
    }

    top->telem_snapshot = 1;
    tick(top.get());
    top->telem_snapshot = 0;
    tick(top.get());
    settle(top.get());

    const std::uint32_t sat_count = top->sat_event_count;
    const std::uint32_t sat_snap = top->sat_event_snap;
    const std::uint32_t frames = top->frame_count;
    const unsigned sticky = top->sat_sticky;

    if (sat_count != model_sat_beats) {
      report(&errors, "telemetry", &counters.telemetry,
             "saturation event count: RTL " + std::to_string(sat_count) +
                 " vs model tally " + std::to_string(model_sat_beats));
    }
    if (sat_snap != sat_count) {
      report(&errors, "telemetry", &counters.telemetry,
             "saturation snapshot " + std::to_string(sat_snap) +
                 " does not match the live count " + std::to_string(sat_count));
    }
    if (frames != model_frames) {
      report(&errors, "telemetry", &counters.telemetry,
             "frame count: RTL " + std::to_string(frames) + " vs tally " +
                 std::to_string(model_frames));
    }
    if (model_sat_beats == 0) {
      report(&errors, "coverage", &counters.coverage,
             "the telemetry pass saw no saturating beat; the counter check "
             "would have passed vacuously");
    }
    if (model_sat_beats > 0 && (top->sat_any == 0 || sticky == 0)) {
      report(&errors, "telemetry", &counters.telemetry,
             "the sticky saturation flags are clear after " +
                 std::to_string(model_sat_beats) + " saturating beats");
    }
    flag_union |= sticky;
  }

  // ---- coverage audit ------------------------------------------------------
  // Both saturation directions must have been observed. A saturation test that
  // never saturates passes vacuously.
  if ((flag_union & 2u) == 0 || (flag_union & 1u) == 0) {
    report(&errors, "coverage", &counters.coverage,
           std::string("the run never observed both saturation directions (") +
               flags_str(flag_union) + "); the flag checks would have passed "
               "vacuously");
  }
  if (frames_checked < 8) {
    report(&errors, "coverage", &counters.coverage,
           "only " + std::to_string(frames_checked) +
               " end-of-frame beats were checked");
  }

  // =========================================================================
  // Pass 9 — the negative test. LAST: it clears fatalOnError for the whole
  // build, so nothing may run after it.
  // =========================================================================
  std::size_t assertion_fires = 0;
  std::string assertion_evidence;
  {
    idle_inputs(top.get());
    for (int i = 0; i < 8; ++i) tick(top.get());

    Verilated::fatalOnError(false);
    Capture cap;
    cap.begin();

    // A swap request to the ALLOW_UNSAFE_SWAP weight bank, with no beat and no
    // start-of-frame anywhere near it. The bank in use must not change, and
    // a_coeff_swap_at_sof must say so.
    top->unsafe_swap_req = 1;
    tick(top.get());
    top->unsafe_swap_req = 0;
    for (int i = 0; i < 32; ++i) tick(top.get());

    cap.end();
    assertion_evidence = cap.text;
    const bool fired = Verilated::gotError();
    const bool named =
        cap.text.find("a_coeff_swap_at_sof") != std::string::npos;
    if (!fired || !named) {
      report(&errors, "assertion", &counters.assertion,
             std::string("the illegal mid-frame swap did not provoke "
                         "a_coeff_swap_at_sof (fired=") +
                 (fired ? "yes" : "no") + " named=" + (named ? "yes" : "no") +
                 "); the weight-bank frame-boundary assertion is not "
                 "load-bearing");
    } else {
      ++assertion_fires;
    }
  }

  const bool passed = counters.total() == 0;

  std::printf("--- beamforming matrix ---\n");
  std::printf("  geometry         : %u antennas x %u beams x %u bins/beat, "
              "mult_pipe %u, acc_w %u\n",
              kNAnt, kNBeams, kBinPar, kMultPipe, bf::acc_w(kNAnt));
  std::printf("  matrices         : ref (BEAM_PAR=%u mux=%u lat=%u), "
              "mux2 (BEAM_PAR=%u mux=%u), reg2 (ADD_REG_EVERY=2 lat=%u)\n",
              kBeamPar[0], bf::beam_mux(kNBeams, kBeamPar[0]),
              bf::lat_cycles(kNAnt, kMultPipe, kRegEvery[0]), kBeamPar[1],
              bf::beam_mux(kNBeams, kBeamPar[1]),
              bf::lat_cycles(kNAnt, kMultPipe, kRegEvery[2]));
  std::printf("  dot products     : %u antennas, ADD_REG_EVERY 1 (lat %u) and "
              "2 (lat %u)\n",
              kDot16Ant, bf::dot_lat(kDot16Ant, kMultPipe, 1),
              bf::dot_lat(kDot16Ant, kMultPipe, 2));
  std::printf("  reported tput    : %u ant, %u beams, %u bins/beat, "
              "%u beam-bins/cycle (ref) / %u (mux2)\n",
              top->tput_n_ant, top->tput_n_beams, top->tput_bin_par0,
              top->tput_bb0, top->tput_bb1);
  std::printf("  dot results      : %zu checked\n", dots_checked);
  std::printf("  output beats     : %zu checked against the C++ model\n",
              beats_checked);
  std::printf("  frames           : %zu end-of-frame beats checked\n",
              frames_checked);
  std::printf("  saturation seen  : %s\n", flags_str(flag_union).c_str());
  std::printf("  swap assertion   : %zu expected fire(s)\n", assertion_fires);
  std::printf("  RTL vs model     : %zu\n", counters.rtl_vs_model);
  std::printf("  RTL vs float     : %zu\n", counters.rtl_vs_float);
  std::printf("  RTL vs directed  : %zu\n", counters.rtl_vs_directed);
  std::printf("  metadata         : %zu\n", counters.metadata);
  std::printf("  alignment        : %zu\n", counters.alignment);
  std::printf("  metamorphic      : %zu\n", counters.metamorphic);
  std::printf("  telemetry        : %zu\n", counters.telemetry);
  std::printf("  throughput       : %zu\n", counters.throughput);
  std::printf("  coverage         : %zu\n", counters.coverage);
  std::printf("  assertion        : %zu\n", counters.assertion);
  if (!assertion_evidence.empty()) {
    const std::size_t nl = assertion_evidence.find('\n');
    std::printf("  expected failure : %s\n",
                assertion_evidence
                    .substr(0, nl == std::string::npos
                                   ? assertion_evidence.size()
                                   : nl)
                    .c_str());
  }

  const auto wall_end = std::chrono::steady_clock::now();
  RunSummary summary;
  summary.test_name = kTestName;
  summary.config_name = sim_config::kName;
  summary.build_mode = args.build_mode;
  summary.seed = args.seed;
  summary.passed = passed;
  summary.stop_reason = passed ? "pass" : "error";
  summary.stop_detail =
      passed ? "three engines and two dot-product pipelinings bit-exact against "
               "the C++ model, the directed expectations and each other"
             : "beamformer mismatch; see errors_by_category";
  summary.passes = 10;
  summary.beats_observed = beats_checked;
  summary.absorb(errors);
  summary.wall_time_s =
      std::chrono::duration<double>(wall_end - wall_start).count();
  const std::string written = summary.write(args.results_dir);
  if (!written.empty()) std::printf("  summary json     : %s\n", written.c_str());

  if (passed) {
    std::printf("RESULT: PASS seed=%llu test=%s config=%s beats=%zu dots=%zu\n",
                static_cast<unsigned long long>(args.seed), kTestName,
                sim_config::kName, beats_checked, dots_checked);
    return 0;
  }
  std::printf("RESULT: FAIL seed=%llu test=%s config=%s rtl_vs_model=%zu "
              "rtl_vs_float=%zu rtl_vs_directed=%zu metadata=%zu alignment=%zu "
              "metamorphic=%zu telemetry=%zu throughput=%zu coverage=%zu "
              "assertion=%zu config=%zu\n",
              static_cast<unsigned long long>(args.seed), kTestName,
              sim_config::kName, counters.rtl_vs_model, counters.rtl_vs_float,
              counters.rtl_vs_directed, counters.metadata, counters.alignment,
              counters.metamorphic, counters.telemetry, counters.throughput,
              counters.coverage, counters.assertion, counters.config);
  return 1;
}
