# Estimate the maximum SCR1 PL-clock frequency from the already routed design.
# Usage from the Tcl Console of an open Vivado project:
#   source estimate_fmax.tcl
#
# Usage in batch mode:
#   vivado -mode batch -source scripts/scripts/vivado/estimate_fmax.tcl \
#     -tclargs /absolute/path/to/vd100_scr1.xpr
#
# This calculation assumes the worst same-SCR1-clock setup path has a
# one-cycle requirement. It does not re-synthesize or re-route at the computed
# frequency. Re-implement and check timing at any proposed operating clock.

if {[llength $argv] > 1} {
    error "Usage: source estimate_fmax.tcl, or use -tclargs /absolute/path/to/vd100_scr1.xpr"
}

set opened_project_here 0
if {[llength $argv] == 1} {
    set project_file [file normalize [lindex $argv 0]]
    if {![file isfile $project_file]} {
        error "Vivado project not found: $project_file"
    }
    if {[current_project -quiet] ne ""} {
        error "A Vivado project is already open. Run 'source estimate_fmax.tcl' without arguments, or close it before using -tclargs."
    }
    open_project $project_file
    set opened_project_here 1
} else {
    set project_object [current_project -quiet]
    if {$project_object eq ""} {
        error "No Vivado project is open. Open the project first, then run 'source estimate_fmax.tcl'."
    }
    set project_dir [get_property DIRECTORY $project_object]
    set project_name [get_property NAME $project_object]
    set project_file [file join $project_dir "${project_name}.xpr"]
}

open_run impl_1

# The Linux build drives top-level clk from pll_pl_scr1, not directly from
# CIPS clk_pl_0. Resolve the actual clock on the unchanged board-top net.
set scr1_clock [get_clocks -quiet -of_objects [get_nets -quiet clk]]
if {[llength $scr1_clock] != 1} {
    set pll_output [get_pins -hier -quiet -filter {NAME =~ *pll_pl_scr1*/clk_out1}]
    set scr1_clock [get_clocks -quiet -of_objects $pll_output]
}
if {[llength $scr1_clock] != 1} {
    # Backwards compatibility with earlier successful non-PLL projects.
    set scr1_clock [get_clocks -quiet clk_pl_0]
}
if {[llength $scr1_clock] != 1} {
    error "Cannot identify a unique SCR1 clock on top-level clk / pll_pl_scr1"
}
set scr1_clock_name [get_property NAME $scr1_clock]

set period_ns [get_property PERIOD $scr1_clock]
set paths [get_timing_paths -setup -from $scr1_clock -to $scr1_clock \
    -max_paths 1 -sort_by slack]
if {[llength $paths] != 1} {
    error "No constrained same-clock setup path found for $scr1_clock_name"
}

set worst_path [lindex $paths 0]
set slack_ns [get_property SLACK $worst_path]
set requirement_ns [get_property REQUIREMENT $worst_path]

# The period-minus-slack estimate is meaningful for a same-clock, one-cycle
# setup path. A multicycle/max-delay/phase-shifted requirement needs its own
# analysis; in that case refuse to print a misleading Fmax number.
if {[expr {abs(double($requirement_ns) - double($period_ns))}] > 0.001} {
    error "Worst path requirement ($requirement_ns ns) differs from clock period ($period_ns ns); inspect timing exceptions/clock edges manually"
}

set limiting_period_ns [expr {double($period_ns) - double($slack_ns)}]
if {$limiting_period_ns <= 0.0} {
    error "Nonpositive estimated period: $limiting_period_ns ns"
}

set f_target_mhz [expr {1000.0 / double($period_ns)}]
set f_est_mhz [expr {1000.0 / $limiting_period_ns}]
set start_pin [get_property NAME [get_property STARTPOINT_PIN $worst_path]]
set end_pin [get_property NAME [get_property ENDPOINT_PIN $worst_path]]

set report_dir [file join [file dirname $project_file] qor_reports]
file mkdir $report_dir
set report_file [file join $report_dir scr1_fmax_estimate.txt]
set fh [open $report_file w]
set lines [list \
    "SCR1 clock: $scr1_clock_name" \
    [format "Constrained period: %.3f ns (%.3f MHz)" $period_ns $f_target_mhz] \
    [format "Worst setup slack: %.3f ns" $slack_ns] \
    [format "Estimated limiting period: %.3f ns" $limiting_period_ns] \
    [format "Estimated Fmax of this routed SCR1 domain: %.3f MHz" $f_est_mhz] \
    "Start: $start_pin" \
    "End:   $end_pin" \
    "Estimate only: re-run implementation and timing at the proposed frequency."]
foreach line $lines {
    puts $fh $line
    puts $line
}
close $fh
puts "Saved: $report_file"
if {$opened_project_here} {
    close_project
}
