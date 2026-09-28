# =============================================================================
# Add SCR1, project RTL and XDC files to Vivado.
# SCR1 itself is loaded only through core.files + axi_top.files; do not glob
# every .sv under the upstream repository because the fork contains alternate
# and experimental source copies.
# =============================================================================

proc vd100_add_sources {} {
    variable ::vd100::rtl_root
    variable ::vd100::constraints_root
    variable ::vd100::scr1_src
    variable ::vd100::scr1_include_dir
    variable ::vd100::scr1_arch_custom_dir
    variable ::vd100::scr1_arch_custom_file

    vd100_require_dir $rtl_root
    vd100_require_dir $constraints_root
    vd100_require_dir $scr1_src
    vd100_require_dir $scr1_include_dir

    set srcset [get_filesets sources_1]
    set simset [get_filesets sim_1]
    set conset [get_filesets constrs_1]

    # -------------------------------------------------------------------------
    # Project RTL. The ordering is deliberate: packages first, then control,
    # boot protection, subsystem and finally the board top.
    # -------------------------------------------------------------------------
    set project_rtl [list \
        [file join $rtl_root control vd100_scr1_pkg.sv] \
        [file join $rtl_root control scr1_regs_pkg.sv] \
        [file join $rtl_root control scr1_control_axil.sv] \
        [file join $rtl_root control scr1_lifecycle_fsm.sv] \
        [file join $rtl_root control scr1_fault_irq_aggregator.sv] \
        [file join $rtl_root control scr1_control_top.sv] \
        [file join $rtl_root control scr1_axi_monitor.sv] \
        [file join $rtl_root boot boot_bram_write_guard.sv] \
        [file join $rtl_root boot scr1_boot_bram_axil.sv] \
        [file join $rtl_root scr1_subsystem.sv] \
        [file join $rtl_root vd100_scr1_top.sv]]

    foreach f $project_rtl {
        add_files -norecurse -fileset $srcset [vd100_require_file $f]
    }

    # -------------------------------------------------------------------------
    # Platform-specific SCR1 address map.
    # Do not silently compile the upstream default 0x0000_0200 reset vector:
    # the VD100 design boots SCR1 at 0xFFFF_0000.
    # -------------------------------------------------------------------------
    vd100_require_file $scr1_arch_custom_file
    add_files -norecurse -fileset $srcset $scr1_arch_custom_file
    set_property file_type {Verilog Header} [get_files $scr1_arch_custom_file]

    # -------------------------------------------------------------------------
    # SCR1 source manifests from the selected fork.
    # -------------------------------------------------------------------------
    set core_manifest [file join $scr1_src core.files]
    set axi_manifest  [file join $scr1_src axi_top.files]
    vd100_add_manifest $core_manifest $scr1_src $srcset
    vd100_add_manifest $axi_manifest  $scr1_src $srcset

    # TODO-16 integration requires the modified copies to have replaced these
    # files inside external/scr1/src/top/.
    set scr1_top [file join $scr1_src top scr1_top_axi.sv]
    set dcache   [file join $scr1_src top scr1_dcache_top.sv]
    set wb       [file join $scr1_src top scr1_write_buffer.sv]
    vd100_require_text $scr1_top "master_enable_i" \
        "TODO-16 SCR1 top integration is missing"
    vd100_require_text $scr1_top "memory_idle_o" \
        "TODO-16 SCR1 memory drain status is missing"
    vd100_require_text $dcache "drain_idle_o" \
        "TODO-16 D-cache drain status is missing"
    vd100_require_text $wb "drain_idle_o" \
        "TODO-16 write-buffer drain status is missing"

    # SCR1 include paths. rtl/config is needed because scr1_arch_description.svh
    # includes scr1_arch_custom.svh by basename.
    set project_include_dirs [list \
        $scr1_include_dir \
        $scr1_arch_custom_dir \
        [file join $rtl_root control] \
        [file join $rtl_root boot]]

    # Apply the same include/define environment to synthesis and simulation.
    # scr1_arch_custom.svh itself selects SCR1_CFG_RV32IMC_MAX, so defining it
    # globally here as well would only create a duplicate macro definition.
    foreach fs [list $srcset $simset] {
        set_property include_dirs $project_include_dirs $fs
        set_property verilog_define [list SCR1_ARCH_CUSTOM] $fs
    }

    # -------------------------------------------------------------------------
    # Constraints.
    # -------------------------------------------------------------------------
    foreach xdc [list \
        vd100_ddr4.xdc \
        vd100_clocks.xdc \
        vd100_timing.xdc \
        vd100_io.xdc] {
        set path [file join $constraints_root $xdc]
        add_files -norecurse -fileset $conset [vd100_require_file $path]
    }

    # Do not call update_compile_order here. vd100_scr1_top instantiates the
    # generated vd100_platform_wrapper, which does not exist until build_bd.tcl
    # and make_wrapper have completed. create_project.tcl updates compile order
    # after the wrapper is generated and added to sources_1.
}
