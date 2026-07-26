// -----------------------------------------------------------------------------
// pkt_egress — per-destination reassembly and check point (SPEC.md 7.8, 14).
//
// One instance per egress port. Terminates the fabric's credit link, holds one
// buffer per virtual channel, presents ONE flit stream to the consumer, and — the
// reason the module exists rather than being a FIFO — RE-DERIVES every packet
// invariant from the flits that actually arrived.
//
// WHY THE CHECKS ARE HERE AND NOT ONLY AT THE INGRESS
// ---------------------------------------------------
// rtl/packet/pkt_ingress.sv checks the packet its SOURCE declared. This module
// checks the packet the NETWORK delivered, and those are different statements:
// between them lie eight switch stages' worth of buffers, arbiters and
// crossbars, which is exactly the machinery a length or framing invariant is
// worth testing across. A checker that only ran at the producer would pass on a
// fabric that dropped every other flit.
//
// Five sticky bits, one per way a delivered packet can be wrong (SPEC 14):
//
//   [0] PARITY   a flit arrived whose parity is not odd. Localises to this hop,
//                because every switch stage asserts the same property on its own
//                buffers (packet_pkg section 3).
//   [1] LENGTH   the flits framed between SOF and EOF do not match the header's
//                declared length: a truncated packet, an extended one, a body
//                flit with no open packet, or a SOF inside one. THE SPEC 14
//                "packet length consistency" check, stated on delivered traffic.
//   [2] VC       a flit's own VC tag disagrees with the VC its packet's header
//                declared. The fabric routes by the flit tag and the egress
//                buffers by it too, so a disagreement means a header and its body
//                took different channels.
//   [3] DEST     a packet arrived at a port that is not its destination. This is
//                the routing function checked at its only observable end.
//   [4] TYPE     a reserved packet type.
//
// The checks run on ARRIVAL, before the buffer, so a fault is recorded even if
// the consumer never drains the packet.
//
// OUTPUT: ONE PORT, PER-VC ENABLE
// -------------------------------
// The consumer sees one flit stream and a per-VC enable mask. Round robin over
// the channels that are both enabled and non-empty selects which VC is presented;
// the flit carries its own VC tag, so the consumer always knows which stream it
// is looking at. Deasserting one bit of `m_vc_en` stalls exactly one virtual
// channel, which is how sim/tests/test_packet.cpp's VC-isolation pass creates the
// condition SPEC 7.8's virtual channels exist to survive: VC0 blocked at its
// consumer must not stop VC1 crossing the network.
//
// A single shared FIFO would have made that test unwritable — a blocked VC0 flit
// at the head would block VC1 behind it, at the one place in the design where the
// blocking would be the testbench's fault rather than the fabric's.
//
// Reset (SPEC 23): control state only — reassembly state, sticky bits, counters,
// arbiter pointer.
// -----------------------------------------------------------------------------

`default_nettype none

module pkt_egress
  import packet_pkg::*;
#(
    parameter int unsigned PACKET_W = 64,
    parameter int unsigned N_VC     = 4,

    // This port's identity. Every arriving packet's destination field must equal
    // it; a mismatch sets err_sticky[3].
    parameter int unsigned DEST_ID = 0,

    parameter int unsigned VC_DEPTH = 4,
    parameter string       STORAGE  = "regs"
) (
    input  wire                       clk,
    input  wire                       rst_n,

    // ---- fabric side: credit link -----------------------------------------
    input  wire                       in_valid,
    input  wire [PACKET_W+4:0]        in_flit,
    output wire [N_VC-1:0]            in_credit_out,

    // ---- consumer side -----------------------------------------------------
    output wire                       m_valid,
    input  wire                       m_ready,
    output wire [PACKET_W+4:0]        m_flit,
    input  wire [N_VC-1:0]            m_vc_en,

    // ---- telemetry (SPEC 9) -------------------------------------------------
    output wire [31:0]                tel_packets,
    output wire [31:0]                tel_flits,
    output wire [$clog2(VC_DEPTH+1)-1:0] tel_hiwater,

    // ---- sticky errors ------------------------------------------------------
    output wire [4:0]                 err_sticky,
    input  wire                       err_clear
);

  localparam int unsigned FLIT_W = PACKET_W + PKT_FLIT_CTRL_W;
  localparam int unsigned OCC_W  = $clog2(VC_DEPTH + 1);
  localparam int unsigned VIDX_W = (N_VC > 1) ? $clog2(N_VC) : 1;

`ifndef SYNTHESIS
  initial begin
    if (!pkt_packet_w_ok(pkt_uint_t'(PACKET_W))) begin
      $fatal(1, "pkt_egress: PACKET_W=%0d cannot carry a %0d-bit header, or exceeds %0d",
             PACKET_W, PKT_HDR_W, PKT_MAX_PACKET_W);
    end
    if (DEST_ID >= (1 << PKT_DEST_W)) begin
      $fatal(1, "pkt_egress: DEST_ID=%0d does not fit the %0d-bit dest field",
             DEST_ID, PKT_DEST_W);
    end
  end
`endif

  // ---------------------------------------------------------------------------
  // Arriving flit
  // ---------------------------------------------------------------------------
  wire pkt_flit_t arr = pkt_flit_t'(in_flit);

  wire [PKT_VC_W-1:0] arr_vc  = pkt_flit_vc(arr);
  wire                arr_sof = pkt_flit_sof(arr);
  wire                arr_eof = pkt_flit_eof(arr);
  wire                arr_par = pkt_flit_parity_ok(pkt_uint_t'(PACKET_W), arr);

  pkt_hdr_t arr_hdr;
  assign arr_hdr = pkt_flit_hdr(pkt_uint_t'(PACKET_W), arr);

  wire [VIDX_W-1:0] arr_idx = VIDX_W'(arr_vc);
  wire              arr_ok  = in_valid && (int'(arr_vc) < int'(N_VC));

  // ---------------------------------------------------------------------------
  // Reassembly state, one set per virtual channel
  // ---------------------------------------------------------------------------
  logic                 open_q [N_VC];
  logic [PKT_LEN_W-1:0] rem_q  [N_VC];   // flits still expected after this one
  logic [PKT_VC_W-1:0]  hvc_q  [N_VC];   // the VC the open packet's header named

  wire hdr_arr  = arr_ok && arr_sof;
  wire body_arr = arr_ok && !arr_sof;

  // Length consistency, in one expression per failure mode.
  wire e_len_nested   = hdr_arr  && open_q[arr_idx];
  wire e_len_illegal  = hdr_arr  && !pkt_length_legal(arr_hdr.length);
  wire e_len_hdr_eof  = hdr_arr  && (arr_eof != (arr_hdr.length == PKT_LEN_W'(1)));
  wire e_len_orphan   = body_arr && !open_q[arr_idx];
  wire e_len_short    = body_arr && open_q[arr_idx] && arr_eof &&
                        (rem_q[arr_idx] != PKT_LEN_W'(1));
  wire e_len_long     = body_arr && open_q[arr_idx] && !arr_eof &&
                        (rem_q[arr_idx] <= PKT_LEN_W'(1));

  wire e_length = e_len_nested || e_len_illegal || e_len_hdr_eof ||
                  e_len_orphan || e_len_short || e_len_long;

  wire e_parity = in_valid && !arr_par;
  wire e_vc     = (hdr_arr  && (arr_hdr.vc != arr_vc)) ||
                  (body_arr && open_q[arr_idx] && (hvc_q[arr_idx] != arr_vc)) ||
                  (in_valid && (int'(arr_vc) >= int'(N_VC)));
  wire e_dest   = hdr_arr && (int'(arr_hdr.dest) != int'(DEST_ID));
  wire e_type   = hdr_arr && !pkt_type_legal(arr_hdr.ptype);

  logic [4:0] err_q;
  always_ff @(posedge clk) begin
    if (!rst_n || err_clear) begin
      err_q <= 5'd0;
    end else begin
      if (e_parity) err_q[0] <= 1'b1;
      if (e_length) err_q[1] <= 1'b1;
      if (e_vc)     err_q[2] <= 1'b1;
      if (e_dest)   err_q[3] <= 1'b1;
      if (e_type)   err_q[4] <= 1'b1;
    end
  end

  assign err_sticky = err_q;

  for (genvar v = 0; v < N_VC; v = v + 1) begin : g_reasm
    wire hit = arr_ok && (int'(arr_vc) == v);

    always_ff @(posedge clk) begin
      if (!rst_n) begin
        open_q[v] <= 1'b0;
        rem_q[v]  <= '0;
        hvc_q[v]  <= '0;
      end else if (hit) begin
        if (arr_sof) begin
          hvc_q[v]  <= arr_hdr.vc;
          rem_q[v]  <= (arr_hdr.length > PKT_LEN_W'(1))
                       ? (arr_hdr.length - PKT_LEN_W'(1)) : PKT_LEN_W'(0);
          open_q[v] <= (arr_hdr.length > PKT_LEN_W'(1));
        end else begin
          rem_q[v]  <= (rem_q[v] > PKT_LEN_W'(0))
                       ? (rem_q[v] - PKT_LEN_W'(1)) : PKT_LEN_W'(0);
          if (arr_eof) open_q[v] <= 1'b0;
        end
      end
    end
  end

  // ---------------------------------------------------------------------------
  // Per-VC buffers
  // ---------------------------------------------------------------------------
  logic              fifo_s_valid [N_VC];
  logic              fifo_s_ready [N_VC];
  logic              fifo_m_valid [N_VC];
  logic              fifo_m_ready [N_VC];
  logic [FLIT_W-1:0] fifo_m_data  [N_VC];
  logic [OCC_W-1:0]  fifo_high    [N_VC];

  logic [N_VC*OCC_W-1:0] unused_occ;
  logic [N_VC-1:0] unused_full, unused_empty, unused_af, unused_ae;
  logic [N_VC-1:0] unused_ovf, unused_unf;

  for (genvar v = 0; v < N_VC; v = v + 1) begin : g_vc
    assign fifo_s_valid[v] = arr_ok && (int'(arr_vc) == v);

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
        .s_data           (in_flit),
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

    assign in_credit_out[v] = fifo_m_valid[v] && fifo_m_ready[v];
  end

  // ---------------------------------------------------------------------------
  // Output selection
  // ---------------------------------------------------------------------------
  logic [N_VC-1:0] out_req;
  always_comb begin
    for (int unsigned v = 0; v < N_VC; v = v + 1) begin
      out_req[v] = fifo_m_valid[v] && m_vc_en[v];
    end
  end

  wire [N_VC-1:0]   out_grant;
  wire              out_any;
  wire [VIDX_W-1:0] out_idx;

  pkt_rr_arb #(.N (N_VC)) u_out_arb (
      .clk       (clk),
      .rst_n     (rst_n),
      .req       (out_req),
      // Rotate only on a beat the consumer actually took, so a channel selected
      // during a stall does not lose its turn.
      .update    (m_ready),
      .grant     (out_grant),
      .any_grant (out_any),
      .grant_idx (out_idx)
  );

  always_comb begin
    for (int unsigned v = 0; v < N_VC; v = v + 1) begin
      fifo_m_ready[v] = out_grant[v] && m_ready;
    end
  end

  assign m_valid = out_any;
  assign m_flit  = fifo_m_data[out_idx];

  // ---------------------------------------------------------------------------
  // Telemetry (SPEC 9)
  // ---------------------------------------------------------------------------
  logic [OCC_W-1:0] high_max;
  always_comb begin
    high_max = '0;
    for (int unsigned v = 0; v < N_VC; v = v + 1) begin
      if (fifo_high[v] > high_max) high_max = fifo_high[v];
    end
  end
  assign tel_hiwater = high_max;

  wire [31:0]  c_pkts, c_flits;
  logic [63:0] unused_snap;
  logic [1:0]  unused_sv, unused_wp, unused_wr;

  perf_counter #(.WIDTH (32), .INCR_W (1), .SATURATE (1'b1)) u_c_pkts (
      .clk (clk), .rst_n (rst_n), .enable (1'b1), .event_i (hdr_arr),
      .incr (1'b1), .clear (err_clear), .snapshot (1'b0),
      .count (c_pkts), .snap (unused_snap[31:0]), .snap_valid (unused_sv[0]),
      .wrap_pulse (unused_wp[0]), .wrapped (unused_wr[0]));

  perf_counter #(.WIDTH (32), .INCR_W (1), .SATURATE (1'b1)) u_c_flits (
      .clk (clk), .rst_n (rst_n), .enable (1'b1), .event_i (arr_ok),
      .incr (1'b1), .clear (err_clear), .snapshot (1'b0),
      .count (c_flits), .snap (unused_snap[63:32]), .snap_valid (unused_sv[1]),
      .wrap_pulse (unused_wp[1]), .wrapped (unused_wr[1]));

  assign tel_packets = c_pkts;
  assign tel_flits   = c_flits;

  // `src` and `seq` are decoded here for the waveform and for the consumer, and
  // are deliberately not acted on: loss, duplication and reordering are checked
  // per (source, VC, destination) by the scoreboard in
  // model/cpp/packet/packet_model.hpp, which reads them out of the delivered
  // flit itself. Putting a 32 x 4 expected-sequence table in every egress port
  // would be the scoreboard implemented in hardware, in sixteen copies, to
  // re-derive a fact the flit already carries.
  logic unused_status;
  assign unused_status = ^{unused_occ, unused_full, unused_empty, unused_af,
                           unused_ae, unused_ovf, unused_unf,
                           unused_snap, unused_sv, unused_wp, unused_wr,
                           arr_hdr.src, arr_hdr.seq};

  // ---------------------------------------------------------------------------
  // SPEC 14 assertions
  // ---------------------------------------------------------------------------
`ifndef SYNTHESIS
  always_ff @(posedge clk) begin
    if (rst_n) begin
      // Credits are only ever returned for flits that were sent, so the buffer
      // this module presents to the fabric can never overrun.
      a_egr_no_overrun : assert (!(arr_ok && !fifo_s_ready[arr_idx]))
        else $error("pkt_egress[%0d]: buffer VC%0d overrun", DEST_ID, arr_vc);
      a_egr_length : assert (!e_length)
        else $error("pkt_egress[%0d]: packet length inconsistency on VC%0d (sof=%0b eof=%0b open=%0b rem=%0d len=%0d)",
                    DEST_ID, arr_vc, arr_sof, arr_eof, open_q[arr_idx],
                    rem_q[arr_idx], arr_hdr.length);
      a_egr_parity : assert (!e_parity)
        else $error("pkt_egress[%0d]: flit arrived with bad parity", DEST_ID);
      a_egr_vc : assert (!e_vc)
        else $error("pkt_egress[%0d]: flit VC tag disagrees with its packet's header", DEST_ID);
      a_egr_dest : assert (!e_dest)
        else $error("pkt_egress[%0d]: packet for destination %0d arrived here",
                    DEST_ID, arr_hdr.dest);
      a_egr_type : assert (!e_type)
        else $error("pkt_egress[%0d]: reserved packet type %0d", DEST_ID, arr_hdr.ptype);
    end
  end
`endif

endmodule : pkt_egress

`default_nettype wire
