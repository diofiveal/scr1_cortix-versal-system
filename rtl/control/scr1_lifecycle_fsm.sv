import scr1_regs_pkg::*;
import vd100_scr1_pkg::*;


module scr1_lifecycle_fsm #(
    parameter bit VERIFY_REQUIRED = 1'b0
) (
    // -------------------------------------------------------------------------
    // Clock / reset
    // -------------------------------------------------------------------------
    input  logic clk,
    input  logic rst_n,

    // -------------------------------------------------------------------------
    // Lifecycle command from scr1_control_axil
    // -------------------------------------------------------------------------
    input  logic                                      cmd_valid_i,
    input  vd100_scr1_pkg::scr1_lifecycle_cmd_e       cmd_i,

    // -------------------------------------------------------------------------
    // Platform / image readiness
    // -------------------------------------------------------------------------
    input  logic dependencies_ready_i,
    input  logic image_config_valid_i,
    input  logic verifier_ready_i,

    // -------------------------------------------------------------------------
    // AXI drain / fault status
    // -------------------------------------------------------------------------
    input  logic                                      axi_quiescent_i,
    input  logic                                      hw_fault_valid_i,
    input  vd100_scr1_pkg::scr1_fault_code_e          hw_fault_code_i,

    // -------------------------------------------------------------------------
    // Boot BRAM protection
    // -------------------------------------------------------------------------
    input  logic                                      boot_violation_i,

    // -------------------------------------------------------------------------
    // Programmable lifecycle configuration
    // -------------------------------------------------------------------------
    input  logic [31:0]                               start_timeout_i,
    input  logic [31:0]                               quiesce_timeout_i,
    input  logic [31:0]                               watchdog_cfg_i,
    input  logic [31:0]                               start_token_i,
    input  logic                                      watchdog_kick_pulse_i,

    // -------------------------------------------------------------------------
    // SCR1 software progress
    // -------------------------------------------------------------------------
    input  logic [31:0]                               sw_status_i,
    input  logic                                      sw_status_write_pulse_i,

    // -------------------------------------------------------------------------
    // Current lifecycle state
    // -------------------------------------------------------------------------
    output vd100_scr1_pkg::scr1_lifecycle_state_e     lifecycle_state_o,

    // -------------------------------------------------------------------------
    // SCR1 control
    // -------------------------------------------------------------------------
    output logic                                      scr1_cpu_rst_n_o,
    output logic                                      scr1_master_enable_o,

    // -------------------------------------------------------------------------
    // Register / Boot BRAM write policy
    // -------------------------------------------------------------------------
    output logic                                      launch_cfg_write_enable_o,
    output logic                                      boot_crc_write_enable_o,
    output logic                                      boot_write_allowed_o,

    // -------------------------------------------------------------------------
    // Fault clear
    // -------------------------------------------------------------------------
    output logic                                      clear_fault_pulse_o,

    // -------------------------------------------------------------------------
    // Lifecycle events
    // -------------------------------------------------------------------------
    output logic                                      event_valid_o,
    output vd100_scr1_pkg::scr1_event_e               event_o,

    // -------------------------------------------------------------------------
    // New fault request
    // -------------------------------------------------------------------------
    output logic                                      fault_request_valid_o,
    output vd100_scr1_pkg::scr1_fault_code_e          fault_request_code_o,

    // -------------------------------------------------------------------------
    // Software completion state
    // -------------------------------------------------------------------------
    output logic                                      completion_pending_o
);
    logic cmd_valid_safe;
    assign cmd_valid_safe = cmd_valid_i
                         && ((cmd_i != SCR1_CMD_CLEAR_FAULT) || axi_quiescent_i);



    logic completion_pending_q;
    logic software_app_done;
    logic software_app_error;

    logic software_start_confirmed;
    assign software_start_confirmed = sw_status_write_pulse_i 
                                    && (sw_status_i == SCR1_SW_STATUS_READY 
                                        || sw_status_i == SCR1_SW_STATUS_APP_RUNNING);
    

    logic [31:0] start_timer_counter;
    logic        start_timeout_expired;

    logic [31:0] quiesce_timer_counter;
    logic        quiesce_timeout_expired;

    logic [31:0] watchdog_timer_counter;
    logic        watchdog_timeout_expired;

    logic [31:0] last_start_token_q;
    logic        last_start_token_valid_q;
    logic        start_token_replay;
    logic        start_command_attempt;
    logic        start_command_accepted;

    scr1_lifecycle_state_e state_q, state_n;
    scr1_lifecycle_cmd_e reason_quiescing_q, reason_quiescing_n;
    scr1_event_e fault_event_comb;

    assign start_token_replay = last_start_token_valid_q
                              && (start_token_i == last_start_token_q);

    assign start_command_attempt = (state_q == SCR1_LC_READY)
                                && image_config_valid_i
                                && cmd_valid_safe
                                && (cmd_i == SCR1_CMD_START)
                                && dependencies_ready_i
                                && (verifier_ready_i || !VERIFY_REQUIRED)
                                && !boot_violation_i;

    assign start_command_accepted = start_command_attempt
                                 && !start_token_replay;



    always_comb begin
        state_n = state_q;
        reason_quiescing_n = reason_quiescing_q;

        case (state_q)
            //OFF is reserved for future power-management.
            //No normal P1 transition enters or leaves OFF.
            SCR1_LC_OFF: begin

            end
            
            SCR1_LC_RESET: begin
                if (cmd_valid_safe && cmd_i != SCR1_CMD_LOAD) begin
                    state_n = SCR1_LC_FAULT;
                end
                else if (cmd_valid_safe && cmd_i == SCR1_CMD_LOAD) begin
                    state_n = SCR1_LC_LOADING;
                end
            end 

            SCR1_LC_LOADING: begin
                if (cmd_valid_safe) begin
                    state_n = SCR1_LC_FAULT;
                end
                else if (image_config_valid_i) begin
                    state_n = SCR1_LC_READY;
                end
            end 

            SCR1_LC_READY: begin
                if (boot_violation_i
                    || (cmd_valid_safe && cmd_i != SCR1_CMD_START)) begin
                    state_n = SCR1_LC_FAULT;
                end
                else if (image_config_valid_i 
                    && cmd_valid_safe
                    && (cmd_i == SCR1_CMD_START) 
                    && dependencies_ready_i
                    && (verifier_ready_i || !VERIFY_REQUIRED)) begin

                    if (start_token_replay) begin
                        state_n = SCR1_LC_FAULT;
                    end
                    else begin
                        state_n = SCR1_LC_STARTING;
                    end
                end
            end 

            SCR1_LC_STARTING: begin
                if (hw_fault_valid_i 
                    || boot_violation_i
                    || cmd_valid_safe) begin
                    state_n = SCR1_LC_FAULT;
                end
                else if(software_start_confirmed) begin
                    state_n = SCR1_LC_RUNNING;
                end
                else if (start_timeout_expired) begin
                    state_n = SCR1_LC_FAULT;
                end
            end

            SCR1_LC_RUNNING: begin
                if (hw_fault_valid_i
                    || boot_violation_i
                    || watchdog_timeout_expired
                    || (cmd_valid_safe && !(cmd_i == SCR1_CMD_HALT 
                                        || cmd_i == SCR1_CMD_QUIESCE
                                        || cmd_i == SCR1_CMD_SOFT_RESET))) begin
                    state_n = SCR1_LC_FAULT;
                end
                else if(cmd_valid_safe && (cmd_i == SCR1_CMD_HALT)) begin
                    state_n            = SCR1_LC_QUIESCING;
                    reason_quiescing_n = SCR1_CMD_HALT;
                end
                else if (cmd_valid_safe && (cmd_i == SCR1_CMD_QUIESCE)) begin
                    state_n            = SCR1_LC_QUIESCING;
                    reason_quiescing_n = SCR1_CMD_QUIESCE;
                end
                else if (cmd_valid_safe && (cmd_i == SCR1_CMD_SOFT_RESET)) begin
                    state_n            = SCR1_LC_QUIESCING;
                    reason_quiescing_n = SCR1_CMD_SOFT_RESET;
                end
            end 

            SCR1_LC_QUIESCING: begin
                if (hw_fault_valid_i
                    || boot_violation_i
                    || quiesce_timeout_expired
                    || cmd_valid_safe
                    ) begin
                    state_n = SCR1_LC_FAULT;
                end
                else if(axi_quiescent_i) begin
                    if ((reason_quiescing_q == SCR1_CMD_HALT)
                     || (reason_quiescing_q == SCR1_CMD_QUIESCE)) begin
                        state_n = SCR1_LC_HALTED;
                        reason_quiescing_n = SCR1_CMD_NONE;
                    end
                    else if (reason_quiescing_q == SCR1_CMD_SOFT_RESET) begin
                        state_n = SCR1_LC_RESET;
                        reason_quiescing_n = SCR1_CMD_NONE;
                    end
                    else begin
                        state_n = SCR1_LC_FAULT;
                        reason_quiescing_n = SCR1_CMD_NONE;
                    end
                end
            end

            SCR1_LC_HALTED: begin
                if (boot_violation_i
                    || (cmd_valid_safe && !(cmd_i == SCR1_CMD_LOAD
                                            || cmd_i == SCR1_CMD_SOFT_RESET))) begin
                    state_n = SCR1_LC_FAULT;
                end
                else if (cmd_valid_safe && (cmd_i == SCR1_CMD_LOAD)) begin
                    state_n = SCR1_LC_LOADING;
                end
                else if (cmd_valid_safe && (cmd_i == SCR1_CMD_SOFT_RESET)) begin
                    state_n = SCR1_LC_RESET;
                end
            end

            SCR1_LC_FAULT: begin
                if (cmd_valid_safe && (cmd_i == SCR1_CMD_CLEAR_FAULT)) begin
                    state_n = SCR1_LC_RESET;
                    reason_quiescing_n = SCR1_CMD_NONE;
                end
            end

            default: begin
                state_n = SCR1_LC_FAULT;
                reason_quiescing_n = SCR1_CMD_NONE;
            end
        endcase
    end

    always_ff @(posedge clk) begin
        if(!rst_n) begin
            state_q            <= SCR1_LC_RESET;
            reason_quiescing_q <= SCR1_CMD_NONE;
        end
        else begin
            state_q            <= state_n;
            reason_quiescing_q <= reason_quiescing_n;
        end
    end

// START_TOKEN replay protection
    always_ff @(posedge clk) begin
        if (!rst_n) begin
            last_start_token_q       <= '0;
            last_start_token_valid_q <= 1'b0;
        end
        else if (start_command_accepted) begin
            last_start_token_q       <= start_token_i;
            last_start_token_valid_q <= 1'b1;
        end
    end

// reset sequencing
// rst_n is expected to come from Processor System Reset with synchronous
// deassertion in the control clock domain. SCR1 synchronizes cpu_rst_n internally.
// Global reset still forces lifecycle outputs to a safe state immediately.
    always_comb begin
        if (!rst_n) begin
            scr1_cpu_rst_n_o          = 1'b0;
            scr1_master_enable_o      = 1'b0;
            launch_cfg_write_enable_o = 1'b0;
            boot_crc_write_enable_o   = 1'b0;
            boot_write_allowed_o      = 1'b0;
        end
        else begin
            case (state_q)

            SCR1_LC_OFF: begin
                scr1_cpu_rst_n_o          = 1'b0;
                scr1_master_enable_o      = 1'b0;
                launch_cfg_write_enable_o = 1'b0;
                boot_crc_write_enable_o   = 1'b0;
                boot_write_allowed_o      = 1'b0;
            end

            SCR1_LC_RESET: begin
                scr1_cpu_rst_n_o          = 1'b0;
                scr1_master_enable_o      = 1'b0;
                launch_cfg_write_enable_o = 1'b1;
                boot_crc_write_enable_o   = 1'b1;
                boot_write_allowed_o      = 1'b1;
            end 

            SCR1_LC_LOADING: begin
                scr1_cpu_rst_n_o          = 1'b0;
                scr1_master_enable_o      = 1'b0;
                launch_cfg_write_enable_o = 1'b1;
                boot_crc_write_enable_o   = 1'b1;
                boot_write_allowed_o      = 1'b1;
            end 

            SCR1_LC_READY: begin
                scr1_cpu_rst_n_o          = 1'b0;
                scr1_master_enable_o      = 1'b0;
                launch_cfg_write_enable_o = 1'b0;
                boot_crc_write_enable_o   = 1'b0;
                boot_write_allowed_o      = 1'b0;
            end 

            SCR1_LC_STARTING: begin
                scr1_cpu_rst_n_o          = 1'b1;
                scr1_master_enable_o      = 1'b1;
                launch_cfg_write_enable_o = 1'b0;
                boot_crc_write_enable_o   = 1'b0;
                boot_write_allowed_o      = 1'b0;
            end

            SCR1_LC_RUNNING: begin
                scr1_cpu_rst_n_o          = 1'b1;
                scr1_master_enable_o      = 1'b1;
                launch_cfg_write_enable_o = 1'b0;
                boot_crc_write_enable_o   = 1'b0;
                boot_write_allowed_o      = 1'b0;
            end 

            SCR1_LC_QUIESCING: begin
                scr1_cpu_rst_n_o          = 1'b1;
                scr1_master_enable_o      = 1'b0;
                launch_cfg_write_enable_o = 1'b0;
                boot_crc_write_enable_o   = 1'b0;
                boot_write_allowed_o      = 1'b0;
            end

            SCR1_LC_HALTED: begin
                scr1_cpu_rst_n_o          = 1'b0;
                scr1_master_enable_o      = 1'b0;
                launch_cfg_write_enable_o = 1'b0;
                boot_crc_write_enable_o   = 1'b0;
                boot_write_allowed_o      = 1'b0;
            end

            SCR1_LC_FAULT: begin
                scr1_cpu_rst_n_o          = 1'b0;
                scr1_master_enable_o      = 1'b0;
                launch_cfg_write_enable_o = 1'b0;
                boot_crc_write_enable_o   = 1'b0;
                boot_write_allowed_o      = 1'b0;
            end
            default: begin
                scr1_cpu_rst_n_o          = 1'b0;
                scr1_master_enable_o      = 1'b0;
                launch_cfg_write_enable_o = 1'b0;
                boot_crc_write_enable_o   = 1'b0;
                boot_write_allowed_o      = 1'b0;
            end
            endcase
        end
    end

// fault request encoder
    always_comb begin
        fault_request_valid_o = 1'b0;
        fault_request_code_o  = SCR1_FAULT_NONE;
        fault_event_comb      = SCR1_EVENT_NONE;

        if (rst_n) begin
            case (state_q)

                SCR1_LC_OFF: begin

                end

                SCR1_LC_RESET: begin
                    if (cmd_valid_safe && (cmd_i != SCR1_CMD_LOAD)) begin
                        fault_request_valid_o = 1'b1;
                        fault_request_code_o  = SCR1_FAULT_ILLEGAL_TRANSITION;
                        fault_event_comb      = SCR1_EVENT_FAULT;
                    end
                end

                SCR1_LC_LOADING: begin
                    if (cmd_valid_safe) begin
                        fault_request_valid_o = 1'b1;
                        fault_request_code_o  = SCR1_FAULT_ILLEGAL_TRANSITION;
                        fault_event_comb      = SCR1_EVENT_FAULT;
                    end
                end

                SCR1_LC_READY: begin
                    if (boot_violation_i) begin
                        fault_request_valid_o = 1'b1;
                        fault_request_code_o  = SCR1_FAULT_BOOT_PROTECTION;
                        fault_event_comb      = SCR1_EVENT_FAULT;
                    end
                    else if (cmd_valid_safe && (cmd_i != SCR1_CMD_START)) begin
                        fault_request_valid_o = 1'b1;
                        fault_request_code_o  = SCR1_FAULT_ILLEGAL_TRANSITION;
                        fault_event_comb      = SCR1_EVENT_FAULT;
                    end
                    else if (start_command_attempt && start_token_replay) begin
                        fault_request_valid_o = 1'b1;
                        fault_request_code_o  = SCR1_FAULT_ILLEGAL_TRANSITION;
                        fault_event_comb      = SCR1_EVENT_FAULT;
                    end
                end

                SCR1_LC_STARTING: begin
                    if (hw_fault_valid_i) begin
                        fault_request_valid_o = 1'b1;
                        fault_request_code_o  = hw_fault_code_i;

                        if ((hw_fault_code_i == SCR1_FAULT_AXI_SLVERR)
                            || (hw_fault_code_i == SCR1_FAULT_AXI_DECERR)
                            || (hw_fault_code_i == SCR1_FAULT_ADDRESS_VIOLATION)) begin
                            fault_event_comb = SCR1_EVENT_AXI_ERROR;
                        end
                        else begin
                            fault_event_comb = SCR1_EVENT_FAULT;
                        end
                    end
                    else if (boot_violation_i) begin
                        fault_request_valid_o = 1'b1;
                        fault_request_code_o  = SCR1_FAULT_BOOT_PROTECTION;
                        fault_event_comb      = SCR1_EVENT_FAULT;
                    end
                    else if (cmd_valid_safe) begin
                        fault_request_valid_o = 1'b1;
                        fault_request_code_o  = SCR1_FAULT_ILLEGAL_TRANSITION;
                        fault_event_comb      = SCR1_EVENT_FAULT;
                    end
                    else if (!software_start_confirmed && start_timeout_expired) begin
                        fault_request_valid_o = 1'b1;
                        fault_request_code_o  = SCR1_FAULT_TIMEOUT;
                        fault_event_comb      = SCR1_EVENT_START_TIMEOUT;
                    end
                end

                SCR1_LC_RUNNING: begin
                    if (hw_fault_valid_i) begin
                        fault_request_valid_o = 1'b1;
                        fault_request_code_o  = hw_fault_code_i;

                        if ((hw_fault_code_i == SCR1_FAULT_AXI_SLVERR)
                            || (hw_fault_code_i == SCR1_FAULT_AXI_DECERR)
                            || (hw_fault_code_i == SCR1_FAULT_ADDRESS_VIOLATION)) begin
                            fault_event_comb = SCR1_EVENT_AXI_ERROR;
                        end
                        else begin
                            fault_event_comb = SCR1_EVENT_FAULT;
                        end
                    end
                    else if (boot_violation_i) begin
                        fault_request_valid_o = 1'b1;
                        fault_request_code_o  = SCR1_FAULT_BOOT_PROTECTION;
                        fault_event_comb      = SCR1_EVENT_FAULT;
                    end
                    else if (watchdog_timeout_expired) begin
                        fault_request_valid_o = 1'b1;
                        fault_request_code_o  = SCR1_FAULT_WATCHDOG;
                        fault_event_comb      = SCR1_EVENT_WATCHDOG_TIMEOUT;
                    end
                    else if (cmd_valid_safe
                            && !(cmd_i == SCR1_CMD_HALT
                                || cmd_i == SCR1_CMD_QUIESCE
                                || cmd_i == SCR1_CMD_SOFT_RESET)) begin
                        fault_request_valid_o = 1'b1;
                        fault_request_code_o  = SCR1_FAULT_ILLEGAL_TRANSITION;
                        fault_event_comb      = SCR1_EVENT_FAULT;
                    end
                end

                SCR1_LC_QUIESCING: begin
                    if (hw_fault_valid_i) begin
                        fault_request_valid_o = 1'b1;
                        fault_request_code_o  = hw_fault_code_i;

                        if ((hw_fault_code_i == SCR1_FAULT_AXI_SLVERR)
                            || (hw_fault_code_i == SCR1_FAULT_AXI_DECERR)
                            || (hw_fault_code_i == SCR1_FAULT_ADDRESS_VIOLATION)) begin
                            fault_event_comb = SCR1_EVENT_AXI_ERROR;
                        end
                        else begin
                            fault_event_comb = SCR1_EVENT_FAULT;
                        end
                    end
                    else if (boot_violation_i) begin
                        fault_request_valid_o = 1'b1;
                        fault_request_code_o  = SCR1_FAULT_BOOT_PROTECTION;
                        fault_event_comb      = SCR1_EVENT_FAULT;
                    end
                    else if (quiesce_timeout_expired) begin
                        fault_request_valid_o = 1'b1;
                        fault_request_code_o  = SCR1_FAULT_TIMEOUT;
                        fault_event_comb      = SCR1_EVENT_QUIESCE_TIMEOUT;
                    end
                    else if (cmd_valid_safe) begin
                        fault_request_valid_o = 1'b1;
                        fault_request_code_o  = SCR1_FAULT_ILLEGAL_TRANSITION;
                        fault_event_comb      = SCR1_EVENT_FAULT;
                    end
                    else if (axi_quiescent_i
                            && !(reason_quiescing_q == SCR1_CMD_HALT
                                || reason_quiescing_q == SCR1_CMD_QUIESCE
                                || reason_quiescing_q == SCR1_CMD_SOFT_RESET)) begin
                        fault_request_valid_o = 1'b1;
                        fault_request_code_o  = SCR1_FAULT_ILLEGAL_TRANSITION;
                        fault_event_comb      = SCR1_EVENT_FAULT;
                    end
                end

                SCR1_LC_HALTED: begin
                    if (boot_violation_i) begin
                        fault_request_valid_o = 1'b1;
                        fault_request_code_o  = SCR1_FAULT_BOOT_PROTECTION;
                        fault_event_comb      = SCR1_EVENT_FAULT;
                    end
                    else if (cmd_valid_safe
                            && !(cmd_i == SCR1_CMD_LOAD
                                || cmd_i == SCR1_CMD_SOFT_RESET)) begin
                        fault_request_valid_o = 1'b1;
                        fault_request_code_o  = SCR1_FAULT_ILLEGAL_TRANSITION;
                        fault_event_comb      = SCR1_EVENT_FAULT;
                    end
                end

                SCR1_LC_FAULT: begin

                end

                default: begin
                    fault_request_valid_o = 1'b1;
                    fault_request_code_o  = SCR1_FAULT_ILLEGAL_TRANSITION;
                    fault_event_comb      = SCR1_EVENT_FAULT;
                end
            endcase
        end
    end

// Event encoder
    always_comb begin
        event_valid_o = 1'b0;
        event_o       = SCR1_EVENT_NONE;

        if (rst_n) begin
            if (fault_request_valid_o) begin
                event_valid_o = 1'b1;
                event_o       = fault_event_comb;
            end
            else if ((state_q == SCR1_LC_STARTING)
                    && software_start_confirmed) begin
                event_valid_o = 1'b1;
                event_o       = SCR1_EVENT_SW_READY;
            end
            else if ((state_q == SCR1_LC_RUNNING)
                    && software_app_done) begin
                event_valid_o = 1'b1;
                event_o       = SCR1_EVENT_APP_DONE;
            end
            else if ((state_q == SCR1_LC_RUNNING)
                    && software_app_error) begin
                event_valid_o = 1'b1;
                event_o       = SCR1_EVENT_SW_EVENT;
            end
        end
    end
// clear fault pulse
    always_ff @(posedge clk) begin
        if (!rst_n) begin
            clear_fault_pulse_o <= 1'b0;
        end
        else if (state_q == SCR1_LC_FAULT
                && cmd_valid_safe
                && (cmd_i == SCR1_CMD_CLEAR_FAULT)) begin

            clear_fault_pulse_o <= 1'b1;
        end
        else begin
            clear_fault_pulse_o <= 1'b0;
        end
    end
// start timeout counter
    always_ff @(posedge clk) begin
        if (!rst_n || state_q != SCR1_LC_STARTING) begin
            start_timer_counter <= '0;
        end
        else if (start_timeout_i == 32'd0) begin
            start_timer_counter <= '0;
        end
        else begin
            start_timer_counter <= start_timer_counter + 1'b1;
        end
    end

// start timeout detection
    always_comb begin
        start_timeout_expired = 1'b0;

        if (state_q == SCR1_LC_STARTING) begin
            if (start_timeout_i != 32'd0) begin
                if (start_timer_counter >= (start_timeout_i - 32'd1)) begin
                    start_timeout_expired = 1'b1;
                end
            end
        end
    end

// quiesce timeout counter
    always_ff @(posedge clk) begin
        if(!rst_n || state_q != SCR1_LC_QUIESCING) begin
            quiesce_timer_counter <= '0;
        end
        else if (quiesce_timeout_i == 32'd0) begin
            quiesce_timer_counter <= '0;
        end
        else begin
            quiesce_timer_counter <= quiesce_timer_counter + 1'b1;
        end
    end

// quiesce timeout detection
    always_comb begin
        quiesce_timeout_expired = 1'b0;

        if (state_q == SCR1_LC_QUIESCING) begin
            if (quiesce_timeout_i != 32'd0) begin
                if (quiesce_timer_counter >= (quiesce_timeout_i - 32'd1)) begin
                    quiesce_timeout_expired = 1'b1;
                end
            end
        end
    end

// watchdog timeout counter
    always_ff @(posedge clk) begin
        if (!rst_n
            || state_q != SCR1_LC_RUNNING
            || watchdog_cfg_i == '0
            || completion_pending_q
            || watchdog_kick_pulse_i
            || software_app_done) begin

                watchdog_timer_counter <= '0;
            end
        else begin
            watchdog_timer_counter <= watchdog_timer_counter + 1'b1;
        end
    end

// watchdog timeout detection
    always_comb begin
        watchdog_timeout_expired = 1'b0;

        if (state_q == SCR1_LC_RUNNING) begin
            if (watchdog_cfg_i != 32'd0) begin
                if (watchdog_timer_counter >= (watchdog_cfg_i - 32'd1)
                    && !completion_pending_q
                    && !watchdog_kick_pulse_i
                    && !software_app_done) begin
                    watchdog_timeout_expired = 1'b1;
                end
            end
        end
    end
//software complition
    always_ff @(posedge clk) begin
        if (!rst_n) begin
            completion_pending_q <= '0;
        end
        else if (software_app_done
                && (state_q == SCR1_LC_RUNNING)
                && !fault_request_valid_o) begin
            completion_pending_q <= '1;
        end
        else if (state_q == SCR1_LC_RESET 
                && cmd_valid_safe 
                && (cmd_i == SCR1_CMD_LOAD)) begin
            completion_pending_q <= '0;
        end
        else if (state_q == SCR1_LC_HALTED 
                && cmd_valid_safe
                && (cmd_i == SCR1_CMD_LOAD)) begin
            completion_pending_q <= '0;
         end
    end

    always_comb begin
        software_app_done  = sw_status_write_pulse_i && (sw_status_i == SCR1_SW_STATUS_APP_DONE);
        software_app_error = sw_status_write_pulse_i && (sw_status_i == SCR1_SW_STATUS_APP_ERROR);

        completion_pending_o = completion_pending_q;
    end

    assign lifecycle_state_o = state_q;




// -----------------------------------------------------------------------------
// Assertions / protocol checks
// -----------------------------------------------------------------------------
`ifndef SYNTHESIS

    property p_reset_safe_outputs;
        @(posedge clk)
        (!rst_n) |-> (!scr1_cpu_rst_n_o
                   && !scr1_master_enable_o
                   && !launch_cfg_write_enable_o
                   && !boot_crc_write_enable_o
                   && !boot_write_allowed_o);
    endproperty

    property p_reset_state;
        @(posedge clk)
        (!rst_n) |=> (state_q == SCR1_LC_RESET);
    endproperty

    property p_reset_outputs;
        @(posedge clk) disable iff (!rst_n)
        (state_q == SCR1_LC_RESET) |-> (!scr1_cpu_rst_n_o
                                     && !scr1_master_enable_o
                                     && launch_cfg_write_enable_o
                                     && boot_crc_write_enable_o
                                     && boot_write_allowed_o);
    endproperty

    property p_loading_outputs;
        @(posedge clk) disable iff (!rst_n)
        (state_q == SCR1_LC_LOADING) |-> (!scr1_cpu_rst_n_o
                                       && !scr1_master_enable_o
                                       && launch_cfg_write_enable_o
                                       && boot_crc_write_enable_o
                                       && boot_write_allowed_o);
    endproperty

    property p_ready_outputs;
        @(posedge clk) disable iff (!rst_n)
        (state_q == SCR1_LC_READY) |-> (!scr1_cpu_rst_n_o
                                     && !scr1_master_enable_o
                                     && !launch_cfg_write_enable_o
                                     && !boot_crc_write_enable_o
                                     && !boot_write_allowed_o);
    endproperty

    property p_starting_outputs;
        @(posedge clk) disable iff (!rst_n)
        (state_q == SCR1_LC_STARTING) |-> (scr1_cpu_rst_n_o
                                        && scr1_master_enable_o
                                        && !launch_cfg_write_enable_o
                                        && !boot_crc_write_enable_o
                                        && !boot_write_allowed_o);
    endproperty

    property p_running_outputs;
        @(posedge clk) disable iff (!rst_n)
        (state_q == SCR1_LC_RUNNING) |-> (scr1_cpu_rst_n_o
                                       && scr1_master_enable_o
                                       && !launch_cfg_write_enable_o
                                       && !boot_crc_write_enable_o
                                       && !boot_write_allowed_o);
    endproperty

    property p_quiescing_outputs;
        @(posedge clk) disable iff (!rst_n)
        (state_q == SCR1_LC_QUIESCING) |-> (scr1_cpu_rst_n_o
                                         && !scr1_master_enable_o
                                         && !launch_cfg_write_enable_o
                                         && !boot_crc_write_enable_o
                                         && !boot_write_allowed_o);
    endproperty

    property p_halted_outputs;
        @(posedge clk) disable iff (!rst_n)
        (state_q == SCR1_LC_HALTED) |-> (!scr1_cpu_rst_n_o
                                      && !scr1_master_enable_o
                                      && !launch_cfg_write_enable_o
                                      && !boot_crc_write_enable_o
                                      && !boot_write_allowed_o);
    endproperty

    property p_fault_outputs;
        @(posedge clk) disable iff (!rst_n)
        (state_q == SCR1_LC_FAULT) |-> (!scr1_cpu_rst_n_o
                                     && !scr1_master_enable_o
                                     && !launch_cfg_write_enable_o
                                     && !boot_crc_write_enable_o
                                     && !boot_write_allowed_o);
    endproperty

    property p_fault_sticky;
        @(posedge clk) disable iff (!rst_n)
        ((state_q == SCR1_LC_FAULT)
         && !(cmd_valid_safe && (cmd_i == SCR1_CMD_CLEAR_FAULT)))
        |=> (state_q == SCR1_LC_FAULT);
    endproperty

    property p_clear_fault_transition;
        @(posedge clk) disable iff (!rst_n)
        ((state_q == SCR1_LC_FAULT)
         && cmd_valid_safe
         && (cmd_i == SCR1_CMD_CLEAR_FAULT))
        |=> (state_q == SCR1_LC_RESET);
    endproperty

    property p_reset_load_transition;
        @(posedge clk) disable iff (!rst_n)
        ((state_q == SCR1_LC_RESET)
         && cmd_valid_safe
         && (cmd_i == SCR1_CMD_LOAD))
        |=> (state_q == SCR1_LC_LOADING);
    endproperty

    property p_start_command_accepted;
        @(posedge clk) disable iff (!rst_n)
        start_command_accepted |=> (state_q == SCR1_LC_STARTING);
    endproperty

    property p_start_token_replay_fault;
        @(posedge clk) disable iff (!rst_n)
        (start_command_attempt && start_token_replay)
        |=> (state_q == SCR1_LC_FAULT);
    endproperty

    property p_start_timeout_disabled;
        @(posedge clk) disable iff (!rst_n)
        ((state_q == SCR1_LC_STARTING) && (start_timeout_i == 32'd0))
        |-> !start_timeout_expired;
    endproperty

    property p_quiesce_timeout_disabled;
        @(posedge clk) disable iff (!rst_n)
        ((state_q == SCR1_LC_QUIESCING) && (quiesce_timeout_i == 32'd0))
        |-> !quiesce_timeout_expired;
    endproperty

    property p_watchdog_disabled;
        @(posedge clk) disable iff (!rst_n)
        ((state_q == SCR1_LC_RUNNING) && (watchdog_cfg_i == 32'd0))
        |-> !watchdog_timeout_expired;
    endproperty

    property p_watchdog_kick_suppresses_timeout;
        @(posedge clk) disable iff (!rst_n)
        ((state_q == SCR1_LC_RUNNING) && watchdog_kick_pulse_i)
        |-> !watchdog_timeout_expired;
    endproperty

    property p_app_done_suppresses_watchdog_timeout;
        @(posedge clk) disable iff (!rst_n)
        ((state_q == SCR1_LC_RUNNING) && software_app_done)
        |-> !watchdog_timeout_expired;
    endproperty

    property p_event_has_code;
        @(posedge clk) disable iff (!rst_n)
        event_valid_o |-> (event_o != SCR1_EVENT_NONE);
    endproperty

    property p_fault_request_has_code;
        @(posedge clk) disable iff (!rst_n)
        fault_request_valid_o |-> (fault_request_code_o != SCR1_FAULT_NONE);
    endproperty

    property p_fault_state_no_new_fault_request;
        @(posedge clk) disable iff (!rst_n)
        (state_q == SCR1_LC_FAULT) |-> !fault_request_valid_o;
    endproperty

    property p_completion_pending_sticky;
        @(posedge clk) disable iff (!rst_n)
        (completion_pending_q
         && !((state_q == SCR1_LC_RESET)
              && cmd_valid_safe
              && (cmd_i == SCR1_CMD_LOAD))
         && !((state_q == SCR1_LC_HALTED)
              && cmd_valid_safe
              && (cmd_i == SCR1_CMD_LOAD)))
        |=> completion_pending_q;
    endproperty

    property p_invalid_state_defensive;
        @(posedge clk) disable iff (!rst_n)
        (!(state_q inside {SCR1_LC_OFF,
                           SCR1_LC_RESET,
                           SCR1_LC_LOADING,
                           SCR1_LC_READY,
                           SCR1_LC_STARTING,
                           SCR1_LC_RUNNING,
                           SCR1_LC_QUIESCING,
                           SCR1_LC_HALTED,
                           SCR1_LC_FAULT}))
        |-> ((state_n == SCR1_LC_FAULT)
             && !scr1_cpu_rst_n_o
             && !scr1_master_enable_o
             && fault_request_valid_o
             && (fault_request_code_o == SCR1_FAULT_ILLEGAL_TRANSITION));
    endproperty

    a_reset_safe_outputs:
        assert property (p_reset_safe_outputs)
        else $error("scr1_lifecycle_fsm: unsafe outputs while reset is asserted");

    a_reset_state:
        assert property (p_reset_state)
        else $error("scr1_lifecycle_fsm: state did not return to RESET after reset");

    a_reset_outputs:
        assert property (p_reset_outputs)
        else $error("scr1_lifecycle_fsm: RESET outputs are invalid");

    a_loading_outputs:
        assert property (p_loading_outputs)
        else $error("scr1_lifecycle_fsm: LOADING outputs are invalid");

    a_ready_outputs:
        assert property (p_ready_outputs)
        else $error("scr1_lifecycle_fsm: READY outputs are invalid");

    a_starting_outputs:
        assert property (p_starting_outputs)
        else $error("scr1_lifecycle_fsm: STARTING outputs are invalid");

    a_running_outputs:
        assert property (p_running_outputs)
        else $error("scr1_lifecycle_fsm: RUNNING outputs are invalid");

    a_quiescing_outputs:
        assert property (p_quiescing_outputs)
        else $error("scr1_lifecycle_fsm: QUIESCING outputs are invalid");

    a_halted_outputs:
        assert property (p_halted_outputs)
        else $error("scr1_lifecycle_fsm: HALTED outputs are invalid");

    a_fault_outputs:
        assert property (p_fault_outputs)
        else $error("scr1_lifecycle_fsm: FAULT outputs are invalid");

    a_fault_sticky:
        assert property (p_fault_sticky)
        else $error("scr1_lifecycle_fsm: FAULT is not sticky");

    a_clear_fault_transition:
        assert property (p_clear_fault_transition)
        else $error("scr1_lifecycle_fsm: CLEAR_FAULT did not return FSM to RESET");

    a_reset_load_transition:
        assert property (p_reset_load_transition)
        else $error("scr1_lifecycle_fsm: LOAD was not accepted from RESET");

    a_start_command_accepted:
        assert property (p_start_command_accepted)
        else $error("scr1_lifecycle_fsm: accepted START did not enter STARTING");

    a_start_token_replay_fault:
        assert property (p_start_token_replay_fault)
        else $error("scr1_lifecycle_fsm: repeated START_TOKEN did not fault");

    a_start_timeout_disabled:
        assert property (p_start_timeout_disabled)
        else $error("scr1_lifecycle_fsm: START timeout fired while disabled");

    a_quiesce_timeout_disabled:
        assert property (p_quiesce_timeout_disabled)
        else $error("scr1_lifecycle_fsm: QUIESCE timeout fired while disabled");

    a_watchdog_disabled:
        assert property (p_watchdog_disabled)
        else $error("scr1_lifecycle_fsm: watchdog fired while disabled");

    a_watchdog_kick_suppresses_timeout:
        assert property (p_watchdog_kick_suppresses_timeout)
        else $error("scr1_lifecycle_fsm: watchdog timeout won over watchdog kick");

    a_app_done_suppresses_watchdog_timeout:
        assert property (p_app_done_suppresses_watchdog_timeout)
        else $error("scr1_lifecycle_fsm: watchdog timeout won over APP_DONE");

    a_event_has_code:
        assert property (p_event_has_code)
        else $error("scr1_lifecycle_fsm: event_valid asserted with NONE event");

    a_fault_request_has_code:
        assert property (p_fault_request_has_code)
        else $error("scr1_lifecycle_fsm: fault request asserted with NONE code");

    a_fault_state_no_new_fault_request:
        assert property (p_fault_state_no_new_fault_request)
        else $error("scr1_lifecycle_fsm: FAULT state repeated a fault request");

    a_completion_pending_sticky:
        assert property (p_completion_pending_sticky)
        else $error("scr1_lifecycle_fsm: completion_pending lost before next LOAD");

    a_invalid_state_defensive:
        assert property (p_invalid_state_defensive)
        else $error("scr1_lifecycle_fsm: invalid state did not select defensive FAULT behavior");


    property p_running_stop_command_to_quiescing;
        @(posedge clk) disable iff (!rst_n)
        ((state_q == SCR1_LC_RUNNING)
         && !hw_fault_valid_i
         && !boot_violation_i
         && !watchdog_timeout_expired
         && cmd_valid_safe
         && (cmd_i inside {SCR1_CMD_HALT,
                           SCR1_CMD_QUIESCE,
                           SCR1_CMD_SOFT_RESET}))
        |=> (state_q == SCR1_LC_QUIESCING);
    endproperty

    property p_quiescing_halt_to_halted;
        @(posedge clk) disable iff (!rst_n)
        ((state_q == SCR1_LC_QUIESCING)
         && !hw_fault_valid_i
         && !boot_violation_i
         && !quiesce_timeout_expired
         && !cmd_valid_safe
         && axi_quiescent_i
         && (reason_quiescing_q inside {SCR1_CMD_HALT, SCR1_CMD_QUIESCE}))
        |=> (state_q == SCR1_LC_HALTED);
    endproperty

    property p_quiescing_soft_reset_to_reset;
        @(posedge clk) disable iff (!rst_n)
        ((state_q == SCR1_LC_QUIESCING)
         && !hw_fault_valid_i
         && !boot_violation_i
         && !quiesce_timeout_expired
         && !cmd_valid_safe
         && axi_quiescent_i
         && (reason_quiescing_q == SCR1_CMD_SOFT_RESET))
        |=> (state_q == SCR1_LC_RESET);
    endproperty

    property p_hw_fault_enters_fault;
        @(posedge clk) disable iff (!rst_n)
        ((state_q inside {SCR1_LC_STARTING,
                          SCR1_LC_RUNNING,
                          SCR1_LC_QUIESCING})
         && hw_fault_valid_i)
        |=> (state_q == SCR1_LC_FAULT);
    endproperty

    property p_boot_violation_enters_fault;
        @(posedge clk) disable iff (!rst_n)
        ((state_q inside {SCR1_LC_READY,
                          SCR1_LC_STARTING,
                          SCR1_LC_RUNNING,
                          SCR1_LC_QUIESCING,
                          SCR1_LC_HALTED})
         && boot_violation_i)
        |=> (state_q == SCR1_LC_FAULT);
    endproperty

    property p_illegal_reset_command_enters_fault;
        @(posedge clk) disable iff (!rst_n)
        ((state_q == SCR1_LC_RESET)
         && cmd_valid_safe
         && (cmd_i != SCR1_CMD_LOAD))
        |=> (state_q == SCR1_LC_FAULT);
    endproperty

    property p_clear_fault_pulse_source;
        @(posedge clk) disable iff (!rst_n)
        clear_fault_pulse_o
        |-> ($past(state_q) == SCR1_LC_FAULT
             && $past(cmd_valid_safe)
             && ($past(cmd_i) == SCR1_CMD_CLEAR_FAULT));
    endproperty

    a_running_stop_command_to_quiescing:
        assert property (p_running_stop_command_to_quiescing)
        else $error("scr1_lifecycle_fsm: legal stop command did not enter QUIESCING");

    a_quiescing_halt_to_halted:
        assert property (p_quiescing_halt_to_halted)
        else $error("scr1_lifecycle_fsm: drained HALT/QUIESCE did not enter HALTED");

    a_quiescing_soft_reset_to_reset:
        assert property (p_quiescing_soft_reset_to_reset)
        else $error("scr1_lifecycle_fsm: drained SOFT_RESET did not enter RESET");

    a_hw_fault_enters_fault:
        assert property (p_hw_fault_enters_fault)
        else $error("scr1_lifecycle_fsm: hardware fault did not enter FAULT");

    a_boot_violation_enters_fault:
        assert property (p_boot_violation_enters_fault)
        else $error("scr1_lifecycle_fsm: Boot BRAM violation did not enter FAULT");

    a_illegal_reset_command_enters_fault:
        assert property (p_illegal_reset_command_enters_fault)
        else $error("scr1_lifecycle_fsm: illegal RESET command did not enter FAULT");

    a_clear_fault_pulse_source:
        assert property (p_clear_fault_pulse_source)
        else $error("scr1_lifecycle_fsm: clear_fault_pulse has no legal CLEAR_FAULT source");

`endif

endmodule