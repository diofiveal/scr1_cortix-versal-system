package vd100_scr1_pkg;

    // =========================================================================
    // Lifecycle states
    // =========================================================================

    localparam int unsigned SCR1_LIFECYCLE_STATE_WIDTH = 4;

    typedef enum logic [SCR1_LIFECYCLE_STATE_WIDTH-1:0] {
        SCR1_LC_OFF        = 4'h0,
        SCR1_LC_RESET      = 4'h1,
        SCR1_LC_LOADING    = 4'h2,
        SCR1_LC_READY      = 4'h3,
        SCR1_LC_STARTING   = 4'h4,
        SCR1_LC_RUNNING    = 4'h5,
        SCR1_LC_QUIESCING  = 4'h6,
        SCR1_LC_HALTED     = 4'h7,
        SCR1_LC_FAULT      = 4'h8
    } scr1_lifecycle_state_e;

    // 4'h9 - 4'hF reserved for future lifecycle states


    // =========================================================================
    // Lifecycle commands
    // =========================================================================

    localparam int unsigned SCR1_LIFECYCLE_CMD_WIDTH = 3;

    typedef enum logic [SCR1_LIFECYCLE_CMD_WIDTH-1:0] {
        SCR1_CMD_NONE         = 3'h0,
        SCR1_CMD_LOAD         = 3'h1,
        SCR1_CMD_START        = 3'h2,
        SCR1_CMD_QUIESCE      = 3'h3,
        SCR1_CMD_HALT         = 3'h4,
        SCR1_CMD_SOFT_RESET   = 3'h5,
        SCR1_CMD_CLEAR_FAULT  = 3'h6
    } scr1_lifecycle_cmd_e;

    // 3'h7 reserved for future lifecycle command


    // =========================================================================
    // Fault codes
    // =========================================================================

    localparam int unsigned SCR1_FAULT_CODE_WIDTH = 4;

    typedef enum logic [SCR1_FAULT_CODE_WIDTH-1:0] {
        SCR1_FAULT_NONE                = 4'h0,
        SCR1_FAULT_TIMEOUT             = 4'h1,
        SCR1_FAULT_AXI_SLVERR          = 4'h2,
        SCR1_FAULT_AXI_DECERR          = 4'h3,
        SCR1_FAULT_ADDRESS_VIOLATION   = 4'h4,
        SCR1_FAULT_WATCHDOG            = 4'h5,
        SCR1_FAULT_ILLEGAL_TRANSITION  = 4'h6,
        SCR1_FAULT_BOOT_PROTECTION     = 4'h7
    } scr1_fault_code_e;

    // 4'h8 - 4'hF reserved for future fault codes


    // =========================================================================
    // Events
    // =========================================================================
    //
    // Logical events exchanged between RTL blocks.
    //
    // IMPORTANT:
    // These numeric values are NOT IRQ_STATUS bit positions.
    // Mapping event -> IRQ_STATUS bit belongs to scr1_regs_pkg.sv /
    // IRQ aggregation logic.
    // =========================================================================

    localparam int unsigned SCR1_EVENT_WIDTH = 4;

    typedef enum logic [SCR1_EVENT_WIDTH-1:0] {
        SCR1_EVENT_NONE              = 4'h0,
        SCR1_EVENT_SW_READY          = 4'h1,
        SCR1_EVENT_APP_DONE          = 4'h2,
        SCR1_EVENT_FAULT             = 4'h3,
        SCR1_EVENT_WATCHDOG_TIMEOUT  = 4'h4,
        SCR1_EVENT_START_TIMEOUT     = 4'h5,
        SCR1_EVENT_QUIESCE_TIMEOUT   = 4'h6,
        SCR1_EVENT_AXI_ERROR         = 4'h7,
        SCR1_EVENT_SW_EVENT          = 4'h8
    } scr1_event_e;

    // 4'h9 - 4'hF reserved for future events


    // =========================================================================
    // TODO: shared structures
    // =========================================================================
    //
    // Do not add packed structs yet.
    //
    // Add them only when the same structured information is exchanged between
    // at least two RTL blocks, for example:
    //
    //   scr1_axi_monitor -> scr1_control
    //
    // Possible future candidates:
    //   scr1_fault_info_t
    //   scr1_status_t
    //
    // Do not add PC/retire/signature fields unless they really exist on the
    // synthesizable subsystem interface.
    // =========================================================================


endpackage : vd100_scr1_pkg