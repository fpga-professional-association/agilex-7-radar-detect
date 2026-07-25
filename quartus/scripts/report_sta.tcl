# ---------------------------------------------------------------------------
# report_sta.tcl — scripted timing analysis extraction
# Governing spec: SPEC.md 17 (Timing), 24 (Constraints integrity report).
#
# Usage:
#   quartus_sta -t report_sta.tcl
#
# MUST be run under quartus_sta (it needs the ::quartus::sta timing netlist
# API). Requires a completed Fitter run; without one it writes a fragment
# saying so and exits 0 so that `make quartus-report` after a bare
# `quartus-map` still produces a valid JSON record.
#
# Per SPEC.md 17, for every clock: constraint, restricted Fmax, setup slack,
# hold slack, recovery/removal slack, TNS, failing path count, critical chain,
# logic depth, routing delay, cell delay, clock skew, source hierarchy,
# destination hierarchy. Obtained from get_clock_fmax_info /
# report_clock_fmax_summary / create_timing_summary / get_timing_paths, never
# from GUI text.
#
# Also emits the SPEC.md 24 constraints-integrity report: every false path,
# multicycle path, asynchronous clock group, disabled timing arc and
# unconstrained endpoint present in the compiled design.
# ---------------------------------------------------------------------------

source [file join [file dirname [info script]] common.tcl]

package require ::quartus::project
package require ::quartus::sta

bench::ensure_dirs
bench::open_project

set timing [dict create]
set notes {}

# ---------------------------------------------------------------------------
# Build the timing netlist
# ---------------------------------------------------------------------------
set netlist_ok 1
if {[catch {create_timing_netlist} err]} {
    set netlist_ok 0
    lappend notes "timing netlist unavailable: $err"
    bench::log "WARNING: create_timing_netlist failed: $err"
}
if {$netlist_ok} {
    if {[catch {read_sdc} err]} {
        lappend notes "read_sdc failed: $err"
        bench::log "WARNING: read_sdc failed: $err"
    }
    if {[catch {update_timing_netlist} err]} {
        set netlist_ok 0
        lappend notes "update_timing_netlist failed: $err"
        bench::log "WARNING: update_timing_netlist failed: $err"
    }
}

if {!$netlist_ok} {
    dict set timing available 0
    dict set timing notes [linsert $notes 0 "STA requires a completed fit — run `make quartus-fit` first"]
    bench::frag_save timing $timing
    set fh [bench::text_report_open sta]
    puts $fh "STA unavailable — requires a completed Fitter run."
    foreach n [dict get $timing notes] { puts $fh "  - $n" }
    close $fh
    bench::close_project
    bench::log "STA report degraded: no timing netlist"
    exit 0
}

dict set timing available 1

# ---------------------------------------------------------------------------
# Small helpers
# ---------------------------------------------------------------------------
proc coll_size {c} {
    set n 0
    catch {
        foreach_in_collection item $c { incr n }
    }
    return $n
}

# Node id -> full hierarchical name; the hierarchy is everything above the leaf.
proc node_name {id} {
    set n ""
    catch {set n [get_node_info -name $id]}
    return $n
}
proc node_hierarchy {name} {
    set parts [split $name |]
    if {[llength $parts] <= 1} { return "" }
    return [join [lrange $parts 0 end-1] |]
}

# get_path_info option that may not exist on every path type / release.
proc path_info {path opt} {
    set v ""
    catch {set v [get_path_info $path $opt]}
    return $v
}

# get_path_info -from_clock/-to_clock return clock object ids, not names.
proc clock_name {id} {
    if {$id eq ""} { return "" }
    set n ""
    catch {set n [get_clock_info $id -name]}
    if {$n eq ""} { return $id }
    return $n
}

# Run a report_* command with -file and return its text. Quartus writes these
# as delimited ASCII tables, which is the tool's own machine-readable form —
# the report panel API does not expose report_ucp / report_sdc / report_exceptions
# in a scripted (non-GUI) session, so -file is the only scripted route to them.
proc capture_to_file {name cmd} {
    set path [file join $::bench::synth_dir "sta_${name}.txt"]
    catch {file delete -force $path}
    if {[catch {eval [concat $cmd [list -file $path]]} err]} {
        return [list "" "ERROR: $err"]
    }
    if {![file exists $path]} { return [list "" "no output produced"] }
    set fh [open $path r]
    set txt [read $fh]
    close $fh
    return [list $txt ""]
}

# Split a Quartus delimited ASCII table into rows of trimmed cells.
proc table_rows {txt} {
    set out {}
    foreach line [split $txt \n] {
        set line [string trim $line]
        if {[string index $line 0] ne ";"} { continue }
        set cells {}
        foreach c [split $line ";"] { lappend cells [string trim $c] }
        # split on ";" produces a leading and a trailing empty cell
        lappend out [lrange $cells 1 end-1]
    }
    return $out
}

# Parse a "; Label ; v1 ; v2 ;" row out of a Quartus delimited ASCII table.
proc table_row_values {txt label_glob} {
    foreach cells [table_rows $txt] {
        if {[llength $cells] < 2} { continue }
        if {[string match -nocase $label_glob [lindex $cells 0]]} {
            return [lrange $cells 1 end]
        }
    }
    return {}
}

# ---------------------------------------------------------------------------
# Clock constraints
# ---------------------------------------------------------------------------
set clocks [dict create]
set clock_names {}
foreach_in_collection clk [get_clocks] {
    set name [get_clock_info $clk -name]
    lappend clock_names $name
    set period ""
    catch {set period [get_clock_info $clk -period]}
    set constraint_mhz ""
    if {$period ne "" && [string is double -strict $period] && $period > 0} {
        set constraint_mhz [bench::round [expr {1000.0 / $period}] 3]
    }
    dict set clocks $name [dict create \
        period_ns      [bench::round $period 4] \
        constraint_mhz $constraint_mhz \
    ]
}
bench::log "clocks: [join $clock_names {, }]"

# ---------------------------------------------------------------------------
# Restricted Fmax (SPEC.md 17 names these APIs explicitly)
# ---------------------------------------------------------------------------
# get_clock_fmax_info returns a list of {clock_name fmax restricted_fmax [note]}
set fmax_rows {}
if {[catch {set fmax_rows [get_clock_fmax_info]} err]} {
    lappend notes "get_clock_fmax_info failed: $err"
} else {
    foreach row $fmax_rows {
        set name [lindex $row 0]
        set fmax [bench::num [lindex $row 1]]
        set rfmax [bench::num [lindex $row 2]]
        if {![dict exists $clocks $name]} { dict set clocks $name [dict create] }
        dict set clocks $name fmax_mhz            [bench::round $fmax 3]
        dict set clocks $name restricted_fmax_mhz [bench::round $rfmax 3]
        if {[llength $row] > 3} {
            dict set clocks $name fmax_note [lindex $row 3]
        }
    }
}
catch {report_clock_fmax_summary -panel_name "bench_fmax"}

# ---------------------------------------------------------------------------
# Per-clock slack and TNS for each analysis type
# ---------------------------------------------------------------------------
# create_timing_summary produces the official per-clock "Slack" / "End Point
# TNS" table. Key names match the SPEC.md 17 schema.
set summary_map {
    setup    {wns_ns tns_ns}
    hold     {hold_wns_ns hold_tns_ns}
    recovery {recovery_wns_ns recovery_tns_ns}
    removal  {removal_wns_ns removal_tns_ns}
}

# The report-panel API needs load_report, which is not available in a
# quartus_sta session, so the summaries are written with -file and read back
# from Quartus's own delimited ASCII table.
set summary_texts [dict create]
foreach {kind keys} $summary_map {
    lassign $keys wns_key tns_key
    lassign [capture_to_file "summary_$kind" [list create_timing_summary -$kind]] txt err
    dict set summary_texts $kind $txt
    if {$err ne ""} {
        lappend notes "create_timing_summary -$kind failed: $err"
        continue
    }
    set matched 0
    foreach row [table_rows $txt] {
        if {[llength $row] < 2} { continue }
        set cname [lindex $row 0]
        if {$cname eq "" || [string equal -nocase $cname "Clock"]} { continue }
        set slack [bench::num [lindex $row 1]]
        if {$slack eq ""} { continue }
        set tns ""
        if {[llength $row] >= 3} { set tns [bench::num [lindex $row 2]] }
        if {![dict exists $clocks $cname]} { dict set clocks $cname [dict create] }
        dict set clocks $cname $wns_key [bench::round $slack 4]
        dict set clocks $cname $tns_key [bench::round $tns 4]
        incr matched
    }
    if {!$matched} {
        lappend notes "create_timing_summary -$kind produced no per-clock row (no $kind paths in the design)"
    }
}

# --- failing path counts ----------------------------------------------------
foreach {kind key} {setup failing_paths_setup hold failing_paths_hold \
                    recovery failing_paths_recovery removal failing_paths_removal} {
    foreach cname [dict keys $clocks] {
        set n 0
        if {[catch {
            set c [get_timing_paths -$kind -to_clock $cname -npaths 10000 -less_than_slack 0]
            set n [coll_size $c]
        } err]} {
            set n ""
        }
        dict set clocks $cname $key $n
    }
}

# ---------------------------------------------------------------------------
# Critical path detail (SPEC.md 17: critical chain, logic depth, routing delay,
# cell delay, clock skew, source hierarchy, destination hierarchy)
# ---------------------------------------------------------------------------
set critical [dict create]
foreach cname [dict keys $clocks] {
    set path ""
    catch {
        set c [get_timing_paths -setup -to_clock $cname -npaths 1 -detail full_path]
        foreach_in_collection p $c { set path $p; break }
    }
    if {$path eq ""} { continue }

    set from_name [node_name [path_info $path -from]]
    set to_name   [node_name [path_info $path -to]]

    set entry [dict create \
        slack_ns          [bench::round [path_info $path -slack] 4] \
        num_logic_levels  [path_info $path -num_logic_levels] \
        data_delay_ns     [bench::round [path_info $path -data_delay] 4] \
        cell_delay_ns     [bench::round [path_info $path -cell_delay] 4] \
        routing_delay_ns  [bench::round [path_info $path -ic_delay] 4] \
        clock_skew_ns     [bench::round [path_info $path -clock_skew] 4] \
        clock_uncertainty_ns [bench::round [path_info $path -clock_uncertainty] 4] \
        arrival_time_ns   [bench::round [path_info $path -arrival_time] 4] \
        required_time_ns  [bench::round [path_info $path -required_time] 4] \
        source_node       $from_name \
        destination_node  $to_name \
        source_hierarchy  [node_hierarchy $from_name] \
        destination_hierarchy [node_hierarchy $to_name] \
        from_clock        [clock_name [path_info $path -from_clock]] \
        to_clock          [clock_name [path_info $path -to_clock]] \
    ]
    dict set critical $cname $entry

    # Mirror the interesting bits onto the clock record for the JSON schema.
    dict set clocks $cname logic_depth      [dict get $entry num_logic_levels]
    dict set clocks $cname routing_delay_ns [dict get $entry routing_delay_ns]
    dict set clocks $cname cell_delay_ns    [dict get $entry cell_delay_ns]
    dict set clocks $cname clock_skew_ns    [dict get $entry clock_skew_ns]
    dict set clocks $cname source_hierarchy [dict get $entry source_hierarchy]
    dict set clocks $cname destination_hierarchy [dict get $entry destination_hierarchy]
}

# ---------------------------------------------------------------------------
# Unconstrained paths (SPEC.md 2: "Unconstrained paths: zero")
# ---------------------------------------------------------------------------
set ucp_total ""
lassign [capture_to_file ucp {report_ucp}] ucp_txt ucp_err
if {$ucp_err ne ""} {
    lappend notes "report_ucp failed: $ucp_err"
} else {
    # The "Unconstrained Paths Summary" table counts, per analysis type, the
    # illegal/unconstrained clocks and the paths from/to unconstrained ports.
    # SPEC.md 2 requires this to be zero; every row is summed so a non-zero in
    # any category is visible.
    set total 0
    set seen 0
    foreach label {
        {Illegal Clocks}
        {Unconstrained Clocks}
        {Unconstrained Input Ports}
        {Paths from Unconstrained Input Ports*}
        {Unconstrained Output Ports}
        {Paths to Unconstrained Output Ports*}
    } {
        set vals [table_row_values $ucp_txt $label]
        foreach v $vals {
            set n [bench::num $v]
            if {$n ne ""} { set total [expr {$total + int($n)}]; set seen 1 }
        }
    }
    if {$seen} { set ucp_total $total }
}
if {$ucp_total eq ""} {
    lappend notes "unconstrained path count not resolved from report_ucp; see results/synthesis/sta_ucp.txt"
}

# ---------------------------------------------------------------------------
# Constraints-integrity report (SPEC.md 24)
# ---------------------------------------------------------------------------
# Every false path, multicycle path, asynchronous clock group, disabled timing
# arc and unconstrained endpoint. Written to the text report in full; counts go
# into the JSON so a regression is visible without opening the report.
set integrity [dict create]

lassign [capture_to_file sdc        {report_sdc}]             sdc_txt        e1
lassign [capture_to_file exceptions {report_exceptions}]      exceptions_txt e2
lassign [capture_to_file transfers  {report_clock_transfers}] transfers_txt  e3
lassign [capture_to_file asynch_cdc {report_asynch_cdc}]      asynch_txt     e4
foreach {n e} [list report_sdc $e1 report_exceptions $e2 \
                    report_clock_transfers $e3 report_asynch_cdc $e4] {
    if {$e ne ""} { lappend notes "$n: $e" }
}

# The authoritative source for what exceptions exist is the SDC itself: the
# checked-in exceptions.sdc is empty by design, so these counts must be 0.
proc count_sdc_directive {dir} {
    set n 0
    foreach f [glob -nocomplain [file join $::bench::cons_dir *.sdc]] {
        set fh [open $f r]
        foreach line [split [read $fh] \n] {
            set line [string trim $line]
            if {[string index $line 0] eq "#"} { continue }
            if {[regexp "(^|\\\[|\\s)${dir}(\\s|$)" $line]} { incr n }
        }
        close $fh
    }
    return $n
}

dict set integrity false_paths      [count_sdc_directive set_false_path]
dict set integrity multicycle_paths [count_sdc_directive set_multicycle_path]
dict set integrity clock_groups     [count_sdc_directive set_clock_groups]
dict set integrity max_delays       [count_sdc_directive set_max_delay]
dict set integrity min_delays       [count_sdc_directive set_min_delay]
dict set integrity unconstrained_paths $ucp_total

# "Every disabled timing arc" (SPEC.md 24). Quartus exposes no collection of
# disabled arcs; the scriptable equivalent is the set of SDC constraints the
# analyzer IGNORED, which is what silently disables analysis in practice.
lassign [capture_to_file sdc_ignored {report_sdc -ignored}] sdc_ignored_txt e5
if {$e5 ne ""} { lappend notes "report_sdc -ignored: $e5" }
set ignored_count 0
foreach line [split $sdc_ignored_txt \n] {
    set line [string trim $line]
    if {[string index $line 0] eq ";" && [regexp {set_[a-z_]+} $line]} { incr ignored_count }
}
dict set integrity ignored_sdc_constraints $ignored_count

dict set timing clocks              $clocks
dict set timing critical_path       $critical
dict set timing integrity           $integrity
dict set timing unconstrained_paths $ucp_total
dict set timing clock_names         $clock_names
dict set timing notes               $notes

bench::frag_save timing $timing

# ---------------------------------------------------------------------------
# Human-readable evidence report
# ---------------------------------------------------------------------------
set fh [bench::text_report_open sta]
puts $fh "-- per-clock summary --------------------------------------------------"
dict for {cname cd} $clocks {
    puts $fh "clock: $cname"
    foreach k [lsort [dict keys $cd]] {
        puts $fh [format "    %-24s %s" $k [dict get $cd $k]]
    }
    puts $fh ""
}
puts $fh "-- critical path (worst setup per clock) ------------------------------"
dict for {cname cd} $critical {
    puts $fh "clock: $cname"
    foreach k [lsort [dict keys $cd]] {
        puts $fh [format "    %-24s %s" $k [dict get $cd $k]]
    }
    puts $fh ""
}
puts $fh "-- timing summaries (create_timing_summary) ---------------------------"
dict for {kind txt} $summary_texts {
    puts $fh "  [string toupper $kind]"
    puts $fh $txt
}
puts $fh ""
puts $fh "-- SPEC.md 24 constraints integrity -----------------------------------"
dict for {k v} $integrity { puts $fh [format "    %-24s %s" $k $v] }
puts $fh ""
puts $fh "-- unconstrained paths (report_ucp) ----------------------------------"
puts $fh "    total unconstrained: $ucp_total"
puts $fh $ucp_txt
puts $fh ""
puts $fh "-- report_sdc ---------------------------------------------------------"
puts $fh $sdc_txt
puts $fh ""
puts $fh "-- report_sdc -ignored (disabled / ignored constraints) ---------------"
puts $fh $sdc_ignored_txt
puts $fh ""
puts $fh "-- report_exceptions --------------------------------------------------"
puts $fh $exceptions_txt
puts $fh ""
puts $fh "-- report_clock_transfers --------------------------------------------"
puts $fh $transfers_txt
puts $fh ""
puts $fh "-- report_asynch_cdc --------------------------------------------------"
puts $fh $asynch_txt
if {[llength $notes] > 0} {
    puts $fh ""
    puts $fh "-- notes --------------------------------------------------------------"
    foreach n $notes { puts $fh "    - $n" }
}
close $fh

bench::close_project
bench::log "STA report complete"
exit 0
