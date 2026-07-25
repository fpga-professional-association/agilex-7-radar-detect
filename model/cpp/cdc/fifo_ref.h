// -----------------------------------------------------------------------------
// fifo_ref.h — bit-accurate C++ reference models for the issue #6 FIFOs.
//
// SPEC 12.4 requires a bit-accurate C++ reference model that the RTL is checked
// against, rather than a test that only checks the RTL against itself. This
// header carries two, one for each FIFO, and they are deliberately different in
// kind because the two FIFOs are:
//
//   SyncFifoRef            an EXACT cycle-accurate mirror of rtl/common/
//                          sync_fifo.sv. Every observable — s_ready, m_valid,
//                          occupancy, full, empty, almost_full, almost_empty,
//                          high_water — is predicted from the handshake alone
//                          and compared against the RTL on every cycle. It reads
//                          nothing from the DUT, so a disagreement is a real
//                          disagreement and not a restatement.
//
//   AsyncFifoBoundsRef     the invariants of rtl/cdc/async_fifo.sv. An exact
//                          cycle-accurate mirror of a DUAL-clock FIFO would have
//                          to reproduce the pointer synchronizers' staleness,
//                          which means reproducing the exact interleaving of two
//                          asynchronous clocks — and the resulting "reference"
//                          would be the same design written twice, agreeing with
//                          the RTL for the same reason a copy agrees with its
//                          original. What is actually specified about the two
//                          occupancy ports is a set of BOUNDS (each side's
//                          estimate is conservative in its own safe direction),
//                          and bounds are exactly what this class checks. Data
//                          integrity across the crossing is proved separately,
//                          by the harness scoreboard on transaction identity.
//
// The high-water rule is shared, and is the same in both FIFOs by construction:
//
//     high_water(n) = max( occupancy(0) .. occupancy(n-1) )
//
// i.e. the greatest occupancy held up to and INCLUDING THE PREVIOUS CYCLE. Both
// RTL modules implement `high <= (occ > high) ? occ : high`, so one rule and one
// checker cover both. Getting this off by one cycle is the classic way a
// high-water mark silently under-reports the peak that sized the buffer.
//
// Header-only, no dependencies beyond the standard library, so a test includes
// it and a future standalone model build does too.
// -----------------------------------------------------------------------------
#ifndef MODEL_CDC_FIFO_REF_H_
#define MODEL_CDC_FIFO_REF_H_

#include <cstdint>
#include <string>

namespace model {

// ---------------------------------------------------------------------------
// SyncFifoRef — exact mirror of rtl/common/sync_fifo.sv.
//
// Usage, once per cycle, in the scheduler's kSample phase (which observes the
// values the RTL is about to capture):
//
//     std::string bad = ref.check(rtl_observables...);   // compare
//     ref.step(s_valid, m_ready);                        // advance
//
// `check` returns an empty string when everything agrees, or a description of
// the first disagreement.
// ---------------------------------------------------------------------------
class SyncFifoRef {
 public:
  SyncFifoRef(unsigned depth, unsigned almost_full_threshold,
              unsigned almost_empty_threshold, bool show_ahead)
      : depth_(depth),
        af_(almost_full_threshold),
        ae_(almost_empty_threshold),
        show_ahead_(show_ahead) {}

  void reset() {
    count_ = 0;
    out_valid_ = false;
    high_ = 0;
    cycles_ = 0;
  }

  // ---- predicted observables, for the current cycle ----
  unsigned occupancy() const { return count_; }
  unsigned high_water() const { return high_; }
  bool full() const { return count_ == depth_; }
  bool empty() const { return count_ == 0; }
  bool almost_full() const { return count_ >= af_; }
  bool almost_empty() const { return count_ <= ae_; }
  bool s_ready() const { return count_ != depth_; }
  bool m_valid() const { return show_ahead_ ? (count_ != 0) : out_valid_; }

  std::uint64_t cycles() const { return cycles_; }
  unsigned peak() const { return peak_; }

  // Advance one cycle given the handshake inputs the harness drove.
  void step(bool s_valid, bool m_ready) {
    const bool wr = s_valid && s_ready();
    const bool core_valid = (count_ != 0);
    const bool core_ready = show_ahead_ ? m_ready : (!out_valid_ || m_ready);
    const bool rd = core_valid && core_ready;

    if (high_ < count_) high_ = count_;
    if (peak_ < count_) peak_ = count_;

    if (!show_ahead_ && core_ready) out_valid_ = core_valid;

    count_ = count_ + (wr ? 1u : 0u) - (rd ? 1u : 0u);
    ++cycles_;
  }

  // Compare every observable against the RTL. Empty string means agreement.
  std::string check(bool rtl_s_ready, bool rtl_m_valid, unsigned rtl_occupancy,
                    unsigned rtl_high_water, bool rtl_full, bool rtl_empty,
                    bool rtl_almost_full, bool rtl_almost_empty) const {
    if (rtl_s_ready != s_ready()) return mismatch("s_ready", rtl_s_ready, s_ready());
    if (rtl_m_valid != m_valid()) return mismatch("m_valid", rtl_m_valid, m_valid());
    if (rtl_occupancy != occupancy()) {
      return mismatch("occupancy", rtl_occupancy, occupancy());
    }
    if (rtl_high_water != high_water()) {
      return mismatch("high_water", rtl_high_water, high_water());
    }
    if (rtl_full != full()) return mismatch("full", rtl_full, full());
    if (rtl_empty != empty()) return mismatch("empty", rtl_empty, empty());
    if (rtl_almost_full != almost_full()) {
      return mismatch("almost_full", rtl_almost_full, almost_full());
    }
    if (rtl_almost_empty != almost_empty()) {
      return mismatch("almost_empty", rtl_almost_empty, almost_empty());
    }
    return std::string();
  }

 private:
  static std::string mismatch(const char* what, unsigned rtl, unsigned ref) {
    return std::string(what) + ": RTL says " + std::to_string(rtl) +
           ", the reference model says " + std::to_string(ref);
  }

  unsigned depth_;
  unsigned af_;
  unsigned ae_;
  bool show_ahead_;

  unsigned count_ = 0;
  bool out_valid_ = false;
  unsigned high_ = 0;
  unsigned peak_ = 0;
  std::uint64_t cycles_ = 0;
};

// ---------------------------------------------------------------------------
// AsyncFifoBoundsRef — the invariants of rtl/cdc/async_fifo.sv, checked per
// domain in that domain's own sample phase.
//
// What each side's occupancy port means, and therefore what is checkable:
//
//   write side   computed against a read pointer up to SYNC_STAGES read cycles
//                stale, so it is an OVER-estimate of the true fill and can never
//                read low. A producer's credit scheme must use this number.
//   read side    computed against a stale write pointer, so it is an
//                UNDER-estimate and can never read high.
//
// Neither is comparable to the other at a single instant in a testbench that
// samples two asynchronous clocks, and pretending otherwise produces a flaky
// test rather than a strong one. What holds unconditionally, and is checked:
//
//   * each side's occupancy is within 0..DEPTH;
//   * each side's high-water mark follows the shared rule above, exactly,
//     within its own domain;
//   * a high-water mark never decreases and never exceeds DEPTH;
//   * the sticky overflow and underflow flags stay clear.
//
// The total-in-flight capacity bound (beats accepted minus beats emitted never
// exceeds DEPTH plus the output register) is a cross-domain property and is
// checked by the test directly, not here.
// ---------------------------------------------------------------------------
class AsyncFifoBoundsRef {
 public:
  explicit AsyncFifoBoundsRef(unsigned depth) : depth_(depth) {}

  void reset() {
    high_ = 0;
    last_high_ = 0;
    peak_ = 0;
    started_ = false;
  }

  unsigned peak() const { return peak_; }

  // One sample of one domain's ports. Returns an empty string on agreement.
  std::string check(const char* side, unsigned occupancy, unsigned high_water,
                    bool overflow_or_underflow_sticky) {
    if (occupancy > depth_) {
      return std::string(side) + " occupancy " + std::to_string(occupancy) +
             " exceeds DEPTH " + std::to_string(depth_);
    }
    if (high_water > depth_) {
      return std::string(side) + " high-water mark " +
             std::to_string(high_water) + " exceeds DEPTH " +
             std::to_string(depth_);
    }
    if (overflow_or_underflow_sticky) {
      return std::string(side) + " sticky error flag is set";
    }
    if (started_ && high_water < last_high_) {
      return std::string(side) + " high-water mark fell from " +
             std::to_string(last_high_) + " to " + std::to_string(high_water);
    }
    if (started_ && high_water != high_) {
      return std::string(side) + " high-water mark is " +
             std::to_string(high_water) + ", but the maximum occupancy up to " +
             "the previous cycle was " + std::to_string(high_);
    }
    // Advance the shared high-water rule with this cycle's occupancy.
    if (high_ < occupancy) high_ = occupancy;
    if (peak_ < occupancy) peak_ = occupancy;
    last_high_ = high_water;
    started_ = true;
    return std::string();
  }

 private:
  unsigned depth_;
  unsigned high_ = 0;
  unsigned last_high_ = 0;
  unsigned peak_ = 0;
  bool started_ = false;
};

}  // namespace model

#endif  // MODEL_CDC_FIFO_REF_H_
