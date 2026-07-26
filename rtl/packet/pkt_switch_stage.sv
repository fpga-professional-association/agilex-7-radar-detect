// -----------------------------------------------------------------------------
// pkt_switch_stage — one pipelined switching stage of the SPEC.md 7.8 packet
// network (issue #18). THE calibration unit of SPEC.md 18 item 9.
//
// A RADIX x RADIX buffered switch with N_VC virtual channels per port,
// credit-based flow control in both directions, and TWO levels of round-robin
// arbitration separated by a register. rtl/packet/pkt_fabric.sv replicates this
// module into a multistage butterfly; nothing about this file knows how many
// stages there are, and the only thing it knows about the topology is which
// destination digit it routes on (`DEST_DIGIT`).
//
// -----------------------------------------------------------------------------
// 1. Structure, one cycle at a time
// -----------------------------------------------------------------------------
//   input link ---> per-(port,VC) sync_fifo ---> VC allocation ---> switch
//                    (issue #6)                   (registered)     allocation
//                                                                       |
//                                                              output register
//                                                              (+ OUT_PIPE)
//
//   cycle N     Every buffer's head is a REGISTER (sync_fifo with SHOW_AHEAD=0).
//               A head that carries SOF has its route computed — one slice of
//               the destination field, no arithmetic — and requests the output
//               VC it wants. One pkt_rr_arb per (output, VC) over the RADIX
//               inputs picks a winner, and the winner is LATCHED into that
//               output VC's lock register.
//
//   cycle N+1   Switch allocation reads the LOCK REGISTERS, the buffer heads and
//               the credit counters — all registers — and one pkt_rr_arb per
//               output port picks which of its locked VCs transmits. The grant
//               pops that buffer and loads the output register.
//
// THE REGISTER BETWEEN THE TWO LEVELS IS THE POINT. SPEC 7.8 requires pipelined
// arbitration and forbids an unregistered monolithic crossbar; the failure mode
// it is aiming at is an iSLIP-style request/grant/accept loop resolved
// combinationally, which is a cone whose depth grows with RADIX x N_VC and which
// no amount of Hyper-Register retiming can break because the loop closes within
// one cycle (SPEC 23: "treat feedback-loop latency as an architectural
// constraint"). Here the VC allocator's output reaches the switch allocator only
// through `vc_lock_q`, so the longest arbitration cone is ONE pkt_rr_arb, and
// the two levels can be retimed independently.
//
// The cost of the register is one cycle of latency per hop on a packet's FIRST
// flit only: the lock persists for the rest of the packet, so flits 2..L are
// switched at one per cycle with no re-arbitration.
//
// -----------------------------------------------------------------------------
// 2. Virtual channels: what is and is not claimed
// -----------------------------------------------------------------------------
// An output VC is LOCKED to one input for the duration of a packet, and released
// on the flit carrying EOF. That is what makes a packet arrive contiguously and
// in order at the far end, and it is why the egress needs no reorder buffer.
//
// The output PORT is not locked. Every cycle the switch allocator is free to
// pick a different VC, so a virtual channel whose downstream buffer is full —
// zero credits, therefore no request — simply drops out of the arbitration and
// the other channels keep the link busy. THAT is the SPEC 7.8 purpose of virtual
// channels, and sim/tests/test_packet.cpp's VC-isolation pass is the measurement
// of it: VC0 is starved of credit at an egress and VC1's throughput must not
// change.
//
// Input VC index equals output VC index — there is no VC remapping. Remapping
// buys deadlock freedom in a network with cycles; this one is a butterfly, whose
// buffer-dependency graph is acyclic by construction because every flit moves
// strictly forward through the stages. A packet can therefore never wait on a
// buffer that is waiting on it, and adding a VC-swap table would cost a
// per-packet renaming register to solve a problem the topology does not have.
//
// -----------------------------------------------------------------------------
// 3. Credits
// -----------------------------------------------------------------------------
// Downstream: `credit_q[o][v]` counts the free slots this stage believes the
// next stage's (o,v) buffer has. It resets to CREDITS, decrements when a flit is
// sent, and increments on `out_credit_in`. A flit is sent only when the count is
// non-zero, so the downstream buffer cannot overflow — which is asserted at the
// downstream input rather than assumed here.
//
// Upstream: this stage returns one credit on `in_credit_out[i][v]` for each flit
// that LEAVES buffer (i,v). Returning on departure rather than on arrival is
// what makes the count a genuine free-slot count.
//
// Every credit loop is closed between ADJACENT stages and is one registered
// pulse wide. No credit signal crosses more than one hop, which is the property
// that keeps the fabric's timing independent of its depth.
//
// -----------------------------------------------------------------------------
// 4. Fairness, and the metric that is actually checked
// -----------------------------------------------------------------------------
// Round robin at both levels is starvation-free by construction (pkt_rr_arb),
// but "starvation-free eventually" is not a number. `tel_max_wait` is the
// number: for every buffered head flit it counts the cycles on which THE OUTPUT
// THAT FLIT WANTS GRANTED SOMEBODY ELSE, and reports the maximum ever observed.
//
// Counting overtakes rather than idle cycles is deliberate. A head that waits
// because the whole network is backpressured has not been treated unfairly, and
// a metric that counted those cycles would grow with the test's stall profile
// and measure the testbench. This one grows only when the arbiter chose against
// the flit, so it is bounded by the arbitration policy alone, and
// sim/tests/test_packet.cpp checks it against that bound under a hotspot in
// which every source targets one egress port.
//
// Reset (SPEC 23): control state only — locks, owners, credits, pointers, valid
// bits, counters. Flit payloads and the output flit register are never reset.
// -----------------------------------------------------------------------------

`default_nettype none

module pkt_switch_stage
  import packet_pkg::*;
#(
    parameter int unsigned PACKET_W = 64,
    parameter int unsigned N_VC     = 4,

    // Ports in and out. Must be a power of two: the routing digit is then a
    // SLICE of the destination field rather than a division, which is checked at
    // elaboration rather than hoped for.
    parameter int unsigned RADIX = 4,

    // Which base-RADIX digit of the destination this stage routes on. Digit 0 is
    // least significant. pkt_fabric.sv passes STAGES-1-s, so stage 0 routes on
    // the most significant digit.
    parameter int unsigned DEST_DIGIT = 0,

    // Entries per input virtual-channel buffer.
    parameter int unsigned VC_DEPTH = 4,

    // Credits held toward the DOWNSTREAM buffer. Must not exceed that buffer's
    // depth; pkt_fabric.sv passes the same VC_DEPTH to both.
    parameter int unsigned CREDITS = 4,

    // Extra output register stage. 0 = one register between the switch
    // allocator's grant and the link; 1 = two. THE axis the SPEC 18 sweep
    // measures: whether a second registered hop buys Fmax at 512-bit flits, or
    // whether Hyper-Register retiming already recovers it from the first.
    parameter int unsigned OUT_PIPE = 0,

    // sync_fifo storage style for the VC buffers.
    parameter string STORAGE = "regs"
) (
    input  wire                          clk,
    input  wire                          rst_n,

    // ---- upstream link (credit controlled) ---------------------------------
    input  wire [RADIX-1:0]              in_valid,
    input  wire [RADIX*(PACKET_W+5)-1:0] in_flit,
    output wire [RADIX*N_VC-1:0]         in_credit_out,

    // ---- downstream link (credit controlled) -------------------------------
    output wire [RADIX-1:0]              out_valid,
    output wire [RADIX*(PACKET_W+5)-1:0] out_flit,
    input  wire [RADIX*N_VC-1:0]         out_credit_in,

    // ---- fault injection (SPEC 7.8 error-injection hook) -------------------
    // Bit (i*N_VC+v) high SUPPRESSES the credit this stage would have returned
    // upstream for buffer (i,v). The upstream port then runs out of credit and
    // stops; the test's credit-conservation and progress checks are what must
    // notice. Broken credit return is the fault chosen because it is the one
    // failure a fabric can have that produces no wrong data at all — only an
    // absence — and an absence is the hardest thing for a scoreboard to catch.
    input  wire [RADIX*N_VC-1:0]         fi_credit_kill,

    // ---- telemetry (SPEC 9) -------------------------------------------------
    output wire [31:0]                   tel_flits,
    output wire [31:0]                   tel_stall,
    output wire [$clog2(VC_DEPTH+1)-1:0] tel_hiwater,
    output wire [15:0]                   tel_max_wait,

    input  wire                          tel_clear
);

  localparam int unsigned FLIT_W  = PACKET_W + PKT_FLIT_CTRL_W;
  localparam int unsigned PIDX_W  = (RADIX > 1) ? $clog2(RADIX) : 1;
  localparam int unsigned VIDX_W  = (N_VC > 1) ? $clog2(N_VC) : 1;
  localparam int unsigned CRED_W  = $clog2(CREDITS + 1);
  localparam int unsigned OCC_W   = $clog2(VC_DEPTH + 1);

`ifndef SYNTHESIS
  initial begin
    if (!pkt_packet_w_ok(pkt_uint_t'(PACKET_W))) begin
      $fatal(1, "pkt_switch_stage: PACKET_W=%0d cannot carry a %0d-bit header, or exceeds %0d",
             PACKET_W, PKT_HDR_W, PKT_MAX_PACKET_W);
    end
    if (RADIX < 2 || (RADIX & (RADIX - 1)) != 0) begin
      $fatal(1, "pkt_switch_stage: RADIX=%0d must be a power of two >= 2; the routing digit is a slice of the destination field, not a division",
             RADIX);
    end
    if (N_VC < 1 || N_VC > int'(PKT_N_VC)) begin
      $fatal(1, "pkt_switch_stage: N_VC=%0d is outside 1..%0d", N_VC, PKT_N_VC);
    end
    if ((DEST_DIGIT + 1) * PIDX_W > int'(PKT_DEST_W)) begin
      $fatal(1, "pkt_switch_stage: DEST_DIGIT=%0d needs bits %0d..%0d of a %0d-bit destination field",
             DEST_DIGIT, DEST_DIGIT * PIDX_W, (DEST_DIGIT + 1) * PIDX_W - 1, PKT_DEST_W);
    end
    if (CREDITS < 1 || CREDITS > VC_DEPTH) begin
      $fatal(1, "pkt_switch_stage: CREDITS=%0d must be in 1..VC_DEPTH=%0d", CREDITS, VC_DEPTH);
    end
    if (OUT_PIPE > 1) begin
      $fatal(1, "pkt_switch_stage: OUT_PIPE=%0d is outside 0..1", OUT_PIPE);
    end
  end
`endif

  // ---------------------------------------------------------------------------
  // Input buffers, one per (port, VC)
  // ---------------------------------------------------------------------------
  logic              fifo_s_valid [RADIX][N_VC];
  logic              fifo_s_ready [RADIX][N_VC];
  logic              fifo_m_valid [RADIX][N_VC];
  logic              fifo_m_ready [RADIX][N_VC];
  logic [FLIT_W-1:0] fifo_m_data  [RADIX][N_VC];
  logic [OCC_W-1:0]  fifo_high    [RADIX][N_VC];

  // Deliberately unused sync_fifo status, gathered so that "not used here" is
  // written down; `unused_` is the prefix Verilator's --unused-regexp knows.
  logic [RADIX*N_VC*OCC_W-1:0] unused_occ;
  logic [RADIX*N_VC-1:0] unused_full, unused_empty, unused_af, unused_ae;
  logic [RADIX*N_VC-1:0] unused_ovf, unused_unf;

  // Credits withheld by the fault-injection hook, per buffer. See the credit
  // return below for why they are held rather than dropped.
  logic [CRED_W-1:0] held_q [RADIX][N_VC];

  for (genvar i = 0; i < RADIX; i = i + 1) begin : g_port
    wire [FLIT_W-1:0] link_flit = in_flit[i*FLIT_W +: FLIT_W];
    wire [PKT_VC_W-1:0] link_vc = pkt_flit_vc(pkt_flit_t'(link_flit));

    for (genvar v = 0; v < N_VC; v = v + 1) begin : g_vc
      localparam int unsigned FIDX = i * N_VC + v;

      assign fifo_s_valid[i][v] = in_valid[i] && (int'(link_vc) == v);

      sync_fifo #(
          .WIDTH      (FLIT_W),
          .DEPTH      (VC_DEPTH),
          .SHOW_AHEAD (1'b0),
          .STORAGE    (STORAGE)
      ) u_fifo (
          .clk              (clk),
          .rst_n            (rst_n),
          .s_valid          (fifo_s_valid[i][v]),
          .s_ready          (fifo_s_ready[i][v]),
          .s_data           (link_flit),
          .m_valid          (fifo_m_valid[i][v]),
          .m_ready          (fifo_m_ready[i][v]),
          .m_data           (fifo_m_data[i][v]),
          .occupancy        (unused_occ[FIDX*OCC_W +: OCC_W]),
          .full             (unused_full[FIDX]),
          .empty            (unused_empty[FIDX]),
          .almost_full      (unused_af[FIDX]),
          .almost_empty     (unused_ae[FIDX]),
          .high_water       (fifo_high[i][v]),
          .overflow_sticky  (unused_ovf[FIDX]),
          .underflow_sticky (unused_unf[FIDX]),
          .sticky_clear     (tel_clear)
      );

      // Credit returned upstream when a flit LEAVES this buffer.
      //
      // The fault-injection hook DELAYS the credit rather than dropping it. A
      // dropped credit is unrecoverable by construction — the upstream port's
      // counter never gets it back, so that virtual channel is dead for the rest
      // of the run and the injection is a one-way trip that cannot be reverted.
      // Holding the credits and releasing them when the hook clears produces the
      // same stall with a defined end, which is what makes "inject, observe the
      // checks fire, revert, observe a full recovery" a test rather than a
      // demolition. The holding counter can never exceed CREDITS, because only
      // that many flits can be in the buffer; a_sw_credit_held asserts it.
      wire pop_now = fifo_m_valid[i][v] && fifo_m_ready[i][v];
      wire kill_now = fi_credit_kill[FIDX];
      wire release_now = !kill_now && !pop_now && (held_q[i][v] != CRED_W'(0));

      assign in_credit_out[FIDX] = (pop_now && !kill_now) || release_now;

      always_ff @(posedge clk) begin
        if (!rst_n) begin
          held_q[i][v] <= CRED_W'(0);
        end else if (pop_now && kill_now) begin
          held_q[i][v] <= held_q[i][v] + CRED_W'(1);
        end else if (release_now) begin
          held_q[i][v] <= held_q[i][v] - CRED_W'(1);
        end
      end
    end
  end

  // ---------------------------------------------------------------------------
  // Head decode and routing
  //
  // The route is ONE SLICE of the destination field. It is computed from the
  // head register combinationally when the head carries SOF, and held in
  // `route_q` for the body flits — so a body flit never re-reads a header it
  // does not carry.
  // ---------------------------------------------------------------------------
  logic [PIDX_W-1:0] route_q [RADIX][N_VC];
  logic [PIDX_W-1:0] route_eff [RADIX][N_VC];
  logic              head_sof [RADIX][N_VC];
  logic              head_eof [RADIX][N_VC];

  pkt_flit_t             head_flit_v;
  logic [PKT_DEST_W-1:0] head_dest_v;

  always_comb begin
    head_flit_v = '0;
    head_dest_v = '0;
    for (int unsigned i = 0; i < RADIX; i = i + 1) begin
      for (int unsigned v = 0; v < N_VC; v = v + 1) begin
        head_flit_v     = pkt_flit_t'(fifo_m_data[i][v]);
        head_dest_v     = pkt_flit_dest(pkt_uint_t'(PACKET_W), head_flit_v);
        head_sof[i][v]  = pkt_flit_sof(head_flit_v);
        head_eof[i][v]  = pkt_flit_eof(head_flit_v);
        route_eff[i][v] = head_sof[i][v]
                          ? PIDX_W'(head_dest_v >> (DEST_DIGIT * PIDX_W))
                          : route_q[i][v];
      end
    end
  end

  // ---------------------------------------------------------------------------
  // Level 1 — virtual-channel allocation (cycle N)
  // ---------------------------------------------------------------------------
  logic              vc_lock_q  [RADIX][N_VC];
  logic [PIDX_W-1:0] vc_owner_q [RADIX][N_VC];

  logic [RADIX-1:0]  va_req   [RADIX][N_VC];
  wire  [RADIX-1:0]  unused_va_grant [RADIX][N_VC];
  wire               va_any   [RADIX][N_VC];
  wire [PIDX_W-1:0]  va_idx   [RADIX][N_VC];

  always_comb begin
    for (int unsigned o = 0; o < RADIX; o = o + 1) begin
      for (int unsigned v = 0; v < N_VC; v = v + 1) begin
        va_req[o][v] = '0;
        for (int unsigned i = 0; i < RADIX; i = i + 1) begin
          va_req[o][v][i] = fifo_m_valid[i][v] && head_sof[i][v] &&
                            (int'(route_eff[i][v]) == int'(o)) &&
                            !vc_lock_q[o][v];
        end
      end
    end
  end

  for (genvar o = 0; o < RADIX; o = o + 1) begin : g_va_out
    for (genvar v = 0; v < N_VC; v = v + 1) begin : g_va_vc
      pkt_rr_arb #(.N (RADIX)) u_va (
          .clk       (clk),
          .rst_n     (rst_n),
          .req       (va_req[o][v]),
          .update    (1'b1),
          .grant     (unused_va_grant[o][v]),
          .any_grant (va_any[o][v]),
          .grant_idx (va_idx[o][v])
      );
    end
  end

  // ---------------------------------------------------------------------------
  // Level 2 — switch allocation (cycle N+1), from registers only
  // ---------------------------------------------------------------------------
  logic [CRED_W-1:0] credit_q [RADIX][N_VC];

  logic [N_VC-1:0]   sa_req   [RADIX];
  wire  [N_VC-1:0]   sa_grant [RADIX];
  wire               sa_any   [RADIX];
  wire  [VIDX_W-1:0] sa_idx   [RADIX];

  always_comb begin
    for (int unsigned o = 0; o < RADIX; o = o + 1) begin
      sa_req[o] = '0;
      for (int unsigned v = 0; v < N_VC; v = v + 1) begin
        sa_req[o][v] = vc_lock_q[o][v] &&
                       fifo_m_valid[vc_owner_q[o][v]][v] &&
                       (credit_q[o][v] != CRED_W'(0));
      end
    end
  end

  for (genvar o = 0; o < RADIX; o = o + 1) begin : g_sa
    pkt_rr_arb #(.N (N_VC)) u_sa (
        .clk       (clk),
        .rst_n     (rst_n),
        .req       (sa_req[o]),
        .update    (1'b1),
        .grant     (sa_grant[o]),
        .any_grant (sa_any[o]),
        .grant_idx (sa_idx[o])
    );
  end

  // The buffer each output pops this cycle, and the flit it takes.
  logic [PIDX_W-1:0] sa_src   [RADIX];
  logic [FLIT_W-1:0] sa_flit  [RADIX];
  logic              sa_eof   [RADIX];

  always_comb begin
    for (int unsigned o = 0; o < RADIX; o = o + 1) begin
      sa_src[o]  = vc_owner_q[o][sa_idx[o]];
      sa_flit[o] = fifo_m_data[sa_src[o]][sa_idx[o]];
      sa_eof[o]  = head_eof[sa_src[o]][sa_idx[o]];
    end
  end

  // Buffer read enables. Exactly one output can pop a given buffer, because a
  // buffer's route is unique and its output VC is locked to it.
  always_comb begin
    for (int unsigned i = 0; i < RADIX; i = i + 1) begin
      for (int unsigned v = 0; v < N_VC; v = v + 1) begin
        fifo_m_ready[i][v] = 1'b0;
      end
    end
    for (int unsigned o = 0; o < RADIX; o = o + 1) begin
      if (sa_any[o]) fifo_m_ready[sa_src[o]][sa_idx[o]] = 1'b1;
    end
  end

  // ---------------------------------------------------------------------------
  // Lock, owner, route and credit registers
  // ---------------------------------------------------------------------------
  for (genvar o = 0; o < RADIX; o = o + 1) begin : g_lock
    for (genvar v = 0; v < N_VC; v = v + 1) begin : g_lock_vc
      wire release_now = sa_any[o] && (int'(sa_idx[o]) == v) && sa_eof[o];

      always_ff @(posedge clk) begin
        if (!rst_n) begin
          vc_lock_q[o][v]  <= 1'b0;
          vc_owner_q[o][v] <= '0;
        end else if (release_now) begin
          vc_lock_q[o][v]  <= 1'b0;
        end else if (va_any[o][v]) begin
          vc_lock_q[o][v]  <= 1'b1;
          vc_owner_q[o][v] <= va_idx[o][v];
        end
      end

      wire send_now = sa_any[o] && (int'(sa_idx[o]) == v);

      always_ff @(posedge clk) begin
        if (!rst_n) begin
          credit_q[o][v] <= CRED_W'(CREDITS);
        end else begin
          case ({send_now, out_credit_in[o*N_VC + v]})
            2'b10:   credit_q[o][v] <= credit_q[o][v] - CRED_W'(1);
            2'b01:   credit_q[o][v] <= credit_q[o][v] + CRED_W'(1);
            default: credit_q[o][v] <= credit_q[o][v];
          endcase
        end
      end
    end
  end

  // The route of the packet currently occupying buffer (i,v), latched when its
  // header flit is popped so the body flits follow it.
  for (genvar i = 0; i < RADIX; i = i + 1) begin : g_route
    for (genvar v = 0; v < N_VC; v = v + 1) begin : g_route_vc
      always_ff @(posedge clk) begin
        if (!rst_n) begin
          route_q[i][v] <= '0;
        end else if (fifo_m_valid[i][v] && fifo_m_ready[i][v] && head_sof[i][v]) begin
          route_q[i][v] <= route_eff[i][v];
        end
      end
    end
  end

  // ---------------------------------------------------------------------------
  // Output registers
  // ---------------------------------------------------------------------------
  logic [RADIX-1:0]  out_valid_q;
  logic [FLIT_W-1:0] out_flit_q [RADIX];

  for (genvar o = 0; o < RADIX; o = o + 1) begin : g_out
    always_ff @(posedge clk) begin
      if (!rst_n) out_valid_q[o] <= 1'b0;
      else        out_valid_q[o] <= sa_any[o];
    end

    // Payload register: no reset (SPEC 23); guarded by its valid bit.
    always_ff @(posedge clk) begin
      if (sa_any[o]) out_flit_q[o] <= sa_flit[o];
    end
  end

  if (OUT_PIPE == 0) begin : g_pipe0
    for (genvar o = 0; o < RADIX; o = o + 1) begin : g_o
      assign out_valid[o]                = out_valid_q[o];
      assign out_flit[o*FLIT_W +: FLIT_W] = out_flit_q[o];
    end
  end else begin : g_pipe1
    logic [RADIX-1:0]  out2_valid_q;
    logic [FLIT_W-1:0] out2_flit_q [RADIX];

    for (genvar o = 0; o < RADIX; o = o + 1) begin : g_o
      always_ff @(posedge clk) begin
        if (!rst_n) out2_valid_q[o] <= 1'b0;
        else        out2_valid_q[o] <= out_valid_q[o];
      end
      always_ff @(posedge clk) begin
        if (out_valid_q[o]) out2_flit_q[o] <= out_flit_q[o];
      end
      assign out_valid[o]                 = out2_valid_q[o];
      assign out_flit[o*FLIT_W +: FLIT_W] = out2_flit_q[o];
    end
  end

  // ---------------------------------------------------------------------------
  // Telemetry (SPEC 9) and the fairness metric (section 4)
  // ---------------------------------------------------------------------------
  logic flit_event;
  logic stall_event;

  always_comb begin
    flit_event  = 1'b0;
    stall_event = 1'b0;
    for (int unsigned o = 0; o < RADIX; o = o + 1) begin
      if (sa_any[o]) flit_event = 1'b1;
    end
    for (int unsigned i = 0; i < RADIX; i = i + 1) begin
      for (int unsigned v = 0; v < N_VC; v = v + 1) begin
        if (fifo_m_valid[i][v] && !fifo_m_ready[i][v]) stall_event = 1'b1;
      end
    end
  end

  // Overtake counters: cycles on which a buffered head's chosen output granted
  // somebody else. Plain registers rather than perf_counter instances — this is
  // a per-buffer MAXIMUM tracker, not an event tally, and perf_counter has no
  // notion of a running maximum. The design's event tallies below ARE
  // perf_counters.
  logic [15:0] wait_q [RADIX][N_VC];
  logic [15:0] wait_max_q;

  for (genvar i = 0; i < RADIX; i = i + 1) begin : g_wait
    for (genvar v = 0; v < N_VC; v = v + 1) begin : g_wait_vc
      wire overtaken = fifo_m_valid[i][v] && !fifo_m_ready[i][v] &&
                       sa_any[route_eff[i][v]];
      always_ff @(posedge clk) begin
        if (!rst_n || tel_clear) begin
          wait_q[i][v] <= 16'd0;
        end else if (fifo_m_valid[i][v] && fifo_m_ready[i][v]) begin
          wait_q[i][v] <= 16'd0;
        end else if (overtaken && (wait_q[i][v] != 16'hFFFF)) begin
          wait_q[i][v] <= wait_q[i][v] + 16'd1;
        end
      end
    end
  end

  logic [15:0] wait_max_now;
  always_comb begin
    wait_max_now = 16'd0;
    for (int unsigned i = 0; i < RADIX; i = i + 1) begin
      for (int unsigned v = 0; v < N_VC; v = v + 1) begin
        if (wait_q[i][v] > wait_max_now) wait_max_now = wait_q[i][v];
      end
    end
  end

  always_ff @(posedge clk) begin
    if (!rst_n || tel_clear) begin
      wait_max_q <= 16'd0;
    end else if (wait_max_now > wait_max_q) begin
      wait_max_q <= wait_max_now;
    end
  end

  assign tel_max_wait = wait_max_q;

  logic [OCC_W-1:0] high_max;
  always_comb begin
    high_max = '0;
    for (int unsigned i = 0; i < RADIX; i = i + 1) begin
      for (int unsigned v = 0; v < N_VC; v = v + 1) begin
        if (fifo_high[i][v] > high_max) high_max = fifo_high[i][v];
      end
    end
  end
  assign tel_hiwater = high_max;

  wire [31:0]  c_flits, c_stall;
  logic [63:0] unused_snap;
  logic [1:0]  unused_sv, unused_wp, unused_wr;

  perf_counter #(.WIDTH (32), .INCR_W (1), .SATURATE (1'b1)) u_c_flits (
      .clk (clk), .rst_n (rst_n), .enable (1'b1), .event_i (flit_event),
      .incr (1'b1), .clear (tel_clear), .snapshot (1'b0),
      .count (c_flits), .snap (unused_snap[31:0]), .snap_valid (unused_sv[0]),
      .wrap_pulse (unused_wp[0]), .wrapped (unused_wr[0]));

  perf_counter #(.WIDTH (32), .INCR_W (1), .SATURATE (1'b1)) u_c_stall (
      .clk (clk), .rst_n (rst_n), .enable (1'b1), .event_i (stall_event),
      .incr (1'b1), .clear (tel_clear), .snapshot (1'b0),
      .count (c_stall), .snap (unused_snap[63:32]), .snap_valid (unused_sv[1]),
      .wrap_pulse (unused_wp[1]), .wrapped (unused_wr[1]));

  assign tel_flits = c_flits;
  assign tel_stall = c_stall;

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
      for (int unsigned i = 0; i < RADIX; i = i + 1) begin
        for (int unsigned v = 0; v < N_VC; v = v + 1) begin
          // The credit scheme's whole claim: an arriving flit always finds room.
          a_sw_no_overrun : assert (!(fifo_s_valid[i][v] && !fifo_s_ready[i][v]))
            else $error("pkt_switch_stage: buffer (%0d,%0d) overrun; upstream sent a flit with no credit",
                        i, v);
          // Every buffered flit is parity-correct, so a corruption is localised
          // to the hop that produced it (packet_pkg section 3).
          a_sw_parity : assert (!fifo_m_valid[i][v] ||
                                pkt_flit_parity_ok(pkt_uint_t'(PACKET_W),
                                                   pkt_flit_t'(fifo_m_data[i][v])))
            else $error("pkt_switch_stage: buffer (%0d,%0d) holds a flit with bad parity", i, v);
          // A flit found in buffer (i,v) must carry VC v: the input demux is by
          // the flit's own field, so a mismatch means the field moved in flight.
          a_sw_credit_held : assert (held_q[i][v] <= CRED_W'(CREDITS))
            else $error("pkt_switch_stage: buffer (%0d,%0d) is holding %0d credits, above CREDITS=%0d",
                        i, v, held_q[i][v], CREDITS);
          a_sw_vc_match : assert (!fifo_m_valid[i][v] ||
                                  (int'(pkt_flit_vc(pkt_flit_t'(fifo_m_data[i][v]))) == int'(v)))
            else $error("pkt_switch_stage: buffer (%0d,%0d) holds a flit tagged VC %0d",
                        i, v, pkt_flit_vc(pkt_flit_t'(fifo_m_data[i][v])));
        end
      end
      for (int unsigned o = 0; o < RADIX; o = o + 1) begin
        for (int unsigned v = 0; v < N_VC; v = v + 1) begin
          a_sw_credit_bound : assert (credit_q[o][v] <= CRED_W'(CREDITS))
            else $error("pkt_switch_stage: output (%0d,%0d) credit %0d exceeds CREDITS=%0d",
                        o, v, credit_q[o][v], CREDITS);
          // An output VC may only be granted while it is locked, and a locked
          // output VC must have an owner whose buffer is the one being read.
          a_sw_grant_locked : assert (!(sa_any[o] && (int'(sa_idx[o]) == int'(v))) ||
                                      vc_lock_q[o][v])
            else $error("pkt_switch_stage: output %0d granted unlocked VC %0d", o, v);
        end
        // Switch allocation is one-hot over VCs by construction; restated here
        // because it is the property the crossbar mux depends on.
        a_sw_sa_onehot : assert ($onehot0(sa_grant[o]))
          else $error("pkt_switch_stage: output %0d switch grant %b is not one-hot",
                      o, sa_grant[o]);
      end
    end
  end
`endif

endmodule : pkt_switch_stage

`default_nettype wire
