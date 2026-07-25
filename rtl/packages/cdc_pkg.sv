// -----------------------------------------------------------------------------
// cdc_pkg — shared clock-domain-crossing definitions (SPEC.md 8).
//
// SPEC 8 states the crossing rules this package and rtl/cdc/ implement:
//
//     * Use asynchronous FIFOs for bulk CDC traffic.
//     * Use proper synchronizers for single-bit status.
//     * Use toggle or handshake synchronizers for pulses.
//     * Use Gray-coded pointers for asynchronous FIFOs.
//     * Do not synchronize a multibit bus by independently synchronizing every bit.
//     * Add CDC-specific assertions.
//     * Generate an explicit CDC inventory report.
//
// This package is the single definition of the two things every crossing in the
// design shares: the Gray code, and the default synchronizer depth. Nothing in
// rtl/cdc/ writes `(b >> 1) ^ b` inline, for the same reason nothing in
// rtl/stream/ writes its own payload concatenation — a second expression for a
// shared encoding is a second definition of it.
//
// Working types (the stream_pkg / fxp_pkg pattern, for the same reason)
// ---------------------------------------------------------------------
// SystemVerilog has no parameterised functions (IEEE 1800-2017 has no
// `function #(...)`), so the Gray helpers work on a maximum-width type and take
// the instance's pointer width as an argument. `CDC_MAX_PTR_W` = 32 bounds that
// working type: an asynchronous FIFO pointer is $clog2(DEPTH)+1 bits, so 32 bits
// covers every depth up to 2^31 entries, which is far past anything this device
// can hold.
//
// Everything here is exported as a function rather than as a package localparam.
// Same measured reason as stream_pkg: `verilator --lint-only --Wall` reports a
// package localparam that a particular build's file list never reads as
// UNUSEDPARAM, and this project lints one top at a time (files.f, files_cdc.f,
// files_stream.f, ...). A function is available to every build and dead in none.
//
// Lint contract: linted by `make lint` on every run, clean under --Wall with no
// waiver.
// -----------------------------------------------------------------------------

`default_nettype none

package cdc_pkg;

  // ---------------------------------------------------------------------------
  // Working types
  // ---------------------------------------------------------------------------

  // Unsigned 32-bit integer, so widths can be cast explicitly (`uint_t'(x)`);
  // `int unsigned'(x)` is not legal cast syntax. Spelled the same way as
  // stream_pkg::uint_t and fxp_pkg::uint_t on purpose.
  typedef int unsigned uint_t;

  // Bound on any pointer this package encodes. See the header note.
  localparam int unsigned CDC_MAX_PTR_W = 32;

  // Maximum-width working value for the Gray helpers.
  typedef logic [CDC_MAX_PTR_W-1:0] cdc_word_t;

  // ---------------------------------------------------------------------------
  // Synchronizer depth
  // ---------------------------------------------------------------------------

  // Default flip-flop count in a synchronizer chain.
  //
  // Two, not three. The MTBF of a two-stage synchronizer on Agilex 7 at the
  // SPEC 8 clock rates is many orders of magnitude beyond the life of the
  // benchmark, and every extra stage is a cycle of latency on every status bit
  // and on both pointer paths of every asynchronous FIFO — latency that shows up
  // directly as asynchronous-FIFO occupancy, because the pointer a domain sees
  // is that many cycles stale. Three stages is available per instance
  // (`STAGES` on cdc_sync2) and is the right choice for a bit whose failure is
  // unrecoverable rather than merely lossy; nothing in this design is in that
  // class today. Recorded in DECISIONS.md.
  function automatic uint_t cdc_sync_stages_default();
    return 32'd2;
  endfunction

  // Minimum legal chain depth. One flop is not a synchronizer.
  function automatic uint_t cdc_sync_stages_min();
    return 32'd2;
  endfunction

  // ---------------------------------------------------------------------------
  // Gray code (NORMATIVE for this design)
  //
  // Standard reflected binary Gray code:  g = b ^ (b >> 1).
  //
  // The property the asynchronous FIFO depends on, and the one
  // sim/assertions/cdc_sva.svh checks on every pointer in the design: successive
  // values differ in exactly one bit, so a pointer sampled by the other domain
  // while it is changing resolves either to the old value or to the new one, and
  // never to a third value that was never a real pointer.
  //
  // `w` is the pointer width in bits. Bits at or above `w` are masked off, so a
  // caller that passes a wider working value cannot leak a high bit into the
  // encoding.
  // ---------------------------------------------------------------------------

  // `w` low bits set. w == 0 yields 0; w >= CDC_MAX_PTR_W yields all ones.
  function automatic cdc_word_t cdc_mask(input uint_t w);
    if (w == 32'd0) return '0;
    if (w >= uint_t'(CDC_MAX_PTR_W)) return '1;
    return (cdc_word_t'(1) << w) - cdc_word_t'(1);
  endfunction

  function automatic cdc_word_t cdc_bin2gray(input uint_t w, input cdc_word_t b);
    cdc_word_t m;
    m = cdc_mask(w);
    return ((b & m) ^ ((b & m) >> 1)) & m;
  endfunction

  // Inverse of cdc_bin2gray. The identity is b[i] = ^g[w-1:i], i.e. each binary
  // bit is the XOR of the Gray bits at or above it. Written directly as that
  // reduction rather than as a sequential recurrence so it is one expression per
  // bit and obviously combinational.
  //
  // Bits at or above `w` are already zero in `gm`, so the loop runs over the
  // whole working type without a bound test: for i >= w the shifted value is
  // zero and the bit comes out zero.
  function automatic cdc_word_t cdc_gray2bin(input uint_t w, input cdc_word_t g);
    cdc_word_t b;
    cdc_word_t gm;
    gm = g & cdc_mask(w);
    b  = '0;
    for (int unsigned i = 0; i < CDC_MAX_PTR_W; i++) begin
      b[i] = ^(gm >> i);
    end
    return b & cdc_mask(w);
  endfunction

  // True when `next` is a legal successor of `prev` on a Gray-coded pointer:
  // either unchanged (no update this cycle) or exactly one bit different.
  // This is the SPEC 14 "Gray-pointer one-bit transitions" predicate; the
  // assertion macros call it so the rule exists once.
  function automatic logic cdc_gray_step_ok(input cdc_word_t prev,
                                            input cdc_word_t next);
    return ($countones(prev ^ next) <= 1);
  endfunction

  // ---------------------------------------------------------------------------
  // Asynchronous-FIFO pointer geometry
  //
  // A DEPTH-entry FIFO uses a $clog2(DEPTH)+1-bit pointer: the extra top bit is
  // what distinguishes "empty" from "full" when the two pointers have equal
  // address bits (Cummings, SNUG 2002, "Simulation and Synthesis Techniques for
  // Asynchronous FIFO Design"). Named here so that async_fifo, its assertions
  // and the C++ model all derive the width from one expression.
  // ---------------------------------------------------------------------------

  function automatic uint_t cdc_addr_w(input uint_t depth);
    return uint_t'($clog2(depth));
  endfunction

  function automatic uint_t cdc_ptr_w(input uint_t depth);
    return cdc_addr_w(depth) + 32'd1;
  endfunction

  // Width of an occupancy counter representing 0..depth inclusive.
  function automatic uint_t cdc_occ_w(input uint_t depth);
    return uint_t'($clog2(depth + 32'd1));
  endfunction

  // True when `depth` is a power of two and at least 2. The asynchronous FIFO
  // requires it: the Gray full/empty derivation is only valid when the pointer
  // wraps exactly at the top of its own binary range.
  function automatic logic cdc_depth_ok(input uint_t depth);
    return (depth >= 32'd2) && ((depth & (depth - 32'd1)) == 32'd0);
  endfunction

endpackage : cdc_pkg

`default_nettype wire
