import scr1_regs_pkg::*;
import vd100_scr1_pkg::*;
module scr1_control #(
    parameter int unsigned AXIL_ADDR_WIDTH =
        scr1_regs_pkg::SCR1_REG_ADDR_WIDTH,
    parameter int unsigned AXIL_DATA_WIDTH =
        scr1_regs_pkg::SCR1_REG_DATA_WIDTH,
    parameter int unsigned OUTSTANDING_WIDTH = 4,
    parameter bit VERIFY_REQUIRED = 1'b0,
    parameter logic [31:0] BOOT_ADDR_VALUE = 32'hFFFF_0000
) (

    // -------------------------------------------------------------------------
    // Clock / platform reset

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
    // Platform readiness

    // -------------------------------------------------------------------------
    input  logic                           clock_locked_i,
    input  logic                           noc_ready_i,
    input  logic                           ddr_ready_i,
    input  logic                           verifier_ready_i,

    // -------------------------------------------------------------------------
    // SCR1 AXI monitor / drain status

    // -------------------------------------------------------------------------
    input  logic [OUTSTANDING_WIDTH-1:0]   imem_outstanding_i,
    input  logic [OUTSTANDING_WIDTH-1:0]   dmem_read_outstanding_i,
    input  logic [OUTSTANDING_WIDTH-1:0]   dmem_write_outstanding_i,
    input  logic                           axi_quiescent_i,

    // -------------------------------------------------------------------------
    // Hardware fault from AXI monitor

    // -------------------------------------------------------------------------
    input  logic                             hw_fault_valid_i,
    input  vd100_scr1_pkg::scr1_fault_code_e hw_fault_code_i,
    input  logic [31:0]                      hw_fault_info0_i,
    input  logic [31:0]                      hw_fault_info1_i,

    // -------------------------------------------------------------------------
    // Boot BRAM protection violation

    // -------------------------------------------------------------------------
    input  logic                           boot_violation_i,
    input  logic [31:0]                    boot_violation_addr_i,

    // -------------------------------------------------------------------------
    // SCR1 lifecycle control

    // -------------------------------------------------------------------------
    output logic                           scr1_cpu_rst_no,
    output logic                           scr1_master_enable_o,
    output logic                           scr1_quiesce_req_o,

    // -------------------------------------------------------------------------
    // Boot BRAM write policy

    // -------------------------------------------------------------------------
    output logic                           boot_bram_host_write_enable_o,

    // -------------------------------------------------------------------------
    // Clear sticky faults in external monitor / guard

    // -------------------------------------------------------------------------
    output logic                           clear_fault_o,

    // -------------------------------------------------------------------------
    // Launch configuration

    // -------------------------------------------------------------------------
    output logic [31:0]                    fw_desc_addr_o,
    output logic [31:0]                    fw_desc_size_o,
    output logic [31:0]                    start_token_o,

    // -------------------------------------------------------------------------
    // Interrupt / lifecycle observation

    // -------------------------------------------------------------------------
    output logic                           irq_to_a72_o,
    output vd100_scr1_pkg::scr1_lifecycle_state_e lifecycle_state_o
);
    logic                                      cmd_valid;
    scr1_lifecycle_cmd_e                       cmd;
    logic [31:0]                               fw_desc_addr;
    logic [31:0]                               fw_desc_size;
    logic [31:0]                               start_token;
    logic [31:0]                               start_timeout;
    logic [31:0]                               quiesce_timeout;
    logic [31:0]                               watchdog_cfg;
    logic                                      watchdog_kick_pulse;
    logic [31:0]                               boot_crc_expected;
    logic [31:0]                               boot_crc_observed;
    logic [31:0]                               sw_status;
    logic                                      sw_status_write_pulse;
    logic [31:0]                               sw_error;
    logic                                      sw_error_write_pulse;
    logic                                      dependencies_ready;
    logic                                      image_config_valid;
    scr1_lifecycle_state_e                     lifecycle_state;
    logic                                      completion_pending;
    logic                                      scr1_cpu_rst_n;
    logic                                      scr1_master_enable;
    logic                                      launch_cfg_write_enable;
    logic                                      boot_crc_write_enable;
    logic                                      boot_write_allowed;
    logic                                      clear_fault_pulse;
    logic                                      event_valid;
    scr1_event_e                               event_code;
    logic                                      fault_request_valid;
    scr1_fault_code_e                          fault_request_code;
    logic [31:0]                               fault_context_pc;
    logic [31:0]                               fault_context_info0;
    logic [31:0]                               fault_context_info1;
    logic [31:0]                               irq_set;
    logic [31:0]                               irq_status;
    logic [31:0]                               irq_enable;
    logic                                      primary_fault_valid;
    scr1_fault_code_e                          primary_fault_code;
    logic [31:0]                               primary_fault_pc;
    logic [31:0]                               primary_fault_info0;
    logic [31:0]                               primary_fault_info1;
    logic [31:0]                               heartbeat;
    logic [63:0]                               cycle_count;

    assign dependencies_ready = clock_locked_i
                              && noc_ready_i
                              && ddr_ready_i;

    assign image_config_valid = (fw_desc_addr != 32'd0)
                             && (fw_desc_size != 32'd0);

    scr1_control_axil #(
        .AXIL_ADDR_WIDTH   (AXIL_ADDR_WIDTH),
        .AXIL_DATA_WIDTH   (AXIL_DATA_WIDTH),
        .OUTSTANDING_WIDTH (OUTSTANDING_WIDTH),
        .VERIFY_REQUIRED   (VERIFY_REQUIRED)
    ) u_scr1_control_axil (
        .clk                         (clk),
        .rst_n                       (rst_n),
        .s_axil_awaddr_i             (s_axil_awaddr_i),
        .s_axil_awprot_i             (s_axil_awprot_i),
        .s_axil_awvalid_i            (s_axil_awvalid_i),
        .s_axil_awready_o            (s_axil_awready_o),
        .s_axil_wdata_i              (s_axil_wdata_i),
        .s_axil_wstrb_i              (s_axil_wstrb_i),
        .s_axil_wvalid_i             (s_axil_wvalid_i),
        .s_axil_wready_o             (s_axil_wready_o),
        .s_axil_bresp_o              (s_axil_bresp_o),
        .s_axil_bvalid_o             (s_axil_bvalid_o),
        .s_axil_bready_i             (s_axil_bready_i),
        .s_axil_araddr_i             (s_axil_araddr_i),
        .s_axil_arprot_i             (s_axil_arprot_i),
        .s_axil_arvalid_i            (s_axil_arvalid_i),
        .s_axil_arready_o            (s_axil_arready_o),
        .s_axil_rdata_o              (s_axil_rdata_o),
        .s_axil_rresp_o              (s_axil_rresp_o),
        .s_axil_rvalid_o             (s_axil_rvalid_o),
        .s_axil_rready_i             (s_axil_rready_i),
        .launch_cfg_write_enable_i    (launch_cfg_write_enable),
        .boot_crc_write_enable_i      (boot_crc_write_enable),
        .lifecycle_state_i            (lifecycle_state),
        .dependencies_ready_i         (dependencies_ready),
        .image_config_valid_i         (image_config_valid),
        .axi_quiescent_i              (axi_quiescent_i),
        .boot_write_allowed_i         (boot_write_allowed),
        .verifier_ready_i             (verifier_ready_i),
        .completion_pending_i         (completion_pending),
        .boot_addr_i                  (BOOT_ADDR_VALUE),
        .imem_outstanding_i           (imem_outstanding_i),
        .dmem_read_outstanding_i      (dmem_read_outstanding_i),
        .dmem_write_outstanding_i     (dmem_write_outstanding_i),
        .fault_code_i                 (primary_fault_code),
        .fault_pc_i                   (primary_fault_pc),
        .fault_info0_i                (primary_fault_info0),
        .fault_info1_i                (primary_fault_info1),
        .heartbeat_i                  (heartbeat),
        .cycle_count_i                (cycle_count),
        .irq_set_i                    (irq_set),
        .irq_status_o                 (irq_status),
        .irq_enable_o                 (irq_enable),
        .cmd_valid_o                  (cmd_valid),
        .cmd_o                        (cmd),
        .fw_desc_addr_o               (fw_desc_addr),
        .fw_desc_size_o               (fw_desc_size),
        .start_token_o                (start_token),
        .start_timeout_o              (start_timeout),
        .quiesce_timeout_o            (quiesce_timeout),
        .watchdog_cfg_o               (watchdog_cfg),
        .watchdog_kick_pulse_o        (watchdog_kick_pulse),
        .boot_crc_expected_o          (boot_crc_expected),
        .boot_crc_observed_o          (boot_crc_observed),
        .sw_status_o                  (sw_status),
        .sw_status_write_pulse_o      (sw_status_write_pulse),
        .sw_error_o                   (sw_error),
        .sw_error_write_pulse_o       (sw_error_write_pulse)
    );

    scr1_lifecycle_fsm #(
        .VERIFY_REQUIRED (VERIFY_REQUIRED)
    ) u_scr1_lifecycle_fsm (
        .clk                         (clk),
        .rst_n                       (rst_n),
        .cmd_valid_i (cmd_valid && ((cmd != SCR1_CMD_CLEAR_FAULT) || axi_quiescent_i)),
        .cmd_i                       (cmd),
        .dependencies_ready_i        (dependencies_ready),
        .image_config_valid_i        (image_config_valid),
        .verifier_ready_i            (verifier_ready_i),
        .axi_quiescent_i             (axi_quiescent_i),
        .hw_fault_valid_i            (hw_fault_valid_i),
        .hw_fault_code_i             (hw_fault_code_i),
        .boot_violation_i            (boot_violation_i),
        .start_timeout_i             (start_timeout),
        .quiesce_timeout_i           (quiesce_timeout),
        .watchdog_cfg_i              (watchdog_cfg),
        .start_token_i               (start_token),
        .watchdog_kick_pulse_i       (watchdog_kick_pulse),
        .sw_status_i                 (sw_status),
        .sw_status_write_pulse_i     (sw_status_write_pulse),
        .lifecycle_state_o           (lifecycle_state),
        .scr1_cpu_rst_n_o            (scr1_cpu_rst_n),
        .scr1_master_enable_o        (scr1_master_enable),
        .launch_cfg_write_enable_o   (launch_cfg_write_enable),
        .boot_crc_write_enable_o     (boot_crc_write_enable),
        .boot_write_allowed_o        (boot_write_allowed),
        .clear_fault_pulse_o         (clear_fault_pulse),
        .event_valid_o               (event_valid),
        .event_o                     (event_code),
        .fault_request_valid_o       (fault_request_valid),
        .fault_request_code_o        (fault_request_code),
        .completion_pending_o        (completion_pending)
    );

    always_comb begin
        fault_context_pc    = 32'd0;
        fault_context_info0 = 32'd0;
        fault_context_info1 = 32'd0;
        if (fault_request_valid) begin
            if (hw_fault_valid_i
                && (fault_request_code == hw_fault_code_i)) begin
                fault_context_info0 = hw_fault_info0_i;
                fault_context_info1 = hw_fault_info1_i;
            end
            else if (boot_violation_i
                    && (fault_request_code == SCR1_FAULT_BOOT_PROTECTION)) begin
                fault_context_info0 = boot_violation_addr_i;
            end
        end
    end

    scr1_fault_irq_aggregator u_scr1_fault_irq_aggregator (
        .clk                     (clk),
        .rst_n                   (rst_n),
        .event_valid_i           (event_valid),
        .event_i                 (event_code),
        .fault_request_valid_i   (fault_request_valid),
        .fault_request_code_i    (fault_request_code),
        .fault_pc_i              (fault_context_pc),
        .fault_info0_i           (fault_context_info0),
        .fault_info1_i           (fault_context_info1),
        .clear_fault_i           (clear_fault_pulse),
        .irq_set_o               (irq_set),
        .fault_valid_o           (primary_fault_valid),
        .fault_code_o            (primary_fault_code),
        .fault_pc_o              (primary_fault_pc),
        .fault_info0_o           (primary_fault_info0),
        .fault_info1_o           (primary_fault_info1)
    );

    assign irq_to_a72_o = |(irq_status & irq_enable);

    assign scr1_cpu_rst_no                 = scr1_cpu_rst_n;
    assign scr1_master_enable_o            = scr1_master_enable;
    assign boot_bram_host_write_enable_o   = boot_write_allowed;
    assign clear_fault_o                   = clear_fault_pulse;
    assign lifecycle_state_o               = lifecycle_state;

    assign scr1_quiesce_req_o = (lifecycle_state == SCR1_LC_QUIESCING);

    always_ff @(posedge clk) begin
        if (!rst_n) begin
            cycle_count <= '0;
        end
        else begin
            cycle_count <= cycle_count + 1'b1;
        end
    end

    always_ff @(posedge clk) begin
        if (!rst_n) begin
            heartbeat <= '0;
        end
        else if (watchdog_kick_pulse) begin
            heartbeat <= heartbeat + 1'b1;
        end
    end

    assign fw_desc_addr_o = fw_desc_addr;
    assign fw_desc_size_o = fw_desc_size;
    assign start_token_o  = start_token;


`ifndef SYNTHESIS

    property p_irq_to_a72_equation;
        @(posedge clk) disable iff (!rst_n)
        irq_to_a72_o == (|(irq_status & irq_enable));
    endproperty
    assert property (p_irq_to_a72_equation)
        else $error("scr1_control: irq_to_a72_o equation mismatch");

    property p_dependencies_ready_equation;
        @(posedge clk) disable iff (!rst_n)
        dependencies_ready == (clock_locked_i && noc_ready_i && ddr_ready_i);
    endproperty
    assert property (p_dependencies_ready_equation)
        else $error("scr1_control: dependencies_ready equation mismatch");

    property p_image_config_valid_equation;
        @(posedge clk) disable iff (!rst_n)
        image_config_valid == ((fw_desc_addr != 32'd0) &&
                               (fw_desc_size != 32'd0));
    endproperty
    assert property (p_image_config_valid_equation)
        else $error("scr1_control: image_config_valid equation mismatch");

    property p_running_control_outputs;
        @(posedge clk) disable iff (!rst_n)
        (lifecycle_state == SCR1_LC_RUNNING)
        |-> (scr1_cpu_rst_no
             && scr1_master_enable_o
             && !boot_bram_host_write_enable_o
             && !scr1_quiesce_req_o);
    endproperty
    assert property (p_running_control_outputs)
        else $error("scr1_control: invalid outputs in RUNNING");

    property p_quiescing_control_outputs;
        @(posedge clk) disable iff (!rst_n)
        (lifecycle_state == SCR1_LC_QUIESCING)
        |-> (scr1_cpu_rst_no
             && !scr1_master_enable_o
             && scr1_quiesce_req_o
             && !boot_bram_host_write_enable_o);
    endproperty
    assert property (p_quiescing_control_outputs)
        else $error("scr1_control: invalid outputs in QUIESCING");

    property p_fault_control_outputs;
        @(posedge clk) disable iff (!rst_n)
        (lifecycle_state == SCR1_LC_FAULT)
        |-> (!scr1_cpu_rst_no
             && !scr1_master_enable_o
             && !boot_bram_host_write_enable_o
             && !scr1_quiesce_req_o);
    endproperty
    assert property (p_fault_control_outputs)
        else $error("scr1_control: invalid outputs in FAULT");

    property p_quiesce_request_exact;
        @(posedge clk) disable iff (!rst_n)
        scr1_quiesce_req_o == (lifecycle_state == SCR1_LC_QUIESCING);
    endproperty
    assert property (p_quiesce_request_exact)
        else $error("scr1_control: quiesce request mismatch");

    property p_clear_fault_fanout;
        @(posedge clk) disable iff (!rst_n)
        clear_fault_o == clear_fault_pulse;
    endproperty
    assert property (p_clear_fault_fanout)
        else $error("scr1_control: clear fault fanout mismatch");

    property p_launch_outputs_mirror_registers;
        @(posedge clk) disable iff (!rst_n)
        (fw_desc_addr_o == fw_desc_addr)
        && (fw_desc_size_o == fw_desc_size)
        && (start_token_o == start_token);
    endproperty
    assert property (p_launch_outputs_mirror_registers)
        else $error("scr1_control: launch output mismatch");

    property p_cycle_counter_increments;
        @(posedge clk) disable iff (!rst_n)
        1'b1 |=> (cycle_count == ($past(cycle_count) + 64'd1));
    endproperty
    assert property (p_cycle_counter_increments)
        else $error("scr1_control: cycle_count did not increment");

    property p_heartbeat_increments_on_kick;
        @(posedge clk) disable iff (!rst_n)
        watchdog_kick_pulse
        |=> (heartbeat == ($past(heartbeat) + 32'd1));
    endproperty
    assert property (p_heartbeat_increments_on_kick)
        else $error("scr1_control: heartbeat did not increment on kick");

    property p_heartbeat_holds_without_kick;
        @(posedge clk) disable iff (!rst_n)
        !watchdog_kick_pulse
        |=> (heartbeat == $past(heartbeat));
    endproperty
    assert property (p_heartbeat_holds_without_kick)
        else $error("scr1_control: heartbeat changed without kick");

    property p_hw_fault_context_mapping;
        @(posedge clk) disable iff (!rst_n)
        (fault_request_valid
         && hw_fault_valid_i
         && (fault_request_code == hw_fault_code_i))
        |-> ((fault_context_pc == 32'd0)
             && (fault_context_info0 == hw_fault_info0_i)
             && (fault_context_info1 == hw_fault_info1_i));
    endproperty
    assert property (p_hw_fault_context_mapping)
        else $error("scr1_control: hardware fault context mismatch");

    property p_boot_fault_context_mapping;
        @(posedge clk) disable iff (!rst_n)
        (fault_request_valid
         && !hw_fault_valid_i
         && boot_violation_i
         && (fault_request_code == SCR1_FAULT_BOOT_PROTECTION))
        |-> ((fault_context_pc == 32'd0)
             && (fault_context_info0 == boot_violation_addr_i)
             && (fault_context_info1 == 32'd0));
    endproperty
    assert property (p_boot_fault_context_mapping)
        else $error("scr1_control: boot fault context mismatch");

    property p_no_unknown_control_outputs;
        @(posedge clk) disable iff (!rst_n)
        !$isunknown({
            scr1_cpu_rst_no,
            scr1_master_enable_o,
            scr1_quiesce_req_o,
            boot_bram_host_write_enable_o,
            clear_fault_o,
            irq_to_a72_o,
            lifecycle_state_o
        });
    endproperty
    assert property (p_no_unknown_control_outputs)
        else $error("scr1_control: X/Z on control outputs");
`endif

endmodule : scr1_control
