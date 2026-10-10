#!/usr/bin/env python3
"""Standalone VM entry point: verify/extract bundle, check host, configure/build SD files."""
import argparse
import hashlib
import json
import os
from pathlib import Path, PurePosixPath
import shutil
import subprocess
import sys
import zipfile

SD_FILES = ("BOOT.BIN", "image.ub", "boot.scr", "rootfs.tar.gz")


def verify_bundle(bundle):
    """Check the entire inventory before extraction; never extract absolute/../ paths."""
    with zipfile.ZipFile(bundle) as archive:
        names = archive.namelist()
        if len(names) != len(set(names)):
            raise ValueError("Duplicate bundle members")
        manifest = json.loads(archive.read("vm-bundle.json"))
        if manifest.get("format") != 1:
            raise ValueError("Unknown VM bundle format")
        hashes = manifest["sha256"]
        if set(names) != set(hashes) | {"vm-bundle.json"}:
            raise ValueError("Bundle inventory differs from manifest")
        for name, expected in hashes.items():
            path = PurePosixPath(name)
            if path.is_absolute() or ".." in path.parts or "\\" in name:
                raise ValueError(f"Invalid bundle path: {name}")
            if hashlib.sha256(archive.read(name)).hexdigest() != expected:
                raise ValueError(f"SHA256 mismatch: {name}")
        required = {"scripts/scripts/linux/prepare_petalinux.py", "scripts/scripts/linux/build_sd.sh",
                    "scripts/scripts/linux/handoff.py", "scripts/scripts/checks/test_linux_integration.py",
                    "linux/config.fragment", "linux/rootfs.fragment", "SOURCE_REVISION"}
        required.update(f"build/hardware/cortix_scr1.{suffix}" for suffix in ("xsa", "pdi", "ltx"))
        if not required <= set(hashes):
            raise ValueError(f"Missing required source/artifact: {sorted(required - set(hashes))}")
    return manifest


def verify_sd_archive(path):
    with zipfile.ZipFile(path) as archive:
        manifest = json.loads(archive.read("handoff.json"))
        for name in SD_FILES:
            data = archive.read(name)
            if not data or hashlib.sha256(data).hexdigest() != manifest["image_sha256"][name]:
                raise ValueError(f"Returned SD payload SHA256 mismatch: {name}")
    return manifest


def check_host(workdir, settings, min_memory, min_free):
    if sys.platform != "linux" or os.geteuid() == 0:
        raise ValueError("Run inside the Linux VM as a normal user, without sudo")
    if " " in str(workdir) or any(char.isspace() for char in str(workdir)):
        raise ValueError("PetaLinux workdir must not contain whitespace")
    if not settings.is_file():
        raise ValueError(f"PetaLinux settings.sh not found: {settings}")
    memory = {}
    for line in Path("/proc/meminfo").read_text().splitlines():
        key, value = line.split(":", 1)
        memory[key] = int(value.split()[0]) * 1024
    parent = workdir
    while not parent.exists():
        parent = parent.parent
    free = shutil.disk_usage(parent).free / 2**30
    ram = memory["MemTotal"] / 2**30
    print(f"VM: RAM {ram:.1f} GiB, available {memory['MemAvailable']/2**30:.1f} GiB, "
          f"swap {memory['SwapTotal']/2**30:.1f} GiB, disk free {free:.1f} GiB, CPUs {os.cpu_count()}", flush=True)
    # Allow the small kernel-reserved difference from an 8-GiB VM allocation.
    if ram < min_memory * 0.95 or free < min_free:
        raise ValueError(f"Allocate at least {min_memory:g} GiB RAM and {min_free:g} GiB free disk to the VM")
    fs = subprocess.check_output(["findmnt", "-n", "-o", "FSTYPE", "--target", str(parent)], text=True).strip()
    if fs not in ("ext2", "ext3", "ext4", "xfs", "btrfs"):
        raise ValueError(f"Build on the VM native Linux disk, not {fs}; shared folders are for transfer only")
    if Path("/bin/sh").resolve().name != "bash":
        raise ValueError("PetaLinux 2023.2 requires /bin/sh=bash. On Ubuntu configure it with: sudo dpkg-reconfigure dash")
    # Source settings in bash with a positional argument, never interpolate paths.
    env_data = subprocess.check_output(["bash", "-c", 'source "$1" >/dev/null && env -0', "vm-build", str(settings)])
    env = dict(item.decode().split("=", 1) for item in env_data.split(b"\0") if item)
    if env.get("PETALINUX_VER") != "2023.2":
        raise ValueError("settings.sh must belong to PetaLinux 2023.2")
    for tool in ("petalinux-create", "petalinux-config", "petalinux-build", "petalinux-package", "gcc", "ld", "make", "tar", "git"):
        if not shutil.which(tool, path=env.get("PATH")):
            raise ValueError(f"Missing VM dependency: {tool}")
    return env


def run_logged(command, cwd, env, log):
    print("RUN:", " ".join(map(str, command)), flush=True)
    with subprocess.Popen(command, cwd=cwd, env=env, stdout=subprocess.PIPE,
                          stderr=subprocess.STDOUT, text=True, errors="replace") as process:
        for line in process.stdout:
            print(line, end="", flush=True)
            log.write(line)
            log.flush()
        if process.wait():
            raise subprocess.CalledProcessError(process.returncode, command)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("bundle", type=Path)
    parser.add_argument("--settings", type=Path, required=True)
    parser.add_argument("--workdir", type=Path, required=True, help="native VM disk; a new directory")
    parser.add_argument("--configure-only", action="store_true")
    parser.add_argument("--resume", action="store_true", help="resume a failed build using the unchanged bundle/XSA")
    parser.add_argument("--min-memory-gib", type=float, default=8)
    parser.add_argument("--min-free-gib", type=float, default=100)
    args = parser.parse_args()
    bundle = args.bundle.resolve(strict=True)
    work = args.workdir.resolve()
    manifest = verify_bundle(bundle)
    env = check_host(work, args.settings.resolve(), args.min_memory_gib, args.min_free_gib)
    repo = work / "repository"
    if args.resume:
        if json.loads((repo / "vm-bundle.json").read_text()) != manifest:
            raise ValueError("Resume bundle differs from the original; use a new workdir")
        for name, expected in manifest["sha256"].items():
            if hashlib.sha256((repo / name).read_bytes()).hexdigest() != expected:
                raise ValueError(f"Transferred source changed: {name}; use a new workdir")
    else:
        work.mkdir(parents=True, exist_ok=False)
        with zipfile.ZipFile(bundle) as archive:
            archive.extractall(repo)
    project = work / "petalinux-cortix"
    linux = repo / "scripts/scripts/linux"
    with (work / "vm-build.log").open("a") as log:
        run_logged([sys.executable, str(repo / "scripts/scripts/checks/test_linux_integration.py")], repo, env, log)
        if not project.exists():
            run_logged([sys.executable, str(linux / "prepare_petalinux.py"),
                        str(repo / "build/hardware/cortix_scr1.xsa"), str(project)], repo, env, log)
        # Verify configured/imported XSA even when resuming.
        run_logged([sys.executable, str(linux / "handoff.py"), "verify", str(project)], repo, env, log)
        identity = json.loads((project / "cortix-handoff.json").read_text())
        if identity["xsa_sha256"] != manifest["sha256"]["build/hardware/cortix_scr1.xsa"]:
            raise ValueError("Configured project uses a different XSA than this VM bundle")
        if args.configure_only:
            print(f"Configured {project}. Resume this bundle without --configure-only to build.")
            return
        run_logged(["bash", str(linux / "build_sd.sh"), str(project)], repo, env, log)
    payload = project / "cortix-sd"
    result = work / "sd-output.zip"
    with zipfile.ZipFile(result, "x", compression=zipfile.ZIP_DEFLATED) as archive:
        for name in (*SD_FILES, "handoff.json", "SHA256SUMS"):
            archive.write(payload / name, name)
    verify_sd_archive(result)
    print(f"SUCCESS: {result}\nBuild log: {work / 'vm-build.log'}\nSD write and FPGA boot must be tested separately.")


if __name__ == "__main__":
    try:
        main()
    except (OSError, ValueError, KeyError, subprocess.CalledProcessError, zipfile.BadZipFile) as error:
        sys.exit(f"ERROR: {error}")
