# =============================================================================
# Versal CIPS configuration for the minimal VD100 + SCR1 platform.
# The CCI setup follows the ALINX VD100 Vivado 2023.2 ps_hello reference:
# enabling the FPD CCI NoC path exposes the four interleaved CCI interfaces.
# =============================================================================

proc vd100_create_cips {} {
    set cips [vd100_create_ip versal_cips_0 xilinx.com:ip:versal_cips:3.4]

    set_property -dict [list \
        CONFIG.CLOCK_MODE {Custom} \
        CONFIG.DDR_MEMORY_MODE {Enable} \
        CONFIG.DESIGN_MODE {1} \
        CONFIG.PS_PL_CONNECTIVITY_MODE {Custom} \
        CONFIG.PS_PMC_CONFIG { \
            CLOCK_MODE {Custom} \
            DDR_MEMORY_MODE {Connectivity to DDR via NOC} \
            DESIGN_MODE {1} \
            PMC_CRP_PL0_REF_CTRL_FREQMHZ {100} \
            PS_M_AXI_FPD_DATA_WIDTH {32} \
            PS_NUM_FABRIC_RESETS {1} \
            PS_PL_CONNECTIVITY_MODE {Custom} \
            PS_USE_M_AXI_FPD {1} \
            PS_USE_PMCPL_CLK0 {1} \
            PS_USE_FPD_CCI_NOC {1} \
            PS_USE_FPD_CCI_NOC0 {1} \
            PS_IRQ_USAGE {{CH0 1} {CH1 0} {CH2 0} {CH3 0} {CH4 0} {CH5 0} {CH6 0} {CH7 0} {CH8 0} {CH9 0} {CH10 0} {CH11 0} {CH12 0} {CH13 0} {CH14 0} {CH15 0}} \
            SMON_ALARMS {Set_Alarms_On} \
            SMON_ENABLE_TEMP_AVERAGING {0} \
            SMON_TEMP_AVERAGING_SAMPLES {0} \
        } \
    ] $cips

    return $cips
}
