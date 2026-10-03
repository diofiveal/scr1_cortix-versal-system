# =============================================================================
# Address map for the first VD100 + SCR1 integration.
#
# A72-visible PL aperture:
#   0xA400_0000 .. 0xA400_0FFF : scr1_control
#   0xA401_0000 .. 0xA401_FFFF : Boot BRAM AXI-Lite adapter
#   0xA402_0000 .. 0xA402_0FFF : platform_ready GPIO
#
# SCR1 top translates its local MMIO aliases before entering the BD:
#   0xFF00_0000 -> 0xA400_0000
#   0xFFFF_0000 -> 0xA401_0000
# Native PS/PMC/LPD DDR stays 0x0000_0000 .. 0x7FFF_FFFF.
# SCR1 IMEM/DMEM can access only 0x7F00_0000 .. 0x7FFF_FFFF (16 MiB).
# DPC/XSDB LPD aliases: control 0x8000_0000, boot 0x8001_0000,
# GPIO 0x8002_0000. The debug master has no SmartConnect -> DDR route.
# =============================================================================

proc vd100_assign_addresses {} {
    variable ::vd100::ctrl_base
    variable ::vd100::ctrl_range
    variable ::vd100::boot_base
    variable ::vd100::boot_range
    variable ::vd100::ready_gpio_base
    variable ::vd100::ready_gpio_range
    variable ::vd100::linux_ddr_base
    variable ::vd100::linux_ddr_range
    variable ::vd100::scr1_ddr_base
    variable ::vd100::scr1_ddr_range
    variable ::vd100::debug_ctrl_base
    variable ::vd100::debug_boot_base
    variable ::vd100::debug_gpio_base

    # These are the address-space names emitted by Vivado 2023.2 for the CIPS
    # interfaces used in the VD100 reference design.
    set ps_space   "versal_cips_0/M_AXI_FPD"
    set debug_space "versal_cips_0/M_AXI_LPD"
    set imem_space "S_AXI_IMEM"
    set dmem_space "S_AXI_DMEM"

    set ctrl_seg [vd100_find_external_segment M_AXIL_CTRL]
    set boot_seg [vd100_find_external_segment M_AXIL_BOOT]
    set gpio_seg [vd100_require_one \
        [get_bd_addr_segs -quiet axi_gpio_0/S_AXI/Reg] \
        "AXI GPIO register segment"]

    # PL/SCR1 DDR route is S04_AXI -> MC_0 -> C0_DDR_LOW0.
    set noc_pl_ddr [vd100_find_noc_ddr_segment axi_noc_0 S04_AXI]

    # Four CCI routes.  Their DDR segments are respectively C3/C2/C0/C1.
    set cci_spaces [list \
        "versal_cips_0/FPD_CCI_NOC_0" \
        "versal_cips_0/FPD_CCI_NOC_1" \
        "versal_cips_0/FPD_CCI_NOC_2" \
        "versal_cips_0/FPD_CCI_NOC_3"]

    set cci_ddr_segments [list \
        [vd100_find_noc_ddr_segment axi_noc_0 S00_AXI] \
        [vd100_find_noc_ddr_segment axi_noc_0 S01_AXI] \
        [vd100_find_noc_ddr_segment axi_noc_0 S02_AXI] \
        [vd100_find_noc_ddr_segment axi_noc_0 S03_AXI]]

    # A72 reaches control, Boot BRAM and readiness flags through M_AXI_FPD.
    vd100_map_segment $ps_space $ctrl_seg $ctrl_base $ctrl_range
    vd100_map_segment $ps_space $boot_seg $boot_base $boot_range
    vd100_map_segment $ps_space $gpio_seg $ready_gpio_base $ready_gpio_range

    # A72 reaches DDR through the native four-way interleaved CCI path.
    foreach cci_space $cci_spaces cci_ddr $cci_ddr_segments {
        vd100_map_segment $cci_space $cci_ddr $linux_ddr_base $linux_ddr_range
    }
    vd100_map_segment "versal_cips_0/PMC_NOC_AXI_0" \
        [vd100_find_noc_ddr_segment axi_noc_0 S05_AXI] $linux_ddr_base $linux_ddr_range
    vd100_map_segment "versal_cips_0/LPD_AXI_NOC_0" \
        [vd100_find_noc_ddr_segment axi_noc_0 S06_AXI] $linux_ddr_base $linux_ddr_range

    # Do not create a second A72->DDR route through M_AXI_FPD/SmartConnect.
    vd100_exclude_segment $ps_space $noc_pl_ddr

    # Native DPC access via the LPD aperture, separate from A72 FPD addresses.
    vd100_map_segment $debug_space $ctrl_seg $debug_ctrl_base $ctrl_range
    vd100_map_segment $debug_space $boot_seg $debug_boot_base $boot_range
    vd100_map_segment $debug_space $gpio_seg $debug_gpio_base $ready_gpio_range
    vd100_exclude_segment $debug_space $noc_pl_ddr

    # Both SCR1 buses see only the shared 16-MiB DDR and Boot BRAM.
    # SmartConnect per-SI decoding rejects ordinary Linux DDR addresses.
    # This is address filtering, not an AXI timeout or cache-coherency mechanism.
    foreach space [list $imem_space $dmem_space] {
        vd100_map_segment $space $noc_pl_ddr $scr1_ddr_base $scr1_ddr_range
        vd100_map_segment $space $boot_seg $boot_base $boot_range

        # Readiness GPIO is host-only.
        vd100_exclude_segment $space $gpio_seg
    }
    # Instruction fetch must not reach control MMIO.
    vd100_exclude_segment $imem_space $ctrl_seg
    vd100_map_segment $dmem_space $ctrl_seg $ctrl_base $ctrl_range
}

