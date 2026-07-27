// -----------------------------------------------------------------------------
// mem_arbiter -- N-to-1 arbitration for the abstract memory interface (#19).
//
// This is the SEAM. Issue #24 replaces THIS MODULE with an HBM2e AXI adapter
// (`hbm_axi_adapter` in an upcoming file); everything upstream of it -- the
// event aggregator, the future covariance store, the future raw-capture path --
// continues to use rtl/memory/mem_req_rsp_if.sv, which is the vendor-neutral
// abstraction SPEC 4.3 asks for. Nothing above this line ever sees HBM2e or an
// AXI channel structure.
//
// For Phase 4 the arbiter is a small round-robin over N producer ports into
// ONE consumer port (the behavioural memory model). Fair enough that no
// producer is starved, cheap enough that the arbitration is not the timing
// bottleneck: SPEC 7.8's arbitration in the packet fabric goes into more
// depth, but a memory-side arbiter is one-hop and one clock domain.
//
// Response routing: responses carry the request tag. This module keeps a small
// per-producer table mapping issued tags back to their producer id, so a
// response returning at any time is delivered to the right producer. The table
// size (N_PORTS * MAX_INFLIGHT_PER_PORT) is checked at elaboration against the
// MEM_TAG_W field's capacity.
//
// Reset (SPEC 23): the arbitration state and the tag table are control state
// and reset in full.
// -----------------------------------------------------------------------------

`default_nettype none

module mem_arbiter
  import mem_pkg::*;
#(
    parameter int unsigned N_PORTS = 2,
    parameter int unsigned MAX_INFLIGHT_PER_PORT = 4
) (
    input  wire                              clk,
    input  wire                              rst_n,

    // ---- upstream ports (producers) ----
    input  wire [N_PORTS-1:0]                s_req_valid,
    output wire [N_PORTS-1:0]                s_req_ready,
    input  mem_req_t                         s_req[N_PORTS],

    output wire [N_PORTS-1:0]                s_rsp_valid,
    input  wire [N_PORTS-1:0]                s_rsp_ready,
    output mem_rsp_t                         s_rsp[N_PORTS],

    // ---- downstream port (the behavioural memory model) ----
    output wire                              m_req_valid,
    input  wire                              m_req_ready,
    output mem_req_t                         m_req,

    input  wire                              m_rsp_valid,
    output wire                              m_rsp_ready,
    input  mem_rsp_t                         m_rsp,

    // ---- soft reset / enable from DBG_MEM_CTRL ----
    input  wire                              cfg_enable,
    input  wire                              cfg_soft_reset,

    // ---- observation for the debug window ----
    output wire [7:0]                        obs_inflight,
    output wire [7:0]                        obs_max_inflight,
    output wire [7:0]                        obs_outstanding_tag
);

`ifndef SYNTHESIS
  initial begin
    // The tag table indexes at N_PORTS * MAX_INFLIGHT_PER_PORT; MEM_TAG_W must
    // hold that many distinct tags.
    if ((N_PORTS * MAX_INFLIGHT_PER_PORT) > (1 << MEM_TAG_W)) begin
      $fatal(1, "mem_arbiter: %0d ports * %0d inflight = %0d tags do not fit MEM_TAG_W=%0d",
             N_PORTS, MAX_INFLIGHT_PER_PORT,
             N_PORTS * MAX_INFLIGHT_PER_PORT, MEM_TAG_W);
    end
  end
`endif

  localparam int unsigned PORT_W = (N_PORTS <= 1) ? 1 : $clog2(N_PORTS);

  // ---- Round-robin over available producers ----
  logic [PORT_W-1:0] rr_ptr_q;
  wire  [N_PORTS-1:0] req_pending = s_req_valid & {N_PORTS{cfg_enable}};

  // Pick the next port after rr_ptr_q that has a request pending.
  logic [PORT_W-1:0] grant_idx;
  logic              grant_valid;
  always_comb begin
    grant_idx   = rr_ptr_q;
    grant_valid = 1'b0;
    for (int unsigned i = 0; i < N_PORTS; i++) begin
      // Search order: rr_ptr, rr_ptr+1, ..., rr_ptr-1 (rotated)
      logic [PORT_W-1:0] idx;
      idx = PORT_W'((32'(rr_ptr_q) + i) % N_PORTS);
      if (!grant_valid && req_pending[idx]) begin
        grant_idx   = idx;
        grant_valid = 1'b1;
      end
    end
  end

  wire m_req_fire = m_req_valid && m_req_ready;

  always_ff @(posedge clk) begin
    if (!rst_n || cfg_soft_reset) begin
      rr_ptr_q <= '0;
    end else if (m_req_fire) begin
      rr_ptr_q <= (grant_idx == PORT_W'(N_PORTS-1)) ? '0 : (grant_idx + PORT_W'(1));
    end
  end

  // ---- tag mapping: for each ISSUED tag we remember which port it belongs to ----
  localparam int unsigned MAX_TAG = N_PORTS * MAX_INFLIGHT_PER_PORT;
  localparam int unsigned TAG_W_USED = (MAX_TAG <= 1) ? 1 : $clog2(MAX_TAG);

  logic [PORT_W-1:0]  tag_owner_q [MAX_TAG];
  logic               tag_valid_q [MAX_TAG];
  logic [TAG_W_USED-1:0] next_tag_q;
  logic [7:0]         inflight_q;

  // Find a free tag when issuing.
  logic [TAG_W_USED-1:0] free_tag_c;
  logic                  free_tag_valid_c;
  always_comb begin
    free_tag_c = '0;
    free_tag_valid_c = 1'b0;
    for (int unsigned i = 0; i < MAX_TAG; i++) begin
      logic [TAG_W_USED-1:0] idx2;
      idx2 = TAG_W_USED'((32'(next_tag_q) + i) % MAX_TAG);
      if (!free_tag_valid_c && !tag_valid_q[idx2]) begin
        free_tag_c = idx2;
        free_tag_valid_c = 1'b1;
      end
    end
  end

  // We accept a producer's beat only when we have both a downstream slot and a
  // free tag.
  wire can_issue = grant_valid && m_req_ready && free_tag_valid_c;

  // ---- Downstream request ----
  mem_req_t m_req_q;
  logic     m_req_valid_q;

  always_ff @(posedge clk) begin
    if (!rst_n || cfg_soft_reset) begin
      m_req_valid_q <= 1'b0;
      m_req_q       <= '0;
      next_tag_q    <= '0;
      inflight_q    <= 8'd0;
      for (int unsigned t = 0; t < MAX_TAG; t++) begin
        tag_valid_q[t] <= 1'b0;
        tag_owner_q[t] <= '0;
      end
    end else begin
      if (m_req_fire) m_req_valid_q <= 1'b0;

      if (can_issue) begin
        m_req_q       <= s_req[grant_idx];
        m_req_q.tag   <= MEM_TAG_W'(free_tag_c);
        m_req_valid_q <= 1'b1;
        tag_valid_q[free_tag_c] <= 1'b1;
        tag_owner_q[free_tag_c] <= grant_idx;
        next_tag_q    <= (free_tag_c == TAG_W_USED'(MAX_TAG-1)) ? '0 : (free_tag_c + TAG_W_USED'(1));
        inflight_q    <= inflight_q + 8'd1;
      end

      // Response: free the tag, decrement.
      if (m_rsp_valid && m_rsp_ready) begin
        logic [TAG_W_USED-1:0] rt;
        rt = m_rsp.tag[TAG_W_USED-1:0];
        if (32'(rt) < 32'(MAX_TAG) && tag_valid_q[rt]) begin
          tag_valid_q[rt] <= 1'b0;
        end
        if (inflight_q != 8'd0) inflight_q <= inflight_q - 8'd1;
      end
    end
  end

  assign m_req_valid = m_req_valid_q;
  assign m_req       = m_req_q;

  // Ready to producer only if we are picking that producer AND we can issue.
  for (genvar p = 0; p < N_PORTS; p++) begin : g_req_ready
    assign s_req_ready[p] = can_issue && (grant_idx == PORT_W'(p)) && !m_req_valid_q;
  end

  // ---- Response routing ----
  // The response tag tells us who owns it. We route s_rsp_valid[owner] and
  // hold the response until the producer accepts it.
  mem_rsp_t s_rsp_q [N_PORTS];
  logic [N_PORTS-1:0] s_rsp_valid_q;

  always_ff @(posedge clk) begin
    if (!rst_n || cfg_soft_reset) begin
      s_rsp_valid_q <= '0;
      for (int unsigned p = 0; p < N_PORTS; p++) s_rsp_q[p] <= '0;
    end else begin
      // Clear on accept
      for (int unsigned p = 0; p < N_PORTS; p++) begin
        if (s_rsp_valid_q[p] && s_rsp_ready[p]) begin
          s_rsp_valid_q[p] <= 1'b0;
        end
      end
      // Capture new response
      if (m_rsp_valid && m_rsp_ready) begin
        logic [TAG_W_USED-1:0] rt2;
        rt2 = m_rsp.tag[TAG_W_USED-1:0];
        if (32'(rt2) < 32'(MAX_TAG)) begin
          logic [PORT_W-1:0] owner2;
          owner2 = tag_owner_q[rt2];
          if (32'(owner2) < 32'(N_PORTS)) begin
            s_rsp_q[owner2]      <= m_rsp;
            s_rsp_valid_q[owner2]<= 1'b1;
          end
        end
      end
    end
  end

  // Accept downstream response as long as no producer response is still pending
  // (single-outstanding per port keeps the tag routing simple; the fabric-side
  // arbiter has a deeper table if needed).
  assign m_rsp_ready = ~(|s_rsp_valid_q);

  for (genvar p = 0; p < N_PORTS; p++) begin : g_rsp_out
    assign s_rsp_valid[p] = s_rsp_valid_q[p];
    assign s_rsp[p]       = s_rsp_q[p];
  end

  // ---- observation ----
  assign obs_inflight        = inflight_q;
  assign obs_max_inflight    = 8'(MAX_TAG);
  assign obs_outstanding_tag = 8'(next_tag_q);

endmodule : mem_arbiter

`default_nettype wire
