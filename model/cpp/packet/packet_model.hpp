// -----------------------------------------------------------------------------
// packet_model.hpp — functional reference model and scoreboard for the SPEC 7.8
// packet network (issue #18).
//
// Header-only, no dependency on Verilator, and buildable on its own with the
// issue #4 -Wall -Wextra -Werror contract, so it can be checked before it is
// trusted as an oracle (SPEC 12.4).
//
// WHAT THIS MODEL IS, AND WHAT IT DELIBERATELY IS NOT
// ---------------------------------------------------
// It is FUNCTIONAL, not cycle accurate — the same choice cfar_model.hpp made
// (DECISIONS.md issue #14 decision 11) and for a stronger version of the same
// reason. The fabric's subject is DELIVERY: which packets come out, at which
// port, in what order, with what contents. Its cycle-by-cycle behaviour is a
// function of arbitration state, credit round trips and the testbench's stall
// profile, all three of which SPEC 23 explicitly invites changing for timing
// closure. A cycle-accurate model would have to be re-derived every time a
// pipeline register moved, and every such edit is a chance to make the model
// agree with a bug.
//
// So this model states four properties and checks them exactly:
//
//   1. ROUTING DETERMINISM. `route_path()` reproduces the butterfly's
//      destination-tag routing digit by digit and asserts that the path ends at
//      the destination named in the header. A packet delivered to any other port
//      is a routing failure, and the model — not only the RTL's own egress check
//      — says so.
//
//   2. ORDERING. Packets are in order within a (source, VC, destination) triple,
//      because the topology gives that triple exactly one path and a VC lock
//      keeps one packet's flits contiguous on it. Ordering ACROSS VCs is not
//      claimed and is not checked: two packets from one source to one
//      destination on different channels may be delivered in either order. A
//      scoreboard that demanded global order would fail a correct fabric.
//
//   3. INTEGRITY. Every delivered packet's payload is compared word for word
//      against what was injected, and its header field for field. Not a
//      checksum: the words themselves.
//
//   4. CONSERVATION. Every injected packet is delivered exactly once. Loss and
//      duplication are separate counts, because they have different causes: a
//      lost packet is a buffer or credit fault, a duplicated one is an
//      arbitration or lock fault, and summing them into "mismatch" would throw
//      away the diagnosis.
//
// CREDIT CONSERVATION is NOT modelled here, and that is deliberate rather than
// an omission. Credits are a per-link invariant with no end-to-end observable,
// so the honest place to check them is inside the RTL on every cycle, which is
// where they are checked: pkt_ingress's a_pkt_credit_bound and
// a_pkt_credit_no_underflow, pkt_switch_stage's a_sw_credit_bound and
// a_sw_no_overrun, pkt_egress's a_egr_no_overrun. What this model contributes to
// the same question is the end-to-end consequence: if a credit is ever lost, a
// packet is never delivered, and `report()` says which one.
// -----------------------------------------------------------------------------
#ifndef MODEL_CPP_PACKET_PACKET_MODEL_HPP_
#define MODEL_CPP_PACKET_PACKET_MODEL_HPP_

#include <cstddef>
#include <cstdint>
#include <map>
#include <string>
#include <vector>

namespace packet_model {

// ---------------------------------------------------------------------------
// Mirror of rtl/packages/packet_pkg.sv.
//
// Every constant here is echoed by sim/verilator/tops/packet_top.sv and checked
// against the RTL before any stimulus runs. A layout change the model did not
// follow is therefore a named failure rather than a wrong comparison — the same
// arrangement cfar_model.hpp uses.
// ---------------------------------------------------------------------------
constexpr unsigned kDestW = 4;
constexpr unsigned kSrcW = 5;
constexpr unsigned kVcW = 2;
constexpr unsigned kTypeW = 3;
constexpr unsigned kLenW = 6;
constexpr unsigned kSeqW = 16;
constexpr unsigned kHdrW = kDestW + kSrcW + kVcW + kTypeW + kLenW + kSeqW;  // 36

constexpr unsigned kNVc = 4;
constexpr unsigned kMaxFlits = 32;
constexpr unsigned kFlitCtrlW = 1 + kVcW + 1 + 1;  // 5

// Flit control offsets (packet_pkg section 1).
constexpr unsigned kFlitParityLsb = 0;
constexpr unsigned kFlitVcLsb = 1;
constexpr unsigned kFlitSofLsb = kFlitVcLsb + kVcW;   // 3
constexpr unsigned kFlitEofLsb = kFlitSofLsb + 1;     // 4
constexpr unsigned kFlitDataLsb = kFlitEofLsb + 1;    // 5

// Header field offsets (packet_pkg section 2).
constexpr unsigned kHdrDestLsb = 0;
constexpr unsigned kHdrSrcLsb = kHdrDestLsb + kDestW;   // 4
constexpr unsigned kHdrVcLsb = kHdrSrcLsb + kSrcW;      // 9
constexpr unsigned kHdrTypeLsb = kHdrVcLsb + kVcW;      // 11
constexpr unsigned kHdrLenLsb = kHdrTypeLsb + kTypeW;   // 14
constexpr unsigned kHdrSeqLsb = kHdrLenLsb + kLenW;     // 20

enum PacketType : unsigned {
  kTypeDetection = 0,
  kTypePower = 1,
  kTypeCovar = 2,
  kTypeError = 3,
  kTypeCounter = 4,
  kTypeRaw = 5,
};

inline bool type_legal(unsigned t) { return t <= kTypeRaw; }
inline bool length_legal(unsigned l) { return l >= 1 && l <= kMaxFlits; }

// cfar_pkg::CFAR_EVENT_W. Mirrored rather than included, and checked against the
// RTL's echo, because model/cpp/cfar/cfar_model.hpp is a different unit and this
// header must build on its own.
constexpr unsigned kDetectionPayloadW = 176;

inline unsigned payload_flits(unsigned bits, unsigned packet_w) {
  if (packet_w == 0) return 0;
  return (bits + packet_w - 1) / packet_w;
}
inline unsigned total_flits(unsigned bits, unsigned packet_w) {
  return 1 + payload_flits(bits, packet_w);
}
inline unsigned detection_flits(unsigned packet_w) {
  return total_flits(kDetectionPayloadW, packet_w);
}

// ---------------------------------------------------------------------------
// Header
// ---------------------------------------------------------------------------
struct Header {
  unsigned dest = 0;
  unsigned src = 0;
  unsigned vc = 0;
  unsigned ptype = 0;
  unsigned length = 1;  // TOTAL flits, header included
  unsigned seq = 0;

  bool operator==(const Header& o) const {
    return dest == o.dest && src == o.src && vc == o.vc && ptype == o.ptype &&
           length == o.length && seq == o.seq;
  }
};

inline std::uint64_t mask_u64(unsigned w) {
  return (w >= 64) ? ~0ULL : ((1ULL << w) - 1ULL);
}

inline std::uint64_t hdr_pack(const Header& h) {
  std::uint64_t p = 0;
  p |= (static_cast<std::uint64_t>(h.dest) & mask_u64(kDestW)) << kHdrDestLsb;
  p |= (static_cast<std::uint64_t>(h.src) & mask_u64(kSrcW)) << kHdrSrcLsb;
  p |= (static_cast<std::uint64_t>(h.vc) & mask_u64(kVcW)) << kHdrVcLsb;
  p |= (static_cast<std::uint64_t>(h.ptype) & mask_u64(kTypeW)) << kHdrTypeLsb;
  p |= (static_cast<std::uint64_t>(h.length) & mask_u64(kLenW)) << kHdrLenLsb;
  p |= (static_cast<std::uint64_t>(h.seq) & mask_u64(kSeqW)) << kHdrSeqLsb;
  return p;
}

inline Header hdr_unpack(std::uint64_t p) {
  Header h;
  h.dest = static_cast<unsigned>((p >> kHdrDestLsb) & mask_u64(kDestW));
  h.src = static_cast<unsigned>((p >> kHdrSrcLsb) & mask_u64(kSrcW));
  h.vc = static_cast<unsigned>((p >> kHdrVcLsb) & mask_u64(kVcW));
  h.ptype = static_cast<unsigned>((p >> kHdrTypeLsb) & mask_u64(kTypeW));
  h.length = static_cast<unsigned>((p >> kHdrLenLsb) & mask_u64(kLenW));
  h.seq = static_cast<unsigned>((p >> kHdrSeqLsb) & mask_u64(kSeqW));
  return h;
}

// ---------------------------------------------------------------------------
// Flit
//
// Held as a little-endian word vector so PACKET_W can be 512 without a bignum:
// word 0 holds bits 63..0 of the flit (control bits included), and `data_word(i)`
// pulls the i-th PACKET_W-bit payload word out of it.
// ---------------------------------------------------------------------------
struct Flit {
  std::vector<std::uint32_t> w;  // 32-bit words, little endian
  unsigned packet_w = 64;

  unsigned flit_w() const { return packet_w + kFlitCtrlW; }

  void resize_for(unsigned pw) {
    packet_w = pw;
    w.assign((flit_w() + 31) / 32, 0);
  }

  bool bit(unsigned i) const {
    if (i / 32 >= w.size()) return false;
    return ((w[i / 32] >> (i % 32)) & 1u) != 0;
  }
  void set_bit(unsigned i, bool v) {
    if (i / 32 >= w.size()) return;
    if (v) {
      w[i / 32] |= (1u << (i % 32));
    } else {
      w[i / 32] &= ~(1u << (i % 32));
    }
  }

  // `n` bits starting at `lsb`, n <= 64.
  std::uint64_t field(unsigned lsb, unsigned n) const {
    std::uint64_t v = 0;
    for (unsigned i = 0; i < n; ++i) {
      if (bit(lsb + i)) v |= (1ULL << i);
    }
    return v;
  }
  void set_field(unsigned lsb, unsigned n, std::uint64_t v) {
    for (unsigned i = 0; i < n; ++i) set_bit(lsb + i, ((v >> i) & 1ULL) != 0);
  }

  unsigned vc() const { return static_cast<unsigned>(field(kFlitVcLsb, kVcW)); }
  bool sof() const { return bit(kFlitSofLsb); }
  bool eof() const { return bit(kFlitEofLsb); }
  bool parity_bit() const { return bit(kFlitParityLsb); }

  // Odd parity over the whole flit: a correct flit has an odd population count.
  bool parity_ok() const {
    unsigned n = 0;
    for (unsigned i = 0; i < flit_w(); ++i)
      if (bit(i)) ++n;
    return (n & 1u) != 0;
  }

  // The payload word this flit carries, as up to 64 bits at a time. `k` selects
  // which 64-bit slice of a wide PACKET_W to read.
  std::uint64_t data64(unsigned k) const {
    const unsigned lo = k * 64;
    if (lo >= packet_w) return 0;
    const unsigned n = (packet_w - lo >= 64) ? 64 : (packet_w - lo);
    return field(kFlitDataLsb + lo, n);
  }

  Header header() const { return hdr_unpack(data64(0) & mask_u64(kHdrW)); }
};

// Build a sealed flit. `data` is the payload in 64-bit little-endian slices.
inline Flit make_flit(unsigned packet_w, unsigned vc, bool sof, bool eof,
                      const std::vector<std::uint64_t>& data) {
  Flit f;
  f.resize_for(packet_w);
  f.set_field(kFlitVcLsb, kVcW, vc);
  f.set_bit(kFlitSofLsb, sof);
  f.set_bit(kFlitEofLsb, eof);
  for (unsigned k = 0; k * 64 < packet_w; ++k) {
    const unsigned lo = k * 64;
    const unsigned n = (packet_w - lo >= 64) ? 64 : (packet_w - lo);
    const std::uint64_t v = (k < data.size()) ? data[k] : 0ULL;
    f.set_field(kFlitDataLsb + lo, n, v & mask_u64(n));
  }
  // Seal: odd parity.
  unsigned n = 0;
  for (unsigned i = 0; i < f.flit_w(); ++i)
    if (f.bit(i)) ++n;
  f.set_bit(kFlitParityLsb, (n & 1u) == 0);
  return f;
}

// ---------------------------------------------------------------------------
// Routing (property 1)
// ---------------------------------------------------------------------------
inline unsigned ipow(unsigned r, unsigned e) {
  unsigned v = 1;
  for (unsigned i = 0; i < e; ++i) v *= r;
  return v;
}

inline unsigned bfly_insert(unsigned rest, unsigned d, unsigned pos,
                            unsigned radix) {
  const unsigned scale = ipow(radix, pos);
  const unsigned low = rest % scale;
  const unsigned high = rest / scale;
  return high * scale * radix + d * scale + low;
}

inline unsigned digit(unsigned value, unsigned pos, unsigned radix) {
  return (value / ipow(radix, pos)) % radix;
}

// The sequence of global wire indices a packet from `src` to `dest` occupies:
// path[0] = src, path[s+1] = the wire out of stage s. The last element must be
// `dest` — that IS the determinism property, and route_path_ok() checks it.
inline std::vector<unsigned> route_path(unsigned src, unsigned dest,
                                        unsigned radix, unsigned stages) {
  std::vector<unsigned> path;
  path.push_back(src);
  unsigned cur = src;
  for (unsigned s = 0; s < stages; ++s) {
    const unsigned dig = stages - 1 - s;
    // Switch at stage s is the current index with digit `dig` deleted.
    const unsigned scale = ipow(radix, dig);
    const unsigned low = cur % scale;
    const unsigned high = cur / (scale * radix);
    const unsigned sw = high * scale + low;
    const unsigned out = digit(dest, dig, radix);
    cur = bfly_insert(sw, out, dig, radix);
    path.push_back(cur);
  }
  return path;
}

inline bool route_path_ok(unsigned src, unsigned dest, unsigned radix,
                          unsigned stages) {
  const std::vector<unsigned> p = route_path(src, dest, radix, stages);
  return !p.empty() && p.back() == dest;
}

// ---------------------------------------------------------------------------
// Packets
// ---------------------------------------------------------------------------
struct Packet {
  Header hdr;
  // Payload words, one entry per payload flit, each a vector of 64-bit slices.
  std::vector<std::vector<std::uint64_t>> payload;

  unsigned flits() const { return 1 + static_cast<unsigned>(payload.size()); }
};

// ---------------------------------------------------------------------------
// Scoreboard (properties 2, 3, 4)
// ---------------------------------------------------------------------------
struct Counts {
  std::size_t delivered = 0;
  std::size_t lost = 0;
  std::size_t duplicated = 0;
  std::size_t misrouted = 0;
  std::size_t corrupted = 0;
  std::size_t reordered = 0;
  std::size_t framing = 0;
  std::size_t parity = 0;
  std::size_t unexpected = 0;

  std::size_t total_errors() const {
    return lost + duplicated + misrouted + corrupted + reordered + framing +
           parity + unexpected;
  }
};

class Scoreboard {
 public:
  Scoreboard(unsigned packet_w, unsigned radix, unsigned stages)
      : packet_w_(packet_w), radix_(radix), stages_(stages) {}

  // Called when the testbench commits a packet to an ingress port.
  void inject(const Packet& p) {
    const Key k{p.hdr.src, p.hdr.vc, p.hdr.dest};
    expected_[k].push_back(p);
    ++injected_;
    if (!route_path_ok(p.hdr.src, p.hdr.dest, radix_, stages_)) {
      ++counts_.misrouted;
      note("injected packet src=" + std::to_string(p.hdr.src) + " dest=" +
           std::to_string(p.hdr.dest) + " has no deterministic route");
    }
  }

  // Called for every flit the testbench accepts at egress port `port`.
  void observe(unsigned port, const Flit& f) {
    if (!f.parity_ok()) {
      ++counts_.parity;
      note("flit at egress " + std::to_string(port) + " failed parity");
    }
    const unsigned vc = f.vc();
    Open& o = open_[{port, vc}];

    if (f.sof()) {
      if (o.active) {
        ++counts_.framing;
        note("SOF inside an open packet at egress " + std::to_string(port) +
             " VC " + std::to_string(vc));
      }
      o = Open{};
      o.active = true;
      o.hdr = f.header();
      o.remaining = (o.hdr.length > 1) ? (o.hdr.length - 1) : 0;
      if (!length_legal(o.hdr.length)) {
        ++counts_.framing;
        note("illegal declared length " + std::to_string(o.hdr.length));
      }
      if (o.hdr.dest != port) {
        ++counts_.misrouted;
        note("packet for dest " + std::to_string(o.hdr.dest) +
             " arrived at egress " + std::to_string(port));
      }
      if (o.hdr.vc != vc) {
        ++counts_.framing;
        note("header VC " + std::to_string(o.hdr.vc) + " but flit VC " +
             std::to_string(vc));
      }
      if (!type_legal(o.hdr.ptype)) {
        ++counts_.framing;
        note("reserved packet type " + std::to_string(o.hdr.ptype));
      }
      if (f.eof() != (o.hdr.length == 1)) {
        ++counts_.framing;
        note("header EOF disagrees with a declared length of " +
             std::to_string(o.hdr.length));
      }
      if (o.remaining == 0) complete(port, &o);
      return;
    }

    if (!o.active) {
      ++counts_.framing;
      note("body flit with no open packet at egress " + std::to_string(port) +
           " VC " + std::to_string(vc));
      return;
    }

    std::vector<std::uint64_t> words;
    for (unsigned k = 0; k * 64 < packet_w_; ++k) words.push_back(f.data64(k));
    o.payload.push_back(words);

    if (o.remaining > 0) --o.remaining;

    if (f.eof()) {
      if (o.remaining != 0) {
        ++counts_.framing;
        note("EOF with " + std::to_string(o.remaining) + " flits still expected");
      }
      complete(port, &o);
    } else if (o.remaining == 0) {
      ++counts_.framing;
      note("packet ran past its declared length at egress " +
           std::to_string(port));
    }
  }

  // Called once the run has drained. Anything still expected is lost.
  void finish() {
    for (const auto& kv : expected_) {
      for (const Packet& p : kv.second) {
        ++counts_.lost;
        note("never delivered: src=" + std::to_string(p.hdr.src) + " vc=" +
             std::to_string(p.hdr.vc) + " dest=" + std::to_string(p.hdr.dest) +
             " seq=" + std::to_string(p.hdr.seq));
      }
    }
    for (const auto& kv : open_) {
      if (kv.second.active) {
        ++counts_.framing;
        note("packet still open at egress " + std::to_string(kv.first.first) +
             " VC " + std::to_string(kv.first.second) + " at end of run");
      }
    }
  }

  const Counts& counts() const { return counts_; }
  std::size_t injected() const { return injected_; }
  const std::vector<std::string>& notes() const { return notes_; }

  // Delivery log: one "src.vc.dest#seq" entry per completed packet, in the order
  // the egress produced them. The backpressure-invariance pass compares two runs
  // through this, grouped by triple — stalls may reorder ACROSS triples and that
  // is legal, so a flat comparison would fail a correct fabric.
  const std::vector<std::string>& log() const { return log_; }
  void clear_log() { log_.clear(); }

  // Discount corruption that the test INJECTED on purpose, so a deliberate
  // fault does not poison the run's totals. Only the fault-injection pass calls
  // it, and only for the exact number of corruptions it caused.
  void forgive_corruption(std::size_t n) {
    counts_.corrupted = (counts_.corrupted > n) ? (counts_.corrupted - n) : 0;
  }

  // Per-egress, per-source delivered packet counts. The hotspot fairness metric
  // is computed from this: with every source targeting one destination, a fair
  // fabric delivers comparable numbers from each.
  std::size_t delivered_from(unsigned port, unsigned src) const {
    const auto it = per_src_.find({port, src});
    return (it == per_src_.end()) ? 0 : it->second;
  }
  std::size_t delivered_on_vc(unsigned port, unsigned vc) const {
    const auto it = per_vc_.find({port, vc});
    return (it == per_vc_.end()) ? 0 : it->second;
  }

 private:
  struct Key {
    unsigned src, vc, dest;
    bool operator<(const Key& o) const {
      if (src != o.src) return src < o.src;
      if (vc != o.vc) return vc < o.vc;
      return dest < o.dest;
    }
  };

  struct Open {
    bool active = false;
    Header hdr;
    unsigned remaining = 0;
    std::vector<std::vector<std::uint64_t>> payload;
  };

  void note(const std::string& s) {
    if (notes_.size() < 64) notes_.push_back(s);
  }

  void complete(unsigned port, Open* o) {
    const Header h = o->hdr;
    const Key k{h.src, h.vc, h.dest};
    auto it = expected_.find(k);
    if (it == expected_.end() || it->second.empty()) {
      ++counts_.unexpected;
      note("delivered a packet nobody injected: src=" + std::to_string(h.src) +
           " vc=" + std::to_string(h.vc) + " dest=" + std::to_string(h.dest) +
           " seq=" + std::to_string(h.seq));
      o->active = false;
      return;
    }

    // ORDERING (property 2): within a (source, VC, destination) triple the head
    // of the expected queue is the only legal next delivery. If the delivered
    // packet is somewhere else in the queue, it arrived out of order — which is
    // reported as reordering AND consumed, so one displacement does not cascade
    // into a report of every later packet being wrong too.
    std::size_t idx = 0;
    bool found = false;
    for (std::size_t i = 0; i < it->second.size(); ++i) {
      if (it->second[i].hdr.seq == h.seq) {
        idx = i;
        found = true;
        break;
      }
    }
    if (!found) {
      ++counts_.duplicated;
      note("duplicate or unknown seq " + std::to_string(h.seq) + " for src=" +
           std::to_string(h.src) + " vc=" + std::to_string(h.vc) + " dest=" +
           std::to_string(h.dest));
      o->active = false;
      return;
    }
    if (idx != 0) {
      ++counts_.reordered;
      note("out of order within (src=" + std::to_string(h.src) + ",vc=" +
           std::to_string(h.vc) + ",dest=" + std::to_string(h.dest) +
           "): seq " + std::to_string(h.seq) + " arrived " +
           std::to_string(idx) + " early");
    }

    const Packet& want = it->second[idx];

    // INTEGRITY (property 3): header field for field, payload word for word.
    if (!(want.hdr == h)) {
      ++counts_.corrupted;
      note("header mismatch for seq " + std::to_string(h.seq));
    } else if (want.payload.size() != o->payload.size()) {
      ++counts_.corrupted;
      note("payload flit count " + std::to_string(o->payload.size()) +
           " but expected " + std::to_string(want.payload.size()));
    } else {
      for (std::size_t i = 0; i < want.payload.size() && i < o->payload.size();
           ++i) {
        if (want.payload[i] != o->payload[i]) {
          ++counts_.corrupted;
          note("payload word " + std::to_string(i) + " of seq " +
               std::to_string(h.seq) + " differs");
          break;
        }
      }
    }

    it->second.erase(it->second.begin() + static_cast<std::ptrdiff_t>(idx));
    ++counts_.delivered;
    ++per_src_[{port, h.src}];
    ++per_vc_[{port, h.vc}];
    log_.push_back(std::to_string(h.src) + "." + std::to_string(h.vc) + "." +
                   std::to_string(h.dest) + "#" + std::to_string(h.seq));
    o->active = false;
  }

  unsigned packet_w_;
  unsigned radix_;
  unsigned stages_;
  std::size_t injected_ = 0;
  Counts counts_;
  std::map<Key, std::vector<Packet>> expected_;
  std::map<std::pair<unsigned, unsigned>, Open> open_;
  std::map<std::pair<unsigned, unsigned>, std::size_t> per_src_;
  std::map<std::pair<unsigned, unsigned>, std::size_t> per_vc_;
  std::vector<std::string> notes_;
  std::vector<std::string> log_;
};

}  // namespace packet_model

#endif  // MODEL_CPP_PACKET_PACKET_MODEL_HPP_
