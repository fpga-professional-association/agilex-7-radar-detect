// -----------------------------------------------------------------------------
// fft_delay_line — the delay feedback of a single-path delay-feedback stage.
//
// SPEC 7.2 requires the FFT's memories to be inferred rather than instantiated,
// and SPEC 18 item 4 makes "how did the delay feedback map" one of the numbers
// the calibration phase has to MEASURE. This module is the one place the answer
// is decided, so there is exactly one memory description in the FFT and exactly
// one place a memory-geometry experiment changes.
//
// Contract
// --------
// `q` is `d` delayed by exactly DEPTH ENABLED cycles. Cycles with `en` low do
// not advance the line at all — the SDF datapath is indexed by sample position,
// not by time, so a stall must freeze the feedback rather than shift zeros
// through it.
//
// How DEPTH cycles come out of a DEPTH-entry memory
// -------------------------------------------------
// The write pointer advances one entry per enabled cycle. The read address is
// one entry AHEAD of the write pointer, so it names the oldest live entry: the
// value written DEPTH-1 cycles ago. One output register then makes the total
// exactly DEPTH.
//
//     write addr = w             read addr = w + 1 (mod DEPTH)
//     mem[w+1] was written at t+1-DEPTH   ->   q(t+1) = d(t+1-DEPTH)
//
// Read and write addresses are therefore NEVER equal, which is the point: a
// circular buffer of DEPTH-1 entries would give the same latency with the read
// and the write on the same address every cycle, and same-address
// read-during-write behaviour on an M20K is a mode question rather than a
// portable guarantee. One extra word buys the guarantee.
//
// DEPTH = 1 is a plain register. The last sub-stage of every SDF path has
// DEPTH = 1, and a one-entry memory whose read address equals its write address
// is exactly the case the paragraph above refuses to depend on.
//
// Reset (SPEC 23 "reset validity, not every datapath bit")
// --------------------------------------------------------
// Only the write pointer is reset. The storage is not: resetting DEPTH x WIDTH
// bits would be a reset fanout that scales with the transform size and would
// pin every one of those bits out of retiming for no functional gain. Nothing
// downstream may look at the contents before they are written, and streaming_fft
// enforces exactly that with its fill counter — the first
// fft_pkg::fft_total_latency() beats after reset produce no valid output.
//
// STYLE (SPEC 18 "memory geometry")
// ---------------------------------
// "AUTO" leaves the choice to Quartus, which is what the design ships with.
// "M20K" / "MLAB" / "LOGIC" force it, so the calibration sweep can price the
// three against each other instead of arguing about where a 32-entry line
// belongs. The attribute is the only difference between the branches; the
// behaviour is identical and one shared assertion covers all of them.
//
// Lint contract: clean under `verilator --lint-only --Wall` with no waiver.
// -----------------------------------------------------------------------------

`default_nettype none

module fft_delay_line #(
    parameter int unsigned WIDTH = 32,

    // Delay in enabled cycles. Minimum 1.
    parameter int unsigned DEPTH = 4,

    // "AUTO" | "M20K" | "MLAB" | "LOGIC". See the note above.
    parameter string       STYLE = "AUTO"
) (
    input  wire              clk,
    input  wire              rst_n,
    input  wire              en,
    input  wire  [WIDTH-1:0] d,
    output wire  [WIDTH-1:0] q
);

  localparam int unsigned ADDR_W = (DEPTH <= 2) ? 1 : $clog2(DEPTH);

`ifndef SYNTHESIS
  initial begin
    if (DEPTH < 1) begin
      $fatal(1, "fft_delay_line: DEPTH=%0d is illegal; minimum is 1", DEPTH);
    end
    if (WIDTH < 1) begin
      $fatal(1, "fft_delay_line: WIDTH=%0d is illegal; minimum is 1", WIDTH);
    end
    if (STYLE != "AUTO" && STYLE != "M20K" && STYLE != "MLAB" &&
        STYLE != "LOGIC") begin
      $fatal(1, "fft_delay_line: STYLE=\"%s\" is not AUTO/M20K/MLAB/LOGIC",
             STYLE);
    end
  end
`endif

  if (DEPTH == 1) begin : g_reg
    // ---- one register ------------------------------------------------------
    logic [WIDTH-1:0] q_r;
    always_ff @(posedge clk) begin
      if (en) q_r <= d;
    end
    assign q = q_r;

  end else begin : g_mem
    // ---- circular memory, read one ahead of write --------------------------
    logic [ADDR_W-1:0] wr_q;
    logic [ADDR_W-1:0] rd_c;
    logic [WIDTH-1:0]  q_r;

    assign rd_c = (wr_q == ADDR_W'(DEPTH - 1)) ? ADDR_W'(0)
                                               : (wr_q + ADDR_W'(1));

    always_ff @(posedge clk) begin
      if (!rst_n) begin
        wr_q <= ADDR_W'(0);
      end else if (en) begin
        wr_q <= (wr_q == ADDR_W'(DEPTH - 1)) ? ADDR_W'(0)
                                             : (wr_q + ADDR_W'(1));
      end
    end

    // The four branches differ ONLY in the synthesis attribute. Verilator
    // ignores the attribute and lints one description; Quartus reads it and
    // places the storage where the sweep asked for it.
    if (STYLE == "M20K") begin : g_m20k
      (* ramstyle = "M20K" *) logic [WIDTH-1:0] mem [DEPTH];
      always_ff @(posedge clk) begin
        if (en) begin
          q_r      <= mem[rd_c];
          mem[wr_q] <= d;
        end
      end
    end else if (STYLE == "MLAB") begin : g_mlab
      (* ramstyle = "MLAB" *) logic [WIDTH-1:0] mem [DEPTH];
      always_ff @(posedge clk) begin
        if (en) begin
          q_r      <= mem[rd_c];
          mem[wr_q] <= d;
        end
      end
    end else if (STYLE == "LOGIC") begin : g_logic
      (* ramstyle = "logic" *) logic [WIDTH-1:0] mem [DEPTH];
      always_ff @(posedge clk) begin
        if (en) begin
          q_r      <= mem[rd_c];
          mem[wr_q] <= d;
        end
      end
    end else begin : g_auto
      logic [WIDTH-1:0] mem [DEPTH];
      always_ff @(posedge clk) begin
        if (en) begin
          q_r      <= mem[rd_c];
          mem[wr_q] <= d;
        end
      end
    end

    assign q = q_r;
  end

  // ---------------------------------------------------------------------------
  // Simulation-only proof of the contract
  //
  // An independent shadow queue — a plain DEPTH-entry shift register, which is
  // the naive implementation this module exists to avoid in hardware — is fed
  // the same data with the same enable and its output must equal `q` on every
  // enabled cycle once DEPTH values have been pushed. The pointer arithmetic
  // therefore cannot be checked against itself; it is checked against a second
  // description of "delay by DEPTH".
  // ---------------------------------------------------------------------------
`ifndef SYNTHESIS
  // Shadow shift register. Verilator 5.020 refuses to compile a for-loop
  // with delayed assignments to an unpacked array (BLKLOOPINIT) when the
  // loop bound is large. Rewrite the shift as a packed vector so the
  // element index is a bit-slice select rather than an array lookup and
  // the shift is a single non-blocking assignment. Semantics unchanged.
  logic [DEPTH-1:0][WIDTH-1:0] shadow;
  logic [31:0]      pushed_q;

  always_ff @(posedge clk) begin
    if (!rst_n) begin
      pushed_q <= 32'd0;
    end else if (en) begin
      shadow[0] <= d;
      if (pushed_q < 32'hFFFF_FFFF) pushed_q <= pushed_q + 32'd1;
    end
  end
  if (DEPTH > 1) begin : g_shadow_shift
    always_ff @(posedge clk) begin
      if (rst_n && en) begin
        shadow[DEPTH-1:1] <= shadow[DEPTH-2:0];
      end
    end
  end

  always_ff @(posedge clk) begin
    if (rst_n && en && (pushed_q >= 32'(DEPTH))) begin
      a_fft_delay_matches_shadow : assert (q == shadow[DEPTH-1])
        else $error("fft_delay_line(DEPTH=%0d): q=%0h but a %0d-deep shift register holds %0h",
                    DEPTH, q, DEPTH, shadow[DEPTH-1]);
    end
  end
`endif

endmodule : fft_delay_line

`default_nettype wire
