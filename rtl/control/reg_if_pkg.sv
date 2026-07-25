// -----------------------------------------------------------------------------
// reg_if_pkg — the portable 32-bit register interface (SPEC.md 9, issue #7).
//
// SPEC 9 fixes the signal list and nothing else:
//
//     address  write_data  read_data  write_enable  read_enable
//     byte_enable  ready  error
//
// This package is the normative definition of what those signals mean. It is
// vendor neutral by construction: no APB state names, no Avalon waitrequest
// semantics, no AXI channel ordering. An APB or Avalon-MM adapter is a separate
// module that speaks this protocol on its back side (SPEC 9: "An APB or
// Avalon-MM wrapper may be added, but the internal register fabric must remain
// vendor-neutral"); the fabric itself never learns which one is attached.
//
// Protocol
// --------
// One outstanding transaction, request/response, all in the cfg_clk domain.
//
//   1. A request exists in any cycle where `write_enable | read_enable`. Both
//      high at once is malformed (see below), never a read-modify-write.
//   2. The master holds address, write_data, byte_enable and the enables stable
//      from the request cycle until it observes `ready`. The register-interface
//      checker (sim/assertions/reg_if_checker.sv) enforces this on the master,
//      so a harness bug is reported as a harness bug.
//   3. The slave asserts `ready` for exactly one cycle per accepted request.
//      `read_data` and `error` are valid in that cycle and only in that cycle.
//   4. The master drops the request in the cycle after `ready`. A back-to-back
//      pair therefore costs one idle cycle; nothing in the fabric requires it,
//      and a master that holds the request high simply issues it again.
//   5. Latency is bounded and small: every access through reg_fabric completes
//      in REG_ACCESS_LATENCY cycles. A block that fails to respond is completed
//      by the fabric's watchdog after REG_WATCHDOG_CYCLES with error=1, so the
//      interface can never hang, whatever a block does.
//
// Malformed requests. Each of the following completes normally with
// `ready=1, error=1` and has no side effect whatsoever:
//
//     write_enable && read_enable        ambiguous request
//     address[1:0] != 0                  unaligned; registers are word aligned
//     write_enable && byte_enable == 0   a write that writes nothing
//     address outside every window       unmapped
//     address inside a window, past the  unmapped within a mapped block
//       block's last register
//     write to a register with no        read-only register
//       writable bits
//
// Answering rather than stalling is the deliberate choice: a bus that hangs on a
// bad address turns a one-line software bug into a dead device and an unusable
// simulation. Every error path here still produces exactly one `ready`.
//
// Byte enables. On a write, `byte_enable[i]` gates byte i into the register's
// writable bits. On a read, byte enables are ignored and the full 32-bit word is
// returned: partial reads have no meaning for a register file whose reads are
// side-effect free, and honouring them would only invent a way to get zeros.
//
// Structs versus an interface. The request and response are packed structs, not
// a SystemVerilog `interface`. Packed structs cross a module port as a plain
// vector, which keeps the fabric usable from Quartus, from Verilator and from a
// C++ harness that binds to top-level ports, and keeps every field individually
// visible in a waveform without --trace-structs. `interface` buys modports and
// costs portability; this design needs no modports.
// -----------------------------------------------------------------------------

`default_nettype none

package reg_if_pkg;

  // ---- widths ------------------------------------------------------------
  // The address is a BYTE address, so software's pointer arithmetic and the
  // register map agree without a shift anywhere. 16 bits covers the SPEC 9
  // plane with room for every planned block (see control/regmap.json).
  localparam int unsigned REG_ADDR_W = 16;
  localparam int unsigned REG_DATA_W = 32;
  localparam int unsigned REG_STRB_W = REG_DATA_W / 8;

  // ---- response timing ---------------------------------------------------
  // Cycles from the request cycle to the ready cycle, inclusive of neither: a
  // request presented in cycle N is answered in cycle N+1. One cycle of decode
  // and one register stage inside the addressed block; nothing is combinational
  // from `address` to `read_data`, so the plane never lands on a timing path it
  // has to be rescued from later.
  localparam int unsigned REG_ACCESS_LATENCY = 1;

  // Cycles the fabric waits for a block's `ready` before completing the
  // transaction itself with error=1. Sized well above REG_ACCESS_LATENCY so it
  // never fires for a correct block, and small enough that a broken one shows
  // up as an error response rather than as a simulation timeout.
  localparam int unsigned REG_WATCHDOG_CYCLES = 15;

  // ---- transaction types -------------------------------------------------
  typedef logic [REG_ADDR_W-1:0] reg_addr_t;
  typedef logic [REG_DATA_W-1:0] reg_data_t;
  typedef logic [REG_STRB_W-1:0] reg_strb_t;

  typedef struct packed {
    reg_addr_t address;
    reg_data_t write_data;
    reg_strb_t byte_enable;
    logic      write_enable;
    logic      read_enable;
  } reg_req_t;

  typedef struct packed {
    reg_data_t read_data;
    logic      ready;
    logic      error;
  } reg_rsp_t;

  // ---- helpers -----------------------------------------------------------

  // Byte enables expanded to a bit mask over the data word.
  function automatic reg_data_t reg_be_mask(input reg_strb_t byte_enable);
    reg_data_t m;
    for (int unsigned b = 0; b < REG_STRB_W; b++) begin
      for (int unsigned i = 0; i < 8; i++) begin
        m[b * 8 + i] = byte_enable[b];
      end
    end
    return m;
  endfunction

  // A request is present. Not "well formed" — see reg_req_malformed.
  function automatic logic reg_req_active(input logic write_enable,
                                          input logic read_enable);
    return write_enable || read_enable;
  endfunction

  // The map-independent half of the malformed test: everything a decoder can
  // judge without knowing which registers exist. Taking the four signals rather
  // than a reg_req_t keeps the caller free to hold them however it likes; the
  // struct types above are for a module that wants to carry a whole transaction
  // on one port (an APB or Avalon-MM adapter, a future pipelined fabric), not an
  // obligation on everything that touches the protocol.
  // `address_low` is address[1:0]: alignment is the only thing about the address
  // this test judges, and taking the two bits rather than the whole bus says so.
  function automatic logic reg_req_malformed(input logic [1:0] address_low,
                                             input reg_strb_t byte_enable,
                                             input logic write_enable,
                                             input logic read_enable);
    return (write_enable && read_enable)
        || (address_low != 2'b00)
        || (write_enable && !read_enable && (byte_enable == '0));
  endfunction

endpackage : reg_if_pkg

`default_nettype wire
