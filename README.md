# Agilex 7 Wideband Processing Benchmark

Large, functionally meaningful, timing-constrained FPGA design targeting
**AGMF039R47B1E1VC** (Agilex 7 M-Series, M039 density, R47B package: 1,305,600 ALMs,
18,960 M20Ks, 12,300 DSP blocks, HBM2e, 4x F-Tile).

Built autonomously by an AI agent to demonstrate AI-driven FPGA architecture,
verification, scaling, and Quartus timing closure. See [SPEC.md](SPEC.md) for the
governing specification and [PLAN.md](PLAN.md) for the execution plan and issue map.

## What this is

A scalable wideband multichannel signal-processing system:

```
ADC sources → polyphase FIR banks → streaming FFTs → time-frequency history
→ frequency-bin alignment → complex beamforming → power/covariance → CFAR
→ event packet network → DMA/HBM abstract memory interface
```

One parameterized RTL codebase elaborates at four sizes (`tiny`, `medium`, `large`,
`full_agmf039`). Verification runs at small scale under Verilator against a
bit-accurate C++ reference model; the full configuration is the Quartus
timing-closure benchmark.

## Environment

| Tool | Where | Version |
|---|---|---|
| Quartus Prime Pro | Windows, `C:\altera_pro\26.1\quartus` | 26.1.0 Pro |
| Verilator | WSL Ubuntu-24.04 | 5.020 |
| GNU Make, g++ | WSL Ubuntu-24.04 | 4.3, 13.3 |

Simulation targets run in WSL; Quartus targets run on Windows. See PLAN.md for the
dispatch rules.

## Build entry points

```bash
make lint             # Verilator lint (WSL)
make sim-tiny         # tiny-config regression (WSL)
make sim-medium       # medium-config regression (WSL)
make quartus-map      # Analysis & Synthesis (Windows)
make quartus-compile  # full compile + STA + JSON reports (Windows)
```

Full list in SPEC.md §16.

## Status

Bootstrap phase. Progress is tracked in
[GitHub issues](https://github.com/fpga-professional-association/agilex-7-radar-detect/issues);
each issue lands as one reviewed PR.
