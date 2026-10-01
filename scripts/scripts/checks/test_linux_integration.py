#!/usr/bin/env python3
"""Offline Tcl/Python regression; not a Vivado IP or board-boot validation.

Uses Python's Tcl interpreter to EXECUTE the production BD procedures against
an explicitly mocked API, then checks clocks, reset, PS overlay and NoC map.
"""
import importlib.util
import hashlib
import json
from pathlib import Path
import tempfile
import tkinter
import unittest
import zipfile

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
    for name in ("project_info", "helpers", "ps_config", "noc_config", "pl_config", "address_map"):
        tcl.call("source", str(ROOT / f"scripts/scripts/vivado/{name}.tcl"))
    tcl.eval(r'''
        proc vd100_find_external_segment {name} {return $name/Reg}
        proc vd100_find_noc_ddr_segment {noc si} {return $noc/$si/DDR}
        proc get_bd_addr_segs {args} {return [lindex $args end]}
        proc vd100_map_segment {space segment offset range} {lappend ::mapped [list $space $segment $offset $range]}
        proc vd100_exclude_segment {args} {}
    ''')
    tcl.call("vd100_create_pl")
    tcl.call("vd100_assign_addresses")
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
                    "smartconnect_0/aclk", "proc_sys_reset_0/slowest_sync_clk", "axi_gpio_0/s_axi_aclk"):
            self.assertIn(pin, network)
        self.assertNotIn("versal_cips_0/pl0_ref_clk", network)
        self.assertNotIn("const_one", tcl.splitlist(tcl.getvar("cells")))

    def test_ps_and_native_ddr(self):
        tcl = mock_bd()
        cfg = tcl.call("dict", "get", tcl.getvar("properties"), "versal_cips_0", "CONFIG.PS_PMC_CONFIG")
        get = lambda key: tcl.call("dict", "get", cfg, key)
        self.assertEqual(int(get("PMC_CRP_PL0_REF_CTRL_FREQMHZ")), 100)
        self.assertFalse(tcl.call("dict", "exists", cfg, "PMC_CRP_PL0_REF_CTRL_ACT_FREQMHZ"))
        for key in ("PMC_USE_PMC_NOC_AXI0", "PS_USE_NOC_LPD_AXI0", "PS_USE_M_AXI_FPD", "PS_USE_PMCPL_CLK0"):
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
        for source in ("versal_cips_0/M_AXI_FPD", "S_AXI_IMEM", "S_AXI_DMEM"):
            self.assertIn((source, "M_AXIL_CTRL/Reg", "0xA4000000", "0x00001000"), maps)

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
