# Verilator simulation flow

Everything in this directory runs inside **WSL Ubuntu-24.04** (Verilator 5.020,
g++ 13.3), per the PLAN.md split-toolchain rule. Windows-side `make` re-dispatches
simulation targets into WSL automatically; Quartus never runs here.

Governing spec: [SPEC.md](../../SPEC.md) §12 (Verilator strategy), §13 (tests),
§16 (build commands).

## Quick start

```bash
make lint            # verilator --lint-only --Wall, zero unwaived warnings
make numerics-check  # SPEC §6/§12.4 fixed-point equivalence proof
make sim-tiny        # numerics-check, then fast build + loopback test across SEEDS
```

`make sim-tiny` defaults to `SEEDS='1 2 3'`. Override anything on the command
line:

```bash
make sim-tiny SEEDS='1 3 7 11 17'   # wider seed sweep, one build
make sim-tiny JOBS=8                # fewer parallel compile jobs
make lint CONFIG=full_agmf039       # lint the largest elaboration
```

## The other tops

`benchmark_sim_top` is the design (SPEC §4.1). Six further tops exist, each
self-contained with its own file list, for one reason: a failure in a
self-contained build is unambiguously a failure of the thing that build tests,
never a knock-on from unrelated RTL. All seven are built by the same script with
`--top` / `--files` changed together, and a non-default top builds into
`build/<mode>_<config>_<top>/` so they never share objects.

| Top | File list | Test | Proves |
|---|---|---|---|
| `benchmark_sim_top` | `files.f` | `test_stream_loopback` | the SPEC §5 loopback, the harness, and the SPEC §5 packing against the RTL's `m_payload` |
| `fxp_probe_top` | `files_fxp.f` | `test_fxp_rtl` | `fxp_pkg` == `model/cpp/fxp` == NumPy, bit for bit (SPEC §6, §12.4) |
| `stream_prims_top` | `files_stream.f` | `test_stream_primitives` | the three stream primitives, per primitive: stalls, framing, occupancy, capacity, latency, throughput (SPEC §5, §13.1) |
| `stream_violator_top` | `files_violator.f` | `test_stream_assertions` | that the SPEC §14 protocol assertions actually fire, by name, on injected violations — and stay silent on a correct stage |
| `control_top` | `files_control.f` | `test_control_regs` | the SPEC §9 register plane: the map against the generated tables, every access type, every illegal address form, and the watchdog that keeps the fabric from hanging |
| `cdc_prims_top` | `files_cdc.f` | `test_sync_fifo`, `test_async_fifo`, `test_cdc_synchronizers` | the SPEC §8 FIFO and CDC primitives: `sync_fifo` against a cycle-accurate C++ model, and every crossing across a seven-entry clock-ratio sweep |
| `cdc_violator_top` | `files_cdc_violator.f` | `test_cdc_assertions` | that the SPEC §14 CDC assertions actually fire, by name, on injected violations — and stay silent on a correct crossing |

`make lint` lints all six of `benchmark_sim_top`, `stream_prims_top`,
`stream_violator_top`, `control_top`, `cdc_prims_top` and `cdc_violator_top`;
`make sim-tiny` builds and runs their seven tests once per seed, after
`make numerics-check` has run the eighth against `fxp_probe_top` and
`make cdc-inventory` has produced the SPEC §8 crossing report.

`cdc_prims_top` is the only top with more than one test: the three tests share one
verilated model (they differ only in which DUTs inside it they drive), so keeping
them in one build costs one elaboration instead of three.

`control_top` also holds a second fabric attached to `reg_block_dead.sv`, a block
that never answers. Like the violator it is knowingly wrong, appears only in
`files_control.f`, and exists so the fabric's watchdog escape is an exercised
path rather than an untested comment.

`stream_violator_top` and `cdc_violator_top` contain deliberately incorrect RTL.
Each is in its own file list and nowhere else, so neither can reach the design
build. Their two tests clear `Verilated::fatalOnError` — the only places in the
repository where a failing assertion is not fatal: there, an assertion failure is
the expected result, and the binary exits 0 when every expected failure was
observed by name.

## `fxp_probe_top` in detail (numerics cross-check)

Most of this directory is about `benchmark_sim_top`. There is one other top, and
it exists for a single purpose: proving that `rtl/packages/fxp_pkg.sv` and
`model/cpp/fxp/` compute identical results (SPEC §6, §12.4).

```text
sim/verilator/files_fxp.f          three files: fxp_pkg, fxp_sticky_flags, probe
sim/verilator/tops/fxp_probe_top.sv  thin probe; nothing but calls into fxp_pkg
sim/tests/test_fxp_rtl.cpp         drives model/vectors/ through it
```

It is built with the same script and the same modes, pointed at a different top
and file list:

```bash
python3 scripts/build_verilator.py --mode fast --config tiny \
    --top fxp_probe_top --files sim/verilator/files_fxp.f --test test_fxp_rtl
./sim/verilator/build/fast_tiny_fxp_probe_top/Vfxp_probe_top_test_fxp_rtl \
    +vectors=model/vectors
```

`--top` / `--files` are changed together, and a non-default top builds into
`build/<mode>_<config>_<top>/` so the two never share objects. Keeping the
numerics build independent of `benchmark_sim_top` means a failure in the
numerics gate is always a numerics failure, never a knock-on from unrelated RTL.

`make numerics-check` wraps that build plus two more steps — regenerating the
committed vectors and comparing, and the standalone (Verilator-free) C++ unit
test. It is a prerequisite of `make sim-tiny`, not a SPEC §16 entry point. See
[NUMERICS.md](../../NUMERICS.md) §10 and `model/vectors/README.md`.

## The four build modes (SPEC §12.1)

All four are driven by `scripts/build_verilator.py`. `make lint` and
`make sim-tiny` wrap the first two; the other two are invoked directly until
`make sim-coverage` lands in issue #17.

| Mode | Command | Purpose |
|---|---|---|
| `lint` | `scripts/build_verilator.py --mode lint --config tiny` | Syntax, widths, latches, unused signals, incomplete cases. `--Wall`, warnings fatal. |
| `fast` | `scripts/build_verilator.py --mode fast --config tiny` | The regression build. `-O3`, `--assert`, no trace, no coverage. |
| `coverage` | `scripts/build_verilator.py --mode coverage --config tiny` | `--coverage` (line, branch, toggle, user). Writes `results/simulation/coverage_seed<N>.dat` per run. |
| `debug` | `scripts/build_verilator.py --mode debug --config tiny` | `--trace-fst`, depth 8, `-O0 -g`. Tracing still requires `+trace` at runtime. |

Each mode builds into its own directory, `sim/verilator/build/<mode>_<config>/`,
so switching modes never invalidates another mode's objects. Everything under
`build*/` is gitignored.

The resulting binary is
`sim/verilator/build/<mode>_<config>/Vbenchmark_sim_top_<test>`.

### Runtime arguments

Verilator-style plusargs, accepted by every simulation binary:

| Argument | Meaning |
|---|---|
| `+seed=<n>` | master random seed (also `$SIM_SEED`; default 1) |
| `+frames=<n>` | frames per pass (0 = test default) |
| `+timeout=<cycles>` | hard cycle timeout (0 = test default) |
| `+results=<dir>` | run-summary directory (default `results/simulation`) |
| `+trace` | arm FST tracing — debug build only |
| `+trace_file=<path>` | override the trace path |
| `+coverage=<path>` | override the coverage output path — coverage build only |
| `+quiet` | suppress per-pass progress lines |
| `+vectors=<dir>` | golden-vector directory — `test_fxp_rtl` only (default `model/vectors`) |

The resolved seed is printed on **every** run, pass or fail, together with the
exact command line that replays it.

## Reproducing a failure

The run summary and the `RESULT:` line both carry the seed. To get a waveform for
a failing seed, rebuild in debug mode and rerun with the same seed — nothing else
changes, because all randomness derives from that one number:

```bash
python3 scripts/build_verilator.py --mode debug --config tiny
./sim/verilator/build/debug_tiny/Vbenchmark_sim_top_test_stream_loopback \
    +seed=<failing seed> +trace
gtkwave sim/failures/test_stream_loopback_seed<failing seed>.fst
```

Traces land in `sim/failures/` (gitignored) named after the test and seed, so the
artefact identifies its own reproduction command.

## Adding a warning waiver

Waivers live in [`lint_waivers.vlt`](lint_waivers.vlt) and nowhere else; the lint
build runs without `--Wno-fatal`, so an unwaived warning fails `make lint` with a
non-zero exit status.

1. **Fix the RTL first.** WIDTH, LATCH, CASEINCOMPLETE and BLKSEQ warnings are
   real bugs; they are never waivable.
2. If the warning is genuinely wrong or genuinely accepted, add a `lint_off` line
   scoped as narrowly as the rule permits — `-rule` plus `-file`, and `-match`
   when the file scope alone is not honoured (Verilator 5.020 needs `-file` *and*
   `-match` for `UNUSEDPARAM`; `lint_off -module` is a syntax error).
3. Above the line, write a comment saying **why** the warning does not indicate a
   defect, what the waiver's scope is, and **what would make it removable**.
4. Prove it is narrow: introduce the same warning somewhere else in the design
   and confirm `make lint` still fails.

The file currently holds one waiver. Keep the count low enough to read.

## Layout

```text
sim/verilator/
├── README.md            this file
├── files.f              RTL file list for the design build
├── files_fxp.f          three-file list for the numerics cross-check build
├── files_stream.f       stream primitives + their unit-test top
├── files_violator.f     the deliberately broken stage + its top (negative test)
├── files_control.f      the SPEC 9 register plane + its unit-test top
├── files_cdc.f          the SPEC 8 FIFO and CDC primitives + their unit-test top
├── files_cdc_violator.f the deliberately broken crossing + its top (negative test)
├── lint_waivers.vlt     checked-in warning waivers, each justified
├── sim_main.cpp         main(): argument parsing, seed banner, coverage dump
├── harness/             the C++ simulation harness (see harness.h)
├── tops/
│   ├── benchmark_sim_top.sv   SPEC 4.1 simulation top
│   ├── fxp_probe_top.sv       SPEC 12.4 numerics probe (simulation only)
│   ├── stream_prims_top.sv    SPEC 13.1 per-primitive unit-test top
│   ├── stream_violator.sv     deliberately broken stage (negative test only)
│   ├── stream_violator_top.sv wrapper that binds the SPEC 14 checker onto it
│   ├── control_top.sv         SPEC 9 register-plane unit-test top
│   ├── reg_block_dead.sv      a block that never answers (watchdog test only)
│   ├── cdc_prims_top.sv       SPEC 8/13.1 FIFO and CDC unit-test top
│   ├── cdc_violator.sv        deliberately broken crossing (negative test only)
│   └── cdc_violator_top.sv    wrapper that binds the SPEC 14 CDC checkers onto it
├── generated/           config_pkg.sv + config_sim.h (generated, gitignored)
└── build/<mode>_<config>[_<top>]/  verilated objects and binaries (gitignored)

sim/assertions/          shared SPEC 14 property text and the checker module
sim/tests/               one .cpp per test; each defines harness::sim_test_main
sim/failures/            FST traces and failure artefacts (gitignored)
results/simulation/      JSON run summaries, coverage data (gitignored)

model/cpp/fxp/           bit-accurate C++ reference model, on every build's -I path
model/cpp/cdc/           cycle-accurate FIFO reference model (issue #6)
model/vectors/           committed golden vectors (see model/vectors/README.md)
```

## Harness

`harness/harness.h` is the umbrella include and lists which SPEC §12.2
capabilities exist today and which are owned by later issues. The pieces:

| Header | Role |
|---|---|
| `clock_scheduler.h` | integer-time multi-clock event scheduler (SPEC §12.3) |
| `reset_sequencer.h` | per-domain reset assert/release |
| `random.h` | seeded substreams, randomized bursty backpressure |
| `stream_types.h` | provisional SPEC §5 bundle, source/sink port interfaces |
| `stream_driver.h` | randomized-valid source |
| `stream_monitor.h` | randomized-ready sink, frame and sequence integrity |
| `scoreboard.h` | transaction-identity scoreboard (SPEC §12.5) |
| `timeout.h` | hard and stall timeouts |
| `error_collector.h` | categorised error collection |
| `trace.h` | optional FST tracing, compiled in only for the debug build |
| `run_summary.h` | deterministic JSON run record |
| `sim_args.h` | plusarg parsing; declares `sim_test_main` |

The harness never includes a generated model header. A test binds the DUT's ports
to `StreamSourcePort` / `StreamSinkPort` implementations, which is what lets the
same driver, monitor and scoreboard follow the design as it grows.

### Writing a new test

1. Add `sim/tests/<name>.cpp` defining `int harness::sim_test_main(const SimArgs&)`.
   Do not write a `main()`; `sim_main.cpp` owns it.
2. Print `RESULT: PASS seed=<n> ...` or `RESULT: FAIL seed=<n> ...` and return 0
   or non-zero to match.
3. Build and run with `--test <name>` / `make sim-tiny TEST=<name>`.

## Configuration injection

`config/<name>.json` is the single source of elaboration parameters.
`scripts/build_verilator.py` reads it and generates, into `generated/`:

* `config_pkg.sv` — a SystemVerilog package imported by `benchmark_sim_top`,
* `config_sim.h` — the same constants for the C++ side.

Both are rewritten only when their content changes, so re-running the script does
not force a rebuild. Neither is committed. See DECISIONS.md for why a generated
package was chosen over `-G` parameter overrides.
