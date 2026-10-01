# ALINX VD100 Linux board configuration

`course_s2_ps_config.tcl` is the board CIPS configuration below, with only a
final newline added (no configuration values changed):

- Repository: https://github.com/alinxalinx/VD100_2023.2
- Commit: `902446432c7d60a2968d96f8b02a7c57e00cc7e6`
- Path: `Demo/course_s2/vivado/auto_create_project/ps_config.tcl`

Origin/credit: ALINX. No new licence is assigned to this upstream file.
The upstream repository has no top-level licence file in this revision.

The Cortix overlay in `scripts/scripts/vivado/ps_config.tcl` keeps board MIO
and boot clocks, enables the 100 MHz PL source and SCR1 FPD master, and removes
unconnected course_s2 EMIO/video interfaces. The PMC and LPD native DDR paths
are preserved. NoC DDR timing values and SD/USB device-tree quirks are adapted
from that same pinned reference, not from generic evaluation boards.

This is a Linux-console/SD integration, not a copy of the complete camera/LCD
demo. Its old PDI/XSA, generated DT and video driver recipes must not be used
as the Cortix hardware description.
