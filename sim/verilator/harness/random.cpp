#include "harness/random.h"

namespace harness {

std::uint64_t splitmix64(std::uint64_t x) {
  x += 0x9E3779B97F4A7C15ULL;
  std::uint64_t z = x;
  z = (z ^ (z >> 30)) * 0xBF58476D1CE4E5B9ULL;
  z = (z ^ (z >> 27)) * 0x94D049BB133111EBULL;
  return z ^ (z >> 31);
}

std::uint64_t hash_name(std::string_view name) {
  std::uint64_t h = 0xCBF29CE484222325ULL;  // FNV-1a 64-bit offset basis
  for (char c : name) {
    h ^= static_cast<std::uint64_t>(static_cast<unsigned char>(c));
    h *= 0x100000001B3ULL;
  }
  return h;
}

std::uint64_t uniform_u64(std::mt19937_64& rng, std::uint64_t lo,
                          std::uint64_t hi) {
  if (hi <= lo) return lo;
  const std::uint64_t span = hi - lo;             // inclusive range width - 1
  if (span == UINT64_MAX) return rng();
  const std::uint64_t n = span + 1;
  // Rejection sampling: discard the short final bucket so every value in
  // [0, n) is equally likely regardless of n.
  const std::uint64_t limit = UINT64_MAX - (UINT64_MAX % n);
  std::uint64_t r;
  do {
    r = rng();
  } while (r >= limit);
  return lo + (r % n);
}

bool bernoulli(std::mt19937_64& rng, double p) {
  if (p <= 0.0) return false;
  if (p >= 1.0) return true;
  // Resolve on a 2^32 grid: exact, cheap, and free of libstdc++ distribution
  // internals.
  const std::uint64_t threshold =
      static_cast<std::uint64_t>(p * 4294967296.0);  // p * 2^32
  return (rng() >> 32) < threshold;
}

bool BackpressureGenerator::allow() {
  if (stall_remaining_ > 0) {
    --stall_remaining_;
    ++stall_cycles_;
    return false;
  }
  if (bernoulli(rng_, cfg_.stall_probability)) {
    const std::uint64_t len =
        uniform_u64(rng_, cfg_.burst_min == 0 ? 1u : cfg_.burst_min,
                    cfg_.burst_max < cfg_.burst_min ? cfg_.burst_min
                                                    : cfg_.burst_max);
    // This cycle is the first stall cycle of the burst.
    stall_remaining_ = static_cast<std::uint32_t>(len - 1);
    ++stall_cycles_;
    return false;
  }
  ++active_cycles_;
  return true;
}

}  // namespace harness
