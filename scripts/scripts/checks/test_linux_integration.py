#!/usr/bin/env python3
"""Offline Tcl/Python regression; not a Vivado IP or board-boot validation.

Uses Python's Tcl interpreter to EXECUTE the production BD procedures against
an explicitly mocked API, then checks clocks, reset, PS overlay and NoC map.
"""
import importlib.util
import hashlib
import json
import re
import shutil
import subprocess
from pathlib import Path
import tempfile
import tkinter
import unittest
import zipfile

try:
    import pyslang
except ImportError:
    pyslang = None  # Optional real SV elaboration: pip install pyslang==12.0.0

ROOT = Path(__file__).resolve().parents[3]


def load(name, path):
    spec = importlib.util.spec_from_file_location(name, ROOT / path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


PREPARE = load("prepare", "scripts/scripts/linux/prepare_petalinux.py")
HANDOFF = load("handoff", "scripts/scripts/linux/handoff.py")


def mock_bd():
    tcl = tkinter.Tcl()
    tcl.eval(r'''
        set properties [dict create]
        set nets {}
        set interface_nets {}
        set mapped {}
        set excluded {}
        set cells {}
        proc get_ipdefs {args} {return [lindex $args end]}
        proc create_bd_cell {args} {
            set name [lindex $args end]
            lappend ::cells $name
            return $name
        }
        proc get_bd_cells {args} {return [lindex $args end]}
        proc get_bd_pins {args} {return [lindex $args end]}
        proc get_bd_intf_pins {args} {return [lindex $args end]}
        proc get_bd_ports {args} {return [lindex $args end]}
        proc get_bd_intf_ports {args} {return [lindex $args end]}
        proc create_bd_port {args} {return [lindex $args end]}
        proc create_bd_intf_port {args} {return [lindex $args end]}
        proc set_property {args} {
            set obj [lindex $args end]
            if {[lindex $args 0] eq "-dict"} {set props [lindex $args 1]} else {set props [lrange $args 0 1]}
            foreach {key value} $props {dict set ::properties $obj $key $value}
        }
        proc get_property {key obj} {
            # Deliberately DIFFERENT source/output metadata, as in Vivado 2023.2.
            if {$obj eq "versal_cips_0/pl0_ref_clk"} {return 99999001}
            if {$obj eq "pll_pl_scr1/clk_out1"} {return 90000038}
            return [dict get $::properties $obj $key]
        }
        proc connect_bd_net {args} {lappend ::nets $args}
        proc connect_bd_intf_net {args} {lappend ::interface_nets $args}
    ''')
    for name in ("project_info", "helpers", "ps_config", "noc_config", "pl_config", "address_map", "debug_config"):
        tcl.call("source", str(ROOT / f"scripts/scripts/vivado/{name}.tcl"))
    tcl.eval(r'''
        proc vd100_find_external_segment {name} {return $name/Reg}
        proc vd100_find_noc_ddr_segment {noc si} {return $noc/$si/DDR}
        proc get_bd_addr_segs {args} {return [lindex $args end]}
        proc vd100_map_segment {space segment offset range} {lappend ::mapped [list $space $segment $offset $range]}
        proc vd100_exclude_segment {args} {lappend ::excluded $args}
    ''')
    tcl.call("vd100_create_pl")
    tcl.call("vd100_assign_addresses")
    tcl.call("vd100_create_debug")
    return tcl


class IntegrationTests(unittest.TestCase):
    def test_tcl_syntax(self):
        tcl = tkinter.Tcl()
        paths = list((ROOT / "scripts/scripts").rglob("*.tcl"))
        paths += list((ROOT / "constraints").glob("*.xdc"))
        paths += list((ROOT / "external/alinx_vd100").glob("*.tcl"))
        self.assertGreater(len(paths), 15)
        for path in paths:
            with self.subTest(path=path):
                self.assertTrue(tcl.call("info", "complete", path.read_text()))

    def test_create_project_runs_routed_implementation_and_checks_timing(self):
        script = (ROOT / "scripts/scripts/vivado/create_project.tcl").read_text()
        settings = (ROOT / "scripts/scripts/vivado/project_info.tcl").read_text()
        self.assertIn("variable run_implementation 1", settings)
        self.assertIn("launch_runs impl_1 -to_step route_design", script)
        self.assertIn("wait_on_run impl_1", script)
        self.assertIn("report_timing_summary -report_unconstrained", script)
        self.assertIn("foreach delay_type {max min} check_name {setup hold}", script)
        self.assertIn("get_drc_violations -quiet -filter {SEVERITY == Error}", script)

    def test_clock_reset_and_metadata(self):
        tcl = mock_bd()
        def prop(obj, key):
            return tcl.call("dict", "get", tcl.getvar("properties"), obj, key)
        self.assertEqual(prop("pll_pl_scr1", "CONFIG.PRIM_IN_FREQ"), "99.999001")
        self.assertTrue(prop("pll_pl_scr1", "CONFIG.CLKOUT_REQUESTED_OUT_FREQUENCY").startswith("90.000000,"))
        for port in ("S_AXI_IMEM", "S_AXI_DMEM", "M_AXIL_CTRL", "M_AXIL_BOOT"):
            self.assertEqual(int(prop(port, "CONFIG.FREQ_HZ")), 90000038)
        nets = [tcl.splitlist(net) for net in tcl.splitlist(tcl.getvar("nets"))]
        self.assertIn(("pll_pl_scr1/locked", "proc_sys_reset_0/dcm_locked"), nets)
        network = next(net for net in nets if "pl_clk_o" in net)
        for pin in ("pll_pl_scr1/clk_out1", "versal_cips_0/m_axi_fpd_aclk", "axi_noc_0/aclk4",
                    "smartconnect_0/aclk", "proc_sys_reset_0/slowest_sync_clk", "axi_gpio_0/s_axi_aclk",
                    "versal_cips_0/m_axi_lpd_aclk"):
            self.assertIn(pin, network)
        self.assertNotIn("versal_cips_0/pl0_ref_clk", network)
        self.assertNotIn("const_one", tcl.splitlist(tcl.getvar("cells")))

    def test_ps_and_native_ddr(self):
        tcl = mock_bd()
        cfg = tcl.call("dict", "get", tcl.getvar("properties"), "versal_cips_0", "CONFIG.PS_PMC_CONFIG")
        get = lambda key: tcl.call("dict", "get", cfg, key)
        self.assertEqual(int(get("PMC_CRP_PL0_REF_CTRL_FREQMHZ")), 100)
        self.assertFalse(tcl.call("dict", "exists", cfg, "PMC_CRP_PL0_REF_CTRL_ACT_FREQMHZ"))
        for key in ("PMC_USE_PMC_NOC_AXI0", "PS_USE_NOC_LPD_AXI0", "PS_USE_M_AXI_FPD", "PS_USE_M_AXI_LPD", "PS_USE_PMCPL_CLK0"):
            self.assertEqual(int(get(key)), 1)
        self.assertIn("PS_MIO 16 .. 17", get("PS_UART0_PERIPHERAL"))
        self.assertIn("PMC_MIO 26 .. 36", get("PMC_SD1_PERIPHERAL"))
        for key in ("PS_ENET1_PERIPHERAL", "PS_ENET1_MDIO", "PS_I2C0_PERIPHERAL", "PS_I2C1_PERIPHERAL"):
            self.assertIn("ENABLE 0", get(key))
        self.assertEqual(int(get("PS_GPIO_EMIO_PERIPHERAL_ENABLE")), 0)
        interfaces = [tcl.splitlist(net) for net in tcl.splitlist(tcl.getvar("interface_nets"))]
        self.assertIn(("versal_cips_0/PMC_NOC_AXI_0", "axi_noc_0/S05_AXI"), interfaces)
        self.assertIn(("versal_cips_0/LPD_AXI_NOC_0", "axi_noc_0/S06_AXI"), interfaces)
        maps = [tcl.splitlist(m) for m in tcl.splitlist(tcl.getvar("mapped"))]
        for source, si in (("PMC_NOC_AXI_0", "S05_AXI"), ("LPD_AXI_NOC_0", "S06_AXI")):
            self.assertIn((f"versal_cips_0/{source}", f"axi_noc_0/{si}/DDR", "0x00000000", "0x80000000"), maps)
        for source in ("versal_cips_0/M_AXI_FPD", "S_AXI_DMEM"):
            self.assertIn((source, "M_AXIL_CTRL/Reg", "0xA4000000", "0x00001000"), maps)

    def test_per_master_address_isolation(self):
        tcl = mock_bd()
        maps = [tcl.splitlist(m) for m in tcl.splitlist(tcl.getvar("mapped"))]
        excluded = [tcl.splitlist(m) for m in tcl.splitlist(tcl.getvar("excluded"))]
        for bus in ("S_AXI_IMEM", "S_AXI_DMEM"):
            ddr = [m for m in maps if m[0] == bus and m[1].endswith("/DDR")]
            self.assertEqual(ddr, [(bus, "axi_noc_0/S04_AXI/DDR", "0x7F000000", "0x01000000")])
            base, size = map(lambda x: int(x, 0), ddr[0][2:])
            for address in (0, 0x7EFFFFFF, 0x80000000):
                self.assertFalse(base <= address < base + size)
            for address in (0x7F000000, 0x7FFFFFFF):
                self.assertTrue(base <= address < base + size)
            self.assertIn((bus, "axi_gpio_0/S_AXI/Reg"), excluded)
            self.assertIn((bus, "M_AXIL_BOOT/Reg", "0xA4010000", "0x00010000"), maps)
        self.assertIn(("S_AXI_IMEM", "M_AXIL_CTRL/Reg"), excluded)
        for master in ("versal_cips_0/M_AXI_FPD", "versal_cips_0/M_AXI_LPD"):
            self.assertIn((master, "axi_noc_0/S04_AXI/DDR"), excluded)
        debug = [m[1:] for m in maps if m[0] == "versal_cips_0/M_AXI_LPD"]
        self.assertCountEqual(debug, [
            ("M_AXIL_CTRL/Reg", "0x80000000", "0x00001000"),
            ("M_AXIL_BOOT/Reg", "0x80010000", "0x00010000"),
            ("axi_gpio_0/S_AXI/Reg", "0x80020000", "0x00001000"),
        ])
        for si in range(4):
            self.assertIn((f"versal_cips_0/FPD_CCI_NOC_{si}", f"axi_noc_0/S0{si}_AXI/DDR",
                           "0x00000000", "0x80000000"), maps)
        dt = (ROOT / "linux/project-spec/meta-user/recipes-bsp/device-tree/files/system-user.dtsi").read_text()
        self.assertRegex(dt, r"reg = <0x0 0x7f000000 0x0 0x01000000>;")
        self.assertIn("no-map;", dt)
        self.assertRegex(dt, r"&axi_gpio_0\s*\{\s*reg = <0x0 0xa4020000 0x0 0x1000>;")

    def test_versal_debug_connectivity_and_probes(self):
        tcl = mock_bd()
        prop = lambda obj, key: tcl.call("dict", "get", tcl.getvar("properties"), obj, key)
        self.assertEqual(int(prop("smartconnect_0", "CONFIG.NUM_SI")), 4)
        self.assertEqual(prop("versal_cips_0", "CONFIG.DEBUG_MODE"), "JTAG")
        interfaces = [tcl.splitlist(m) for m in tcl.splitlist(tcl.getvar("interface_nets"))]
        self.assertIn(("versal_cips_0/M_AXI_LPD", "smartconnect_0/S03_AXI"), interfaces)
        slots = ("smartconnect_0/S00_AXI", "smartconnect_0/M01_AXI", "smartconnect_0/M02_AXI",
                 "axi_gpio_0/S_AXI", "smartconnect_0/S03_AXI", "smartconnect_0/S01_AXI", "smartconnect_0/S02_AXI")
        for i, source in enumerate(slots):
            self.assertIn((source, f"axis_ila_scr1/SLOT_{i}_AXI"), interfaces)
        self.assertEqual(prop("axis_ila_scr1", "CONFIG.C_MON_TYPE"), "Mixed")
        self.assertEqual(int(prop("axis_ila_scr1", "CONFIG.C_NUM_MONITOR_SLOTS")), 7)
        self.assertEqual(int(prop("axis_ila_scr1", "CONFIG.C_DATA_DEPTH")), 1024)
        probes = ("pll_pl_scr1/locked", "versal_cips_0/pl0_resetn", "proc_sys_reset_0/interconnect_aresetn",
                  "proc_sys_reset_0/peripheral_aresetn", "axi_gpio_0/gpio_io_o", "debug_scr1_resetn_i",
                  "debug_lifecycle_i", "debug_axi_fault_i", "debug_outstanding_i")
        nets = [tcl.splitlist(m) for m in tcl.splitlist(tcl.getvar("nets"))]
        for i, (source, width) in enumerate(zip(probes, (1, 1, 1, 1, 3, 1, 4, 4, 12))):
            self.assertIn((source, f"axis_ila_scr1/probe{i}"), nets)
            self.assertEqual(int(prop("axis_ila_scr1", f"CONFIG.C_PROBE{i}_WIDTH")), width)
        self.assertIn(("pll_pl_scr1/clk_out1", "axis_ila_scr1/clk"), nets)
        self.assertIn(("debug_const_one/dout", "axis_ila_scr1/resetn"), nets)
        # Readiness must never feed clock/reset/control inputs in this BD.
        for net in nets:
            if "axi_gpio_0/gpio_io_o" in net:
                self.assertTrue(set(net) <= {"axi_gpio_0/gpio_io_o", "platform_ready_o", "axis_ila_scr1/probe4"})

    def test_dpc_read_only_smoke_rejects_wrong_image(self):
        for ip_id, mhz, accepted in ((0x5343544C, 90, True), (0, 90, False), (0x5343544C, 100, False)):
            tcl = tkinter.Tcl()
            tcl.setvar("id", ip_id)
            tcl.setvar("mhz", mhz)
            tcl.eval(r'''
                set ::scr1_dpc_library_only 1
                set reads {}
                proc mrd {option addr count} {
                    if {$option ne "-value" || $count != 1} {error "Bad mrd arguments"}
                    lappend ::reads $addr
                    switch -- $addr {
                        0x80000000 {return [format %08X $::id]}
                        default {
                            if {$addr == 0x80000000} {return [format %08X $::id]}
                            if {$addr == 0x8000000C} {return [format 0x%08X $::mhz]}
                            return 00000000
                        }
                    }
                }
            ''')
            tcl.call("source", str(ROOT / "scripts/scripts/debug/scr1_dpc_smoke.tcl"))
            if accepted:
                tcl.call("scr1_dpc_smoke")
            else:
                with self.assertRaises(tkinter.TclError):
                    tcl.call("scr1_dpc_smoke")
            self.assertTrue(all(0x80000000 <= int(x) < 0x80001000 for x in tcl.splitlist(tcl.getvar("reads"))))
            # mwr/reset/targets are deliberately absent from this mocked API.

    def test_software_header_matches_tcl_and_register_offsets(self):
        header = (ROOT / "include/scr1_platform.h").read_text()
        values = {name: int(value, 16) for name, value in
                  re.findall(r"#define (\w+)\s+(0x[0-9A-Fa-f]+)UL", header)}
        tcl = mock_bd()
        for macro, setting in {
            "SCR1_A72_CONTROL_BASE": "ctrl_base", "SCR1_A72_BOOT_BASE": "boot_base",
            "SCR1_A72_READY_GPIO_BASE": "ready_gpio_base", "SCR1_DPC_CONTROL_BASE": "debug_ctrl_base",
            "SCR1_DPC_BOOT_BASE": "debug_boot_base", "SCR1_DPC_READY_GPIO_BASE": "debug_gpio_base",
            "SCR1_SHARED_DDR_BASE": "scr1_ddr_base", "SCR1_SHARED_DDR_BYTES": "scr1_ddr_range",
        }.items():
            self.assertEqual(values[macro], int(tcl.getvar(f"::vd100::{setting}"), 0))
        rtl = (ROOT / "rtl/control/scr1_regs_pkg.sv").read_text()
        for name, value in re.findall(r"localparam scr1_reg_addr_t\s+(SCR1_REG_\w+)\s*=\s*12'h([0-9A-Fa-f]+);", rtl):
            self.assertEqual(values[name], int(value, 16))
        if compiler := shutil.which("cc"):
            source = '#include "linux/include/scr1_platform.h"\n#include "firmware/include/scr1_platform.h"\n'
            for expression in ("SCR1_CLOCK_HZ == 90000000", "SCR1_START_TIMEOUT_CYCLES == 9000000",
                               "SCR1_QUIESCE_TIMEOUT_CYCLES == 90000", "SCR1_WATCHDOG_PERIOD_CYCLES == 90000000"):
                source += f'_Static_assert({expression}, "clock contract");\n'
            subprocess.run([compiler, "-x", "c", "-std=c11", "-Werror", "-fsyntax-only", "-I", str(ROOT), "-"],
                           input=source, text=True, capture_output=True, check=True)

    @unittest.skipUnless(pyslang, "Real SV checks require pip install pyslang==12.0.0")
    def test_real_sv_alias_boundaries_and_clock_defaults(self):
        top = (ROOT / "rtl/vd100_scr1_top.sv").read_text()
        function = re.search(r"function automatic logic \[31:0\] platform_address.*?endfunction", top, re.S).group()
        cases = {
            0xFF000000: 0xA4000000, 0xFF000070: 0xA4000070, 0xFF000FFC: 0xA4000FFC,
            0xFF000FFF: 0xA4000FFF, 0xFF001000: 0xFF001000, 0xFEFFFFFF: 0xFEFFFFFF,
            0xFFFF0000: 0xA4010000, 0xFFFF0080: 0xA4010080, 0xFFFFFFFF: 0xA401FFFF,
            0xFFFEFFFF: 0xFFFEFFFF, 0x7EFFFFFF: 0x7EFFFFFF, 0x7F000000: 0x7F000000,
            0x7FFFFFFF: 0x7FFFFFFF, 0xF0000000: 0xF0000000, 0xF0040000: 0xF0040000,
            0xA4000000: 0xA4000000, 0x80000000: 0x80000000,
        }
        source = "module contract_test; import scr1_regs_pkg::*;\n" + function + "\n"
        for i, (address, expected) in enumerate(cases.items()):
            source += f"localparam logic [31:0] ALIAS_{i}=platform_address(32'h{address:08x});\n"
        source += """localparam logic [31:0] HW = scr1_make_hw_config(4, 1);
            localparam logic [31:0] START = SCR1_START_TIMEOUT_RESET_VALUE;
            localparam logic [31:0] QUIESCE = SCR1_QUIESCE_TIMEOUT_RESET_VALUE;
            localparam logic [31:0] WATCHDOG = SCR1_WATCHDOG_CFG_RESET_VALUE;
            endmodule"""
        compilation = pyslang.ast.Compilation()
        for path in ("rtl/control/vd100_scr1_pkg.sv", "rtl/control/scr1_regs_pkg.sv"):
            compilation.addSyntaxTree(pyslang.syntax.SyntaxTree.fromText((ROOT / path).read_text()))
        compilation.addSyntaxTree(pyslang.syntax.SyntaxTree.fromText(source))
        body = next(x for x in compilation.getRoot().topInstances if x.name == "contract_test").body
        self.assertFalse([d for d in compilation.getAllDiagnostics() if d.isError()])
        for i, expected in enumerate(cases.values()):
            self.assertEqual(int(body.find(f"ALIAS_{i}").value.value), expected)
        for name, expected in (("HW", 0x14040C5A), ("START", 9000000), ("QUIESCE", 90000), ("WATCHDOG", 90000000)):
            self.assertEqual(int(body.find(name).value.value), expected)
        for bus in ("imem", "dmem"):
            for channel in ("ar", "aw"):
                self.assertRegex(top, rf"\.S_AXI_{bus.upper()}_{channel}addr\s*\(platform_address\(m_axi_{bus}_{channel}addr\)\)")
        preprocessor = pyslang.parsing.PreprocessorOptions()
        preprocessor.additionalIncludePaths = [str(ROOT / "external/scr1/src/includes"), str(ROOT / "rtl/config")]
        preprocessor.predefines = ["SCR1_ARCH_CUSTOM"]
        options = pyslang.Bag([preprocessor])
        manager = pyslang.SourceManager()
        for path in ("rtl/vd100_scr1_top.sv", "rtl/scr1_subsystem.sv"):
            tree = pyslang.syntax.SyntaxTree.fromFiles([str(ROOT / path)], manager, options)
            self.assertFalse([d for d in tree.diagnostics if d.isError()])
        # Evaluate the actual SCR1 architecture macro under production defines.
        tree = pyslang.syntax.SyntaxTree.fromText(
            '`include "scr1_arch_description.svh"\n'
            'module clock_test; localparam logic[31:0] HZ=`SCR1_PTFM_CORE_CLK_FREQ; endmodule',
            manager, options=options)
        arch = pyslang.ast.Compilation()
        arch.addSyntaxTree(tree)
        clock_body = next(x for x in arch.getRoot().topInstances if x.name == "clock_test").body
        self.assertEqual(int(clock_body.find("HZ").value.value), 90000000)
        self.assertFalse([d for d in arch.getAllDiagnostics() if d.isError()])

    @unittest.skipUnless(shutil.which("cc") and shutil.which("ld"), "Linker checks require a C toolchain/binutils")
    def test_linker_windows_and_overflow(self):
        with tempfile.TemporaryDirectory() as directory:
            work = Path(directory)
            asm = '.globl _start\n.section .text.reset\n_start: .byte 0x90\n.section .text.trap\n.byte 0x90\n.section .text\n.byte 0x90\n.section .bss\n.space 128\n'
            def assemble(text):
                subprocess.run(["cc", "-x", "assembler", "-c", "-o", str(work / "test.o"), "-"],
                               input=text, text=True, capture_output=True, check=True)
            for name, origin, length in (("boot_bram", 0xFFFF0000, 0x10000), ("tcm", 0xF0000000, 0x10000),
                                         ("shared_ddr", 0x7F000000, 0x1000000)):
                script = ROOT / f"firmware/linker/scr1_{name}.ld"
                self.assertIn(f"ORIGIN = 0x{origin:08X}, LENGTH = 0x{length:08X}", script.read_text())
                assemble(asm)
                command = ["ld", "-T", str(script), "-o", str(work / "test.elf"), str(work / "test.o")]
                subprocess.run(command, text=True, capture_output=True, check=True)
                assemble(asm.replace('.space 128', f'.space {length}'))
                result = subprocess.run(command, text=True, capture_output=True)
                self.assertNotEqual(result.returncode, 0, result.stderr)
            assemble(asm.replace('.byte 0x90\n.section .text.trap', '.space 129\n.section .text.trap', 1))
            result = subprocess.run(["ld", "-T", str(ROOT / "firmware/linker/scr1_boot_bram.ld"),
                                     "-o", str(work / "bad.elf"), str(work / "test.o")], text=True, capture_output=True)
            self.assertNotEqual(result.returncode, 0)
            self.assertIn("Reset stub overlaps", result.stderr)

    def test_merge_config_preserves_other_keys_and_is_idempotent(self):
        before = 'CONFIG_KEEP="yes"\nCONFIG_X=y\n# CONFIG_Y is not set\n'
        fragment = '# CONFIG_X is not set\nCONFIG_Y=y\n'
        after = PREPARE.merge_config(before, fragment)
        self.assertIn('CONFIG_KEEP="yes"', after)
        self.assertNotIn("\nCONFIG_X=y", after)
        self.assertEqual(after.count("CONFIG_X"), 1)
        self.assertEqual(after, PREPARE.merge_config(after, fragment))

    def test_xsa_accepts_cortix_rejects_alinx_and_missing_pdi(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "test.xsa"
            for name, markers, accepted in (
                ("vd100_scr1_top.pdi", "pll_pl_scr1 versal_cips_0 axi_noc_0", True),
                ("design_1_wrapper.pdi", "versal_cips_0 axi_noc_0", False),
                (None, "pll_pl_scr1 versal_cips_0 axi_noc_0", False),
            ):
                with zipfile.ZipFile(path, "w") as archive:
                    archive.writestr("design.hwh", markers)
                    if name:
                        archive.writestr(name, "mock PDI, not hardware")
                if accepted:
                    self.assertEqual(PREPARE.inspect_xsa(path), [name])
                else:
                    with self.assertRaises(ValueError):
                        PREPARE.inspect_xsa(path)

    def test_export_fails_on_negative_slack_or_stale_run(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory)
            (path / "project.xpr").touch()
            (path / "test.pdi").touch()
            for slack, stale in ((-0.1, 0), (0.1, 1), (0.1, 0)):
                tcl = tkinter.Tcl()
                tcl.setvar("run_dir", str(path))
                tcl.setvar("slack", slack)
                tcl.setvar("stale", stale)
                tcl.eval(r'''
                    set ::vd100_export_library_only 1
                    set exported 0
                    proc version {args} {return 2023.2}
                    proc open_project {args} {}
                    proc current_project {} {return project}
                    proc get_runs {args} {return impl_1}
                    proc get_files {args} {return vd100_platform.bd}
                    proc open_bd_design {args} {}
                    proc get_bd_cells {args} {return [lindex $args end]}
                    proc get_bd_intf_pins {args} {return [lindex $args end]}
                    proc get_bd_intf_nets {args} {return connected}
                    proc validate_bd_design {} {}
                    proc open_run {args} {}
                    proc report_timing_summary {args} {}
                    proc report_cdc {args} {}
                    proc report_drc {args} {}
                    proc get_drc_violations {args} {return {}}
                    proc get_timing_paths {args} {return path}
                    proc get_property {key obj} {
                        switch -- $key {
                            PART {return xcve2302-sfva784-1LP-e-S}
                            STATUS {return "write_device_image Complete!"}
                            NEEDS_REFRESH {return $::stale}
                            DIRECTORY {return $::run_dir}
                            SLACK {return $::slack}
                        }
                        error "Unexpected property $key"
                    }
                    proc write_debug_probes {file} {
                        set fh [open $file w]; puts $fh "mock LTX, not hardware"; close $fh
                    }
                    proc write_hw_platform {args} {set ::exported 1}
                    proc close_project {} {}
                ''')
                tcl.call("source", str(ROOT / "scripts/scripts/vivado/export_xsa.tcl"))
                if slack < 0 or stale:
                    with self.assertRaises(tkinter.TclError):
                        tcl.call("vd100_export_xsa", str(path / "project.xpr"), str(path / "output.xsa"))
                    self.assertEqual(int(tcl.getvar("exported")), 0)
                else:
                    tcl.call("vd100_export_xsa", str(path / "project.xpr"), str(path / "output.xsa"))
                    self.assertEqual(int(tcl.getvar("exported")), 1)

    def test_handoff_rejects_changed_imported_xsa(self):
        with tempfile.TemporaryDirectory() as directory:
            project = Path(directory)
            (project / "cortix-hardware").mkdir()
            (project / "project-spec/hw-description").mkdir(parents=True)
            imported = project / "cortix-hardware/cortix_scr1.xsa"
            system = project / "project-spec/hw-description/system.xsa"
            imported.write_bytes(b"mock qualified handoff")
            system.write_bytes(imported.read_bytes())
            manifest = {"xsa_sha256": HANDOFF.digest(imported), "imported_xsa": "cortix-hardware/cortix_scr1.xsa"}
            (project / "cortix-handoff.json").write_text(json.dumps(manifest))
            self.assertEqual(HANDOFF.verify(project), manifest)
            system.write_bytes(b"stale ALINX handoff")
            with self.assertRaises(ValueError):
                HANDOFF.verify(project)

    def test_stage_requires_all_four_sd_images_and_preserves_old_payload(self):
        with tempfile.TemporaryDirectory() as directory:
            project = Path(directory)
            (project / "cortix-hardware").mkdir()
            (project / "project-spec/hw-description").mkdir(parents=True)
            imported = project / "cortix-hardware/cortix_scr1.xsa"
            system = project / "project-spec/hw-description/system.xsa"
            imported.write_bytes(b"mock qualified handoff")
            system.write_bytes(imported.read_bytes())
            manifest = {"xsa_sha256": HANDOFF.digest(imported), "imported_xsa": "cortix-hardware/cortix_scr1.xsa"}
            (project / "cortix-handoff.json").write_text(json.dumps(manifest))
            images = project / "images/linux"
            images.mkdir(parents=True)
            for name in ("BOOT.BIN", "image.ub", "boot.scr"):
                (images / name).write_bytes(b"mock " + name.encode())
            with self.assertRaises(ValueError):
                HANDOFF.stage(project)
            self.assertFalse((project / "cortix-sd").exists())
            (images / "rootfs.tar.gz").write_bytes(b"mock rootfs")
            HANDOFF.stage(project)
            staged = json.loads((project / "cortix-sd/handoff.json").read_text())
            self.assertIn("NOT verified", staged["status"])
            self.assertEqual(staged["image_sha256"]["rootfs.tar.gz"], hashlib.sha256(b"mock rootfs").hexdigest())
            with self.assertRaises(FileExistsError):
                HANDOFF.stage(project)


if __name__ == "__main__":
    unittest.main(verbosity=2)

