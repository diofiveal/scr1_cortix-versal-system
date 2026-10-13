# UVM verification

This is the root of the scalable UVM environment for the VD100/SCR1 system.

Start with the approved specification and verification plan. The directory
architecture is defined in
[docs/verification/uvm_architecture.md](../../docs/verification/uvm_architecture.md).

## Layout

- `common/`: shared interfaces, types, transactions, and utilities.
- `vip/`: reusable physical-protocol agents.
- `rm/`: independent shared reference models.
- `benches/`: target-centric unit, subsystem, system, and platform benches.
- `cfg/`: project-level declarative configuration.
- `tools/`: compile, simulation, lint, and coverage helpers.
- `regressions/`: named regression manifests.
- `traceability/`: requirement mappings and retained run evidence.
- `build/`: generated local output; ignored by Git.

## Current status

The architecture and tracked skeleton are `IMPLEMENTED`. No UVM source has
been compiled or simulated yet, and no requirement is `VERIFIED`.
