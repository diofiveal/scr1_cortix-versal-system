# =============================================================================
# VD100 + SCR1 project-wide Vivado settings
# Target tool: Vivado 2023.2
# =============================================================================

namespace eval vd100 {
    # scripts/scripts/vivado -> project root
    variable root [file normalize [file join [file dirname [info script]] ../../..]]

    variable project_name "vd100_scr1"
    variable bd_name      "vd100_platform"
    variable top_name     "vd100_scr1_top"
    variable part         "xcve2302-sfva784-1LP-e-S"
    variable vivado_version "2023.2"
    variable jobs 4
    # Preserve the 90 MHz PLL configuration used to close SCR1 timing.
    # CIPS keeps its nominal 100 MHz source; actual Hz come from BD metadata.
    variable scr1_freq_mhz 90.0

    # Generated output is separate from the versioned sources.
    # A new directory keeps the previously successful non-Linux build intact.
    variable build_root  [file join $root build vivado-linux]
    variable project_dir [file join $build_root $project_name]

    # Project source tree.
    variable rtl_root         [file join $root rtl]
    variable constraints_root [file join $root constraints]
    variable external_root    [file join $root external]
    variable scr1_root        [file join $external_root scr1]
    variable scr1_src         [file join $scr1_root src]
    variable scr1_include_dir [file join $scr1_src includes]

    # Platform-specific SCR1 address configuration. scr1_arch_description.svh
    # includes this exact basename when SCR1_ARCH_CUSTOM is defined.
    variable scr1_arch_custom_dir  [file join $rtl_root config]
    variable scr1_arch_custom_file [file join $scr1_arch_custom_dir scr1_arch_custom.svh]

    # A72-visible PL aperture through CIPS M_AXI_FPD.
    # Versal M_AXI_FPD low apertures start at 0xA400_0000; 0xA000_0000 is
    # outside this master aperture and is rejected by Vivado Address Editor.
    variable ctrl_base        0xA4000000
    variable ctrl_range       0x00001000
    variable boot_base        0xA4010000
    variable boot_range       0x00010000
    variable ready_gpio_base  0xA4020000
    variable ready_gpio_range 0x00001000

    # SCR1-visible DDR window used in the first implementation.
    variable ddr_base         0x00000000
    variable ddr_range        0x80000000

    # create_project.tcl starts synthesis by default, matching the requested
    # one-command bring-up flow. Set this to 0 while debugging BD creation.
    variable run_synthesis 1
}
