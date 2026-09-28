`include "scr1_memif.svh"
`include "scr1_arch_description.svh"

module scr1_latency_regs (
    input  logic                           clk,
    input  logic                           rst_n,

    // DMEM router PORT3
    input  logic                           dmem_req,
    input  type_scr1_mem_cmd_e             dmem_cmd,
    input  type_scr1_mem_width_e           dmem_width,
    input  logic [`SCR1_DMEM_AWIDTH-1:0]   dmem_addr,
    input  logic [`SCR1_DMEM_DWIDTH-1:0]   dmem_wdata,

    output logic                           dmem_req_ack,
    output logic [`SCR1_DMEM_DWIDTH-1:0]   dmem_rdata,
    output type_scr1_mem_resp_e            dmem_resp,

    // Monitor control
    output logic                           stats_enable,
    output logic                           stats_clear,

    // IMEM
    input logic [31:0] imem_last_latency,
    input logic [31:0] imem_axi_latency,
    input logic [31:0] imem_last_addr,
    input logic [31:0] imem_min_latency,
    input logic [31:0] imem_max_latency,
    input logic [31:0] imem_count,
    input logic [31:0] imem_average_latency,

    // LOAD
    input logic [31:0] load_last_latency,
    input logic [31:0] load_axi_latency,
    input logic [31:0] load_last_addr,
    input logic [31:0] load_min_latency,
    input logic [31:0] load_max_latency,
    input logic [31:0] load_count,
    input logic [31:0] load_average_latency,

    // STORE
    input logic [31:0] store_last_latency,
    input logic [31:0] store_axi_latency,
    input logic [31:0] store_last_addr,
    input logic [31:0] store_min_latency,
    input logic [31:0] store_max_latency,
    input logic [31:0] store_count,
    input logic [31:0] store_average_latency
);


//--------------------------------------------------------------
// Register map
//--------------------------------------------------------------

localparam logic [7:0] LATMON_CONTROL = 8'h00;
localparam logic [7:0] LATMON_STATUS  = 8'h04;

localparam logic [7:0] LATMON_IMEM_LAST  = 8'h10;
localparam logic [7:0] LATMON_IMEM_AXI   = 8'h14;
localparam logic [7:0] LATMON_IMEM_ADDR  = 8'h18;
localparam logic [7:0] LATMON_IMEM_MIN   = 8'h1C;
localparam logic [7:0] LATMON_IMEM_MAX   = 8'h20;
localparam logic [7:0] LATMON_IMEM_COUNT = 8'h24;
localparam logic [7:0] LATMON_IMEM_AVG   = 8'h28;

localparam logic [7:0] LATMON_LOAD_LAST  = 8'h30;
localparam logic [7:0] LATMON_LOAD_AXI   = 8'h34;
localparam logic [7:0] LATMON_LOAD_ADDR  = 8'h38;
localparam logic [7:0] LATMON_LOAD_MIN   = 8'h3C;
localparam logic [7:0] LATMON_LOAD_MAX   = 8'h40;
localparam logic [7:0] LATMON_LOAD_COUNT = 8'h44;
localparam logic [7:0] LATMON_LOAD_AVG   = 8'h48;

localparam logic [7:0] LATMON_STORE_LAST  = 8'h50;
localparam logic [7:0] LATMON_STORE_AXI   = 8'h54;
localparam logic [7:0] LATMON_STORE_ADDR  = 8'h58;
localparam logic [7:0] LATMON_STORE_MIN   = 8'h5C;
localparam logic [7:0] LATMON_STORE_MAX   = 8'h60;
localparam logic [7:0] LATMON_STORE_COUNT = 8'h64;
localparam logic [7:0] LATMON_STORE_AVG   = 8'h68;


//--------------------------------------------------------------
// Snapshot registers
//--------------------------------------------------------------

logic snapshot_valid;

// IMEM
logic [31:0] s_imem_last;
logic [31:0] s_imem_axi;
logic [31:0] s_imem_addr;
logic [31:0] s_imem_min;
logic [31:0] s_imem_max;
logic [31:0] s_imem_count;
logic [31:0] s_imem_avg;

// LOAD
logic [31:0] s_load_last;
logic [31:0] s_load_axi;
logic [31:0] s_load_addr;
logic [31:0] s_load_min;
logic [31:0] s_load_max;
logic [31:0] s_load_count;
logic [31:0] s_load_avg;

// STORE
logic [31:0] s_store_last;
logic [31:0] s_store_axi;
logic [31:0] s_store_addr;
logic [31:0] s_store_min;
logic [31:0] s_store_max;
logic [31:0] s_store_count;
logic [31:0] s_store_avg;


logic access_valid;


//--------------------------------------------------------------
// Validation
//--------------------------------------------------------------

assign access_valid =
       (dmem_width == SCR1_MEM_WIDTH_WORD)
    && (dmem_addr[1:0] == 2'b00)
    && (dmem_addr[7:0] <= LATMON_STORE_AVG);

assign dmem_req_ack = 1'b1;


//--------------------------------------------------------------
// MMIO
//--------------------------------------------------------------

always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin

        dmem_resp  <= SCR1_MEM_RESP_NOTRDY;
        dmem_rdata <= '0;

        stats_enable  <= 1'b0;
        stats_clear   <= 1'b0;
        snapshot_valid <= 1'b0;

        s_imem_last  <= '0;
        s_imem_axi   <= '0;
        s_imem_addr  <= '0;
        s_imem_min   <= '0;
        s_imem_max   <= '0;
        s_imem_count <= '0;
        s_imem_avg   <= '0;

        s_load_last  <= '0;
        s_load_axi   <= '0;
        s_load_addr  <= '0;
        s_load_min   <= '0;
        s_load_max   <= '0;
        s_load_count <= '0;
        s_load_avg   <= '0;

        s_store_last  <= '0;
        s_store_axi   <= '0;
        s_store_addr  <= '0;
        s_store_min   <= '0;
        s_store_max   <= '0;
        s_store_count <= '0;
        s_store_avg   <= '0;

    end else begin

        dmem_resp  <= SCR1_MEM_RESP_NOTRDY;
        dmem_rdata <= '0;

        // pulse by default
        stats_clear <= 1'b0;


        if (dmem_req) begin

            if (!access_valid) begin

                dmem_resp <=
                    SCR1_MEM_RESP_RDY_ER;

            end else if (dmem_cmd
                         == SCR1_MEM_CMD_RD) begin

                dmem_resp <=
                    SCR1_MEM_RESP_RDY_OK;

                case (dmem_addr[7:0])

                    LATMON_CONTROL:
                        dmem_rdata <=
                            {31'b0, stats_enable};

                    LATMON_STATUS:
                        dmem_rdata <=
                            {30'b0,
                             stats_enable,
                             snapshot_valid};


                    LATMON_IMEM_LAST:
                        dmem_rdata <= s_imem_last;

                    LATMON_IMEM_AXI:
                        dmem_rdata <= s_imem_axi;

                    LATMON_IMEM_ADDR:
                        dmem_rdata <= s_imem_addr;

                    LATMON_IMEM_MIN:
                        dmem_rdata <= s_imem_min;

                    LATMON_IMEM_MAX:
                        dmem_rdata <= s_imem_max;

                    LATMON_IMEM_COUNT:
                        dmem_rdata <= s_imem_count;

                    LATMON_IMEM_AVG:
                        dmem_rdata <= s_imem_avg;


                    LATMON_LOAD_LAST:
                        dmem_rdata <= s_load_last;

                    LATMON_LOAD_AXI:
                        dmem_rdata <= s_load_axi;

                    LATMON_LOAD_ADDR:
                        dmem_rdata <= s_load_addr;

                    LATMON_LOAD_MIN:
                        dmem_rdata <= s_load_min;

                    LATMON_LOAD_MAX:
                        dmem_rdata <= s_load_max;

                    LATMON_LOAD_COUNT:
                        dmem_rdata <= s_load_count;

                    LATMON_LOAD_AVG:
                        dmem_rdata <= s_load_avg;


                    LATMON_STORE_LAST:
                        dmem_rdata <= s_store_last;

                    LATMON_STORE_AXI:
                        dmem_rdata <= s_store_axi;

                    LATMON_STORE_ADDR:
                        dmem_rdata <= s_store_addr;

                    LATMON_STORE_MIN:
                        dmem_rdata <= s_store_min;

                    LATMON_STORE_MAX:
                        dmem_rdata <= s_store_max;

                    LATMON_STORE_COUNT:
                        dmem_rdata <= s_store_count;

                    LATMON_STORE_AVG:
                        dmem_rdata <= s_store_avg;

                    default:
                        dmem_rdata <= '0;

                endcase


            //--------------------------------------------------
            // CONTROL write
            //--------------------------------------------------

            end else begin

                if (dmem_addr[7:0]
                    == LATMON_CONTROL) begin

                    dmem_resp <=
                        SCR1_MEM_RESP_RDY_OK;


                    // bit 0 = statistics enable
                    stats_enable <=
                        dmem_wdata[0];


                    // bit 1 = clear pulse
                    if (dmem_wdata[1]) begin

                        stats_clear <= 1'b1;
                        snapshot_valid <= 1'b0;
                    end


                    // bit 2 = snapshot
                    if (dmem_wdata[2]) begin

                        s_imem_last <=
                            imem_last_latency;

                        s_imem_axi <=
                            imem_axi_latency;

                        s_imem_addr <=
                            imem_last_addr;

                        s_imem_min <=
                            imem_min_latency;

                        s_imem_max <=
                            imem_max_latency;

                        s_imem_count <=
                            imem_count;

                        s_imem_avg <=
                            imem_average_latency;


                        s_load_last <=
                            load_last_latency;

                        s_load_axi <=
                            load_axi_latency;

                        s_load_addr <=
                            load_last_addr;

                        s_load_min <=
                            load_min_latency;

                        s_load_max <=
                            load_max_latency;

                        s_load_count <=
                            load_count;

                        s_load_avg <=
                            load_average_latency;


                        s_store_last <=
                            store_last_latency;

                        s_store_axi <=
                            store_axi_latency;

                        s_store_addr <=
                            store_last_addr;

                        s_store_min <=
                            store_min_latency;

                        s_store_max <=
                            store_max_latency;

                        s_store_count <=
                            store_count;

                        s_store_avg <=
                            store_average_latency;


                        snapshot_valid <= 1'b1;
                    end

                end else begin

                    dmem_resp <=
                        SCR1_MEM_RESP_RDY_ER;
                end
            end
        end
    end
end

endmodule