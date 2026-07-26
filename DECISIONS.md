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

## 2026-07-26 — Streaming FFT: parallelism by decimation in time, committed twiddles, non-stallable core, per-stage scaling  (issue #11)

Context: SPEC §7.2 asks for a parameterised streaming FFT — radix-2² single-path delay
feedback preferred, `SAMPLES_PER_CYCLE` complex samples per cycle, a fixed-point scaling
schedule, frame-continuous operation, twiddles in memory and twiddle multipliers in DSPs —
beginning at `FFT_SIZE=64`, `SAMPLES_PER_CYCLE=2`. SPEC §18 items 4 and 5 require one FFT
stage and one full FFT to be synthesized and measured before full-scale parameters are
chosen. This is the second Phase 2 kernel and the first block in the design with memories,
a frame structure and a multi-stage numerical schedule, so several things settled here are
settled for the PFB, the corner turn and the beamformer as well.

**Decision 1 — parallelism comes from a decimation-in-time lane split, not from widening
the SDF path.** A radix-2² SDF path is inherently one sample per cycle: one datapath, one
delay-feedback memory, one control counter. `SAMPLES_PER_CYCLE = P` is obtained instead by
observing that the beat already carries the samples in time order, so

```text
beat t carries x[P*t + 0] .. x[P*t + P-1]   ->   lane p IS the subsequence x[P*n + p]
```

Each lane runs an ordinary `M = N/P` point radix-2² SDF core, and the lanes are reassembled
by log2(P) levels of radix-2 decimation-in-time merge:

```text
X[m]       = E[m] + W_N^m O[m]
X[m + N/2] = E[m] - W_N^m O[m]        m = bitrev(j), j the output beat index
```

The split costs **nothing** — it is how the samples arrive — and the merge is one complex
multiply and one butterfly per beat, with no memory at all. Every lane keeps the property
that makes radix-2² SDF worth choosing in the first place: one delay-feedback word per
sample of transform state, and `log4(M) - 1` non-trivial multipliers.

*Alternatives rejected.* A **P-parallel multi-path delay commutator (MDC)** carries the same
total delay memory but adds a commutator network between every pair of stages and makes
every stage's control a function of P; the RTL then has a P-dependent structure inside each
stage rather than P identical stages. A **2-parallel radix-2² with the delay lines split
across the two paths** keeps one control network but doubles the butterfly count per stage
and needs cross-path wiring at every stage, and its stage module is no longer the same
module a 1-sample-per-cycle configuration would use. Both were rejected for the same
reason: they make P an *internal* parameter of every stage, where this decomposition makes
it the *number of identical cores*, and issue #20 has to reach `P = 8` on RTL that has been
verified at `P = 2`.

*What is verified.* `P ∈ {1, 2}`. `fft_pkg::fft_spc_supported()` says so and elaboration
fails otherwise. The merge module takes its level as a parameter and `fft_dit_tw()` takes
the level in its twiddle arithmetic, so `P = 8` is a generate loop over three levels rather
than a rewrite — but it is unverified, and an unverified geometry that elaborates silently
is worse than one that refuses to.

**Decision 2 — the trailing radix-2 stage is the normal case, and it falls out of the rule
rather than being bolted on.** `N` a power of four with `P = 2` gives `M = N/2` and
therefore an **odd** `log2(M)` for every size this design uses: 64/2 → M=32, n=5; 256/2 →
M=128, n=7; 1024/2 → M=512, n=9. The general rule in `fft_pkg` is

```text
sub-stage s: delay 2^(n-1-s); BF2I when s is even, BF2II when s is odd;
             a twiddle multiplier follows s when s is odd and s < n-1
```

For odd `n` this produces a lone BF2I with delay 1 as the last sub-stage — exactly the
"final radix-2 stage" a non-power-of-four transform needs — with no special case anywhere.
`fft_sdf_path` asserts at elaboration that the chain it generated has the multiplier count
`fft_lane_mults(n)` predicts, so a miscount is a build failure rather than a wrong
transform. Both parities are exercised: the shipped sizes are odd, and
`model/cpp/test/test_fft_ref.cpp` sweeps the geometry helpers over 8…1024 at P ∈ {1,2}.

**Decision 3 — control is data: the sample's position travels with it.** Every SDF
sub-stage needs the phase bit, the trivial-twiddle bit and the twiddle ROM address, and all
three are fields of the sample's position in the frame. A counter per stage would have to be
*aligned* to that stage's stream, and the alignment is a function of every delay and every
pipeline register ahead of it — the arithmetic that is right in the comment and wrong in the
RTL. So the position is an n-bit tag that travels with the sample, and a sub-stage emits
`idx_out = idx_in - D(s)` because its output stream is its input stream delayed by `D`
positions. The tag is n bits and M is 2ⁿ, so the modulo is free.

The only place cumulative latency appears is `fft_pkg::fft_total_latency()`, which sizes the
metadata path, and `streaming_fft` asserts on every delivered beat that the metadata's
`start_of_frame` coincides with position 0 out of the core. If the latency arithmetic were
off by one beat, that fires on the second frame.

**Decision 4 — the scaling schedule is a compile-time bit per sub-stage, and its headroom
claim is stated precisely because the comfortable version is false.** The datapath is Q1.15
complex at every sub-stage boundary. A butterfly sums two Q1.15 values, which by `fxp_pkg`'s
own growth rule needs `fxp_acc_w(FXP_SAMPLE_W, 2) = 17` bits; `SCALE_SCHED` bit *g* decides
whether that 17th bit is discarded by a one-place right shift (round-to-nearest-even, then
saturate) or kept by letting the value saturate and setting the stage's flags.

The obvious claim — "one place of right shift cannot overflow" — is **wrong**, and the
assertion written to check it is what found that out:

```text
a + b in [-2^16, 2^16 - 2]         rne(-2^16 / 2) = -2^15         fits
a - b in [-(2^16 - 1), 2^16 - 1]   rne(65535 / 2) = rne(32767.5) = 32768   does NOT fit
```

The difference reaches `2^16 - 1` at `a = +0.99997, b = -1.0`, and ties-to-even rounds it
one LSB past the top of Q1.15. So a fully scaled butterfly *can* saturate, on exactly one
operand pair, by exactly one LSB, upward only. `fft_bf2` now asserts that precise statement
— never negative, never more than one LSB over — on every beat, and both models reproduce
the event. It is the asymmetric two's-complement range showing through, the same way it does
in `-(-1.0)`; the trivial twiddle is the second, independent instance, since `-j` negates a
component and a sample of exactly `-1.0` saturates there whatever the schedule says.

*Compile-time, not a register.* A programmable schedule would put a per-stage shift
multiplexer in the datapath and make the bit-exact reference model a function of run-time
state, so a vector would no longer be a statement about the design. The same coverage is
obtained by elaborating a second instance, which is what `sim/verilator/tops/fft_top.sv`
does: two saturating schedules, one shifting nowhere and one shifting only sub-stages 0 and
1, so the **per-sub-stage** flags are falsifiable rather than merely present. Making the
schedule programmable later is a parameter becoming a port; nothing else changes.

**Decision 5 — the twiddle table is generated once, committed, and read by all three
implementations. It is not computed at elaboration time.** The coefficients are the only
numbers in this design that come from transcendental functions. A table computed at
elaboration would be computed three times — by Verilator's libm, by Quartus's libm and by
Python's — and "the three agree in the last unit in the last place, for every entry, on
every host" is an assumption that **cannot be checked from inside a simulation**: a
Quartus/Verilator disagreement produces hardware that differs from the model it was verified
against, and nothing in the flow would notice.

So `model/python/gen_fft_twiddles.py` emits `rtl/fft/generated/fft_twiddle_pkg.sv` and
`model/cpp/fft/fft_twiddle_table.hpp` from one list of 1024 integers, both committed, both
checked by `--check` inside `make lint` and `make sim-tiny`. The precedent is exactly the
generated register map (issue #7, decision 2) and the golden vectors (issue #4); the
addition here is a **digest**: the vector file carries the table's SHA-256 prefix and the
test refuses to run against a file whose digest does not match the build, so a regenerated
table paired with stale expectations is one line of output instead of thousands of wrong
samples.

Angle reduction is to the first quadrant with exact sign/swap symmetry, so `W^0 = (1, 0)`,
`W^(N/4) = (0, -1)` and `W^(N/2) = (-1, 0)` are exact rather than whatever `cos(pi/2)`
returns — which matters, because the radix-2² structure's trivial twiddles depend on it.

**Decision 6 — trivial twiddles are multiplied, not bypassed, and `W^0` quantises to
`0x7FFF`.** `cos(0) = 1.0` is not representable in Q1.15, so the quantised `W^0` is
`0x7FFF`, one LSB short of unity, and multiplying by it is not the identity. The FFT
multiplies anyway. Bypassing per sample would need a multiplexer between the multiplier
output and a delayed copy of its input, on the sample's own position, in every twiddle
stage — and it would save **no DSP**, because the multiplier exists for the non-trivial
samples regardless. What it would buy is a gain of exactly 1 instead of 32767/32768 per
multiplier stage; the measured consequence of not buying it is that a full-scale impulse
comes back as 32764 instead of 32767 across a 64-point transform, which is inside the
3 LSB the float cross-check measures. The structural trivial twiddles that *do* matter —
the `-j` of BF2II and the absent multiplier after the final group — are structural and cost
nothing, and those are kept.

**Decision 7 — the core is never stalled; backpressure is applied at the input by credit,
and the output FIFO is sized from the pipeline's own latency.** The obvious construction is
a clock enable on every register driven by the downstream ready. Two things rule it out.
SPEC §23 says, in order, "Avoid one chip-wide clock enable", "Pipeline enables before broad
distribution", "Keep pipeline stages latency-insensitive", "Break ready/valid feedback with
elastic buffers" — a ready-driven enable on every DSP and every memory in the transform is
the first of those, verbatim. And `rtl/common/complex_multiplier.sv` has **no clock enable
on its datapath**, by an explicit decision recorded in issue #9 and measured by its
calibration sweep; stalling the FFT internally would mean changing that kernel and
invalidating its numbers, or not using it.

So the core is a valid-tagged, gap-tolerant pipeline: each stage's registers advance on a
local, pipelined beat-valid, and a cycle with no beat simply does not advance the delay
feedback. Nothing downstream can stop a beat once it is in. Backpressure is applied at the
input by a credit counter that reserves an output slot for every beat admitted, which bounds
(FIFO occupancy + beats in flight) by the FIFO's depth; the beats in flight are exactly the
pipeline's latency, so the depth is `fft_pkg::fft_total_latency() + OUT_SLACK`, derived
rather than guessed.

**The cost is real and is stated rather than buried:** an output FIFO of about one M20K for
the 64-point / 2-samples-per-cycle configuration, where a stallable design would need a
four-entry skid. That is what the two calibration projects are for — `fft_stage_calib`
prices the arithmetic and memory of one stage, `fft_core_calib` prices the whole block, and
the difference is this decision's bill.

*Consequence worth knowing.* The pipeline is indexed by sample position, not by time: a
frame's output requires `fft_total_latency()` further beats to be admitted before it
emerges. In continuous operation — which is what a radar front end is — that is invisible;
a test driving a finite number of frames must drive that many more, and `test_fft.cpp` does.

**Decision 8 — metadata rides a FIFO, not a delay line.** The core's latency is a fixed
number of *beats* but not a fixed number of *cycles*: its delay feedbacks advance on beats
while its multipliers free-run. A shift register would have to reproduce the core's internal
structure to stay aligned. A FIFO pushed on admission and popped on delivery is aligned by
construction, and the assertion that the popped `start_of_frame` lands on output position 0
is what turns the latency arithmetic into a checked fact.

Output beat *k* of a frame carries input beat *k*'s metadata. No output beat "is" a
particular input beat — the output is a transform of the whole frame — so this is a
convention, and it is the one that keeps `stream_id`, the sequence number and the frame
flags meaningful end to end, so the SPEC §5 loss/ordering checks and the issue #8 sequence
checker work across the FFT exactly as they work across a FIFO.

**Decision 9 — the output pairs bins half a spectrum apart, and the reorder is optional.**
Output beat *j* carries `X[m]` and `X[m + N/2]`, with `m = bitrev(j)` when `REORDER = 0` and
`m = j` when `REORDER = 1`.

Pairing `(X[j], X[j+N/2])` rather than the more obvious `(X[2j], X[2j+1])` is what makes the
reorder buffer a **pure beat permutation**: both slots move together, no sample ever changes
lane, and the buffer is two independent banks read at the same address. The adjacent pairing
would need two addresses differing in the low bit — the same bank on the same cycle — and a
second read port the memory does not have.

`REORDER` is a parameter because the corner-turn memory of issue #15 addresses its write
side arbitrarily and can absorb the permutation for **nothing**. Reordering here costs one
frame of latency and two banks of `N/P` beats; whether to spend that belongs to the issue
that consumes the output, so both orders are supported, both are bit-exact against the
reference model from the same parameter, and `model/vectors/fft64.vec` pins both with data.
Double buffering rather than an in-place exchange: bit reversal is an involution, so the
permutation is a set of swaps, but an in-place version needs a read and a write to different
addresses in the same cycle and still cannot start until the frame is complete — it trades
memory for a second port and a much harder correctness argument.

**Decision 10 — which model is the oracle.** The same triangle as issues #4 and #9, one
level up: `model/python/gen_fft_vectors.py` (NumPy, independent algorithm) writes
`model/vectors/fft64.vec`; `model/cpp/test/test_fft_ref.cpp` validates
`model/cpp/fft/fft_ref.hpp` against those vectors **before** anything uses it; and
`sim/tests/test_fft.cpp` requires the RTL, the C++ model and the vectors to agree
bit-for-bit. The one thing deliberately shared is the twiddle *table* (decision 5) — what is
independent is the algorithm.

The Python generator additionally compares every non-saturating record against
`numpy.fft.fft` scaled by the schedule's gain and fails above 16 LSB; the committed set's
worst is **3.0 LSB**. That produces no expected value, but it catches the one class of error
a self-consistent bit-exact model cannot: a transform that agrees with itself and is not a
DFT.

**Decision 11 — two calibration projects, not one.** SPEC §18 names "one FFT stage" and "one
full FFT" as separate items, and they answer different questions.
`quartus/calibration/fft_stage_calib` compiles a single `fft_radix22_stage` — the smallest
piece containing all four cost classes at once: delay-feedback memory, a twiddle ROM, a
DSP-mapped complex multiply and the quantisation network. `fft_core_calib` compiles the
whole `streaming_fft` block. The difference between them, after multiplying the stage by the
structure, is decision 7's bill, measured rather than argued.

No new Tcl. `quartus/scripts/calibrate.tcl` was written kernel-agnostic by issue #9 — "the
top-level entity is read FROM the project, not hardcoded here, so adding the SPEC 18 kernels
that follow the complex multiplier … is a new qpf/qsf/sdc triple and nothing else" — so this
issue adds two project triples, two wrappers and two matrix entries.

### Measured calibration data (SPEC §18 items 4 and 5, seed 1)

Device `AGMF039R47B1E1VC`, Quartus Prime Pro 26.1, full compile (synthesis +
Fitter + STA), probe constraint 600 MHz for the reason
`quartus/calibration/*_calib.sdc` gives. `Fmax` is the register-to-register
measurement; `ALM(kern)` is the `u_kernel` instance alone, without the wrapper's
boundary registers. Every point's critical path is inside `u_kernel` and every
point reports zero unconstrained endpoints.

**One radix-2² stage** (`fft_stage_calib`, the first group of a 64-point /
2-samples-per-cycle lane: delay lines of 16 and 8 words, a 32-entry twiddle ROM):

| point | DSP | 18x18 | M20K | MLAB | ALM | ALM(kern) | regs | hyper | Fmax MHz | depth |
|---|---|---|---|---|---|---|---|---|---|---|
| `TW_PIPE=3` mem AUTO | 2 | 2 | 2 | 0 | 531 | 453.9 | 494 | 160 | **338.5** | 7 |
| `TW_PIPE=4` mem AUTO | 2 | 2 | 2 | 0 | 534 | 468.3 | 682 | 315 | **345.9** | 4 |
| `TW_PIPE=4` mem MLAB | 2 | 2 | 0 | 6 | 570 | 505.8 | 519 | 89 | **382.0** | 6 |

**The whole 64-point block** (`fft_core_calib`, `streaming_fft` including the
elastic boundary, the metadata FIFO and the credit-backed output FIFO):

| point | DSP | 18x18 | M20K | MLAB | ALM | ALM(kern) | regs | hyper | Fmax MHz | depth |
|---|---|---|---|---|---|---|---|---|---|---|
| `TW_PIPE=4` reorder, mem AUTO | 10 | 10 | 12 | 26 | 3157 | 2998.0 | 3481 | 1131 | **330.0** | 4 |
| `TW_PIPE=3` reorder, mem AUTO | 10 | 10 | 12 | 26 | 3282 | 3125.7 | 3106 | 654 | **331.0** | 4 |
| `TW_PIPE=4` no reorder, mem AUTO | 10 | 10 | 8 | 19 | 2987 | 2829.9 | 3063 | 886 | **337.6** | 6 |
| `TW_PIPE=4` reorder, mem **DEFAULT** | 10 | 10 | 4 | 42 | 3322 | 3164.2 | 3086 | 603 | **362.2** | 6 |

**Finding 1 — the DSP count is exactly the structure, and nothing else.** Two DSP
blocks per complex multiply, in `sum_of_two_18x18` mode, which is what issue #9
measured for `complex_multiplier` on its own. Ten for the 64-point block: two
lanes × two twiddle multipliers, plus one merge multiplier, × 2. The
radix-2² structure's whole point is that only every second butterfly needs a
multiplier, and the count confirms it — a radix-2 SDF of the same size would
need eight.

**Finding 2 — the delay feedback is the FFT's critical path, and leaving its
placement to the tool is the wrong answer.** At `mem AUTO` the Fitter puts a
16-word by 32-bit feedback into an M20K, and the failing path is then *inside the
M20K*, block register to block register:

```text
u_kernel|u_bf2i|u_dly|...|altera_syncram_impl1|ram_block2a0~reg0
  ->     u_kernel|u_bf2i|u_dly|...|altera_syncram_impl1|ram_block2a12~reg0
```

Nothing downstream can fix that: the path is inside a hard block, so the
Hyper-Retimer has nowhere to put a register, and the points duly report `Path
Limit` (and, at the block level, once `Retiming Dependency Loop`). Forcing the
line into LUT-RAM moves the critical path back into the fabric — MLAB output
through the butterfly to the next feedback's write port — where it is at least
the kind of path that pipelining can shorten.

That is the measurement behind `fft_pkg`'s `"DEFAULT"` placement rule, and the
seventh point measures the rule rather than inferring it from the stage: **330.0
→ 362.2 MHz (+9.7%), M20K 12 → 4, at +165 ALMs and +16 MLABs.** The M20Ks that
remain are the output and metadata FIFOs and the reorder banks, which are the
places an M20K belongs.

**Finding 3 — the twiddle multiplier's depth is currently irrelevant.**
`TW_PIPE` 3 against 4 is 331.0 against 330.0 MHz at block level — a difference
of 0.3%, i.e. noise — because the multiplier is nowhere near the critical path.
At the stage level, where there is less else to be slow, 4 is 7 MHz better than
3. `TW_PIPE = 4` stays the default, matching issue #9's measured choice, but the
sweep says plainly that spending a cycle there buys nothing until finding 2's
path is fixed.

**Finding 4 — the bit-reversal reorder costs about what it looks like.**
`REORDER = 1` against `0`, both at `mem AUTO`: +170 ALMs, +4 M20K, +7 MLAB and
−7.6 MHz, plus one frame of latency. That is the number DECISIONS.md decision 9
leaves for issue #15 to spend or not: if the corner turn can absorb the
permutation in its own write addressing, this is what it saves.

**Finding 5 — 450 MHz is not met, and the reason is identified rather than
guessed.** The best point is 362.2 MHz against the SPEC §2 target of 450. The
remaining critical path, with the memory placement fixed, is

```text
u_bf2i|dout_q.re[7]  ->  ... -> u_bf2ii|u_dly|...|lutrama26~reg0
```

— one butterfly's output register, through the trivial `-j`, the second
butterfly's adder and its round-and-saturate, into the next delay line's write
port: six logic levels, 1.564 ns of cell delay and 0.997 ns of routing. There is
exactly one register between those two points, so the Hyper-Retimer has nothing
to move and reports `Path Limit`.

The structural answer is a register between the butterfly's quantisation and the
feedback's write port, which deepens `fft_bf2` by one stage and moves the
position/latency arithmetic in `fft_pkg` with it. That is a timing-closure change
with a functional blast radius, and SPEC §20 has a procedure for exactly that
kind of change — one hypothesis, the smallest defensible edit, correctness
re-proven, then a compile. It is **not** made here: issue #11's remit is to
produce the measurement that says which change to make, and this is it. The
number to beat is 362.2 MHz, the path is named above, and the bit-exact model and
the vector set are what will prove the change did not alter the transform.

## 2026-07-25 — Power and covariance: POWER_W as an exact window bound, conjugation by operand swap, where configuration latches  (issue #13)

Context: SPEC §7.6 asks for `Power = I^2 + Q^2`, a configurable cross-power
`Rxy = X * conj(Y)` over selected antenna or beam pairs, a programmable integration window,
accumulator protection, window-boundary metadata, optional exponential averaging, a runtime
enable per pair, and deterministic reset and flush behaviour. SPEC §3 fixes `POWER_W = 40`.
This is the third Phase 2 kernel; it consumes the issue #9 complex multiplier and the issue
#4 numerics package, and it is the first block in the design with a **programmable
integration state**, so several things settled here are settled for CFAR (#14) and the
event aggregator (#18) as well.

**Decision 1 — `POWER_W = 40` is not a round number, it is 32 + 8, and the 8 is the exact
window bound.** With I, Q in Q1.15, one term of anything this block accumulates satisfies
`|v| <= 2^31`: the power extreme `I = Q = -32768` gives exactly `2^31`, and so does each
component of a Q1.15 conjugate product. A single term therefore needs 32 signed bits — the
same "the sum of two Q2.30 products is not Q2.30" fact that made `complex_multiplier`'s
full-precision port 33 bits wide (issue #9, decision 1). An N-term sum of such terms fits a
signed w-bit accumulator without clamping iff

```text
N * 2^31 <= 2^(w-1) - 1        i.e.        N <= 2^(w-32) - 1
```

so `w = 40` buys **255 samples of provably exact integration, for any input**. That is the
whole content of SPEC §3's `POWER_W`, and `covar_pkg` exports the relation in both
directions (`covar_acc_w_required`, `covar_window_max_exact`) so that a longer exact window
is obtained by calling a function rather than by guessing a width.

At N = 256 the bound is missed by exactly one LSB, and only by the single input sequence in
which every sample is the extreme — 256 copies of `X = Y = (-32768, -32768)` sum to exactly
`+2^39` against a maximum of `2^39 - 1`. That is not a hypothetical to be waved at: it is a
directed test, and `test_covariance` drives both it and the 255-sample case that must sum
exactly. Beyond the bound the accumulator clamps, never wraps, and raises a sticky flag
through `fxp_sticky_flags` — the standing reason being that a wrapped power estimate is
indistinguishable from a target to the CFAR stage downstream, whereas a clamp degrades
monotonically and is visibly flagged.

**Decision 2 — one SIGNED accumulator for both power and cross-power, even though power is
provably non-negative.** An unsigned accumulator for the power path would buy one bit
(exact to 511 rather than 255) at the price of a second saturation rule, a second C++ model
path, and a second set of corner tests — and `fxp_pkg` has no unsigned clamp, so it would
also be the first quantisation in the design not expressed as a call into the shared
package. `power_calc` therefore presents its result in a signed `POWER_W` field with the
top eight bits zero, and `integrator` is instantiated identically behind the power path and
behind each half of a covariance pair. The width note is in `power_calc.sv` section 1.

**Decision 3 — `power_calc` has no saturation flag, because saturation is impossible, and
the impossibility is asserted rather than declared.** `max(I^2 + Q^2) = 2^31 < 2^39 - 1`.
A flag that can never fire is worse than no flag: it invites a consumer to believe the
datapath is monitored when the monitoring is one module downstream. What the module carries
instead is `a_power_range` and `a_power_matches_pkg`, checked on every qualified output
against `fxp_pkg`'s own multiply on a shadow copy of the operands — the same arrangement
`complex_multiplier` uses for its arithmetic core.

**Decision 4 — the conjugate is formed by REWIRING the multiplier, never by negating
`y.im`.** The obvious wiring, `b = (y.re, -y.im)`, is wrong on the first input a reviewer
tries: `y.im = -32768` is a legal Q1.15 value whose negation is `+32768`, which does not fit
16 bits. Negating it either saturates (wrong product) or wraps back to `-32768` (wrong
sign), and either way the extreme corner — the corner decision 1's whole analysis is built
on — would be silently incorrect.

The engine instead feeds the issue #9 kernel the Y operand with its halves EXCHANGED,
`b = {re: y.im, im: y.re}`, and reads

```text
p_re = x.re*y.im - x.im*y.re = -Im(X conj(Y))
p_im = x.re*y.re + x.im*y.im = +Re(X conj(Y))

  ->   Rxy.re = p_im        Rxy.im = -p_re
```

The negation moves from a 16-bit OPERAND, where `-32768` overflows, to the 33-bit exact
PRODUCT port, where `|p_re| <= 2^31` and the field holds `[-2^32, 2^32-1]` — so it cannot
overflow for any input, and it costs one adder rather than one multiplier. No new
arithmetic, no saturation, `complex_multiplier` used exactly as it is, in genuine conjugate
mode. The directed test that keeps it honest is `X = Y`, which must give `Rxx.re == power`
and `Rxx.im == 0` exactly, on every corner; the fault injection that proved the oracle
bites was reverting this one expression.

`ROUND_OUT = 0` on every instance: the accumulator consumes the exact 33-bit product,
because quantising each term back to Q1.15 before summing 255 of them would throw away
precisely the bits the 40-bit accumulator exists to keep. The rounding network optimises
away entirely.

**Decision 5 — the input contract is a PARALLEL source vector, not a time-multiplexed pair
stream.** SPEC §3 puts this block after the frequency-alignment network and the beamforming
matrix, both of which exist to produce all channels for one instant in the same beat. A
serialised `(X, Y)` pair stream would need a re-serialiser whose only job is to undo that,
would cap the input rate at one vector per enabled pair — a 10x reduction at the SPEC §11
medium size, where the full upper triangle of four sources is ten pairs — and would need an
elastic buffer and a ready chain, which is exactly the convention every other Phase 2
kernel avoids (issue #9, decision 4).

The price is DSPs: one complex multiplier per pair, forty of them at medium against a DSP
column of several thousand. The trade is not close at that size. It does **not** stay
comfortable at full scale: sixteen sources with a full upper triangle is 136 pairs = 544
DSPs at MULT4, which is where `MULT3` (three multipliers, bit-identical — issue #9,
decision 2, so it is a pure resource decision) and a pruned pair list start to matter. Both
are already parameters here, and the full-scale pair count is a SPEC §18 measurement rather
than a number chosen in this file.

**Decision 6 — the per-pair enable gates the ACCUMULATION, not the multiply, and it latches
at a window boundary.** An enable on a DSP register is what stops the tool using the
block's own pipeline registers (SPEC §23; measured in issue #9), and a per-pair mask is
exactly the kind of high-fanout control that should not reach a datapath register. So a
disabled pair still computes a product and that product goes nowhere. Because
`integrator`'s `cfg_enable` latches at a boundary, a pair disabled mid-window FINISHES the
window it is in and then stops, and a pair enabled mid-window starts at the NEXT window with
a full-length one. Neither ever produces a partial window as a side effect of a register
write: the only thing that shortens a window is an explicit flush, and a flush marks it.

**Decision 7 — a configuration boundary is "no window open AND none opening", and the
second half of that is load-bearing.** Window length, mode, exponential shift and enable
latch at a window close, at a flush, or in an idle cycle. The idle term is what lets a
DISABLED block be enabled again — a disabled block accepts no samples, closes no windows,
and would therefore never see another boundary. The `!accept` term is what stops a length
written in the same cycle as a window's FIRST sample from latching while that sample is
already being counted.

That second term was not in the first implementation, and it is here because
`a_covar_truncated_implies_flushed` fired during bring-up: the window ran to a length that
was never in force when it opened, overshot, and was reported truncated without having been
flushed. The lesson is worth the paragraph — the visible symptom of a configuration-timing
defect is a metadata inconsistency, several cycles removed from the cause, on a stimulus
that has to change the length at exactly the wrong cycle. An assertion inside the module
turned that into an immediate named failure; a scoreboard alone would have reported a wrong
accumulator value and left the diagnosis open.

**Decision 8 — the pair TABLE latches only on reset and flush, which is deliberately
stricter than the enable rule.** The multiplier is `CMULT_PIPE_STAGES` deep, so at any
instant there are products in flight formed from the selectors as they were several cycles
ago. A selector change timed against the integrator's window boundary would still let a
handful of old-source products land in the new window: a boundary that is exact at the
accumulator is not exact at the multiplier input, and pretending otherwise is how a block
acquires a rare, timing-dependent wrong answer. Re-pointing a pair is therefore: write the
table, pulse `FLUSH`. The per-window runtime control SPEC §7.6 actually asks for is the
per-pair ENABLE, which has no such hazard because a disabled pair's in-flight products are
discarded rather than misattributed.

**Decision 9 — flush is defined as an EQUIVALENCE, not as a list of side effects.** "After
a flush the module is in the state it is in one cycle after reset release, and any partial
window has been emitted first." Concretely that includes resetting `window_id` to zero and
clearing the sticky saturation state, both of which are easy to leave out and neither of
which a list-shaped specification would make testable. Written as an equivalence it is
directly checkable, and `test_covariance` checks it the obvious way: the same stimulus run
from reset and again after a flush must produce byte-identical result streams, window ids
included. Software that wants to keep the saturation history reads it before flushing;
`SAT_CLEAR` exists for the opposite case.

**Decision 10 — exponential averaging TRUNCATES, and the resulting dead band is documented
rather than discovered.** The update is `y += (x - y) >>> k` through `fxp_pkg::fxp_trunc`,
i.e. floor division. The project rule is round-to-nearest-even everywhere a value is
QUANTISED, and this is deliberately not that: it is the loop gain of the one feedback path
in the block that cannot be pipelined, since `y` is needed next cycle. Rounding inside that
loop buys a fraction of an LSB of DC accuracy and costs the closure of the accumulator loop,
on a block whose output feeds a software-programmable threshold.

The consequences are exact and are checked against the model rather than tolerated:
`k = 0` is a pass-through; for `x > y` the increment is zero whenever `0 < x - y < 2^k`, so
rising convergence stalls in a dead band and never quite reaches the target; for `x < y` the
increment is at most `-1` always, so falling convergence never stalls. The fixed set for a
constant `x` is `y in (x - 2^k, x]` — biased low by up to one shift quantum, exactly. The
test asserts that interval in both directions for every `k` it can settle inside its cycle
budget (`k <= 6`; a `k = 15` filter needs on the order of `2^15 * 20` samples, and claiming
convergence the run never observed would be worse than not claiming it). Every `k` from 0
to 15 is still checked bit-exactly against the model.

**Decision 11 — the SPEC §9 group "Integration settings" gets a real window, at 0x9000.**
It was the one group in SPEC §9 that no implemented block claimed — it was parked on the
planned CFAR window. `rtl/control/reg_block_covar.sv` implements it: window length,
exponential mode and shift, per-pair enable mask, a pair-table programming port, the FLUSH
and SAT_CLEAR pulses, and the accumulator-protection status coming back as W1C sticky bits
plus a saturating event count.

The pair table is a PROGRAMMING PORT (index, X, Y, then a WRITE pulse) rather than N
registers, for the reason the coefficient window is one: a table sized by `N_PAIRS` would
make the generated, machine-readable register map depend on an elaboration parameter. The
block additionally checks its generated reset values and field widths against `covar_pkg`
at elaboration, because `control/regmap.json` and `rtl/packages/covar_pkg.sv` are two files
and two files drift.

Two consequences worth recording. `control_top` gains the block with its hardware inputs
tied off — the same arrangement, and the same reason, as the coefficient window (issue #7,
decision 5): control_top is the register plane's own test bench, and wiring a live
covariance engine into it would make a register-plane failure and a covariance failure
indistinguishable. And `test_control_regs` had `0x9000` in its "gap above the last declared
window" list; the gap moved to `0xA000` and the covariance window joined the
"inside an implemented window, past the last register" list instead.

**Decision 12 — `covar_pkg` exports its widths as functions as well as localparams.**
Same measured reason `stream_pkg` gives for its latency constants: `verilator --lint-only
--Wall` reports a package localparam that a given build happens not to reference as a dead
parameter, and this package is deliberately lintable one top at a time (`files_covar.f`,
`files_control.f`, `files.f`). The localparam remains the definition; the function's body
references it, which makes it "used" in every build, and a function is dead in none. Two of
those functions — `covar_window_max_exact` and `covar_acc_w_required` — are load-bearing
rather than cosmetic: they are decision 1's inequality, and the test checks them against an
independent C++ implementation at the bound and one past it.

**Decision 13 — a pre-existing defect in `sim-tiny` had to be fixed to run the gate.** The
`sim-tiny` recipe on `main` was missing the `$(BUILD_VERILATOR)` command word on the
`fft_top` fast build, so the line was passed to the shell as a bare
`--top fft_top --files ...` and the binary the recipe then ran had never been built:

```text
[sim-tiny] ===== seed 3 : test_fft =====
/bin/sh: 1: ./sim/verilator/build/fast_tiny_fft_top/Vfft_top_test_fft: not found
[sim-tiny] FAILED (seeds: 1 2 3)
```

`make sim-tiny` therefore failed on a clean checkout of `main` before any of this issue's
work existed. The fix is one line restored, and it is recorded here rather than folded
silently into this issue's diff because it means the issue #11 gate transcript was produced
by an invocation that has not been reproducible since it landed.

**Calibration.** SPEC §18 evidence for this kernel is deferred; the pull request states why
and what a sweep would measure. What the design DOES claim about mapping, and therefore what
a later sweep has to check, is written down where it can be falsified: `power_calc` states
that `I^2 + Q^2` should map to ONE DSP in sum-of-two-multipliers mode (the two products and
their sum are one combinational expression between two registers, and neither register has a
clock enable or a reset, which are the three things that stop the fold), and `covar_engine`
states that a pair costs one `complex_multiplier`. Both are measurements waiting to be made,
not results. Issue #10's decision 13 is the standing warning that applies here: lint clean
is not the same as synthesizable, and this kernel has not yet been through Quartus.

## 2026-07-25 — Beamforming matrix: the aligned-vector beat, one quantisation per beam, visible time multiplexing, a reused weight store  (issue #12)

Context: SPEC §7.5 asks for `Y[b] = sum_a X[a]·W[b][a]` over up to 16 antennas and 16 beams,
eight frequency bins per cycle, complex programmable weights with double buffering and safe
bank switching, a pipelined accumulation tree, saturation and overflow reporting,
parameterised multiplier implementation and parameterised beam and bin parallelism — and,
in its own paragraph, *"Do not silently reduce throughput to meet utilization. Any time
multiplexing must be visible in parameters and reported throughput."* SPEC §18 items 6 and 7
require one dot product and one complete beam to be synthesized and measured before
full-scale parameters are chosen. This is the third Phase 2 kernel and **the design's
dominant DSP consumer**: the numbers below are the ones issue #20's parameter freeze has to
be planned around.

**Decision 1 — the input beat is `BIN_PAR` aligned antenna vectors, and the alignment is
stated as a contract because nothing downstream can check it.** A beat's data field carries
`BIN_PAR` consecutive frequency bins, each as the *complete* vector of `N_ANT` complex
samples for that bin, bin-major and antenna-minor. With `BIN_PAR = 1` that is exactly "one
beat is one bin's antenna vector", which is what issue #16's frequency alignment network
will produce.

The word *aligned* is the whole contract, and it is the reason it is written down in
ARCHITECTURE.md rather than left to a diagram: a beamformer sums **across** the antenna
dimension, so a beat in which antenna 3 is one bin behind the others produces a result that
is not a beam **and is not detectably wrong from the output alone**. It is still a complex
number of plausible magnitude; it still saturates plausibly; it passes every protocol check.
There is no test this block can run on itself that catches a misaligned producer.

What the block deliberately does *not* require of #16 is as important: no particular bin
order (`bin_base` is positional, not decoded) and no relationship between frame length and
any parameter. Constraining either would push a beamformer parameter into the alignment
network for nothing.

*The cost is a very wide interface, and it is paid rather than hidden.* `BIN_PAR * N_ANT * 32`
bits: 1024 at the calibrated slice, **4096** at the `full_agmf039` 8-bin, 16-antenna
configuration. That is the widest interface in the design and it is intrinsic — an
alternative that presented antennas serially would need `N_ANT` beats of storage per bin
inside this block, which is the alignment network rebuilt in the wrong place.

**Decision 2 — one quantisation, at the end of the tree, and the cost of the alternative is
a measured number rather than an argument.** Every `complex_multiplier` runs with
`ROUND_OUT = 0`; the `N_ANT` exact 33-bit partial products are summed at
`bf_acc_w(N_ANT) = fxp_mac_q15_acc_w(2*N_ANT)` bits — 37 for 16 antennas — and rounded and
saturated **once**, at the output.

This is `fxp_pkg`'s accumulator policy applied literally, and the width makes the
accumulation provably unable to overflow, so there is **no intermediate saturation
anywhere**. Three things follow, and all three are load-bearing:

* integer addition is associative and nothing clamps in between, so the tree's *shape*
  cannot change its *answer*. That is what makes `ADD_REG_EVERY` a pure cost parameter and
  what lets one expectation list serve every engine in the verification top;
* the C++ model may sum antenna 0 upward while the RTL sums through a balanced tree, and the
  two are the same integer rather than merely close;
* rounding per antenna would buy **sixteen** rounding networks instead of one. Issue #9
  measured what one costs: `MULT4` at four stages is 102.0 kernel ALMs and 715 MHz with
  `ROUND_OUT = 1` against 1.2 kernel ALMs and ≥ 1302 MHz with `ROUND_OUT = 0` — about a
  hundred ALMs and roughly half the achievable clock per avoided rounding, plus double the
  quantisation noise.

*The output format is Q1.15 with saturation, deliberately not a wider "beam sample".* SPEC §6
fixes one sample format for the whole datapath, and everything downstream — the power and
covariance engine (#13), CFAR (#14), the packet payload — is written against Q1.15 complex.
A wider beam sample would make the beamformer the one block whose output nothing else can
consume without a converter, and the converter would round anyway. Saturation *is* a real
event here — the sum of `N` Q1.15 products reaches `N` in magnitude — so the programming
contract is that a weight row is normalised (`sum_a |W[b][a]| <= 1`), and a row that is not
produces a clamped sample and a direction-resolved flag rather than a wrapped one. A wrapped
overflow turns a strong beam into a strong beam of the opposite sign, which CFAR cannot
distinguish from a real target.

*The exact accumulator is exported anyway.* `bf_dot` presents `acc_re`/`acc_im` at
`bf_acc_w(N_ANT)` bits, unrounded and unsaturated. Nothing in this issue consumes it, but
issue #13 computes `|Y|²` and would otherwise square a value that has already been rounded
and clamped. It costs nothing when unused — it is the same wire the quantiser reads — and it
is the difference between a clean interface for the next kernel and a second copy of this
module.

**Decision 3 — time multiplexing is a first-class, reported property, not an implementation
detail.** When `BEAM_PAR < N_BEAMS` the engine computes the remaining beams on later cycles
from the same held input beat, in `BEAM_MUX = N_BEAMS / BEAM_PAR` groups. The full statement,
derived from the parameters rather than asserted:

```text
input  beats accepted per cycle  =  1 / BEAM_MUX
output beats produced per cycle  =  1
sustained bins per cycle         =  BIN_PAR / BEAM_MUX
arithmetic throughput            =  BIN_PAR * BEAM_PAR beam-bins per cycle   (invariant)
```

The last line is the substance: multiplexing trades **input rate for engine reuse** and
changes nothing else. All six numbers are exported on the block's `tput_*` ports, read back
through `WEIGHT_PARALLELISM` / `WEIGHT_THROUGHPUT` in the register map, and checked against
the elaborated parameters by the test — so SPEC §7.5's "visible in ... reported throughput"
is a readback rather than a comment. `beamformer_assertions` additionally checks the
admission rate on live traffic, so a build that admitted faster than the engine can serve
fails rather than silently dropping beams.

*`BEAM_MUX` is restricted to a power of two, and the restriction buys something specific.*
The output sequence number is `seq_out = {seq_in, group}`: a free concatenation, continuous
beat-to-beat (which `stream_protocol_checker`'s `a_seq_continuous` requires on the master
interface), and invertible by slicing, so a consumer recovers the input beat index and the
beam group. A non-power-of-two factor would need a multiply on the sequence field and would
break the slice.

*The output `user` field carries the beam group.* SPEC §12.5's transaction identity names
`beam` as a dimension and this is the only field it can live in; the bin dimension is
positional within the beat and needs none. Forwarding the input's `user` instead would leave
`beam` unexpressible. Output beat *k* is not "the same beat as" any input beat once
`BEAM_MUX > 1`, so this is a convention, and the precedent for stating one rather than
implying it is issue #11 decision 8.

**Decision 4 — the weight swap is aligned to the ISSUE of the first beam group, not to the
admission of the beat, and this was a real defect found by a multiplexed DUT.** The obvious
wiring drives the weight bank's `core_beat`/`core_sof` from `admit`/`s_fields.sof`, exactly
as `pfb_bank` does. It is wrong here, and only here, because of decision 3: with
`BEAM_MUX > 1` a new beat is admitted **on the same cycle** as the *last group of the
previous beat is issued* — that is precisely what sustains one beat every `BEAM_MUX` cycles.
Driving the bank from the admission therefore swaps the matrix one cycle early, and the
previous frame's final beat gets its last `BEAM_PAR` beams computed with the **next frame's**
weights.

The symptom is a frame beamformed with two different calibration solutions, on one beat per
frame, in beams nobody is looking at. It is invisible at `BEAM_MUX = 1`, where admission and
issue coincide — which is exactly why `sim/verilator/tops/beamformer_top.sv` elaborates a
multiplexed instance alongside the reference one, and why the swap pass found it on `mux2`
and on nothing else:

```text
ERROR [rtl_vs_model] swap.mux2 seq 1087 beam+0 bin 0: RTL (5863,4567) vs model (500,-554)
```

The fix — `core_beat = issue && (grp == 0)`, `core_sof = the held beat's sof` — also makes
the property *stateable*: the bank in use changes on the cycle the datapath first reads it
for the new frame, which is what `a_coeff_swap_at_sof` asserts.

**Decision 5 — `stream_pkg::STREAM_MAX_DATA_W` is raised from 256 to 1024, and not to 4096.**
Decision 1's beat is `BIN_PAR * N_ANT * 32` bits, so the SPEC §18 matrix calibration (2 bins,
16 antennas) needs 1024 and the full-scale configuration will need 4096. The bound is on the
*working type* the pack/unpack functions compute in, not on any instance's payload width.

The bound was raised rather than the calibration shrunk because the alternative is worse than
it looks. Quartus does not define the opposite of `SYNTHESIS`: with the bound left at 256 the
elaboration checks — which all live under `` `ifndef SYNTHESIS `` — are **absent from a
synthesis build**, and `stream_pack` would silently truncate the data field. Three quarters
of the beamformer's multipliers would then optimise away and the calibration would report a
resource figure for a block that does not exist. SPEC §24 forbids exactly that
("constant-driving unused inputs so large blocks optimize away"); a silent truncation is the
same defect arrived at by accident.

Not 4096, because the cost is linear and paid by everything: every pack/unpack in the design
computes in a `STREAM_MAX_PAYLOAD_W`-bit working type, so 4096 would be four times this
raise's simulation cost, paid by every block, for a geometry nothing yet verifies. **Measured cost of the raise from 256 to 1024: `make sim-tiny SEEDS=1` from a clean build directory went from 144 s to 152 s wall clock on this host — 5.6%, with every one of the eighteen test runs passing at both settings.** Raising it to 4096 belongs to the issue that builds the alignment network
producing such a beat (#16) and the one that freezes full scale (#20), with their own
measurement in hand.

**Decision 6 — the weight bank REUSES `rtl/pfb/coeff_bank.sv`; it does not reimplement it,
and it was not hoisted into `rtl/common/` either.** SPEC §7.5's "weight double buffering" and
"safe weight-bank switching" are, word for word, the requirement SPEC §7.1 places on the
polyphase coefficient store, and issue #10 built exactly that: a dual-bank store of
`P × T` complex Q1.15 words, written through a `cdc_handshake`, swapped by a `cdc_pulse` at a
frame boundary, with status synchronised back and a checker proving both properties. Nothing
in it is polyphase-specific — `PHASES × TAPS` is a two-dimensional index into a flat store,
and here it is `N_BEAMS × N_ANT`.

So `weight_bank` instantiates it and adds what is genuinely beamformer-specific: the SPEC
§7.5 bounds, the beam-major/antenna-minor index contract (checked at elaboration at the two
corners a transposed instantiation would hit), and a beamformer-named status surface for the
register map.

*The tidier refactor — hoist `coeff_bank`'s body into a `dual_bank_store` under
`rtl/common/` and make both a thin wrapper — was rejected for now, in the open.* It changes
no logic; it would move the SPEC §8 CDC inventory entry and the assertion names of a module
that is already verified and calibrated, for no functional gain; and issue #13 is in flight
against the same tree, so a mechanical refactor of a shared file is a merge hazard bought
with nothing. The honest cost is a naming seam — a file under `rtl/beamformer/` instantiating
a module under `rtl/pfb/` — and it is recorded rather than hidden. The moment to pay for the
hoist is when a **third** consumer appears; `control/regmap.json` already names issue #16's
per-antenna fan-out as one.

*The dividend is immediate:* `a_coeff_swap_at_sof` and `a_coeff_stable_between` hold for the
beam weights with no second copy to drift, and the negative test that proves the first one
can fire is the same mechanism issue #10 built.

**Decision 7 — swap granularity is the whole array, never per beam.** One `active_bank` bit
covers all `N_BEAMS × N_ANT` weights; a swap replaces the entire matrix atomically at a frame
boundary. Per-beam granularity — `N_BEAMS` independent bank bits and pending flags — was
considered and rejected:

* a beamforming matrix is a **calibration solution**, not `N_BEAMS` independent filters. The
  rows are computed together from one array-manifold estimate and a beam pattern is only
  meaningful relative to the others'. Half-swapped, the array steers to a geometry that was
  never solved for, and no downstream consumer could tell that from a real result;
* "which bank is active" is **one bit** in the register map. Per-beam makes it an
  `N_BEAMS`-bit field, makes `SWAP_REQ` a mask, and makes "the swap completed" a reduction
  software has to poll — a materially larger control surface bought to enable an operation
  nobody has asked for;
* the property that makes double buffering worth having — the active bank's contents never
  change except on the cycle the active bank changes — is stateable for one bank bit and
  becomes `N_BEAMS` separate properties for `N_BEAMS` bits.

The cost is that a single-beam update still costs a full spare-bank load. That is a software
cost, on a plane that is not in the datapath, and it buys an atomic matrix. If a later issue
needs incremental steering it should get a separate mechanism with its own name, not a
widened bank bit.

**Decision 8 — the independent oracle leg is a double-precision evaluation in C++, not a
committed NumPy vector set, and this is a deliberate departure from issues #4/#9/#10/#11.**
SPEC §12.4's problem is that an oracle agreeing only with itself is not an oracle, and the
C++ model shares `fxp_pkg`'s definitions with the RTL *by design*. Every non-saturating beat
is therefore also checked against `bf::dot_float()` — the same sum in doubles, through no
shared code — to within 2 output LSB.

Why no generator and no golden file: the beamformer is **stateless**. There is no history, no
schedule and no transcendental table, so a vector file would carry no information the weight
set and the input beat do not already carry — whereas an FFT vector pins a whole scaling
schedule and a PFB vector pins a tap ordering. The two error classes a vector file exists to
catch here are covered more directly: a *wrong algorithm* by the double-precision leg, and a
*wrong index* by the Hadamard orthogonality case and the SPEC §13.2 permutation relation,
both of which are expectations with no model in them at all. If a later issue makes the
beamformer stateful, this trade stops holding and a generator should be added with it.

**Decision 9 — a symmetric directed case cannot detect a transpose, and the fault injection
is what said so.** The oracle was proved to bite by transposing the weight index in
`beamformer.sv`. It fired on 41 472 model comparisons, 41 472 double-precision comparisons and
1 024 permutation-relation comparisons — but on **zero** directed comparisons, because the
unit-weight pass had been written as "beam *b* selects antenna *b*", which makes `W` the
identity: symmetric, and therefore unchanged by a transpose. The Hadamard pass is symmetric
too, by construction (`H[p][a]` depends only on `popcount(p & a)`).

The unit-weight pass was changed to a cyclic shift — asymmetric for every `N_ANT > 2` — and
the injection re-run to confirm it now fails as well. The lesson generalises and is recorded
because of it: **a directed case built from a symmetric matrix is blind to a transpose**, and
a transpose is the most likely defect in any matrix kernel. The permutation relation is the
check that does not depend on getting that right.

**Decision 10 — the adder tree is one signal per level, not one array indexed by level, and
the shape is forced rather than chosen.** Verilator's combinational-loop analysis works on
whole variables: with the whole tree in a single `node[c][l][i]` array, a level that feeds the
next one *combinationally* — which is exactly what `ADD_REG_EVERY > 1` asks for — makes the
array appear to depend on itself and the build fails with `UNOPTFLAT`.
`rtl/pfb/fir_lane.sv` keeps one array only because every one of its levels is registered, so
the loop is always broken by a flip-flop. Declaring each level inside its own generate scope
makes the dependency the acyclic chain it actually is, at the cost of one hierarchical
reference per level and no waiver.

### Measured calibration data (SPEC §18 items 6 and 7, seed 1)

Seed 1, `AGMF039R47B1E1VC`, Quartus Prime Pro 26.1.0 Build 110, probe constraint 600.24 MHz
— the same device, the same tool and the same deliberately-unreachable probe issues #9, #10
and #11 used, so all four sets of numbers are comparable. Four points, all successful. Full
records in `results/synthesis/calibration_bf_dot.json` and `calibration_bf_matrix.json`
(generated, not committed); per-point evidence, including the verbatim DSP and retiming
panels, under `results/synthesis/calibration/`.

| point | DSP | DSP mode | M20K | ALM (total / kernel) | ALUTs | regs (total / kernel) | Hyper (kernel) | Fmax MHz | depth | fit s |
|---|---|---|---|---|---|---|---|---|---|---|
| `bfdot_a16_reg1` | 32 | 32× sum of two 18×18 | 0 | 1234 / 651.2 | 1285 | 1478 / 1407 | 109 | 660.1* | 1 | 584 |
| `bfdot_a16_reg2` | 32 | 32× sum of two 18×18 | 0 | 1241 / 658.2 | 1295 | 871 / 800 | 231 | **460.0** | 2 | 581 |
| `bfmat_b2x4a16_reg1` | 256 | 256× sum of two 18×18 | 7 | 12146 / 11121.5 | 19086 | 19782 / 18658 | 128 | **413.9** | 3 | 1054 |
| `bfmat_b2x4a16_reg2` | 256 | 256× sum of two 18×18 | 7 | 9739 / 8715.6 | 13255 | 14109 / 12985 | 76 | **402.4** | 4 | 1053 |

`*` the register-to-register paths met the 600 MHz probe, so that Fmax is a lower bound
rather than a measured limit. Every other figure is a genuine measured limit. The worst
register-to-register path is **inside `u_kernel` for all four points**, so none of these
numbers is bounding the wrapper instead of the kernel; `scripts/run_calibration.py` records
that per point rather than leaving it for a reader to notice.

**The accumulation tree does not compete with the complex multiply for the DSP block's
adder.** Every point maps to exactly 2 DSP blocks per complex multiply in `Sum of Two 18x18`
mode — 32 blocks for a 16-antenna dot product, 256 for eight of them — which is issue #9's
mapping scaled linearly and completely unchanged by the 37-bit adder tree hanging off it.
That was the open question this kernel had to answer, because issue #10 found the *opposite*
result one level down: a systolic FIR buys no DSP cascade precisely because the complex
multiply has already consumed the block's adder. Here the tree is in fabric by construction
and the DSPs are untouched, so **DSP count is exactly `2 × N_ANT` per dot product and scales
exactly linearly**. That is what makes the full-scale projection below arithmetic rather than
extrapolation.

**The adder-tree pipelining answer INVERTS between the atom and the block, and that is the
most useful thing this sweep produced.**

At the dot product, `ADD_REG_EVERY = 2` is a disaster for Fmax: it saves 607 kernel registers
(43%), saves **no ALMs at all** (+7, i.e. the adders are the same adders), and costs
200 MHz — 660.1 down to 460.0, a 30% loss that lands it 2% above the SPEC §2 450 MHz target
with no margin. The retimer visibly tried: 231 Hyper-Registers against 109, and still
`Path Limit`.

At the block, the same axis costs **2.8%** of Fmax (413.9 → 402.4) and saves **22% of kernel
ALMs** (11121.5 → 8715.6) and **30% of kernel registers** (18658 → 12985). The reason is the
next finding: at block level the critical path is not in the tree at all, so shortening the
tree's pipeline stops mattering and only its cost remains.

**Neither block point clears 450 MHz, and the limit is the WEIGHT DISTRIBUTION NETWORK, not
the arithmetic.** `bfmat_b2x4a16_reg1`'s worst register-to-register path is

```text
u_kernel|u_weights|u_store|mem[0][25][18]
   -> u_kernel|g_bin[0].g_beam[1].u_dot|g_mult[6].u_mult|g_reg_in.b_q.im[6]
```

— the weight store's output, through the beam-group multiplexer, into a multiplier's operand
register — with the Fitter reporting `Insufficient Registers` rather than `Path Limit`, i.e.
the path is **register-starved and not logic-starved**. The `reg2` point's path moved
somewhere else again (`f_im_q.sat_pos -> u_sat_cnt|count_q[6]`, the saturation flag into the
telemetry counter), which is also not the arithmetic. The arithmetic itself clears 660 MHz.

This is exactly what `bf_matrix_wrap`'s header and `beamformer.sv` section 5 predicted would
be worth measuring, and it was predicted because issue #10 found the analogous cone — the
coefficient bank's `bank_sel` into a multiplier operand — on the critical path of a FIR lane.
Same shape, one level up, and now with a number.

**The structural answer, and why it is NOT made here.** A pipeline register between the
weight bank's output and the multiplier operand would break that path. It is not free and it
is not local:

* it costs `BEAM_PAR × N_ANT × 32` flip-flops — 2048 at this slice, **8192** at the full-scale
  16-beam configuration;
* it moves the weight-bank swap point. Decision 4 above aligns the swap to the *issue* of the
  first beam group precisely so the bank in use changes on the cycle the datapath first reads
  it; inserting a register in the weight path means the beat/`sof` pair driving the bank must
  move with it, or `a_coeff_swap_at_sof` stops describing the truth.

That is a timing-closure change with a functional blast radius, and SPEC §20 has a procedure
for exactly that kind of change — one hypothesis, the smallest defensible edit, correctness
re-proven, then a compile. It is deliberately **not** made in this issue, on the same
reasoning issue #11 recorded for the FFT's delay-feedback path: this issue's remit is to
produce the measurement that says which change to make, and this is it. **The number to beat
is 413.9 MHz, the path is named above, and the bit-exact model, the three-engine equivalence
and the permutation relation are what will prove the change did not alter a single beam.**

**The seven M20K at the block are the output elastic buffer, not the weight store.** Both dot
points report M20K = 0 and MLAB = 0: sixteen 32-bit weights are ALM registers. The 8 × 16 × 2
× 32-bit weight store is likewise not a memory. The seven blocks are the 280-bit output
payload at the credit-derived depth, which is the same thing issue #10 found at `pfb8` and the
same note applies — `stream_elastic_buffer`'s header still claims distributed registers "by
construction", and that claim is wrong at wide payloads.

**Decision 11 — `ADD_REG_EVERY = 1` is the shipped default, on measurement.** At the atom it
is 200 MHz better for 607 registers and zero ALMs. At the block the two are within 3% of each
other on Fmax while `reg2` is 22% cheaper — which would argue for `reg2` *if* the block's
limit were the tree. It is not: the limit is the weight path, and fixing that (above) will
move the block's Fmax back toward the arithmetic's, at which point the tree's own 200 MHz
gap starts to matter again. Shipping the configuration with the headroom, and re-measuring
the axis after the weight path is pipelined, is the order that cannot paint itself into a
corner. The parameter stays, the sweep entry stays, and issue #20 has both numbers.

### Full-scale DSP projection (SPEC §2, SPEC §18)

DSP scales **exactly** linearly and is measured at both levels (32 per 16-antenna dot
product at the atom, 256 for eight of them at the block), so this is arithmetic:

| configuration | dot products | DSP blocks | % of 12 300 | sustained bins/cycle |
|---|---|---|---|---|
| **16 beams × 8 bins/cycle × 16 antennas, `BEAM_PAR = 16`** | 128 | **4 096** | **33.3%** | 8 |
| 16 beams × 8 bins/cycle × 16 antennas, `BEAM_PAR = 8` (`BEAM_MUX = 2`) | 64 | 2 048 | 16.7% | 4 |
| 16 beams × 8 bins/cycle × 16 antennas, `BEAM_PAR = 4` (`BEAM_MUX = 4`) | 32 | 1 024 | 8.3% | 2 |

ALM, projected from the block point's kernel figure of 11121.5 for eight dot products
(1390 per dot product, which already includes an amortised share of the weight store, the
beam-group mux, the credit gate and the output buffer): **≈ 178 k ALM, ≈ 13.6% of
1 305 600**, at `BEAM_PAR = 16`. Treat that as a **lower bound**: the weight-mux part of it
grows with `N_BEAMS × N_ANT` and with `BEAM_PAR`, both of which double or quadruple from the
calibrated slice, and the calibration measured 8 beams and `BEAM_PAR = 4`.

**The headline for issue #20.** Against issue #10's measured polyphase projection of
**4 096 DSP (33%)** for 16 antennas, the beamformer at full parallelism is another
**4 096 DSP (33%)** — **8 192 of 12 300, 67%, before the FFT, the covariance engine or CFAR**.
SPEC §2 targets 75–90% total DSP utilisation, so the budget is not comfortable and it is not
hopeless: it is *tight*, and the beamformer is the single largest lever in it. `BEAM_PAR` is
that lever, its effect is exactly linear, and SPEC §7.5's insistence that time multiplexing be
visible in reported throughput is precisely so that pulling it is a recorded architectural
choice rather than a quiet reduction. The `WEIGHT_PARALLELISM` / `WEIGHT_THROUGHPUT`
registers exist to make the chosen point readable from a running device.

## 2026-07-26 — CFAR detector: a division-free threshold, suppression as the edge policy, a self-verifying detection event  (issue #14)

Context: SPEC §7.7 asks for a configurable one-dimensional CFAR detector over frequency bins
with, at minimum, cell averaging, a programmable guard-cell count, a programmable
reference-cell count, a programmable threshold multiplier, edge handling, detection metadata,
and detection suppression under invalid or incomplete windows. Greatest-of and
ordered-statistics CFAR are optional extensions. This is the fourth Phase 2 kernel; it
consumes the issue #13 power stream and the issue #4 numerics package, and it is the first
block in the design whose OUTPUT is an event rather than a sample — so several things settled
here are settled for the event aggregator and packet network (#18) as well.

**Decision 1 — the threshold comparison is DIVISION-FREE and therefore EXACT.** Cell-averaging
CFAR compares the cell under test against `alpha × (reference sum) / (reference count)`. The
mean is never computed. Writing `S`, `N`, `C` and `A = alpha · 2^F`:

```text
C > alpha·S/N   <=>   C > (A/2^F)·S/N   <=>   C·N·2^F  >  A·S
```

Both sides are exact integer products of quantities the datapath already holds: no divider,
no reciprocal table, no rounding, no tolerance. The consequence is not a convenience but a
verification property — the decision is a total order on integers, so the RTL and the C++
model agree bit for bit **by construction** rather than by comparison, and "bit exact" needed
no argument about rounding modes anywhere in this block.

Two closed forms fall out and are directed tests, because they are the cheapest available
checks of the whole arithmetic path. The comparison is STRICT, so an identically-zero
spectrum raises no detection at any alpha including zero (`0 > 0` is false), and a perfectly
flat spectrum raises none at alpha = exactly 1.0 (both sides are the same integer). One LSB
below 1.0 the same flat spectrum must detect *every* evaluable bin, which is what proves the
1.0 case was a boundary rather than a floor.

Widths: the left side reaches `2^55` and the right `2^63`, so the package's working type is an
UNSIGNED 64-bit — deliberately not `fxp_pkg::fxp_wide_t`, which is signed and one bit short.
`cfar_widths_ok()` elaborates that claim rather than asserting it in a comment.

**Decision 2 — alpha is UNSIGNED Q8.8, and that is a deviation from SPEC §6 with a reason.**
SPEC §6 fixes Q1.15 for samples and coefficients. Alpha is neither: Q1.15 represents only
`[−1, 1)`, and a CFAR threshold multiplier is essentially always greater than one — the
textbook design point `alpha = N(Pfa^(−1/N) − 1)` is ≈ 21.9 for 16 reference cells at
`Pfa = 1e−6` and ≈ 25.6 for 32 cells at `1e−8`. **A format that cannot express 21.9 cannot
express the design point.**

Q8.8 keeps the 16-bit width the rest of the numeric plane uses — one register field, one
16-bit multiplier operand — and covers `[0, 255.996]` in steps of 1/256. The precision claim
is quantified rather than asserted: one LSB at the design point is a relative threshold step
of 1.8e−4, i.e. 0.0016 dB, against integrated powers whose own standard deviation is 1/√N of
the mean — 1.9 dB for a 16-sample non-coherent integration. The quantisation is three orders
of magnitude below the statistical spread of the thing being thresholded, so fractional bits
beyond eight would buy nothing measurable. At the other end, alpha = 256 is a 24 dB threshold,
past any useful operating point. Alpha below 1.0 is legal and useless operationally, and it is
the cheapest way for a test to force detections everywhere, so it is defined rather than
excluded.

**Decision 3 — the edge policy is SUPPRESS, and the two alternatives are rejected for reasons
that are about the detector's defining property.** A bin whose complete programmed window does
not lie inside the frame raises no detection and is counted as suppressed.

*Shrinking* the window at the edges gives those bins a different reference-cell count, hence a
different noise-estimate variance, hence a different false-alarm rate. A detector whose Pfa
varies by bin is not a CONSTANT-false-alarm-rate detector, and the variation is largest exactly
where it cannot be calibrated.

*Mirroring* invents data. A target near bin 0 is mirrored into its own reference window and
raises the threshold that is supposed to detect it — the classic self-masking failure — and
the mirrored cells are perfectly correlated with the real ones, which breaks the independence
the threshold multiplier is derived from.

SPEC §7.7 asks for "detection suppression under invalid or incomplete windows"; suppression is
that requirement, and the other two are ways of pretending the window is complete. The same
rule covers every other incomplete case with no special branches: a frame shorter than the
window, a disabled block, and a reference geometry the selected mode cannot use.

The price is stated rather than hidden. At the SPEC §11 tiny geometry — 64 bins, 2 guard and 8
reference cells per side — **20 of 64 bins yield no detections**, and that is the reason the
guard and reference counts are runtime registers rather than compile-time constants. Every
suppressed bin is counted, per frame in the summary event and cumulatively in
`CFAR_SUP_COUNT`: a detector that quietly declines to look at a third of the spectrum is a
defect, one that says how many bins it declined to look at is a design.

**Decision 4 — greatest-of is ONE comparison, not two, and that is what makes the event
self-consistent.** GO's noise estimate is `max(S_lead/N_lead, S_lag/N_lag)`. The obvious
implementation is the AND of two independent threshold tests, which is correct and needs two
full comparators. Selecting the larger MEAN first instead — one cross-multiply of a sum by a
6-bit count, `S_lead·N_lag ≥ S_lag·N_lead` — reduces GO to a single instance of decision 1's
comparison, shared with cell averaging.

The resource argument is the smaller half of it. The real reason is that the emitted event
then carries the `noise_sum` and `ref_count` the decision ACTUALLY used, so a consumer can
re-run the comparison on the event's own fields and reproduce the detector's answer exactly
(decision 6). An AND of two comparisons has no single (S, N) pair to report, and the event
would have had to carry both sides or none.

Ordered-statistics CFAR is not implemented. It needs a rank-order network over the reference
cells rather than a sum — a different structure and a different cost class — and SPEC §7.7
lists it as optional. The mode field is two bits with two values used, so adding it later is a
named addition rather than a magic 2.

**Decision 5 — the reference sum is a MASKED TREE over every slot, not a variable-offset
selection, and the reason is correctness rather than area.** A selection of `R` cells starting
at a runtime offset puts a `(2D+1)`-to-1 multiplexer in front of every adder input, with the
guard count as the select — a register-plane value on the critical path of the widest datapath
in the block. The masked form puts a 7-bit two-bound comparator on each slot instead, off the
datapath, gating an adder input.

The cost is that the tree is always `2D+1` wide rather than `2R`. The honest alternative is a
RUNNING sum, one add and one subtract per advance, O(1) instead of O(D) — and it is not used
here because a running sum carries state across bins, so a geometry change, a frame boundary
or an edge-suppressed bin has to unwind that state exactly, and each of those is a case where
the sum can silently drift from the cells it claims to be over. The masked tree recomputes
from the register file every cycle and has no state to drift. Adopting the running form is a
SPEC §18 measurement away, and its gate is this block's own tests continuing to pass against
the same model.

**Decision 6 — the detection event is 176 bits, configuration-independent, and
self-verifying.** ARCHITECTURE.md §6.4 is the normative statement; `cfar_pkg` is the
definition. Three properties are load-bearing for the issue #18 packet network:

*Configuration-independent.* Every field width is a constant of the package, none is an
elaboration parameter. A packet format that changed with the FFT size would have to be
renegotiated at every SPEC §11 size.

*Self-verifying.* `(cut_power, noise_sum, ref_count, alpha)` are exactly the four operands of
decision 1's comparison, so a consumer re-runs `C·N·2^8 > A·S` on the event's own fields and
reproduces the detector's answer bit for bit — no division, no floating point. That is why
alpha rides in the event rather than being read from the register plane: an event stays
verifiable after the register changes.

*A sum and a count, not a quotient.* The detector never divides, and adding a divider purely
to fill in a metadata field would put the only inexact operation in the block on the reporting
path. A consumer that wants the mean computes it; a consumer that wants to CHECK the detection
does not need it.

Exactly one SUMMARY event is emitted per input frame and it is the beat carrying
`end_of_frame`, so a frame with no detections is a well-formed one-beat output frame with both
boundary bits set. The aggregator therefore never has to distinguish "no detections" from
"frame lost", and `CFAR_FRAME_COUNT` and the number of `eof` beats are the same number.

**Decision 7 — the output sequence number is PER BEAM, not global.** SPEC §5 requires the
sequence field to permit end-to-end loss and ordering checks, and
`sim/assertions/stream_protocol_checker.sv` enforces exactly that: the field must increment by
one per beat WITHIN a `stream_id`. A single global counter looks continuous only while one
beam is running; interleave two beams' frames and every frame boundary becomes an apparent
discontinuity — a false loss report on the one signal a consumer uses to detect real loss. The
table costs `2^STREAM_ID_W` words of `SEQ_W` bits, is read at a frame boundary and written on
each emitted beat, and it was added because the protocol checker on the detector's own output
buffer would otherwise have fired.

**Decision 8 — configuration latches at a START-OF-FRAME beat, which is stricter than the
covariance engine's window-boundary rule, for a stronger reason.** Issue #13 decision 6 latches
at a window boundary because the integrator's window is the natural unit. Here the reference
window spans `2D+1` BINS, so a geometry change timed anywhere inside a frame would be evaluated
against cells admitted under the old geometry for the following `D` bins. There is no instant
at which the window is empty except a frame boundary, so a frame boundary is the only honest
place to switch — and it is also the only way a per-frame suppression count, a per-frame
detection count, or the alpha carried in an event mean anything.

`a_cfar_cfg_frame_boundary` asserts that the active copy changes only on the cycle after an
admitted start-of-frame beat. `CFAR_STATUS.CFG_PENDING` reports that a write is waiting, so
software watches its change retire rather than inferring it. A count above the elaborated
maximum is CLAMPED and flagged: out of range is defined rather than undefined, for the reason
`covar_engine` gives for its source selector — a register plane can be programmed with
anything, and "X" is not a behaviour.

**Decision 9 — a start-of-frame beat cannot arrive while a frame is open, and that is
STRUCTURAL rather than an error case.** `s_ready` is driven from the NEXT state, so it falls on
the cycle after `end_of_frame` is admitted and does not rise again until the block is idle. A
source obeying SPEC §5's "hold payload and metadata stable while stalled" loses nothing, and
the block acquires no branch for interleaved frames and no way to half-abandon one. The
alternative — accepting the beat and then reconciling two open frames — is where a detector
acquires a rare, ordering-dependent wrong answer.

The residual cases are still defined and counted rather than ignored: a beat outside a frame
with no `start_of_frame` is consumed and DISCARDED (`CFAR_FAULT.ORPHAN_BEAT`) because stalling
would back pressure into the FFT; a stray `start_of_frame` on a mid-frame beat is IGNORED and
the beat treated as an ordinary bin (`CFAR_FAULT.SOF_IN_FRAME`); a negative input power is
clamped to zero (`CFAR_FAULT.NEG_INPUT`), because a negative "power" can only be an upstream
defect or a cross-power stream wired here by mistake, and sign-extending one into the
comparison would turn that mistake into a plausible-looking detection.

**Decision 10 — the credit bound is sized against the PIPELINE, not against the window, and
the first version that was not deadlocked on the first frame.** The initial scheme reserved one
output slot per admitted beat. Its arithmetic was correct in total — every reservation was
eventually returned — and what it got wrong was the LATENCY between taking one and returning
it: a beat's decision does not retire until `D` advances later, so outstanding reservations
grow to `D + pipeline` before the first comes back. With an eight-deep buffer and `D = 10` the
block stopped accepting after six bins and never produced the end-of-frame summary that would
have released them.

The rule now is one line: an ADVANCE is allowed only while the free-slot count is at least
(pipeline stages + 1). Let `F` be the number of in-flight decisions that may still push;
`F ≤ 4`, so gating on `credits ≥ 5` maintains `credits ≥ F`, and a decision that reaches the
push point always finds a slot. The end-of-frame flush is made STALLABLE for the same reason —
its advances come from this block's own state machine, so they simply pause. The buffer depth
is then independent of the window geometry, which matters: at full scale `D` is 36, and a
buffer sized to cover it would be an M20K's worth of storage bought to solve an accounting
problem. `a_cfar_out_never_blocked` is the argument, checked every cycle.

**Decision 11 — the C++ model is FUNCTIONAL, not cycle-accurate, and that is a departure from
issue #13 with a reason.** `covar_model.hpp` is stepped once per clock edge because its subject
is window timing. The CFAR detector's subject is the detection arithmetic and the event
sequence; its pipeline depth is an implementation choice SPEC §23 explicitly invites changing
for timing closure. A cycle-accurate model would have to be edited every time a register is
added to the datapath — and each such edit is an opportunity to make the model agree with a
bug. Modelling the frame → event-sequence function instead makes the oracle invariant to
pipeline depth, to backpressure and to the phantom-flush mechanism, while staying exact on
every value and every ordering: the detection set is compared bin for bin, every field of every
event is compared, and the ORDER is compared.

The one thing the model deliberately does not predict — which cycle an event appears on — is
checked structurally instead: the same stimulus under randomized input gaps and output stalls
must produce a byte-identical event sequence. That is a stronger statement about the pipeline
than any single predicted latency would have been.

**Decision 12 — `cfar_pkg` names its integer type `cfar_uint_t`, and the event's power field is
`cut_power` rather than `cell`.** The first is issue #10 decision 9 applied a fourth time:
`fxp_pkg`, `stream_pkg` and `covar_pkg` each export a `uint_t`, and a name visible via two
wildcard imports is ambiguous under IEEE 1800 §26.3 — Quartus Prime Pro rejects it outright and
Verilator accepts it silently.

The second is a NEW portability trap, found the same way and worth recording: **`cell` is a
Verilog-2001 configuration keyword.** Verilator 5.020 rejects it as a struct member, as a
function argument and as a field access, with `Unsupported: Verilog 2001-config reserved word
not implemented: 'cell'` — nineteen errors from one identifier. It is a natural name in a
CFAR ("the cell under test"), which is exactly why it is worth writing down: the trap is that
the most idiomatic word for the subject of this block is reserved. The field is `cut_power`
and the function argument is `cut`.

**Decision 13 — the SPEC §9 group "CFAR settings" gets a real window, at 0x6000.** The window
was already reserved and claimed two groups; "Integration settings" is implemented by the
covariance window at 0x9000 (issue #13, decision 11), so this window now claims only "CFAR
settings". `rtl/control/reg_block_cfar.sv` implements it: enable, mode, output mode, the four
geometry counts, the threshold multiplier, the `STATUS_CLEAR` pulse, hardware-reported geometry
(the elaborated maxima, the alpha format, and the event widths so a packet decoder needs no
build-time header), the sticky fault bits as W1C, and three saturating counters. The block
checks its generated reset values and field widths against `cfar_pkg` at elaboration, because
`control/regmap.json` and `cfar_pkg.sv` are two files and two files drift.

Two consequences worth recording. `control_top` gains the block with its hardware inputs tied
off — the same arrangement, and the same reason, as the coefficient and covariance windows
(issue #7, decision 5). And `CFAR_STATUS.ALPHA_FRAC_W` is driven by a PORT rather than by
`cfar_pkg` directly, which was not the first implementation: a hardware-driven field whose
value comes from a package reads non-zero in `control_top`, and `test_control_regs` predicts
every response from the generated tables alone. A block that puts a constant where the plane's
model expects a tied-off hardware input is a register-plane failure with a CFAR-shaped cause.

**Calibration.** SPEC §18 evidence for this kernel is deferred; the pull request states why and
what a sweep would measure. What the design DOES claim about mapping, and therefore what a
later sweep has to check, is written down where it can be falsified: `cfar_window` states that
the reference sum is a `2D+1`-input adder tree per side whose comparators are off the datapath,
so the block should cost adders and comparators and **no DSPs at all** except the three
multipliers of the comparison (`alpha × sum` at 16 × `SUM_W`, `cell × N` at `POWER_W` × 7, and
the greatest-of cross-multiply at `SUM_W` × 6); and `cfar_core` states that the window register
file is `(2D+1) × (POWER_W + BIN_W + 1)` bits of distributed registers, 1 197 bits at the tiny
geometry and 4 161 at the SPEC 11 full-scale geometry, which is where a running-sum
rewrite (decision 5) would start to pay. Both are measurements waiting to be made, not results. Issue #10's decision 13 is
the standing warning that applies here too: lint clean is not the same as synthesizable, and
this kernel has not yet been through Quartus.

---

## 2026-07-26 — Time-frequency history and corner turn: banking, rotation, the read contract  (issue #15)

**Context.** SPEC §7.3 asks for a banked memory that stores FFT frames by antenna, time and
frequency, takes continuous writes, serves beamformer reads by common frequency bin, keeps a
programmable history depth in multiple independently addressable banks with double buffering
or rotating frame banks, avoids a single globally broadcast address and enable network, and
exposes occupancy, overwrite, collision and error counters. SPEC §8 puts the read side in its
own `history_clk` domain. SPEC §18 item 8 asks for one M20K history bank to be swept before
full-scale parameters are frozen. The block sits between the FFT (#11) and the frequency
alignment network (#16), so its output contract is #16's input contract.

**Decision 1 — the bank dimension is the ANTENNA, and the memory performs the corner turn.**
`BANK(a, l) = a * LANES + l`, where `l` is the sample's position in the arriving beat.
`N_ANT × LANES` banks, each `FRAMES_MAX × BEATS_PER_FRAME` words of one complex sample.

This is the whole design and everything else follows from it. A write touches one bank per
lane and those banks belong to one antenna, so two antennas can never contend — **writes are
collision-free by construction rather than by arbitration**, which is why `s_ready` is tied
high and the ingest is full rate with no arbiter, no queue and no condition under which a
beat cannot be taken. A read of bin `b` enables one lane's bank in every antenna, and each
returns the same bin for a different antenna: that is the antenna vector, assembled in one
cycle, with no multiplexer and no transpose.

*Consequences.* Read bandwidth is one bin per cycle against a write bandwidth of `LANES`
bins per cycle per antenna, because `(LANES-1) × N_ANT` banks are idle on any read cycle.
That headroom is real — the banks are independent, so up to `LANES` bins could be served per
cycle if they fell on distinct lanes — and it is deliberately not spent here: giving #16 a
wider but lane-CONSTRAINED port would push the constraint into its scheduler and make the two
blocks' correctness joint. The address algebra already supports it unchanged.
*Alternatives rejected:* a transpose buffer, or a write crossbar. Both buy read flexibility
by making the ingest stallable, and a stalled ingest back-pressures the FFT and ultimately the
front end, which is exactly what "supports continuous writes" forbids.

**Decision 2 — the address is `{slot, beat}`, and the corner turn costs no arithmetic.**
`FRAMES_MAX`, `FFT_SIZE` and `LANES` are all required to be powers of two, so
`ADDR(s, k) = s * M + k` is a concatenation rather than a multiply, and the read-side decode
`lane = b / M`, `m = b % M` is two bit slices rather than a divider and a modulo. The
run-time `DEPTH` is deliberately NOT constrained to a power of two — the modulo lives on the
write path's own counter, where it is a compare-and-reset.

This is only free because of what issue #11 already chose. `fft_core` emits
`beat k, slot q = X[q*M + m]` — the two slots of a beat are half a spectrum apart, not
adjacent, because that let #11's reorder buffer be two banks read at one address. The
consequence here is stronger: **the slot index is the high bits of the bin and the beat index
is the low bits**, so the inverse mapping is a slice in both directions.

**Decision 3 — the bit-reversal is absorbed here, and the recommendation to #17 is to spend
it.** `INPUT_BIT_REVERSED` changes the read address decode from `b % M` to `bitrev(b % M)` —
a wire permutation — and changes the write side not at all, because positional lane
assignment means the write side never needs a bin index. Issue #11's sweep priced its reorder
stage at **+170 ALMs, +4 M20K, +7 MLAB, −7.6 MHz and one frame of latency** (issue #11,
finding 4). Absorbing it deletes all of that and adds nothing.

*Consequences.* Both settings are elaborated and verified against the model, and DUT 1 of
`history_top` runs bit-reversed with `LANES = 2` so the two mechanisms are exercised
together. The parameter is not hard-wired, because the choice couples two blocks and belongs
to the issue that owns both (#17); what this entry leaves #17 is a position and a number
rather than a question.

**Decision 4 — overwrite-oldest, unconditionally, with exact bookkeeping.** A history that
stalled its own ingest to preserve old frames would back-pressure the front end, which in a
radar pipeline is a worse failure than losing the oldest frame. What the block owes instead
is arithmetic that is exact at every instant, and the C++ model asserts all of it:
`occupancy = min(frames_done, DEPTH)`, `overwrite = max(frames_done − DEPTH, 0)`.

**Decision 5 — a frame is complete only when EVERY antenna has finished it, computed as a
barrier.** `frames_done` advances when every antenna's frame counter differs from it, which
for monotone counters is exactly the minimum and costs `N_ANT` equality comparators instead
of `N_ANT−1` magnitude comparators. It moves once per frame, not once per beat, so it is off
the datapath. Skew is COUNTED rather than assumed away: an antenna running a whole depth
ahead of the barrier is about to overwrite a live slot, and `HISTORY_SKEW` counts it — **on
the rising edge of the condition, not while it holds**, because skew is an episode and a
level count would report a number that depends on how long a test happened to leave the
antennas apart, which no reference model can predict.

**Decision 6 — the readable set is `min(frames_done, DEPTH − 2)`, and the second excluded
slot is the interesting one.** The first is the frame being written. The second absorbs one
frame of PUBLICATION LAG, and getting this wrong is a defect the collision counter cannot
see.

The reader works from a pointer that crossed a handshake. Between the writer finishing frame
`F` — which makes the pointer read `F+1` — and the read domain seeing `F+1`, the writer is
already filling `slot(F+1)`. A reader still working from `frames_done = F`, allowed the full
`DEPTH−1` offsets, addresses exactly `slot(F+1)` at its maximum offset. It reads the slot
being written, gets a frame that is half one and half another, and **the collision test does
not fire, because it is made against the same stale pointer**. Excluding one further slot
moves the maximum-offset request to `slot(F+2)`, which the writer reaches only after two more
frame completions.

*Consequences.* One frame slot is spent, and it is the honest price of putting the read side
in its own clock domain. A programmed depth of 1 or 2 leaves nothing readable — legal,
reported through `HISTORY_STATUS.OCCUPANCY` and the out-of-range flag, and tested. The
one-frame margin is checked rather than assumed by `a_history_publication_fresh`, because a
future configuration with a frame shorter than a handshake round trip would break it as
unexplained corruption at maximum frame offset, which is the least diagnosable failure this
block has. Every geometry `history_top` builds keeps `BEATS_PER_FRAME ≥ 32` for that reason.
*This decision came from reasoning about the crossing, not from a failing test* — the
`DEPTH−1` bound would have passed every test in the suite at every clock ratio tried, which
is precisely why it is written down here.

**Decision 7 — the publication bundle crosses as ONE handshake, not as a Gray pointer.** The
read side needs `{frames_done, done_slot, depth, readable, force_unsafe}` to agree with each
other. Gray coding is valid for a single monotone counter: it guarantees that a value sampled
mid-change resolves to the old or the new value of *that* counter, and says nothing about two
counters sampled together. A reader that took `done_slot` from after a depth change and
`depth` from before it would compute a slot belonging to neither configuration, silently.
`cdc_handshake` transfers the whole bundle as one payload that never passes through a
synchroniser — the case SPEC §8's multibit prohibition explicitly carves out. The same
argument applies in the other direction to the three read-side counters, which cross together
as 96 bits so a reader can never mix two snapshots.

*Consequences.* The cost is latency, and it is bounded: the publisher re-offers whenever the
bundle changes and the crossing is idle, so the read side is never more than one handshake
behind, against a frame of at least 32 core cycles. Three crossings in total, one per SPEC §8
mechanism (handshake, pulse, handshake), all through `rtl/cdc/` primitives.

**Decision 8 — the collision counter is made reachable by fault injection, because a counter
that cannot fire is a counter nobody has tested.** In correct operation `HISTORY_COLLISION`
is identically zero: the readable set excludes the in-flight slot by construction, so it is a
defect detector rather than a statistic. `HISTORY_CTRL.FORCE_UNSAFE` removes the readable-set
clamp so an out-of-range request reaches the slot being written, the counter increments, and
the C++ model predicts the count exactly. It is a SPEC §9 fault-injection field, not a mode
for production use.

**Decision 9 — the read response carries its metadata INSIDE the SPEC §5 `data` field.**
`data = {meta, ant[N−1] … ant[0]}` with antenna 0 at bit 0 and `meta = {flags, frame_id,
frame_off, bin}` above the vector. Metadata does not fit `user` and `stream_id` (`bin` alone
is 10 bits at `FFT_SIZE = 1024` against `STREAM_MAX_USER_W = 8`), and a sideband bus
qualified by `valid` would be a second interface with none of SPEC §5's protocol checking.
`meta` sits above the vector so that widening the antenna count moves no antenna's offset.

*Consequences.* Issue #16 strips `meta` when it assembles beamformer beats — which it must do
anyway, because it re-groups bins — and antenna 0 at bit 0 with `{im, re}` packing means the
`BIN_PAR = 1` case of `beamformer_pkg`'s input layout falls straight out. `frame_id` is
ABSOLUTE, and it is what lets a consumer detect that a rotation overtook a long-lived
request; `frame_off` alone cannot express that. The flags are additionally mirrored into
`user`, so a monitor that decodes only the SPEC §5 bundle still sees them, and the test
checks the two statements against each other.

**Decision 10 — a depth change DISCARDS the history, at a frame boundary.** Changing `DEPTH`
remaps every frame slot, so every stored frame is at an address the new mapping reads as a
different frame. There is no reinterpretation that preserves the data. The apply therefore
waits until no antenna is mid-frame and then restarts empty, bumping `HISTORY_STATUS.EPOCH`
so software can tell "no frames yet" from "frames from before a reconfiguration".
*Alternative rejected:* a change that may only GROW the depth, which can preserve data but
only between powers of two, and which makes the set of legal transitions a table nobody will
read.

**Decision 11 — the SPEC §9 window is at `0xA000`, claiming "Active bank selection" and
"Frame counts".** Both are literal: the rotating frame-bank pointer with its programmable
depth, and the completed-frame counter that decides what a read may ask for. The window
claims no group of its own because `scripts/gen_regmap.py`'s `SPEC9_GROUPS` is a verbatim
copy of SPEC §9's list and has none for a memory; adding one would make the copy stop being a
copy. Every register is in `core_clk`, the write side, because that is where the rotation
policy lives. `0xA000` was the first free window; `regmap_version` goes to 1.6.0, and
`test_control_regs`' "gap above the last declared window" probe moves to `0xB000`.

**Decision 12 — `history_pkg` names its integer type `hist_uint_t`, and avoids `time` and
`table`.** The first is issue #10's decision 9 applied a fifth time: `fxp_pkg`, `stream_pkg`,
`covar_pkg` and `cfar_pkg` each export a `uint_t`, and a name visible through two wildcard
imports is ambiguous under IEEE 1800 §26.3 — Quartus rejects it outright and Verilator
accepts it silently.

The second is the same class of trap issue #14's decision 12 records about `cell`, and worth
recording because this block's subject matter walks straight into it: **`time` and `table`
are both SystemVerilog keywords**, and both are the most natural word for something this
block owns — the time axis, and the frame-slot table. The time axis is spelled `frame` and a
lookup is spelled `map`.

**Decision 13 — every geometry helper in `history_pkg` is guarded by `hist_geom_ok(g)`.** Two
things fall out, one of them mechanical. A derived quantity is only DEFINED for a legal
geometry, so an illegal one yields a benign 1 rather than a plausible number that propagates
into a port width. And the guard reads every field of the struct, which is what makes each
function a total use of its argument: without it `verilator --lint-only --Wall` reports
UNUSEDSIGNAL on the unread fields of every helper that needs two of five — thirteen warnings,
one per accessor. The alternatives are worse: loose scalar arguments reintroduce the "four of
five, correctly" defect the struct exists to prevent, and a file-wide UNUSEDSIGNAL waiver
silences the rule everywhere else in the package too. The cost is zero — every call site is
an elaboration-time constant.

A related mechanical note, recorded because it will recur: **a package `localparam` that the
elaborated hierarchy never reads is reported as UNUSEDPARAM**, and `files.f` lists
`history_pkg.sv` for a top that does not yet instantiate `history_core`. `stream_pkg` and
`cdc_pkg` solve this by exporting functions instead of localparams. This package needs two of
its constants in port declarations, so it keeps them and gives each one a reader inside the
package (`hist_port_fits`, `hist_req_meta_w`) — both of which a caller wanted anyway.

**Decision 14 — the SPEC §14 property set is TWO single-clock checkers, not one straddling
both domains.** `scripts/cdc_inventory.py --strict` reports any instantiated module with two
clock-like ports and no `(* cdc_primitive *)` tag, which is the correct default. Tagging a
checker would put a crossing in the SPEC §8 inventory that does not exist in the hardware,
and an inventory with an imaginary entry is worse than one with a missing entry. Every other
checker in `sim/assertions/` takes a single `clk` for the same reason.

The two prohibitions SPEC §7.3 states as bans on NETS are checked as the consequences a
broadcast design could not produce: `c_history_write_enables_differ` covers a cycle in which
the antennas disagree about writing, and `a_history_lane_onehot0` requires that at most one
lane's banks are read-enabled. A design that regressed to a broadcast net would fail the
cover, not merely look different.

**Decision 15 — `history_bank` is tagged as a CDC primitive with `cdc_stages = "0"`.** The
bank has two clock ports, so the inventory would report it either way; what the tag adds is
the honest value. A `history_bank` contains no synchroniser, and nothing in it makes it safe
to read a word while it is being written. What makes the design safe is the tagged pointer
crossing and the readable-set bound derived from it. The inventory therefore shows a
zero-stage bulk path guarded by a tagged pointer crossing, which is the actual architecture
rather than a reassuring omission. The same tag is what licenses `no_rw_check` on every M20K
in the subsystem, and `a_history_no_safe_collision` is the property that discharges it.

**Verification.** `sim/tests/test_history.cpp`, nine passes over three geometries and five
core:history clock ratios including 9:8 and 8:9 — the SPEC §8 constraint pair and its
inverse, added locally rather than to the shared `clock_ratios.h` table so that every other
CDC test in the suite does not grow two ratios it has no reason to want. What is predicted
EXACTLY is everything in a quiesced phase: every sample, every flag, every metadata field and
all six counters, over more than two full rotations of the buffer. What is predicted BY
IDENTITY is the concurrent phase, where full-rate writes run with reads in flight: the
response's absolute `frame_id` and `bin` are fed back into the pure stimulus generator, so a
wrong bank, a wrong slot, a wrong lane or a stale pointer all land as a mismatch, while the
frame the pointer happens to be on is not predicted — that is a function of the clock ratio,
and SPEC §12.5 forbids assuming it.

The fault-injection proof required by the gate: swapping the read bank-select from the high
bin bits to the low ones produced a wall of `data` mismatches on the `LANES = 2` geometry
within one second of simulation, at `9to8_core_fast`, each naming the bin, the frame, the
antenna and both values. Reverted, the suite passes on seeds 1, 2 and 3 in 1.6 s each.

**Calibration.** SPEC §18 item 8 is `make calibrate-history`:
`quartus/calibration/history_bank_calib` sweeps one bank at three aspect ratios of the SAME
16 384-bit capacity (512×32, 1K×16, 256×64) plus a no-input/output-register point, and
`history_core_calib` prices a four-bank slice reached two ways (4 antennas × 1 lane, and
2 × 2 bit-reversed) so the block's fixed cost is the difference between them rather than an
argument. The extraction was extended for this sweep, because the existing path recorded M20K
and MLAB BLOCK COUNTS and no memory BITS — which cannot distinguish one M20K used at full
occupancy from one used at a twentieth, and that is precisely the question a geometry sweep
asks. `calibrate.tcl` now also captures the Fitter RAM Summary panel verbatim as `ram.txt`
and samples `-src_unregistered_ram`, which is the closest thing this repo has to a
purpose-built "were the RAM registers absorbed into the hard block?" measurement — SPEC §23's
rule for M20Ks, and one of SPEC §18's seven named axes.

### Measured calibration data (SPEC §18 item 8, seed 1)

Seed 1, `AGMF039R47B1E1VC`, Quartus Prime Pro 26.1.0 Build 110, probe constraint 600.24 MHz —
the same device, the same tool and the same deliberately-unreachable probe that issues #9,
#10, #11 and #12 used, so all five sets of numbers are comparable. 6 successful points. Full records in
`results/synthesis/calibration_history_bank.json` and `calibration_history_core.json`
(generated, not committed); per-point evidence, including the verbatim RAM Summary panel, under
`results/synthesis/calibration/`.

### One M20K history bank — SPEC §18 item 8

Three of the four points hold the logical capacity constant at **16 384 bits** and vary only
the aspect ratio, so the block count is a measurement of packing and of nothing else.

| point | geometry | M20K | RAM bits | MLAB | ALM (total / kernel) | regs | Hyper | Fmax MHz | fit s |
|---|---|---|---|---|---|---|---|---|---|
| `bank_512x32` | 512 × 32, one complex sample per word | **1** | 16 384 | 0 | 111 / 13.7 | 141 | 34 | 956.9\* | 555 |
| `bank_1024x16` | 1K × 16, half a sample per word | **1** | 16 384 | 0 | 104 / 10.2 | 97 | 18 | 905.8\* | 457 |
| `bank_256x64` | 256 × 64, two samples per word | **2** | 16 384 | 0 | 126 / 21.2 | 233 | 66 | 824.4\* | 471 |
| `bank_512x32_noreg` | 512 × 32, `IN_REG = OUT_REG = 0` | 1 | 16 384 | 0 | 101 / **0.5** | 56 | 2 | 858.4\* | 460 |

`*` every bank point MET the 600 MHz probe (slack +0.62, +0.56, +0.45, +0.50 ns), so these
Fmax figures are lower bounds rather than measured limits. The worst register-to-register path
is inside `u_kernel` for all four. No DSPs, no MLABs, `unregistered_ram_paths = 0` everywhere.

**Finding 1 — aspect ratio is free until it is not, and the cliff is depth, not width.**
512 × 32 and 1K × 16 both cost exactly one M20K for the same 16 384 bits: Quartus reshapes the
array into whichever native mode fits, and the two are the same memory seen from two
directions. **256 × 64 costs two blocks for the same capacity** — 8 192 bits in each, 40 %
occupancy — because 64 bits exceeds the widest native word and the array is split across two
blocks that each use half their depth. Shallower-and-wider is strictly worse at fixed
capacity, and it costs +15 ALMs, +136 registers and −132 MHz as well. **The history bank
should be one complex sample per word and as deep as the geometry allows.** That is what
`history_core` already builds; the sweep confirms the default rather than changing it.

**Finding 2 — the registers ARE absorbed, and SPEC §23's rule is worth 98.6 MHz here.** The
worst path of every point ends inside the hard block:

```text
  u_kernel|mem_v_q
    -> u_kernel|g_store.mem_rtl_0|auto_generated|altera_syncram_impl1|ram_block2a31~reg1
```

`ram_block*~reg*` is the M20K's own input register, and `reg2reg_logic_depth = 0` with
`cell_delay = 0.000 ns` says there is no fabric logic on that path at all — it is a register,
a wire and a hard-block register. Removing the bank's own input and output registers
(`bank_512x32_noreg`) drops the kernel from 13.7 ALMs to **0.5**, and drops Fmax from
**956.9 to 858.4 MHz**, and — the part that matters — changes the Fitter's retiming limit
reason from `Path Limit` to **`Insufficient Registers`**: the Hyper-Retimer wants registers to
move and there are none. Thirteen ALMs per bank against 98.6 MHz is not a trade-off, it is a
rounding error against a real gain, and at the full-scale 128 banks it is 1 754 ALMs, 0.13 %
of the device.

This is the direct answer to the question SPEC §18 asks by naming "input and output register
choices" as an axis, and it is why `history_core` fixes `IN_REG = OUT_REG = 1` and does not
expose them.

**Finding 3 — a 32-bit word can only ever fill 80 % of an M20K.** Every point stores 16 384
bits in a block that holds 20 480. The M20K's parity-carrying modes are ×40, ×20, ×10 and ×5;
32 is 80 % of 40 and 16 is 80 % of 20, so no aspect ratio of a 32-bit-word memory reaches the
parity bits. This is not a defect and not fixable by reshaping — it is the constant that the
full-scale projection below has to be built on, and measuring it was the point of holding the
capacity fixed.

### A four-bank corner-turn slice

| point | geometry | M20K | RAM bits | ALM (total / kernel) | regs | Hyper | Fmax MHz | depth | fit s |
|---|---|---|---|---|---|---|---|---|---|
| `core_a4_l1` | 4 antennas × 1 lane = 4 banks, 64 bins, 4 frames | 4 | 32 768 | 2 024 / 1 496.4 | 4 694 | 1 266 | **444.6** | 4 | 474 |
| `core_a2_l2` | 2 antennas x 2 lanes = 4 banks, 64 bins, 4 frames, bit-reversed | 4 | 16384 | 1619 / 1112.4 | 3359 | 554 | **475.737** | 3 | 462 |

**Finding 4 — the banks are not the limiter; the frame barrier is.** `core_a4_l1` is the only
point in this sweep that did NOT meet the probe, so **444.6 MHz is a genuine measured limit**
(WNS −0.583 ns against 1.666 ns), and the path is not in a memory:

```text
  u_kernel|frame_q[3][9]~RTM_104  ->  u_kernel|frame_q[2][0]~RTM_28DUPLICATE
  logic depth 4, cell 0.799 ns, routing 1.213 ns
```

`frame_q` is the per-antenna 32-bit absolute frame counter, and the path between two of them
is the **frame barrier**: `all_past_barrier` compares every antenna's counter against
`frames_done`, and the skew test computes `frame_q[a] − frames_done ≥ depth`, both across the
full 32 bits and all N_ANT antennas. The `~RTM_` and `~RTM_*DUPLICATE` suffixes say the
Hyper-Retimer already retimed and duplicated those registers and still ran out — the limit
reason is `Path Limit`.

444.6 MHz clears the SPEC §8 `history_clk` of 400 MHz with 11 % margin. It misses `core_clk`'s
450 MHz by **1.2 %**, and the barrier is in `core_clk`.

**The second core point corroborates it, and that is why two shapes of the same bank count
were compiled.** `core_a2_l2` has the SAME four banks as `core_a4_l1` and half the antennas,
and it comes out **475.7 MHz against 444.6** — 7 % faster — with the kernel at 1 112 ALMs
against 1 496 and logic depth 3 against 4. Same memory count, fewer antennas, faster and
smaller: the limiter tracks N_ANT through the barrier's comparator tree and not the bank
count, which is the claim finding 4 makes and which one point alone could only have
suggested.

A caveat on the M20K column of this table, stated so it is not read as a density result:
both core points report 4 M20Ks for four banks, but `core_a2_l2` holds 16 384 bits against
`core_a4_l1`'s 32 768. At a four-frame slice every bank is far smaller than one block, so the
count is a FLOOR of one block per bank rather than a measurement of packing. That is exactly
why the bank sweep above holds capacity at a full 16 384 bits — the two tables answer
different questions on purpose.

**The structural answer, and why it is not made here.** The barrier does not need 32-bit
comparisons. `frames_done` and `frame_q` are compared only for equality and for a
"more than `depth` ahead" test, and both are correct on a counter of a few bits more than
`log2(FRAMES_MAX)` — the 32-bit absolute number is needed only for the published `frame_id`,
which is off the critical path and moves once per frame. Narrowing the barrier's counters to
`SLOT_W + 2` bits would cut the comparison from 32 bits to 5 and leave the datapath untouched.

Per SPEC §20 that change is not made in this PR: it is one hypothesis, it needs its own
correctness re-proof and its own compile, and the number to beat is now on record — **444.6
MHz, path named above, target 450**. It is exactly the shape of edit the issue #22 closure loop
exists to make, and it is written into DECISIONS.md so that loop inherits a hypothesis rather
than a search.

**Finding 5 — the corner turn's fixed cost is about 1 500 ALMs at four banks**, against
4 × 13.7 ≈ 55 ALMs for the banks themselves. That is the write sequencers, the barrier, the
rotation and readable-set arithmetic, the registered read fanout, the three CDC crossings, six
saturating counters and the output FIFO with its credit gate — and it is dominated by things
that do NOT grow with the bank count. The 1 266 Hyper-Registers say the Fitter found a great
deal to retime, which is what the latency-insensitive shape was for.

### Full-scale M20K projection (SPEC §2, SPEC §11 `full_agmf039`)

At `N_ANTENNAS=16, SAMPLES_PER_CYCLE=8, FFT_SIZE=1024, HISTORY_FRAMES=512, SAMPLE_W=16`,
computed by `model/cpp/history/history_model.hpp` from the same geometry the RTL elaborates:

```text
  LANES      = 8                     M = FFT_SIZE / LANES  = 128 beats/frame
  banks      = 16 x 8                = 128
  words/bank = 512 x 128             = 65 536
  bits/bank  = 65 536 x 32           = 2 097 152          (2 Mibit)
  TOTAL      = 128 x 2 097 152       = 268 435 456 bits   (256 Mibit)

  device     = 18 960 M20K x 20 480  = 388 300 800 bits   (370 Mibit)
```

The payload is **69.1 % of the device's raw M20K bits**, inside SPEC §2's 55-80 % band. The
BLOCK count is not, and finding 3 is why: **the sweep measured 16 384 bits in a block that
holds 20 480**, at every aspect ratio, so the projection has to be built on 16 384 and not on
20 480.

```text
  268 435 456 / 16 384  =  16 384 M20K  =  86.4 % of 18 960     <- over the target
  268 435 456 / 20 480  =  13 108 M20K  =  69.1 %               <- unreachable at a 32-bit word
```

**A power-of-two `HISTORY_FRAMES` cannot land in the band.** The projection scales linearly:

| `HISTORY_FRAMES` | M20K | % of 18 960 | |
|---|---|---|---|
| 256 | 8 192 | 43.2 % | under |
| **384** | **12 288** | **64.8 %** | **in band** |
| 448 | 14 336 | 75.6 % | in band |
| 512 | 16 384 | 86.4 % | over, and leaves nothing for FIFOs, the packet network or telemetry |

**The structural answer, and why it is not made here.** `history_pkg` requires `FRAMES_MAX` to
be a power of two, and that requirement is one line stronger than the algebra needs.
`ADDR(s, k) = s*M + k` is a concatenation because **`M`** is a power of two, not because
`FRAMES_MAX` is; the only thing the stronger condition buys is that `{slot, beat}` fills the
address space exactly, and it is enforced by a single elaboration check
(`ADDR_W == SLOT_W + BEAT_W`). Dropping `hist_is_pow2(g.frames_max)` from `hist_geom_ok` and
sizing each bank at `FRAMES_MAX * M` words unlocks 384 and 448 with no change to the datapath,
no new arithmetic and no change to the read decode.

Not made in this PR, per SPEC §20: it is a change to a verified geometry invariant made for a
resource reason, the parameter freeze is issue #20's job, and the number that freeze needs is
now measured rather than assumed. The one-line change and its exact effect are named here so
#20 can make it with the measurement in hand.

**A second projection finding, for issue #20 and for issue #22.** At full scale each bank is
65 536 words deep, which is a **128-block cascade** with a 128-way output mux per antenna-lane.
The four-frame slice cannot show that, and it is a plausible `history_clk` limiter on top of
the barrier path finding 4 already names. The banking scheme contains the fix and it costs
nothing structurally: the frame-slot dimension can be split into further banks exactly as the
lane dimension is, by moving high address bits into the bank index, and `history_pkg`'s
mapping supports it unchanged.

---

## 2026-07-26 — Frequency-bin alignment: what is left after the corner turn, identity as the routing key, and a measured crossbar/Clos comparison  (issue #16)

**Context.** SPEC §7.4 asks for a pipelined network that rearranges FFT output into
beamformer vectors, preserving antenna, frequency-bin and frame identity, supporting
backpressure, detecting missing or duplicated samples, and avoiding one giant unregistered
multiplexer — and it asks for **two architectures to be built and compared** with "area,
congestion, latency, and Fmax recorded for both". The input is issue #15's read contract and
the output is issue #12's input contract; both are normative and neither may be
reinterpreted here. Simulation was run in WSL Ubuntu-24.04 with Verilator 5.020 and g++
13.3; the calibration compiles were Quartus Prime Pro 26.1 on AGMF039R47B1E1VC, seed 1.

**Decision 1 — the antenna transpose is NOT in this block, and the block says so at the top
of its package.** The naive reading of §7.4 is "transpose antenna-sequential FFT output into
bin-parallel antenna vectors". Issue #15 already did that transpose, in memory, for free:
`history_pkg` chooses the bank dimension to be the antenna, so a read of one bin enables one
bank per antenna and returns the whole antenna vector in one cycle with no multiplexer at
all. Building a transpose here would be building it twice.

What is left — and what this block is — is the **bin-parallel marshalling layer**: issuing
`BIN_PAR` requests per cycle across `BIN_PAR` independent history read ports, routing each
response to the beat position it belongs to, reassembling responses that arrive skewed, and
detecting the ones that never arrive or arrive twice.

*Consequences.* The interpretation is recorded in `align_pkg` section 0, in ARCHITECTURE.md
§3.4a and here, because a reader who expects a transpose will otherwise look for one and
conclude it is missing. It also settles a question #15 left open: its header records that the
read port could serve up to `LANES` bins per cycle and deliberately does not, so that the lane
constraint does not leak into this block's scheduler. This block spends that headroom by
**instantiating the port `BIN_PAR` times** rather than by widening it, which leaves #15's
correctness argument untouched and makes the skew between instances a first-class thing to be
absorbed rather than a thing to be prevented.

*Alternative rejected:* a wider, lane-constrained read port — it would make the two blocks'
correctness joint, which is exactly what #15 declined.

**Decision 2 — the request schedule ROTATES, and that is what makes the network a network.**
Beat position `j` of group `g` is requested on port `(j + g) mod BIN_PAR`. A fixed assignment
(`j` always on port `j`) would reduce the "network" to `BIN_PAR` wires and make SPEC §7.4's
architecture comparison vacuous.

The reason is physical rather than contrived. #15's banking makes the memory lane of a bin the
*high* bits of the bin index, so a fixed assignment would send a fixed residue class of bins to
each port forever, pinning each port to one subset of memory lanes at a fixed duty cycle — the
one arrangement that guarantees the per-port enable trees are maximally unbalanced. Rotating
spreads every port over every lane in `BIN_PAR` groups.

*Consequences.* The map from response port to beat position is a different cyclic permutation
on every group, so the network routes a genuinely time-varying permutation. The rotation is
arithmetic on the request side only; nothing on the response side has to remember it (decision
3), which is what makes the block tolerant of *arbitrary* skew rather than only of the skew the
schedule happens to produce.

**Decision 3 — the routing key is the response's own identity, not a side-channel tag.** The
obvious mechanism is a per-port FIFO of issued tags, popped one per response. It is rejected,
and the reason is the failure mode §7.4 exists to catch: **a tag FIFO is only correct while
responses and tags stay in step, so the first dropped or duplicated response silently
mis-labels every response after it.** The detector would be the thing that breaks first.

The key is recomputed from the response's own metadata, which #15 already carries inside
`data`: the lane is the low bits of the bin, the group is the high bits, and the reassembly
entry index is the group modulo `GROUPS` — three bit slices, no arithmetic. The entry
independently stores the `(group, frame_off, frame_id)` it was allocated for, and every
arriving response is checked against it.

*Consequences.* Missing is detected **positively** (a present bit that never sets) rather than
inferred from a stream position; duplicate is detected exactly, on the second copy, whatever
the skew; a response whose key does not match is an orphan, counted and dropped rather than
written over a live beat; and **no ordering assumption at all** is made about the response
streams, so a future out-of-order memory would not invalidate the network. The cost is that the
identity travels through the routing network with the data instead of a `log2` tag — which is
also literally what §7.4 means by "preserve antenna, frequency-bin and frame identity": the
identity is *in* the routed word and is checked at the far end.

*Alternative rejected:* a CAM over the open entries. It would be `BIN_PAR × GROUPS` comparators
of a key wider than the index it replaces, on the response path, to compute something the
address already contains.

**Decision 4 — `frame_id` is part of the key, at its full 32 bits.** It is about 6% of the
routed word and it is the only field that can answer "is every antenna vector in this beat from
the same frame". `frame_off` cannot: it is relative to the newest complete frame, so two
responses that both asked for offset 1 are from different absolute frames if a rotation
happened between them — and #15's `stale` flag only fires when the addressed *slot* was reused,
which is a later and coarser event. A beat assembled across a frame boundary is the exact
failure ARCHITECTURE.md calls "not detectably wrong from the output alone".

*Consequences.* The first response to reach an entry fixes its frame number and every later one
must agree. Responses arriving in the **same cycle** before the number is fixed are compared
against the lowest-numbered lane's, by a prefix scan across lanes — because with `BIN_PAR`
history instances answering a group's requests in step, all arriving together is the *natural*
case, not the exotic one, and a check that only looked at later cycles would miss it exactly
when it matters. The scan costs `BIN_PAR(BIN_PAR−1)/2` selections of one frame id, not
`GROUPS × BIN_PAR`: it is over lanes, and the entry-indexed lookup was already there for the
group and offset comparison. The rule ("lowest-numbered lane wins") is stated normatively
because both the RTL and `model/cpp/align` have to implement the same one.

**Decision 5 — an incomplete group EMITS A BEAT; it does not vanish.** A group whose responses
do not all arrive within the timeout is resolved rather than waited on. The obvious policy —
drop the beat — is wrong, because SPEC §5 is normative too: the checker requires `sequence` to
advance by exactly one per beat and requires one `eof` per frame. Deleting a beat breaks the
first; deleting the beat that carried `eof` breaks the second and leaves the frame open
forever, so the *next* frame's `sof` fires an assertion. A block that answers "detect missing
samples" by corrupting the stream protocol has moved the defect, not fixed it.

So: **the beat is emitted, the data is not.** Absent lanes are zeroed (`cfg_partial_pass = 0`,
the default), so no stale or half-formed antenna vector ever reaches the beamformer;
`ALGN_USER_MISSING` is set in the SPEC §5 `user` field; `stat_missing_count` advances by the
exact number of absent lanes; and `sequence`, `sof` and `eof` are exactly what they would have
been. `cfg_partial_pass = 1` keeps whatever arrived, for diagnosis. Both settings are modelled
and both are tested; the default is the safe one.

**Decision 6 — the timeout counts CYCLES OF PROGRESS, not wall time.** An entry's age advances
only in cycles where the block could have retired a beat. Without that rule the detector is
worse than useless: a beamformer that stalled for longer than the timeout would make every open
group "time out", and the block would report missing samples for a pipeline that lost nothing.
A missing-sample counter that fires on backpressure is a counter nobody can act on. The
backpressure-invariance pass — a byte-identical beat sequence at four stall profiles — is the
property that would fail immediately if the age counters free-ran.

**Decision 7 — architecture 2 is an OMEGA network, not a literal three-stage Clos, and the
reason is that non-blocking is the wrong purchase here.** SPEC §7.4 says "multistage or
Clos-style". A strictly non-blocking Clos guarantees that any new connection can be added
without rearranging existing ones — a guarantee about *circuits held open across time*. This
network carries single-cycle packets: every word is independently routed, nothing is held open,
and there is no connection to rearrange. What blocking costs here is one cycle of delay for one
word, and the reassembly buffer already absorbs far larger skew between independent history
instances. Paying `2n−1` middle stages would be buying the same insurance twice.

What is bought instead is the multistage property that actually matters against a crossbar, and
it is a **wiring** property: every connection is between adjacent switch positions of
consecutive stages, so a routed word never has to be presented across the full width of the
block, where a crossbar must present all `N` sources at every one of the `N` destinations. On a
device where §7.4 asks specifically for *congestion* to be recorded, that is the difference the
measurement is looking for. The blocking rate is measured and reported
(`stat_conflict_count`) rather than argued away.

**Decision 8 — the two architectures are LATENCY-MATCHED, by parameter, and the match is
checked.** `align_xbar`'s `MUX_STAGES` is the knob: `algn_xbar_latency(1) = 2 =
algn_clos_latency(4)` and `algn_xbar_latency(2) = 3 = algn_clos_latency(8)`. A resource
comparison between a 2-cycle network and a 3-cycle network is a comparison of pipeline depths
wearing two topologies' names. `align_switch` checks the match at elaboration and prints a note
when a caller breaks it deliberately; the verification top's geometry pass fails the run if a
pair is un-matched; and the calibration matrix sets `MUX_STAGES` explicitly at each width.

**Decision 9 — `MUX_STAGES = 2` is how "no giant unregistered multiplexer" is met structurally
rather than by argument.** At the wide calibration point an output's mux is 8 sources of 566
bits and there are 8 of them: 4528 eight-input multiplexers in one combinational cone.
`MUX_STAGES = 2` partitions the inputs into `ceil(sqrt(N))` groups and registers one `RADIX:1`
mux result per group, so no cone is wider than `RADIX:1`. The alternative reading — "an 8:1 mux
is only two LUT6 levels, that is not giant" — is available as `MUX_STAGES = 1` and is a real
trade, but it is an argument about LUT depth where §7.4 asks for a structure.

*Consequences.* Level 0 is `GROUPS` registers wide per output and only one of them can ever be
loaded in a cycle. That is not an oversight: deciding *which* group to register before
registering it needs the group decision to have already muxed the data, which is the `N:1` cone
again. The cost it exposes is the measurement §7.4 asks for.

**Decision 10 — `align_clos`'s ready chain is combinational across its stages, deliberately,
and the alternative is priced rather than dismissed.** A link is free when it is empty or is
being emptied, and "being emptied" is decided by the next stage — so `in_ready` is a function of
`out_ready` through `log2(N)` stages of two-input arbitration. The fix, a two-deep elastic
buffer on every link, **doubles the storage of the entire network**, which is the resource this
architecture exists to economise: at `N = 8` it would take the omega network from 24 link
registers to 48, against the crossbar's 40, and would invert the comparison's own result.
Spending it to remove a path of three two-input gates would give away the subject. The
calibration records the critical path's endpoints for every point, so whether this is the
limiter is in the record and not in a comment.

**Decision 11 — the SPEC §14 route property lives OUTSIDE both architectures, and the
elaboration proof does not replace it.** `a_align_route_correct` sits in
`align_assertions.sv`, watching the network's master side, so both architectures are held to it
by the same code. It is the property this issue turns on: a mis-routed word still produces a
perfectly well-formed beat — right count, right frame, right group — carrying two copies of one
bin and none of another.

`align_clos` additionally proves its wiring at elaboration, over the whole `N × N` space, and
checks every delivered word at run time. Both, because they catch different things: the
elaboration proof catches a shuffle that is off by one rotation (which otherwise passes every
test where the destination happens to equal the source — and at `BIN_PAR = 2` that is every
test there is), and the runtime property catches an arbiter, stall or reset interaction that
moves a word off a correct route. The fault injection in decision 20 shows a fault that passes
the first and fails the second.

**Decision 12 — `cfg_run` is a separate control from `cfg_enable`, and it stops at a frame
boundary.** Dropping `cfg_run` halts the sweep only when the current frame completes; a sweep in
progress ignores it. It is one term — `run_gate = cfg_run || (gidx != 0)` — with no state and no
handshake, and it is what makes it impossible to leave a SPEC §5 frame open.

It is separate from `cfg_enable` because conflating them is a **deadlock**: `cfg_enable` low
also stops the block accepting responses, so a block disabled with work in flight would strand
its own reassembly entries and then report them as missing samples. This was found by writing
the test — there was no way to bring the block to a clean quiescent point at which the counters
could be compared — which is a design defect the test surfaced rather than a test inconvenience.

**Decision 13 — the reassembly buffer's lane ports are ALWAYS ready, and that is a deadlock
argument.** Every word arriving on a lane belongs to an entry that is already open, because the
scheduler allocates the entry before it issues the requests. Refusing such a word could not
free anything — the entry it would fill is the very thing the buffer is waiting for — so a
full-buffer stall there would be a deadlock, not backpressure. Backpressure is applied one level
upstream, at group allocation, where refusing genuinely does bound the work in flight.
`cfg_lane_stall` exists so SPEC §13.1 stall testing can reach that interface anyway; it is a
real port driven by the harness and by the calibration wrapper's pins, not a tie-off.

**Decision 14 — the SPEC §18 sweep measures the ROUTING FABRIC on its own, and the block
separately.** Two calibration projects, `align_sw` (four points) and `align_net` (two). The two
architectures *are* the two routing fabrics; everything else in the block is byte-for-byte
identical in both builds, and the reassembly buffer alone is `GROUPS × BIN_PAR × VEC_W`
flip-flops, which at the wide point is several times either fabric. Sweeping the whole block
twice would report two numbers differing by a few percent and the few percent would *be* the
answer. `align_net`'s two points price the common part once per architecture, which is what a
full-scale projection needs as a number rather than as a difference.

*Consequence, and it is a real gain:* the fabric carries no SPEC §5 payload — it moves one bin's
vector plus its identity — so `stream_pkg::STREAM_MAX_DATA_W` does not bound it, and the
**full-scale 16-antenna routing width is measured a phase early**, without raising that bound.
The block-level points stop at 8 bins × 4 antennas, which is exactly 1024 bits.

**Decision 15 — `STREAM_MAX_DATA_W` is NOT raised to 4096 by this issue.** Issue #12 raised it
from 256 to 1024 and recorded that going to 4096 "belongs to the issue that builds the alignment
network producing such a beat (#16) and the one that freezes full scale (#20), with measured
data in hand". This is that issue, and the answer is: not yet, and here is the data.

Raising it multiplies the working type of every `stream_pack`/`stream_unpack` in the design by
four, paid by every block, for a geometry nothing yet verifies. What #20 actually needs is (a)
the full-scale routing cost, which `align_sw`'s wide points measure at 16 antennas without the
bound applying, and (b) the block's fixed cost, which `align_net`'s points measure at the widest
beat the bound allows. The full-scale figure is (a) + (b), which is arithmetic rather than
another compile. The bound is left where #12 put it, and moving it is left to the issue that
also freezes the geometry.

**Decision 16 — `align_pkg` names its integer type `algn_uint_t`, and the block is spelled
`algn_` inside identifiers.** Issue #10's decision 9 applied a sixth time: `fxp_pkg`,
`stream_pkg`, `covar_pkg`, `cfar_pkg`, `pfb_pkg`, `beamformer_pkg` and `history_pkg` each export
a helper of that role, and a name visible through two wildcard imports is ambiguous under IEEE
1800 §26.3 — Quartus rejects it outright and Verilator accepts it silently. `align_net`
wildcard-imports `fxp_pkg`, `stream_pkg`, `history_pkg` and this package at once.

One naming hazard is worth recording because it is specific to this block: **`lane` means two
different axes in two adjacent packages.** In `history_pkg` it is a memory bank index; here it
is a beat position. They never appear in one expression and each package's header says which one
it means, but a reader moving between the two files will meet both.

**Decision 17 — `ALGN_USER_W` and `ALGN_FAULT_W` stay localparams and are given a reader inside
the package.** Everything else in `align_pkg` is a function, for the reason `stream_pkg` and
`history_pkg` give. These two cannot be: they appear in port declarations. Issue #15's decision
13 records the consequence — a package localparam the elaborated hierarchy never reads is
`UNUSEDPARAM`, and `files.f` lists this package for a top that does not yet instantiate the
block — and this issue hit it on the first full `make lint`. The reader is
`algn_status_encoding_ok()`, which states the invariant that makes "one decode serves both"
true: the beat's status field and the block's sticky fault word are the same four bits in the
same order.

**Decision 18 — `scripts/cdc_inventory.py` gains `--allow-empty`, and the alignment network is
the first block to use it.** The block is single-clock by construction: `history_pkg` §5 puts
the read request and the read response in `history_clk`, and the beamformer that consumes the
output beat is in it too. Running the inventory over it with `--strict` failed on "the inventory
is empty", which was an unconditional error — reasonable when every block inventoried so far had
crossings, and wrong for a block whose *design claim* is that it has none.

`--allow-empty` makes zero crossings a pass **while leaving the unclassified-crossing check
running**, so a two-clock module added to `rtl/align/` later without a `(* cdc_primitive *)` tag
still fails the gate. The default is unchanged. The alternative — simply not inventorying the
block, as the other single-clock tops are not — would have left "no crossings here" as an
untested absence rather than a checked fact.

**Decision 19 — `align_net` does not truncate an out-of-range frame offset.** The scheduler
carries `cfg_frame_off` at #15's full control-port width and drives it onto the request port
unmodified. An offset that does not fit the geometry's `FOFF_W` is *out of range*, and
`history_pkg` §5 already defines what happens to it: #15 answers deterministically, sets
`HIST_FLAG_OUT_OF_RANGE` and advances its own error counter. Truncating here would instead send
a **different, perfectly legal** request and get a perfectly good answer to a question nobody
asked. The returned metadata then disagrees with the entry key and the responses are counted as
orphans — loud, exact, and correct: a software error is reported rather than silently
reinterpreted.

**Decision 20 — two deliberate faults, one per architecture, prove the property set fires.**
SPEC §14 requires the assertions to be shown to fire rather than assumed to.

* `align_xbar`: the per-output request comparison changed to `a_dst[i] == (o+1) % N`, so every
  word is delivered one lane from where it belongs. `a_align_route_correct` fired on the first
  delivered word — *"lane 0 was given a word belonging at beat position 1"*.
* `align_clos`: a switch's routing bit changed from `src_dst[J0][RBIT]` to `src_dst[J0][0]`, so
  the hardware routes on the LSB at every stage while the elaboration-time `route_ok()` proof —
  written against the generic expression — still passes. `a_clos_arrived_at_destination` fired:
  *"a word addressed to 1 was presented at output 3"*. This is precisely the case decision 11
  says the elaboration proof cannot catch.

Both edits were reverted and `make sim-tiny` passes on seeds 1, 2 and 3.

**Decision 21 — two defects this issue found in its own test rather than in the RTL, recorded
because they will recur.** Both were the model disagreeing with correct hardware, and both are
properties of how an elastic, independently-stalled interface is observed:

* the model must open a reassembly entry on the **first** accepted request of a group, not the
  last. The block allocates at issue — all `BIN_PAR` requests are loaded in one cycle — so with
  the request ports stalling independently, the answer to the first request can be back before
  the last has been accepted.
* the model must find an entry by searching its open list **from the back**. The RTL frees an
  entry when the beat is *pushed* into the output elastic buffer; the test only learns about the
  beat when it is *popped*, so the model can be holding an entry the RTL has already reused.
  Taking the newest open entry with the matching index reproduces exactly what the RTL sees.

The general lesson, and it applies to every block after this one: **a transaction-level model of
an elastic block is synchronised by the events the test caused, not by the events it observes**,
and the two differ by the depth of every buffer between them.
