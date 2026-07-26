// -----------------------------------------------------------------------------
// pkt_ingress — per-source packet adapter (SPEC.md 7.8, issue #18).
//
// One instance per ingress port. Takes a source's MESSAGE stream — detection
// events from rtl/cfar/, power and covariance summaries from rtl/covariance/,
// error events, counter snapshots from rtl/common/telemetry_block.sv, raw
// capture — and turns it into packet_pkg flits on a credit-controlled link into
// the fabric, with per-virtual-channel elastic buffering.
//
// THE MESSAGE INTERFACE, AND WHY THE SOURCE DECLARES ITS LENGTH
// -------------------------------------------------------------
// The slave side is one PACKET_W-bit payload word per beat, framed by `s_sof`
// and `s_eof` exactly as SPEC 5 frames a stream, plus four fields sampled on the
// SOF beat: destination, packet type, virtual channel, and TOTAL FLIT COUNT.
//
// The length is declared by the source rather than measured by this module,
// and that is the design decision in this file. The header flit has to carry the
// length and the header flit goes out FIRST, so a module that measured the
// length would have to buffer the whole packet before emitting anything —
// store-and-forward, one packet-sized buffer per virtual channel per ingress
// port, 32 x 512 bits x 4 VC x 16 ports of storage bought to avoid asking the
// producer a question it already knows the answer to. Declaring it makes this a
// virtual-cut-through adapter with a flit-sized critical resource.
//
// The price of declaring it is that the declaration can be WRONG, and that is
// exactly why it is the right shape: `a_pkt_len_matches` compares the declared
// length against the flits actually framed and fires when they differ. That is
// SPEC 14's "packet length consistency" as a live check on real traffic, rather
// than an invariant that holds by construction and therefore tests nothing. The
// same violation also sets a sticky `err_length` bit, so a fault seen once in a
// long run is still visible at the end of it.
//
// ONE BEAT PER FLIT
// -----------------
//   beat 0 (s_sof)  produces the HEADER flit. Its `s_data` is IGNORED — the
//                   header flit's data field is the packet_pkg header in the low
//                   PKT_HDR_W bits and reserved zero above — and it is consumed
//                   like any other beat.
//   beats 1..L-1    produce payload flits, least significant word first, the
//                   last carrying `s_eof`.
//
// So a length-L packet is exactly L beats on the message interface and L cycles
// on the fabric link, and BEAT COUNT EQUALS FLIT COUNT. The alternative — folding
// the header into the first payload beat to save one cycle — was written and
// removed: it makes `s_sof` true on a beat that is consumed as a body flit, so
// the framing rule "SOF may not arrive inside an open packet" becomes
// unstateable and the producer has to know when the adapter latched the header.
// One beat of throughput per packet is a small price for a framing rule that a
// checker can state in one line.
//
// A header-only packet (L = 1) is one beat carrying both SOF and EOF. It is not
// a degenerate case to be excluded: an error event or a counter-snapshot marker
// is a header and nothing else, and SPEC 7.8 lists both.
//
// VIRTUAL CHANNELS: ONE BUFFER EACH, AND NO LOCK ON THE LINK
// ----------------------------------------------------------
// Each virtual channel gets its own sync_fifo (issue #6). A packet is committed
// to the VC named on its SOF beat and every flit of it goes to that buffer;
// `a_pkt_vc_stable` fires if the VC field moves mid packet, which is the "no
// VC-mixing mid-packet" property.
//
// The OUTPUT link is then shared per FLIT, round robin over the channels that
// have both a flit and a credit — there is no packet-level lock here. That is
// the whole point of virtual channels and it is what makes the SPEC 7.8 VC
// isolation property true at this boundary: a VC whose downstream buffer is full
// holds no credit, drops out of the arbitration, and the other channels keep the
// link busy. A lock would reintroduce head-of-line blocking at the one place the
// design is explicitly buying its way out of it.
//
// Interleaving flits of different VCs on one link is safe because the downstream
// switch de-multiplexes by the flit's own `vc` field into per-VC buffers again;
// ordering is preserved WITHIN a (source, VC) and is not claimed across VCs.
//
// FLOW CONTROL: CREDITS, NOT READY
// --------------------------------
// SPEC 7.8 allows either. Credits are used because the link into the fabric is
// the one place a registered ready would cost throughput: a ready returned from
// the switch's buffer occupancy is a combinational path from a FIFO's full flag,
// through the switch's port boundary, into this module's output mux — precisely
// the ready chain SPEC 5 forbids and SPEC 23 asks to be broken with elastic
// buffers. A credit counter replaces that path with a registered pulse in the
// opposite direction: nothing downstream is in this module's timing cone at all.
// `CREDITS` is the downstream buffer's depth; the counter cannot underflow
// because a flit is only sent when it is non-zero, and cannot overflow because a
// credit is only returned for a flit that was sent — both asserted below.
//
// Reset (SPEC 23, DECISIONS.md decision 6): synchronous, active low, control
// state only. The FIFO payload arrays are never reset (sync_fifo's own policy),
// and the output flit register is guarded by its valid bit.
// -----------------------------------------------------------------------------

`default_nettype none

module pkt_ingress
  import packet_pkg::*;
#(
    // Flit payload width. A SPEC 11 sized parameter (config PACKET_W).
    parameter int unsigned PACKET_W = 64,

    // Virtual channels. 4 in every SPEC 11 configuration; parameterised so a
    // calibration point can price a narrower fabric.
    parameter int unsigned N_VC = 4,

    // This port's identity, written into every header's `src` field. The egress
    // sequence check is per (src, vc), so two ports sharing an id is a defect
    // the checker would report as reordering; the elaboration check below stops
    // it being possible to build.
    parameter int unsigned SRC_ID = 0,

    // Entries per virtual-channel buffer.
    parameter int unsigned VC_DEPTH = 8,

    // Credits held toward the downstream buffer. Must not exceed the downstream
    // buffer's usable depth or the credit scheme is not a bound.
    parameter int unsigned CREDITS = 8,

    // sync_fifo storage style for the VC buffers: "regs", "mlab" or "m20k".
    parameter string STORAGE = "regs"
) (
    input  wire                       clk,
    input  wire                       rst_n,

    // ---- message side ------------------------------------------------------
    input  wire                       s_valid,
    output wire                       s_ready,
    input  wire [PACKET_W-1:0]        s_data,
    input  wire                       s_sof,
    input  wire                       s_eof,
    input  wire [PKT_DEST_W-1:0]      s_dest,
    input  wire [PKT_TYPE_W-1:0]      s_type,
    input  wire [PKT_VC_W-1:0]        s_vc,
    input  wire [PKT_LEN_W-1:0]       s_len,

    // ---- fabric side: credit link -----------------------------------------
    output wire                       m_valid,
    output wire [PACKET_W+4:0]        m_flit,
    input  wire [N_VC-1:0]            m_credit,

    // ---- fault injection (SPEC 7.8 error-injection hook) -------------------
    // Bit 0 flips ONE payload bit of the flit being emitted: parity fires.
    // Bit 1 flips a SECOND payload bit: parity is silent by construction
    // (packet_pkg section 3) and only the egress payload scoreboard catches it.
    // Both are one-cycle effects; the register plane pulses them.
    input  wire [1:0]                 fi_flip,

    // ---- telemetry (SPEC 9) -------------------------------------------------
    output wire [31:0]                tel_packets,
    output wire [31:0]                tel_flits,
    output wire [31:0]                tel_stall,
    output wire [$clog2(VC_DEPTH+1)-1:0] tel_hiwater,

    // ---- sticky errors ------------------------------------------------------
    // [0] declared length disagreed with the framed flit count
    // [1] illegal packet type
    // [2] VC field moved mid packet
    // [3] illegal declared length (0, or above PKT_MAX_FLITS)
    output wire [3:0]                 err_sticky,
    input  wire                       err_clear
);

  localparam int unsigned FLIT_W  = PACKET_W + PKT_FLIT_CTRL_W;
  localparam int unsigned CRED_W  = $clog2(CREDITS + 1);
  localparam int unsigned OCC_W   = $clog2(VC_DEPTH + 1);
  localparam int unsigned VCIDX_W = (N_VC > 1) ? $clog2(N_VC) : 1;

`ifndef SYNTHESIS
  initial begin
    if (!pkt_packet_w_ok(pkt_uint_t'(PACKET_W))) begin
      $fatal(1, "pkt_ingress: PACKET_W=%0d cannot carry a %0d-bit header, or exceeds %0d",
             PACKET_W, PKT_HDR_W, PKT_MAX_PACKET_W);
    end
    if (N_VC < 1 || N_VC > int'(PKT_N_VC)) begin
      $fatal(1, "pkt_ingress: N_VC=%0d is outside 1..%0d", N_VC, PKT_N_VC);
    end
    if (SRC_ID >= (1 << PKT_SRC_W)) begin
      $fatal(1, "pkt_ingress: SRC_ID=%0d does not fit the %0d-bit src field",
             SRC_ID, PKT_SRC_W);
    end
    if (CREDITS < 1 || CREDITS > VC_DEPTH) begin
      $fatal(1, "pkt_ingress: CREDITS=%0d must be in 1..VC_DEPTH=%0d; a credit count above the downstream depth is not a bound",
             CREDITS, VC_DEPTH);
    end
  end
`endif

  // ---------------------------------------------------------------------------
  // Packet framing state
  // ---------------------------------------------------------------------------
  // S_HDR: waiting for a SOF beat; the header flit is produced here.
  // S_BODY: the header is away; every accepted beat is a payload flit.
  localparam logic S_HDR  = 1'b0;
  localparam logic S_BODY = 1'b1;

  logic                    state_q;
  logic [PKT_VC_W-1:0]     cur_vc_q;
  logic [PKT_LEN_W-1:0]    cur_len_q;
  logic [PKT_LEN_W-1:0]    flit_cnt_q;   // flits framed so far, header included
  logic [PKT_SEQ_W-1:0]    seq_q [N_VC];

  // ---------------------------------------------------------------------------
  // Virtual-channel buffers
  // ---------------------------------------------------------------------------
  logic [N_VC-1:0]      fifo_s_valid;
  logic [N_VC-1:0]      fifo_s_ready;
  logic [FLIT_W-1:0]    fifo_s_data;
  logic [N_VC-1:0]      fifo_m_valid;
  logic [N_VC-1:0]      fifo_m_ready;
  logic [FLIT_W-1:0]    fifo_m_data [N_VC];
  logic [OCC_W-1:0]     fifo_high   [N_VC];

  // The VC this cycle's flit belongs to: the SOF beat's own field in S_HDR, the
  // latched one in S_BODY. One expression, so the demux and the header can never
  // pick different channels.
  wire [PKT_VC_W-1:0] flit_vc = (state_q == S_HDR) ? s_vc : cur_vc_q;
  wire [VCIDX_W-1:0]  flit_vc_idx = VCIDX_W'(flit_vc);
  wire                vc_in_range = (int'(flit_vc) < int'(N_VC));

  // Room in the buffer this flit would go to.
  wire fifo_room = vc_in_range && fifo_s_ready[flit_vc_idx];

  // ---------------------------------------------------------------------------
  // Flit construction
  // ---------------------------------------------------------------------------
  pkt_hdr_t hdr;
  always_comb begin
    hdr        = '0;
    hdr.dest   = s_dest;
    hdr.src    = PKT_SRC_W'(SRC_ID);
    hdr.vc     = s_vc;
    hdr.ptype  = s_type;
    hdr.length = s_len;
    hdr.seq    = vc_in_range ? seq_q[flit_vc_idx] : '0;
  end

  wire pkt_flit_t hdr_data = pkt_flit_t'(pkt_hdr_pack(hdr));

  // Header flit: sof always; eof comes from the SOURCE and not from the declared
  // length, deliberately. Deriving it from the length would make "the header
  // says one flit and the framing says otherwise" unrepresentable — and that
  // disagreement is precisely what the SPEC 14 length check exists to catch,
  // both here and again at the egress.
  wire pkt_flit_t hdr_flit =
      pkt_flit_make(pkt_uint_t'(PACKET_W), s_vc, 1'b1, s_eof, hdr_data);

  // Payload flit: never sof, eof from the message framing.
  wire pkt_flit_t body_flit =
      pkt_flit_make(pkt_uint_t'(PACKET_W), cur_vc_q, 1'b0, s_eof,
                    pkt_flit_t'(s_data));

  // ---------------------------------------------------------------------------
  // Framing and admission
  // ---------------------------------------------------------------------------
  wire hdr_go  = (state_q == S_HDR)  && s_valid && s_sof && fifo_room;
  wire body_go = (state_q == S_BODY) && s_valid          && fifo_room;

  assign s_ready = hdr_go || body_go;

  always_comb begin
    fifo_s_valid = '0;
    fifo_s_data  = FLIT_W'(hdr_go ? hdr_flit : body_flit);
    if ((hdr_go || body_go) && vc_in_range) begin
      fifo_s_valid[flit_vc_idx] = 1'b1;
    end
  end

  // ---------------------------------------------------------------------------
  // Error detection (SPEC 14)
  // ---------------------------------------------------------------------------
  // Declared length against framed flit count, checked on every accepted beat.
  // `framed_now` is the number of flits this packet will have framed once this
  // beat is taken.
  wire [PKT_LEN_W-1:0] framed_now = hdr_go ? PKT_LEN_W'(1)
                                           : (flit_cnt_q + PKT_LEN_W'(1));

  wire len_mismatch =
      // a header that ends the packet must have declared exactly one flit,
      // and a header that does not must have declared more than one
      (hdr_go && (s_eof != (s_len == PKT_LEN_W'(1)))) ||
      // the last flit must be the length-th
      (body_go && s_eof && (framed_now != cur_len_q)) ||
      // and no flit may run past the declared length without ending the packet
      (body_go && !s_eof && (framed_now >= cur_len_q));

  wire type_bad = hdr_go && !pkt_type_legal(s_type);
  wire vc_bad   = body_go && (s_vc != cur_vc_q);
  wire len_bad  = hdr_go && !pkt_length_legal(s_len);

  logic [3:0] err_q;
  always_ff @(posedge clk) begin
    if (!rst_n) begin
      err_q <= 4'd0;
    end else if (err_clear) begin
      err_q <= 4'd0;
    end else begin
      if (len_mismatch) err_q[0] <= 1'b1;
      if (type_bad)     err_q[1] <= 1'b1;
      if (vc_bad)       err_q[2] <= 1'b1;
      if (len_bad)      err_q[3] <= 1'b1;
    end
  end

  assign err_sticky = err_q;

  // ---------------------------------------------------------------------------
  // Framing state register
  // ---------------------------------------------------------------------------
  always_ff @(posedge clk) begin
    if (!rst_n) begin
      state_q    <= S_HDR;
      cur_vc_q   <= '0;
      cur_len_q  <= PKT_LEN_W'(1);
      flit_cnt_q <= '0;
    end else begin
      if (hdr_go) begin
        cur_vc_q   <= s_vc;
        cur_len_q  <= s_len;
        flit_cnt_q <= PKT_LEN_W'(1);
        state_q    <= s_eof ? S_HDR : S_BODY;
      end else if (body_go) begin
        flit_cnt_q <= flit_cnt_q + PKT_LEN_W'(1);
        if (s_eof) state_q <= S_HDR;
      end
    end
  end

  // Per-VC packet sequence numbers. Advanced once per packet, on the header.
  for (genvar v = 0; v < N_VC; v = v + 1) begin : g_seq
    always_ff @(posedge clk) begin
      if (!rst_n) begin
        seq_q[v] <= '0;
      end else if (hdr_go && (int'(flit_vc) == v)) begin
        seq_q[v] <= seq_q[v] + PKT_SEQ_W'(1);
      end
    end
  end

  // ---------------------------------------------------------------------------
  // The virtual-channel buffers themselves
  // ---------------------------------------------------------------------------
  // Deliberately unused sync_fifo status outputs, gathered rather than left as
  // empty port connections so that "this output is not used here" is written
  // down. The `unused_` prefix is the spelling Verilator's --unused-regexp
  // recognises, so a genuinely dropped signal elsewhere is still reported. The
  // sticky error flags are provably unreachable — sync_fifo asserts it on every
  // cycle — and the live occupancy is exported as a high-water mark instead.
  logic [N_VC*OCC_W-1:0] unused_occ;
  logic [N_VC-1:0]       unused_full, unused_empty, unused_af, unused_ae;
  logic [N_VC-1:0]       unused_ovf, unused_unf;

  for (genvar v = 0; v < N_VC; v = v + 1) begin : g_vc
    sync_fifo #(
        .WIDTH      (FLIT_W),
        .DEPTH      (VC_DEPTH),
        .SHOW_AHEAD (1'b0),
        .STORAGE    (STORAGE)
    ) u_fifo (
        .clk              (clk),
        .rst_n            (rst_n),
        .s_valid          (fifo_s_valid[v]),
        .s_ready          (fifo_s_ready[v]),
        .s_data           (fifo_s_data),
        .m_valid          (fifo_m_valid[v]),
        .m_ready          (fifo_m_ready[v]),
        .m_data           (fifo_m_data[v]),
        .occupancy        (unused_occ[v*OCC_W +: OCC_W]),
        .full             (unused_full[v]),
        .empty            (unused_empty[v]),
        .almost_full      (unused_af[v]),
        .almost_empty     (unused_ae[v]),
        .high_water       (fifo_high[v]),
        .overflow_sticky  (unused_ovf[v]),
        .underflow_sticky (unused_unf[v]),
        .sticky_clear     (err_clear)
    );
  end

  // ---------------------------------------------------------------------------
  // Output link: credits and per-flit round robin over the channels
  // ---------------------------------------------------------------------------
  logic [CRED_W-1:0] credit_q [N_VC];
  logic [N_VC-1:0]   send_req;

  always_comb begin
    for (int unsigned v = 0; v < N_VC; v = v + 1) begin
      send_req[v] = fifo_m_valid[v] && (credit_q[v] != CRED_W'(0));
    end
  end

  wire [N_VC-1:0]     send_grant;
  wire                send_any;
  wire [VCIDX_W-1:0]  send_idx;

  pkt_rr_arb #(.N (N_VC)) u_link_arb (
      .clk       (clk),
      .rst_n     (rst_n),
      .req       (send_req),
      .update    (1'b1),
      .grant     (send_grant),
      .any_grant (send_any),
      .grant_idx (send_idx)
  );

  assign fifo_m_ready = send_grant;

  for (genvar v = 0; v < N_VC; v = v + 1) begin : g_credit
    always_ff @(posedge clk) begin
      if (!rst_n) begin
        credit_q[v] <= CRED_W'(CREDITS);
      end else begin
        case ({send_grant[v], m_credit[v]})
          2'b10:   credit_q[v] <= credit_q[v] - CRED_W'(1);
          2'b01:   credit_q[v] <= credit_q[v] + CRED_W'(1);
          default: credit_q[v] <= credit_q[v];
        endcase
      end
    end
  end

  // Output register. The flit is the granted buffer's head, optionally corrupted
  // by the fault-injection hook.
  wire [FLIT_W-1:0] sel_flit = fifo_m_data[send_idx];

  // The hook corrupts PAYLOAD flits only. Flipping a header's destination field
  // is not a fabric fault — the fabric would deliver the packet exactly where
  // the header now says, which is correct behaviour on corrupted input and tests
  // nothing. The fault worth injecting is a bit that changes in flight and must
  // be caught, and that is a payload bit.
  wire              fi_arm  = !pkt_flit_sof(pkt_flit_t'(sel_flit));
  wire [FLIT_W-1:0] fi_mask =
      fi_arm ? ((FLIT_W'(fi_flip[0]) << PKT_FLIT_DATA_LSB) |
                (FLIT_W'(fi_flip[1]) << (PKT_FLIT_DATA_LSB + 1)))
             : FLIT_W'(0);

  logic              out_valid_q;
  logic [FLIT_W-1:0] out_flit_q;
  // Records that the flit now in the output register was deliberately corrupted,
  // so the parity assertion below knows not to fire on it. Registered alongside
  // the flit for the obvious reason: `fi_flip` describes the cycle the flit was
  // LOADED, not the cycle it is observed.
  logic              out_dirty_q;

  always_ff @(posedge clk) begin
    if (!rst_n) begin
      out_valid_q <= 1'b0;
      out_dirty_q <= 1'b0;
    end else begin
      out_valid_q <= send_any;
      if (send_any) out_dirty_q <= (fi_mask != FLIT_W'(0));
    end
  end

  // Payload register: no reset (SPEC 23); guarded by out_valid_q.
  always_ff @(posedge clk) begin
    if (send_any) out_flit_q <= sel_flit ^ fi_mask;
  end

  assign m_valid = out_valid_q;
  assign m_flit  = out_flit_q;

  // ---------------------------------------------------------------------------
  // Telemetry (SPEC 9)
  // ---------------------------------------------------------------------------
  wire pkt_event  = hdr_go;
  wire flit_event = hdr_go || body_go;
  wire stall_event = s_valid && !s_ready;

  logic [OCC_W-1:0] high_max;
  always_comb begin
    high_max = '0;
    for (int unsigned v = 0; v < N_VC; v = v + 1) begin
      if (fifo_high[v] > high_max) high_max = fifo_high[v];
    end
  end

  assign tel_hiwater = high_max;

  wire [31:0] c_pkts, c_flits, c_stall;
  logic [95:0] unused_snap;
  logic [2:0]  unused_sv, unused_wp, unused_wr;

  perf_counter #(.WIDTH (32), .INCR_W (1), .SATURATE (1'b1)) u_c_pkts (
      .clk (clk), .rst_n (rst_n), .enable (1'b1), .event_i (pkt_event),
      .incr (1'b1), .clear (err_clear), .snapshot (1'b0),
      .count (c_pkts), .snap (unused_snap[31:0]), .snap_valid (unused_sv[0]),
      .wrap_pulse (unused_wp[0]), .wrapped (unused_wr[0]));

  perf_counter #(.WIDTH (32), .INCR_W (1), .SATURATE (1'b1)) u_c_flits (
      .clk (clk), .rst_n (rst_n), .enable (1'b1), .event_i (flit_event),
      .incr (1'b1), .clear (err_clear), .snapshot (1'b0),
      .count (c_flits), .snap (unused_snap[63:32]), .snap_valid (unused_sv[1]),
      .wrap_pulse (unused_wp[1]), .wrapped (unused_wr[1]));

  perf_counter #(.WIDTH (32), .INCR_W (1), .SATURATE (1'b1)) u_c_stall (
      .clk (clk), .rst_n (rst_n), .enable (1'b1), .event_i (stall_event),
      .incr (1'b1), .clear (err_clear), .snapshot (1'b0),
      .count (c_stall), .snap (unused_snap[95:64]), .snap_valid (unused_sv[2]),
      .wrap_pulse (unused_wp[2]), .wrapped (unused_wr[2]));

  assign tel_packets = c_pkts;
  assign tel_flits   = c_flits;
  assign tel_stall   = c_stall;

  // Every deliberately unused net in this module, gathered in one place.
  logic unused_status;
  assign unused_status = ^{unused_occ, unused_full, unused_empty, unused_af,
                           unused_ae, unused_ovf, unused_unf,
                           unused_snap, unused_sv, unused_wp, unused_wr};

  // ---------------------------------------------------------------------------
  // SPEC 14 assertions
  // ---------------------------------------------------------------------------
`ifndef SYNTHESIS
  always_ff @(posedge clk) begin
    if (rst_n) begin
      // SPEC 14: packet length consistency. The declared length and the framed
      // flit count must agree at every EOF, and no packet may run past its
      // declared length.
      a_pkt_len_matches : assert (!len_mismatch)
        else $error("pkt_ingress[%0d]: declared length %0d disagrees with the framed flit count %0d",
                    SRC_ID, cur_len_q, framed_now);
      a_pkt_len_legal : assert (!len_bad)
        else $error("pkt_ingress[%0d]: declared length %0d is outside 1..%0d",
                    SRC_ID, s_len, PKT_MAX_FLITS);
      // No VC mixing mid packet.
      a_pkt_vc_stable : assert (!vc_bad)
        else $error("pkt_ingress[%0d]: VC changed mid packet (%0d -> %0d)",
                    SRC_ID, cur_vc_q, s_vc);
      a_pkt_type_legal : assert (!type_bad)
        else $error("pkt_ingress[%0d]: packet type %0d is reserved", SRC_ID, s_type);
      // A SOF beat may not arrive while a packet is open.
      a_pkt_no_nested_sof : assert (!((state_q == S_BODY) && s_valid && s_sof))
        else $error("pkt_ingress[%0d]: SOF inside an open packet", SRC_ID);
      // Credit conservation: the counter never underflows and never exceeds the
      // credits this port was elaborated with.
      for (int unsigned v = 0; v < N_VC; v = v + 1) begin
        a_pkt_credit_bound : assert (credit_q[v] <= CRED_W'(CREDITS))
          else $error("pkt_ingress[%0d]: VC%0d credit %0d exceeds CREDITS=%0d",
                      SRC_ID, v, credit_q[v], CREDITS);
        a_pkt_credit_no_underflow : assert (!(send_grant[v] && (credit_q[v] == CRED_W'(0))))
          else $error("pkt_ingress[%0d]: VC%0d sent a flit with no credit", SRC_ID, v);
      end
      // Every emitted flit is parity-correct unless the fault-injection hook was
      // asked to break it.
      a_pkt_egress_parity : assert (!out_valid_q ||
                                    pkt_flit_parity_ok(pkt_uint_t'(PACKET_W),
                                                       pkt_flit_t'(out_flit_q)) ||
                                    out_dirty_q)
        else $error("pkt_ingress[%0d]: emitted a flit with bad parity", SRC_ID);
    end
  end
`endif

endmodule : pkt_ingress

`default_nettype wire
