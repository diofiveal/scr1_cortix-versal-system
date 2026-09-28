// Not Synthacore. Just me.
// Module for communication between LSU and EXU, if we gonna use SCR1 with MEM stage



`include "scr1_arch_description.svh"
`include "scr1_arch_types.svh"
`include "scr1_memif.svh"
`include "scr1_riscv_isa_decoding.svh"

`ifdef SCR1_TDU_EN
`include "scr1_tdu.svh"
`endif

`ifdef SCR1_MEM_STAGE_EN
module scr1_pipe_mem (
// Common
//------------------------------------------------------------------
input  logic                                                    clk,
input  logic                                                  rst_n,
//------------------------------------------------------------------
// EXU -> MEM
//------------------------------------------------------------------
input  logic                                          exu2mem_req_i,  // Valid signal. EXU already has a memory-interface instruction
input  type_scr1_lsu_cmd_sel_e                    exu2mem_lsu_cmd_i,  // Type of instruction exactly
input  logic [`SCR1_XLEN-1:0]                        exu2mem_addr_i,  // Address calculated by EXU
input  logic [`SCR1_XLEN-1:0]                       exu2mem_sdata_i,  // Data for store
input  logic [`SCR1_MPRF_AWIDTH-1:0]              exu2mem_rd_addr_i,
input  logic [`SCR1_XLEN-1:0]                          exu2mem_pc_i,
input  logic                                     exu2mem_rd_w_req_i,
//------------------------------------------------------------------
// MEM -> EXU
//------------------------------------------------------------------
output  logic                                         mem2exu_rdy_o,  // MEM ready for next instruction from EXU
output  logic                                        mem2exu_done_o,  // Operation in MEM finished
output  logic [`SCR1_XLEN-1:0]                      mem2exu_ldata_o,  // Data for loading in register
output  logic [`SCR1_MPRF_AWIDTH-1:0]             mem2exu_rd_addr_o,
output  logic                                    mem2exu_rd_w_req_o,
output  logic [`SCR1_XLEN-1:0]                         mem2exu_pc_o,
output  logic [`SCR1_XLEN-1:0]                       mem2exu_addr_o,
output  logic                                         mem2exu_exc_o,  // Exeption flag
output  type_scr1_exc_code_e                     mem2exu_exc_code_o,  // Exeption code

`ifdef SCR1_TDU_EN
//------------------------------------------------------------------
// MEM/LSU <-> TDU
//------------------------------------------------------------------
output type_scr1_brkm_lsu_mon_s           mem2tdu_dmon_o,
input  logic                              tdu2mem_ibrkpt_exc_req_i,
input  logic                              tdu2mem_dbrkpt_exc_req_i,
`endif
//------------------------------------------------------------------
// MEM <-> DMEM
//------------------------------------------------------------------
output  logic                                        mem2dmem_req_o,
output  type_scr1_mem_cmd_e                          mem2dmem_cmd_o,
output  type_scr1_mem_width_e                      mem2dmem_width_o,
output  logic [`SCR1_DMEM_AWIDTH-1:0]               mem2dmem_addr_o,
output  logic [`SCR1_DMEM_DWIDTH-1:0]              mem2dmem_wdata_o,

input   logic                                    dmem2mem_req_ack_i,
input   logic [`SCR1_DMEM_DWIDTH-1:0]              dmem2mem_rdata_i,
input   type_scr1_mem_resp_e                        dmem2mem_resp_i
//-------------------------------------------------------------------
);
//-------------------------------------------------------------------
// Pipeline signals
//-------------------------------------------------------------------
logic                                                      mem_vd_ff; 
type_scr1_lsu_cmd_sel_e                               mem_lsu_cmd_ff;
logic [`SCR1_XLEN-1:0]                                   mem_addr_ff;
logic [`SCR1_XLEN-1:0]                                  mem_sdata_ff;
logic [`SCR1_MPRF_AWIDTH-1:0]                         mem_rd_addr_ff;
logic [`SCR1_XLEN-1:0]                                     mem_pc_ff;
logic                                                mem_rd_w_req_ff;
//---------------------------------------------------------------------
// Handshake signals
//---------------------------------------------------------------------
logic                                                       mem_accept;
logic                                                     mem_complete;
//---------------------------------------------------------------------
// LSU signals
//---------------------------------------------------------------------
logic                                                          lsu_rdy;
logic [`SCR1_XLEN-1:0]                                       lsu_ldata;
logic                                                          lsu_exc;
type_scr1_exc_code_e                                      lsu_exc_code;
//---------------------------------------------------------------------
// Pipeline register
//---------------------------------------------------------------------
always_ff @(posedge clk, negedge rst_n) begin
    if (~rst_n) begin
        mem_vd_ff       <= 1'b0;
        mem_lsu_cmd_ff  <= SCR1_LSU_CMD_NONE;
        mem_addr_ff     <= '0;
        mem_sdata_ff    <= '0;
        mem_rd_addr_ff  <= '0;
        mem_pc_ff       <= '0;
        mem_rd_w_req_ff <= 1'b0;
    end else begin
        if (mem_complete) begin
            mem_vd_ff <= 1'b0;
        end

        if (mem_accept) begin
            mem_vd_ff       <= 1'b1;
            mem_lsu_cmd_ff  <= exu2mem_lsu_cmd_i;
            mem_addr_ff     <= exu2mem_addr_i;
            mem_sdata_ff    <= exu2mem_sdata_i;
            mem_rd_addr_ff  <= exu2mem_rd_addr_i;
            mem_pc_ff       <= exu2mem_pc_i;
            mem_rd_w_req_ff <= exu2mem_rd_w_req_i;
        end
    end
end
//--------------------------------------------------------------------- 

// Output forming
//---------------------------------------------------------------------
assign mem2exu_rdy_o = ~mem_vd_ff;

assign mem_accept =
       exu2mem_req_i
     & mem2exu_rdy_o;

// LSU completes either normally or with an exception
assign mem_complete =
       mem_vd_ff
     & (lsu_rdy | lsu_exc);

assign mem2exu_done_o     = mem_complete;
assign mem2exu_ldata_o    = lsu_ldata;
assign mem2exu_exc_o      = mem_vd_ff & lsu_exc;
assign mem2exu_exc_code_o = lsu_exc_code;

assign mem2exu_rd_addr_o  = mem_rd_addr_ff;
assign mem2exu_rd_w_req_o = mem_rd_w_req_ff;
assign mem2exu_pc_o       = mem_pc_ff;
assign mem2exu_addr_o     = mem_addr_ff;

assign mem2exu_pc_o       = mem_pc_ff;
assign mem2exu_addr_o     = mem_addr_ff;
//----------------------------------------------------------------------
// Load/Store Unit Connection
//----------------------------------------------------------------------
scr1_pipe_lsu i_lsu (
    .rst_n                      (rst_n),
    .clk                        (clk),

    // MEM register -> LSU
    .exu2lsu_req_i              (mem_vd_ff),
    .exu2lsu_cmd_i              (mem_lsu_cmd_ff),
    .exu2lsu_addr_i             (mem_addr_ff),
    .exu2lsu_sdata_i            (mem_sdata_ff),

    // LSU -> MEM/EXU
    .lsu2exu_rdy_o              (lsu_rdy),
    .lsu2exu_ldata_o            (lsu_ldata),
    .lsu2exu_exc_o              (lsu_exc),
    .lsu2exu_exc_code_o         (lsu_exc_code),

`ifdef SCR1_TDU_EN
    .lsu2tdu_dmon_o             (mem2tdu_dmon_o),
    .tdu2lsu_ibrkpt_exc_req_i   (tdu2mem_ibrkpt_exc_req_i),
    .tdu2lsu_dbrkpt_exc_req_i   (tdu2mem_dbrkpt_exc_req_i),
`endif

    // LSU -> DMEM
    .lsu2dmem_req_o             (mem2dmem_req_o),
    .lsu2dmem_cmd_o             (mem2dmem_cmd_o),
    .lsu2dmem_width_o           (mem2dmem_width_o),
    .lsu2dmem_addr_o            (mem2dmem_addr_o),
    .lsu2dmem_wdata_o           (mem2dmem_wdata_o),

    // DMEM -> LSU
    .dmem2lsu_req_ack_i         (dmem2mem_req_ack_i),
    .dmem2lsu_rdata_i           (dmem2mem_rdata_i),
    .dmem2lsu_resp_i            (dmem2mem_resp_i)
);
//----------------------------------------------------------------------
endmodule : scr1_pipe_mem
`endif
// Now we use this module to isolate new MEM pipeline stage