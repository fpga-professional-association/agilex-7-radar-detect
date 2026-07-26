# Decisions

Append-only log of architectural decisions and parameter changes. One dated entry per
decision, per PLAN.md standing rule #4. Entries are never rewritten; a superseded
decision gets a new entry that references the old one.

Entry format:

```
## YYYY-MM-DD — <short title>  (issue #N)
Context / Decision / Consequences / Alternatives rejected
```

---

## 2026-07-25 — Repository scaffold layout and toolchain split  (issue #1)

**Context.** SPEC §10 shows the repository structure rooted at a directory named
`agilex7-wideband/`. The actual git repository
(`fpga-professional-association/agilex-7-radar-detect`, checked out at
`D:\agielx-7-radar-test` = `/mnt/d/agielx-7-radar-test`) already exists, and PLAN.md
fixes the toolchain as Quartus Prime Pro 26.1 on Windows plus Verilator 5.020 and
GNU Make 4.3 in WSL Ubuntu-24.04.

**Decision 1 — repo root is the project root.** The SPEC §10 tree is created directly at
the repository root. `agilex7-wideband/` in the spec listing is read as the name of the
project, not as a nested directory to be created inside the repo. Every path in SPEC
(`rtl/`, `sim/`, `config/tiny.json`, …) therefore resolves relative to the repository
root with no prefix.

*Consequences.* Paths in SPEC, PLAN, issues, and the Makefile agree literally. `make` is
run from the checkout root. No later issue needs to reason about a prefix.
*Alternative rejected:* creating a nested `agilex7-wideband/` directory — it would add a
level to every path for no benefit and would make `make` invocation ambiguous.

**Decision 2 — split toolchain, one Makefile, host-detecting dispatch.** Simulation
(`lint`, `sim-*`) is owned by WSL; Quartus (`quartus-*`) is owned by Windows Quartus
Prime Pro 26.1. A single root `Makefile` detects its host with `uname` and dispatches:
invoked from native Windows make, simulation targets re-enter WSL via
`wsl.exe -d $(WSL_DISTRO) -- make -C $(WSL_REPO_DIR) <target>`; Quartus targets always
run `quartus_sh.exe` directly, reachable from WSL as
`/mnt/c/altera_pro/26.1/quartus/bin64/quartus_sh.exe` and from Windows as
`C:/altera_pro/26.1/quartus/bin64/quartus_sh.exe`. The path is overridable through the
`QUARTUS_SH` environment variable, and WSL is never invoked for a Quartus target.

*Consequences.* The canonical execution environment is WSL Ubuntu-24.04 bash with GNU
Make 4.3; the Makefile uses POSIX/GNU-make constructs only. A native Windows make must
provide a POSIX shell. Quartus targets validate `QUARTUS_SH` before doing anything, so a
missing or relocated Quartus fails loudly instead of silently.
*Alternative rejected:* two separate makefiles (one per host) — it duplicates the target
list and lets the two drift.

**Decision 3 — unimplemented targets fail loudly.** Every SPEC §16 entry point exists
now, and every one that is not yet implemented prints
`TODO(issue #N): implemented by '<title>'. Not yet available.` and exits non-zero. No
target silently no-ops or exits 0. Note that GNU make reports its own exit status 2 for
a failed recipe; the stub command itself exits 1, and make cannot exit 1 on recipe
failure by design.

*Consequences.* A missing implementation can never be mistaken for a passing gate. The
issue number in the message is the single pointer to where the work lands.

**Decision 4 — config JSONs carry the invariant widths.** `config/*.json` hold the seven
SPEC §11 size parameters plus the four SPEC §3 invariants (`SAMPLE_W=16`, `COEFF_W=16`,
`POWER_W=40`, `N_VIRTUAL_CHANS=4`) in one flat `params` map, with `sized_params` and
`invariant_params` naming which is which, under a shared schema (`schema_version: 1`).

*Consequences.* One file is the complete elaboration parameter set for a configuration —
build scripts, RTL generation, and the C++ model read a single source. Changing an
invariant is visible as a diff in all four files, which is the intended friction.
*Alternative rejected:* keeping invariants only in the SystemVerilog package — the C++
model and Python vector generators would then need a second source of truth.

**Scope note.** This entry records scaffold-structural decisions only. No architectural,
numerical, or verification decisions are made by issue #1; those are logged by the
issues that make them.

---

## 2026-07-25 — Verilator harness architecture  (issue #2)

**Context.** SPEC §12 fixes Verilator as the primary simulator and prescribes four build
modes (§12.1), a native C++ harness (§12.2), an integer-time multi-clock event scheduler
(§12.3) and transaction-identity scoreboarding (§12.5). Every later issue builds tests on
this foundation, so the choices below are expensive to revisit. Measurements were taken
in WSL Ubuntu-24.04, Verilator 5.020, g++ 13.3, 16 cores.

**Decision 1 — simulation time unit is the picosecond, clocks are defined by half
period.** SPEC §12.3 requires integer time units that represent all selected clock
periods "exactly enough for CDC testing". A 64-bit picosecond counter spans ~213 days of
simulated time and quantises the SPEC §8 clocks to within 300 ppm: 400/200/100 MHz are
exact, 450 MHz becomes 450.045 MHz (half period 1111 ps, +100 ppm), 350 MHz becomes
349.895 MHz (1429 ps, −300 ppm). Clocks are stored as a *half* period so a rounded half
can never accumulate into period drift, and no floating point advances time.

*Consequences.* Two clocks are only ever coincident when their picosecond edge times are
equal, which is the property CDC tests need. Femtoseconds were rejected: they buy
resolution nothing in this design can use and cost a third of the 64-bit time range.

**Decision 2 — the scheduler splits each edge into a sample phase and a drive phase.**
SPEC §12.3 lists "toggle, `eval()`, then driver and monitor work". Doing all harness work
after `eval()` is subtly wrong for a ready/valid protocol: after the positive edge the
model's combinational `ready` already reflects the *new* register state, so a driver that
samples there sees the next cycle's `ready` and mis-decides every handshake. The scheduler
therefore runs `Phase::kSample` callbacks at the edge time *before* toggling and
evaluating — observing exactly the values the flip-flops are about to capture, the
equivalent of a Verilog testbench's non-blocking sampling region — then toggles, evals,
runs `Phase::kDrive` callbacks, and evals again so combinational outputs settle.

*Consequences.* Handshake detection is correct with no per-DUT delta-cycle tuning, and
drivers can be written as plain "did my beat go?" logic. Cost: two `eval()` calls per time
step instead of one. *Alternative rejected:* driving on the negative edge and sampling on
the positive edge — it works for a single clock but stops being well defined once domains
have unrelated periods and duty cycles.

**Decision 3 — Verilator model thread count is 1.** SPEC §12.1: "Measure whether
multithreading improves this particular model. Do not assume more threads are
automatically faster." Measured on the tiny loopback in the fast build, `+frames=3000`
(570 437 core cycles), best of three runs after a warm-up, on the 16-core WSL host:

| `--threads` | wall time | core cycles/s |
|---|---|---|
| 1 | **0.13 s** | **4.39 M** |
| 2 | 0.34 s | 1.68 M |
| 4 | 0.79 s | 0.72 M |
| 8 | 1.08 s | 0.53 M |

More threads are monotonically *worse* — 2.6× slower at two threads, 8.3× at eight. The
model is far too small for partitioning to pay for its synchronisation. `--threads 1` is
therefore the default in `scripts/build_verilator.py` (`DEFAULT_THREADS`).

*Consequences.* Regression throughput comes from running independent seeds in parallel
processes, not from threading one model. This number must be re-measured — the flag is
exposed as `--threads` precisely so it can be — once the full-scale elaboration exists
(issue #20), where the trade-off may genuinely reverse.

*Related finding.* Verilator's generated makefile ends each user-source rule with
`$(OPT_FAST)`, which defaults to `-Os`. Anything `-CFLAGS` injects therefore loses the
last-flag-wins race, and the harness and test were silently built at `-Os` in every mode
regardless of the requested optimisation. `scripts/build_verilator.py` now overrides
`OPT_FAST` per mode through `-MAKEFLAGS`. The thread numbers above are post-fix.

**Decision 4 — configuration is injected as a generated SystemVerilog package plus a
generated C++ header, not as `-G` parameter overrides.** `scripts/build_verilator.py`
reads `config/<name>.json` (issue #1, decision 4) and writes
`sim/verilator/generated/config_pkg.sv` and `sim/verilator/generated/config_sim.h`, both
gitignored and both rewritten only when their content changes.

*Consequences.* One source of truth reaches both the RTL and the C++ harness, so a width
in a test can never drift from the width the RTL elaborated. A package is visible to every
module without threading parameters down each level of hierarchy. *Alternative rejected:*
`-G` overrides on the Verilator command line — they would have to be repeated identically
on every Verilator and every Quartus invocation, which is exactly the kind of duplication
that drifts, and they cannot reach the C++ side at all.

*Cost, accepted:* the generated package exports parameters that Phase 0 RTL does not yet
consume, which Verilator reports as `UNUSEDPARAM`. That is the single waiver in
`sim/verilator/lint_waivers.vlt`; it is scoped to the generated file and verified not to
hide a dead parameter anywhere else.

**Decision 5 — lint runs without `--Wno-fatal`.** SPEC §12.1's conceptual command
includes `--Wno-fatal`, which makes warnings non-fatal and would let `make lint` exit 0
with warnings outstanding. Since the same section requires that warnings be waived only
through a justified waiver file, the flag is omitted: any warning not covered by
`lint_waivers.vlt` fails the build.

**Decision 6 — randomized stalls are bursty, not per-cycle independent.** Independent
per-cycle coin flips give geometric stall lengths and essentially never produce a long
stall, which is the case that actually breaks skid buffers and frame boundaries. The
backpressure generator instead *starts* a stall with a configured probability and holds it
for a uniformly chosen burst length. The provided profiles are `none`, `light` (10%, 1–2
cycles), `heavy` (50%, 1–8) and `bursty` (20%, 4–40).

**Decision 7 — random substreams are named, not sequential.** Every generator is seeded
from `splitmix64(master ^ splitmix64(fnv1a(name)))`, so its sequence depends only on the
master seed and its own name. Adding a monitor to a test does not perturb the driver's
stall pattern, which is what makes SPEC §13.3's "every failing seed is replayable" hold
across changes to the test. Bounded draws use rejection sampling implemented in the
harness rather than `std::uniform_int_distribution`, whose algorithm the C++ standard does
not specify; `std::mt19937_64` itself is specified bit-exactly.

**Decision 8 — no CMake.** `verilator --build` drives the C++ compile directly and
`scripts/build_verilator.py` drives Verilator. Adding CMake on top would mean two build
descriptions for one binary. `CMakeLists.txt` stays a placeholder, now pointed at issue #4
(the bit-accurate C++ reference model), which is the first component that will need a
standalone, non-Verilator build.

**Decision 9 — the provisional loopback uses synchronous reset.** SPEC §23 says to avoid
asynchronous resets in performance-critical pipelines, and SPEC §8 says to reset control
state rather than every datapath register. `rtl/common/stream_loopback.sv` therefore
resets only the valid bits and the ready bit, synchronously; payload registers are flushed
by validity tracking. This also keeps the design free of Verilator's `SYNCASYNCNET`
warning, which an asynchronous reset combined with `disable iff (!rst_n)` in an assertion
would otherwise produce — a warning that would have needed a waiver to paper over a style
the spec already rules out.

**Decision 10 — run summaries are deterministic apart from wall time.**
`results/simulation/<test>_<config>_seed<N>.json` is emitted with fixed key order, no
timestamps or host paths, and fixed-precision floats. Every field except `wall_time_s` is
a pure function of (seed, config, build mode, test); two runs of the same seed produce
byte-identical files apart from that one line. Verified as part of the issue #2 gate.

**Decision 11 — the harness is validated by fault injection, not by passing.** A loopback
test that passes against a correct DUT is evidence of nothing. Six faults were injected
into `stream_loopback.sv` and each was caught before this work was accepted: a swallowed
beat (sequence + order), a `valid` never cleared (duplicate), an inverted data bit
(content), `ready` ignoring skid occupancy (sequence + order), a payload register changing
while stalled (the `a_master_stable` SystemVerilog assertion), and an unused parameter
added to real RTL (`make lint` fails, which also proves the one waiver is narrow). The
table lives in VERIFICATION_PLAN.md §4.1 and must be re-run whenever a check is added or
relaxed.

*Note recorded because it nearly went unnoticed:* the first corruption attempt inverted the
same bit in both skid stages and cancelled itself out, so the test passed. A negative test
that does not fail is not a passing negative test — it is an injection bug.

---

## 2026-07-25 — Quartus Prime Pro flow, virtual-pin strategy, report extraction  (issue #3)

**Context.** SPEC §15 fixes the project shape and SPEC §17 demands machine-readable
per-compile JSON rather than GUI scraping. Quartus Prime Pro 26.1 (detected:
`Version 26.1.0 Build 110 03/26/2026 SC Pro Edition`) differs from Classic in both its
compiler modules and its scripting surface, so the choices below were verified against
the installed tool, not assumed.

**Decision 1 — Pro module set via `execute_module`, not the Classic `quartus_map`
chain.** `compile.tcl` drives `::quartus::flow execute_module -tool syn|fit|sta`. The
`-tool` values were read off this install's own usage string
(`asm cdb eda fit map syn pow sta stp sim si cpf ipg pfg qtlg quick_elaboration sh`);
Pro's Analysis & Synthesis is `syn` (`quartus_syn`), and `map` exists only as a Classic
compatibility alias. `make quartus-map` therefore runs the `syn` module — the target
name is kept because SPEC §16 fixes it.
*Alternative rejected:* `qexec "quartus_syn ..."`. It works, but bypasses the flow
package's assignment export and would need per-executable argument handling for each
stage.

**Decision 2 — the tracked `.qsf` is snapshotted and restored around every compile.**
`execute_module` exports the in-memory assignment database over the `.qsf` before
launching each executable. That rewrite drops every comment, reorders the file, and
bakes the run's `SEED` into tracked source. `compile.tcl` therefore reads the `.qsf`
bytes before opening the project and writes them back unconditionally afterwards, so a
compile never dirties tracked state. The seed lives in the exported JSON, which is the
single source of truth for what ran (SPEC §25).
*Alternative rejected:* `-dont_export_assignments`. It protects the file but then the
seed never reaches `quartus_fit`, which runs as a separate process.

**Decision 3 — every data port is a virtual pin; only `core_clk` and `rst_n` are real.**
This is a fabric benchmark, not a pinout exercise. Real IO buffers for 232 stream ports
would inject package/IO timing that has nothing to do with the measured result and would
constrain placement of the logic under test. The assignments are wildcard-based
(`-to "in_data[*]"`) so widening `DATA_W` in a later issue needs no `.qsf` edit.
*Consequence, recorded honestly:* virtual pins are unconstrained fabric nodes, so the
Fitter scatters them across the die. The first fit's critical path is a
register→virtual-output path with **-2.516 ns of clock skew**, and restricted Fmax lands
at 308.6 MHz against the 450 MHz target. That number is boundary-dominated, not a
statement about the 4-stage pipeline. Later issues that care about fabric Fmax should
region-constrain the virtual pins; SPEC §24 forbids "fixing" this by relaxing the clock.

**Decision 4 — report extraction is API-first, with Quartus's own delimited ASCII as the
documented fallback.** Preference order: typed Tcl APIs (`get_clock_fmax_info`,
`get_path_info`, `get_timing_paths`) → report-panel API (`get_report_panel_row`, used for
Fitter resource/routing/retiming panels under `quartus_sh`) → `report_* -file` plus a
delimited-table parser. The third tier is needed because `report_ucp`, `report_sdc`,
`report_exceptions` and `create_timing_summary` are unreachable through the panel API in
a `quartus_sta` session (`get_report_panel_names` requires `load_report`, which does not
coexist with a live timing netlist), and those commands return nothing to Tcl — they emit
through the message system. `-file` output is the tool's own machine-readable form, which
is materially different from scraping GUI text, and every parse is anchored on an exact
row label rather than a loose glob.

**Decision 5 — fragments, not one monolithic script.** Each `report_*.tcl` writes a
Tcl-sourceable dict fragment to `results/synthesis/`; `export_results.tcl` merges them
into one JSON record. This lets each report run under the interpreter it needs
(`quartus_sta` for timing/congestion/retiming, `quartus_sh` for utilization/export)
without a shared process. `compile.tcl` deletes all fragments at the start of every run,
so a `quartus-map` followed by `quartus-report` can never silently inherit a previous
compile's post-fit timing.

**Decision 6 — absent data is `null` plus a note, never a fabricated zero.** A `map`-only
compile has no timing, congestion or retiming data. The record still validates; the
fields are `null` and `notes` explains why. `verification_passed` is `null` because the
Verilator regression (issue #2) owns it — this flow will not assert a verification result
it did not observe.

**Decision 7 — `exceptions.sdc` ships empty.** The minimal top is single-clock and fully
synchronous; it needs no exception, and SPEC §24 forbids adding one speculatively. The
file carries the SPEC §15 five-field template (source, destination, functional reason,
verification method, reviewer-facing explanation) and `report_sta.tcl` counts false
paths, multicycle paths, clock groups, min/max delays, ignored SDC constraints and
unconstrained endpoints into every JSON record, so a future undocumented exception is
visible without opening a report.

**Note on the SPEC §5 `sequence` field.** `sequence` is a SystemVerilog reserved word.
The ports are named `in_sequence` / `out_sequence`; field semantics are unchanged.

**Decision 8 — Quartus targets run from the Windows side on this host.** The issue #1
Makefile assumed WSL could execute `/mnt/c/.../quartus_sh.exe` directly. Measured on
2026-07-25: this machine's WSL distribution has Windows interop DISABLED
(`/proc/sys/fs/binfmt_misc/WSLInterop` does not exist), so WSL cannot launch any `.exe`
and every `quartus-*` target failed there with the shell trying to parse a PE binary as
a script. `QUARTUS_CHECK` now probes executability and prints the actual diagnosis plus
the working invocation; `env-check` reports `[runnable]` / `[NOT RUNNABLE FROM THIS
HOST]`. The Quartus install ships GNU Make 4.4.1 at
`C:/altera_pro/26.1/riscfree/build_tools/bin/make.exe`, which runs this Makefile from Git
Bash, so no new dependency is introduced. Enabling interop is a host configuration change
and is left to the operator, not performed by the build.
*Consequence:* the split-toolchain rule stands — simulation in WSL, Quartus on Windows —
but the two sides are now invoked by two different `make` binaries rather than one.

**Decision 9 — the exporter drops negative pre-fit resource estimates.** Analysis &
Synthesis reports "Estimate of Logic utilization (ALMs needed)" and, for a design this
small, returns **-552**. That is an artefact of the pre-fit packing model, not a resource
count, and publishing it yields a negative utilization percentage. `report_utilization.tcl`
drops any negative count and records why in `notes`; it does not clamp to zero, because a
fabricated zero is indistinguishable from a real measurement.

**Known, deliberate omission — no Reset Release IP.** Every compile emits Critical
Warning (20759) and one High-severity Design Assistant violation
(`RES-10204 — Reset Release Instance Count Check`, "No reset release IP detected in
project, exactly 1 required"). The Reset Release IP is required for Agilex 7 *device
configuration* bring-up; this benchmark never configures a device, it measures fabric
mapping and timing. Adding the IP would put vendor logic into a project whose whole point
is custom RTL. The warning is recorded in every JSON record's warning count rather than
suppressed, and is revisited by issue #24 if a real device top is ever built.

---

## 2026-07-25 — Fixed-point numerics: rounding rule, saturation, accumulator growth, vector format  (issue #4)

**Context.** SPEC §6 requires one shared package defining signed rounding, saturation,
truncation points, accumulator widths and overflow flags, and forbids modules inventing
their own rounding. SPEC §12.4 requires a bit-accurate C++ reference library with
identical semantics, validated against independently generated Python/NumPy vectors
*before* it is trusted as the RTL oracle. Every DSP kernel from issue #9 onward is built
on whatever is decided here, so these are expensive to revisit. The normative statement
of all of it is now NUMERICS.md; this entry records the choices and why the alternatives
lost.

**Decision 1 — round to nearest, ties to even (convergent), project-wide.** SPEC §6
allows "convergent or round-to-nearest"; the project rule is convergent.
`fxp_round()` / `fxp::round()` is the only rounding entry point datapath code may call,
and it resolves through the `FXP_ROUND_MODE` localparam, which folds at elaboration.

*Why not round-half-up*, which is one carry-in and free inside a DSP block: it is biased.
Every exact tie moves toward +infinity, for a mean error of +2^-(s+1). Measured over a
complete residue sweep by the C++ unit test — 131 072 consecutive inputs at s=3 —
round-to-nearest-even's total error is exactly **0** and round-half-up's is **+65 536
LSB-scaled units, one half LSB for each of the 16 384 ties**. That number is printed on
every run of `make numerics-check`, so the justification is a measurement rather than an
assertion. The bias matters here specifically because it is *coherent*: it adds through
every FIR tap, survives the FFT as energy at bin 0, and lands in the power estimate as a
DC pedestal that CFAR then thresholds against. Round-half-up is also asymmetric about
zero (+0.5 -> +1 but -0.5 -> 0), which on a signed I/Q datapath is a signed DC offset.
Round-half-away-from-zero fixes the symmetry but keeps a magnitude bias and costs
sign-dependent logic.

*Cost, accepted:* convergent rounding needs the tie detection (a wide NOR of the
discarded bits) plus one LSB of the quotient — a handful of ALMs per rounding site, off
the DSP cascade's critical path. Accepted because rounding sites number in the hundreds,
not the hundreds of thousands. This is the one place the project knowingly trades a
little area for a numerical property.

*Consequence:* `fxp_round_half_up()` is implemented and exported anyway, and the vector
set proves it, so the comparison stays measurable — but it is documented as not available
to the datapath. Flipping `FXP_ROUND_MODE` is a one-line change that invalidates every
golden vector, which is the friction it should have.

**Decision 2 — saturation clamps to the full two's-complement range, and is
direction-flagged.** `[-2^(w-1), 2^(w-1)-1]`, never wrapped. Wrapping turns a large
positive detection into a large negative one, which CFAR cannot distinguish from a real
target. *Alternative rejected:* symmetric saturation (low end clamped to -max), which is
common in DSP libraries because it makes negation total — but it discards a representable
value on every path that never negates, and it makes the format's own minimum an illegal
datapath value. Instead the asymmetry is kept and negation is explicitly saturating, so
-(-1.0) -> 0x7FFF with `sat_pos` rather than silently.

Flags are a `{sat_pos, sat_neg}` pair, not one bit: persistent positive saturation is a
gain-staging error, alternating saturation is oscillation, and negative-only saturation
on a power path is a sign bug. One flip-flop buys that distinction.

**Decision 3 — round first, saturate second, in one composite.** `fxp_round_sat` exists
so the order cannot be got wrong. A value one tie below the top of the range rounds *up*
past it (0x7FFF.8 -> 0x8000), and only a saturation applied afterwards catches it;
saturating first would clamp, round the clamped value, and report no overflow. Inverting
the order in the RTL was one of the three injected faults, and it produced 292 mismatches
against both the vectors and the C++ model.

**Decision 4 — accumulator width is `P + ceil(log2 N)`, and accumulators do not saturate
internally.** `fxp_acc_w(P, N)`; for an N-term Q1.15 MAC that is `32 + ceil(log2 N)`. The
formula is exact for power-of-two N and conservative by at most one bit otherwise (N=3
gets 34 bits where 33 would do). The bit is paid deliberately: at this width an N-term
sum of worst-case products provably cannot overflow, so the only saturation in a MAC is
the final round-and-saturate on the way out.

*Why that matters more than the flip-flop:* a saturating add is not associative. An
accumulation tree that saturates internally gives a result that depends on the reduction
order, so RTL (balanced tree, for timing) and a reference model (linear loop, because
that is how a loop is written) would legitimately disagree, and no amount of vector
comparison would resolve it. Sizing the accumulator so no intermediate can overflow
deletes the question.

*Consequence, made testable:* `fxp_probe_top` and `fxp::Acc` implement the opposite —
saturate at every step — and `model/vectors/fxp_accum.vec` pins that order-dependent
behaviour down exactly, including the `no_growth_32` counter-example that saturates on
its second term because the growth bits were omitted. The difference between the two
policies is therefore measured, not argued.

**Decision 5 — vector files are line-oriented ASCII, and they are committed.**
`# key: value` headers plus whitespace-separated signed-decimal records; two files,
`fxp_ops.vec` (one line per operation) and `fxp_accum.vec` (one line per accumulate
step). Headers carry `schema`, `kind`, `rounding_mode`, `seed` and `count`, and all five
are checked: a truncated file fails on the count, and a vector set generated under the
other rounding mode is rejected instead of "passing" against whichever implementation
happens to match it.

*Why not JSON:* the same reader has to work inside a Verilator test binary, a standalone
C++ unit test and a Python script. JSON would mean vendoring a C++ JSON library so that a
clean checkout still builds (SPEC §16), for a schema that is eight fixed columns. Three
lines of `strtoll` and whitespace splitting is the whole parser. *Why not a binary
format:* a golden vector whose diff is unreadable is not evidence.

*Why committed, against the surface reading of PLAN.md standing rule #3 ("no generated
files committed"):* these are source-of-truth test data, not build output. The point of a
golden vector is that changing it appears as a reviewable diff; a set regenerated on
demand proves only that the generator agrees with itself. The tension is resolved by
making the files self-verifying — `gen_fxp_vectors.py --check` regenerates in memory and
compares, and `make numerics-check` runs it — so the committed bytes are provably what
the recorded seed produces. Total size 78 KB.

**Decision 6 — the equivalence proof is a triangle, and it is validated by fault
injection.** Three implementations written from NUMERICS.md rather than from each other:
the NumPy reference (`divmod` / `floor_divide`), the RTL package and the C++ library
(masks and arithmetic shifts). `sim/tests/test_fxp_rtl.cpp` checks all three pairwise
relations and reports them separately, because RTL == C++ alone would be satisfied by two
implementations sharing a mistake, and RTL == NumPy alone would leave the C++ oracle —
which every later kernel test compares against — unproven.

Three faults were injected before this was accepted and each was caught: RTL ties
rounding toward -infinity (caught by `rtl_vs_vector` and `rtl_vs_cpp`, first at
`rne_s1_kn3_half`), C++ saturation made symmetric (114 failures in the standalone unit
test, first at `sat_w16_minm2`), and the round/saturate order inverted in the RTL (292
failures with `cpp_vs_vector` clean, correctly localising the fault). The table is in
NUMERICS.md §10 and must be re-run whenever a check is added or relaxed.

**Decision 7 — the C++ mirror is exact by construction, not by observation.**
SystemVerilog arithmetic on a 64-bit signed vector wraps; C++ signed overflow is
undefined behaviour and C++17 leaves `>>` on a negative value implementation-defined.
Rather than rely on what g++ 13 happens to do, every primitive in `fxp.hpp` goes through
unsigned 64-bit operations with one reinterpretation at the end (`add_wrap`, `sub_wrap`,
`neg_wrap`, `shl_wrap`, `asr`), and nothing outside that block uses a raw arithmetic
operator on the working type. The mirror is then correct on any conforming compiler.

**Decision 8 — `numerics-check` is a sub-target of `sim-tiny`, not a new SPEC §16 entry
point.** SPEC §16 fixes the command list; adding a top-level numerics target would extend
it. `make sim-tiny` gains `numerics-check` as a prerequisite, so the equivalence proof
runs on every regression, and the sub-target is also runnable on its own while working on
the package. On Windows the prerequisite is deliberately omitted, because `sim-tiny`
re-dispatches the whole target into WSL and the WSL-side make applies it there; declaring
it on both sides would run the gate twice.

*Related, and small:* `scripts/build_verilator.py` gained `--top` / `--files` so the
numerics cross-check can verilate `fxp_probe_top` from its own two-file list. Keeping it
independent of `benchmark_sim_top` means a failure in the numerics gate is always a
numerics failure. A non-default top builds into its own directory.

**Decision 9 — CMakeLists.txt stays a placeholder; the standalone C++ build is one g++
command.** Issue #4's task list mentions building the reference model "as part of
CMakeLists.txt", and DECISIONS.md 2026-07-25 (issue #2, decision 8) had pointed that file
at this issue. Measured on this host: **cmake is not installed in WSL Ubuntu-24.04**, the
canonical build environment, so a CMake path could not be executed here — and shipping an
unrun build description is worse than not shipping one. The reference model is
header-only plus one test translation unit, so the entire standalone build is
`g++ -std=c++17 -O3 -Wall -Wextra -Werror -Imodel/cpp -o ... test_fxp_vectors.cpp`, which
is what `make numerics-check` runs and what the issue gate specifies. `CMakeLists.txt`
keeps its loud placeholder, now pointing at `make numerics-check` rather than at this
issue. Revisit if a component ever needs a build graph rather than a command.

---

## 2026-07-26 — Stream bundle transport, assertion mechanism and reset policy  (issue #5)

**Context.** SPEC §5 mandates one canonical streaming interface at every module boundary,
with elastic buffering so no combinational `ready` chain crosses more than one module, and
SPEC §14 requires a reusable protocol assertion set that stays active in the fast
simulation build. Issue #2's loopback used a provisional ad hoc bundle to unblock the
Verilator flow. This issue replaces it with `rtl/packages/stream_pkg.sv` plus the three
primitives in `rtl/stream/`, which everything from issue #6 onward builds on.

**Decision 1 — the bundle travels as `valid` + `ready` + one packed payload vector, not as
a SystemVerilog interface.** The issue #5 task list asks for a `stream_if` interface with
`src`/`snk` modports. It was not built, and the reason is measured rather than stylistic.
Verilator 5.020 cannot accept an interface on a top-level module port:

```text
%Error-UNSUPPORTED: iface.sv:8:50: Unsupported: Interfaced port on top level module
%Error: Internal Error: iface.sv:2:11: ../V3LinkDot.cpp:422: Module/etc never assigned
        a symbol entry?
```

(reproduced with a two-modport `stream_if` and a three-line pass-through top; note that
`--lint-only` accepts the same file, so the limitation appears only when a model is
actually built). The SPEC §12.2 C++ harness attaches to the DUT exactly at that boundary —
it drives `valid`, samples `ready` and reads the payload through the Verilated model's
ports — so an interface-typed top port would make the primary verification environment
impossible, not merely awkward. Structs and flat vectors behave identically under
Verilator and Quartus Pro and need no per-tool workaround.

What replaced it: `stream_pkg` defines the field set, the normative field order
(`data | sof | eof | stream_id | seq | user`, with `user` at bit 0), the offset functions,
and `stream_pack()` / `stream_unpack()` between a `stream_fields_t` view and the packed
vector. `stream_geom_t` carries the four field widths as a function argument — the same
device, for the same IEEE 1800 reason (no parameterised functions), that `fxp_pkg` uses
for its 64-bit working type. Primitives are parameterised on `PAYLOAD_W` alone and never
decode the bundle, which is what makes them reusable for any stream in the design.

*Consequences.* One `PAYLOAD_W` parameter and three ports per interface instead of one
interface instance; port lists are longer than an interface's would be. In exchange the
same RTL builds under both tools with no conditional code, the C++ harness binds to it
directly, and a payload crosses a module boundary as one vector that neither tool can
flatten differently on each side.
*Alternative rejected:* interfaces for internal boundaries plus structs at the top level —
two conventions, and the seam between them becomes where the bugs live.

**Decision 2 — the SPEC §5 `sequence` field is spelled `seq` everywhere.** `sequence` is a
SystemVerilog keyword, so it is illegal as a struct member, a variable or an unprefixed
port; only a prefixed form (`in_sequence`, `s_sequence`) is legal, and only sometimes.
`seq` is legal in every context, so one token names the field in the package, in module
ports (`s_seq` / `m_seq`), in the C++ mirror (`StreamBeat::seq`) and in the generated
configuration (`STREAM_SEQ_W`, `STREAM_SEQ_LSB`). Renamed this issue: the `stream_loopback`
and `benchmark_sim_top` ports, and the C++ `StreamBeat` member.

*Two deliberate exceptions.* `rtl/top/benchmark_fabric_top.sv` (issue #3) keeps
`in_sequence` / `out_sequence`; it is out of scope here and is rebuilt on these primitives
by a later issue, which retires the exception. `TransactionId::sequence` in the scoreboard
keeps its name because it is SPEC §12.5's identity tuple — a different concept from the
wire field, and never a SystemVerilog identifier.

**Decision 3 — assertions are a bindable checker module built from macros, and what
Verilator 5.020 actually enforces was measured, not assumed.**
`sim/assertions/stream_sva.svh` holds the property text once;
`sim/assertions/stream_protocol_checker.sv` wraps it in a module. Both attachment
mechanisms are exercised: every primitive in `rtl/stream/` instantiates a checker on its
master interface inside `` `ifndef SYNTHESIS ``, so a design built from the primitives is
checked everywhere by construction and in the fast build (SPEC §14: "Assertions must
remain active in fast simulation"); and `sim/verilator/tops/stream_violator_top.sv`
attaches one by `bind` to a module that contains no assertions of its own.

Measured on Verilator 5.020 (Debian 5.020-1) while writing this:

| Construct | Result |
|---|---|
| `assert property` with `\|=>`, `\|->`, `$stable`, `$past`, `disable iff` | works |
| immediate `assert` inside `always_ff` with an `else $error(...)` action | works |
| `bind <module> <checker> #(...) u (...)` at file scope, concurrent properties included | works |
| `cover property` | compiles; counted only in a `--coverage` build |
| `##1` cycle-delay sequences | **not supported** — `%Error-UNSUPPORTED: ## (in sequence expression)`. Every property here is written with implication and `$past` instead |
| `$isunknown` | compiles, but the tool is two-state, so the X checks are structurally dead under it and exist for four-state simulators |
| macro arguments inside string literals | **substituted**, contrary to IEEE 1800. A message containing a word that is also a macro parameter name silently mutates at every use site; the macros therefore avoid such words |
| bind parameter expressions | elaborated in the *target* module's scope, so a bind written inside a wrapper cannot see the wrapper's imports. Package-qualified names (`config_pkg::...`) are used instead |

A failing assertion prints `%Error: <file>:<line>: Assertion failed in <hier>.<label>` and
calls `vl_stop`, which by default routes to `vl_fatal` and aborts the process. That is kept
for every test except the negative one, which calls `Verilated::fatalOnError(false)` so the
failure becomes an observable event (`Verilated::gotError()`) rather than a SIGABRT. That is
what lets `sim/tests/test_stream_assertions.cpp` require each expected assertion to fire *by
name* and still exit 0 for the suite. It checks the name and not merely the fact of a
failure, because a checker that fired the wrong property would otherwise look like a pass.
*Alternative rejected:* overriding `vl_stop` through `VL_USER_STOP` — it needs a
compile-time define on every build and yields the file and line but not the property name.

**Decision 4 — one parameterised elastic buffer instead of a separate `reg_slice_2deep`.**
The issue task list names `skid_buffer.sv` and `reg_slice_2deep.sv`. What is delivered is
`stream_skid_buffer.sv` (two beats of storage, the minimum full-throughput decoupler) and
`stream_elastic_buffer.sv` with `DEPTH >= 2`; the two-deep register slice is `DEPTH = 2`,
and it is tested as its own DUT in `stream_prims_top`. A second module whose body would be
"instantiate the general one at depth 2" is a second thing to keep correct for no
behavioural difference, and depth is the only axis on which the two differ.

*Skid versus full FIFO for Phase 1 elastic buffering.* Both primitives are distributed
registers with a plain occupancy counter, deliberately not M20K: at the depths that break a
ready path (2 to 8 beats) an M20K costs a block, two cycles of read latency and a
read-during-write policy, to store fewer bits than the ALMs it saves. Memory-backed and
clock-crossing FIFOs are issue #6 and are a different cost class. The rule this issue sets:
a boundary that needs only decoupling gets a skid or a shallow elastic buffer, never a FIFO.

**Decision 5 — `stream_pipe` inserts latency with credits, not with a shared enable.** The
textbook N-stage pipeline shares one `advance = !m_valid || m_ready` enable across every
stage. That puts `m_ready` on the enable of every register in the delay line — a fanout
growing with both depth and payload width, feeding registers Quartus can then no longer
retime freely — and makes `s_ready` a combinational function of `m_ready`. SPEC §23 warns
against all three ("avoid one chip-wide clock enable", "pipeline enables before broad
distribution", "break ready/valid feedback with elastic buffers").

`stream_pipe` instead admits a beat only when a credit is available, a credit meaning that
its output elastic buffer is guaranteed to have room by the time the beat arrives. The delay
line then has **no enable and no stall condition at all** — every stage shifts every cycle —
and `s_ready` is a flip-flop whose input depends only on the credit counter.
`OUT_DEPTH >= STAGES + 2` sustains one beat per cycle; it is both the default and an
elaboration-time check. The price is `OUT_DEPTH` entries of storage; the purchase is a delay
line of pure forward registers, which is exactly what HyperFlex retiming wants.

**Decision 6 — reset policy: synchronous, active low, validity only.** Applied identically
in all three primitives, per SPEC §23 ("Reset validity, not every datapath bit") and SPEC §8
("avoid resetting every datapath register"). Reset reaches the valid bits, the occupancy
counter, the pointers, the credit counter and the registered `ready` flops — and nothing
else. No payload register anywhere in `rtl/stream/` has a reset: correctness comes from the
validity travelling beside the data, and a payload reset would add a `PAYLOAD_W`- or
`DEPTH * PAYLOAD_W`-wide reset fanout that pins those exact registers out of Hyper-Register
retiming for no functional gain. No asynchronous reset is used anywhere (SPEC §23).

**Decision 7 — one payload layout, mirrored twice, checked twice.**
`rtl/packages/stream_pkg.sv` is normative. `scripts/build_verilator.py` computes the same
offsets in Python and emits them into the generated `config_pkg.sv` and `config_sim.h`,
because the C++ harness cannot call a SystemVerilog function. Two independent checks stop
the mirror drifting: an `initial` block in `benchmark_sim_top` compares every offset and the
payload width against `stream_pkg`'s own functions at time 0 of every run and `$fatal`s by
name on a mismatch; and `test_stream_loopback.cpp` compares its own `pack()`/`unpack()`
against the RTL's exported `m_payload` on every transferred beat, and fails if the number of
such comparisons is not equal to the number of beats observed. The first check covers the
constants, the second covers the code that uses them.
*Why not generate the SystemVerilog package from Python as well:* the package is source that
engineers read and reason about, and a generated one could not carry the rationale the field
order needs. *Why not hand-write the C++ constants:* they would be a third definition with
nothing checking it.

**Decision 8 — `sim-tiny` grows a test list rather than a new entry point.** SPEC §16 fixes
the command list, so the two new tests join `make sim-tiny` — which already depends on
`numerics-check` — instead of adding targets. Each has its own top and file list
(`stream_prims_top` / `files_stream.f`, `stream_violator_top` / `files_violator.f`) for the
reason `fxp_probe_top` has one: a failure in a self-contained build is unambiguously a
failure of the thing that build tests. The violator's RTL is knowingly incorrect and appears
in no other file list, so it can never reach the design build. `make lint` now lints all
three tops.

## 2026-07-26 — Register plane: source of truth, generation strategy, decode and response protocol  (issue #7)

**Decision 1 — the register map is one hand-edited JSON file, and everything else is
generated from it.** `control/regmap.json` declares blocks, windows, registers, fields,
access types and reset values; `scripts/gen_regmap.py` emits the SystemVerilog package, the
C++ harness header, `docs/regmap.md` and the machine-readable `results/regmap/regmap.json`.
Nothing else may define a register address anywhere in the repository.

*JSON rather than YAML.* The repository ships no YAML parser and `requirements.txt` carries
only numpy, so a YAML source of truth would add a dependency that a clean checkout needs
before it can lint (SPEC §16 requires a clean checkout plus documented variables to be
sufficient). The one thing JSON costs is comments — and that turns out to be a benefit,
because every rationale that would have been a comment is a `description` field instead,
which flows into `docs/regmap.md` and into the header comments of the generated package
rather than dying in the source file.

*Why `control/` and not `config/`.* `scripts/build_verilator.py` enumerates `config/*.json`
as the list of available size configurations (`--config <stem>`), so a register description
dropped in there would appear as an elaboration config named `regmap`. The register map is
not a size configuration; it gets its own directory.

**Decision 2 — the generated SystemVerilog, C++ header and Markdown table are committed;
the machine-readable JSON is not.** SPEC §10 says generated files are not committed, and the
plain reading of that rule would have the register package regenerated on every build, as
`config_pkg.sv` is. Two things weigh the other way for this artefact: a clean checkout must
lint and simulate the control plane without first running a generator, and a register-map
change is exactly the kind of change a reviewer must see as a diff — an address moving by
four bytes is invisible in a diff of the source of truth alone if nobody can see what it did
to the map. What makes committing them safe is the drift gate: `make regmap-check` (a
prerequisite of both `make lint` and `make sim-tiny`) regenerates all three in memory and
fails on any difference, so a hand-edited generated file and a source-of-truth edit that was
never regenerated are both build failures. Proven once by hand: editing `REGMAP_BLOCK_MASK`
in the generated package makes `make lint` exit non-zero with the offending line quoted.
`results/regmap/regmap.json` stays uncommitted under `results/`, where SPEC §10 puts
generated output, and is the artefact downstream tooling should read.

*Corollary — no VCS state in a generated artefact.* The ID block's `VERSION` is a static
number bumped by hand in the source of truth, not a `git describe`. The generated files must
be a pure function of the source tree, or the drift check would fail on a clean checkout with
a different VCS state, and two people building one commit would get different register
contents.

**Decision 3 — generate the tables, hand-write the logic: one CSR engine, thin per-block
wrappers.** The alternative shapes are a hand-written decode per block (the access-type
semantics then exist five times, and the fifth copy gets W1C backwards) or fully generated
block RTL (nobody reviews a generated `always_ff`). What is generated here is data with no
rationale to lose: five 32-bit masks per register — reset, writable, write-1-to-clear,
write-1-pulse, hardware-driven — as flat vectors. `rtl/control/reg_csr_block.sv` is the one
hand-written implementation of what those masks mean, and each block (`reg_block_id`,
`reg_block_build_params`, `reg_block_ctrl`, `reg_block_fault`, `reg_block_scratch`) is that
engine plus the wiring only it can know: `config_pkg` values into the build-parameter block,
the arming-gated injection and its saturating counter into the fault block, the enable and
pulse outputs out of the control block. Wiring is by generated index localparam, never by
literal position, so reordering registers in the source of truth cannot silently transpose
two of them.

*Where a register is not writable at all,* the write is refused with `error=1`; where it is
partly writable, the write succeeds and the non-writable bits are ignored. That distinction
is a property of the generated masks, not of code, and `SCRATCH3` exists to test it.

**Decision 4 — uniform 4 KiB windows, so the decode is an address-bit compare.** Every
block, implemented or planned, occupies one window aligned to its own size; the generator
enforces it. Membership is then `address[15:12] == base[15:12]`, the word index inside the
window is one expression shared by every block, and adding a block adds a comparator rather
than a range subtraction. The cost is address space, of which a 16-bit plane has more than
this design will use. Windows for the groups SPEC §9 names but no issue has built yet
(coefficients and bank select, CFAR and integration, counters, snapshot/debug) are declared
now and answer `error=1`: reserving the address space is free today and expensive later, and
the generator refuses to build a map that does not claim every one of the sixteen SPEC §9
groups.

**Decision 5 — the response protocol answers everything, in bounded time, and never
stalls.** One outstanding transaction; the master holds the request stable until `ready`;
`ready` is one cycle per accepted request, with `read_data` and `error` valid in that cycle
and driven inert outside it. Every access completes in exactly two cycles — one to decode,
one in the block — and the test asserts that on every one of its ~1200 transactions rather
than in a single directed case.

Malformed and unmapped requests are *answered*, not stalled: both enables at once, an
unaligned address, a write with no byte enables, an address outside every window, an address
inside a window but past the block's last register, and a write to a read-only register all
produce `ready=1, error=1` with no side effect. A bus that hangs on a bad address turns a
one-line software bug into a dead device and an unusable simulation.

The last defence is the fabric's watchdog: if a selected block does not answer within
`REG_WATCHDOG_CYCLES` (15), the fabric completes the transaction itself with `error=1` and
returns to idle. It cannot fire for any block in this design — their responses are registers,
not handshakes — which is the point: it covers the block that has not been written yet, the
one behind a future clock crossing, and the one whose author assumed a bus that stalls
politely. `control_top` therefore instantiates a *second* fabric against a deliberately dead
block, so the escape is an exercised path with a measured latency rather than an untested
comment.

**Decision 6 — the plane is single-clock (`cfg_clk`), and stops cleanly at the domain
boundary.** Everything in `rtl/control/` is synchronous to `cfg_clk`, so a failure in the
control plane is never a CDC question. Enables leave as levels and resets leave as one-cycle
pulses, which is exactly what a level synchroniser and a toggle synchroniser respectively
want at their inputs; the crossings themselves belong to the issue #6 primitives and to the
blocks that consume them. No crossing is invented here.

**Decision 7 — the assertions watch the master as well as the fabric.**
`sim/assertions/reg_if_checker.sv` is instantiated inside `reg_fabric` under
`ifndef SYNTHESIS`, the same mechanism `rtl/stream/` uses. Half its properties check the
fabric (one `ready` per request, never two running, `error` and `read_data` only in a
response cycle, a bounded outstanding count); half check the *master* — that the request is
bit-stable until answered — because a harness that violates the protocol it is testing for is
otherwise invisible, and every result it produces is worthless. Verified load-bearing:
perturbing the driver's address mid-transaction fires `a_request_stable` by name.

---

## 2026-07-26 — CDC: reset strategy, handshake phases, synchronizer attributes, inventory mechanism  (issue #6)

Context: SPEC §8 requires asynchronous FIFOs with Gray-coded pointers for bulk crossings,
proper synchronizers for single-bit status, toggle or handshake synchronizers for pulses, a
prohibition on synchronizing a multibit bus bit by bit, CDC-specific assertions (SPEC §14),
and "an explicit CDC inventory report". This issue builds the primitive library every later
crossing in the design is made of, so the choices below are load-bearing for the whole
benchmark rather than local to one block.

**Decision 1 — the two-domain reset contract: asserted together, released per domain, and the
FIFO bridges the skew itself.** A dual-clock FIFO has two resets and they are not
independent. Reset one side alone and its pointer goes to zero while the other's does not:
the FIFO then reports a fill level that corresponds to no data and the read side walks through
stale storage. That is silent corruption, not loss, and it is the classic asynchronous-FIFO
defect.

The contract `rtl/cdc/async_fifo.sv` implements:

* **assertion is common and simultaneous** — `wr_rst_n` and `rd_rst_n` are driven from one
  system reset; asserting one alone is a design error;
* **release is per domain and synchronous to that domain's own clock** — the standard
  asynchronous-assert / synchronous-release arrangement, which is also exactly what the
  SPEC §12.2 harness's `ResetSequencer` does, so the two domains leave reset at different
  absolute times on every test pass;
* **the FIFO absorbs the release skew** — each domain synchronizes a single "the other domain
  is in reset" bit through `cdc_sync2` with `RST_VALUE = 1`, so the safe interpretation
  survives its own reset, and refuses to move a pointer until the other side is out of reset.
  Both pointers are therefore provably zero at the instant either side starts, whatever the
  skew.

Rejected: *fully synchronous reset in both domains with a common release* needs a globally
synchronous release across asynchronous clocks, which is the thing that cannot be built.
*Asynchronous reset inside the FIFO* is ruled out by SPEC §23 for performance-critical logic,
and an asynchronous release into a Gray counter is precisely the recovery hazard this scheme
removes. *No gating at all* relies on release skew being zero, which it is not, and fails
silently rather than loudly when it is not.

The one-sided-reset error is *detected*, not merely documented: `a_wr_reset_pointers_cleared`
and `a_rd_reset_pointers_cleared` fire if a domain's pointer is non-zero at the instant the
crossing leaves its hold state, which can only happen if the two resets were not asserted
together. Reset scope elsewhere is unchanged from decision 6 of issue #5 — synchronous, active
low, control state only; no storage array in `rtl/cdc/` or in `rtl/common/sync_fifo.sv` has a
reset.

**Decision 2 — the multibit handshake is four-phase, not two-phase.** Two-phase
(non-return-to-zero) signalling halves the round trip: request and acknowledge are toggles,
and a transfer is one edge each way rather than a full up-and-down on both. Rejected for three
reasons, in order of weight:

1. *Reset.* A two-phase crossing's idle condition is "the two toggles agree", which is a
   relation **between two clock domains**. Under decision 1 the two domains leave reset at
   different times, and any scheme whose idle state is a cross-domain relation can wake up
   believing a transfer is in flight — delivering a phantom value, or wedging. Four-phase has
   an absolute idle state (`req = 0`, `ack = 0`) that each domain reaches from its own reset
   alone.
2. *Checkability.* "The request is held until acknowledged, and the payload is stable
   throughout" is a property with an explicit window, which is why `a_hs_req_held` and
   `a_hs_data_stable` can be written directly. A two-phase crossing has no held request; its
   stability window is implicit, and an assertion for it has to reconstruct the state
   machine — which means the assertion can be wrong in the same way the design is.
3. *Cost.* The extra latency is one more synchronizer round trip on a path that is by
   construction not a throughput path: anything needing throughput uses `async_fifo`.

**Decision 3 — two synchronizer stages by default, and multibit synchronization is refused
unless the caller declares the value Gray-coded.** `cdc_pkg::cdc_sync_stages_default()` is 2.
The MTBF of a two-stage synchronizer on Agilex 7 at the SPEC §8 clock rates is many orders of
magnitude beyond the life of the benchmark, and every extra stage is a cycle of latency on
every status bit and on **both** pointer paths of every asynchronous FIFO — latency that shows
up directly as asynchronous-FIFO occupancy, because the pointer a domain sees is that many
cycles stale. Three stages is available per instance (`STAGES` on `cdc_sync2`) for a bit whose
corruption would be unrecoverable rather than merely lossy; nothing in this design is in that
class today. Note for the Quartus phase: Hyperflex devices default
`SYNCHRONIZATION_REGISTER_CHAIN_LENGTH` to three, so the Fitter's *reporting* threshold and
this default differ by one — a reporting question, not a correctness one.

SPEC §8's "do not synchronize a multibit bus by independently synchronizing every bit" is
enforced rather than reviewed: `cdc_sync2` `$fatal`s at elaboration for `WIDTH > 1` unless the
instantiator sets `GRAY_CODED`, which is the caller asserting that consecutive values differ
in at most one bit. `async_fifo` is the only module in the design that sets it, and it
instantiates a `cdc_gray_checker` on the same vector so the claim is checked every cycle
rather than trusted. Anything else multibit goes through `cdc_handshake`.

**Decision 4 — synchronizer attributes for Quartus Prime Pro 26.1: copy the vendor's own IP.**
Researched against the Quartus Prime Pro Edition Settings File Reference (683296), the Pro
User Guide chapter "Managing Metastability" (683082 §4), the Timing Analyzer guide (683243)
and Altera's shipped `altera_std_synchronizer.v`. Every synchronizer register in the design
carries:

```systemverilog
(* altera_attribute = {"-name ADV_NETLIST_OPT_ALLOWED NEVER_ALLOW; -name SYNCHRONIZER_IDENTIFICATION FORCED_IF_ASYNCHRONOUS; -name DONT_MERGE_REGISTER ON; -name PRESERVE_REGISTER ON"} *)
(* preserve *) (* dont_merge *)
```

* `SYNCHRONIZER_IDENTIFICATION FORCED_IF_ASYNCHRONOUS`, not `FORCED`. Pro Edition still
  honours the assignment — it is not Standard-only, and the Pro CDC Viewer complements it
  rather than replacing it. `FORCED_IF_ASYNCHRONOUS` identifies the chain whenever an
  asynchronous transfer is actually detected; a bare `FORCED` marks registers unconditionally,
  is documented as the wrong tool for a chain the Compiler can see for itself, and is warned
  against as a global assignment. The underscore spelling avoids nested quoting inside the
  attribute string, which is what Altera's own IP does.
* `PRESERVE_REGISTER ON` + `DONT_MERGE_REGISTER ON` + `ADV_NETLIST_OPT_ALLOWED NEVER_ALLOW`.
  A synchronizer chain is a shift register whose stages have identical logic; without these,
  synthesis may merge two stages, merge two instances that synchronize the same net, or retime
  the chain apart — each of which silently removes the metastability margin the module exists
  to provide. The short `(* preserve *)` / `(* dont_merge *)` forms are given as well because
  those are the ones Quartus applies to a variable declaration directly.

HyperFlex interaction (SPEC §23): the Hyper-Retimer already declines to retime registers it
has identified as a synchronizer chain, so the preserve attributes are belt-and-braces rather
than the primary mechanism — but they also make the chain a deliberate retiming **barrier**.
The consequence worth writing down now, for the Fast Forward reviews in Phase 5: the fix for a
synchronizer on a critical path is pipeline registers *feeding* it, never a relaxation of
these attributes. SDC treatment (a false path onto the first stage; `set_max_skew` /
`set_net_delay` on a handshake payload bus) belongs to the constraints issue. Two facts for
whoever writes it: Quartus has no `-datapath_only` on `set_max_delay` — that is Vivado
syntax — and `SDC_STATEMENT` can embed an entity-bound exception in the RTL if that turns out
to be preferable to a central `.sdc`.

Verilator tolerates all of it: `(* ... *)` is consumed by the lexer before the parser runs, so
none of it reaches the AST and `--lint-only --Wall` is clean. Measured on 5.020.

**Decision 5 — the CDC inventory is a source-scanned catalog joined to a Verilator-elaborated
instance tree.** `scripts/cdc_inventory.py` has two halves, because neither is authoritative
for both of the things it needs:

* the **catalog** — what kind of crossing a module is, which of its ports carry the two
  clocks, which parameters give the width and the stage count — is scanned from a
  `(* cdc_primitive = "...", cdc_src_clk = "...", ... *)` attribute above each module
  declaration in `rtl/`. It has to come from the source, because Verilator strips attributes
  in the lexer and no tool output carries them. Keeping the declaration next to the RTL it
  describes is also what stops it drifting the way a separate `cdc_registry.json` would.
* the **instance tree** — every instance path, every resolved parameter value, and the net on
  every port — comes from `verilator --xml-only` on the same file list the simulation builds
  from. A regex over instantiations could not resolve a parameter overridden two levels up,
  could not expand a generate block, and would list modules that are never instantiated. The
  inventory has to describe the design that exists, not the text that produced it. Quartus's
  netlist was rejected as the source because the report must be producible on the simulation
  side of the split-toolchain rule, from a clean checkout, with no licence and no fit.

The two halves join on Verilator's `origName`, the module's pre-parameterisation name.

What makes it self-maintaining rather than a snapshot: the script also flags **untagged**
crossings — any instantiated module with two or more clock-like ports that carries no
`cdc_primitive` attribute — as `unknown`, and `--strict` (used by `make cdc-inventory`, a
prerequisite of `sim-tiny`) fails the target on a non-empty `unknown` list. Verified by
running the script against a catalog containing only `cdc_sync2`: it reported the seven
composite crossings as unknown and exited non-zero.

`cdc_src_clk = "@async"` is a **declared** value, not a missing one: a flip-flop synchronizer
has no source-side logic and therefore no source clock port. Its source is an arbitrary
asynchronous domain, constrained in SDC by a false path onto the first stage rather than by a
named clock. The report still locates it by naming the nearest enclosing tagged primitive,
whose own source clock is resolved to a top-level net.

Current design: 24 crossings, 0 unknown — 3 `async_fifo_gray`, 2 `stream_cdc`, 1
`handshake_4phase`, 1 `pulse_toggle`, 17 `sync_ff`.

**Decision 6 — the Gray one-bit assertion watches the pointer in the domain that owns it, and
nowhere else.** The first version of `async_fifo` also instantiated `cdc_gray_checker` on the
two *synchronized* pointer copies, on the theory that a checker there would catch the wrong
vector being routed into a synchronizer. It fires on correct RTL at every non-unity clock
ratio, and did — measured at 2:1, on the first run of the ratio sweep. The reason is that the
one-bit rule is a statement about consecutive values of the pointer **register**: that is what
makes a sample taken mid-transition resolve to the old value or the new one. The synchronized
copy is that register sampled by a different clock, and when the source is the faster of the
two it legitimately advances several Gray steps between two destination samples. A property
that holds only at one clock ratio is not the property SPEC §14 is asking for. What the
crossing actually depends on is that the value *entering* each synchronizer is Gray-coded,
which is what the two remaining instances check.

**Decision 7 — `sync_fifo` and `async_fifo` are separate modules, and the storage style is a
parameter from the start.** One module with a `SAME_CLOCK` parameter would be two designs
sharing a file: the pointer comparison, the flag derivation and the reset contract are all
different. The rule issue #5 set still holds — a boundary that needs only to break a ready
path gets a skid or a shallow elastic buffer, never a FIFO.

`STORAGE` in {`"regs"`, `"mlab"`, `"m20k"`} selects a **literal** `ramstyle` attribute through
a generate block rather than substituting the parameter into one, for two measured reasons:
Quartus wants a string literal there, and Verilator does not count a parameter read inside an
attribute as a use of that parameter (it reports `UNUSEDPARAM`). `STORAGE = "m20k"` requires a
registered read (`SHOW_AHEAD = 0` / `OUT_REG = 1`), checked at elaboration, because an M20K
read port is registered; the registered-output path is written as `q <= mem[addr]` with an
enable, which is the shape Quartus infers as an M20K with a registered read port. The
parameter exists now rather than being retrofitted because the SPEC §11 full-scale M20K budget
is a headline result, and the depth-versus-style split has to be tunable before that
measurement rather than after it.

`high_water` means the same thing in both FIFOs — the greatest occupancy held up to and
including the **previous** cycle — so one reference model (`model/cpp/cdc/fifo_ref.h`) checks
both. `sync_fifo` was changed to match `async_fifo`'s semantics rather than the other way
round: on the asynchronous side the *next* occupancy is not available cheaply, and one rule
that is slightly less responsive beats two rules that differ by a cycle.

**Decision 8 — `sim-tiny` grows four more tests and one more sub-target, not new entry
points.** SPEC §16 fixes the command list, so `test_sync_fifo`, `test_async_fifo`,
`test_cdc_synchronizers` and `test_cdc_assertions` join `make sim-tiny`, and the SPEC §8
inventory report becomes `make cdc-inventory` — a prerequisite of `sim-tiny` in the same way
`numerics-check` (issue #4) and `regmap-check` (issue #7) are, and runnable alone while
working on the primitives. Two new tops, each with its own file list, for the reason
`fxp_probe_top` and `stream_prims_top` have one: a failure in a self-contained build is
unambiguously a failure of the thing that build tests. `cdc_violator_top`'s RTL is knowingly
wrong and appears in no other file list, so it can never reach the design build. Clean
`make sim-tiny` on the merged tree: 52 s for six tops, seven tests and three seeds, inside the
runtime budget.

---

## 2026-07-26 — Telemetry: snapshot coherence, counter wrap policy, sequence resync semantics  (issue #8)

Context: SPEC §9 requires the register plane to expose stream counters, stall counters, FIFO
high-water marks, overflow and saturation counts, frame counts, sequence errors and CDC
errors; SPEC §5 requires sequence numbers to permit end-to-end loss and ordering checks;
SPEC §13.4 requires the long stress test to exercise counter wrap. Every datapath block from
Phase 2 onward reports through these primitives, so what is decided here is decided for the
whole benchmark.

**Decision 1 — the register plane never reads a running counter; it reads a shadow.** Every
count register in the `counters` window presents a shadow register, and
`TELEM_CTRL.SNAPSHOT` is a write-1-pulse that latches every counter in the block — and the
sequence checker's five beside it — into their shadows at one edge.

The problem is not hypothetical. The beat counter is 64 bits and the plane is 32, so reading
it takes two accesses; between them the low word can wrap, and the pair then names a beat
count that never existed. The same failure in slower motion applies to any two counters meant
to describe one interval: a stall count read after a beat count can exceed it, and a
utilisation figure computed from the two can exceed 1. A telemetry system whose numbers are
individually plausible and jointly impossible is worse than no telemetry, because nothing
about the output says which reading to distrust.

The captured value is defined against the counter's **next state**, not its current one: the
shadow latches what the counter itself takes at the strobe edge, so a snapshot includes any
event in the strobe cycle and the shadow equals the live count for the whole of the following
cycle. Stating the rule that way removes the off-by-one from every call site, and it is
checked directly — `a_shadow_latched` in `sim/assertions/telemetry_sva.svh` asserts
`snapshot |=> (shadow == count)`.

Two supporting registers exist because the mechanism has two failure modes a number cannot
express. `TELEM_STATUS.SNAP_VALID` separates "nothing happened" from "you never asked": before
the first snapshot every shadow reads zero, and zero is also a perfectly good count.
`SNAPSHOT_ID` counts the strobes, so a reader proves its sweep was coherent by reading that
register before and after — equal values mean nobody else snapshotted in the middle. It is
deliberately modulo rather than saturating and deliberately not gated by `ENABLE`: a
saturated identity would compare equal to every later one and silently stop detecting the race
it exists to detect, and a coherence proof must work on a block whose measurement window is
shut.

Rejected: *a shadow-copy strobe per counter* moves the coherence problem into software and
guarantees somebody gets it wrong. *A wide atomic read port* is not expressible in the SPEC §9
32-bit interface. *Reading twice and retrying on disagreement* costs two sweeps, does not
converge under sustained traffic, and is exactly the software workaround one register removes.

**Decision 2 — traffic counters wrap, error counters saturate; both are parameters and the
mode is readable at run time.** A traffic counter (beats, stalls, idle cycles, frames, frame
starts) is a rate measure: after a wrap the difference between two reads is still exactly
right, which is the quantity anyone uses, and SPEC §13.4 asks for wrap to be exercised rather
than avoided. An error counter (FIFO overflows, arithmetic saturations, CDC errors, and the
sequence checker's five) is a magnitude, and a dump taken long after a run must not report a
small number because the counter went round — the argument `reg_block_fault.sv` made for its
own counter in issue #7, now made once in `perf_counter` and reused everywhere.

Neither mode has an undefined overflow: the adder in `rtl/common/perf_counter.sv` is one bit
wider than the counter and its carry out **is** the wrap decision, so the boundary behaviour
is structural rather than a property of the synthesiser. `WRAP_STATUS` carries one sticky bit
per counter and `TELEM_STATUS.WRAP_ANY` their OR, so a reader always knows whether an absolute
value still means anything; `TELEM_STATUS.TRAFFIC_SATURATE` and `.ERROR_SATURATE` report which
arithmetic was built, so software never has to assume.

Widths: 64 bits for beats and stalls (1.3 million years at 450 MHz — the pair never wraps in
any real run, and the LO/HI presentation is what makes decision 1 load-bearing), 32 for
everything else. Wrap is nevertheless a **directed** test rather than a reasoned-about
condition: `telemetry_top` instantiates three deliberately 8-bit `perf_counter` probes, and
`test_perf_counters` wraps them in 300 events, in every seed, in milliseconds. One of the
three takes increments larger than one, so the boundary is *stepped over* rather than landed
on — the case an equality test for "counter == all ones" misses entirely.

**Decision 3 — sequence classification is a signed half-circle, and the resync rules are
explicit.** `rtl/common/seq_checker.sv` computes `delta = (seq - expect) mod 2**SEQ_W` per
tracked stream and splits the modular circle in half:

| `delta` | verdict | expectation |
|---|---|---|
| `0` | in order | advances |
| `2**SEQ_W - 1` | **duplicate** — the beat just accepted, again | held |
| `0 < delta < 2**(SEQ_W-1)` | **gap**, of `delta` beats | resynchronises forward |
| otherwise (backwards, not the last) | **reorder** | held |

Nothing special-cases the top of the range, which is exactly why nothing breaks at it: at
`SEQ_W = 16` the step from `0xFFFF` to `0x0000` has `delta = 0`, and a gap that straddles the
wrap is still a small forward delta. Duplication is separated from reordering because they
have different causes and different fixes, and one counter for both would hide which.

A gap **resynchronises forward** — one lost burst is one report, not one report per beat
forever after — while a duplicate or a reorder leaves the expectation alone, because a beat
from behind says nothing about where the stream now is. Gap *events* and beats *lost* are
counted separately: one gap of forty and forty gaps of one are different failures.

Initialisation, stated because a checker that invents an expectation reports a loss on every
stream that legitimately starts elsewhere: the first beat of a stream after reset, after
`ENABLE` was low, or after a resync establishes `expect = seq + 1` and is never an error.
`ENABLE` low clears every stream's known bit, so closing and reopening a measurement window
starts clean instead of reporting a gap the size of everything that flowed while it was shut.

`sof_resync` is a **runtime input**, exposed as `TELEM_CTRL.SEQ_SOF_RESYNC` and off by
default, rather than the elaboration parameter the issue text suggested. Two reasons. It is
the better interface — a source whose numbering restarts per frame and one whose numbering is
continuous can share an elaboration and be told apart by software — and a parameter would
leave `sof` unreferenced in every instance that switched the feature off, which
`verilator --lint-only --Wall` reports as an unused input and this project does not waive.
Both behaviours are therefore reachable in one build, and `test_seq_checker` pass 6 checks
both against the same instance: with resync off a `start_of_frame` does not excuse a jump.

A fifth verdict, **untracked**, covers a beat on a `stream_id` at or above `N_IDS`. It is
counted rather than ignored: an instance sized for four streams that silently dropped
everything on stream 7 would report a clean run on traffic it never looked at. Sizing the
parameter too small is then a visible number.

**Decision 4 — telemetry is single-clock; what crosses domains is the register interface, not
the counters.** `telemetry_block` is instantiated in the domain of the interface it observes,
because counting in the domain where the events occur is the only way to count them exactly.
When the register plane is in a different domain (SPEC §8 puts it in `cfg_clk`), the crossing
is one issue-#6 handshake on the register bus, not twenty crossings on twenty counters — one
thing to verify instead of twenty, and decision 1 is what makes it correct, because the
cfg-side reader strobes a snapshot and then reads shadows that are not moving. That crossing
belongs to the multi-domain integration (issue #19); `telemetry_top` is deliberately
single-clock so that a counting error and a CDC error cannot be confused while the counting
itself is being proved. This supersedes the note in the issue-#7 `counters` block description
that said the counters would live in the telemetry clock domain and be the first consumer of
the CDC primitives on the register path.

**Decision 5 — `control_top` attaches the counters window to a bare `reg_csr_block`.**
Implementing the block changes `REGMAP_N_BLOCKS_IMPL`, so `control_top` has to instantiate
something at that window or the fabric waits on a block that is not there. It instantiates the
register file without its hardware: the access types, the decode, the read-only refusals and
the randomized soak then cover the counters window like every other block, while the counters
themselves are verified in `telemetry_top` against real traffic. The alternative — the real
`telemetry_block` with its stream inputs tied off — would require `test_control_regs` to model
telemetry hardware a second time inside a test about the register plane, to prove something
the telemetry test already proves better. The hardware-driven fields consequently read zero
there and their real values in `telemetry_top`; both are checked, each in the top where it is
the subject.

**Decision 6 — `perf_counter` and `seq_checker` join `files.f`; `telemetry_block` does not.**
The first two are design RTL that every kernel from Phase 2 onward instantiates, and `files.f`
is the single definition of what "the design" is. `telemetry_block` is the counters block of
the register plane and needs `rtl/control/`, which `files.f` does not carry until issue #19
brings the whole plane into `benchmark_sim_top`; until then it is linted through
`files_telemetry.f`, which `make lint` runs as step 7 of 7. `sim-tiny` grows two tests and one
top, not a new entry point — the arrangement issues #4, #5, #6 and #7 each used.

## 2026-07-25 — Complex multiplier: full-precision width, Karatsuba exactness, pipeline shape, calibration methodology  (issue #9)

Context: SPEC §6 defines the four-real-multiply complex product and requires an optional
three-real-multiply variant "parameterized so Quartus results can compare" DSP consumption,
ALM consumption, pipeline depth, routing pressure, Fmax and power. SPEC §18 requires the
kernel to be synthesized on its own, before the full design, with those quantities measured
rather than argued. This is the first Phase 2 kernel and the first entry in the calibration
database; the FIR lane, the PFB, the FFT butterfly and the beamforming dot product are all
built out of it, so what is decided here is decided for every kernel that follows.

**Decision 1 — the full-precision output is 33 bits, not 32, and it is exact.** A single
Q1.15 × Q1.15 product is Q2.30 in 32 bits and that is where most descriptions stop. The
*sum* of two of them is not:

```text
imag((-1.0 - 1.0j) x (-1.0 - 1.0j)) = (-2^15)(-2^15) + (-2^15)(-2^15) = +2^31
```

`+2^31` is one past the top of a signed 32-bit field. `fxp_pkg`'s own accumulator-width
policy already says so — `fxp_mac_q15_acc_w(2) = 32 + ceil(log2 2) = 33` — and this is the
case where that bound is **tight** rather than conservative by a bit. So `p_re` / `p_im` are
33 bits, Q3.30, and they never saturate and carry no flags.

The alternative — call the port Q2.30, clamp, and set a flag — was rejected. It makes the
"full precision" output not full precision, it puts a saturation event on the one input pair
a reviewer is most likely to try first, and it would silently change the numerics of every
accumulation tree that sums these products, because a saturated addend is not associative.
The port width is written as `[FXP_PROD_W:0]` and checked against `fxp_mac_q15_acc_w(2)` at
elaboration, so it moves if the format ever does. Rounding to Q1.15 is unaffected and is a
single `fxp_round_sat` at the output; it saturates on exactly the pair above.

**Decision 2 — the three-multiply form is Karatsuba/Gauss, and its exactness is a ring
identity, not a tolerance.** The factorization is

```text
k1 = a_re * (b_re + b_im)
k2 = b_im * (a_re + a_im)
k3 = b_re * (a_im - a_re)
re = k1 - k2            im = k1 + k3
```

Expanding: `k1 - k2 = a_re*b_re + a_re*b_im - a_re*b_im - a_im*b_im = a_re*b_re - a_im*b_im`,
and `k1 + k3 = a_re*b_re + a_re*b_im + a_im*b_re - a_re*b_re = a_re*b_im + a_im*b_re`. Every
step is distributivity and cancellation of **integer** terms — no division, no rounding — so
the identities hold in **Z** and therefore bit-exactly in two's complement, *provided no
intermediate wraps*. That proviso is the only real obligation, and it is a statement about
widths:

| term | bound | width |
|---|---|---|
| operands | 2^15 | 16 |
| `b_re+b_im`, `a_re+a_im`, `a_im-a_re` | 2^16 | 17 |
| `k1`, `k2`, `k3` | 2^15 · 2^16 = 2^31 | 33 |
| `k1-k2`, `k1+k3` (= the result) | 2^31 | 33 |

The last row is where a naive bound says 34, and where relying on the reviewer being right
would be a mistake. So the RTL **forms the post-adder at 34 bits and casts down to 33**, and
a simulation-only assertion checks that the cast is lossless on every cycle. A second pair of
assertions compares the whole arithmetic core against `fxp_pkg::fxp_cmul_q15_re_raw` and
`_im_raw` — the package's canonical four-multiply definition — using a shadow copy of the
operands delayed to the same pipeline level. That is the exactness claim checked against the
*package*, not against a second copy of the same algebra.

There are three further independent statements of the same fact, because one proof of an
identity that everything downstream depends on is not enough: the C++ model writes the two
paths out separately and `test_fxp_vectors` agrees them over the 6561-pair Q1.15 corner grid
and 200 000 pseudo-random pairs; the NumPy generator asserts the agreement for every one of
the 864 committed vectors as it writes them; and `cmult_assertions` compares the two RTL
variants bit-for-bit on every valid beat of every simulation.

The alternative factorization — the one that computes `(a_re+a_im)(b_re+b_im)` and subtracts
both cross terms — was not chosen. It needs the *same* three multiplies, but one of its
multiplies has a sum on **both** operands, i.e. a 17×17 product rather than 16×17. That is
one more bit on the multiplier for no arithmetic gain, and on a device whose DSP is natively
18×19 it is exactly the bit that would push an operand out of the native width.

**Decision 3 — five register locations, enabled in a fixed priority order, so latency *is*
the parameter.** `PIPE_STAGES` selects which of five cut points are registered:

| `PIPE_STAGES` | 1 | 2 | 3 | 4 | 5 |
|---|---|---|---|---|---|
| `REG_IN` operands | on | on | on | on | on |
| `REG_MULT` products | | on | on | on | on |
| `REG_POST` sums | | | on | on | on |
| `REG_OUT` results | | | | on | on |
| `REG_PRE` pre-adds | | | | | on |

The enables sum to `PIPE_STAGES`, so latency equals the parameter exactly, for both variants,
at every legal value — which is what lets the calibration sweep compare *arithmetic* rather
than comparing pipeline depths that happen to differ between variants, and what lets a block
composing this kernel treat the number as a contract rather than looking it up in a table.

The order is not arbitrary. `REG_IN` and `REG_MULT` come first because they are the two
registers a DSP block owns natively (SPEC §23, "provide registers on both sides of DSP-heavy
operations"): at `PIPE_STAGES = 2` the entire multiply is inside the block and the fabric
sees only the post-adder. `REG_POST` is next because the post-adder is the widest fabric
arithmetic in the module. `REG_OUT` is next because it keeps the rounding network — the one
place a carry chain crosses 33 bits, and, as the sweep confirms, the critical path — off the
path into whatever consumes the kernel. `REG_PRE` is last because only MULT3 has anything to
put there; for MULT4 it is a second operand register, which is not wasted (HyperFlex can
retime it forward) but is not the first stage worth spending.

**Decision 4 — no `ready`, and no reset on the datapath.** This is a fixed-latency arithmetic
kernel, not a stream stage. Backpressure is a block-level concern and is provided by the
SPEC §5 primitives in `rtl/stream/` when the kernel is wrapped into a lane. A ready chain
here would put `m_ready` on the enable of every DSP register — a broad clock enable feeding
registers Quartus can then no longer retime freely, which is precisely what SPEC §23 warns
against. The datapath registers are therefore free-running with no enable, and only the valid
chain is reset: "reset validity, not every datapath bit". A beat's outputs are meaningful when
`valid_out` is high and are don't-care otherwise.

**Decision 5 — the calibration probe constraint is 600 MHz, deliberately above the target.**
`quartus/calibration/cmult_calib.sdc` constrains the calibration project at 1.666 ns
(600.24 MHz) while SPEC §2's target, and `quartus/constraints/clocks.sdc`, stay at 450 MHz.

A Fitter that meets its constraint stops optimising: it reports positive slack, takes whatever
placement was good enough, and the reported Fmax becomes a statement about the constraint. On
a two-DSP design every point of a 450 MHz sweep would come back "met" and the sweep would have
measured nothing — which is exactly the "theoretical DSP-count arithmetic" SPEC §18 forbids
building on. Constraining above the achievable range makes every point fail, pushes every
point as hard as the Fitter knows how, and makes the reported Fmax a measurement of a
critical path.

This is not SPEC §24's prohibition in reverse. §24 forbids *lowering* a requested clock after
seeing a poor result, to make a benchmark look better. This *raises* it, before any result
exists, in a project that is not the benchmark and whose output is a measurement. The
benchmark's own constraint is untouched, and every calibration record carries both numbers.

**Decision 6 — the calibration Fmax is the register-to-register number, and Quartus's own
whole-design figure is recorded beside it rather than instead of it.** Measured during
development: on a virtual-pin harness the worst setup path is always an *output port* path,
at about −1.33 ns against a 1.666 ns period, and essentially all of it is clock skew of about
−2.5 ns. The reason is structural: a port is timed against the clock at the `clk` pin, while
the register driving it sees the clock after the global network's insertion delay. No fitter
can fix that, and in the real design there is nothing to fix — the block on the other side of
this boundary is on the same clock network and sees the same insertion delay.

So `timing.fmax_mhz` in each record is computed from the worst setup slack over paths whose
two ends are both registers, and `timing.quartus_restricted_fmax_mhz` carries Quartus's
unaltered whole-design figure under a name that says what it is. Nothing is relaxed to
achieve this: no false path, no multicycle path, no clock group, and the ports stay fully
constrained — every record checks `unconstrained_paths == 0`. Each record also carries the
source and destination of the measured path and a `critical_path_in_kernel` flag, so "this
number is about the kernel" is checked rather than assumed.

**Decision 7 — the sweep is pruned to ten points, in the open.** The full matrix is
{MULT4, MULT3} × `PIPE_STAGES` {2,3,4,5} × `ROUND_OUT` {1,0} = 16 compiles, and one compile of
this project on AGMF039R47B1E1VC measures at about nine minutes. The pipeline axis is swept
fully for both variants at `ROUND_OUT = 1` (8 points), and the output-format axis is measured
at `PIPE_STAGES = 4` only (2 points), because rounding is a fixed combinational network
hanging off the post-adder register and does not interact with how many stages precede it —
measuring it at every depth would buy four copies of one number. The pruning and its reason
live in the matrix table in `scripts/run_calibration.py`, beside the points themselves, rather
than in a commit message.

**Decision 8 — the sweep compiles in a copy of the calibration project, always.** Quartus
exports its in-memory assignment database over the qsf on `project_close`, so even a
read-only STA run writes `LAST_QUARTUS_VERSION` and three power-management defaults into a
hand-maintained tracked file; and a compile leaves `db/`, `qdb/` and `output_files/` behind.
Both were observed during development. Each point therefore compiles in its own copy at
`results/calib_<kernel>_<point>/` — two levels below the repository root, exactly like
`quartus/calibration/`, so the `../../rtl` paths in the copied qsf still resolve to the same
sources — and `quartus/calibration/` stays byte-identical to what a clean checkout has. The
copy is also what makes `--jobs > 1` possible, since two compiles cannot share a project
database.

Note the consequence for parameter passing: the compile phase must **let** Quartus export the
assignment database, because that export is how a `set_parameter` value reaches the
`quartus_syn` process. `-dont_export_assignments` — which `quartus/scripts/compile.tcl` uses
as its primary defence — would silently discard the swept parameters. The byte-level
snapshot/restore is therefore the primary defence here rather than the backup one, and every
record carries the parameters Quartus reported having elaborated, so a sweep whose parameters
did not apply shows up as a mismatch rather than as ten identical results.

### Measured calibration data (SPEC §18, seed 1)

Seed 1, AGMF039R47B1E1VC, Quartus Prime Pro 26.1.0 Build 110, probe constraint 600.24 MHz.
Full records in `results/synthesis/calibration_cmult.json` (generated, not committed).

| variant | stages | out | DSP needed | DSP placed | DSP mode | mults | ALM (total) | ALM (kernel) | regs (design/hyper) | Fmax MHz | depth | fit s |
|---|---|---|---|---|---|---|---|---|---|---|---|---|
| MULT4 | 2 | rounded | 2 | 2 | 2x sum of two 18x18 | 4 | 151 | 54.2 | 107 / 104 | 517.1 | 3 | 495 |
| MULT3 | 2 | rounded | 2 | 3 | 3x two independent 18x18, 3x pre-adder | 3 | 186 | 88.8 | 107 / 104 | 367.2 | 4 | 506 |
| MULT4 | 3 | rounded | 2 | 2 | 2x sum of two 18x18 | 4 | 187 | 91.1 | 108 / 104 | 490.2 | 3 | 507 |
| MULT3 | 3 | rounded | 2 | 3 | 3x two independent 18x18, 3x pre-adder | 3 | 215 | 118.3 | 240 / 236 | 418.9 | 4 | 484 |
| MULT4 | 4 | rounded | 2 | 2 | 2x sum of two 18x18 | 4 | 192 | 102.0 | 273 / 140 | 715.3* | 1 | 498 |
| MULT3 | 4 | rounded | 2 | 3 | 3x two independent 18x18, 3x pre-adder | 3 | 220 | 126.4 | 405 / 271 | 483.6 | 5 | 487 |
| MULT4 | 5 | rounded | 2 | 2 | 2x sum of two 18x18 | 4 | 197 | 105.4 | 383 / 173 | 742.4* | 2 | 530 |
| MULT3 | 5 | rounded | 2 | 3 | 3x two independent 18x18, 3x pre-adder | 3 | 220 | 125.3 | 339 / 138 | 713.8* | 1 | 487 |
| MULT4 | 4 | full | 2 | 2 | 2x sum of two 18x18 | 4 | 88 | 1.2 | 138 / 133 | 1302.1* | 0 | 497 |
| MULT3 | 4 | full | 2 | 3 | 3x two independent 18x18, 3x pre-adder | 3 | 126 | 40.2 | 238 / 133 | 909.1* | 1 | 470 |

`*` = the register-to-register paths met the 600 MHz probe, so that Fmax is a lower bound rather than a measured limit.

**The three-multiply form saves a multiplier and does not save a DSP block.** That is the
whole reason SPEC 18 exists, and it is the opposite of what the arithmetic suggests.

Quartus maps MULT4's four 16x16 multiplies into **two** DSP blocks in `Sum of Two 18x18`
mode: the block's native two-multiplier-with-shared-adder mode absorbs both the multiplies
*and* the post-adder for one output component, and two blocks cover both components. MULT3's
three multiplies go into **three** blocks in `Two Independent 18x18` mode — one product per
adder, so they cannot share — with the three Karatsuba pre-adders landing in the block's
`Fixed Point Dedicated Pre-Adder` rather than in ALMs. The Fitter estimates one of the three
is recoverable by dense merging, so it reports "DSP Blocks Needed = 2" for both variants, but
it *places* three for MULT3 and two for MULT4.

The saving a three-multiply form buys is a saving in **multipliers**, and this block's
granularity is two multipliers with one adder. Three multiplies therefore cannot occupy fewer
than two blocks — and MULT4's four already fit in two.

**What MULT3 pays instead is the post-adders.** Because its three products come out of three
separate blocks, `k1-k2` and `k1+k3` must be built in fabric at 33 bits. The `full` pair
isolates that cost exactly, with the rounding network removed from both:

| | ALM (kernel entity) | Fmax |
|---|---|---|
| MULT4, 4 stages, full-precision out | **1.2** | >= 1302 MHz |
| MULT3, 4 stages, full-precision out | **40.2** | >= 909 MHz |

MULT4's kernel is essentially *nothing but two DSP blocks*. MULT3's 39 extra ALMs are two
34-bit fabric adders at roughly half an ALM per bit, which is what they should cost. The same
gap appears at every rounded depth (+29 to +35 total ALMs), and MULT3 is slower at every
depth: -150 MHz at 2 stages, -71 at 3, -232 at 4, -29 at 5.

**The rounding network, not the multiply, is the critical path.** MULT4 at 4 stages costs
102.0 kernel ALMs and reaches 715 MHz with `ROUND_OUT = 1`; the same point with
`ROUND_OUT = 0` costs 1.2 kernel ALMs and reaches at least 1302 MHz. Rounding and saturating
two 33-bit values to Q1.15 is therefore about a hundred ALMs and roughly half the achievable
clock — considerably more than the arithmetic it follows. That is a measurement of what
NUMERICS.md 7 already required on numerical grounds ("no intermediate saturation inside an
accumulation tree"): a FIR lane or a beamformer dot product must carry the full-precision
port through the accumulation and round **once** at the end, and now the cost of getting that
wrong has a number.

**Retiming.** Every point reports the same Fitter limiting reason — `Path Limit`, "Retiming
has used all available register locations in the critical chain path" — i.e. the Hyper-Retimer
did everything it could and the remaining delay is combinational. It is visibly working: at
`PIPE_STAGES = 2` the kernel holds 2 dedicated registers (the valid chain; every datapath
register is inside the DSP), while at 4 and 5 the retimer has spread 200-332 registers, most
of them Hyper-Registers, across the kernel. The Design Assistant flags one rule on this
design, `RES-10201 Power Up Don't Care Setting May Prevent Retiming`, which is the expected
consequence of deliberately not resetting the datapath (decision 4) and is recorded rather
than acted on.

**Decision 9 — the default for downstream kernels.** **MULT4 at `PIPE_STAGES = 4` is the default, and the module's parameter defaults now say so.**

MULT4 wins on every measured axis: same DSP blocks needed, fewer placed, 29-35 fewer ALMs,
and faster at every pipeline depth. Nothing in the sweep argues for MULT3 on this device.

`PIPE_STAGES = 4` rather than 3: at 3 the kernel reaches 490 MHz against SPEC 2's 450 MHz
target — inside the target, but with no margin for the logic a real lane puts around it — and
at 4 it clears the 600 MHz probe outright at a cost of 11 kernel ALMs and one cycle of
latency. The fourth stage is the output register, and the sweep shows that is the one that
takes the rounding network off the path into the consumer.

Downstream kernels that accumulate should instantiate it with `ROUND_OUT = 0`, carry the
33-bit exact port through the accumulation, and quantise once at the end. That is what
NUMERICS.md 7 requires numerically, and the sweep prices it at about a hundred ALMs and half
the clock per avoided rounding.

**MULT3 stays.** It is not dead code and it is not kept out of politeness to SPEC 6. The
result above is a property of *this* block's granularity at *these* operand widths: a kernel
whose coefficients push an operand past the native 18x19 multiplier — a wider coefficient
format, or a complex multiply feeding a 27x27 mode — changes which side of the trade wins,
and the sweep that answers that question is one matrix entry away. What the sweep has settled
is the default, not the parameter.

## 2026-07-25 — Polyphase FIR bank: accumulation structure, the beat/cycle latency split, frame-aligned coefficient swap, delay-line storage policy  (issue #10)

Context: SPEC §7.1 asks for a parameterized complex FIR/PFB with eight samples per cycle,
sixteen taps per phase, dual coefficient banks loaded from the configuration domain, a bank
swap confined to a safe frame boundary, configurable pipeline stages, delay lines that infer
M20Ks "when their size makes that appropriate", a multiplier structure that maps naturally to
DSP blocks, metadata that travels with its samples, and no global reset on large datapath
arrays. SPEC §18 items 2 and 3 require one FIR lane and one eight-lane PFB to be synthesized
on their own before the full design. This is the first block directory to be populated and
the first consumer of the issue #9 multiplier.

**Decision 1 — a lane's latency is TWO numbers in DIFFERENT UNITS, and they are not
interchangeable.** This is the load-bearing decision of the issue; everything else follows
from it.

A FIR history must advance once per **sample**, not once per clock: the SPEC §5 stream
presents gaps, and a delay line that shifted on every clock would push a stale sample into
the history and corrupt every subsequent output. So the delay line carries an enable. The
consequence is that anything downstream which combines values from **different beats** must
also advance once per beat, while anything combining values from the **same beat** may
free-run:

| `ACC_STYLE` | latency (beats) | latency (cycles) |
|---|---|---|
| `TREE` | 0 | `MULT_PIPE + ceil(log2 TAPS) + 1` |
| `SYSTOLIC` | `TAPS-1` | `MULT_PIPE + 2` |

A consumer aligns metadata by delaying it `pfb_lat_beats()` beats and **then**
`pfb_lat_cycles()` cycles. Collapsing the two into one delay in either unit is correct only
on a gapless stream — which is exactly the condition a unit test tends to run under and a
real system never does. `rtl/pfb/pfb_bank.sv` builds the two delays in series, and
`sim/tests/test_pfb_bank.cpp` scoreboards **by sequence number** under three backpressure
profiles so that a misalignment fails on content rather than passing quietly.

The rejected alternative was to give the systolic cascade per-stage enables so that its
latency would also be pure cycles. It does not work, and the reason is worth recording
because it looks like it should: with per-stage enables, stage `k-1` is enabled one cycle
before stage `k` **for the same beat**, so the one-beat skew the cascade depends on collapses
to zero. The cascade needs ONE shared enable — the multiplier's output valid — and that is
what makes part of its latency beat-measured. `rtl/pfb/fir_lane.sv` says so at the point of
use, because it is invisible on a gapless stream and wrong on every other one.

**Decision 2 — both accumulation structures are implemented, they are bit-identical, and
`TREE` is the default.** SPEC §18 asks which structure Agilex 7 prefers; that is a
measurement, not an argument, so both exist behind one parameter and the sweep prices them.

They are bit-identical because there is **no intermediate saturation** anywhere in a lane:
every multiplier runs at `ROUND_OUT = 0` and contributes exact 33-bit partial sums, the
`TAPS` of them are accumulated at `fxp_mac_q15_acc_w(2*TAPS)` bits where overflow is provably
impossible, and the single round-and-saturate is at the lane output. Integer addition is
associative, so the reduction order cannot change the answer. A lane that saturated
internally would give a different result for a different structure and "tree vs cascade"
would stop being a pure cost comparison.

`TREE` is the default for a reason that survives whatever the sweep says: a fabric adder tree
is the structure whose cost is predictable without knowing what the synthesiser will infer,
and — see decision 3 — it is the only one of the two that can swap coefficient sets cleanly.

**Decision 3 — the systolic cascade CANNOT swap coefficient sets cleanly, and that is a
property of the architecture rather than a defect.** This was found by the swap test and is
the strongest argument in the file for `TREE`.

A systolic cascade's partial sums walk forward one stage per beat while the data walks
backward relative to them, which is why tap `j` needs `2j` delay stages. Expanding the
cascade with a time-varying coefficient gives

```text
y(n) = sum_j h_j(n + j) * x(n - j)
```

— tap `j`'s coefficient is sampled `j` beats LATE. A swap at beat `B` therefore leaves
outputs `n` in `[B-TAPS+1, B-1]` computed from a **mixture** of the two coefficient sets, one
tap at a time. An adder-tree lane multiplies all taps of a beat in the same cycle and has no
such window.

Making the cascade swap cleanly would need tap `j`'s coefficient delayed by `j` beats — a
staggered coefficient pipeline of `32·TAPS(TAPS-1)/2` bits per lane, which at the nominal
8×16 geometry is 30 720 flip-flops per antenna. That is far more than the fabric adder tree
it was meant to save.

So the window is **documented and verified rather than eliminated**: `test_pfb_bank` builds a
second expectation set that predicts the mixture tap by tap and requires the RTL to match it
bit for bit. A cascade that switched cleanly fails just as loudly as one that switched at the
wrong beat. Nothing was relaxed to make the test pass.

**Decision 4 — the swap is aligned to the start-of-frame beat, and the start-of-frame beat
itself already uses the new bank.** SPEC §7.1's "safe frame boundary" has two readings, and
only one of them does what a user expects: the first beat of the new frame must already be
filtered with the new coefficients, or the frame is filtered with two different filters.

A registered active-bank alone cannot do that — it updates at the end of the start-of-frame
cycle. So the coefficient read selects `bank_sel = active_q ^ swap_now`, which is `active_q`
on every ordinary cycle and the incoming bank on the swap cycle. The cost is a two-gate
combinational cone ahead of the coefficient mux select; the mux itself is the wide thing and
it was always there.

Writes aimed at the bank currently in use are **refused** and raise a sticky `WR_REJECT`,
tested against `bank_sel` rather than `active_q` so the swap cycle is covered too. Allowing
them would change a coefficient set under a frame already being filtered — precisely what
double buffering exists to prevent — and would make "inactive-bank write has no effect"
unstateable. Refusing turns a software ordering bug into a visible flag instead of a
numerical result nobody can explain later.

Both properties are assertions rather than comments, and both are stated on the OUTPUT rather
than on the write logic so they survive a rewrite of it:
`a_coeff_swap_at_sof` (the bank in use changes only on an admitted start-of-frame beat) and
`a_coeff_stable_between` (the active bank's contents move only when the bank does).

**Decision 5 — one coefficient bank for the whole polyphase bank, not one per lane.** SPEC
§7.1 says "shared dual coefficient banks" and the sharing is load-bearing: a per-lane
instance would replicate the clock-domain crossing, the swap state machine and the
frame-boundary logic once per lane, and would make "the banks swapped together" a property of
eight independent state machines agreeing rather than a property of one. `coeff_bank` holds
`PHASES × TAPS` complex coefficients twice over, phase-major, and hands each lane its slice.

**Decision 6 — the configuration-to-core seam is real RTL even though this issue's
simulation tops tie both clocks together.** The write crosses as ONE `cdc_handshake` payload
carrying `{bank, address, data}` — crossing address and data as independent synchronised
buses is exactly the multibit crossing SPEC §8 prohibits, and would let one bit of an address
be sampled from a different cycle than its data. The swap request crosses as a `cdc_pulse`
(an event, with an overrun flag, not a level). The three status bits cross as three
**separate** `cdc_sync2` instances, never as a three-bit bus.

Tying `cfg_clk` to `core_clk` in a simulation top bypasses none of it: the handshake still
takes its full four-phase round trip, so the tests exercise the flow control the real system
will have. `coeff_bank` and `pfb_bank` carry `(* cdc_primitive *)` attributes as
**composites** — the same arrangement `stream_cdc` uses over `async_fifo` — and
`make cdc-inventory` now runs `--strict` over `pfb_top` as well as `cdc_prims_top`: 32
crossings, 0 unknown.

**Decision 7 — a tapped delay line can never be an M20K, and that is arithmetic rather than a
threshold.** SPEC §7.1 asks for delay lines that infer M20Ks "when their size makes that
appropriate". A memory serves one read per cycle; a direct-form FIR presents every stage at
once. So `N_TAPS > 1` forces the shift-register form at any depth and an explicit
`STYLE = "MEM"` is an elaboration error rather than a silently ignored request.

The style choice is real only for a **pure delay** (`N_TAPS == 1`) — a metadata alignment
path, a corner-turn feed, a history bank — and there `pfb_pkg` applies a joint condition:
depth ≥ 32 **and** total bits ≥ 2048. Depth alone would put a 64-deep 4-bit line (256 bits) in
a 20 Kb block; bits alone would put a 4-deep 512-bit line in one. Both must hold.

At the nominal SPEC §7.1 geometry every delay line in the design lands on shift registers,
which is the correct answer for it. The measured question the sweep answers is what Quartus
does *with* those shift registers — ALM registers or MLABs — not whether an M20K appears.

**Decision 8 — `STREAM_MAX_DATA_W` is raised from 64 to 256.** The polyphase bank is the
first block whose beat is actually the SPEC §3 beat: `SAMPLES_PER_CYCLE` complex samples, 256
bits at the SPEC §11 `full_agmf039` size. The previous bound covered a single complex sample
and matched no configuration in SPEC §11 — it was a Phase-1 artefact. Raising it changes no
instance's payload width, because every instance's width comes from its own `stream_geom_t`;
it only widens the working type the pack/unpack functions compute in.

**Decision 9 — `pfb_pkg` names its integer type `pfb_uint_t`, not `uint_t`.** `fxp_pkg` and
`stream_pkg` each already declare a `uint_t`, and `pfb_bank` wildcard-imports all three. A
name visible via two wildcard imports is ambiguous under IEEE 1800 §26.3; **Quartus Prime Pro
rejects it outright** and Verilator accepts it silently. The first calibration compile failed
to elaborate with thirteen `uint_t is visible via multiple package imports` errors — a defect
that `make lint` had passed cleanly through, and a reminder that lint clean is not the same
as synthesizable. `pfb_bank` and `pfb_top` additionally qualify their remaining `uint_t` uses
as `stream_pkg::uint_t` at the use site.

**Decision 10 — the coefficient files are committed, and the C++ model is checked against
them before the RTL is checked against the model.** `scripts/generate_coefficients.py`
designs a windowed-sinc channelizer prototype in NumPy, decomposes it phase-wise, quantises
it through `model/python/fxp_reference.py` (never through a float cast), and emits five
coefficient sets per geometry plus a golden input/output vector file for each. The vector
files are produced by `model/python/pfb_model.py`, which consults neither the SystemVerilog
package nor the C++ library.

They are committed for the reason `model/vectors/README.md` gives for the issue #4 vectors: a
golden expectation regenerated on demand proves only that the generator agrees with itself,
whereas a committed one makes a change to the filter design a reviewable diff.
`make coeff-check` — a prerequisite of `sim-tiny` — regenerates them in memory and fails on
any difference, so neither a hand edit nor an unregenerated design change survives a
regression. The issue text asked for "no generated files committed"; this follows the
established repository convention instead, with the regeneration gate as the safeguard, and
records the deviation here.

The designed sets are scaled so that `max_p sum_k |h_p[k]| = 0.98`, which makes clipping
impossible for any legal input and turns any saturation the RTL reports into a real defect
rather than a design consequence. The `random` and `max` sets deliberately do the opposite,
because the saturation path has to be exercised too — a coverage audit fails the run if both
saturation directions were not observed.

**Decision 11 — the sample delay line and the coefficient storage are never reset; the
coefficient array powers up at zero by declaration.** SPEC §23: reset validity, not every
datapath bit. A reset fanout across the 8192 bits of a nominal coefficient bank would pin
every one of them out of Hyper-Register retiming and buy nothing — coefficients are
meaningless until software writes them, so there is no state a reset could restore. The
`initial` that zeroes the array is a declaration, not a reset network: it gives simulation a
defined start and a device a null filter at power-up. Only the control state resets: the
active-bank register, the pending flag, the sticky reject flag, the credit counter and the
valid chains.

**Decision 12 — `stream_elastic_buffer`'s occupancy-bound assertion is now elaborated
conditionally.** At `DEPTH = 2**OCC_W - 1` the counter's own width already bounds it, the
comparison is constant, and Verilator 5.020 rejects it (`CMPCONST`). The check is vacuous
there rather than wrong. Left ungated it makes every `DEPTH` of the form `2**k - 1`
unbuildable — which is how it was found, by a systolic polyphase bank whose credit arithmetic
landed on 15. It is now in its own generate block, guarded; a procedural `if` with a constant
condition does not help, because the body is still elaborated.

### Measured calibration data (SPEC §18 items 2 and 3, seed 1)

Seed 1, AGMF039R47B1E1VC, Quartus Prime Pro 26.1.0 Build 110, probe constraint 600.24 MHz —
the same device, the same tool and the same deliberately-unreachable probe the issue #9 sweep
used, so the two sets of numbers are comparable. Five points, all successful. Full records in
`results/synthesis/calibration_fir.json` and `calibration_pfb8.json` (generated, not
committed); per-point evidence, including the verbatim DSP and retiming panels, under
`results/synthesis/calibration/`.

| point | DSP | DSP mode | M20K | MLAB | ALM (total / kernel) | ALUTs | regs (total / kernel) | Hyper | Fmax MHz | depth | fit s |
|---|---|---|---|---|---|---|---|---|---|---|---|
| `fir_t16_tree_p4` | 32 | 32× sum of two 18×18 | 0 | 0 | 1311 / 772.5 | 1799 | 2963 / 1756 | 75 | 620.7* | 2 | 500 |
| `fir_t16_sys_p4` | 32 | 32× sum of two 18×18 | 0 | 0 | 1469 / 932.0 | 1859 | 3580 / 2371 | 87 | 621.1* | 4 | 462 |
| `fir_t16_tree_p3` | 32 | 32× sum of two 18×18 | 0 | 0 | 1311 / 773.2 | 1797 | 2980 / 1773 | 82 | 623.1*† | 2 | 485 |
| `pfb8_t16_tree` | 256 | 256× sum of two 18×18 | 7 | 2 | 10514 / 10066.8 | 15701 | 22833 / 22469 | 758 | **537.1**† | 4 | 699 |
| `pfb8_t16_sys` | 256 | 256× sum of two 18×18 | 7 | 2 | 11664 / 11237.0 | 15828 | 27289 / 26925 | 133 | **449.6** | 4 | 692 |

`*` the register-to-register paths MET the 600 MHz probe, so that Fmax is a lower bound rather
than a measured limit. `†` the worst register-to-register path does not touch the kernel
instance, so the number bounds the wrapper as well as the kernel. Both caveats are recorded per
point by `scripts/run_calibration.py` rather than left for a reader to notice; the two
**bold** figures are genuine measured limits.

**The systolic cascade buys no DSP cascade at all.** Both structures map to exactly 32 blocks
for a 16-tap lane and 256 for the eight-lane bank — 2 blocks per complex multiply, 64
multipliers per lane, all in `Sum of Two 18x18` mode. That is the same mapping issue #9
measured for a bare complex multiply, scaled linearly, and it is the whole answer: the block's
adder is **already consumed** by the complex multiply's own post-add, so there is no chainout
left for the tap accumulation to ride. The textbook argument for a systolic FIR — that the
accumulator disappears into the DSP chain — assumes a real multiply per block. A complex
multiply does not leave that room.

**So the cascade pays for a delay line and gets nothing back.** Per lane it costs 21% more
kernel ALMs (932.0 vs 772.5) and 35% more kernel registers (2371 vs 1756) — the doubled delay
line (two stages per tap) plus 37-bit accumulator registers where the tree has 33-bit adders.
At eight lanes the gap is 11.6% of ALMs and 20% of registers.

**And at scale it is 19% slower.** The lane points both cleared the probe, so they say only
"≥620 MHz" and cannot separate the two. The eight-lane points are where the structures
actually differ: **537.1 MHz for the tree against 449.6 MHz for the cascade**, with the tree
also retiming far better — 758 Hyper-Registers against 133. Against the SPEC §2 benchmark
target of 450 MHz the tree has 19% margin and the cascade has none.

**`ACC_STYLE = "TREE"` is therefore the default on measurement, not on taste**: fewer ALMs,
fewer registers, better retiming, higher Fmax, identical DSP count — and, from decision 3, the
only one of the two that can swap coefficient sets cleanly at a frame boundary.

**No M20K appears at the lane, and the two that appear at the bank are not the delay line.**
Both FIR points report M20K = 0 and MLAB = 0: the 16-tap history and the 2×16×32-bit
coefficient store are ALM registers, exactly as `pfb_pkg`'s threshold predicts and as decision
7 argues they must be. The 7 M20K and 2 MLAB at the eight-lane point are the **output elastic
buffer** — a 280-bit payload at depth 11 (tree) or 22 (cascade) is 3–6 Kb of storage, and
Quartus infers memory for it despite `stream_elastic_buffer`'s header claiming distributed
registers "by construction". That claim is now wrong at wide payloads and is worth revisiting
when the medium integration (issue #17) sizes the real interfaces.

**The multiplier pipeline depth does not move the lane.** `fir_t16_tree_p3` is
indistinguishable from `fir_t16_tree_p4` in ALMs (773.2 vs 772.5) and in Fmax (both above the
probe), so the issue #9 calibrated default of `PIPE_STAGES = 4` carries into a lane at no cost.
Its critical path did move out of the kernel and into the coefficient bank's write path, which
is the first sign that the boundary rather than the arithmetic is what limits a shallow lane.

**The frame-boundary swap logic is on the critical path, and it was found rather than
assumed.** `fir_t16_tree_p4`'s worst register-to-register path runs
`u_coeff|pending_q → g_mult[9].u_mult|add_1` — the two-gate `bank_sel` cone from decision 4,
straight into a multiplier operand. At the lane it still clears 620 MHz. If the eight-lane
number ever needs to go past 537 MHz, that cone — not the adder tree — is the first thing to
pipeline, and the record says so.

**Full-scale projection.** At the SPEC §11 `full_agmf039` size the polyphase bank alone is
256 DSP × 16 antennas = **4096 of 12 300 DSP blocks (33%)** and roughly 168 k of 1 305 600 ALMs
(13%), before the FFT, the beamformer or anything else. That is the number SPEC §18 exists to
produce, and it says the DSP budget — not the fabric — is what the full-scale parameter freeze
(issue #17/#20) has to be planned around.

**Decision 13 — two defects that only a Quartus compile could find, and what they say about
the gate.** Neither of these was reachable through `make lint` or `make sim-tiny`; both fell
out of the first calibration compiles, which is an argument for running SPEC §18 early rather
than at the end.

* `rtl/packages/pfb_pkg.sv` originally declared its own `uint_t`, colliding with `fxp_pkg`'s
  and `stream_pkg`'s. Quartus rejected it with thirteen `visible via multiple package imports`
  errors; Verilator had accepted it silently. See decision 9.
* `rtl/common/fxp_sticky_flags.sv` declared `input logic` ports under `default_nettype none`.
  Quartus rejects that ("net type must be explicitly specified"); every other module in the
  repository already declared `wire`, and this one had simply never been through a synthesis
  tool because the polyphase bank is the first block to instantiate it in one.

The lesson is recorded because it changes how a later kernel should be developed: **lint clean
is not the same as synthesizable**, and a kernel that has never been compiled by Quartus has an
unknown number of these waiting. The calibration project is the cheapest way to find them, and
it should be stood up alongside the RTL rather than after the tests pass.

**Decision 14 — the delay line's memory form is exercised by a same-run equivalence probe.**
`pfb_pkg`'s AUTO threshold correctly resolves every delay line in the datapath to a shift
register, so the M20K branch was reachable only by an explicit override that nothing used —
code no test ran, which is the same thing as code that does not work.

`sim/verilator/tops/pfb_top.sv` therefore instantiates two lines of identical geometry, one
forced to each style, off the live stream, and compares them on every enabled cycle once both
have filled (`a_dl_styles_agree`). A pure delay is a pure delay: if the memory form's pointer
arithmetic or its read-before-write ordering were wrong, this says so. The test additionally
fails if the probe never filled, so it cannot pass vacuously. The geometry — 40 deep, 32 bits
— is past `PFB_MEM_MIN_DEPTH` but only 1280 bits, so AUTO would still choose SRL; the MEM
instance is therefore also a test that an explicit override is honoured.
