# =============================================================================
# AXI NoC + DDR4 memory controller for ALINX VD100.
# DDR: 64-bit board interface, DDR4-3200, 200 MHz differential reference.
#
# NoC slave-interface allocation follows the ALINX VD100 ps_hello reference:
#   S00_AXI : CIPS FPD_CCI_NOC_0 -> MC_3 (ps_cci)
#   S01_AXI : CIPS FPD_CCI_NOC_1 -> MC_2 (ps_cci)
#   S02_AXI : CIPS FPD_CCI_NOC_2 -> MC_0 (ps_cci)
#   S03_AXI : CIPS FPD_CCI_NOC_3 -> MC_1 (ps_cci)
#   S04_AXI : PL/SCR1 SmartConnect -> MC_0 (pl)
# =============================================================================

proc vd100_create_noc {} {
    set noc [vd100_create_ip axi_noc_0 xilinx.com:ip:axi_noc:1.0]

    set_property -dict [list \
        CONFIG.CONTROLLERTYPE {DDR4_SDRAM} \
        CONFIG.MC_CHAN_REGION1 {NONE} \
        CONFIG.MC_COMPONENT_WIDTH {x16} \
        CONFIG.MC_INPUTCLK0_PERIOD {5000} \
        CONFIG.MC_MEMORY_SPEEDGRADE {DDR4-3200AA(22-22-22)} \
        CONFIG.MC_SYSTEM_CLOCK {No_Buffer} \
        CONFIG.NUM_CLKS {5} \
        CONFIG.NUM_MC {1} \
        CONFIG.NUM_MCP {4} \
        CONFIG.NUM_MI {0} \
        CONFIG.NUM_SI {5} \
    ] $noc

    set_property -dict [list \
        CONFIG.REGION {0} \
        CONFIG.CONNECTIONS {MC_3 {read_bw {100} write_bw {100} read_avg_burst {4} write_avg_burst {4}}} \
        CONFIG.NOC_PARAMS {} \
        CONFIG.CATEGORY {ps_cci}] [get_bd_intf_pins $noc/S00_AXI]

    set_property -dict [list \
        CONFIG.REGION {0} \
        CONFIG.CONNECTIONS {MC_2 {read_bw {100} write_bw {100} read_avg_burst {4} write_avg_burst {4}}} \
        CONFIG.NOC_PARAMS {} \
        CONFIG.CATEGORY {ps_cci}] [get_bd_intf_pins $noc/S01_AXI]

    set_property -dict [list \
        CONFIG.REGION {0} \
        CONFIG.CONNECTIONS {MC_0 {read_bw {100} write_bw {100} read_avg_burst {4} write_avg_burst {4}}} \
        CONFIG.NOC_PARAMS {} \
        CONFIG.CATEGORY {ps_cci}] [get_bd_intf_pins $noc/S02_AXI]

    set_property -dict [list \
        CONFIG.REGION {0} \
        CONFIG.CONNECTIONS {MC_1 {read_bw {100} write_bw {100} read_avg_burst {4} write_avg_burst {4}}} \
        CONFIG.NOC_PARAMS {} \
        CONFIG.CATEGORY {ps_cci}] [get_bd_intf_pins $noc/S03_AXI]

    set_property -dict [list \
        CONFIG.REGION {0} \
        CONFIG.CONNECTIONS {MC_0 {read_bw {500} write_bw {500} read_avg_burst {4} write_avg_burst {4}}} \
        CONFIG.NOC_PARAMS {} \
        CONFIG.CATEGORY {pl}] [get_bd_intf_pins $noc/S04_AXI]

    set_property CONFIG.ASSOCIATED_BUSIF {S00_AXI} [get_bd_pins $noc/aclk0]
    set_property CONFIG.ASSOCIATED_BUSIF {S01_AXI} [get_bd_pins $noc/aclk1]
    set_property CONFIG.ASSOCIATED_BUSIF {S02_AXI} [get_bd_pins $noc/aclk2]
    set_property CONFIG.ASSOCIATED_BUSIF {S03_AXI} [get_bd_pins $noc/aclk3]
    set_property CONFIG.ASSOCIATED_BUSIF {S04_AXI} [get_bd_pins $noc/aclk4]

    return $noc
}
