# Execution Plan — Autonomous Agilex 7 Wideband Processing Benchmark

Governing spec: [SPEC.md](SPEC.md). Target device: **AGMF039R47B1E1VC** (Agilex 7
M-Series M039, R47B, HBM2e + 4x F-Tile).

## Environment (measured 2026-07-25)

| Component | Location | Version |
|---|---|---|
| Quartus Prime Pro | `C:\altera_pro\26.1\quartus` (Windows) | 26.1.0 Build 110 Pro |
| Verilator | WSL Ubuntu-24.04 | 5.020 |
| GNU Make / g++ | WSL Ubuntu-24.04 | 4.3 / 13.3.0 |
| Python | WSL 3.12.3, Windows 3.14.0 | — |
| CPU cores | — | 16 |

**Split-toolchain rule:** all simulation (`make lint`, `make sim-*`) runs inside WSL
(`wsl -d Ubuntu-24.04`); all Quartus targets run on Windows using
`C:\altera_pro\26.1\quartus\bin64\quartus_sh.exe`. The Makefile must dispatch each
target to the correct side and work when invoked from either side. The repo lives at
`D:\agielx-7-radar-test` = `/mnt/d/agielx-7-radar-test` in WSL.

## Process

1. Every GitHub issue below is executed on its own branch (`issue-NN-<slug>`).
2. Each issue produces one PR against `main`.
3. Fable (orchestrator) reviews every PR against the spec and the issue's gate before
   merging. Failed gates → PR revised, not merged.
4. Subagent tiers: complexity score 1–3 → Sonnet, 4–10 → Opus. Scores recorded below.
5. Spec rules in SPEC.md §28 bind every agent. No vendor DSP IP in the principal
   benchmark. No constraint games. Deterministic seeds everywhere.

## Issue Breakdown

Scores are task-complexity 1–10 (design judgment, cross-module reasoning, correctness
risk) and select the executing agent tier.

### Phase 0 — Infrastructure

| # | Title | Score → Agent |
|---|---|---|
| 1 | Repo scaffold: directory tree, docs skeleton, config JSONs, Makefile + entry points | 4 → Opus |
| 2 | Verilator flow: build scripts, C++ multi-clock harness, randomized loopback test | 7 → Opus |
| 3 | Quartus flow: project for AGMF039R47B1E1VC, compile/report Tcl, minimal fabric top, JSON export | 6 → Opus |

Gate: `make lint`, `make sim-tiny`, `make quartus-map` pass from clean checkout.

### Phase 1 — Common infrastructure

| # | Title | Score → Agent |
|---|---|---|
| 4 | Fixed-point numerics: shared SV package + bit-identical C++ types, NUMERICS.md | 7 → Opus |
| 5 | Stream interface, elastic buffer, skid buffer, protocol assertions | 6 → Opus |
| 6 | Sync FIFO, async FIFO (Gray), CDC primitives, CDC assertions + inventory report | 7 → Opus |
| 7 | Register/control plane + generated machine-readable register map | 5 → Opus |
| 8 | Sequence tracking, performance counters, telemetry primitives | 4 → Opus |

### Phase 2 — DSP kernels

| # | Title | Score → Agent |
|---|---|---|
| 9 | Complex multiplier (4-mult and 3-mult, parameterized) + verification + Quartus calibration sweep | 6 → Opus |
| 10 | Complex FIR lane + polyphase FIR bank with dual coefficient banks | 8 → Opus |
| 11 | Streaming FFT (radix-2^2 SDF), start at 64-pt / 2 SPC, scaling schedule | 9 → Opus |
| 12 | Beamforming dot product + pipelined accumulation tree + weight double-buffering | 7 → Opus |
| 13 | Power + covariance engine with programmable integration | 6 → Opus |
| 14 | CFAR detector (CA-CFAR; GO/OS optional) | 6 → Opus |

### Phase 3 — Medium pipeline

| # | Title | Score → Agent |
|---|---|---|
| 15 | Time-frequency history / corner-turn banked memory subsystem | 8 → Opus |
| 16 | Frequency-bin alignment network: crossbar vs Clos comparison | 8 → Opus |
| 17 | Medium pipeline integration + long stress test + coverage | 8 → Opus |

### Phase 4 — Packet and control fabric

| # | Title | Score → Agent |
|---|---|---|
| 18 | Event aggregation + multistage packet network (4 VCs, pipelined arbitration) | 8 → Opus |
| 19 | Telemetry, fault reporting, register map completion, abstract DMA/HBM interface | 6 → Opus |

### Phases 5–8 — Scale, baseline, closure, robustness

| # | Title | Score → Agent |
|---|---|---|
| 20 | Full-scale elaboration + full smoke tests + synthesis resource check | 7 → Opus |
| 21 | Baseline full fit (immutable) + evidence capture + parse_quartus/dashboard tooling | 6 → Opus |
| 22 | Autonomous timing-closure loop (hypothesis-driven iterations per SPEC §20–23) | 10 → Opus |
| 23 | Ten-seed robustness sweep + baseline/final comparison report | 5 → Opus |

### Phase 9 + Evidence

| # | Title | Score → Agent |
|---|---|---|
| 24 | HBM2e integration: benchmark_device_top, AXI adapters, behavioral model in sim | 8 → Opus |
| 25 | Evidence package + executive summary + reproducibility doc | 4 → Opus |

Simple sub-tasks inside any issue (file boilerplate, .gitkeep trees, report formatting,
label management) are delegated to Sonnet agents (score ≤3) by the orchestrator or the
executing workflow.

## Sequencing and parallelism

- 1 → (2 ∥ 3) → 4 → (5 ∥ 7) → 6 → 8 → 9 → (10 ∥ 11) → (12 ∥ 13 ∥ 14) → (15 ∥ 16) → 17
  → (18 ∥ 19) → 20 → 21 → 22 → 23 → (24 ∥ 25 after 23)
- Calibration compiles (SPEC §18) are folded into the kernel issues (9–16): each kernel
  issue must land its own Quartus calibration data in `results/synthesis/` before the
  full-scale parameters are frozen in issue 20.

## Standing rules for every PR

1. Branch per issue, PR references the issue, squash-merge after review.
2. CI-equivalent local gate (`make lint` + relevant `sim-*` targets) must pass; command
   transcripts pasted into the PR description.
3. No generated files committed (except reproducible vendor IP recipes).
4. DECISIONS.md gets one dated entry per architectural decision or parameter change.
5. Latency changes update scoreboard metadata only — never expected numerical values.
