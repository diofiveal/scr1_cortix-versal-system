`ifndef SCR1_ARCH_CUSTOM_SVH
`define SCR1_ARCH_CUSTOM_SVH
//------------------------------------------------------------------------------
// VD100 + SCR1 custom architecture configuration
//
// Target:
//   ALINX VD100 / AMD Versal VE2302
//   xcve2302-sfva784-1LP-e-s
//
// This file is included by scr1_arch_description.svh when SCR1_ARCH_CUSTOM
// is defined by the Vivado project.
//
// Memory map used by the VD100 SCR1 integration:
//   Boot BRAM : 0xFFFF_0000 - 0xFFFF_FFFF
//   TCM       : 0xF000_0000 - 0xF000_FFFF
//   Timer     : 0xF004_0000 - 0xF004_001F
//
// SCR1 core clock:
//   100 MHz
//------------------------------------------------------------------------------

//------------------------------------------------------------------------------
// Platform identification
//------------------------------------------------------------------------------
// Project-local identifiers. They are informational and may be changed when a
// formal platform/build numbering scheme is introduced.
`define SCR1_PTFM_SOC_ID            32'h5644_3130
`define SCR1_PTFM_BLD_ID            32'h2026_0927

// SCR1 clock frequency in Hz.
`define SCR1_PTFM_CORE_CLK_FREQ     32'd100000000

//------------------------------------------------------------------------------
// FPGA target
//------------------------------------------------------------------------------
`define SCR1_TRGT_FPGA_XILINX

//------------------------------------------------------------------------------
// Recommended SCR1 architecture configuration
//------------------------------------------------------------------------------
// This matches the current integration target:
// RV32IMC + debug + TDU + IPIC + TCM + BPU + IMEM skid buffer.
`define SCR1_CFG_RV32IMC_MAX

//------------------------------------------------------------------------------
// Reset / trap-vector addresses
//------------------------------------------------------------------------------

// SCR1 starts from the first byte of the 64 KiB Boot BRAM.
parameter bit [`SCR1_XLEN-1:0] SCR1_ARCH_RST_VECTOR =
    32'hFFFF_0000;

// Reset MTVEC is placed inside Boot BRAM and kept naturally aligned.
// 0xFFFF_0080 leaves the reset entry area at 0xFFFF_0000 available for the
// initial boot sequence while keeping the trap vector in the same protected
// Boot BRAM window.
parameter bit [`SCR1_XLEN-1:0] SCR1_ARCH_MTVEC_BASE =
    32'hFFFF_0080;

//------------------------------------------------------------------------------
// TCM
//------------------------------------------------------------------------------
// 64 KiB window:
//   mask    = 0xFFFF_0000
//   pattern = 0xF000_0000
parameter bit [`SCR1_DMEM_AWIDTH-1:0] SCR1_TCM_ADDR_MASK =
    32'hFFFF_0000;

parameter bit [`SCR1_DMEM_AWIDTH-1:0] SCR1_TCM_ADDR_PATTERN =
    32'hF000_0000;

//------------------------------------------------------------------------------
// SCR1 timer
//------------------------------------------------------------------------------
// Native SCR1 timer occupies 32 bytes at 0xF004_0000.
parameter bit [`SCR1_DMEM_AWIDTH-1:0] SCR1_TIMER_ADDR_MASK =
    32'hFFFF_FFE0;

parameter bit [`SCR1_DMEM_AWIDTH-1:0] SCR1_TIMER_ADDR_PATTERN =
    32'hF004_0000;

`endif // SCR1_ARCH_CUSTOM_SVH
