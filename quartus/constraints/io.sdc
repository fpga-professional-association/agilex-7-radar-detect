# ---------------------------------------------------------------------------
# io.sdc — IO timing for the Agilex 7 wideband benchmark
# Governing spec: SPEC.md 15, 17 (zero unconstrained paths), 24.
#
# Every top-level data/handshake port of benchmark_fabric_top is a VIRTUAL PIN
# (see quartus/project/agilex7_wideband.qsf). The ports still need input and
# output delays, for two reasons:
#
#   1. SPEC.md 2 requires "Unconstrained paths: zero". An unconstrained virtual
#      pin is still an unconstrained endpoint and still shows up in report_ucp.
#   2. The delays keep the boundary registers inside the analysed timing graph
#      instead of being silently excluded, so the reported Fmax reflects the
#      whole minimal top.
#
# These are REAL numbers, not placeholders and not false paths. They are a
# fabric-internal budget, not a board-level SSTL/LVDS budget: a virtual pin has
# no package or board flight time, so the budget models the fabric routing an
# adjacent block would contribute on either side of the boundary.
#
# Budget derivation (core_clk period 2.222 ns @ 450 MHz):
#   max (setup side) 0.450 ns  = ~20% of the period, i.e. the boundary logic is
#                                allowed one fifth of the cycle on each side.
#   min (hold side)  0.100 ns  = ~4.5% of the period, a short-route hold floor.
# The same 20% / 4.5% split is used for input and output so the boundary is
# symmetric and neither side is quietly relaxed.
#
# SPEC.md 24: these values must not be loosened after seeing a poor result. If
# the boundary budget ever changes, the change is recorded in DECISIONS.md with
# the original benchmark preserved.
# ---------------------------------------------------------------------------

set io_delay_max_ns 0.450
set io_delay_min_ns 0.100

# --- input ports ------------------------------------------------------------
# core_clk is the clock source itself and takes no input delay.
set core_clk_port [get_ports {core_clk}]
set all_in_ports  [remove_from_collection [all_inputs] $core_clk_port]

set_input_delay -clock [get_clocks core_clk] -max $io_delay_max_ns $all_in_ports
set_input_delay -clock [get_clocks core_clk] -min $io_delay_min_ns $all_in_ports

# --- output ports -----------------------------------------------------------
set_output_delay -clock [get_clocks core_clk] -max $io_delay_max_ns [all_outputs]
set_output_delay -clock [get_clocks core_clk] -min $io_delay_min_ns [all_outputs]
