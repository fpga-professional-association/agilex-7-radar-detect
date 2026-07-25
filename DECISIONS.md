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
