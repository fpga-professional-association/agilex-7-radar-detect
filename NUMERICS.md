# Numerics

The single normative definition of every fixed-point format, growth rule, rounding mode,
and saturation policy used in the benchmark. The RTL package under `rtl/packages/` and
the C++ reference model under `model/cpp/` are both derived from this document and must
be bit-identical to it; where this document and an implementation disagree, the
implementation is wrong. Governing requirements: [SPEC.md](SPEC.md) §6 (numerical
definition) and §7 (per-block arithmetic).

> **Status: skeleton (issue #1).** Headings only. No format, width, or policy is
> asserted here until issue #4 lands the shared package and its bit-accuracy proof.

## 1. Scope and invariants

Invariant widths from SPEC §3: `SAMPLE_W=16`, `COEFF_W=16`, `POWER_W=40`. These are held
constant across all four size configurations in `config/*.json`.

TODO — populated by issue #4.

## 2. Input and coefficient formats

Complex sample representation (signed I and Q), coefficient representation, and their
Q-format notation.

TODO — populated by issue #4. See SPEC §6 "Input format" and "Coefficients".

## 3. Multiplication and bit growth

Product widths, guard bits, and the growth rule applied at each arithmetic stage.

TODO — populated by issue #4. See SPEC §6 "Multiplication".

## 4. Rounding policy

Rounding mode, tie-breaking behaviour, and where rounding is applied versus deferred.

TODO — populated by issue #4. See SPEC §6 "Rounding and saturation".

## 5. Saturation policy

Saturation points, saturation flags, and how saturation events are counted and reported
to the telemetry plane.

TODO — populated by issue #4; telemetry hookup by issue #8.

## 6. Per-block numerical contracts

### 6.1 Polyphase FIR bank

TODO — populated by issue #10.

### 6.2 Streaming FFT and scaling schedule

TODO — populated by issue #11. The scaling schedule is normative and must be stated
explicitly per stage.

### 6.3 Beamforming dot product and accumulation tree

TODO — populated by issue #12.

### 6.4 Power and covariance

TODO — populated by issue #13.

### 6.5 CFAR thresholding

TODO — populated by issue #14.

## 7. Bit-accuracy methodology

How RTL/model equivalence is established and maintained: shared parameter source,
directed boundary vectors, randomized comparison, and the failure-triage procedure.

TODO — populated by issue #4; extended per kernel by issues #9–#14. Test mechanics live
in [VERIFICATION_PLAN.md](VERIFICATION_PLAN.md).

## 8. Arithmetic boundary coverage

Enumerated boundary conditions (extremes, sign transitions, saturation edges) that every
kernel must exercise.

TODO — populated by issue #4 and enforced by the Phase 2 gate (SPEC §19).
