// -----------------------------------------------------------------------------
// seq_checker_assertions — the SPEC 14 sequence-discontinuity property set (#8).
//
// Simulation only. rtl/common/seq_checker.sv instantiates one under
// `ifndef SYNTHESIS`, exactly as every stream primitive instantiates a
// stream_protocol_checker: the checker travels with the module rather than with
// the testbench, so a kernel that instantiates a sequence checker in issue #12
// is checked without its author wiring anything.
//
// What this checks, and what it deliberately does not
// ---------------------------------------------------
// The continuity of the STREAM is checked elsewhere: `STREAM_SVA_FRAMING` in
// sim/assertions/stream_sva.svh already asserts that the sequence field
// increments by one per beat on every interface inside a stream primitive. That
// property is about the producer.
//
// This one is about the DETECTOR. A checker whose job is to classify loss,
// duplication and reordering has its own failure mode — classifying one beat as
// two kinds of fault, or reporting a fault on a cycle in which nothing was
// transferred — and neither of those would be visible in the counts, which would
// simply be wrong in a plausible-looking way. The properties are in
// sim/assertions/telemetry_sva.svh; this module is the port list.
//
// The two together are what make the counts trustworthy: the stream property
// says a nominal run contains no discontinuity, and these say the classifier
// does not invent one.
//
// Never synthesized, never in a Quartus source list.
// -----------------------------------------------------------------------------

`default_nettype none

`include "telemetry_sva.svh"

module seq_checker_assertions #(
    parameter int unsigned SEQ_W = 16
) (
    input wire             clk,
    input wire             rst_n,

    // An accepted beat this instance is watching (enable && beat).
    input wire             active,

    // The classification, one-hot at most.
    input wire             err_gap,
    input wire             err_dup,
    input wire             err_reorder,
    input wire             err_untracked,
    input wire [SEQ_W-1:0] gap_size
);

  `TELEMETRY_SVA_SEQ(clk, rst_n, active, err_gap, err_dup, err_reorder,
                     err_untracked, gap_size)

endmodule : seq_checker_assertions

`default_nettype wire
