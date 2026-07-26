// -----------------------------------------------------------------------------
// align_assertions — the SPEC.md 14 property set for the frequency-bin alignment
// network (issue #16).
//
// Instantiated by rtl/align/align_net.sv under `ifndef SYNTHESIS`, so a design
// built from the block is checked by construction with no test-side wiring —
// the mechanism every kernel in this repository uses (DECISIONS.md, issue #5,
// decision 3). It is SINGLE CLOCK, per issue #15's decision 14: a two-clock
// checker would be reported by `scripts/cdc_inventory.py --strict` as an
// untagged crossing, and tagging it would put an imaginary crossing in the
// SPEC 8 inventory.
//
// WHAT IS HERE AND WHAT IS NOT
// ----------------------------
// The C++ scoreboard in sim/tests/test_align.cpp checks VALUES: every emitted
// beat, bit for bit, against model/cpp/align/align_model.hpp. These properties
// check the things a value comparison cannot localise, or cannot see at all.
//
//   a_align_route_correct   THE central property of this issue. A word
//                           presented on lane `l` must be a word whose own bin
//                           index says it belongs at beat position `l`. If the
//                           network mis-routes, the assembled beat is still a
//                           perfectly well-formed beat — BIN_PAR antenna
//                           vectors, right frame, right group — carrying two
//                           copies of one bin and none of another. The
//                           scoreboard catches that only because it happens to
//                           compare every sample; this catches it at the wire,
//                           on the cycle, in either architecture, and names the
//                           lane. It is deliberately checked HERE, outside both
//                           architectures, rather than inside one of them.
//
//   a_align_in_held /       The network's slave side is a valid/ready interface
//   a_align_in_dst_stable   but not a SPEC 5 stream (no framing, no sequence),
//                           so stream_protocol_checker cannot be pointed at it.
//                           These are the two handshake properties that still
//                           apply and that a blocking network can plausibly get
//                           wrong: `align_clos`'s ready depends on its own
//                           inputs' valids, so a producer that withdrew a
//                           request after losing an arbitration would deadlock
//                           the switch rather than fail visibly.
//
//   a_align_idle_when_      Nothing may be delivered while the block is
//   disabled                disabled. Cheap, and it is what catches an enable or
//                           reset path that leaves one architecture's stage
//                           registers live when the other's are not — which
//                           matters here because align_top holds three of its
//                           four DUTs disabled at all times.
//
// The measured coverage this issue needs — whether two lanes were ever delivered
// in one cycle, whether every lane was ever used — is NOT here: it lives on
// align_net's telemetry ports, because it is a throughput statement about the
// two architectures that the pull request quotes, not a simulation artefact.
//
// Lint contract: clean under `verilator --lint-only --Wall` with no waiver.
// -----------------------------------------------------------------------------

`default_nettype none

module align_assertions #(
    parameter int unsigned BIN_PAR    = 2,
    parameter int unsigned LANE_W     = 1,
    parameter int unsigned NET_DATA_W = 8,
    parameter int unsigned BIN_W      = 6,
    parameter int unsigned VEC_W      = 32
) (
    input  wire                          clk,
    input  wire                          rst_n,
    input  wire                          enable,

    // The network's slave side, as align_net presents it.
    input  wire [BIN_PAR-1:0]            in_valid,
    input  wire [BIN_PAR-1:0]            in_ready,
    input  wire [BIN_PAR*LANE_W-1:0]     in_dst,

    // The network's master side, as align_collect sees it.
    input  wire [BIN_PAR-1:0]            lane_valid,
    input  wire [BIN_PAR-1:0]            lane_ready,
    input  wire [BIN_PAR*NET_DATA_W-1:0] lane_data
);

  logic [BIN_PAR-1:0]        in_valid_q;
  logic [BIN_PAR-1:0]        in_ready_q;
  logic [BIN_PAR*LANE_W-1:0] in_dst_q;

  always_ff @(posedge clk) begin
    if (!rst_n) begin
      in_valid_q <= '0;
      in_ready_q <= '0;
    end else begin
      in_valid_q <= in_valid;
      in_ready_q <= in_ready;

      for (int unsigned i = 0; i < BIN_PAR; i++) begin
        a_align_in_held :
          assert (!(in_valid_q[i] && !in_ready_q[i]) || in_valid[i])
          else $error("align: input %0d withdrew valid before it was accepted", i);

        a_align_in_dst_stable :
          assert (!(in_valid_q[i] && !in_ready_q[i]) ||
                  (in_dst[i*LANE_W +: LANE_W] == in_dst_q[i*LANE_W +: LANE_W]))
          else $error("align: input %0d changed its destination while stalled", i);
      end

      for (int unsigned l = 0; l < BIN_PAR; l++) begin
        automatic logic [LANE_W-1:0] carried;
        // The bin sits immediately above the antenna vector in the routed word,
        // and its low LANE_W bits are the beat position it belongs to
        // (align_pkg, "The routed word" and section 1).
        carried = lane_data[l*NET_DATA_W + VEC_W +: LANE_W];

        a_align_route_correct :
          assert (!(lane_valid[l] && lane_ready[l]) || (carried == LANE_W'(l)))
          else $error("align: lane %0d was given a word belonging at beat position %0d",
                      l, carried);
      end

      a_align_idle_when_disabled :
        assert (enable || ((lane_valid & lane_ready) == '0))
        else $error("align: a lane was accepted while the block was disabled");
    end
  end

  always_ff @(posedge clk) begin
    in_dst_q <= in_dst;
  end

`ifndef SYNTHESIS
  initial begin
    // The routing property slices `bin` out of the routed word at a fixed
    // offset. If the word were narrower than the fields it carries, that slice
    // would read adjacent bits and the property would silently check nothing.
    if (NET_DATA_W < (VEC_W + BIN_W)) begin
      $fatal(1, "align_assertions: NET_DATA_W=%0d cannot hold a %0d-bit vector and a %0d-bit bin",
             NET_DATA_W, VEC_W, BIN_W);
    end
    if (BIN_W < LANE_W) begin
      $fatal(1, "align_assertions: BIN_W=%0d is narrower than LANE_W=%0d", BIN_W, LANE_W);
    end
  end
`endif

endmodule : align_assertions

`default_nettype wire
