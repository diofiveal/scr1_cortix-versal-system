`include "scr1_memif.svh"
`include "scr1_arch_description.svh"

// -----------------------------------------------------------------------------
// SCR1 4-entry write buffer
// -----------------------------------------------------------------------------
// Ordered FIFO for cacheable write-through stores issued by L1 D-cache.
//
// Cacheable writes are acknowledged when they are accepted into the FIFO and
// receive a local RDY_OK on the following cycle. The dcache controller therefore
// does not wait for the backing-memory response.
// Reads and MMIO/uncached writes are never buffered: they are allowed through
// only after all older buffered stores have drained, preserving memory order.
//
// The FIFO payload memories are intentionally not reset. Only pointers/count
// are reset, which avoids adding reset muxes to the storage and maps better to
// FPGA distributed RAM/LUTRAM. BUFFER_DEPTH=4 is the intended configuration.
// -----------------------------------------------------------------------------
module scr1_write_buffer #(
    parameter int unsigned ADDR_WIDTH    = `SCR1_DMEM_AWIDTH,
    parameter int unsigned DATA_WIDTH    = `SCR1_DMEM_DWIDTH,
    parameter int unsigned BUFFER_DEPTH = 4
) (
    input  logic                         clk,
    input  logic                         rst_n,

    // D-cache controller side
    input  logic                         dcache_req_i,
    input  type_scr1_mem_cmd_e           dcache_cmd_i,
    input  type_scr1_mem_width_e         dcache_width_i,
    input  logic [ADDR_WIDTH-1:0]        dcache_addr_i,
    input  logic [DATA_WIDTH-1:0]        dcache_wdata_i,
    input  logic [7:0]                   dcache_burst_len_i,

    output logic                         dcache_req_ack_o,
    output logic                         dcache_rvalid_o,
    output logic                         dcache_rlast_o,
    output logic [DATA_WIDTH-1:0]        dcache_rdata_o,
    output type_scr1_mem_resp_e          dcache_resp_o,

    // Backing-memory side
    output logic                         memory_req_o,
    output type_scr1_mem_cmd_e           memory_cmd_o,
    output type_scr1_mem_width_e         memory_width_o,
    output logic [ADDR_WIDTH-1:0]        memory_addr_o,
    output logic [DATA_WIDTH-1:0]        memory_wdata_o,
    output logic [7:0]                   memory_burst_len_o,

    input  logic                         memory_req_ack_i,
    input  logic                         memory_rvalid_i,
    input  logic                         memory_rlast_i,
    input  logic [DATA_WIDTH-1:0]        memory_rdata_i,
    input  type_scr1_mem_resp_e          memory_resp_i,

    // Status / monitoring
    output logic                         buffer_full_o,
    output logic                         buffer_empty_o,
    output logic [$clog2(BUFFER_DEPTH+1)-1:0] buffer_count_o,
    output logic                         write_error_o,
    output logic                         perf_enqueue_o,
    output logic                         perf_dequeue_o,
    output logic                         perf_full_stall_o,

    // Lifecycle drain status. Asserted only when the write buffer owns no
    // queued, pass-through, or locally pending transaction.
    output logic                         drain_idle_o
);

    localparam int unsigned PTR_WIDTH =
        (BUFFER_DEPTH > 1) ? $clog2(BUFFER_DEPTH) : 1;
    localparam int unsigned COUNT_WIDTH =
        (BUFFER_DEPTH > 0) ? $clog2(BUFFER_DEPTH + 1) : 1;

    typedef enum logic [1:0] {
        BUS_IDLE,
        BUS_WB_WAIT,
        BUS_PT_WAIT
    } bus_state_e;

    bus_state_e bus_state_q;
    bus_state_e bus_state_d;

    // Small FPGA-friendly FIFO. Separate arrays give synthesis a simple
    // distributed-RAM/register implementation and avoid a large packed mux.
    (* ram_style = "distributed" *)
    logic [ADDR_WIDTH-1:0] addr_fifo_q [0:BUFFER_DEPTH-1];

    (* ram_style = "distributed" *)
    logic [DATA_WIDTH-1:0] data_fifo_q [0:BUFFER_DEPTH-1];

    type_scr1_mem_width_e width_fifo_q [0:BUFFER_DEPTH-1];

    logic [PTR_WIDTH-1:0]   write_ptr_q;
    logic [PTR_WIDTH-1:0]   read_ptr_q;
    logic [COUNT_WIDTH-1:0] count_q;

    logic                   write_error_q;
    logic                   dcache_write_resp_pending_q;

    // A pass-through response can theoretically return in the same cycle as
    // request acknowledgement. The dcache controller changes to its WAIT state
    // only on the next edge, so capture such a response and replay it there.
    logic                   pt_resp_latched_q;
    logic                   pt_rvalid_q;
    logic                   pt_rlast_q;
    logic                   pt_is_read_q;
    logic [DATA_WIDTH-1:0]  pt_rdata_q;
    type_scr1_mem_resp_e    pt_resp_q;

    logic dcache_is_write;
    logic dcache_is_read;
    logic dcache_is_mmio;
    logic dcache_is_bufferable_write;
    logic dcache_is_passthrough;

    logic memory_resp_terminal;
    logic drain_req_active;
    logic push_event;
    logic pop_event;
    logic pt_accept_event;

    function automatic logic [PTR_WIDTH-1:0] ptr_inc (
        input logic [PTR_WIDTH-1:0] ptr
    );
        begin
            if (ptr == PTR_WIDTH'(BUFFER_DEPTH - 1)) begin
                ptr_inc = '0;
            end else begin
                ptr_inc = ptr + 1'b1;
            end
        end
    endfunction

    assign dcache_is_write = (dcache_cmd_i == SCR1_MEM_CMD_WR);
    assign dcache_is_read  = (dcache_cmd_i == SCR1_MEM_CMD_RD);

    // Same uncached/MMIO window used by the current D-cache controller.
    assign dcache_is_mmio =
        (dcache_addr_i[ADDR_WIDTH-1 -: 8] == 8'hFF);

    assign dcache_is_bufferable_write = dcache_is_write && !dcache_is_mmio;
    assign dcache_is_passthrough =
        dcache_is_read || (dcache_is_write && dcache_is_mmio);

    assign buffer_empty_o = (count_q == '0);
    assign buffer_full_o  = (count_q == COUNT_WIDTH'(BUFFER_DEPTH));
    assign buffer_count_o = count_q;
    assign write_error_o  = write_error_q;

    assign memory_resp_terminal =
        (memory_resp_i == SCR1_MEM_RESP_RDY_OK)
        || (memory_resp_i == SCR1_MEM_RESP_RDY_ER);

    // A queued store owns the memory port whenever the bus FSM is idle.
    assign drain_req_active = (bus_state_q == BUS_IDLE) && !buffer_empty_o;

    // A buffered store is removed only on a terminal backing-memory response.
    // The second term covers a zero-latency req_ack+resp implementation.
    assign pop_event =
        ((bus_state_q == BUS_WB_WAIT) && memory_resp_terminal)
        || (drain_req_active && memory_req_ack_i && memory_resp_terminal);

    // When the FIFO is full, a new store may still be accepted in the exact
    // cycle that the oldest entry completes. This sustains one enqueue/dequeue
    // per completion without an unnecessary bubble.
    assign push_event =
        dcache_req_i
        && dcache_is_bufferable_write
        && (!buffer_full_o || pop_event);

    assign pt_accept_event =
        (bus_state_q == BUS_IDLE)
        && buffer_empty_o
        && dcache_req_i
        && dcache_is_passthrough
        && memory_req_ack_i;

    assign perf_enqueue_o    = push_event;
    assign perf_dequeue_o    = pop_event;
    assign perf_full_stall_o =
        dcache_req_i
        && dcache_is_bufferable_write
        && buffer_full_o
        && !pop_event;

    // -------------------------------------------------------------------------
    // Combinational memory-port arbitration
    // Priority:
    //   1) outstanding transaction
    //   2) oldest queued store
    //   3) direct read or MMIO write from D-cache
    // -------------------------------------------------------------------------
    always_comb begin
        bus_state_d = bus_state_q;

        dcache_req_ack_o = 1'b0;
        dcache_rvalid_o  = 1'b0;
        dcache_rlast_o   = 1'b0;
        dcache_rdata_o   = memory_rdata_i;
        dcache_resp_o    = SCR1_MEM_RESP_NOTRDY;

        memory_req_o       = 1'b0;
        memory_cmd_o       = SCR1_MEM_CMD_RD;
        memory_width_o     = SCR1_MEM_WIDTH_WORD;
        memory_addr_o      = '0;
        memory_wdata_o     = '0;
        memory_burst_len_o = 8'd0;

        // Cacheable stores are accepted at FIFO enqueue. A local RDY_OK
        // response is generated on the following cycle, matching the existing
        // D-cache STORE_REQ -> STORE_WAIT protocol.
        if (dcache_is_bufferable_write && dcache_req_i) begin
            dcache_req_ack_o = !buffer_full_o || pop_event;
        end

        // One-cycle-later local completion for an enqueued cacheable STORE.
        // Backing-memory write responses are consumed internally by the buffer.
        if (dcache_write_resp_pending_q) begin
            dcache_rdata_o = '0;
            dcache_resp_o  = SCR1_MEM_RESP_RDY_OK;
        end

        case (bus_state_q)
            BUS_IDLE: begin
                if (!buffer_empty_o) begin
                    // Drain oldest buffered store first.
                    memory_req_o   = 1'b1;
                    memory_cmd_o   = SCR1_MEM_CMD_WR;
                    memory_width_o = width_fifo_q[read_ptr_q];
                    memory_addr_o  = addr_fifo_q[read_ptr_q];
                    memory_wdata_o = data_fifo_q[read_ptr_q];

                    if (memory_req_ack_i) begin
                        if (memory_resp_terminal) begin
                            bus_state_d = BUS_IDLE;
                        end else begin
                            bus_state_d = BUS_WB_WAIT;
                        end
                    end
                end else if (dcache_req_i && dcache_is_passthrough) begin
                    // Reads/refills and MMIO writes are synchronous pass-through
                    // transactions and can start only after older stores drain.
                    memory_req_o       = 1'b1;
                    memory_cmd_o       = dcache_cmd_i;
                    memory_width_o     = dcache_width_i;
                    memory_addr_o      = dcache_addr_i;
                    memory_wdata_o     = dcache_wdata_i;
                    memory_burst_len_o = dcache_is_read
                                       ? dcache_burst_len_i : 8'd0;

                    dcache_req_ack_o = memory_req_ack_i;

                    if (memory_req_ack_i) begin
                        bus_state_d = BUS_PT_WAIT;
                    end
                end
            end

            BUS_WB_WAIT: begin
                // Request has already been accepted. Keep the head payload
                // visible for debug/timing clarity, but do not reassert request.
                memory_cmd_o   = SCR1_MEM_CMD_WR;
                memory_width_o = width_fifo_q[read_ptr_q];
                memory_addr_o  = addr_fifo_q[read_ptr_q];
                memory_wdata_o = data_fifo_q[read_ptr_q];

                if (memory_resp_terminal) begin
                    bus_state_d = BUS_IDLE;
                end
            end

            BUS_PT_WAIT: begin
                if (pt_resp_latched_q) begin
                    dcache_rvalid_o = pt_rvalid_q;
                    dcache_rlast_o  = pt_rlast_q;
                    dcache_rdata_o  = pt_rdata_q;
                    dcache_resp_o   = pt_resp_q;

                    if (pt_is_read_q) begin
                        if (pt_rvalid_q && pt_rlast_q) begin
                            bus_state_d = BUS_IDLE;
                        end
                    end else if ((pt_resp_q == SCR1_MEM_RESP_RDY_OK)
                                 || (pt_resp_q == SCR1_MEM_RESP_RDY_ER)) begin
                        bus_state_d = BUS_IDLE;
                    end
                end else if (pt_is_read_q) begin
                    // Keep the pass-through transaction active for the full
                    // AXI read burst. Each beat is streamed directly to D-cache.
                    dcache_rvalid_o = memory_rvalid_i;
                    dcache_rlast_o  = memory_rvalid_i && memory_rlast_i;
                    dcache_rdata_o  = memory_rdata_i;
                    if (memory_rvalid_i) begin
                        dcache_resp_o = memory_resp_i;
                    end

                    if (memory_rvalid_i && memory_rlast_i) begin
                        bus_state_d = BUS_IDLE;
                    end
                end else begin
                    // MMIO writes remain single-beat and complete on B response.
                    dcache_resp_o = memory_resp_i;
                    if (memory_resp_terminal) begin
                        bus_state_d = BUS_IDLE;
                    end
                end
            end

            default: begin
                bus_state_d = BUS_IDLE;
            end
        endcase
    end

    // -------------------------------------------------------------------------
    // Sequential FIFO/state logic
    // -------------------------------------------------------------------------
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            bus_state_q       <= BUS_IDLE;
            write_ptr_q       <= '0;
            read_ptr_q        <= '0;
            count_q                    <= '0;
            write_error_q              <= 1'b0;
            dcache_write_resp_pending_q <= 1'b0;
            pt_resp_latched_q          <= 1'b0;
            pt_rvalid_q                <= 1'b0;
            pt_rlast_q                 <= 1'b0;
            pt_is_read_q               <= 1'b0;
            pt_rdata_q                 <= '0;
            pt_resp_q                  <= SCR1_MEM_RESP_NOTRDY;
        end else begin
            bus_state_q <= bus_state_d;

            if (pt_accept_event) begin
                pt_is_read_q <= dcache_is_read;
            end else if ((bus_state_q == BUS_PT_WAIT)
                         && (bus_state_d == BUS_IDLE)) begin
                pt_is_read_q <= 1'b0;
            end

            if (push_event) begin
                addr_fifo_q[write_ptr_q]  <= dcache_addr_i;
                data_fifo_q[write_ptr_q]  <= dcache_wdata_i;
                width_fifo_q[write_ptr_q] <= dcache_width_i;
                write_ptr_q               <= ptr_inc(write_ptr_q);
            end

            if (pop_event) begin
                read_ptr_q <= ptr_inc(read_ptr_q);
            end

            case ({push_event, pop_event})
                2'b10: count_q <= count_q + 1'b1;
                2'b01: count_q <= count_q - 1'b1;
                default: count_q <= count_q;
            endcase

            // Existing D-cache controller expects ACK in STORE_REQ and RDY_OK
            // in STORE_WAIT. Consecutive pushes keep the pipeline full and emit
            // one completion pulse per cycle after the first accepted store.
            if (push_event) begin
                dcache_write_resp_pending_q <= 1'b1;
            end else if (dcache_write_resp_pending_q) begin
                dcache_write_resp_pending_q <= 1'b0;
            end

            // A failed asynchronous buffered write cannot be returned to the
            // retired CPU store. Record a sticky error and retire the FIFO entry
            // to avoid a permanent deadlock on a completed bus-error response.
            if (pop_event && (memory_resp_i == SCR1_MEM_RESP_RDY_ER)) begin
                write_error_q <= 1'b1;
            end

            // Capture a same-cycle pass-through response. The AXI bridge gates
            // RREADY until the request entry is live, so this is mainly a safety
            // path for zero-latency single-beat/AHB-style memory models.
            if (pt_accept_event
                && ((dcache_is_read && memory_rvalid_i)
                    || (!dcache_is_read && memory_resp_terminal))) begin
                pt_resp_latched_q <= 1'b1;
                pt_rvalid_q       <= dcache_is_read && memory_rvalid_i;
                pt_rlast_q        <= dcache_is_read && memory_rvalid_i
                                   && memory_rlast_i;
                pt_rdata_q        <= memory_rdata_i;
                pt_resp_q         <= memory_resp_i;
            end else if ((bus_state_q == BUS_PT_WAIT) && pt_resp_latched_q) begin
                pt_resp_latched_q <= 1'b0;
                pt_rvalid_q       <= 1'b0;
                pt_rlast_q        <= 1'b0;
            end
        end
    end

    // Full drain indication for lifecycle control. buffer_empty_o alone is not
    // sufficient because a pass-through request or local STORE completion can
    // remain active after the FIFO itself becomes empty.
    assign drain_idle_o = (bus_state_q == BUS_IDLE)
                       && buffer_empty_o
                       && !dcache_write_resp_pending_q
                       && !pt_resp_latched_q
                       && !dcache_req_i;

`ifdef SCR1_TRGT_SIMULATION
    initial begin
        if (BUFFER_DEPTH < 1) begin
            $fatal(1, "scr1_write_buffer: BUFFER_DEPTH must be >= 1");
        end
    end

    always_ff @(posedge clk) begin
        if (rst_n && pop_event && (memory_resp_i == SCR1_MEM_RESP_RDY_ER)) begin
            $error("scr1_write_buffer: backing-memory write failed");
        end

        if (rst_n && (bus_state_q == BUS_PT_WAIT)
            && pt_resp_latched_q && memory_rvalid_i) begin
            $error("scr1_write_buffer: pass-through skid beat collision");
        end
    end
`endif

endmodule : scr1_write_buffer
