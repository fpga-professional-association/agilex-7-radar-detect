// -----------------------------------------------------------------------------
// pkt_switch_wrap — synthesis wrapper for the SPEC 18 packet-switch calibration
// (issue #18, SPEC.md 18 item 9: "one packet-switch stage").
//
// Wraps ONE rtl/packet/pkt_switch_stage.sv at the SPEC 7.8 NOMINAL SCALE —
// radix 4, four virtual channels, 512-bit flits — in boundary registers, so the
// sweep measures a genuine register-to-register fabric path rather than the I/O
// budget. Same arrangement, and the same reasoning, as
// quartus/calibration/cmult_wrap.sv, fir_wrap.sv and bf_dot_wrap.sv:
//
//     virtual pin -> in_q -> [ pkt_switch_stage ] -> out_q -> virtual pin
//                     \_________ measured reg-to-reg _________/
//
// WHY THIS IS THE RIGHT UNIT TO MEASURE
// -------------------------------------
// The full network is STAGES x (N_PORTS/RADIX) copies of exactly this module and
// nothing else in the datapath, plus the endpoints. SPEC 7.8 says the block "is
// expected to create substantial ALM and routing pressure", and this is the unit
// that creates it: sixteen 517-bit buffers, a 4x4 crossbar 517 bits wide, twenty
// arbiters and thirty-two credit counters. Everything the full-scale projection
// claims is this point's number times a count.
//
// Measuring it at 512 bits rather than at the tiny 64 is the whole point. Buffer
// storage, crossbar mux width and inter-switch routing all scale with PACKET_W
// while the arbitration and credit logic do not, so a 64-bit measurement scaled
// by eight would over-count the control logic and under-count the wires. SPEC 18
// exists to stop exactly that kind of extrapolation.
//
// THE AXIS THIS POINT SWEEPS: OUT_PIPE, 0 against 1.
// One registered hop between the switch allocator's grant and the outgoing link
// against two. The two produce IDENTICAL traffic — the extra stage is a pure
// delay on a credit-controlled link, and the credit accounting already reserved
// the slot — which is what makes this a pure cost comparison. The question is
// whether a second register buys Fmax at 517-bit flits or whether HyperFlex
// retiming already recovers it from the first, and it is not answerable by
// inspection.
//
// The buffer depth is deliberately NOT swept. It changes the storage linearly
// and the arbitration not at all, so a sweep of it would be four copies of one
// number; what a later revision needs from it is the high-water mark the
// simulation reports, not a fitter run.
//
// Ports are sized for the calibrated geometry — a fixed four ports of 517 bits —
// so that the virtual-pin assignments in pkt_switch_calib.qsf name the same pins
// at every point of the sweep. A point at a different PACKET_W would need its
// own project, which is the honest way to price a different geometry.
//
// SPEC 24: nothing is tied off to make the block optimise away. Every output is
// registered and driven to a pin, every input is a genuine port, and the fault
// injection mask is a port rather than a constant zero — a constant would let
// the fitter delete the credit-holding counters, which are real logic in the
// shipped design.
//
// Listed in sim/verilator/files_packet.f so `make lint` covers it: RTL that no
// lint ever sees is RTL that rots, and a Quartus compile depends on this file.
// -----------------------------------------------------------------------------

`default_nettype none

module pkt_switch_wrap #(
    // The SPEC 7.8 nominal geometry. Ports below are sized for exactly this;
    // see the header.
    parameter int unsigned PACKET_W = 512,
    parameter int unsigned N_VC     = 4,
    parameter int unsigned RADIX    = 4,

    // Buffer entries per (port, VC), and the credits held toward the downstream
    // buffer. Equal by construction.
    parameter int unsigned VC_DEPTH = 4,

    // THE axis this point sweeps: 0 = one output register, 1 = two.
    parameter int unsigned OUT_PIPE = 0,

    // Which destination digit this stage routes on. Stage 0 of a two-stage
    // radix-4 network routes on digit 1.
    parameter int unsigned DEST_DIGIT = 1
) (
    input  wire          clk,
    input  wire          rst_n,

    input  wire [3:0]    in_valid,
    input  wire [2067:0] in_flit,       // 4 ports x 517-bit flits
    output wire [15:0]   in_credit_out, // 4 ports x 4 VCs

    output wire [3:0]    out_valid,
    output wire [2067:0] out_flit,
    input  wire [15:0]   out_credit_in,

    input  wire [15:0]   fi_credit_kill,
    input  wire          tel_clear,

    output wire [31:0]   tel_flits,
    output wire [31:0]   tel_stall,
    output wire [15:0]   tel_max_wait,
    output wire [7:0]    tel_hiwater
);

  localparam int unsigned FLIT_W = PACKET_W + 5;
  localparam int unsigned BUS_W  = RADIX * FLIT_W;
  localparam int unsigned CRED_W = RADIX * N_VC;
  localparam int unsigned OCC_W  = $clog2(VC_DEPTH + 1);

  // ---------------------------------------------------------------------------
  // Boundary input registers
  //
  // The datapath registers are free-running and unreset, matching the kernel's
  // own policy (SPEC 23: reset validity, not every datapath bit). Only the
  // valids and the credit strobes are reset, so the reset network the Fitter
  // sees is the one the real design has rather than a 2068-bit synchronous clear
  // that would distort both the ALM count and the retiming result.
  // ---------------------------------------------------------------------------
  logic [RADIX-1:0]  in_valid_q;
  logic [BUS_W-1:0]  in_flit_q;
  logic [CRED_W-1:0] out_credit_q;
  logic [CRED_W-1:0] fi_kill_q;
  logic              tel_clear_q;

  always_ff @(posedge clk) begin
    if (!rst_n) begin
      in_valid_q   <= '0;
      out_credit_q <= '0;
      tel_clear_q  <= 1'b0;
    end else begin
      in_valid_q   <= in_valid[RADIX-1:0];
      out_credit_q <= out_credit_in[CRED_W-1:0];
      tel_clear_q  <= tel_clear;
    end
  end

  always_ff @(posedge clk) begin
    in_flit_q <= in_flit[BUS_W-1:0];
    fi_kill_q <= fi_credit_kill[CRED_W-1:0];
  end

  // ---------------------------------------------------------------------------
  // The kernel under calibration. The instance MUST be named u_kernel:
  // quartus/scripts/calibrate.tcl extracts the per-entity utilisation row and
  // decides whether the critical path is inside the kernel by that name.
  // ---------------------------------------------------------------------------
  wire [CRED_W-1:0] k_in_credit;
  wire [RADIX-1:0]  k_out_valid;
  wire [BUS_W-1:0]  k_out_flit;
  wire [31:0]       k_flits, k_stall;
  wire [15:0]       k_max_wait;
  wire [OCC_W-1:0]  k_hiwater;

  pkt_switch_stage #(
      .PACKET_W   (PACKET_W),
      .N_VC       (N_VC),
      .RADIX      (RADIX),
      .DEST_DIGIT (DEST_DIGIT),
      .VC_DEPTH   (VC_DEPTH),
      .CREDITS    (VC_DEPTH),
      .OUT_PIPE   (OUT_PIPE),
      .STORAGE    ("regs")
  ) u_kernel (
      .clk            (clk),
      .rst_n          (rst_n),
      .in_valid       (in_valid_q),
      .in_flit        (in_flit_q),
      .in_credit_out  (k_in_credit),
      .out_valid      (k_out_valid),
      .out_flit       (k_out_flit),
      .out_credit_in  (out_credit_q),
      .fi_credit_kill (fi_kill_q),
      .tel_flits      (k_flits),
      .tel_stall      (k_stall),
      .tel_hiwater    (k_hiwater),
      .tel_max_wait   (k_max_wait),
      .tel_clear      (tel_clear_q)
  );

  // ---------------------------------------------------------------------------
  // Boundary output registers. EVERY output is registered and driven out.
  // Nothing is tied off or folded into a reduction tree: SPEC 24 forbids
  // "constant-driving unused inputs so large blocks optimize away", and a
  // reduction tree would add ALMs that are not the kernel's.
  // ---------------------------------------------------------------------------
  logic [RADIX-1:0]  out_valid_q;
  logic [BUS_W-1:0]  out_flit_q;
  logic [CRED_W-1:0] in_credit_q;
  logic [31:0]       flits_q, stall_q;
  logic [15:0]       wait_q;
  logic [7:0]        hiwater_q;

  always_ff @(posedge clk) begin
    if (!rst_n) begin
      out_valid_q <= '0;
      in_credit_q <= '0;
    end else begin
      out_valid_q <= k_out_valid;
      in_credit_q <= k_in_credit;
    end
  end

  always_ff @(posedge clk) begin
    out_flit_q <= k_out_flit;
    flits_q    <= k_flits;
    stall_q    <= k_stall;
    wait_q     <= k_max_wait;
    hiwater_q  <= 8'(k_hiwater);
  end

  assign out_valid     = 4'(out_valid_q);
  assign out_flit      = 2068'(out_flit_q);
  assign in_credit_out = 16'(in_credit_q);
  assign tel_flits     = flits_q;
  assign tel_stall     = stall_q;
  assign tel_max_wait  = wait_q;
  assign tel_hiwater   = hiwater_q;

endmodule : pkt_switch_wrap

`default_nettype wire
