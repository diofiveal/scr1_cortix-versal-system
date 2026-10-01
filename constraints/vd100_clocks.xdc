# =============================================================================
# ALINX VD100 external PL/DDR reference clock constraints
# Device: xcve2302-sfva784-1LP-e-s
# Vivado: 2023.2
#
# Board reference clock:
#   Differential 200 MHz
#   P pin: AB23
#   N pin: AC23
#
# Current vd100_scr1_top.sv port names:
#   sys_clk_clk_p[0]
#   sys_clk_clk_n[0]
#
# The Clock Wizard / AXI NoC generated clocks are constrained by their AMD IP.
# Do not add a second create_clock on the generated SCR1 PLL clock (~90 MHz).
# =============================================================================

set_property PACKAGE_PIN AB23 [get_ports {sys_clk_clk_p[0]}]
set_property PACKAGE_PIN AC23 [get_ports {sys_clk_clk_n[0]}]

set_property IOSTANDARD LVDS15 [get_ports {sys_clk_clk_p[0]}]
set_property IOSTANDARD LVDS15 [get_ports {sys_clk_clk_n[0]}]

# 200 MHz differential reference clock: 5.000 ns period.
# Constrain only the P side of the differential input pair.
create_clock -period 5.000 -name sys_clk_200m     -waveform {0.000 2.500} [get_ports {sys_clk_clk_p[0]}]
