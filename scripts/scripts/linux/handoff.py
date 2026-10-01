#!/usr/bin/env python3
"""Verify XSA identity and stage a matched SD payload without touching devices."""
import argparse
import hashlib
import json
from pathlib import Path
import shutil


def digest(path):
    result = hashlib.sha256()
    with path.open("rb") as source:
        for block in iter(lambda: source.read(1024 * 1024), b""):
            result.update(block)
    return result.hexdigest()


def verify(project):
    manifest = json.loads((project / "cortix-handoff.json").read_text())
    expected = manifest["xsa_sha256"]
    for path in (project / manifest["imported_xsa"], project / "project-spec/hw-description/system.xsa"):
        if digest(path) != expected:
            raise ValueError(f"XSA has changed since configuration: {path}. Re-import/reconfigure intentionally.")
    return manifest


def stage(project):
    manifest = verify(project)
    images = project / "images/linux"
    sources = {name: images / name for name in ("BOOT.BIN", "image.ub", "boot.scr", "rootfs.tar.gz")}
    # Fail before creating a misleading/partial payload.
    for path in sources.values():
        if not path.is_file() or not path.stat().st_size:
            raise ValueError(f"Missing/empty build output: {path}")
    destination = project / "cortix-sd"
    destination.mkdir(exist_ok=False)
    for name, path in sources.items():
        shutil.copy2(path, destination / name)
    manifest["image_sha256"] = {name: digest(destination / name) for name in sources}
    manifest["status"] = "PetaLinux build packaged; SD write and board boot NOT verified"
    (destination / "handoff.json").write_text(json.dumps(manifest, indent=2) + "\n")
    (destination / "SHA256SUMS").write_text("".join(f"{digest(destination / name)}  {name}\n" for name in sources))


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("action", choices=("verify", "stage"))
    parser.add_argument("project", type=Path)
    args = parser.parse_args()
    project = args.project.resolve(strict=True)
    if args.action == "stage":
        stage(project)
    else:
        verify(project)
        print("Verified: configured/imported XSA matches the Cortix handoff SHA256.")


if __name__ == "__main__":
    main()
