// -----------------------------------------------------------------------------
// cdc_sync2 — the flip-flop synchronizer chain (SPEC.md 8).
//
// SPEC 8: "Use proper synchronizers for single-bit status." This is the only
// module in the design that carries a signal from one clock domain into another
// through raw flip-flops. Every other crossing — the asynchronous FIFO's Gray
// pointers, the pulse synchronizer's toggle, the handshake's request and
// acknowledge — is built out of instances of this one, so there is exactly one
// piece of RTL to get right and exactly one place the vendor attributes live.
//
// (* cdc_primitive *) — scripts/cdc_inventory.py reads the attribute block above
// the module keyword to build the SPEC 8 CDC inventory report. See that script's
// header for the schema. The attribute is metadata for the inventory only; it
// has no effect on synthesis.
//
// THE MULTIBIT RULE
// -----------------
// SPEC 8: "Do not synchronize a multibit bus by independently synchronizing
// every bit." That rule is enforced here rather than left to review: WIDTH > 1
// is a `$fatal` at elaboration unless the instantiator sets GRAY_CODED, which is
// an assertion by the instantiator that consecutive values of `d` differ in at
// most one bit — the only condition under which per-bit synchronization of a bus
// is sound. rtl/cdc/async_fifo.sv is the one module that sets it, for its Gray
// pointers, and it instantiates a cdc_gray_checker on the same vector so the
// claim is checked every cycle rather than trusted.
//
// A status bus that is not Gray-coded goes through rtl/cdc/cdc_handshake.sv.
//
// QUARTUS PRO 26.1 ATTRIBUTES (researched 2026-07-25; DECISIONS.md, issue #6)
// --------------------------------------------------------------------------
// The `altera_attribute` string below is the combination Altera's own shipped
// synchronizer IP (altera_std_synchronizer.v) uses, in the underscore form that
// needs no nested quoting:
//
//   SYNCHRONIZER_IDENTIFICATION FORCED_IF_ASYNCHRONOUS
//       Marks the chain so the Fitter and the Timing Analyzer recognise it as a
//       synchronizer and can report and optimise its MTBF
//       (report_metastability, OPTIMIZE_FOR_METASTABILITY). FORCED_IF_ASYNCHRONOUS
//       rather than FORCED: it identifies the chain whenever an asynchronous
//       transfer is actually detected, where a bare FORCED marks the registers
//       unconditionally and is documented as the wrong tool for a chain the
//       Compiler can see for itself.
//   PRESERVE_REGISTER ON + DONT_MERGE_REGISTER ON
//       A synchronizer chain is a shift register whose stages have identical
//       logic; without these, synthesis is free to merge two stages, merge two
//       instances that happen to synchronize the same net, or retime the chain
//       apart. Any of those silently removes the metastability margin the module
//       exists to provide. The `(* preserve *)` / `(* dont_merge *)` short forms
//       are given as well: they are the ones Quartus applies to a variable
//       declaration directly and cost nothing to state twice.
//   ADV_NETLIST_OPT_ALLOWED NEVER_ALLOW
//       Blocks gate-level netlist optimisation and physical synthesis on these
//       registers, for the same reason.
//
// HyperFlex note (SPEC 23): on Agilex the Hyper-Retimer already declines to
// retime registers it has identified as a synchronizer chain, so the preserve
// attributes are belt-and-braces rather than the primary mechanism — but they
// are also what makes the chain a deliberate retiming *barrier*. The consequence
// worth remembering when this shows up in a Fast Forward report: the fix for a
// synchronizer on a critical path is pipeline registers *feeding* it, never a
// relaxation of these attributes.
//
// Note on Verilator: `(* ... *)` attributes are stripped by the lexer before
// parsing, so none of this reaches the parser and `--lint-only --Wall` is clean
// (measured, Verilator 5.020).
//
// Reset (SPEC 23, DECISIONS.md decision 6): synchronous, active low, to
// RST_VALUE. No asynchronous reset anywhere in this design. The chain is control
// state and is therefore reset — this is one of the few places where resetting
// the storage *is* the point, because a chain that powers up holding the wrong
// value presents a spurious status edge to the destination.
// -----------------------------------------------------------------------------

`default_nettype none

(* cdc_primitive = "sync_ff", cdc_src_clk = "@async", cdc_dst_clk = "clk", cdc_width = "WIDTH", cdc_stages = "STAGES" *)
module cdc_sync2 #(
    // Bits carried. Must be 1 unless GRAY_CODED is set; see THE MULTIBIT RULE.
    parameter int unsigned WIDTH = 1,

    // Flip-flops in the chain. Minimum 2 (checked at elaboration). The project
    // default lives in cdc_pkg::cdc_sync_stages_default(); 3 is available for a
    // bit whose corruption is unrecoverable rather than merely lossy.
    parameter int unsigned STAGES = 2,

    // Value the chain holds while `rst_n` is low, and therefore the value the
    // destination sees for the first STAGES cycles after release. Choose it so
    // that the safe interpretation is the reset one: an "other domain is in
    // reset" flag resets to 1, a "data available" flag resets to 0.
    parameter logic [WIDTH-1:0] RST_VALUE = '0,

    // Instantiator's assertion that consecutive values of `d` differ in at most
    // one bit. Required for WIDTH > 1. See THE MULTIBIT RULE.
    parameter bit GRAY_CODED = 1'b0
) (
    // Destination-domain clock and reset. The source domain has no port here on
    // purpose: a synchronizer has no source-side logic, and naming a source
    // clock it does not use would put a fictional net in the CDC inventory.
    input  wire              clk,
    input  wire              rst_n,

    // Asynchronous input, from the source domain.
    input  wire [WIDTH-1:0]  d,

    // Synchronized output, safe to use in the `clk` domain.
    output wire [WIDTH-1:0]  q
);

`ifndef SYNTHESIS
  initial begin
    if (STAGES < int'(cdc_pkg::cdc_sync_stages_min())) begin
      $fatal(1, "cdc_sync2: STAGES=%0d is illegal; a synchronizer needs at least %0d flip-flops",
             STAGES, int'(cdc_pkg::cdc_sync_stages_min()));
    end
    if (WIDTH < 1) begin
      $fatal(1, "cdc_sync2: WIDTH=%0d is illegal", WIDTH);
    end
    if ((WIDTH > 1) && !GRAY_CODED) begin
      $fatal(1, "cdc_sync2: WIDTH=%0d with GRAY_CODED=0 violates SPEC 8 (do not synchronize a multibit bus bit by bit); use cdc_handshake, or set GRAY_CODED for a Gray-coded pointer",
             WIDTH);
    end
  end
`endif

  // The chain. One array, indexed 0 (nearest the asynchronous input) to
  // STAGES-1 (the output). Every stage carries the same attributes because
  // stage 0 is the one that goes metastable and stages 1..N-1 are the ones a
  // merge or a retime would remove.
  (* altera_attribute = {"-name ADV_NETLIST_OPT_ALLOWED NEVER_ALLOW; -name SYNCHRONIZER_IDENTIFICATION FORCED_IF_ASYNCHRONOUS; -name DONT_MERGE_REGISTER ON; -name PRESERVE_REGISTER ON"} *)
  (* preserve *)
  (* dont_merge *)
  logic [WIDTH-1:0] sync_q [STAGES];

  always_ff @(posedge clk) begin
    if (!rst_n) begin
      for (int unsigned i = 0; i < STAGES; i++) begin
        sync_q[i] <= RST_VALUE;
      end
    end else begin
      sync_q[0] <= d;
      for (int unsigned i = 1; i < STAGES; i++) begin
        sync_q[i] <= sync_q[i-1];
      end
    end
  end

  assign q = sync_q[STAGES-1];

endmodule : cdc_sync2

`default_nettype wire
