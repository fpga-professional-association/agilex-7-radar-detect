// -----------------------------------------------------------------------------
// align_sw_wrap — SPEC.md 18 / SPEC.md 7.4 calibration wrapper: THE ROUTING
// FABRIC, and only the routing fabric (issue #16).
//
// Registered pins in, one `align_switch` — which is one `align_xbar` or one
// `align_clos`, chosen by `NET_SEL` — registered pins out. The instance is named
// `u_kernel` because quartus/scripts/calibrate.tcl matches `*u_kernel*` to pull
// the per-entity resource row and to decide whether the worst
// register-to-register path is inside the kernel or in the harness.
//
// -----------------------------------------------------------------------------
// WHY THIS AND NOT THE WHOLE BLOCK
// -----------------------------------------------------------------------------
// SPEC 7.4 asks for area, congestion, latency and Fmax "for both" architectures.
// The two architectures are the two ROUTING FABRICS. Everything else in
// `align_net` — the scheduler, the ingress decode, the reassembly buffer, the
// detector, the counters — is byte-for-byte identical in both builds, and the
// reassembly buffer alone is GROUPS * BIN_PAR * VEC_W flip-flops, which at the
// full-scale width is several times either fabric. Measuring the whole block
// twice would therefore report two numbers that differ by a few percent, and the
// few percent is the answer. This wrapper puts the difference on its own.
//
// The whole block IS measured, at quartus/calibration/align_net_wrap.sv, for the
// thing that number is actually good for: the system-level cost the pull
// request's resource projection needs. Two wrappers, two questions, and neither
// one pretending to answer the other's.
//
// -----------------------------------------------------------------------------
// THE GEOMETRY REACHES THE FABRIC AS A WIDTH
// -----------------------------------------------------------------------------
// `DATA_W` is not a free parameter: it is `align_pkg::algn_net_data_w()` of the
// geometry, so the routed word carries exactly the antenna vector and the
// identity that align_net routes — 534 bits at 16 antennas and 1024 bins, of
// which 512 are the vector and 22 are the (bin, frame offset, flags) identity
// SPEC 7.4 requires to be preserved. Sweeping a round number instead would
// measure a network nobody builds.
//
// NOTE that this wrapper does NOT touch stream_pkg, and that is what lets it be
// swept at the full-scale 16-antenna width: the beamformer beat that width
// implies is 4096 bits, above `STREAM_MAX_DATA_W`, and raising that bound is
// issue #20's business (DECISIONS.md, issue #12 decision 5, and this issue's own
// entry). The fabric does not carry a SPEC 5 payload — it carries one bin's
// vector plus its identity — so the bound does not apply to it and the
// full-scale routing measurement is available a phase early.
//
// SPEC 24: nothing is tied off to make the block optimise away. Every output is
// registered and driven to a pin, and every input is a genuine port rather than
// a constant.
//
// Listed in sim/verilator/files_align.f so `make lint` covers it.
// -----------------------------------------------------------------------------

`default_nettype none

module align_sw_wrap
  import align_pkg::*;
#(
    // The geometry the routed word's width comes from.
    parameter int unsigned N_ANT      = 16,
    parameter int unsigned FFT_SIZE   = 1024,
    parameter int unsigned LANES      = 8,
    parameter int unsigned FRAMES_MAX = 512,
    parameter int unsigned SAMPLE_W   = 16,
    parameter int unsigned BIN_PAR    = 8,
    parameter int unsigned GROUPS     = 4,

    // The SPEC 7.4 architecture axis. 0 = direct registered crossbar,
    // 1 = multistage omega. An integer, not a string: `set_parameter` passes
    // integers cleanly and strings only with quoting that differs between
    // Quartus versions (the same device bf_dot_wrap uses for `VARIANT_SEL`).
    parameter int unsigned NET_SEL    = 0,

    // Registered mux levels in the crossbar. 2 latency-matches it to the omega
    // network at BIN_PAR = 8; 1 does so at BIN_PAR = 4.
    parameter int unsigned MUX_STAGES = 2,

    // DERIVED; never overridden.
    parameter int unsigned DATA_W =
        int'(algn_net_data_w(algn_geom(N_ANT, FFT_SIZE, LANES, FRAMES_MAX,
                                       SAMPLE_W, BIN_PAR, GROUPS))),
    parameter int unsigned DST_W = (BIN_PAR <= 1) ? 1 : $clog2(BIN_PAR)
) (
    input  wire                       clk,
    input  wire                       rst_n,

    input  wire [BIN_PAR-1:0]         in_valid,
    output wire [BIN_PAR-1:0]         in_ready,
    input  wire [BIN_PAR*DATA_W-1:0]  in_data,
    input  wire [BIN_PAR*DST_W-1:0]   in_dst,

    output wire [BIN_PAR-1:0]         out_valid,
    input  wire [BIN_PAR-1:0]         out_ready,
    output wire [BIN_PAR*DATA_W-1:0]  out_data,

    // The blocking rate and the elaborated latency, folded into one registered
    // word rather than given pins of their own. Both still participate, so
    // neither optimises away (SPEC 24), and the boundary stays a fixed cost
    // across the sweep. Same device, same reason, as pfb8_wrap.
    output wire [15:0]                status
);

  // ---------------------------------------------------------------------------
  // Boundary input registers. Valid is reset; the payload is not (SPEC 23) — a
  // wide synchronous clear would distort both the ALM count and the retiming
  // result, which are two of the four numbers this sweep exists to produce.
  // ---------------------------------------------------------------------------
  logic [BIN_PAR-1:0]        iv_q, orr_q;
  logic [BIN_PAR*DATA_W-1:0] id_q;
  logic [BIN_PAR*DST_W-1:0]  is_q;

  always_ff @(posedge clk) begin
    if (!rst_n) begin
      iv_q  <= '0;
      orr_q <= '0;
    end else begin
      iv_q  <= in_valid;
      orr_q <= out_ready;
    end
  end

  always_ff @(posedge clk) begin
    id_q <= in_data;
    is_q <= in_dst;
  end

  // ---------------------------------------------------------------------------
  // The kernel under calibration
  // ---------------------------------------------------------------------------
  wire [BIN_PAR-1:0]        k_in_ready, k_out_valid;
  wire [BIN_PAR*DATA_W-1:0] k_out_data;
  wire                      k_conflict;
  wire [7:0]                k_latency;

  align_switch #(
      .N          (BIN_PAR),
      .DATA_W     (DATA_W),
      .NET_SEL    (NET_SEL),
      .MUX_STAGES (MUX_STAGES),
      .DST_W      (DST_W)
  ) u_kernel (
      .clk            (clk),
      .rst_n          (rst_n),
      .in_valid       (iv_q),
      .in_ready       (k_in_ready),
      .in_data        (id_q),
      .in_dst         (is_q),
      .out_valid      (k_out_valid),
      .out_ready      (orr_q),
      .out_data       (k_out_data),
      .conflict_event (k_conflict),
      .net_latency    (k_latency)
  );

  // ---------------------------------------------------------------------------
  // Boundary output registers
  // ---------------------------------------------------------------------------
  logic [BIN_PAR-1:0]        ir_q, ov_q;
  logic [BIN_PAR*DATA_W-1:0] od_q;
  logic [15:0]               st_q;

  always_ff @(posedge clk) begin
    if (!rst_n) begin
      ir_q <= '0;
      ov_q <= '0;
      st_q <= '0;
    end else begin
      ir_q <= k_in_ready;
      ov_q <= k_out_valid;
      st_q <= {7'd0, k_conflict, k_latency};
    end
  end

  always_ff @(posedge clk) begin
    od_q <= k_out_data;
  end

  assign in_ready  = ir_q;
  assign out_valid = ov_q;
  assign out_data  = od_q;
  assign status    = st_q;

endmodule : align_sw_wrap

`default_nettype wire
