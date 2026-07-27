// -----------------------------------------------------------------------------
// mem_req_rsp_if -- abstract memory request/response interface (issue #19).
//
// SPEC 4.3 (benchmark_device_top seam) requires a vendor-neutral abstraction of
// the memory the design attaches to, so the RTL that consumes it is unchanged
// when issue #24 replaces the seam with an HBM2e AXI adapter. SPEC 5 (stream
// protocol) is the exact template: valid/ready on both request and response,
// deterministic latency between them, and no vendor-specific handshake.
//
// This file is the PACKAGE that defines the request and response types and the
// helpers a producer or consumer needs. The actual buses cross module ports as
// packed structs (rtl/memory/mem_arbiter.sv), for the same reason
// reg_if_pkg::reg_req_t crosses ports as a packed struct rather than an
// interface: a packed struct is a plain vector across a boundary, works
// unchanged in Quartus and Verilator, and every field is individually visible
// in a waveform. No modports, no SystemVerilog `interface`.
//
// FIELD SUMMARY
// -------------
// A REQUEST carries:
//   opcode   READ or WRITE (a 1-bit enum for the two ops we need; #24's HBM2e
//            adapter adds ATOMIC etc. by extending the enum)
//   addr     32-bit byte address (compact for the SPEC 11 sizes; the HBM2e
//            adapter widens to 40 for full_agmf039)
//   len      beat count for a burst (1..255). One beat = 512 bits of data.
//   tag      8-bit request tag. Responses are tagged and may arrive out of
//            order; the tag is the identity a producer's scoreboard matches on.
//   data     512 bits of write data (ignored on READ). Fixed width because a
//            packet-flit-wide store is what the design's traffic looks like.
//   strb     64 write byte enables (ignored on READ).
//   valid/ready  stream handshake as SPEC 5.
//
// A RESPONSE carries:
//   status   OK / RANGE / PROTOCOL / TIMEOUT (2-bit enum). Every response ends
//            the request, whether or not it succeeded, so the producer can never
//            wait for one that already came back with an error.
//   tag      the tag of the request being answered.
//   data     512 bits of read data (ignored on WRITE).
//   valid/ready  stream handshake as SPEC 5.
//
// LATENCY DISCIPLINE
// ------------------
// The behavioural model rtl/memory/behavioral_mem_model.sv applies a
// DETERMINISTIC latency between an accepted request and its response, set by
// DBG_MEM_CTRL.LATENCY at 0x8028. That is what makes the same seed reproduce
// the same event ordering under Verilator regardless of build mode; an HBM2e IP
// with variable latency is the follow-up in issue #24, and the abstract seam
// makes the change local.
// -----------------------------------------------------------------------------

`default_nettype none

// The package name intentionally differs from the file name: mem_req_rsp_if.sv
// says what the file CONTAINS (the request/response interface types), and
// `mem_pkg` is what consumers name the package.
/* verilator lint_off DECLFILENAME */
package mem_pkg;

  // ---- widths ----
  localparam int unsigned MEM_ADDR_W  = 32;
  localparam int unsigned MEM_DATA_W  = 512;
  localparam int unsigned MEM_STRB_W  = MEM_DATA_W / 8;
  localparam int unsigned MEM_TAG_W   = 8;
  localparam int unsigned MEM_LEN_W   = 8;

  // ---- opcodes (extensible; #24 adds atomic ops) ----
  typedef enum logic {
    MEM_OP_READ  = 1'b0,
    MEM_OP_WRITE = 1'b1
  } mem_op_e;

  // ---- response status ----
  typedef enum logic [1:0] {
    MEM_RSP_OK       = 2'b00,
    MEM_RSP_RANGE    = 2'b01,
    MEM_RSP_PROTOCOL = 2'b10,
    MEM_RSP_TIMEOUT  = 2'b11
  } mem_status_e;

  // ---- request ----
  typedef struct packed {
    logic                     op;       // mem_op_e
    logic [MEM_ADDR_W-1:0]    addr;
    logic [MEM_LEN_W-1:0]     len;      // beats, 1..255
    logic [MEM_TAG_W-1:0]     tag;
    logic [MEM_DATA_W-1:0]    data;
    logic [MEM_STRB_W-1:0]    strb;
  } mem_req_t;

  // ---- response ----
  typedef struct packed {
    logic [1:0]               status;   // mem_status_e
    logic [MEM_TAG_W-1:0]     tag;
    logic [MEM_DATA_W-1:0]    data;
  } mem_rsp_t;

  // ---- helpers ----
  function automatic mem_req_t mem_read(input logic [MEM_ADDR_W-1:0] addr,
                                        input logic [MEM_LEN_W-1:0]  len,
                                        input logic [MEM_TAG_W-1:0]  tag);
    mem_req_t r;
    r = '0;
    r.op   = MEM_OP_READ;
    r.addr = addr;
    r.len  = len;
    r.tag  = tag;
    return r;
  endfunction

  function automatic mem_req_t mem_write(input logic [MEM_ADDR_W-1:0] addr,
                                         input logic [MEM_DATA_W-1:0] data,
                                         input logic [MEM_STRB_W-1:0] strb,
                                         input logic [MEM_TAG_W-1:0]  tag);
    mem_req_t r;
    r = '0;
    r.op   = MEM_OP_WRITE;
    r.addr = addr;
    r.len  = 8'd1;
    r.tag  = tag;
    r.data = data;
    r.strb = strb;
    return r;
  endfunction

  // Elaboration predicate for the seam: the abstract interface widths must be
  // compatible with any HBM2e AXI adapter #24 might attach. 512-bit data is the
  // native HBM2e burst; a 32-bit request address covers up to 4 GiB and every
  // SPEC 11 memory sizing.
  function automatic logic mem_widths_ok(input int unsigned addr_w,
                                         input int unsigned data_w,
                                         input int unsigned tag_w);
    return (addr_w >= 20) && (addr_w <= 40)
        && (data_w == 512)
        && (tag_w >= 4) && (tag_w <= 12);
  endfunction

endpackage : mem_pkg
/* verilator lint_on DECLFILENAME */

`default_nettype wire
