// -----------------------------------------------------------------------------
// fft_reorder — bit-reversed to natural beat order, double buffered.
//
// A single-path delay-feedback FFT delivers its result in bit-reversed order.
// fft_core's output beat j carries X[m] and X[m + N/2] with m = bitrev(j); this
// module turns that into beat j carrying X[j] and X[j + N/2].
//
// It permutes BEATS ONLY. Both slots of a beat move together, and no sample ever
// changes lane. That is not luck: it is why fft_core was arranged with a
// decimation-in-time split at the input and a merge at the output rather than
// the other way round. A design whose output pair were (X[2j], X[2j+1]) would
// need the two slots to come from addresses that differ in the LOW bit, i.e.
// from the same bank on the same cycle, and the reorder buffer would need a
// second read port it cannot have. With the pair (X[j], X[j+N/2]) the two slots
// are simply two independent banks read at the same address.
//
// Double buffered, not in place. A frame cannot be read in natural order until
// it is completely written, so one frame is filled while the previous one is
// drained: two banks per lane, and one whole frame of latency. An in-place
// exchange is possible — bit reversal is an involution, so the permutation is a
// set of swaps — but it needs a read and a write to two different addresses in
// the same cycle and it cannot start until the frame is complete either, so it
// buys memory at the price of a second port and a much harder correctness
// argument. See DECISIONS.md (issue #11).
//
// REORDERING IS OPTIONAL. The corner-turn memory of issue #15 addresses its
// write side arbitrarily and can absorb the permutation for free, in which case
// this module is not elaborated at all and the frame of latency and the two
// banks are not spent. streaming_fft's REORDER parameter is that choice, and
// both orders are bit-exact against the reference model — the model applies the
// same permutation, or does not, from the same parameter.
//
// Lint contract: clean under `verilator --lint-only --Wall` with no waiver.
// -----------------------------------------------------------------------------

`default_nettype none

module fft_reorder #(
    // log2 of the beats per frame. The buffer holds 2^N_LANE beats per bank.
    parameter int unsigned N_LANE = 5,

    // Beat width: SAMPLES_PER_CYCLE complex samples.
    parameter int unsigned WIDTH  = 64,

    // "AUTO" | "M20K" | "MLAB" | "LOGIC" — SPEC 18 memory-geometry axis.
    parameter string       STYLE  = "AUTO"
) (
    input  wire                clk,
    input  wire                rst_n,

    input  wire                vld_in,
    input  wire [WIDTH-1:0]    din,
    input  wire [N_LANE-1:0]   idx_in,
    input  wire                warm_in,

    output wire                vld_out,
    output wire [WIDTH-1:0]    dout,
    output wire [N_LANE-1:0]   idx_out,
    output wire                warm_out
);

  localparam int unsigned M           = 1 << N_LANE;
  localparam int unsigned WARM_TARGET = M + 1;   // one frame plus the read register
  localparam int unsigned WARM_CNT_W  = $clog2(WARM_TARGET + 1);

  // ---------------------------------------------------------------------------
  // Addressing
  //
  // Write at bitrev(idx), read at idx. Reading address j of the previous frame
  // returns the beat that was written at bitrev(j'), i.e. the beat with
  // j' = bitrev(j) — which carries X[bitrev(j')] = X[j]. The bit reversal is a
  // wire permutation and costs nothing.
  // ---------------------------------------------------------------------------
  logic [N_LANE-1:0] wr_addr;
  for (genvar b = 0; b < int'(N_LANE); b++) begin : g_bitrev
    assign wr_addr[b] = idx_in[N_LANE-1-b];
  end

  // Bank in use for WRITING. Toggles at the end of every frame, so the frame
  // being read is always the other bank.
  logic bank_q;
  always_ff @(posedge clk) begin
    if (!rst_n) begin
      bank_q <= 1'b0;
    end else if (vld_in && (idx_in == N_LANE'(M - 1))) begin
      bank_q <= ~bank_q;
    end
  end

  // ---------------------------------------------------------------------------
  // Storage: two banks, each one write port and one read port. Two arrays rather
  // than one array with a bank bit in the address, so each is a simple dual-port
  // memory of the natural depth and Quartus is not asked to build a 2M-deep
  // memory whose two halves are never accessed together.
  // ---------------------------------------------------------------------------
  logic [WIDTH-1:0] rd_q;

  if (STYLE == "M20K") begin : g_m20k
    (* ramstyle = "M20K" *) logic [WIDTH-1:0] mem0 [M];
    (* ramstyle = "M20K" *) logic [WIDTH-1:0] mem1 [M];
    always_ff @(posedge clk) begin
      if (vld_in) begin
        if (bank_q) mem1[wr_addr] <= din;
        else        mem0[wr_addr] <= din;
        rd_q <= bank_q ? mem0[idx_in] : mem1[idx_in];
      end
    end
  end else if (STYLE == "MLAB") begin : g_mlab
    (* ramstyle = "MLAB" *) logic [WIDTH-1:0] mem0 [M];
    (* ramstyle = "MLAB" *) logic [WIDTH-1:0] mem1 [M];
    always_ff @(posedge clk) begin
      if (vld_in) begin
        if (bank_q) mem1[wr_addr] <= din;
        else        mem0[wr_addr] <= din;
        rd_q <= bank_q ? mem0[idx_in] : mem1[idx_in];
      end
    end
  end else if (STYLE == "LOGIC") begin : g_logic
    (* ramstyle = "logic" *) logic [WIDTH-1:0] mem0 [M];
    (* ramstyle = "logic" *) logic [WIDTH-1:0] mem1 [M];
    always_ff @(posedge clk) begin
      if (vld_in) begin
        if (bank_q) mem1[wr_addr] <= din;
        else        mem0[wr_addr] <= din;
        rd_q <= bank_q ? mem0[idx_in] : mem1[idx_in];
      end
    end
  end else begin : g_auto
    logic [WIDTH-1:0] mem0 [M];
    logic [WIDTH-1:0] mem1 [M];
    always_ff @(posedge clk) begin
      if (vld_in) begin
        if (bank_q) mem1[wr_addr] <= din;
        else        mem0[wr_addr] <= din;
        rd_q <= bank_q ? mem0[idx_in] : mem1[idx_in];
      end
    end
  end

  // ---------------------------------------------------------------------------
  // Metadata and warmth
  //
  // fft_core's warmth rises exactly at a frame boundary — its first real output
  // beat is position 0 of frame 0, because the core's latency maps input beat 0
  // onto the first warm output beat — so counting M+1 warm beats here marks
  // exactly the first beat of the first COMPLETELY written frame. That
  // alignment is asserted below rather than assumed.
  // ---------------------------------------------------------------------------
  logic [N_LANE-1:0]     idx_q;
  logic                  vld_q;
  logic [WARM_CNT_W-1:0] warm_cnt_q;

  always_ff @(posedge clk) begin
    if (vld_in) idx_q <= idx_in;
  end

  always_ff @(posedge clk) begin
    if (!rst_n) begin
      vld_q      <= 1'b0;
      warm_cnt_q <= '0;
    end else begin
      vld_q <= vld_in;
      if (vld_in && warm_in && (warm_cnt_q != WARM_CNT_W'(WARM_TARGET))) begin
        warm_cnt_q <= warm_cnt_q + WARM_CNT_W'(1);
      end
    end
  end

  assign vld_out  = vld_q;
  assign dout     = rd_q;
  assign idx_out  = idx_q;
  assign warm_out = (warm_cnt_q == WARM_CNT_W'(WARM_TARGET));

`ifndef SYNTHESIS
  // Warmth must arrive on a frame boundary: if it did not, the first natural-
  // order frame this module emitted would be half of one frame and half of the
  // fill, which is exactly the failure that a bit-exact comparison would report
  // as "everything is wrong" rather than as "the alignment is off by k".
  logic warm_prev_q;
  always_ff @(posedge clk) begin
    if (!rst_n) warm_prev_q <= 1'b0;
    else if (vld_in) warm_prev_q <= warm_in;
  end

  always_ff @(posedge clk) begin
    if (rst_n && vld_in && warm_in && !warm_prev_q) begin
      a_fft_reorder_warm_on_frame_start : assert (idx_in == '0)
        else $error("fft_reorder: warmth started at frame position %0d, not 0", idx_in);
    end
  end
`endif

endmodule : fft_reorder

`default_nettype wire
