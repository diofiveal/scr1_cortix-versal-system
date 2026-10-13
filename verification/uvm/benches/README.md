# DUT benches

All files specific to one DUT are colocated below its verification level:

- `unit/`: one block or FSM;
- `subsystem/`: connected RTL blocks;
- `system/`: complete PL system;
- `platform/`: future PS/PL/software integration.

The standard target layout is documented in
[docs/verification/uvm_architecture.md](../../../docs/verification/uvm_architecture.md).
Create subdirectories only when they contain real source, configuration, or
documentation.
