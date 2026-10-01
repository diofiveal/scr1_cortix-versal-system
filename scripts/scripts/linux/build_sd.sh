#!/usr/bin/env bash
# Build files for an SD card; NEVER format/write a block device here.
set -euo pipefail
if [[ $# != 1 ]]; then
    echo "Usage: bash build_sd.sh /absolute/path/to/new-petalinux-project" >&2
    exit 2
fi
if [[ ${PETALINUX_VER:-} != 2023.2 || $EUID == 0 ]]; then
    echo "Source PetaLinux 2023.2 settings.sh and run as a normal user." >&2
    exit 2
fi
project=$(realpath "$1")
script_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
python3 "$script_dir/handoff.py" verify "$project"
cd -- "$project"
petalinux-build
# Versal packages the imported Cortix PDI, PLM, PSM firmware, TF-A, U-Boot, DTB.
petalinux-package --boot --format BIN --plm --psmfw --u-boot --dtb --force
python3 "$script_dir/handoff.py" stage "$project"
echo "SD files prepared in $project/cortix-sd. No SD was written; boot is not yet verified."
