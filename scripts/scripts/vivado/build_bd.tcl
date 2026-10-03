# =============================================================================
# Create the vd100_platform Block Design.
# =============================================================================

proc vd100_build_bd {} {
    variable ::vd100::bd_name

    foreach ip [list \
        xilinx.com:ip:versal_cips:3.4 \
        xilinx.com:ip:axi_noc:1.0 \
        xilinx.com:ip:smartconnect:1.0 \
        xilinx.com:ip:axi_gpio:2.0 \
        xilinx.com:ip:axis_ila:1.2 \
        xilinx.com:ip:clk_wizard:1.0 \
        xilinx.com:ip:proc_sys_reset:5.0 \
        xilinx.com:ip:util_ds_buf:2.2 \
        xilinx.com:ip:xlconstant:1.1] {
        vd100_require_ip $ip
    }

    if {[llength [get_files -quiet ${bd_name}.bd]] != 0} {
        error "Block Design '$bd_name' already exists in the project"
    }

    create_bd_design $bd_name
    current_bd_design $bd_name

    set script_dir [file dirname [info script]]
    source [file join $script_dir ps_config.tcl]
    source [file join $script_dir noc_config.tcl]
    source [file join $script_dir pl_config.tcl]
    source [file join $script_dir address_map.tcl]
    source [file join $script_dir debug_config.tcl]

    vd100_create_pl
    vd100_assign_addresses
    vd100_create_debug

    validate_bd_design
    save_bd_design
}

