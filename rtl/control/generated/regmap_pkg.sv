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
  localparam int unsigned REGMAP_N_BLOCKS = 10;
  localparam int unsigned REGMAP_N_BLOCKS_IMPL = 9;
  localparam int unsigned REGMAP_N_REGS_TOTAL = 69;
  localparam logic [31:0] REGMAP_BLOCK_MASK = 32'h000002FF;

  // ---- implemented block windows, in fabric port order ----
  // The fabric decodes one master port onto these windows; index i here is index i
  // on every per-block port array of rtl/control/reg_fabric.sv.
  localparam logic [REGMAP_N_BLOCKS_IMPL*REGMAP_ADDR_W-1:0] REGMAP_IMPL_BASE = {16'h9000, 16'h7000, 16'h6000, 16'h5000, 16'h4000, 16'h3000, 16'h2000, 16'h1000, 16'h0000};
  //   [0] id            base 0x0000  4 registers
  //   [1] build_params  base 0x1000  12 registers
  //   [2] ctrl          base 0x2000  4 registers
  //   [3] fault         base 0x3000  4 registers
  //   [4] scratch       base 0x4000  4 registers
  //   [5] coeff         base 0x5000  4 registers
  //   [6] cfar          base 0x6000  9 registers
  //   [7] counters      base 0x7000  21 registers
  //   [8] covar         base 0x9000  7 registers

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
      32'h000002FF,  // [3]
      32'h1020450A,  // [2]
      32'h01040001,  // [1]
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
  // Block 5: coeff — implemented
  // SPEC 9 groups: Coefficient and weight programming; Active bank selection
  // Coefficient and weight programming with double buffering and an active-bank select
  // (SPEC 7.1, SPEC 9). Implemented for the polyphase FIR bank by issue #10; the FFT
  // twiddles (#11), the beam weights (#12) and the per-antenna fan-out (#16) extend it
  // inside the same reserved window. PROGRAMMING SEQUENCE: set COEFF_CTRL.BANK_SEL to
  // the SPARE bank, write COEFF_ADDR once, then write COEFF_DATA per coefficient (the
  // DATA write is what issues the transfer; AUTO_INC advances the index), then write
  // COEFF_CTRL.SWAP_REQ. The swap takes effect at the next start-of-frame beat and not
  // before, which is what makes a frame filtered by exactly one coefficient set. A
  // write aimed at the bank that is currently ACTIVE is refused and raises
  // COEFF_STATUS.WR_REJECT; it is never merged and never deferred. Every field here
  // crosses a clock domain, because the register plane runs on cfg_clk and the bank on
  // core_clk (rtl/pfb/coeff_bank.sv, issue #6 primitives): writes through a four-phase
  // handshake, SWAP_REQ through a pulse synchronizer, and each status bit through its
  // own flip-flop synchronizer. WR_BUSY and SWAP_BUSY are therefore flow control, not
  // decoration.
  // -------------------------------------------------------------------------
  localparam logic [REGMAP_ADDR_W-1:0] REGMAP_COEFF_BASE = 16'h5000;
  localparam int unsigned REGMAP_COEFF_SIZE = 4096;
  localparam int unsigned REGMAP_COEFF_N_REGS = 4;
  localparam int unsigned REGMAP_COEFF_INDEX = 5;  // fabric port index

  // COEFF_CTRL @ 0x5000 (MIXED)
  //   Bank selection and the swap request. BANK_SEL names the bank a COEFF_DATA write
  //   targets; it is NOT the active bank, which changes only at a frame boundary and is
  //   reported by COEFF_STATUS.ACTIVE_BANK.
  //   [0:0] BANK_SEL (RW)
  //       Target bank for coefficient writes. Resets to 1 because the active bank
  //       resets to 0, so the reset state is already a legal programming state and
  //       software can write without reading anything first.
  //   [8:8] SWAP_REQ (RWP)
  //       Writing 1 requests a bank swap. The swap happens at the next start-of-frame
  //       beat, not here; poll COEFF_STATUS.SWAP_PENDING to watch it retire. Refused,
  //       and flagged in SWAP_OVERRUN, while SWAP_BUSY is set.
  //   [9:9] STATUS_CLEAR (RWP)
  //       Writing 1 clears the sticky COEFF_STATUS.WR_REJECT and
  //       COEFF_STATUS.SWAP_OVERRUN bits.
  localparam int unsigned REGMAP_COEFF_COEFF_CTRL_INDEX = 0;
  localparam logic [REGMAP_ADDR_W-1:0] REGMAP_COEFF_COEFF_CTRL_ADDR = 16'h5000;
  localparam int unsigned REGMAP_COEFF_COEFF_CTRL_BANK_SEL_LSB = 0;
  localparam int unsigned REGMAP_COEFF_COEFF_CTRL_BANK_SEL_WIDTH = 1;
  localparam logic [31:0] REGMAP_COEFF_COEFF_CTRL_BANK_SEL_MASK = 32'h00000001;
  localparam int unsigned REGMAP_COEFF_COEFF_CTRL_SWAP_REQ_LSB = 8;
  localparam int unsigned REGMAP_COEFF_COEFF_CTRL_SWAP_REQ_WIDTH = 1;
  localparam logic [31:0] REGMAP_COEFF_COEFF_CTRL_SWAP_REQ_MASK = 32'h00000100;
  localparam int unsigned REGMAP_COEFF_COEFF_CTRL_STATUS_CLEAR_LSB = 9;
  localparam int unsigned REGMAP_COEFF_COEFF_CTRL_STATUS_CLEAR_WIDTH = 1;
  localparam logic [31:0] REGMAP_COEFF_COEFF_CTRL_STATUS_CLEAR_MASK = 32'h00000200;

  // COEFF_ADDR @ 0x5004 (RW)
  //   Coefficient index within the selected bank, phase-major and tap-minor: index =
  //   phase*PFB_TAPS + tap (pfb_pkg::pfb_coeff_index). That is the order
  //   scripts/generate_coefficients.py writes its files in, so a bank is loaded by
  //   counting up from zero.
  //   [15:0] INDEX (RW)
  //       Coefficient index. 16 bits covers 8 phases x 16 taps across 16 antennas with
  //       room to spare; an index beyond the elaborated bank is dropped and raises
  //       WR_REJECT.
  //   [31:31] AUTO_INC (RW)
  //       When 1, the LIVE index advances by one after every accepted COEFF_DATA write,
  //       so a whole bank is loaded by writing COEFF_ADDR once and COEFF_DATA
  //       repeatedly. Note that INDEX above reads back the last value SOFTWARE wrote,
  //       not the live index: reg_csr_block has no hardware-write path into an RW
  //       field, and giving it one would hand every RW register in the design a side
  //       channel. The live index lives in rtl/control/reg_block_coeff.sv, is reloaded
  //       by any COEFF_ADDR write, and is what a transfer carries.
  localparam int unsigned REGMAP_COEFF_COEFF_ADDR_INDEX = 1;
  localparam logic [REGMAP_ADDR_W-1:0] REGMAP_COEFF_COEFF_ADDR_ADDR = 16'h5004;
  localparam int unsigned REGMAP_COEFF_COEFF_ADDR_INDEX_LSB = 0;
  localparam int unsigned REGMAP_COEFF_COEFF_ADDR_INDEX_WIDTH = 16;
  localparam logic [31:0] REGMAP_COEFF_COEFF_ADDR_INDEX_MASK = 32'h0000FFFF;
  localparam int unsigned REGMAP_COEFF_COEFF_ADDR_AUTO_INC_LSB = 31;
  localparam int unsigned REGMAP_COEFF_COEFF_ADDR_AUTO_INC_WIDTH = 1;
  localparam logic [31:0] REGMAP_COEFF_COEFF_ADDR_AUTO_INC_MASK = 32'h80000000;

  // COEFF_DATA @ 0x5008 (RW)
  //   One complex Q1.15 coefficient, packed {IM, RE} with the real part in the low half
  //   - the same layout as fxp_pkg::fxp_complex_t and the coefficient files. WRITING
  //   THIS REGISTER ISSUES THE TRANSFER; COEFF_CTRL and COEFF_ADDR only set it up.
  //   Refused while COEFF_STATUS.WR_BUSY is set. Reads return the last value written,
  //   not the bank contents: the bank lives in the core clock domain and a read-back
  //   path would be a second crossing for no diagnostic gain the coefficient files do
  //   not already provide.
  //   [15:0] RE (RW)
  //       Real part, Q1.15.
  //   [31:16] IM (RW)
  //       Imaginary part, Q1.15.
  localparam int unsigned REGMAP_COEFF_COEFF_DATA_INDEX = 2;
  localparam logic [REGMAP_ADDR_W-1:0] REGMAP_COEFF_COEFF_DATA_ADDR = 16'h5008;
  localparam int unsigned REGMAP_COEFF_COEFF_DATA_RE_LSB = 0;
  localparam int unsigned REGMAP_COEFF_COEFF_DATA_RE_WIDTH = 16;
  localparam logic [31:0] REGMAP_COEFF_COEFF_DATA_RE_MASK = 32'h0000FFFF;
  localparam int unsigned REGMAP_COEFF_COEFF_DATA_IM_LSB = 16;
  localparam int unsigned REGMAP_COEFF_COEFF_DATA_IM_WIDTH = 16;
  localparam logic [31:0] REGMAP_COEFF_COEFF_DATA_IM_MASK = 32'hFFFF0000;

  // COEFF_STATUS @ 0x500C (ROHW)
  //   Hardware-driven status for the coefficient plane. Every bit is synchronised out
  //   of the core clock domain, so it is a snapshot of a free-running block rather than
  //   a handshake - except the two BUSY bits, which are exactly the flow control.
  //   [0:0] ACTIVE_BANK (ROHW)
  //       The bank the datapath is filtering with. Changes only on a start-of-frame
  //       beat (SPEC 7.1), which the RTL asserts as a_coeff_swap_at_sof.
  //   [1:1] SWAP_PENDING (ROHW)
  //       A swap has been requested and is waiting for the next frame boundary.
  //   [2:2] WR_BUSY (ROHW)
  //       A coefficient write is in flight across the clock-domain crossing. A
  //       COEFF_DATA write issued while this is set is refused.
  //   [3:3] SWAP_BUSY (ROHW)
  //       A swap request is in flight across the crossing. A second SWAP_REQ while this
  //       is set is refused and sets SWAP_OVERRUN.
  //   [8:8] WR_REJECT (ROHW)
  //       Sticky: at least one coefficient write since the last completed swap targeted
  //       the ACTIVE bank, or an index outside the elaborated bank, and was dropped.
  //       Cleared by COEFF_CTRL.STATUS_CLEAR.
  //   [9:9] SWAP_OVERRUN (ROHW)
  //       Sticky: a swap request was refused because one was already in flight. Cleared
  //       by COEFF_CTRL.STATUS_CLEAR.
  //   [31:16] N_COEFF (ROHW)
  //       Coefficients per bank in the elaborated design (SAMPLES_PER_CYCLE *
  //       PFB_TAPS), reported by hardware so software can size a load without a
  //       build-time constant.
  localparam int unsigned REGMAP_COEFF_COEFF_STATUS_INDEX = 3;
  localparam logic [REGMAP_ADDR_W-1:0] REGMAP_COEFF_COEFF_STATUS_ADDR = 16'h500C;
  localparam int unsigned REGMAP_COEFF_COEFF_STATUS_ACTIVE_BANK_LSB = 0;
  localparam int unsigned REGMAP_COEFF_COEFF_STATUS_ACTIVE_BANK_WIDTH = 1;
  localparam logic [31:0] REGMAP_COEFF_COEFF_STATUS_ACTIVE_BANK_MASK = 32'h00000001;
  localparam int unsigned REGMAP_COEFF_COEFF_STATUS_SWAP_PENDING_LSB = 1;
  localparam int unsigned REGMAP_COEFF_COEFF_STATUS_SWAP_PENDING_WIDTH = 1;
  localparam logic [31:0] REGMAP_COEFF_COEFF_STATUS_SWAP_PENDING_MASK = 32'h00000002;
  localparam int unsigned REGMAP_COEFF_COEFF_STATUS_WR_BUSY_LSB = 2;
  localparam int unsigned REGMAP_COEFF_COEFF_STATUS_WR_BUSY_WIDTH = 1;
  localparam logic [31:0] REGMAP_COEFF_COEFF_STATUS_WR_BUSY_MASK = 32'h00000004;
  localparam int unsigned REGMAP_COEFF_COEFF_STATUS_SWAP_BUSY_LSB = 3;
  localparam int unsigned REGMAP_COEFF_COEFF_STATUS_SWAP_BUSY_WIDTH = 1;
  localparam logic [31:0] REGMAP_COEFF_COEFF_STATUS_SWAP_BUSY_MASK = 32'h00000008;
  localparam int unsigned REGMAP_COEFF_COEFF_STATUS_WR_REJECT_LSB = 8;
  localparam int unsigned REGMAP_COEFF_COEFF_STATUS_WR_REJECT_WIDTH = 1;
  localparam logic [31:0] REGMAP_COEFF_COEFF_STATUS_WR_REJECT_MASK = 32'h00000100;
  localparam int unsigned REGMAP_COEFF_COEFF_STATUS_SWAP_OVERRUN_LSB = 9;
  localparam int unsigned REGMAP_COEFF_COEFF_STATUS_SWAP_OVERRUN_WIDTH = 1;
  localparam logic [31:0] REGMAP_COEFF_COEFF_STATUS_SWAP_OVERRUN_MASK = 32'h00000200;
  localparam int unsigned REGMAP_COEFF_COEFF_STATUS_N_COEFF_LSB = 16;
  localparam int unsigned REGMAP_COEFF_COEFF_STATUS_N_COEFF_WIDTH = 16;
  localparam logic [31:0] REGMAP_COEFF_COEFF_STATUS_N_COEFF_MASK = 32'hFFFF0000;

  // reset value of the stored bits
  localparam logic [REGMAP_COEFF_N_REGS*32-1:0] REGMAP_COEFF_RESET = {
      32'h00000000,  // [3]
      32'h00000000,  // [2]
      32'h80000000,  // [1]
      32'h00000001  // [0]
  };
  // bits a software write may set or clear (RW)
  localparam logic [REGMAP_COEFF_N_REGS*32-1:0] REGMAP_COEFF_WMASK = {
      32'h00000000,  // [3]
      32'hFFFFFFFF,  // [2]
      32'h8000FFFF,  // [1]
      32'h00000001  // [0]
  };
  // bits cleared by writing 1, set by hardware (W1C)
  localparam logic [REGMAP_COEFF_N_REGS*32-1:0] REGMAP_COEFF_W1CMASK = {
      32'h00000000,  // [3]
      32'h00000000,  // [2]
      32'h00000000,  // [1]
      32'h00000000  // [0]
  };
  // bits that pulse for one cycle and read 0 (RWP)
  localparam logic [REGMAP_COEFF_N_REGS*32-1:0] REGMAP_COEFF_PULSEMASK = {
      32'h00000000,  // [3]
      32'h00000000,  // [2]
      32'h00000000,  // [1]
      32'h00000300  // [0]
  };
  // bits read from the hardware input, not from storage (ROHW)
  localparam logic [REGMAP_COEFF_N_REGS*32-1:0] REGMAP_COEFF_HWMASK = {
      32'hFFFF030F,  // [3]
      32'h00000000,  // [2]
      32'h00000000,  // [1]
      32'h00000000  // [0]
  };

  // -------------------------------------------------------------------------
  // Block 6: cfar — implemented
  // SPEC 9 groups: CFAR settings
  // Settings for the SPEC 7.7 one-dimensional CFAR detector over frequency bins
  // (rtl/cfar/, issue #14): the detection mode, the guard and reference cell counts on
  // each side independently, the threshold multiplier, the output mode, and the
  // detection/suppression accounting coming back the other way. EVERYTHING WRITABLE
  // HERE TAKES EFFECT AT A FRAME BOUNDARY AND ONLY THERE. rtl/cfar/cfar_core.sv latches
  // the whole window into an active copy at the admitted start-of-frame beat, so a
  // frame is always processed under exactly one geometry - which is the only way its
  // suppression count, its detection count and the alpha carried in its events mean
  // anything. CFAR_STATUS.CFG_PENDING reports that a write has not been taken yet, so
  // software watches the change retire rather than inferring it. A guard or reference
  // count above the elaborated maximum is CLAMPED to that maximum and raises
  // CFAR_FAULT.CFG_CLAMPED; out of range is defined rather than undefined, because a
  // register plane can be programmed with anything. The elaborated maxima themselves
  // are reported in CFAR_STATUS so software sizes its programming without a compiled-in
  // constant. Note that issue #16 was expected to add coherent and non-coherent
  // integration settings to this window; the SPEC 9 group 'Integration settings' is
  // implemented by the covariance window at 0x9000 (issue #13), so this window claims
  // only 'CFAR settings'.
  // -------------------------------------------------------------------------
  localparam logic [REGMAP_ADDR_W-1:0] REGMAP_CFAR_BASE = 16'h6000;
  localparam int unsigned REGMAP_CFAR_SIZE = 4096;
  localparam int unsigned REGMAP_CFAR_N_REGS = 9;
  localparam int unsigned REGMAP_CFAR_INDEX = 6;  // fabric port index

  // CFAR_CTRL @ 0x6000 (MIXED)
  //   Master controls. STATUS_CLEAR is write-1-pulse and reads back zero, because it is
  //   an event rather than a mode.
  //   [0:0] ENABLE (RW)
  //       Detection enable. Cleared, every bin is reported SUPPRESSED and no detection
  //       is raised - the same path an incomplete window takes, so there is one
  //       suppression rule and one counter rather than two. Resets to 0: a detector
  //       that powers up detecting would flood the packet network before software had
  //       configured a threshold.
  //   [5:4] MODE (RW)
  //       0: cell averaging, the noise estimate is the mean of ALL reference cells. 1:
  //       greatest-of, the noise estimate is the larger of the two one-sided means. 2
  //       and 3 are reserved; ordered-statistics CFAR needs a rank-order network rather
  //       than a sum and is not implemented (SPEC 7.7 lists it as optional).
  //       Greatest-of requires a non-zero reference count on BOTH sides; cell averaging
  //       requires only that their sum be non-zero. A mode whose reference geometry is
  //       unusable suppresses every bin and raises CFAR_FAULT.NO_REF.
  //   [8:8] OUT_MODE (RW)
  //       0: EVENTS - the output stream carries only the bins that detected, plus one
  //       end-of-frame summary per input frame. 1: DENSE - every bin is reported
  //       (detected, evaluated-and-not-detected, or suppressed) plus the same summary.
  //       DENSE is the debug and snapshot mode: it makes the whole per-bin decision
  //       observable without a second data path, at the cost of one output beat per
  //       bin.
  //   [16:16] STATUS_CLEAR (RWP)
  //       Writing 1 clears the sticky CFAR_FAULT bits and zeroes CFAR_DET_COUNT,
  //       CFAR_SUP_COUNT and CFAR_FRAME_COUNT. A fault raised in the same cycle as the
  //       clear survives it, which is what stops a read-then-clear from losing an
  //       event.
  localparam int unsigned REGMAP_CFAR_CFAR_CTRL_INDEX = 0;
  localparam logic [REGMAP_ADDR_W-1:0] REGMAP_CFAR_CFAR_CTRL_ADDR = 16'h6000;
  localparam int unsigned REGMAP_CFAR_CFAR_CTRL_ENABLE_LSB = 0;
  localparam int unsigned REGMAP_CFAR_CFAR_CTRL_ENABLE_WIDTH = 1;
  localparam logic [31:0] REGMAP_CFAR_CFAR_CTRL_ENABLE_MASK = 32'h00000001;
  localparam int unsigned REGMAP_CFAR_CFAR_CTRL_MODE_LSB = 4;
  localparam int unsigned REGMAP_CFAR_CFAR_CTRL_MODE_WIDTH = 2;
  localparam logic [31:0] REGMAP_CFAR_CFAR_CTRL_MODE_MASK = 32'h00000030;
  localparam int unsigned REGMAP_CFAR_CFAR_CTRL_OUT_MODE_LSB = 8;
  localparam int unsigned REGMAP_CFAR_CFAR_CTRL_OUT_MODE_WIDTH = 1;
  localparam logic [31:0] REGMAP_CFAR_CFAR_CTRL_OUT_MODE_MASK = 32'h00000100;
  localparam int unsigned REGMAP_CFAR_CFAR_CTRL_STATUS_CLEAR_LSB = 16;
  localparam int unsigned REGMAP_CFAR_CFAR_CTRL_STATUS_CLEAR_WIDTH = 1;
  localparam logic [31:0] REGMAP_CFAR_CFAR_CTRL_STATUS_CLEAR_MASK = 32'h00010000;

  // CFAR_WINDOW @ 0x6004 (RW)
  //   Guard and reference cell counts, LEADING (higher frequency) and LAGGING (lower
  //   frequency) sides independently. The reference cells of a side start immediately
  //   beyond that side's guard cells. The first and last (guard + reference) bins of
  //   every frame have an incomplete window and are suppressed, which at a 64-bin frame
  //   with 2 guard and 8 reference cells is 20 of 64 bins - the reason these are
  //   runtime registers rather than compile-time constants.
  //   [4:0] GUARD_LEAD (RW)
  //       Guard cells between the cell under test and the leading reference band. Zero
  //       is legal and means the reference cells start in the adjacent bin.
  //   [12:8] GUARD_LAG (RW)
  //       Guard cells on the lagging side.
  //   [21:16] REF_LEAD (RW)
  //       Leading reference cells. Zero is legal in cell-averaging mode (a one-sided
  //       estimator) and is not in greatest-of mode.
  //   [29:24] REF_LAG (RW)
  //       Lagging reference cells.
  localparam int unsigned REGMAP_CFAR_CFAR_WINDOW_INDEX = 1;
  localparam logic [REGMAP_ADDR_W-1:0] REGMAP_CFAR_CFAR_WINDOW_ADDR = 16'h6004;
  localparam int unsigned REGMAP_CFAR_CFAR_WINDOW_GUARD_LEAD_LSB = 0;
  localparam int unsigned REGMAP_CFAR_CFAR_WINDOW_GUARD_LEAD_WIDTH = 5;
  localparam logic [31:0] REGMAP_CFAR_CFAR_WINDOW_GUARD_LEAD_MASK = 32'h0000001F;
  localparam int unsigned REGMAP_CFAR_CFAR_WINDOW_GUARD_LAG_LSB = 8;
  localparam int unsigned REGMAP_CFAR_CFAR_WINDOW_GUARD_LAG_WIDTH = 5;
  localparam logic [31:0] REGMAP_CFAR_CFAR_WINDOW_GUARD_LAG_MASK = 32'h00001F00;
  localparam int unsigned REGMAP_CFAR_CFAR_WINDOW_REF_LEAD_LSB = 16;
  localparam int unsigned REGMAP_CFAR_CFAR_WINDOW_REF_LEAD_WIDTH = 6;
  localparam logic [31:0] REGMAP_CFAR_CFAR_WINDOW_REF_LEAD_MASK = 32'h003F0000;
  localparam int unsigned REGMAP_CFAR_CFAR_WINDOW_REF_LAG_LSB = 24;
  localparam int unsigned REGMAP_CFAR_CFAR_WINDOW_REF_LAG_WIDTH = 6;
  localparam logic [31:0] REGMAP_CFAR_CFAR_WINDOW_REF_LAG_MASK = 32'h3F000000;

  // CFAR_THRESHOLD @ 0x6008 (RW)
  //   The programmable threshold multiplier (SPEC 7.7). A bin detects when its power
  //   strictly exceeds ALPHA times the mean of its reference cells; the detector never
  //   divides, comparing cell*N*2^F against ALPHA*sum instead, so the decision is an
  //   exact integer inequality with no rounding and no tolerance.
  //   [15:0] ALPHA (RW)
  //       Threshold multiplier in UNSIGNED Q8.8: 8 integer bits and 8 fractional bits,
  //       covering [0, 255.996] in steps of 1/256. NOT Q1.15 - the SPEC 6 sample format
  //       cannot represent a value above 1, and the textbook cell-averaging design
  //       point alpha = N*(Pfa^(-1/N) - 1) is about 21.9 for 16 reference cells at Pfa
  //       = 1e-6. The reset value 0x1400 is exactly 20.0, close to that design point.
  //       0x0100 is exactly 1.0, at which a perfectly flat spectrum detects nothing
  //       because the comparison is strict; alpha below 1.0 is legal and is the
  //       cheapest way for a test to force detections everywhere.
  localparam int unsigned REGMAP_CFAR_CFAR_THRESHOLD_INDEX = 2;
  localparam logic [REGMAP_ADDR_W-1:0] REGMAP_CFAR_CFAR_THRESHOLD_ADDR = 16'h6008;
  localparam int unsigned REGMAP_CFAR_CFAR_THRESHOLD_ALPHA_LSB = 0;
  localparam int unsigned REGMAP_CFAR_CFAR_THRESHOLD_ALPHA_WIDTH = 16;
  localparam logic [31:0] REGMAP_CFAR_CFAR_THRESHOLD_ALPHA_MASK = 32'h0000FFFF;

  // CFAR_STATUS @ 0x600C (ROHW)
  //   Hardware-driven status. The geometry fields let software size its programming
  //   without compiled-in constants, exactly as the build-parameter block does for the
  //   rest of the design.
  //   [7:0] MAX_GUARD (ROHW)
  //       Elaborated maximum guard-cell count per side. A larger value written to
  //       CFAR_WINDOW is clamped to this.
  //   [15:8] MAX_REF (ROHW)
  //       Elaborated maximum reference-cell count per side.
  //   [23:16] ALPHA_FRAC_W (ROHW)
  //       Fractional bits in CFAR_THRESHOLD.ALPHA, so software converts a real-valued
  //       multiplier without a compiled-in scale factor.
  //   [24:24] CFG_PENDING (ROHW)
  //       The register values differ from the active copy: a write is waiting for the
  //       next frame boundary. Clears when the frame that takes it starts.
  //   [25:25] FRAME_OPEN (ROHW)
  //       A frame is in flight (being consumed, flushed, or summarised). A write issued
  //       while this is clear takes effect on the next frame with no wait.
  localparam int unsigned REGMAP_CFAR_CFAR_STATUS_INDEX = 3;
  localparam logic [REGMAP_ADDR_W-1:0] REGMAP_CFAR_CFAR_STATUS_ADDR = 16'h600C;
  localparam int unsigned REGMAP_CFAR_CFAR_STATUS_MAX_GUARD_LSB = 0;
  localparam int unsigned REGMAP_CFAR_CFAR_STATUS_MAX_GUARD_WIDTH = 8;
  localparam logic [31:0] REGMAP_CFAR_CFAR_STATUS_MAX_GUARD_MASK = 32'h000000FF;
  localparam int unsigned REGMAP_CFAR_CFAR_STATUS_MAX_REF_LSB = 8;
  localparam int unsigned REGMAP_CFAR_CFAR_STATUS_MAX_REF_WIDTH = 8;
  localparam logic [31:0] REGMAP_CFAR_CFAR_STATUS_MAX_REF_MASK = 32'h0000FF00;
  localparam int unsigned REGMAP_CFAR_CFAR_STATUS_ALPHA_FRAC_W_LSB = 16;
  localparam int unsigned REGMAP_CFAR_CFAR_STATUS_ALPHA_FRAC_W_WIDTH = 8;
  localparam logic [31:0] REGMAP_CFAR_CFAR_STATUS_ALPHA_FRAC_W_MASK = 32'h00FF0000;
  localparam int unsigned REGMAP_CFAR_CFAR_STATUS_CFG_PENDING_LSB = 24;
  localparam int unsigned REGMAP_CFAR_CFAR_STATUS_CFG_PENDING_WIDTH = 1;
  localparam logic [31:0] REGMAP_CFAR_CFAR_STATUS_CFG_PENDING_MASK = 32'h01000000;
  localparam int unsigned REGMAP_CFAR_CFAR_STATUS_FRAME_OPEN_LSB = 25;
  localparam int unsigned REGMAP_CFAR_CFAR_STATUS_FRAME_OPEN_WIDTH = 1;
  localparam logic [31:0] REGMAP_CFAR_CFAR_STATUS_FRAME_OPEN_MASK = 32'h02000000;

  // CFAR_GEOMETRY @ 0x6010 (ROHW)
  //   Widths of the detection-event format, reported by hardware so a consumer of the
  //   SPEC 7.8 packet network can parse events without a build-time header.
  //   [15:0] EVENT_W (ROHW)
  //       Total width of a packed detection event in bits. Configuration-independent by
  //       construction: every field of the event format is a constant of
  //       rtl/packages/cfar_pkg.sv, none is an elaboration parameter, because a packet
  //       format that changed with the FFT size would have to be renegotiated at every
  //       SPEC 11 size.
  //   [23:16] POWER_W (ROHW)
  //       Width of the cell-power field, which is SPEC 3 POWER_W.
  //   [31:24] SUM_W (ROHW)
  //       Width of the reference-sum field. The noise estimate is reported as the SUM
  //       and the COUNT rather than as their quotient, because the detector never
  //       divides and adding a divider to fill in a metadata field would put the only
  //       inexact operation in the block on the reporting path.
  localparam int unsigned REGMAP_CFAR_CFAR_GEOMETRY_INDEX = 4;
  localparam logic [REGMAP_ADDR_W-1:0] REGMAP_CFAR_CFAR_GEOMETRY_ADDR = 16'h6010;
  localparam int unsigned REGMAP_CFAR_CFAR_GEOMETRY_EVENT_W_LSB = 0;
  localparam int unsigned REGMAP_CFAR_CFAR_GEOMETRY_EVENT_W_WIDTH = 16;
  localparam logic [31:0] REGMAP_CFAR_CFAR_GEOMETRY_EVENT_W_MASK = 32'h0000FFFF;
  localparam int unsigned REGMAP_CFAR_CFAR_GEOMETRY_POWER_W_LSB = 16;
  localparam int unsigned REGMAP_CFAR_CFAR_GEOMETRY_POWER_W_WIDTH = 8;
  localparam logic [31:0] REGMAP_CFAR_CFAR_GEOMETRY_POWER_W_MASK = 32'h00FF0000;
  localparam int unsigned REGMAP_CFAR_CFAR_GEOMETRY_SUM_W_LSB = 24;
  localparam int unsigned REGMAP_CFAR_CFAR_GEOMETRY_SUM_W_WIDTH = 8;
  localparam logic [31:0] REGMAP_CFAR_CFAR_GEOMETRY_SUM_W_MASK = 32'hFF000000;

  // CFAR_DET_COUNT @ 0x6014 (ROHW)
  //   Detections raised since the last CFAR_CTRL.STATUS_CLEAR. Saturates at all-ones
  //   rather than wrapping: a wrapped counter can read zero on a detector that is
  //   firing continuously, which is the one reading that must never be produced.
  //   [31:0] VALUE (ROHW)
  //       Detection count.
  localparam int unsigned REGMAP_CFAR_CFAR_DET_COUNT_INDEX = 5;
  localparam logic [REGMAP_ADDR_W-1:0] REGMAP_CFAR_CFAR_DET_COUNT_ADDR = 16'h6014;
  localparam int unsigned REGMAP_CFAR_CFAR_DET_COUNT_VALUE_LSB = 0;
  localparam int unsigned REGMAP_CFAR_CFAR_DET_COUNT_VALUE_WIDTH = 32;
  localparam logic [31:0] REGMAP_CFAR_CFAR_DET_COUNT_VALUE_MASK = 32'hFFFFFFFF;

  // CFAR_SUP_COUNT @ 0x6018 (ROHW)
  //   Bins suppressed since the last CFAR_CTRL.STATUS_CLEAR: incomplete window at a
  //   frame edge, block disabled, or an unusable reference geometry. SPEC 7.7 requires
  //   suppression under invalid or incomplete windows; this is the number that makes it
  //   visible rather than silent. Saturating, for the reason CFAR_DET_COUNT is.
  //   [31:0] VALUE (ROHW)
  //       Suppressed-bin count.
  localparam int unsigned REGMAP_CFAR_CFAR_SUP_COUNT_INDEX = 6;
  localparam logic [REGMAP_ADDR_W-1:0] REGMAP_CFAR_CFAR_SUP_COUNT_ADDR = 16'h6018;
  localparam int unsigned REGMAP_CFAR_CFAR_SUP_COUNT_VALUE_LSB = 0;
  localparam int unsigned REGMAP_CFAR_CFAR_SUP_COUNT_VALUE_WIDTH = 32;
  localparam logic [31:0] REGMAP_CFAR_CFAR_SUP_COUNT_VALUE_MASK = 32'hFFFFFFFF;

  // CFAR_FAULT @ 0x601C (W1C)
  //   Sticky fault bits, write 1 to clear; also cleared by CFAR_CTRL.STATUS_CLEAR.
  //   Every one of these is a condition the detector handles deterministically rather
  //   than a condition it fails on - the bit exists so that the handling is visible
  //   instead of plausible.
  //   [0:0] CFG_CLAMPED (W1C)
  //       A guard or reference count written above the elaborated maximum was clamped
  //       to it when the frame latched.
  //   [1:1] NEG_INPUT (W1C)
  //       An input cell arrived with its sign bit set. A negative integrated power is
  //       not physical; it is clamped to zero so that every width downstream is an
  //       honest magnitude, and flagged here because it can only be an upstream defect
  //       or a cross-power stream wired to the detector by mistake.
  //   [2:2] ORPHAN_BEAT (W1C)
  //       A beat arrived between frames without start_of_frame. It has no defined bin
  //       index, so it is consumed and discarded rather than stalled: a stalled
  //       detector backs pressure into the FFT.
  //   [3:3] SOF_IN_FRAME (W1C)
  //       start_of_frame was asserted on a beat that is not a frame's first. The bit is
  //       IGNORED and the beat is treated as an ordinary bin; the source is violating
  //       SPEC 5.
  //   [4:4] NO_REF (W1C)
  //       A frame ran with a reference geometry the selected mode cannot use - zero
  //       reference cells in cell-averaging mode, or a zero count on either side in
  //       greatest-of mode. Every bin of that frame is suppressed.
  //   [5:5] BIN_OVERFLOW (W1C)
  //       A frame ran past 65535 bins, so the bin index saturated rather than wrapping.
  //       A wrapped index would put two different frequencies in one detection event.
  localparam int unsigned REGMAP_CFAR_CFAR_FAULT_INDEX = 7;
  localparam logic [REGMAP_ADDR_W-1:0] REGMAP_CFAR_CFAR_FAULT_ADDR = 16'h601C;
  localparam int unsigned REGMAP_CFAR_CFAR_FAULT_CFG_CLAMPED_LSB = 0;
  localparam int unsigned REGMAP_CFAR_CFAR_FAULT_CFG_CLAMPED_WIDTH = 1;
  localparam logic [31:0] REGMAP_CFAR_CFAR_FAULT_CFG_CLAMPED_MASK = 32'h00000001;
  localparam int unsigned REGMAP_CFAR_CFAR_FAULT_NEG_INPUT_LSB = 1;
  localparam int unsigned REGMAP_CFAR_CFAR_FAULT_NEG_INPUT_WIDTH = 1;
  localparam logic [31:0] REGMAP_CFAR_CFAR_FAULT_NEG_INPUT_MASK = 32'h00000002;
  localparam int unsigned REGMAP_CFAR_CFAR_FAULT_ORPHAN_BEAT_LSB = 2;
  localparam int unsigned REGMAP_CFAR_CFAR_FAULT_ORPHAN_BEAT_WIDTH = 1;
  localparam logic [31:0] REGMAP_CFAR_CFAR_FAULT_ORPHAN_BEAT_MASK = 32'h00000004;
  localparam int unsigned REGMAP_CFAR_CFAR_FAULT_SOF_IN_FRAME_LSB = 3;
  localparam int unsigned REGMAP_CFAR_CFAR_FAULT_SOF_IN_FRAME_WIDTH = 1;
  localparam logic [31:0] REGMAP_CFAR_CFAR_FAULT_SOF_IN_FRAME_MASK = 32'h00000008;
  localparam int unsigned REGMAP_CFAR_CFAR_FAULT_NO_REF_LSB = 4;
  localparam int unsigned REGMAP_CFAR_CFAR_FAULT_NO_REF_WIDTH = 1;
  localparam logic [31:0] REGMAP_CFAR_CFAR_FAULT_NO_REF_MASK = 32'h00000010;
  localparam int unsigned REGMAP_CFAR_CFAR_FAULT_BIN_OVERFLOW_LSB = 5;
  localparam int unsigned REGMAP_CFAR_CFAR_FAULT_BIN_OVERFLOW_WIDTH = 1;
  localparam logic [31:0] REGMAP_CFAR_CFAR_FAULT_BIN_OVERFLOW_MASK = 32'h00000020;

  // CFAR_FRAME_COUNT @ 0x6020 (ROHW)
  //   Frames summarised since the last CFAR_CTRL.STATUS_CLEAR. Exactly one summary
  //   event is emitted per input frame, so this counter and the number of end_of_frame
  //   beats on the detection stream are the same number - which is what lets a consumer
  //   detect a lost output frame.
  //   [31:0] VALUE (ROHW)
  //       Summarised-frame count.
  localparam int unsigned REGMAP_CFAR_CFAR_FRAME_COUNT_INDEX = 8;
  localparam logic [REGMAP_ADDR_W-1:0] REGMAP_CFAR_CFAR_FRAME_COUNT_ADDR = 16'h6020;
  localparam int unsigned REGMAP_CFAR_CFAR_FRAME_COUNT_VALUE_LSB = 0;
  localparam int unsigned REGMAP_CFAR_CFAR_FRAME_COUNT_VALUE_WIDTH = 32;
  localparam logic [31:0] REGMAP_CFAR_CFAR_FRAME_COUNT_VALUE_MASK = 32'hFFFFFFFF;

  // reset value of the stored bits
  localparam logic [REGMAP_CFAR_N_REGS*32-1:0] REGMAP_CFAR_RESET = {
      32'h00000000,  // [8]
      32'h00000000,  // [7]
      32'h00000000,  // [6]
      32'h00000000,  // [5]
      32'h00000000,  // [4]
      32'h00000000,  // [3]
      32'h00001400,  // [2]
      32'h08080202,  // [1]
      32'h00000000  // [0]
  };
  // bits a software write may set or clear (RW)
  localparam logic [REGMAP_CFAR_N_REGS*32-1:0] REGMAP_CFAR_WMASK = {
      32'h00000000,  // [8]
      32'h00000000,  // [7]
      32'h00000000,  // [6]
      32'h00000000,  // [5]
      32'h00000000,  // [4]
      32'h00000000,  // [3]
      32'h0000FFFF,  // [2]
      32'h3F3F1F1F,  // [1]
      32'h00000131  // [0]
  };
  // bits cleared by writing 1, set by hardware (W1C)
  localparam logic [REGMAP_CFAR_N_REGS*32-1:0] REGMAP_CFAR_W1CMASK = {
      32'h00000000,  // [8]
      32'h0000003F,  // [7]
      32'h00000000,  // [6]
      32'h00000000,  // [5]
      32'h00000000,  // [4]
      32'h00000000,  // [3]
      32'h00000000,  // [2]
      32'h00000000,  // [1]
      32'h00000000  // [0]
  };
  // bits that pulse for one cycle and read 0 (RWP)
  localparam logic [REGMAP_CFAR_N_REGS*32-1:0] REGMAP_CFAR_PULSEMASK = {
      32'h00000000,  // [8]
      32'h00000000,  // [7]
      32'h00000000,  // [6]
      32'h00000000,  // [5]
      32'h00000000,  // [4]
      32'h00000000,  // [3]
      32'h00000000,  // [2]
      32'h00000000,  // [1]
      32'h00010000  // [0]
  };
  // bits read from the hardware input, not from storage (ROHW)
  localparam logic [REGMAP_CFAR_N_REGS*32-1:0] REGMAP_CFAR_HWMASK = {
      32'hFFFFFFFF,  // [8]
      32'h00000000,  // [7]
      32'hFFFFFFFF,  // [6]
      32'hFFFFFFFF,  // [5]
      32'hFFFFFFFF,  // [4]
      32'h03FFFFFF,  // [3]
      32'h00000000,  // [2]
      32'h00000000,  // [1]
      32'h00000000  // [0]
  };

  // -------------------------------------------------------------------------
  // Block 7: counters — implemented
  // SPEC 9 groups: Stream counters; Stall counters; FIFO high-water marks; Overflow and saturation counts; Frame counts; Sequence errors; CDC errors; Snapshot and debug control
  // Performance and health telemetry for one observed interface
  // (rtl/common/telemetry_block.sv, issue #8). EVERY COUNT REGISTER IN THIS BLOCK READS
  // A SHADOW, NOT A RUNNING COUNTER: write TELEM_CTRL.SNAPSHOT, then read as many
  // registers as you like, and all of them describe the single edge at which that
  // strobe landed. A running counter read through a 32-bit plane cannot be coherent -
  // the low word of a 64-bit beat count can wrap between the two accesses and report a
  // number that never existed - so the plane is never given the chance. SNAPSHOT_ID is
  // the proof: read it before and after a sweep, and equal values mean the sweep saw
  // one instant. The block is instantiated in the domain of the interface it observes,
  // and the register interface, not the counters, is what crosses into cfg_clk when the
  // two differ (issue #19): crossing one bus once is cheaper and far easier to verify
  // than crossing twenty counters.
  // -------------------------------------------------------------------------
  localparam logic [REGMAP_ADDR_W-1:0] REGMAP_COUNTERS_BASE = 16'h7000;
  localparam int unsigned REGMAP_COUNTERS_SIZE = 4096;
  localparam int unsigned REGMAP_COUNTERS_N_REGS = 21;
  localparam int unsigned REGMAP_COUNTERS_INDEX = 7;  // fabric port index

  // TELEM_CTRL @ 0x7000 (MIXED)
  //   Measurement window and the three strobes. ENABLE gates every counter, so a window
  //   can be opened and closed without touching the traffic being measured. SNAPSHOT,
  //   CLEAR and STICKY_CLEAR are write-1-pulse and always read 0.
  //   [0:0] ENABLE (RW)
  //       Counters advance only while this is 1. Reset to 1 so a design that never
  //       touches the control plane still measures itself.
  //   [1:1] SEQ_ENABLE (RW)
  //       Enables the sequence checker. Clearing it drops every stream's expectation,
  //       so the first beat after it is set again re-initialises instead of reporting a
  //       loss.
  //   [2:2] SEQ_SOF_RESYNC (RW)
  //       Treat start_of_frame as a sequence resync point. Correct for a source that
  //       restarts numbering each frame; masks real loss at every frame boundary for
  //       one that does not, hence off by default.
  //   [8:8] SNAPSHOT (RWP)
  //       Latch every counter in this block, and the sequence checker's five, into
  //       their shadows at one edge. The shadow includes any event in the strobe cycle.
  //   [9:9] CLEAR (RWP)
  //       Zero every counter, every shadow, the high-water mark and the shadow-valid
  //       flag. Beats a simultaneous event.
  //   [10:10] STICKY_CLEAR (RWP)
  //       Clear the sequence checker's sticky flags. Does not touch the counts, and a
  //       fault detected in the same cycle still sets them.
  localparam int unsigned REGMAP_COUNTERS_TELEM_CTRL_INDEX = 0;
  localparam logic [REGMAP_ADDR_W-1:0] REGMAP_COUNTERS_TELEM_CTRL_ADDR = 16'h7000;
  localparam int unsigned REGMAP_COUNTERS_TELEM_CTRL_ENABLE_LSB = 0;
  localparam int unsigned REGMAP_COUNTERS_TELEM_CTRL_ENABLE_WIDTH = 1;
  localparam logic [31:0] REGMAP_COUNTERS_TELEM_CTRL_ENABLE_MASK = 32'h00000001;
  localparam int unsigned REGMAP_COUNTERS_TELEM_CTRL_SEQ_ENABLE_LSB = 1;
  localparam int unsigned REGMAP_COUNTERS_TELEM_CTRL_SEQ_ENABLE_WIDTH = 1;
  localparam logic [31:0] REGMAP_COUNTERS_TELEM_CTRL_SEQ_ENABLE_MASK = 32'h00000002;
  localparam int unsigned REGMAP_COUNTERS_TELEM_CTRL_SEQ_SOF_RESYNC_LSB = 2;
  localparam int unsigned REGMAP_COUNTERS_TELEM_CTRL_SEQ_SOF_RESYNC_WIDTH = 1;
  localparam logic [31:0] REGMAP_COUNTERS_TELEM_CTRL_SEQ_SOF_RESYNC_MASK = 32'h00000004;
  localparam int unsigned REGMAP_COUNTERS_TELEM_CTRL_SNAPSHOT_LSB = 8;
  localparam int unsigned REGMAP_COUNTERS_TELEM_CTRL_SNAPSHOT_WIDTH = 1;
  localparam logic [31:0] REGMAP_COUNTERS_TELEM_CTRL_SNAPSHOT_MASK = 32'h00000100;
  localparam int unsigned REGMAP_COUNTERS_TELEM_CTRL_CLEAR_LSB = 9;
  localparam int unsigned REGMAP_COUNTERS_TELEM_CTRL_CLEAR_WIDTH = 1;
  localparam logic [31:0] REGMAP_COUNTERS_TELEM_CTRL_CLEAR_MASK = 32'h00000200;
  localparam int unsigned REGMAP_COUNTERS_TELEM_CTRL_STICKY_CLEAR_LSB = 10;
  localparam int unsigned REGMAP_COUNTERS_TELEM_CTRL_STICKY_CLEAR_WIDTH = 1;
  localparam logic [31:0] REGMAP_COUNTERS_TELEM_CTRL_STICKY_CLEAR_MASK = 32'h00000400;

  // TELEM_STATUS @ 0x7004 (ROHW)
  //   Build geometry of this telemetry instance plus the two facts a reader needs
  //   before trusting a count: whether a snapshot was ever taken, and whether any
  //   counter has passed its maximum since the last clear.
  //   [7:0] COUNT_W (ROHW) <- telemetry_block COUNT_W
  //       Width in bits of the ordinary counters. Anything above it in a count register
  //       reads 0.
  //   [15:8] WIDE_W (ROHW) <- telemetry_block WIDE_W
  //       Width in bits of the beat and stall counters, which are presented as a LO/HI
  //       pair.
  //   [23:16] TRACKED_IDS (ROHW) <- telemetry_block N_TRACKED_IDS
  //       Streams the sequence checker tracks independently. Beats on a higher
  //       stream_id are counted in SEQ_UNTRACKED_COUNT rather than folded onto a
  //       tracked stream.
  //   [24:24] SNAP_VALID (ROHW)
  //       A snapshot has been taken since reset or the last CLEAR. While this is 0
  //       every count register reads 0 because nothing was captured, not because
  //       nothing happened.
  //   [25:25] TRAFFIC_SATURATE (ROHW) <- telemetry_block TRAFFIC_SATURATE
  //       0: the traffic counters are exact modulo 2**width and set a WRAP_STATUS bit
  //       when they roll. 1: they stop at all ones.
  //   [26:26] ERROR_SATURATE (ROHW) <- telemetry_block ERROR_SATURATE
  //       The same, for the error and fault counters. 1 by default: a dump taken after
  //       a long run must not report a small number because the counter went round.
  //   [27:27] WRAP_ANY (ROHW)
  //       Sticky OR of every counter's own range flag. A quick 'are these numbers still
  //       absolute' test that does not need WRAP_STATUS decoded.
  localparam int unsigned REGMAP_COUNTERS_TELEM_STATUS_INDEX = 1;
  localparam logic [REGMAP_ADDR_W-1:0] REGMAP_COUNTERS_TELEM_STATUS_ADDR = 16'h7004;
  localparam int unsigned REGMAP_COUNTERS_TELEM_STATUS_COUNT_W_LSB = 0;
  localparam int unsigned REGMAP_COUNTERS_TELEM_STATUS_COUNT_W_WIDTH = 8;
  localparam logic [31:0] REGMAP_COUNTERS_TELEM_STATUS_COUNT_W_MASK = 32'h000000FF;
  localparam int unsigned REGMAP_COUNTERS_TELEM_STATUS_WIDE_W_LSB = 8;
  localparam int unsigned REGMAP_COUNTERS_TELEM_STATUS_WIDE_W_WIDTH = 8;
  localparam logic [31:0] REGMAP_COUNTERS_TELEM_STATUS_WIDE_W_MASK = 32'h0000FF00;
  localparam int unsigned REGMAP_COUNTERS_TELEM_STATUS_TRACKED_IDS_LSB = 16;
  localparam int unsigned REGMAP_COUNTERS_TELEM_STATUS_TRACKED_IDS_WIDTH = 8;
  localparam logic [31:0] REGMAP_COUNTERS_TELEM_STATUS_TRACKED_IDS_MASK = 32'h00FF0000;
  localparam int unsigned REGMAP_COUNTERS_TELEM_STATUS_SNAP_VALID_LSB = 24;
  localparam int unsigned REGMAP_COUNTERS_TELEM_STATUS_SNAP_VALID_WIDTH = 1;
  localparam logic [31:0] REGMAP_COUNTERS_TELEM_STATUS_SNAP_VALID_MASK = 32'h01000000;
  localparam int unsigned REGMAP_COUNTERS_TELEM_STATUS_TRAFFIC_SATURATE_LSB = 25;
  localparam int unsigned REGMAP_COUNTERS_TELEM_STATUS_TRAFFIC_SATURATE_WIDTH = 1;
  localparam logic [31:0] REGMAP_COUNTERS_TELEM_STATUS_TRAFFIC_SATURATE_MASK = 32'h02000000;
  localparam int unsigned REGMAP_COUNTERS_TELEM_STATUS_ERROR_SATURATE_LSB = 26;
  localparam int unsigned REGMAP_COUNTERS_TELEM_STATUS_ERROR_SATURATE_WIDTH = 1;
  localparam logic [31:0] REGMAP_COUNTERS_TELEM_STATUS_ERROR_SATURATE_MASK = 32'h04000000;
  localparam int unsigned REGMAP_COUNTERS_TELEM_STATUS_WRAP_ANY_LSB = 27;
  localparam int unsigned REGMAP_COUNTERS_TELEM_STATUS_WRAP_ANY_WIDTH = 1;
  localparam logic [31:0] REGMAP_COUNTERS_TELEM_STATUS_WRAP_ANY_MASK = 32'h08000000;

  // SNAPSHOT_ID @ 0x7008 (ROHW)
  //   Snapshots taken since reset or the last CLEAR, saturating. Read it before and
  //   after a sweep of this block: if the two agree, every register in between came
  //   from one edge. This is the only defence against a second agent snapshotting in
  //   the middle of someone else's read sequence, and it costs one register.
  //   [31:0] VALUE (ROHW)
  //       Count of SNAPSHOT strobes.
  localparam int unsigned REGMAP_COUNTERS_SNAPSHOT_ID_INDEX = 2;
  localparam logic [REGMAP_ADDR_W-1:0] REGMAP_COUNTERS_SNAPSHOT_ID_ADDR = 16'h7008;
  localparam int unsigned REGMAP_COUNTERS_SNAPSHOT_ID_VALUE_LSB = 0;
  localparam int unsigned REGMAP_COUNTERS_SNAPSHOT_ID_VALUE_WIDTH = 32;
  localparam logic [31:0] REGMAP_COUNTERS_SNAPSHOT_ID_VALUE_MASK = 32'hFFFFFFFF;

  // BEAT_COUNT_LO @ 0x700C (ROHW)
  //   SPEC 9 stream counters. Low half of the accepted-transfer count on the observed
  //   interface: cycles in which valid && ready. Read together with BEAT_COUNT_HI after
  //   one SNAPSHOT; the pair is coherent because both halves come from one shadow.
  //   [31:0] VALUE (ROHW)
  //       Bits 31:0 of the beat count.
  localparam int unsigned REGMAP_COUNTERS_BEAT_COUNT_LO_INDEX = 3;
  localparam logic [REGMAP_ADDR_W-1:0] REGMAP_COUNTERS_BEAT_COUNT_LO_ADDR = 16'h700C;
  localparam int unsigned REGMAP_COUNTERS_BEAT_COUNT_LO_VALUE_LSB = 0;
  localparam int unsigned REGMAP_COUNTERS_BEAT_COUNT_LO_VALUE_WIDTH = 32;
  localparam logic [31:0] REGMAP_COUNTERS_BEAT_COUNT_LO_VALUE_MASK = 32'hFFFFFFFF;

  // BEAT_COUNT_HI @ 0x7010 (ROHW)
  //   High half of the accepted-transfer count. Reads 0 when WIDE_W is 32 or less.
  //   [31:0] VALUE (ROHW)
  //       Bits 63:32 of the beat count.
  localparam int unsigned REGMAP_COUNTERS_BEAT_COUNT_HI_INDEX = 4;
  localparam logic [REGMAP_ADDR_W-1:0] REGMAP_COUNTERS_BEAT_COUNT_HI_ADDR = 16'h7010;
  localparam int unsigned REGMAP_COUNTERS_BEAT_COUNT_HI_VALUE_LSB = 0;
  localparam int unsigned REGMAP_COUNTERS_BEAT_COUNT_HI_VALUE_WIDTH = 32;
  localparam logic [31:0] REGMAP_COUNTERS_BEAT_COUNT_HI_VALUE_MASK = 32'hFFFFFFFF;

  // STALL_COUNT_LO @ 0x7014 (ROHW)
  //   SPEC 9 stall counters. Low half of the count of cycles in which the source
  //   offered a beat and the sink refused it: valid && !ready. Divided by the beat
  //   count this is the backpressure the interface actually suffered, which is the
  //   number that decides whether a stage needs more buffering.
  //   [31:0] VALUE (ROHW)
  //       Bits 31:0 of the stall count.
  localparam int unsigned REGMAP_COUNTERS_STALL_COUNT_LO_INDEX = 5;
  localparam logic [REGMAP_ADDR_W-1:0] REGMAP_COUNTERS_STALL_COUNT_LO_ADDR = 16'h7014;
  localparam int unsigned REGMAP_COUNTERS_STALL_COUNT_LO_VALUE_LSB = 0;
  localparam int unsigned REGMAP_COUNTERS_STALL_COUNT_LO_VALUE_WIDTH = 32;
  localparam logic [31:0] REGMAP_COUNTERS_STALL_COUNT_LO_VALUE_MASK = 32'hFFFFFFFF;

  // STALL_COUNT_HI @ 0x7018 (ROHW)
  //   High half of the stall count.
  //   [31:0] VALUE (ROHW)
  //       Bits 63:32 of the stall count.
  localparam int unsigned REGMAP_COUNTERS_STALL_COUNT_HI_INDEX = 6;
  localparam logic [REGMAP_ADDR_W-1:0] REGMAP_COUNTERS_STALL_COUNT_HI_ADDR = 16'h7018;
  localparam int unsigned REGMAP_COUNTERS_STALL_COUNT_HI_VALUE_LSB = 0;
  localparam int unsigned REGMAP_COUNTERS_STALL_COUNT_HI_VALUE_WIDTH = 32;
  localparam logic [31:0] REGMAP_COUNTERS_STALL_COUNT_HI_VALUE_MASK = 32'hFFFFFFFF;

  // IDLE_COUNT @ 0x701C (ROHW)
  //   Cycles in which the sink was ready and the source had nothing: !valid && ready.
  //   The third arm of the three-way split of a ready cycle - beat, stall, idle - so a
  //   starved stage is distinguishable from a stalled one rather than both appearing as
  //   'not full throughput'.
  //   [31:0] VALUE (ROHW)
  //       Count of starved cycles.
  localparam int unsigned REGMAP_COUNTERS_IDLE_COUNT_INDEX = 7;
  localparam logic [REGMAP_ADDR_W-1:0] REGMAP_COUNTERS_IDLE_COUNT_ADDR = 16'h701C;
  localparam int unsigned REGMAP_COUNTERS_IDLE_COUNT_VALUE_LSB = 0;
  localparam int unsigned REGMAP_COUNTERS_IDLE_COUNT_VALUE_WIDTH = 32;
  localparam logic [31:0] REGMAP_COUNTERS_IDLE_COUNT_VALUE_MASK = 32'hFFFFFFFF;

  // FRAME_COUNT @ 0x7020 (ROHW)
  //   SPEC 9 frame counts. Accepted beats carrying end_of_frame, i.e. frames completed
  //   on the observed interface.
  //   [31:0] VALUE (ROHW)
  //       Frames completed.
  localparam int unsigned REGMAP_COUNTERS_FRAME_COUNT_INDEX = 8;
  localparam logic [REGMAP_ADDR_W-1:0] REGMAP_COUNTERS_FRAME_COUNT_ADDR = 16'h7020;
  localparam int unsigned REGMAP_COUNTERS_FRAME_COUNT_VALUE_LSB = 0;
  localparam int unsigned REGMAP_COUNTERS_FRAME_COUNT_VALUE_WIDTH = 32;
  localparam logic [31:0] REGMAP_COUNTERS_FRAME_COUNT_VALUE_MASK = 32'hFFFFFFFF;

  // FRAME_START_COUNT @ 0x7024 (ROHW)
  //   Accepted beats carrying start_of_frame. Counted separately from FRAME_COUNT
  //   because the difference between the two is the frame that was opened and never
  //   closed, which is exactly the symptom of a truncated frame and is invisible in
  //   either count alone.
  //   [31:0] VALUE (ROHW)
  //       Frames started.
  localparam int unsigned REGMAP_COUNTERS_FRAME_START_COUNT_INDEX = 9;
  localparam logic [REGMAP_ADDR_W-1:0] REGMAP_COUNTERS_FRAME_START_COUNT_ADDR = 16'h7024;
  localparam int unsigned REGMAP_COUNTERS_FRAME_START_COUNT_VALUE_LSB = 0;
  localparam int unsigned REGMAP_COUNTERS_FRAME_START_COUNT_VALUE_WIDTH = 32;
  localparam logic [31:0] REGMAP_COUNTERS_FRAME_START_COUNT_VALUE_MASK = 32'hFFFFFFFF;

  // FIFO_HIGH_WATER @ 0x7028 (ROHW)
  //   SPEC 9 FIFO high-water marks. The deepest fill level the observed FIFO reached in
  //   the measurement window, beside the depth it was built with, so the margin is
  //   readable without knowing the elaboration parameters. This is the number that
  //   sizes the next revision of a DEPTH.
  //   [15:0] HIGH (ROHW)
  //       Maximum fill level since reset or the last CLEAR.
  //   [31:16] DEPTH (ROHW) <- telemetry_block FIFO_DEPTH
  //       Depth the observed FIFO was elaborated with. HIGH equal to DEPTH means it
  //       filled.
  localparam int unsigned REGMAP_COUNTERS_FIFO_HIGH_WATER_INDEX = 10;
  localparam logic [REGMAP_ADDR_W-1:0] REGMAP_COUNTERS_FIFO_HIGH_WATER_ADDR = 16'h7028;
  localparam int unsigned REGMAP_COUNTERS_FIFO_HIGH_WATER_HIGH_LSB = 0;
  localparam int unsigned REGMAP_COUNTERS_FIFO_HIGH_WATER_HIGH_WIDTH = 16;
  localparam logic [31:0] REGMAP_COUNTERS_FIFO_HIGH_WATER_HIGH_MASK = 32'h0000FFFF;
  localparam int unsigned REGMAP_COUNTERS_FIFO_HIGH_WATER_DEPTH_LSB = 16;
  localparam int unsigned REGMAP_COUNTERS_FIFO_HIGH_WATER_DEPTH_WIDTH = 16;
  localparam logic [31:0] REGMAP_COUNTERS_FIFO_HIGH_WATER_DEPTH_MASK = 32'hFFFF0000;

  // OVERFLOW_COUNT @ 0x702C (ROHW)
  //   SPEC 9 overflow counts. Overflow events reported by the observed storage.
  //   Unreachable in correct operation, so any non-zero value here is a design defect
  //   rather than a traffic condition.
  //   [31:0] VALUE (ROHW)
  //       Overflow events.
  localparam int unsigned REGMAP_COUNTERS_OVERFLOW_COUNT_INDEX = 11;
  localparam logic [REGMAP_ADDR_W-1:0] REGMAP_COUNTERS_OVERFLOW_COUNT_ADDR = 16'h702C;
  localparam int unsigned REGMAP_COUNTERS_OVERFLOW_COUNT_VALUE_LSB = 0;
  localparam int unsigned REGMAP_COUNTERS_OVERFLOW_COUNT_VALUE_WIDTH = 32;
  localparam logic [31:0] REGMAP_COUNTERS_OVERFLOW_COUNT_VALUE_MASK = 32'hFFFFFFFF;

  // SATURATE_COUNT @ 0x7030 (ROHW)
  //   SPEC 9 saturation counts. Arithmetic saturation events reported by the observed
  //   datapath (SPEC 6 saturating arithmetic, collected by
  //   rtl/common/fxp_sticky_flags.sv). Non-zero is legal and expected on loud input; it
  //   is the number that says whether a headroom choice was right.
  //   [31:0] VALUE (ROHW)
  //       Saturation events.
  localparam int unsigned REGMAP_COUNTERS_SATURATE_COUNT_INDEX = 12;
  localparam logic [REGMAP_ADDR_W-1:0] REGMAP_COUNTERS_SATURATE_COUNT_ADDR = 16'h7030;
  localparam int unsigned REGMAP_COUNTERS_SATURATE_COUNT_VALUE_LSB = 0;
  localparam int unsigned REGMAP_COUNTERS_SATURATE_COUNT_VALUE_WIDTH = 32;
  localparam logic [31:0] REGMAP_COUNTERS_SATURATE_COUNT_VALUE_MASK = 32'hFFFFFFFF;

  // CDC_ERROR_COUNT @ 0x7034 (ROHW)
  //   SPEC 9 CDC errors. Events reported by the crossings the observed path contains -
  //   a handshake that did not complete, a Gray pointer that moved by more than one
  //   bit. Like OVERFLOW_COUNT, unreachable in correct operation.
  //   [31:0] VALUE (ROHW)
  //       CDC error events.
  localparam int unsigned REGMAP_COUNTERS_CDC_ERROR_COUNT_INDEX = 13;
  localparam logic [REGMAP_ADDR_W-1:0] REGMAP_COUNTERS_CDC_ERROR_COUNT_ADDR = 16'h7034;
  localparam int unsigned REGMAP_COUNTERS_CDC_ERROR_COUNT_VALUE_LSB = 0;
  localparam int unsigned REGMAP_COUNTERS_CDC_ERROR_COUNT_VALUE_WIDTH = 32;
  localparam logic [31:0] REGMAP_COUNTERS_CDC_ERROR_COUNT_VALUE_MASK = 32'hFFFFFFFF;

  // SEQ_GAP_COUNT @ 0x7038 (ROHW)
  //   SPEC 9 sequence errors. Gap EVENTS seen by the attached seq_checker: occasions on
  //   which the sequence number jumped forward. Counted separately from the beats lost,
  //   because one gap of forty and forty gaps of one are different failures.
  //   [31:0] VALUE (ROHW)
  //       Gap events.
  localparam int unsigned REGMAP_COUNTERS_SEQ_GAP_COUNT_INDEX = 14;
  localparam logic [REGMAP_ADDR_W-1:0] REGMAP_COUNTERS_SEQ_GAP_COUNT_ADDR = 16'h7038;
  localparam int unsigned REGMAP_COUNTERS_SEQ_GAP_COUNT_VALUE_LSB = 0;
  localparam int unsigned REGMAP_COUNTERS_SEQ_GAP_COUNT_VALUE_WIDTH = 32;
  localparam logic [31:0] REGMAP_COUNTERS_SEQ_GAP_COUNT_VALUE_MASK = 32'hFFFFFFFF;

  // SEQ_DUP_COUNT @ 0x703C (ROHW)
  //   Beats whose sequence number repeated the one immediately before it: duplication.
  //   [31:0] VALUE (ROHW)
  //       Duplicate beats.
  localparam int unsigned REGMAP_COUNTERS_SEQ_DUP_COUNT_INDEX = 15;
  localparam logic [REGMAP_ADDR_W-1:0] REGMAP_COUNTERS_SEQ_DUP_COUNT_ADDR = 16'h703C;
  localparam int unsigned REGMAP_COUNTERS_SEQ_DUP_COUNT_VALUE_LSB = 0;
  localparam int unsigned REGMAP_COUNTERS_SEQ_DUP_COUNT_VALUE_WIDTH = 32;
  localparam logic [31:0] REGMAP_COUNTERS_SEQ_DUP_COUNT_VALUE_MASK = 32'hFFFFFFFF;

  // SEQ_REORDER_COUNT @ 0x7040 (ROHW)
  //   Beats whose sequence number came from behind the current position and was not the
  //   immediately preceding one: reordering.
  //   [31:0] VALUE (ROHW)
  //       Out-of-order beats.
  localparam int unsigned REGMAP_COUNTERS_SEQ_REORDER_COUNT_INDEX = 16;
  localparam logic [REGMAP_ADDR_W-1:0] REGMAP_COUNTERS_SEQ_REORDER_COUNT_ADDR = 16'h7040;
  localparam int unsigned REGMAP_COUNTERS_SEQ_REORDER_COUNT_VALUE_LSB = 0;
  localparam int unsigned REGMAP_COUNTERS_SEQ_REORDER_COUNT_VALUE_WIDTH = 32;
  localparam logic [31:0] REGMAP_COUNTERS_SEQ_REORDER_COUNT_VALUE_MASK = 32'hFFFFFFFF;

  // SEQ_LOST_BEATS @ 0x7044 (ROHW)
  //   Beats that never arrived, summed over every gap. SEQ_GAP_COUNT says how often the
  //   stream broke; this says how much of it was lost.
  //   [31:0] VALUE (ROHW)
  //       Missing beats.
  localparam int unsigned REGMAP_COUNTERS_SEQ_LOST_BEATS_INDEX = 17;
  localparam logic [REGMAP_ADDR_W-1:0] REGMAP_COUNTERS_SEQ_LOST_BEATS_ADDR = 16'h7044;
  localparam int unsigned REGMAP_COUNTERS_SEQ_LOST_BEATS_VALUE_LSB = 0;
  localparam int unsigned REGMAP_COUNTERS_SEQ_LOST_BEATS_VALUE_WIDTH = 32;
  localparam logic [31:0] REGMAP_COUNTERS_SEQ_LOST_BEATS_VALUE_MASK = 32'hFFFFFFFF;

  // SEQ_UNTRACKED_COUNT @ 0x7048 (ROHW)
  //   Beats on a stream_id at or above TRACKED_IDS. Counted rather than ignored: an
  //   instance sized for four streams that silently dropped everything on stream 7
  //   would report a clean run on traffic it never looked at.
  //   [31:0] VALUE (ROHW)
  //       Beats on an untracked stream.
  localparam int unsigned REGMAP_COUNTERS_SEQ_UNTRACKED_COUNT_INDEX = 18;
  localparam logic [REGMAP_ADDR_W-1:0] REGMAP_COUNTERS_SEQ_UNTRACKED_COUNT_ADDR = 16'h7048;
  localparam int unsigned REGMAP_COUNTERS_SEQ_UNTRACKED_COUNT_VALUE_LSB = 0;
  localparam int unsigned REGMAP_COUNTERS_SEQ_UNTRACKED_COUNT_VALUE_WIDTH = 32;
  localparam logic [31:0] REGMAP_COUNTERS_SEQ_UNTRACKED_COUNT_VALUE_MASK = 32'hFFFFFFFF;

  // SEQ_STATUS @ 0x704C (MIXED)
  //   Sticky record of which kinds of sequence fault occurred at all, so a fault that
  //   happened once in a long run is still visible after the counts have been cleared.
  //   The W1C half is this block's own copy, cleared by writing 1; CHECKER_STICKY
  //   mirrors the checker's flags, which TELEM_CTRL.STICKY_CLEAR clears.
  //   [0:0] GAP (W1C)
  //       A gap was detected.
  //   [1:1] DUP (W1C)
  //       A duplicate was detected.
  //   [2:2] REORDER (W1C)
  //       A reordered beat was detected.
  //   [3:3] UNTRACKED (W1C)
  //       A beat arrived on an untracked stream.
  //   [11:8] CHECKER_STICKY (ROHW) <- seq_checker sticky
  //       The checker's own sticky flags, in the same bit order: untracked, reorder,
  //       dup, gap, from bit 11 down to bit 8.
  localparam int unsigned REGMAP_COUNTERS_SEQ_STATUS_INDEX = 19;
  localparam logic [REGMAP_ADDR_W-1:0] REGMAP_COUNTERS_SEQ_STATUS_ADDR = 16'h704C;
  localparam int unsigned REGMAP_COUNTERS_SEQ_STATUS_GAP_LSB = 0;
  localparam int unsigned REGMAP_COUNTERS_SEQ_STATUS_GAP_WIDTH = 1;
  localparam logic [31:0] REGMAP_COUNTERS_SEQ_STATUS_GAP_MASK = 32'h00000001;
  localparam int unsigned REGMAP_COUNTERS_SEQ_STATUS_DUP_LSB = 1;
  localparam int unsigned REGMAP_COUNTERS_SEQ_STATUS_DUP_WIDTH = 1;
  localparam logic [31:0] REGMAP_COUNTERS_SEQ_STATUS_DUP_MASK = 32'h00000002;
  localparam int unsigned REGMAP_COUNTERS_SEQ_STATUS_REORDER_LSB = 2;
  localparam int unsigned REGMAP_COUNTERS_SEQ_STATUS_REORDER_WIDTH = 1;
  localparam logic [31:0] REGMAP_COUNTERS_SEQ_STATUS_REORDER_MASK = 32'h00000004;
  localparam int unsigned REGMAP_COUNTERS_SEQ_STATUS_UNTRACKED_LSB = 3;
  localparam int unsigned REGMAP_COUNTERS_SEQ_STATUS_UNTRACKED_WIDTH = 1;
  localparam logic [31:0] REGMAP_COUNTERS_SEQ_STATUS_UNTRACKED_MASK = 32'h00000008;
  localparam int unsigned REGMAP_COUNTERS_SEQ_STATUS_CHECKER_STICKY_LSB = 8;
  localparam int unsigned REGMAP_COUNTERS_SEQ_STATUS_CHECKER_STICKY_WIDTH = 4;
  localparam logic [31:0] REGMAP_COUNTERS_SEQ_STATUS_CHECKER_STICKY_MASK = 32'h00000F00;

  // WRAP_STATUS @ 0x7050 (W1C)
  //   One sticky bit per counter, set when that counter passed its maximum. For a
  //   modulo counter this says the absolute value is no longer meaningful and only
  //   differences are; for a saturating one it says the count has stopped moving.
  //   Either way it is the difference between a number and a number that can be
  //   believed, which is why SPEC 13.4 exercises wrap deliberately.
  //   [0:0] BEAT (W1C)
  //       The beat counter passed its maximum.
  //   [1:1] STALL (W1C)
  //       The stall counter passed its maximum.
  //   [2:2] IDLE (W1C)
  //       The idle counter passed its maximum.
  //   [3:3] FRAME (W1C)
  //       The frame counter passed its maximum.
  //   [4:4] FRAME_START (W1C)
  //       The frame-start counter passed its maximum.
  //   [5:5] OVERFLOW (W1C)
  //       The overflow counter passed its maximum.
  //   [6:6] SATURATE (W1C)
  //       The saturation counter passed its maximum.
  //   [7:7] CDC_ERROR (W1C)
  //       The CDC error counter passed its maximum.
  //   [8:8] SNAPSHOT_ID (W1C)
  //       SNAPSHOT_ID rolled over. Harmless in itself - it is an identity, not a
  //       magnitude - but a reader comparing it across a sweep should know that equal
  //       values are now only overwhelmingly likely to mean the same instant rather
  //       than certain to.
  localparam int unsigned REGMAP_COUNTERS_WRAP_STATUS_INDEX = 20;
  localparam logic [REGMAP_ADDR_W-1:0] REGMAP_COUNTERS_WRAP_STATUS_ADDR = 16'h7050;
  localparam int unsigned REGMAP_COUNTERS_WRAP_STATUS_BEAT_LSB = 0;
  localparam int unsigned REGMAP_COUNTERS_WRAP_STATUS_BEAT_WIDTH = 1;
  localparam logic [31:0] REGMAP_COUNTERS_WRAP_STATUS_BEAT_MASK = 32'h00000001;
  localparam int unsigned REGMAP_COUNTERS_WRAP_STATUS_STALL_LSB = 1;
  localparam int unsigned REGMAP_COUNTERS_WRAP_STATUS_STALL_WIDTH = 1;
  localparam logic [31:0] REGMAP_COUNTERS_WRAP_STATUS_STALL_MASK = 32'h00000002;
  localparam int unsigned REGMAP_COUNTERS_WRAP_STATUS_IDLE_LSB = 2;
  localparam int unsigned REGMAP_COUNTERS_WRAP_STATUS_IDLE_WIDTH = 1;
  localparam logic [31:0] REGMAP_COUNTERS_WRAP_STATUS_IDLE_MASK = 32'h00000004;
  localparam int unsigned REGMAP_COUNTERS_WRAP_STATUS_FRAME_LSB = 3;
  localparam int unsigned REGMAP_COUNTERS_WRAP_STATUS_FRAME_WIDTH = 1;
  localparam logic [31:0] REGMAP_COUNTERS_WRAP_STATUS_FRAME_MASK = 32'h00000008;
  localparam int unsigned REGMAP_COUNTERS_WRAP_STATUS_FRAME_START_LSB = 4;
  localparam int unsigned REGMAP_COUNTERS_WRAP_STATUS_FRAME_START_WIDTH = 1;
  localparam logic [31:0] REGMAP_COUNTERS_WRAP_STATUS_FRAME_START_MASK = 32'h00000010;
  localparam int unsigned REGMAP_COUNTERS_WRAP_STATUS_OVERFLOW_LSB = 5;
  localparam int unsigned REGMAP_COUNTERS_WRAP_STATUS_OVERFLOW_WIDTH = 1;
  localparam logic [31:0] REGMAP_COUNTERS_WRAP_STATUS_OVERFLOW_MASK = 32'h00000020;
  localparam int unsigned REGMAP_COUNTERS_WRAP_STATUS_SATURATE_LSB = 6;
  localparam int unsigned REGMAP_COUNTERS_WRAP_STATUS_SATURATE_WIDTH = 1;
  localparam logic [31:0] REGMAP_COUNTERS_WRAP_STATUS_SATURATE_MASK = 32'h00000040;
  localparam int unsigned REGMAP_COUNTERS_WRAP_STATUS_CDC_ERROR_LSB = 7;
  localparam int unsigned REGMAP_COUNTERS_WRAP_STATUS_CDC_ERROR_WIDTH = 1;
  localparam logic [31:0] REGMAP_COUNTERS_WRAP_STATUS_CDC_ERROR_MASK = 32'h00000080;
  localparam int unsigned REGMAP_COUNTERS_WRAP_STATUS_SNAPSHOT_ID_LSB = 8;
  localparam int unsigned REGMAP_COUNTERS_WRAP_STATUS_SNAPSHOT_ID_WIDTH = 1;
  localparam logic [31:0] REGMAP_COUNTERS_WRAP_STATUS_SNAPSHOT_ID_MASK = 32'h00000100;

  // reset value of the stored bits
  localparam logic [REGMAP_COUNTERS_N_REGS*32-1:0] REGMAP_COUNTERS_RESET = {
      32'h00000000,  // [20]
      32'h00000000,  // [19]
      32'h00000000,  // [18]
      32'h00000000,  // [17]
      32'h00000000,  // [16]
      32'h00000000,  // [15]
      32'h00000000,  // [14]
      32'h00000000,  // [13]
      32'h00000000,  // [12]
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
      32'h00000003  // [0]
  };
  // bits a software write may set or clear (RW)
  localparam logic [REGMAP_COUNTERS_N_REGS*32-1:0] REGMAP_COUNTERS_WMASK = {
      32'h00000000,  // [20]
      32'h00000000,  // [19]
      32'h00000000,  // [18]
      32'h00000000,  // [17]
      32'h00000000,  // [16]
      32'h00000000,  // [15]
      32'h00000000,  // [14]
      32'h00000000,  // [13]
      32'h00000000,  // [12]
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
      32'h00000007  // [0]
  };
  // bits cleared by writing 1, set by hardware (W1C)
  localparam logic [REGMAP_COUNTERS_N_REGS*32-1:0] REGMAP_COUNTERS_W1CMASK = {
      32'h000001FF,  // [20]
      32'h0000000F,  // [19]
      32'h00000000,  // [18]
      32'h00000000,  // [17]
      32'h00000000,  // [16]
      32'h00000000,  // [15]
      32'h00000000,  // [14]
      32'h00000000,  // [13]
      32'h00000000,  // [12]
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
  localparam logic [REGMAP_COUNTERS_N_REGS*32-1:0] REGMAP_COUNTERS_PULSEMASK = {
      32'h00000000,  // [20]
      32'h00000000,  // [19]
      32'h00000000,  // [18]
      32'h00000000,  // [17]
      32'h00000000,  // [16]
      32'h00000000,  // [15]
      32'h00000000,  // [14]
      32'h00000000,  // [13]
      32'h00000000,  // [12]
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
      32'h00000700  // [0]
  };
  // bits read from the hardware input, not from storage (ROHW)
  localparam logic [REGMAP_COUNTERS_N_REGS*32-1:0] REGMAP_COUNTERS_HWMASK = {
      32'h00000000,  // [20]
      32'h00000F00,  // [19]
      32'hFFFFFFFF,  // [18]
      32'hFFFFFFFF,  // [17]
      32'hFFFFFFFF,  // [16]
      32'hFFFFFFFF,  // [15]
      32'hFFFFFFFF,  // [14]
      32'hFFFFFFFF,  // [13]
      32'hFFFFFFFF,  // [12]
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
      32'h0FFFFFFF,  // [1]
      32'h00000000  // [0]
  };

  // -------------------------------------------------------------------------
  // Block 8: debug — PLANNED (#19)
  // SPEC 9 groups: Snapshot and debug control
  // PLANNED. Snapshot capture, trigger configuration and debug readback.
  // -------------------------------------------------------------------------
  localparam logic [REGMAP_ADDR_W-1:0] REGMAP_DEBUG_BASE = 16'h8000;
  localparam int unsigned REGMAP_DEBUG_SIZE = 4096;
  localparam int unsigned REGMAP_DEBUG_N_REGS = 0;
  // No registers in this build: every access to 0x8000..0x8FFF returns error=1.

  // -------------------------------------------------------------------------
  // Block 9: covar — implemented
  // SPEC 9 groups: Integration settings
  // Integration settings for the SPEC 7.6 power and covariance engine (rtl/covariance/,
  // issue #13): the programmable window length, the exponential-averaging mode and its
  // shift, the per-pair enable mask, the pair table, the deterministic flush, and the
  // accumulator-protection status. Everything writable here is latched by
  // rtl/covariance/integrator.sv at a window boundary and never mid-window, so a write
  // can lengthen or shorten the NEXT window but can never change the interval a result
  // already covers. Software that needs a change to take effect at once writes the
  // register and then pulses COVAR_CTRL.FLUSH, which drains the open window with its
  // truncated marker and restarts the block from its post-reset state.
  // -------------------------------------------------------------------------
  localparam logic [REGMAP_ADDR_W-1:0] REGMAP_COVAR_BASE = 16'h9000;
  localparam int unsigned REGMAP_COVAR_SIZE = 4096;
  localparam int unsigned REGMAP_COVAR_N_REGS = 7;
  localparam int unsigned REGMAP_COVAR_INDEX = 8;  // fabric port index

  // COVAR_CTRL @ 0x9000 (MIXED)
  //   Master controls. FLUSH and SAT_CLEAR are write-1-pulse and read back zero,
  //   because they are events rather than modes.
  //   [0:0] ENABLE (RW)
  //       Global accumulate enable. Cleared, the integrators admit no samples and emit
  //       nothing. Latched at a window boundary, so clearing it mid-window lets that
  //       window finish rather than truncating it.
  //   [1:1] EXP_MODE (RW)
  //       0: block integration, acc += x over COVAR_WINDOW.LENGTH samples, cleared at
  //       each boundary. 1: exponential averaging, y += (x - y) >> EXP_K per sample,
  //       reported every COVAR_WINDOW.LENGTH samples and NOT cleared at the boundary.
  //       rtl/covariance/integrator.sv section 4 states the exact fixed-point
  //       behaviour.
  //   [7:4] EXP_K (RW)
  //       Exponential-averaging shift k, 0..15. k = 0 is a pass-through. The update
  //       truncates toward -infinity, so a constant target is approached from below and
  //       the filter settles inside (x - 2^k, x].
  //   [8:8] FLUSH (RWP)
  //       Drain every open window, mark each result flushed (and truncated when short),
  //       then restart the block in its post-reset state: zero accumulators, zero
  //       sample counts, window_id back to zero, sticky saturation cleared, and the
  //       pair table reloaded from COVAR_PAIR_TABLE.
  //   [9:9] SAT_CLEAR (RWP)
  //       Clear the sticky saturation flags and the saturation-event counter without
  //       disturbing any window.
  localparam int unsigned REGMAP_COVAR_COVAR_CTRL_INDEX = 0;
  localparam logic [REGMAP_ADDR_W-1:0] REGMAP_COVAR_COVAR_CTRL_ADDR = 16'h9000;
  localparam int unsigned REGMAP_COVAR_COVAR_CTRL_ENABLE_LSB = 0;
  localparam int unsigned REGMAP_COVAR_COVAR_CTRL_ENABLE_WIDTH = 1;
  localparam logic [31:0] REGMAP_COVAR_COVAR_CTRL_ENABLE_MASK = 32'h00000001;
  localparam int unsigned REGMAP_COVAR_COVAR_CTRL_EXP_MODE_LSB = 1;
  localparam int unsigned REGMAP_COVAR_COVAR_CTRL_EXP_MODE_WIDTH = 1;
  localparam logic [31:0] REGMAP_COVAR_COVAR_CTRL_EXP_MODE_MASK = 32'h00000002;
  localparam int unsigned REGMAP_COVAR_COVAR_CTRL_EXP_K_LSB = 4;
  localparam int unsigned REGMAP_COVAR_COVAR_CTRL_EXP_K_WIDTH = 4;
  localparam logic [31:0] REGMAP_COVAR_COVAR_CTRL_EXP_K_MASK = 32'h000000F0;
  localparam int unsigned REGMAP_COVAR_COVAR_CTRL_FLUSH_LSB = 8;
  localparam int unsigned REGMAP_COVAR_COVAR_CTRL_FLUSH_WIDTH = 1;
  localparam logic [31:0] REGMAP_COVAR_COVAR_CTRL_FLUSH_MASK = 32'h00000100;
  localparam int unsigned REGMAP_COVAR_COVAR_CTRL_SAT_CLEAR_LSB = 9;
  localparam int unsigned REGMAP_COVAR_COVAR_CTRL_SAT_CLEAR_WIDTH = 1;
  localparam logic [31:0] REGMAP_COVAR_COVAR_CTRL_SAT_CLEAR_MASK = 32'h00000200;

  // COVAR_WINDOW @ 0x9004 (RW)
  //   Programmable integration window (SPEC 7.6).
  //   [15:0] LENGTH (RW)
  //       Samples per integration window. Zero is treated as one, so a zero-initialised
  //       register plane cannot make the window infinite - which would be
  //       indistinguishable from a hang. A signed POWER_W = 40 accumulator integrates
  //       terms bounded by 2^31 exactly for LENGTH <= 255 (rtl/packages/covar_pkg.sv
  //       section 1); longer windows are legal and may clamp, which COVAR_SAT_STATUS
  //       reports.
  localparam int unsigned REGMAP_COVAR_COVAR_WINDOW_INDEX = 1;
  localparam logic [REGMAP_ADDR_W-1:0] REGMAP_COVAR_COVAR_WINDOW_ADDR = 16'h9004;
  localparam int unsigned REGMAP_COVAR_COVAR_WINDOW_LENGTH_LSB = 0;
  localparam int unsigned REGMAP_COVAR_COVAR_WINDOW_LENGTH_WIDTH = 16;
  localparam logic [31:0] REGMAP_COVAR_COVAR_WINDOW_LENGTH_MASK = 32'h0000FFFF;

  // COVAR_PAIR_ENABLE @ 0x9008 (RW)
  //   Runtime enable, one bit per covariance pair (SPEC 7.6, 'runtime enable per
  //   covariance pair').
  //   [31:0] MASK (RW)
  //       Bit p enables pair p. Latched by that pair's accumulators at a window
  //       boundary, so a pair disabled mid-window completes the window it is in and a
  //       pair enabled mid-window starts at the next one with a full-length window. A
  //       disabled pair accumulates nothing and emits nothing; its multiplier still
  //       free-runs, because a clock enable on a DSP register is what stops the tool
  //       using the block's own pipeline registers.
  localparam int unsigned REGMAP_COVAR_COVAR_PAIR_ENABLE_INDEX = 2;
  localparam logic [REGMAP_ADDR_W-1:0] REGMAP_COVAR_COVAR_PAIR_ENABLE_ADDR = 16'h9008;
  localparam int unsigned REGMAP_COVAR_COVAR_PAIR_ENABLE_MASK_LSB = 0;
  localparam int unsigned REGMAP_COVAR_COVAR_PAIR_ENABLE_MASK_WIDTH = 32;
  localparam logic [31:0] REGMAP_COVAR_COVAR_PAIR_ENABLE_MASK_MASK = 32'hFFFFFFFF;

  // COVAR_PAIR_TABLE @ 0x900C (MIXED)
  //   Pair table programming port. One entry per write: set INDEX, X_SEL and Y_SEL,
  //   then pulse WRITE. The table takes effect at the next COVAR_CTRL.FLUSH rather than
  //   at a window boundary; rtl/covariance/covar_engine.sv section 4 explains why a
  //   multiplier pipeline deeper than one cycle cannot re-point a pair cleanly at a
  //   window edge.
  //   [7:0] INDEX (RW)
  //       Pair index to program.
  //   [15:8] X_SEL (RW)
  //       Source index for X. An index beyond the elaborated source count reads source
  //       0; out of range is defined rather than undefined, because a register plane
  //       can be programmed with anything.
  //   [23:16] Y_SEL (RW)
  //       Source index for Y, the conjugated operand.
  //   [24:24] WRITE (RWP)
  //       Write the entry named by INDEX. One-cycle pulse; reads back zero.
  localparam int unsigned REGMAP_COVAR_COVAR_PAIR_TABLE_INDEX = 3;
  localparam logic [REGMAP_ADDR_W-1:0] REGMAP_COVAR_COVAR_PAIR_TABLE_ADDR = 16'h900C;
  localparam int unsigned REGMAP_COVAR_COVAR_PAIR_TABLE_INDEX_LSB = 0;
  localparam int unsigned REGMAP_COVAR_COVAR_PAIR_TABLE_INDEX_WIDTH = 8;
  localparam logic [31:0] REGMAP_COVAR_COVAR_PAIR_TABLE_INDEX_MASK = 32'h000000FF;
  localparam int unsigned REGMAP_COVAR_COVAR_PAIR_TABLE_X_SEL_LSB = 8;
  localparam int unsigned REGMAP_COVAR_COVAR_PAIR_TABLE_X_SEL_WIDTH = 8;
  localparam logic [31:0] REGMAP_COVAR_COVAR_PAIR_TABLE_X_SEL_MASK = 32'h0000FF00;
  localparam int unsigned REGMAP_COVAR_COVAR_PAIR_TABLE_Y_SEL_LSB = 16;
  localparam int unsigned REGMAP_COVAR_COVAR_PAIR_TABLE_Y_SEL_WIDTH = 8;
  localparam logic [31:0] REGMAP_COVAR_COVAR_PAIR_TABLE_Y_SEL_MASK = 32'h00FF0000;
  localparam int unsigned REGMAP_COVAR_COVAR_PAIR_TABLE_WRITE_LSB = 24;
  localparam int unsigned REGMAP_COVAR_COVAR_PAIR_TABLE_WRITE_WIDTH = 1;
  localparam logic [31:0] REGMAP_COVAR_COVAR_PAIR_TABLE_WRITE_MASK = 32'h01000000;

  // COVAR_STATUS @ 0x9010 (ROHW)
  //   Hardware-driven status. The geometry fields let software size its own buffers
  //   without compiled-in constants, exactly as the build-parameter block does for the
  //   rest of the design.
  //   [15:0] WINDOW_ID (ROHW)
  //       Window id of the most recent result, wrapping at 2^16. Increments by exactly
  //       one per emitted window, so a consumer detects a dropped one.
  //   [23:16] N_PAIRS (ROHW)
  //       Elaborated covariance pair count.
  //   [31:24] ACC_W (ROHW)
  //       Elaborated accumulator width in bits (SPEC 3 POWER_W).
  localparam int unsigned REGMAP_COVAR_COVAR_STATUS_INDEX = 4;
  localparam logic [REGMAP_ADDR_W-1:0] REGMAP_COVAR_COVAR_STATUS_ADDR = 16'h9010;
  localparam int unsigned REGMAP_COVAR_COVAR_STATUS_WINDOW_ID_LSB = 0;
  localparam int unsigned REGMAP_COVAR_COVAR_STATUS_WINDOW_ID_WIDTH = 16;
  localparam logic [31:0] REGMAP_COVAR_COVAR_STATUS_WINDOW_ID_MASK = 32'h0000FFFF;
  localparam int unsigned REGMAP_COVAR_COVAR_STATUS_N_PAIRS_LSB = 16;
  localparam int unsigned REGMAP_COVAR_COVAR_STATUS_N_PAIRS_WIDTH = 8;
  localparam logic [31:0] REGMAP_COVAR_COVAR_STATUS_N_PAIRS_MASK = 32'h00FF0000;
  localparam int unsigned REGMAP_COVAR_COVAR_STATUS_ACC_W_LSB = 24;
  localparam int unsigned REGMAP_COVAR_COVAR_STATUS_ACC_W_WIDTH = 8;
  localparam logic [31:0] REGMAP_COVAR_COVAR_STATUS_ACC_W_MASK = 32'hFF000000;

  // COVAR_SAT_STATUS @ 0x9014 (W1C)
  //   Accumulator protection (SPEC 7.6 'accumulator protection', SPEC 6 overflow
  //   flags). Sticky, write 1 to clear; also cleared by COVAR_CTRL.SAT_CLEAR and by
  //   COVAR_CTRL.FLUSH.
  //   [0:0] POWER (W1C)
  //       The power accumulator clamped at least once since the last clear.
  //   [1:1] CROSS (W1C)
  //       A cross-power accumulator clamped at least once since the last clear.
  //   [2:2] TRUNCATED (W1C)
  //       At least one window was emitted short of its programmed length. Set only by a
  //       flush, because a flush is the only thing that can shorten a window.
  localparam int unsigned REGMAP_COVAR_COVAR_SAT_STATUS_INDEX = 5;
  localparam logic [REGMAP_ADDR_W-1:0] REGMAP_COVAR_COVAR_SAT_STATUS_ADDR = 16'h9014;
  localparam int unsigned REGMAP_COVAR_COVAR_SAT_STATUS_POWER_LSB = 0;
  localparam int unsigned REGMAP_COVAR_COVAR_SAT_STATUS_POWER_WIDTH = 1;
  localparam logic [31:0] REGMAP_COVAR_COVAR_SAT_STATUS_POWER_MASK = 32'h00000001;
  localparam int unsigned REGMAP_COVAR_COVAR_SAT_STATUS_CROSS_LSB = 1;
  localparam int unsigned REGMAP_COVAR_COVAR_SAT_STATUS_CROSS_WIDTH = 1;
  localparam logic [31:0] REGMAP_COVAR_COVAR_SAT_STATUS_CROSS_MASK = 32'h00000002;
  localparam int unsigned REGMAP_COVAR_COVAR_SAT_STATUS_TRUNCATED_LSB = 2;
  localparam int unsigned REGMAP_COVAR_COVAR_SAT_STATUS_TRUNCATED_WIDTH = 1;
  localparam logic [31:0] REGMAP_COVAR_COVAR_SAT_STATUS_TRUNCATED_MASK = 32'h00000004;

  // COVAR_SAT_COUNT @ 0x9018 (ROHW)
  //   Count of saturation events, highest across the block's accumulators. Saturates at
  //   all-ones rather than wrapping: a wrapped counter can read zero on a permanently
  //   clamping datapath, which is the one reading that must never be produced.
  //   [31:0] VALUE (ROHW)
  //       Saturation-event count.
  localparam int unsigned REGMAP_COVAR_COVAR_SAT_COUNT_INDEX = 6;
  localparam logic [REGMAP_ADDR_W-1:0] REGMAP_COVAR_COVAR_SAT_COUNT_ADDR = 16'h9018;
  localparam int unsigned REGMAP_COVAR_COVAR_SAT_COUNT_VALUE_LSB = 0;
  localparam int unsigned REGMAP_COVAR_COVAR_SAT_COUNT_VALUE_WIDTH = 32;
  localparam logic [31:0] REGMAP_COVAR_COVAR_SAT_COUNT_VALUE_MASK = 32'hFFFFFFFF;

  // reset value of the stored bits
  localparam logic [REGMAP_COVAR_N_REGS*32-1:0] REGMAP_COVAR_RESET = {
      32'h00000000,  // [6]
      32'h00000000,  // [5]
      32'h00000000,  // [4]
      32'h00000000,  // [3]
      32'h00000001,  // [2]
      32'h00000010,  // [1]
      32'h00000031  // [0]
  };
  // bits a software write may set or clear (RW)
  localparam logic [REGMAP_COVAR_N_REGS*32-1:0] REGMAP_COVAR_WMASK = {
      32'h00000000,  // [6]
      32'h00000000,  // [5]
      32'h00000000,  // [4]
      32'h00FFFFFF,  // [3]
      32'hFFFFFFFF,  // [2]
      32'h0000FFFF,  // [1]
      32'h000000F3  // [0]
  };
  // bits cleared by writing 1, set by hardware (W1C)
  localparam logic [REGMAP_COVAR_N_REGS*32-1:0] REGMAP_COVAR_W1CMASK = {
      32'h00000000,  // [6]
      32'h00000007,  // [5]
      32'h00000000,  // [4]
      32'h00000000,  // [3]
      32'h00000000,  // [2]
      32'h00000000,  // [1]
      32'h00000000  // [0]
  };
  // bits that pulse for one cycle and read 0 (RWP)
  localparam logic [REGMAP_COVAR_N_REGS*32-1:0] REGMAP_COVAR_PULSEMASK = {
      32'h00000000,  // [6]
      32'h00000000,  // [5]
      32'h00000000,  // [4]
      32'h01000000,  // [3]
      32'h00000000,  // [2]
      32'h00000000,  // [1]
      32'h00000300  // [0]
  };
  // bits read from the hardware input, not from storage (ROHW)
  localparam logic [REGMAP_COVAR_N_REGS*32-1:0] REGMAP_COVAR_HWMASK = {
      32'hFFFFFFFF,  // [6]
      32'h00000000,  // [5]
      32'hFFFFFFFF,  // [4]
      32'h00000000,  // [3]
      32'h00000000,  // [2]
      32'h00000000,  // [1]
      32'h00000000  // [0]
  };

endpackage : regmap_pkg
