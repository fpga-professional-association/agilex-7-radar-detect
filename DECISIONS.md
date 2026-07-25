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
