// -----------------------------------------------------------------------------
// packet_pkg — packet format, flit-isation rules and topology arithmetic of the
// SPEC.md 7.8 event aggregator and packet network (issue #18).
//
// SPEC 7.8 asks for a packet network carrying detection events, power summaries,
// covariance summaries, error events, performance counters and optional raw
// capture across "16 or more ingress ports, 512-bit packet width, 4 virtual
// channels, pipelined arbitration, credit or ready/valid flow control", built as
// a pipelined multistage fabric rather than one unregistered crossbar. This
// package is the one place where the PACKET HEADER, the FLIT layout, the
// PARITY rule, the length invariants and the BUTTERFLY wiring arithmetic are
// defined. The flow-control mechanism, the arbitration and the buffering live in
// rtl/packet/; none of them re-derives a field offset or a port index.
//
// Naming (DECISIONS.md issue #10 decision 9, applied a fifth time)
// ----------------------------------------------------------------
// The integer helper type is `pkt_uint_t`, NOT `uint_t`. fxp_pkg, stream_pkg,
// covar_pkg and cfar_pkg already export a type of that name; a fifth one is
// ambiguous under IEEE 1800-2017 26.3 in any module that wildcard-imports two of
// them. Quartus Prime Pro rejects that outright and Verilator accepts it
// silently. One package, one spelling.
//
// -----------------------------------------------------------------------------
// 1. What a packet is, and where its width comes from
// -----------------------------------------------------------------------------
// A PACKET is 1..PKT_MAX_FLITS flits. The first flit is the HEADER flit and
// carries no payload; the remaining flits carry the payload, PACKET_W bits at a
// time, least significant word first. PACKET_W is a SPEC 11 sized parameter
// (config/*.json: tiny 64 ... full_agmf039 512), so the same RTL elaborates at
// every configuration and only the flit count of a given payload changes.
//
// A FLIT is what the fabric actually moves in one cycle:
//
//   MSB                                                     LSB
//   +-----------------------+-----+-----+------+--------+
//   |         data          | eof | sof |  vc  | parity |
//   +-----------------------+-----+-----+------+--------+
//        PACKET_W              1     1     2       1
//
// The CONTROL bits are at the BOTTOM and the variable-width data field at the
// top, which is the field-order rule stream_pkg states and for the same reason
// inverted: here it is the CONTROL fields whose offsets must not move when
// PACKET_W changes between SPEC 11 sizes, because every checker, every FIFO tap
// and the C++ mirror address them by constant offset. `data` is the only field
// whose width is a configuration parameter, so it is the one that goes on top.
//
// -----------------------------------------------------------------------------
// 2. The header, and why it is CONFIGURATION-INDEPENDENT
// -----------------------------------------------------------------------------
//   MSB                                                              LSB
//   +---------+--------+--------+--------+--------+--------+
//   |   seq   | length |  type  |   vc   |  src   |  dest  |
//   +---------+--------+--------+--------+--------+--------+
//       16        6        3        2        5        4      = 36 bits
//
// Every width above is a constant of this package; none is an elaboration
// parameter. That is deliberate and is the same argument cfar_pkg makes for its
// 176-bit detection event: a header that changed shape with FFT_SIZE or with
// PACKET_W would have to be renegotiated at every SPEC 11 size, and the software
// that decodes a captured packet would need a build-time header to do it. The
// header therefore occupies the low PKT_HDR_W bits of the header flit's data
// field and the rest of that flit is reserved zero. `pkt_hdr_fits()` is the
// elaboration check that PKT_HDR_W <= PACKET_W; it holds at the tiny 64-bit
// configuration with 28 bits to spare and at 512 with 476.
//
// Field sizing:
//   dest    4 bits, 16 egress ports — the SPEC 7.8 nominal network.
//   src     5 bits, 32 ingress ports — SPEC 7.8 says "16 or more", so the
//           source field is deliberately one binade wider than the destination
//           field. Aggregation fans IN; it does not fan out.
//   vc      2 bits, N_VC = 4 (config N_VIRTUAL_CHANS, a SPEC 3 invariant).
//   type    3 bits. Six kinds are defined (below) and two values are reserved;
//           `pkt_type_legal()` is what makes the reserved values a checkable
//           error rather than an undefined behaviour.
//   length  6 bits, the packet's TOTAL flit count INCLUDING the header, 1..32.
//           Total rather than payload-only because the invariant a checker wants
//           to state is "the number of flits between SOF and EOF inclusive
//           equals the header's length field" (SPEC 14, "packet length
//           consistency"), and a payload-only field makes that invariant an
//           arithmetic identity with an off-by-one in it.
//   seq     16 bits, incremented per packet per (source, VC). This is what makes
//           loss, duplication and reordering DETECTABLE at the egress rather
//           than merely improbable, and it is the same device rtl/common/
//           seq_checker.sv (issue #8) uses on a stream.
//
// -----------------------------------------------------------------------------
// 3. PARITY PER FLIT, not a CRC per packet — and the honest limits of it
// -----------------------------------------------------------------------------
// Each flit carries one ODD parity bit over its own data and control bits. The
// choice was made against a CRC-32 per packet, and the reasons are structural
// rather than aesthetic:
//
//   * A per-flit check is checkable AT EVERY HOP. A packet CRC can only be
//     verified at reassembly, so a flit corrupted in stage 0 is indistinguishable
//     from one corrupted in stage 1 — which is exactly the question a fabric
//     failure report has to answer. Parity localises a fault to a hop and a
//     virtual channel.
//   * It is combinational and stateless: one XOR tree of PACKET_W + 4 inputs per
//     checked point, roughly PACKET_W/3 ALMs at 512 bits, with no per-VC CRC
//     register, no polynomial shift and no ordering dependency on flits that a
//     virtual-channel fabric is entitled to interleave. A packet CRC computed
//     across interleaved flits needs one accumulator per (input, VC) at every
//     hop, which is the cost of the fabric's buffering again for a weaker
//     property.
//   * The dominant on-die failure mode this benchmark can express — a stuck bit,
//     a mis-wired mux, a flit written into the wrong VC — flips a small number of
//     bits in one flit, which parity catches.
//
// WHAT PARITY DOES NOT CATCH is stated here rather than discovered later: an
// EVEN number of bit errors in one flit passes. It is therefore not the only
// integrity mechanism. The per-(source, VC) sequence number catches a lost,
// duplicated or reordered flit regardless of its content, the length field
// catches a truncated or extended packet, and the egress payload scoreboard in
// sim/tests/test_packet.cpp compares every payload bit against what was
// injected. The fault-injection hook can flip one bit (parity fires) or two
// (parity is silent, the scoreboard fires), and the test exercises both, so the
// limit is a measured property of the design rather than a footnote.
//
// -----------------------------------------------------------------------------
// 4. Flit-isation rules  (NORMATIVE)
// -----------------------------------------------------------------------------
//   payload_flits(bits) = ceil(bits / PACKET_W)
//   total_flits(bits)   = 1 + payload_flits(bits)
//
// with total_flits <= PKT_MAX_FLITS. A packet with a zero-length payload is
// legal and is one flit: an error event or a credit-drain marker needs a header
// and nothing else. The header flit carries `sof`, the last flit carries `eof`,
// and a one-flit packet carries both — the SPEC 5 framing convention, so a
// packet boundary in this fabric is the same object as a frame boundary in the
// stream fabric and the same checkers apply.
//
// The two payloads the design actually produces size the network:
//   detection event   cfar_pkg::CFAR_EVENT_W = 176 bits -> 4 flits at PACKET_W
//                     64, 2 flits at 128, 2 at 256, 2 at 512.
//   counter snapshot  a telemetry record; sized by its producer (issue #19).
// `pkt_detection_flits()` states the first of these in one place so a test, the
// C++ model and the RTL cannot disagree about how long a detection packet is.
//
// -----------------------------------------------------------------------------
// 5. Topology arithmetic: an R-ary butterfly, and why that one
// -----------------------------------------------------------------------------
// The fabric is an R-ary butterfly (equivalently an omega network under a
// relabelling) of S stages carrying N = R^S ports: 16 ports as two stages of
// radix 4, which is the SPEC 7.8 nominal size.
//
// The alternative considered and rejected is the obvious one: a single 16x16
// crossbar. SPEC 7.8 forbids it in words ("Do not build one unregistered,
// monolithic crossbar"), and the routability argument is why the words are
// there. A 16x16 crossbar at 512-bit flits is 256 crosspoints, each of which is
// a 517-bit-wide mux input, and every one of the 16 output muxes must reach all
// 16 inputs — 16 x 16 x 517 = 132 k wires converging on 16 points. On Agilex 7
// that is a routing-congestion problem before it is an ALM problem. The two-stage
// radix-4 butterfly is 8 switches of 16 crosspoints each: 128 crosspoints total,
// each mux reaching 4 inputs, and the inter-stage wiring is a FIXED PERMUTATION
// of 16 point-to-point flit buses rather than an all-to-all. Same bisection, half
// the crosspoints, and — the part that matters for HyperFlex — a registered hop
// between the two halves, which is where SPEC 23's "keep pipeline stages
// latency-insensitive" gets its opportunity.
//
// A fat-tree was the other candidate and is not built. A fat tree buys
// path diversity, which buys nothing here: the traffic is aggregation (many
// sources, few sinks) and adaptive routing would destroy the in-order-per-
// (source, VC, dest) property that makes the egress checkable with a sequence
// number instead of a reorder buffer. Determinism is worth more than diversity
// for this workload, and it is a decision, so it is written down.
//
// ROUTING IS DESTINATION-TAG, one base-R digit per stage, MOST significant digit
// first. Stage s consumes destination digit (S-1-s). Combined with the butterfly
// wiring below this is loop-free and gives EXACTLY ONE path from every ingress to
// every egress, which is what makes ordering a per-(source, VC) property rather
// than a network-wide one.
//
// `pkt_bfly_insert()` is the whole wiring rule. At stage s a switch is named by
// the port index with digit (S-1-s) DELETED, and a port's position inside that
// switch is that digit; so the global index of switch j's position k is the
// digit k re-inserted into j at position (S-1-s). The same function maps a
// switch OUTPUT to the next stage's global wire index, which is why the topology
// is one function and not two tables that can disagree.
//
// Lint contract: linted by `make lint` on every run, clean under --Wall with no
// waiver.
// -----------------------------------------------------------------------------

`default_nettype none

package packet_pkg;

  // ---------------------------------------------------------------------------
  // Working types
  // ---------------------------------------------------------------------------

  // Unsigned 32-bit integer, so widths and indices can be cast explicitly
  // (`pkt_uint_t'(x)`); `int unsigned'(x)` is not legal cast syntax. Same device
  // as fxp_pkg::uint_t and friends, deliberately spelled differently — see the
  // naming note at the top.
  typedef int unsigned pkt_uint_t;

  // ---------------------------------------------------------------------------
  // Widths (section 2)
  // ---------------------------------------------------------------------------

  localparam int unsigned PKT_DEST_W = 4;   // 16 egress ports
  localparam int unsigned PKT_SRC_W  = 5;   // 32 ingress ports ("16 or more")
  localparam int unsigned PKT_VC_W   = 2;   // N_VC = 4
  localparam int unsigned PKT_TYPE_W = 3;   // six kinds, two reserved
  localparam int unsigned PKT_LEN_W  = 6;   // total flits, 1..32
  localparam int unsigned PKT_SEQ_W  = 16;  // per (source, VC) packet sequence

  localparam int unsigned PKT_HDR_W =
      PKT_DEST_W + PKT_SRC_W + PKT_VC_W + PKT_TYPE_W + PKT_LEN_W + PKT_SEQ_W;

  // Virtual channels. A constant of the packet FORMAT rather than of a given
  // elaboration: the vc field is two bits wide in every configuration, so a
  // fabric built with fewer than four channels still decodes the same header.
  // config_pkg::N_VIRTUAL_CHANS is checked against this at elaboration by
  // rtl/packet/pkt_fabric.sv.
  localparam int unsigned PKT_N_VC = 4;

  // Longest legal packet, in flits including the header. 32 covers the largest
  // payload the design produces at the narrowest configuration — a raw-capture
  // record of 31 x 64 = 1984 bits at PACKET_W = 64 — and bounds the length field,
  // the flit counters and the egress reassembly check with one number.
  localparam int unsigned PKT_MAX_FLITS = 32;

  // Flit control bits: parity, vc, sof, eof (section 1).
  localparam int unsigned PKT_FLIT_CTRL_W = 1 + PKT_VC_W + 1 + 1;

  // Maximum PACKET_W the working type below covers. This is the SPEC 11
  // full_agmf039 packet width and the width the SPEC 18 calibration compiles;
  // an elaboration wider than this fails at time 0 rather than truncating.
  localparam int unsigned PKT_MAX_PACKET_W = 512;
  localparam int unsigned PKT_MAX_FLIT_W   = PKT_MAX_PACKET_W + PKT_FLIT_CTRL_W;

  // Packed flit at maximum width. A real link uses only the low
  // pkt_flit_w(PACKET_W) bits.
  typedef logic [PKT_MAX_FLIT_W-1:0] pkt_flit_t;

  // ---------------------------------------------------------------------------
  // Packet types (SPEC 7.8's list, one value each)
  // ---------------------------------------------------------------------------
  typedef enum logic [PKT_TYPE_W-1:0] {
    PKT_TYPE_DETECTION = 3'd0,  // cfar_pkg detection event
    PKT_TYPE_POWER     = 3'd1,  // power summary
    PKT_TYPE_COVAR     = 3'd2,  // covariance summary
    PKT_TYPE_ERROR     = 3'd3,  // error event
    PKT_TYPE_COUNTER   = 3'd4,  // performance-counter snapshot
    PKT_TYPE_RAW       = 3'd5   // optional raw-data capture record
  } pkt_type_e;

  // Reserved encodings are an ERROR, not a don't-care. Checked at the ingress
  // and again at the egress, so a corrupted type field is caught rather than
  // routed.
  function automatic logic pkt_type_legal(input logic [PKT_TYPE_W-1:0] t);
    return (t <= PKT_TYPE_W'(PKT_TYPE_RAW));
  endfunction

  // ---------------------------------------------------------------------------
  // Header layout  (NORMATIVE — section 2)
  // ---------------------------------------------------------------------------
  typedef enum int unsigned {
    PKT_HSEL_DEST = 0,
    PKT_HSEL_SRC  = 1,
    PKT_HSEL_VC   = 2,
    PKT_HSEL_TYPE = 3,
    PKT_HSEL_LEN  = 4,
    PKT_HSEL_SEQ  = 5,
    PKT_HSEL_END  = 6
  } pkt_hsel_e;

  // The one place the header layout arithmetic exists, for the reason
  // stream_layout_bit() gives: a second expression for any boundary is a second
  // definition of the layout.
  function automatic pkt_uint_t pkt_hdr_bit(input pkt_hsel_e sel);
    pkt_uint_t b;
    b = 32'd0;
    if (sel == PKT_HSEL_DEST) return b;
    b = b + pkt_uint_t'(PKT_DEST_W);
    if (sel == PKT_HSEL_SRC) return b;
    b = b + pkt_uint_t'(PKT_SRC_W);
    if (sel == PKT_HSEL_VC) return b;
    b = b + pkt_uint_t'(PKT_VC_W);
    if (sel == PKT_HSEL_TYPE) return b;
    b = b + pkt_uint_t'(PKT_TYPE_W);
    if (sel == PKT_HSEL_LEN) return b;
    b = b + pkt_uint_t'(PKT_LEN_W);
    if (sel == PKT_HSEL_SEQ) return b;
    b = b + pkt_uint_t'(PKT_SEQ_W);
    return b;  // PKT_HSEL_END
  endfunction

  // Unpacked view. Every field width is a constant, so unlike stream_pkg this
  // struct needs no maximum-width working form.
  typedef struct packed {
    logic [PKT_SEQ_W-1:0]  seq;
    logic [PKT_LEN_W-1:0]  length;   // TOTAL flits, header included
    logic [PKT_TYPE_W-1:0] ptype;
    logic [PKT_VC_W-1:0]   vc;
    logic [PKT_SRC_W-1:0]  src;
    logic [PKT_DEST_W-1:0] dest;
  } pkt_hdr_t;

  typedef logic [PKT_HDR_W-1:0] pkt_hdr_bits_t;

  // Fields -> packed. Every field is masked by its own width by the part-select,
  // so a value too large for its field is truncated rather than written into its
  // neighbour.
  function automatic pkt_hdr_bits_t pkt_hdr_pack(input pkt_hdr_t h);
    pkt_hdr_bits_t p;
    p = '0;
    p[pkt_hdr_bit(PKT_HSEL_DEST) +: PKT_DEST_W] = h.dest;
    p[pkt_hdr_bit(PKT_HSEL_SRC)  +: PKT_SRC_W]  = h.src;
    p[pkt_hdr_bit(PKT_HSEL_VC)   +: PKT_VC_W]   = h.vc;
    p[pkt_hdr_bit(PKT_HSEL_TYPE) +: PKT_TYPE_W] = h.ptype;
    p[pkt_hdr_bit(PKT_HSEL_LEN)  +: PKT_LEN_W]  = h.length;
    p[pkt_hdr_bit(PKT_HSEL_SEQ)  +: PKT_SEQ_W]  = h.seq;
    return p;
  endfunction

  // Packed -> fields. A round trip is the identity on any header whose fields
  // fit their widths.
  function automatic pkt_hdr_t pkt_hdr_unpack(input pkt_hdr_bits_t p);
    pkt_hdr_t h;
    h        = '0;
    h.dest   = p[pkt_hdr_bit(PKT_HSEL_DEST) +: PKT_DEST_W];
    h.src    = p[pkt_hdr_bit(PKT_HSEL_SRC)  +: PKT_SRC_W];
    h.vc     = p[pkt_hdr_bit(PKT_HSEL_VC)   +: PKT_VC_W];
    h.ptype  = p[pkt_hdr_bit(PKT_HSEL_TYPE) +: PKT_TYPE_W];
    h.length = p[pkt_hdr_bit(PKT_HSEL_LEN)  +: PKT_LEN_W];
    h.seq    = p[pkt_hdr_bit(PKT_HSEL_SEQ)  +: PKT_SEQ_W];
    return h;
  endfunction

  // ---------------------------------------------------------------------------
  // Flit layout  (NORMATIVE — section 1)
  //
  // Control bits at CONSTANT offsets; only `data` moves with PACKET_W.
  // ---------------------------------------------------------------------------
  localparam int unsigned PKT_FLIT_PARITY_LSB = 0;
  localparam int unsigned PKT_FLIT_VC_LSB     = 1;
  localparam int unsigned PKT_FLIT_SOF_LSB    = PKT_FLIT_VC_LSB + PKT_VC_W;   // 3
  localparam int unsigned PKT_FLIT_EOF_LSB    = PKT_FLIT_SOF_LSB + 1;         // 4
  localparam int unsigned PKT_FLIT_DATA_LSB   = PKT_FLIT_EOF_LSB + 1;         // 5

  function automatic pkt_uint_t pkt_flit_w(input pkt_uint_t packet_w);
    return packet_w + pkt_uint_t'(PKT_FLIT_CTRL_W);
  endfunction

  // `w` low bits set, in the flit working type.
  function automatic pkt_flit_t pkt_mask(input pkt_uint_t w);
    if (w == 32'd0) return '0;
    if (w >= pkt_uint_t'(PKT_MAX_FLIT_W)) return '1;
    return (pkt_flit_t'(1) << w) - pkt_flit_t'(1);
  endfunction

  // Build a flit WITHOUT its parity bit. Parity is added by pkt_flit_seal() so
  // that the one place parity is computed is also the one place it is checked
  // against (pkt_flit_parity_ok), and a producer cannot compute it a second way.
  function automatic pkt_flit_t pkt_flit_body(input pkt_uint_t packet_w,
                                              input logic [PKT_VC_W-1:0] vc,
                                              input logic sof,
                                              input logic eof,
                                              input pkt_flit_t data);
    pkt_flit_t f;
    f = '0;
    f = f | (pkt_flit_t'(vc) << PKT_FLIT_VC_LSB);
    f = f | (pkt_flit_t'(sof) << PKT_FLIT_SOF_LSB);
    f = f | (pkt_flit_t'(eof) << PKT_FLIT_EOF_LSB);
    f = f | ((data & pkt_mask(packet_w)) << PKT_FLIT_DATA_LSB);
    return f;
  endfunction

  // ODD parity over the whole flit: the sealed flit has an odd number of set
  // bits, so an all-zero word — the value an undriven or reset link presents —
  // is NOT a legal flit. That is deliberate: it makes "the link is dead" and
  // "the link is carrying an empty flit" different observations.
  function automatic logic pkt_body_parity(input pkt_uint_t packet_w,
                                           input pkt_flit_t body);
    return ~(^(body & pkt_mask(pkt_flit_w(packet_w))));
  endfunction

  function automatic pkt_flit_t pkt_flit_seal(input pkt_uint_t packet_w,
                                              input pkt_flit_t body);
    return body | (pkt_flit_t'(pkt_body_parity(packet_w, body))
                   << PKT_FLIT_PARITY_LSB);
  endfunction

  // Complete constructor: body then seal.
  function automatic pkt_flit_t pkt_flit_make(input pkt_uint_t packet_w,
                                              input logic [PKT_VC_W-1:0] vc,
                                              input logic sof,
                                              input logic eof,
                                              input pkt_flit_t data);
    return pkt_flit_seal(packet_w,
                         pkt_flit_body(packet_w, vc, sof, eof, data));
  endfunction

  // True when the flit's parity is odd, i.e. when the flit is intact under the
  // limits of section 3.
  function automatic logic pkt_flit_parity_ok(input pkt_uint_t packet_w,
                                              input pkt_flit_t f);
    return ^(f & pkt_mask(pkt_flit_w(packet_w)));
  endfunction

  // The three control accessors are written as a SHIFT and not as a bit select
  // for a measured reason: `verilator --lint-only --Wall` reports the unselected
  // bits of a function argument as unused (UNUSEDSIGNAL on the argument), so a
  // 517-bit flit read for one bit fails lint. A shift of the whole word does
  // not, and produces the same constant-folded select in every synthesiser.
  function automatic logic [PKT_VC_W-1:0] pkt_flit_vc(input pkt_flit_t f);
    logic [PKT_VC_W-1:0] v;
    v = PKT_VC_W'(f >> PKT_FLIT_VC_LSB);
    return v;
  endfunction

  function automatic logic pkt_flit_sof(input pkt_flit_t f);
    logic b;
    b = 1'(f >> PKT_FLIT_SOF_LSB);
    return b;
  endfunction

  function automatic logic pkt_flit_eof(input pkt_flit_t f);
    logic b;
    b = 1'(f >> PKT_FLIT_EOF_LSB);
    return b;
  endfunction

  function automatic pkt_flit_t pkt_flit_data(input pkt_uint_t packet_w,
                                              input pkt_flit_t f);
    return (f >> PKT_FLIT_DATA_LSB) & pkt_mask(packet_w);
  endfunction

  // THE ROUTING ACCESSOR. A switch stage needs the destination and nothing else
  // from a header flit, and unpacking the whole header to take four bits of it
  // fails `--Wall` (the other fields of the unpacked struct are then unused) as
  // well as reading as if the switch cared about the rest. This is the one
  // field a router touches.
  function automatic logic [PKT_DEST_W-1:0] pkt_flit_dest(input pkt_uint_t packet_w,
                                                          input pkt_flit_t f);
    logic [PKT_DEST_W-1:0] d;
    d = PKT_DEST_W'(pkt_flit_data(packet_w, f) >> pkt_hdr_bit(PKT_HSEL_DEST));
    return d;
  endfunction

  // The header carried by a header flit. Only meaningful when pkt_flit_sof().
  function automatic pkt_hdr_t pkt_flit_hdr(input pkt_uint_t packet_w,
                                            input pkt_flit_t f);
    return pkt_hdr_unpack(
        pkt_hdr_bits_t'(pkt_flit_data(packet_w, f) & pkt_mask(pkt_uint_t'(PKT_HDR_W))));
  endfunction

  // ---------------------------------------------------------------------------
  // Flit-isation  (NORMATIVE — section 4)
  // ---------------------------------------------------------------------------
  function automatic pkt_uint_t pkt_payload_flits(input pkt_uint_t bits,
                                                  input pkt_uint_t packet_w);
    if (packet_w == 32'd0) return 32'd0;
    return (bits + packet_w - 32'd1) / packet_w;
  endfunction

  function automatic pkt_uint_t pkt_total_flits(input pkt_uint_t bits,
                                                input pkt_uint_t packet_w);
    return 32'd1 + pkt_payload_flits(bits, packet_w);
  endfunction

  // The detection event of cfar_pkg, in flits. Stated here so the RTL, the C++
  // model and the tests cannot disagree about how long a detection packet is.
  function automatic pkt_uint_t pkt_detection_payload_w();
    return pkt_uint_t'(cfar_pkg::CFAR_EVENT_W);
  endfunction

  function automatic pkt_uint_t pkt_detection_flits(input pkt_uint_t packet_w);
    return pkt_total_flits(pkt_detection_payload_w(), packet_w);
  endfunction

  // ---------------------------------------------------------------------------
  // Elaboration predicates
  // ---------------------------------------------------------------------------

  // The header must fit one flit's data field (section 2).
  function automatic logic pkt_hdr_fits(input pkt_uint_t packet_w);
    return (pkt_uint_t'(PKT_HDR_W) <= packet_w);
  endfunction

  function automatic logic pkt_packet_w_ok(input pkt_uint_t packet_w);
    return pkt_hdr_fits(packet_w) &&
           (packet_w <= pkt_uint_t'(PKT_MAX_PACKET_W));
  endfunction

  // A length field value is legal when it names between one and PKT_MAX_FLITS
  // flits. Zero is not a packet.
  function automatic logic pkt_length_legal(input logic [PKT_LEN_W-1:0] len);
    return (len >= PKT_LEN_W'(1)) && (len <= PKT_LEN_W'(PKT_MAX_FLITS));
  endfunction

  // ---------------------------------------------------------------------------
  // Topology arithmetic  (NORMATIVE — section 5)
  // ---------------------------------------------------------------------------

  // radix**exp, as an elaboration-time integer.
  function automatic pkt_uint_t pkt_ipow(input pkt_uint_t radix,
                                         input pkt_uint_t exp);
    pkt_uint_t r;
    r = 32'd1;
    for (pkt_uint_t i = 32'd0; i < exp; i = i + 32'd1) r = r * radix;
    return r;
  endfunction

  // Ports carried by an S-stage radix-R butterfly.
  function automatic pkt_uint_t pkt_bfly_ports(input pkt_uint_t radix,
                                               input pkt_uint_t stages);
    return pkt_ipow(radix, stages);
  endfunction

  // Insert base-R digit `d` at digit position `pos` into `rest`, which holds the
  // remaining S-1 digits in order. THE wiring rule: at stage s a switch is named
  // by the port index with digit (S-1-s) deleted, and this function puts it back.
  function automatic pkt_uint_t pkt_bfly_insert(input pkt_uint_t rest,
                                                input pkt_uint_t d,
                                                input pkt_uint_t pos,
                                                input pkt_uint_t radix);
    pkt_uint_t scale, low, high;
    scale = pkt_ipow(radix, pos);
    low   = rest % scale;
    high  = rest / scale;
    return (high * scale * radix) + (d * scale) + low;
  endfunction

  // Which destination digit stage `s` of an S-stage network routes on. Most
  // significant digit first, which is what makes the wiring above loop free.
  function automatic pkt_uint_t pkt_bfly_digit(input pkt_uint_t stage,
                                               input pkt_uint_t stages);
    return stages - 32'd1 - stage;
  endfunction

  // Extract base-R digit `pos` of `value`. The routing function itself.
  function automatic pkt_uint_t pkt_digit(input pkt_uint_t value,
                                          input pkt_uint_t pos,
                                          input pkt_uint_t radix);
    return (value / pkt_ipow(radix, pos)) % radix;
  endfunction

  // ---------------------------------------------------------------------------
  // Credit arithmetic
  // ---------------------------------------------------------------------------

  // Width of a credit counter that must represent 0..depth inclusive. Same shape
  // as stream_pkg::stream_occ_w(), deliberately, because it is the same number.
  function automatic pkt_uint_t pkt_credit_w(input pkt_uint_t depth);
    return pkt_uint_t'($clog2(depth + 32'd1));
  endfunction

  // ---------------------------------------------------------------------------
  // Function forms of the widths.
  //
  // Exported as FUNCTIONS for the measured reason stream_pkg, covar_pkg and
  // cfar_pkg all give: `verilator --lint-only --Wall` reports a package
  // localparam that a given build happens not to reference as a dead parameter,
  // and this package is deliberately lintable one top at a time. A function is
  // available to every build and dead in none, and referencing the localparam
  // from a function body is what makes the localparam "used" in every build.
  // ---------------------------------------------------------------------------
  function automatic pkt_uint_t pkt_dest_w();   return pkt_uint_t'(PKT_DEST_W);   endfunction
  function automatic pkt_uint_t pkt_src_w();    return pkt_uint_t'(PKT_SRC_W);    endfunction
  function automatic pkt_uint_t pkt_vc_w();     return pkt_uint_t'(PKT_VC_W);     endfunction
  function automatic pkt_uint_t pkt_type_w();   return pkt_uint_t'(PKT_TYPE_W);   endfunction
  function automatic pkt_uint_t pkt_len_w();    return pkt_uint_t'(PKT_LEN_W);    endfunction
  function automatic pkt_uint_t pkt_seq_w();    return pkt_uint_t'(PKT_SEQ_W);    endfunction
  function automatic pkt_uint_t pkt_hdr_w();    return pkt_uint_t'(PKT_HDR_W);    endfunction
  function automatic pkt_uint_t pkt_n_vc();     return pkt_uint_t'(PKT_N_VC);     endfunction
  function automatic pkt_uint_t pkt_max_flits(); return pkt_uint_t'(PKT_MAX_FLITS); endfunction
  function automatic pkt_uint_t pkt_ctrl_w();   return pkt_uint_t'(PKT_FLIT_CTRL_W); endfunction
  function automatic pkt_uint_t pkt_max_packet_w(); return pkt_uint_t'(PKT_MAX_PACKET_W); endfunction

endpackage : packet_pkg

`default_nettype wire
