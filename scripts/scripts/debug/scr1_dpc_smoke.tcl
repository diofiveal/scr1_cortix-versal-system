# Read-only bring-up through native Versal DPC; no A72/Linux execution needed.
# First program the matching PDI and select the DPC target in XSDB:
#   connect -url tcp:127.0.0.1:3121
#   targets
#   targets <DPC-target-id>
#   source scripts/scripts/debug/scr1_dpc_smoke.tcl
# No reset, readiness write, LOAD or START command is issued here.
# A nonresponding AXI target can still block mrd: arm the ILA first.

proc scr1_dpc_read32 {address} {
    set value [string trim [mrd -value $address 1]]
    if {![regexp {^(0x)?[0-9a-fA-F]{1,8}$} $value]} {
        error "Invalid XSDB read at [format 0x%08X $address]: '$value'"
    }
    scan $value %x word
    return $word
}

proc scr1_dpc_smoke {} {
    # LPD aliases, not the A72 FPD addresses and not the SCR1 FFxx aliases.
    set base 0x80000000
    set id [scr1_dpc_read32 $base]
    if {$id != 0x5343544C} {
        error "Unexpected IP_ID [format 0x%08X $id]; check PDI, target and LPD route"
    }
    set hw [scr1_dpc_read32 [expr {$base + 0x0C}]]
    if {($hw & 0xFF) != 90} {
        error "HW_CONFIG reports [expr {$hw & 0xFF}] MHz, expected 90; stale hardware?"
    }
    foreach {name offset} {
        IP_ID 0x000 IP_VERSION 0x004 CAPABILITIES 0x008 HW_CONFIG 0x00C
        STATUS 0x014 START_TIMEOUT 0x028 QUIESCE_TIMEOUT 0x02C
        WATCHDOG_CFG 0x030 FAULT_CODE 0x040 OUTSTANDING 0x050
    } {
        puts [format "%-16s 0x%08X" $name [scr1_dpc_read32 [expr {$base + $offset}]]]
    }
    puts "Control read test passed; SCR1 has not been started."
}

if {![info exists ::scr1_dpc_library_only]} {scr1_dpc_smoke}
