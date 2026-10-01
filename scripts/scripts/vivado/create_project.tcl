# =============================================================================
# One-command Vivado 2023.2 project creation + BD generation + synthesis.
# Run from any directory:
#   vivado -mode batch -source scripts/scripts/vivado/create_project.tcl
# =============================================================================

set script_dir [file normalize [file dirname [info script]]]
source [file join $script_dir project_info.tcl]
source [file join $script_dir helpers.tcl]
source [file join $script_dir add_sources.tcl]
source [file join $script_dir build_bd.tcl]

set current_version [version -short]
if {![string match "${::vd100::vivado_version}*" $current_version]} {
    error "This project targets Vivado $::vd100::vivado_version; current Vivado is $current_version"
}

file mkdir $::vd100::build_root
file mkdir $::vd100::project_dir

if {[file exists [file join $::vd100::project_dir ${::vd100::project_name}.xpr]]} {
    error "Project already exists; open it or choose a new build_root in project_info.tcl. Refusing to overwrite a working build."
}
create_project $::vd100::project_name $::vd100::project_dir \
    -part $::vd100::part

set_property target_language Verilog [current_project]
set_property simulator_language Mixed [current_project]
set_property source_mgmt_mode All [current_project]

# Add RTL + SCR1 + XDC first, then build the vendor-IP platform.
vd100_add_sources
vd100_build_bd

# Generate the HDL wrapper used by rtl/vd100_scr1_top.sv.
set bd_file [vd100_require_one [get_files -quiet ${::vd100::bd_name}.bd] \
    "Block Design file"]
generate_target all $bd_file

set wrapper_files [make_wrapper -files $bd_file -top]
foreach wrapper $wrapper_files {
    if {[llength [get_files -quiet $wrapper]] == 0} {
        add_files -norecurse -fileset sources_1 $wrapper
    }
}

set_property top $::vd100::top_name [get_filesets sources_1]
update_compile_order -fileset sources_1
update_compile_order -fileset sim_1


puts ""
puts "============================================================"
puts "VD100 + SCR1 project created"
puts "Project : $::vd100::project_dir/$::vd100::project_name.xpr"
puts "Top     : $::vd100::top_name"
puts "BD      : $::vd100::bd_name"
puts "============================================================"

if {$::vd100::run_synthesis} {
    set report_dir [file join $::vd100::build_root reports]
    file mkdir $report_dir

    reset_run synth_1
    launch_runs synth_1 -jobs $::vd100::jobs
    wait_on_run synth_1

    set synth_status [get_property STATUS [get_runs synth_1]]
    puts "Synthesis status: $synth_status"
    if {![string match "*Complete*" $synth_status]} {
        error "Synthesis did not complete successfully: $synth_status"
    }

    open_run synth_1
    report_utilization -file [file join $report_dir synth_utilization.rpt]
    report_timing_summary -file [file join $report_dir synth_timing_summary.rpt]
    report_drc -file [file join $report_dir synth_drc.rpt]

    puts "Synthesis reports: $report_dir"
}
