# Range-Doppler mapping in this benchmark

> **Issue #44 (part 1).** This document is the reader-facing explanation of the
> fast-time / slow-time mapping the reference-chain range-Doppler map assumes.
> Part 2 of #44 (blocked on issue #17) adds the sim-injection CFAR detection
> test that turns a picture into a pass/fail. This is the picture.

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
* Issue #44 (this document is part 1 of that issue; the sim-injection
  CFAR test that turns a picture into a pass/fail is part 2, blocked on
  issue #17).
