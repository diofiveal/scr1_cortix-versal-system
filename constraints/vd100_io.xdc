# =============================================================================
# VD100 + SCR1 optional PL I/O constraints
# Device: xcve2302-sfva784-1LP-e-s
# Vivado: 2023.2
# =============================================================================
#
# The current minimal vd100_scr1_top exposes only:
#   - DDR4 pins                  -> vd100_ddr4.xdc
#   - differential 200 MHz clock -> vd100_clocks.xdc
#
# CIPS MIO / PMC MIO peripherals are configured inside Versal CIPS and must not
# be assigned here as ordinary PL PACKAGE_PIN constraints.
#
# Keep this file for future PL-side I/O such as LEDs, buttons, PL UART or
# dedicated debug pins. Do not invent PACKAGE_PIN/IOSTANDARD values: copy them
# from the VD100 schematic / ALINX reference for the exact connector or device.
# =============================================================================
