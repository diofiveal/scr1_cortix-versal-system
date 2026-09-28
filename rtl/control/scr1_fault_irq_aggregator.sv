import scr1_regs_pkg::*;
import vd100_scr1_pkg::*;


module scr1_fault_irq_aggregator (
    // -------------------------------------------------------------------------
    // Clock / reset
    // -------------------------------------------------------------------------
    input  logic                                      clk,
    input  logic                                      rst_n,

    // -------------------------------------------------------------------------
    // Lifecycle event from scr1_lifecycle_fsm
    // -------------------------------------------------------------------------
    input  logic                                      event_valid_i,
    input  vd100_scr1_pkg::scr1_event_e               event_i,

    // -------------------------------------------------------------------------
    // New fault request from scr1_lifecycle_fsm
    // -------------------------------------------------------------------------
    input  logic                                      fault_request_valid_i,
    input  vd100_scr1_pkg::scr1_fault_code_e          fault_request_code_i,

    // -------------------------------------------------------------------------
    // Context associated with the current fault request
    // -------------------------------------------------------------------------
    input  logic [31:0]                               fault_pc_i,
    input  logic [31:0]                               fault_info0_i,
    input  logic [31:0]                               fault_info1_i,

    // -------------------------------------------------------------------------
    // Clear sticky primary fault
    // -------------------------------------------------------------------------
    input  logic                                      clear_fault_i,

    // -------------------------------------------------------------------------
    // IRQ set pulses to scr1_control_axil
    // Sticky IRQ_STATUS is stored in scr1_control_axil.
    // -------------------------------------------------------------------------
    output logic [31:0]                               irq_set_o,

    // -------------------------------------------------------------------------
    // Sticky primary fault status to scr1_control_axil
    // -------------------------------------------------------------------------
    output logic                                      fault_valid_o,
    output vd100_scr1_pkg::scr1_fault_code_e          fault_code_o,
    output logic [31:0]                               fault_pc_o,
    output logic [31:0]                               fault_info0_o,
    output logic [31:0]                               fault_info1_o
);

    logic fault_valid_q;
    scr1_fault_code_e fault_code_q;
    logic [31:0] fault_pc_q;
    logic [31:0] fault_info0_q;
    logic [31:0] fault_info1_q;

//event decoder
    always_comb begin
        irq_set_o[31:0] = '0;

        if (event_valid_i) begin

            case (event_i)

                SCR1_EVENT_NONE: begin
                    irq_set_o[7:0] = '0;
                end 
                SCR1_EVENT_SW_READY: begin
                    irq_set_o[0] = 1'b1;
                end 
                SCR1_EVENT_APP_DONE: begin
                    irq_set_o[1] = 1'b1;
                end 
                SCR1_EVENT_FAULT: begin
                    irq_set_o[2] = 1'b1;
                end 
                SCR1_EVENT_WATCHDOG_TIMEOUT: begin
                    irq_set_o[3] = 1'b1;
                end 
                SCR1_EVENT_START_TIMEOUT: begin
                    irq_set_o[4] = 1'b1;
                end 
                SCR1_EVENT_QUIESCE_TIMEOUT: begin
                    irq_set_o[5] = 1'b1;
                end 
                SCR1_EVENT_AXI_ERROR: begin
                    irq_set_o[6] = 1'b1;
                end 
                SCR1_EVENT_SW_EVENT: begin
                    irq_set_o[7] = 1'b1;
                end

                default: begin
                    irq_set_o[7:0] = '0;
                end
            endcase
        end
    end

    //fault reg
    always_ff @(posedge clk) begin
        if(!rst_n) begin
            fault_valid_q <= '0;
            fault_code_q  <= SCR1_FAULT_NONE;
            fault_pc_q    <= '0;
            fault_info0_q <= '0;
            fault_info1_q <= '0;
        end
        else if (clear_fault_i && fault_request_valid_i) begin
            fault_valid_q <= 1'b1;
            fault_code_q  <= fault_request_code_i;
            fault_pc_q    <= fault_pc_i;
            fault_info0_q <= fault_info0_i;
            fault_info1_q <= fault_info1_i;
        end
        else if (clear_fault_i) begin
            fault_valid_q <= '0;
            fault_code_q  <= SCR1_FAULT_NONE;
            fault_pc_q    <= '0;
            fault_info0_q <= '0;
            fault_info1_q <= '0;
        end
        else if (fault_request_valid_i && !fault_valid_q) begin
            fault_valid_q <= 1'b1;
            fault_code_q  <= fault_request_code_i;
            fault_pc_q    <= fault_pc_i;
            fault_info0_q <= fault_info0_i;
            fault_info1_q <= fault_info1_i;
        end
    end
    
    //fault outputs
    always_comb begin
        fault_valid_o = fault_valid_q;
        fault_code_o  = fault_code_q;
        fault_pc_o    = fault_pc_q;
        fault_info0_o = fault_info0_q;
        fault_info1_o = fault_info1_q;
    end

`ifndef SYNTHESIS

    // -------------------------------------------------------------------------
    // Assertions
    // -------------------------------------------------------------------------

    // Reserved IRQ bits must never be set.
    property p_irq_reserved_zero;
        @(posedge clk)
        (irq_set_o[31:8] == '0);
    endproperty

    assert property (p_irq_reserved_zero)
        else $error("scr1_fault_irq_aggregator: reserved IRQ bits are not zero");

    // No valid lifecycle event means no IRQ set pulse.
    property p_no_event_no_irq;
        @(posedge clk)
        (!event_valid_i) |-> (irq_set_o == 32'h0000_0000);
    endproperty

    assert property (p_no_event_no_irq)
        else $error("scr1_fault_irq_aggregator: IRQ asserted without valid event");

    // EVENT_NONE must not generate an IRQ.
    property p_event_none_no_irq;
        @(posedge clk)
        (event_valid_i && (event_i == SCR1_EVENT_NONE))
        |-> (irq_set_o == 32'h0000_0000);
    endproperty

    assert property (p_event_none_no_irq)
        else $error("scr1_fault_irq_aggregator: EVENT_NONE generated IRQ");

    // Event to IRQ mapping.
    property p_irq_sw_ready;
        @(posedge clk)
        (event_valid_i && (event_i == SCR1_EVENT_SW_READY))
        |-> (irq_set_o == SCR1_IRQ_SW_READY_MASK);
    endproperty

    assert property (p_irq_sw_ready)
        else $error("scr1_fault_irq_aggregator: wrong IRQ mapping for SW_READY");

    property p_irq_app_done;
        @(posedge clk)
        (event_valid_i && (event_i == SCR1_EVENT_APP_DONE))
        |-> (irq_set_o == SCR1_IRQ_APP_DONE_MASK);
    endproperty

    assert property (p_irq_app_done)
        else $error("scr1_fault_irq_aggregator: wrong IRQ mapping for APP_DONE");

    property p_irq_fault;
        @(posedge clk)
        (event_valid_i && (event_i == SCR1_EVENT_FAULT))
        |-> (irq_set_o == SCR1_IRQ_FAULT_MASK);
    endproperty

    assert property (p_irq_fault)
        else $error("scr1_fault_irq_aggregator: wrong IRQ mapping for FAULT");

    property p_irq_watchdog_timeout;
        @(posedge clk)
        (event_valid_i && (event_i == SCR1_EVENT_WATCHDOG_TIMEOUT))
        |-> (irq_set_o == SCR1_IRQ_WATCHDOG_TIMEOUT_MASK);
    endproperty

    assert property (p_irq_watchdog_timeout)
        else $error("scr1_fault_irq_aggregator: wrong IRQ mapping for WATCHDOG_TIMEOUT");

    property p_irq_start_timeout;
        @(posedge clk)
        (event_valid_i && (event_i == SCR1_EVENT_START_TIMEOUT))
        |-> (irq_set_o == SCR1_IRQ_START_TIMEOUT_MASK);
    endproperty

    assert property (p_irq_start_timeout)
        else $error("scr1_fault_irq_aggregator: wrong IRQ mapping for START_TIMEOUT");

    property p_irq_quiesce_timeout;
        @(posedge clk)
        (event_valid_i && (event_i == SCR1_EVENT_QUIESCE_TIMEOUT))
        |-> (irq_set_o == SCR1_IRQ_QUIESCE_TIMEOUT_MASK);
    endproperty

    assert property (p_irq_quiesce_timeout)
        else $error("scr1_fault_irq_aggregator: wrong IRQ mapping for QUIESCE_TIMEOUT");

    property p_irq_axi_error;
        @(posedge clk)
        (event_valid_i && (event_i == SCR1_EVENT_AXI_ERROR))
        |-> (irq_set_o == SCR1_IRQ_AXI_ERROR_MASK);
    endproperty

    assert property (p_irq_axi_error)
        else $error("scr1_fault_irq_aggregator: wrong IRQ mapping for AXI_ERROR");

    property p_irq_sw_event;
        @(posedge clk)
        (event_valid_i && (event_i == SCR1_EVENT_SW_EVENT))
        |-> (irq_set_o == SCR1_IRQ_SW_EVENT_MASK);
    endproperty

    assert property (p_irq_sw_event)
        else $error("scr1_fault_irq_aggregator: wrong IRQ mapping for SW_EVENT");

    // The first fault request must be captured with all associated context.
    property p_first_fault_capture;
        @(posedge clk) disable iff (!rst_n)
        (fault_request_valid_i && !fault_valid_q && !clear_fault_i)
        |=> (fault_valid_o
            && (fault_code_o  == $past(fault_request_code_i))
            && (fault_pc_o    == $past(fault_pc_i))
            && (fault_info0_o == $past(fault_info0_i))
            && (fault_info1_o == $past(fault_info1_i)));
    endproperty

    assert property (p_first_fault_capture)
        else $error("scr1_fault_irq_aggregator: first fault was not captured correctly");

    // Once a primary fault exists, another fault must not overwrite it.
    property p_first_fault_wins;
        @(posedge clk) disable iff (!rst_n)
        (fault_valid_q && fault_request_valid_i && !clear_fault_i)
        |=> (fault_valid_o
            && (fault_code_o  == $past(fault_code_o))
            && (fault_pc_o    == $past(fault_pc_o))
            && (fault_info0_o == $past(fault_info0_o))
            && (fault_info1_o == $past(fault_info1_o)));
    endproperty

    assert property (p_first_fault_wins)
        else $error("scr1_fault_irq_aggregator: secondary fault overwrote primary fault");

    // Clear without a simultaneous new fault must empty the primary fault slot.
    property p_clear_fault;
        @(posedge clk) disable iff (!rst_n)
        (clear_fault_i && !fault_request_valid_i)
        |=> (!fault_valid_o
            && (fault_code_o  == SCR1_FAULT_NONE)
            && (fault_pc_o    == 32'h0000_0000)
            && (fault_info0_o == 32'h0000_0000)
            && (fault_info1_o == 32'h0000_0000));
    endproperty

    assert property (p_clear_fault)
        else $error("scr1_fault_irq_aggregator: CLEAR_FAULT did not clear fault storage");

    // Clear and a new fault in the same cycle must capture the new fault.
    property p_clear_and_new_fault;
        @(posedge clk) disable iff (!rst_n)
        (clear_fault_i && fault_request_valid_i)
        |=> (fault_valid_o
            && (fault_code_o  == $past(fault_request_code_i))
            && (fault_pc_o    == $past(fault_pc_i))
            && (fault_info0_o == $past(fault_info0_i))
            && (fault_info1_o == $past(fault_info1_i)));
    endproperty

    assert property (p_clear_and_new_fault)
        else $error("scr1_fault_irq_aggregator: clear/new-fault collision lost new fault");

    // A reset edge must clear all stored fault information.
    property p_reset_clears_fault;
        @(posedge clk)
        (!rst_n)
        |=> (!fault_valid_o
            && (fault_code_o  == SCR1_FAULT_NONE)
            && (fault_pc_o    == 32'h0000_0000)
            && (fault_info0_o == 32'h0000_0000)
            && (fault_info1_o == 32'h0000_0000));
    endproperty

    assert property (p_reset_clears_fault)
        else $error("scr1_fault_irq_aggregator: reset did not clear fault storage");

    // Invalid/empty fault state must expose a clean context.
    property p_empty_fault_is_clean;
        @(posedge clk) disable iff (!rst_n)
        (!fault_valid_o)
        |-> ((fault_code_o  == SCR1_FAULT_NONE)
            && (fault_pc_o    == 32'h0000_0000)
            && (fault_info0_o == 32'h0000_0000)
            && (fault_info1_o == 32'h0000_0000));
    endproperty

    assert property (p_empty_fault_is_clean)
        else $error("scr1_fault_irq_aggregator: empty fault slot contains stale context");

`endif

endmodule : scr1_fault_irq_aggregator
