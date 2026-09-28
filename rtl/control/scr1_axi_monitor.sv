// SPDX-License-Identifier: Apache-2.0
//
// Passive AXI4 monitor for SCR1 IMEM/DMEM master interfaces.
//
// Placement:
//   SCR1 AXI master -> (tap here) -> SmartConnect / NoC / slave
//
// The monitor is observational only. It never drives READY/VALID and never
// modifies an AXI transaction.

module scr1_axi_monitor #(
    parameter int unsigned AXI_ADDR_WIDTH        = 32,
    parameter int unsigned AXI_ID_WIDTH          = 4,

    // Current SCR1 scr1_mem_axi has a two-entry accepted-request/status queue.
    // Two counter bits represent 0..3 and are sufficient for the baseline.
    parameter int unsigned OUTSTANDING_WIDTH     = 2,
    parameter int unsigned MAX_OUTSTANDING       = 2,

    // IMEM is semantically read-only. Use MONITOR_WRITES=0 for IMEM and
    // MONITOR_WRITES=1 for DMEM.
    parameter bit          MONITOR_WRITES        = 1'b1,

    // Timeout uses no-progress semantics. A value of 0 disables timeout logic.
    parameter int unsigned TIMEOUT_CYCLES        = 0
) (
    // -------------------------------------------------------------------------
    // Clock / reset
    // -------------------------------------------------------------------------
    input  logic                               clk_i,
    input  logic                               rst_ni,
    input  logic                               clear_fault_i,

    // -------------------------------------------------------------------------
    // AXI read-address channel: AR
    // -------------------------------------------------------------------------
    input  logic [AXI_ID_WIDTH-1:0]            arid_i,
    input  logic [AXI_ADDR_WIDTH-1:0]          araddr_i,
    input  logic [7:0]                         arlen_i,
    input  logic                               arvalid_i,
    input  logic                               arready_i,

    // -------------------------------------------------------------------------
    // AXI read-data/response channel: R
    // -------------------------------------------------------------------------
    input  logic [AXI_ID_WIDTH-1:0]            rid_i,
    input  logic [1:0]                         rresp_i,
    input  logic                               rlast_i,
    input  logic                               rvalid_i,
    input  logic                               rready_i,

    // -------------------------------------------------------------------------
    // AXI write-address channel: AW
    // -------------------------------------------------------------------------
    input  logic [AXI_ID_WIDTH-1:0]            awid_i,
    input  logic [AXI_ADDR_WIDTH-1:0]          awaddr_i,
    input  logic [7:0]                         awlen_i,
    input  logic                               awvalid_i,
    input  logic                               awready_i,

    // -------------------------------------------------------------------------
    // AXI write-data channel: W
    // -------------------------------------------------------------------------
    input  logic                               wlast_i,
    input  logic                               wvalid_i,
    input  logic                               wready_i,

    // -------------------------------------------------------------------------
    // AXI write-response channel: B
    // -------------------------------------------------------------------------
    input  logic [AXI_ID_WIDTH-1:0]            bid_i,
    input  logic [1:0]                         bresp_i,
    input  logic                               bvalid_i,
    input  logic                               bready_i,

    // -------------------------------------------------------------------------
    // Outstanding / quiesce status
    // -------------------------------------------------------------------------
    output logic [OUTSTANDING_WIDTH-1:0]       read_outstanding_o,
    output logic [OUTSTANDING_WIDTH-1:0]       write_outstanding_o,
    output logic [OUTSTANDING_WIDTH-1:0]       read_high_water_o,
    output logic [OUTSTANDING_WIDTH-1:0]       write_high_water_o,
    output logic                               write_partial_o,
    output logic                               quiescent_o,

    // -------------------------------------------------------------------------
    // Sticky first-fault context
    // -------------------------------------------------------------------------
    output logic                               fault_valid_o,
    output vd100_scr1_pkg::scr1_fault_code_e  fault_code_o,
    output logic [AXI_ADDR_WIDTH-1:0]          fault_addr_o,
    output logic [AXI_ID_WIDTH-1:0]            fault_id_o,
    output logic [1:0]                         fault_resp_o,
    output logic                               fault_is_write_o
);

    import vd100_scr1_pkg::*;

    // -------------------------------------------------------------------------
    // Static configuration checks
    // -------------------------------------------------------------------------
    localparam logic [OUTSTANDING_WIDTH-1:0] MAX_OUTSTANDING_COUNT =
        MAX_OUTSTANDING;

    localparam int unsigned TIMEOUT_COUNTER_WIDTH =
        (TIMEOUT_CYCLES <= 1) ? 1 : $clog2(TIMEOUT_CYCLES);

    // -------------------------------------------------------------------------
    // AXI handshakes
    // -------------------------------------------------------------------------
    logic read_start_hs;
    logic read_beat_hs;
    logic read_complete_hs;
    logic write_addr_hs;
    logic write_data_hs;
    logic write_complete_hs;

    assign read_start_hs      = arvalid_i && arready_i;
    assign read_beat_hs       = rvalid_i  && rready_i;
    assign read_complete_hs   = read_beat_hs && rlast_i;

    assign write_addr_hs      = MONITOR_WRITES && awvalid_i && awready_i;
    assign write_data_hs      = MONITOR_WRITES && wvalid_i  && wready_i && wlast_i;
    assign write_complete_hs  = MONITOR_WRITES && bvalid_i  && bready_i;

    // -------------------------------------------------------------------------
    // Outstanding counter next state
    // -------------------------------------------------------------------------
    logic [OUTSTANDING_WIDTH-1:0] read_outstanding_n;
    logic [OUTSTANDING_WIDTH-1:0] write_outstanding_n;

    always_comb begin
        read_outstanding_n = read_outstanding_o;

        unique case ({read_start_hs, read_complete_hs})
            2'b10: begin
                if (read_outstanding_o < MAX_OUTSTANDING_COUNT) begin
                    read_outstanding_n = read_outstanding_o + 1'b1;
                end
            end

            2'b01: begin
                if (read_outstanding_o != '0) begin
                    read_outstanding_n = read_outstanding_o - 1'b1;
                end
            end

            default: begin
                // 00: no change
                // 11: one request accepted while one request completes
            end
        endcase
    end

    always_comb begin
        if (!MONITOR_WRITES) begin
            write_outstanding_n = '0;
        end else begin
            write_outstanding_n = write_outstanding_o;

            unique case ({write_addr_hs, write_complete_hs})
                2'b10: begin
                    if (write_outstanding_o < MAX_OUTSTANDING_COUNT) begin
                        write_outstanding_n = write_outstanding_o + 1'b1;
                    end
                end

                2'b01: begin
                    if (write_outstanding_o != '0) begin
                        write_outstanding_n = write_outstanding_o - 1'b1;
                    end
                end

                default: begin
                    // 00: no change
                    // 11: one AW accepted while one B response completes
                end
            endcase
        end
    end

    // -------------------------------------------------------------------------
    // Independent AW/W tracking
    // -------------------------------------------------------------------------
    // aw_waiting_w_count_q : accepted AWs that have not yet been paired with WLAST
    // early_w_count_q      : accepted WLAST beats that arrived before their AW
    //
    // With the current single-beat SCR1 write contract, these two counters cannot
    // both be non-zero when the AXI stream is legal and ordered.
    logic [OUTSTANDING_WIDTH-1:0] aw_waiting_w_count_q;
    logic [OUTSTANDING_WIDTH-1:0] aw_waiting_w_count_n;
    logic [OUTSTANDING_WIDTH-1:0] early_w_count_q;
    logic [OUTSTANDING_WIDTH-1:0] early_w_count_n;

    always_comb begin
        aw_waiting_w_count_n = aw_waiting_w_count_q;
        early_w_count_n      = early_w_count_q;

        if (!MONITOR_WRITES) begin
            aw_waiting_w_count_n = '0;
            early_w_count_n      = '0;
        end else begin
            // If AW and WLAST handshake together, one address and one data beat
            // pair with each other (or keep the existing unmatched depth stable).
            if (write_addr_hs && !write_data_hs) begin
                if (early_w_count_q != '0) begin
                    early_w_count_n = early_w_count_q - 1'b1;
                end else if (aw_waiting_w_count_q < MAX_OUTSTANDING_COUNT) begin
                    aw_waiting_w_count_n = aw_waiting_w_count_q + 1'b1;
                end
            end else if (write_data_hs && !write_addr_hs) begin
                if (aw_waiting_w_count_q != '0) begin
                    aw_waiting_w_count_n = aw_waiting_w_count_q - 1'b1;
                end else if (early_w_count_q < MAX_OUTSTANDING_COUNT) begin
                    early_w_count_n = early_w_count_q + 1'b1;
                end
            end
        end
    end

    always_comb begin
        if (!MONITOR_WRITES) begin
            write_partial_o = 1'b0;
        end else begin
            write_partial_o = (aw_waiting_w_count_q != '0) ||
                              (early_w_count_q      != '0);
        end
    end

    // -------------------------------------------------------------------------
    // Address / ID context FIFOs
    // -------------------------------------------------------------------------
    // Current SCR1 uses fixed IDs (ARID=0, AWID=1) and same-ID ordering.
    // A compact in-order FIFO is therefore sufficient for the baseline monitor.
    logic [AXI_ADDR_WIDTH-1:0] read_addr_fifo [0:MAX_OUTSTANDING-1];
    logic [AXI_ID_WIDTH-1:0]   read_id_fifo   [0:MAX_OUTSTANDING-1];
    logic [AXI_ADDR_WIDTH-1:0] write_addr_fifo[0:MAX_OUTSTANDING-1];
    logic [AXI_ID_WIDTH-1:0]   write_id_fifo  [0:MAX_OUTSTANDING-1];

    integer i;

    always_ff @(posedge clk_i) begin
        if (!rst_ni) begin
            for (i = 0; i < MAX_OUTSTANDING; i = i + 1) begin
                read_addr_fifo[i]  <= '0;
                read_id_fifo[i]    <= '0;
                write_addr_fifo[i] <= '0;
                write_id_fifo[i]   <= '0;
            end
        end else begin
            // ---------------------------- Read context ------------------------
            if (read_start_hs && !read_complete_hs) begin
                if (read_outstanding_o < MAX_OUTSTANDING_COUNT) begin
                    read_addr_fifo[read_outstanding_o] <= araddr_i;
                    read_id_fifo[read_outstanding_o]   <= arid_i;
                end
            end else if (!read_start_hs && read_complete_hs) begin
                if (read_outstanding_o != '0) begin
                    for (i = 0; i < MAX_OUTSTANDING-1; i = i + 1) begin
                        if (i < (read_outstanding_o - 1'b1)) begin
                            read_addr_fifo[i] <= read_addr_fifo[i+1];
                            read_id_fifo[i]   <= read_id_fifo[i+1];
                        end
                    end
                end
            end else if (read_start_hs && read_complete_hs) begin
                if (read_outstanding_o == '0) begin
                    // Zero-latency request/response: nothing remains queued.
                end else begin
                    for (i = 0; i < MAX_OUTSTANDING-1; i = i + 1) begin
                        if (i < (read_outstanding_o - 1'b1)) begin
                            read_addr_fifo[i] <= read_addr_fifo[i+1];
                            read_id_fifo[i]   <= read_id_fifo[i+1];
                        end
                    end
                    read_addr_fifo[read_outstanding_o-1'b1] <= araddr_i;
                    read_id_fifo[read_outstanding_o-1'b1]   <= arid_i;
                end
            end

            // ---------------------------- Write context -----------------------
            if (MONITOR_WRITES) begin
                if (write_addr_hs && !write_complete_hs) begin
                    if (write_outstanding_o < MAX_OUTSTANDING_COUNT) begin
                        write_addr_fifo[write_outstanding_o] <= awaddr_i;
                        write_id_fifo[write_outstanding_o]   <= awid_i;
                    end
                end else if (!write_addr_hs && write_complete_hs) begin
                    if (write_outstanding_o != '0) begin
                        for (i = 0; i < MAX_OUTSTANDING-1; i = i + 1) begin
                            if (i < (write_outstanding_o - 1'b1)) begin
                                write_addr_fifo[i] <= write_addr_fifo[i+1];
                                write_id_fifo[i]   <= write_id_fifo[i+1];
                            end
                        end
                    end
                end else if (write_addr_hs && write_complete_hs) begin
                    if (write_outstanding_o == '0) begin
                        // Zero-latency request/response: nothing remains queued.
                    end else begin
                        for (i = 0; i < MAX_OUTSTANDING-1; i = i + 1) begin
                            if (i < (write_outstanding_o - 1'b1)) begin
                                write_addr_fifo[i] <= write_addr_fifo[i+1];
                                write_id_fifo[i]   <= write_id_fifo[i+1];
                            end
                        end
                        write_addr_fifo[write_outstanding_o-1'b1] <= awaddr_i;
                        write_id_fifo[write_outstanding_o-1'b1]   <= awid_i;
                    end
                end
            end
        end
    end

    // -------------------------------------------------------------------------
    // Counters and high-water marks
    // -------------------------------------------------------------------------
    always_ff @(posedge clk_i) begin
        if (!rst_ni) begin
            read_outstanding_o  <= '0;
            write_outstanding_o <= '0;
            read_high_water_o   <= '0;
            write_high_water_o  <= '0;
            aw_waiting_w_count_q <= '0;
            early_w_count_q      <= '0;
        end else begin
            read_outstanding_o  <= read_outstanding_n;
            write_outstanding_o <= write_outstanding_n;
            aw_waiting_w_count_q <= aw_waiting_w_count_n;
            early_w_count_q      <= early_w_count_n;

            if (read_outstanding_n > read_high_water_o) begin
                read_high_water_o <= read_outstanding_n;
            end

            if (write_outstanding_n > write_high_water_o) begin
                write_high_water_o <= write_outstanding_n;
            end
        end
    end

    // -------------------------------------------------------------------------
    // Quiescent
    // -------------------------------------------------------------------------
    always_comb begin
        quiescent_o = (read_outstanding_o == 0)
                       && !arvalid_i
                       && (!MONITOR_WRITES || ((write_outstanding_o == 0)
                           && !write_partial_o && !awvalid_i && !wvalid_i));
    end

    // -------------------------------------------------------------------------
    // Timeout tracking: no-progress semantics
    // -------------------------------------------------------------------------
    logic [TIMEOUT_COUNTER_WIDTH-1:0] read_timeout_count_q;
    logic [TIMEOUT_COUNTER_WIDTH-1:0] write_timeout_count_q;
    logic read_timeout_event;
    logic write_timeout_event;
    logic write_progress_hs;

    assign write_progress_hs = write_addr_hs || write_data_hs || write_complete_hs;

    generate
        if (TIMEOUT_CYCLES == 0) begin : g_timeout_disabled
            always_comb begin
                read_timeout_event  = 1'b0;
                write_timeout_event = 1'b0;
            end

            always_ff @(posedge clk_i) begin
                if (!rst_ni) begin
                    read_timeout_count_q  <= '0;
                    write_timeout_count_q <= '0;
                end else begin
                    read_timeout_count_q  <= '0;
                    write_timeout_count_q <= '0;
                end
            end
        end else begin : g_timeout_enabled
            localparam logic [TIMEOUT_COUNTER_WIDTH-1:0] TIMEOUT_LIMIT =
                TIMEOUT_CYCLES - 1;

            always_comb begin
                read_timeout_event =
                    (read_outstanding_o != '0) &&
                    !read_beat_hs &&
                    (read_timeout_count_q == TIMEOUT_LIMIT);

                write_timeout_event =
                    MONITOR_WRITES &&
                    ((write_outstanding_o != '0) || write_partial_o) &&
                    !write_progress_hs &&
                    (write_timeout_count_q == TIMEOUT_LIMIT);
            end

            always_ff @(posedge clk_i) begin
                if (!rst_ni) begin
                    read_timeout_count_q  <= '0;
                    write_timeout_count_q <= '0;
                end else begin
                    // Read timer: any accepted R beat is progress. A newly
                    // accepted AR starts at age zero.
                    if (read_outstanding_o == '0) begin
                        read_timeout_count_q <= '0;
                    end else if (read_beat_hs) begin
                        read_timeout_count_q <= '0;
                    end else if (read_timeout_count_q < TIMEOUT_LIMIT) begin
                        read_timeout_count_q <= read_timeout_count_q + 1'b1;
                    end

                    // Write timer: AW/W/B handshakes are all forward progress.
                    if (!MONITOR_WRITES ||
                        ((write_outstanding_o == '0) && !write_partial_o)) begin
                        write_timeout_count_q <= '0;
                    end else if (write_progress_hs) begin
                        write_timeout_count_q <= '0;
                    end else if (write_timeout_count_q < TIMEOUT_LIMIT) begin
                        write_timeout_count_q <= write_timeout_count_q + 1'b1;
                    end
                end
            end
        end
    endgenerate

    // -------------------------------------------------------------------------
    // AXI response error classification
    // -------------------------------------------------------------------------
    logic read_resp_fault_event;
    logic write_resp_fault_event;

    assign read_resp_fault_event  = read_beat_hs && (rresp_i != 2'b00);
    assign write_resp_fault_event = write_complete_hs && (bresp_i != 2'b00);

    function automatic scr1_fault_code_e response_to_fault_code(
        input logic [1:0] resp
    );
        begin
            unique case (resp)
                2'b10: response_to_fault_code = SCR1_FAULT_AXI_SLVERR;
                2'b11: response_to_fault_code = SCR1_FAULT_AXI_DECERR;

                // EXOKAY is not expected from the current non-exclusive SCR1
                // traffic. Preserve raw RESP and classify it as an AXI slave
                // response fault until a dedicated protocol-fault code exists.
                2'b01: response_to_fault_code = SCR1_FAULT_AXI_SLVERR;

                default: response_to_fault_code = SCR1_FAULT_NONE;
            endcase
        end
    endfunction

    // -------------------------------------------------------------------------
    // New-fault arbitration
    // -------------------------------------------------------------------------
    // Deterministic priority:
    //   1. read response error
    //   2. write response error
    //   3. read timeout
    //   4. write timeout
    logic                              new_fault_valid;
    scr1_fault_code_e                  new_fault_code;
    logic [AXI_ADDR_WIDTH-1:0]         new_fault_addr;
    logic [AXI_ID_WIDTH-1:0]           new_fault_id;
    logic [1:0]                        new_fault_resp;
    logic                              new_fault_is_write;

    always_comb begin
        new_fault_valid    = 1'b0;
        new_fault_code     = SCR1_FAULT_NONE;
        new_fault_addr     = '0;
        new_fault_id       = '0;
        new_fault_resp     = 2'b00;
        new_fault_is_write = 1'b0;

        if (read_resp_fault_event) begin
            new_fault_valid = 1'b1;
            new_fault_code  = response_to_fault_code(rresp_i);
            new_fault_addr  = (read_outstanding_o != '0) ?
                              read_addr_fifo[0] :
                              (read_start_hs ? araddr_i : '0);
            new_fault_id    = rid_i;
            new_fault_resp  = rresp_i;
            new_fault_is_write = 1'b0;
        end else if (write_resp_fault_event) begin
            new_fault_valid = 1'b1;
            new_fault_code  = response_to_fault_code(bresp_i);
            new_fault_addr  = (write_outstanding_o != '0) ?
                              write_addr_fifo[0] :
                              (write_addr_hs ? awaddr_i : '0);
            new_fault_id    = bid_i;
            new_fault_resp  = bresp_i;
            new_fault_is_write = 1'b1;
        end else if (read_timeout_event) begin
            new_fault_valid = 1'b1;
            new_fault_code  = SCR1_FAULT_TIMEOUT;
            new_fault_addr  = (read_outstanding_o != '0) ? read_addr_fifo[0] : '0;
            new_fault_id    = (read_outstanding_o != '0) ? read_id_fifo[0]   : '0;
            new_fault_resp  = 2'b00;
            new_fault_is_write = 1'b0;
        end else if (write_timeout_event) begin
            new_fault_valid = 1'b1;
            new_fault_code  = SCR1_FAULT_TIMEOUT;
            new_fault_addr  = (write_outstanding_o != '0) ? write_addr_fifo[0] : '0;
            new_fault_id    = (write_outstanding_o != '0) ? write_id_fifo[0]   : '0;
            new_fault_resp  = 2'b00;
            new_fault_is_write = 1'b1;
        end
    end

    // -------------------------------------------------------------------------
    // First-fault-wins storage
    // -------------------------------------------------------------------------
    always_ff @(posedge clk_i) begin
        if (!rst_ni) begin
            fault_valid_o    <= 1'b0;
            fault_code_o     <= SCR1_FAULT_NONE;
            fault_addr_o     <= '0;
            fault_id_o       <= '0;
            fault_resp_o     <= 2'b00;
            fault_is_write_o <= 1'b0;
        end else begin
            if (clear_fault_i) begin
                fault_valid_o    <= 1'b0;
                fault_code_o     <= SCR1_FAULT_NONE;
                fault_addr_o     <= '0;
                fault_id_o       <= '0;
                fault_resp_o     <= 2'b00;
                fault_is_write_o <= 1'b0;
            end

            // If clear and a new fault happen in the same cycle, retain the new
            // fault. In normal use clear_fault_i is asserted only in a safe state.
            if ((!fault_valid_o || clear_fault_i) && new_fault_valid) begin
                fault_valid_o    <= 1'b1;
                fault_code_o     <= new_fault_code;
                fault_addr_o     <= new_fault_addr;
                fault_id_o       <= new_fault_id;
                fault_resp_o     <= new_fault_resp;
                fault_is_write_o <= new_fault_is_write;
            end
        end
    end

`ifndef SYNTHESIS
    // -------------------------------------------------------------------------
    // Simulation-time integration checks
    // -------------------------------------------------------------------------
    initial begin
        if (MAX_OUTSTANDING < 1) begin
            $fatal(1, "scr1_axi_monitor: MAX_OUTSTANDING must be >= 1");
        end
        if (MAX_OUTSTANDING > ((1 << OUTSTANDING_WIDTH) - 1)) begin
            $fatal(1, "scr1_axi_monitor: OUTSTANDING_WIDTH is too small");
        end
    end

    always_ff @(posedge clk_i) begin
        if (rst_ni) begin
            if (read_complete_hs && (read_outstanding_o == '0) && !read_start_hs) begin
                $error("scr1_axi_monitor: read completion with zero outstanding reads");
            end

            if (read_start_hs && (read_outstanding_o == MAX_OUTSTANDING_COUNT) &&
                !read_complete_hs) begin
                $error("scr1_axi_monitor: read outstanding/context overflow");
            end

            if (MONITOR_WRITES) begin
                if (write_complete_hs && (write_outstanding_o == '0) &&
                    !write_addr_hs) begin
                    $error("scr1_axi_monitor: write completion with zero outstanding writes");
                end

                if (write_addr_hs && (write_outstanding_o == MAX_OUTSTANDING_COUNT) &&
                    !write_complete_hs) begin
                    $error("scr1_axi_monitor: write outstanding/context overflow");
                end

                if (awvalid_i && awready_i && (awlen_i != 8'd0)) begin
                    $error("scr1_axi_monitor: current SCR1 contract expects AWLEN=0");
                end

                if (wvalid_i && wready_i && !wlast_i) begin
                    $error("scr1_axi_monitor: current SCR1 contract expects single-beat WLAST=1");
                end

                if ((aw_waiting_w_count_q != '0) && (early_w_count_q != '0)) begin
                    $error("scr1_axi_monitor: contradictory independent AW/W partial state");
                end
            end
        end
    end
`endif

endmodule : scr1_axi_monitor
