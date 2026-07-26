// -----------------------------------------------------------------------------
// align_xbar — SPEC.md 7.4 architecture 1: the DIRECT REGISTERED CROSSBAR
// (issue #16).
//
// N inputs, N outputs, full connectivity. Every input carries a destination
// index with its word; every output takes at most one word per cycle. This is
// the reference architecture in SPEC 7.4's comparison — "simple but wide" — and
// it is built to be exactly that: one arbiter per output over every input, and
// one mux per output over every input. Nothing is shared between outputs, which
// is the definition of a crossbar and the reason its cost is N^2.
//
// It is interchangeable with rtl/align/align_clos.sv: same ports, same
// parameters, same protocol, same latency at the calibrated settings. That
// interchangeability is the whole point — SPEC 7.4 asks for two architectures
// compared at matched functionality, and two blocks that differ in their
// interface cannot be compared at all.
//
// -----------------------------------------------------------------------------
// 1. THE MUX IS PIPELINED, AND SPEC 7.4 IS WHY
// -----------------------------------------------------------------------------
// SPEC 7.4: "Avoid one giant unregistered multiplexer." At the full-scale
// geometry an output's mux is N = 8 sources of DATA_W = 515 bits, and there are
// 8 of them: 4120 eight-input multiplexers in one combinational cone between two
// registers. That is precisely the structure the sentence forbids.
//
// `MUX_STAGES` is the answer, and it is a PARAMETER rather than a fixed choice
// because the two settings are a real trade the sweep can price:
//
//   MUX_STAGES = 1   one register per output. The N:1 mux is one combinational
//                    cone — 2 LUT6 levels at N = 8, which is not "giant" but is
//                    the whole mux in one stage. Fewest registers, most LUTs on
//                    one path.
//   MUX_STAGES = 2   the N inputs are partitioned into RADIX = ceil(sqrt(N))
//                    groups. Level 0 registers one RADIX:1 mux result per
//                    group; level 1 muxes the GROUPS results into the output
//                    register. No combinational cone is wider than RADIX:1.
//                    GROUPS + 1 registers per output instead of 1.
//
// The default is 2: it satisfies SPEC 7.4 structurally rather than by argument
// about LUT levels, and it makes the crossbar's latency 3 at N = 8, which is
// exactly `align_clos`'s latency at the same width. A comparison between a
// 2-cycle network and a 3-cycle network would be a comparison of pipeline depths
// wearing two topologies' names; `align_pkg`'s latency functions state the match
// and `align_net` checks it.
//
// LEVEL 0 IS N REGISTERS WIDE PER OUTPUT AND THAT IS NOT A MISTAKE. Only one of
// an output's GROUPS level-0 registers can ever be loaded in a cycle, because
// the arbiter grants at most one input per output. Registering all of them
// anyway is what makes the structure a crossbar: the alternative — deciding
// which group to register before registering it — needs the group decision to
// have already muxed the data, which is the N:1 cone again. The cost this
// exposes, GROUPS * N * DATA_W flip-flops, IS the measurement SPEC 7.4 asks for.
//
// -----------------------------------------------------------------------------
// 2. ARBITRATION IS PER OUTPUT AND THE MATCHING IS TRIVIALLY VALID
// -----------------------------------------------------------------------------
// Each input carries ONE destination, so the bipartite matching problem a
// general crossbar scheduler has does not arise: input `i` is a candidate for
// exactly one output, and an output picks one of its candidates. The union of
// the per-output grants is therefore automatically a matching, with no iteration
// and no conflict resolution between outputs. That is a property of this
// block's traffic (a response belongs to exactly one beat position), not a
// simplification of the crossbar.
//
// The arbiter is ROUND ROBIN, not fixed priority. Fixed priority would starve
// the high-numbered history read ports whenever the low-numbered ones stayed
// busy, and since the schedule rotates (align_pkg section 2) that starvation
// would land on a different beat position every group — a throughput defect that
// looks like random skew. `rr_ptr` advances past the granted input on every
// grant, which is the standard rotate-after-grant policy.
//
// -----------------------------------------------------------------------------
// 3. BACKPRESSURE: THE COLUMN FREEZES, IT DOES NOT DROP
// -----------------------------------------------------------------------------
// An output that is not `ready` freezes its ENTIRE column — every level of its
// mux pipeline and its arbiter — rather than letting the pipeline advance into a
// full register. Freezing is lossless by construction (no register is loaded, so
// no value is overwritten) and it needs no skid buffer and no credit counter.
//
// The cost is a bubble: a column that unfreezes takes MUX_STAGES cycles to
// deliver its next word rather than one. That is a throughput cost only when an
// output actually stalls, and `align_net`'s reassembly buffer is sized so that
// its own inputs never stall in normal operation — the stall path exists for the
// case where the beamformer backpressures the whole block, in which case
// stalling is the correct behaviour and a bubble is free.
//
// Columns are INDEPENDENT: output 3 stalling does not stall output 4. Only the
// inputs whose current word is destined for output 3 are held, which is what
// `in_ready` reports.
//
// -----------------------------------------------------------------------------
// 4. WHAT THIS BLOCK DOES NOT DO
// -----------------------------------------------------------------------------
// It does not look at the word it routes. `DATA_W` bits go in and the same
// DATA_W bits come out at the destination the input asked for; the identity
// check, the duplicate detection and the timeout all live in
// rtl/align/align_collect.sv, on the far side. That separation is what lets the
// two architectures be swapped without touching a line of the detection logic,
// and it is why the SPEC 7.4 comparison is a comparison of routing fabrics
// rather than of two whole blocks that happen to share a name.
//
// Lint contract: clean under `verilator --lint-only --Wall` with no waiver.
// -----------------------------------------------------------------------------

`default_nettype none

module align_xbar #(
    // Network width. Inputs and outputs both; a rectangular network is a
    // concentrator, which is a different block with a different correctness
    // argument. Power of two and at least 2, checked at elaboration.
    parameter int unsigned N = 4,

    // Width of the routed word. Opaque to this module.
    parameter int unsigned DATA_W = 32,

    // Registered mux levels per output. 1 or 2; see header section 1.
    parameter int unsigned MUX_STAGES = 2,

    // DERIVED; never overridden. A port width must be a parameter expression.
    parameter int unsigned DST_W = (N <= 1) ? 1 : $clog2(N)
) (
    input  wire                  clk,
    input  wire                  rst_n,

    // Slave side: N independent valid/ready ports, flattened. Input `i` occupies
    // in_data[i*DATA_W +: DATA_W] and in_dst[i*DST_W +: DST_W].
    input  wire [N-1:0]          in_valid,
    output wire [N-1:0]          in_ready,
    input  wire [N*DATA_W-1:0]   in_data,
    input  wire [N*DST_W-1:0]    in_dst,

    // Master side: N independent valid/ready ports, flattened.
    output wire [N-1:0]          out_valid,
    input  wire [N-1:0]          out_ready,
    output wire [N*DATA_W-1:0]   out_data,

    // One cycle high whenever two or more inputs asked for the same output in
    // the same cycle. Not an error — it is the blocking rate, which is the
    // number that distinguishes the two architectures under load and which
    // align_net counts. See align_clos.sv, whose internal blocking is different
    // in kind and is counted through the same port.
    output wire                  conflict_event
);

  // ---------------------------------------------------------------------------
  // Geometry
  // ---------------------------------------------------------------------------

  // ceil(sqrt(N)) without a square root: the smallest r with r*r >= N. N is a
  // power of two and at most bf_max_bin_par, so the loop is short and entirely
  // elaboration-time.
  function automatic int unsigned radix_of(input int unsigned n);
    int unsigned r;
    r = 1;
    while ((r * r) < n) r = r + 1;
    return r;
  endfunction

  localparam int unsigned RADIX  = (MUX_STAGES <= 1) ? N : radix_of(N);
  localparam int unsigned GROUPS = (MUX_STAGES <= 1) ? 1 : ((N + RADIX - 1) / RADIX);

`ifndef SYNTHESIS
  initial begin
    if (N < 2 || ((N & (N - 1)) != 0)) begin
      $fatal(1, "align_xbar: N=%0d must be a power of two and at least 2", N);
    end
    if (DATA_W < 1) begin
      $fatal(1, "align_xbar: DATA_W=%0d must be at least 1", DATA_W);
    end
    if (MUX_STAGES < 1 || MUX_STAGES > 2) begin
      $fatal(1, "align_xbar: MUX_STAGES=%0d must be 1 or 2", MUX_STAGES);
    end
    if (DST_W != ((N <= 1) ? 1 : $clog2(N))) begin
      $fatal(1, "align_xbar: DST_W is derived and must not be overridden");
    end
  end
`endif

  // ---------------------------------------------------------------------------
  // Input capture stage
  //
  // One register per input, shared by every output's mux tree. This is the
  // stage that makes `in_ready` a registered decision rather than a
  // combinational function of eight arbiters, and it is the stage the two
  // architectures have in common.
  // ---------------------------------------------------------------------------
  logic [N-1:0]        a_valid;
  logic [DATA_W-1:0]   a_data [N];
  logic [DST_W-1:0]    a_dst  [N];

  // Set for input `i` when its held word is consumed this cycle.
  logic [N-1:0]        a_take;

  wire  [N-1:0]        a_free = ~a_valid | a_take;

  for (genvar i = 0; i < int'(N); i++) begin : g_in
    wire load = a_free[i] && in_valid[i];

    always_ff @(posedge clk) begin
      if (!rst_n) begin
        a_valid[i] <= 1'b0;
      end else if (load) begin
        a_valid[i] <= 1'b1;
      end else if (a_take[i]) begin
        a_valid[i] <= 1'b0;
      end
    end

    // Payload registers are NOT reset (SPEC 23): a wide synchronous clear
    // distorts both the ALM count and what the retimer can do, and the value is
    // meaningless while `a_valid` is low.
    always_ff @(posedge clk) begin
      if (load) begin
        a_data[i] <= in_data[i*DATA_W +: DATA_W];
        a_dst[i]  <= in_dst[i*DST_W +: DST_W];
      end
    end

    assign in_ready[i] = a_free[i];
  end : g_in

  // ---------------------------------------------------------------------------
  // Per-output arbitration and mux pipeline
  // ---------------------------------------------------------------------------

  // grant[o] is one-hot over inputs. a_take is the OR across outputs, which is a
  // matching by construction: an input requests exactly one output (header
  // section 2).
  logic [N-1:0] grant   [N];
  logic [N-1:0] req     [N];
  logic [N-1:0] col_en;
  logic [N-1:0] contend;

  always_comb begin
    a_take = '0;
    for (int unsigned o = 0; o < N; o++) begin
      a_take = a_take | grant[o];
    end
  end

  assign conflict_event = |contend;

  for (genvar o = 0; o < int'(N); o++) begin : g_out
    // ---- request vector ----
    always_comb begin
      req[o] = '0;
      for (int unsigned i = 0; i < N; i++) begin
        req[o][i] = a_valid[i] && (a_dst[i] == DST_W'(o));
      end
    end

    // Two or more candidates: the blocking event this architecture exhibits.
    always_comb begin
      automatic logic seen;
      seen       = 1'b0;
      contend[o] = 1'b0;
      for (int unsigned i = 0; i < N; i++) begin
        if (req[o][i]) begin
          if (seen) contend[o] = 1'b1;
          seen = 1'b1;
        end
      end
    end

    // ---- round-robin arbiter ----
    logic [DST_W-1:0] rr_ptr;
    logic [N-1:0]     gnt;

    always_comb begin
      automatic logic found;
      gnt   = '0;
      found = 1'b0;
      // Search from rr_ptr upward, wrapping. Two passes over N is the
      // conventional unrolled form and elaborates to a priority encoder on a
      // rotated request vector.
      for (int unsigned k = 0; k < N; k++) begin
        automatic logic [DST_W-1:0] idx;
        idx = DST_W'((int'(rr_ptr) + int'(k)) % int'(N));
        if (!found && req[o][idx] && col_en[o]) begin
          gnt[idx] = 1'b1;
          found    = 1'b1;
        end
      end
    end

    assign grant[o] = gnt;

    always_ff @(posedge clk) begin
      if (!rst_n) begin
        rr_ptr <= '0;
      end else if (|gnt) begin
        for (int unsigned i = 0; i < N; i++) begin
          if (gnt[i]) rr_ptr <= DST_W'((i + 1) % N);
        end
      end
    end

    // ---- the mux pipeline ----
    // Final stage, common to both MUX_STAGES settings.
    logic              v_last;
    logic [DATA_W-1:0] d_last;

    // The column freezes whole when its output is holding a word nobody has
    // taken (header section 3).
    assign col_en[o] = !(v_last && !out_ready[o]);

    if (MUX_STAGES == 1) begin : g_mux1
      // One register per output; the N:1 select is one combinational cone.
      logic [DATA_W-1:0] sel_data;
      always_comb begin
        sel_data = '0;
        for (int unsigned i = 0; i < N; i++) begin
          if (gnt[i]) sel_data = a_data[i];
        end
      end

      always_ff @(posedge clk) begin
        if (!rst_n) begin
          v_last <= 1'b0;
        end else if (col_en[o]) begin
          v_last <= |gnt;
        end
      end

      always_ff @(posedge clk) begin
        if (col_en[o] && (|gnt)) d_last <= sel_data;
      end
    end : g_mux1
    else begin : g_mux2
      // Level 0: one RADIX:1 mux and one register per group. At most one group
      // is ever loaded in a cycle (one grant per output), but all of them are
      // present — see header section 1 for why that is the structure rather
      // than an oversight.
      logic [GROUPS-1:0]  v0;
      logic [DATA_W-1:0]  d0 [GROUPS];

      for (genvar g = 0; g < int'(GROUPS); g++) begin : g_lvl0
        logic              hit;
        logic [DATA_W-1:0] mux;

        always_comb begin
          hit = 1'b0;
          mux = '0;
          for (int unsigned r = 0; r < RADIX; r++) begin
            automatic int unsigned idx;
            idx = int'(g) * int'(RADIX) + int'(r);
            if (idx < int'(N)) begin
              if (gnt[idx]) begin
                hit = 1'b1;
                mux = a_data[idx];
              end
            end
          end
        end

        always_ff @(posedge clk) begin
          if (!rst_n) begin
            v0[g] <= 1'b0;
          end else if (col_en[o]) begin
            v0[g] <= hit;
          end
        end

        always_ff @(posedge clk) begin
          if (col_en[o] && hit) d0[g] <= mux;
        end
      end : g_lvl0

      // Level 1: GROUPS:1 over the level-0 registers, into the output register.
      logic [DATA_W-1:0] sel1;
      always_comb begin
        sel1 = '0;
        for (int unsigned g = 0; g < GROUPS; g++) begin
          if (v0[g]) sel1 = d0[g];
        end
      end

      always_ff @(posedge clk) begin
        if (!rst_n) begin
          v_last <= 1'b0;
        end else if (col_en[o]) begin
          v_last <= |v0;
        end
      end

      always_ff @(posedge clk) begin
        if (col_en[o] && (|v0)) d_last <= sel1;
      end
    end : g_mux2

    assign out_valid[o]                = v_last;
    assign out_data[o*DATA_W +: DATA_W] = d_last;
  end : g_out

endmodule : align_xbar

`default_nettype wire
