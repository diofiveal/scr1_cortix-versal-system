# Export only a successful, current Cortix Linux implementation.
# vivado -mode batch -source scripts/scripts/vivado/export_xsa.tcl \
#   -tclargs project.xpr ?output.xsa?
# This script does not launch/reset runs or invent a successful timing result.

proc vd100_export_xsa {project_file output_file} {
    if {![string match "2023.2*" [version -short]]} {
        error "Use Vivado 2023.2 for this hardware/PetaLinux handoff"
    }
    if {![file isfile $project_file]} {error "Project not found: $project_file"}
    open_project $project_file
    if {[string tolower [get_property PART [current_project]]] ne "xcve2302-sfva784-1lp-e-s"} {
        error "This is not the VD100 XCVE2302 project"
    }
    set run [get_runs impl_1]
    if {[get_property NEEDS_REFRESH $run]} {error "Implementation is stale; rebuild before export"}
    if {![string match "*Complete*" [get_property STATUS $run]]} {
        error "Implementation is not complete: [get_property STATUS $run]"
    }
    set run_dir [get_property DIRECTORY $run]
    if {[llength [glob -nocomplain -directory $run_dir *.pdi]] == 0} {
        error "Generate Device Image first: impl_1 has no PDI"
    }
    set bd [get_files -quiet */vd100_platform.bd]
    if {[llength $bd] != 1} {error "Expected the Cortix vd100_platform BD"}
    open_bd_design $bd
    foreach cell {pll_pl_scr1 versal_cips_0 axi_noc_0} {
        if {[llength [get_bd_cells -quiet $cell]] != 1} {error "Missing $cell; recreate the Linux BD"}
    }
    foreach pin {versal_cips_0/PMC_NOC_AXI_0 versal_cips_0/LPD_AXI_NOC_0} {
        if {[llength [get_bd_intf_nets -quiet -of_objects [get_bd_intf_pins $pin]]] != 1} {
            error "Native DDR route is not connected: $pin"
        }
    }
    validate_bd_design
    if {[get_property NEEDS_REFRESH $run]} {
        error "BD validation changed the hardware; re-implement before exporting"
    }
    open_run impl_1
    set reports [file join [file dirname $output_file] reports]
    file mkdir $reports
    report_timing_summary -report_unconstrained -file [file join $reports routed_timing.rpt]
    report_cdc -file [file join $reports routed_cdc.rpt]
    report_drc -file [file join $reports routed_drc.rpt]
    foreach delay {max min} name {setup hold} {
        set paths [get_timing_paths -quiet -delay_type $delay -max_paths 1]
        if {[llength $paths] != 1} {error "No $name path available; cannot qualify timing"}
        set slack [get_property SLACK [lindex $paths 0]]
        if {![string is double -strict $slack] || $slack < 0} {
            error "Negative/invalid $name slack: $slack ns. XSA not exported."
        }
        puts "INFO: routed worst $name slack = $slack ns"
    }
    if {[llength [get_drc_violations -quiet -filter {SEVERITY == Error}]] != 0} {
        error "Error-severity DRC violations remain; XSA not exported"
    }
    # On Versal, -include_bit includes the generated device image (PDI).
    # Do not replace it with ALINX's design_1_wrapper.xsa/PDI.
    if {[file exists $output_file]} {error "Refusing to overwrite existing XSA: $output_file"}
    write_hw_platform -fixed -include_bit $output_file
    puts "INFO: XSA exported: $output_file"
    puts "INFO: Review unconstrained-path/CDC reports; SD boot is a separate hardware test."
    close_project
}

# When sourced by build_device_image.tcl only define the procedure.
if {![info exists ::vd100_export_library_only]} {
    if {[llength $argv] < 1 || [llength $argv] > 2} {
        error "Usage: export_xsa.tcl project.xpr ?output.xsa?"
    }
    set project_file [file normalize [lindex $argv 0]]
    set output_file [file normalize [file join [file dirname $project_file] .. .. hardware cortix_scr1.xsa]]
    if {[llength $argv] == 2} {set output_file [file normalize [lindex $argv 1]]}
    file mkdir [file dirname $output_file]
    vd100_export_xsa $project_file $output_file
}
