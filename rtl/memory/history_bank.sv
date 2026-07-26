// -----------------------------------------------------------------------------
// history_bank — one independently addressed bank of the SPEC.md 7.3 history
// (issue #15).
//
// A simple dual-port memory: one write port in one clock domain, one read port
// in another, no shared address, no shared enable, and a register on every
// control and data path at both faces. That is the whole module. Everything
// about WHICH word a request means lives in rtl/memory/history_core.sv and in
// history_pkg's address algebra; this module knows only WIDTH and DEPTH.
//
// The separation is deliberate and is what makes the SPEC 18 experiment
// possible. "One M20K history bank" (SPEC 18 item 8) has to be synthesizable on
// its own, at several geometries, with nothing else in the project around it —
// see quartus/calibration/history_bank_calib.qsf. A bank that knew about frames
// or antennas could not be compiled that way, and the geometry question would
// have to be answered by argument instead of by measurement.
//
// -----------------------------------------------------------------------------
// 1. Why simple dual port, and not true dual port
// -----------------------------------------------------------------------------
// One write port and one read port, never both on one port. The M20K supports a
// true dual-port mode, and using it would halve the block count for a given
// capacity in some geometries — but it would also make every bank a place where
// two requests can collide, and SPEC 7.3 asks for collision COUNTERS precisely
// because collisions are supposed to be observable rather than routine. With
// simple dual port there is exactly one writer and exactly one reader per bank,
// so the only collision that can exist is the LOGICAL one (a read of a frame
// slot that is being overwritten), which is a property of the rotation policy
// and is counted where that policy lives — in history_core, in the read domain,
// against the published frame pointer.
//
// The consequence is stated so a later issue can revisit it with data: this
// choice costs block count in exchange for a collision argument that is
// structural. The SPEC 18 sweep measures the block count; the alternative is not
// swept, because a true-dual-port bank is a different correctness argument and
// not merely a different geometry.
//
// -----------------------------------------------------------------------------
// 2. Registers around the memory (SPEC 23)
// -----------------------------------------------------------------------------
// SPEC 23 says "provide suitable input and output registers around M20Ks", and
// this module is where that rule is obeyed:
//
//     wr_en / wr_addr / wr_data  -> input register -> memory
//     rd_en / rd_addr            -> input register -> memory -> output register
//
// Both are parameters (`IN_REG`, `OUT_REG`) rather than fixed, for one reason:
// SPEC 18 names "input and output register choices" as an axis to SWEEP, and a
// rule that cannot be turned off cannot be measured. history_core fixes both to
// 1 and does not expose them; the calibration wrapper sweeps them. What the
// sweep is actually asking is whether Quartus ABSORBS these registers into the
// M20K's own input and output registers, which is the difference between a
// memory that closes timing at 600 MHz and one that does not, and which shows up
// as a critical path whose endpoints are named `ram_block*~reg*` — the same
// signature issue #11 found in its delay-feedback lines.
//
// The input register is not free of consequence and the consequence is stated
// here rather than discovered later: with `IN_REG = 1` a write lands in the
// array two write-clock edges after it is presented, and a read is answered
// `hist_bank_read_latency()` read-clock edges after it is presented. Both
// numbers are exported from history_pkg so that history_core and the C++ model
// state them once.
//
// -----------------------------------------------------------------------------
// 3. No globally broadcast address or enable network (SPEC 7.3)
// -----------------------------------------------------------------------------
// This is the module's half of the prohibition. Whatever history_core does with
// its fanout, EVERY BANK RE-REGISTERS ITS OWN ADDRESS AND ITS OWN ENABLE before
// the memory sees them. So the net that leaves history_core's per-antenna
// address pipeline terminates at a flip-flop inside each bank, and no net in the
// design runs from one register to every bank's memory input.
//
// It also means the enable is genuinely per bank: `rd_en` low holds both the
// memory's read register and the output register, so an unaddressed bank does
// not toggle and does not appear in the read timing path at all. In the corner
// turn, LANES-1 banks out of every LANES are unaddressed on any given cycle
// (history_pkg section 1), so most of the memory is quiet on most cycles, which
// is the power argument for the banking scheme as well as the timing one.
//
// -----------------------------------------------------------------------------
// 4. Read-during-write
// -----------------------------------------------------------------------------
// The `no_rw_check` in the ramstyle attribute tells Quartus not to build the
// logic that would make a simultaneous read and write of the SAME address return
// a defined value. That is legal here because it cannot happen: history_core's
// rotation guarantees that the frame slot being written is never the frame slot
// being read, and a frame slot is a contiguous range of this bank's addresses.
// The guarantee is not assumed — it is checked, in the read domain, against the
// synchronised write pointer, by history_core's collision logic and by
// sim/assertions/history_rd_assertions.sv.
//
// Note what is NOT claimed: nothing here says the two clocks are related, and
// nothing here synchronises anything. Data does not cross a domain in this
// module; a word written in the write domain is read in the read domain only
// after history_core has published, through a real SPEC 8 crossing, that the
// frame containing it is complete. The `(* cdc_primitive *)` tag below records
// exactly that, so the SPEC 8 inventory names the seam rather than missing it.
//
// Lint contract: linted by `make lint` on every run, clean under --Wall with no
// waiver.
// -----------------------------------------------------------------------------

`default_nettype none

// (* cdc_primitive *) — scripts/cdc_inventory.py reads the attribute below.
// This module has two clock ports and would otherwise be reported as an untagged
// crossing under `--strict`, which is the right default: a dual-clock memory IS
// a place where a domain boundary exists, whether or not the design intends data
// to cross it.
//
// `cdc_stages = "0"` is the honest value and is the point of the tag: this bank
// contains NO synchroniser. Nothing here makes it safe to read a word while it
// is being written. What makes the design safe is the frame-pointer crossing in
// rtl/memory/history_core.sv, which is separately tagged, and the inventory
// therefore shows a zero-stage bulk path guarded by a tagged pointer crossing —
// which is the actual architecture, stated where a reviewer will see it.
(* cdc_primitive = "history_bank_sdp", cdc_src_clk = "wr_clk", cdc_dst_clk = "rd_clk", cdc_width = "WIDTH", cdc_stages = "0" *)
module history_bank #(
    // Bits per stored word. history_core uses 2 * SAMPLE_W (one complex sample);
    // the SPEC 18 sweep uses whatever shape it is measuring.
    parameter int unsigned WIDTH = 32,

    // Words. Minimum 2 — a one-word "memory" has a zero-width address and is a
    // register, not a bank.
    parameter int unsigned DEPTH = 256,

    // Registers between the module's face and the memory array. See section 2.
    // history_core fixes both to 1; the calibration wrapper sweeps them.
    parameter bit IN_REG  = 1'b1,
    parameter bit OUT_REG = 1'b1,

    // Storage geometry. The value selects a LITERAL `ramstyle` attribute in one
    // named generate branch rather than being substituted into one: Quartus
    // wants a string literal there, and Verilator does not count a parameter
    // read inside an attribute as a use of the parameter (measured — it reports
    // UNUSEDPARAM). Same device, same reason, as rtl/common/sync_fifo.sv.
    //
    //   "auto"  no attribute; Quartus chooses. The right default for a bank
    //           whose depth is not known at the time this file is written.
    //   "m20k"  block RAM. What a history bank is expected to become.
    //   "mlab"  LUT-RAM. Right only for a very shallow bank; measured by the
    //           sweep so the crossover is a number and not a guess.
    //   "regs"  ALM registers. Present so the sweep has a floor to compare
    //           against, not because a history bank should ever be built of them.
    parameter string STORAGE = "auto"
) (
    // ---------------- write domain (core_clk) ----------------
    input  wire                       wr_clk,
    input  wire                       wr_rst_n,

    input  wire                       wr_en,
    input  wire [$clog2(DEPTH)-1:0]   wr_addr,
    input  wire [WIDTH-1:0]           wr_data,

    // ---------------- read domain (history_clk) ----------------
    input  wire                       rd_clk,
    input  wire                       rd_rst_n,

    input  wire                       rd_en,
    input  wire [$clog2(DEPTH)-1:0]   rd_addr,

    // Valid exactly hist_bank_read_latency() read edges after the `rd_en` that
    // produced it. Exported rather than left for the consumer to count, so the
    // latency is stated by the module that owns it and a change to IN_REG or
    // OUT_REG cannot silently desynchronise a pipeline built around it.
    output wire                       rd_data_valid,
    output wire [WIDTH-1:0]           rd_data
);

  localparam int unsigned ADDR_W = (DEPTH > 1) ? $clog2(DEPTH) : 1;

`ifndef SYNTHESIS
  initial begin
    if (DEPTH < 2) begin
      $fatal(1, "history_bank: DEPTH=%0d is illegal; minimum is 2", DEPTH);
    end
    if (WIDTH < 1) begin
      $fatal(1, "history_bank: WIDTH=%0d is illegal", WIDTH);
    end
    if (STORAGE != "auto" && STORAGE != "regs" && STORAGE != "mlab" &&
        STORAGE != "m20k") begin
      $fatal(1, "history_bank: STORAGE=\"%s\" is not one of auto, regs, mlab, m20k",
             STORAGE);
    end
  end
`endif

  // ---------------------------------------------------------------------------
  // Storage
  //
  // One named generate block per style so the `ramstyle` attribute is a literal
  // in every branch. All four branches name the block `g_store`, so
  // `g_store.mem` refers to whichever one was elaborated and the access code
  // below exists exactly once.
  // ---------------------------------------------------------------------------
  if (STORAGE == "m20k") begin : g_store
    (* ramstyle = "M20K, no_rw_check" *) logic [WIDTH-1:0] mem [DEPTH];
  end else if (STORAGE == "mlab") begin : g_store
    (* ramstyle = "MLAB, no_rw_check" *) logic [WIDTH-1:0] mem [DEPTH];
  end else if (STORAGE == "regs") begin : g_store
    (* ramstyle = "logic" *) logic [WIDTH-1:0] mem [DEPTH];
  end else begin : g_store
    (* ramstyle = "no_rw_check" *) logic [WIDTH-1:0] mem [DEPTH];
  end

  // ---------------------------------------------------------------------------
  // Write port — input registration, then the array
  //
  // Only the ENABLE is reset. The address and the data are free-running, per
  // SPEC 23: a reset on a WIDTH-bit data register is a wide fanout of the reset
  // net for no benefit, because a word whose enable never went high is never
  // read. Validity is reset; the datapath is not.
  // ---------------------------------------------------------------------------
  logic              wr_en_i;
  logic [ADDR_W-1:0] wr_addr_i;
  logic [WIDTH-1:0]  wr_data_i;

  if (IN_REG) begin : g_wr_in_reg
    logic              wr_en_q;
    logic [ADDR_W-1:0] wr_addr_q;
    logic [WIDTH-1:0]  wr_data_q;

    always_ff @(posedge wr_clk) begin
      if (!wr_rst_n) begin
        wr_en_q <= 1'b0;
      end else begin
        wr_en_q <= wr_en;
      end
    end

    always_ff @(posedge wr_clk) begin
      wr_addr_q <= wr_addr;
      wr_data_q <= wr_data;
    end

    assign wr_en_i   = wr_en_q;
    assign wr_addr_i = wr_addr_q;
    assign wr_data_i = wr_data_q;
  end else begin : g_wr_in_comb
    assign wr_en_i   = wr_en;
    assign wr_addr_i = wr_addr;
    assign wr_data_i = wr_data;
  end

  always_ff @(posedge wr_clk) begin
    if (wr_en_i) begin
      g_store.mem[wr_addr_i] <= wr_data_i;
    end
  end

  // ---------------------------------------------------------------------------
  // Read port — input registration, the array's own output register, then the
  // optional second output register.
  //
  // Every stage is gated by its own enable, so an unaddressed bank holds still.
  // That is what makes the LANES-1 idle banks of a corner-turn read cost nothing
  // in toggling and stay out of the read timing path.
  // ---------------------------------------------------------------------------
  logic              rd_en_i;
  logic [ADDR_W-1:0] rd_addr_i;

  if (IN_REG) begin : g_rd_in_reg
    logic              rd_en_q;
    logic [ADDR_W-1:0] rd_addr_q;

    always_ff @(posedge rd_clk) begin
      if (!rd_rst_n) begin
        rd_en_q <= 1'b0;
      end else begin
        rd_en_q <= rd_en;
      end
    end

    always_ff @(posedge rd_clk) begin
      rd_addr_q <= rd_addr;
    end

    assign rd_en_i   = rd_en_q;
    assign rd_addr_i = rd_addr_q;
  end else begin : g_rd_in_comb
    assign rd_en_i   = rd_en;
    assign rd_addr_i = rd_addr;
  end

  // The array's read register. This one is not optional: a memory read that is
  // not registered is a combinational read of the array, which forbids M20K
  // inference outright (rtl/common/sync_fifo.sv records the same constraint for
  // its show-ahead mode).
  logic [WIDTH-1:0] mem_q;
  logic             mem_v_q;

  always_ff @(posedge rd_clk) begin
    if (rd_en_i) begin
      mem_q <= g_store.mem[rd_addr_i];
    end
  end

  always_ff @(posedge rd_clk) begin
    if (!rd_rst_n) begin
      mem_v_q <= 1'b0;
    end else begin
      mem_v_q <= rd_en_i;
    end
  end

  if (OUT_REG) begin : g_rd_out_reg
    logic [WIDTH-1:0] out_q;
    logic             out_v_q;

    always_ff @(posedge rd_clk) begin
      if (mem_v_q) begin
        out_q <= mem_q;
      end
    end

    always_ff @(posedge rd_clk) begin
      if (!rd_rst_n) begin
        out_v_q <= 1'b0;
      end else begin
        out_v_q <= mem_v_q;
      end
    end

    assign rd_data       = out_q;
    assign rd_data_valid = out_v_q;
  end else begin : g_rd_out_comb
    assign rd_data       = mem_q;
    assign rd_data_valid = mem_v_q;
  end

endmodule : history_bank

`default_nettype wire
