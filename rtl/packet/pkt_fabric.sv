// -----------------------------------------------------------------------------
// pkt_fabric — the SPEC.md 7.8 multistage packet network (issue #18).
//
// N_PORTS = RADIX**STAGES ingress adapters, STAGES stages of RADIX x RADIX
// switches wired as an R-ary butterfly, and N_PORTS egress reassembly points.
// At the SPEC 7.8 nominal size that is 16 ingress, two stages of four radix-4
// switches, four virtual channels, 512-bit flits.
//
// -----------------------------------------------------------------------------
// 1. The topology, in one paragraph and one function
// -----------------------------------------------------------------------------
// packet_pkg section 5 states the choice and the reasons; this file is the
// wiring. At stage `s` a switch is named by the port index with base-RADIX digit
// (STAGES-1-s) deleted, and a port's position inside that switch is that digit.
// `pkt_bfly_insert()` puts the digit back, so the global index of stage s's
// switch j position k, and the global index that switch's output o drives in
// stage s+1, are the SAME function evaluated twice. There is no wiring table to
// get wrong, and adding a stage changes one parameter.
//
// Stage s routes on destination digit (STAGES-1-s) — most significant first —
// which combined with that wiring gives exactly one path from every ingress to
// every egress. Determinism is the property the whole verification strategy
// rests on: with one path per (source, destination) and one VC lock per packet,
// ORDER IS PRESERVED WITHIN A (source, VC, destination) triple and the egress
// needs a sequence number rather than a reorder buffer to prove it.
//
// Ordering across VCs is explicitly NOT claimed. Two packets from one source to
// one destination on different virtual channels may arrive in either order; that
// is what a virtual channel is for, and the C++ model's ordering rule
// (model/cpp/packet/packet_model.hpp) says so.
//
// -----------------------------------------------------------------------------
// 2. Every credit loop is local
// -----------------------------------------------------------------------------
// Each link — ingress to stage 0, stage s to stage s+1, last stage to egress —
// carries flits forward and credits back, and BOTH ends of every loop are
// adjacent. Nothing in this file connects a credit from stage 0 to stage 1's
// downstream, and no combinational path runs from an egress consumer's `ready`
// to an ingress producer's `ready`: the only backward signal is a registered
// credit pulse one hop long. That is what makes the fabric's timing independent
// of its depth, and it is why STAGES can grow without re-closing timing on
// anything but the new stage.
//
// The buffer-dependency graph is therefore acyclic (packet_pkg section 5), so
// the network is deadlock-free without VC remapping or escape channels.
//
// -----------------------------------------------------------------------------
// 3. Fault injection (SPEC 9 "Fault injection", SPEC 7.8)
// -----------------------------------------------------------------------------
//   fi_flip[p]         flips one or two payload bits of the flit ingress port p
//                      is emitting. One bit is caught by parity at the next hop
//                      and at the egress; two are not (packet_pkg section 3) and
//                      are caught by the payload scoreboard instead. Both are
//                      exercised, so the limits of the parity scheme are a
//                      measured property.
//   fi_credit_kill     suppresses the credit stage s would have returned
//                      upstream for global wire p, VC v. The upstream port runs
//                      out of credit and that virtual channel stops. This is the
//                      fault the issue asks for by name, and it is the
//                      interesting one: a broken credit return produces no wrong
//                      data at all, only an absence, so it is caught by the
//                      progress and credit-conservation checks or by nothing.
//
// Both hooks are inputs rather than registers here; rtl/control/reg_block_packet.sv
// drives them from the PACKET window and control/regmap.json is the source of
// truth for the field layout.
//
// -----------------------------------------------------------------------------
// 4. Telemetry (SPEC 9)
// -----------------------------------------------------------------------------
// Per ingress port: packets accepted. Per egress port: packets delivered. Per
// stage: flits switched, stall cycles, buffer high-water, and the fairness
// metric `tel_stage_maxwait` (pkt_switch_stage section 4), aggregated across the
// switches of that stage — sum for the tallies, maximum for the watermarks,
// because a maximum is the only aggregation of a high-water mark that means
// anything.
// -----------------------------------------------------------------------------

`default_nettype none

module pkt_fabric
  import packet_pkg::*;
#(
    parameter int unsigned PACKET_W = 64,
    parameter int unsigned N_VC     = 4,
    parameter int unsigned RADIX    = 4,
    parameter int unsigned STAGES   = 2,

    // Entries per switch input virtual-channel buffer, and the credits held
    // toward it. Equal by construction: a credit count above the downstream
    // depth is not a bound, and one below it wastes buffering.
    parameter int unsigned VC_DEPTH = 4,

    // Entries per ingress and egress virtual-channel buffer. Deeper than the
    // switch buffers because these are the elastic points that absorb a bursty
    // producer and a stalling consumer; the switch buffers only have to cover
    // one hop's credit round trip.
    parameter int unsigned END_DEPTH = 8,

    // Extra output register stage inside every switch. THE SPEC 18 axis.
    parameter int unsigned OUT_PIPE = 0,

    parameter string STORAGE = "regs"
) (
    input  wire                                clk,
    input  wire                                rst_n,

    // ---- ingress message interfaces (one per source) ------------------------
    input  wire [(RADIX**STAGES)-1:0]              s_valid,
    output wire [(RADIX**STAGES)-1:0]              s_ready,
    input  wire [(RADIX**STAGES)*PACKET_W-1:0]     s_data,
    input  wire [(RADIX**STAGES)-1:0]              s_sof,
    input  wire [(RADIX**STAGES)-1:0]              s_eof,
    input  wire [(RADIX**STAGES)*PKT_DEST_W-1:0]   s_dest,
    input  wire [(RADIX**STAGES)*PKT_TYPE_W-1:0]   s_type,
    input  wire [(RADIX**STAGES)*PKT_VC_W-1:0]     s_vc,
    input  wire [(RADIX**STAGES)*PKT_LEN_W-1:0]    s_len,

    // ---- egress flit interfaces (one per destination) -----------------------
    output wire [(RADIX**STAGES)-1:0]                 m_valid,
    input  wire [(RADIX**STAGES)-1:0]                 m_ready,
    output wire [(RADIX**STAGES)*(PACKET_W+5)-1:0]    m_flit,
    input  wire [(RADIX**STAGES)*N_VC-1:0]            m_vc_en,

    // ---- fault injection ----------------------------------------------------
    input  wire [(RADIX**STAGES)*2-1:0]               fi_flip,
    input  wire [STAGES*(RADIX**STAGES)*N_VC-1:0]     fi_credit_kill,

    // ---- telemetry (SPEC 9) -------------------------------------------------
    output wire [(RADIX**STAGES)*32-1:0]              tel_ing_packets,
    output wire [(RADIX**STAGES)*32-1:0]              tel_egr_packets,
    output wire [STAGES*32-1:0]                       tel_stage_flits,
    output wire [STAGES*32-1:0]                       tel_stage_stall,
    output wire [STAGES*16-1:0]                       tel_stage_maxwait,
    output wire [STAGES*8-1:0]                        tel_stage_hiwater,

    // ---- sticky errors ------------------------------------------------------
    output wire [(RADIX**STAGES)*4-1:0]               ing_err,
    output wire [(RADIX**STAGES)*5-1:0]               egr_err,

    input  wire                                       tel_clear
);

  localparam int unsigned N_PORTS   = RADIX**STAGES;
  localparam int unsigned N_SWITCH  = N_PORTS / RADIX;
  localparam int unsigned FLIT_W    = PACKET_W + PKT_FLIT_CTRL_W;
  localparam int unsigned SW_OCC_W  = $clog2(VC_DEPTH + 1);
  localparam int unsigned EN_OCC_W  = $clog2(END_DEPTH + 1);

`ifndef SYNTHESIS
  initial begin
    // The configuration cross-check (config_pkg::N_VIRTUAL_CHANS against
    // PKT_N_VC, and config_pkg::PACKET_W against this instance) lives in
    // sim/verilator/tops/packet_top.sv, not here: this module is instantiated by
    // the SPEC 18 calibration wrappers as well, which have no generated
    // configuration package, and a design module that cannot elaborate outside
    // the simulation build is a design module that cannot be calibrated.
    if (STAGES < 1) begin
      $fatal(1, "pkt_fabric: STAGES=%0d is illegal; minimum is 1", STAGES);
    end
    if (N_PORTS > (1 << PKT_DEST_W)) begin
      $fatal(1, "pkt_fabric: %0d ports do not fit the %0d-bit destination field",
             N_PORTS, PKT_DEST_W);
    end
    if (N_PORTS > (1 << PKT_SRC_W)) begin
      $fatal(1, "pkt_fabric: %0d ports do not fit the %0d-bit source field",
             N_PORTS, PKT_SRC_W);
    end
  end
`endif

  // ---------------------------------------------------------------------------
  // Inter-stage wires. Index [s] is the input side of stage s; index [STAGES] is
  // the egress side. Credits run backwards on the same index.
  // ---------------------------------------------------------------------------
  logic              w_valid  [STAGES+1][N_PORTS];
  logic [FLIT_W-1:0] w_flit   [STAGES+1][N_PORTS];
  logic [N_VC-1:0]   w_credit [STAGES+1][N_PORTS];

  // ---------------------------------------------------------------------------
  // Ingress adapters
  // ---------------------------------------------------------------------------
  logic [EN_OCC_W-1:0] unused_ing_hw [N_PORTS];
  logic [N_PORTS*32-1:0] unused_ing_flits, unused_ing_stall;

  for (genvar p = 0; p < N_PORTS; p = p + 1) begin : g_ing
    pkt_ingress #(
        .PACKET_W (PACKET_W),
        .N_VC     (N_VC),
        .SRC_ID   (p),
        .VC_DEPTH (END_DEPTH),
        .CREDITS  (VC_DEPTH),
        .STORAGE  (STORAGE)
    ) u_ing (
        .clk         (clk),
        .rst_n       (rst_n),
        .s_valid     (s_valid[p]),
        .s_ready     (s_ready[p]),
        .s_data      (s_data[p*PACKET_W +: PACKET_W]),
        .s_sof       (s_sof[p]),
        .s_eof       (s_eof[p]),
        .s_dest      (s_dest[p*PKT_DEST_W +: PKT_DEST_W]),
        .s_type      (s_type[p*PKT_TYPE_W +: PKT_TYPE_W]),
        .s_vc        (s_vc[p*PKT_VC_W +: PKT_VC_W]),
        .s_len       (s_len[p*PKT_LEN_W +: PKT_LEN_W]),
        .m_valid     (w_valid[0][p]),
        .m_flit      (w_flit[0][p]),
        .m_credit    (w_credit[0][p]),
        .fi_flip     (fi_flip[p*2 +: 2]),
        .tel_packets (tel_ing_packets[p*32 +: 32]),
        .tel_flits   (unused_ing_flits[p*32 +: 32]),
        .tel_stall   (unused_ing_stall[p*32 +: 32]),
        .tel_hiwater (unused_ing_hw[p]),
        .err_sticky  (ing_err[p*4 +: 4]),
        .err_clear   (tel_clear)
    );
  end

  // ---------------------------------------------------------------------------
  // Switch stages
  // ---------------------------------------------------------------------------
  logic [31:0]        sw_flits   [STAGES][N_SWITCH];
  logic [31:0]        sw_stall   [STAGES][N_SWITCH];
  logic [15:0]        sw_maxwait [STAGES][N_SWITCH];
  logic [SW_OCC_W-1:0] sw_hiwater [STAGES][N_SWITCH];

  for (genvar s = 0; s < STAGES; s = s + 1) begin : g_stage
    // Destination digit this stage routes on: most significant first.
    localparam int unsigned DIG = STAGES - 1 - s;

    for (genvar j = 0; j < N_SWITCH; j = j + 1) begin : g_sw
      wire [RADIX-1:0]          sw_in_valid;
      wire [RADIX*FLIT_W-1:0]   sw_in_flit;
      wire [RADIX*N_VC-1:0]     sw_in_credit;
      wire [RADIX-1:0]          sw_out_valid;
      wire [RADIX*FLIT_W-1:0]   sw_out_flit;
      wire [RADIX*N_VC-1:0]     sw_out_credit;
      wire [RADIX*N_VC-1:0]     sw_fi_kill;

      for (genvar k = 0; k < RADIX; k = k + 1) begin : g_wire
        // The butterfly wiring rule, evaluated once per port of this switch.
        localparam int unsigned GP = int'(pkt_bfly_insert(pkt_uint_t'(j),
                                                          pkt_uint_t'(k),
                                                          pkt_uint_t'(DIG),
                                                          pkt_uint_t'(RADIX)));

        assign sw_in_valid[k]                 = w_valid[s][GP];
        assign sw_in_flit[k*FLIT_W +: FLIT_W] = w_flit[s][GP];
        assign w_credit[s][GP]                = sw_in_credit[k*N_VC +: N_VC];

        assign w_valid[s+1][GP]               = sw_out_valid[k];
        assign w_flit[s+1][GP]                = sw_out_flit[k*FLIT_W +: FLIT_W];
        assign sw_out_credit[k*N_VC +: N_VC]  = w_credit[s+1][GP];

        assign sw_fi_kill[k*N_VC +: N_VC] =
            fi_credit_kill[(s*N_PORTS + GP)*N_VC +: N_VC];
      end

      pkt_switch_stage #(
          .PACKET_W   (PACKET_W),
          .N_VC       (N_VC),
          .RADIX      (RADIX),
          .DEST_DIGIT (DIG),
          .VC_DEPTH   (VC_DEPTH),
          .CREDITS    (VC_DEPTH),
          .OUT_PIPE   (OUT_PIPE),
          .STORAGE    (STORAGE)
      ) u_sw (
          .clk            (clk),
          .rst_n          (rst_n),
          .in_valid       (sw_in_valid),
          .in_flit        (sw_in_flit),
          .in_credit_out  (sw_in_credit),
          .out_valid      (sw_out_valid),
          .out_flit       (sw_out_flit),
          .out_credit_in  (sw_out_credit),
          .fi_credit_kill (sw_fi_kill),
          .tel_flits      (sw_flits[s][j]),
          .tel_stall      (sw_stall[s][j]),
          .tel_hiwater    (sw_hiwater[s][j]),
          .tel_max_wait   (sw_maxwait[s][j]),
          .tel_clear      (tel_clear)
      );
    end
  end

  // ---------------------------------------------------------------------------
  // Egress reassembly points
  // ---------------------------------------------------------------------------
  logic [EN_OCC_W-1:0]   unused_egr_hw [N_PORTS];
  logic [N_PORTS*32-1:0] unused_egr_flits;

  for (genvar p = 0; p < N_PORTS; p = p + 1) begin : g_egr
    pkt_egress #(
        .PACKET_W (PACKET_W),
        .N_VC     (N_VC),
        .DEST_ID  (p),
        .VC_DEPTH (END_DEPTH),
        .STORAGE  (STORAGE)
    ) u_egr (
        .clk           (clk),
        .rst_n         (rst_n),
        .in_valid      (w_valid[STAGES][p]),
        .in_flit       (w_flit[STAGES][p]),
        .in_credit_out (w_credit[STAGES][p]),
        .m_valid       (m_valid[p]),
        .m_ready       (m_ready[p]),
        .m_flit        (m_flit[p*FLIT_W +: FLIT_W]),
        .m_vc_en       (m_vc_en[p*N_VC +: N_VC]),
        .tel_packets   (tel_egr_packets[p*32 +: 32]),
        .tel_flits     (unused_egr_flits[p*32 +: 32]),
        .tel_hiwater   (unused_egr_hw[p]),
        .err_sticky    (egr_err[p*5 +: 5]),
        .err_clear     (tel_clear)
    );
  end

  // ---------------------------------------------------------------------------
  // Per-stage telemetry aggregation
  //
  // Sums for the tallies (saturating at all ones, the same policy perf_counter
  // uses and for the same reason: a wrapped error tally can read zero on a
  // permanently faulting fabric), maxima for the watermarks.
  // ---------------------------------------------------------------------------
  for (genvar s = 0; s < STAGES; s = s + 1) begin : g_agg
    logic [31:0] f_sum, t_sum;
    logic [15:0] w_max;
    logic [7:0]  h_max;

    always_comb begin
      f_sum = 32'd0;
      t_sum = 32'd0;
      w_max = 16'd0;
      h_max = 8'd0;
      for (int unsigned j = 0; j < N_SWITCH; j = j + 1) begin
        f_sum = ((f_sum + sw_flits[s][j]) < f_sum) ? 32'hFFFF_FFFF
                                                   : (f_sum + sw_flits[s][j]);
        t_sum = ((t_sum + sw_stall[s][j]) < t_sum) ? 32'hFFFF_FFFF
                                                   : (t_sum + sw_stall[s][j]);
        if (sw_maxwait[s][j] > w_max)     w_max = sw_maxwait[s][j];
        if (8'(sw_hiwater[s][j]) > h_max) h_max = 8'(sw_hiwater[s][j]);
      end
    end

    assign tel_stage_flits[s*32 +: 32]   = f_sum;
    assign tel_stage_stall[s*32 +: 32]   = t_sum;
    assign tel_stage_maxwait[s*16 +: 16] = w_max;
    assign tel_stage_hiwater[s*8 +: 8]   = h_max;
  end

  // Deliberately unused per-endpoint telemetry, gathered so that "not exported
  // at this level" is written down rather than silently dropped.
  logic unused_status;
  always_comb begin
    unused_status = 1'b0;
    for (int unsigned p = 0; p < N_PORTS; p = p + 1) begin
      unused_status = unused_status ^ (^unused_ing_hw[p]) ^ (^unused_egr_hw[p]);
    end
    unused_status = unused_status ^ (^unused_ing_flits) ^ (^unused_ing_stall) ^
                    (^unused_egr_flits);
  end

endmodule : pkt_fabric

`default_nettype wire
