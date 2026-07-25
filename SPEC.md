# Autonomous Agilex 7 Wideband Processing Benchmark

Governing project specification. This document is the contract for all work in this
repository. Do not change the specification to match an incorrect implementation.

## 1. Mission

Create a large, functionally meaningful, timing-constrained FPGA design targeting:

```text
AGMF039R47B1E1VC
```

The design must implement a scalable wideband multichannel signal-processing system and
deliberately exercise:

* DSP placement and routing.
* M20K placement and routing.
* Wide streaming datapaths.
* High-fanout control.
* Ready/valid feedback paths.
* Multiple clock domains.
* Clock-domain crossings.
* Large memories and corner-turn buffers.
* Cross-chip communication.
* HyperFlex retiming.
* Congestion-aware hierarchy.
* Quartus timing closure.

The goal is not merely to generate correct RTL. The goal is to demonstrate that an AI
agent can:

1. Produce a complex FPGA architecture.
2. Verify it without relying on slow full-chip event-driven simulation.
3. Scale it near the limits of an Agilex 7 device.
4. Read Quartus reports.
5. Identify physical implementation bottlenecks.
6. Modify RTL, constraints, hierarchy, and implementation settings.
7. Improve timing while preserving behavior.
8. Produce repeatable results across fixed fitter seeds.

Do not use the Quartus GUI. All operations must be reproducible through shell, Python,
Tcl, Make, CMake, or equivalent scripts.

## 2. Device Facts and Resource Targets

Target device resources:

```text
Device:        AGMF039R47B1E1VC
Family:        Agilex 7 M-Series
Density:       M039
Package:       R47B
Pin count:     4700
ALMs:          1,305,600
ALM registers: 5,222,400
M20K blocks:   18,960
M20K capacity: approximately 370 Mb
DSP blocks:    12,300
18x19 mults:   24,600
```

The package includes HBM2e and four F-Tiles. Do not make HBM2e or F-Tile simulation a
prerequisite for the custom RTL benchmark. Create clean abstraction layers so that
behavioral models are used under Verilator and vendor IP is used only in the Quartus
implementation wrapper.

### Initial implementation targets

After scaling, aim for:

```text
DSP utilization:       75%-90%
M20K utilization:      55%-80%
ALM utilization:       55%-80%
Primary clock target:  450 MHz initial
Stretch clock target:  500-550 MHz
Required seed closure: at least 8 of 10 fixed seeds
Unconstrained paths:   zero
```

These are targets, not permission to invent useless logic. Every major block must have a
defensible signal-processing, buffering, control, or routing purpose.

Do not assume the resource formula is exact. First synthesize reduced instances and
measure actual Quartus mapping. Scale parameters from measured results.

## 3. System Architecture

The design shall implement this pipeline:

```text
Synthetic ADC Sources
        |
        v
Per-Antenna Polyphase FIR Banks
        |
        v
Parallel Streaming FFT Banks
        |
        v
Time-Frequency History / Corner-Turn Memory
        |
        v
Frequency-Bin Alignment Network
        |
        v
Complex Beamforming Matrix
        |
        v
Power and Covariance Processing
        |
        v
CFAR Detection
        |
        v
Event Aggregation and Packet Routing
        |
        v
DMA / HBM Abstract Memory Interface
```

### Nominal full-scale configuration

Use these as the initial architectural parameters:

```systemverilog
parameter int N_ANTENNAS        = 16;
parameter int SAMPLES_PER_CYCLE = 8;
parameter int SAMPLE_W          = 16;
parameter int COEFF_W           = 16;
parameter int FFT_SIZE          = 1024;
parameter int PFB_TAPS          = 16;
parameter int N_BEAMS           = 16;
parameter int POWER_W           = 40;
parameter int HISTORY_FRAMES    = 512;
parameter int PACKET_W          = 512;
parameter int N_VIRTUAL_CHANS   = 4;
```

Parameters may be adjusted after resource-calibration compilations, but their values and
the justification for every change must be recorded.

### Interpretation

* There are 16 antenna or sensor streams.
* Each stream accepts eight complex samples per processing cycle.
* Each complex sample contains signed I and Q components.
* Each stream passes through a 16-tap polyphase filter bank.
* Each antenna has an independent parallel streaming FFT.
* FFT output is stored in a banked time-frequency history.
* Samples from matching frequency bins are aligned across antennas.
* A complex beamforming matrix produces up to 16 simultaneous beams.
* Power and covariance products are calculated.
* CFAR identifies statistically significant events.
* Events enter a packet-routing and aggregation fabric.
* Bulk data and event records are accessible through an abstract memory interface.

## 4. Required Top-Level Variants

Create three top levels.

### 4.1 `benchmark_sim_top`

Purpose:

* Verilator simulation.
* No encrypted or proprietary vendor models.
* Behavioral memory model.
* Synthetic clocks and resets.
* Direct C++ access to ingress, configuration, and output streams.

### 4.2 `benchmark_fabric_top`

Purpose:

* Primary Quartus timing-closure benchmark.
* Custom fabric RTL only.
* May include lightweight clock and memory-interface stubs.
* Must not depend on successful HBM2e or transceiver IP generation.
* Must contain the complete processing, buffering, routing, and control fabric.

This is the reproducible benchmark used to prove AI-driven timing closure.

### 4.3 `benchmark_device_top`

Purpose:

* Device-specific integration.
* Instantiates generated HBM2e and any required clocking IP.
* Connects the abstract memory interface to HBM2e AXI interfaces.
* Optionally connects F-Tile interfaces in a later phase.
* Must not contaminate the portable processing hierarchy with vendor-specific interfaces.

The first major result should come from `benchmark_fabric_top`. HBM2e integration is a
later extension, not a gate for the timing-closure experiment.

## 5. Streaming Protocol

Use a common synthesizable streaming interface throughout the design.

Each stream shall include at least:

```systemverilog
logic                 valid;
logic                 ready;
logic [DATA_W-1:0]    data;
logic                 start_of_frame;
logic                 end_of_frame;
logic [STREAM_ID_W-1:0] stream_id;
logic [SEQ_W-1:0]     sequence;
logic [USER_W-1:0]    user;
```

Requirements:

* Transfer occurs only when `valid && ready`.
* A source must hold payload and metadata stable while stalled.
* Backpressure may occur on every internal interface.
* Frame boundaries must survive arbitrary backpressure.
* Sequence numbers must permit end-to-end loss and ordering checks.
* No combinational ready loop may cross more than one module boundary.
* Insert elastic buffers where needed.
* Add assertions for protocol stability and transaction preservation.

Do not use a combinational `ready` chain across the entire pipeline.

## 6. Numerical Definition

Use signed fixed-point arithmetic.

### Input format

```text
I component: signed 16-bit
Q component: signed 16-bit
Nominal interpretation: Q1.15
```

### Coefficients

```text
Signed 16-bit
Nominal interpretation: Q1.15
```

### Multiplication

For a normal four-real-multiply complex product:

```text
real = a_i*b_i - a_q*b_q
imag = a_i*b_q + a_q*b_i
```

Also implement an optional three-real-multiply complex multiplier. The implementation
choice must be parameterized so Quartus results can compare:

* DSP consumption.
* ALM consumption.
* Pipeline depth.
* Routing pressure.
* Fmax.
* Power estimate.

### Rounding and saturation

Define one shared package containing:

* Signed rounding rules.
* Convergent or round-to-nearest behavior.
* Saturation functions.
* Truncation locations.
* Accumulator widths.
* Overflow flags.

Do not allow each module to invent its own rounding behavior.

The C++ reference model and RTL must use identical numerical rules.

## 7. Signal-Processing Blocks

### 7.1 Polyphase FIR bank

Create a parameterized complex FIR/PFB module.

Requirements:

* Eight samples accepted per cycle in the nominal configuration.
* Sixteen taps per phase in the nominal configuration.
* Coefficients held in dual coefficient banks.
* Coefficient updates occur through the configuration domain.
* Active coefficient bank may change only at a safe frame boundary.
* Pipeline stages must be configurable.
* Delay lines should infer M20Ks when their size makes that appropriate.
* The multiplier structure must map naturally to DSP blocks.
* Valid metadata must travel with the corresponding samples.
* No global reset should unnecessarily reset large datapath arrays.

Verification cases:

* Zero input.
* Complex impulse.
* Constant input.
* Single complex sinusoid.
* Random samples.
* Maximum positive and negative values.
* Saturation.
* Coefficient-bank swap.
* Random output backpressure.

### 7.2 Parallel streaming FFT

Create a parameterized 1024-point streaming FFT.

Preferred architecture:

* Radix-2^2 single-path delay feedback or another deeply pipelined streaming architecture.
* Eight complex samples per cycle.
* Fixed-point scaling schedule.
* Frame-continuous operation.
* Twiddle ROMs inferred into memory.
* Twiddle multipliers inferred into DSPs.
* No dependence on vendor FFT IP for the principal benchmark.

The first implementation may begin with:

```text
FFT_SIZE=64
SAMPLES_PER_CYCLE=2
```

Scale only after verification.

Verification cases:

* Impulse.
* DC.
* Single-bin tone.
* Negative-frequency tone.
* Two tones.
* Random vectors compared against the bit-accurate model.
* Back-to-back frames.
* Stalls between and within frames.
* Scaling and overflow behavior.

### 7.3 Time-frequency history and corner turn

Implement a banked memory subsystem that:

* Stores FFT frames by antenna, time, and frequency.
* Supports continuous writes.
* Supports beamformer reads organized by common frequency bin.
* Maintains a programmable history depth.
* Uses multiple independently addressable banks.
* Supports double buffering or rotating frame banks.
* Avoids a single globally broadcast address and enable network.
* Exposes occupancy, overwrite, collision, and error counters.

The nominal `HISTORY_FRAMES=512` is intended to create meaningful M20K utilization.
Reduce this parameter in simulation configurations.

### 7.4 Frequency alignment network

Create a pipelined network that rearranges FFT outputs into beamformer vectors.

A beamformer vector contains one complex value from each antenna for a common
frequency-bin and time index.

The network must:

* Preserve antenna identity.
* Preserve frequency-bin identity.
* Preserve frame identity.
* Support backpressure.
* Detect missing or duplicated samples.
* Avoid one giant unregistered multiplexer.

Compare at least two architectures:

1. Direct crossbar.
2. Multistage or Clos-style pipelined network.

Record area, congestion, latency, and Fmax for both.

### 7.5 Beamforming matrix

Implement:

```text
Y[b] = sum over antennas a of X[a] * W[b][a]
```

Requirements:

* Complex input samples.
* Complex programmable weights.
* Up to 16 antennas.
* Up to 16 beams.
* Eight frequency bins processed per cycle in the nominal architecture, unless measured
  DSP usage requires a lower parallelization factor.
* Weight double buffering.
* Safe weight-bank switching.
* Pipelined accumulation tree.
* Saturation and overflow reporting.
* Parameterized multiplier implementation.
* Parameterized beam and bin parallelism.

Do not silently reduce throughput to meet utilization. Any time multiplexing must be
visible in parameters and reported throughput.

### 7.6 Power and covariance processing

Calculate at least:

```text
Power = I^2 + Q^2
```

Also implement a configurable covariance or cross-power engine for selected antenna or
beam pairs:

```text
Rxy = X * conjugate(Y)
```

Requirements:

* Programmable integration window.
* Accumulator protection.
* Window-boundary metadata.
* Optional exponential averaging.
* Runtime enable per covariance pair.
* Deterministic reset and flush behavior.

### 7.7 CFAR detector

Implement a configurable one-dimensional CFAR detector over frequency bins.

At minimum support:

* Cell-averaging CFAR.
* Programmable guard-cell count.
* Programmable reference-cell count.
* Programmable threshold multiplier.
* Edge handling.
* Detection metadata.
* Detection suppression under invalid or incomplete windows.

Optional extension:

* Greatest-of CFAR.
* Ordered-statistics CFAR.

### 7.8 Event aggregator and packet network

Create a packet network carrying:

* Detection events.
* Power summaries.
* Covariance summaries.
* Error events.
* Performance counters.
* Optional raw-data capture records.

Nominal network:

```text
16 or more ingress ports
512-bit packet width
4 virtual channels
Pipelined arbitration
Credit or ready/valid flow control
```

Do not build one unregistered, monolithic crossbar. Implement a pipelined multistage
fabric with explicit arbitration and buffering.

This block is expected to create substantial ALM and routing pressure.

## 8. Clock Domains

Use at least these logical clock domains in the full benchmark:

```text
core_clk:       processing datapath
history_clk:    history/corner-turn memory
packet_clk:     packet network
memory_clk:     abstract HBM/DMA interface
cfg_clk:        register and coefficient configuration
telemetry_clk:  counters and health monitoring
```

Suggested initial constraints:

```text
core_clk:       450 MHz
history_clk:    400 MHz
packet_clk:     400 MHz
memory_clk:     350 MHz
cfg_clk:        100 MHz
telemetry_clk:  200 MHz
```

These are benchmark constraints, not guaranteed device limits.

Requirements:

* Use asynchronous FIFOs for bulk CDC traffic.
* Use proper synchronizers for single-bit status.
* Use toggle or handshake synchronizers for pulses.
* Use Gray-coded pointers for asynchronous FIFOs.
* Do not synchronize a multibit bus by independently synchronizing every bit.
* Add CDC-specific assertions.
* Generate an explicit CDC inventory report.

Avoid resetting every datapath register. Reset control state, valid pipelines, pointers,
and safety state. Flush invalid datapath contents using validity tracking.

## 9. Register and Control Plane

Create a portable 32-bit register interface with:

```text
address
write_data
read_data
write_enable
read_enable
byte_enable
ready
error
```

An APB or Avalon-MM wrapper may be added, but the internal register fabric must remain
vendor-neutral.

Register groups:

* Global identification.
* Build parameters.
* Per-block enable and reset.
* Coefficient and weight programming.
* Active bank selection.
* CFAR settings.
* Integration settings.
* Stream counters.
* Stall counters.
* FIFO high-water marks.
* Overflow and saturation counts.
* Frame counts.
* Sequence errors.
* CDC errors.
* Fault injection.
* Snapshot and debug control.

All registers must be documented in a generated machine-readable register map.

## 10. Repository Structure

Create this structure:

```text
agilex7-wideband/
├── README.md
├── SPEC.md
├── ARCHITECTURE.md
├── NUMERICS.md
├── VERIFICATION_PLAN.md
├── TIMING_CLOSURE_PLAN.md
├── DECISIONS.md
├── Makefile
├── CMakeLists.txt
├── requirements.txt
├── config/
│   ├── tiny.json
│   ├── medium.json
│   ├── large.json
│   └── full_agmf039.json
├── rtl/
│   ├── packages/
│   ├── common/
│   ├── stream/
│   ├── cdc/
│   ├── memory/
│   ├── pfb/
│   ├── fft/
│   ├── beamformer/
│   ├── covariance/
│   ├── cfar/
│   ├── packet/
│   ├── control/
│   └── top/
├── model/
│   ├── cpp/
│   ├── python/
│   └── vectors/
├── sim/
│   ├── verilator/
│   ├── tests/
│   ├── assertions/
│   └── failures/
├── quartus/
│   ├── project/
│   ├── constraints/
│   ├── assignments/
│   ├── ip/
│   └── scripts/
├── scripts/
│   ├── build_verilator.py
│   ├── run_regression.py
│   ├── generate_coefficients.py
│   ├── parse_quartus.py
│   ├── seed_sweep.py
│   ├── compare_runs.py
│   └── make_dashboard.py
├── results/
│   ├── simulation/
│   ├── synthesis/
│   ├── timing/
│   └── seed_sweeps/
└── ci/
```

No generated files should be committed unless they are required to reproduce vendor IP.

## 11. Configuration Sizes

Use the same RTL for all configurations.

### Tiny

```text
N_ANTENNAS=2
SAMPLES_PER_CYCLE=1
FFT_SIZE=64
PFB_TAPS=4
N_BEAMS=2
HISTORY_FRAMES=4
PACKET_W=64
```

Purpose:

* Unit tests.
* Fast lint.
* Fast randomized simulation.
* Debug traces.

### Medium

```text
N_ANTENNAS=4
SAMPLES_PER_CYCLE=2
FFT_SIZE=256
PFB_TAPS=8
N_BEAMS=4
HISTORY_FRAMES=16
PACKET_W=128
```

Purpose:

* Integration regression.
* CDC testing.
* Backpressure testing.
* Coverage.

### Large

```text
N_ANTENNAS=8
SAMPLES_PER_CYCLE=4
FFT_SIZE=1024
PFB_TAPS=16
N_BEAMS=8
HISTORY_FRAMES=64
PACKET_W=256
```

Purpose:

* Pre-synthesis integration.
* Longer stress tests.
* Early Quartus calibration.

### Full AGMF039

```text
N_ANTENNAS=16
SAMPLES_PER_CYCLE=8
FFT_SIZE=1024
PFB_TAPS=16
N_BEAMS=16
HISTORY_FRAMES=512
PACKET_W=512
```

Purpose:

* Full-device Quartus benchmark.
* Short full-scale Verilator smoke tests.
* Seed sweeps.
* Timing-closure optimization.

Never create a separate hand-written implementation for the small configurations. They
must elaborate from the same modules.

## 12. Verilator Simulation Strategy

Verilator is the primary simulator.

Verilator compiles SystemVerilog into a C++ or SystemC model and supports assertions,
coverage, multithreaded models, and FST tracing. Use these capabilities selectively;
tracing and coverage should not be enabled in the fastest regression build.

### 12.1 Build modes

Create four simulation builds.

#### Lint build

Purpose:

* Syntax.
* Width errors.
* Latches.
* Unused signals.
* Incomplete cases.
* Suspicious signed arithmetic.

Conceptual command:

```bash
verilator --lint-only \
  --Wall \
  --Wno-fatal \
  --top-module benchmark_sim_top \
  -f sim/verilator/files.f
```

Warnings may be waived only through a checked-in waiver file containing a written
justification.

#### Fast build

Purpose:

* Maximum tests per second.
* No waveforms.
* No coverage.
* Optimized C++.
* Assertions enabled.

Conceptual command:

```bash
verilator \
  --cc \
  --exe \
  --build \
  --assert \
  --threads 8 \
  -CFLAGS "-O3 -march=native" \
  --top-module benchmark_sim_top \
  -f sim/verilator/files.f \
  sim/verilator/sim_main.cpp
```

Measure whether multithreading improves this particular model. Do not assume more
threads are automatically faster.

#### Coverage build

Purpose:

* Line coverage.
* Branch coverage.
* Toggle coverage.
* FSM coverage.
* User cover properties.

Merge coverage from randomized tests and generate annotated source and summary reports.

#### Debug build

Purpose:

* FST waveform generation.
* Limited hierarchy depth.
* Enabled only for a failing test.
* Reuses the exact failing random seed.

Use FST, not VCD, for substantial traces. Limit trace depth and omit enormous arrays.

### 12.2 C++ simulation harness

Implement a native C++ harness.

Do not place the main randomized test engine in Python.

The C++ harness shall provide:

* Multiple clock generation.
* Event scheduling.
* Reset sequencing.
* Register reads and writes.
* Stream drivers.
* Randomized backpressure.
* Memory model.
* Reference-model invocation.
* Scoreboards.
* Timeout detection.
* Assertion and error collection.
* Failure minimization metadata.
* Optional FST tracing.
* Deterministic random seeds.

Python may launch tests, aggregate results, generate coefficients, and produce reports.
It must not be in the per-cycle execution path.

### 12.3 Clock scheduler

Do not use SystemVerilog delay-based clock generators in the fast build.

Implement a C++ event scheduler that:

1. Tracks the next edge time of every clock.
2. Advances to the earliest scheduled edge.
3. Toggles all clocks with an edge at that time.
4. Calls `eval()`.
5. Performs driver and monitor work on appropriate edges.
6. Stops on pass, failure, or timeout.

Use integer simulation time units that represent all selected clock periods exactly
enough for CDC testing.

### 12.4 Reference model

Create a bit-accurate C++ reference library.

It must contain:

* Complex fixed-point types.
* Saturation.
* Rounding.
* FIR/PFB.
* FFT.
* Beamforming.
* Power.
* Covariance.
* CFAR.
* Packet generation.

The C++ model and RTL must load the same coefficient and weight files.

Validate the C++ model independently against Python, NumPy, or MATLAB-generated vectors
before using it as the RTL oracle.

### 12.5 Scoreboard strategy

Do not require one fixed end-to-end latency when elastic buffering is enabled.

Use transaction identity:

```text
stream_id
frame_id
sequence
antenna
frequency_bin
beam
```

Maintain expected output queues keyed by transaction identity.

Check:

* No lost transactions.
* No duplicated transactions.
* Correct ordering where ordering is required.
* Correct numerical result.
* Correct frame metadata.
* Correct response to backpressure.
* Bounded maximum latency.
* No output generated from invalid or incomplete input.

## 13. Verification Tests

### 13.1 Unit tests

Every module must have:

* Directed nominal tests.
* Directed boundary tests.
* Randomized tests.
* Protocol assertions.
* Reset tests.
* Stall tests.
* Parameter-edge tests.

### 13.2 Metamorphic tests

Use properties that remain valid without requiring large golden-data files:

* Zero input produces zero signal output.
* An impulse produces the programmed impulse response.
* Scaling an unsaturated input scales the output.
* Delaying input delays output without changing values.
* Adding legal backpressure does not change transaction content.
* Changing inactive coefficient memory has no immediate effect.
* Bank changes affect only permitted frame boundaries.
* Permuting antenna inputs and weights consistently produces equivalent beam outputs.
* Packet-network output is invariant to unrelated port stalls.
* Reset followed by the same stimulus produces the same outputs.

### 13.3 Random testing

Randomize:

* Input samples.
* Signal amplitudes.
* Tone frequencies.
* Coefficients.
* Beam weights.
* Frame lengths where legal.
* Output stalls.
* Clock phase relationships.
* Configuration access timing.
* Coefficient-bank changes.
* Memory response latency.
* FIFO pressure.
* Packet destinations.
* Fault injection.

Every test must print a reproducible seed.

### 13.4 Long stress test

Run at least one medium-configuration test containing:

* Millions of processing cycles.
* Independently randomized clock phases.
* Sustained near-full throughput.
* Random stalls.
* Periodic coefficient updates.
* Periodic weight updates.
* Counter wrap testing.
* FIFO near-full events.
* No waveform generation unless failure occurs.

### 13.5 Full-scale smoke tests

For the full configuration, run short targeted tests:

* Reset and initialization.
* Several complete FFT frames.
* One coefficient-bank update.
* One beam-weight update.
* Random backpressure.
* At least one CFAR detection.
* Packet output verification.

The full design does not need millions of simulated cycles before every compile. Full
functional confidence must come from common RTL exercised extensively in smaller
configurations.

## 14. Assertions

Add synthesizable or Verilator-compatible assertions for:

* Valid-data stability while stalled.
* FIFO overflow.
* FIFO underflow.
* Illegal simultaneous read/write states.
* Sequence discontinuity.
* Invalid state-machine states.
* Frame-boundary consistency.
* Bank changes outside safe boundaries.
* CDC handshake completion.
* Gray-pointer one-bit transitions.
* Memory response without a request.
* Duplicate outstanding tags.
* Arithmetic overflow where overflow is forbidden.
* Packet length consistency.
* Configuration writes to illegal addresses.

Assertions must remain active in fast simulation.

Assertions unsuitable for synthesis may be guarded without changing functional RTL.

## 15. Quartus Project

Create a Quartus Prime Pro project with:

```tcl
set_global_assignment -name FAMILY "Agilex 7"
set_global_assignment -name DEVICE AGMF039R47B1E1VC
set_global_assignment -name TOP_LEVEL_ENTITY benchmark_fabric_top
```

Detect and record the installed Quartus version. Do not silently change tool versions
during the experiment.

Create:

```text
quartus/project/agilex7_wideband.qpf
quartus/project/agilex7_wideband.qsf
quartus/constraints/clocks.sdc
quartus/constraints/io.sdc
quartus/constraints/exceptions.sdc
quartus/scripts/compile.tcl
quartus/scripts/report_sta.tcl
quartus/scripts/report_utilization.tcl
quartus/scripts/report_congestion.tcl
quartus/scripts/report_retiming.tcl
quartus/scripts/export_results.tcl
```

All generated clocks and asynchronous relationships must be explicit.

Never add a false path or multicycle path merely to improve timing reports.

Each exception must contain:

* Source.
* Destination.
* Functional reason.
* Verification method.
* Reviewer-facing explanation.

## 16. Build Commands

Provide these stable entry points:

```bash
make lint
make sim-tiny
make sim-medium
make sim-random
make sim-stress
make sim-coverage
make sim-full-smoke

make quartus-map
make quartus-fit
make quartus-sta
make quartus-report
make quartus-compile

make seed-sweep
make compare-baseline
make reproduce-final
```

A clean checkout plus documented environment variables must be sufficient to run every
command.

## 17. Quartus Reporting

Generate machine-readable reports after every compile.

Quartus supports scripted timing analysis and parseable Fmax data, including
`get_clock_fmax_info` and `report_clock_fmax_summary`. Use Tcl to export the results
rather than scraping GUI text.

Collect:

### Compilation

* Tool version.
* Device.
* Revision.
* Seed.
* Wall-clock time.
* Peak memory usage.
* Compiler stages completed.
* Fatal errors.
* Warnings.

### Utilization

* ALMs.
* ALM registers.
* MLABs.
* M20Ks.
* DSPs.
* RAM bits.
* Clock resources.
* Routing utilization when available.
* Resource use by hierarchy.

### Timing

For every clock:

* Constraint.
* Restricted Fmax.
* Setup slack.
* Hold slack.
* Recovery/removal slack.
* TNS.
* Number of failing paths.
* Critical chain.
* Logic depth.
* Routing delay.
* Cell delay.
* Clock skew.
* Source hierarchy.
* Destination hierarchy.

### Physical implementation

* Congestion regions.
* High-fanout nets.
* Longest interconnect paths.
* Retiming restrictions.
* Registers not retimed.
* DSP and RAM placement restrictions.
* Critical chains.
* Fast Forward recommendations.
* Design Assistant findings.

Quartus Fast Forward reports estimate potential clock performance after retiming,
pipelining, and optimization and provide recommended RTL modifications. These reports
are a primary input to the agent's timing-closure reasoning.

Export one JSON record per compile.

Example:

```json
{
  "commit": "abc1234",
  "quartus_version": "detected-version",
  "device": "AGMF039R47B1E1VC",
  "seed": 17,
  "configuration": "full_agmf039",
  "verification_passed": true,
  "unconstrained_paths": 0,
  "utilization": {
    "alm_percent": 0.0,
    "m20k_percent": 0.0,
    "dsp_percent": 0.0
  },
  "clocks": {
    "core_clk": {
      "constraint_mhz": 450.0,
      "restricted_fmax_mhz": 0.0,
      "wns_ns": 0.0,
      "tns_ns": 0.0
    }
  },
  "compile_seconds": 0,
  "notes": []
}
```

## 18. Resource-Calibration Phase

Before constructing the entire design, synthesize representative kernels.

Create calibration projects for:

1. One complex multiplier.
2. One complex FIR lane.
3. One eight-lane PFB.
4. One FFT stage.
5. One full FFT.
6. One beamforming dot product.
7. One complete beam.
8. One M20K history bank.
9. One packet-switch stage.
10. One asynchronous FIFO.

For each kernel, sweep:

* Pipeline depth.
* Register placement.
* Reset style.
* Multiplier implementation.
* Parallelism.
* Memory geometry.
* Input and output register choices.

Measure:

* DSP mapping.
* M20K mapping.
* ALMs.
* Fmax.
* Retiming.
* Routing delay.

Use measured data to select the full-scale parameters.

Do not build the full design based solely on theoretical DSP-count arithmetic.

## 19. Development Phases

### Phase 0: Infrastructure

Deliver:

* Repository.
* Build system.
* Verilator lint.
* C++ harness.
* Configuration generation.
* Logging.
* One trivial stream loopback test.
* Quartus project that compiles a minimal top.

Gate:

```text
make lint
make sim-tiny
make quartus-map
```

must pass from a clean checkout.

### Phase 1: Common infrastructure

Implement:

* Stream interface.
* Elastic buffer.
* Synchronous FIFO.
* Asynchronous FIFO.
* Register interface.
* CDC primitives.
* Fixed-point package.
* Sequence tracking.
* Performance counters.

Gate:

* All unit tests pass.
* Random stalls pass.
* CDC tests pass.
* Assertions pass.

### Phase 2: DSP kernels

Implement:

* Complex multiplier.
* FIR.
* FFT.
* Beamforming dot product.
* Power.
* Covariance.

Gate:

* Bit-accurate comparison to C++ model.
* Directed vectors pass.
* Random vectors pass.
* Arithmetic boundary coverage passes.

### Phase 3: Medium processing pipeline

Connect:

```text
PFB -> FFT -> history -> beamformer -> power -> CFAR
```

Use medium parameters.

Gate:

* Continuous frames.
* Random backpressure.
* Configuration changes.
* Long stress test.
* Coverage report.

### Phase 4: Packet and control fabric

Add:

* Event packetization.
* Virtual channels.
* Multistage switching.
* Telemetry.
* Fault reporting.
* Register map.

Gate:

* No loss or duplication.
* Random destination and stall tests.
* Priority and fairness tests.
* Counter verification.

### Phase 5: Full-scale elaboration

Generate the full AGMF039 configuration.

Gate:

* Verilator can compile the full design.
* Full smoke test passes.
* Quartus Analysis and Synthesis succeeds.
* No accidental logic removal.
* Resource usage is within the target region.

### Phase 6: Initial fit

Perform one complete baseline fit.

Do not optimize before saving:

* Baseline source commit.
* Baseline project.
* Baseline reports.
* Baseline seed.
* Baseline simulation result.
* Baseline utilization.
* Baseline timing.
* Baseline power estimate.

This baseline must remain immutable.

### Phase 7: Autonomous timing closure

Run the optimization loop described below.

### Phase 8: Seed robustness

Run the final candidate across ten fixed seeds.

Suggested fixed seed set:

```text
1, 3, 7, 11, 17, 23, 31, 43, 59, 73
```

Do not change the seed set after seeing results.

### Phase 9: HBM2e integration

Only after the fabric benchmark is stable:

* Generate HBM2e IP.
* Create AXI adapters.
* Connect abstract memory requests to HBM pseudo-channels.
* Keep behavioral memory under Verilator.
* Add HBM traffic generators and counters.
* Run Quartus integration and board-oriented reports.

## 20. Autonomous Timing-Closure Loop

For every timing-closure iteration, follow this exact process.

### Step 1: Preserve correctness

Run:

```bash
make lint
make sim-tiny
make sim-medium
```

If any fail, do not compile Quartus.

### Step 2: State one hypothesis

Write a concise hypothesis such as:

```text
The critical ready path crosses four packet-switch stages without
registration. Adding one elastic boundary should reduce routing delay
without changing packet ordering.
```

Do not make multiple unrelated architectural changes in one iteration.

### Step 3: Make the smallest defensible change

Possible changes include:

* Add a pipeline register.
* Add an elastic buffer.
* Localize a clock enable.
* Remove unnecessary datapath reset.
* Duplicate high-fanout control.
* Change RAM organization.
* Change DSP pipeline placement.
* Split hierarchy.
* Change beamformer accumulation topology.
* Change crossbar topology.
* Move a register boundary.
* Add latency-insensitive pipelining.
* Partition a large fanout domain.
* Adjust legal placement assignments.
* Enable or improve HyperFlex retiming.
* Modify a legitimate timing constraint.

### Step 4: Prove functional behavior

Run targeted tests and the medium regression.

If latency changed, update only the permitted latency metadata or scoreboard bounds. Do
not change expected numerical values.

### Step 5: Compile

Run the full Quartus flow using the current experiment seed.

### Step 6: Parse results

Record:

* Fmax.
* WNS.
* TNS.
* Critical path.
* Critical hierarchy.
* Resource changes.
* Congestion changes.
* Compile time.
* Power estimate.
* Fast Forward recommendations.

### Step 7: Accept or reject

Accept the change only if:

* Verification passes.
* Constraints remain valid.
* No unconstrained paths appear.
* The relevant physical metric improves.
* No unacceptable regression occurs elsewhere.

Otherwise revert the change.

### Step 8: Commit the result

Each accepted optimization receives one Git commit containing:

* Hypothesis.
* Change.
* Verification evidence.
* Quartus before-and-after metrics.
* Known tradeoffs.

Each rejected experiment receives a JSONL log entry even though the RTL change is
reverted.

## 21. Bottleneck Classification

Classify every major timing failure before modifying RTL.

Allowed categories:

```text
PIPELINE_DEPTH
LONG_COMBINATIONAL_PATH
READY_VALID_FEEDBACK
ARBITRATION_FEEDBACK
HIGH_FANOUT_CONTROL
RESET_LIMITED_RETIMING
ENABLE_LIMITED_RETIMING
DSP_PIPELINE
RAM_PIPELINE
RAM_GEOMETRY
CROSSBAR_CONGESTION
HIERARCHY_BOUNDARY
CLOCK_SKEW
CDC_CONSTRAINT
GENERATED_CLOCK
PLACEMENT_LOCALITY
RESOURCE_OVERUTILIZATION
ROUTING_CONGESTION
HOLD_LIMITED
RECOVERY_REMOVAL
INVALID_CONSTRAINT
UNKNOWN
```

Do not use `UNKNOWN` without collecting additional reports.

## 22. Optimization Priority

Use this priority order:

1. Correct invalid or incomplete constraints.
2. Eliminate unconstrained paths.
3. Fix CDC errors.
4. Remove combinational protocol loops.
5. Address retiming restrictions.
6. Localize resets and enables.
7. Pipeline long datapaths.
8. Pipeline arbitration and feedback.
9. Improve DSP and RAM register placement.
10. Restructure high-fanout networks.
11. Restructure wide crossbars.
12. Improve memory banking.
13. Improve hierarchy and physical locality.
14. Consider floorplanning.
15. Run seed exploration.

Seed sweeps must not substitute for architectural work.

## 23. HyperFlex-Specific Rules

The design targets a HyperFlex architecture. Quartus attempts to maximize register
retiming into Hyper-Registers, but RTL structures, reset behavior, feedback loops, DSPs,
memories, and control networks can limit this optimization.

Follow these rules:

* Reset validity, not every datapath bit.
* Avoid asynchronous resets in performance-critical pipelines.
* Avoid one chip-wide clock enable.
* Pipeline enables before broad distribution.
* Duplicate high-fanout controls where functionally safe.
* Keep pipeline stages latency-insensitive.
* Break ready/valid feedback with elastic buffers.
* Provide registers on both sides of DSP-heavy operations.
* Provide suitable input and output registers around M20Ks.
* Avoid artificial hierarchy preservation until its effect is measured.
* Review Fast Forward recommendations after each major architecture change.
* Treat feedback-loop latency as an architectural constraint, not merely a placement
  problem.

## 24. Constraints Integrity Rules

The following are prohibited unless fully justified:

* Broad wildcard false paths.
* False paths through active datapaths.
* Multicycle paths added because a path fails timing.
* Clock groups that hide real synchronous crossings.
* Disabling timing analysis for difficult hierarchy.
* Lowering the requested clock after seeing a poor result without preserving the
  original benchmark.
* Removing logic that participates in the specified workload.
* Constant-driving unused inputs so large blocks optimize away.
* Marking failing logic as debug-only.
* Replacing custom RTL with vendor processing IP after the baseline.

Create a script that reports:

* Every false path.
* Every multicycle path.
* Every asynchronous clock group.
* Every disabled timing arc.
* Every unconstrained endpoint.

The final evidence package must include this report.

## 25. Seed Experiment

Use two stages.

### Development stage

Use one fixed development seed while making architectural changes.

This reduces noise when comparing iterations.

### Final stage

Run ten fixed seeds for:

* Original baseline.
* Best intermediate candidate.
* Final candidate.

Report:

* Closure rate.
* Median restricted Fmax.
* Minimum Fmax.
* Tenth-percentile Fmax.
* Median WNS.
* Worst WNS.
* Median TNS.
* Utilization.
* Compile time.
* Power estimate.

Do not present only the best seed.

## 26. Success Criteria

### Functional success

* All unit tests pass.
* All integration tests pass.
* Long stress test passes.
* Full-scale smoke test passes.
* No assertion failures.
* No lost or duplicated transactions.
* Numerical results match the bit-accurate model.
* Coefficient and weight changes obey frame-boundary rules.
* Random backpressure does not alter outputs.
* All planned functional coverage points are reached.

### Implementation success

* Device is exactly `AGMF039R47B1E1VC`.
* No unconstrained paths.
* No unjustified timing exceptions.
* DSP utilization is at least 75%, unless another resource becomes the verified limiting
  resource.
* M20K utilization is at least 55%, unless routing or DSP limits prevent it.
* ALM utilization is high enough to create a genuine full-chip routing problem.
* The design cannot be dismissed as a collection of independent replicated kernels.
* Cross-module traffic spans the major processing hierarchy.
* At least eight of ten fixed seeds close required timing.
* Final median Fmax materially exceeds the baseline.
* All accepted changes have verification and report evidence.

### Strong-result threshold

A strong result would be:

```text
Full functional regression passes
Zero unconstrained paths
DSP utilization between 80% and 90%
M20K utilization between 60% and 80%
Substantial ALM and routing use
At least 8/10 seeds close
Median core Fmax improves by at least 15%
No unjustified timing exceptions
```

A 20% or greater median Fmax improvement produced by autonomous RTL restructuring would
be especially significant.

## 27. Required Evidence Package

Produce:

```text
evidence/
├── baseline/
│   ├── source_commit.txt
│   ├── simulation_summary.json
│   ├── utilization.json
│   ├── timing.json
│   ├── constraints_report.txt
│   └── quartus_reports/
├── final/
│   ├── source_commit.txt
│   ├── simulation_summary.json
│   ├── coverage/
│   ├── utilization.json
│   ├── timing.json
│   ├── constraints_report.txt
│   └── quartus_reports/
├── seed_comparison.csv
├── optimization_history.jsonl
├── accepted_changes.md
├── rejected_experiments.md
├── reproducibility.md
└── executive_summary.md
```

The executive summary must answer:

1. What was built?
2. Why is it not a toy design?
3. How was it verified?
4. What was the initial Quartus result?
5. What bottlenecks were found?
6. What changes did the AI make?
7. Which changes failed?
8. How much did median Fmax improve?
9. How robust was the result across seeds?
10. Were any timing exceptions added?
11. Can the complete result be reproduced without the GUI?

## 28. Rules for the Coding Agent

Always:

* Keep the design compiling.
* Prefer small, reviewable commits.
* Run targeted verification after every RTL change.
* Record parameter changes.
* Record rejected approaches.
* Use deterministic seeds.
* Preserve failing test seeds.
* Generate FST only for failures.
* Maintain a bit-accurate model.
* Separate portable RTL from vendor IP.
* Parse reports into structured data.
* Make one optimization hypothesis at a time.
* Revert changes that do not improve the measured objective.

Never:

* Claim timing closure from synthesis estimates.
* Claim success from one lucky seed.
* Hide timing failures with invalid constraints.
* Waive a simulator warning without explanation.
* Disable assertions to obtain a passing regression.
* Replace the workload with disconnected resource burners.
* Use generated vendor FFT, FIR, beamforming, or CFAR IP for the principal benchmark.
* Change the specification to match an incorrect implementation.
* Modify both the RTL and reference model to hide a discrepancy without independently
  resolving which implementation is correct.

## 29. First Execution Tasks

Perform these tasks in order:

1. Create the repository structure.
2. Write `SPEC.md` from this document.
3. Create `tiny`, `medium`, `large`, and `full_agmf039` configurations.
4. Implement the common stream interface.
5. Implement an elastic buffer.
6. Implement synchronous and asynchronous FIFOs.
7. Implement the fixed-point C++ and SystemVerilog packages.
8. Create the C++ multi-clock Verilator harness.
9. Demonstrate randomized ready/valid loopback testing.
10. Create the Quartus project for `AGMF039R47B1E1VC`.
11. Compile a minimal `benchmark_fabric_top`.
12. Export Quartus utilization and timing JSON.
13. Implement and verify one complex multiplier.
14. Run a Quartus calibration sweep for its pipeline configurations.
15. Implement one FIR lane.
16. Scale to the tiny PFB.
17. Implement the tiny FFT.
18. Integrate the tiny pipeline.
19. Continue only after the tiny regression is deterministic and clean.

Do not begin with the full 16-antenna design.

The first deliverable is a verified, scripted vertical slice:

```text
input stream
  -> complex FIR
  -> small FFT
  -> power
  -> output stream
```

It must run under Verilator and synthesize in Quartus for the exact target device before
additional scale or functionality is added.

## 30. Definition of Done

The project is done only when a third party can execute:

```bash
git clone <repository>
cd agilex7-wideband
make sim-medium
make sim-full-smoke
make reproduce-final
```

and obtain:

* Passing simulations.
* The documented full-device Quartus build.
* Structured timing and utilization reports.
* The fixed ten-seed comparison.
* The complete autonomous optimization history.
* The same final conclusion without opening the Quartus GUI.

The most important structural choice is the separation between simulation scale and
synthesis scale. Verilator can exhaustively exercise the common parameterized RTL at
tiny and medium sizes, while the exact full configuration receives shorter smoke tests
and the complete Quartus physical-implementation flow. This avoids spending most of the
project simulating thousands of parallel copies while still proving that the full
elaborated design is derived from verified RTL.
