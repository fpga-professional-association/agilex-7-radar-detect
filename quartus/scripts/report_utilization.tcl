# ---------------------------------------------------------------------------
# report_utilization.tcl — resource utilization extraction
# Governing spec: SPEC.md 17 (Utilization).
#
# Usage:
#   quartus_sh -t report_utilization.tcl
#
# Collects ALMs, ALM registers, MLABs, M20Ks, DSPs, RAM bits, clock resources
# and resource-use-by-hierarchy from the Quartus report database via the
# ::quartus::report API. Nothing is scraped out of GUI text.
#
# Degrades gracefully:
#   * after fit  -> Fitter resource panels (authoritative, placed counts)
#   * after syn  -> Synthesis resource panels (estimates; flagged as such)
#   * neither    -> writes a fragment saying so and exits 0, so `make
#                   quartus-report` after a bare `quartus-map` still produces a
#                   valid JSON record.
#
# Percentages are computed against the SPEC.md 2 device totals for
# AGMF039R47B1E1VC (1,305,600 ALMs / 18,960 M20K / 12,300 DSP), not against
# whatever denominator a report panel happens to print.
# ---------------------------------------------------------------------------

source [file join [file dirname [info script]] common.tcl]

package require ::quartus::project
package require ::quartus::report

bench::ensure_dirs
bench::open_project

set have_report 1
if {[catch {load_report} err]} {
    bench::log "WARNING: load_report failed: $err"
    set have_report 0
}

# --- panel helpers ----------------------------------------------------------
proc all_panels {} {
    set names {}
    catch {set names [get_report_panel_names]}
    return $names
}

# First panel whose name matches any of the glob patterns, in priority order.
proc find_panel {patterns} {
    set names [all_panels]
    foreach pat $patterns {
        foreach n $names {
            if {[string match -nocase $pat $n]} { return $n }
        }
    }
    return ""
}

# Turn a two-column "label | value" panel into a label->value dict, and return
# the raw rows as well so the text report can carry the untouched table.
proc panel_kv {panel} {
    set kv   [dict create]
    set rows {}
    if {$panel eq ""} { return [list $kv $rows] }
    set nrows 0
    if {[catch {set nrows [get_number_of_rows -name $panel]}]} { return [list $kv $rows] }
    for {set r 1} {$r < $nrows} {incr r} {
        set row {}
        if {[catch {set row [get_report_panel_row -name $panel -row $r]}]} { continue }
        lappend rows $row
        if {[llength $row] < 2} { continue }
        set label [string trim [lindex $row 0]]
        set value [string trim [lindex $row 1]]
        if {$label eq ""} { continue }
        dict set kv $label $value
    }
    return [list $kv $rows]
}

proc panel_rows {panel} {
    set rows {}
    if {$panel eq ""} { return $rows }
    set nrows 0
    if {[catch {set nrows [get_number_of_rows -name $panel]}]} { return $rows }
    for {set r 0} {$r < $nrows} {incr r} {
        if {[catch {set row [get_report_panel_row -name $panel -row $r]}]} { continue }
        lappend rows $row
    }
    return $rows
}

# Pick the first kv entry whose label matches any glob, return the bare number.
proc kv_num {kv patterns} {
    foreach pat $patterns {
        dict for {label value} $kv {
            if {[string match -nocase $pat $label]} {
                set n [bench::num $value]
                if {$n ne ""} { return $n }
            }
        }
    }
    return ""
}

# Analysis & Synthesis reports "Estimate of Logic utilization (ALMs needed)",
# and for very small designs that estimate can come out NEGATIVE (this minimal
# top reports -552). It is an artefact of the pre-fit packing model, not a
# resource count. Publishing it would produce a negative utilization
# percentage, so a negative resource count is dropped and explained rather than
# passed through or silently clamped to zero.
proc nonneg {value what} {
    if {$value eq "" || ![string is double -strict $value]} { return "" }
    if {$value < 0} {
        lappend ::negative_estimates $what
        return ""
    }
    return $value
}

# ---------------------------------------------------------------------------
# Locate the resource panels
# ---------------------------------------------------------------------------
set fit_panel [find_panel {
    {*Fitter*Resource Usage Summary*}
    {*Fitter Resource Usage Summary*}
    {*Fitter*Summary*Resource*}
}]
set syn_panel [find_panel {
    {*Synthesis*Resource Usage Summary*}
    {*Analysis & Synthesis Resource Usage Summary*}
    {*Synthesis*Resource*Summary*}
}]
set ent_panel [find_panel {
    {*Fitter*Resource Utilization by Entity*}
    {*Resource Utilization by Entity*}
    {*Resource Usage Summary*by Entity*}
}]
set clk_panel [find_panel {
    {*Fitter*Global*Signal*}
    {*Global & Other Fast Signals*}
    {*Clock*Resource*Summary*}
}]

set source_stage ""
set panel ""
if {$fit_panel ne ""} {
    set panel $fit_panel
    set source_stage "fit"
} elseif {$syn_panel ne ""} {
    set panel $syn_panel
    set source_stage "syn"
}

set notes {}
if {$panel eq ""} {
    lappend notes "no resource panel found; run `make quartus-map` or `make quartus-fit` first"
    bench::log "WARNING: no resource usage panel in the report database"
} elseif {$source_stage eq "syn"} {
    lappend notes "utilization taken from Analysis & Synthesis (pre-fit estimate); run quartus-fit for placed counts"
}

# Populated by nonneg{} below, appended to notes after the values are read.
set negative_estimates {}

lassign [panel_kv $panel] kv rows

# ---------------------------------------------------------------------------
# Map report labels to the schema keys (SPEC.md 17)
# ---------------------------------------------------------------------------
#
# Label patterns are ORDERED and deliberately specific. Loose globs silently
# pick up the wrong row: "*MLAB*" matches "Total MLAB memory BITS" (456) as
# readily as the MLAB block count (6), and the resulting JSON looks plausible
# while being nonsense. Each list below therefore names the exact row first.
set alms       [nonneg [kv_num $kv {{Logic utilization (ALMs needed*} {ALMs needed*} \
                            {*Estimate of Logic utilization (ALMs needed)*} \
                            {*ALMs used*} {*Total ALMs*}}] "ALMs"]
set alm_regs   [nonneg [kv_num $kv {{Dedicated logic registers} {*Dedicated logic registers*} \
                            {*ALM registers*} {*Total registers*}}] "ALM registers"]
# MLAB blocks = "Memory LABs", i.e. LABs configured as memory. Distinct from
# MLAB memory bits.
set mlabs      [kv_num $kv {{*Memory LABs*} {*MLAB blocks*}}]
set mlab_bits  [kv_num $kv {{Total MLAB memory bits} {*MLAB memory bits*}}]
set m20ks      [kv_num $kv {{M20K blocks} {*M20K blocks*}}]
set block_bits [kv_num $kv {{Total block memory bits} {*block memory bits*}}]
set dsps       [kv_num $kv {{DSP Blocks Needed*} {*Total DSP Blocks*} {*DSP Blocks*}}]
set pins       [kv_num $kv {{I/O pins} {*I/O pins*} {*Total pins*}}]
set max_fanout [kv_num $kv {{Maximum fan-out} {*Maximum fan-out*}}]
set global_sig [kv_num $kv {{Global signals*} {*Global signals*}}]

# SPEC.md 17 asks for "RAM bits": total memory bits, wherever they landed.
set ram_bits ""
if {$block_bits ne "" || $mlab_bits ne ""} {
    set b [expr {$block_bits eq "" ? 0 : int($block_bits)}]
    set m [expr {$mlab_bits  eq "" ? 0 : int($mlab_bits)}]
    set ram_bits [expr {$b + $m}]
}

# --- virtual pins -----------------------------------------------------------
# No panel reports the virtual-pin count directly. It is the difference between
# the design's total port count (Analysis & Synthesis, which counts every top
# port) and the Fitter's real I/O pin count. Every port that did not become a
# package pin became a virtual pin, which is exactly what the qsf asks for.
set virt_pins ""
if {$source_stage eq "fit" && $syn_panel ne ""} {
    lassign [panel_kv $syn_panel] syn_kv syn_rows
    set syn_pins [kv_num $syn_kv {{I/O pins} {*I/O pins*}}]
    if {$syn_pins ne "" && $pins ne ""} {
        set virt_pins [expr {int($syn_pins) - int($pins)}]
        if {$virt_pins < 0} { set virt_pins "" }
    }
}

# --- routing utilization ("Routing utilization when available", SPEC.md 17) --
set route_panel [find_panel {
    {*Finalize Stage*Routing Usage Summary*}
    {*Route Stage*Routing Usage Summary*}
    {*Routing Usage Summary*}
}]
set peak_ic [kv_num $kv {{Peak interconnect usage*}}]
set avg_ic  [kv_num $kv {{Average interconnect usage*}}]

foreach what [lsort -unique $negative_estimates] {
    lappend notes "$what reported a negative pre-fit estimate and was dropped; run quartus-fit for a real placed count"
}

set util [dict create \
    source_stage   $source_stage \
    panel          $panel \
    alm_used       $alms \
    alm_total      $bench::total_alms \
    alm_percent    [bench::pct $alms $bench::total_alms] \
    alm_reg_used   $alm_regs \
    alm_reg_total  $bench::total_alm_regs \
    alm_reg_percent [bench::pct $alm_regs $bench::total_alm_regs] \
    mlab_used         $mlabs \
    mlab_memory_bits  $mlab_bits \
    block_memory_bits $block_bits \
    max_fanout        $max_fanout \
    global_signals    $global_sig \
    peak_interconnect_percent $peak_ic \
    avg_interconnect_percent  $avg_ic \
    m20k_used      $m20ks \
    m20k_total     $bench::total_m20k \
    m20k_percent   [bench::pct $m20ks $bench::total_m20k] \
    dsp_used       $dsps \
    dsp_total      $bench::total_dsp \
    dsp_percent    [bench::pct $dsps $bench::total_dsp] \
    ram_bits       $ram_bits \
    pins_used      $pins \
    virtual_pins   $virt_pins \
    notes          $notes \
]

# --- resource by hierarchy --------------------------------------------------
set by_hier {}
set ent_rows [panel_rows $ent_panel]
if {[llength $ent_rows] > 1} {
    set hdr [lindex $ent_rows 0]
    foreach row [lrange $ent_rows 1 end] {
        if {[llength $row] < 2} { continue }
        lappend by_hier $row
    }
    dict set util by_hierarchy_columns $hdr
} else {
    lappend notes "resource-by-entity table unavailable (requires a completed fit)"
    dict set util notes $notes
}
dict set util by_hierarchy $by_hier

# --- clock resources --------------------------------------------------------
set clk_rows [panel_rows $clk_panel]
dict set util clock_resource_panel $clk_panel
dict set util clock_resource_rows  [expr {[llength $clk_rows] > 0 ? [llength $clk_rows] - 1 : 0}]

# --- routing utilization rows ----------------------------------------------
set route_rows [panel_rows $route_panel]
dict set util routing_panel $route_panel
if {[llength $route_rows] == 0} {
    lappend notes "routing usage table unavailable (requires a completed fit)"
    dict set util notes $notes
}

bench::frag_save utilization $util

# ---------------------------------------------------------------------------
# Human-readable evidence report
# ---------------------------------------------------------------------------
set fh [bench::text_report_open utilization]
puts $fh "source stage : $source_stage"
puts $fh "panel        : $panel"
puts $fh ""
puts $fh "-- schema values ------------------------------------------------------"
foreach k {alm_used alm_percent alm_reg_used alm_reg_percent mlab_used \
           mlab_memory_bits block_memory_bits m20k_used m20k_percent \
           dsp_used dsp_percent ram_bits pins_used virtual_pins \
           max_fanout global_signals peak_interconnect_percent \
           avg_interconnect_percent} {
    puts $fh [format "  %-18s %s" $k [dict get $util $k]]
}
puts $fh ""
puts $fh "-- raw resource panel -------------------------------------------------"
foreach row $rows { puts $fh "  [join $row { | }]" }
puts $fh ""
puts $fh "-- resource utilization by entity ------------------------------------"
if {[llength $ent_rows] == 0} {
    puts $fh "  (unavailable — requires a completed fit)"
} else {
    foreach row $ent_rows { puts $fh "  [join $row { | }]" }
}
puts $fh ""
puts $fh "-- clock / global signal resources -----------------------------------"
if {[llength $clk_rows] == 0} {
    puts $fh "  (unavailable — requires a completed fit)"
} else {
    foreach row $clk_rows { puts $fh "  [join $row { | }]" }
}
puts $fh ""
puts $fh "-- routing utilization ------------------------------------------------"
if {[llength $route_rows] == 0} {
    puts $fh "  (unavailable — requires a completed fit)"
} else {
    foreach row $route_rows { puts $fh "  [join $row { | }]" }
}
puts $fh ""
puts $fh "-- all report panels --------------------------------------------------"
foreach n [all_panels] { puts $fh "  $n" }
close $fh

catch {unload_report}
bench::close_project
bench::log "utilization report complete"
exit 0
