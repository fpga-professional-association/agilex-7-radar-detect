# ---------------------------------------------------------------------------
# compile.tcl — scripted Quartus Prime Pro compile driver
# Governing spec: SPEC.md 15, 16, 17 (Compilation section).
#
# Usage:
#   quartus_sh -t compile.tcl <stage> [seed]
#
#   stage = map   Analysis & Synthesis only          (quartus_syn)
#           fit   Analysis & Synthesis + Fitter      (quartus_syn, quartus_fit)
#           sta   Timing analysis only, on an existing fit  (quartus_sta)
#           all   map + fit + sta
#   seed  = fitter seed, default 1. Recorded in the exported JSON, NOT in the
#           qsf (see the qsf preservation note below).
#
# Records, per SPEC.md 17: tool version, device, revision, seed, wall-clock time
# per stage, peak memory, stages completed, fatal errors, warnings. The result
# is written as a fragment for export_results.tcl to merge.
#
# Quartus Pro flow note: this uses ::quartus::flow `execute_module -tool syn |
# fit | sta`, which is the Pro-edition module set (quartus_syn, not the Classic
# quartus_map). The `-tool` values were verified against this install's
# execute_module usage string, which lists: asm cdb eda fit map syn pow sta stp
# sim si cpf ipg pfg qtlg quick_elaboration sh.
# ---------------------------------------------------------------------------

source [file join [file dirname [info script]] common.tcl]

package require ::quartus::flow
package require ::quartus::project

# --- arguments --------------------------------------------------------------
set stage "map"
set seed  1

if {[llength $quartus(args)] >= 1} { set stage [string tolower [lindex $quartus(args) 0]] }
if {[llength $quartus(args)] >= 2} { set seed  [lindex $quartus(args) 1] }

if {[lsearch -exact {map fit sta all} $stage] < 0} {
    puts stderr "ERROR: unknown stage '$stage'. Expected one of: map fit sta all"
    exit 2
}
if {![string is integer -strict $seed]} {
    puts stderr "ERROR: seed must be an integer, got '$seed'"
    exit 2
}

set stage_list {}
switch -- $stage {
    map { set stage_list {syn} }
    fit { set stage_list {syn fit} }
    sta { set stage_list {sta} }
    all { set stage_list {syn fit sta} }
}

bench::ensure_dirs

# A new compile invalidates every previously exported report. Without this, a
# `quartus-map` run followed by `quartus-report` would silently merge the
# post-fit timing and utilization fragments of an EARLIER compile into a
# map-only record — a plausible-looking result describing a design state that
# no longer exists. The report_*.tcl scripts regenerate whatever the new stage
# can actually support.
bench::frag_clear

bench::log "stage=$stage seed=$seed modules=[join $stage_list {, }]"
bench::log "quartus=[bench::quartus_version]"

# ---------------------------------------------------------------------------
# Report scraping helpers
# ---------------------------------------------------------------------------
# Each command-line executable writes output_files/<revision>.<tool>.rpt and
# ends it with a summary line of the form
#   "Quartus Prime <Tool> was successful. 0 errors, 42 warnings"
# plus "Peak virtual memory: N megabytes". These are the authoritative
# per-module error/warning/memory numbers.
proc module_rpt {tool} {
    set names [list ${bench::revision}.${tool}.rpt]
    if {$tool eq "syn"} { lappend names ${bench::revision}.map.rpt }
    foreach n $names {
        set p [file join $bench::out_dir $n]
        if {[file exists $p]} { return $p }
    }
    return ""
}

proc scrape_module {tool} {
    set res [dict create errors "" warnings "" peak_memory_mb "" report ""]
    set path [module_rpt $tool]
    if {$path eq ""} { return $res }
    dict set res report [file tail $path]
    set fh [open $path r]
    set txt [read $fh]
    close $fh
    if {[regexp {([0-9]+) error[s]?, ([0-9]+) warning[s]?} $txt -> e w]} {
        dict set res errors $e
        dict set res warnings $w
    }
    set peak ""
    foreach {- mb} [regexp -all -inline {Peak virtual memory: ([0-9]+) megabytes} $txt] {
        if {$peak eq "" || $mb > $peak} { set peak $mb }
    }
    dict set res peak_memory_mb $peak
    return $res
}

# ---------------------------------------------------------------------------
# Run
# ---------------------------------------------------------------------------
# qsf preservation, belt and braces.
#
# By default execute_module exports the assignment database to the qsf before
# launching each executable, which APPENDS Quartus's own defaults
# (LAST_QUARTUS_VERSION, PWRMGT_*, AUTO_OPEN_DRAIN_PINS, ...) plus any
# run-specific assignment to the hand-maintained file. Two independent
# defences, because this leaked once during development when a compile was
# killed mid-run:
#
#   1. -dont_export_assignments on every execute_module call, and the seed
#      passed to quartus_fit as a command-line argument instead of being set as
#      an assignment. Nothing ever asks Quartus to write the qsf.
#   2. This byte-level snapshot/restore, which still runs on the normal and the
#      error path. It cannot survive a SIGKILL, which is exactly why defence 1
#      exists and is the primary one.
bench::qsf_snapshot

set overall_start [clock milliseconds]
set stages_completed {}
set stage_seconds [dict create]
set errors_total 0
set warnings_total 0
set peak_memory_mb ""
set fatal ""
set module_detail [dict create]

set rc 0
if {[catch {
    bench::open_project

    foreach tool $stage_list {
        # The fitter seed is a per-run parameter, passed on the command line
        # (quartus_fit --seed=<n>) rather than written into the assignment
        # database, so it can never reach the tracked qsf. --write_settings_files=off
        # additionally forbids the Fitter from writing settings back.
        # SPEC.md 25 seed experiments read the value from the exported JSON,
        # which is the single source of truth for what ran.
        set args {}
        if {$tool eq "fit"} {
            set args [list -args "--seed=$seed --write_settings_files=off"]
        }

        bench::log "=== running module: $tool [join $args] ==="
        set t0 [clock milliseconds]
        set module_ok 1
        if {[catch {eval [concat [list execute_module -tool $tool -dont_export_assignments] $args]} module_err]} {
            set module_ok 0
        }
        set dt [expr {([clock milliseconds] - $t0) / 1000.0}]
        dict set stage_seconds $tool [bench::round $dt 1]

        set s [scrape_module $tool]
        dict set module_detail $tool [dict merge $s [dict create seconds [bench::round $dt 1] ok $module_ok]]

        set e [dict get $s errors]
        set w [dict get $s warnings]
        if {$e ne ""} { incr errors_total   $e }
        if {$w ne ""} { incr warnings_total $w }
        set pm [dict get $s peak_memory_mb]
        if {$pm ne "" && ($peak_memory_mb eq "" || $pm > $peak_memory_mb)} {
            set peak_memory_mb $pm
        }

        if {!$module_ok} {
            set fatal "module '$tool' failed: $module_err"
            bench::log "FATAL: $fatal"
            set rc 1
            break
        }
        lappend stages_completed $tool
        bench::log "=== module $tool ok in [bench::round $dt 1] s ==="
    }
} outer_err]} {
    set fatal $outer_err
    set rc 1
    bench::log "FATAL: $outer_err"
}

set total_seconds [bench::round [expr {([clock milliseconds] - $overall_start) / 1000.0}] 1]

catch {bench::close_project}
bench::qsf_restore
bench::log "restored pristine qsf"

# ---------------------------------------------------------------------------
# Fragment
# ---------------------------------------------------------------------------
set d [dict create \
    stage_requested   $stage \
    seed              $seed \
    quartus_version   [bench::quartus_version_short] \
    quartus_version_full [bench::quartus_version] \
    device            $bench::device \
    revision          $bench::revision \
    project           $bench::project \
    modules_requested $stage_list \
    stages_completed  $stages_completed \
    stage_seconds     $stage_seconds \
    compile_seconds   $total_seconds \
    peak_memory_mb    $peak_memory_mb \
    errors            $errors_total \
    warnings          $warnings_total \
    fatal             $fatal \
    module_detail     $module_detail \
    timestamp         [clock format [clock seconds] -format {%Y-%m-%dT%H:%M:%S}] \
    epoch             [clock seconds] \
]

bench::frag_save compile $d

bench::log "stages completed : [join $stages_completed {, }]"
bench::log "errors           : $errors_total"
bench::log "warnings         : $warnings_total"
bench::log "peak memory (MB) : $peak_memory_mb"
bench::log "wall clock (s)   : $total_seconds"

if {$rc != 0} {
    puts stderr "ERROR: compile stage '$stage' failed: $fatal"
}
exit $rc
