// -----------------------------------------------------------------------------
// align_switch — the one interface behind which SPEC.md 7.4's two architectures
// are interchangeable (issue #16).
//
// `NET_SEL` picks `align_xbar` (0) or `align_clos` (1) at elaboration. Nothing
// else in the design names either module: `align_net` instantiates this, the
// SPEC 18 calibration wrapper instantiates this, and the verification top builds
// one of each THROUGH this, so "the two are interchangeable" is a property the
// build enforces rather than a claim the pull request makes.
//
// It also holds the two checks that make the comparison honest, and both are
// elaboration-time:
//
//   * LATENCY MATCH. `align_pkg::algn_xbar_latency(MUX_STAGES)` must equal
//     `algn_clos_latency(N)`. A resource comparison between a 2-cycle network
//     and a 3-cycle network is a comparison of pipeline depths wearing two
//     topologies' names. At N = 8 the match is MUX_STAGES = 2; at N = 4 it is
//     MUX_STAGES = 1. The check fires at time 0 rather than letting a sweep
//     produce two numbers that cannot be put in the same table.
//
//     It is a WARNING, not a fatal, and deliberately so: a caller may want the
//     mismatched point on purpose (to price the crossbar's own MUX_STAGES axis,
//     which is a legitimate second question). What must not happen is that the
//     mismatch goes unrecorded, so it prints, every elaboration, with both
//     numbers in it.
//
//   * SELECTOR RANGE. An out-of-range `NET_SEL` is a fatal rather than a silent
//     default to the crossbar, because a sweep that mistypes the parameter would
//     otherwise compile the same architecture twice and report it as two.
//
// Lint contract: clean under `verilator --lint-only --Wall` with no waiver.
// -----------------------------------------------------------------------------

`default_nettype none

module align_switch
  import align_pkg::*;
#(
    parameter int unsigned N          = 4,
    parameter int unsigned DATA_W     = 32,

    // 0 = ALGN_NET_XBAR, 1 = ALGN_NET_CLOS. An integer rather than a string —
    // see align_pkg's `algn_net_e` for why the calibration flow needs it to be.
    parameter int unsigned NET_SEL    = 0,

    // Registered mux levels in the crossbar. Ignored by the omega network, which
    // has log2(N) stages by construction.
    parameter int unsigned MUX_STAGES = 2,

    // DERIVED; never overridden.
    parameter int unsigned DST_W = (N <= 1) ? 1 : $clog2(N)
) (
    input  wire                  clk,
    input  wire                  rst_n,

    input  wire [N-1:0]          in_valid,
    output wire [N-1:0]          in_ready,
    input  wire [N*DATA_W-1:0]   in_data,
    input  wire [N*DST_W-1:0]    in_dst,

    output wire [N-1:0]          out_valid,
    input  wire [N-1:0]          out_ready,
    output wire [N*DATA_W-1:0]   out_data,

    output wire                  conflict_event,

    // The elaborated latency, in cycles, of whichever architecture was built.
    // A PORT rather than a parameter a consumer recomputes: align_net sizes its
    // timeout from it and the calibration wrapper drives it to a pin, so the
    // number in the record is the number the design built.
    output wire [7:0]            net_latency
);

`ifndef SYNTHESIS
  initial begin
    if (!algn_net_sel_ok(algn_uint_t'(NET_SEL))) begin
      $fatal(1, "align_switch: NET_SEL=%0d is neither ALGN_NET_XBAR (0) nor ALGN_NET_CLOS (1)",
             NET_SEL);
    end
    if (algn_xbar_latency(algn_uint_t'(MUX_STAGES)) !=
        algn_clos_latency(algn_uint_t'(N))) begin
      $display("[align_switch] NOTE: the two architectures are NOT latency-matched at N=%0d (xbar=%0d with MUX_STAGES=%0d, clos=%0d). A resource comparison across this point compares pipeline depths as well as topologies.",
               N, algn_xbar_latency(algn_uint_t'(MUX_STAGES)), MUX_STAGES,
               algn_clos_latency(algn_uint_t'(N)));
    end
  end
`endif

  assign net_latency =
      8'(algn_net_latency(algn_uint_t'(NET_SEL), algn_uint_t'(N),
                          algn_uint_t'(MUX_STAGES)));

  if (NET_SEL == int'(ALGN_NET_CLOS)) begin : g_clos
    align_clos #(
        .N          (N),
        .DATA_W     (DATA_W),
        .MUX_STAGES (MUX_STAGES),
        .DST_W      (DST_W)
    ) u_net (
        .clk            (clk),
        .rst_n          (rst_n),
        .in_valid       (in_valid),
        .in_ready       (in_ready),
        .in_data        (in_data),
        .in_dst         (in_dst),
        .out_valid      (out_valid),
        .out_ready      (out_ready),
        .out_data       (out_data),
        .conflict_event (conflict_event)
    );
  end : g_clos
  else begin : g_xbar
    align_xbar #(
        .N          (N),
        .DATA_W     (DATA_W),
        .MUX_STAGES (MUX_STAGES),
        .DST_W      (DST_W)
    ) u_net (
        .clk            (clk),
        .rst_n          (rst_n),
        .in_valid       (in_valid),
        .in_ready       (in_ready),
        .in_data        (in_data),
        .in_dst         (in_dst),
        .out_valid      (out_valid),
        .out_ready      (out_ready),
        .out_data       (out_data),
        .conflict_event (conflict_event)
    );
  end : g_xbar

endmodule : align_switch

`default_nettype wire
