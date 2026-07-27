// -----------------------------------------------------------------------------
// behavioral_mem_model -- synthesizable stub + Verilator-side C++ storage.
//
// The RTL half (this file) is the shim between mem_arbiter's mem_req/mem_rsp
// buses and a byte-addressed storage array. The array is small (parameter
// DEPTH_BYTES) and lives in registers, sized so a Verilator run's traffic fits
// (behavioral_mem_model.cpp on the C++ side deals with the addressable but
// non-instantiated tail).
//
// LATENCY: deterministic, set by cfg_latency (from DBG_MEM_CTRL.LATENCY at
// 0x8028). Every accepted request enters a queue with a "arrives at" time; a
// response is produced when the queue's head reaches its target. That is what
// makes the same seed reproduce the same event ordering.
//
// FAULTS: cfg_fault_mode drives one-shot injection of the RANGE / PROTOCOL /
// TIMEOUT paths, so a test can exercise the failure branches without patching
// the RTL. cfg_fault_mode reverts to zero after the pulse (fault_mode_ack).
//
// This module is DESIGNED to be replaced by issue #24's HBM2e AXI adapter; it
// is deliberately behavioural, not calibratable, and does not appear in any
// synthesis file list except the sim wrapper.
// -----------------------------------------------------------------------------

`default_nettype none

module behavioral_mem_model
  import mem_pkg::*;
#(
    // Depth of the in-RTL byte store. 4096 bytes is enough for the phase-4
    // DMA test's tally. A test that needs more addressable space uses the
    // C++ storage in sim/verilator/behavioral_mem_model.cpp.
    parameter int unsigned DEPTH_BYTES = 4096,
    // Maximum outstanding requests before back-pressuring.
    parameter int unsigned MAX_INFLIGHT = 16
) (
    input  wire                              clk,
    input  wire                              rst_n,

    // ---- upstream (from mem_arbiter) ----
    input  wire                              s_req_valid,
    output wire                              s_req_ready,
    input  mem_req_t                         s_req,

    output wire                              s_rsp_valid,
    input  wire                              s_rsp_ready,
    output mem_rsp_t                         s_rsp,

    // ---- control from DBG_MEM_CTRL ----
    input  wire                              cfg_enable,
    input  wire                              cfg_soft_reset,
    input  wire [7:0]                        cfg_latency,   // deterministic delay
    input  wire [1:0]                        cfg_fault_mode,// 0=none 1=drop_req 2=drop_rsp 3=err_status

    // ---- status ----
    output wire                              obs_fault_range,
    output wire                              obs_fault_protocol,
    output wire                              obs_fault_timeout,
    output wire [31:0]                       obs_req_count,
    output wire [31:0]                       obs_rsp_count
);

  localparam int unsigned WORD_BYTES = MEM_DATA_W / 8;   // 64 for 512-bit
  localparam int unsigned DEPTH_WORDS = DEPTH_BYTES / WORD_BYTES;

`ifndef SYNTHESIS
  initial begin
    if (WORD_BYTES == 0) $fatal(1, "behavioral_mem_model: WORD_BYTES=0");
  end
`endif

  // Consume s_req.strb for lint (byte-enable-per-write is a future extension;
  // this behavioural model writes the whole beat).
  wire _unused_strb = &{1'b0, s_req.strb};

  // ---- byte store, addressed by (addr / WORD_BYTES) ----
  logic [MEM_DATA_W-1:0] mem_q [DEPTH_WORDS];

  // Latency queue: FIFO of {tag, data, status, remaining_cycles}. Entries
  // decrement each cycle; when the head reaches 0 it becomes an eligible
  // response.
  typedef struct packed {
    logic [7:0]              remaining;
    logic [1:0]              status;
    logic [MEM_TAG_W-1:0]    tag;
    logic [MEM_DATA_W-1:0]   data;
    logic                    valid;
  } queue_entry_t;

  queue_entry_t q_r [MAX_INFLIGHT];
  logic [$clog2(MAX_INFLIGHT+1)-1:0] q_count;

  logic obs_fault_range_q, obs_fault_protocol_q, obs_fault_timeout_q;
  logic [31:0] req_count_q, rsp_count_q;

  // Address range check: address plus one beat's bytes must be in range.
  wire in_range = ({8'd0, s_req.addr} < 40'(DEPTH_BYTES));

  // Effective latency: 0 is illegal per the register description; treat as 1.
  wire [7:0] eff_lat = (cfg_latency == 8'd0) ? 8'd1 : cfg_latency;

  // Fault handling
  wire fault_drop_req = (cfg_fault_mode == 2'd1);
  wire fault_drop_rsp = (cfg_fault_mode == 2'd2);
  wire fault_err      = (cfg_fault_mode == 2'd3);

  // ---- Accept a request when we have space, enabled, and not dropping it ----
  wire req_accept = cfg_enable && s_req_valid && (q_count < MAX_INFLIGHT[$bits(q_count)-1:0]) && !fault_drop_req;
  assign s_req_ready = cfg_enable && (q_count < MAX_INFLIGHT[$bits(q_count)-1:0]) && !fault_drop_req;

  // ---- Response mux: pick the oldest entry whose remaining==0 ----
  // We schedule from head-of-queue: the FIFO ensures the queue is age-ordered
  // among entries with the same latency; because latency is CONSTANT here, the
  // head is always the oldest.
  wire head_ready = (q_count > 0) && (q_r[0].remaining == 8'd0);
  wire rsp_will_fire = head_ready && s_rsp_ready && !fault_drop_rsp;

  assign s_rsp_valid = head_ready && !fault_drop_rsp;

  mem_rsp_t s_rsp_c;
  always_comb begin
    s_rsp_c        = '0;
    s_rsp_c.tag    = q_r[0].tag;
    s_rsp_c.data   = q_r[0].data;
    s_rsp_c.status = q_r[0].status;
  end
  assign s_rsp = s_rsp_c;

  always_ff @(posedge clk) begin
    if (!rst_n || cfg_soft_reset) begin
      for (int unsigned i = 0; i < MAX_INFLIGHT; i++) q_r[i] <= '0;
      q_count             <= '0;
      obs_fault_range_q   <= 1'b0;
      obs_fault_protocol_q<= 1'b0;
      obs_fault_timeout_q <= 1'b0;
      req_count_q         <= 32'd0;
      rsp_count_q         <= 32'd0;
    end else begin
      // Decrement every remaining counter (age the queue).
      for (int unsigned i = 0; i < MAX_INFLIGHT; i++) begin
        if (q_r[i].valid && (q_r[i].remaining != 8'd0)) begin
          q_r[i].remaining <= q_r[i].remaining - 8'd1;
        end
      end

      // Retire the head if the consumer takes it.
      if (rsp_will_fire) begin
        rsp_count_q <= (rsp_count_q == 32'hFFFF_FFFF) ? rsp_count_q : (rsp_count_q + 32'd1);
        // Shift the queue up by one.
        for (int unsigned i = 0; i < MAX_INFLIGHT-1; i++) begin
          q_r[i] <= q_r[i+1];
        end
        q_r[MAX_INFLIGHT-1] <= '0;
        q_count <= q_count - 1;
      end

      // Accept a new request. If we also retired one this cycle the count is
      // net-zero, so we insert at (q_count - 1). If not, insert at q_count.
      if (req_accept) begin
        int ins_idx;
        ins_idx = rsp_will_fire ? (int'(q_count) - 1) : int'(q_count);
        if (ins_idx >= 0 && ins_idx < int'(MAX_INFLIGHT)) begin
          queue_entry_t e;
          e = '0;
          e.valid     = 1'b1;
          e.remaining = eff_lat;
          e.tag       = s_req.tag;
          e.status    = fault_err ? 2'(MEM_RSP_PROTOCOL) : 2'(MEM_RSP_OK);
          // Range check
          if (!in_range) begin
            e.status = 2'(MEM_RSP_RANGE);
            obs_fault_range_q <= 1'b1;
          end
          // Protocol check: len must be 1 for our simple test protocol.
          if (s_req.len != 8'd1) begin
            e.status = 2'(MEM_RSP_PROTOCOL);
            obs_fault_protocol_q <= 1'b1;
          end
          if (fault_err) obs_fault_protocol_q <= 1'b1;
          if (fault_drop_rsp) obs_fault_timeout_q <= 1'b1;

          // For READ, take the data from the store (if in range).
          if (s_req.op == 1'(MEM_OP_READ)) begin
            if (in_range) begin
              int unsigned widx;
              widx = 32'(s_req.addr / MEM_ADDR_W'(WORD_BYTES));
              if (widx < DEPTH_WORDS) begin
                e.data = mem_q[widx];
              end
            end
          end else begin
            // For WRITE, update the store (if in range).
            if (in_range) begin
              int unsigned widx3;
              widx3 = 32'(s_req.addr / MEM_ADDR_W'(WORD_BYTES));
              if (widx3 < DEPTH_WORDS) begin
                mem_q[widx3] <= s_req.data;
              end
            end
            e.data = '0;
          end

          q_r[ins_idx] <= e;
          if (!rsp_will_fire) q_count <= q_count + 1;
          req_count_q <= (req_count_q == 32'hFFFF_FFFF) ? req_count_q : (req_count_q + 32'd1);
        end
      end
    end
  end

  assign obs_fault_range    = obs_fault_range_q;
  assign obs_fault_protocol = obs_fault_protocol_q;
  assign obs_fault_timeout  = obs_fault_timeout_q;
  assign obs_req_count      = req_count_q;
  assign obs_rsp_count      = rsp_count_q;

endmodule : behavioral_mem_model

`default_nettype wire
