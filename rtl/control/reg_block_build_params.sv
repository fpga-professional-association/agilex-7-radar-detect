// -----------------------------------------------------------------------------
// reg_block_build_params — elaboration parameters, read only (SPEC.md 9, #7).
//
// Window 0x1000. Every register is ROHW: the read data comes from config_pkg,
// which scripts/build_verilator.py generates from config/<name>.json (SPEC 11),
// so this block reports what was actually elaborated rather than what a header
// or a document claims. That distinction is the whole reason SPEC 9 asks for a
// build-parameter group.
//
// Wiring is by generated index localparam (REGMAP_BUILD_PARAMS_<name>_INDEX),
// never by a hard-coded position. Reordering the registers in
// control/regmap.json therefore cannot silently transpose two parameters here:
// the names move with the values.
//
// PARAM_CHECKSUM is FNV-1a 32 over the eleven parameter words in offset order.
// The C++ harness computes the same hash from config_sim.h and compares. A
// mismatch means the RTL and the harness were built from different
// configurations — a failure that otherwise shows up much later as an
// inexplicable functional difference, if it shows up at all.
// -----------------------------------------------------------------------------

`default_nettype none

module reg_block_build_params
  import reg_if_pkg::*;
  import regmap_pkg::*;
  import config_pkg::*;
#(
    parameter int unsigned IDX_W = REGMAP_WINDOW_W - 2
) (
    input  wire                                      clk,
    input  wire                                      rst_n,

    input  wire                                      sel,
    input  wire                                      write_enable,
    input  wire                                      read_enable,
    input  wire [IDX_W-1:0]                          index,
    input  wire [REG_DATA_W-1:0]                     write_data,
    input  wire [REG_STRB_W-1:0]                     byte_enable,

    output wire [REG_DATA_W-1:0]                     read_data,
    output wire                                      ready,
    output wire                                      error,

    output wire [REGMAP_BUILD_PARAMS_N_REGS*32-1:0]  csr,
    output wire [REGMAP_BUILD_PARAMS_N_REGS*32-1:0]  pulse,

    // The elaborated parameter checksum, also readable at PARAM_CHECKSUM.
    output wire [31:0]                               param_checksum
);

  localparam int unsigned N = REGMAP_BUILD_PARAMS_N_REGS;

  // ---- FNV-1a 32 over one 32-bit word, little-endian bytes ----------------
  // The offset basis and prime are the published FNV-1a constants. Written as a
  // function so the RTL and model/cpp read the same algorithm rather than two
  // descriptions of it.
  function automatic logic [31:0] fnv1a32_word(input logic [31:0] h_in,
                                               input logic [31:0] word);
    logic [31:0] h;
    h = h_in;
    for (int unsigned b = 0; b < 4; b++) begin
      h = h ^ {24'd0, word[b*8 +: 8]};
      h = h * 32'd16777619;
    end
    return h;
  endfunction

  // ---- hardware read values, wired by generated index --------------------
  logic [N*32-1:0] hw_value;
  logic [31:0]     checksum;

  always_comb begin
    hw_value = '0;
    hw_value[REGMAP_BUILD_PARAMS_N_ANTENNAS_INDEX        * 32 +: 32] = 32'(N_ANTENNAS);
    hw_value[REGMAP_BUILD_PARAMS_SAMPLES_PER_CYCLE_INDEX * 32 +: 32] = 32'(SAMPLES_PER_CYCLE);
    hw_value[REGMAP_BUILD_PARAMS_FFT_SIZE_INDEX          * 32 +: 32] = 32'(FFT_SIZE);
    hw_value[REGMAP_BUILD_PARAMS_PFB_TAPS_INDEX          * 32 +: 32] = 32'(PFB_TAPS);
    hw_value[REGMAP_BUILD_PARAMS_N_BEAMS_INDEX           * 32 +: 32] = 32'(N_BEAMS);
    hw_value[REGMAP_BUILD_PARAMS_HISTORY_FRAMES_INDEX    * 32 +: 32] = 32'(HISTORY_FRAMES);
    hw_value[REGMAP_BUILD_PARAMS_PACKET_W_INDEX          * 32 +: 32] = 32'(PACKET_W);
    hw_value[REGMAP_BUILD_PARAMS_SAMPLE_W_INDEX          * 32 +: 32] = 32'(SAMPLE_W);
    hw_value[REGMAP_BUILD_PARAMS_COEFF_W_INDEX           * 32 +: 32] = 32'(COEFF_W);
    hw_value[REGMAP_BUILD_PARAMS_POWER_W_INDEX           * 32 +: 32] = 32'(POWER_W);
    hw_value[REGMAP_BUILD_PARAMS_N_VIRTUAL_CHANS_INDEX   * 32 +: 32] = 32'(N_VIRTUAL_CHANS);

    // Hash the eleven parameter words in offset order, i.e. exactly the order
    // they appear in the register map, so the C++ side can reproduce it by
    // walking the generated register table.
    checksum = 32'h811C9DC5;  // FNV-1a 32 offset basis
    for (int unsigned i = 0; i < REGMAP_BUILD_PARAMS_PARAM_CHECKSUM_INDEX; i++) begin
      checksum = fnv1a32_word(checksum, hw_value[i*32 +: 32]);
    end
    hw_value[REGMAP_BUILD_PARAMS_PARAM_CHECKSUM_INDEX * 32 +: 32] = checksum;
  end

  assign param_checksum = checksum;

  reg_csr_block #(
      .N_REGS     (N),
      .IDX_W      (IDX_W),
      .RESET_VAL  (REGMAP_BUILD_PARAMS_RESET),
      .WMASK      (REGMAP_BUILD_PARAMS_WMASK),
      .W1C_MASK   (REGMAP_BUILD_PARAMS_W1CMASK),
      .PULSE_MASK (REGMAP_BUILD_PARAMS_PULSEMASK),
      .HW_MASK    (REGMAP_BUILD_PARAMS_HWMASK)
  ) u_csr (
      .clk          (clk),
      .rst_n        (rst_n),
      .sel          (sel),
      .write_enable (write_enable),
      .read_enable  (read_enable),
      .index        (index),
      .write_data   (write_data),
      .byte_enable  (byte_enable),
      .read_data    (read_data),
      .ready        (ready),
      .error        (error),
      .hw_value     (hw_value),
      .hw_set       ('0),
      .csr          (csr),
      .pulse        (pulse)
  );

endmodule : reg_block_build_params

`default_nettype wire
