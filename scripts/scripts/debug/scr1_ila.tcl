# Source in Vivado 2023.2 Hardware Manager AFTER connecting/selecting a device
# and programming the matching PDI (or booting its matching BOOT.BIN from SD).
# This helper never reprograms/resets the board or accesses functional MMIO.
set ::scr1_debug_root [file normalize [file join [file dirname [info script]] ../../..]]

proc scr1_ila_attach {{ltx ""}} {
    if {$ltx eq ""} {set ltx [file join $::scr1_debug_root build hardware cortix_scr1.ltx]}
    set ltx [file normalize $ltx]
    if {![file isfile $ltx]} {error "Matching LTX not found: $ltx"}
    set device [current_hw_device]
    set_property PROBES.FILE $ltx $device
    refresh_hw_device $device
    set ilas [get_hw_ilas -of_objects $device -filter {CELL_NAME =~ "*axis_ila_scr1*"}]
    if {[llength $ilas] != 1} {
        error "Expected one axis_ila_scr1; check matching PDI/LTX, AXI Debug Hub, clock and debug transport"
    }
    set ::scr1_debug_ila [lindex $ilas 0]
    puts "INFO: Attached $::scr1_debug_ila; scr1_ila_now or scr1_ila_arm_read 0/3/4"
    return $::scr1_debug_ila
}

proc scr1_ila_require {} {
    if {![info exists ::scr1_debug_ila]} {error "Run scr1_ila_attach first"}
    return $::scr1_debug_ila
}

proc scr1_ila_now {} {
    set ila [scr1_ila_require]
    reset_hw_ila $ila
    run_hw_ila -trigger_now $ila
    puts "INFO: Immediate capture started; call scr1_ila_save /path/to/capture"
}

proc scr1_ila_arm_read {slot} {
    if {![string is integer -strict $slot] || $slot < 0 || $slot > 6} {error "AXI slot must be 0..6"}
    set ila [scr1_ila_require]
    reset_hw_ila $ila
    set matches {}
    foreach probe [get_hw_probes -of_objects $ila] {
        if {[string match -nocase "*slot_${slot}_axi*arvalid*" [get_property NAME $probe]]} {
            lappend matches $probe
        }
    }
    if {[llength $matches] != 1} {
        error "Cannot identify SLOT_${slot}_AXI ARVALID in this LTX; inspect get_hw_probes -of_objects $ila"
    }
    set_property CONTROL.TRIGGER_MODE BASIC_ONLY $ila
    set_property CONTROL.TRIGGER_POSITION 1024 $ila
    set_property TRIGGER_COMPARE_VALUE "eq1'b1" [lindex $matches 0]
    run_hw_ila $ila
    puts "INFO: Armed on slot $slot ARVALID. Now perform ONE Linux/XSDB read, then scr1_ila_save."
}

proc scr1_ila_save {prefix} {
    set ila [scr1_ila_require]
    set prefix [file normalize $prefix]
    foreach suffix {ila csv} {
        if {[file exists ${prefix}.$suffix]} {error "Capture already exists: ${prefix}.$suffix"}
    }
    file mkdir [file dirname $prefix]
    # Bounded wait: a missing transaction/clock must not hang the Tcl console.
    wait_on_hw_ila -timeout 10 $ila
    set data [upload_hw_ila_data $ila]
    write_hw_ila_data ${prefix}.ila $data
    write_hw_ila_data -csv_file ${prefix}.csv $data
    display_hw_ila_data $data
    puts "INFO: Capture saved: ${prefix}.ila and ${prefix}.csv"
}
