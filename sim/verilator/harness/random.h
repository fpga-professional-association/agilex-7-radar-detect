// -----------------------------------------------------------------------------
// random.h — deterministic seeded randomness and backpressure generation.
//
// SPEC 12.2 requires "deterministic random seeds"; SPEC 13.3 requires that every
// failing seed be replayable. Two rules follow, and both are enforced here:
//
//   1. One master seed per run, printed on every run (pass or fail) by
//      sim_main.cpp. Everything random derives from it.
//   2. Independent named substreams. A substream's sequence depends only on the
//      master seed and the substream name, never on how many other substreams
//      exist or on the order in which they are drawn from. Adding a monitor to
//      a test therefore does not perturb the driver's stall pattern, so a seed
//      that reproduced a failure yesterday still reproduces it today.
//
// The bounded-integer and Bernoulli draws are implemented here rather than with
// std::uniform_int_distribution / std::bernoulli_distribution because the
// standard does not specify the distributions' algorithms: two libstdc++
// versions may map the same engine output to different values. std::mt19937_64
// itself *is* specified bit-exactly, so deriving everything from raw engine
// output keeps runs reproducible across toolchains.
// -----------------------------------------------------------------------------
#ifndef HARNESS_RANDOM_H_
#define HARNESS_RANDOM_H_

#include <cstdint>
#include <random>
#include <string>
#include <string_view>

namespace harness {

// SplitMix64 — used only to decorrelate substream seeds, never for stimulus.
std::uint64_t splitmix64(std::uint64_t x);

// FNV-1a over the substream name.
std::uint64_t hash_name(std::string_view name);

// Derives named, mutually independent engines from one master seed.
class SeedSource {
 public:
  explicit SeedSource(std::uint64_t master) : master_(master) {}

  std::uint64_t master() const { return master_; }

  // Seed for a named substream. Pure function of (master, name).
  std::uint64_t substream_seed(std::string_view name) const {
    return splitmix64(master_ ^ splitmix64(hash_name(name)));
  }

  std::mt19937_64 engine(std::string_view name) const {
    return std::mt19937_64(substream_seed(name));
  }

 private:
  std::uint64_t master_;
};

// Uniform integer in [lo, hi] inclusive, by rejection. Unbiased and
// implementation-independent.
std::uint64_t uniform_u64(std::mt19937_64& rng, std::uint64_t lo,
                          std::uint64_t hi);

// True with probability p (clamped to [0,1]), resolved on a 2^32 grid.
bool bernoulli(std::mt19937_64& rng, double p);

// -----------------------------------------------------------------------------
// Randomized backpressure (SPEC 12.2 "randomized backpressure", SPEC 5
// "Backpressure may occur on every internal interface").
//
// Bursty rather than per-cycle-independent: independent coin flips produce
// geometric stalls of mean 1/(1-p) and almost never exercise a long stall, which
// is exactly the case that breaks skid buffers and frame boundaries. Here a
// stall is *started* with probability `stall_probability` and then lasts a
// uniformly chosen `burst_min..burst_max` cycles.
// -----------------------------------------------------------------------------
struct BackpressureConfig {
  double stall_probability = 0.0;  // per-cycle probability of starting a stall
  std::uint32_t burst_min = 1;     // stall length, inclusive lower bound
  std::uint32_t burst_max = 1;     // stall length, inclusive upper bound

  static BackpressureConfig none() { return BackpressureConfig{}; }
  static BackpressureConfig light() { return BackpressureConfig{0.10, 1, 2}; }
  static BackpressureConfig heavy() { return BackpressureConfig{0.50, 1, 8}; }
  static BackpressureConfig bursty() { return BackpressureConfig{0.20, 4, 40}; }
};

class BackpressureGenerator {
 public:
  BackpressureGenerator(std::mt19937_64 rng, BackpressureConfig cfg)
      : rng_(rng), cfg_(cfg) {}

  // Call exactly once per cycle in which the interface would otherwise be
  // active. Returns true if the interface may proceed this cycle.
  bool allow();

  // Restarts the stall state machine without reseeding, so a per-pass reset
  // does not replay the identical stall pattern.
  void clear_state() { stall_remaining_ = 0; }

  std::uint64_t stall_cycles() const { return stall_cycles_; }
  std::uint64_t active_cycles() const { return active_cycles_; }
  const BackpressureConfig& config() const { return cfg_; }

 private:
  std::mt19937_64 rng_;
  BackpressureConfig cfg_;
  std::uint32_t stall_remaining_ = 0;
  std::uint64_t stall_cycles_ = 0;
  std::uint64_t active_cycles_ = 0;
};

}  // namespace harness

#endif  // HARNESS_RANDOM_H_
