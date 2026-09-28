# =============================================================================
# VD100 + SCR1 project-specific timing constraints
# Device: xcve2302-sfva784-1LP-e-s
# Vivado: 2023.2
# =============================================================================
#
# Intentionally minimal for the first integration.
#
# 1. The 200 MHz board reference clock is defined in vd100_clocks.xdc.
# 2. Clock Wizard / NoC / CIPS generated clocks are constrained by their IP.
# 3. The current board top ties SCR1 rtc_clk to 1'b0, so there is no separate
#    asynchronous RTC clock domain to constrain in this revision.
# 4. No broad set_false_path or set_clock_groups exceptions are added here.
#    Such exceptions must only be introduced after report_timing_summary /
#    report_cdc demonstrates a real asynchronous relationship.
#
# This file is intentionally kept as a dedicated location for future,
# reviewed project-specific timing exceptions.
# =============================================================================
