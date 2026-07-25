// -----------------------------------------------------------------------------
// reg_csr_block — the generic control/status register engine (SPEC.md 9, #7).
//
// One hand-written implementation of every access type in the register map,
// parameterised by the per-bit tables that scripts/gen_regmap.py emits into
// rtl/control/generated/regmap_pkg.sv. Every block in rtl/control/ is this
// module plus a thin wrapper that supplies its table slice and wires its
// hardware-driven fields.
//
// Why one engine rather than a hand-written decode per block
// ---------------------------------------------------------
// The access-type semantics — byte-enable masking, write-1-to-clear against a
// simultaneous hardware set, write-1-pulse, hardware-driven read data, refusing
// a write to a read-only register — are one piece of logic that is easy to get
// subtly wrong and hard to notice. Written once, it is tested once and correct
// everywhere. Written per block, the fifth block silently gets W1C backwards.
//
// Why the tables are generated and the logic is not
// ------------------------------------------------
// The tables are data with no rationale to lose: five 32-bit masks per register,
// mechanically derived from the source of truth, and drift between them and the
// documentation is exactly what a generator prevents. The logic below is the
// opposite: it needs to be read, reviewed and argued about, which nobody does to
// a generated always_ff. So the generator emits localparams and stops there.
//
// Per-bit semantics, from the masks (a bit appears in at most one mask)
// --------------------------------------------------------------------
//   WMASK      plain read-write storage. A write with the byte enable set
//              replaces the bit.
//   W1C_MASK   sticky. Hardware sets it through `hw_set`; software clears it by
//              writing 1. Writing 0 does nothing. A hardware set in the same
//              cycle as a software clear WINS: the event happened, and losing it
//              to a racing clear would make the status register lie.
//   PULSE_MASK write-1-pulse. A written 1 appears on `pulse` for exactly one
//              cycle and the storage bit is held at 0, so the register always
//              reads back 0 and a pulse can never be left latched.
//   HW_MASK    read-only from hardware. Read data for the bit comes from
//              `hw_value`, not from storage.
//   in none of them: constant. The reset value is the value.
//
// A register whose masks are all clear in WMASK|W1C_MASK|PULSE_MASK is not
// writable at all, and a write to it answers with error=1 and changes nothing.
// A register with only some writable bits accepts the write and ignores the
// rest — the ordinary hardware convention, and the one SCRATCH3 tests.
//
// Timing and protocol
// -------------------
// The fabric presents `sel` for exactly one cycle per transaction, already
// qualified: alignment, window decode and read/write exclusivity are settled
// before this module sees anything. `index` is the register's word index inside
// the block window. The response — `ready`, `error`, `read_data` — is registered
// and appears in the following cycle. Nothing here is combinational from the
// request to the response, so the register plane contributes no long path.
//
// Reset (SPEC 23): every storage bit resets, because all of it is control state
// by definition — that is what a register file is. This is the one place in the
// design where a full reset is right.
// -----------------------------------------------------------------------------

`default_nettype none

module reg_csr_block
  import reg_if_pkg::*;
#(
    // Registers in this block, and the width of the word index the fabric
    // supplies. Both come from regmap_pkg at the instantiation site.
    parameter int unsigned N_REGS = 1,
    parameter int unsigned IDX_W  = 10,

    // Per-register tables, flat: entry i at [i*32 +: 32]. Generated.
    parameter logic [N_REGS*32-1:0] RESET_VAL  = '0,
    parameter logic [N_REGS*32-1:0] WMASK      = '0,
    parameter logic [N_REGS*32-1:0] W1C_MASK   = '0,
    parameter logic [N_REGS*32-1:0] PULSE_MASK = '0,
    parameter logic [N_REGS*32-1:0] HW_MASK    = '0
) (
    input  wire                    clk,
    input  wire                    rst_n,

    // Request, from reg_fabric. One cycle, already qualified.
    input  wire                    sel,
    input  wire                    write_enable,
    input  wire                    read_enable,
    input  wire [IDX_W-1:0]        index,
    input  wire [REG_DATA_W-1:0]   write_data,
    input  wire [REG_STRB_W-1:0]   byte_enable,

    // Response, registered, one cycle after the request.
    output wire [REG_DATA_W-1:0]   read_data,
    output wire                    ready,
    output wire                    error,

    // Hardware side. `hw_value` supplies read data for HW_MASK bits;
    // `hw_set` sets W1C_MASK bits. Both are flat, entry i at [i*32 +: 32].
    input  wire [N_REGS*32-1:0]    hw_value,
    input  wire [N_REGS*32-1:0]    hw_set,

    // Live register-file contents and the one-cycle pulses, for the consumers
    // the block drives. Flat, same indexing.
    output wire [N_REGS*32-1:0]    csr,
    output wire [N_REGS*32-1:0]    pulse
);

  // ---------------------------------------------------------------------------
  // Request qualification
  // ---------------------------------------------------------------------------
  wire req = sel && (write_enable || read_enable);

  // Word index inside the block, and whether it names a register that exists.
  // A window is larger than the registers in it (uniform 4 KiB windows keep the
  // fabric decode an address-bit compare), so "inside the window but past the
  // last register" is a real and reachable case, and it is an error.
  wire        in_range = (32'(index) < N_REGS);
  wire [31:0] be_mask  = reg_be_mask(byte_enable);

  // Whether the addressed register has any writable bit at all.
  logic writable_sel;
  always_comb begin
    writable_sel = 1'b0;
    for (int unsigned i = 0; i < N_REGS; i++) begin
      if (32'(index) == i) begin
        writable_sel = |(WMASK[i*32 +: 32] | W1C_MASK[i*32 +: 32] | PULSE_MASK[i*32 +: 32]);
      end
    end
  end

  // ---------------------------------------------------------------------------
  // Per-register storage
  //
  // The state lives inside the generate block so that each register is driven by
  // exactly one procedural block. An array declared outside and written from N
  // generate instances is the same logic and a multiple-driver warning.
  // ---------------------------------------------------------------------------
  wire [N_REGS*32-1:0] rd_sel_bus;

  for (genvar r = 0; r < N_REGS; r++) begin : g_reg
    localparam logic [31:0] RST_R   = RESET_VAL [r*32 +: 32];
    localparam logic [31:0] W_R     = WMASK     [r*32 +: 32];
    localparam logic [31:0] W1C_R   = W1C_MASK  [r*32 +: 32];
    localparam logic [31:0] PLS_R   = PULSE_MASK[r*32 +: 32];
    localparam logic [31:0] HW_R    = HW_MASK   [r*32 +: 32];
    localparam logic        WRITE_R = |(W_R | W1C_R | PLS_R);

    wire hit  = req && in_range && (32'(index) == 32'(r));
    wire wr   = hit && write_enable && WRITE_R;

    logic [31:0] q, q_d, pulse_q, pulse_d;

    always_comb begin
      q_d     = q;
      pulse_d = 32'd0;
      for (int unsigned i = 0; i < 32; i++) begin
        if (wr && be_mask[i]) begin
          if (W_R[i]) begin
            q_d[i] = write_data[i];
          end else if (W1C_R[i] && write_data[i]) begin
            q_d[i] = 1'b0;
          end
          pulse_d[i] = PLS_R[i] && write_data[i];
        end
        // Hardware set beats a software clear in the same cycle.
        if (W1C_R[i] && hw_set[r*32 + i]) begin
          q_d[i] = 1'b1;
        end
        // A pulse bit never stores: it reads 0 always.
        if (PLS_R[i]) begin
          q_d[i] = 1'b0;
        end
      end
    end

    always_ff @(posedge clk) begin
      if (!rst_n) begin
        q       <= RST_R;
        pulse_q <= 32'd0;
      end else begin
        q       <= q_d;
        pulse_q <= pulse_d;
      end
    end

    // Read value: hardware bits from `hw_value`, everything else from storage.
    wire [31:0] rd_value = (q & ~HW_R) | (hw_value[r*32 +: 32] & HW_R);

    // Read mux contribution. Qualified by the index alone so this is a plain
    // mux; the request qualification happens once, at the output register.
    assign rd_sel_bus[r*32 +: 32] = (32'(index) == 32'(r)) ? rd_value : 32'd0;

    assign csr  [r*32 +: 32] = q;
    assign pulse[r*32 +: 32] = pulse_q;
  end

  // ---------------------------------------------------------------------------
  // Read mux and registered response
  // ---------------------------------------------------------------------------
  logic [31:0] rd_mux;
  always_comb begin
    rd_mux = 32'd0;
    for (int unsigned i = 0; i < N_REGS; i++) begin
      rd_mux = rd_mux | rd_sel_bus[i*32 +: 32];
    end
  end

  logic [31:0] rdata_q;
  logic        ready_q;
  logic        error_q;

  always_ff @(posedge clk) begin
    if (!rst_n) begin
      rdata_q <= 32'd0;
      ready_q <= 1'b0;
      error_q <= 1'b0;
    end else begin
      ready_q <= req;
      error_q <= req && (!in_range || (write_enable && !writable_sel));
      // Reads of an absent register return zero alongside error=1, so a stale
      // word from a previous access can never be mistaken for data.
      rdata_q <= (req && read_enable && in_range) ? rd_mux : 32'd0;
    end
  end

  assign read_data = rdata_q;
  assign ready     = ready_q;
  assign error     = error_q;

endmodule : reg_csr_block

`default_nettype wire
