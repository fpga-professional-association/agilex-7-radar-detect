// GENERATED FILE - DO NOT EDIT.
//
// Produced by scripts/gen_regmap.py from control/regmap.json (SPEC 9, issue #7).
// Hand edits are erased by the next run and, before that, fail `make regmap-check`,
// which `make lint` and `make sim-tiny` both depend on.
//
// This package is DATA, not behaviour: addresses, window geometry, per-bit access
// masks and reset values. The behaviour that consumes it is hand written and lives
// in rtl/control/reg_csr_block.sv (the access-type engine) and rtl/control/
// reg_fabric.sv (the decode). Generating tables and hand-writing logic is the split
// this project keeps: a generated always_ff is a thing nobody reviews.
//
// Table layout: each per-block table is a flat vector of N_REGS 32-bit entries,
// entry i at [i*32 +: 32], where i is the register's word index within the block.

package regmap_pkg;

  // ---- plane geometry ----
  localparam int unsigned REGMAP_ADDR_W = 16;
  localparam int unsigned REGMAP_DATA_W = 32;
  localparam int unsigned REGMAP_STRB_W = 4;
  localparam int unsigned REGMAP_WINDOW_BYTES = 4096;
  localparam int unsigned REGMAP_WINDOW_W = 12;
  localparam int unsigned REGMAP_N_BLOCKS = 9;
  localparam int unsigned REGMAP_N_BLOCKS_IMPL = 5;
  localparam int unsigned REGMAP_N_REGS_TOTAL = 28;
  localparam logic [31:0] REGMAP_BLOCK_MASK = 32'h0000001F;

  // ---- implemented block windows, in fabric port order ----
  // The fabric decodes one master port onto these windows; index i here is index i
  // on every per-block port array of rtl/control/reg_fabric.sv.
  localparam logic [REGMAP_N_BLOCKS_IMPL*REGMAP_ADDR_W-1:0] REGMAP_IMPL_BASE = {16'h4000, 16'h3000, 16'h2000, 16'h1000, 16'h0000};
  //   [0] id            base 0x0000  4 registers
  //   [1] build_params  base 0x1000  12 registers
  //   [2] ctrl          base 0x2000  4 registers
  //   [3] fault         base 0x3000  4 registers
  //   [4] scratch       base 0x4000  4 registers

  // -------------------------------------------------------------------------
  // Block 0: id — implemented
  // SPEC 9 groups: Global identification
  // Fixed identification of the control plane itself. Every field is a constant folded
  // in at elaboration, so a live design can be identified without any prior knowledge
  // of what was built.
  // -------------------------------------------------------------------------
  localparam logic [REGMAP_ADDR_W-1:0] REGMAP_ID_BASE = 16'h0000;
  localparam int unsigned REGMAP_ID_SIZE = 4096;
  localparam int unsigned REGMAP_ID_N_REGS = 4;
  localparam int unsigned REGMAP_ID_INDEX = 0;  // fabric port index

  // MAGIC @ 0x0000 (RO)
  //   Constant marker. Reading 0x52414441 ('RADA') at block base proves a control plane
  //   is present and the address decode is alive.
  //   [31:0] MAGIC (RO)
  //       ASCII 'RADA'.
  localparam int unsigned REGMAP_ID_MAGIC_INDEX = 0;
  localparam logic [REGMAP_ADDR_W-1:0] REGMAP_ID_MAGIC_ADDR = 16'h0000;
  localparam int unsigned REGMAP_ID_MAGIC_MAGIC_LSB = 0;
  localparam int unsigned REGMAP_ID_MAGIC_MAGIC_WIDTH = 32;
  localparam logic [31:0] REGMAP_ID_MAGIC_MAGIC_MASK = 32'hFFFFFFFF;

  // VERSION @ 0x0004 (RO)
  //   Register-map version, from regmap_version in the source of truth. Static build
  //   data, deliberately not a git describe: the same source tree must produce the same
  //   register contents on any machine, and a VCS-derived value would make the
  //   generated artefacts depend on checkout state.
  //   [31:24] MAJOR (RO)
  //       Incompatible layout change.
  //   [23:16] MINOR (RO)
  //       Registers or fields added.
  //   [15:8] PATCH (RO)
  //       Documentation-only change.
  //   [7:0] SCHEMA (RO)
  //       Source-of-truth schema version.
  localparam int unsigned REGMAP_ID_VERSION_INDEX = 1;
  localparam logic [REGMAP_ADDR_W-1:0] REGMAP_ID_VERSION_ADDR = 16'h0004;
  localparam int unsigned REGMAP_ID_VERSION_MAJOR_LSB = 24;
  localparam int unsigned REGMAP_ID_VERSION_MAJOR_WIDTH = 8;
  localparam logic [31:0] REGMAP_ID_VERSION_MAJOR_MASK = 32'hFF000000;
  localparam int unsigned REGMAP_ID_VERSION_MINOR_LSB = 16;
  localparam int unsigned REGMAP_ID_VERSION_MINOR_WIDTH = 8;
  localparam logic [31:0] REGMAP_ID_VERSION_MINOR_MASK = 32'h00FF0000;
  localparam int unsigned REGMAP_ID_VERSION_PATCH_LSB = 8;
  localparam int unsigned REGMAP_ID_VERSION_PATCH_WIDTH = 8;
  localparam logic [31:0] REGMAP_ID_VERSION_PATCH_MASK = 32'h0000FF00;
  localparam int unsigned REGMAP_ID_VERSION_SCHEMA_LSB = 0;
  localparam int unsigned REGMAP_ID_VERSION_SCHEMA_WIDTH = 8;
  localparam logic [31:0] REGMAP_ID_VERSION_SCHEMA_MASK = 32'h000000FF;

  // GEOMETRY @ 0x0008 (RO)
  //   Shape of the register plane, so a discovery walk needs no compiled-in constants.
  //   [7:0] N_BLOCKS (RO)
  //       Declared blocks, implemented and planned.
  //   [15:8] N_REGS (RO)
  //       Implemented registers across all blocks.
  //   [23:16] DATA_W (RO)
  //       Register data width in bits.
  //   [31:24] ADDR_W (RO)
  //       Register address width in bits.
  localparam int unsigned REGMAP_ID_GEOMETRY_INDEX = 2;
  localparam logic [REGMAP_ADDR_W-1:0] REGMAP_ID_GEOMETRY_ADDR = 16'h0008;
  localparam int unsigned REGMAP_ID_GEOMETRY_N_BLOCKS_LSB = 0;
  localparam int unsigned REGMAP_ID_GEOMETRY_N_BLOCKS_WIDTH = 8;
  localparam logic [31:0] REGMAP_ID_GEOMETRY_N_BLOCKS_MASK = 32'h000000FF;
  localparam int unsigned REGMAP_ID_GEOMETRY_N_REGS_LSB = 8;
  localparam int unsigned REGMAP_ID_GEOMETRY_N_REGS_WIDTH = 8;
  localparam logic [31:0] REGMAP_ID_GEOMETRY_N_REGS_MASK = 32'h0000FF00;
  localparam int unsigned REGMAP_ID_GEOMETRY_DATA_W_LSB = 16;
  localparam int unsigned REGMAP_ID_GEOMETRY_DATA_W_WIDTH = 8;
  localparam logic [31:0] REGMAP_ID_GEOMETRY_DATA_W_MASK = 32'h00FF0000;
  localparam int unsigned REGMAP_ID_GEOMETRY_ADDR_W_LSB = 24;
  localparam int unsigned REGMAP_ID_GEOMETRY_ADDR_W_WIDTH = 8;
  localparam logic [31:0] REGMAP_ID_GEOMETRY_ADDR_W_MASK = 32'hFF000000;

  // CAPABILITY @ 0x000C (RO)
  //   One bit per declared block, set when that block is implemented in this build. Bit
  //   i is block i in declaration order; a planned block reads 0 and its window returns
  //   error.
  //   [31:0] BLOCK_MASK (RO)
  //       Implemented-block bitmap.
  localparam int unsigned REGMAP_ID_CAPABILITY_INDEX = 3;
  localparam logic [REGMAP_ADDR_W-1:0] REGMAP_ID_CAPABILITY_ADDR = 16'h000C;
  localparam int unsigned REGMAP_ID_CAPABILITY_BLOCK_MASK_LSB = 0;
  localparam int unsigned REGMAP_ID_CAPABILITY_BLOCK_MASK_WIDTH = 32;
  localparam logic [31:0] REGMAP_ID_CAPABILITY_BLOCK_MASK_MASK = 32'hFFFFFFFF;

  // reset value of the stored bits
  localparam logic [REGMAP_ID_N_REGS*32-1:0] REGMAP_ID_RESET = {
      32'h0000001F,  // [3]
      32'h10201C09,  // [2]
      32'h01000001,  // [1]
      32'h52414441  // [0]
  };
  // bits a software write may set or clear (RW)
  localparam logic [REGMAP_ID_N_REGS*32-1:0] REGMAP_ID_WMASK = {
      32'h00000000,  // [3]
      32'h00000000,  // [2]
      32'h00000000,  // [1]
      32'h00000000  // [0]
  };
  // bits cleared by writing 1, set by hardware (W1C)
  localparam logic [REGMAP_ID_N_REGS*32-1:0] REGMAP_ID_W1CMASK = {
      32'h00000000,  // [3]
      32'h00000000,  // [2]
      32'h00000000,  // [1]
      32'h00000000  // [0]
  };
  // bits that pulse for one cycle and read 0 (RWP)
  localparam logic [REGMAP_ID_N_REGS*32-1:0] REGMAP_ID_PULSEMASK = {
      32'h00000000,  // [3]
      32'h00000000,  // [2]
      32'h00000000,  // [1]
      32'h00000000  // [0]
  };
  // bits read from the hardware input, not from storage (ROHW)
  localparam logic [REGMAP_ID_N_REGS*32-1:0] REGMAP_ID_HWMASK = {
      32'h00000000,  // [3]
      32'h00000000,  // [2]
      32'h00000000,  // [1]
      32'h00000000  // [0]
  };

  // -------------------------------------------------------------------------
  // Block 1: build_params — implemented
  // SPEC 9 groups: Build parameters
  // Read-only mirror of the elaboration parameters. Every value is driven from
  // config_pkg, which scripts/build_verilator.py generates from config/<name>.json
  // (SPEC 11), so this block reports what was actually elaborated rather than what a
  // header claims.
  // -------------------------------------------------------------------------
  localparam logic [REGMAP_ADDR_W-1:0] REGMAP_BUILD_PARAMS_BASE = 16'h1000;
  localparam int unsigned REGMAP_BUILD_PARAMS_SIZE = 4096;
  localparam int unsigned REGMAP_BUILD_PARAMS_N_REGS = 12;
  localparam int unsigned REGMAP_BUILD_PARAMS_INDEX = 1;  // fabric port index

  // N_ANTENNAS @ 0x1000 (ROHW)
  //   SPEC 11 sized parameter.
  //   [31:0] VALUE (ROHW) <- config_pkg::N_ANTENNAS
  //       Antenna count.
  localparam int unsigned REGMAP_BUILD_PARAMS_N_ANTENNAS_INDEX = 0;
  localparam logic [REGMAP_ADDR_W-1:0] REGMAP_BUILD_PARAMS_N_ANTENNAS_ADDR = 16'h1000;
  localparam int unsigned REGMAP_BUILD_PARAMS_N_ANTENNAS_VALUE_LSB = 0;
  localparam int unsigned REGMAP_BUILD_PARAMS_N_ANTENNAS_VALUE_WIDTH = 32;
  localparam logic [31:0] REGMAP_BUILD_PARAMS_N_ANTENNAS_VALUE_MASK = 32'hFFFFFFFF;

  // SAMPLES_PER_CYCLE @ 0x1004 (ROHW)
  //   SPEC 11 sized parameter.
  //   [31:0] VALUE (ROHW) <- config_pkg::SAMPLES_PER_CYCLE
  //       Samples presented per core clock.
  localparam int unsigned REGMAP_BUILD_PARAMS_SAMPLES_PER_CYCLE_INDEX = 1;
  localparam logic [REGMAP_ADDR_W-1:0] REGMAP_BUILD_PARAMS_SAMPLES_PER_CYCLE_ADDR = 16'h1004;
  localparam int unsigned REGMAP_BUILD_PARAMS_SAMPLES_PER_CYCLE_VALUE_LSB = 0;
  localparam int unsigned REGMAP_BUILD_PARAMS_SAMPLES_PER_CYCLE_VALUE_WIDTH = 32;
  localparam logic [31:0] REGMAP_BUILD_PARAMS_SAMPLES_PER_CYCLE_VALUE_MASK = 32'hFFFFFFFF;

  // FFT_SIZE @ 0x1008 (ROHW)
  //   SPEC 11 sized parameter.
  //   [31:0] VALUE (ROHW) <- config_pkg::FFT_SIZE
  //       FFT points.
  localparam int unsigned REGMAP_BUILD_PARAMS_FFT_SIZE_INDEX = 2;
  localparam logic [REGMAP_ADDR_W-1:0] REGMAP_BUILD_PARAMS_FFT_SIZE_ADDR = 16'h1008;
  localparam int unsigned REGMAP_BUILD_PARAMS_FFT_SIZE_VALUE_LSB = 0;
  localparam int unsigned REGMAP_BUILD_PARAMS_FFT_SIZE_VALUE_WIDTH = 32;
  localparam logic [31:0] REGMAP_BUILD_PARAMS_FFT_SIZE_VALUE_MASK = 32'hFFFFFFFF;

  // PFB_TAPS @ 0x100C (ROHW)
  //   SPEC 11 sized parameter.
  //   [31:0] VALUE (ROHW) <- config_pkg::PFB_TAPS
  //       Polyphase taps per branch.
  localparam int unsigned REGMAP_BUILD_PARAMS_PFB_TAPS_INDEX = 3;
  localparam logic [REGMAP_ADDR_W-1:0] REGMAP_BUILD_PARAMS_PFB_TAPS_ADDR = 16'h100C;
  localparam int unsigned REGMAP_BUILD_PARAMS_PFB_TAPS_VALUE_LSB = 0;
  localparam int unsigned REGMAP_BUILD_PARAMS_PFB_TAPS_VALUE_WIDTH = 32;
  localparam logic [31:0] REGMAP_BUILD_PARAMS_PFB_TAPS_VALUE_MASK = 32'hFFFFFFFF;

  // N_BEAMS @ 0x1010 (ROHW)
  //   SPEC 11 sized parameter.
  //   [31:0] VALUE (ROHW) <- config_pkg::N_BEAMS
  //       Formed beams.
  localparam int unsigned REGMAP_BUILD_PARAMS_N_BEAMS_INDEX = 4;
  localparam logic [REGMAP_ADDR_W-1:0] REGMAP_BUILD_PARAMS_N_BEAMS_ADDR = 16'h1010;
  localparam int unsigned REGMAP_BUILD_PARAMS_N_BEAMS_VALUE_LSB = 0;
  localparam int unsigned REGMAP_BUILD_PARAMS_N_BEAMS_VALUE_WIDTH = 32;
  localparam logic [31:0] REGMAP_BUILD_PARAMS_N_BEAMS_VALUE_MASK = 32'hFFFFFFFF;

  // HISTORY_FRAMES @ 0x1014 (ROHW)
  //   SPEC 11 sized parameter.
  //   [31:0] VALUE (ROHW) <- config_pkg::HISTORY_FRAMES
  //       Frames of history retained.
  localparam int unsigned REGMAP_BUILD_PARAMS_HISTORY_FRAMES_INDEX = 5;
  localparam logic [REGMAP_ADDR_W-1:0] REGMAP_BUILD_PARAMS_HISTORY_FRAMES_ADDR = 16'h1014;
  localparam int unsigned REGMAP_BUILD_PARAMS_HISTORY_FRAMES_VALUE_LSB = 0;
  localparam int unsigned REGMAP_BUILD_PARAMS_HISTORY_FRAMES_VALUE_WIDTH = 32;
  localparam logic [31:0] REGMAP_BUILD_PARAMS_HISTORY_FRAMES_VALUE_MASK = 32'hFFFFFFFF;

  // PACKET_W @ 0x1018 (ROHW)
  //   SPEC 11 sized parameter.
  //   [31:0] VALUE (ROHW) <- config_pkg::PACKET_W
  //       Packet datapath width.
  localparam int unsigned REGMAP_BUILD_PARAMS_PACKET_W_INDEX = 6;
  localparam logic [REGMAP_ADDR_W-1:0] REGMAP_BUILD_PARAMS_PACKET_W_ADDR = 16'h1018;
  localparam int unsigned REGMAP_BUILD_PARAMS_PACKET_W_VALUE_LSB = 0;
  localparam int unsigned REGMAP_BUILD_PARAMS_PACKET_W_VALUE_WIDTH = 32;
  localparam logic [31:0] REGMAP_BUILD_PARAMS_PACKET_W_VALUE_MASK = 32'hFFFFFFFF;

  // SAMPLE_W @ 0x101C (ROHW)
  //   SPEC 3 invariant parameter.
  //   [31:0] VALUE (ROHW) <- config_pkg::SAMPLE_W
  //       Sample component width.
  localparam int unsigned REGMAP_BUILD_PARAMS_SAMPLE_W_INDEX = 7;
  localparam logic [REGMAP_ADDR_W-1:0] REGMAP_BUILD_PARAMS_SAMPLE_W_ADDR = 16'h101C;
  localparam int unsigned REGMAP_BUILD_PARAMS_SAMPLE_W_VALUE_LSB = 0;
  localparam int unsigned REGMAP_BUILD_PARAMS_SAMPLE_W_VALUE_WIDTH = 32;
  localparam logic [31:0] REGMAP_BUILD_PARAMS_SAMPLE_W_VALUE_MASK = 32'hFFFFFFFF;

  // COEFF_W @ 0x1020 (ROHW)
  //   SPEC 3 invariant parameter.
  //   [31:0] VALUE (ROHW) <- config_pkg::COEFF_W
  //       Coefficient width.
  localparam int unsigned REGMAP_BUILD_PARAMS_COEFF_W_INDEX = 8;
  localparam logic [REGMAP_ADDR_W-1:0] REGMAP_BUILD_PARAMS_COEFF_W_ADDR = 16'h1020;
  localparam int unsigned REGMAP_BUILD_PARAMS_COEFF_W_VALUE_LSB = 0;
  localparam int unsigned REGMAP_BUILD_PARAMS_COEFF_W_VALUE_WIDTH = 32;
  localparam logic [31:0] REGMAP_BUILD_PARAMS_COEFF_W_VALUE_MASK = 32'hFFFFFFFF;

  // POWER_W @ 0x1024 (ROHW)
  //   SPEC 3 invariant parameter.
  //   [31:0] VALUE (ROHW) <- config_pkg::POWER_W
  //       Power/magnitude accumulator width.
  localparam int unsigned REGMAP_BUILD_PARAMS_POWER_W_INDEX = 9;
  localparam logic [REGMAP_ADDR_W-1:0] REGMAP_BUILD_PARAMS_POWER_W_ADDR = 16'h1024;
  localparam int unsigned REGMAP_BUILD_PARAMS_POWER_W_VALUE_LSB = 0;
  localparam int unsigned REGMAP_BUILD_PARAMS_POWER_W_VALUE_WIDTH = 32;
  localparam logic [31:0] REGMAP_BUILD_PARAMS_POWER_W_VALUE_MASK = 32'hFFFFFFFF;

  // N_VIRTUAL_CHANS @ 0x1028 (ROHW)
  //   SPEC 3 invariant parameter.
  //   [31:0] VALUE (ROHW) <- config_pkg::N_VIRTUAL_CHANS
  //       Packet virtual channels.
  localparam int unsigned REGMAP_BUILD_PARAMS_N_VIRTUAL_CHANS_INDEX = 10;
  localparam logic [REGMAP_ADDR_W-1:0] REGMAP_BUILD_PARAMS_N_VIRTUAL_CHANS_ADDR = 16'h1028;
  localparam int unsigned REGMAP_BUILD_PARAMS_N_VIRTUAL_CHANS_VALUE_LSB = 0;
  localparam int unsigned REGMAP_BUILD_PARAMS_N_VIRTUAL_CHANS_VALUE_WIDTH = 32;
  localparam logic [31:0] REGMAP_BUILD_PARAMS_N_VIRTUAL_CHANS_VALUE_MASK = 32'hFFFFFFFF;

  // PARAM_CHECKSUM @ 0x102C (ROHW)
  //   FNV-1a 32 over the eleven parameter words above, in offset order, little-endian
  //   bytes. Computed in RTL from config_pkg and independently in the C++ harness from
  //   config_sim.h: a mismatch means the RTL and the harness were elaborated from
  //   different configurations, which is otherwise a silent and very expensive failure.
  //   [31:0] VALUE (ROHW) <- computed
  //       FNV-1a 32 of the build parameters.
  localparam int unsigned REGMAP_BUILD_PARAMS_PARAM_CHECKSUM_INDEX = 11;
  localparam logic [REGMAP_ADDR_W-1:0] REGMAP_BUILD_PARAMS_PARAM_CHECKSUM_ADDR = 16'h102C;
  localparam int unsigned REGMAP_BUILD_PARAMS_PARAM_CHECKSUM_VALUE_LSB = 0;
  localparam int unsigned REGMAP_BUILD_PARAMS_PARAM_CHECKSUM_VALUE_WIDTH = 32;
  localparam logic [31:0] REGMAP_BUILD_PARAMS_PARAM_CHECKSUM_VALUE_MASK = 32'hFFFFFFFF;

  // reset value of the stored bits
  localparam logic [REGMAP_BUILD_PARAMS_N_REGS*32-1:0] REGMAP_BUILD_PARAMS_RESET = {
      32'h00000000,  // [11]
      32'h00000000,  // [10]
      32'h00000000,  // [9]
      32'h00000000,  // [8]
      32'h00000000,  // [7]
      32'h00000000,  // [6]
      32'h00000000,  // [5]
      32'h00000000,  // [4]
      32'h00000000,  // [3]
      32'h00000000,  // [2]
      32'h00000000,  // [1]
      32'h00000000  // [0]
  };
  // bits a software write may set or clear (RW)
  localparam logic [REGMAP_BUILD_PARAMS_N_REGS*32-1:0] REGMAP_BUILD_PARAMS_WMASK = {
      32'h00000000,  // [11]
      32'h00000000,  // [10]
      32'h00000000,  // [9]
      32'h00000000,  // [8]
      32'h00000000,  // [7]
      32'h00000000,  // [6]
      32'h00000000,  // [5]
      32'h00000000,  // [4]
      32'h00000000,  // [3]
      32'h00000000,  // [2]
      32'h00000000,  // [1]
      32'h00000000  // [0]
  };
  // bits cleared by writing 1, set by hardware (W1C)
  localparam logic [REGMAP_BUILD_PARAMS_N_REGS*32-1:0] REGMAP_BUILD_PARAMS_W1CMASK = {
      32'h00000000,  // [11]
      32'h00000000,  // [10]
      32'h00000000,  // [9]
      32'h00000000,  // [8]
      32'h00000000,  // [7]
      32'h00000000,  // [6]
      32'h00000000,  // [5]
      32'h00000000,  // [4]
      32'h00000000,  // [3]
      32'h00000000,  // [2]
      32'h00000000,  // [1]
      32'h00000000  // [0]
  };
  // bits that pulse for one cycle and read 0 (RWP)
  localparam logic [REGMAP_BUILD_PARAMS_N_REGS*32-1:0] REGMAP_BUILD_PARAMS_PULSEMASK = {
      32'h00000000,  // [11]
      32'h00000000,  // [10]
      32'h00000000,  // [9]
      32'h00000000,  // [8]
      32'h00000000,  // [7]
      32'h00000000,  // [6]
      32'h00000000,  // [5]
      32'h00000000,  // [4]
      32'h00000000,  // [3]
      32'h00000000,  // [2]
      32'h00000000,  // [1]
      32'h00000000  // [0]
  };
  // bits read from the hardware input, not from storage (ROHW)
  localparam logic [REGMAP_BUILD_PARAMS_N_REGS*32-1:0] REGMAP_BUILD_PARAMS_HWMASK = {
      32'hFFFFFFFF,  // [11]
      32'hFFFFFFFF,  // [10]
      32'hFFFFFFFF,  // [9]
      32'hFFFFFFFF,  // [8]
      32'hFFFFFFFF,  // [7]
      32'hFFFFFFFF,  // [6]
      32'hFFFFFFFF,  // [5]
      32'hFFFFFFFF,  // [4]
      32'hFFFFFFFF,  // [3]
      32'hFFFFFFFF,  // [2]
      32'hFFFFFFFF,  // [1]
      32'hFFFFFFFF  // [0]
  };

  // -------------------------------------------------------------------------
  // Block 2: ctrl — implemented
  // SPEC 9 groups: Per-block enable and reset
  // Per-block enable and soft-reset stubs. The bit assignment is fixed now so that each
  // kernel issue wires its own enable and reset without renumbering anything; a bit
  // whose consumer has not landed drives an output of control_top and nothing else.
  // -------------------------------------------------------------------------
  localparam logic [REGMAP_ADDR_W-1:0] REGMAP_CTRL_BASE = 16'h2000;
  localparam int unsigned REGMAP_CTRL_SIZE = 4096;
  localparam int unsigned REGMAP_CTRL_N_REGS = 4;
  localparam int unsigned REGMAP_CTRL_INDEX = 2;  // fabric port index

  // BLOCK_ENABLE @ 0x2000 (RW)
  //   Per-block enable. Reset value enables every block, so a build with no software
  //   present still runs.
  //   [0:0] PFB (RW)
  //       Polyphase filter bank (issue #11).
  //   [1:1] FFT (RW)
  //       FFT (issue #10).
  //   [2:2] BEAMFORMER (RW)
  //       Beamformer (issue #12).
  //   [3:3] COVARIANCE (RW)
  //       Covariance (issue #13).
  //   [4:4] CFAR (RW)
  //       CFAR detector (issue #14).
  //   [5:5] PACKET (RW)
  //       Packet fabric (issue #18).
  //   [6:6] MEMORY (RW)
  //       History memory / corner turn (issue #15).
  //   [7:7] TELEMETRY (RW)
  //       Telemetry and counters (issue #8).
  localparam int unsigned REGMAP_CTRL_BLOCK_ENABLE_INDEX = 0;
  localparam logic [REGMAP_ADDR_W-1:0] REGMAP_CTRL_BLOCK_ENABLE_ADDR = 16'h2000;
  localparam int unsigned REGMAP_CTRL_BLOCK_ENABLE_PFB_LSB = 0;
  localparam int unsigned REGMAP_CTRL_BLOCK_ENABLE_PFB_WIDTH = 1;
  localparam logic [31:0] REGMAP_CTRL_BLOCK_ENABLE_PFB_MASK = 32'h00000001;
  localparam int unsigned REGMAP_CTRL_BLOCK_ENABLE_FFT_LSB = 1;
  localparam int unsigned REGMAP_CTRL_BLOCK_ENABLE_FFT_WIDTH = 1;
  localparam logic [31:0] REGMAP_CTRL_BLOCK_ENABLE_FFT_MASK = 32'h00000002;
  localparam int unsigned REGMAP_CTRL_BLOCK_ENABLE_BEAMFORMER_LSB = 2;
  localparam int unsigned REGMAP_CTRL_BLOCK_ENABLE_BEAMFORMER_WIDTH = 1;
  localparam logic [31:0] REGMAP_CTRL_BLOCK_ENABLE_BEAMFORMER_MASK = 32'h00000004;
  localparam int unsigned REGMAP_CTRL_BLOCK_ENABLE_COVARIANCE_LSB = 3;
  localparam int unsigned REGMAP_CTRL_BLOCK_ENABLE_COVARIANCE_WIDTH = 1;
  localparam logic [31:0] REGMAP_CTRL_BLOCK_ENABLE_COVARIANCE_MASK = 32'h00000008;
  localparam int unsigned REGMAP_CTRL_BLOCK_ENABLE_CFAR_LSB = 4;
  localparam int unsigned REGMAP_CTRL_BLOCK_ENABLE_CFAR_WIDTH = 1;
  localparam logic [31:0] REGMAP_CTRL_BLOCK_ENABLE_CFAR_MASK = 32'h00000010;
  localparam int unsigned REGMAP_CTRL_BLOCK_ENABLE_PACKET_LSB = 5;
  localparam int unsigned REGMAP_CTRL_BLOCK_ENABLE_PACKET_WIDTH = 1;
  localparam logic [31:0] REGMAP_CTRL_BLOCK_ENABLE_PACKET_MASK = 32'h00000020;
  localparam int unsigned REGMAP_CTRL_BLOCK_ENABLE_MEMORY_LSB = 6;
  localparam int unsigned REGMAP_CTRL_BLOCK_ENABLE_MEMORY_WIDTH = 1;
  localparam logic [31:0] REGMAP_CTRL_BLOCK_ENABLE_MEMORY_MASK = 32'h00000040;
  localparam int unsigned REGMAP_CTRL_BLOCK_ENABLE_TELEMETRY_LSB = 7;
  localparam int unsigned REGMAP_CTRL_BLOCK_ENABLE_TELEMETRY_WIDTH = 1;
  localparam logic [31:0] REGMAP_CTRL_BLOCK_ENABLE_TELEMETRY_MASK = 32'h00000080;

  // BLOCK_RESET @ 0x2004 (RWP)
  //   Per-block soft reset request. Writing 1 emits a one-cycle pulse in the cfg_clk
  //   domain; the bit always reads 0. Crossing the pulse into each block's own domain
  //   is issue #6 work and is deliberately not done here.
  //   [0:0] PFB (RWP)
  //       Pulse a soft reset at the PFB.
  //   [1:1] FFT (RWP)
  //       Pulse a soft reset at the FFT.
  //   [2:2] BEAMFORMER (RWP)
  //       Pulse a soft reset at the beamformer.
  //   [3:3] COVARIANCE (RWP)
  //       Pulse a soft reset at the covariance engine.
  //   [4:4] CFAR (RWP)
  //       Pulse a soft reset at the CFAR detector.
  //   [5:5] PACKET (RWP)
  //       Pulse a soft reset at the packet fabric.
  //   [6:6] MEMORY (RWP)
  //       Pulse a soft reset at the history memory.
  //   [7:7] TELEMETRY (RWP)
  //       Pulse a soft reset at the telemetry block.
  localparam int unsigned REGMAP_CTRL_BLOCK_RESET_INDEX = 1;
  localparam logic [REGMAP_ADDR_W-1:0] REGMAP_CTRL_BLOCK_RESET_ADDR = 16'h2004;
  localparam int unsigned REGMAP_CTRL_BLOCK_RESET_PFB_LSB = 0;
  localparam int unsigned REGMAP_CTRL_BLOCK_RESET_PFB_WIDTH = 1;
  localparam logic [31:0] REGMAP_CTRL_BLOCK_RESET_PFB_MASK = 32'h00000001;
  localparam int unsigned REGMAP_CTRL_BLOCK_RESET_FFT_LSB = 1;
  localparam int unsigned REGMAP_CTRL_BLOCK_RESET_FFT_WIDTH = 1;
  localparam logic [31:0] REGMAP_CTRL_BLOCK_RESET_FFT_MASK = 32'h00000002;
  localparam int unsigned REGMAP_CTRL_BLOCK_RESET_BEAMFORMER_LSB = 2;
  localparam int unsigned REGMAP_CTRL_BLOCK_RESET_BEAMFORMER_WIDTH = 1;
  localparam logic [31:0] REGMAP_CTRL_BLOCK_RESET_BEAMFORMER_MASK = 32'h00000004;
  localparam int unsigned REGMAP_CTRL_BLOCK_RESET_COVARIANCE_LSB = 3;
  localparam int unsigned REGMAP_CTRL_BLOCK_RESET_COVARIANCE_WIDTH = 1;
  localparam logic [31:0] REGMAP_CTRL_BLOCK_RESET_COVARIANCE_MASK = 32'h00000008;
  localparam int unsigned REGMAP_CTRL_BLOCK_RESET_CFAR_LSB = 4;
  localparam int unsigned REGMAP_CTRL_BLOCK_RESET_CFAR_WIDTH = 1;
  localparam logic [31:0] REGMAP_CTRL_BLOCK_RESET_CFAR_MASK = 32'h00000010;
  localparam int unsigned REGMAP_CTRL_BLOCK_RESET_PACKET_LSB = 5;
  localparam int unsigned REGMAP_CTRL_BLOCK_RESET_PACKET_WIDTH = 1;
  localparam logic [31:0] REGMAP_CTRL_BLOCK_RESET_PACKET_MASK = 32'h00000020;
  localparam int unsigned REGMAP_CTRL_BLOCK_RESET_MEMORY_LSB = 6;
  localparam int unsigned REGMAP_CTRL_BLOCK_RESET_MEMORY_WIDTH = 1;
  localparam logic [31:0] REGMAP_CTRL_BLOCK_RESET_MEMORY_MASK = 32'h00000040;
  localparam int unsigned REGMAP_CTRL_BLOCK_RESET_TELEMETRY_LSB = 7;
  localparam int unsigned REGMAP_CTRL_BLOCK_RESET_TELEMETRY_WIDTH = 1;
  localparam logic [31:0] REGMAP_CTRL_BLOCK_RESET_TELEMETRY_MASK = 32'h00000080;

  // GLOBAL_CTRL @ 0x2008 (MIXED)
  //   Datapath-wide control. GLOBAL_ENABLE gates every block regardless of
  //   BLOCK_ENABLE.
  //   [0:0] GLOBAL_ENABLE (RW)
  //       Master enable for the datapath.
  //   [1:1] FLUSH (RWP)
  //       Pulse a pipeline flush.
  //   [2:2] SOFT_RESET (RWP)
  //       Pulse a datapath-wide soft reset.
  localparam int unsigned REGMAP_CTRL_GLOBAL_CTRL_INDEX = 2;
  localparam logic [REGMAP_ADDR_W-1:0] REGMAP_CTRL_GLOBAL_CTRL_ADDR = 16'h2008;
  localparam int unsigned REGMAP_CTRL_GLOBAL_CTRL_GLOBAL_ENABLE_LSB = 0;
  localparam int unsigned REGMAP_CTRL_GLOBAL_CTRL_GLOBAL_ENABLE_WIDTH = 1;
  localparam logic [31:0] REGMAP_CTRL_GLOBAL_CTRL_GLOBAL_ENABLE_MASK = 32'h00000001;
  localparam int unsigned REGMAP_CTRL_GLOBAL_CTRL_FLUSH_LSB = 1;
  localparam int unsigned REGMAP_CTRL_GLOBAL_CTRL_FLUSH_WIDTH = 1;
  localparam logic [31:0] REGMAP_CTRL_GLOBAL_CTRL_FLUSH_MASK = 32'h00000002;
  localparam int unsigned REGMAP_CTRL_GLOBAL_CTRL_SOFT_RESET_LSB = 2;
  localparam int unsigned REGMAP_CTRL_GLOBAL_CTRL_SOFT_RESET_WIDTH = 1;
  localparam logic [31:0] REGMAP_CTRL_GLOBAL_CTRL_SOFT_RESET_MASK = 32'h00000004;

  // CTRL_STATUS @ 0x200C (ROHW)
  //   Hardware-driven status. ENABLED_COUNT is computed in the block from the live
  //   BLOCK_ENABLE value, so it exercises a real hardware read path rather than
  //   mirroring storage.
  //   [3:0] ENABLED_COUNT (ROHW)
  //       Population count of BLOCK_ENABLE.
  //   [8:8] ALIVE (ROHW)
  //       Tied high by the block; reads 1 whenever the control plane is out of reset.
  localparam int unsigned REGMAP_CTRL_CTRL_STATUS_INDEX = 3;
  localparam logic [REGMAP_ADDR_W-1:0] REGMAP_CTRL_CTRL_STATUS_ADDR = 16'h200C;
  localparam int unsigned REGMAP_CTRL_CTRL_STATUS_ENABLED_COUNT_LSB = 0;
  localparam int unsigned REGMAP_CTRL_CTRL_STATUS_ENABLED_COUNT_WIDTH = 4;
  localparam logic [31:0] REGMAP_CTRL_CTRL_STATUS_ENABLED_COUNT_MASK = 32'h0000000F;
  localparam int unsigned REGMAP_CTRL_CTRL_STATUS_ALIVE_LSB = 8;
  localparam int unsigned REGMAP_CTRL_CTRL_STATUS_ALIVE_WIDTH = 1;
  localparam logic [31:0] REGMAP_CTRL_CTRL_STATUS_ALIVE_MASK = 32'h00000100;

  // reset value of the stored bits
  localparam logic [REGMAP_CTRL_N_REGS*32-1:0] REGMAP_CTRL_RESET = {
      32'h00000000,  // [3]
      32'h00000001,  // [2]
      32'h00000000,  // [1]
      32'h000000FF  // [0]
  };
  // bits a software write may set or clear (RW)
  localparam logic [REGMAP_CTRL_N_REGS*32-1:0] REGMAP_CTRL_WMASK = {
      32'h00000000,  // [3]
      32'h00000001,  // [2]
      32'h00000000,  // [1]
      32'h000000FF  // [0]
  };
  // bits cleared by writing 1, set by hardware (W1C)
  localparam logic [REGMAP_CTRL_N_REGS*32-1:0] REGMAP_CTRL_W1CMASK = {
      32'h00000000,  // [3]
      32'h00000000,  // [2]
      32'h00000000,  // [1]
      32'h00000000  // [0]
  };
  // bits that pulse for one cycle and read 0 (RWP)
  localparam logic [REGMAP_CTRL_N_REGS*32-1:0] REGMAP_CTRL_PULSEMASK = {
      32'h00000000,  // [3]
      32'h00000006,  // [2]
      32'h000000FF,  // [1]
      32'h00000000  // [0]
  };
  // bits read from the hardware input, not from storage (ROHW)
  localparam logic [REGMAP_CTRL_N_REGS*32-1:0] REGMAP_CTRL_HWMASK = {
      32'h0000010F,  // [3]
      32'h00000000,  // [2]
      32'h00000000,  // [1]
      32'h00000000  // [0]
  };

  // -------------------------------------------------------------------------
  // Block 3: fault — implemented
  // SPEC 9 groups: Fault injection
  // Fault injection (SPEC 24). Injection is two-step on purpose: a persistent arming
  // mask plus a one-shot trigger. A single stray write can therefore never inject a
  // fault, and the arming state is visible in a register dump taken after the fact.
  // -------------------------------------------------------------------------
  localparam logic [REGMAP_ADDR_W-1:0] REGMAP_FAULT_BASE = 16'h3000;
  localparam int unsigned REGMAP_FAULT_SIZE = 4096;
  localparam int unsigned REGMAP_FAULT_N_REGS = 4;
  localparam int unsigned REGMAP_FAULT_INDEX = 3;  // fabric port index

  // FAULT_ENABLE @ 0x3000 (RW)
  //   Arming mask. A trigger bit has no effect unless the matching enable bit is set.
  //   [0:0] STREAM_CORRUPT (RW)
  //       Corrupt a stream payload.
  //   [1:1] SEQ_ERROR (RW)
  //       Force a sequence discontinuity.
  //   [2:2] FIFO_OVERFLOW (RW)
  //       Force a FIFO overflow (issue #6 primitives).
  //   [3:3] CDC_ERROR (RW)
  //       Force a CDC error report.
  //   [4:4] SATURATION (RW)
  //       Force a fixed-point saturation event.
  //   [5:5] PACKET_DROP (RW)
  //       Drop a packet in the packet fabric.
  localparam int unsigned REGMAP_FAULT_FAULT_ENABLE_INDEX = 0;
  localparam logic [REGMAP_ADDR_W-1:0] REGMAP_FAULT_FAULT_ENABLE_ADDR = 16'h3000;
  localparam int unsigned REGMAP_FAULT_FAULT_ENABLE_STREAM_CORRUPT_LSB = 0;
  localparam int unsigned REGMAP_FAULT_FAULT_ENABLE_STREAM_CORRUPT_WIDTH = 1;
  localparam logic [31:0] REGMAP_FAULT_FAULT_ENABLE_STREAM_CORRUPT_MASK = 32'h00000001;
  localparam int unsigned REGMAP_FAULT_FAULT_ENABLE_SEQ_ERROR_LSB = 1;
  localparam int unsigned REGMAP_FAULT_FAULT_ENABLE_SEQ_ERROR_WIDTH = 1;
  localparam logic [31:0] REGMAP_FAULT_FAULT_ENABLE_SEQ_ERROR_MASK = 32'h00000002;
  localparam int unsigned REGMAP_FAULT_FAULT_ENABLE_FIFO_OVERFLOW_LSB = 2;
  localparam int unsigned REGMAP_FAULT_FAULT_ENABLE_FIFO_OVERFLOW_WIDTH = 1;
  localparam logic [31:0] REGMAP_FAULT_FAULT_ENABLE_FIFO_OVERFLOW_MASK = 32'h00000004;
  localparam int unsigned REGMAP_FAULT_FAULT_ENABLE_CDC_ERROR_LSB = 3;
  localparam int unsigned REGMAP_FAULT_FAULT_ENABLE_CDC_ERROR_WIDTH = 1;
  localparam logic [31:0] REGMAP_FAULT_FAULT_ENABLE_CDC_ERROR_MASK = 32'h00000008;
  localparam int unsigned REGMAP_FAULT_FAULT_ENABLE_SATURATION_LSB = 4;
  localparam int unsigned REGMAP_FAULT_FAULT_ENABLE_SATURATION_WIDTH = 1;
  localparam logic [31:0] REGMAP_FAULT_FAULT_ENABLE_SATURATION_MASK = 32'h00000010;
  localparam int unsigned REGMAP_FAULT_FAULT_ENABLE_PACKET_DROP_LSB = 5;
  localparam int unsigned REGMAP_FAULT_FAULT_ENABLE_PACKET_DROP_WIDTH = 1;
  localparam logic [31:0] REGMAP_FAULT_FAULT_ENABLE_PACKET_DROP_MASK = 32'h00000020;

  // FAULT_INJECT @ 0x3004 (RWP)
  //   One-shot triggers, same bit assignment as FAULT_ENABLE. Writing 1 to an armed bit
  //   emits a one-cycle pulse and sets the matching FAULT_STATUS bit. Always reads 0.
  //   [0:0] STREAM_CORRUPT (RWP)
  //       Trigger a stream corruption.
  //   [1:1] SEQ_ERROR (RWP)
  //       Trigger a sequence discontinuity.
  //   [2:2] FIFO_OVERFLOW (RWP)
  //       Trigger a FIFO overflow.
  //   [3:3] CDC_ERROR (RWP)
  //       Trigger a CDC error.
  //   [4:4] SATURATION (RWP)
  //       Trigger a saturation event.
  //   [5:5] PACKET_DROP (RWP)
  //       Trigger a packet drop.
  localparam int unsigned REGMAP_FAULT_FAULT_INJECT_INDEX = 1;
  localparam logic [REGMAP_ADDR_W-1:0] REGMAP_FAULT_FAULT_INJECT_ADDR = 16'h3004;
  localparam int unsigned REGMAP_FAULT_FAULT_INJECT_STREAM_CORRUPT_LSB = 0;
  localparam int unsigned REGMAP_FAULT_FAULT_INJECT_STREAM_CORRUPT_WIDTH = 1;
  localparam logic [31:0] REGMAP_FAULT_FAULT_INJECT_STREAM_CORRUPT_MASK = 32'h00000001;
  localparam int unsigned REGMAP_FAULT_FAULT_INJECT_SEQ_ERROR_LSB = 1;
  localparam int unsigned REGMAP_FAULT_FAULT_INJECT_SEQ_ERROR_WIDTH = 1;
  localparam logic [31:0] REGMAP_FAULT_FAULT_INJECT_SEQ_ERROR_MASK = 32'h00000002;
  localparam int unsigned REGMAP_FAULT_FAULT_INJECT_FIFO_OVERFLOW_LSB = 2;
  localparam int unsigned REGMAP_FAULT_FAULT_INJECT_FIFO_OVERFLOW_WIDTH = 1;
  localparam logic [31:0] REGMAP_FAULT_FAULT_INJECT_FIFO_OVERFLOW_MASK = 32'h00000004;
  localparam int unsigned REGMAP_FAULT_FAULT_INJECT_CDC_ERROR_LSB = 3;
  localparam int unsigned REGMAP_FAULT_FAULT_INJECT_CDC_ERROR_WIDTH = 1;
  localparam logic [31:0] REGMAP_FAULT_FAULT_INJECT_CDC_ERROR_MASK = 32'h00000008;
  localparam int unsigned REGMAP_FAULT_FAULT_INJECT_SATURATION_LSB = 4;
  localparam int unsigned REGMAP_FAULT_FAULT_INJECT_SATURATION_WIDTH = 1;
  localparam logic [31:0] REGMAP_FAULT_FAULT_INJECT_SATURATION_MASK = 32'h00000010;
  localparam int unsigned REGMAP_FAULT_FAULT_INJECT_PACKET_DROP_LSB = 5;
  localparam int unsigned REGMAP_FAULT_FAULT_INJECT_PACKET_DROP_WIDTH = 1;
  localparam logic [31:0] REGMAP_FAULT_FAULT_INJECT_PACKET_DROP_MASK = 32'h00000020;

  // FAULT_STATUS @ 0x3008 (W1C)
  //   Sticky record of faults actually injected, set by hardware and cleared by writing
  //   1. A hardware set in the same cycle as a software clear wins, so an event is
  //   never lost to a racing clear.
  //   [0:0] STREAM_CORRUPT (W1C)
  //       A stream corruption was injected.
  //   [1:1] SEQ_ERROR (W1C)
  //       A sequence discontinuity was injected.
  //   [2:2] FIFO_OVERFLOW (W1C)
  //       A FIFO overflow was injected.
  //   [3:3] CDC_ERROR (W1C)
  //       A CDC error was injected.
  //   [4:4] SATURATION (W1C)
  //       A saturation event was injected.
  //   [5:5] PACKET_DROP (W1C)
  //       A packet drop was injected.
  localparam int unsigned REGMAP_FAULT_FAULT_STATUS_INDEX = 2;
  localparam logic [REGMAP_ADDR_W-1:0] REGMAP_FAULT_FAULT_STATUS_ADDR = 16'h3008;
  localparam int unsigned REGMAP_FAULT_FAULT_STATUS_STREAM_CORRUPT_LSB = 0;
  localparam int unsigned REGMAP_FAULT_FAULT_STATUS_STREAM_CORRUPT_WIDTH = 1;
  localparam logic [31:0] REGMAP_FAULT_FAULT_STATUS_STREAM_CORRUPT_MASK = 32'h00000001;
  localparam int unsigned REGMAP_FAULT_FAULT_STATUS_SEQ_ERROR_LSB = 1;
  localparam int unsigned REGMAP_FAULT_FAULT_STATUS_SEQ_ERROR_WIDTH = 1;
  localparam logic [31:0] REGMAP_FAULT_FAULT_STATUS_SEQ_ERROR_MASK = 32'h00000002;
  localparam int unsigned REGMAP_FAULT_FAULT_STATUS_FIFO_OVERFLOW_LSB = 2;
  localparam int unsigned REGMAP_FAULT_FAULT_STATUS_FIFO_OVERFLOW_WIDTH = 1;
  localparam logic [31:0] REGMAP_FAULT_FAULT_STATUS_FIFO_OVERFLOW_MASK = 32'h00000004;
  localparam int unsigned REGMAP_FAULT_FAULT_STATUS_CDC_ERROR_LSB = 3;
  localparam int unsigned REGMAP_FAULT_FAULT_STATUS_CDC_ERROR_WIDTH = 1;
  localparam logic [31:0] REGMAP_FAULT_FAULT_STATUS_CDC_ERROR_MASK = 32'h00000008;
  localparam int unsigned REGMAP_FAULT_FAULT_STATUS_SATURATION_LSB = 4;
  localparam int unsigned REGMAP_FAULT_FAULT_STATUS_SATURATION_WIDTH = 1;
  localparam logic [31:0] REGMAP_FAULT_FAULT_STATUS_SATURATION_MASK = 32'h00000010;
  localparam int unsigned REGMAP_FAULT_FAULT_STATUS_PACKET_DROP_LSB = 5;
  localparam int unsigned REGMAP_FAULT_FAULT_STATUS_PACKET_DROP_WIDTH = 1;
  localparam logic [31:0] REGMAP_FAULT_FAULT_STATUS_PACKET_DROP_MASK = 32'h00000020;

  // FAULT_COUNT @ 0x300C (ROHW)
  //   Free-running count of injected fault pulses (one per armed bit per trigger).
  //   Saturating, not wrapping, so a dump taken long after the event still reports
  //   'many' rather than an ambiguous small number.
  //   [31:0] VALUE (ROHW)
  //       Injected fault pulses, saturating at 0xFFFFFFFF.
  localparam int unsigned REGMAP_FAULT_FAULT_COUNT_INDEX = 3;
  localparam logic [REGMAP_ADDR_W-1:0] REGMAP_FAULT_FAULT_COUNT_ADDR = 16'h300C;
  localparam int unsigned REGMAP_FAULT_FAULT_COUNT_VALUE_LSB = 0;
  localparam int unsigned REGMAP_FAULT_FAULT_COUNT_VALUE_WIDTH = 32;
  localparam logic [31:0] REGMAP_FAULT_FAULT_COUNT_VALUE_MASK = 32'hFFFFFFFF;

  // reset value of the stored bits
  localparam logic [REGMAP_FAULT_N_REGS*32-1:0] REGMAP_FAULT_RESET = {
      32'h00000000,  // [3]
      32'h00000000,  // [2]
      32'h00000000,  // [1]
      32'h00000000  // [0]
  };
  // bits a software write may set or clear (RW)
  localparam logic [REGMAP_FAULT_N_REGS*32-1:0] REGMAP_FAULT_WMASK = {
      32'h00000000,  // [3]
      32'h00000000,  // [2]
      32'h00000000,  // [1]
      32'h0000003F  // [0]
  };
  // bits cleared by writing 1, set by hardware (W1C)
  localparam logic [REGMAP_FAULT_N_REGS*32-1:0] REGMAP_FAULT_W1CMASK = {
      32'h00000000,  // [3]
      32'h0000003F,  // [2]
      32'h00000000,  // [1]
      32'h00000000  // [0]
  };
  // bits that pulse for one cycle and read 0 (RWP)
  localparam logic [REGMAP_FAULT_N_REGS*32-1:0] REGMAP_FAULT_PULSEMASK = {
      32'h00000000,  // [3]
      32'h00000000,  // [2]
      32'h0000003F,  // [1]
      32'h00000000  // [0]
  };
  // bits read from the hardware input, not from storage (ROHW)
  localparam logic [REGMAP_FAULT_N_REGS*32-1:0] REGMAP_FAULT_HWMASK = {
      32'hFFFFFFFF,  // [3]
      32'h00000000,  // [2]
      32'h00000000,  // [1]
      32'h00000000  // [0]
  };

  // -------------------------------------------------------------------------
  // Block 4: scratch — implemented
  // SPEC 9 groups: Snapshot and debug control
  // Software scratch registers with no hardware effect. They exist to test the fabric
  // itself: four distinct reset values prove per-register reset defaults, and SCRATCH3
  // mixes a writable half with a read-only half so that partial writability is covered
  // by construction rather than by a future block happening to need it. The snapshot
  // and debug-control group proper lands with issue #19 in the debug window.
  // -------------------------------------------------------------------------
  localparam logic [REGMAP_ADDR_W-1:0] REGMAP_SCRATCH_BASE = 16'h4000;
  localparam int unsigned REGMAP_SCRATCH_SIZE = 4096;
  localparam int unsigned REGMAP_SCRATCH_N_REGS = 4;
  localparam int unsigned REGMAP_SCRATCH_INDEX = 4;  // fabric port index

  // SCRATCH0 @ 0x4000 (RW)
  //   Scratch, reset all zeros.
  //   [31:0] VALUE (RW)
  //       Free software use.
  localparam int unsigned REGMAP_SCRATCH_SCRATCH0_INDEX = 0;
  localparam logic [REGMAP_ADDR_W-1:0] REGMAP_SCRATCH_SCRATCH0_ADDR = 16'h4000;
  localparam int unsigned REGMAP_SCRATCH_SCRATCH0_VALUE_LSB = 0;
  localparam int unsigned REGMAP_SCRATCH_SCRATCH0_VALUE_WIDTH = 32;
  localparam logic [31:0] REGMAP_SCRATCH_SCRATCH0_VALUE_MASK = 32'hFFFFFFFF;

  // SCRATCH1 @ 0x4004 (RW)
  //   Scratch, reset all ones.
  //   [31:0] VALUE (RW)
  //       Free software use.
  localparam int unsigned REGMAP_SCRATCH_SCRATCH1_INDEX = 1;
  localparam logic [REGMAP_ADDR_W-1:0] REGMAP_SCRATCH_SCRATCH1_ADDR = 16'h4004;
  localparam int unsigned REGMAP_SCRATCH_SCRATCH1_VALUE_LSB = 0;
  localparam int unsigned REGMAP_SCRATCH_SCRATCH1_VALUE_WIDTH = 32;
  localparam logic [31:0] REGMAP_SCRATCH_SCRATCH1_VALUE_MASK = 32'hFFFFFFFF;

  // SCRATCH2 @ 0x4008 (RW)
  //   Scratch, alternating reset.
  //   [31:0] VALUE (RW)
  //       Free software use.
  localparam int unsigned REGMAP_SCRATCH_SCRATCH2_INDEX = 2;
  localparam logic [REGMAP_ADDR_W-1:0] REGMAP_SCRATCH_SCRATCH2_ADDR = 16'h4008;
  localparam int unsigned REGMAP_SCRATCH_SCRATCH2_VALUE_LSB = 0;
  localparam int unsigned REGMAP_SCRATCH_SCRATCH2_VALUE_WIDTH = 32;
  localparam logic [31:0] REGMAP_SCRATCH_SCRATCH2_VALUE_MASK = 32'hFFFFFFFF;

  // SCRATCH3 @ 0x400C (MIXED)
  //   Half writable, half constant. A write updates RW_LOW and leaves RO_HIGH
  //   untouched, and the transaction succeeds (error=0) because the register is
  //   partially writable.
  //   [15:0] RW_LOW (RW)
  //       Writable half.
  //   [31:16] RO_HIGH (RO)
  //       Constant half; writes are ignored, not refused.
  localparam int unsigned REGMAP_SCRATCH_SCRATCH3_INDEX = 3;
  localparam logic [REGMAP_ADDR_W-1:0] REGMAP_SCRATCH_SCRATCH3_ADDR = 16'h400C;
  localparam int unsigned REGMAP_SCRATCH_SCRATCH3_RW_LOW_LSB = 0;
  localparam int unsigned REGMAP_SCRATCH_SCRATCH3_RW_LOW_WIDTH = 16;
  localparam logic [31:0] REGMAP_SCRATCH_SCRATCH3_RW_LOW_MASK = 32'h0000FFFF;
  localparam int unsigned REGMAP_SCRATCH_SCRATCH3_RO_HIGH_LSB = 16;
  localparam int unsigned REGMAP_SCRATCH_SCRATCH3_RO_HIGH_WIDTH = 16;
  localparam logic [31:0] REGMAP_SCRATCH_SCRATCH3_RO_HIGH_MASK = 32'hFFFF0000;

  // reset value of the stored bits
  localparam logic [REGMAP_SCRATCH_N_REGS*32-1:0] REGMAP_SCRATCH_RESET = {
      32'hDEAD5A5A,  // [3]
      32'hA5A5A5A5,  // [2]
      32'hFFFFFFFF,  // [1]
      32'h00000000  // [0]
  };
  // bits a software write may set or clear (RW)
  localparam logic [REGMAP_SCRATCH_N_REGS*32-1:0] REGMAP_SCRATCH_WMASK = {
      32'h0000FFFF,  // [3]
      32'hFFFFFFFF,  // [2]
      32'hFFFFFFFF,  // [1]
      32'hFFFFFFFF  // [0]
  };
  // bits cleared by writing 1, set by hardware (W1C)
  localparam logic [REGMAP_SCRATCH_N_REGS*32-1:0] REGMAP_SCRATCH_W1CMASK = {
      32'h00000000,  // [3]
      32'h00000000,  // [2]
      32'h00000000,  // [1]
      32'h00000000  // [0]
  };
  // bits that pulse for one cycle and read 0 (RWP)
  localparam logic [REGMAP_SCRATCH_N_REGS*32-1:0] REGMAP_SCRATCH_PULSEMASK = {
      32'h00000000,  // [3]
      32'h00000000,  // [2]
      32'h00000000,  // [1]
      32'h00000000  // [0]
  };
  // bits read from the hardware input, not from storage (ROHW)
  localparam logic [REGMAP_SCRATCH_N_REGS*32-1:0] REGMAP_SCRATCH_HWMASK = {
      32'h00000000,  // [3]
      32'h00000000,  // [2]
      32'h00000000,  // [1]
      32'h00000000  // [0]
  };

  // -------------------------------------------------------------------------
  // Block 5: coeff — PLANNED (#10, #11, #12, #16)
  // SPEC 9 groups: Coefficient and weight programming; Active bank selection
  // PLANNED. Coefficient and beam-weight programming with double buffering and an
  // active-bank select. Declared here so the window is reserved and the address space
  // cannot be reassigned by a later issue; unimplemented until its owning issues land,
  // and every access to this window returns error=1 today.
  // -------------------------------------------------------------------------
  localparam logic [REGMAP_ADDR_W-1:0] REGMAP_COEFF_BASE = 16'h5000;
  localparam int unsigned REGMAP_COEFF_SIZE = 4096;
  localparam int unsigned REGMAP_COEFF_N_REGS = 0;
  // No registers in this build: every access to 0x5000..0x5FFF returns error=1.

  // -------------------------------------------------------------------------
  // Block 6: cfar — PLANNED (#14, #16)
  // SPEC 9 groups: CFAR settings; Integration settings
  // PLANNED. CFAR guard/training geometry and threshold scaling, plus coherent and
  // non-coherent integration settings.
  // -------------------------------------------------------------------------
  localparam logic [REGMAP_ADDR_W-1:0] REGMAP_CFAR_BASE = 16'h6000;
  localparam int unsigned REGMAP_CFAR_SIZE = 4096;
  localparam int unsigned REGMAP_CFAR_N_REGS = 0;
  // No registers in this build: every access to 0x6000..0x6FFF returns error=1.

  // -------------------------------------------------------------------------
  // Block 7: counters — PLANNED (#8)
  // SPEC 9 groups: Stream counters; Stall counters; FIFO high-water marks; Overflow and saturation counts; Frame counts; Sequence errors; CDC errors
  // PLANNED. Performance and health telemetry. The counters themselves are issue #8;
  // this window is where they are read from. Counters live in the telemetry clock
  // domain, so this block will be the first consumer of the issue #6 CDC primitives on
  // the register path.
  // -------------------------------------------------------------------------
  localparam logic [REGMAP_ADDR_W-1:0] REGMAP_COUNTERS_BASE = 16'h7000;
  localparam int unsigned REGMAP_COUNTERS_SIZE = 4096;
  localparam int unsigned REGMAP_COUNTERS_N_REGS = 0;
  // No registers in this build: every access to 0x7000..0x7FFF returns error=1.

  // -------------------------------------------------------------------------
  // Block 8: debug — PLANNED (#19)
  // SPEC 9 groups: Snapshot and debug control
  // PLANNED. Snapshot capture, trigger configuration and debug readback.
  // -------------------------------------------------------------------------
  localparam logic [REGMAP_ADDR_W-1:0] REGMAP_DEBUG_BASE = 16'h8000;
  localparam int unsigned REGMAP_DEBUG_SIZE = 4096;
  localparam int unsigned REGMAP_DEBUG_N_REGS = 0;
  // No registers in this build: every access to 0x8000..0x8FFF returns error=1.

endpackage : regmap_pkg
