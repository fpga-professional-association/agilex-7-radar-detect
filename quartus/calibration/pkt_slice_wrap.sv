// -----------------------------------------------------------------------------
// pkt_slice_wrap — synthesis wrapper for the SPEC 18 two-stage fabric-slice
// calibration (issue #18, SPEC.md 18 item 9, second point).
//
// Wraps TWO rtl/packet/pkt_switch_stage.sv instances in series, with the credit
// loop between them closed locally, at the SPEC 7.8 nominal scale — radix 4,
// four virtual channels, 512-bit flits. The difference between this point and
// pkt_switch_wrap.sv is the cost of a HOP: the inter-stage flit bus, the credit
// return path, and whatever the fitter does to a 517-bit link that has to cross
// between two blocks each already holding sixteen buffers of the same width.
//
// WHY A SLICE AND NOT THE WHOLE FABRIC
// ------------------------------------
// The nominal network is 16 ports through two stages, which is eight of these
// switches plus 32 endpoints — one compile of that at 512 bits is not a
// calibration point, it is the design. What the projection actually needs from
// this point is the per-hop increment: the full fabric's cost is
// (switches x switch cost) + (hops x inter-stage cost) + endpoints, and the
// second term is what only a multi-stage compile can measure. Two stages of four
// ports measures it at the same flit width the real fabric uses, which is the
// property that makes the number multiply out honestly.
//
// The two stages route on DIFFERENT destination digits — 1 then 0, exactly as
// rtl/packet/pkt_fabric.sv assigns them — so the routing slices the fitter sees
// are the ones the real network has and not two copies of one.
//
// The inter-stage wiring here is the IDENTITY permutation, not the butterfly's
// perfect shuffle. That is deliberate and is the one thing this point does not
// price: the shuffle is a fixed renaming of 4 x 517 point-to-point wires whose
// cost is placement, not logic, and reproducing it on a four-port slice would
// reproduce a permutation of four elements rather than the sixteen-element one
// the real fabric routes. The full-scale projection therefore states the wiring
// as an unmeasured term rather than folding it into a measured one.
//
// SPEC 24: nothing is tied off. Both stages' telemetry is registered and driven
// to pins, the fault-injection masks are ports, and the inter-stage bus is real
// logic in both directions.
//
// Listed in sim/verilator/files_packet.f so `make lint` covers it.
// -----------------------------------------------------------------------------

`default_nettype none

// ---------------------------------------------------------------------------
// The boundary-register wrapper.
// ---------------------------------------------------------------------------
module pkt_slice_wrap #(
    parameter int unsigned PACKET_W = 512,
    parameter int unsigned N_VC     = 4,
    parameter int unsigned RADIX    = 4,
    parameter int unsigned VC_DEPTH = 4,
    parameter int unsigned OUT_PIPE = 0
) (
    input  wire          clk,
    input  wire          rst_n,

    input  wire [3:0]    in_valid,
    input  wire [2067:0] in_flit,
    output wire [15:0]   in_credit_out,

    output wire [3:0]    out_valid,
    output wire [2067:0] out_flit,
    input  wire [15:0]   out_credit_in,

    input  wire [15:0]   fi_credit_kill_a,
    input  wire [15:0]   fi_credit_kill_b,
    input  wire          tel_clear,

    output wire [31:0]   tel_flits,
    output wire [31:0]   tel_stall,
    output wire [15:0]   tel_max_wait
);

  localparam int unsigned FLIT_W = PACKET_W + 5;
  localparam int unsigned BUS_W  = RADIX * FLIT_W;
  localparam int unsigned CRED_W = RADIX * N_VC;

  logic [RADIX-1:0]  in_valid_q;
  logic [BUS_W-1:0]  in_flit_q;
  logic [CRED_W-1:0] out_credit_q, fi_a_q, fi_b_q;
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
    fi_a_q    <= fi_credit_kill_a[CRED_W-1:0];
    fi_b_q    <= fi_credit_kill_b[CRED_W-1:0];
  end

  wire [CRED_W-1:0] k_in_credit;
  wire [RADIX-1:0]  k_out_valid;
  wire [BUS_W-1:0]  k_out_flit;
  wire [31:0]       k_flits_a, k_flits_b, k_stall_a, k_stall_b;
  wire [15:0]       k_wait_a, k_wait_b;

  pkt_slice_core #(
      .PACKET_W (PACKET_W),
      .N_VC     (N_VC),
      .RADIX    (RADIX),
      .VC_DEPTH (VC_DEPTH),
      .OUT_PIPE (OUT_PIPE)
  ) u_kernel (
      .clk              (clk),
      .rst_n            (rst_n),
      .in_valid         (in_valid_q),
      .in_flit          (in_flit_q),
      .in_credit_out    (k_in_credit),
      .out_valid        (k_out_valid),
      .out_flit         (k_out_flit),
      .out_credit_in    (out_credit_q),
      .fi_credit_kill_a (fi_a_q),
      .fi_credit_kill_b (fi_b_q),
      .tel_clear        (tel_clear_q),
      .tel_flits_a      (k_flits_a),
      .tel_flits_b      (k_flits_b),
      .tel_stall_a      (k_stall_a),
      .tel_stall_b      (k_stall_b),
      .tel_max_wait_a   (k_wait_a),
      .tel_max_wait_b   (k_wait_b)
  );

  logic [RADIX-1:0]  out_valid_q;
  logic [BUS_W-1:0]  out_flit_q;
  logic [CRED_W-1:0] in_credit_q;
  logic [31:0]       flits_q, stall_q;
  logic [15:0]       wait_q;

  always_ff @(posedge clk) begin
    if (!rst_n) begin
      out_valid_q <= '0;
      in_credit_q <= '0;
    end else begin
      out_valid_q <= k_out_valid;
      in_credit_q <= k_in_credit;
    end
  end

  // Both stages' telemetry participates, so neither optimises away; the pairs
  // are combined rather than exported separately only because sixteen more pins
  // of counter would tell the sweep nothing the simulation does not already
  // report.
  always_ff @(posedge clk) begin
    out_flit_q <= k_out_flit;
    flits_q    <= k_flits_a ^ k_flits_b;
    stall_q    <= k_stall_a ^ k_stall_b;
    wait_q     <= k_wait_a ^ k_wait_b;
  end

  assign out_valid     = 4'(out_valid_q);
  assign out_flit      = 2068'(out_flit_q);
  assign in_credit_out = 16'(in_credit_q);
  assign tel_flits     = flits_q;
  assign tel_stall     = stall_q;
  assign tel_max_wait  = wait_q;

endmodule : pkt_slice_wrap

`default_nettype wire
