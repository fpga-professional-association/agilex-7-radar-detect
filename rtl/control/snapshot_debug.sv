// -----------------------------------------------------------------------------
// snapshot_debug -- ring buffer for a captured stream beat (issue #19, SPEC 9).
//
// Given
//   * SNAP_CTRL.ARM + TRIGGER (arm/one-shot fire),
//   * SNAP_SOURCE.SOURCE_SEL (which observed interface to sample),
//   * SNAP_DEPTH.DEPTH (how many beats to capture),
// this module fills a BUF_DEPTH-entry ring with beats from the selected source
// and exposes it through DBG_SNAP_DATA / DATA_HI / DATA_META via a shared read
// index (DBG_SNAP_POINTER.INDEX).
//
// One-shot vs continuous is selected by SNAP_CTRL.ONE_SHOT: one-shot captures
// DEPTH beats after the trigger and stops (the ring becomes a linear buffer),
// continuous overwrites the oldest slot as new beats arrive.
//
// Source multiplex, in one paragraph: the caller (benchmark_sim_top) fans one
// beat + metadata per selectable source into `src_valid` / `src_data_lo/hi` /
// `src_meta` arrays. This module picks the one named by SOURCE_SEL and writes
// it into the ring. All sources are always in the same clock domain here
// (core_clk); a source in a different domain would be brought over by a
// stream_cdc in the pipeline top before it reaches this module.
//
// Reset (SPEC 23): control state resets (pointer, arm state); the ring content
// does not, exactly as SRAM contents do not reset.
// -----------------------------------------------------------------------------

`default_nettype none

module snapshot_debug
  import regmap_pkg::*;
#(
    // Ring-buffer depth. 128 is the elaborated default; small enough to fit in
    // one M20K, large enough to hold a whole medium-config CFAR frame (~110
    // beats). Configurable so a tiny build fits in registers.
    parameter int unsigned BUF_DEPTH = 128,
    // Number of selectable sources. 8 covers the sources SOURCE_SEL enumerates.
    parameter int unsigned N_SOURCES = 8
) (
    input  wire                                     clk,
    input  wire                                     rst_n,

    // ---- SNAP_CTRL storage bits (from fault_injection's CSR file) ----
    input  wire                                     snap_arm,
    input  wire                                     snap_trigger,      // 1-cyc pulse
    input  wire                                     snap_status_clear, // 1-cyc pulse
    input  wire                                     snap_one_shot,

    // ---- SNAP_SOURCE.SOURCE_SEL ----
    input  wire [3:0]                               source_sel,

    // ---- SNAP_DEPTH.DEPTH (register value; hardware clamps to [1, BUF_DEPTH]) ----
    input  wire [11:0]                              depth_req,

    // ---- SNAP_POINTER.INDEX / AUTO_INC ----
    input  wire [11:0]                              rd_index,
    input  wire                                     rd_auto_inc,
    // Fires on an accepted read of DBG_SNAP_DATA.
    input  wire                                     rd_pulse,

    // ---- source beats (one per source, mux by SOURCE_SEL) ----
    input  wire [N_SOURCES-1:0]                     src_valid,
    input  wire [N_SOURCES*64-1:0]                  src_data,     // low 64 bits of the beat
    input  wire [N_SOURCES*32-1:0]                  src_meta,     // SEQ(16) | ID(4) | SOF | EOF | VALID | FAULT
    input  wire                                     any_fault,     // for correlating FAULT flag

    // ---- read outputs to fault_injection ----
    output wire [31:0]                              snap_hw_status,   // {WR_PTR[11:0] << 16, SOURCE_INVALID, OVERRUN, DONE, CAPTURING}
    output wire [31:0]                              snap_hw_data_lo,
    output wire [31:0]                              snap_hw_data_hi,
    output wire [31:0]                              snap_hw_data_meta,
    output wire [7:0]                               snap_hw_n_sources,
    output wire [11:0]                              snap_hw_buf_depth
);

  // ---------------------------------------------------------------------------
  // Ring memory. Storage is behavioural (an array of registers); a real build
  // would map this to an M20K, but at BUF_DEPTH=128 the register array is
  // small enough to synthesise trivially. We keep the width to 128 bits (64 lo +
  // 32 hi + 32 meta = 128) for a bit-exact match against the register readback.
  // ---------------------------------------------------------------------------
  localparam int unsigned PTR_W = (BUF_DEPTH <= 1) ? 1 : $clog2(BUF_DEPTH);
  logic [63:0] ring_data_q [BUF_DEPTH];
  logic [31:0] ring_meta_q [BUF_DEPTH];

  // Clamp the request to [1, BUF_DEPTH].
  wire [11:0] depth_active =
      (depth_req == 12'd0)                   ? 12'd1
    : (depth_req > 12'(BUF_DEPTH))           ? 12'(BUF_DEPTH)
                                             : depth_req;

  // Clamp the read index to [0, BUF_DEPTH-1].
  wire [11:0] rd_index_c =
      (rd_index >= 12'(BUF_DEPTH)) ? 12'(BUF_DEPTH-1) : rd_index;

  // Clamp the source selection.
  wire        source_invalid = (32'(source_sel) >= 32'(N_SOURCES));
  wire [3:0]  source_sel_c   = source_invalid ? 4'd0 : source_sel;

  // Fan the selected source's beat into a single-cycle capture.
  logic sel_valid;
  logic [63:0] sel_data;
  logic [31:0] sel_meta;
  always_comb begin
    sel_valid = 1'b0;
    sel_data  = 64'd0;
    sel_meta  = 32'd0;
    for (int unsigned s = 0; s < N_SOURCES; s++) begin
      if (32'(source_sel_c) == s) begin
        sel_valid = src_valid[s];
        sel_data  = src_data[s*64 +: 64];
        sel_meta  = src_meta[s*32 +: 32];
      end
    end
  end

  // ---- FSM: IDLE -> ARMED -> CAPTURING (-> DONE or continuous) ----
  typedef enum logic [1:0] {
      S_IDLE      = 2'b00,
      S_ARMED     = 2'b01,
      S_CAPTURING = 2'b10,
      S_DONE      = 2'b11
  } snap_state_e;

  snap_state_e state_q;
  logic [11:0] wr_ptr_q;
  logic [11:0] fill_count_q;   // beats captured in this run
  logic        overrun_q;
  logic        source_inv_q;
  logic        done_q;         // sticky, cleared by status_clear

  // Read pointer for the readback path. Updated by the CSR's INDEX writes; here
  // we auto-advance on a rd_pulse when AUTO_INC is set.
  logic [11:0] rd_ptr_q;
  always_ff @(posedge clk) begin
    if (!rst_n) begin
      rd_ptr_q <= 12'd0;
    end else begin
      // Follow the CSR-written INDEX unless auto-inc is on and a read fired.
      if (rd_pulse && rd_auto_inc) begin
        rd_ptr_q <= (rd_ptr_q + 12'd1 >= 12'(BUF_DEPTH)) ? 12'd0 : (rd_ptr_q + 12'd1);
      end else begin
        rd_ptr_q <= rd_index_c;
      end
    end
  end

  always_ff @(posedge clk) begin
    if (!rst_n) begin
      state_q       <= S_IDLE;
      wr_ptr_q      <= 12'd0;
      fill_count_q  <= 12'd0;
      overrun_q     <= 1'b0;
      source_inv_q  <= 1'b0;
      done_q        <= 1'b0;
    end else begin
      // Status clear pulse
      if (snap_status_clear) begin
        overrun_q    <= 1'b0;
        source_inv_q <= 1'b0;
        done_q       <= 1'b0;
        wr_ptr_q     <= 12'd0;
      end

      unique case (state_q)
        S_IDLE: begin
          if (snap_arm) state_q <= S_ARMED;
        end
        S_ARMED: begin
          if (!snap_arm) begin
            state_q <= S_IDLE;
          end else if (snap_trigger) begin
            wr_ptr_q     <= 12'd0;
            fill_count_q <= 12'd0;
            source_inv_q <= source_invalid;
            state_q      <= S_CAPTURING;
          end
        end
        S_CAPTURING: begin
          // Refuse a fresh trigger during capture
          if (snap_trigger) overrun_q <= 1'b1;

          if (sel_valid) begin
            ring_data_q[wr_ptr_q[PTR_W-1:0]] <= sel_data;
            // FAULT flag OR'd in when the design is currently pulsing a fault
            ring_meta_q[wr_ptr_q[PTR_W-1:0]] <= {sel_meta[31:28], sel_meta[27] | any_fault, sel_meta[26:0]};
            wr_ptr_q <= (wr_ptr_q + 12'd1 >= 12'(BUF_DEPTH)) ? 12'd0 : (wr_ptr_q + 12'd1);
            if (fill_count_q < depth_active) begin
              fill_count_q <= fill_count_q + 12'd1;
              if (fill_count_q + 12'd1 == depth_active) begin
                // Filled to depth
                if (snap_one_shot) begin
                  state_q <= S_DONE;
                  done_q  <= 1'b1;
                end
              end
            end
          end

          // Clearing ARM stops the capture immediately.
          if (!snap_arm) begin
            state_q <= S_IDLE;
            done_q  <= 1'b1;
          end
        end
        S_DONE: begin
          if (snap_status_clear) state_q <= snap_arm ? S_ARMED : S_IDLE;
          if (snap_trigger)      overrun_q <= 1'b1;
        end
        default: state_q <= S_IDLE;
      endcase
    end
  end

  // ---------------------------------------------------------------------------
  // Read-out
  // ---------------------------------------------------------------------------
  wire        capturing = (state_q == S_CAPTURING);

  assign snap_hw_status = {4'd0, wr_ptr_q,
                           12'd0,
                           source_inv_q,
                           overrun_q,
                           done_q,
                           capturing};

  assign snap_hw_data_lo    = ring_data_q[rd_ptr_q[PTR_W-1:0]][31:0];
  assign snap_hw_data_hi    = ring_data_q[rd_ptr_q[PTR_W-1:0]][63:32];
  assign snap_hw_data_meta  = ring_meta_q[rd_ptr_q[PTR_W-1:0]];
  assign snap_hw_n_sources  = 8'(N_SOURCES);
  assign snap_hw_buf_depth  = 12'(BUF_DEPTH);

endmodule : snapshot_debug

`default_nettype wire
