// -----------------------------------------------------------------------------
// packet_tb.h — driver and monitor for sim/verilator/tops/packet_top.sv.
//
// Shared by sim/tests/test_packet.cpp (the positive suite) and
// sim/tests/test_packet_assertions.cpp (the negative one), so both drive the
// fabric through exactly the same protocol-correct machinery and any assertion
// that fires in the negative test is provably the DUT's doing rather than the
// testbench's — the same arrangement test_stream_assertions relies on.
//
// WHY THE PRODUCER MODEL HAS ONE QUEUE PER VIRTUAL CHANNEL
// --------------------------------------------------------
// An ingress port has ONE message interface, so whichever packet is being handed
// over occupies it until its last beat. If the driver kept a single queue per
// port, a packet on a jammed virtual channel would sit at the head of that queue
// and block every packet behind it — including packets on healthy channels —
// and the VC-isolation measurement would be reporting the TESTBENCH's
// head-of-line blocking rather than the fabric's.
//
// So the driver models what a real producer is: N_VC independent sources sharing
// one port. It keeps a queue per (port, VC), picks a channel at each packet
// boundary, and if the chosen packet's first beat is not accepted within a short
// window it picks a different channel instead. Ordering within a (port, VC) is
// strictly FIFO, which is what the fabric promises to preserve and what the
// scoreboard checks.
//
// The per-(port, VC) packet sequence numbers are assigned here, in the same
// order and by the same rule as rtl/packet/pkt_ingress.sv assigns them, and both
// are reset by `reset()`. A disagreement between the two would show up as
// reordering at the scoreboard, which is the point: the sequence number is only
// worth carrying if the model predicts it independently.
// -----------------------------------------------------------------------------
#ifndef HARNESS_PACKET_TB_H_
#define HARNESS_PACKET_TB_H_

#include <cstddef>
#include <cstdint>
#include <deque>
#include <random>
#include <string>
#include <type_traits>
#include <vector>

#include "Vpacket_top.h"
#include "verilated.h"

#include "config_sim.h"
#include "packet/packet_model.hpp"

namespace packet_tb {

// Mirror of sim/verilator/tops/packet_top.sv's elaboration. Checked against the
// RTL's cfg_* echo by the geometry pass before any stimulus runs.
constexpr unsigned kPacketW = sim_config::PACKET_W;
constexpr unsigned kNVc = sim_config::N_VIRTUAL_CHANS;
constexpr unsigned kRadix = 4;
constexpr unsigned kStages = 2;
constexpr unsigned kNPorts = kRadix * kRadix;  // kRadix ** kStages
constexpr unsigned kFlitW = kPacketW + packet_model::kFlitCtrlW;
constexpr unsigned kSlices = (kPacketW + 63) / 64;

static_assert(kStages == 2, "kNPorts is written for two stages");
static_assert(kNVc == packet_model::kNVc, "config N_VIRTUAL_CHANS moved");

// ---------------------------------------------------------------------------
// Bit accessors that work on every Verilator port type.
//
// A port narrower than 65 bits is a plain integer; a wider one is a VlWide word
// array. The tests address ports by (index, field width) and must not care
// which, because the widths follow PACKET_W and therefore follow the SPEC 11
// configuration.
// ---------------------------------------------------------------------------
template <typename T>
inline typename std::enable_if<std::is_integral<T>::value>::type sig_set(
    T& s, unsigned lsb, unsigned n, std::uint64_t v) {
  for (unsigned i = 0; i < n; ++i) {
    const std::uint64_t bit = 1ULL << (lsb + i);
    if (((v >> i) & 1ULL) != 0) {
      s = static_cast<T>(static_cast<std::uint64_t>(s) | bit);
    } else {
      s = static_cast<T>(static_cast<std::uint64_t>(s) & ~bit);
    }
  }
}

template <typename T>
inline typename std::enable_if<std::is_integral<T>::value, std::uint64_t>::type
sig_get(const T& s, unsigned lsb, unsigned n) {
  const std::uint64_t w = static_cast<std::uint64_t>(s);
  const std::uint64_t m = (n >= 64) ? ~0ULL : ((1ULL << n) - 1ULL);
  return (w >> lsb) & m;
}

template <std::size_t N>
inline void sig_set(VlWide<N>& s, unsigned lsb, unsigned n, std::uint64_t v) {
  for (unsigned i = 0; i < n; ++i) {
    const unsigned b = lsb + i;
    if (((v >> i) & 1ULL) != 0) {
      s[b / 32] |= (1u << (b % 32));
    } else {
      s[b / 32] &= ~(1u << (b % 32));
    }
  }
}

template <std::size_t N>
inline std::uint64_t sig_get(const VlWide<N>& s, unsigned lsb, unsigned n) {
  std::uint64_t v = 0;
  for (unsigned i = 0; i < n; ++i) {
    const unsigned b = lsb + i;
    if (((s[b / 32] >> (b % 32)) & 1u) != 0) v |= (1ULL << i);
  }
  return v;
}

// ---------------------------------------------------------------------------
// Device
// ---------------------------------------------------------------------------
class Device {
 public:
  Device(Vpacket_top* top, std::mt19937_64 rng)
      : top_(top),
        rng_(rng),
        board_(kPacketW, kRadix, kStages) {
    for (unsigned p = 0; p < kNPorts; ++p) {
      ports_.emplace_back();
    }
    idle_inputs();
    top_->m_ready = 0;
    top_->tel_clear = 0;
    sig_set(top_->fi_flip, 0, 32, 0);
    for (unsigned p = 0; p < kNPorts; ++p) {
      for (unsigned v = 0; v < kNVc; ++v) vc_en_[p][v] = true;
    }
    write_vc_en();
    clear_credit_kill();
  }

  // ---- clock ---------------------------------------------------------------
  void tick() {
    top_->clk = 0;
    top_->eval();
    top_->clk = 1;
    top_->eval();
    ++cycles_;
  }

  void reset() {
    idle_inputs();
    top_->rst_n = 0;
    for (int i = 0; i < 8; ++i) tick();
    top_->rst_n = 1;
    for (int i = 0; i < 4; ++i) tick();
    for (unsigned p = 0; p < kNPorts; ++p) {
      ports_[p] = Port{};
      for (unsigned v = 0; v < kNVc; ++v) seq_[p][v] = 0;
    }
    board_.clear_log();
  }

  std::uint64_t cycles() const { return cycles_; }
  std::uint64_t flits_seen() const { return flits_; }

  packet_model::Scoreboard& board_mut() { return board_; }
  const packet_model::Scoreboard& board() const { return board_; }
  std::vector<std::string> delivery_log() const { return board_.log(); }

  // ---- stimulus ------------------------------------------------------------
  void set_stall_probability(double p) { stall_p_ = p; }

  // Build a packet with deterministic, packet-unique payload content. The
  // sequence number is assigned by enqueue(), which is the only place that knows
  // the per-(port, VC) order the RTL will use.
  packet_model::Packet make_packet(unsigned src, unsigned dest, unsigned vc,
                                   unsigned ptype, unsigned len) {
    packet_model::Packet p;
    p.hdr.src = src;
    p.hdr.dest = dest;
    p.hdr.vc = vc;
    p.hdr.ptype = ptype;
    p.hdr.length = len;
    p.hdr.seq = 0;
    const std::uint64_t salt = ++salt_;
    for (unsigned f = 1; f < len; ++f) {
      std::vector<std::uint64_t> words;
      for (unsigned k = 0; k < kSlices; ++k) {
        std::uint64_t w = salt * 0x9E3779B97F4A7C15ULL +
                          static_cast<std::uint64_t>(f) * 0xBF58476D1CE4E5B9ULL +
                          static_cast<std::uint64_t>(k) * 0x94D049BB133111EBULL;
        w ^= w >> 31;
        const unsigned lo = k * 64;
        const unsigned n = (kPacketW - lo >= 64) ? 64 : (kPacketW - lo);
        w &= packet_model::mask_u64(n);
        words.push_back(w);
      }
      p.payload.push_back(words);
    }
    return p;
  }

  void enqueue(unsigned port, packet_model::Packet p) {
    p.hdr.src = port;
    p.hdr.seq = seq_[port][p.hdr.vc]++ & 0xFFFFu;
    board_.inject(p);
    ports_[port].q[p.hdr.vc].push_back(std::move(p));
  }

  // Enqueue a packet whose DECLARED length disagrees with the number of beats
  // that will be driven. Used only by the negative test; the scoreboard is not
  // told about it, because it is not a packet the fabric is expected to deliver.
  void enqueue_malformed(unsigned port, unsigned dest, unsigned vc,
                         unsigned declared_len, unsigned actual_beats) {
    packet_model::Packet p = make_packet(port, dest, vc,
                                         packet_model::kTypeError,
                                         actual_beats);
    p.hdr.src = port;
    p.hdr.seq = seq_[port][vc]++ & 0xFFFFu;
    p.hdr.length = declared_len;  // the lie
    ports_[port].q[vc].push_back(std::move(p));
  }

  // ---- egress controls -----------------------------------------------------
  void set_vc_enable(unsigned port, unsigned vc, bool on) {
    vc_en_[port][vc] = on;
    write_vc_en();
  }

  void arm_flip(unsigned port, bool two_bits) {
    sig_set(top_->fi_flip, port * 2, 2, two_bits ? 3u : 1u);
  }
  void disarm_flip(unsigned port) { sig_set(top_->fi_flip, port * 2, 2, 0u); }

  void set_credit_kill(unsigned stage, unsigned port, unsigned vc, bool on) {
    const unsigned bit = (stage * kNPorts + port) * kNVc + vc;
    sig_set(top_->fi_credit_kill, bit, 1, on ? 1u : 0u);
  }
  void clear_credit_kill() {
    for (unsigned i = 0; i < kStages * kNPorts * kNVc; ++i) {
      sig_set(top_->fi_credit_kill, i, 1, 0u);
    }
  }

  void clear_telemetry() {
    top_->tel_clear = 1;
    tick();
    tick();
    top_->tel_clear = 0;
    tick();
  }

  // ---- telemetry -----------------------------------------------------------
  std::uint32_t ingress_packets(unsigned p) const {
    return static_cast<std::uint32_t>(sig_get(top_->tel_ing_packets, p * 32, 32));
  }
  std::uint32_t egress_packets(unsigned p) const {
    return static_cast<std::uint32_t>(sig_get(top_->tel_egr_packets, p * 32, 32));
  }
  std::uint32_t stage_flits(unsigned s) const {
    return static_cast<std::uint32_t>(sig_get(top_->tel_stage_flits, s * 32, 32));
  }
  std::uint32_t stage_stall(unsigned s) const {
    return static_cast<std::uint32_t>(sig_get(top_->tel_stage_stall, s * 32, 32));
  }
  unsigned stage_maxwait(unsigned s) const {
    return static_cast<unsigned>(sig_get(top_->tel_stage_maxwait, s * 16, 16));
  }
  unsigned stage_hiwater(unsigned s) const {
    return static_cast<unsigned>(sig_get(top_->tel_stage_hiwater, s * 8, 8));
  }
  unsigned ingress_err(unsigned p) const {
    return static_cast<unsigned>(sig_get(top_->ing_err, p * 4, 4));
  }
  unsigned egress_err(unsigned p) const {
    return static_cast<unsigned>(sig_get(top_->egr_err, p * 5, 5));
  }

  // ---- run -----------------------------------------------------------------
  void run_cycles(std::uint64_t n) {
    for (std::uint64_t i = 0; i < n; ++i) step();
  }

  // Runs until every queue is empty, no packet is mid-transfer, and the egress
  // has been silent for long enough that anything still in the fabric would have
  // come out. Returns false on the budget, which is a hang.
  bool run_until_drained(std::uint64_t budget) {
    std::uint64_t quiet = 0;
    while (budget-- > 0) {
      const bool activity = step();
      if (activity || !all_idle()) {
        quiet = 0;
      } else if (++quiet >= kQuietCycles) {
        return true;
      }
    }
    return false;
  }

 private:
  static constexpr unsigned kQuietCycles = 400;
  // Cycles a packet's first beat may go unaccepted before the driver tries a
  // different virtual channel. Long enough that ordinary backpressure does not
  // trigger it, short enough that a jammed channel does not stall the port.
  static constexpr unsigned kSwitchAfter = 16;

  struct Port {
    std::deque<packet_model::Packet> q[packet_model::kNVc];
    bool active = false;
    unsigned vc = 0;       // channel currently being handed over
    unsigned beat = 0;     // 0 = header flit, 1.. = payload flits
    unsigned waited = 0;   // cycles the first beat has gone unaccepted
    unsigned rr = 0;       // round-robin pointer over the channels
  };

  void idle_inputs() {
    sig_set(top_->s_valid, 0, kNPorts, 0);
    sig_set(top_->s_sof, 0, kNPorts, 0);
    sig_set(top_->s_eof, 0, kNPorts, 0);
    top_->m_ready = 0;
  }

  void write_vc_en() {
    for (unsigned p = 0; p < kNPorts; ++p) {
      for (unsigned v = 0; v < kNVc; ++v) {
        sig_set(top_->m_vc_en, p * kNVc + v, 1, vc_en_[p][v] ? 1u : 0u);
      }
    }
  }

  bool all_idle() const {
    for (unsigned p = 0; p < kNPorts; ++p) {
      if (ports_[p].active) return false;
      for (unsigned v = 0; v < kNVc; ++v) {
        if (!ports_[p].q[v].empty()) return false;
      }
    }
    return true;
  }

  bool stall() { return stall_p_ > 0.0 && unit_(rng_) < stall_p_; }

  // Pick the next virtual channel with something to send, round robin.
  bool select_vc(Port* pt) {
    for (unsigned i = 0; i < kNVc; ++i) {
      const unsigned v = (pt->rr + i) % kNVc;
      if (!pt->q[v].empty()) {
        pt->vc = v;
        pt->rr = (v + 1) % kNVc;
        pt->beat = 0;
        pt->waited = 0;
        pt->active = true;
        return true;
      }
    }
    return false;
  }

  // One cycle: drive every ingress, sample every egress. Returns true when any
  // handshake happened, which is what run_until_drained uses to detect quiet.
  bool step() {
    bool activity = false;

    // ---- drive ingress -----------------------------------------------------
    bool drive[kNPorts];
    for (unsigned p = 0; p < kNPorts; ++p) {
      Port& pt = ports_[p];
      if (!pt.active) select_vc(&pt);

      drive[p] = false;
      if (pt.active && !stall()) {
        const packet_model::Packet& pk = pt.q[pt.vc].front();
        const unsigned len = pk.hdr.length;
        const unsigned beats = 1 + static_cast<unsigned>(pk.payload.size());
        drive[p] = true;
        sig_set(top_->s_sof, p, 1, (pt.beat == 0) ? 1u : 0u);
        sig_set(top_->s_eof, p, 1, (pt.beat + 1 == beats) ? 1u : 0u);
        sig_set(top_->s_dest, p * packet_model::kDestW, packet_model::kDestW,
                pk.hdr.dest);
        sig_set(top_->s_type, p * packet_model::kTypeW, packet_model::kTypeW,
                pk.hdr.ptype);
        sig_set(top_->s_vc, p * packet_model::kVcW, packet_model::kVcW,
                pk.hdr.vc);
        sig_set(top_->s_len, p * packet_model::kLenW, packet_model::kLenW, len);
        for (unsigned k = 0; k < kSlices; ++k) {
          const unsigned lo = k * 64;
          const unsigned n = (kPacketW - lo >= 64) ? 64 : (kPacketW - lo);
          const std::uint64_t w =
              (pt.beat == 0) ? 0ULL : pk.payload[pt.beat - 1][k];
          sig_set(top_->s_data, p * kPacketW + lo, n, w);
        }
      }
      sig_set(top_->s_valid, p, 1, drive[p] ? 1u : 0u);
    }

    // ---- egress ready ------------------------------------------------------
    for (unsigned p = 0; p < kNPorts; ++p) {
      sig_set(top_->m_ready, p, 1, stall() ? 0u : 1u);
    }

    top_->eval();

    // ---- sample on the settled combinational state, before the edge ---------
    for (unsigned p = 0; p < kNPorts; ++p) {
      const bool mv = sig_get(top_->m_valid, p, 1) != 0;
      const bool mr = sig_get(top_->m_ready, p, 1) != 0;
      if (mv && mr) {
        packet_model::Flit f;
        f.resize_for(kPacketW);
        for (unsigned w = 0; w * 32 < kFlitW; ++w) {
          const unsigned lo = w * 32;
          const unsigned n = (kFlitW - lo >= 32) ? 32 : (kFlitW - lo);
          f.w[w] = static_cast<std::uint32_t>(
              sig_get(top_->m_flit, p * kFlitW + lo, n));
        }
        board_.observe(p, f);
        ++flits_;
        activity = true;
      }
    }

    bool taken[kNPorts];
    for (unsigned p = 0; p < kNPorts; ++p) {
      taken[p] = drive[p] && (sig_get(top_->s_ready, p, 1) != 0);
      if (taken[p]) activity = true;
    }

    tick();

    // ---- advance the producers ---------------------------------------------
    for (unsigned p = 0; p < kNPorts; ++p) {
      Port& pt = ports_[p];
      if (!pt.active) continue;
      if (taken[p]) {
        const unsigned beats =
            1 + static_cast<unsigned>(pt.q[pt.vc].front().payload.size());
        ++pt.beat;
        pt.waited = 0;
        if (pt.beat >= beats) {
          pt.q[pt.vc].pop_front();
          pt.active = false;
        }
      } else if (pt.beat == 0) {
        // The first beat has not been accepted. After a while, assume this
        // channel is jammed and offer a different one — see the header.
        if (++pt.waited >= kSwitchAfter) {
          pt.active = false;
          pt.waited = 0;
        }
      }
    }

    return activity;
  }

  Vpacket_top* top_;
  std::mt19937_64 rng_;
  std::uniform_real_distribution<double> unit_{0.0, 1.0};
  packet_model::Scoreboard board_;
  std::vector<Port> ports_;
  unsigned seq_[kNPorts][packet_model::kNVc] = {};
  bool vc_en_[kNPorts][packet_model::kNVc] = {};
  double stall_p_ = 0.0;
  std::uint64_t cycles_ = 0;
  std::uint64_t flits_ = 0;
  std::uint64_t salt_ = 0;
};

}  // namespace packet_tb

#endif  // HARNESS_PACKET_TB_H_
