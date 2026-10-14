# P0 integration closure: Gateway v1.2, Boot Seal, reset, DTB
Status: DESIGN CONTRACT / IMPLEMENTATION OPEN. Reviewed 2026-10-14.
Scope: all 7 outstanding Platform Wrapper P0 integration gates.
The approved L0 and five L1 specifications remain authoritative.

## P0-01 Gateway v1.2
Separate PHYSICAL FPD(A72, SOURCE_ID=01), DMEM(SCR1, 10), LPD(Debug, 11) ingresses before any source-erasing SmartConnect merge. SOURCE_ID=00 is invalid. SCR1 IMEM uses a separate dedicated READ-ONLY Boot path without changing 2-bit encoding. Never infer source from AXI ID or USER. Latch AW and AR context independently with origin, owner epoch, original ID/len, target and parent-child fragment ledger. Block all bypass routes to Control, Boot and Shared BRAM. FPD 128->32 AXI conversion must preserve upstream beat count and B/R response identity.

Protected targets: Control 0xA4000000 size 0x1000, Boot 0xA4010000 size 0x10000, Shared BRAM 0xA4030000 size 0x10000. SCR1 local Control 0xFF000000 and Boot 0xFFFF0000 are aliases only. Debug Boot/Shared access denied. Debug Control must be an explicit read-only diagnostic whitelist.

## P0-02 Boot Seal CSR ABI, proposed encoding
Retain legacy 0x000..0x074 and Task CSR 0x080..0x0B0 unchanged. Add:
- 0x0B4 BOOT_SEAL_CTRL: A72-only WO, WDATA=1 and WSTRB=0001 accepted COMMIT pulse; reserved combinations denied SLVERR.
- 0x0B8 BOOT_SEAL_STATUS: RO bit0 LOAD_OPEN, bit1 SEAL_PENDING, bit2 WRITE_DRAIN_DONE, bit3 IMAGE_READY, bit4 BOOT_FAULT_LOCK, bit5 HOST_VALIDATION_REPORTED; upper bits zero.
- 0x0BC BOOT_IMAGE_EPOCH: RO, image/load generation; never reuse generation with live old writes.

Host readback and software CRC are a TRUSTED-HOST ATTESTATION, NOT hardware-computed CRC or cryptographic secure boot. Valid COMMIT requires completed host B responses, exact readback compare, validated descriptor, correct state, and no fault. COMMIT B response acknowledges command acceptance only, never complete Boot drain. Software polls IMAGE_READY before Lifecycle START.

Seal is an atomic cut-over at the gateway physical Boot AW admission frontier: new AW denied, AW previously admitted with saved authorized epoch may finish W/physical byte writes/B responses. SEAL wins an exactly simultaneous admission race. IMAGE_READY requires verified host report, closed admission, matched epoch, complete Gateway parent/child and physical Boot writes and original B handshakes, nonfaulted fabric. LOAD rearm requires safe quiescence, increments image epoch and invalidates previous image without clearing RAM. CPU reset NEVER reopens Boot write permission.

**Encoding requires ABI owner approval and coordinated implementation:** scr1_regs_pkg.sv, CSR SOURCE_ID guard, Gateway FSM, Boot L1, Linux/FW headers and IP_VERSION. NO RTL implementing these CSRs is currently claimed.

## P0-03 Vivado evidence
Run scripts/scripts/vivado/report_axi_interfaces.tcl inside a real open Vivado 2023.2 Block Design and archive CIPS M_AXI_FPD/M_AXI_LPD DATA/ADDR/ID widths, protocol and converter pins. Actual values are unknown until this run. Also validate_bd_design, compile generated HDL, check AXI burst converters and 128->32 preservation.

## P0-04 CPU-only reset
Stop new SCR1 admission but do not erase Gateway/NoC/SmartConnect context. HALT/QUIESCE resets CPU only after internal core idle PLUS IMEM/DMEM R/B, all Gateway parent/child transactions and affected BRAM drains are complete. Fatal handling must fail-closed: preserve protocol via live isolation bridge or perform a PROVEN coherent reset of affected fabric; no fake B/R responses or forced owner changes. PLL lock loss disables fresh admission. Current SCR1 passthrough and FAULT reset need implementation/proof.

## P0-05 No bypass
The current legacy pl_config.tcl wires FPD+IMEM+DMEM+LPD to smartconnect_0 and connects M01/M02 directly to Control/Boot. Current address_map.tcl also maps LPD Debug Boot. These must be eliminated. For every physical master, prove all paths to protected targets traverse the trusted gate before identity is lost. Negative transactions and generated-BD cut-set required.

## P0-06 Shared DDR Linux
The versioned system-user.dtsi ALREADY reserves 0x7F000000 size 0x01000000 with no-map and prepare_petalinux.py copies it. SOURCE PRESENT, not DTB/BOOT VERIFIED. Validate the compiled DTB and the live /sys/firmware/devicetree/base via scripts/scripts/linux/verify_reserved_memory.py. no-map does not solve CPU cache coherency.

## P0-07 Cross-module completion contracts
boot_write_drain_done: complete Gateway Boot parent B handshakes, child AXI-Lite writes, old AW/W, physical WE and matching image epoch. Never infer from local outstanding=0.
boot_image_ready: authorized sealed host validation + boot_write_drain_done + nonfaulted fabric + valid image configuration/current epoch; prerequisite to Lifecycle READY/START.
shared_drain_complete: all old-owner upstream RLAST/B handshakes and Gateway daughter fragments/physical writes complete, ownership epoch still consistent. New ACK and RESULT_READY forbidden before proof.
gateway_ready: clocks and fabric queues actually initialized; not software GPIO.
fabric_operational: actual hardware reset/clock/guards ready; advisory GPIO alone cannot override FAULT_LOCK.

## Evidence and no-false-PASS policy
P0-01: OPEN RTL/UVM/BD.
P0-02: proposed ABI documented; RTL+headers OPEN.
P0-03: NEEDS REAL VIVADO.
P0-04: OPEN RTL+ASSERTIONS+SIM LOGS.
P0-05: FAIL current legacy BD, needs rebuilt cut-set proof.
P0-06: SOURCE PRESENT, LIVE DTB NOT VERIFIED.
P0-07: CONTRACT DOCUMENTED, RTL/SVA OPEN.

Never mark VERIFIED from scripts alone. For P0 closure retain real Vivado reports, DUT/UVM traces, independent physical WE checks, actual final DTB and Linux boot evidence.
