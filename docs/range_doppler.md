# Range-Doppler mapping in this benchmark

> **Issue #44 (part 1).** This document is the reader-facing explanation of the
> fast-time / slow-time mapping the reference-chain range-Doppler map assumes.
> **Part 2 of #44 (now landed)** adds the sim-injection CFAR detection
> test that turns a picture into a pass/fail — see the [hardware
> cross-check](#hardware-cross-check-issue-44-part-2) section at the bottom.
> This is the picture.

## The pipeline, and what each axis is

The verified pipeline (SPEC.md §3) is:

```text
Synthetic ADC -> PFB -> FFT -> Time-Frequency History -> Alignment ->
Beamformer -> Power/Covariance -> CFAR
```

Two of those stages already define the range-Doppler axes:

* The per-antenna **FFT** turns an FFT_SIZE fast-time sample window into an
  FFT_SIZE-bin spectrum. **Bin index is the range gate.** A target at range
  bin `k_r` shows up as a peak at column `k_r` of the frame's spectrum.

* The **time-frequency history** stacks `HISTORY_FRAMES` such spectra one on
  top of the next, keyed by frequency bin. The history is what makes a
  second, slow-time, transform possible across the frame axis at each bin.
  **The FFT of a bin's history, across frames, is that bin's Doppler
  spectrum.** A target whose fast-time phase advances by `k_d` cycles per
  `HISTORY_FRAMES` frames peaks at Doppler bin `k_d`.

This is the standard fast-time / slow-time decomposition of a coherent
processing interval, made concrete by the pipeline's structure: the fast-time
FFT is done in the hardware datapath; the slow-time FFT lives in the
reference/visualisation layer (SPEC.md §7 explicitly does not add a
hardware slow-time FFT — see the "Out of scope" note on issue #44).

## Ground-truth signal model

The generator (`model/python/gen_target_iq.py`) synthesizes each target as
three separable phase progressions summed at a chosen amplitude:

```text
s_r[f, a, n] = amp_r
             * exp(j 2 pi k_r n / FFT_SIZE)         # range tone (fast-time)
             * exp(j 2 pi k_d f / HISTORY_FRAMES)   # Doppler phase (slow-time)
             * exp(j 2 pi phi_r a / N_ANTENNAS)     # per-antenna gradient (angle)
```

for frame `f`, antenna `a`, sample-within-frame `n`. The AWGN floor is
independent complex Gaussian with std `noise_sigma`. A stationary clutter
ridge (Doppler bin 0, fixed range bin) can be added; the built-in
`three_targets` scenario leaves it off. Every real component goes through
`fxp_reference.round_sat` — the same rounding rule NUMERICS.md §4 requires
of every fixed-point path in the design — so the IQ handed to the pipeline
is bit-exact Q1.15.

## What the visualiser does

`model/python/range_doppler.py` reads the scenario, runs the bit-exact
polyphase FIR bank with the identity coefficient set (the SPEC 7.1 `ident`
pass-through — the one filter whose expected output is its input), does a
per-frame FFT across fast-time, then a slow-time FFT across the frame axis
at each range bin. The result is a `(HISTORY_FRAMES, N_ANTENNAS, FFT_SIZE)`
complex map, one range-Doppler plane per antenna. Doppler is fftshifted so
bin 0 (stationary) sits at the centre of the vertical axis.

Why the identity PFB and a float FFT here: this script's job is a **reference
picture**, not the RTL oracle. The RTL FFT is proved bit-exact against
`model/vectors/fft64.vec` by SPEC §7.2's test; part 2 of #44 will prove
the RTL's picture agrees with this one on the same IQ. Using a real windowed
PFB prototype here would broaden every peak; using the RTL's fixed-point FFT
scaling schedule would drop the weak target below the noise after eight
stages of a 256-point transform. Either would obscure what the picture is
supposed to show: **where energy lands when the pipeline is doing what it
should**. See the docstring of `range_doppler.py` for the rationale in more
depth.

## Example

Running the built-in three-target scenario:

```bash
make scenario SCENARIO=three_targets SEED=1
```

produces one PNG per antenna under
`results/scenarios/three_targets_seed1/`. The output is generated
(gitignored) so a reader must run the target locally; the PR that opened
this document (#44 part 1) includes a transcript of the ground-truth-vs.
-peak table it prints alongside the plots. Antenna 1's plane, for
example, holds the strong 20 dB target at range bin 32 and Doppler bin +2:

```text
target       range_bin(gt/peak/dr)  doppler_bin(gt/peak/dr)  angle_idx(gt/peak/dr)  mag[dB]
-------------------------------------------------------------------------------------------
t0_strong     32/ 32/+0              2/  2/+0                 1/  2/+1               +0.0
t1_moderate   67/ 67/+0             13/ 13/+0                 2/  3/+1               -8.0
t2_weak       96/ 96/+0              7/  7/+0                 3/  2/-1              -14.0
```

The three targets appear as bright spots at their ground-truth positions
in the plotted maps (white circles = target-centred antenna, grey X = the
same target's expected location on this antenna's plane). The acceptance
gate for this part of #44 is every target within ±1 bin of ground truth
in (range, Doppler); the row-by-row `dr` / `dd` columns above are that
check made visible.

## Where each bin index appears

| Axis      | Bin range           | Origin                                       |
|-----------|---------------------|----------------------------------------------|
| Range     | 0 .. FFT_SIZE-1     | FFT bin index, natural order                 |
| Doppler   | -HISTORY_FRAMES/2 .. HISTORY_FRAMES/2-1 | slow-time FFT after fftshift |
| Antenna   | 0 .. N_ANTENNAS-1   | ADC channel index                             |

Ground truth in `scenario.json` records Doppler as an **unshifted** bin
0..HISTORY_FRAMES-1, matching the raw slow-time FFT output. The visualiser
maps that to the shifted axis (`k -> (k + H/2) % H`) before overlaying the
marker, so the picture and the JSON stay consistent.

## References

* SPEC.md §3 (system architecture), §7 (per-stage blocks), §7.7 (CFAR).
* `model/python/gen_target_iq.py`, `model/python/range_doppler.py`.
* `model/python/fxp_reference.py` (bit-exact Q1.15 rounding rule).
* `model/vectors/README.md` (the ASCII vector-file convention the
  `scenario.iq` format follows).
* Issue #44 (this document opened as part 1 of that issue; part 2 adds
  the sim-injection CFAR test — see below).

## Hardware cross-check (issue #44, part 2)

Part 1 answers the question *does the scene we generated show up in the
right (range, Doppler) bin under the reference chain*. Part 2 answers
the harder question: *does the same scene, fed through the RTL
pipeline, produce CFAR detections at the right bin*. It is the sim-side
acceptance gate for the scenario generator.

The test is `sim/tests/test_pipeline_scenario.cpp` (built as
`Vpipeline_top_test_pipeline_scenario`), driven by the Makefile target
`make sim-scenario`. The target generates one IQ scenario per seed with
`gen_target_iq.py` and injects it through `benchmark_pipeline_top` via
the same C++ harness (`sim/verilator/harness/pipeline_tb.h`) as the
other issue-#17 pipeline tests. See
`sim/verilator/harness/iq_loader.{h,cpp}` for the ASCII IQ reader.

### What the RTL sees vs. what the reference chain sees

The RTL medium pipeline computes power and CFAR from **only** beam 0,
lane 0 of each beamformer beat (DECISIONS.md 2026-07-27 Decision 7).
With `BIN_PAR = 2`, the alignment network's LANE assignment is
`LANE = bin mod BIN_PAR = bin[0]`. Lane 0 therefore carries the EVEN
FFT bins; lane 1 carries the ODD FFT bins. So:

* A target on an ODD FFT bin is **invisible to the tap** — the reference
  map still shows it, but no CFAR detection can fire.
* A target on an EVEN FFT bin `K` shows up at CFAR bin `K // BIN_PAR`.

Beam discrimination is **also unavailable** at Phase 3. With uniform
beamformer weights (bank-1 = 0x1000 per lane, programmed by
`Session::program_and_swap_to_active_banks`) coherent addition of a
per-antenna phase gradient `exp(j 2 pi angle_idx * a / N_ANT)` sums to
zero unless `angle_idx == 0 (mod N_ANT)`. So a Phase-3 scenario aimed at
the tapped path must place every target at `angle_idx = 0`, and the
"right beam" check reduces to "did the beam-0 tap see it".

The `three_targets_even` built-in scenario satisfies both conditions
(even FFT bins, angle_idx = 0). The original `three_targets` scenario
does not (bin 67 is odd; angles are 1/2/3) and is not appropriate for
the sim-injection gate — but it remains the canonical map scenario for
part 1's picture-only gate.

Phase 5 (issue #20) is the follow-up that removes both narrowings: the
full-scale AGMF039 elaboration fans the beamformer beat out per
(beam, bin) and instantiates one power/covariance/CFAR per pair, at
which point beam discrimination is real and every FFT bin is tapped.

### Tolerances (documented in DECISIONS.md 2026-07-27)

* **Bin tolerance**: ±1 CFAR bin around each target's expected CFAR
  bin. The reference chain's peak table (`range_doppler.py`) uses the
  same tolerance for the fixed-point-vs-float comparison, so the two
  gates are consistent.
* **False-alarm bound**: ≤ 6 DETECT events across all 16 frames of the
  scenario, at CFAR settings guard = 1 lead / 1 lag, ref = 8 lead / 8
  lag, alpha = 8.0 (UQ8.8 = 0x0800), mode = cell-averaging. At the
  designed noise floor (`noise_sigma = 0.005`) this fits the analytic
  Pfa the alpha choice implies, times the ~110 fittable CFAR bins per
  frame times 16 frames.
* **Detection rule**: a target counts as detected if any frame in the
  16-frame run produced a DETECT at a CFAR bin within ±1 of the target's
  expected CFAR bin. Doppler modulates only phase (not magnitude at the
  target's fast-time bin), so detection is sustained across frames; a
  single frame's DETECT sighting is sufficient.
* **Beam-check limitation**: the sim test cannot check angle_idx (only
  beam 0 is tapped in Phase 3, and every scenario target has
  angle_idx = 0). The reference map (`range_doppler.py`) still checks
  angle by antenna, so the picture-gate covers the axis the sim gate
  cannot.

### Running it

```bash
# Part-2 sim gate: generate + inject + check, on seeds 1 / 2 / 3.
make sim-scenario                              # SEEDS defaults to '1 2 3'
make sim-scenario SEEDS='1'                    # one seed
make sim-scenario SIM_SCENARIO_SCENARIO=<name> # a different named scenario
```

The target uses the existing pipeline build plumbing (`--config medium`,
`--top pipeline_top`, `--files sim/verilator/files_pipeline.f`) via
`scripts/build_verilator.py`. Total wall-clock for three seeds is well
under one minute on the reference host: one build (~20 s) + three runs
(< 1 s each).

The test prints a ground-truth-vs-detected table like
`range_doppler.py`'s peak table:

```text
target       fft_bin  cfar_bin  hits/frames  detected?  hit-bins
------------------------------------------------------------------------
t0_strong       40       20      16/ 16        YES      20
t1_moderate     96       48      15/ 16        YES      48
t2_weak        160       80      15/ 16        YES      80
total DETECT events: 47, false alarms: 1 (bound 6)
```

which is what turns the reference-chain map (`range_doppler.py`'s PNGs)
into a hardware-side pass/fail.
