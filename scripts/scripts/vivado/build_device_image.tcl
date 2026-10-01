# Build the Versal PDI and then qualify/export a fixed XSA.
# vivado -mode batch -source scripts/scripts/vivado/build_device_image.tcl \
#   -tclargs project.xpr ?output.xsa?
if {[llength $argv] < 1 || [llength $argv] > 2} {
    error "Usage: build_device_image.tcl project.xpr ?output.xsa?"
}
if {![string match "2023.2*" [version -short]]} {error "Use Vivado 2023.2"}
set project_file [file normalize [lindex $argv 0]]
if {![file isfile $project_file]} {error "Project not found: $project_file"}
open_project $project_file
set synth [get_runs synth_1]
if {[get_property NEEDS_REFRESH $synth] && [get_property STATUS $synth] ne "Not started"} {
    error "Synthesis is stale; rebuild the changed design first"
}
if {![string match "*Complete*" [get_property STATUS $synth]]} {
    launch_runs synth_1 -jobs 4
    wait_on_run synth_1
    if {![string match "*Complete*" [get_property STATUS $synth]]} {error "Synthesis failed"}
}
set impl [get_runs impl_1]
if {[get_property NEEDS_REFRESH $impl] && [get_property STATUS $impl] ne "Not started"} {
    error "Implementation is stale; reset/rebuild it explicitly in Vivado"
}
if {![string match "write_device_image Complete*" [get_property STATUS $impl]]} {
    launch_runs impl_1 -to_step write_device_image -jobs 4
    wait_on_run impl_1
}
if {![string match "write_device_image Complete*" [get_property STATUS $impl]]} {
    error "Device Image generation failed: [get_property STATUS $impl]"
}
close_project
source [file join [file dirname [info script]] export_xsa.tcl]
