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
