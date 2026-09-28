import scr1_regs_pkg::*;

module scr1_control_axil #(
    parameter int unsigned AXIL_ADDR_WIDTH =
        scr1_regs_pkg::SCR1_REG_ADDR_WIDTH,

    parameter int unsigned AXIL_DATA_WIDTH =
        scr1_regs_pkg::SCR1_REG_DATA_WIDTH,

    parameter int unsigned OUTSTANDING_WIDTH = 2,

    parameter bit VERIFY_REQUIRED = 1'b0,

    // CAPABILITIES depends on the final bitstream integration.
    // Keep default conservative and override it from the top-level if needed.
    parameter logic [31:0] CAPABILITIES_VALUE = 32'h0000_0000
) (
    // -------------------------------------------------------------------------
    // Clock / reset
    // -------------------------------------------------------------------------
    input  logic                           clk,
    input  logic                           rst_n,

    // -------------------------------------------------------------------------
    // AXI4-Lite write address channel
    // -------------------------------------------------------------------------
    input  logic [AXIL_ADDR_WIDTH-1:0]     s_axil_awaddr_i,
    input  logic [2:0]                     s_axil_awprot_i,
    input  logic                           s_axil_awvalid_i,
    output logic                           s_axil_awready_o,

    // -------------------------------------------------------------------------
    // AXI4-Lite write data channel
    // -------------------------------------------------------------------------
    input  logic [AXIL_DATA_WIDTH-1:0]     s_axil_wdata_i,
    input  logic [AXIL_DATA_WIDTH/8-1:0]   s_axil_wstrb_i,
    input  logic                           s_axil_wvalid_i,
    output logic                           s_axil_wready_o,

    // -------------------------------------------------------------------------
    // AXI4-Lite write response channel
    // -------------------------------------------------------------------------
    output logic [1:0]                     s_axil_bresp_o,
    output logic                           s_axil_bvalid_o,
    input  logic                           s_axil_bready_i,

    // -------------------------------------------------------------------------
    // AXI4-Lite read address channel
    // -------------------------------------------------------------------------
    input  logic [AXIL_ADDR_WIDTH-1:0]     s_axil_araddr_i,
    input  logic [2:0]                     s_axil_arprot_i,
    input  logic                           s_axil_arvalid_i,
    output logic                           s_axil_arready_o,

    // -------------------------------------------------------------------------
    // AXI4-Lite read data channel
    // -------------------------------------------------------------------------
    output logic [AXIL_DATA_WIDTH-1:0]     s_axil_rdata_o,
    output logic [1:0]                     s_axil_rresp_o,
    output logic                           s_axil_rvalid_o,
    input  logic                           s_axil_rready_i,

    // -------------------------------------------------------------------------
    // Register write permissions from lifecycle/control policy
    // -------------------------------------------------------------------------
    input  logic                           launch_cfg_write_enable_i,
    input  logic                           boot_crc_write_enable_i,

    // -------------------------------------------------------------------------
    // Hardware / lifecycle status used for read-only registers
    // -------------------------------------------------------------------------
    input  vd100_scr1_pkg::scr1_lifecycle_state_e lifecycle_state_i,

    input  logic                           dependencies_ready_i,
    input  logic                           image_config_valid_i,
    input  logic                           axi_quiescent_i,
    input  logic                           boot_write_allowed_i,
    input  logic                           verifier_ready_i,
    input  logic                           completion_pending_i,

    input  logic [31:0]                    boot_addr_i,

    // -------------------------------------------------------------------------
    // Outstanding AXI status
    // -------------------------------------------------------------------------
    input  logic [OUTSTANDING_WIDTH-1:0]   imem_outstanding_i,
    input  logic [OUTSTANDING_WIDTH-1:0]   dmem_read_outstanding_i,
    input  logic [OUTSTANDING_WIDTH-1:0]   dmem_write_outstanding_i,

    // -------------------------------------------------------------------------
    // Fault status from fault aggregator
    // -------------------------------------------------------------------------
    input  vd100_scr1_pkg::scr1_fault_code_e fault_code_i,
    input  logic [31:0]                    fault_pc_i,
    input  logic [31:0]                    fault_info0_i,
    input  logic [31:0]                    fault_info1_i,

    // -------------------------------------------------------------------------
    // Runtime counters / status
    // -------------------------------------------------------------------------
    input  logic [31:0]                    heartbeat_i,
    input  logic [63:0]                    cycle_count_i,

    // -------------------------------------------------------------------------
    // IRQ causes generated by other control blocks
    // Sticky storage / W1C lives in this register bank.
    // -------------------------------------------------------------------------
    input  logic [31:0]                    irq_set_i,

    output logic [31:0]                    irq_status_o,
    output logic [31:0]                    irq_enable_o,

    // -------------------------------------------------------------------------
    // Typed lifecycle command
    // -------------------------------------------------------------------------
    output logic                           cmd_valid_o,
    output vd100_scr1_pkg::scr1_lifecycle_cmd_e cmd_o,

    // -------------------------------------------------------------------------
    // Launch configuration registers
    // -------------------------------------------------------------------------
    output logic [31:0]                    fw_desc_addr_o,
    output logic [31:0]                    fw_desc_size_o,
    output logic [31:0]                    start_token_o,

    // -------------------------------------------------------------------------
    // Timeout / watchdog configuration
    // -------------------------------------------------------------------------
    output logic [31:0]                    start_timeout_o,
    output logic [31:0]                    quiesce_timeout_o,
    output logic [31:0]                    watchdog_cfg_o,
    output logic                           watchdog_kick_pulse_o,

    // -------------------------------------------------------------------------
    // Boot verification configuration
    // -------------------------------------------------------------------------
    output logic [31:0]                    boot_crc_expected_o,
    output logic [31:0]                    boot_crc_observed_o,

    // -------------------------------------------------------------------------
    // SCR1 software-visible progress/error
    // -------------------------------------------------------------------------
    output logic [31:0]                    sw_status_o,
    output logic                           sw_status_write_pulse_o,

    output logic [31:0]                    sw_error_o,
    output logic                           sw_error_write_pulse_o
);

    localparam logic [1:0] AXI_RESP_OKAY   = 2'b00;
    localparam logic [1:0] AXI_RESP_SLVERR = 2'b10;

    // -------------------------------------------------------------------------
    // Helpers
    // -------------------------------------------------------------------------

    function automatic logic [AXIL_DATA_WIDTH-1:0] apply_wstrb(
        input logic [AXIL_DATA_WIDTH-1:0]   old_value,
        input logic [AXIL_DATA_WIDTH-1:0]   new_value,
        input logic [AXIL_DATA_WIDTH/8-1:0] strb
    );
        logic [AXIL_DATA_WIDTH-1:0] result;
        begin
            result = old_value;

            for (int i = 0; i < AXIL_DATA_WIDTH/8; i++) begin
                if (strb[i]) begin
                    result[i*8 +: 8] = new_value[i*8 +: 8];
                end
            end

            return result;
        end
    endfunction


    function automatic logic [AXIL_DATA_WIDTH-1:0] make_wstrb_mask(
        input logic [AXIL_DATA_WIDTH/8-1:0] strb
    );
        logic [AXIL_DATA_WIDTH-1:0] result;
        begin
            result = '0;

            for (int i = 0; i < AXIL_DATA_WIDTH/8; i++) begin
                if (strb[i]) begin
                    result[i*8 +: 8] = 8'hFF;
                end
            end

            return result;
        end
    endfunction


    function automatic logic sw_status_code_valid(
        input logic [7:0] code
    );
        begin
            case (code)
                SCR1_SW_STATUS_IDLE,
                SCR1_SW_STATUS_BOOT_ENTERED,
                SCR1_SW_STATUS_READY,
                SCR1_SW_STATUS_APP_RUNNING,
                SCR1_SW_STATUS_APP_DONE,
                SCR1_SW_STATUS_APP_ERROR: begin
                    sw_status_code_valid = 1'b1;
                end

                default: begin
                    sw_status_code_valid = 1'b0;
                end
            endcase
        end
    endfunction

    // -------------------------------------------------------------------------
    // AW
    // -------------------------------------------------------------------------

    logic [AXIL_ADDR_WIDTH-1:0] awaddr_q;
    logic                       aw_pending_q;

    logic aw_handshake;
    assign aw_handshake = s_axil_awvalid_i && s_axil_awready_o;

    always_ff @(posedge clk) begin
        if (!rst_n) begin
            awaddr_q   <= '0;
            aw_pending_q <= '0;
        end
        else if (b_handshake) begin
            aw_pending_q <= '0;
        end
        else if (aw_handshake) begin
            awaddr_q     <= s_axil_awaddr_i;
            aw_pending_q <= 1'b1;
        end
    end

    assign s_axil_awready_o = !aw_pending_q;

    // -------------------------------------------------------------------------
    // W
    // -------------------------------------------------------------------------

    logic [AXIL_DATA_WIDTH-1:0]   wdata_q;
    logic [AXIL_DATA_WIDTH/8-1:0] wstrb_q;
    logic                         w_pending_q;

    logic w_handshake;
    assign w_handshake = s_axil_wvalid_i && s_axil_wready_o;

    always_ff @(posedge clk) begin
        if (!rst_n) begin
            wdata_q     <= '0;
            wstrb_q     <= '0;
            w_pending_q <= '0;
        end
        else if (b_handshake) begin
            w_pending_q <= '0;
        end
        else if (w_handshake) begin
            wdata_q     <= s_axil_wdata_i;
            wstrb_q     <= s_axil_wstrb_i;
            w_pending_q <= 1'b1;
        end
    end

    assign s_axil_wready_o = !w_pending_q;

    // -------------------------------------------------------------------------
    // B
    // -------------------------------------------------------------------------

    logic write_request_ready;
    logic b_handshake;
    logic write_commit;

    logic [1:0] write_resp_comb;

    assign write_request_ready = aw_pending_q && w_pending_q;
    assign b_handshake = s_axil_bready_i && s_axil_bvalid_o;
    assign write_commit = write_request_ready && !s_axil_bvalid_o;

    always_ff @(posedge clk) begin
        if (!rst_n) begin
            s_axil_bresp_o  <= AXI_RESP_OKAY;
            s_axil_bvalid_o <= 1'b0;
        end
        else if (b_handshake) begin
            s_axil_bvalid_o <= 1'b0;
        end
        else if (write_commit) begin
            s_axil_bvalid_o <= 1'b1;
            s_axil_bresp_o  <= write_resp_comb;
        end
    end

    // -------------------------------------------------------------------------
    // Write decoder
    // -------------------------------------------------------------------------

    logic scratch0_write_en;
    logic scratch1_write_en;

    logic fw_desc_addr_write_en;
    logic fw_desc_size_write_en;
    logic start_token_write_en;

    logic start_timeout_write_en;
    logic quiesce_timeout_write_en;
    logic watchdog_cfg_write_en;
    logic watchdog_kick_pulse_write_en;

    logic irq_status_write_en;
    logic irq_enable_write_en;

    logic boot_crc_expected_write_en;
    logic boot_crc_observed_write_en;

    logic sw_status_write_en;
    logic sw_error_write_en;

    logic control_cmd_write_en;
    vd100_scr1_pkg::scr1_lifecycle_cmd_e control_cmd_comb;

    logic [AXIL_DATA_WIDTH-1:0] write_byte_mask_comb;
    logic [AXIL_DATA_WIDTH-1:0] effective_wdata_comb;
    logic [AXIL_DATA_WIDTH-1:0] watchdog_cfg_next_comb;
    logic [31:0]                irq_status_clear_mask_comb;

    always_comb begin
        write_byte_mask_comb   = make_wstrb_mask(wstrb_q);
        effective_wdata_comb   = wdata_q & write_byte_mask_comb;
        watchdog_cfg_next_comb = apply_wstrb(watchdog_cfg_o, wdata_q, wstrb_q);

        write_resp_comb = AXI_RESP_SLVERR;

        scratch0_write_en            = 1'b0;
        scratch1_write_en            = 1'b0;

        fw_desc_addr_write_en        = 1'b0;
        fw_desc_size_write_en        = 1'b0;
        start_token_write_en         = 1'b0;

        start_timeout_write_en       = 1'b0;
        quiesce_timeout_write_en     = 1'b0;
        watchdog_cfg_write_en        = 1'b0;
        watchdog_kick_pulse_write_en = 1'b0;

        irq_status_write_en          = 1'b0;
        irq_enable_write_en          = 1'b0;

        boot_crc_expected_write_en   = 1'b0;
        boot_crc_observed_write_en   = 1'b0;

        sw_status_write_en           = 1'b0;
        sw_error_write_en            = 1'b0;

        control_cmd_write_en         = 1'b0;
        control_cmd_comb             = vd100_scr1_pkg::SCR1_CMD_NONE;

        irq_status_clear_mask_comb   = '0;

        if (write_commit) begin
            case (awaddr_q)

                // -------------------------------------------------------------
                // CONTROL - write-only, one command per write
                // -------------------------------------------------------------
                SCR1_REG_CONTROL: begin
                    case (effective_wdata_comb)
                        SCR1_CONTROL_LOAD_MASK: begin
                            write_resp_comb      = AXI_RESP_OKAY;
                            control_cmd_write_en = 1'b1;
                            control_cmd_comb     = vd100_scr1_pkg::SCR1_CMD_LOAD;
                        end

                        SCR1_CONTROL_START_MASK: begin
                            write_resp_comb      = AXI_RESP_OKAY;
                            control_cmd_write_en = 1'b1;
                            control_cmd_comb     = vd100_scr1_pkg::SCR1_CMD_START;
                        end

                        SCR1_CONTROL_QUIESCE_MASK: begin
                            write_resp_comb      = AXI_RESP_OKAY;
                            control_cmd_write_en = 1'b1;
                            control_cmd_comb     = vd100_scr1_pkg::SCR1_CMD_QUIESCE;
                        end

                        SCR1_CONTROL_HALT_MASK: begin
                            write_resp_comb      = AXI_RESP_OKAY;
                            control_cmd_write_en = 1'b1;
                            control_cmd_comb     = vd100_scr1_pkg::SCR1_CMD_HALT;
                        end

                        SCR1_CONTROL_SOFT_RESET_MASK: begin
                            write_resp_comb      = AXI_RESP_OKAY;
                            control_cmd_write_en = 1'b1;
                            control_cmd_comb     = vd100_scr1_pkg::SCR1_CMD_SOFT_RESET;
                        end

                        SCR1_CONTROL_CLEAR_FAULT_MASK: begin
                            write_resp_comb      = AXI_RESP_OKAY;
                            control_cmd_write_en = 1'b1;
                            control_cmd_comb     = vd100_scr1_pkg::SCR1_CMD_CLEAR_FAULT;
                        end

                        default: begin
                            // zero, reserved bits or more than one command -> SLVERR
                            write_resp_comb      = AXI_RESP_SLVERR;
                            control_cmd_write_en = 1'b0;
                        end
                    endcase
                end

                // -------------------------------------------------------------
                // Launch configuration - protected by lifecycle policy
                // -------------------------------------------------------------
                SCR1_REG_FW_DESC_ADDR: begin
                    if (launch_cfg_write_enable_i) begin
                        write_resp_comb       = AXI_RESP_OKAY;
                        fw_desc_addr_write_en = 1'b1;
                    end
                end

                SCR1_REG_FW_DESC_SIZE: begin
                    if (launch_cfg_write_enable_i) begin
                        write_resp_comb       = AXI_RESP_OKAY;
                        fw_desc_size_write_en = 1'b1;
                    end
                end

                SCR1_REG_START_TOKEN: begin
                    if (launch_cfg_write_enable_i) begin
                        write_resp_comb      = AXI_RESP_OKAY;
                        start_token_write_en = 1'b1;
                    end
                end

                // -------------------------------------------------------------
                // Timeouts / watchdog
                // -------------------------------------------------------------
                SCR1_REG_START_TIMEOUT: begin
                    write_resp_comb        = AXI_RESP_OKAY;
                    start_timeout_write_en = 1'b1;
                end

                SCR1_REG_QUIESCE_TIMEOUT: begin
                    write_resp_comb          = AXI_RESP_OKAY;
                    quiesce_timeout_write_en = 1'b1;
                end

                SCR1_REG_WATCHDOG_CFG: begin
                    if (!(watchdog_cfg_next_comb[SCR1_WATCHDOG_ENABLE_BIT] &&
                          (watchdog_cfg_next_comb[SCR1_WATCHDOG_PERIOD_MSB:
                                                  SCR1_WATCHDOG_PERIOD_LSB] == '0))) begin
                        write_resp_comb       = AXI_RESP_OKAY;
                        watchdog_cfg_write_en = 1'b1;
                    end
                end

                SCR1_REG_WATCHDOG_KICK: begin
                    write_resp_comb = AXI_RESP_OKAY;

                    if (|wstrb_q) begin
                        watchdog_kick_pulse_write_en = 1'b1;
                    end
                end

                // -------------------------------------------------------------
                // IRQ
                // -------------------------------------------------------------
                SCR1_REG_IRQ_STATUS: begin
                    if ((effective_wdata_comb & ~SCR1_IRQ_VALID_MASK) == '0) begin
                        write_resp_comb             = AXI_RESP_OKAY;
                        irq_status_write_en         = 1'b1;
                        irq_status_clear_mask_comb  = effective_wdata_comb &
                                                      SCR1_IRQ_VALID_MASK;
                    end
                end

                SCR1_REG_IRQ_ENABLE: begin
                    if ((effective_wdata_comb & ~SCR1_IRQ_VALID_MASK) == '0) begin
                        write_resp_comb      = AXI_RESP_OKAY;
                        irq_enable_write_en  = 1'b1;
                    end
                end

                // -------------------------------------------------------------
                // Boot CRC - protected by boot policy
                // -------------------------------------------------------------
                SCR1_REG_BOOT_CRC_EXPECTED: begin
                    if (boot_crc_write_enable_i) begin
                        write_resp_comb            = AXI_RESP_OKAY;
                        boot_crc_expected_write_en = 1'b1;
                    end
                end

                SCR1_REG_BOOT_CRC_OBSERVED: begin
                    if (boot_crc_write_enable_i) begin
                        write_resp_comb            = AXI_RESP_OKAY;
                        boot_crc_observed_write_en = 1'b1;
                    end
                end

                // -------------------------------------------------------------
                // SCR1 software-visible status
                // -------------------------------------------------------------
                SCR1_REG_SW_STATUS: begin
                    if ((effective_wdata_comb & ~SCR1_SW_STATUS_CODE_MASK) == '0) begin
                        if (!wstrb_q[0]) begin
                            // Write touches no status byte. Legal no-op.
                            write_resp_comb = AXI_RESP_OKAY;
                        end
                        else if (sw_status_code_valid(wdata_q[7:0])) begin
                            write_resp_comb   = AXI_RESP_OKAY;
                            sw_status_write_en = 1'b1;
                        end
                    end
                end

                SCR1_REG_SW_ERROR: begin
                    write_resp_comb = AXI_RESP_OKAY;

                    if (|wstrb_q) begin
                        sw_error_write_en = 1'b1;
                    end
                end

                // -------------------------------------------------------------
                // Scratch
                // -------------------------------------------------------------
                SCR1_REG_SCRATCH0: begin
                    write_resp_comb  = AXI_RESP_OKAY;
                    scratch0_write_en = 1'b1;
                end

                SCR1_REG_SCRATCH1: begin
                    write_resp_comb  = AXI_RESP_OKAY;
                    scratch1_write_en = 1'b1;
                end

                // RO, reserved, unmapped or misaligned address -> SLVERR
                default: begin
                    write_resp_comb = AXI_RESP_SLVERR;
                end

            endcase
        end
    end

    // -------------------------------------------------------------------------
    // Ordinary RW register storage
    // -------------------------------------------------------------------------

    logic [31:0] scratch0_reg;
    logic [31:0] scratch1_reg;

    always_ff @(posedge clk) begin
        if (!rst_n) begin
            scratch0_reg         <= SCR1_SCRATCH0_RESET_VALUE;
            scratch1_reg         <= SCR1_SCRATCH1_RESET_VALUE;

            fw_desc_addr_o       <= SCR1_FW_DESC_ADDR_RESET_VALUE;
            fw_desc_size_o       <= SCR1_FW_DESC_SIZE_RESET_VALUE;
            start_token_o        <= SCR1_START_TOKEN_RESET_VALUE;

            start_timeout_o      <= SCR1_START_TIMEOUT_RESET_VALUE;
            quiesce_timeout_o    <= SCR1_QUIESCE_TIMEOUT_RESET_VALUE;
            watchdog_cfg_o       <= SCR1_WATCHDOG_CFG_RESET_VALUE;

            irq_enable_o         <= SCR1_IRQ_ENABLE_RESET_VALUE;

            boot_crc_expected_o  <= SCR1_BOOT_CRC_EXPECTED_RESET_VALUE;
            boot_crc_observed_o  <= SCR1_BOOT_CRC_OBSERVED_RESET_VALUE;

            sw_status_o          <= SCR1_SW_STATUS_RESET_VALUE;
            sw_error_o           <= SCR1_SW_ERROR_RESET_VALUE;
        end
        else if (scratch0_write_en) begin
            for (int i = 0; i < AXIL_DATA_WIDTH/8; i++) begin
                if (wstrb_q[i]) begin
                    scratch0_reg[i*8 +: 8] <= wdata_q[i*8 +: 8];
                end
            end
        end
        else if (scratch1_write_en) begin
            for (int i = 0; i < AXIL_DATA_WIDTH/8; i++) begin
                if (wstrb_q[i]) begin
                    scratch1_reg[i*8 +: 8] <= wdata_q[i*8 +: 8];
                end
            end
        end
        else if (fw_desc_addr_write_en) begin
            for (int i = 0; i < AXIL_DATA_WIDTH/8; i++) begin
                if (wstrb_q[i]) begin
                    fw_desc_addr_o[i*8 +: 8] <= wdata_q[i*8 +: 8];
                end
            end
        end
        else if (fw_desc_size_write_en) begin
            for (int i = 0; i < AXIL_DATA_WIDTH/8; i++) begin
                if (wstrb_q[i]) begin
                    fw_desc_size_o[i*8 +: 8] <= wdata_q[i*8 +: 8];
                end
            end
        end
        else if (start_token_write_en) begin
            for (int i = 0; i < AXIL_DATA_WIDTH/8; i++) begin
                if (wstrb_q[i]) begin
                    start_token_o[i*8 +: 8] <= wdata_q[i*8 +: 8];
                end
            end
        end
        else if (start_timeout_write_en) begin
            for (int i = 0; i < AXIL_DATA_WIDTH/8; i++) begin
                if (wstrb_q[i]) begin
                    start_timeout_o[i*8 +: 8] <= wdata_q[i*8 +: 8];
                end
            end
        end
        else if (quiesce_timeout_write_en) begin
            for (int i = 0; i < AXIL_DATA_WIDTH/8; i++) begin
                if (wstrb_q[i]) begin
                    quiesce_timeout_o[i*8 +: 8] <= wdata_q[i*8 +: 8];
                end
            end
        end
        else if (watchdog_cfg_write_en) begin
            watchdog_cfg_o <= watchdog_cfg_next_comb;
        end
        else if (irq_enable_write_en) begin
            for (int i = 0; i < AXIL_DATA_WIDTH/8; i++) begin
                if (wstrb_q[i]) begin
                    irq_enable_o[i*8 +: 8] <= wdata_q[i*8 +: 8];
                end
            end
        end
        else if (boot_crc_expected_write_en) begin
            for (int i = 0; i < AXIL_DATA_WIDTH/8; i++) begin
                if (wstrb_q[i]) begin
                    boot_crc_expected_o[i*8 +: 8] <= wdata_q[i*8 +: 8];
                end
            end
        end
        else if (boot_crc_observed_write_en) begin
            for (int i = 0; i < AXIL_DATA_WIDTH/8; i++) begin
                if (wstrb_q[i]) begin
                    boot_crc_observed_o[i*8 +: 8] <= wdata_q[i*8 +: 8];
                end
            end
        end
        else if (sw_status_write_en) begin
            sw_status_o       <= '0;
            sw_status_o[7:0]  <= wdata_q[7:0];
        end
        else if (sw_error_write_en) begin
            for (int i = 0; i < AXIL_DATA_WIDTH/8; i++) begin
                if (wstrb_q[i]) begin
                    sw_error_o[i*8 +: 8] <= wdata_q[i*8 +: 8];
                end
            end
        end
    end

    // -------------------------------------------------------------------------
    // CONTROL one-shot command
    // -------------------------------------------------------------------------

    always_ff @(posedge clk) begin
        if (!rst_n) begin
            cmd_valid_o <= 1'b0;
            cmd_o       <= vd100_scr1_pkg::SCR1_CMD_NONE;
        end
        else begin
            cmd_valid_o <= control_cmd_write_en;

            if (control_cmd_write_en) begin
                cmd_o <= control_cmd_comb;
            end
            else begin
                cmd_o <= vd100_scr1_pkg::SCR1_CMD_NONE;
            end
        end
    end

    // -------------------------------------------------------------------------
    // WATCHDOG_KICK pulse
    // -------------------------------------------------------------------------

    always_ff @(posedge clk) begin
        if (!rst_n) begin
            watchdog_kick_pulse_o <= 1'b0;
        end
        else begin
            watchdog_kick_pulse_o <= watchdog_kick_pulse_write_en;
        end
    end

    // -------------------------------------------------------------------------
    // SW_STATUS / SW_ERROR notification pulses
    // -------------------------------------------------------------------------

    always_ff @(posedge clk) begin
        if (!rst_n) begin
            sw_status_write_pulse_o <= 1'b0;
            sw_error_write_pulse_o  <= 1'b0;
        end
        else begin
            sw_status_write_pulse_o <= sw_status_write_en;
            sw_error_write_pulse_o  <= sw_error_write_en;
        end
    end

    // -------------------------------------------------------------------------
    // IRQ_STATUS sticky W1C
    // Hardware set wins if set and clear happen on the same cycle.
    // -------------------------------------------------------------------------

    always_ff @(posedge clk) begin
        if (!rst_n) begin
            irq_status_o <= SCR1_IRQ_STATUS_RESET_VALUE;
        end
        else if (irq_status_write_en) begin
            irq_status_o <= (irq_status_o & ~irq_status_clear_mask_comb) |
                            (irq_set_i & SCR1_IRQ_VALID_MASK);
        end
        else begin
            irq_status_o <= irq_status_o |
                            (irq_set_i & SCR1_IRQ_VALID_MASK);
        end
    end

    // -------------------------------------------------------------------------
    // AR
    // -------------------------------------------------------------------------

    logic [AXIL_ADDR_WIDTH-1:0] araddr_q;
    logic                       ar_pending_q;
    logic                       ar_handshake;

    logic read_request_ready;
    logic read_commit;

    assign read_request_ready = ar_pending_q;
    assign read_commit        = read_request_ready && !s_axil_rvalid_o;
    assign ar_handshake       = s_axil_arvalid_i && s_axil_arready_o;

    always_ff @(posedge clk) begin
        if (!rst_n) begin
            araddr_q     <= '0;
            ar_pending_q <= '0;
        end
        else if (r_handshake) begin
            ar_pending_q <= 1'b0;
        end
        else if (ar_handshake) begin
            araddr_q     <= s_axil_araddr_i;
            ar_pending_q <= 1'b1;
        end
    end

    assign s_axil_arready_o = !ar_pending_q;

    // -------------------------------------------------------------------------
    // RO values
    // -------------------------------------------------------------------------

    logic [31:0] status_value_comb;
    logic [31:0] outstanding_value_comb;
    logic [31:0] hw_config_value_comb;
    logic [31:0] capabilities_value_comb;

    always_comb begin
        status_value_comb = '0;

        status_value_comb[SCR1_STATUS_STATE_MSB:
                          SCR1_STATUS_STATE_LSB] = lifecycle_state_i;

        status_value_comb[SCR1_STATUS_DEPENDENCIES_READY_BIT] =
            dependencies_ready_i;

        status_value_comb[SCR1_STATUS_IMAGE_VALID_BIT] =
            image_config_valid_i;

        status_value_comb[SCR1_STATUS_RUNNING_BIT] =
            (lifecycle_state_i == vd100_scr1_pkg::SCR1_LC_RUNNING);

        status_value_comb[SCR1_STATUS_HALTED_BIT] =
            (lifecycle_state_i == vd100_scr1_pkg::SCR1_LC_HALTED);

        status_value_comb[SCR1_STATUS_FAULT_BIT] =
            (lifecycle_state_i == vd100_scr1_pkg::SCR1_LC_FAULT);

        status_value_comb[SCR1_STATUS_AXI_QUIESCENT_BIT] =
            axi_quiescent_i;

        status_value_comb[SCR1_STATUS_BOOT_WRITE_ALLOWED_BIT] =
            boot_write_allowed_i;

        status_value_comb[SCR1_STATUS_VERIFIER_READY_BIT] =
            verifier_ready_i;

        status_value_comb[SCR1_STATUS_COMPLETION_PENDING_BIT] =
            completion_pending_i;
    end


    always_comb begin
        outstanding_value_comb = '0;

        outstanding_value_comb[SCR1_OUTSTANDING_IMEM_RD_MSB:
                               SCR1_OUTSTANDING_IMEM_RD_LSB] =
            imem_outstanding_i;

        outstanding_value_comb[SCR1_OUTSTANDING_DMEM_RD_MSB:
                               SCR1_OUTSTANDING_DMEM_RD_LSB] =
            dmem_read_outstanding_i;

        outstanding_value_comb[SCR1_OUTSTANDING_DMEM_WR_MSB:
                               SCR1_OUTSTANDING_DMEM_WR_LSB] =
            dmem_write_outstanding_i;
    end


    always_comb begin
        hw_config_value_comb =
            scr1_make_hw_config(OUTSTANDING_WIDTH, VERIFY_REQUIRED);

        capabilities_value_comb = CAPABILITIES_VALUE &
                                  SCR1_CAP_VALID_MASK;
    end

    // -------------------------------------------------------------------------
    // Read decoder
    // -------------------------------------------------------------------------

    logic [AXIL_DATA_WIDTH-1:0] read_data_comb;
    logic [1:0]                 read_resp_comb;

    always_comb begin
        read_data_comb = '0;
        read_resp_comb = AXI_RESP_SLVERR;

        case (araddr_q)
            SCR1_REG_IP_ID: begin
                read_data_comb = SCR1_IP_ID_VALUE;
                read_resp_comb = AXI_RESP_OKAY;
            end

            SCR1_REG_IP_VERSION: begin
                read_data_comb = SCR1_IP_VERSION_VALUE;
                read_resp_comb = AXI_RESP_OKAY;
            end

            SCR1_REG_CAPABILITIES: begin
                read_data_comb = capabilities_value_comb;
                read_resp_comb = AXI_RESP_OKAY;
            end

            SCR1_REG_HW_CONFIG: begin
                read_data_comb = hw_config_value_comb;
                read_resp_comb = AXI_RESP_OKAY;
            end

            SCR1_REG_STATUS: begin
                read_data_comb = status_value_comb;
                read_resp_comb = AXI_RESP_OKAY;
            end

            SCR1_REG_BOOT_ADDR: begin
                read_data_comb = boot_addr_i;
                read_resp_comb = AXI_RESP_OKAY;
            end

            SCR1_REG_FW_DESC_ADDR: begin
                read_data_comb = fw_desc_addr_o;
                read_resp_comb = AXI_RESP_OKAY;
            end

            SCR1_REG_FW_DESC_SIZE: begin
                read_data_comb = fw_desc_size_o;
                read_resp_comb = AXI_RESP_OKAY;
            end

            SCR1_REG_START_TOKEN: begin
                read_data_comb = start_token_o;
                read_resp_comb = AXI_RESP_OKAY;
            end

            SCR1_REG_START_TIMEOUT: begin
                read_data_comb = start_timeout_o;
                read_resp_comb = AXI_RESP_OKAY;
            end

            SCR1_REG_QUIESCE_TIMEOUT: begin
                read_data_comb = quiesce_timeout_o;
                read_resp_comb = AXI_RESP_OKAY;
            end

            SCR1_REG_WATCHDOG_CFG: begin
                read_data_comb = watchdog_cfg_o;
                read_resp_comb = AXI_RESP_OKAY;
            end

            // WATCHDOG_KICK is write-only. Read returns SLVERR.

            SCR1_REG_IRQ_STATUS: begin
                read_data_comb = irq_status_o;
                read_resp_comb = AXI_RESP_OKAY;
            end

            SCR1_REG_IRQ_ENABLE: begin
                read_data_comb = irq_enable_o;
                read_resp_comb = AXI_RESP_OKAY;
            end

            SCR1_REG_FAULT_CODE: begin
                read_data_comb = '0;
                read_data_comb[$bits(fault_code_i)-1:0] = fault_code_i;
                read_resp_comb = AXI_RESP_OKAY;
            end

            SCR1_REG_FAULT_PC: begin
                read_data_comb = fault_pc_i;
                read_resp_comb = AXI_RESP_OKAY;
            end

            SCR1_REG_FAULT_INFO0: begin
                read_data_comb = fault_info0_i;
                read_resp_comb = AXI_RESP_OKAY;
            end

            SCR1_REG_FAULT_INFO1: begin
                read_data_comb = fault_info1_i;
                read_resp_comb = AXI_RESP_OKAY;
            end

            SCR1_REG_OUTSTANDING: begin
                read_data_comb = outstanding_value_comb;
                read_resp_comb = AXI_RESP_OKAY;
            end

            SCR1_REG_HEARTBEAT: begin
                read_data_comb = heartbeat_i;
                read_resp_comb = AXI_RESP_OKAY;
            end

            SCR1_REG_CYCLE_LO: begin
                read_data_comb = cycle_count_i[31:0];
                read_resp_comb = AXI_RESP_OKAY;
            end

            SCR1_REG_CYCLE_HI: begin
                read_data_comb = cycle_count_i[63:32];
                read_resp_comb = AXI_RESP_OKAY;
            end

            SCR1_REG_BOOT_CRC_EXPECTED: begin
                read_data_comb = boot_crc_expected_o;
                read_resp_comb = AXI_RESP_OKAY;
            end

            SCR1_REG_BOOT_CRC_OBSERVED: begin
                read_data_comb = boot_crc_observed_o;
                read_resp_comb = AXI_RESP_OKAY;
            end

            SCR1_REG_SW_STATUS: begin
                read_data_comb = sw_status_o;
                read_resp_comb = AXI_RESP_OKAY;
            end

            SCR1_REG_SW_ERROR: begin
                read_data_comb = sw_error_o;
                read_resp_comb = AXI_RESP_OKAY;
            end

            SCR1_REG_SCRATCH0: begin
                read_data_comb = scratch0_reg;
                read_resp_comb = AXI_RESP_OKAY;
            end

            SCR1_REG_SCRATCH1: begin
                read_data_comb = scratch1_reg;
                read_resp_comb = AXI_RESP_OKAY;
            end

            // CONTROL is write-only.
            // Reserved, unmapped or misaligned addresses also return SLVERR.
            default: begin
                read_data_comb = '0;
                read_resp_comb = AXI_RESP_SLVERR;
            end
        endcase
    end

    // -------------------------------------------------------------------------
    // R
    // -------------------------------------------------------------------------

    logic r_handshake;
    assign r_handshake = s_axil_rready_i && s_axil_rvalid_o;

    always_ff @(posedge clk) begin
        if (!rst_n) begin
            s_axil_rvalid_o <= 1'b0;
            s_axil_rdata_o  <= '0;
            s_axil_rresp_o  <= AXI_RESP_OKAY;
        end
        else if (read_commit) begin
            s_axil_rdata_o  <= read_data_comb;
            s_axil_rresp_o  <= read_resp_comb;
            s_axil_rvalid_o <= 1'b1;
        end
        else if (r_handshake) begin
            s_axil_rvalid_o <= 1'b0;
        end
    end

endmodule : scr1_control_axil
