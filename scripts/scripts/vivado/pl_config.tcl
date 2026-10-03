# =============================================================================
# PL-side Block Design construction for the minimal VD100 + SCR1 platform.
# =============================================================================

proc vd100_create_external_ports {pl_freq_hz} {
    # Board DDR4 interface.
    create_bd_intf_port -mode Master -vlnv xilinx.com:interface:ddr4_rtl:1.0 DDR4

    # Board differential 200 MHz reference clock.
    set sys_clk [create_bd_intf_port -mode Slave \
        -vlnv xilinx.com:interface:diff_clock_rtl:1.0 sys_clk]
    set_property CONFIG.FREQ_HZ 200000000 $sys_clk

    # AXI interfaces crossing the BD/RTL boundary.  Set FREQ_HZ now, before
    # Vivado propagates the interfaces and turns this property read-only.
    vd100_axi_port S_AXI_IMEM  Slave  AXI4     32 32 4 4 $pl_freq_hz
    vd100_axi_port S_AXI_DMEM  Slave  AXI4     32 32 4 4 $pl_freq_hz
    vd100_axi_port M_AXIL_CTRL Master AXI4LITE 12 32 0 0 $pl_freq_hz
    vd100_axi_port M_AXIL_BOOT Master AXI4LITE 16 32 0 0 $pl_freq_hz

    # PL clock/reset exported to the RTL top.
    set pl_clk_o [create_bd_port -dir O -type clk -freq_hz $pl_freq_hz pl_clk_o]
    set_property -dict [list \
        CONFIG.ASSOCIATED_BUSIF {S_AXI_IMEM:S_AXI_DMEM:M_AXIL_CTRL:M_AXIL_BOOT} \
        CONFIG.ASSOCIATED_RESET {pl_rst_no}] $pl_clk_o

    set pl_rst_no [create_bd_port -dir O -type rst pl_rst_no]
    set_property CONFIG.POLARITY ACTIVE_LOW $pl_rst_no

    # A72-written readiness bits:
    #   bit0 NoC ready, bit1 DDR ready, bit2 verifier ready.
    create_bd_port -dir O -from 2 -to 0 platform_ready_o

    # SCR1 control interrupt into A72 via PL->PS IRQ channel 0.
    create_bd_port -dir I scr1_irq_i
}

proc vd100_create_scr1_pll {cips_pl_clk} {
    set input_hz [get_property CONFIG.FREQ_HZ $cips_pl_clk]
    if {![string is double -strict $input_hz] || $input_hz <= 0} {
        error "CIPS pl0_ref_clk has invalid CONFIG.FREQ_HZ: '$input_hz'"
    }
    # Versal uses clk_wizard:1.0 and vector-valued output parameters, not
    # the 7-series clk_wiz:6.0/CLKOUT1_REQUESTED_OUT_FREQ parameter set.
    set pll [vd100_create_ip pll_pl_scr1 xilinx.com:ip:clk_wizard:1.0]
    set requested [format %.6f $::vd100::scr1_freq_mhz]
    set_property -dict [list \
        CONFIG.PRIM_IN_FREQ [format %.6f [expr {$input_hz / 1000000.0}]] \
        CONFIG.PRIM_SOURCE {No_buffer} \
        CONFIG.CLKOUT_USED {true,false,false,false,false,false,false} \
        CONFIG.CLKOUT_PORT {clk_out1,clk_out2,clk_out3,clk_out4,clk_out5,clk_out6,clk_out7} \
        CONFIG.CLKOUT_REQUESTED_OUT_FREQUENCY "$requested,100.000,100.000,100.000,100.000,100.000,100.000,100.000" \
        CONFIG.CLKOUT_REQUESTED_PHASE {0.000,0.000,0.000,0.000,0.000,0.000,0.000} \
        CONFIG.CLKOUT_REQUESTED_DUTY_CYCLE {50.000,50.000,50.000,50.000,50.000,50.000,50.000} \
        CONFIG.CLKOUT_DRIVES {BUFG,BUFG,BUFG,BUFG,BUFG,BUFG,BUFG} \
        CONFIG.USE_LOCKED {true} \
        CONFIG.USE_RESET {false}] $pll
    connect_bd_net $cips_pl_clk [get_bd_pins $pll/clk_in1]
    return $pll
}

proc vd100_create_pl {} {
    # Configure CIPS and PLL before creating external interfaces. Read the
    # PLL output's exact Hz; do not copy input FREQ_HZ to SCR1 interfaces.
    set cips [vd100_create_cips]
    set cips_pl_clk [vd100_require_one \
        [get_bd_pins -quiet $cips/pl0_ref_clk] \
        "CIPS pl0_ref_clk pin"]
    set pll [vd100_create_scr1_pll $cips_pl_clk]
    set pl_freq_hz [get_property CONFIG.FREQ_HZ [get_bd_pins $pll/clk_out1]]
    if {![string is double -strict $pl_freq_hz] || $pl_freq_hz <= 0 ||
        abs($pl_freq_hz - $::vd100::scr1_freq_mhz * 1000000.0) > 100000.0} {
        error "PLL output metadata '$pl_freq_hz' does not match requested $::vd100::scr1_freq_mhz MHz"
    }
    puts "INFO: pll_pl_scr1 output metadata = ${pl_freq_hz} Hz"

    vd100_create_external_ports $pl_freq_hz
    set noc [vd100_create_noc]

    # Four initiators (A72 FPD, SCR1 IMEM/DMEM, DPC via LPD) and four targets
    # (DDR NoC, control, Boot BRAM adapter, readiness GPIO).
    set sc [vd100_create_ip smartconnect_0 xilinx.com:ip:smartconnect:1.0]
    set_property -dict [list CONFIG.NUM_SI {4} CONFIG.NUM_MI {4}] $sc

    set gpio [vd100_create_ip axi_gpio_0 xilinx.com:ip:axi_gpio:2.0]
    set_property -dict [list \
        CONFIG.C_GPIO_WIDTH {3} \
        CONFIG.C_ALL_OUTPUTS {1} \
        CONFIG.C_IS_DUAL {0} \
        CONFIG.C_DOUT_DEFAULT {0x00000000}] $gpio

    set rst [vd100_create_ip proc_sys_reset_0 xilinx.com:ip:proc_sys_reset:5.0]

    # With MC_SYSTEM_CLOCK=No_Buffer, AXI NoC sys_clk0 is a scalar clock pin.
    # The VD100 reference design places util_ds_buf in front of it.
    set dsbuf [vd100_create_ip util_ds_buf_0 xilinx.com:ip:util_ds_buf:2.2]

    set const0 [vd100_create_ip const_zero xilinx.com:ip:xlconstant:1.1]
    set_property -dict [list CONFIG.CONST_WIDTH {1} CONFIG.CONST_VAL {0}] $const0

    # -------------------------------------------------------------------------
    # AXI connectivity.
    # -------------------------------------------------------------------------
    connect_bd_intf_net [get_bd_intf_pins $cips/M_AXI_FPD] \
                        [get_bd_intf_pins $sc/S00_AXI]
    connect_bd_intf_net [get_bd_intf_ports S_AXI_IMEM] \
                        [get_bd_intf_pins $sc/S01_AXI]
    connect_bd_intf_net [get_bd_intf_ports S_AXI_DMEM] \
                        [get_bd_intf_pins $sc/S02_AXI]

    # Versal has no jtag_axi IP. Native DPC transactions use the LPD aperture.
    connect_bd_intf_net [get_bd_intf_pins $cips/M_AXI_LPD] \
                        [get_bd_intf_pins $sc/S03_AXI]

    # PL/SCR1 path occupies S04_AXI.  S00..S03 are the four interleaved CCIs.
    connect_bd_intf_net [get_bd_intf_pins $sc/M00_AXI] \
                        [get_bd_intf_pins $noc/S04_AXI]
    connect_bd_intf_net [get_bd_intf_pins $sc/M01_AXI] \
                        [get_bd_intf_ports M_AXIL_CTRL]
    connect_bd_intf_net [get_bd_intf_pins $sc/M02_AXI] \
                        [get_bd_intf_ports M_AXIL_BOOT]
    connect_bd_intf_net [get_bd_intf_pins $sc/M03_AXI] \
                        [get_bd_intf_pins $gpio/S_AXI]

    connect_bd_intf_net [get_bd_intf_pins $cips/FPD_CCI_NOC_0] \
                        [get_bd_intf_pins $noc/S00_AXI]
    connect_bd_intf_net [get_bd_intf_pins $cips/FPD_CCI_NOC_1] \
                        [get_bd_intf_pins $noc/S01_AXI]
    connect_bd_intf_net [get_bd_intf_pins $cips/FPD_CCI_NOC_2] \
                        [get_bd_intf_pins $noc/S02_AXI]
    connect_bd_intf_net [get_bd_intf_pins $cips/FPD_CCI_NOC_3] \
                        [get_bd_intf_pins $noc/S03_AXI]

    # Keep the native Linux peripheral-DMA and firmware DDR paths. S04 stays
    # the SCR1/SmartConnect route, preserving the existing address map.
    connect_bd_intf_net [get_bd_intf_pins $cips/PMC_NOC_AXI_0] \
                        [get_bd_intf_pins $noc/S05_AXI]
    connect_bd_intf_net [get_bd_intf_pins $cips/LPD_AXI_NOC_0] \
                        [get_bd_intf_pins $noc/S06_AXI]

    connect_bd_intf_net [get_bd_intf_ports DDR4] \
                        [get_bd_intf_pins $noc/CH0_DDR4_0]

    # Differential board clock -> IBUFDS -> scalar NoC sys_clk0.
    connect_bd_intf_net [get_bd_intf_ports sys_clk] \
                        [get_bd_intf_pins $dsbuf/CLK_IN_D]
    connect_bd_net [get_bd_pins $dsbuf/IBUF_OUT] \
                   [get_bd_pins $noc/sys_clk0]

    # -------------------------------------------------------------------------
    # Clocks.
    # -------------------------------------------------------------------------
    connect_bd_net [get_bd_pins $pll/clk_out1] \
        [get_bd_pins $cips/m_axi_fpd_aclk] \
        [get_bd_pins $cips/m_axi_lpd_aclk] \
        [get_bd_pins $sc/aclk] \
        [get_bd_pins $noc/aclk4] \
        [get_bd_pins $gpio/s_axi_aclk] \
        [get_bd_pins $rst/slowest_sync_clk] \
        [get_bd_ports pl_clk_o]

    connect_bd_net [get_bd_pins $cips/fpd_cci_noc_axi0_clk] \
                   [get_bd_pins $noc/aclk0]
    connect_bd_net [get_bd_pins $cips/fpd_cci_noc_axi1_clk] \
                   [get_bd_pins $noc/aclk1]
    connect_bd_net [get_bd_pins $cips/fpd_cci_noc_axi2_clk] \
                   [get_bd_pins $noc/aclk2]
    connect_bd_net [get_bd_pins $cips/fpd_cci_noc_axi3_clk] \
                   [get_bd_pins $noc/aclk3]
    connect_bd_net [get_bd_pins $cips/pmc_axi_noc_axi0_clk] \
                   [get_bd_pins $noc/aclk5]
    connect_bd_net [get_bd_pins $cips/lpd_axi_noc_clk] \
                   [get_bd_pins $noc/aclk6]

    # -------------------------------------------------------------------------
    # Reset distribution.
    # Do not write CONFIG.C_EXT_RESET_HIGH: Vivado 2023.2 marks it read-only.
    # The ALINX generated design connects CIPS pl0_resetn directly here.
    # -------------------------------------------------------------------------
    connect_bd_net [get_bd_pins $cips/pl0_resetn] \
                   [get_bd_pins $rst/ext_reset_in]
    connect_bd_net [get_bd_pins $const0/dout] \
                   [get_bd_pins $rst/mb_debug_sys_rst] \
                   [get_bd_pins $rst/aux_reset_in]
    connect_bd_net [get_bd_pins $pll/locked] \
                   [get_bd_pins $rst/dcm_locked]

    connect_bd_net [get_bd_pins $rst/interconnect_aresetn] \
                   [get_bd_pins $sc/aresetn]
    connect_bd_net [get_bd_pins $rst/peripheral_aresetn] \
                   [get_bd_pins $gpio/s_axi_aresetn] \
                   [get_bd_ports pl_rst_no]

    # -------------------------------------------------------------------------
    # Status and interrupt.
    # -------------------------------------------------------------------------
    connect_bd_net [get_bd_pins $gpio/gpio_io_o] \
                   [get_bd_ports platform_ready_o]
    connect_bd_net [get_bd_ports scr1_irq_i] \
                   [get_bd_pins $cips/pl_ps_irq0]
}

