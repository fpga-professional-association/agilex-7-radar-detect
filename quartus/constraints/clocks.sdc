# ---------------------------------------------------------------------------
# clocks.sdc — clock definitions for the Agilex 7 wideband benchmark
# Governing spec: SPEC.md 8 (Clock Domains), 15, 24.
#
# Rules that bind this file:
#   * Every generated clock and every asynchronous relationship is declared
#     EXPLICITLY. Nothing is left to inference.
#   * The requested clock is never lowered to make a report look better
#     (SPEC.md 24). The 450 MHz primary target is the benchmark; if it fails,
#     the failure is reported, not constrained away.
# ---------------------------------------------------------------------------

# --- primary fabric clock ---------------------------------------------------
# SPEC.md 2: "Primary clock target: 450 MHz initial".
# 450 MHz -> 2.2222... ns. The constraint uses 2.222 ns (450.045 MHz), which is
# marginally tighter than the target, so a passing result is never an artefact
# of period rounding.
set core_clk_period_ns 2.222

create_clock \
    -name core_clk \
    -period $core_clk_period_ns \
    [get_ports {core_clk}]

# --- generated clocks -------------------------------------------------------
# None. The Phase 0 minimal top is single-clock: there is no PLL, no clock
# divider, and no gated clock. Every generated clock added by a later issue
# (IOPLL outputs, the 2x/4x SIMD-rate clocks of SPEC.md 8, HBM/F-Tile user
# clocks) must be declared here with an explicit create_generated_clock, not
# left to Quartus inference.
#
# Example shape for a later issue (kept commented; do not enable speculatively):
#   create_generated_clock -name pll_core_clk -source [get_pins {u_pll|refclk}] \
#       -divide_by 1 -multiply_by 1 [get_pins {u_pll|outclk[0]}]

# --- asynchronous clock relationships ---------------------------------------
# None. A single clock domain exists, so there is no clock group to declare.
# SPEC.md 24 prohibits clock groups that hide real synchronous crossings: when
# the async FIFO / CDC work of issue #6 lands, each set_clock_groups
# -asynchronous must name the exact domains and be justified alongside the CDC
# inventory report, never applied as a blanket -exclusive over all clocks.

# --- uncertainty ------------------------------------------------------------
# Let Quartus derive real PLL/jitter/crosstalk uncertainty from the device
# models rather than hand-waving a fixed margin.
derive_clock_uncertainty
