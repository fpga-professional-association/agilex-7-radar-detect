// -----------------------------------------------------------------------------
// test_packet.cpp — packet-network verification (issue #18; SPEC 7.8, 13.1,
// 13.3, 14).
//
// Every packet the fabric delivers is compared FIELD FOR FIELD and WORD FOR WORD
// against model/cpp/packet/packet_model.hpp, in order within its (source, VC,
// destination) triple, for every packet this test injects. Not a count, not a
// checksum, not a spot check.
//
// Eight passes:
//
//   1. geometry     the RTL's cfg_* echo against this file's mirror and against
//                   packet_model.hpp's constants — both the FLIT control offsets
//                   and the HEADER field offsets, because those are the two
//                   layouts the model reproduces. Nothing else runs until they
//                   agree, so a layout change is a named failure rather than a
//                   wrong comparison.
//   2. directed     one packet of every SPEC 7.8 type, at minimum length (1
//                   flit, header only) and at maximum length (PKT_MAX_FLITS),
//                   plus a detection-event-sized packet whose flit count comes
//                   from cfar_pkg by way of packet_pkg. Every one checked whole.
//   3. random       random sources, destinations, virtual channels, lengths and
//                   stalls on both sides. Zero loss, zero duplication, zero
//                   corruption, and in-order within every (src, VC, dest).
//   4. hotspot      every source targeting ONE egress port. Nothing may starve:
//                   the per-source delivered share is checked against a fairness
//                   bound, and the switch's own overtake metric
//                   (tel_stage_maxwait) against the arbitration bound.
//   5. vc isolation VC0 is stalled at one egress by clearing its enable bit
//                   while every source drives both VC0 and VC1 at that port.
//                   VC1 must keep being delivered — which is the entire purpose
//                   of a virtual channel and the property SPEC 7.8 names.
//   6. backpressure the same stimulus with and without randomized stalls on
//                   both sides must deliver a byte-identical packet sequence per
//                   (src, VC, dest). Stalls may reorder ACROSS triples; that is
//                   allowed and is not checked.
//   7. fault        the credit return of one (stage, port, VC) is broken. That
//                   virtual channel must stop making progress and every other
//                   one must not; the fault is then reverted and the fabric must
//                   drain completely, with the scoreboard finding nothing lost.
//                   Then a TWO-BIT payload corruption, which parity is blind to
//                   by construction (packet_pkg section 3), must be caught by the
//                   payload comparison instead.
//   8. telemetry    the RTL's own per-port packet counters against this test's
//                   independent tally.
//
// The RTL carries its own checks in parallel on every cycle of all of it:
// pkt_ingress's length, VC-stability and credit assertions, pkt_switch_stage's
// buffer-overrun, parity, VC-tag and grant-lock assertions, pkt_egress's five
// reassembly checks, sync_fifo's overflow/underflow proofs and pkt_rr_arb's
// one-hot and no-starvation properties. A Verilator assertion failure aborts the
// run, so all of those gate this test even though nothing here references them.
// The negative half — that those assertions FIRE when they should — is
// sim/tests/test_packet_assertions.cpp.
//
// Built by `make sim-tiny` as:
//   scripts/build_verilator.py --mode fast --top packet_top
//       --files sim/verilator/files_packet.f --test test_packet
// -----------------------------------------------------------------------------

#include <chrono>
#include <cstdint>
#include <cstdio>
#include <deque>
#include <map>
#include <memory>
#include <random>
#include <string>
#include <vector>

#include "Vpacket_top.h"
#include "verilated.h"

#include "config_sim.h"
#include "harness/error_collector.h"
#include "harness/random.h"
#include "harness/run_summary.h"
#include "harness/sim_args.h"

#include "packet/packet_model.hpp"
#include "harness/packet_tb.h"

using harness::ErrorCollector;
using harness::RunSummary;
using harness::SimArgs;
using packet_tb::Device;
using packet_tb::kNPorts;
using packet_tb::kNVc;
using packet_tb::kPacketW;

namespace {

constexpr const char* kTestName = "test_packet";

struct Counters {
  std::size_t config = 0;
  std::size_t loss = 0;
  std::size_t dup = 0;
  std::size_t corrupt = 0;
  std::size_t order = 0;
  std::size_t route = 0;
  std::size_t framing = 0;
  std::size_t parity = 0;
  std::size_t fairness = 0;
  std::size_t isolation = 0;
  std::size_t invariance = 0;
  std::size_t fault = 0;
  std::size_t telemetry = 0;
  std::size_t hang = 0;

  std::size_t total() const {
    return config + loss + dup + corrupt + order + route + framing + parity +
           fairness + isolation + invariance + fault + telemetry + hang;
  }
};

Counters g_counters;
ErrorCollector* g_errors = nullptr;

void fail(const char* category, std::size_t* slot, const std::string& what) {
  ++*slot;
  if (g_errors != nullptr) g_errors->error(category, what);
  if (*slot <= 8) std::printf("  FAIL [%s] %s\n", category, what.c_str());
}

// ---------------------------------------------------------------------------
// pass 1 — geometry
// ---------------------------------------------------------------------------
void check_eq(const char* name, std::uint64_t got, std::uint64_t want) {
  if (got != want) {
    fail("config", &g_counters.config,
         std::string(name) + ": RTL says " + std::to_string(got) +
             ", the model says " + std::to_string(want));
  }
}

void pass_geometry(Vpacket_top* top) {
  namespace pm = packet_model;
  check_eq("PACKET_W", top->cfg_packet_w, kPacketW);
  check_eq("N_VC", top->cfg_n_vc, kNVc);
  check_eq("RADIX", top->cfg_radix, packet_tb::kRadix);
  check_eq("STAGES", top->cfg_stages, packet_tb::kStages);
  check_eq("N_PORTS", top->cfg_n_ports, kNPorts);
  check_eq("FLIT_W", top->cfg_flit_w, kPacketW + pm::kFlitCtrlW);
  check_eq("PKT_HDR_W", top->cfg_hdr_w, pm::kHdrW);
  check_eq("PKT_DEST_W", top->cfg_dest_w, pm::kDestW);
  check_eq("PKT_SRC_W", top->cfg_src_w, pm::kSrcW);
  check_eq("PKT_VC_W", top->cfg_vc_w, pm::kVcW);
  check_eq("PKT_TYPE_W", top->cfg_type_w, pm::kTypeW);
  check_eq("PKT_LEN_W", top->cfg_len_w, pm::kLenW);
  check_eq("PKT_SEQ_W", top->cfg_seq_w, pm::kSeqW);
  check_eq("PKT_MAX_FLITS", top->cfg_max_flits, pm::kMaxFlits);
  check_eq("flit parity lsb", top->cfg_flit_parity_lsb, pm::kFlitParityLsb);
  check_eq("flit vc lsb", top->cfg_flit_vc_lsb, pm::kFlitVcLsb);
  check_eq("flit sof lsb", top->cfg_flit_sof_lsb, pm::kFlitSofLsb);
  check_eq("flit eof lsb", top->cfg_flit_eof_lsb, pm::kFlitEofLsb);
  check_eq("flit data lsb", top->cfg_flit_data_lsb, pm::kFlitDataLsb);
  check_eq("hdr dest lsb", top->cfg_hdr_dest_lsb, pm::kHdrDestLsb);
  check_eq("hdr src lsb", top->cfg_hdr_src_lsb, pm::kHdrSrcLsb);
  check_eq("hdr vc lsb", top->cfg_hdr_vc_lsb, pm::kHdrVcLsb);
  check_eq("hdr type lsb", top->cfg_hdr_type_lsb, pm::kHdrTypeLsb);
  check_eq("hdr len lsb", top->cfg_hdr_len_lsb, pm::kHdrLenLsb);
  check_eq("hdr seq lsb", top->cfg_hdr_seq_lsb, pm::kHdrSeqLsb);
  check_eq("detection payload width", top->cfg_detect_payload_w,
           pm::kDetectionPayloadW);
  check_eq("detection flits", top->cfg_detect_flits,
           pm::detection_flits(kPacketW));

  // The routing arithmetic, checked exhaustively rather than at a sample: every
  // (source, destination) pair of the elaborated network must have a
  // deterministic path that ends where the header says.
  for (unsigned s = 0; s < kNPorts; ++s) {
    for (unsigned d = 0; d < kNPorts; ++d) {
      if (!pm::route_path_ok(s, d, packet_tb::kRadix, packet_tb::kStages)) {
        fail("config", &g_counters.config,
             "no deterministic route from " + std::to_string(s) + " to " +
                 std::to_string(d));
      }
    }
  }
}

// ---------------------------------------------------------------------------
// Error harvesting shared by every traffic pass
// ---------------------------------------------------------------------------
// Snapshot of the scoreboard's counts at the last harvest. A file-scope
// variable rather than a function-local static so that the fault-injection pass
// can RE-SYNC it after forgiving the corruption it caused on purpose.
packet_model::Counts g_prev;

void absorb(Device* dev, const char* where) {
  const packet_model::Counts& c = dev->board().counts();
  packet_model::Counts& prev = g_prev;
  const auto bump = [&](std::size_t now, std::size_t was, const char* cat,
                        std::size_t* slot) {
    if (now > was) {
      fail(cat, slot,
           std::string(where) + ": " + std::to_string(now - was) + " " + cat);
    }
  };
  bump(c.lost, prev.lost, "loss", &g_counters.loss);
  bump(c.duplicated, prev.duplicated, "dup", &g_counters.dup);
  bump(c.corrupted, prev.corrupted, "corrupt", &g_counters.corrupt);
  bump(c.reordered, prev.reordered, "order", &g_counters.order);
  bump(c.misrouted, prev.misrouted, "route", &g_counters.route);
  bump(c.framing, prev.framing, "framing", &g_counters.framing);
  bump(c.parity, prev.parity, "parity", &g_counters.parity);
  bump(c.unexpected, prev.unexpected, "dup", &g_counters.dup);
  prev = c;

  // The RTL's own sticky error bits, harvested at the same points.
  for (unsigned p = 0; p < kNPorts; ++p) {
    const unsigned ie = dev->ingress_err(p);
    const unsigned ee = dev->egress_err(p);
    if (ie != 0) {
      fail("framing", &g_counters.framing,
           std::string(where) + ": ingress " + std::to_string(p) +
               " sticky error bits 0x" + std::to_string(ie));
    }
    if (ee != 0) {
      fail("framing", &g_counters.framing,
           std::string(where) + ": egress " + std::to_string(p) +
               " sticky error bits 0x" + std::to_string(ee));
    }
  }
}

// ---------------------------------------------------------------------------
// pass 2 — directed, one packet of every type at the length extremes
// ---------------------------------------------------------------------------
void pass_directed(Device* dev) {
  namespace pm = packet_model;
  const unsigned types[] = {pm::kTypeDetection, pm::kTypePower, pm::kTypeCovar,
                            pm::kTypeError,     pm::kTypeCounter, pm::kTypeRaw};

  unsigned src = 0;
  for (const unsigned t : types) {
    // Minimum: one flit, header only.
    dev->enqueue(src % kNPorts, dev->make_packet(src % kNPorts,
                                                 (src + 3) % kNPorts,
                                                 src % kNVc, t, 1));
    // Maximum: PKT_MAX_FLITS.
    dev->enqueue((src + 1) % kNPorts,
                 dev->make_packet((src + 1) % kNPorts, (src + 7) % kNPorts,
                                  (src + 1) % kNVc, t, pm::kMaxFlits));
    // A detection event, at the flit count packet_pkg derives from cfar_pkg.
    dev->enqueue((src + 2) % kNPorts,
                 dev->make_packet((src + 2) % kNPorts, (src + 11) % kNPorts,
                                  (src + 2) % kNVc, pm::kTypeDetection,
                                  pm::detection_flits(kPacketW)));
    src += 3;
  }

  if (!dev->run_until_drained(80000)) {
    fail("hang", &g_counters.hang, "directed traffic never drained");
  }
  absorb(dev, "directed");
}

// ---------------------------------------------------------------------------
// pass 3 — random traffic
// ---------------------------------------------------------------------------
void pass_random(Device* dev, std::mt19937_64 rng, unsigned n_packets,
                 double stall_p, const char* label) {
  namespace pm = packet_model;
  std::uniform_int_distribution<unsigned> port(0, kNPorts - 1);
  std::uniform_int_distribution<unsigned> vc(0, kNVc - 1);
  std::uniform_int_distribution<unsigned> len(1, 6);
  std::uniform_int_distribution<unsigned> type(0, pm::kTypeRaw);

  dev->set_stall_probability(stall_p);
  for (unsigned i = 0; i < n_packets; ++i) {
    const unsigned s = port(rng);
    dev->enqueue(s, dev->make_packet(s, port(rng), vc(rng), type(rng), len(rng)));
  }
  if (!dev->run_until_drained(400000)) {
    fail("hang", &g_counters.hang,
         std::string(label) + ": traffic never drained");
  }
  dev->set_stall_probability(0.0);
  absorb(dev, label);
}

// ---------------------------------------------------------------------------
// pass 4 — hotspot and fairness
//
// THE FAIRNESS METRIC. Every source sends the same number of equal-length
// packets to ONE destination. A fair fabric delivers every source's share; an
// unfair one starves somebody. The metric is the SPREAD of the per-source
// delivered counts, and the bound is that no source may deliver fewer than half
// of what the busiest source delivered once the run has drained — at which point
// a correct fabric has delivered ALL of them and the spread is zero, so the
// bound is loose on purpose and only fires on genuine starvation.
//
// The second half of the check is the switch's own metric: `tel_stage_maxwait`
// counts, per buffered head flit, the cycles on which the output it wanted
// granted somebody else. Round robin over RADIX inputs and N_VC channels means a
// head is overtaken at most (RADIX*N_VC - 1) packets' worth of flits before it
// wins, so the bound is RADIX*N_VC*PKT_MAX_FLITS with a factor of two for the
// two arbitration levels. A metric with no bound is not a metric.
// ---------------------------------------------------------------------------
void pass_hotspot(Device* dev) {
  constexpr unsigned kDest = 7;
  constexpr unsigned kPerSource = 6;
  constexpr unsigned kLen = 4;

  dev->clear_telemetry();

  // Earlier passes have already delivered packets to this port, so the shares
  // are measured as DELTAS. A baseline is not optional bookkeeping: without it
  // the metric reports the whole run's history and would pass whatever this pass
  // did.
  std::vector<std::size_t> base(kNPorts, 0);
  for (unsigned s = 0; s < kNPorts; ++s) {
    base[s] = dev->board().delivered_from(kDest, s);
  }

  for (unsigned rep = 0; rep < kPerSource; ++rep) {
    for (unsigned s = 0; s < kNPorts; ++s) {
      dev->enqueue(s, dev->make_packet(s, kDest, (s + rep) % kNVc,
                                       packet_model::kTypeDetection, kLen));
    }
  }
  if (!dev->run_until_drained(400000)) {
    fail("hang", &g_counters.hang, "hotspot traffic never drained");
  }
  absorb(dev, "hotspot");

  std::size_t lo = ~static_cast<std::size_t>(0);
  std::size_t hi = 0;
  for (unsigned s = 0; s < kNPorts; ++s) {
    const std::size_t n = dev->board().delivered_from(kDest, s) - base[s];
    if (n < lo) lo = n;
    if (n > hi) hi = n;
  }
  if (hi == 0) {
    fail("fairness", &g_counters.fairness,
         "the hotspot delivered nothing at all");
  } else if (lo * 2 < hi) {
    fail("fairness", &g_counters.fairness,
         "hotspot share spread: quietest source delivered " +
             std::to_string(lo) + ", busiest " + std::to_string(hi));
  }

  const unsigned bound =
      2 * packet_tb::kRadix * kNVc * packet_model::kMaxFlits;
  for (unsigned st = 0; st < packet_tb::kStages; ++st) {
    const unsigned w = dev->stage_maxwait(st);
    if (w > bound) {
      fail("fairness", &g_counters.fairness,
           "stage " + std::to_string(st) + " overtake metric " +
               std::to_string(w) + " exceeds the arbitration bound " +
               std::to_string(bound));
    }
  }
  std::printf("  hotspot: per-source delivered %zu..%zu, stage overtake bound %u\n",
              lo, hi, bound);
}

// ---------------------------------------------------------------------------
// pass 5 — virtual-channel isolation
//
// VC0 is disabled at egress `kDest` while traffic for that port runs on both
// VC0 and VC1. Every VC0 buffer on the path fills, its credits run out, and VC0
// stops dead; VC1 must be unaffected. The measurement is direct: every VC1
// packet injected must be delivered while VC0 is jammed.
//
// THE SOURCES ARE SPLIT, and that is what makes this a measurement of the FABRIC
// rather than of the testbench. An ingress port has one message interface, so a
// source that had a VC0 packet half-way through handing over would be stuck on
// that packet and could not offer its VC1 packets either — head-of-line blocking
// at the producer, which is real, is not what SPEC 7.8's virtual channels claim
// to fix, and would make the number here meaningless. Even ports therefore drive
// VC0 and odd ports drive VC1. The two classes share every link and every
// switch on the way to `kDest`, so the property under test — a jammed virtual
// channel does not consume the shared link — is asked cleanly.
// ---------------------------------------------------------------------------
void pass_vc_isolation(Device* dev) {
  constexpr unsigned kDest = 3;
  constexpr unsigned kPerSource = 4;
  constexpr unsigned kLen = 5;

  const std::size_t vc1_before = dev->board().delivered_on_vc(kDest, 1);

  // Enough VC0 traffic to fill every buffer on the path and then some.
  unsigned vc0_injected = 0;
  unsigned vc1_injected = 0;
  for (unsigned rep = 0; rep < kPerSource; ++rep) {
    for (unsigned s = 0; s < kNPorts; ++s) {
      if ((s % 2) == 0) {
        dev->enqueue(s, dev->make_packet(s, kDest, 0, packet_model::kTypeError,
                                         kLen));
        ++vc0_injected;
      } else {
        dev->enqueue(s, dev->make_packet(s, kDest, 1, packet_model::kTypePower,
                                         kLen));
        ++vc1_injected;
      }
    }
  }

  dev->set_vc_enable(kDest, 0, false);
  // Run long enough that every VC1 packet has had time to cross a fabric whose
  // VC0 is jammed solid.
  dev->run_cycles(30000);

  const std::size_t vc1_mid = dev->board().delivered_on_vc(kDest, 1);
  const std::size_t vc0_mid = dev->board().delivered_on_vc(kDest, 0);

  if (vc1_mid - vc1_before < vc1_injected) {
    fail("isolation", &g_counters.isolation,
         "VC1 delivered only " + std::to_string(vc1_mid - vc1_before) + " of " +
             std::to_string(vc1_injected) +
             " packets while VC0 was blocked: a stalled VC0 is blocking VC1");
  }
  std::printf("  vc isolation: VC0 blocked, VC1 delivered %zu/%u, VC0 %zu\n",
              vc1_mid - vc1_before, vc1_injected, vc0_mid);

  dev->set_vc_enable(kDest, 0, true);
  if (!dev->run_until_drained(400000)) {
    fail("hang", &g_counters.hang,
         "the fabric did not drain after VC0 was re-enabled");
  }
  absorb(dev, "vc isolation");
  (void)vc0_injected;
}

// ---------------------------------------------------------------------------
// pass 6 — backpressure invariance
// ---------------------------------------------------------------------------
void pass_invariance(Device* dev, std::mt19937_64 rng) {
  namespace pm = packet_model;
  std::uniform_int_distribution<unsigned> port(0, kNPorts - 1);
  std::uniform_int_distribution<unsigned> vc(0, kNVc - 1);
  std::uniform_int_distribution<unsigned> len(1, 5);

  struct Spec {
    unsigned src, dest, vc, len;
  };
  std::vector<Spec> plan;
  for (unsigned i = 0; i < 48; ++i) {
    plan.push_back({port(rng), port(rng), vc(rng), len(rng)});
  }

  const auto run_once = [&](double stall_p) {
    dev->reset();
    dev->set_stall_probability(stall_p);
    for (const Spec& s : plan) {
      dev->enqueue(s.src, dev->make_packet(s.src, s.dest, s.vc,
                                           pm::kTypeCounter, s.len));
    }
    const bool ok = dev->run_until_drained(400000);
    dev->set_stall_probability(0.0);
    return ok;
  };

  if (!run_once(0.0)) {
    fail("hang", &g_counters.hang, "invariance: dense run never drained");
  }
  const std::vector<std::string> dense = dev->delivery_log();

  if (!run_once(0.45)) {
    fail("hang", &g_counters.hang, "invariance: stalled run never drained");
  }
  const std::vector<std::string> stalled = dev->delivery_log();

  // Compare per (src, VC, dest): stalls may reorder ACROSS triples and that is
  // legal. Within one, the sequence must be identical.
  std::map<std::string, std::vector<std::string>> a, b;
  for (const std::string& s : dense) a[s.substr(0, s.find('#'))].push_back(s);
  for (const std::string& s : stalled) b[s.substr(0, s.find('#'))].push_back(s);
  if (a != b) {
    fail("invariance", &g_counters.invariance,
         "the delivered packet sequence differs between the dense and stalled "
         "runs within some (src, VC, dest)");
  }
  absorb(dev, "invariance");
}

// ---------------------------------------------------------------------------
// pass 7 — fault injection
// ---------------------------------------------------------------------------
void pass_faults(Device* dev) {
  namespace pm = packet_model;
  dev->reset();

  // ---- 7a: break one virtual channel's credit return ----------------------
  // Stage 0, global wire 0, VC 0. Every packet from source 0 on VC0 must stop;
  // traffic on VC1 from the same source, and everything from other sources, must
  // not.
  constexpr unsigned kSrc = 0;
  constexpr unsigned kDest = 9;
  // Deltas, not totals: earlier passes have already delivered to this port.
  const std::size_t vc0_base = dev->board().delivered_on_vc(kDest, 0);
  const std::size_t vc1_base = dev->board().delivered_on_vc(kDest, 1);

  for (unsigned i = 0; i < 4; ++i) {
    dev->enqueue(kSrc, dev->make_packet(kSrc, kDest, 0, pm::kTypeError, 3));
    dev->enqueue(kSrc, dev->make_packet(kSrc, kDest, 1, pm::kTypeError, 3));
  }

  dev->set_credit_kill(0, 0, 0, true);
  dev->run_cycles(6000);

  const std::size_t vc0_stuck =
      dev->board().delivered_on_vc(kDest, 0) - vc0_base;
  const std::size_t vc1_ok = dev->board().delivered_on_vc(kDest, 1) - vc1_base;

  if (vc1_ok == 0) {
    fail("fault", &g_counters.fault,
         "a broken VC0 credit return also stopped VC1");
  }
  if (vc0_stuck >= 4) {
    fail("fault", &g_counters.fault,
         "breaking the VC0 credit return changed nothing: the check that was "
         "supposed to catch it does not");
  }
  std::printf("  fault (credit kill): VC0 delivered %zu of 4, VC1 %zu of 4\n",
              vc0_stuck, vc1_ok);

  // ---- revert, and require a complete recovery ----------------------------
  dev->set_credit_kill(0, 0, 0, false);
  if (!dev->run_until_drained(400000)) {
    fail("fault", &g_counters.fault,
         "the fabric did not drain after the credit return was restored");
  }
  absorb(dev, "credit fault reverted");

  // ---- 7b: a two-bit payload corruption, which parity cannot see ----------
  // packet_pkg section 3 states that an even number of bit errors passes parity.
  // This proves it — the RTL raises no parity error at all — and proves that the
  // payload scoreboard catches it anyway, which is why the sequence number and
  // the word-for-word comparison exist.
  const std::size_t corrupt_before = dev->board().counts().corrupted;
  const std::size_t parity_before = dev->board().counts().parity;

  dev->enqueue(1, dev->make_packet(1, 4, 2, pm::kTypeRaw, 4));
  dev->arm_flip(1, /*two_bits=*/true);
  if (!dev->run_until_drained(400000)) {
    fail("hang", &g_counters.hang, "corrupted packet never drained");
  }
  dev->disarm_flip(1);

  const std::size_t corrupt_after = dev->board().counts().corrupted;
  const std::size_t parity_after = dev->board().counts().parity;

  if (corrupt_after == corrupt_before) {
    fail("fault", &g_counters.fault,
         "a two-bit payload corruption was not caught by the payload "
         "comparison");
  }
  if (parity_after != parity_before) {
    fail("fault", &g_counters.fault,
         "a two-bit corruption was reported as a parity error; parity is "
         "blind to even error counts by construction");
  }
  std::printf("  fault (2-bit flip): payload mismatches +%zu, parity errors +%zu\n",
              corrupt_after - corrupt_before, parity_after - parity_before);

  // The deliberate corruption is accounted for here rather than left to poison
  // the run's totals, and the RTL's sticky bits are cleared for the same reason.
  dev->board_mut().forgive_corruption(corrupt_after - corrupt_before);
  g_prev = dev->board().counts();
  dev->clear_telemetry();
  dev->reset();
}

// ---------------------------------------------------------------------------
// pass 8 — telemetry against an independent tally
// ---------------------------------------------------------------------------
void pass_telemetry(Device* dev, std::mt19937_64 rng) {
  std::uniform_int_distribution<unsigned> port(0, kNPorts - 1);
  std::uniform_int_distribution<unsigned> vc(0, kNVc - 1);
  std::uniform_int_distribution<unsigned> len(1, 4);

  dev->reset();
  dev->clear_telemetry();

  std::vector<unsigned> per_src(kNPorts, 0), per_dest(kNPorts, 0);
  for (unsigned i = 0; i < 96; ++i) {
    const unsigned s = port(rng);
    const unsigned d = port(rng);
    dev->enqueue(s, dev->make_packet(s, d, vc(rng),
                                     packet_model::kTypeCounter, len(rng)));
    ++per_src[s];
    ++per_dest[d];
  }
  if (!dev->run_until_drained(400000)) {
    fail("hang", &g_counters.hang, "telemetry traffic never drained");
  }
  absorb(dev, "telemetry");

  for (unsigned p = 0; p < kNPorts; ++p) {
    const std::uint32_t ing = dev->ingress_packets(p);
    const std::uint32_t egr = dev->egress_packets(p);
    if (ing != per_src[p]) {
      fail("telemetry", &g_counters.telemetry,
           "ingress " + std::to_string(p) + " counted " + std::to_string(ing) +
               " packets, the test injected " + std::to_string(per_src[p]));
    }
    if (egr != per_dest[p]) {
      fail("telemetry", &g_counters.telemetry,
           "egress " + std::to_string(p) + " counted " + std::to_string(egr) +
               " packets, the test addressed " + std::to_string(per_dest[p]));
    }
  }
}

}  // namespace

int harness::sim_test_main(const SimArgs& args) {
  const auto wall_start = std::chrono::steady_clock::now();

  ErrorCollector errors;
  g_errors = &errors;
  g_counters = Counters{};

  auto top = std::make_unique<Vpacket_top>();
  const harness::SeedSource seeds(args.seed);

  top->eval();
  pass_geometry(top.get());
  if (g_counters.config != 0) {
    std::printf("RESULT: FAIL seed=%llu test=%s config=%s reason=geometry\n",
                static_cast<unsigned long long>(args.seed), kTestName,
                sim_config::kName);
    return 1;
  }

  Device dev(top.get(), seeds.engine("packet.stalls"));
  dev.reset();

  pass_directed(&dev);
  pass_random(&dev, seeds.engine("packet.random.dense"), 96, 0.0, "random dense");
  pass_random(&dev, seeds.engine("packet.random.stall"), 96, 0.40,
              "random stalled");
  pass_hotspot(&dev);
  pass_vc_isolation(&dev);
  pass_invariance(&dev, seeds.engine("packet.invariance"));
  pass_faults(&dev);
  pass_telemetry(&dev, seeds.engine("packet.telemetry"));

  dev.board_mut().finish();
  absorb(&dev, "final");

  if (dev.board().counts().delivered == 0) {
    fail("loss", &g_counters.loss, "the run delivered no packets at all");
  }

  const bool passed = g_counters.total() == 0;

  std::printf("--- packet network ---\n");
  std::printf("  topology         : radix %u, %u stages, %u ports, %u VCs\n",
              packet_tb::kRadix, packet_tb::kStages, kNPorts, kNVc);
  std::printf("  flit             : %u payload + %u control bits\n", kPacketW,
              packet_model::kFlitCtrlW);
  std::printf("  cycles           : %llu\n",
              static_cast<unsigned long long>(dev.cycles()));
  std::printf("  packets injected : %zu\n", dev.board().injected());
  std::printf("  packets delivered: %zu\n", dev.board().counts().delivered);
  std::printf("  flits observed   : %llu\n",
              static_cast<unsigned long long>(dev.flits_seen()));
  std::printf("  loss/dup/corrupt : %zu / %zu / %zu\n", g_counters.loss,
              g_counters.dup, g_counters.corrupt);
  std::printf("  order/route      : %zu / %zu\n", g_counters.order,
              g_counters.route);
  std::printf("  framing/parity   : %zu / %zu\n", g_counters.framing,
              g_counters.parity);
  std::printf("  fairness         : %zu\n", g_counters.fairness);
  std::printf("  vc isolation     : %zu\n", g_counters.isolation);
  std::printf("  invariance       : %zu\n", g_counters.invariance);
  std::printf("  fault injection  : %zu\n", g_counters.fault);
  std::printf("  telemetry        : %zu\n", g_counters.telemetry);
  std::printf("  hangs            : %zu\n", g_counters.hang);

  if (!passed) {
    const std::vector<std::string>& notes = dev.board().notes();
    for (std::size_t i = 0; i < notes.size() && i < 16; ++i) {
      std::printf("  note: %s\n", notes[i].c_str());
    }
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
      passed ? "every delivered packet bit-exact and in order against the C++ model"
             : "packet-network mismatch; see errors_by_category";
  summary.passes = 8;
  summary.core_cycles = dev.cycles();
  summary.beats_observed = dev.flits_seen();
  summary.absorb(errors);
  summary.wall_time_s =
      std::chrono::duration<double>(wall_end - wall_start).count();
  const std::string written = summary.write(args.results_dir);
  if (!written.empty()) std::printf("  summary json     : %s\n", written.c_str());

  top->final();

  if (passed) {
    std::printf("RESULT: PASS seed=%llu test=%s config=%s packets=%zu\n",
                static_cast<unsigned long long>(args.seed), kTestName,
                sim_config::kName, dev.board().counts().delivered);
    return 0;
  }
  std::printf(
      "RESULT: FAIL seed=%llu test=%s config=%s loss=%zu dup=%zu corrupt=%zu "
      "order=%zu route=%zu framing=%zu parity=%zu fairness=%zu isolation=%zu "
      "invariance=%zu fault=%zu telemetry=%zu hang=%zu\n",
      static_cast<unsigned long long>(args.seed), kTestName, sim_config::kName,
      g_counters.loss, g_counters.dup, g_counters.corrupt, g_counters.order,
      g_counters.route, g_counters.framing, g_counters.parity,
      g_counters.fairness, g_counters.isolation, g_counters.invariance,
      g_counters.fault, g_counters.telemetry, g_counters.hang);
  return 1;
}
