// -----------------------------------------------------------------------------
// pkt_rr_arb — round-robin arbiter with a registered priority pointer
// (SPEC.md 7.8 "pipelined arbitration", SPEC.md 23).
//
// The one arbiter in the packet fabric. Both arbitration levels of
// rtl/packet/pkt_switch_stage.sv are instances of this module — virtual-channel
// allocation over the switch's inputs, and switch allocation over the output
// port's virtual channels — so "round robin" means one thing in this design and
// is proved once.
//
// SHAPE
// -----
//   grant      one-hot, COMBINATIONAL from `req` and the registered pointer.
//   ptr_q      registered. Advances only when `update` is asserted, to one past
//              the granted index, so the granted requester becomes the LOWEST
//              priority next time. That is the round-robin guarantee: a
//              continuously-asserted request is granted at least once every N
//              grants, and therefore cannot starve.
//
// WHY THE POINTER IS SEPARATE FROM THE GRANT, AND WHY `update` IS AN INPUT
// -----------------------------------------------------------------------
// A switch's two arbitration levels do not both commit in the cycle they decide.
// Virtual-channel allocation commits when the lock register takes the grant;
// switch allocation commits when the flit leaves the buffer. Making `update` an
// input rather than deriving it from `|grant` inside the module means the
// pointer advances exactly when the decision was USED, not when it was merely
// computed. An arbiter that rotates on a decision the caller then discarded is
// how a round-robin quietly becomes a random-looking scheduler that still passes
// every "somebody got a grant" test.
//
// NO COMBINATIONAL ARB-TO-ARB FEEDBACK (the SPEC 7.8 structural requirement)
// --------------------------------------------------------------------------
// This module contains no path from `grant` back to `req`. The two levels in
// pkt_switch_stage are separated by a REGISTER — the VC-allocation result is
// latched into the lock state and is consumed by switch allocation on the next
// cycle — so the two arbiters never form one combinational cone. That is a
// property of the switch, stated here because this is the module a reader will
// check it against.
//
// COST
// ----
// The masked-priority form below is two N-bit priority encoders and a mux: for
// N = 4 that is a handful of ALMs, and the whole cone from a buffer's head
// register to the granted read enable is one level of AND plus this. The
// alternative "matrix" arbiter stores N*(N-1)/2 order bits and is cheaper to
// retime at large N; at N = 4 it costs more state than the pointer and buys
// nothing measurable, so it is not built. If a later radix makes that false the
// swap is confined to this file.
//
// Reset (SPEC 23): the pointer is control state and is reset. Nothing else here
// holds state.
// -----------------------------------------------------------------------------

`default_nettype none

module pkt_rr_arb #(
    // Number of requesters. Minimum 1 (checked at elaboration); the N = 1 case
    // is legal and degenerates to a wire, which is what makes a single-VC or
    // single-input elaboration of the switch build without a special case.
    parameter int unsigned N = 4
) (
    input  wire                       clk,
    input  wire                       rst_n,

    // Requests, one bit per requester. May change every cycle.
    input  wire [N-1:0]               req,

    // Assert in the cycle the caller CONSUMES `grant`. The pointer advances past
    // the granted requester at that edge and at no other time.
    input  wire                       update,

    // One-hot. Zero when `req` is zero.
    output wire [N-1:0]               grant,
    output wire                       any_grant,
    output wire [(N > 1 ? $clog2(N) : 1)-1:0] grant_idx
);

  localparam int unsigned IDX_W = (N > 1) ? $clog2(N) : 1;

`ifndef SYNTHESIS
  initial begin
    if (N < 1) begin
      $fatal(1, "pkt_rr_arb: N=%0d is illegal; minimum is 1", N);
    end
  end
`endif

  // ---------------------------------------------------------------------------
  // Priority pointer. Names the requester that has HIGHEST priority this cycle.
  // ---------------------------------------------------------------------------
  logic [IDX_W-1:0] ptr_q;

  // Mask of requesters at or above the pointer. Built by a shift rather than by
  // a comparison chain so the expression is one barrel shifter regardless of N.
  wire [N-1:0] hi_mask = {N{1'b1}} << ptr_q;
  wire [N-1:0] hi_req  = req & hi_mask;

  // Lowest set bit of a vector: x & -x. Two of them, and a mux — the whole
  // arbiter.
  wire [N-1:0] lowest_hi  = hi_req & (~hi_req + N'(1));
  wire [N-1:0] lowest_any = req    & (~req    + N'(1));

  wire [N-1:0] grant_w = (|hi_req) ? lowest_hi : lowest_any;

  // One-hot to index. A loop rather than a case, so N is a genuine parameter.
  logic [IDX_W-1:0] idx_w;
  always_comb begin
    idx_w = '0;
    for (int unsigned i = 0; i < N; i = i + 1) begin
      if (grant_w[i]) idx_w = IDX_W'(i);
    end
  end

  // Next pointer: one past the granted index, wrapping. N need not be a power of
  // two, so the wrap is an explicit compare rather than a truncation.
  wire [IDX_W-1:0] ptr_next =
      (N == 1) ? IDX_W'(0)
               : ((idx_w == IDX_W'(N - 1)) ? IDX_W'(0) : (idx_w + IDX_W'(1)));

  always_ff @(posedge clk) begin
    if (!rst_n) begin
      ptr_q <= IDX_W'(0);
    end else if (update && (|grant_w)) begin
      ptr_q <= ptr_next;
    end
  end

  assign grant     = grant_w;
  assign any_grant = |grant_w;
  assign grant_idx = idx_w;

  // ---------------------------------------------------------------------------
  // SPEC 14 assertions. Simulation only, active in the fast build, so every
  // instance in the design is checked with no test-side wiring.
  // ---------------------------------------------------------------------------
`ifndef SYNTHESIS
  always_ff @(posedge clk) begin
    if (rst_n) begin
      a_rr_grant_onehot : assert ($onehot0(grant_w))
        else $error("pkt_rr_arb: grant %b is not one-hot (N=%0d)", grant_w, N);
      a_rr_grant_requested : assert ((grant_w & ~req) == {N{1'b0}})
        else $error("pkt_rr_arb: granted a requester that did not request (req=%b grant=%b)",
                    req, grant_w);
      a_rr_grant_when_req : assert ((|req) == (|grant_w))
        else $error("pkt_rr_arb: req=%b but grant=%b; the arbiter must grant whenever anyone asks",
                    req, grant_w);
      a_rr_ptr_range : assert (int'(ptr_q) < int'(N))
        else $error("pkt_rr_arb: pointer %0d is outside 0..%0d", ptr_q, N - 1);
    end
  end
`endif

endmodule : pkt_rr_arb

`default_nettype wire
