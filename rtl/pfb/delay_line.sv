// -----------------------------------------------------------------------------
// delay_line — the parameterised sample/metadata delay (SPEC.md 7.1, 23).
//
// SPEC 7.1 asks for delay lines that "infer M20Ks when their size makes that
// appropriate". This module is the one place in the design that decides, and it
// decides from pfb_pkg's threshold rather than from a per-instance opinion.
//
// TWO STYLES, AND THE ONE FACT THAT DECIDES BETWEEN THEM
// -----------------------------------------------------
// A memory has one read port per cycle. A TAPPED delay line — one that presents
// every stage simultaneously, which is what a direct-form FIR needs — therefore
// cannot be a memory at any depth. That is not a threshold, it is arithmetic,
// and it is why `N_TAPS > 1` forces STYLE="SRL" and rejects an explicit "MEM".
//
// The style choice is real only for a PURE DELAY (`N_TAPS == 1`): a metadata
// alignment path, a corner-turn feed, a history bank. There, depth and total
// bits decide (pfb_pkg::pfb_delay_use_mem), and "AUTO" is the default so that a
// line which grows past the threshold moves to an M20K without an edit.
//
//   STYLE = "SRL"   DEPTH registers, shifted on `en`. Quartus may pack a pure
//                   delay into an MLAB-based shift register on its own; a tapped
//                   line stays in ALM registers because every stage is read.
//   STYLE = "MEM"   a circular buffer in block RAM: one write and one read per
//                   enabled cycle, plus the output register. Carries the
//                   `ramstyle` attribute that names M20K, in the same form
//                   rtl/common/sync_fifo.sv and rtl/cdc/async_fifo.sv use.
//
// TAP GEOMETRY
// ------------
// `taps[i]` is the input delayed by `(i+1) * TAP_STRIDE` ENABLED cycles, and
// `q` is `taps[N_TAPS-1]`, the deepest. Exposing a stride rather than every
// stage is what lets a systolic FIR — which needs two delay stages per tap —
// share this module with a direct-form one without either reading half a bus
// and leaving the other half dangling.
//
// BEATS, NOT CYCLES (pfb_pkg, "Beats and cycles")
// -----------------------------------------------
// Every register here is gated by `en`. A FIR history must advance once per
// SAMPLE; if it advanced once per clock, a gap in the SPEC 5 stream would shift
// a stale sample into the history and every subsequent output would be wrong.
// The gap-driven tests in sim/tests/ exist to make that falsifiable.
//
// RESET (SPEC 23 "Reset validity, not every datapath bit")
// --------------------------------------------------------
// The storage is NEVER reset — not the registers, not the memory. A reset fanout
// across DEPTH x WIDTH bits would pin every one of them out of Hyper-Register
// retiming for no functional gain. Correctness comes from the consumer's valid
// pipeline: a lane's output is not valid until enough beats have been admitted
// for the history to be entirely real data. Only the MEM style's write pointer
// is reset, because a pointer is control state.
//
// Lint contract: clean under `verilator --lint-only --Wall` with no waiver.
// -----------------------------------------------------------------------------

`default_nettype none

module delay_line
  import pfb_pkg::*;
#(
    parameter int unsigned WIDTH = 32,

    // Number of exposed taps. 1 is a pure delay of TAP_STRIDE stages.
    parameter int unsigned N_TAPS = 15,

    // Enabled cycles between consecutive taps. 1 for a direct-form FIR history,
    // 2 for a systolic one (pfb_pkg::pfb_tap_stride).
    parameter int unsigned TAP_STRIDE = 1,

    // "AUTO" | "SRL" | "MEM". See the header.
    parameter string STYLE = "AUTO"
) (
    input  wire                    clk,

    // A sample is present this cycle. Every register advances only here.
    input  wire                    en,
    input  wire [WIDTH-1:0]        d,

    // taps[i] = d delayed by (i+1)*TAP_STRIDE enabled cycles.
    output wire [N_TAPS*WIDTH-1:0] taps,

    // The deepest tap, i.e. taps[N_TAPS-1]. Exported separately so a pure-delay
    // consumer never has to slice a one-element bus.
    output wire [WIDTH-1:0]        q
);

  localparam int unsigned DEPTH = N_TAPS * TAP_STRIDE;

  localparam bit USE_MEM = pfb_delay_use_mem(STYLE, pfb_uint_t'(WIDTH),
                                             pfb_uint_t'(N_TAPS), pfb_uint_t'(DEPTH));

`ifndef SYNTHESIS
  initial begin
    if (!pfb_delay_style_ok(STYLE)) begin
      $fatal(1, "delay_line: STYLE=\"%s\" is not \"AUTO\", \"SRL\" or \"MEM\"",
             STYLE);
    end
    if (WIDTH < 1) $fatal(1, "delay_line: WIDTH=%0d is illegal", WIDTH);
    if (N_TAPS < 1) $fatal(1, "delay_line: N_TAPS=%0d is illegal", N_TAPS);
    if (TAP_STRIDE < 1) begin
      $fatal(1, "delay_line: TAP_STRIDE=%0d is illegal", TAP_STRIDE);
    end
    // The arithmetic fact from the header, enforced rather than documented.
    if ((STYLE == "MEM") && (N_TAPS != 1)) begin
      $fatal(1, "delay_line: STYLE=\"MEM\" with N_TAPS=%0d; a memory has one read port per cycle and cannot present %0d taps at once",
             N_TAPS, N_TAPS);
    end
    if (USE_MEM && (DEPTH < 2)) begin
      $fatal(1, "delay_line: STYLE resolves to MEM at DEPTH=%0d; the memory form needs DEPTH >= 2",
             DEPTH);
    end
  end
`endif

  if (USE_MEM) begin : g_mem
    // -------------------------------------------------------------------------
    // Memory form. A pure delay of DEPTH enabled cycles.
    //
    // Write at wr_ptr; read at wr_ptr - (DEPTH-1); register the read. The read
    // therefore returns the value written DEPTH-1 enabled cycles ago and the
    // output register adds the last one, so q is d delayed by exactly DEPTH.
    //
    // MEM_DEPTH is rounded UP to a power of two, which is not (only) about
    // cheap pointer wrapping: it guarantees MEM_DEPTH > DEPTH-1, so the read
    // address is never equal to the write address. That is what makes
    // `no_rw_check` an honest claim rather than a wish — the read-during-write
    // same-address case, whose behaviour differs between M20K configurations,
    // structurally cannot occur.
    // -------------------------------------------------------------------------
    localparam int unsigned MEM_DEPTH = 1 << $clog2(DEPTH);
    localparam int unsigned PTR_W     = $clog2(MEM_DEPTH);

    (* ramstyle = "M20K, no_rw_check" *) logic [WIDTH-1:0] mem [MEM_DEPTH];

    logic [PTR_W-1:0] wr_ptr_q;
    logic [PTR_W-1:0] rd_ptr;
    logic [WIDTH-1:0] rd_q;

    // The pointer is control state and IS reset-free here for the same reason
    // the storage is: nothing downstream reads the line until the consumer's
    // valid pipeline says enough beats have been admitted, and until then the
    // contents are meaningless whatever the pointer was. It is initialised at
    // elaboration so that a simulation does not start on X.
    initial wr_ptr_q = '0;

    assign rd_ptr = wr_ptr_q - PTR_W'(DEPTH - 1);

    always_ff @(posedge clk) begin
      if (en) begin
        rd_q          <= mem[rd_ptr];
        mem[wr_ptr_q] <= d;
        wr_ptr_q      <= wr_ptr_q + PTR_W'(1);
      end
    end

    assign taps = rd_q;
    assign q    = rd_q;

  end else begin : g_srl
    // -------------------------------------------------------------------------
    // Shift-register form. DEPTH registers; taps at the requested stride.
    //
    // One continuous driver per stage, assembled into a packed bus, which is the
    // same discipline rtl/common/complex_multiplier.sv uses for its shadow
    // chain: every bit of `chain` has exactly one driver, so no element can pick
    // up a second procedural writer as the module grows.
    // -------------------------------------------------------------------------
    logic [DEPTH:0][WIDTH-1:0] chain;

    assign chain[0] = d;

    for (genvar s = 0; s < int'(DEPTH); s++) begin : g_stage
      logic [WIDTH-1:0] stage_q;
      always_ff @(posedge clk) begin
        if (en) stage_q <= chain[s];
      end
      assign chain[s+1] = stage_q;
    end

    for (genvar t = 0; t < int'(N_TAPS); t++) begin : g_tap
      assign taps[t*WIDTH +: WIDTH] = chain[(t + 1) * TAP_STRIDE];
    end

    assign q = chain[DEPTH];
  end

endmodule : delay_line

`default_nettype wire
