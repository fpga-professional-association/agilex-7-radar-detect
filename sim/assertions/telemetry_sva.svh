// -----------------------------------------------------------------------------
// telemetry_sva.svh — the reusable SPEC 14 telemetry property set (issue #8).
//
// SPEC 14 requires assertions for "arithmetic overflow where overflow is
// forbidden" and for "sequence discontinuity", and requires them to remain
// active in fast simulation. This header holds that property TEXT, once, in the
// shape stream_sva.svh and cdc_sva.svh already established:
//
//   1. `telemetry_assertions` (sim/assertions/telemetry_assertions.sv) is a
//      module built from the counter macros below. rtl/common/perf_counter.sv
//      instantiates one under `ifndef SYNTHESIS`, so every counter in the design
//      — and there is exactly one counter implementation — is checked in every
//      build with no test-side wiring.
//   2. The sequence macro is used directly, inside rtl/common/seq_checker.sv.
//      The properties are about that module's own decision, not about an
//      interface it could be bound to, so an instance would only add a port
//      list. stream_sva.svh sanctions this second form explicitly.
//
// One use of each macro per scope: the macros declare fixed assertion names.
//
// MEASURED PREPROCESSOR HAZARD (stream_sva.svh, issue #5): this preprocessor
// substitutes macro arguments inside string literals. No message below may
// contain a word that is also a parameter name of the macro it sits in, which is
// why every parameter here carries an `_i` / `_ni` suffix that no prose uses.
// -----------------------------------------------------------------------------

`ifndef TELEMETRY_SVA_SVH_
`define TELEMETRY_SVA_SVH_

// -----------------------------------------------------------------------------
// `TELEMETRY_SVA_COUNTER(clk_i, rst_ni, en_i, ev_i, clr_i, snap_i, cnt_i,
//                        shadow_i, shvalid_i, wrp_i, wrpd_i)
//
// The mode-independent obligations of perf_counter — the ones that hold whether
// the counter wraps or saturates.
//
//   a_count_gated       a counter that is not counting and not being cleared
//                       does not move. This is the whole meaning of the gate:
//                       a measurement window that leaked would make every
//                       number downstream wrong by an unknown amount.
//   a_count_cleared     clear takes effect in one cycle and beats a simultaneous
//                       event.
//   a_shadow_holds      the shadow changes ONLY on a snapshot or a clear. This
//                       is the property the whole coherent-read mechanism rests
//                       on: if the shadow could move on its own, a multi-word
//                       read would describe no single instant.
//   a_shadow_latched    one cycle after a snapshot the shadow equals the live
//                       count. Both registers take the same next-state value at
//                       the strobe edge, so this is the executable form of the
//                       "captured at the same edge" rule in perf_counter's
//                       header, and it is what makes the off-by-one at the call
//                       site checkable rather than assumed.
//   a_shadow_valid      the shadow-valid flag is sticky until a clear.
//   a_wrapped_sticky    so is the wrap flag.
//   a_wrap_needs_event  a counter cannot pass its maximum in a cycle in which it
//                       was not counting.
//
// The covers record that the interesting states were reached at all: a wrap, and
// a snapshot taken while the counter was still moving.
// -----------------------------------------------------------------------------
`define TELEMETRY_SVA_COUNTER(clk_i, rst_ni, en_i, ev_i, clr_i, snap_i, cnt_i, shadow_i, shvalid_i, wrp_i, wrpd_i) \
  property p_count_gated;                                                       \
    @(posedge (clk_i)) disable iff (!(rst_ni))                                  \
      (!((en_i) && (ev_i)) && !(clr_i)) |=> $stable(cnt_i);                     \
  endproperty                                                                   \
  a_count_gated : assert property (p_count_gated)                               \
    else $error("perf counter: advanced while gated off");                      \
                                                                                \
  property p_count_cleared;                                                     \
    @(posedge (clk_i)) disable iff (!(rst_ni))                                  \
      (clr_i) |=> ((cnt_i) == '0);                                              \
  endproperty                                                                   \
  a_count_cleared : assert property (p_count_cleared)                           \
    else $error("perf counter: did not reach zero after a synchronous clear");  \
                                                                                \
  property p_shadow_holds;                                                      \
    @(posedge (clk_i)) disable iff (!(rst_ni))                                  \
      (!(snap_i) && !(clr_i)) |=> $stable(shadow_i);                            \
  endproperty                                                                   \
  a_shadow_holds : assert property (p_shadow_holds)                             \
    else $error("perf counter: the shadow register moved without a strobe");    \
                                                                                \
  property p_shadow_latched;                                                    \
    @(posedge (clk_i)) disable iff (!(rst_ni))                                  \
      (snap_i) |=> ((shadow_i) == (cnt_i));                                     \
  endproperty                                                                   \
  a_shadow_latched : assert property (p_shadow_latched)                         \
    else $error("perf counter: the shadow does not equal the live value one cycle after a strobe"); \
                                                                                \
  property p_shadow_valid;                                                      \
    @(posedge (clk_i)) disable iff (!(rst_ni))                                  \
      ((shvalid_i) && !(clr_i)) |=> (shvalid_i);                                \
  endproperty                                                                   \
  a_shadow_valid : assert property (p_shadow_valid)                             \
    else $error("perf counter: the shadow-valid flag dropped without a clear"); \
                                                                                \
  property p_wrapped_sticky;                                                    \
    @(posedge (clk_i)) disable iff (!(rst_ni))                                  \
      ((wrpd_i) && !(clr_i)) |=> (wrpd_i);                                      \
  endproperty                                                                   \
  a_wrapped_sticky : assert property (p_wrapped_sticky)                         \
    else $error("perf counter: the sticky range flag dropped without a clear"); \
                                                                                \
  property p_wrap_needs_event;                                                  \
    @(posedge (clk_i)) disable iff (!(rst_ni))                                  \
      (!((en_i) && (ev_i))) |=> !(wrp_i);                                       \
  endproperty                                                                   \
  a_wrap_needs_event : assert property (p_wrap_needs_event)                     \
    else $error("perf counter: passed its maximum in a cycle with nothing to add"); \
                                                                                \
  property p_cover_wrap;                                                        \
    @(posedge (clk_i)) disable iff (!(rst_ni)) (wrp_i);                         \
  endproperty                                                                   \
  c_wrap : cover property (p_cover_wrap);                                       \
                                                                                \
  property p_cover_snap_live;                                                   \
    @(posedge (clk_i)) disable iff (!(rst_ni)) ((snap_i) && (en_i) && (ev_i));  \
  endproperty                                                                   \
  c_snapshot_while_counting : cover property (p_cover_snap_live);

// -----------------------------------------------------------------------------
// `TELEMETRY_SVA_COUNTER_SAT(clk_i, rst_ni, clr_i, cnt_i, wrp_i)
//
// SPEC 14 "arithmetic overflow where overflow is forbidden", for the saturating
// mode. A saturating counter that wrapped would silently turn a large error
// count into a small one, which is the single worst failure a telemetry counter
// can have: it reports success.
//
//   a_sat_holds_max     the cycle the counter reports passing its maximum, it
//                       already reads all ones.
//   a_sat_never_falls   and it never decreases thereafter, other than through a
//                       deliberate clear. Together these say the count is a
//                       monotone lower bound on the true number of events, which
//                       is exactly what a saturating counter promises.
// -----------------------------------------------------------------------------
`define TELEMETRY_SVA_COUNTER_SAT(clk_i, rst_ni, clr_i, cnt_i, wrp_i)           \
  property p_sat_holds_max;                                                     \
    @(posedge (clk_i)) disable iff (!(rst_ni))                                  \
      (wrp_i) |-> ((cnt_i) == '1);                                              \
  endproperty                                                                   \
  a_sat_holds_max : assert property (p_sat_holds_max)                           \
    else $error("saturating counter: reported passing its limit without holding all ones"); \
                                                                                \
  property p_sat_never_falls;                                                   \
    @(posedge (clk_i)) disable iff (!(rst_ni))                                  \
      (!(clr_i)) |=> ((cnt_i) >= $past(cnt_i));                                 \
  endproperty                                                                   \
  a_sat_never_falls : assert property (p_sat_never_falls)                        \
    else $error("saturating counter: decreased, so an event was lost to overflow");

// -----------------------------------------------------------------------------
// `TELEMETRY_SVA_COUNTER_MOD(clk_i, rst_ni, cnt_i, wrp_i)
//
// The modulo mode's half of the same obligation: a reported wrap must BE a wrap.
// Every increment is smaller than the modulus, so the value after a wrap is
// strictly below the value before it — and a "wrap" that left the count higher
// would mean the flag, not the arithmetic, is wrong.
// -----------------------------------------------------------------------------
`define TELEMETRY_SVA_COUNTER_MOD(clk_i, rst_ni, cnt_i, wrp_i)                  \
  property p_mod_wraps_down;                                                    \
    @(posedge (clk_i)) disable iff (!(rst_ni))                                  \
      (wrp_i) |-> ((cnt_i) < $past(cnt_i));                                     \
  endproperty                                                                   \
  a_mod_wraps_down : assert property (p_mod_wraps_down)                         \
    else $error("modulo counter: reported passing its limit but did not come out below where it went in");

// -----------------------------------------------------------------------------
// `TELEMETRY_SVA_SEQ(clk_i, rst_ni, act_i, gap_i, dup_i, ror_i, unt_i, gsz_i)
//
// SPEC 14 "sequence discontinuity", as the obligations of the detector rather
// than of the stream. The stream's own continuity is checked by
// `STREAM_SVA_FRAMING` in stream_sva.svh; this checks that the module that
// CLASSIFIES a discontinuity classifies it exactly once and only when it saw
// something.
//
//   a_seq_one_kind      a beat is in order, or lost, or repeated, or out of
//                       order, or on a stream this instance does not track —
//                       never two of those at once. Without this the counters
//                       could double count and still look plausible.
//   a_seq_needs_beat    no classification without an accepted beat.
//   a_seq_gap_nonzero   a reported loss lost at least one beat.
// -----------------------------------------------------------------------------
`define TELEMETRY_SVA_SEQ(clk_i, rst_ni, act_i, gap_i, dup_i, ror_i, unt_i, gsz_i) \
  property p_seq_one_kind;                                                      \
    @(posedge (clk_i)) disable iff (!(rst_ni))                                  \
      $countones({(gap_i), (dup_i), (ror_i), (unt_i)}) <= 1;                    \
  endproperty                                                                   \
  a_seq_one_kind : assert property (p_seq_one_kind)                             \
    else $error("sequence checker: one beat classified as more than one kind of fault"); \
                                                                                \
  property p_seq_needs_beat;                                                    \
    @(posedge (clk_i)) disable iff (!(rst_ni))                                  \
      ((gap_i) || (dup_i) || (ror_i) || (unt_i)) |-> (act_i);                   \
  endproperty                                                                   \
  a_seq_needs_beat : assert property (p_seq_needs_beat)                         \
    else $error("sequence checker: reported a fault without an accepted transfer"); \
                                                                                \
  property p_seq_gap_nonzero;                                                   \
    @(posedge (clk_i)) disable iff (!(rst_ni))                                  \
      (gap_i) |-> ((gsz_i) != '0);                                              \
  endproperty                                                                   \
  a_seq_gap_nonzero : assert property (p_seq_gap_nonzero)                       \
    else $error("sequence checker: reported a loss of zero beats");

`endif  // TELEMETRY_SVA_SVH_
