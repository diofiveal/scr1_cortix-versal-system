# Inspect an already routed Vivado 2023.2 implementation without changing its
# saved run. Usage:
#   vivado -mode batch -source scripts/scripts/vivado/analyze_routed.tcl \
#     -tclargs /absolute/path/to/vd100_scr1.xpr ?/absolute/path/to/activity.saif?
#
# SAIF is optional. Without it, power is an uncalibrated vectorless estimate.
# Collect SAIF from a representative workload (PS, DDR and SCR1 included if
# those domains matter) before treating the power result as a budget check.

if {[llength $argv] < 1 || [llength $argv] > 2} {
    error "Usage: analyze_routed.tcl project.xpr ?activity.saif?"
}

set project_file [file normalize [lindex $argv 0]]
if {![file isfile $project_file]} {
    error "Vivado project not found: $project_file"
}

open_project $project_file
open_run impl_1

set report_dir [file join [file dirname $project_file] qor_reports]
file mkdir $report_dir

report_timing_summary -file [file join $report_dir timing_summary.rpt]
report_timing -max_paths 50 -file [file join $report_dir worst_50_paths.rpt]
report_methodology -file [file join $report_dir methodology.rpt]
report_power -hier all -file [file join $report_dir power_vectorless.rpt]

if {[llength $argv] == 2} {
    set saif_file [file normalize [lindex $argv 1]]
    if {![file isfile $saif_file]} {
        error "SAIF not found: $saif_file"
    }
    read_saif $saif_file
    report_power -hier all -file [file join $report_dir power_saif.rpt]
    puts "Check Design Nets Matched and Confidence Level in power_saif.rpt"
}

puts "Routed QoR reports: $report_dir"
close_project
