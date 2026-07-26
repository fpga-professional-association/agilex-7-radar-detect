// -----------------------------------------------------------------------------
// history_pkg — geometry and address algebra of the SPEC.md 7.3 time-frequency
// history and corner turn (issue #15).
//
// SPEC 7.3 asks for a banked memory subsystem that stores FFT frames by antenna,
// time and frequency, takes continuous writes, serves beamformer reads organised
// by COMMON FREQUENCY BIN, keeps a programmable history depth in independently
// addressable banks with double buffering or rotating frame banks, avoids a
// single globally broadcast address and enable network, and exposes occupancy,
// overwrite, collision and error counters.
//
// This package is the one place where the MAPPING from (antenna, frame,
// frequency bin) to (bank, word address) is defined, and the one place where the
// read response's payload layout is defined. The fixed-point format stays in
// fxp_pkg and the stream bundle stays in stream_pkg; neither is duplicated here.
//
// Naming (DECISIONS.md, issue #10 decision 9 / #13 / #14 decision 12)
// ------------------------------------------------------------------
// The integer helper type is `hist_uint_t`, NOT `uint_t`. fxp_pkg, stream_pkg,
// covar_pkg and cfar_pkg already export types of that name, and a fifth is
// ambiguous under IEEE 1800-2017 26.3 in any module that wildcard-imports two of
// them — Quartus Prime Pro rejects it outright and Verilator accepts it
// silently. One package, one spelling.
//
// Two further identifiers are avoided here for the reason issue #14's decision
// 12 records about `cell`: `time` and `table` are SystemVerilog keywords, and
// both are the most natural word for something this block owns (the time axis;
// the frame slot table). The time axis is spelled `frame`, and a lookup is
// spelled `map`.
//
// -----------------------------------------------------------------------------
// 1. THE CORNER TURN, STATED AS ALGEBRA  (NORMATIVE)
// -----------------------------------------------------------------------------
// The write order and the read order disagree, and that disagreement is the
// whole problem:
//
//   WRITE  one antenna at a time, frequency-sequential. In a cycle, antenna `a`
//          delivers LANES consecutive samples of its own FFT frame.
//   READ   one frequency bin at a time, antenna-parallel. In a cycle, the
//          consumer wants bin `b` of EVERY antenna at once.
//
// The subsystem does not solve this with a transpose buffer or a crossbar. It
// solves it by CHOOSING THE BANK DIMENSION TO BE THE ONE THE READ NEEDS IN
// PARALLEL — the antenna — so that the memory itself performs the turn:
//
//     BANK(a, l) = a * LANES + l
//
// where `a` is the antenna and `l` is the LANE the sample arrived on. There are
// N_ANT * LANES banks. Consequences, and they are the design:
//
//   * A write touches exactly one bank per lane, and those banks belong to one
//     antenna. Two antennas can never contend, at any rate, because they share
//     no bank. Writes are therefore collision-free BY CONSTRUCTION rather than
//     by arbitration, which is what lets the ingest be continuous and full rate.
//   * A read of bin `b` enables exactly one lane's bank in every antenna — N_ANT
//     banks — and every one of them returns the same bin for a different
//     antenna. That is the antenna vector, assembled in one cycle, with no
//     multiplexer and no transpose.
//   * The other (LANES-1) * N_ANT banks are idle during that read, which is the
//     price: read bandwidth is one bin per cycle where write bandwidth is LANES
//     bins per cycle per antenna. See section 4 for why that is the right trade
//     and what the headroom is.
//
// The word address inside a bank is the remaining two coordinates:
//
//     ADDR(s, k) = s * BEATS_PER_FRAME + k
//
// where `s` is the rotating FRAME SLOT (section 2) and `k` is the BEAT INDEX
// within the frame, 0 .. M-1, M = BEATS_PER_FRAME = FFT_SIZE / LANES. A bank is
// therefore FRAMES_MAX * M words of HIST_WORD_W bits, and that word count is the
// number the SPEC 18 geometry sweep shapes.
//
// LANE ASSIGNMENT IS POSITIONAL, NOT ARITHMETIC. `l` is the position of the
// sample within the arriving beat, not `bin mod LANES`. This is not a detail: it
// is what makes bit-reversal absorption free (section 3), and it is also exactly
// what rtl/fft/ hands over. fft_core.sv states its output relation as normative:
//
//     beat k, slot q  =  X[ m + q * (FFT_SIZE / LANES) ]
//                     =  X[ q * M + m ]
//
//     with  m = k                       when the reorder stage is present
//           m = bitrev_{log2 M}(k)      when it is skipped
//
// The two slots of a beat are HALF A SPECTRUM APART, not adjacent — issue #11
// chose that pairing so its own reorder buffer could be two banks read at one
// address. This subsystem inherits the same gift, in a stronger form: the SLOT
// INDEX IS THE HIGH BITS OF THE BIN and the beat index is the low bits, so
//
//     bin      b   =  l * M + m           (l = slot = lane, m = position in lane)
//     lane     l   =  b / M               (a bit slice, not a divider)
//     position m   =  b % M               (a bit slice, not a modulo)
//     beat     k   =  m, or bitrev(m)
//
// Every one of those is a wire permutation on a power-of-two geometry. The
// corner turn costs no arithmetic on either side.
//
// A sample's natural frequency-bin index is a FUNCTION of where it was stored,
//
//     b = hist_stored_bin(g, bit_reversed, k, l)
//
// and the read direction is the exact inverse,
//
//     l = hist_lane_of_bin(g, b)
//     k = hist_beat_of_bin(g, bit_reversed, b)
//
// All three are in this package and nothing recomputes them inline.
//
// -----------------------------------------------------------------------------
// 2. FRAME SLOTS, ROTATION AND THE OVERWRITE POLICY
// -----------------------------------------------------------------------------
// Frames are numbered from reset. Frame `f` lives in slot
//
//     s = f mod DEPTH
//
// where DEPTH is the RUN-TIME programmable history depth, 1 .. FRAMES_MAX.
// FRAMES_MAX is elaborated (SPEC 11: 4 tiny, 16 medium, 512 full scale) and
// DEPTH is a register field, so one build serves every depth the software wants
// without re-elaboration. `hist_slot_of` is the mapping; it is a modulo, not a
// mask, because DEPTH is not required to be a power of two — a power-of-two-only
// depth would make "keep the last 100 frames" unrepresentable for no gain, since
// the modulo is on the WRITE path's own counter and is a compare-and-reset, not
// a divider.
//
// The overwrite policy is OVERWRITE-OLDEST, unconditionally, and it is not
// configurable. A history buffer that stalls its own ingest to preserve old
// frames would back-pressure the FFT and ultimately the ADC, which in a radar
// front end is a worse failure than losing the oldest frame — and SPEC 7.3
// asks for continuous writes. What the block owes instead is BOOKKEEPING that
// is exact:
//
//     occupancy      = min(frames_done, DEPTH)      complete frames held
//     overwrite_cnt  = max(frames_done - DEPTH, 0)  frames evicted since reset
//
// `frames_done` counts frames COMPLETE ON EVERY ANTENNA (section 5), so both
// numbers describe what a reader can actually fetch, not what the fastest
// antenna has managed to write.
//
// -----------------------------------------------------------------------------
// 3. BIT-REVERSAL IS ABSORBED HERE, AND IT IS FREE
// -----------------------------------------------------------------------------
// rtl/fft/streaming_fft.sv takes a `REORDER` parameter: 1 (its default) emits
// the frame in natural beat order, 0 leaves it BIT-REVERSED. The reorder stage
// exists precisely because somebody downstream has to pay for the permutation,
// and issue #11's own header says the choice belongs to whoever consumes the
// output. This package's claim is that the history is the cheapest place in the
// design to pay it, because HERE IT IS NOT A PERMUTATION AT ALL, IT IS AN
// ADDRESS.
//
// The mechanism: lane assignment is positional, so the WRITE side never needs to
// know a sample's frequency-bin index. It writes beat k, lane l to bank (a, l),
// word (s, k) — the same address arithmetic whichever order the FFT emits, with
// not one gate different. Only the READ side needs the bin index, and it needs
// to go the other way: given natural bin `b`, which (k, l) holds it? The lane is
// `b / M` either way; the beat is `b % M` for a reordered input and
// `hist_bitrev(log2 M, b % M)` for a bit-reversed one. Bit reversal of a
// constant-width index is a WIRE PERMUTATION — no logic, no memory, no latency,
// no cycle. It is the same trick, on the same index, that fft_reorder.sv itself
// uses on its write port; the difference is that here there is no buffer to put
// it in front of.
//
// THE PRICE THIS SAVES IS MEASURED, NOT ARGUED. Issue #11's SPEC 18 sweep
// recorded `REORDER=1` against `REORDER=0` at the same memory style as
// +170 ALMs, +4 M20K, +7 MLAB, -7.6 MHz and one whole frame of latency
// (DECISIONS.md, issue #11 finding 4). Setting INPUT_BIT_REVERSED here deletes
// all of it and adds nothing.
//
// It is still a PARAMETER, and both settings are verified against the model,
// because the choice couples two blocks and belongs to the integration issue
// that owns both (#17) rather than to either alone. The recommendation, recorded
// so that #17 inherits a position rather than a question, is: run the FFT with
// `REORDER=0` and this block with `INPUT_BIT_REVERSED=1`.
//
// The involution property `hist_bitrev(w, hist_bitrev(w, v)) == v` is what lets
// one function serve both directions; history_core checks it at elaboration over
// the whole index range rather than trusting the identity.
//
// -----------------------------------------------------------------------------
// 4. WHY ONE BIN PER READ CYCLE, AND WHAT THE HEADROOM IS
// -----------------------------------------------------------------------------
// The read interface serves ONE bin, ALL antennas, per cycle. It could serve
// more: the LANES banks of one antenna are physically independent, so up to
// LANES bins could be read in a cycle provided they land on distinct lanes. That
// is deliberately NOT built here, for two reasons. First, the consumer of this
// interface is the SPEC 7.4 alignment network (issue #16), whose entire job is
// to assemble beamformer vectors out of a bin stream; giving it a wider but
// LANE-CONSTRAINED port would push the constraint into its scheduler and make
// the two blocks' correctness joint. Second, a one-bin port has one address
// decode and one enable tree per antenna, and section 6 is about keeping those
// small. The headroom is real, it is recorded here so a later issue can spend
// it with measurements rather than rediscover it, and the address algebra above
// already supports it unchanged.
//
// -----------------------------------------------------------------------------
// 5. THE READ CONTRACT  (NORMATIVE — issue #16 depends on this literally)
// -----------------------------------------------------------------------------
// REQUEST, in the read clock domain, valid/ready:
//
//     bin        [HIST_BIN_W-1:0]     natural frequency-bin index, 0..FFT_SIZE-1
//     frame_off  [HIST_FOFF_W-1:0]    0 = newest COMPLETE frame, 1 = the one
//                                     before it, ... up to occupancy-1
//
// `frame_off` is relative and not absolute on purpose: an absolute frame number
// would force every consumer to track the write side's progress and would make
// every request racy against rotation. Relative-to-newest is the only indexing
// under which a request formed at any time is meaningful when it arrives.
//
// RESPONSE, in the read clock domain, a SPEC 5 stream (valid / ready / packed
// payload). The payload's `data` field is
//
//     data = { meta , ant[N-1] , ... , ant[1] , ant[0] }
//
// with antenna 0 in the LOW bits and each antenna's sample packed exactly as
// fxp_pkg::fxp_complex_t — { im, re }, real in the low half — so a consumer
// slices antenna `a` at `a * HIST_SAMPLE_PAIR_W` and needs no knowledge of this
// package to read a sample. `meta` sits ABOVE the antenna vector, so widening
// the antenna count moves no antenna's offset, and carries the identity SPEC
// 12.5 requires the scoreboard to key on:
//
//     meta = { flags , frame_id , frame_off , bin }
//
// packed by hist_meta_pack() / hist_meta_unpack(), with `flags` =
// { skew_seen, stale, out_of_range } (see hist_flag_e). `frame_id` is the
// ABSOLUTE frame number the response was served from, resolved at the moment
// the request was accepted — the consumer needs it to detect that a rotation
// overtook a long-lived request, which is exactly what `stale` reports and what
// `frame_off` alone cannot express.
//
// Metadata travels INSIDE the data field rather than on the stream's `user` and
// `stream_id` fields because it does not fit them: `bin` alone is 10 bits at
// FFT_SIZE=1024 and stream_pkg bounds `user` at 8 and `stream_id` at 8. It
// travels on the stream rather than on a sideband bus because SPEC 5 requires
// one common interface at every module boundary, and a sideband qualified by
// `valid` is a second interface with none of the protocol checking. The cost is
// HIST_META_W bits of payload that the beamformer eventually discards; issue #16
// strips them when it assembles beamformer vectors, which it must do anyway
// because it re-groups bins.
//
// ORDERING: responses are returned IN REQUEST ORDER, always. The read path is a
// fixed-latency pipeline with an elastic output, so there is no reordering
// mechanism to go wrong and no tag to match.
//
// BACKPRESSURE: the response stream is fully elastic. A consumer may stall it
// indefinitely; the request port stops accepting when the pipeline cannot
// retire, and NOTHING about the returned values depends on when they are taken.
// SPEC 13.1 stall testing and the "backpressure invariance" test in
// VERIFICATION_PLAN.md check exactly that.
//
// -----------------------------------------------------------------------------
// 6. NO GLOBALLY BROADCAST ADDRESS OR ENABLE NETWORK
// -----------------------------------------------------------------------------
// SPEC 7.3 forbids it and SPEC 23 explains why: a chip-wide control net is the
// classic limiter on HyperFlex retiming. Two structural properties of the
// mapping above are what let the prohibition be met rather than asserted.
//
// WRITE: there is no shared write address to broadcast. Each antenna owns its
// beat counter and its slot register, so antenna `a`'s write address is
// generated inside antenna `a`'s own sequencer and fans out to LANES banks. The
// fanout of any write-address register is LANES, independent of N_ANT.
//
// READ: there IS one logical read address per cycle, shared by N_ANT banks —
// that is what makes it a corner turn. It is distributed through a REGISTERED
// FANOUT: history_core registers the decoded address once per antenna
// (`hist_addr_pipe`), and every history_bank registers address and enable AGAIN
// on its own input, so no register drives more than one antenna's worth of
// banks and every bank's control arrives from a flop of its own. The enable is
// per-lane, so at most one lane's bank per antenna is enabled — the enable net
// is not a broadcast even logically.
//
// The assertion set (sim/assertions/history_wr_assertions.sv and its read-side
// twin) checks the observable
// consequence: no two antennas' write enables are required to be equal, and in
// the randomized test they demonstrably are not.
//
// Lint contract: linted by `make lint` on every run, clean under --Wall with no
// waiver.
// -----------------------------------------------------------------------------

`default_nettype none

package history_pkg;

  // ---------------------------------------------------------------------------
  // Working types
  // ---------------------------------------------------------------------------

  // Unsigned 32-bit integer, so widths and indices can be cast explicitly
  // (`hist_uint_t'(x)`); `int unsigned'(x)` is not legal cast syntax. Spelled
  // distinctly from every other package's helper type — see the header.
  typedef int unsigned hist_uint_t;

  // Bound on any index this package's helpers compute in.
  localparam int unsigned HIST_MAX_IDX_W = 32;

  typedef logic [HIST_MAX_IDX_W-1:0] hist_idx_t;

  // ---------------------------------------------------------------------------
  // Geometry
  //
  // One struct rather than five loose parameters, for the reason stream_pkg's
  // stream_geom_t exists: every function here needs the whole geometry, and a
  // module that passes four of five arguments correctly is a defect no width
  // check can catch.
  // ---------------------------------------------------------------------------

  typedef struct packed {
    hist_uint_t n_ant;       // antennas, >= 1
    hist_uint_t fft_size;    // frequency bins per frame, power of two, >= 2
    hist_uint_t lanes;       // complex samples per write beat, power of two,
                             // divides fft_size (SPEC 11 SAMPLES_PER_CYCLE)
    hist_uint_t frames_max;  // elaborated maximum history depth, >= 2
    hist_uint_t sample_w;    // bits per real or imaginary part (SPEC 3 SAMPLE_W)
  } hist_geom_t;

  function automatic hist_geom_t hist_geom(input hist_uint_t n_ant,
                                           input hist_uint_t fft_size,
                                           input hist_uint_t lanes,
                                           input hist_uint_t frames_max,
                                           input hist_uint_t sample_w);
    hist_geom_t g;
    g.n_ant      = n_ant;
    g.fft_size   = fft_size;
    g.lanes      = lanes;
    g.frames_max = frames_max;
    g.sample_w   = sample_w;
    return g;
  endfunction

  function automatic logic hist_is_pow2(input hist_uint_t v);
    return (v >= 32'd1) && ((v & (v - 32'd1)) == 32'd0);
  endfunction

  // Every constraint the algebra above depends on, in one predicate. Instances
  // check it at elaboration; history_core.sv shows the pattern.
  //
  // Three of these are load-bearing rather than defensive, and the reasons are
  // worth having next to the test:
  //
  //   fft_size and lanes powers of two  -- so that lane = bin / M and
  //       m = bin % M are BIT SLICES. A non-power-of-two geometry would put a
  //       divider on the read address path, which is the one path in this block
  //       that has to close timing at the SPEC 8 history_clk.
  //   frames_max a power of two         -- so that ADDR(s, k) = {s, k} is a
  //       CONCATENATION. The run-time depth is NOT so constrained; only the
  //       elaborated maximum is, and only because it sets the address split.
  //   lanes STRICTLY less than fft_size -- so that M >= 2 and the beat index is
  //       at least one bit wide. LANES == FFT_SIZE would put a whole frame in
  //       one beat, which no SPEC 11 configuration asks for and which would make
  //       the address split degenerate.
  function automatic logic hist_geom_ok(input hist_geom_t g);
    return (g.n_ant      >= 32'd1)  &&
           (g.fft_size   >= 32'd2)  && hist_is_pow2(g.fft_size)   &&
           (g.lanes      >= 32'd1)  && hist_is_pow2(g.lanes)      &&
           (g.lanes      <  g.fft_size)                           &&
           (g.frames_max >= 32'd2)  && hist_is_pow2(g.frames_max) &&
           (g.sample_w   >= 32'd2)  && (g.sample_w <= 32'd32);
  endfunction

  // ---------------------------------------------------------------------------
  // Port width for the scalar control and status values
  //
  // `cfg_depth`, `stat_occupancy`, `rd_req_bin` and `rd_req_frame_off` are all
  // carried at this fixed width rather than at their geometry-derived minimum.
  // The reason is mechanical: a module's port list may not read a localparam
  // declared in its body, so a geometry-derived port width has to become an
  // overridable parameter, and an overridable width on a control port is a way
  // for an instantiator to silently truncate a depth. One constant, wide enough
  // for every SPEC 11 configuration (FFT_SIZE <= 1024 needs 10 bits,
  // HISTORY_FRAMES <= 512 needs 10), removes the whole class of mistake. The
  // instance checks its own geometry against it at elaboration.
  // ---------------------------------------------------------------------------
  localparam int unsigned HIST_PORT_W = 16;

  // True when this geometry's indices fit the fixed control ports. Exists for
  // two reasons, and both matter. It gives an instance one predicate to check at
  // elaboration instead of two open-coded comparisons; and it is what READS
  // HIST_PORT_W inside this package, without which `verilator --lint-only
  // --Wall` reports the localparam as UNUSEDPARAM in every build that lists this
  // file but does not yet instantiate the block -- which is every build until
  // issue #17 wires the pipeline together. stream_pkg and cdc_pkg solve the same
  // problem by exporting functions instead of localparams; this package needs
  // the constant in a port declaration, so it keeps the localparam and gives it
  // a reader.
  function automatic logic hist_port_fits(input hist_geom_t g);
    return (hist_bin_w(g) <= HIST_PORT_W) && (hist_occ_w(g) <= HIST_PORT_W);
  endfunction

  // ---------------------------------------------------------------------------
  // Derived counts and widths
  //
  // EVERY FUNCTION HERE IS GUARDED BY hist_geom_ok(), and the guard is not
  // decoration. Two things fall out of it, one of them mechanical:
  //
  //   * a derived quantity is only DEFINED for a legal geometry, so an illegal
  //     one yields a benign 1 rather than a plausible-looking number that
  //     propagates into a port width. The instance's own elaboration check
  //     reports the real problem at time 0;
  //   * the guard reads every field of `g`, which is what makes each function a
  //     total use of its argument. Without it `verilator --lint-only --Wall`
  //     reports UNUSEDSIGNAL on the unread struct fields of every helper that
  //     needs only two of the five — thirteen warnings, one per accessor. The
  //     alternative shapes are worse: passing loose scalars reintroduces the
  //     "four arguments of five, correctly" defect this struct exists to
  //     prevent, and a file-wide UNUSEDSIGNAL waiver would silence the same rule
  //     everywhere else in the package too.
  //
  // The cost is zero: every call site is an elaboration-time constant.
  // ---------------------------------------------------------------------------

  // Beats in one antenna's frame.
  function automatic hist_uint_t hist_beats_per_frame(input hist_geom_t g);
    return hist_geom_ok(g) ? (g.fft_size / g.lanes) : 32'd1;
  endfunction

  // Independently addressed banks in the whole subsystem.
  function automatic hist_uint_t hist_n_banks(input hist_geom_t g);
    return hist_geom_ok(g) ? (g.n_ant * g.lanes) : 32'd1;
  endfunction

  // Words in one bank: every frame slot's share of one lane.
  function automatic hist_uint_t hist_bank_words(input hist_geom_t g);
    return g.frames_max * hist_beats_per_frame(g);
  endfunction

  // One stored word is one complex sample: { im, re }, matching
  // fxp_pkg::fxp_complex_t exactly.
  function automatic hist_uint_t hist_word_w(input hist_geom_t g);
    return hist_geom_ok(g) ? (32'd2 * g.sample_w) : 32'd1;
  endfunction

  // Total storage the subsystem elaborates, in bits. Quoted by history_core in
  // its elaboration banner and by the SPEC 18 projection, so the number in the
  // pull request and the number the RTL builds cannot disagree.
  function automatic hist_uint_t hist_total_bits(input hist_geom_t g);
    return hist_n_banks(g) * hist_bank_words(g) * hist_word_w(g);
  endfunction

  // `$clog2` of a count, floored at 1 so a degenerate geometry still yields a
  // legal vector width. Every width below goes through it.
  function automatic hist_uint_t hist_w_of(input hist_uint_t count);
    hist_uint_t w;
    w = hist_uint_t'($clog2(count));
    return (w == 32'd0) ? 32'd1 : w;
  endfunction

  function automatic hist_uint_t hist_bin_w(input hist_geom_t g);
    return hist_geom_ok(g) ? hist_w_of(g.fft_size) : 32'd1;
  endfunction

  function automatic hist_uint_t hist_lane_w(input hist_geom_t g);
    return hist_geom_ok(g) ? hist_w_of(g.lanes) : 32'd1;
  endfunction

  function automatic hist_uint_t hist_beat_w(input hist_geom_t g);
    return hist_w_of(hist_beats_per_frame(g));
  endfunction

  function automatic hist_uint_t hist_ant_w(input hist_geom_t g);
    return hist_geom_ok(g) ? hist_w_of(g.n_ant) : 32'd1;
  endfunction

  function automatic hist_uint_t hist_slot_w(input hist_geom_t g);
    return hist_geom_ok(g) ? hist_w_of(g.frames_max) : 32'd1;
  endfunction

  function automatic hist_uint_t hist_addr_w(input hist_geom_t g);
    return hist_w_of(hist_bank_words(g));
  endfunction

  // Frame offset: 0 .. frames_max-1, so it needs the same width as a slot.
  function automatic hist_uint_t hist_foff_w(input hist_geom_t g);
    return hist_slot_w(g);
  endfunction

  // Occupancy represents 0 .. frames_max inclusive.
  function automatic hist_uint_t hist_occ_w(input hist_geom_t g);
    return hist_geom_ok(g) ? hist_uint_t'($clog2(g.frames_max + 32'd1)) : 32'd1;
  endfunction

  // Absolute frame number carried in the response metadata and in the
  // counters. 32 bits: at the SPEC 8 history_clk of 400 MHz and the SPEC 11
  // full-scale frame length of 1024 bins, a frame is 2.56 us and 2^32 frames is
  // three and a half centuries, so the field never wraps inside any run this
  // project makes. It is still MODULO and the wrap is still modelled, because
  // the tiny configurations a unit test builds are narrow enough to reach it.
  localparam int unsigned HIST_FRAME_ID_W = 32;

  // ---------------------------------------------------------------------------
  // Bit reversal  (see header section 3)
  //
  // `w` is the index width. Bits at or above `w` are dropped, so a caller that
  // passes a wider working value cannot leak a high bit into the result. The
  // function is its own inverse for any value that fits `w`, which is what lets
  // one function serve the write direction and the read direction.
  // ---------------------------------------------------------------------------

  function automatic hist_idx_t hist_bitrev(input hist_uint_t w,
                                            input hist_idx_t v);
    hist_idx_t r;
    r = '0;
    for (int unsigned i = 0; i < HIST_MAX_IDX_W; i++) begin
      if (i < w) begin
        r[w - 32'd1 - i] = v[i];
      end
    end
    return r;
  endfunction

  // ---------------------------------------------------------------------------
  // The mapping  (NORMATIVE — header section 1)
  // ---------------------------------------------------------------------------

  // Bank holding antenna `a`'s lane `l`.
  function automatic hist_uint_t hist_bank_of(input hist_geom_t g,
                                              input hist_uint_t ant,
                                              input hist_uint_t lane);
    return hist_geom_ok(g) ? (ant * g.lanes + lane) : 32'd0;
  endfunction

  // Word address of beat `beat` of frame slot `slot`, inside any bank.
  function automatic hist_uint_t hist_addr_of(input hist_geom_t g,
                                              input hist_uint_t slot,
                                              input hist_uint_t beat);
    return slot * hist_beats_per_frame(g) + beat;
  endfunction

  // Rotating slot of absolute frame number `frame`, at programmed depth
  // `depth`. A modulo rather than a mask; see header section 2.
  function automatic hist_uint_t hist_slot_of(input hist_uint_t frame,
                                              input hist_uint_t depth);
    return (depth == 32'd0) ? 32'd0 : (frame % depth);
  endfunction

  // Width the bit reversal acts on: the BEAT index, log2(M). Not log2(FFT_SIZE)
  // — the permutation rtl/fft/ leaves behind is over beats, because both slots
  // of a beat move together and no sample ever changes lane (fft_reorder.sv).
  // Raw $clog2, not hist_w_of: at LANES == FFT_SIZE there is one beat per frame
  // and the reversal is correctly the identity on zero bits.
  function automatic hist_uint_t hist_rev_w(input hist_geom_t g);
    return hist_uint_t'($clog2(hist_beats_per_frame(g)));
  endfunction

  // WRITE direction: the natural frequency-bin index of the sample that landed
  // on beat `beat`, lane `lane`. `bit_reversed` is the FFT's output ordering.
  // Used by the C++ model and by the assertions; the write datapath itself never
  // calls it, which is the whole point of section 3.
  function automatic hist_uint_t hist_stored_bin(input hist_geom_t g,
                                                 input logic       bit_reversed,
                                                 input hist_uint_t beat,
                                                 input hist_uint_t lane);
    hist_uint_t m;
    m = bit_reversed
          ? hist_uint_t'(hist_bitrev(hist_rev_w(g), hist_idx_t'(beat)))
          : beat;
    return lane * hist_beats_per_frame(g) + m;
  endfunction

  // READ direction, lane half: which lane's bank holds natural bin `bin`. The
  // high bits of the index; independent of the input ordering, because the
  // reversal acts only on the beat.
  function automatic hist_uint_t hist_lane_of_bin(input hist_geom_t g,
                                                  input hist_uint_t bin);
    return bin / hist_beats_per_frame(g);
  endfunction

  // READ direction, beat half: which word of that bank holds natural bin `bin`,
  // before the frame slot is added.
  function automatic hist_uint_t hist_beat_of_bin(input hist_geom_t g,
                                                  input logic       bit_reversed,
                                                  input hist_uint_t bin);
    hist_uint_t m;
    m = bin % hist_beats_per_frame(g);
    return bit_reversed
             ? hist_uint_t'(hist_bitrev(hist_rev_w(g), hist_idx_t'(m)))
             : m;
  endfunction

  // ---------------------------------------------------------------------------
  // Response payload layout  (NORMATIVE — header section 5)
  // ---------------------------------------------------------------------------

  // One antenna's slot in the vector: { im, re }.
  function automatic hist_uint_t hist_sample_pair_w(input hist_geom_t g);
    return hist_word_w(g);
  endfunction

  // The antenna vector alone, without metadata.
  function automatic hist_uint_t hist_vec_w(input hist_geom_t g);
    return g.n_ant * hist_word_w(g);
  endfunction

  // Response flags, LSB first inside `meta`. The order is normative: the two low
  // bits are decided when the request is accepted and travel with it down the
  // pipeline, and the top bit is decided at the output stage, so a consumer that
  // only wants to know "is this answer trustworthy" reads `|flags` and a
  // consumer that wants to know why reads the bits.
  typedef enum int unsigned {
    HIST_FLAG_OUT_OF_RANGE = 0,  // `frame_off` was outside the readable set. The
                                 // request was still answered, deterministically
                                 // (clamped to the newest readable frame), and
                                 // the error counter advanced
    HIST_FLAG_COLLISION    = 1,  // the addressed slot was the one being written.
                                 // Unreachable outside fault injection; see
                                 // history_core header section 4
    HIST_FLAG_STALE        = 2   // rotation overtook the addressed frame between
                                 // request acceptance and the memory read, so
                                 // the slot had already been reused
  } hist_flag_e;

  localparam int unsigned HIST_FLAGS_W = 3;

  // The two flags decided at request time and carried down the pipeline. The
  // third is added at the output stage and is not pipelined, because it depends
  // on how far rotation moved WHILE the request was in flight.
  localparam int unsigned HIST_REQ_FLAGS_W = 2;

  // Width of the identity history_core carries down its read pipeline beside the
  // in-flight request: the bin, the clamped frame offset, the absolute frame id,
  // the two request-time flags and the lane the response will be muxed from.
  // Exported rather than open-coded in the module for the reason every other
  // width here is -- one expression, one place -- and it is also the reader that
  // keeps HIST_REQ_FLAGS_W from being a dead localparam. See hist_port_fits.
  function automatic hist_uint_t hist_req_meta_w(input hist_geom_t g);
    return hist_bin_w(g) + hist_occ_w(g) +
           hist_uint_t'(HIST_FRAME_ID_W) + hist_uint_t'(HIST_REQ_FLAGS_W) +
           hist_lane_w(g);
  endfunction

  // meta = { flags , frame_id , frame_off , bin }, bin at the bottom.
  function automatic hist_uint_t hist_meta_w(input hist_geom_t g);
    return hist_bin_w(g) + hist_foff_w(g) +
           hist_uint_t'(HIST_FRAME_ID_W) + hist_uint_t'(HIST_FLAGS_W);
  endfunction

  function automatic hist_uint_t hist_meta_bin_lsb(input hist_geom_t g);
    return hist_geom_ok(g) ? 32'd0 : 32'd0;
  endfunction

  function automatic hist_uint_t hist_meta_foff_lsb(input hist_geom_t g);
    return hist_bin_w(g);
  endfunction

  function automatic hist_uint_t hist_meta_frame_lsb(input hist_geom_t g);
    return hist_bin_w(g) + hist_foff_w(g);
  endfunction

  function automatic hist_uint_t hist_meta_flags_lsb(input hist_geom_t g);
    return hist_bin_w(g) + hist_foff_w(g) + hist_uint_t'(HIST_FRAME_ID_W);
  endfunction

  // Full `data` field width: metadata above the antenna vector.
  function automatic hist_uint_t hist_data_w(input hist_geom_t g);
    return hist_vec_w(g) + hist_meta_w(g);
  endfunction

  function automatic hist_uint_t hist_meta_lsb(input hist_geom_t g);
    return hist_vec_w(g);
  endfunction

  // Bit position of antenna `ant`'s sample inside the `data` field.
  function automatic hist_uint_t hist_ant_lsb(input hist_geom_t g,
                                              input hist_uint_t ant);
    return ant * hist_word_w(g);
  endfunction

  // Working type for the metadata word. Bounded by the widest geometry this
  // project elaborates: 10 bin bits + 10 offset bits + 32 frame bits + 3 flags.
  localparam int unsigned HIST_META_MAX_W = 64;
  typedef logic [HIST_META_MAX_W-1:0] hist_meta_t;

  typedef struct packed {
    logic [HIST_FLAGS_W-1:0]     flags;
    logic [HIST_FRAME_ID_W-1:0]  frame_id;
    hist_idx_t                   frame_off;
    hist_idx_t                   bin;
  } hist_meta_fields_t;

  function automatic hist_meta_t hist_mask(input hist_uint_t w);
    if (w == 32'd0) return '0;
    if (w >= hist_uint_t'(HIST_META_MAX_W)) return '1;
    return (hist_meta_t'(1) << w) - hist_meta_t'(1);
  endfunction

  function automatic hist_meta_t hist_meta_pack(input hist_geom_t        g,
                                                input hist_meta_fields_t f);
    hist_meta_t m;
    m = '0;
    m = m | ((hist_meta_t'(f.bin)       & hist_mask(hist_bin_w(g)))
             << hist_meta_bin_lsb(g));
    m = m | ((hist_meta_t'(f.frame_off) & hist_mask(hist_foff_w(g)))
             << hist_meta_foff_lsb(g));
    m = m | ((hist_meta_t'(f.frame_id)  & hist_mask(hist_uint_t'(HIST_FRAME_ID_W)))
             << hist_meta_frame_lsb(g));
    m = m | ((hist_meta_t'(f.flags)     & hist_mask(hist_uint_t'(HIST_FLAGS_W)))
             << hist_meta_flags_lsb(g));
    return m;
  endfunction

  function automatic hist_meta_fields_t hist_meta_unpack(input hist_geom_t g,
                                                         input hist_meta_t m);
    hist_meta_fields_t f;
    f           = '0;
    f.bin       = hist_idx_t'((m >> hist_meta_bin_lsb(g))
                              & hist_mask(hist_bin_w(g)));
    f.frame_off = hist_idx_t'((m >> hist_meta_foff_lsb(g))
                              & hist_mask(hist_foff_w(g)));
    f.frame_id  = HIST_FRAME_ID_W'((m >> hist_meta_frame_lsb(g))
                              & hist_mask(hist_uint_t'(HIST_FRAME_ID_W)));
    f.flags     = HIST_FLAGS_W'((m >> hist_meta_flags_lsb(g))
                              & hist_mask(hist_uint_t'(HIST_FLAGS_W)));
    return f;
  endfunction

  // ---------------------------------------------------------------------------
  // Structural latency
  //
  // Exported as functions rather than localparams for the reason stream_pkg
  // gives: a package localparam a given build never reads is reported as
  // UNUSEDPARAM by `verilator --lint-only --Wall`, and this design lints one top
  // at a time.
  //
  // Latency here means read-clock cycles from the edge at which a request is
  // accepted to the edge at which its response is presented, with no
  // backpressure. Under backpressure there is no fixed latency and SPEC 12.5
  // forbids assuming one.
  // ---------------------------------------------------------------------------

  // history_bank: input register, memory, output register.
  function automatic hist_uint_t hist_bank_read_latency();
    return 32'd3;
  endfunction

  // history_core read path: the registered per-antenna address fanout stage, the
  // bank, and the two stages of the output FIFO (its array and its registered
  // read port). Six read-clock cycles at the geometry this block builds.
  function automatic hist_uint_t hist_read_latency();
    return 32'd1 + hist_bank_read_latency() + 32'd2;
  endfunction

  // ---------------------------------------------------------------------------
  // SPEC 18 projection helper
  //
  // M20K blocks a geometry needs, assuming Quartus packs each bank
  // independently (it does: the banks are separate arrays with separate ports)
  // and that a block holds M20K_BITS usable bits at the chosen word width. The
  // function takes the width the block is configured at rather than assuming
  // one, because that is exactly the variable the SPEC 18 sweep measures.
  // Reported by history_core's elaboration banner so the projection in the pull
  // request is computed from the same expression the RTL builds.
  // ---------------------------------------------------------------------------

  localparam int unsigned HIST_M20K_BITS = 20480;

  function automatic hist_uint_t hist_ceil_div(input hist_uint_t a,
                                               input hist_uint_t b);
    return (b == 32'd0) ? 32'd0 : ((a + b - 32'd1) / b);
  endfunction

  // Blocks for one bank of `words` x `width` bits, given an M20K mode that is
  // `mode_w` bits wide and therefore HIST_M20K_BITS/mode_w words deep.
  function automatic hist_uint_t hist_m20k_per_bank(input hist_uint_t words,
                                                    input hist_uint_t width,
                                                    input hist_uint_t mode_w);
    hist_uint_t depth_per_block;
    hist_uint_t wide;
    hist_uint_t deep;
    if (mode_w == 32'd0) return 32'd0;
    depth_per_block = hist_uint_t'(HIST_M20K_BITS) / mode_w;
    wide            = hist_ceil_div(width, mode_w);
    deep            = hist_ceil_div(words, depth_per_block);
    return wide * deep;
  endfunction

endpackage : history_pkg

`default_nettype wire
