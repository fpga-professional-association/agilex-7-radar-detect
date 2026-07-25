# ---------------------------------------------------------------------------
# common.tcl — shared helpers for the Agilex 7 wideband Quartus scripts
# Governing spec: SPEC.md 15, 17.
#
# Sourced by every other script in this directory. Contains no side effects
# beyond defining the bench:: namespace and computing paths.
#
# Report data flow (SPEC.md 17: "Use Tcl to export the results rather than
# scraping GUI text"):
#
#   compile.tcl              -> results/synthesis/frag_compile.tcl
#   report_sta.tcl           -> results/synthesis/frag_timing.tcl      + .rpt
#   report_utilization.tcl   -> results/synthesis/frag_utilization.tcl + .rpt
#   report_congestion.tcl    -> results/synthesis/frag_congestion.tcl  + .rpt
#   report_retiming.tcl      -> results/synthesis/frag_retiming.tcl    + .rpt
#   export_results.tcl       -> reads every fragment, emits ONE JSON record to
#                               results/timing/
#
# A fragment is a Tcl-sourceable file holding one `dict set REPORT <section>
# <dict>` line. Tcl dicts round-trip losslessly through [list], so no ad-hoc
# parser is needed and a missing fragment simply means that section is absent
# from the JSON (with a note explaining why).
# ---------------------------------------------------------------------------

namespace eval bench {}

set bench::script_dir [file normalize [file dirname [info script]]]
set bench::repo_root  [file normalize [file join $bench::script_dir .. ..]]
set bench::proj_dir   [file join $bench::repo_root quartus project]
set bench::cons_dir   [file join $bench::repo_root quartus constraints]
set bench::synth_dir  [file join $bench::repo_root results synthesis]
set bench::timing_dir [file join $bench::repo_root results timing]

set bench::project    agilex7_wideband
set bench::revision   agilex7_wideband
set bench::qsf        [file join $bench::proj_dir ${bench::project}.qsf]
set bench::out_dir    [file join $bench::proj_dir output_files]

# Device constants from SPEC.md 2. Used for utilization percentages.
set bench::device        AGMF039R47B1E1VC
set bench::total_alms    1305600
set bench::total_alm_regs 5222400
set bench::total_m20k    18960
set bench::total_dsp     12300

proc bench::log {msg} {
    puts "\[bench\] $msg"
}

proc bench::ensure_dirs {} {
    foreach d [list $bench::synth_dir $bench::timing_dir $bench::out_dir] {
        if {![file isdirectory $d]} { file mkdir $d }
    }
}

# The Quartus version is DETECTED, never hardcoded (SPEC.md 15).
# $quartus(version) looks like:
#   "Version 26.1.0 Build 110 03/26/2026 SC Pro Edition"
proc bench::quartus_version {} {
    if {[info exists ::quartus(version)]} { return $::quartus(version) }
    return "unknown"
}

# Compact form, e.g. "26.1.0 Build 110 Pro".
proc bench::quartus_version_short {} {
    set v [bench::quartus_version]
    set num "unknown"
    set build ""
    set edition ""
    regexp {Version\s+(\S+)} $v -> num
    regexp {Build\s+(\d+)} $v -> build
    if {[regexp {(Pro|Standard|Lite)\s+Edition} $v -> edition]} {} else { set edition "" }
    set out $num
    if {$build ne ""}   { append out " Build $build" }
    if {$edition ne ""} { append out " $edition" }
    return $out
}

# --- project handling -------------------------------------------------------
# Always run from the project directory: every path in the qsf is relative to
# it, so the project is position independent.
proc bench::open_project {} {
    cd $bench::proj_dir
    if {[is_project_open]} {
        if {[string equal [get_project_name] $bench::project]} { return }
        project_close
    }
    if {![project_exists $bench::project]} {
        error "project not found: [file join $bench::proj_dir ${bench::project}.qpf]"
    }
    project_open $bench::project -revision $bench::revision
}

proc bench::close_project {} {
    if {[is_project_open]} { project_close }
}

# ---------------------------------------------------------------------------
# qsf preservation
# ---------------------------------------------------------------------------
# execute_module exports the in-memory assignment database to the qsf before
# running a command-line executable. That rewrite drops every comment and
# reorders the file, which would make the hand-maintained, reviewable qsf
# unreviewable and would leave run-specific state (the seed) committed.
#
# So: snapshot the qsf bytes before touching the project, restore them after.
# The seed lives in the exported JSON, not in the qsf.
proc bench::qsf_snapshot {} {
    set fh [open $bench::qsf r]
    fconfigure $fh -translation binary
    set ::bench::qsf_backup [read $fh]
    close $fh
}

proc bench::qsf_restore {} {
    if {![info exists ::bench::qsf_backup]} { return }
    set fh [open $bench::qsf w]
    fconfigure $fh -translation binary
    puts -nonewline $fh $::bench::qsf_backup
    close $fh
}

# --- fragment IO ------------------------------------------------------------
proc bench::frag_path {section} {
    return [file join $bench::synth_dir frag_${section}.tcl]
}

proc bench::frag_save {section d} {
    bench::ensure_dirs
    set path [bench::frag_path $section]
    set fh [open $path w]
    fconfigure $fh -translation lf
    puts $fh "# Generated by quartus/scripts — do not edit. Sourced by export_results.tcl."
    puts $fh [format "dict set REPORT %s %s" [list $section] [list $d]]
    close $fh
    bench::log "wrote fragment $path"
    return $path
}

proc bench::frag_load_all {} {
    set REPORT [dict create]
    foreach path [lsort [glob -nocomplain [file join $bench::synth_dir frag_*.tcl]]] {
        if {[catch {source $path} err]} {
            bench::log "WARNING: could not load fragment $path: $err"
        }
    }
    return $REPORT
}

proc bench::frag_clear {} {
    foreach path [glob -nocomplain [file join $bench::synth_dir frag_*.tcl]] {
        file delete -force $path
    }
}

# --- human-readable report files -------------------------------------------
proc bench::text_report_open {name} {
    bench::ensure_dirs
    set path [file join $bench::synth_dir ${name}.rpt]
    set fh [open $path w]
    fconfigure $fh -translation lf
    puts $fh "# $name — Agilex 7 wideband benchmark"
    puts $fh "# device      : $bench::device"
    puts $fh "# quartus     : [bench::quartus_version]"
    puts $fh "# generated   : [clock format [clock seconds] -format {%Y-%m-%dT%H:%M:%S}]"
    puts $fh ""
    return $fh
}

# --- misc -------------------------------------------------------------------
proc bench::git_commit {} {
    set commit "unknown"
    catch {
        set out [exec git -C $bench::repo_root rev-parse --short=10 HEAD]
        set commit [string trim $out]
    }
    return $commit
}

proc bench::git_dirty {} {
    set dirty 0
    catch {
        set out [exec git -C $bench::repo_root status --porcelain]
        if {[string trim $out] ne ""} { set dirty 1 }
    }
    return $dirty
}

# Round to n decimal places, returning a bare number (never in exponent form).
proc bench::round {v {n 3}} {
    if {$v eq "" || ![string is double -strict $v]} { return $v }
    return [format "%.${n}f" $v]
}

# Percentage helper that tolerates a missing numerator.
proc bench::pct {used total {n 3}} {
    if {$used eq "" || ![string is double -strict $used]} { return "" }
    if {$total == 0} { return "" }
    return [bench::round [expr {100.0 * double($used) / double($total)}] $n]
}

# dict get with a default, so a report section that a given stage could not
# produce reads back as "" (rendered as JSON null) instead of raising.
proc dict_get_or {d key {default ""}} {
    if {[catch {dict exists $d $key} ok] || !$ok} { return $default }
    return [dict get $d $key]
}

# Strip thousands separators and stray units out of a Quartus report cell,
# leaving a bare number, or "" if the cell holds no number.
proc bench::num {s} {
    set s [string trim $s]
    if {$s eq "" || $s eq "N/A" || $s eq "-" || $s eq "--"} { return "" }
    regsub -all {,} $s "" s
    # "12345 / 1305600 ( 1 % )" -> take the first field
    if {[regexp {^([-+]?[0-9]*\.?[0-9]+(?:[eE][-+]?[0-9]+)?)} $s -> m]} { return $m }
    return ""
}
