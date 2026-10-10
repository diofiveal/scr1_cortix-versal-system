#!/usr/bin/env python3
"""Bundle the repository + hardware, then transfer/build over SSH or a shared folder."""
import argparse
from datetime import datetime, timezone
import hashlib
import json
from pathlib import Path
import re
import shlex
import shutil
import subprocess
import sys
import zipfile

from prepare_petalinux import inspect_xsa
from vm_build import verify_sd_archive

ROOT = Path(__file__).resolve().parents[3]
HARDWARE = ("cortix_scr1.xsa", "cortix_scr1.pdi", "cortix_scr1.ltx")


def create_bundle(root, hardware, destination):
    """Copy tracked sources only: no Vivado caches or old PetaLinux projects."""
    for name in HARDWARE:
        path = hardware / name
        if not path.is_file() or not path.stat().st_size:
            raise ValueError(f"Missing/empty hardware output: {path}. Run create_project.tcl first.")
    pdis = inspect_xsa(hardware / HARDWARE[0])
    with zipfile.ZipFile(hardware / HARDWARE[0]) as archive:
        image_hash = hashlib.sha256((hardware / HARDWARE[1]).read_bytes()).hexdigest()
        if not any(hashlib.sha256(archive.read(n)).hexdigest() == image_hash for n in pdis):
            raise ValueError("Standalone PDI differs from the PDI inside XSA")
    tracked = subprocess.check_output(["git", "ls-files", "-z"], cwd=root).decode().split("\0")
    revision = subprocess.check_output(["git", "rev-parse", "HEAD"], cwd=root, text=True).strip()
    sources = {name: root / name for name in tracked if name}
    for name in HARDWARE:
        sources[f"build/hardware/{name}"] = hardware / name
    manifest = {"format": 1, "repository_commit": revision, "sha256": {}}
    destination.parent.mkdir(parents=True, exist_ok=True)
    with zipfile.ZipFile(destination, "x", compression=zipfile.ZIP_DEFLATED) as archive:
        for name, path in sources.items():
            data = path.read_bytes()
            manifest["sha256"][name] = hashlib.sha256(data).hexdigest()
            archive.writestr(name, data)
        archive.writestr("SOURCE_REVISION", revision + "\n")
        manifest["sha256"]["SOURCE_REVISION"] = hashlib.sha256((revision + "\n").encode()).hexdigest()
        archive.writestr("vm-bundle.json", json.dumps(manifest, indent=2) + "\n")
    return manifest


def run(command):
    print("RUN:", shlex.join(map(str, command)), flush=True)
    subprocess.run(command, check=True)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    target = parser.add_mutually_exclusive_group(required=True)
    target.add_argument("--host", help="SSH destination: user@VM-IP (key or ssh-agent authentication)")
    target.add_argument("--shared-dir", type=Path, help="host path to the VirtualBox shared folder")
    parser.add_argument("--hardware", type=Path, default=ROOT / "build/hardware")
    parser.add_argument("--settings", help="absolute PetaLinux 2023.2 settings.sh path INSIDE the VM")
    parser.add_argument("--vm-workdir", help="absolute VM path on native Linux disk")
    parser.add_argument("--port", type=int, default=22)
    parser.add_argument("--configure-only", action="store_true")
    args = parser.parse_args()
    if args.host:
        if not re.fullmatch(r"[A-Za-z0-9_.@:-]+", args.host) or args.host.startswith("-"):
            parser.error("Invalid SSH host")
        if not 1 <= args.port <= 65535:
            parser.error("Invalid SSH port")
        if not args.settings or not args.settings.startswith("/") or not args.vm_workdir or not args.vm_workdir.startswith("/"):
            parser.error("SSH mode requires absolute --settings and --vm-workdir paths inside the VM")
        if not re.fullmatch(r"/[A-Za-z0-9_./-]+", args.vm_workdir):
            parser.error("Use a VM workdir with letters, digits, /, _, -, . and no spaces")
        for tool in ("ssh", "scp"):
            if not shutil.which(tool):
                parser.error(f"Install {tool} on the host")
    run([sys.executable, str(ROOT / "scripts/scripts/checks/test_linux_integration.py")])
    name = "cortix-vm-" + datetime.now(timezone.utc).strftime("%Y%m%d-%H%M%S-%f")
    output = args.shared_dir.resolve() / name if args.shared_dir else ROOT / "build/vm" / name
    output.mkdir(parents=True, exist_ok=False)
    bundle = output / "bundle.zip"
    create_bundle(ROOT, args.hardware.resolve(), bundle)
    runner = output / "vm_build.py"
    shutil.copy2(Path(__file__).with_name("vm_build.py"), runner)
    if args.shared_dir:
        print(f"Ready: {output}\nInside the VM run (substitute its shared-folder mount and settings path):")
        print(f"python3 /media/sf_exchange/{name}/vm_build.py /media/sf_exchange/{name}/bundle.zip "
              f"--settings /absolute/path/to/petalinux/2023.2/settings.sh --workdir ~/cortix-builds/{name}")
        return
    remote = args.vm_workdir.rstrip("/") + "/" + name
    # Each shell argument is quoted independently. No passwords are embedded;
    # normal SSH host-key verification and ssh-agent/key authentication apply.
    ssh = ["ssh", "-o", "BatchMode=yes", "-p", str(args.port), args.host]
    scp = ["scp", "-o", "BatchMode=yes", "-P", str(args.port)]
    run(ssh + ["mkdir -p -- " + shlex.quote(remote)])
    run(scp + [str(bundle), str(runner), args.host + ":" + shlex.quote(remote + "/")])
    command = ["python3", remote + "/vm_build.py", remote + "/bundle.zip",
               "--settings", args.settings, "--workdir", remote + "/work"]
    if args.configure_only:
        command.append("--configure-only")
    run(ssh + [shlex.join(command)])
    if not args.configure_only:
        result = output / "sd-output.zip"
        run(scp + [args.host + ":" + shlex.quote(remote + "/work/sd-output.zip"), str(result)])
        verify_sd_archive(result)
        print(f"Verified SD files returned to {result}. FPGA boot still needs a board test.")


if __name__ == "__main__":
    try:
        main()
    except (OSError, ValueError, subprocess.CalledProcessError, zipfile.BadZipFile) as error:
        sys.exit(f"ERROR: {error}")
