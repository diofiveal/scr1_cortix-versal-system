# =============================================================================
# Reusable Tcl helpers for the VD100 + SCR1 Vivado project.
# =============================================================================

proc vd100_require_file {path} {
    if {![file isfile $path]} {
        error "Required file not found: $path"
    }
    return [file normalize $path]
}

proc vd100_require_dir {path} {
    if {![file isdirectory $path]} {
        error "Required directory not found: $path"
    }
    return [file normalize $path]
}

proc vd100_require_one {objects description} {
    if {[llength $objects] != 1} {
        error "Expected exactly one $description, got [llength $objects]: $objects"
    }
    return [lindex $objects 0]
}

proc vd100_require_ip {vlnv} {
    set defs [get_ipdefs -all -quiet $vlnv]
    if {[llength $defs] == 0} {
        error "Required Vivado IP is unavailable: $vlnv"
    }
}

proc vd100_create_ip {name vlnv} {
    vd100_require_ip $vlnv
    return [create_bd_cell -type ip -vlnv $vlnv $name]
}

proc vd100_manifest_entries {manifest} {
    vd100_require_file $manifest
    set fh [open $manifest r]
    set result {}
    while {[gets $fh line] >= 0} {
        set line [string trim $line]
        if {$line eq ""} { continue }
        if {[string match "#*" $line]} { continue }
        lappend result $line
    }
    close $fh
    return $result
}

proc vd100_add_manifest {manifest base_dir fileset} {
    foreach rel [vd100_manifest_entries $manifest] {
        set abs [file normalize [file join $base_dir $rel]]
        vd100_require_file $abs
        add_files -norecurse -fileset $fileset $abs
    }
}

proc vd100_require_text {path needle description} {
    vd100_require_file $path
    set fh [open $path r]
    set data [read $fh]
    close $fh
    if {[string first $needle $data] < 0} {
        error "$description: '$needle' not found in $path"
    }
}

# Create an external AXI port.  FREQ_HZ must be supplied while the interface is
# still writable.  Vivado makes this property read-only after interface
# propagation/connection, so do not try to patch it later.
proc vd100_axi_port {name mode protocol addr_width {data_width 32} {id_width 0} {user_width 0} {freq_hz ""}} {
    set p [create_bd_intf_port -mode $mode -vlnv xilinx.com:interface:aximm_rtl:1.0 $name]

    set props [list \
        CONFIG.PROTOCOL $protocol \
        CONFIG.ADDR_WIDTH $addr_width \
        CONFIG.DATA_WIDTH $data_width \
        CONFIG.HAS_PROT 1 \
        CONFIG.HAS_WSTRB 1 \
        CONFIG.HAS_BRESP 1 \
        CONFIG.HAS_RRESP 1]

    if {$freq_hz ne ""} {
        lappend props CONFIG.FREQ_HZ $freq_hz
    }

    if {$protocol eq "AXI4"} {
        lappend props \
            CONFIG.ID_WIDTH $id_width \
            CONFIG.HAS_BURST 1 \
            CONFIG.HAS_LOCK 1 \
            CONFIG.HAS_CACHE 1 \
            CONFIG.HAS_QOS 1 \
            CONFIG.HAS_REGION 1 \
            CONFIG.AWUSER_WIDTH $user_width \
            CONFIG.ARUSER_WIDTH $user_width \
            CONFIG.WUSER_WIDTH $user_width \
            CONFIG.RUSER_WIDTH $user_width \
            CONFIG.BUSER_WIDTH $user_width \
            CONFIG.NUM_READ_OUTSTANDING 2 \
            CONFIG.NUM_WRITE_OUTSTANDING 2 \
            CONFIG.SUPPORTS_NARROW_BURST 1
    }

    set_property -dict $props $p
    return $p
}

proc vd100_find_external_segment {port_name} {
    set port [get_bd_intf_ports -quiet $port_name]
    set candidates {}
    if {[llength $port] == 1} {
        set candidates [get_bd_addr_segs -quiet -of_objects $port]
    }
    if {[llength $candidates] == 0} {
        set candidates [get_bd_addr_segs -quiet ${port_name}/Reg]
    }
    if {[llength $candidates] == 0} {
        set candidates [get_bd_addr_segs -quiet */${port_name}/Reg]
    }
    if {[llength $candidates] == 0} {
        set candidates [get_bd_addr_segs -quiet *${port_name}*]
    }
    if {[llength $candidates] != 1} {
        error "Cannot identify the external address segment for $port_name: $candidates"
    }
    return [lindex $candidates 0]
}

# A NoC ingress connected to MC_n creates Cn_DDR_LOW0, not always C0_DDR_LOW0.
# Search for the controller index rather than assuming C0.
proc vd100_find_noc_ddr_segment {noc_cell si_name} {
    set candidates [get_bd_addr_segs -quiet ${noc_cell}/${si_name}/C*_DDR_LOW0]
    if {[llength $candidates] == 0} {
        set candidates [get_bd_addr_segs -quiet ${noc_cell}/${si_name}/*DDR_LOW0*]
    }
    if {[llength $candidates] != 1} {
        error "Cannot identify DDR segment for ${noc_cell}/${si_name}: $candidates"
    }
    return [lindex $candidates 0]
}

proc vd100_find_addr_space {name} {
    set candidates [get_bd_addr_spaces -quiet $name]
    if {[llength $candidates] == 0} {
        set port [get_bd_intf_ports -quiet $name]
        if {[llength $port] == 1} {
            set candidates [get_bd_addr_spaces -quiet -of_objects $port]
        }
    }
    if {[llength $candidates] == 0} {
        set candidates [get_bd_addr_spaces -quiet *${name}*]
    }
    if {[llength $candidates] != 1} {
        error "Cannot identify address space '$name': $candidates"
    }
    return [lindex $candidates 0]
}

proc vd100_map_segment {addr_space segment offset range} {
    set space [vd100_find_addr_space $addr_space]
    assign_bd_address -offset $offset -range $range \
        -target_address_space $space $segment -force
}

proc vd100_exclude_segment {addr_space segment} {
    set space [vd100_find_addr_space $addr_space]
    exclude_bd_addr_seg -target_address_space $space $segment
}
