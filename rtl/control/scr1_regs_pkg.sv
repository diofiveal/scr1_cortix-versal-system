package scr1_regs_pkg;

    import vd100_scr1_pkg::*;

    // =========================================================================
    // Register interface geometry
    // =========================================================================
    //
    // scr1_control occupies one 4-KiB local AXI4-Lite window.
    //
    // 2^12 = 4096 bytes
    // AXI-Lite data width = 32 bits = 4 bytes
    // All registers are 32-bit aligned.
    // =========================================================================

    localparam int unsigned SCR1_REG_ADDR_WIDTH   = 12;
    localparam int unsigned SCR1_REG_DATA_WIDTH   = 32;
    localparam int unsigned SCR1_REG_STRB_WIDTH   =
        SCR1_REG_DATA_WIDTH / 8;

    localparam int unsigned SCR1_REG_WORD_BYTES   = 4;
    localparam int unsigned SCR1_REG_WINDOW_BYTES =
        1 << SCR1_REG_ADDR_WIDTH;

    typedef logic [SCR1_REG_ADDR_WIDTH-1:0] scr1_reg_addr_t;
    typedef logic [SCR1_REG_DATA_WIDTH-1:0] scr1_reg_data_t;


    // =========================================================================
    // Register offsets
    // =========================================================================
    //
    // These are LOCAL offsets inside the 4-KiB scr1_control window.
    //
    // Do NOT place the A72 physical base address here.
    // Do NOT place the SCR1-visible physical base address here.
    // =========================================================================

    localparam scr1_reg_addr_t SCR1_REG_IP_ID              = 12'h000;
    localparam scr1_reg_addr_t SCR1_REG_IP_VERSION         = 12'h004;
    localparam scr1_reg_addr_t SCR1_REG_CAPABILITIES       = 12'h008;
    localparam scr1_reg_addr_t SCR1_REG_HW_CONFIG          = 12'h00C;

    localparam scr1_reg_addr_t SCR1_REG_CONTROL            = 12'h010;
    localparam scr1_reg_addr_t SCR1_REG_STATUS             = 12'h014;

    localparam scr1_reg_addr_t SCR1_REG_BOOT_ADDR          = 12'h018;
    localparam scr1_reg_addr_t SCR1_REG_FW_DESC_ADDR       = 12'h01C;
    localparam scr1_reg_addr_t SCR1_REG_FW_DESC_SIZE       = 12'h020;
    localparam scr1_reg_addr_t SCR1_REG_START_TOKEN        = 12'h024;

    localparam scr1_reg_addr_t SCR1_REG_START_TIMEOUT      = 12'h028;
    localparam scr1_reg_addr_t SCR1_REG_QUIESCE_TIMEOUT    = 12'h02C;

    localparam scr1_reg_addr_t SCR1_REG_WATCHDOG_CFG       = 12'h030;
    localparam scr1_reg_addr_t SCR1_REG_WATCHDOG_KICK      = 12'h034;

    localparam scr1_reg_addr_t SCR1_REG_IRQ_STATUS         = 12'h038;
    localparam scr1_reg_addr_t SCR1_REG_IRQ_ENABLE         = 12'h03C;

    localparam scr1_reg_addr_t SCR1_REG_FAULT_CODE         = 12'h040;
    localparam scr1_reg_addr_t SCR1_REG_FAULT_PC           = 12'h044;
    localparam scr1_reg_addr_t SCR1_REG_FAULT_INFO0        = 12'h048;
    localparam scr1_reg_addr_t SCR1_REG_FAULT_INFO1        = 12'h04C;

    localparam scr1_reg_addr_t SCR1_REG_OUTSTANDING        = 12'h050;
    localparam scr1_reg_addr_t SCR1_REG_HEARTBEAT          = 12'h054;

    localparam scr1_reg_addr_t SCR1_REG_CYCLE_LO           = 12'h058;
    localparam scr1_reg_addr_t SCR1_REG_CYCLE_HI           = 12'h05C;

    localparam scr1_reg_addr_t SCR1_REG_BOOT_CRC_EXPECTED  = 12'h060;
    localparam scr1_reg_addr_t SCR1_REG_BOOT_CRC_OBSERVED  = 12'h064;

    localparam scr1_reg_addr_t SCR1_REG_SW_STATUS          = 12'h068;
    localparam scr1_reg_addr_t SCR1_REG_SW_ERROR           = 12'h06C;

    localparam scr1_reg_addr_t SCR1_REG_SCRATCH0           = 12'h070;
    localparam scr1_reg_addr_t SCR1_REG_SCRATCH1           = 12'h074;

    // 0x078 - 0xFFC reserved for future register ABI extensions
    localparam scr1_reg_addr_t SCR1_REG_RESERVED_BASE      = 12'h078;


    // =========================================================================
    // CONTROL register
    // =========================================================================
    //
    // Offset: 0x010
    //
    // Write-only / pulse-style commands.
    // Each accepted command generates a one-shot lifecycle event.
    // =========================================================================

    localparam int unsigned SCR1_CONTROL_LOAD_BIT        = 0;
    localparam int unsigned SCR1_CONTROL_START_BIT       = 1;
    localparam int unsigned SCR1_CONTROL_QUIESCE_BIT     = 2;
    localparam int unsigned SCR1_CONTROL_HALT_BIT        = 3;
    localparam int unsigned SCR1_CONTROL_SOFT_RESET_BIT  = 4;
    localparam int unsigned SCR1_CONTROL_CLEAR_FAULT_BIT = 5;

    localparam scr1_reg_data_t SCR1_CONTROL_LOAD_MASK =
        32'h0000_0001;

    localparam scr1_reg_data_t SCR1_CONTROL_START_MASK =
        32'h0000_0002;

    localparam scr1_reg_data_t SCR1_CONTROL_QUIESCE_MASK =
        32'h0000_0004;

    localparam scr1_reg_data_t SCR1_CONTROL_HALT_MASK =
        32'h0000_0008;

    localparam scr1_reg_data_t SCR1_CONTROL_SOFT_RESET_MASK =
        32'h0000_0010;

    localparam scr1_reg_data_t SCR1_CONTROL_CLEAR_FAULT_MASK =
        32'h0000_0020;

    // Bits [5:0] are currently defined.
    localparam scr1_reg_data_t SCR1_CONTROL_VALID_MASK =
        32'h0000_003F;


    // =========================================================================
    // STATUS register
    // =========================================================================
    //
    // Offset: 0x014
    // Read-only hardware status.
    // =========================================================================

    localparam int unsigned SCR1_STATUS_STATE_LSB = 0;
    localparam int unsigned SCR1_STATUS_STATE_MSB =
        SCR1_STATUS_STATE_LSB + SCR1_LIFECYCLE_STATE_WIDTH - 1;

    localparam int unsigned SCR1_STATUS_DEPENDENCIES_READY_BIT = 4;
    localparam int unsigned SCR1_STATUS_IMAGE_VALID_BIT        = 5;
    localparam int unsigned SCR1_STATUS_RUNNING_BIT            = 6;
    localparam int unsigned SCR1_STATUS_HALTED_BIT             = 7;
    localparam int unsigned SCR1_STATUS_FAULT_BIT              = 8;
    localparam int unsigned SCR1_STATUS_AXI_QUIESCENT_BIT      = 9;
    localparam int unsigned SCR1_STATUS_BOOT_WRITE_ALLOWED_BIT = 10;
    localparam int unsigned SCR1_STATUS_VERIFIER_READY_BIT     = 11;
    localparam int unsigned SCR1_STATUS_COMPLETION_PENDING_BIT = 12;

    localparam scr1_reg_data_t SCR1_STATUS_STATE_MASK =
        32'h0000_000F;

    localparam scr1_reg_data_t SCR1_STATUS_DEPENDENCIES_READY_MASK =
        32'h0000_0010;

    localparam scr1_reg_data_t SCR1_STATUS_IMAGE_VALID_MASK =
        32'h0000_0020;

    localparam scr1_reg_data_t SCR1_STATUS_RUNNING_MASK =
        32'h0000_0040;

    localparam scr1_reg_data_t SCR1_STATUS_HALTED_MASK =
        32'h0000_0080;

    localparam scr1_reg_data_t SCR1_STATUS_FAULT_MASK =
        32'h0000_0100;

    localparam scr1_reg_data_t SCR1_STATUS_AXI_QUIESCENT_MASK =
        32'h0000_0200;

    localparam scr1_reg_data_t SCR1_STATUS_BOOT_WRITE_ALLOWED_MASK =
        32'h0000_0400;

    localparam scr1_reg_data_t SCR1_STATUS_VERIFIER_READY_MASK =
        32'h0000_0800;

    localparam scr1_reg_data_t SCR1_STATUS_COMPLETION_PENDING_MASK =
        32'h0000_1000;

    // Bits [12:0] are currently defined.
    localparam scr1_reg_data_t SCR1_STATUS_VALID_MASK =
        32'h0000_1FFF;


    // =========================================================================
    // IRQ_STATUS / IRQ_ENABLE
    // =========================================================================
    //
    // IRQ_STATUS is sticky.
    // IRQ_STATUS uses W1C semantics.
    //
    // irq_to_a72 = |(IRQ_STATUS & IRQ_ENABLE)
    // =========================================================================

    localparam int unsigned SCR1_IRQ_SW_READY_BIT         = 0;
    localparam int unsigned SCR1_IRQ_APP_DONE_BIT         = 1;
    localparam int unsigned SCR1_IRQ_FAULT_BIT            = 2;
    localparam int unsigned SCR1_IRQ_WATCHDOG_TIMEOUT_BIT = 3;
    localparam int unsigned SCR1_IRQ_START_TIMEOUT_BIT    = 4;
    localparam int unsigned SCR1_IRQ_QUIESCE_TIMEOUT_BIT  = 5;
    localparam int unsigned SCR1_IRQ_AXI_ERROR_BIT        = 6;
    localparam int unsigned SCR1_IRQ_SW_EVENT_BIT         = 7;

    localparam scr1_reg_data_t SCR1_IRQ_SW_READY_MASK =
        32'h0000_0001;

    localparam scr1_reg_data_t SCR1_IRQ_APP_DONE_MASK =
        32'h0000_0002;

    localparam scr1_reg_data_t SCR1_IRQ_FAULT_MASK =
        32'h0000_0004;

    localparam scr1_reg_data_t SCR1_IRQ_WATCHDOG_TIMEOUT_MASK =
        32'h0000_0008;

    localparam scr1_reg_data_t SCR1_IRQ_START_TIMEOUT_MASK =
        32'h0000_0010;

    localparam scr1_reg_data_t SCR1_IRQ_QUIESCE_TIMEOUT_MASK =
        32'h0000_0020;

    localparam scr1_reg_data_t SCR1_IRQ_AXI_ERROR_MASK =
        32'h0000_0040;

    localparam scr1_reg_data_t SCR1_IRQ_SW_EVENT_MASK =
        32'h0000_0080;

    localparam scr1_reg_data_t SCR1_IRQ_VALID_MASK =
        32'h0000_00FF;


    // =========================================================================
    // Event -> IRQ_STATUS mapping
    // =========================================================================
    //
    // scr1_event_e encoding and IRQ_STATUS bit positions are intentionally
    // independent.
    //
    // Example:
    //
    //   SCR1_EVENT_APP_DONE = 4'h2
    //
    // but APP_DONE is IRQ_STATUS[1].
    // =========================================================================

    function automatic scr1_reg_data_t scr1_event_to_irq_mask(
        input scr1_event_e event_i
    );

        begin
            case (event_i)

                SCR1_EVENT_SW_READY:
                    scr1_event_to_irq_mask =
                        SCR1_IRQ_SW_READY_MASK;

                SCR1_EVENT_APP_DONE:
                    scr1_event_to_irq_mask =
                        SCR1_IRQ_APP_DONE_MASK;

                SCR1_EVENT_FAULT:
                    scr1_event_to_irq_mask =
                        SCR1_IRQ_FAULT_MASK;

                SCR1_EVENT_WATCHDOG_TIMEOUT:
                    scr1_event_to_irq_mask =
                        SCR1_IRQ_WATCHDOG_TIMEOUT_MASK;

                SCR1_EVENT_START_TIMEOUT:
                    scr1_event_to_irq_mask =
                        SCR1_IRQ_START_TIMEOUT_MASK;

                SCR1_EVENT_QUIESCE_TIMEOUT:
                    scr1_event_to_irq_mask =
                        SCR1_IRQ_QUIESCE_TIMEOUT_MASK;

                SCR1_EVENT_AXI_ERROR:
                    scr1_event_to_irq_mask =
                        SCR1_IRQ_AXI_ERROR_MASK;

                SCR1_EVENT_SW_EVENT:
                    scr1_event_to_irq_mask =
                        SCR1_IRQ_SW_EVENT_MASK;

                SCR1_EVENT_NONE:
                    scr1_event_to_irq_mask =
                        '0;

                default:
                    scr1_event_to_irq_mask =
                        '0;

            endcase
        end

    endfunction


    // =========================================================================
    // IP identification / ABI version
    // =========================================================================
    //
    // IP_ID is the ASCII magic "SCTL" (SCR1 ConTroL).
    // IP_VERSION encoding:
    //   [31:24] MAJOR
    //   [23:16] MINOR
    //   [15:0]  PATCH
    //
    // Any incompatible register ABI change must increment MAJOR.
    // Backward-compatible additions increment MINOR.
    // PATCH is for fixes that do not change the ABI contract.
    // =========================================================================

    localparam scr1_reg_data_t SCR1_IP_ID_VALUE =
        32'h5343_544C; // ASCII "SCTL"

    localparam int unsigned SCR1_IP_VERSION_MAJOR_LSB = 24;
    localparam int unsigned SCR1_IP_VERSION_MINOR_LSB = 16;
    localparam int unsigned SCR1_IP_VERSION_PATCH_LSB = 0;

    localparam int unsigned SCR1_IP_VERSION_MAJOR_WIDTH = 8;
    localparam int unsigned SCR1_IP_VERSION_MINOR_WIDTH = 8;
    localparam int unsigned SCR1_IP_VERSION_PATCH_WIDTH = 16;

    localparam int unsigned SCR1_IP_VERSION_MAJOR = 1;
    localparam int unsigned SCR1_IP_VERSION_MINOR = 0;
    localparam int unsigned SCR1_IP_VERSION_PATCH = 0;

    localparam scr1_reg_data_t SCR1_IP_VERSION_VALUE =
        32'h0100_0000; // v1.0.0


    // =========================================================================
    // CAPABILITIES register
    // =========================================================================
    //
    // Offset: 0x008, read-only.
    //
    // A bit is 1 only if that feature is actually present in the bitstream.
    // The register bank should assemble CAPABILITIES from these masks and the
    // compile-time/integration configuration; the package freezes only the ABI.
    // =========================================================================

    localparam int unsigned SCR1_CAP_WATCHDOG_BIT          = 0;
    localparam int unsigned SCR1_CAP_BOOT_CRC_REGS_BIT     = 1;
    localparam int unsigned SCR1_CAP_VERIFIER_IF_BIT       = 2;
    localparam int unsigned SCR1_CAP_SW_STATUS_BIT         = 3;
    localparam int unsigned SCR1_CAP_AXI_MONITOR_BIT       = 4;
    localparam int unsigned SCR1_CAP_BOOT_GUARD_BIT        = 5;
    localparam int unsigned SCR1_CAP_IRQ_TO_SCR1_BIT       = 6;
    localparam int unsigned SCR1_CAP_R5_EVENTS_BIT         = 7;
    localparam int unsigned SCR1_CAP_CYCLE_COUNTER_64_BIT  = 8;
    localparam int unsigned SCR1_CAP_FIRST_FAULT_BIT       = 9;

    localparam scr1_reg_data_t SCR1_CAP_WATCHDOG_MASK =
        32'h0000_0001;
    localparam scr1_reg_data_t SCR1_CAP_BOOT_CRC_REGS_MASK =
        32'h0000_0002;
    localparam scr1_reg_data_t SCR1_CAP_VERIFIER_IF_MASK =
        32'h0000_0004;
    localparam scr1_reg_data_t SCR1_CAP_SW_STATUS_MASK =
        32'h0000_0008;
    localparam scr1_reg_data_t SCR1_CAP_AXI_MONITOR_MASK =
        32'h0000_0010;
    localparam scr1_reg_data_t SCR1_CAP_BOOT_GUARD_MASK =
        32'h0000_0020;
    localparam scr1_reg_data_t SCR1_CAP_IRQ_TO_SCR1_MASK =
        32'h0000_0040;
    localparam scr1_reg_data_t SCR1_CAP_R5_EVENTS_MASK =
        32'h0000_0080;
    localparam scr1_reg_data_t SCR1_CAP_CYCLE_COUNTER_64_MASK =
        32'h0000_0100;
    localparam scr1_reg_data_t SCR1_CAP_FIRST_FAULT_MASK =
        32'h0000_0200;

    localparam scr1_reg_data_t SCR1_CAP_VALID_MASK =
        32'h0000_03FF;


    // =========================================================================
    // HW_CONFIG register
    // =========================================================================
    //
    // Offset: 0x00C, read-only.
    //
    // [7:0]   control clock frequency in MHz
    // [15:8]  AXI4-Lite local address width in bits
    // [23:16] AXI4-Lite data width in bytes
    // [27:24] outstanding-counter width used by control/monitor interface
    // [28]    VERIFY_REQUIRED build/integration policy
    // [31:29] reserved, read as zero
    // =========================================================================

    localparam int unsigned SCR1_HWCFG_CLK_MHZ_LSB          = 0;
    localparam int unsigned SCR1_HWCFG_AXIL_ADDR_WIDTH_LSB  = 8;
    localparam int unsigned SCR1_HWCFG_AXIL_DATA_BYTES_LSB  = 16;
    localparam int unsigned SCR1_HWCFG_OUTSTANDING_WIDTH_LSB = 24;
    localparam int unsigned SCR1_HWCFG_VERIFY_REQUIRED_BIT  = 28;

    localparam scr1_reg_data_t SCR1_HWCFG_CLK_MHZ_MASK =
        32'h0000_00FF;
    localparam scr1_reg_data_t SCR1_HWCFG_AXIL_ADDR_WIDTH_MASK =
        32'h0000_FF00;
    localparam scr1_reg_data_t SCR1_HWCFG_AXIL_DATA_BYTES_MASK =
        32'h00FF_0000;
    localparam scr1_reg_data_t SCR1_HWCFG_OUTSTANDING_WIDTH_MASK =
        32'h0F00_0000;
    localparam scr1_reg_data_t SCR1_HWCFG_VERIFY_REQUIRED_MASK =
        32'h1000_0000;
    localparam scr1_reg_data_t SCR1_HWCFG_VALID_MASK =
        32'h1FFF_FFFF;

    localparam int unsigned SCR1_CONTROL_CLK_MHZ_V1 = 100;

    function automatic scr1_reg_data_t scr1_make_hw_config(
        input int unsigned outstanding_width_i,
        input bit          verify_required_i
    );
        scr1_reg_data_t value;
        begin
            value = '0;
            value[7:0]   = SCR1_CONTROL_CLK_MHZ_V1;
            value[15:8]  = SCR1_REG_ADDR_WIDTH;
            value[23:16] = SCR1_REG_DATA_WIDTH / 8;
            value[27:24] = outstanding_width_i;
            value[28]    = verify_required_i;
            scr1_make_hw_config = value;
        end
    endfunction


    // =========================================================================
    // START_TIMEOUT / QUIESCE_TIMEOUT
    // =========================================================================
    //
    // Units are control-clock cycles (100 MHz in v1).
    // A programmed value of 0 disables the corresponding timeout.
    //
    // V1 defaults:
    //   START_TIMEOUT   = 10,000,000 cycles = 100 ms @ 100 MHz
    //   QUIESCE_TIMEOUT =    100,000 cycles =   1 ms @ 100 MHz
    //
    // These defaults are intentionally generous compared with normal bare-metal
    // start/drain latency while still preventing an infinite lifecycle stall.
    // =========================================================================

    localparam scr1_reg_data_t SCR1_START_TIMEOUT_RESET_VALUE =
        32'd10_000_000;

    localparam scr1_reg_data_t SCR1_QUIESCE_TIMEOUT_RESET_VALUE =
        32'd100_000;


    // =========================================================================
    // WATCHDOG_CFG register
    // =========================================================================
    //
    // Offset: 0x030, read/write.
    //
    // [30:0] watchdog period in control-clock cycles
    // [31]   watchdog enable
    //
    // period=0 while enable=1 is treated as an invalid configuration by the
    // register/lifecycle logic and should return SLVERR on the write.
    //
    // Reset default keeps watchdog disabled but preloads a 1-second period.
    // =========================================================================

    localparam int unsigned SCR1_WATCHDOG_PERIOD_LSB   = 0;
    localparam int unsigned SCR1_WATCHDOG_PERIOD_MSB   = 30;
    localparam int unsigned SCR1_WATCHDOG_ENABLE_BIT   = 31;

    localparam scr1_reg_data_t SCR1_WATCHDOG_PERIOD_MASK =
        32'h7FFF_FFFF;
    localparam scr1_reg_data_t SCR1_WATCHDOG_ENABLE_MASK =
        32'h8000_0000;
    localparam scr1_reg_data_t SCR1_WATCHDOG_VALID_MASK =
        32'hFFFF_FFFF;

    localparam scr1_reg_data_t SCR1_WATCHDOG_PERIOD_DEFAULT_CYCLES =
        32'd100_000_000;

    localparam scr1_reg_data_t SCR1_WATCHDOG_CFG_RESET_VALUE =
        SCR1_WATCHDOG_PERIOD_DEFAULT_CYCLES; // enable=0


    // =========================================================================
    // OUTSTANDING register
    // =========================================================================
    //
    // Offset: 0x050, read-only.
    //
    // The software-visible ABI deliberately allocates four bits per counter,
    // even though the current monitor uses OUTSTANDING_WIDTH=2. This allows a
    // future increase up to 15 outstanding transactions without moving fields.
    //
    // [3:0]   IMEM read outstanding
    // [7:4]   DMEM read outstanding
    // [11:8]  DMEM write outstanding
    // [31:12] reserved, read as zero
    // =========================================================================

    localparam int unsigned SCR1_OUTSTANDING_FIELD_WIDTH = 4;

    localparam int unsigned SCR1_OUTSTANDING_IMEM_RD_LSB = 0;
    localparam int unsigned SCR1_OUTSTANDING_IMEM_RD_MSB = 3;
    localparam int unsigned SCR1_OUTSTANDING_DMEM_RD_LSB = 4;
    localparam int unsigned SCR1_OUTSTANDING_DMEM_RD_MSB = 7;
    localparam int unsigned SCR1_OUTSTANDING_DMEM_WR_LSB = 8;
    localparam int unsigned SCR1_OUTSTANDING_DMEM_WR_MSB = 11;

    localparam scr1_reg_data_t SCR1_OUTSTANDING_IMEM_RD_MASK =
        32'h0000_000F;
    localparam scr1_reg_data_t SCR1_OUTSTANDING_DMEM_RD_MASK =
        32'h0000_00F0;
    localparam scr1_reg_data_t SCR1_OUTSTANDING_DMEM_WR_MASK =
        32'h0000_0F00;
    localparam scr1_reg_data_t SCR1_OUTSTANDING_VALID_MASK =
        32'h0000_0FFF;


    // =========================================================================
    // SCR1_SW_STATUS software ABI
    // =========================================================================
    //
    // Offset: 0x068.
    // Low byte is the frozen v1 software-status code. Bits [31:8] are reserved
    // and must be written as zero in v1.
    //
    // SW_STATUS is intentionally coarse. Detailed errors belong in SW_ERROR;
    // bulk completion information belongs in the DDR completion record.
    // =========================================================================

    localparam int unsigned SCR1_SW_STATUS_CODE_LSB   = 0;
    localparam int unsigned SCR1_SW_STATUS_CODE_MSB   = 7;
    localparam scr1_reg_data_t SCR1_SW_STATUS_CODE_MASK =
        32'h0000_00FF;

    typedef enum logic [7:0] {
        SCR1_SW_STATUS_IDLE         = 8'h00,
        SCR1_SW_STATUS_BOOT_ENTERED = 8'h01,
        SCR1_SW_STATUS_READY        = 8'h02,
        SCR1_SW_STATUS_APP_RUNNING  = 8'h03,
        SCR1_SW_STATUS_APP_DONE     = 8'h04,
        SCR1_SW_STATUS_APP_ERROR    = 8'h05
    } scr1_sw_status_e;

    // SW_ERROR is an opaque 32-bit software-defined error code in v1.
    // 0 means no software-reported error.
    localparam scr1_reg_data_t SCR1_SW_ERROR_NONE =
        32'h0000_0000;


    // =========================================================================
    // BOOT_ADDR policy
    // =========================================================================
    //
    // BOOT_ADDR (offset 0x018) is read-only and reports the platform reset
    // vector. Its numeric value is NOT duplicated in this register package.
    // For the current VD100 platform the expected value is 0xFFFF_0000, but the
    // RTL must source that value from the common platform/address manifest.
    // =========================================================================


    // =========================================================================
    // Register reset defaults
    // =========================================================================

    localparam scr1_reg_data_t SCR1_FW_DESC_ADDR_RESET_VALUE =
        32'h0000_0000;

    localparam scr1_reg_data_t SCR1_FW_DESC_SIZE_RESET_VALUE =
        32'h0000_0000;

    localparam scr1_reg_data_t SCR1_START_TOKEN_RESET_VALUE =
        32'h0000_0000;

    localparam scr1_reg_data_t SCR1_IRQ_STATUS_RESET_VALUE =
        32'h0000_0000;

    localparam scr1_reg_data_t SCR1_IRQ_ENABLE_RESET_VALUE =
        32'h0000_0000;

    localparam scr1_reg_data_t SCR1_FAULT_CODE_RESET_VALUE =
        32'h0000_0000;

    localparam scr1_reg_data_t SCR1_FAULT_PC_RESET_VALUE =
        32'h0000_0000;

    localparam scr1_reg_data_t SCR1_FAULT_INFO0_RESET_VALUE =
        32'h0000_0000;

    localparam scr1_reg_data_t SCR1_FAULT_INFO1_RESET_VALUE =
        32'h0000_0000;

    localparam scr1_reg_data_t SCR1_HEARTBEAT_RESET_VALUE =
        32'h0000_0000;

    localparam scr1_reg_data_t SCR1_CYCLE_LO_RESET_VALUE =
        32'h0000_0000;

    localparam scr1_reg_data_t SCR1_CYCLE_HI_RESET_VALUE =
        32'h0000_0000;

    localparam scr1_reg_data_t SCR1_BOOT_CRC_EXPECTED_RESET_VALUE =
        32'h0000_0000;

    localparam scr1_reg_data_t SCR1_BOOT_CRC_OBSERVED_RESET_VALUE =
        32'h0000_0000;

    localparam scr1_reg_data_t SCR1_SW_STATUS_RESET_VALUE =
        32'h0000_0000;

    localparam scr1_reg_data_t SCR1_SW_ERROR_RESET_VALUE =
        32'h0000_0000;

    localparam scr1_reg_data_t SCR1_SCRATCH0_RESET_VALUE =
        32'h0000_0000;

    localparam scr1_reg_data_t SCR1_SCRATCH1_RESET_VALUE =
        32'h0000_0000;


    // =========================================================================
    // ABI freeze notes -- v1.0
    // =========================================================================
    //
    // Frozen in this package:
    //   - register offsets
    //   - CONTROL / STATUS / IRQ bit positions
    //   - IP_ID and IP_VERSION encoding
    //   - CAPABILITIES bit positions
    //   - HW_CONFIG field layout
    //   - timeout units and reset defaults
    //   - WATCHDOG_CFG layout
    //   - OUTSTANDING field packing
    //   - SCR1_SW_STATUS code ABI
    //
    // Not duplicated here by design:
    //   - physical A72/SCR1 base address of scr1_control
    //   - platform BOOT_ADDR/reset-vector constant
    //
    // Any incompatible change to the above frozen ABI requires IP_VERSION.MAJOR
    // to be incremented.
    // =========================================================================


endpackage : scr1_regs_pkg
