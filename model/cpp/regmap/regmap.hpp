// GENERATED FILE - DO NOT EDIT.
//
// Produced by scripts/gen_regmap.py from control/regmap.json (SPEC 9, issue #7).
// The C++ half of the single source of truth: the harness addresses registers with
// these constants, the RTL decodes with rtl/control/generated/regmap_pkg.sv, and both
// come from one file. `make regmap-check` fails if either drifts.
//
// Two shapes are provided, deliberately:
//   * named constants, for a test that means a specific register;
//   * kBlocks / kRegisters / kFields tables, for a test that walks the whole map
//     (reset-default sweep, randomized soak) without naming anything. A generated
//     table is what makes 'every documented register' a checkable claim.

#ifndef MODEL_CPP_REGMAP_REGMAP_HPP_
#define MODEL_CPP_REGMAP_REGMAP_HPP_

#include <cstddef>
#include <cstdint>

namespace regmap {

inline constexpr unsigned kAddrWidth = 16;
inline constexpr unsigned kDataWidth = 32;
inline constexpr unsigned kStrobeWidth = 4;
inline constexpr std::uint32_t kWindowBytes = 0x1000u;
inline constexpr std::uint32_t kAddrMask = 0xFFFFu;
inline constexpr unsigned kBlockCount = 9;
inline constexpr unsigned kBlockCountImplemented = 5;
inline constexpr unsigned kRegisterCount = 28;
inline constexpr std::uint32_t kBlockMask = 0x0000001Fu;
inline constexpr unsigned kVersionMajor = 1;
inline constexpr unsigned kVersionMinor = 0;
inline constexpr unsigned kVersionPatch = 0;

// Per-bit access classification, matching rtl/control/reg_csr_block.sv.
enum class Access : std::uint8_t { kRo, kRoHw, kRw, kW1c, kRwp, kMixed };

struct FieldInfo {
  const char* block;
  const char* reg;
  const char* name;
  unsigned lsb;
  unsigned width;
  std::uint32_t mask;
  Access access;
  std::uint32_t reset;
};

struct RegInfo {
  const char* block;
  const char* name;
  std::uint32_t address;
  unsigned block_index;   // index among implemented blocks
  unsigned index;         // word index inside the block
  Access access;
  std::uint32_t reset;         // reset value of the stored bits
  std::uint32_t wmask;         // plain read-write bits
  std::uint32_t w1c_mask;      // write-1-to-clear bits
  std::uint32_t pulse_mask;    // write-1-pulse bits (always read 0)
  std::uint32_t hw_mask;       // bits read from hardware, not storage
  std::uint32_t writable_mask; // wmask | w1c_mask | pulse_mask
};

struct BlockInfo {
  const char* name;
  std::uint32_t base;
  std::uint32_t size;
  bool implemented;
  unsigned reg_count;
};

// ---- named register addresses -------------------------------------------
// id: Fixed identification of the control plane itself.
inline constexpr std::uint32_t ID_BASE = 0x0000u;
inline constexpr std::uint32_t ID_MAGIC_ADDR = 0x0000u;
inline constexpr std::uint32_t ID_MAGIC_RESET = 0x52414441u;
inline constexpr unsigned ID_MAGIC_MAGIC_LSB = 0;
inline constexpr unsigned ID_MAGIC_MAGIC_WIDTH = 32;
inline constexpr std::uint32_t ID_MAGIC_MAGIC_MASK = 0xFFFFFFFFu;
inline constexpr std::uint32_t ID_VERSION_ADDR = 0x0004u;
inline constexpr std::uint32_t ID_VERSION_RESET = 0x01000001u;
inline constexpr unsigned ID_VERSION_MAJOR_LSB = 24;
inline constexpr unsigned ID_VERSION_MAJOR_WIDTH = 8;
inline constexpr std::uint32_t ID_VERSION_MAJOR_MASK = 0xFF000000u;
inline constexpr unsigned ID_VERSION_MINOR_LSB = 16;
inline constexpr unsigned ID_VERSION_MINOR_WIDTH = 8;
inline constexpr std::uint32_t ID_VERSION_MINOR_MASK = 0x00FF0000u;
inline constexpr unsigned ID_VERSION_PATCH_LSB = 8;
inline constexpr unsigned ID_VERSION_PATCH_WIDTH = 8;
inline constexpr std::uint32_t ID_VERSION_PATCH_MASK = 0x0000FF00u;
inline constexpr unsigned ID_VERSION_SCHEMA_LSB = 0;
inline constexpr unsigned ID_VERSION_SCHEMA_WIDTH = 8;
inline constexpr std::uint32_t ID_VERSION_SCHEMA_MASK = 0x000000FFu;
inline constexpr std::uint32_t ID_GEOMETRY_ADDR = 0x0008u;
inline constexpr std::uint32_t ID_GEOMETRY_RESET = 0x10201C09u;
inline constexpr unsigned ID_GEOMETRY_N_BLOCKS_LSB = 0;
inline constexpr unsigned ID_GEOMETRY_N_BLOCKS_WIDTH = 8;
inline constexpr std::uint32_t ID_GEOMETRY_N_BLOCKS_MASK = 0x000000FFu;
inline constexpr unsigned ID_GEOMETRY_N_REGS_LSB = 8;
inline constexpr unsigned ID_GEOMETRY_N_REGS_WIDTH = 8;
inline constexpr std::uint32_t ID_GEOMETRY_N_REGS_MASK = 0x0000FF00u;
inline constexpr unsigned ID_GEOMETRY_DATA_W_LSB = 16;
inline constexpr unsigned ID_GEOMETRY_DATA_W_WIDTH = 8;
inline constexpr std::uint32_t ID_GEOMETRY_DATA_W_MASK = 0x00FF0000u;
inline constexpr unsigned ID_GEOMETRY_ADDR_W_LSB = 24;
inline constexpr unsigned ID_GEOMETRY_ADDR_W_WIDTH = 8;
inline constexpr std::uint32_t ID_GEOMETRY_ADDR_W_MASK = 0xFF000000u;
inline constexpr std::uint32_t ID_CAPABILITY_ADDR = 0x000Cu;
inline constexpr std::uint32_t ID_CAPABILITY_RESET = 0x0000001Fu;
inline constexpr unsigned ID_CAPABILITY_BLOCK_MASK_LSB = 0;
inline constexpr unsigned ID_CAPABILITY_BLOCK_MASK_WIDTH = 32;
inline constexpr std::uint32_t ID_CAPABILITY_BLOCK_MASK_MASK = 0xFFFFFFFFu;

// build_params: Read-only mirror of the elaboration parameters.
inline constexpr std::uint32_t BUILD_PARAMS_BASE = 0x1000u;
inline constexpr std::uint32_t BUILD_PARAMS_N_ANTENNAS_ADDR = 0x1000u;
inline constexpr std::uint32_t BUILD_PARAMS_N_ANTENNAS_RESET = 0x00000000u;
inline constexpr unsigned BUILD_PARAMS_N_ANTENNAS_VALUE_LSB = 0;
inline constexpr unsigned BUILD_PARAMS_N_ANTENNAS_VALUE_WIDTH = 32;
inline constexpr std::uint32_t BUILD_PARAMS_N_ANTENNAS_VALUE_MASK = 0xFFFFFFFFu;
inline constexpr std::uint32_t BUILD_PARAMS_SAMPLES_PER_CYCLE_ADDR = 0x1004u;
inline constexpr std::uint32_t BUILD_PARAMS_SAMPLES_PER_CYCLE_RESET = 0x00000000u;
inline constexpr unsigned BUILD_PARAMS_SAMPLES_PER_CYCLE_VALUE_LSB = 0;
inline constexpr unsigned BUILD_PARAMS_SAMPLES_PER_CYCLE_VALUE_WIDTH = 32;
inline constexpr std::uint32_t BUILD_PARAMS_SAMPLES_PER_CYCLE_VALUE_MASK = 0xFFFFFFFFu;
inline constexpr std::uint32_t BUILD_PARAMS_FFT_SIZE_ADDR = 0x1008u;
inline constexpr std::uint32_t BUILD_PARAMS_FFT_SIZE_RESET = 0x00000000u;
inline constexpr unsigned BUILD_PARAMS_FFT_SIZE_VALUE_LSB = 0;
inline constexpr unsigned BUILD_PARAMS_FFT_SIZE_VALUE_WIDTH = 32;
inline constexpr std::uint32_t BUILD_PARAMS_FFT_SIZE_VALUE_MASK = 0xFFFFFFFFu;
inline constexpr std::uint32_t BUILD_PARAMS_PFB_TAPS_ADDR = 0x100Cu;
inline constexpr std::uint32_t BUILD_PARAMS_PFB_TAPS_RESET = 0x00000000u;
inline constexpr unsigned BUILD_PARAMS_PFB_TAPS_VALUE_LSB = 0;
inline constexpr unsigned BUILD_PARAMS_PFB_TAPS_VALUE_WIDTH = 32;
inline constexpr std::uint32_t BUILD_PARAMS_PFB_TAPS_VALUE_MASK = 0xFFFFFFFFu;
inline constexpr std::uint32_t BUILD_PARAMS_N_BEAMS_ADDR = 0x1010u;
inline constexpr std::uint32_t BUILD_PARAMS_N_BEAMS_RESET = 0x00000000u;
inline constexpr unsigned BUILD_PARAMS_N_BEAMS_VALUE_LSB = 0;
inline constexpr unsigned BUILD_PARAMS_N_BEAMS_VALUE_WIDTH = 32;
inline constexpr std::uint32_t BUILD_PARAMS_N_BEAMS_VALUE_MASK = 0xFFFFFFFFu;
inline constexpr std::uint32_t BUILD_PARAMS_HISTORY_FRAMES_ADDR = 0x1014u;
inline constexpr std::uint32_t BUILD_PARAMS_HISTORY_FRAMES_RESET = 0x00000000u;
inline constexpr unsigned BUILD_PARAMS_HISTORY_FRAMES_VALUE_LSB = 0;
inline constexpr unsigned BUILD_PARAMS_HISTORY_FRAMES_VALUE_WIDTH = 32;
inline constexpr std::uint32_t BUILD_PARAMS_HISTORY_FRAMES_VALUE_MASK = 0xFFFFFFFFu;
inline constexpr std::uint32_t BUILD_PARAMS_PACKET_W_ADDR = 0x1018u;
inline constexpr std::uint32_t BUILD_PARAMS_PACKET_W_RESET = 0x00000000u;
inline constexpr unsigned BUILD_PARAMS_PACKET_W_VALUE_LSB = 0;
inline constexpr unsigned BUILD_PARAMS_PACKET_W_VALUE_WIDTH = 32;
inline constexpr std::uint32_t BUILD_PARAMS_PACKET_W_VALUE_MASK = 0xFFFFFFFFu;
inline constexpr std::uint32_t BUILD_PARAMS_SAMPLE_W_ADDR = 0x101Cu;
inline constexpr std::uint32_t BUILD_PARAMS_SAMPLE_W_RESET = 0x00000000u;
inline constexpr unsigned BUILD_PARAMS_SAMPLE_W_VALUE_LSB = 0;
inline constexpr unsigned BUILD_PARAMS_SAMPLE_W_VALUE_WIDTH = 32;
inline constexpr std::uint32_t BUILD_PARAMS_SAMPLE_W_VALUE_MASK = 0xFFFFFFFFu;
inline constexpr std::uint32_t BUILD_PARAMS_COEFF_W_ADDR = 0x1020u;
inline constexpr std::uint32_t BUILD_PARAMS_COEFF_W_RESET = 0x00000000u;
inline constexpr unsigned BUILD_PARAMS_COEFF_W_VALUE_LSB = 0;
inline constexpr unsigned BUILD_PARAMS_COEFF_W_VALUE_WIDTH = 32;
inline constexpr std::uint32_t BUILD_PARAMS_COEFF_W_VALUE_MASK = 0xFFFFFFFFu;
inline constexpr std::uint32_t BUILD_PARAMS_POWER_W_ADDR = 0x1024u;
inline constexpr std::uint32_t BUILD_PARAMS_POWER_W_RESET = 0x00000000u;
inline constexpr unsigned BUILD_PARAMS_POWER_W_VALUE_LSB = 0;
inline constexpr unsigned BUILD_PARAMS_POWER_W_VALUE_WIDTH = 32;
inline constexpr std::uint32_t BUILD_PARAMS_POWER_W_VALUE_MASK = 0xFFFFFFFFu;
inline constexpr std::uint32_t BUILD_PARAMS_N_VIRTUAL_CHANS_ADDR = 0x1028u;
inline constexpr std::uint32_t BUILD_PARAMS_N_VIRTUAL_CHANS_RESET = 0x00000000u;
inline constexpr unsigned BUILD_PARAMS_N_VIRTUAL_CHANS_VALUE_LSB = 0;
inline constexpr unsigned BUILD_PARAMS_N_VIRTUAL_CHANS_VALUE_WIDTH = 32;
inline constexpr std::uint32_t BUILD_PARAMS_N_VIRTUAL_CHANS_VALUE_MASK = 0xFFFFFFFFu;
inline constexpr std::uint32_t BUILD_PARAMS_PARAM_CHECKSUM_ADDR = 0x102Cu;
inline constexpr std::uint32_t BUILD_PARAMS_PARAM_CHECKSUM_RESET = 0x00000000u;
inline constexpr unsigned BUILD_PARAMS_PARAM_CHECKSUM_VALUE_LSB = 0;
inline constexpr unsigned BUILD_PARAMS_PARAM_CHECKSUM_VALUE_WIDTH = 32;
inline constexpr std::uint32_t BUILD_PARAMS_PARAM_CHECKSUM_VALUE_MASK = 0xFFFFFFFFu;

// ctrl: Per-block enable and soft-reset stubs.
inline constexpr std::uint32_t CTRL_BASE = 0x2000u;
inline constexpr std::uint32_t CTRL_BLOCK_ENABLE_ADDR = 0x2000u;
inline constexpr std::uint32_t CTRL_BLOCK_ENABLE_RESET = 0x000000FFu;
inline constexpr unsigned CTRL_BLOCK_ENABLE_PFB_LSB = 0;
inline constexpr unsigned CTRL_BLOCK_ENABLE_PFB_WIDTH = 1;
inline constexpr std::uint32_t CTRL_BLOCK_ENABLE_PFB_MASK = 0x00000001u;
inline constexpr unsigned CTRL_BLOCK_ENABLE_FFT_LSB = 1;
inline constexpr unsigned CTRL_BLOCK_ENABLE_FFT_WIDTH = 1;
inline constexpr std::uint32_t CTRL_BLOCK_ENABLE_FFT_MASK = 0x00000002u;
inline constexpr unsigned CTRL_BLOCK_ENABLE_BEAMFORMER_LSB = 2;
inline constexpr unsigned CTRL_BLOCK_ENABLE_BEAMFORMER_WIDTH = 1;
inline constexpr std::uint32_t CTRL_BLOCK_ENABLE_BEAMFORMER_MASK = 0x00000004u;
inline constexpr unsigned CTRL_BLOCK_ENABLE_COVARIANCE_LSB = 3;
inline constexpr unsigned CTRL_BLOCK_ENABLE_COVARIANCE_WIDTH = 1;
inline constexpr std::uint32_t CTRL_BLOCK_ENABLE_COVARIANCE_MASK = 0x00000008u;
inline constexpr unsigned CTRL_BLOCK_ENABLE_CFAR_LSB = 4;
inline constexpr unsigned CTRL_BLOCK_ENABLE_CFAR_WIDTH = 1;
inline constexpr std::uint32_t CTRL_BLOCK_ENABLE_CFAR_MASK = 0x00000010u;
inline constexpr unsigned CTRL_BLOCK_ENABLE_PACKET_LSB = 5;
inline constexpr unsigned CTRL_BLOCK_ENABLE_PACKET_WIDTH = 1;
inline constexpr std::uint32_t CTRL_BLOCK_ENABLE_PACKET_MASK = 0x00000020u;
inline constexpr unsigned CTRL_BLOCK_ENABLE_MEMORY_LSB = 6;
inline constexpr unsigned CTRL_BLOCK_ENABLE_MEMORY_WIDTH = 1;
inline constexpr std::uint32_t CTRL_BLOCK_ENABLE_MEMORY_MASK = 0x00000040u;
inline constexpr unsigned CTRL_BLOCK_ENABLE_TELEMETRY_LSB = 7;
inline constexpr unsigned CTRL_BLOCK_ENABLE_TELEMETRY_WIDTH = 1;
inline constexpr std::uint32_t CTRL_BLOCK_ENABLE_TELEMETRY_MASK = 0x00000080u;
inline constexpr std::uint32_t CTRL_BLOCK_RESET_ADDR = 0x2004u;
inline constexpr std::uint32_t CTRL_BLOCK_RESET_RESET = 0x00000000u;
inline constexpr unsigned CTRL_BLOCK_RESET_PFB_LSB = 0;
inline constexpr unsigned CTRL_BLOCK_RESET_PFB_WIDTH = 1;
inline constexpr std::uint32_t CTRL_BLOCK_RESET_PFB_MASK = 0x00000001u;
inline constexpr unsigned CTRL_BLOCK_RESET_FFT_LSB = 1;
inline constexpr unsigned CTRL_BLOCK_RESET_FFT_WIDTH = 1;
inline constexpr std::uint32_t CTRL_BLOCK_RESET_FFT_MASK = 0x00000002u;
inline constexpr unsigned CTRL_BLOCK_RESET_BEAMFORMER_LSB = 2;
inline constexpr unsigned CTRL_BLOCK_RESET_BEAMFORMER_WIDTH = 1;
inline constexpr std::uint32_t CTRL_BLOCK_RESET_BEAMFORMER_MASK = 0x00000004u;
inline constexpr unsigned CTRL_BLOCK_RESET_COVARIANCE_LSB = 3;
inline constexpr unsigned CTRL_BLOCK_RESET_COVARIANCE_WIDTH = 1;
inline constexpr std::uint32_t CTRL_BLOCK_RESET_COVARIANCE_MASK = 0x00000008u;
inline constexpr unsigned CTRL_BLOCK_RESET_CFAR_LSB = 4;
inline constexpr unsigned CTRL_BLOCK_RESET_CFAR_WIDTH = 1;
inline constexpr std::uint32_t CTRL_BLOCK_RESET_CFAR_MASK = 0x00000010u;
inline constexpr unsigned CTRL_BLOCK_RESET_PACKET_LSB = 5;
inline constexpr unsigned CTRL_BLOCK_RESET_PACKET_WIDTH = 1;
inline constexpr std::uint32_t CTRL_BLOCK_RESET_PACKET_MASK = 0x00000020u;
inline constexpr unsigned CTRL_BLOCK_RESET_MEMORY_LSB = 6;
inline constexpr unsigned CTRL_BLOCK_RESET_MEMORY_WIDTH = 1;
inline constexpr std::uint32_t CTRL_BLOCK_RESET_MEMORY_MASK = 0x00000040u;
inline constexpr unsigned CTRL_BLOCK_RESET_TELEMETRY_LSB = 7;
inline constexpr unsigned CTRL_BLOCK_RESET_TELEMETRY_WIDTH = 1;
inline constexpr std::uint32_t CTRL_BLOCK_RESET_TELEMETRY_MASK = 0x00000080u;
inline constexpr std::uint32_t CTRL_GLOBAL_CTRL_ADDR = 0x2008u;
inline constexpr std::uint32_t CTRL_GLOBAL_CTRL_RESET = 0x00000001u;
inline constexpr unsigned CTRL_GLOBAL_CTRL_GLOBAL_ENABLE_LSB = 0;
inline constexpr unsigned CTRL_GLOBAL_CTRL_GLOBAL_ENABLE_WIDTH = 1;
inline constexpr std::uint32_t CTRL_GLOBAL_CTRL_GLOBAL_ENABLE_MASK = 0x00000001u;
inline constexpr unsigned CTRL_GLOBAL_CTRL_FLUSH_LSB = 1;
inline constexpr unsigned CTRL_GLOBAL_CTRL_FLUSH_WIDTH = 1;
inline constexpr std::uint32_t CTRL_GLOBAL_CTRL_FLUSH_MASK = 0x00000002u;
inline constexpr unsigned CTRL_GLOBAL_CTRL_SOFT_RESET_LSB = 2;
inline constexpr unsigned CTRL_GLOBAL_CTRL_SOFT_RESET_WIDTH = 1;
inline constexpr std::uint32_t CTRL_GLOBAL_CTRL_SOFT_RESET_MASK = 0x00000004u;
inline constexpr std::uint32_t CTRL_CTRL_STATUS_ADDR = 0x200Cu;
inline constexpr std::uint32_t CTRL_CTRL_STATUS_RESET = 0x00000000u;
inline constexpr unsigned CTRL_CTRL_STATUS_ENABLED_COUNT_LSB = 0;
inline constexpr unsigned CTRL_CTRL_STATUS_ENABLED_COUNT_WIDTH = 4;
inline constexpr std::uint32_t CTRL_CTRL_STATUS_ENABLED_COUNT_MASK = 0x0000000Fu;
inline constexpr unsigned CTRL_CTRL_STATUS_ALIVE_LSB = 8;
inline constexpr unsigned CTRL_CTRL_STATUS_ALIVE_WIDTH = 1;
inline constexpr std::uint32_t CTRL_CTRL_STATUS_ALIVE_MASK = 0x00000100u;

// fault: Fault injection (SPEC 24).
inline constexpr std::uint32_t FAULT_BASE = 0x3000u;
inline constexpr std::uint32_t FAULT_FAULT_ENABLE_ADDR = 0x3000u;
inline constexpr std::uint32_t FAULT_FAULT_ENABLE_RESET = 0x00000000u;
inline constexpr unsigned FAULT_FAULT_ENABLE_STREAM_CORRUPT_LSB = 0;
inline constexpr unsigned FAULT_FAULT_ENABLE_STREAM_CORRUPT_WIDTH = 1;
inline constexpr std::uint32_t FAULT_FAULT_ENABLE_STREAM_CORRUPT_MASK = 0x00000001u;
inline constexpr unsigned FAULT_FAULT_ENABLE_SEQ_ERROR_LSB = 1;
inline constexpr unsigned FAULT_FAULT_ENABLE_SEQ_ERROR_WIDTH = 1;
inline constexpr std::uint32_t FAULT_FAULT_ENABLE_SEQ_ERROR_MASK = 0x00000002u;
inline constexpr unsigned FAULT_FAULT_ENABLE_FIFO_OVERFLOW_LSB = 2;
inline constexpr unsigned FAULT_FAULT_ENABLE_FIFO_OVERFLOW_WIDTH = 1;
inline constexpr std::uint32_t FAULT_FAULT_ENABLE_FIFO_OVERFLOW_MASK = 0x00000004u;
inline constexpr unsigned FAULT_FAULT_ENABLE_CDC_ERROR_LSB = 3;
inline constexpr unsigned FAULT_FAULT_ENABLE_CDC_ERROR_WIDTH = 1;
inline constexpr std::uint32_t FAULT_FAULT_ENABLE_CDC_ERROR_MASK = 0x00000008u;
inline constexpr unsigned FAULT_FAULT_ENABLE_SATURATION_LSB = 4;
inline constexpr unsigned FAULT_FAULT_ENABLE_SATURATION_WIDTH = 1;
inline constexpr std::uint32_t FAULT_FAULT_ENABLE_SATURATION_MASK = 0x00000010u;
inline constexpr unsigned FAULT_FAULT_ENABLE_PACKET_DROP_LSB = 5;
inline constexpr unsigned FAULT_FAULT_ENABLE_PACKET_DROP_WIDTH = 1;
inline constexpr std::uint32_t FAULT_FAULT_ENABLE_PACKET_DROP_MASK = 0x00000020u;
inline constexpr std::uint32_t FAULT_FAULT_INJECT_ADDR = 0x3004u;
inline constexpr std::uint32_t FAULT_FAULT_INJECT_RESET = 0x00000000u;
inline constexpr unsigned FAULT_FAULT_INJECT_STREAM_CORRUPT_LSB = 0;
inline constexpr unsigned FAULT_FAULT_INJECT_STREAM_CORRUPT_WIDTH = 1;
inline constexpr std::uint32_t FAULT_FAULT_INJECT_STREAM_CORRUPT_MASK = 0x00000001u;
inline constexpr unsigned FAULT_FAULT_INJECT_SEQ_ERROR_LSB = 1;
inline constexpr unsigned FAULT_FAULT_INJECT_SEQ_ERROR_WIDTH = 1;
inline constexpr std::uint32_t FAULT_FAULT_INJECT_SEQ_ERROR_MASK = 0x00000002u;
inline constexpr unsigned FAULT_FAULT_INJECT_FIFO_OVERFLOW_LSB = 2;
inline constexpr unsigned FAULT_FAULT_INJECT_FIFO_OVERFLOW_WIDTH = 1;
inline constexpr std::uint32_t FAULT_FAULT_INJECT_FIFO_OVERFLOW_MASK = 0x00000004u;
inline constexpr unsigned FAULT_FAULT_INJECT_CDC_ERROR_LSB = 3;
inline constexpr unsigned FAULT_FAULT_INJECT_CDC_ERROR_WIDTH = 1;
inline constexpr std::uint32_t FAULT_FAULT_INJECT_CDC_ERROR_MASK = 0x00000008u;
inline constexpr unsigned FAULT_FAULT_INJECT_SATURATION_LSB = 4;
inline constexpr unsigned FAULT_FAULT_INJECT_SATURATION_WIDTH = 1;
inline constexpr std::uint32_t FAULT_FAULT_INJECT_SATURATION_MASK = 0x00000010u;
inline constexpr unsigned FAULT_FAULT_INJECT_PACKET_DROP_LSB = 5;
inline constexpr unsigned FAULT_FAULT_INJECT_PACKET_DROP_WIDTH = 1;
inline constexpr std::uint32_t FAULT_FAULT_INJECT_PACKET_DROP_MASK = 0x00000020u;
inline constexpr std::uint32_t FAULT_FAULT_STATUS_ADDR = 0x3008u;
inline constexpr std::uint32_t FAULT_FAULT_STATUS_RESET = 0x00000000u;
inline constexpr unsigned FAULT_FAULT_STATUS_STREAM_CORRUPT_LSB = 0;
inline constexpr unsigned FAULT_FAULT_STATUS_STREAM_CORRUPT_WIDTH = 1;
inline constexpr std::uint32_t FAULT_FAULT_STATUS_STREAM_CORRUPT_MASK = 0x00000001u;
inline constexpr unsigned FAULT_FAULT_STATUS_SEQ_ERROR_LSB = 1;
inline constexpr unsigned FAULT_FAULT_STATUS_SEQ_ERROR_WIDTH = 1;
inline constexpr std::uint32_t FAULT_FAULT_STATUS_SEQ_ERROR_MASK = 0x00000002u;
inline constexpr unsigned FAULT_FAULT_STATUS_FIFO_OVERFLOW_LSB = 2;
inline constexpr unsigned FAULT_FAULT_STATUS_FIFO_OVERFLOW_WIDTH = 1;
inline constexpr std::uint32_t FAULT_FAULT_STATUS_FIFO_OVERFLOW_MASK = 0x00000004u;
inline constexpr unsigned FAULT_FAULT_STATUS_CDC_ERROR_LSB = 3;
inline constexpr unsigned FAULT_FAULT_STATUS_CDC_ERROR_WIDTH = 1;
inline constexpr std::uint32_t FAULT_FAULT_STATUS_CDC_ERROR_MASK = 0x00000008u;
inline constexpr unsigned FAULT_FAULT_STATUS_SATURATION_LSB = 4;
inline constexpr unsigned FAULT_FAULT_STATUS_SATURATION_WIDTH = 1;
inline constexpr std::uint32_t FAULT_FAULT_STATUS_SATURATION_MASK = 0x00000010u;
inline constexpr unsigned FAULT_FAULT_STATUS_PACKET_DROP_LSB = 5;
inline constexpr unsigned FAULT_FAULT_STATUS_PACKET_DROP_WIDTH = 1;
inline constexpr std::uint32_t FAULT_FAULT_STATUS_PACKET_DROP_MASK = 0x00000020u;
inline constexpr std::uint32_t FAULT_FAULT_COUNT_ADDR = 0x300Cu;
inline constexpr std::uint32_t FAULT_FAULT_COUNT_RESET = 0x00000000u;
inline constexpr unsigned FAULT_FAULT_COUNT_VALUE_LSB = 0;
inline constexpr unsigned FAULT_FAULT_COUNT_VALUE_WIDTH = 32;
inline constexpr std::uint32_t FAULT_FAULT_COUNT_VALUE_MASK = 0xFFFFFFFFu;

// scratch: Software scratch registers with no hardware effect.
inline constexpr std::uint32_t SCRATCH_BASE = 0x4000u;
inline constexpr std::uint32_t SCRATCH_SCRATCH0_ADDR = 0x4000u;
inline constexpr std::uint32_t SCRATCH_SCRATCH0_RESET = 0x00000000u;
inline constexpr unsigned SCRATCH_SCRATCH0_VALUE_LSB = 0;
inline constexpr unsigned SCRATCH_SCRATCH0_VALUE_WIDTH = 32;
inline constexpr std::uint32_t SCRATCH_SCRATCH0_VALUE_MASK = 0xFFFFFFFFu;
inline constexpr std::uint32_t SCRATCH_SCRATCH1_ADDR = 0x4004u;
inline constexpr std::uint32_t SCRATCH_SCRATCH1_RESET = 0xFFFFFFFFu;
inline constexpr unsigned SCRATCH_SCRATCH1_VALUE_LSB = 0;
inline constexpr unsigned SCRATCH_SCRATCH1_VALUE_WIDTH = 32;
inline constexpr std::uint32_t SCRATCH_SCRATCH1_VALUE_MASK = 0xFFFFFFFFu;
inline constexpr std::uint32_t SCRATCH_SCRATCH2_ADDR = 0x4008u;
inline constexpr std::uint32_t SCRATCH_SCRATCH2_RESET = 0xA5A5A5A5u;
inline constexpr unsigned SCRATCH_SCRATCH2_VALUE_LSB = 0;
inline constexpr unsigned SCRATCH_SCRATCH2_VALUE_WIDTH = 32;
inline constexpr std::uint32_t SCRATCH_SCRATCH2_VALUE_MASK = 0xFFFFFFFFu;
inline constexpr std::uint32_t SCRATCH_SCRATCH3_ADDR = 0x400Cu;
inline constexpr std::uint32_t SCRATCH_SCRATCH3_RESET = 0xDEAD5A5Au;
inline constexpr unsigned SCRATCH_SCRATCH3_RW_LOW_LSB = 0;
inline constexpr unsigned SCRATCH_SCRATCH3_RW_LOW_WIDTH = 16;
inline constexpr std::uint32_t SCRATCH_SCRATCH3_RW_LOW_MASK = 0x0000FFFFu;
inline constexpr unsigned SCRATCH_SCRATCH3_RO_HIGH_LSB = 16;
inline constexpr unsigned SCRATCH_SCRATCH3_RO_HIGH_WIDTH = 16;
inline constexpr std::uint32_t SCRATCH_SCRATCH3_RO_HIGH_MASK = 0xFFFF0000u;

// ---- planned windows (declared, not implemented in this build) ----------
// coeff 0x5000: planned by #10, #11, #12, #16. Accesses return error=1.
inline constexpr std::uint32_t COEFF_BASE = 0x5000u;
// cfar 0x6000: planned by #14, #16. Accesses return error=1.
inline constexpr std::uint32_t CFAR_BASE = 0x6000u;
// counters 0x7000: planned by #8. Accesses return error=1.
inline constexpr std::uint32_t COUNTERS_BASE = 0x7000u;
// debug 0x8000: planned by #19. Accesses return error=1.
inline constexpr std::uint32_t DEBUG_BASE = 0x8000u;

// ---- tables --------------------------------------------------------------
inline constexpr BlockInfo kBlocks[9] = {
    {"id", 0x0000u, 0x1000u, true, 4},
    {"build_params", 0x1000u, 0x1000u, true, 12},
    {"ctrl", 0x2000u, 0x1000u, true, 4},
    {"fault", 0x3000u, 0x1000u, true, 4},
    {"scratch", 0x4000u, 0x1000u, true, 4},
    {"coeff", 0x5000u, 0x1000u, false, 0},
    {"cfar", 0x6000u, 0x1000u, false, 0},
    {"counters", 0x7000u, 0x1000u, false, 0},
    {"debug", 0x8000u, 0x1000u, false, 0},
};

inline constexpr RegInfo kRegisters[28] = {
    {"id", "MAGIC", 0x0000u, 0, 0, Access::kRo, 0x52414441u, 0x00000000u, 0x00000000u, 0x00000000u, 0x00000000u, 0x00000000u},
    {"id", "VERSION", 0x0004u, 0, 1, Access::kRo, 0x01000001u, 0x00000000u, 0x00000000u, 0x00000000u, 0x00000000u, 0x00000000u},
    {"id", "GEOMETRY", 0x0008u, 0, 2, Access::kRo, 0x10201C09u, 0x00000000u, 0x00000000u, 0x00000000u, 0x00000000u, 0x00000000u},
    {"id", "CAPABILITY", 0x000Cu, 0, 3, Access::kRo, 0x0000001Fu, 0x00000000u, 0x00000000u, 0x00000000u, 0x00000000u, 0x00000000u},
    {"build_params", "N_ANTENNAS", 0x1000u, 1, 0, Access::kRoHw, 0x00000000u, 0x00000000u, 0x00000000u, 0x00000000u, 0xFFFFFFFFu, 0x00000000u},
    {"build_params", "SAMPLES_PER_CYCLE", 0x1004u, 1, 1, Access::kRoHw, 0x00000000u, 0x00000000u, 0x00000000u, 0x00000000u, 0xFFFFFFFFu, 0x00000000u},
    {"build_params", "FFT_SIZE", 0x1008u, 1, 2, Access::kRoHw, 0x00000000u, 0x00000000u, 0x00000000u, 0x00000000u, 0xFFFFFFFFu, 0x00000000u},
    {"build_params", "PFB_TAPS", 0x100Cu, 1, 3, Access::kRoHw, 0x00000000u, 0x00000000u, 0x00000000u, 0x00000000u, 0xFFFFFFFFu, 0x00000000u},
    {"build_params", "N_BEAMS", 0x1010u, 1, 4, Access::kRoHw, 0x00000000u, 0x00000000u, 0x00000000u, 0x00000000u, 0xFFFFFFFFu, 0x00000000u},
    {"build_params", "HISTORY_FRAMES", 0x1014u, 1, 5, Access::kRoHw, 0x00000000u, 0x00000000u, 0x00000000u, 0x00000000u, 0xFFFFFFFFu, 0x00000000u},
    {"build_params", "PACKET_W", 0x1018u, 1, 6, Access::kRoHw, 0x00000000u, 0x00000000u, 0x00000000u, 0x00000000u, 0xFFFFFFFFu, 0x00000000u},
    {"build_params", "SAMPLE_W", 0x101Cu, 1, 7, Access::kRoHw, 0x00000000u, 0x00000000u, 0x00000000u, 0x00000000u, 0xFFFFFFFFu, 0x00000000u},
    {"build_params", "COEFF_W", 0x1020u, 1, 8, Access::kRoHw, 0x00000000u, 0x00000000u, 0x00000000u, 0x00000000u, 0xFFFFFFFFu, 0x00000000u},
    {"build_params", "POWER_W", 0x1024u, 1, 9, Access::kRoHw, 0x00000000u, 0x00000000u, 0x00000000u, 0x00000000u, 0xFFFFFFFFu, 0x00000000u},
    {"build_params", "N_VIRTUAL_CHANS", 0x1028u, 1, 10, Access::kRoHw, 0x00000000u, 0x00000000u, 0x00000000u, 0x00000000u, 0xFFFFFFFFu, 0x00000000u},
    {"build_params", "PARAM_CHECKSUM", 0x102Cu, 1, 11, Access::kRoHw, 0x00000000u, 0x00000000u, 0x00000000u, 0x00000000u, 0xFFFFFFFFu, 0x00000000u},
    {"ctrl", "BLOCK_ENABLE", 0x2000u, 2, 0, Access::kRw, 0x000000FFu, 0x000000FFu, 0x00000000u, 0x00000000u, 0x00000000u, 0x000000FFu},
    {"ctrl", "BLOCK_RESET", 0x2004u, 2, 1, Access::kRwp, 0x00000000u, 0x00000000u, 0x00000000u, 0x000000FFu, 0x00000000u, 0x000000FFu},
    {"ctrl", "GLOBAL_CTRL", 0x2008u, 2, 2, Access::kMixed, 0x00000001u, 0x00000001u, 0x00000000u, 0x00000006u, 0x00000000u, 0x00000007u},
    {"ctrl", "CTRL_STATUS", 0x200Cu, 2, 3, Access::kRoHw, 0x00000000u, 0x00000000u, 0x00000000u, 0x00000000u, 0x0000010Fu, 0x00000000u},
    {"fault", "FAULT_ENABLE", 0x3000u, 3, 0, Access::kRw, 0x00000000u, 0x0000003Fu, 0x00000000u, 0x00000000u, 0x00000000u, 0x0000003Fu},
    {"fault", "FAULT_INJECT", 0x3004u, 3, 1, Access::kRwp, 0x00000000u, 0x00000000u, 0x00000000u, 0x0000003Fu, 0x00000000u, 0x0000003Fu},
    {"fault", "FAULT_STATUS", 0x3008u, 3, 2, Access::kW1c, 0x00000000u, 0x00000000u, 0x0000003Fu, 0x00000000u, 0x00000000u, 0x0000003Fu},
    {"fault", "FAULT_COUNT", 0x300Cu, 3, 3, Access::kRoHw, 0x00000000u, 0x00000000u, 0x00000000u, 0x00000000u, 0xFFFFFFFFu, 0x00000000u},
    {"scratch", "SCRATCH0", 0x4000u, 4, 0, Access::kRw, 0x00000000u, 0xFFFFFFFFu, 0x00000000u, 0x00000000u, 0x00000000u, 0xFFFFFFFFu},
    {"scratch", "SCRATCH1", 0x4004u, 4, 1, Access::kRw, 0xFFFFFFFFu, 0xFFFFFFFFu, 0x00000000u, 0x00000000u, 0x00000000u, 0xFFFFFFFFu},
    {"scratch", "SCRATCH2", 0x4008u, 4, 2, Access::kRw, 0xA5A5A5A5u, 0xFFFFFFFFu, 0x00000000u, 0x00000000u, 0x00000000u, 0xFFFFFFFFu},
    {"scratch", "SCRATCH3", 0x400Cu, 4, 3, Access::kMixed, 0xDEAD5A5Au, 0x0000FFFFu, 0x00000000u, 0x00000000u, 0x00000000u, 0x0000FFFFu},
};

inline constexpr FieldInfo kFields[67] = {
    {"id", "MAGIC", "MAGIC", 0, 32, 0xFFFFFFFFu, Access::kRo, 0x52414441u},
    {"id", "VERSION", "MAJOR", 24, 8, 0xFF000000u, Access::kRo, 0x00000001u},
    {"id", "VERSION", "MINOR", 16, 8, 0x00FF0000u, Access::kRo, 0x00000000u},
    {"id", "VERSION", "PATCH", 8, 8, 0x0000FF00u, Access::kRo, 0x00000000u},
    {"id", "VERSION", "SCHEMA", 0, 8, 0x000000FFu, Access::kRo, 0x00000001u},
    {"id", "GEOMETRY", "N_BLOCKS", 0, 8, 0x000000FFu, Access::kRo, 0x00000009u},
    {"id", "GEOMETRY", "N_REGS", 8, 8, 0x0000FF00u, Access::kRo, 0x0000001Cu},
    {"id", "GEOMETRY", "DATA_W", 16, 8, 0x00FF0000u, Access::kRo, 0x00000020u},
    {"id", "GEOMETRY", "ADDR_W", 24, 8, 0xFF000000u, Access::kRo, 0x00000010u},
    {"id", "CAPABILITY", "BLOCK_MASK", 0, 32, 0xFFFFFFFFu, Access::kRo, 0x0000001Fu},
    {"build_params", "N_ANTENNAS", "VALUE", 0, 32, 0xFFFFFFFFu, Access::kRoHw, 0x00000000u},
    {"build_params", "SAMPLES_PER_CYCLE", "VALUE", 0, 32, 0xFFFFFFFFu, Access::kRoHw, 0x00000000u},
    {"build_params", "FFT_SIZE", "VALUE", 0, 32, 0xFFFFFFFFu, Access::kRoHw, 0x00000000u},
    {"build_params", "PFB_TAPS", "VALUE", 0, 32, 0xFFFFFFFFu, Access::kRoHw, 0x00000000u},
    {"build_params", "N_BEAMS", "VALUE", 0, 32, 0xFFFFFFFFu, Access::kRoHw, 0x00000000u},
    {"build_params", "HISTORY_FRAMES", "VALUE", 0, 32, 0xFFFFFFFFu, Access::kRoHw, 0x00000000u},
    {"build_params", "PACKET_W", "VALUE", 0, 32, 0xFFFFFFFFu, Access::kRoHw, 0x00000000u},
    {"build_params", "SAMPLE_W", "VALUE", 0, 32, 0xFFFFFFFFu, Access::kRoHw, 0x00000000u},
    {"build_params", "COEFF_W", "VALUE", 0, 32, 0xFFFFFFFFu, Access::kRoHw, 0x00000000u},
    {"build_params", "POWER_W", "VALUE", 0, 32, 0xFFFFFFFFu, Access::kRoHw, 0x00000000u},
    {"build_params", "N_VIRTUAL_CHANS", "VALUE", 0, 32, 0xFFFFFFFFu, Access::kRoHw, 0x00000000u},
    {"build_params", "PARAM_CHECKSUM", "VALUE", 0, 32, 0xFFFFFFFFu, Access::kRoHw, 0x00000000u},
    {"ctrl", "BLOCK_ENABLE", "PFB", 0, 1, 0x00000001u, Access::kRw, 0x00000001u},
    {"ctrl", "BLOCK_ENABLE", "FFT", 1, 1, 0x00000002u, Access::kRw, 0x00000001u},
    {"ctrl", "BLOCK_ENABLE", "BEAMFORMER", 2, 1, 0x00000004u, Access::kRw, 0x00000001u},
    {"ctrl", "BLOCK_ENABLE", "COVARIANCE", 3, 1, 0x00000008u, Access::kRw, 0x00000001u},
    {"ctrl", "BLOCK_ENABLE", "CFAR", 4, 1, 0x00000010u, Access::kRw, 0x00000001u},
    {"ctrl", "BLOCK_ENABLE", "PACKET", 5, 1, 0x00000020u, Access::kRw, 0x00000001u},
    {"ctrl", "BLOCK_ENABLE", "MEMORY", 6, 1, 0x00000040u, Access::kRw, 0x00000001u},
    {"ctrl", "BLOCK_ENABLE", "TELEMETRY", 7, 1, 0x00000080u, Access::kRw, 0x00000001u},
    {"ctrl", "BLOCK_RESET", "PFB", 0, 1, 0x00000001u, Access::kRwp, 0x00000000u},
    {"ctrl", "BLOCK_RESET", "FFT", 1, 1, 0x00000002u, Access::kRwp, 0x00000000u},
    {"ctrl", "BLOCK_RESET", "BEAMFORMER", 2, 1, 0x00000004u, Access::kRwp, 0x00000000u},
    {"ctrl", "BLOCK_RESET", "COVARIANCE", 3, 1, 0x00000008u, Access::kRwp, 0x00000000u},
    {"ctrl", "BLOCK_RESET", "CFAR", 4, 1, 0x00000010u, Access::kRwp, 0x00000000u},
    {"ctrl", "BLOCK_RESET", "PACKET", 5, 1, 0x00000020u, Access::kRwp, 0x00000000u},
    {"ctrl", "BLOCK_RESET", "MEMORY", 6, 1, 0x00000040u, Access::kRwp, 0x00000000u},
    {"ctrl", "BLOCK_RESET", "TELEMETRY", 7, 1, 0x00000080u, Access::kRwp, 0x00000000u},
    {"ctrl", "GLOBAL_CTRL", "GLOBAL_ENABLE", 0, 1, 0x00000001u, Access::kRw, 0x00000001u},
    {"ctrl", "GLOBAL_CTRL", "FLUSH", 1, 1, 0x00000002u, Access::kRwp, 0x00000000u},
    {"ctrl", "GLOBAL_CTRL", "SOFT_RESET", 2, 1, 0x00000004u, Access::kRwp, 0x00000000u},
    {"ctrl", "CTRL_STATUS", "ENABLED_COUNT", 0, 4, 0x0000000Fu, Access::kRoHw, 0x00000000u},
    {"ctrl", "CTRL_STATUS", "ALIVE", 8, 1, 0x00000100u, Access::kRoHw, 0x00000000u},
    {"fault", "FAULT_ENABLE", "STREAM_CORRUPT", 0, 1, 0x00000001u, Access::kRw, 0x00000000u},
    {"fault", "FAULT_ENABLE", "SEQ_ERROR", 1, 1, 0x00000002u, Access::kRw, 0x00000000u},
    {"fault", "FAULT_ENABLE", "FIFO_OVERFLOW", 2, 1, 0x00000004u, Access::kRw, 0x00000000u},
    {"fault", "FAULT_ENABLE", "CDC_ERROR", 3, 1, 0x00000008u, Access::kRw, 0x00000000u},
    {"fault", "FAULT_ENABLE", "SATURATION", 4, 1, 0x00000010u, Access::kRw, 0x00000000u},
    {"fault", "FAULT_ENABLE", "PACKET_DROP", 5, 1, 0x00000020u, Access::kRw, 0x00000000u},
    {"fault", "FAULT_INJECT", "STREAM_CORRUPT", 0, 1, 0x00000001u, Access::kRwp, 0x00000000u},
    {"fault", "FAULT_INJECT", "SEQ_ERROR", 1, 1, 0x00000002u, Access::kRwp, 0x00000000u},
    {"fault", "FAULT_INJECT", "FIFO_OVERFLOW", 2, 1, 0x00000004u, Access::kRwp, 0x00000000u},
    {"fault", "FAULT_INJECT", "CDC_ERROR", 3, 1, 0x00000008u, Access::kRwp, 0x00000000u},
    {"fault", "FAULT_INJECT", "SATURATION", 4, 1, 0x00000010u, Access::kRwp, 0x00000000u},
    {"fault", "FAULT_INJECT", "PACKET_DROP", 5, 1, 0x00000020u, Access::kRwp, 0x00000000u},
    {"fault", "FAULT_STATUS", "STREAM_CORRUPT", 0, 1, 0x00000001u, Access::kW1c, 0x00000000u},
    {"fault", "FAULT_STATUS", "SEQ_ERROR", 1, 1, 0x00000002u, Access::kW1c, 0x00000000u},
    {"fault", "FAULT_STATUS", "FIFO_OVERFLOW", 2, 1, 0x00000004u, Access::kW1c, 0x00000000u},
    {"fault", "FAULT_STATUS", "CDC_ERROR", 3, 1, 0x00000008u, Access::kW1c, 0x00000000u},
    {"fault", "FAULT_STATUS", "SATURATION", 4, 1, 0x00000010u, Access::kW1c, 0x00000000u},
    {"fault", "FAULT_STATUS", "PACKET_DROP", 5, 1, 0x00000020u, Access::kW1c, 0x00000000u},
    {"fault", "FAULT_COUNT", "VALUE", 0, 32, 0xFFFFFFFFu, Access::kRoHw, 0x00000000u},
    {"scratch", "SCRATCH0", "VALUE", 0, 32, 0xFFFFFFFFu, Access::kRw, 0x00000000u},
    {"scratch", "SCRATCH1", "VALUE", 0, 32, 0xFFFFFFFFu, Access::kRw, 0xFFFFFFFFu},
    {"scratch", "SCRATCH2", "VALUE", 0, 32, 0xFFFFFFFFu, Access::kRw, 0xA5A5A5A5u},
    {"scratch", "SCRATCH3", "RW_LOW", 0, 16, 0x0000FFFFu, Access::kRw, 0x00005A5Au},
    {"scratch", "SCRATCH3", "RO_HIGH", 16, 16, 0xFFFF0000u, Access::kRo, 0x0000DEADu},
};

inline constexpr std::size_t kBlockTableSize = sizeof(kBlocks) / sizeof(kBlocks[0]);
inline constexpr std::size_t kRegisterTableSize = sizeof(kRegisters) / sizeof(kRegisters[0]);
inline constexpr std::size_t kFieldTableSize = sizeof(kFields) / sizeof(kFields[0]);

// True when `address` falls inside an implemented block window.
constexpr bool address_mapped(std::uint32_t address) {
  for (std::size_t i = 0; i < kBlockTableSize; ++i) {
    if (!kBlocks[i].implemented) continue;
    if (address >= kBlocks[i].base && address < kBlocks[i].base + kBlocks[i].size) {
      return address - kBlocks[i].base < kBlocks[i].reg_count * 4u;
    }
  }
  return false;
}

// The RegInfo for `address`, or nullptr when the address is not a register.
constexpr const RegInfo* find(std::uint32_t address) {
  for (std::size_t i = 0; i < kRegisterTableSize; ++i) {
    if (kRegisters[i].address == address) return &kRegisters[i];
  }
  return nullptr;
}

// Extracts a field from a register value read back from the DUT.
constexpr std::uint32_t field_get(std::uint32_t value, unsigned lsb, unsigned width) {
  return (value >> lsb) & (width >= 32u ? 0xFFFFFFFFu : ((1u << width) - 1u));
}

// Inserts a field into a register value, leaving every other bit alone.
constexpr std::uint32_t field_set(std::uint32_t value, unsigned lsb, unsigned width,
                                  std::uint32_t field) {
  const std::uint32_t m = (width >= 32u ? 0xFFFFFFFFu : ((1u << width) - 1u)) << lsb;
  return (value & ~m) | ((field << lsb) & m);
}

}  // namespace regmap

#endif  // MODEL_CPP_REGMAP_REGMAP_HPP_
