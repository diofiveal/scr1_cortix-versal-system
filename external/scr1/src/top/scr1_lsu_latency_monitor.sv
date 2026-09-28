`include "scr1_memif.svh"
`include "scr1_arch_description.svh"

module scr1_lsu_latency_mon #(
    parameter logic [31:0] DDR_ADDR_MASK    = 32'hF800_0000,
    parameter logic [31:0] DDR_ADDR_PATTERN = 32'h0000_0000
) (
    input  logic                    clk,
    input  logic                    rst_n,

    input  logic                    stats_enable,
    input  logic                    stats_clear,

    // Request after DMEM router
    input  logic                    dmem_req,
    input  logic                    dmem_req_ack,
    input  type_scr1_mem_cmd_e      dmem_cmd,
    input  logic [31:0]             dmem_addr,

    // AXI READ
    input  logic                    arvalid,
    input  logic                    arready,

    input  logic                    rvalid,
    input  logic                    rready,
    input  logic                    rlast,

    // AXI WRITE address
    input  logic                    awvalid,
    input  logic                    awready,

    // AXI WRITE data
    input  logic                    wvalid,
    input  logic                    wready,
    input  logic                    wlast,

    // AXI WRITE response
    input  logic                    bvalid,
    input  logic                    bready,

    // Response back to DMEM router
    input  type_scr1_mem_resp_e      axi_dmem_resp,

    // LOAD
    output logic [31:0]             load_last_latency,
    output logic [31:0]             load_axi_path_latency,
    output logic [31:0]             load_last_addr,
    output logic [31:0]             load_min_latency,
    output logic [31:0]             load_max_latency,
    output logic [31:0]             load_count,
    output logic [31:0]             load_average_latency,

    // STORE
    output logic [31:0]             store_last_latency,
    output logic [31:0]             store_axi_path_latency,
    output logic [31:0]             store_last_addr,
    output logic [31:0]             store_min_latency,
    output logic [31:0]             store_max_latency,
    output logic [31:0]             store_count,
    output logic [31:0]             store_average_latency
);


typedef struct packed {

    logic                   track;

    type_scr1_mem_cmd_e     cmd;

    logic [31:0]            addr;

    logic [31:0]            t_start;
    logic [31:0]            t1;
    logic [31:0]            t2;

    logic                   aw_seen;
    logic                   w_seen;

} txn_t;


txn_t txn_fifo [0:1];


logic [31:0] timer;

logic wr_ptr;
logic proc_ptr;
logic axi_done_ptr;
logic core_done_ptr;


logic [63:0] load_latency_sum;
logic [63:0] store_latency_sum;


logic req_accept;

logic ar_hs;
logic r_hs;

logic aw_hs;
logic w_hs;
logic b_hs;

logic proc_new_req;

type_scr1_mem_cmd_e proc_cmd;

logic proc_aw_seen;
logic proc_w_seen;

logic [31:0] core_done_latency;
logic [31:0] axi_done_latency;


//--------------------------------------------------------------
// Handshakes
//--------------------------------------------------------------

assign req_accept = dmem_req && dmem_req_ack;

assign ar_hs = arvalid && arready;

assign r_hs = rvalid && rready && rlast;

assign aw_hs = awvalid && awready;

assign w_hs = wvalid && wready && wlast;

assign b_hs = bvalid && bready;


//--------------------------------------------------------------
// Request bypass handling
//--------------------------------------------------------------

assign proc_new_req = req_accept && (proc_ptr == wr_ptr);

assign proc_cmd =
    proc_new_req
        ? dmem_cmd
        : txn_fifo[proc_ptr].cmd;

assign proc_aw_seen =
    proc_new_req
        ? 1'b0
        : txn_fifo[proc_ptr].aw_seen;

assign proc_w_seen =
    proc_new_req
        ? 1'b0
        : txn_fifo[proc_ptr].w_seen;


assign core_done_latency =
    timer - txn_fifo[core_done_ptr].t_start;

assign axi_done_latency =
    timer - txn_fifo[axi_done_ptr].t1;


//--------------------------------------------------------------
// Average
//--------------------------------------------------------------

always_comb begin

    if (load_count != 0)
        load_average_latency =
            load_latency_sum / load_count;
    else
        load_average_latency = 32'd0;

    if (store_count != 0)
        store_average_latency =
            store_latency_sum / store_count;
    else
        store_average_latency = 32'd0;
end


//--------------------------------------------------------------
// Main monitor
//--------------------------------------------------------------

always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin

        timer         <= '0;

        wr_ptr        <= '0;
        proc_ptr      <= '0;
        axi_done_ptr  <= '0;
        core_done_ptr <= '0;


        load_last_latency     <= '0;
        load_axi_path_latency <= '0;
        load_last_addr        <= '0;

        load_min_latency <= '0;
        load_max_latency <= '0;
        load_count       <= '0;
        load_latency_sum <= '0;


        store_last_latency     <= '0;
        store_axi_path_latency <= '0;
        store_last_addr        <= '0;

        store_min_latency <= '0;
        store_max_latency <= '0;
        store_count       <= '0;
        store_latency_sum <= '0;


        for (int i = 0; i < 2; i++) begin
            txn_fifo[i] <= '0;
        end

    end else begin

        timer <= timer + 1'b1;


        //------------------------------------------------------
        // t_start
        //------------------------------------------------------

        if (req_accept) begin

            txn_fifo[wr_ptr].cmd <=
                dmem_cmd;

            txn_fifo[wr_ptr].addr <=
                dmem_addr;

            txn_fifo[wr_ptr].t_start <=
                timer;

            txn_fifo[wr_ptr].track <=
                ((dmem_addr & DDR_ADDR_MASK)
                    == DDR_ADDR_PATTERN);

            txn_fifo[wr_ptr].aw_seen <= 1'b0;
            txn_fifo[wr_ptr].w_seen  <= 1'b0;

            wr_ptr <= wr_ptr + 1'b1;
        end


        //------------------------------------------------------
        // LOAD t1 = AR handshake
        //------------------------------------------------------

        if ((proc_cmd == SCR1_MEM_CMD_RD) && ar_hs) begin
            txn_fifo[proc_ptr].t1 <= timer;
            proc_ptr <= proc_ptr + 1'b1;
        end
        //------------------------------------------------------
        // STORE t1
        // AW and W are independent AXI channels.
        //------------------------------------------------------

        if (proc_cmd == SCR1_MEM_CMD_WR) begin

            if (aw_hs)
                txn_fifo[proc_ptr].aw_seen <= 1'b1;

            if (w_hs)
                txn_fifo[proc_ptr].w_seen <= 1'b1;


            // t1 = both AW and W have been accepted
            if (   (proc_aw_seen || aw_hs)
                && (proc_w_seen  || w_hs)) begin

                txn_fifo[proc_ptr].t1 <= timer;
                proc_ptr <= proc_ptr + 1'b1;
            end
        end


        //------------------------------------------------------
        // t2
        //
        // LOAD  -> R
        // STORE -> B
        //------------------------------------------------------

        if (r_hs || b_hs) begin

            txn_fifo[axi_done_ptr].t2 <=
                timer;

            if (stats_enable
                && txn_fifo[axi_done_ptr].track) begin

                if (txn_fifo[axi_done_ptr].cmd
                    == SCR1_MEM_CMD_RD) begin

                    load_axi_path_latency <=
                        axi_done_latency;

                end else begin

                    store_axi_path_latency <=
                        axi_done_latency;
                end
            end

            axi_done_ptr <=
                axi_done_ptr + 1'b1;
        end


        //------------------------------------------------------
        // Clear statistics only.
        // FIFO and pointers are NOT cleared here.
        //------------------------------------------------------

        if (stats_clear) begin

            load_last_latency     <= '0;
            load_axi_path_latency <= '0;
            load_last_addr        <= '0;
            load_min_latency      <= '0;
            load_max_latency      <= '0;
            load_count            <= '0;
            load_latency_sum      <= '0;

            store_last_latency     <= '0;
            store_axi_path_latency <= '0;
            store_last_addr        <= '0;
            store_min_latency      <= '0;
            store_max_latency      <= '0;
            store_count            <= '0;
            store_latency_sum      <= '0;

        end else begin

            //--------------------------------------------------
            // t3
            //--------------------------------------------------

            if (axi_dmem_resp
                != SCR1_MEM_RESP_NOTRDY) begin

                if (stats_enable
                    && txn_fifo[core_done_ptr].track
                    && (axi_dmem_resp
                        == SCR1_MEM_RESP_RDY_OK)) begin


                    //------------------------------------------
                    // LOAD
                    //------------------------------------------

                    if (txn_fifo[core_done_ptr].cmd
                        == SCR1_MEM_CMD_RD) begin

                        load_last_latency <=
                            core_done_latency;

                        load_last_addr <=
                            txn_fifo[core_done_ptr].addr;


                        if (load_count == 0) begin

                            load_min_latency <=
                                core_done_latency;

                            load_max_latency <=
                                core_done_latency;

                        end else begin

                            if (core_done_latency
                                < load_min_latency)
                                load_min_latency <=
                                    core_done_latency;

                            if (core_done_latency
                                > load_max_latency)
                                load_max_latency <=
                                    core_done_latency;
                        end


                        load_latency_sum <=
                            load_latency_sum
                            + core_done_latency;

                        load_count <=
                            load_count + 1'b1;


                    //------------------------------------------
                    // STORE
                    //------------------------------------------

                    end else begin

                        store_last_latency <=
                            core_done_latency;

                        store_last_addr <=
                            txn_fifo[core_done_ptr].addr;


                        if (store_count == 0) begin

                            store_min_latency <=
                                core_done_latency;

                            store_max_latency <=
                                core_done_latency;

                        end else begin

                            if (core_done_latency
                                < store_min_latency)
                                store_min_latency <=
                                    core_done_latency;

                            if (core_done_latency
                                > store_max_latency)
                                store_max_latency <=
                                    core_done_latency;
                        end


                        store_latency_sum <=
                            store_latency_sum
                            + core_done_latency;

                        store_count <=
                            store_count + 1'b1;
                    end
                end


                // Advance even on errors and non-DDR transactions
                // to preserve request/response ordering.
                core_done_ptr <=
                    core_done_ptr + 1'b1;
            end
        end
    end
end

endmodule