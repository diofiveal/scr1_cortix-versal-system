# ALINX VD100 course_s2 PS/PMC board configuration plus the SCR1 PL overlay.
# Keep SD1, eMMC/SD0, UART0, GEM0, USB and PMC I2C on the reference MIO pins.
# Default CIPS MIO settings are not a VD100 Linux BSP.

proc vd100_create_cips {} {
    set cips [vd100_create_ip versal_cips_0 xilinx.com:ip:versal_cips:3.4]

    source [file join $::vd100::external_root alinx_vd100 course_s2_ps_config.tcl]
    set_ps_config $cips
    set cfg [get_property CONFIG.PS_PMC_CONFIG $cips]
    # Discard only derived PL0 fields from the 240 MHz reference. CIPS must
    # recompute these when our requested source frequency becomes 100 MHz.
    dict unset cfg PMC_CRP_PL0_REF_CTRL_ACT_FREQMHZ
    dict unset cfg PMC_CRP_PL0_REF_CTRL_DIVISOR0
    # Disable the reference's camera/LCD/GEM1 EMIO controls: this top has none.
    # Retain GEM0 on MIO and both native PS/PMC DDR routes.
    foreach {key value} {
        DEBUG_MODE JTAG
        PMC_CRP_PL0_REF_CTRL_FREQMHZ 100
        PMC_USE_PMC_NOC_AXI0 1
        PS_M_AXI_FPD_DATA_WIDTH 32
        PS_M_AXI_LPD_DATA_WIDTH 32
        PS_NUM_FABRIC_RESETS 1
        PS_USE_M_AXI_FPD 1
        PS_USE_M_AXI_LPD 1
        PS_USE_PMCPL_CLK0 1
        PS_USE_FPD_CCI_NOC 1
        PS_USE_FPD_CCI_NOC0 1
        PS_USE_NOC_LPD_AXI0 1
        PS_GPIO_EMIO_PERIPHERAL_ENABLE 0
        PS_ENET1_PERIPHERAL {{ENABLE 0} {IO EMIO}}
        PS_ENET1_MDIO {{ENABLE 0} {IO EMIO}}
        PS_I2C0_PERIPHERAL {{ENABLE 0} {IO EMIO}}
        PS_I2C1_PERIPHERAL {{ENABLE 0} {IO EMIO}}
        PS_IRQ_USAGE {{CH0 1} {CH1 0} {CH2 0} {CH3 0} {CH4 0} {CH5 0} {CH6 0} {CH7 0} {CH8 0} {CH9 0} {CH10 0} {CH11 0} {CH12 0} {CH13 0} {CH14 0} {CH15 0}}
    } {
        dict set cfg $key $value
    }
    # ACT_FREQ/DIVISOR are computed by CIPS, not manually overridden.
    set_property -dict [list CONFIG.DEBUG_MODE {JTAG} CONFIG.CLOCK_MODE {Custom} \
        CONFIG.PS_PMC_CONFIG $cfg] $cips
    return $cips
}
