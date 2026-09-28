`include "scr1_memif.svh"
`include "scr1_arch_description.svh"

module scr1_fetch_latency_mon #(
    // Nexys4DDR DDR2:
    // 0x0000_0000 .. 0x07FF_FFFF
    parameter logic [31:0] DDR_ADDR_MASK    = 32'hF800_0000,
    parameter logic [31:0] DDR_ADDR_PATTERN = 32'h0000_0000
) (
    input  logic                    clk,
    input  logic                    rst_n,

    // Statistics control
    input  logic                    stats_enable,
    input  logic                    stats_clear,

    // Request after IMEM router
    input  logic                    imem_req,
    input  logic                    imem_req_ack,
    input  logic [31:0]             imem_addr,

    // AXI read address
    input  logic                    arvalid,
    input  logic                    arready,

    // AXI read response
    input  logic                    rvalid,
    input  logic                    rready,
    input  logic                    rlast,

    // Response from AXI bridge back to IMEM router
    input  type_scr1_mem_resp_e      axi_imem_resp,

    // Results
    output logic [31:0]             last_latency,
    output logic [31:0]             axi_path_latency,
    output logic [31:0]             last_addr,

    output logic [31:0]             min_latency,
    output logic [31:0]             max_latency,
    output logic [31:0]             fetch_count,
    output logic [31:0]             average_latency
);

typedef struct packed {
    logic        track;
    logic [31:0] addr;
    logic [31:0] t_start;
    logic [31:0] t1;
} timestamp_t;


// SCR1 AXI bridge has 2 request slots
timestamp_t timestamp_fifo [0:1];

logic [31:0] timer;

logic wr_ptr;
logic ar_ptr;
logic r_ptr;
logic done_ptr;

logic [63:0] latency_sum;

logic req_accept;
logic ar_hs;
logic r_hs;
logic imem_resp_done;

logic [31:0] done_latency;
logic [31:0] current_axi_latency;


assign req_accept =
       imem_req
    && imem_req_ack;

assign ar_hs =
       arvalid
    && arready;

assign r_hs =
       rvalid
    && rready
    && rlast;

assign imem_resp_done =
       axi_imem_resp != SCR1_MEM_RESP_NOTRDY;


assign done_latency =
    timer - timestamp_fifo[done_ptr].t_start;

assign current_axi_latency =
    timer - timestamp_fifo[r_ptr].t1;


// Integer average, fractional part is discarded.
always_comb begin
    if (fetch_count != 0)
        average_latency = latency_sum / fetch_count;
    else
        average_latency = 32'd0;
end


always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin

        timer    <= '0;

        wr_ptr   <= '0;
        ar_ptr   <= '0;
        r_ptr    <= '0;
        done_ptr <= '0;

        last_latency     <= '0;
        axi_path_latency <= '0;
        last_addr        <= '0;

        min_latency <= '0;
        max_latency <= '0;
        fetch_count <= '0;
        latency_sum <= '0;

        for (int i = 0; i < 2; i++) begin
            timestamp_fifo[i] <= '0;
        end

    end else begin

        timer <= timer + 1'b1;


        //------------------------------------------------------
        // t_start
        //------------------------------------------------------

        if (req_accept) begin

            timestamp_fifo[wr_ptr].addr <=
                imem_addr;

            timestamp_fifo[wr_ptr].t_start <=
                timer;

            timestamp_fifo[wr_ptr].track <=
                ((imem_addr & DDR_ADDR_MASK)
                    == DDR_ADDR_PATTERN);

            wr_ptr <= wr_ptr + 1'b1;
        end


        //------------------------------------------------------
        // t1
        //------------------------------------------------------

        if (ar_hs) begin

            timestamp_fifo[ar_ptr].t1 <=
                timer;

            ar_ptr <= ar_ptr + 1'b1;
        end


        //------------------------------------------------------
        // t2
        //------------------------------------------------------

        if (r_hs) begin

            if (stats_enable
                && timestamp_fifo[r_ptr].track) begin

                axi_path_latency <=
                    current_axi_latency;
            end

            r_ptr <= r_ptr + 1'b1;
        end


        //------------------------------------------------------
        // Statistics clear
        //------------------------------------------------------

        if (stats_clear) begin

            last_latency     <= '0;
            axi_path_latency <= '0;
            last_addr        <= '0;

            min_latency <= '0;
            max_latency <= '0;
            fetch_count <= '0;
            latency_sum <= '0;

        end else begin

            //--------------------------------------------------
            // t3
            //--------------------------------------------------

            if (imem_resp_done) begin

                if (stats_enable
                    && timestamp_fifo[done_ptr].track
                    && (axi_imem_resp
                        == SCR1_MEM_RESP_RDY_OK)) begin

                    last_latency <=
                        done_latency;

                    last_addr <=
                        timestamp_fifo[done_ptr].addr;


                    //--------------------------------------------------
                    // First measurement
                    //--------------------------------------------------

                    if (fetch_count == 0) begin

                        min_latency <=
                            done_latency;

                        max_latency <=
                            done_latency;

                    end else begin

                        if (done_latency < min_latency)
                            min_latency <= done_latency;

                        if (done_latency > max_latency)
                            max_latency <= done_latency;
                    end


                    latency_sum <=
                        latency_sum + done_latency;

                    fetch_count <=
                        fetch_count + 1'b1;
                end

                done_ptr <= done_ptr + 1'b1;
            end
        end
    end
end

endmodule