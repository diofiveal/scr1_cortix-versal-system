# Reusable VIP

Protocol agents belong here. Planned VIP includes AXI4, AXI4-Lite,
clock/reset, IRQ, and reactive memory-slave support.

VIP is independent of SCR1 register names, fixed addresses, task opcodes, and
FSM states. A72, SCR1, and DPC use configured instances of shared source-aware
VIP. Multi-interface workflows belong in bench virtual sequences.
