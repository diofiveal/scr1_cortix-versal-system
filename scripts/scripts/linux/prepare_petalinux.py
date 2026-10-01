#!/usr/bin/env python3
"""Create a NEW PetaLinux 2023.2 project from the qualified Cortix XSA.

No SD devices are opened. Existing PetaLinux projects are never overwritten.
Run after sourcing the installed PetaLinux 2023.2 settings.sh, as non-root.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import zipfile

ROOT = Path(__file__).resolve().parents[3]


def merge_config(current, fragment):
    """Replace named Kconfig assignments; preserve unrelated generated keys."""
    key_re = re.compile(r"^(?:# )?(CONFIG_[A-Za-z0-9_-]+)(?:=| is not set$)")
    updates = {}
    for line in fragment.splitlines():
        match = key_re.match(line)
        if match:
            updates[match[1]] = line
    merged = []
    for line in current.splitlines():
        match = key_re.match(line)
        if not match or match[1] not in updates:
            merged.append(line)
    return "\n".join(merged + list(updates.values())) + "\n"


def inspect_xsa(path):
    """Reject the old ALINX XSA and handoffs without a PDI or Cortix PLL."""
    with zipfile.ZipFile(path) as archive:
        names = archive.namelist()
        pdis = [n for n in names if n.lower().endswith(".pdi")]
        hwhs = [n for n in names if n.lower().endswith(".hwh")]
        if not pdis or not hwhs:
            raise ValueError("XSA must contain a PDI and HWH (export with -include_bit)")
        hw = "\n".join(archive.read(n).decode("utf-8") for n in hwhs)
        for marker in ("pll_pl_scr1", "versal_cips_0", "axi_noc_0"):
            if marker not in hw:
                raise ValueError(f"Not the Cortix Linux hardware: missing {marker} in HWH")
        if not any("vd100_scr1_top" in n for n in pdis):
            raise ValueError("Expected vd100_scr1_top PDI, not the ALINX demo PDI")
        return pdis


def run(command, cwd):
    print("RUN:", " ".join(map(str, command)), flush=True)
    subprocess.run(command, cwd=cwd, check=True)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("xsa", type=Path)
    parser.add_argument("project", type=Path, help="new project directory, not an existing one")
    args = parser.parse_args()
    xsa = args.xsa.resolve(strict=True)
    project = args.project.absolute()
    pdis = inspect_xsa(xsa)
    if project.exists():
        parser.error(f"Refusing to overwrite existing project: {project}")
    if hasattr(os, "geteuid") and os.geteuid() == 0:
        parser.error("PetaLinux must be run as a normal user, not root/sudo")
    if not re.fullmatch(r"[A-Za-z0-9_-]+", project.name) or " " in str(project):
        parser.error("Use a project path without spaces and a simple project name")
    if os.environ.get("PETALINUX_VER") != "2023.2":
        parser.error("First source the PetaLinux 2023.2 settings.sh (PETALINUX_VER=2023.2)")
    for tool in ("petalinux-create", "petalinux-config"):
        if shutil.which(tool) is None:
            parser.error(f"{tool} is unavailable; source settings.sh")
    project.parent.mkdir(parents=True, exist_ok=True)
    run(["petalinux-create", "-t", "project", "--template", "versal", "-n", project.name], project.parent)
    # Use a private import directory with exactly ONE XSA, not stale ALINX HW.
    import_dir = project / "cortix-hardware"
    import_dir.mkdir()
    imported_xsa = import_dir / "cortix_scr1.xsa"
    shutil.copy2(xsa, imported_xsa)
    run(["petalinux-config", "--get-hw-description", str(import_dir), "--silentconfig"], project)
    overlay = ROOT / "linux/project-spec/meta-user/recipes-bsp/device-tree"
    destination = project / "project-spec/meta-user/recipes-bsp/device-tree"
    # This is a fresh template we just created, not the user's existing BSP.
    shutil.copytree(overlay, destination, dirs_exist_ok=True)
    for target, fragment in (("config", "config.fragment"), ("rootfs_config", "rootfs.fragment")):
        config = project / "project-spec/configs" / target
        config.write_text(merge_config(config.read_text(), (ROOT / "linux" / fragment).read_text()))
    run(["petalinux-config", "--silentconfig"], project)
    run(["petalinux-config", "-c", "rootfs", "--silentconfig"], project)
    # Record the handoff identity; build_sd checks it before/after a build.
    git = subprocess.run(["git", "rev-parse", "HEAD"], cwd=ROOT, text=True, capture_output=True)
    manifest = {
        "xsa_sha256": hashlib.sha256(imported_xsa.read_bytes()).hexdigest(),
        "source_xsa": str(xsa), "imported_xsa": "cortix-hardware/cortix_scr1.xsa",
        "pdi_members": pdis, "repository_commit": git.stdout.strip() if git.returncode == 0 else None,
        "petalinux_version": "2023.2", "status": "configured; not built or boot-tested",
    }
    (project / "cortix-handoff.json").write_text(json.dumps(manifest, indent=2) + "\n")
    print(f"Configured {project}. Next: bash {ROOT}/scripts/scripts/linux/build_sd.sh {project}")


if __name__ == "__main__":
    main()
