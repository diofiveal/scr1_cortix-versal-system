# SCR1 Cortix on ALINX VD100 / Versal VE2302

Vivado/PetaLinux 2023.2 platform with SCR1 at nominal 90 MHz, a reserved
16-MiB shared DDR window, native DPC access via a fourth SmartConnect master,
and Versal AXIS ILA instrumentation.

See [Linux bring-up and hardware debug](docs/linux_bringup.md) for the address
map, XSDB smoke test, ILA slots/probes, PDI/XSA/LTX generation, and verification
limits. [Software contract](include/scr1_platform.h) and
[SCR1 linker templates](firmware/linker) are provided for future drivers/firmware.

```sh
python3 scripts/scripts/checks/test_linux_integration.py
vivado -mode batch -source scripts/scripts/vivado/create_project.tcl
```

`create_project.tcl` builds the BD, synthesizes, routes, checks timing/DRC,
generates the Device Image, and exports matching `cortix_scr1.pdi`,
`cortix_scr1.xsa`, `cortix_scr1.ltx` plus reports to `build/hardware/`.
In an empty Vivado GUI session, use `source scripts/scripts/vivado/create_project.tcl`.
The project stays open. Subsequent builds retain previous projects and bundles.

Build Linux in an already running VM with SSH/key authentication (replace paths):

```sh
python3 scripts/scripts/linux/deploy_vm.py --host user@VM-IP --settings /home/user/petalinux/2023.2/settings.sh --vm-workdir /home/user/cortix-builds
```

This transfers versioned sources + hardware, checks the VM and hashes, runs
PetaLinux configuration/build/packaging, then retrieves verified `sd-output.zip`.
For VirtualBox shared folders use `--shared-dir /host/path/to/exchange` instead.
See [the VM workflow](docs/linux_bringup.md#автоматический-перенос-и-сборка-в-vm)
for requirements, logs, resume commands and ILA capture helpers.

Offline tests do not validate vendor IP, timing, the debug hub, or board boot.
Use the matching PDI/LTX from the new routed implementation.
