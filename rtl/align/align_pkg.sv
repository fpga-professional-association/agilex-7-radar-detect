// -----------------------------------------------------------------------------
// align_pkg — geometry, tag algebra and payload layout of the SPEC.md 7.4
// frequency-bin alignment network (issue #16).
//
// SPEC 7.4 asks for a pipelined network that rearranges FFT/history output into
// BEAMFORMER VECTORS, preserving antenna, frequency-bin and frame identity,
// supporting backpressure, detecting missing or duplicated samples, and avoiding
// one giant unregistered multiplexer — and it asks for TWO architectures to be
// built and compared. This package is the one place where the request schedule,
// the routing key, the reassembly geometry and the output payload layout are
// defined, so that `align_xbar` and `align_clos` are interchangeable behind one
// contract rather than two designs that merely look alike.
//
// -----------------------------------------------------------------------------
// 0. WHAT IS LEFT FOR THIS BLOCK TO DO, GIVEN #15  (READ THIS FIRST)
// -----------------------------------------------------------------------------
// The naive reading of SPEC 7.4 is "transpose antenna-sequential FFT output into
// bin-parallel antenna vectors". That transpose IS NOT HERE, and it is not here
// because issue #15 already did it, in memory, for free: rtl/packages/
// history_pkg.sv section 1 chooses the BANK DIMENSION TO BE THE ANTENNA, so a
// read of bin `b` enables one bank per antenna and returns the whole antenna
// vector in one cycle with no multiplexer at all. history_pkg section 5 states
// the resulting read contract, and ARCHITECTURE.md repeats it as normative:
//
//     one request  = (bin, frame_off)
//     one response = { meta , ant[N-1] ... ant[0] }      ONE bin, ALL antennas
//
// So the antenna axis arrives already aligned. What is NOT solved, and what this
// block is, is the BIN-PARALLEL MARSHALLING LAYER between that one-bin-per-cycle
// port and the beamformer's input beat, which `beamformer_pkg` and
// ARCHITECTURE.md 3.5 define as BIN_PAR consecutive bins EACH carrying the whole
// antenna vector:
//
//     data[(j*N_ANT + a) * 2*SAMPLE_W +: 2*SAMPLE_W] = X[antenna a][bin_base+j]
//
// Getting from the first shape to the second means:
//
//   * issuing BIN_PAR read requests per cycle across BIN_PAR independent history
//     read ports (history_pkg section 4 records that the port is deliberately
//     one bin wide and that the headroom to widen it exists; this block spends
//     that headroom by instantiating the port BIN_PAR times rather than by
//     widening it, which keeps #15's correctness argument untouched);
//   * ROUTING each response to the bin position it belongs to in the beat. The
//     port a bin was requested on is NOT the position it occupies in the beat —
//     see section 2 — so this is a genuine BIN_PAR x BIN_PAR permutation that
//     changes every beat, and it is the thing the two architectures implement;
//   * REASSEMBLING responses that arrive skewed, because BIN_PAR independent
//     history instances have independent occupancies and independent stalls, so
//     the responses for one beat do not arrive together;
//   * DETECTING a response that never arrives (missing) or arrives twice
//     (duplicated), which SPEC 7.4 requires and which nothing upstream can do.
//
// That is the interpretation this block is built to. It is recorded here, and in
// ARCHITECTURE.md and DECISIONS.md, because a reader who expects a transpose
// will otherwise look for one and conclude it is missing.
//
// -----------------------------------------------------------------------------
// 1. THE BEAT, THE GROUP AND THE SWEEP
// -----------------------------------------------------------------------------
// A GROUP is one output beat's worth of work: BIN_PAR consecutive frequency bins
// of ONE frame. Group `g` of a frame covers bins
//
//     bin = g * BIN_PAR + j,        j = 0 .. BIN_PAR-1        (j is the LANE)
//
// A SWEEP is one whole frame: GROUPS_PER_FRAME = FFT_SIZE / BIN_PAR groups,
// emitted as one SPEC 5 frame (`sof` on group 0, `eof` on the last group). The
// sequencer walks groups in order and never revisits one, so:
//
//     LANE  j = bin % BIN_PAR   = bin[LANE_W-1:0]             a bit slice
//     GROUP g = bin / BIN_PAR   = bin[BIN_W-1:LANE_W]         a bit slice
//
// Both are wire permutations on a power-of-two geometry, exactly as #15's lane
// and beat indices are, and for the same reason: BIN_PAR is required to be a
// power of two that divides FFT_SIZE.
//
// -----------------------------------------------------------------------------
// 2. WHY THE ROUTING IS NOT THE IDENTITY  (the reason this block has a network)
// -----------------------------------------------------------------------------
// There are BIN_PAR history read ports and BIN_PAR lanes in a beat. If lane `j`
// were always requested on port `j`, the "network" would be BIN_PAR wires and
// SPEC 7.4's architecture comparison would be vacuous. It is not, and the reason
// is physical rather than contrived.
//
// #15's banking is BANK(a, l) = a*LANES + l with l = bin / BEATS_PER_FRAME: the
// LANE OF A BIN INSIDE THE MEMORY is the high bits of the bin index. A schedule
// that always sent beat-position `j` to port `j` would send a fixed residue
// class of bins to each port forever, so each port would drive a fixed subset of
// memory lanes at a fixed duty cycle — the one arrangement that guarantees the
// per-port enable trees are maximally unbalanced. The schedule here therefore
// ROTATES:
//
//     port(g, j) = (j + g) mod BIN_PAR                      algn_port_of()
//
// so over BIN_PAR consecutive groups every port sees every beat position, and
// the inverse — which lane the response arriving on port `p` belongs to — is a
// different cyclic permutation on every group. That is a real, beat-varying
// BIN_PAR x BIN_PAR permutation, which is exactly what a crossbar and a Clos
// network implement differently, and what SPEC 7.4 asks to be measured.
//
// The rotation is arithmetic on the request side only. On the RESPONSE side
// nothing has to remember it (section 3), which is what makes the network
// tolerant of arbitrary skew and reordering rather than merely of the skew the
// schedule happens to produce.
//
// -----------------------------------------------------------------------------
// 3. THE ROUTING KEY IS THE RESPONSE'S OWN IDENTITY, NOT A SIDE-CHANNEL TAG
// -----------------------------------------------------------------------------
// The obvious mechanism is a per-port FIFO of issued tags, popped one per
// response. It is rejected here, and the reason is the failure mode SPEC 7.4
// exists to catch: a tag FIFO is only correct while responses and tags stay in
// step, so the FIRST dropped or duplicated response silently mis-labels every
// response after it. The detector would be the thing that breaks first.
//
// Instead the key is recomputed from the response's OWN metadata, which #15
// already carries inside `data` (history_pkg section 5):
//
//     lane      j   = meta.bin[LANE_W-1:0]
//     group     g   = meta.bin[BIN_W-1:LANE_W]
//     buffer id gid = g mod GROUPS   = g[GID_W-1:0]          (GROUPS is pow2)
//
// and the reassembly entry `gid` independently stores the (group, frame_off) it
// was allocated for. Every arriving response is checked against it. Consequences,
// and they are why the mechanism was chosen:
//
//   * a response that never arrives is not mislabelled as anything — it simply
//     never sets its lane's present bit, and the group's timeout counter finds
//     it. MISSING is detected positively, not inferred from a stream position.
//   * a response that arrives twice hits a lane whose present bit is already
//     set. DUPLICATE is detected exactly, on the second copy, whatever the skew.
//   * a response whose (group, frame_off) does not match the entry — a stale
//     answer to a request from GROUPS groups ago, a rotation that overtook the
//     request, or a tag collision forced by fault injection — is an ORPHAN, and
//     is counted and dropped rather than being written over a live beat.
//   * NO ORDERING ASSUMPTION AT ALL is made about the response streams. #15
//     promises request order per port; this block does not need it, so a future
//     out-of-order memory does not invalidate the network.
//
// The cost is that the identity travels through the routing network with the
// data (ALGN_NET_DATA_W below) instead of a log2 tag. That cost is what buys the
// property, and it is also literally what SPEC 7.4 means by "preserve antenna,
// frequency-bin and frame identity": the identity is IN the routed word and is
// checked at the far end, rather than being reconstructed from position.
//
// -----------------------------------------------------------------------------
// 4. WHAT AN INCOMPLETE GROUP EMITS, AND WHY IT EMITS ANYTHING AT ALL
// -----------------------------------------------------------------------------
// A group whose responses do not all arrive within ALGN_TIMEOUT cycles is
// resolved rather than waited on forever. The obvious policy — drop the beat —
// is WRONG, and the reason is that SPEC 5 is normative too: the SPEC 5 checker
// requires `sequence` to advance by exactly one per beat and requires exactly one
// `eof` per frame. Deleting a beat breaks the first; deleting the beat that
// carried `eof` breaks the second and leaves the frame open forever, so the next
// frame's `sof` fires an assertion. A block that answers "detect missing
// samples" by corrupting the stream protocol has moved the defect, not fixed it.
//
// The policy is therefore: THE BEAT IS EMITTED, THE DATA IS NOT.
//
//   * the absent lanes are zeroed (`cfg_partial_pass` = 0, the default), so no
//     stale or half-formed antenna vector ever reaches the beamformer — which is
//     the actual hazard, because a beam formed across a mixed-frame vector is
//     not detectably wrong from the output alone (ARCHITECTURE.md 3.5);
//   * `ALGN_USER_MISSING` is set in the beat's SPEC 5 `user` field, so the loss
//     is visible to any consumer that decodes only the bundle;
//   * `stat_missing_count` advances by the number of absent lanes, exactly;
//   * `sequence`, `sof` and `eof` stay exactly as they would have been.
//
// `cfg_partial_pass` = 1 keeps whatever did arrive, for diagnosis. Both settings
// are modelled and both are tested; the default is the safe one.
//
// -----------------------------------------------------------------------------
// 5. NAMING (DECISIONS.md, issue #10 decision 13 / #14 decision 12 / #15
//    decision 12)
// -----------------------------------------------------------------------------
// The integer helper type is `algn_uint_t`. fxp_pkg, stream_pkg, covar_pkg,
// cfar_pkg, pfb_pkg, beamformer_pkg and history_pkg already export a helper of
// that role under six different spellings, and two of them visible through
// wildcard imports in one module is ambiguous under IEEE 1800-2017 26.3 —
// Quartus Prime Pro rejects it outright and Verilator accepts it silently, which
// cost issue #10 a failed calibration compile. `align_net` wildcard-imports
// fxp_pkg, stream_pkg, history_pkg and this package at once.
//
// The block is spelled `algn_` inside identifiers and `align_` in file and
// module names, following `hist_`/`history_`. `group` rather than `table`, and
// `lane` rather than `cell`, for the keyword reason issue #14's decision 12
// records. Note that `lane` here is a BEAT POSITION and is a different axis from
// history_pkg's `lane`, which is a memory bank index; the two never appear in
// one expression and each package's header says which one it means.
//
// Lint contract: linted by `make lint` on every run, clean under --Wall with no
// waiver.
// -----------------------------------------------------------------------------

`default_nettype none

package align_pkg;

  // ---------------------------------------------------------------------------
  // Working types
  // ---------------------------------------------------------------------------

  // Unsigned 32-bit integer, so widths and indices can be cast explicitly
  // (`algn_uint_t'(x)`); `int unsigned'(x)` is not legal cast syntax. Spelled
  // distinctly from every other package's helper type — see the header.
  typedef int unsigned algn_uint_t;

  // ---------------------------------------------------------------------------
  // Geometry
  //
  // One struct rather than seven loose parameters, for the reason
  // history_pkg::hist_geom_t and stream_pkg::stream_geom_t exist: every function
  // here needs the whole geometry, and a module that passes six of seven
  // arguments correctly is a defect no width check can catch.
  //
  // The first five fields are the HISTORY geometry, verbatim and in the same
  // order as history_pkg::hist_geom_t, because this block's input is #15's read
  // contract and the two must not be able to disagree. `algn_hist_geom()`
  // converts, and `align_net` checks the converted struct with
  // history_pkg::hist_geom_ok() at elaboration.
  // ---------------------------------------------------------------------------

  typedef struct packed {
    algn_uint_t n_ant;       // antennas per vector, >= 1
    algn_uint_t fft_size;    // frequency bins per frame, power of two
    algn_uint_t lanes;       // history write lanes (SPEC 11 SAMPLES_PER_CYCLE)
    algn_uint_t frames_max;  // history elaborated maximum depth
    algn_uint_t sample_w;    // bits per real or imaginary part
    algn_uint_t bin_par;     // bins per output beat = read ports = network width
    algn_uint_t groups;      // reassembly entries, power of two, >= 2
  } algn_geom_t;

  function automatic algn_geom_t algn_geom(input algn_uint_t n_ant,
                                           input algn_uint_t fft_size,
                                           input algn_uint_t lanes,
                                           input algn_uint_t frames_max,
                                           input algn_uint_t sample_w,
                                           input algn_uint_t bin_par,
                                           input algn_uint_t groups);
    algn_geom_t g;
    g.n_ant      = n_ant;
    g.fft_size   = fft_size;
    g.lanes      = lanes;
    g.frames_max = frames_max;
    g.sample_w   = sample_w;
    g.bin_par    = bin_par;
    g.groups     = groups;
    return g;
  endfunction

  function automatic logic algn_is_pow2(input algn_uint_t v);
    return (v >= 32'd1) && ((v & (v - 32'd1)) == 32'd0);
  endfunction

  // Every constraint the algebra above depends on, in one predicate. Instances
  // check it at elaboration; align_net.sv shows the pattern.
  //
  // Four are load-bearing rather than defensive:
  //
  //   bin_par a power of two    -- so that lane = bin % BIN_PAR and
  //       group = bin / BIN_PAR are BIT SLICES (section 1), and so that the
  //       multistage network has a power-of-two width, which every
  //       butterfly/omega topology requires.
  //   bin_par divides fft_size  -- so that a sweep is a whole number of groups
  //       and the frame's `eof` lands on a real beat.
  //   bin_par <= fft_size / 2   -- so that a frame is at least two beats and the
  //       framing is exercised. A one-beat frame would make `sof` and `eof`
  //       the same beat forever and hide every framing defect.
  //   groups a power of two     -- so that the reassembly entry index is
  //       group[GID_W-1:0], a bit slice rather than a modulo on the response
  //       path (section 3).
  function automatic logic algn_geom_ok(input algn_geom_t g);
    return (g.n_ant      >= 32'd1)                             &&
           (g.fft_size   >= 32'd4)  && algn_is_pow2(g.fft_size) &&
           (g.lanes      >= 32'd1)  && algn_is_pow2(g.lanes)    &&
           (g.lanes      <  g.fft_size)                         &&
           (g.frames_max >= 32'd2)  && algn_is_pow2(g.frames_max) &&
           (g.sample_w   >= 32'd2)  && (g.sample_w <= 32'd32)   &&
           (g.bin_par    >= 32'd2)  && algn_is_pow2(g.bin_par)  &&
           (g.bin_par    <= (g.fft_size / 32'd2))               &&
           (g.groups     >= 32'd2)  && algn_is_pow2(g.groups);
  endfunction

  // The history geometry this block reads from, as history_pkg's own struct, so
  // that every width on the response side comes from #15's package rather than
  // from a second copy of its arithmetic here.
  // Guarded like every other helper here, and for the same two reasons: it is
  // only DEFINED for a legal geometry, and the guard is what reads `bin_par` and
  // `groups`, which the conversion itself does not need — without it
  // `verilator --lint-only --Wall` reports UNUSEDSIGNAL on those two fields.
  function automatic history_pkg::hist_geom_t algn_hist_geom(input algn_geom_t g);
    return algn_geom_ok(g)
             ? history_pkg::hist_geom(history_pkg::hist_uint_t'(g.n_ant),
                                      history_pkg::hist_uint_t'(g.fft_size),
                                      history_pkg::hist_uint_t'(g.lanes),
                                      history_pkg::hist_uint_t'(g.frames_max),
                                      history_pkg::hist_uint_t'(g.sample_w))
             : history_pkg::hist_geom(32'd1, 32'd2, 32'd1, 32'd2, 32'd2);
  endfunction

  // ---------------------------------------------------------------------------
  // Derived counts and widths
  //
  // EVERY FUNCTION HERE IS GUARDED BY algn_geom_ok(), for the two reasons
  // history_pkg gives for the same discipline: a derived quantity is only
  // DEFINED for a legal geometry, and the guard reads every field of `g`, which
  // is what keeps `verilator --lint-only --Wall` from reporting UNUSEDSIGNAL on
  // the struct fields a given accessor does not need. The cost is zero: every
  // call site is an elaboration-time constant.
  // ---------------------------------------------------------------------------

  // `$clog2` of a count, floored at 1 so a degenerate geometry still yields a
  // legal vector width. Every width below goes through it.
  function automatic algn_uint_t algn_w_of(input algn_uint_t count);
    algn_uint_t w;
    w = algn_uint_t'($clog2(count));
    return (w == 32'd0) ? 32'd1 : w;
  endfunction

  // One antenna's slot in a vector: { im, re }, identical to
  // history_pkg::hist_word_w and to beamformer_pkg::bf_sample_pair_w. Stated
  // once here so this package's own arithmetic does not reach into either.
  function automatic algn_uint_t algn_pair_w(input algn_geom_t g);
    return algn_geom_ok(g) ? (32'd2 * g.sample_w) : 32'd1;
  endfunction

  // One bin's antenna vector — the unit the history returns and the unit the
  // network routes.
  function automatic algn_uint_t algn_vec_w(input algn_geom_t g);
    return g.n_ant * algn_pair_w(g);
  endfunction

  // The beamformer input beat: BIN_PAR bins, each a whole antenna vector,
  // bin-major and antenna-minor. This must equal
  // beamformer_pkg::bf_in_data_w(BIN_PAR, N_ANT) and align_net checks it.
  function automatic algn_uint_t algn_out_data_w(input algn_geom_t g);
    return g.bin_par * algn_vec_w(g);
  endfunction

  // Bit position of (bin j of the beat, antenna a) inside the output `data`
  // field. THE NORMATIVE STATEMENT of the beamformer input contract, on this
  // side of the boundary.
  function automatic algn_uint_t algn_out_lsb(input algn_geom_t g,
                                              input algn_uint_t lane,
                                              input algn_uint_t ant);
    return (lane * g.n_ant + ant) * algn_pair_w(g);
  endfunction

  function automatic algn_uint_t algn_bin_w(input algn_geom_t g);
    return algn_geom_ok(g) ? algn_w_of(g.fft_size) : 32'd1;
  endfunction

  // Beat position within a group; also the network's destination index.
  function automatic algn_uint_t algn_lane_w(input algn_geom_t g);
    return algn_geom_ok(g) ? algn_w_of(g.bin_par) : 32'd1;
  endfunction

  // Reassembly entry index.
  function automatic algn_uint_t algn_gid_w(input algn_geom_t g);
    return algn_geom_ok(g) ? algn_w_of(g.groups) : 32'd1;
  endfunction

  function automatic algn_uint_t algn_groups_per_frame(input algn_geom_t g);
    return algn_geom_ok(g) ? (g.fft_size / g.bin_par) : 32'd1;
  endfunction

  // Group index within a sweep, 0 .. GROUPS_PER_FRAME-1.
  function automatic algn_uint_t algn_gidx_w(input algn_geom_t g);
    return algn_w_of(algn_groups_per_frame(g));
  endfunction

  // Frame offset, carried straight through from #15's request port.
  function automatic algn_uint_t algn_foff_w(input algn_geom_t g);
    return algn_uint_t'(history_pkg::hist_foff_w(algn_hist_geom(g)));
  endfunction

  // ---------------------------------------------------------------------------
  // The routing key  (NORMATIVE — header sections 1 to 3)
  // ---------------------------------------------------------------------------

  // Which beat position bin `bin` occupies.
  function automatic algn_uint_t algn_lane_of_bin(input algn_geom_t g,
                                                  input algn_uint_t bin);
    return algn_geom_ok(g) ? (bin % g.bin_par) : 32'd0;
  endfunction

  // Which group bin `bin` belongs to.
  function automatic algn_uint_t algn_group_of_bin(input algn_geom_t g,
                                                   input algn_uint_t bin);
    return algn_geom_ok(g) ? (bin / g.bin_par) : 32'd0;
  endfunction

  // Which reassembly entry group `grp` is allocated in.
  function automatic algn_uint_t algn_gid_of_group(input algn_geom_t g,
                                                   input algn_uint_t grp);
    return algn_geom_ok(g) ? (grp % g.groups) : 32'd0;
  endfunction

  // The rotating request schedule (header section 2): which history read port
  // beat position `lane` of group `grp` is requested on.
  function automatic algn_uint_t algn_port_of(input algn_geom_t g,
                                              input algn_uint_t grp,
                                              input algn_uint_t lane);
    return algn_geom_ok(g) ? ((lane + grp) % g.bin_par) : 32'd0;
  endfunction

  // The bin beat position `lane` of group `grp` asks for.
  function automatic algn_uint_t algn_bin_of(input algn_geom_t g,
                                             input algn_uint_t grp,
                                             input algn_uint_t lane);
    return algn_geom_ok(g) ? (grp * g.bin_par + lane) : 32'd0;
  endfunction

  // ---------------------------------------------------------------------------
  // The routed word  (NORMATIVE)
  //
  //     net = { hflags , frame_id , frame_off , bin , vec }    vec at the bottom
  //
  // `vec` at the bottom for stream_pkg's reason for putting `data` at the top of
  // a payload: the field most likely to change width between configurations must
  // not move the others. Here it is the other way round — `vec` is the wide,
  // configuration-dependent field and the identity fields are narrow — so `vec`
  // goes at the BOTTOM and a waveform of the identity stays readable at a fixed
  // offset from the top as the antenna count changes.
  //
  // WHY `frame_id` IS CARRIED, at 32 bits and about 6% of the routed word. It is
  // the only field that can answer "is every antenna vector in this beat from
  // the SAME frame". `frame_off` cannot: it is relative to the newest complete
  // frame (history_pkg section 5), so two responses that both asked for offset 1
  // are from different absolute frames if a rotation happened between them —
  // and #15's `stale` flag only fires when the addressed SLOT was reused, which
  // is a later and coarser event. A beat assembled across a frame boundary is
  // the exact failure ARCHITECTURE.md 3.5 says is "not detectably wrong from the
  // output alone", and SPEC 7.4's "preserve frame identity" is the requirement
  // that it be detectable. Carrying the absolute number is what makes the entry
  // key complete; align_collect latches the first arrival's and rejects any
  // response that disagrees.
  //
  // `hflags` is history_pkg's three-bit response flag set, carried through so
  // that a beat assembled from a response #15 already marked `stale` or
  // `out_of_range` is marked in turn rather than silently laundered.
  // ---------------------------------------------------------------------------

  function automatic algn_uint_t algn_fid_w();
    return algn_uint_t'(history_pkg::HIST_FRAME_ID_W);
  endfunction

  function automatic algn_uint_t algn_net_data_w(input algn_geom_t g);
    return algn_vec_w(g) + algn_bin_w(g) + algn_foff_w(g) +
           (algn_geom_ok(g)
              ? (algn_fid_w() + algn_uint_t'(history_pkg::HIST_FLAGS_W))
              : 32'd0);
  endfunction

  function automatic algn_uint_t algn_net_vec_lsb(input algn_geom_t g);
    return algn_geom_ok(g) ? 32'd0 : 32'd0;
  endfunction

  function automatic algn_uint_t algn_net_bin_lsb(input algn_geom_t g);
    return algn_vec_w(g);
  endfunction

  function automatic algn_uint_t algn_net_foff_lsb(input algn_geom_t g);
    return algn_vec_w(g) + algn_bin_w(g);
  endfunction

  function automatic algn_uint_t algn_net_fid_lsb(input algn_geom_t g);
    return algn_vec_w(g) + algn_bin_w(g) + algn_foff_w(g);
  endfunction

  function automatic algn_uint_t algn_net_flags_lsb(input algn_geom_t g);
    return algn_vec_w(g) + algn_bin_w(g) + algn_foff_w(g) + algn_fid_w();
  endfunction

  // ---------------------------------------------------------------------------
  // The SPEC 5 `user` field of an output beat  (NORMATIVE)
  //
  // Four bits, LSB first. A consumer that decodes only the SPEC 5 bundle — the
  // beamformer does exactly that — must be able to tell a trustworthy beat from
  // one this block had to repair, without knowing anything about this package.
  // `|user[3:0]` is "something was wrong with this beat".
  // ---------------------------------------------------------------------------
  typedef enum int unsigned {
    ALGN_USER_MISSING   = 0,  // at least one lane never answered; its samples
                              // are zero (or stale, under cfg_partial_pass)
    ALGN_USER_DUPLICATE = 1,  // at least one lane answered more than once. The
                              // FIRST answer is the one in the beat
    ALGN_USER_ORPHAN    = 2,  // a response arrived for this entry that did not
                              // match the (group, frame_off) it was allocated
                              // for, and was discarded
    ALGN_USER_HIST      = 3   // OR of history_pkg's own response flags over the
                              // beat: some lane was stale, out of range or hit a
                              // read/write collision inside #15
  } algn_user_e;

  localparam int unsigned ALGN_USER_W = 4;

  // ---------------------------------------------------------------------------
  // Sticky fault bits, mirroring the four `user` bits at block scope. Same
  // encoding, so one decode serves both, and the same reason history_core has
  // `stat_fault`: a counter that has been cleared no longer says whether the
  // condition ever happened.
  // ---------------------------------------------------------------------------
  localparam int unsigned ALGN_FAULT_W = 4;

  // The two constants above are needed in PORT DECLARATIONS, so unlike every
  // other quantity in this package they cannot be functions. That has a
  // mechanical consequence issue #15's decision 13 records: a package localparam
  // the elaborated hierarchy never reads is reported as UNUSEDPARAM by
  // `verilator --lint-only --Wall`, and files.f lists this package for a top
  // that does not yet instantiate the block. So each one is given a READER
  // inside the package — this predicate, which an instance wanted anyway. It
  // states the invariant that makes "one decode serves both" true: the beat's
  // status field and the block's sticky fault word are the same four bits in the
  // same order, and a consumer that learns one has learned the other.
  function automatic logic algn_status_encoding_ok();
    return (ALGN_USER_W == ALGN_FAULT_W) &&
           (ALGN_USER_W > algn_uint_t'(ALGN_USER_HIST));
  endfunction

  // ---------------------------------------------------------------------------
  // Architecture selection
  //
  // An INTEGER rather than a string, and not because a string would not work:
  // quartus/scripts/calibrate.tcl drives the sweep through `set_parameter`,
  // which passes an integer cleanly and a string only with quoting that differs
  // between Quartus versions. Issue #12's bf_dot_wrap made the same choice for
  // the same reason (`VARIANT_SEL`), and this block is the one whose entire
  // point is that the sweep can select the architecture.
  // ---------------------------------------------------------------------------
  typedef enum int unsigned {
    ALGN_NET_XBAR = 0,  // rtl/align/align_xbar.sv — direct registered crossbar
    ALGN_NET_CLOS = 1   // rtl/align/align_clos.sv — multistage omega network
  } algn_net_e;

  function automatic logic algn_net_sel_ok(input algn_uint_t sel);
    return (sel == algn_uint_t'(ALGN_NET_XBAR)) ||
           (sel == algn_uint_t'(ALGN_NET_CLOS));
  endfunction

  // ---------------------------------------------------------------------------
  // Structural latency
  //
  // Exported as functions rather than localparams for the reason stream_pkg and
  // history_pkg both give: a package localparam a given build never reads is
  // reported as UNUSEDPARAM by `verilator --lint-only --Wall`, and this design
  // lints one top at a time.
  //
  // Latency means cycles from the edge at which a word is accepted on the
  // network's slave side to the edge at which it is presented on its master
  // side, with no backpressure. Under backpressure there is no fixed latency and
  // SPEC 12.5 forbids assuming one.
  //
  // THE TWO ARCHITECTURES ARE DELIBERATELY LATENCY-MATCHED AT BIN_PAR = 8 and
  // that is not a coincidence, it is the condition under which the comparison
  // means anything: `algn_xbar_latency(2) == algn_clos_latency(8) == 3`. A
  // comparison between a 3-cycle network and a 1-cycle network would be a
  // comparison of pipeline depths wearing two topologies' names. MUX_STAGES is
  // the knob that makes them match and the calibration sets it explicitly.
  // ---------------------------------------------------------------------------

  // align_xbar: the input capture register plus one register per mux level.
  function automatic algn_uint_t algn_xbar_latency(input algn_uint_t mux_stages);
    return 32'd1 + ((mux_stages == 32'd0) ? 32'd1 : mux_stages);
  endfunction

  // align_clos: one register per switch stage, log2(width) stages.
  function automatic algn_uint_t algn_clos_latency(input algn_uint_t width);
    return (width <= 32'd1) ? 32'd1 : algn_uint_t'($clog2(width));
  endfunction

  function automatic algn_uint_t algn_net_latency(input algn_uint_t sel,
                                                  input algn_uint_t width,
                                                  input algn_uint_t mux_stages);
    return (sel == algn_uint_t'(ALGN_NET_CLOS))
             ? algn_clos_latency(width)
             : algn_xbar_latency(mux_stages);
  endfunction

  // align_net end to end, response port to output stream: the ingress
  // key-decode register, the network, the reassembly write, and the output
  // elastic buffer. The beat itself is assembled combinationally out of the
  // reassembly entry and pushed straight into the buffer, so there is no
  // separate emit register to count.
  //
  // This is the latency of the LAST response of a beat. A beat cannot exist
  // before every one of its lanes has arrived, so there is no meaningful
  // first-response-to-output number and SPEC 12.5 forbids assuming one anyway.
  function automatic algn_uint_t algn_block_latency(input algn_uint_t sel,
                                                    input algn_uint_t width,
                                                    input algn_uint_t mux_stages);
    return 32'd1 + algn_net_latency(sel, width, mux_stages) + 32'd1 +
           algn_uint_t'(stream_pkg::stream_elastic_latency());
  endfunction

  // ---------------------------------------------------------------------------
  // Timeout bound
  //
  // The default missing-sample timeout, in cycles, for a geometry. It has to be
  // comfortably longer than the worst honest round trip — #15's read latency,
  // plus the network, plus the time a fully-backpressured output can hold a
  // group open — or the detector would report a stall as a loss, which is the
  // one thing a missing-sample counter must never do.
  //
  // The bound is GROUPS * (history latency + network latency) + a margin: the
  // deepest legitimate queueing is every reassembly entry occupied with every
  // response still in flight. It is a PARAMETER on the module, defaulted from
  // here, so a system with a slower memory can raise it without editing RTL.
  // ---------------------------------------------------------------------------
  function automatic algn_uint_t algn_default_timeout(input algn_geom_t g,
                                                      input algn_uint_t sel,
                                                      input algn_uint_t mux_stages);
    algn_uint_t rt;
    rt = algn_uint_t'(history_pkg::hist_read_latency()) +
         algn_net_latency(sel, algn_geom_ok(g) ? g.bin_par : 32'd2, mux_stages);
    return (algn_geom_ok(g) ? g.groups : 32'd2) * rt + 32'd16;
  endfunction

  function automatic algn_uint_t algn_timeout_w(input algn_uint_t timeout);
    return algn_w_of(timeout + 32'd1);
  endfunction

endpackage : align_pkg

`default_nettype wire
