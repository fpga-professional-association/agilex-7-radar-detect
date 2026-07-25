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
