# Versal 2023.2 AXIS ILA. CIPS supplies the native DPC debug transport;
# opt_design automatically inserts/stitches the AXI Debug Hub and its NoC.
# Do not instantiate the unsupported jtag_axi or the legacy ila/system_ila IP.
# See docs/linux_bringup.md for the slot/probe contract and hardware checks.
proc vd100_create_debug {} {
    foreach {name width} {
        debug_scr1_resetn_i 1 debug_lifecycle_i 4
        debug_axi_fault_i 4 debug_outstanding_i 12
    } {
        if {$width == 1} {
            create_bd_port -dir I $name
        } else {
            create_bd_port -dir I -from [expr {$width - 1}] -to 0 $name
        }
    }

    set ila [vd100_create_ip axis_ila_scr1 xilinx.com:ip:axis_ila:1.2]
    set props [list CONFIG.C_MON_TYPE {Mixed} \
        CONFIG.C_NUM_MONITOR_SLOTS {7} CONFIG.C_NUM_OF_PROBES {9} \
        CONFIG.C_DATA_DEPTH $::vd100::ila_depth CONFIG.C_INPUT_PIPE_STAGES {2}]
    # Capture all five AXI channels at each observation point. Widths are
    # and protocol are propagated from the attached interfaces, including the 12/16-bit Lite
    # addresses on the RTL boundary. No extra functional AXI endpoint is added.
    set slots {
        smartconnect_0/S00_AXI AXI4
        smartconnect_0/M01_AXI AXI4LITE
        smartconnect_0/M02_AXI AXI4LITE
        axi_gpio_0/S_AXI AXI4LITE
        smartconnect_0/S03_AXI AXI4
        smartconnect_0/S01_AXI AXI4
        smartconnect_0/S02_AXI AXI4
    }
    set index 0
    foreach {pin protocol} $slots {
        foreach channel {AW W B AR R} {
            lappend props CONFIG.C_SLOT_${index}_AXI_${channel}_SEL_DATA 1
            lappend props CONFIG.C_SLOT_${index}_AXI_${channel}_SEL_TRIG 1
        }
        incr index
    }
    set probes {
        pll_pl_scr1/locked 1 pin
        versal_cips_0/pl0_resetn 1 pin
        proc_sys_reset_0/interconnect_aresetn 1 pin
        proc_sys_reset_0/peripheral_aresetn 1 pin
        axi_gpio_0/gpio_io_o 3 pin
        debug_scr1_resetn_i 1 port
        debug_lifecycle_i 4 port
        debug_axi_fault_i 4 port
        debug_outstanding_i 12 port
    }
    set index 0
    foreach {signal width kind} $probes {
        lappend props CONFIG.C_PROBE${index}_WIDTH $width
        incr index
    }
    set_property -dict $props $ila
    set index 0
    foreach {pin protocol} $slots {
        connect_bd_intf_net [get_bd_intf_pins $pin] \
            [get_bd_intf_pins $ila/SLOT_${index}_AXI]
        incr index
    }
    set index 0
    foreach {signal width kind} $probes {
        if {$kind eq "port"} {set source [get_bd_ports $signal]} \
        else {set source [get_bd_pins $signal]}
        connect_bd_net $source [get_bd_pins $ila/probe${index}]
        incr index
    }
    connect_bd_net [get_bd_pins pll_pl_scr1/clk_out1] [get_bd_pins $ila/clk]
    # Keep ILA alive when the functional AXI/peripheral reset is asserted.
    # Sampling still requires a running PLL output; a stopped clock cannot be
    # diagnosed by an ILA clocked from that same output.
    set const1 [vd100_create_ip debug_const_one xilinx.com:ip:xlconstant:1.1]
    set_property -dict [list CONFIG.CONST_WIDTH {1} CONFIG.CONST_VAL {1}] $const1
    connect_bd_net [get_bd_pins $const1/dout] [get_bd_pins $ila/resetn]
}
