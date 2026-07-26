// -----------------------------------------------------------------------------
// test_pfb_bank.cpp — polyphase FIR bank verification (issue #10; SPEC 6, 7.1,
// 13.1, 13.2, 14).
//
// Drives sim/verilator/tops/pfb_top.sv, which holds TWO complete polyphase banks
// differing only in accumulation structure (TREE and SYSTOLIC) and admitting
// exactly the same beats. Every output beat of both is checked against:
//
//   * the bit-accurate C++ model (model/cpp/pfb/pfb_model.hpp), on every beat,
//   * the independent NumPy expectation committed in model/vectors/pfb_*.vec,
//     on the directed pass,
//
// and the two banks are checked against each other by construction — they
// scoreboard against the same expectation list, so "the adder tree and the
// cascade compute the same integer" is a same-run fact.
//
// THE SPEC 7.1 VERIFICATION LIST, AND WHERE EACH CASE LIVES
// ---------------------------------------------------------
//   zero input .................. directed pass (every set opens with zeros) and
//                                 the per-pass prologue
//   complex impulse ............. directed pass; with the `ident` set the output
//                                 IS the input, and with `proto` the output is
//                                 the programmed response tap by tap — the only
//                                 stimulus that checks coefficient ORDER
//   constant input .............. directed pass
//   single complex sinusoid ..... directed pass
//   random samples .............. directed pass + the three backpressure passes,
//                                 with the seed from +seed (>= 3 seeds per gate)
//   maximum positive/negative ... directed pass
//   saturation .................. the `random` and `max` coefficient sets
//                                 saturate on most beats; a coverage audit at
//                                 the end fails the run if both directions were
//                                 not observed, so the flag checks cannot pass
//                                 vacuously
//   coefficient-bank swap ....... the swap pass: two frames, a swap requested
//                                 MID-FRAME, each frame checked against its own
//                                 coefficient set with no corrupted beat at the
//                                 seam; plus mid-stream writes to the inactive
//                                 bank, which must not move a single output bit
//   random output backpressure .. three passes at none / light / heavy, all
//                                 scoreboarded by sequence number, so content
//                                 invariance under backpressure is checked
//                                 rather than asserted
//
// plus SPEC 13.2 metamorphic relations that need no oracle at all:
//
//   negation .... y(-x) == -y(x) wherever -y is representable. Exact, because
//                 round-to-nearest-even is symmetric about zero.
//   delay ....... delaying the input by D beats delays the output by D beats.
//   scaling ..... doubling an unsaturated input doubles the exact accumulator;
//                 checked as a property of the model AND of the RTL against the
//                 scaled model, which together make it a statement about the
//                 hardware rather than about the model alone.
//
// MATCHING BY SEQUENCE NUMBER, NOT BY POSITION
// --------------------------------------------
// Every beat carries seq, stream_id and user, and every output is matched to its
// input BY SEQ. That is what makes SPEC 7.1's "valid metadata must travel with
// the corresponding samples" a checked property instead of an assumption: a
// result delivered against the wrong metadata fails on content, and a metadata
// field that did not travel fails on its own comparison. It is also what lets
// one scoreboard serve two banks whose latencies differ in KIND — the tree's is
// measured in cycles, the cascade's partly in beats (rtl/packages/pfb_pkg.sv,
// "Beats and cycles").
//
// THE NEGATIVE TEST RUNS LAST
// ---------------------------
// `a_coeff_swap_at_sof` is only worth having if it can fire. pfb_top carries one
// coeff_bank elaborated with ALLOW_UNSAFE_SWAP = 1, outside the datapath, whose
// swap ignores the frame boundary. The final mode drives it with
// `Verilated::fatalOnError` cleared and stdout captured, and REQUIRES that exact
// property to fire by name — the same expected-failure mechanism
// sim/tests/test_stream_assertions.cpp uses, and for the same reason. It runs
// last because clearing fatalOnError weakens every assertion in the build, so
// nothing else may run after it.
//
// Built by `make sim-tiny` as:
//   scripts/build_verilator.py --mode fast --top pfb_top
//       --files sim/verilator/files_pfb.f --test test_pfb_bank
// -----------------------------------------------------------------------------

#include <unistd.h>

#include <chrono>
#include <cstdint>
#include <cstdio>
#include <cstring>
#include <memory>
#include <random>
#include <string>
#include <vector>

#include "Vpfb_top.h"
#include "verilated.h"

#include "config_sim.h"
#include "harness/error_collector.h"
#include "harness/random.h"
#include "harness/run_summary.h"
#include "harness/sim_args.h"

#include "fxp/fxp.hpp"
#include "pfb/pfb_model.hpp"

using harness::BackpressureConfig;
using harness::BackpressureGenerator;
using harness::ErrorCollector;
using harness::RunSummary;
using harness::SeedSource;
using harness::SimArgs;

namespace {

constexpr const char* kTestName = "test_pfb_bank";

// ---------------------------------------------------------------------------
// Mirror of the geometry in sim/verilator/tops/pfb_top.sv. Checked against the
// RTL's own cfg_* echo before anything else runs, so a drift is a named failure
// rather than a silently wrong comparison.
// ---------------------------------------------------------------------------
constexpr unsigned kPhases = 4;
constexpr unsigned kTaps = 8;
constexpr unsigned kMultPipe = 4;
constexpr unsigned kAddrW = 5;      // clog2(kPhases * kTaps)
constexpr unsigned kNCoeff = kPhases * kTaps;
constexpr unsigned kPayloadW = kPhases * 32 + 2 + 2 + 16 + 4;  // 152

constexpr unsigned kNDut = 2;
constexpr bool kDutSystolic[kNDut] = {false, true};
const char* const kDutName[kNDut] = {"TREE", "SYSTOLIC"};

// Zero beats driven before every pass so the RTL's (deliberately unreset) delay
// lines hold nothing but zeros when the pass begins — which is the state the C++
// model starts in. 3*kTaps covers the deepest history the SYSTOLIC style builds
// (2*(kTaps-1) stages) plus its cascade.
constexpr unsigned kPrologue = 3 * kTaps;

// Cycles allowed after the last input before a pass gives up waiting for output.
constexpr unsigned kDrainCycles = 4000;

// Coefficient sets, in the order the directed pass walks them. `ident` is first
// on purpose: its expected output can be written down without running any model
// at all (output beat m is input beat m), so it is the right first failure to
// look at when everything disagrees.
const char* const kSets[] = {"ident", "proto", "mixed", "random", "max"};
constexpr unsigned kNSets = sizeof(kSets) / sizeof(kSets[0]);

// ---------------------------------------------------------------------------
// Failure accounting. The relation that disagrees is the diagnosis, so the
// counts are kept apart rather than summed (NUMERICS.md 10, triage procedure).
// ---------------------------------------------------------------------------
struct Counters {
  std::size_t config = 0;
  std::size_t rtl_vs_model = 0;
  std::size_t model_vs_vector = 0;
  std::size_t rtl_vs_vector = 0;
  std::size_t metadata = 0;
  std::size_t alignment = 0;
  std::size_t metamorphic = 0;
  std::size_t telemetry = 0;
  std::size_t coverage = 0;
  std::size_t assertion = 0;

  std::size_t total() const {
    return config + rtl_vs_model + model_vs_vector + rtl_vs_vector + metadata +
           alignment + metamorphic + telemetry + coverage + assertion;
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
// Beats
// ---------------------------------------------------------------------------

struct InBeat {
  std::vector<fxp::Complex> x;
  bool sof = false;
  bool eof = false;
  std::uint16_t seq = 0;
  std::uint8_t id = 0;
  std::uint8_t user = 0;
  bool checked = true;   // false for prologue beats
};

struct Expected {
  bool present = false;
  std::vector<fxp::Complex> y;
  std::vector<unsigned> f_re;
  std::vector<unsigned> f_im;
  bool sof = false;
  bool eof = false;
  std::uint8_t id = 0;
  std::uint8_t user = 0;
  bool saturating = false;
};

struct OutBeat {
  std::uint16_t seq = 0;
  std::vector<fxp::Complex> y;
  bool sof = false;
  bool eof = false;
  std::uint8_t id = 0;
  std::uint8_t user = 0;
};

// ---------------------------------------------------------------------------
// DUT driving
// ---------------------------------------------------------------------------

void tick(Vpfb_top* top) {
  top->clk = 0;
  top->eval();
  top->clk = 1;
  top->eval();
}

// Settles combinationally with the current inputs applied, WITHOUT taking the
// edge. Everything observable must be read here, so it reflects the state the
// edge is about to act on.
void settle(Vpfb_top* top) {
  top->clk = 0;
  top->eval();
}

void idle_inputs(Vpfb_top* top) {
  top->s_valid = 0;
  top->s_sof = 0;
  top->s_eof = 0;
  top->s_id = 0;
  top->s_seq = 0;
  top->s_user = 0;
  for (unsigned w = 0; w < 4; ++w) top->s_data[w] = 0;
  top->m_ready = 1;
  top->cfg_wr_valid = 0;
  top->cfg_wr_bank = 0;
  top->cfg_wr_addr = 0;
  top->cfg_wr_data = 0;
  top->cfg_swap_req = 0;
  top->telem_clear = 0;
  top->telem_snapshot = 0;
  top->unsafe_swap_req = 0;
  top->unsafe_beat = 0;
  top->unsafe_sof = 0;
}

void reset_dut(Vpfb_top* top) {
  idle_inputs(top);
  top->rst_n = 0;
  for (int i = 0; i < 8; ++i) tick(top);
  top->rst_n = 1;
  for (int i = 0; i < 4; ++i) tick(top);
}

void set_data(Vpfb_top* top, const std::vector<fxp::Complex>& x) {
  for (unsigned p = 0; p < kPhases; ++p) {
    top->s_data[p] = static_cast<std::uint32_t>(x[p].packed());
  }
}

std::vector<fxp::Complex> get_data(const Vpfb_top* top, unsigned dut) {
  std::vector<fxp::Complex> out(kPhases);
  for (unsigned p = 0; p < kPhases; ++p) {
    const std::uint32_t w =
        (dut == 0) ? top->m0_data[p] : top->m1_data[p];
    out[p] = fxp::Complex::from_packed(w);
  }
  return out;
}

// One coefficient write through the configuration port. Returns false only if
// the crossing never accepted it, which would be a defect in the handshake
// rather than in this test.
bool cfg_write(Vpfb_top* top, unsigned bank, unsigned addr, fxp::Complex value) {
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

bool program_bank(Vpfb_top* top, unsigned bank,
                  const std::vector<fxp::Complex>& coeff) {
  for (unsigned i = 0; i < kNCoeff; ++i) {
    if (!cfg_write(top, bank, i, coeff[i])) return false;
  }
  return true;
}

// Requests a bank swap and waits for the crossing to accept the pulse. The swap
// itself does NOT happen here: it happens at the next admitted start-of-frame
// beat, which is the property under test.
bool request_swap(Vpfb_top* top) {
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
    if (top->cfg_swap_pending != 0 || top->cfg_swap_busy == 0) {
      // The request has either landed in the core domain or the crossing has
      // gone idle again (which, with the pending flag already set, is the same
      // thing).
      if (top->cfg_swap_pending != 0) return true;
    }
    tick(top);
  }
  return false;
}

// ---------------------------------------------------------------------------
// The pass engine
//
// Drives `beats` into the DUT, applies scheduled configuration activity, and
// captures every output beat of both banks. Backpressure on the master side and
// gaps on the slave side are generated from named substreams so the stimulus
// depends only on +seed.
// ---------------------------------------------------------------------------

struct CfgAction {
  std::size_t at_beat = 0;    // input beat index at which to start it
  bool swap = false;          // request a bank swap
  bool write = false;         // perform a single-coefficient write
  unsigned bank = 0;
  unsigned addr = 0;
  fxp::Complex value{};
};

struct PassResult {
  std::vector<OutBeat> out[kNDut];
  std::size_t admitted = 0;
  bool timed_out = false;
  std::uint64_t cycles = 0;
};

PassResult run_pass(Vpfb_top* top, const std::vector<InBeat>& beats,
                    BackpressureConfig gap_cfg, BackpressureConfig bp_cfg,
                    SeedSource& seeds, const std::string& tag,
                    std::vector<CfgAction> actions) {
  PassResult r;
  BackpressureGenerator gaps(seeds.engine(tag + ".gaps"), gap_cfg);
  BackpressureGenerator bp(seeds.engine(tag + ".bp"), bp_cfg);

  std::size_t next_in = 0;
  std::size_t next_action = 0;
  bool cfg_busy = false;          // a configuration write is mid-handshake
  bool swap_pulse_pending = false;
  std::uint64_t idle_cycles = 0;

  idle_inputs(top);

  while (true) {
    // ---- configuration activity, interleaved with the stream --------------
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

    // ---- slave side --------------------------------------------------------
    const bool offer = (next_in < beats.size()) && gaps.allow();
    if (offer) {
      const InBeat& b = beats[next_in];
      top->s_valid = 1;
      top->s_sof = b.sof ? 1 : 0;
      top->s_eof = b.eof ? 1 : 0;
      top->s_id = static_cast<std::uint8_t>(b.id);
      top->s_seq = static_cast<std::uint16_t>(b.seq);
      top->s_user = static_cast<std::uint8_t>(b.user);
      set_data(top, b.x);
    } else {
      top->s_valid = 0;
    }

    // ---- master side -------------------------------------------------------
    top->m_ready = bp.allow() ? 1 : 0;

    // ---- settle and observe -----------------------------------------------
    settle(top);

    const bool transferred = offer && (top->s_ready != 0);
    const bool cfg_taken = cfg_busy && (top->cfg_wr_ready != 0);

    for (unsigned d = 0; d < kNDut; ++d) {
      const bool v = (d == 0) ? (top->m0_valid != 0) : (top->m1_valid != 0);
      if (!v || top->m_ready == 0) continue;
      OutBeat o;
      o.y = get_data(top, d);
      if (d == 0) {
        o.seq = static_cast<std::uint16_t>(top->m0_seq);
        o.sof = top->m0_sof != 0;
        o.eof = top->m0_eof != 0;
        o.id = static_cast<std::uint8_t>(top->m0_id);
        o.user = static_cast<std::uint8_t>(top->m0_user);
      } else {
        o.seq = static_cast<std::uint16_t>(top->m1_seq);
        o.sof = top->m1_sof != 0;
        o.eof = top->m1_eof != 0;
        o.id = static_cast<std::uint8_t>(top->m1_id);
        o.user = static_cast<std::uint8_t>(top->m1_user);
      }
      r.out[d].push_back(std::move(o));
      idle_cycles = 0;
    }

    // ---- edge --------------------------------------------------------------
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
      // One-cycle strobe; cdc_pulse refuses a second while one is in flight.
      swap_pulse_pending = false;
      top->cfg_swap_req = 0;
    }

    if (next_in >= beats.size()) {
      ++idle_cycles;
      if (idle_cycles > kDrainCycles) {
        r.timed_out = true;
        break;
      }
      // Stop once both banks have gone quiet for long enough to have drained
      // everything a fixed-latency pipeline could still be holding.
      if (idle_cycles > 64 && top->m0_valid == 0 && top->m1_valid == 0) break;
    }
  }

  idle_inputs(top);
  return r;
}

// ---------------------------------------------------------------------------
// Scoreboard
// ---------------------------------------------------------------------------

struct CheckStats {
  std::size_t checked = 0;
  std::size_t saturating_seen = 0;
  unsigned flag_union = 0;
  std::size_t frames = 0;
};

CheckStats check_outputs(const std::string& where, unsigned dut,
                         const std::vector<OutBeat>& out,
                         const std::vector<Expected>& expect,
                         const std::vector<InBeat>& beats,
                         ErrorCollector* errors, Counters* c) {
  CheckStats st;
  std::vector<bool> seen(expect.size(), false);
  std::uint32_t last_seq = 0;
  bool have_last = false;
  // The sequence number is global across the run; the expectation list is
  // per-pass, so it is indexed relative to the pass's first beat.
  const std::uint16_t base = beats.empty() ? 0 : beats.front().seq;

  const std::size_t allowed_leftover = kDutSystolic[dut] ? (kTaps - 1) : 0;
  std::size_t leftover = 0;

  for (const OutBeat& o : out) {
    const std::size_t idx = static_cast<std::uint16_t>(o.seq - base);
    if (idx >= expect.size()) {
      // A SYSTOLIC bank holds its last TAPS-1 results in the cascade when a
      // pass ends; they emerge at the start of the NEXT pass, carrying the
      // previous pass's metadata. That is correct drain behaviour, and the
      // per-pass prologue exists to flush it — but the beats are still seen
      // here, so they are counted and bounded rather than reported one by one.
      const std::size_t behind = static_cast<std::uint16_t>(base - o.seq);
      if (behind > 0 && behind <= allowed_leftover) {
        ++leftover;
        continue;
      }
      report(errors, "metadata", &c->metadata,
             where + ": output seq " + std::to_string(o.seq) +
                 " is outside the pass (base " + std::to_string(base) + ", " +
                 std::to_string(expect.size()) + " beats driven)");
      continue;
    }
    // Order: the bank is a pipeline, not a reorder buffer. A seq that goes
    // backwards means a beat overtook another, which no amount of content
    // checking would catch.
    if (have_last && o.seq <= last_seq) {
      report(errors, "alignment", &c->alignment,
             where + ": output seq " + std::to_string(o.seq) +
                 " did not advance past " + std::to_string(last_seq));
    }
    last_seq = o.seq;
    have_last = true;

    const Expected& e = expect[idx];
    if (!e.present) continue;   // prologue beat: driven to flush, not checked
    if (seen[idx]) {
      report(errors, "alignment", &c->alignment,
             where + ": output seq " + std::to_string(o.seq) + " arrived twice");
      continue;
    }
    seen[idx] = true;
    ++st.checked;
    if (e.eof) ++st.frames;

    for (unsigned p = 0; p < kPhases; ++p) {
      st.flag_union |= e.f_re[p] | e.f_im[p];
      if (o.y[p] != e.y[p]) {
        report(errors, "rtl_vs_model", &c->rtl_vs_model,
               where + " seq " + std::to_string(o.seq) + " lane " +
                   std::to_string(p) + ": RTL " + cx(o.y[p]) + " vs model " +
                   cx(e.y[p]) + " (in " + cx(beats[idx].x[p]) + ", flags " +
                   flags_str(e.f_re[p]) + "/" + flags_str(e.f_im[p]) + ")");
      }
    }
    if (e.saturating) ++st.saturating_seen;

    if (o.sof != e.sof || o.eof != e.eof || o.id != e.id || o.user != e.user) {
      report(errors, "metadata", &c->metadata,
             where + " seq " + std::to_string(o.seq) +
                 ": metadata RTL {sof=" + std::to_string(o.sof ? 1 : 0) +
                 " eof=" + std::to_string(o.eof ? 1 : 0) + " id=" +
                 std::to_string(o.id) + " user=" + std::to_string(o.user) +
                 "} vs driven {sof=" + std::to_string(e.sof ? 1 : 0) + " eof=" +
                 std::to_string(e.eof ? 1 : 0) + " id=" + std::to_string(e.id) +
                 " user=" + std::to_string(e.user) + "}");
    }
  }

  // A SYSTOLIC bank legitimately retains its last TAPS-1 results (the cascade
  // drain, rtl/pfb/fir_lane.sv section 3); a TREE bank retains nothing. Anything
  // missing beyond that is a lost beat.
  const std::size_t allowed_missing = kDutSystolic[dut] ? (kTaps - 1) : 0;
  std::size_t missing = 0;
  for (std::size_t i = 0; i < expect.size(); ++i) {
    if (expect[i].present && !seen[i]) ++missing;
  }
  if (leftover > allowed_leftover) {
    report(errors, "alignment", &c->alignment,
           where + ": " + std::to_string(leftover) +
               " beats arrived from before this pass (at most " +
               std::to_string(allowed_leftover) + " cascade leftovers are legal)");
  }
  if (missing > allowed_missing) {
    report(errors, "alignment", &c->alignment,
           where + ": " + std::to_string(missing) +
               " expected beats never arrived (at most " +
               std::to_string(allowed_missing) + " may remain in the cascade)");
  }
  return st;
}

// ---------------------------------------------------------------------------
// Stimulus construction
// ---------------------------------------------------------------------------

// ONE stream id and a GLOBALLY monotonic sequence number for the whole run.
//
// Not an arbitrary choice: sim/assertions/stream_protocol_checker.sv checks
// SPEC 5 sequence continuity per stream id on the bank's master interface, and
// it is watching throughout. Restarting the count per pass, or interleaving ids,
// would make the DUT's own protocol checker fire on the testbench's stimulus
// rather than on a defect. The metadata that varies per beat -- sof, eof and
// user -- is what the alignment checks read.
constexpr std::uint8_t kStreamId = 1;
std::uint16_t g_seq = 0;

std::vector<InBeat> make_prologue() {
  std::vector<InBeat> beats;
  for (unsigned i = 0; i < kPrologue; ++i) {
    InBeat b;
    b.x.assign(kPhases, fxp::Complex{});
    b.seq = g_seq++;
    b.id = kStreamId;
    b.user = static_cast<std::uint8_t>(b.seq & 0xFu);
    b.checked = false;
    beats.push_back(std::move(b));
  }
  return beats;
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

// Runs the C++ model over the checked beats of `beats` and fills `expect`.
// `swap_at` (if non-zero) names the ADMITTED BEAT INDEX at which the
// coefficients are replaced — the model twin of a bank swap, which changes the
// taps without disturbing the history.
//
// THE `per_tap_skew` FLAG, AND WHY IT IS NOT A FUDGE
// --------------------------------------------------
// An adder-tree lane multiplies all TAPS taps of a beat in the SAME cycle, so a
// coefficient swap is instantaneous: output n uses h(n) for every tap.
//
// A systolic cascade does not. Its partial sums walk forward one stage per beat
// while the data walks backward, so output n is
//
//     y(n) = sum_j h_j(n + j) * x(n - j)
//
// — tap j's coefficient is sampled j BEATS LATE. A swap at beat B therefore
// gives outputs n in [B-TAPS+1, B-1] a MIXTURE of the two sets, one tap at a
// time. That is a property of the architecture, not a defect and not a timing
// accident, and it is the reason ACC_STYLE defaults to TREE (see DECISIONS.md
// and rtl/pfb/fir_lane.sv section 2).
//
// So this flag does not excuse the transition window; it PREDICTS it, exactly,
// tap by tap, and the RTL is then required to match the prediction bit for bit.
// A cascade that switched cleanly would fail here just as loudly as one that
// switched at the wrong beat.
std::vector<Expected> expect_for(const std::vector<InBeat>& beats,
                                 const std::vector<fxp::Complex>& coeff,
                                 std::size_t swap_at,
                                 const std::vector<fxp::Complex>& coeff2,
                                 bool per_tap_skew = false) {
  pfb::PfbModel model(kPhases, kTaps, coeff);
  std::vector<fxp::Complex> mixed(coeff.size());
  std::vector<Expected> expect(beats.size());
  for (std::size_t i = 0; i < beats.size(); ++i) {
    if (!beats[i].checked) continue;   // prologue: the model is not stepped
    if (swap_at != 0) {
      if (per_tap_skew) {
        for (unsigned p = 0; p < kPhases; ++p) {
          for (unsigned t = 0; t < kTaps; ++t) {
            const std::size_t k = pfb::coeff_index(kTaps, p, t);
            mixed[k] = (i + t >= swap_at) ? coeff2[k] : coeff[k];
          }
        }
        model.swap_coeff(mixed);
      } else if (i == swap_at) {
        model.swap_coeff(coeff2);
      }
    }
    const pfb::BeatResult r = model.step(beats[i].x);
    Expected& e = expect[i];
    e.present = true;
    e.y = r.y;
    e.f_re.resize(kPhases);
    e.f_im.resize(kPhases);
    for (unsigned p = 0; p < kPhases; ++p) {
      e.f_re[p] = r.flags_re[p].packed();
      e.f_im[p] = r.flags_im[p].packed();
    }
    e.sof = beats[i].sof;
    e.eof = beats[i].eof;
    e.id = beats[i].id;
    e.user = beats[i].user;
    e.saturating = r.merged().any();
  }
  return expect;
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
  // A polyphase mismatch is PHASES errors wide by construction, so the default
  // limit of twenty shows one and a half beats. Sixty shows the shape of the
  // failure — which lanes, which passes — which is what triage needs.
  errors.set_print_limit(60);
  Counters counters;
  SeedSource seeds(args.seed);

  const std::string vec_dir = args.plusarg("vectors", "model/vectors");

  // ---- load the coefficient sets and their golden vectors ------------------
  struct SetData {
    std::string name;
    std::vector<fxp::Complex> coeff;
    pfb::CoeffHeader chdr;
    std::vector<pfb::IoVector> io;
    pfb::IoHeader ihdr;
  };
  std::vector<SetData> sets;

  for (unsigned s = 0; s < kNSets; ++s) {
    SetData d;
    d.name = kSets[s];
    const std::string stem = vec_dir + "/pfb_" + d.name + "_p" +
                             std::to_string(kPhases) + "t" +
                             std::to_string(kTaps);
    std::string err;
    if (!pfb::load_coeff(stem + ".coeff", &d.coeff, &d.chdr, &err)) {
      std::printf("RESULT: FAIL seed=%llu test=%s reason=coeff_load (%s)\n",
                  static_cast<unsigned long long>(args.seed), kTestName,
                  err.c_str());
      return 2;
    }
    if (!pfb::load_io(stem + ".vec", &d.io, &d.ihdr, &err)) {
      std::printf("RESULT: FAIL seed=%llu test=%s reason=vector_load (%s)\n",
                  static_cast<unsigned long long>(args.seed), kTestName,
                  err.c_str());
      return 2;
    }
    if (d.chdr.phases != kPhases || d.chdr.taps != kTaps ||
        d.ihdr.phases != kPhases || d.ihdr.taps != kTaps) {
      std::printf("RESULT: FAIL seed=%llu test=%s reason=geometry_mismatch "
                  "(%s is %ux%u; the top is %ux%u)\n",
                  static_cast<unsigned long long>(args.seed), kTestName,
                  d.name.c_str(), d.chdr.phases, d.chdr.taps, kPhases, kTaps);
      return 2;
    }
    if (d.chdr.rounding_mode != pfb::expected_rounding_mode() ||
        d.ihdr.rounding_mode != pfb::expected_rounding_mode()) {
      std::printf("RESULT: FAIL seed=%llu test=%s reason=rounding_mode "
                  "(file says %s; this build is %s)\n",
                  static_cast<unsigned long long>(args.seed), kTestName,
                  d.chdr.rounding_mode.c_str(), pfb::expected_rounding_mode());
      return 2;
    }
    sets.push_back(std::move(d));
  }

  std::unique_ptr<Vpfb_top> top(new Vpfb_top);
  reset_dut(top.get());
  settle(top.get());

  // ---- pass 0: geometry echo ----------------------------------------------
  {
    struct Field { const char* name; unsigned rtl; unsigned mirror; };
    const Field fields[] = {
        {"phases", top->cfg_phases, kPhases},
        {"taps", top->cfg_taps, kTaps},
        {"mult_pipe", top->cfg_mult_pipe, kMultPipe},
        {"coeff_addr_w", top->cfg_coeff_addr_w, kAddrW},
        {"acc_w", top->cfg_acc_w, pfb::acc_w(kTaps)},
        {"lat_beats[TREE]", top->cfg_lat_beats0, pfb::lat_beats(false, kTaps)},
        {"lat_cycles[TREE]", top->cfg_lat_cycles0,
         pfb::lat_cycles(false, kTaps, kMultPipe)},
        {"lat_beats[SYSTOLIC]", top->cfg_lat_beats1,
         pfb::lat_beats(true, kTaps)},
        {"lat_cycles[SYSTOLIC]", top->cfg_lat_cycles1,
         pfb::lat_cycles(true, kTaps, kMultPipe)},
        {"payload_w", top->cfg_payload_w, kPayloadW},
    };
    for (const Field& f : fields) {
      if (f.rtl != f.mirror) {
        report(&errors, "config", &counters.config,
               std::string("geometry ") + f.name + ": RTL " +
                   std::to_string(f.rtl) + " vs test mirror " +
                   std::to_string(f.mirror));
      }
    }
  }
  if (counters.config != 0) {
    std::printf("RESULT: FAIL seed=%llu test=%s reason=geometry_mirror\n",
                static_cast<unsigned long long>(args.seed), kTestName);
    return 2;
  }

  // ---- the C++ model against the committed NumPy vectors -------------------
  // Before the RTL is compared against the model, the model is compared against
  // an expectation it did not produce. An oracle that agrees only with itself is
  // not an oracle (SPEC 12.4).
  for (const SetData& d : sets) {
    pfb::PfbModel m(kPhases, kTaps, d.coeff);
    for (const pfb::IoVector& v : d.io) {
      const pfb::BeatResult r = m.step(v.x);
      for (unsigned p = 0; p < kPhases; ++p) {
        if (r.y[p] != v.y[p] || r.flags_re[p].packed() != v.f_re[p] ||
            r.flags_im[p].packed() != v.f_im[p]) {
          report(&errors, "model_vs_vector", &counters.model_vs_vector,
                 "set " + d.name + " beat " + std::to_string(v.beat) +
                     " lane " + std::to_string(p) + ": C++ model " +
                     cx(r.y[p]) + " vs NumPy vector " + cx(v.y[p]));
        }
      }
    }
  }

  unsigned flag_union = 0;
  std::size_t beats_checked = 0;
  std::size_t frames_checked = 0;
  unsigned active_bank = 0;   // the bank the RTL is currently filtering with

  // =========================================================================
  // Pass 1 — directed: every coefficient set against its golden vectors
  // =========================================================================
  for (const SetData& d : sets) {
    const unsigned spare = active_bank ^ 1u;
    if (!program_bank(top.get(), spare, d.coeff)) {
      report(&errors, "config", &counters.config,
             "set " + d.name + ": the coefficient crossing never accepted a write");
      break;
    }
    if (!request_swap(top.get())) {
      report(&errors, "config", &counters.config,
             "set " + d.name + ": the swap request never reached the core domain");
      break;
    }

    std::vector<InBeat> beats = make_prologue();
    const std::size_t first = beats.size();
    for (const pfb::IoVector& v : d.io) {
      InBeat b;
      b.x = v.x;
      b.seq = g_seq++;
      beats.push_back(std::move(b));
    }
    tag_metadata(&beats, first, beats.size() - 1);

    // The prologue's first beat opens a frame too — the swap must land
    // somewhere, and landing it on the flush frame is what makes the CHECKED
    // frame entirely one coefficient set.
    beats[0].sof = true;
    beats[first - 1].eof = true;

    const std::vector<Expected> expect =
        expect_for(beats, d.coeff, 0, d.coeff);

    const PassResult pr =
        run_pass(top.get(), beats, BackpressureConfig::none(),
                 BackpressureConfig::none(), seeds, "directed." + d.name, {});
    active_bank = spare;

    if (pr.timed_out) {
      report(&errors, "alignment", &counters.alignment,
             "set " + d.name + ": pass timed out with outputs outstanding");
    }
    for (unsigned dut = 0; dut < kNDut; ++dut) {
      const CheckStats st =
          check_outputs("directed[" + d.name + "]." + kDutName[dut], dut,
                        pr.out[dut], expect, beats, &errors, &counters);
      flag_union |= st.flag_union;
      beats_checked += st.checked;
      frames_checked += st.frames;
    }

    // The RTL's own outputs were just checked against the model; the model was
    // checked against the vectors above. The remaining edge of the triangle is
    // RTL against the vectors directly, which is what this loop closes for the
    // TREE bank (whose output beat index equals its input beat index).
    const std::uint16_t seq0 = beats.front().seq;
    for (const OutBeat& o : pr.out[0]) {
      const std::size_t local = static_cast<std::uint16_t>(o.seq - seq0);
      if (local < first) continue;
      const std::size_t vi = local - first;
      if (vi >= d.io.size()) continue;
      for (unsigned p = 0; p < kPhases; ++p) {
        if (o.y[p] != d.io[vi].y[p]) {
          report(&errors, "rtl_vs_vector", &counters.rtl_vs_vector,
                 "directed[" + d.name + "] beat " + std::to_string(vi) +
                     " lane " + std::to_string(p) + ": RTL " + cx(o.y[p]) +
                     " vs NumPy vector " + cx(d.io[vi].y[p]));
        }
      }
    }
  }

  // =========================================================================
  // Pass 2 — random samples under three backpressure profiles
  //
  // The same beats, the same expectations, three different stall patterns. The
  // scoreboard is by sequence number, so "content is invariant under
  // backpressure" is checked rather than asserted: a beat whose value depended
  // on when it was drained would fail against the model it was compared to in
  // the un-stalled run.
  // =========================================================================
  {
    const SetData& d = sets[1];   // `proto`: L1-scaled, so no saturation noise
    const unsigned spare = active_bank ^ 1u;
    program_bank(top.get(), spare, d.coeff);
    request_swap(top.get());

    struct Profile { const char* name; BackpressureConfig gap, bp; };
    const Profile profiles[] = {
        {"dense", BackpressureConfig::none(), BackpressureConfig::none()},
        {"light", BackpressureConfig::light(), BackpressureConfig::light()},
        {"heavy", BackpressureConfig::bursty(), BackpressureConfig::heavy()},
    };

    bool first_profile = true;
    for (const Profile& prof : profiles) {
      std::mt19937_64 rng = seeds.engine(std::string("random.") + prof.name);
      std::vector<InBeat> beats = make_prologue();
      const std::size_t first = beats.size();
      for (unsigned i = 0; i < 320; ++i) {
        InBeat b;
        b.x.resize(kPhases);
        for (unsigned p = 0; p < kPhases; ++p) {
          b.x[p] = fxp::Complex{
              static_cast<fxp::i16>(
                  static_cast<std::int64_t>(
                      harness::uniform_u64(rng, 0, 65535)) - 32768),
              static_cast<fxp::i16>(
                  static_cast<std::int64_t>(
                      harness::uniform_u64(rng, 0, 65535)) - 32768)};
        }
        b.seq = g_seq++;
        beats.push_back(std::move(b));
      }
      // Four frames of 80 beats, so backpressure has to survive frame
      // boundaries as well as beats (SPEC 5).
      for (unsigned f = 0; f < 4; ++f) {
        tag_metadata(&beats, first + f * 80, first + f * 80 + 79);
      }
      beats[0].sof = true;
      beats[first - 1].eof = true;

      const std::vector<Expected> expect =
          expect_for(beats, d.coeff, 0, d.coeff);
      const PassResult pr =
          run_pass(top.get(), beats, prof.gap, prof.bp, seeds,
                   std::string("random.") + prof.name, {});
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
        const CheckStats st = check_outputs(
            std::string("random[") + prof.name + "]." + kDutName[dut], dut,
            pr.out[dut], expect, beats, &errors, &counters);
        flag_union |= st.flag_union;
        beats_checked += st.checked;
        frames_checked += st.frames;
      }
    }
  }

  // =========================================================================
  // Pass 3 — coefficient-bank swap at a frame boundary, requested MID-FRAME
  //
  // Frame A under set `proto`, frame B under set `mixed`. The swap is requested
  // in the middle of frame A and must take effect on frame B's first beat, not
  // before. Writes to the SPARE bank are interleaved with frame A and must not
  // move a single output bit — the inactive-bank-write-has-no-effect property,
  // checked here on the data and continuously by a_coeff_stable_between.
  // =========================================================================
  {
    const SetData& a = sets[1];   // proto
    const SetData& b = sets[2];   // mixed

    const unsigned bank_a = active_bank ^ 1u;
    program_bank(top.get(), bank_a, a.coeff);
    request_swap(top.get());

    std::vector<InBeat> beats = make_prologue();
    const std::size_t first = beats.size();
    // Long frames on purpose. The whole of set B is written into the spare bank
    // WHILE frame A streams, and one coefficient write is a four-phase
    // clock-domain crossing — about eight cycles each, 32 of them. A short frame
    // A would leave the reprogramming unfinished when frame B opened, and the
    // pass would be testing nothing but its own impatience.
    constexpr unsigned kFrame = 384;
    std::mt19937_64 rng = seeds.engine("swap.data");
    for (unsigned i = 0; i < 2 * kFrame; ++i) {
      InBeat bb;
      bb.x.resize(kPhases);
      for (unsigned p = 0; p < kPhases; ++p) {
        bb.x[p] = fxp::Complex{
            static_cast<fxp::i16>(
                static_cast<std::int64_t>(
                    harness::uniform_u64(rng, 0, 40000)) - 20000),
            static_cast<fxp::i16>(
                static_cast<std::int64_t>(
                    harness::uniform_u64(rng, 0, 40000)) - 20000)};
      }
      bb.seq = g_seq++;
      beats.push_back(std::move(bb));
    }
    tag_metadata(&beats, first, first + kFrame - 1);
    tag_metadata(&beats, first + kFrame, first + 2 * kFrame - 1);
    beats[0].sof = true;
    beats[first - 1].eof = true;

    // The prologue frame runs under bank_a as well, so the checked frame A is
    // entirely one coefficient set. Frame A's swap is armed by the mid-frame
    // configuration activity below.
    const std::size_t swap_beat = first + kFrame;

    std::vector<CfgAction> actions;
    // Mid-frame writes into the spare bank — the whole of set B, one write per
    // few beats, starting a quarter of the way into frame A.
    const unsigned bank_b = bank_a ^ 1u;
    for (unsigned i = 0; i < kNCoeff; ++i) {
      CfgAction w;
      w.at_beat = first + 8 + i * 8;
      w.write = true;
      w.bank = bank_b;
      w.addr = i;
      w.value = b.coeff[i];
      actions.push_back(w);
    }
    // The swap request, still mid-frame: it must be REMEMBERED and applied at
    // the next start of frame, which is the property under test.
    CfgAction sw;
    sw.at_beat = first + kFrame - 16;
    sw.swap = true;
    actions.push_back(sw);

    // Two expectation sets, one per accumulation structure. They differ ONLY in
    // the TAPS-1 beats before the swap; see expect_for() for why the cascade's
    // transition window is predicted rather than excused.
    const std::vector<Expected> expect_tree =
        expect_for(beats, a.coeff, swap_beat, b.coeff, false);
    const std::vector<Expected> expect_sys =
        expect_for(beats, a.coeff, swap_beat, b.coeff, true);

    const PassResult pr =
        run_pass(top.get(), beats, BackpressureConfig::light(),
                 BackpressureConfig::light(), seeds, "swap", actions);
    active_bank = bank_b;

    if (pr.timed_out) {
      report(&errors, "alignment", &counters.alignment,
             "swap: pass timed out with outputs outstanding");
    }
    for (unsigned dut = 0; dut < kNDut; ++dut) {
      const std::vector<Expected>& expect =
          kDutSystolic[dut] ? expect_sys : expect_tree;
      const CheckStats st =
          check_outputs(std::string("swap.") + kDutName[dut], dut, pr.out[dut],
                        expect, beats, &errors, &counters);
      flag_union |= st.flag_union;
      beats_checked += st.checked;
      frames_checked += st.frames;
    }

    settle(top.get());
    if (top->cfg_wr_reject != 0) {
      report(&errors, "config", &counters.config,
             "swap: the coefficient bank rejected a write; every write in this "
             "pass targeted the spare bank");
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
  // Pass 4 — metamorphic relations (SPEC 13.2)
  // =========================================================================
  {
    const SetData& d = sets[1];   // proto: L1-scaled, so nothing saturates
    const unsigned spare = active_bank ^ 1u;
    program_bank(top.get(), spare, d.coeff);
    request_swap(top.get());
    active_bank = spare;

    // Base stimulus, deliberately at half scale so that DOUBLING it is still a
    // legal Q1.15 input and so the L1-scaled filter cannot saturate on either.
    std::mt19937_64 rng = seeds.engine("metamorphic.base");
    std::vector<std::vector<fxp::Complex>> base;
    for (unsigned i = 0; i < 160; ++i) {
      std::vector<fxp::Complex> beat(kPhases);
      for (unsigned p = 0; p < kPhases; ++p) {
        beat[p] = fxp::Complex{
            static_cast<fxp::i16>(
                static_cast<std::int64_t>(
                    harness::uniform_u64(rng, 0, 16382)) - 8191),
            static_cast<fxp::i16>(
                static_cast<std::int64_t>(
                    harness::uniform_u64(rng, 0, 16382)) - 8191)};
      }
      base.push_back(std::move(beat));
    }

    enum Variant { kBase = 0, kNegated, kScaled, kDelayed, kNVariant };
    const char* const vname[kNVariant] = {"base", "negated", "scaled",
                                          "delayed"};
    constexpr unsigned kDelay = 5;

    std::vector<std::vector<fxp::Complex>> got[kNVariant];

    for (unsigned v = 0; v < kNVariant; ++v) {
      std::vector<InBeat> beats = make_prologue();
      const std::size_t first = beats.size();

      if (v == kDelayed) {
        // D extra zero beats in front: the response must be the same sequence,
        // D beats later.
        for (unsigned i = 0; i < kDelay; ++i) {
          InBeat z;
          z.x.assign(kPhases, fxp::Complex{});
          z.seq = g_seq++;
          beats.push_back(std::move(z));
        }
      }
      for (const std::vector<fxp::Complex>& src : base) {
        InBeat bb;
        bb.x.resize(kPhases);
        for (unsigned p = 0; p < kPhases; ++p) {
          if (v == kNegated) {
            bb.x[p] = fxp::Complex{static_cast<fxp::i16>(-src[p].re),
                                   static_cast<fxp::i16>(-src[p].im)};
          } else if (v == kScaled) {
            bb.x[p] = fxp::Complex{static_cast<fxp::i16>(src[p].re * 2),
                                   static_cast<fxp::i16>(src[p].im * 2)};
          } else {
            bb.x[p] = src[p];
          }
        }
        bb.seq = g_seq++;
        beats.push_back(std::move(bb));
      }
      tag_metadata(&beats, first, beats.size() - 1);
      beats[0].sof = true;
      beats[first - 1].eof = true;

      const std::vector<Expected> expect =
          expect_for(beats, d.coeff, 0, d.coeff);
      const PassResult pr =
          run_pass(top.get(), beats, BackpressureConfig::none(),
                   BackpressureConfig::none(), seeds,
                   std::string("metamorphic.") + vname[v], {});
      for (unsigned dut = 0; dut < kNDut; ++dut) {
        const CheckStats st = check_outputs(
            std::string("metamorphic[") + vname[v] + "]." + kDutName[dut], dut,
            pr.out[dut], expect, beats, &errors, &counters);
        flag_union |= st.flag_union;
        beats_checked += st.checked;
        frames_checked += st.frames;
      }

      // Collect the TREE bank's response, indexed by the position of the
      // corresponding BASE beat, so the four runs are directly comparable.
      got[v].assign(base.size(), std::vector<fxp::Complex>());
      const std::uint16_t seq0 = beats.front().seq;
      const std::size_t offset = first + ((v == kDelayed) ? kDelay : 0);
      for (const OutBeat& o : pr.out[0]) {
        const std::size_t local = static_cast<std::uint16_t>(o.seq - seq0);
        if (local < offset) continue;
        const std::size_t idx = local - offset;
        if (idx < base.size()) got[v][idx] = o.y;
      }
    }

    // --- the relations ----------------------------------------------------
    std::size_t compared = 0;
    for (std::size_t i = 0; i < base.size(); ++i) {
      if (got[kBase][i].empty()) continue;
      for (unsigned p = 0; p < kPhases; ++p) {
        const fxp::Complex y = got[kBase][i][p];

        // Negation: exact, because round-to-nearest-even is symmetric about
        // zero. The one exception is -32768, whose negation is not
        // representable and saturates; the base stimulus is half scale under an
        // L1-scaled filter, so it cannot occur, and if it does the run should
        // fail rather than quietly skip it.
        if (!got[kNegated][i].empty()) {
          const fxp::Complex n = got[kNegated][i][p];
          if (n.re != -y.re || n.im != -y.im) {
            report(&errors, "metamorphic", &counters.metamorphic,
                   "negation beat " + std::to_string(i) + " lane " +
                       std::to_string(p) + ": y(-x)=" + cx(n) + " but -y(x)=(" +
                       std::to_string(-y.re) + "," + std::to_string(-y.im) +
                       ")");
          }
        }

        // Scaling: doubling the input doubles the exact accumulator, so the
        // output doubles to within the one LSB that rounding may move it. The
        // exact statement — that the RTL matches the model on the scaled run —
        // was already checked above; this is the oracle-free half.
        if (!got[kScaled][i].empty()) {
          const fxp::Complex s = got[kScaled][i][p];
          const long dre = static_cast<long>(s.re) - 2L * y.re;
          const long dim = static_cast<long>(s.im) - 2L * y.im;
          if (dre < -1 || dre > 1 || dim < -1 || dim > 1) {
            report(&errors, "metamorphic", &counters.metamorphic,
                   "scaling beat " + std::to_string(i) + " lane " +
                       std::to_string(p) + ": y(2x)=" + cx(s) +
                       " is not 2*y(x)=(" + std::to_string(2 * y.re) + "," +
                       std::to_string(2 * y.im) + ") to within 1 LSB");
          }
        }

        // Delay: a delayed input produces the identical sequence, delayed.
        if (!got[kDelayed][i].empty()) {
          const fxp::Complex t = got[kDelayed][i][p];
          if (t != y) {
            report(&errors, "metamorphic", &counters.metamorphic,
                   "delay beat " + std::to_string(i) + " lane " +
                       std::to_string(p) + ": delayed run gave " + cx(t) +
                       " where the base run gave " + cx(y));
          }
        }
        ++compared;
      }
    }
    if (compared < base.size()) {
      report(&errors, "coverage", &counters.coverage,
             "the metamorphic pass compared only " + std::to_string(compared) +
                 " lane-beats; the relations would have passed vacuously");
    }
  }

  // =========================================================================
  // Pass 5 — telemetry (SPEC 9 counters through the issue #8 primitives)
  // =========================================================================
  {
    const SetData& d = sets[4];   // `max`: saturates on nearly every beat
    const unsigned spare = active_bank ^ 1u;
    program_bank(top.get(), spare, d.coeff);
    request_swap(top.get());
    active_bank = spare;

    // FLUSH FIRST, THEN CLEAR, THEN MEASURE — and the order is the whole point.
    //
    // The swap to `max` takes effect on this flush pass's first beat, while the
    // delay lines still hold the previous pass's samples. Those residuals times
    // a full-scale coefficient set saturate, and they are real saturation events
    // that the counters are right to count. They are simply not the events this
    // measurement is about, and the model has no way to predict them because it
    // never saw the previous pass's history. So the flush runs first, the
    // counters are cleared after it, and the measured pass starts from a history
    // the model shares.
    {
      std::vector<InBeat> flush = make_prologue();
      flush.front().sof = true;
      flush.back().eof = true;
      run_pass(top.get(), flush, BackpressureConfig::none(),
               BackpressureConfig::none(), seeds, "telemetry.flush", {});
    }

    top->telem_clear = 1;
    tick(top.get());
    top->telem_clear = 0;
    tick(top.get());

    std::vector<InBeat> beats;
    for (const pfb::IoVector& v : d.io) {
      InBeat b;
      b.x = v.x;
      b.seq = g_seq++;
      beats.push_back(std::move(b));
    }
    constexpr unsigned kFrames = 3;
    const std::size_t per = beats.size() / kFrames;
    for (unsigned f = 0; f < kFrames; ++f) {
      tag_metadata(&beats, f * per,
                   (f == kFrames - 1) ? (beats.size() - 1)
                                      : ((f + 1) * per - 1));
    }

    const std::vector<Expected> expect = expect_for(beats, d.coeff, 0, d.coeff);
    const PassResult pr =
        run_pass(top.get(), beats, BackpressureConfig::none(),
                 BackpressureConfig::none(), seeds, "telemetry", {});

    std::size_t model_sat_beats = 0;
    std::size_t model_frames = 0;
    const std::uint16_t seq0 = beats.front().seq;
    for (const OutBeat& o : pr.out[0]) {
      const std::size_t local = static_cast<std::uint16_t>(o.seq - seq0);
      if (local >= beats.size()) continue;   // a leftover from an earlier pass
      if (beats[local].eof) ++model_frames;
      if (expect[local].present && expect[local].saturating) ++model_sat_beats;
    }
    for (unsigned dut = 0; dut < kNDut; ++dut) {
      const CheckStats st =
          check_outputs(std::string("telemetry.") + kDutName[dut], dut,
                        pr.out[dut], expect, beats, &errors, &counters);
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
               " framed beats were checked");
  }

  // =========================================================================
  // Pass 6 — the negative test. LAST: it clears fatalOnError for the whole
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

    // A swap request to the ALLOW_UNSAFE_SWAP bank, with no beat and no
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
                 "); the frame-boundary assertion is not load-bearing");
    } else {
      ++assertion_fires;
    }
  }

  const bool passed = counters.total() == 0;

  std::printf("--- polyphase FIR bank ---\n");
  std::printf("  geometry         : %u phases x %u taps, mult_pipe %u, acc_w %u\n",
              kPhases, kTaps, kMultPipe, pfb::acc_w(kTaps));
  std::printf("  DUTs             : TREE (lat %u beats / %u cycles), "
              "SYSTOLIC (lat %u beats / %u cycles)\n",
              pfb::lat_beats(false, kTaps),
              pfb::lat_cycles(false, kTaps, kMultPipe),
              pfb::lat_beats(true, kTaps),
              pfb::lat_cycles(true, kTaps, kMultPipe));
  std::printf("  coefficient sets : %u (%s)\n", kNSets, "ident proto mixed random max");
  std::printf("  output beats     : %zu checked against the C++ model\n",
              beats_checked);
  std::printf("  frames           : %zu end-of-frame beats checked\n",
              frames_checked);
  std::printf("  saturation seen  : %s\n", flags_str(flag_union).c_str());
  std::printf("  swap assertion   : %zu expected fire(s)\n", assertion_fires);
  std::printf("  RTL vs model     : %zu\n", counters.rtl_vs_model);
  std::printf("  model vs vectors : %zu\n", counters.model_vs_vector);
  std::printf("  RTL vs vectors   : %zu\n", counters.rtl_vs_vector);
  std::printf("  metadata         : %zu\n", counters.metadata);
  std::printf("  alignment        : %zu\n", counters.alignment);
  std::printf("  metamorphic      : %zu\n", counters.metamorphic);
  std::printf("  telemetry        : %zu\n", counters.telemetry);
  std::printf("  coverage         : %zu\n", counters.coverage);
  std::printf("  assertion        : %zu\n", counters.assertion);
  if (!assertion_evidence.empty()) {
    const std::size_t nl = assertion_evidence.find('\n');
    std::printf("  expected failure : %s\n",
                assertion_evidence.substr(0, nl == std::string::npos
                                                 ? assertion_evidence.size()
                                                 : nl).c_str());
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
      passed ? "both accumulation styles bit-exact against the C++ model and "
               "the NumPy vectors"
             : "polyphase FIR mismatch; see errors_by_category";
  summary.passes = 6;
  summary.beats_observed = beats_checked;
  summary.absorb(errors);
  summary.wall_time_s =
      std::chrono::duration<double>(wall_end - wall_start).count();
  const std::string written = summary.write(args.results_dir);
  if (!written.empty()) std::printf("  summary json     : %s\n", written.c_str());

  if (passed) {
    std::printf("RESULT: PASS seed=%llu test=%s config=%s beats=%zu\n",
                static_cast<unsigned long long>(args.seed), kTestName,
                sim_config::kName, beats_checked);
    return 0;
  }
  std::printf("RESULT: FAIL seed=%llu test=%s config=%s rtl_vs_model=%zu "
              "model_vs_vector=%zu rtl_vs_vector=%zu metadata=%zu "
              "alignment=%zu metamorphic=%zu telemetry=%zu coverage=%zu "
              "assertion=%zu config=%zu\n",
              static_cast<unsigned long long>(args.seed), kTestName,
              sim_config::kName, counters.rtl_vs_model,
              counters.model_vs_vector, counters.rtl_vs_vector,
              counters.metadata, counters.alignment, counters.metamorphic,
              counters.telemetry, counters.coverage, counters.assertion,
              counters.config);
  return 1;
}
