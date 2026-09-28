/// Copyright by Syntacore LLC � 2016-2021. See LICENSE for details
/// @file       <scr1_pipe_idu.sv>
/// @brief      Instruction Decoder Unit (IDU)
///

//------------------------------------------------------------------------------
 //
 // Functionality:
 // - Decodes the instruction and creates the appropriate control signals for EXU
 //
 // Structure:
 // - Instruction decoder
 // - IDU <-> IFU i/f
 // - IDU <-> EXU i/f
 //
//------------------------------------------------------------------------------

`include "scr1_memif.svh"
`include "scr1_arch_types.svh"
`include "scr1_riscv_isa_decoding.svh"
`include "scr1_arch_description.svh"

module scr1_pipe_idu
(
`ifdef SCR1_TRGT_SIMULATION
    input   logic                           rst_n,                  // IDU reset
    input   logic                           clk,                    // IDU clock
`endif // SCR1_TRGT_SIMULATION

    // IFU <-> IDU interface
    output  logic                           idu2ifu_rdy_o,          // IDU ready for new data
    input   logic [`SCR1_IMEM_DWIDTH-1:0]   ifu2idu_instr_i,        // IFU instruction
    input   logic                           ifu2idu_imem_err_i,     // Instruction access fault exception
    input   logic                           ifu2idu_err_rvi_hi_i,   // 1 - imem fault when trying to fetch second half of an unaligned RVI instruction
    input   logic                           ifu2idu_vd_i,           // IFU request
`ifdef SCR1_EARLY_BRANCH
    input logic [`SCR1_XLEN-1:0]            ifu2idu_pc_i,
`endif // SCR1_EARLY_BRANCH

    // IDU <-> EXU interface
    output  logic                           idu2exu_req_o,          // IDU request
    output  type_scr1_exu_cmd_s             idu2exu_cmd_o,          // IDU command
    output  logic                           idu2exu_use_rs1_o,      // Instruction uses rs1
    output  logic                           idu2exu_use_rs2_o,      // Instruction uses rs2
`ifndef SCR1_NO_EXE_STAGE
    output  logic                           idu2exu_use_rd_o,       // Instruction uses rd
    output  logic                           idu2exu_use_imm_o,      // Instruction uses immediate
`endif // SCR1_NO_EXE_STAGE
`ifdef SCR1_EARLY_BRANCH
    // Ports for reading MPRF
    output logic [`SCR1_MPRF_AWIDTH-1:0]   idu2mprf_rs1_addr_o,
    input  logic [`SCR1_XLEN-1:0]          mprf2idu_rs1_data_i,
    output logic [`SCR1_MPRF_AWIDTH-1:0]   idu2mprf_rs2_addr_o,
    input  logic [`SCR1_XLEN-1:0]          mprf2idu_rs2_data_i,

    // Ports for requests to IFU
    output logic                           idu2ifu_branch_req_o,
    output logic [`SCR1_XLEN-1:0]          idu2ifu_branch_target_o,
`endif
`ifdef SCR1_BPU_EN
    input   logic                          ifu2idu_bpu_pred_i,
    input   logic                          ifu2idu_bpu_vld_i,

    input   logic [`SCR1_XLEN-1:0]         ifu2idu_bpu_target_i,
    input   logic                          ifu2idu_bpu_str_i,
    input   logic                          ifu2idu_bpu_steer_bypass_i,
    output  logic                          idu2exu_bpu_pred_o,
    output  logic                          idu2exu_bpu_vld_o,
    output  logic [`SCR1_XLEN-1:0]         idu2exu_bpu_target_o,
    output  logic                          idu2exu_bpu_str_o,
    output  logic                          idu2exu_bpu_steer_bypass_o,
`endif
    input   logic                           exu2idu_rdy_i           // EXU ready for new data

);

//-------------------------------------------------------------------------------
// Local parameters declaration
//-------------------------------------------------------------------------------

localparam [SCR1_GPR_FIELD_WIDTH-1:0] SCR1_MPRF_ZERO_ADDR   = 5'd0;
localparam [SCR1_GPR_FIELD_WIDTH-1:0] SCR1_MPRF_RA_ADDR     = 5'd1;
localparam [SCR1_GPR_FIELD_WIDTH-1:0] SCR1_MPRF_SP_ADDR     = 5'd2;

//-------------------------------------------------------------------------------
// Local signals declaration
//-------------------------------------------------------------------------------

logic [`SCR1_IMEM_DWIDTH-1:0]       instr;
type_scr1_instr_type_e              instr_type;
type_scr1_rvi_opcode_e              rvi_opcode;
logic                               rvi_illegal;
logic [2:0]                         funct3;
logic [6:0]                         funct7;
logic [11:0]                        funct12;
logic [4:0]                         shamt;
`ifdef SCR1_RVC_EXT
logic                               rvc_illegal;
`endif  // SCR1_RVC_EXT
`ifdef SCR1_RVE_EXT
logic                               rve_illegal;
`endif  // SCR1_RVE_EXT

`ifdef SCR1_EARLY_BRANCH
logic                               branch_taken_early;
logic                               branch_req_early;
logic [`SCR1_XLEN-1:0]              branch_target_early;
logic                               idu_accept;                // for handshake
`ifdef SCR1_BPU_EN
logic                               bpu_path_taken_early;
`endif // SCR1_BPU_EN
`endif //SCR1_EARLY_BRANCH

//-------------------------------------------------------------------------------
// Instruction decoding
//-------------------------------------------------------------------------------

assign idu2ifu_rdy_o  = exu2idu_rdy_i;
assign idu2exu_req_o  = ifu2idu_vd_i;
assign instr          = ifu2idu_instr_i;

`ifdef SCR1_BPU_EN

assign idu2exu_bpu_pred_o          = ifu2idu_bpu_pred_i;
assign idu2exu_bpu_vld_o           = ifu2idu_bpu_vld_i;

assign idu2exu_bpu_target_o        = ifu2idu_bpu_target_i;
assign idu2exu_bpu_str_o           = ifu2idu_bpu_str_i;
assign idu2exu_bpu_steer_bypass_o  = ifu2idu_bpu_steer_bypass_i;
`ifdef SCR1_EARLY_BRANCH
assign bpu_path_taken_early = ifu2idu_bpu_vld_i
     & ifu2idu_bpu_pred_i
     & (ifu2idu_bpu_str_i | ifu2idu_bpu_steer_bypass_i);
`endif // SCR1_EARLY_BRANCH
`endif // SCR1_BPU_EN
// RVI / RVC
assign instr_type   = type_scr1_instr_type_e'(instr[1:0]);

// RVI / RVC fields
assign rvi_opcode   = type_scr1_rvi_opcode_e'(instr[6:2]);                          // RVI
assign funct3       = (instr_type == SCR1_INSTR_RVI) ? instr[14:12] : instr[15:13]; // RVI / RVC
assign funct7       = instr[31:25];                                                 // RVI
assign funct12      = instr[31:20];                                                 // RVI (SYSTEM)
assign shamt        = instr[24:20];                                                 // RVI

// RV32I(MC) decode
always_comb begin
    // Defaults
    idu2exu_cmd_o.instr_rvc   = 1'b0;
    idu2exu_cmd_o.ialu_op     = SCR1_IALU_OP_REG_REG;
    idu2exu_cmd_o.ialu_cmd    = SCR1_IALU_CMD_NONE;
    idu2exu_cmd_o.sum2_op     = SCR1_SUM2_OP_PC_IMM;
    idu2exu_cmd_o.lsu_cmd     = SCR1_LSU_CMD_NONE;
    idu2exu_cmd_o.csr_op      = SCR1_CSR_OP_REG;
    idu2exu_cmd_o.csr_cmd     = SCR1_CSR_CMD_NONE;
    idu2exu_cmd_o.rd_wb_sel   = SCR1_RD_WB_NONE;
    idu2exu_cmd_o.jump_req    = 1'b0;
    idu2exu_cmd_o.branch_req  = 1'b0;
    idu2exu_cmd_o.mret_req    = 1'b0;
    idu2exu_cmd_o.fencei_req  = 1'b0;
    idu2exu_cmd_o.wfi_req     = 1'b0;
    idu2exu_cmd_o.rs1_addr    = '0;
    idu2exu_cmd_o.rs2_addr    = '0;
    idu2exu_cmd_o.rd_addr     = '0;
    idu2exu_cmd_o.imm         = '0;
    idu2exu_cmd_o.exc_req     = 1'b0;
    idu2exu_cmd_o.exc_code    = SCR1_EXC_CODE_INSTR_MISALIGN;
`ifdef SCR1_EARLY_BRANCH
    branch_taken_early               = 1'b0;
    branch_target_early              = '0;
    branch_req_early                 = 1'b0;
    idu2exu_cmd_o.early_branch_valid = 1'b0;
    idu2exu_cmd_o.early_branch_taken = 1'b0;
`endif // SCR1_EARLY_BRANCH

    // Clock gating
    idu2exu_use_rs1_o         = 1'b0;
    idu2exu_use_rs2_o         = 1'b0;
`ifndef SCR1_NO_EXE_STAGE
    idu2exu_use_rd_o          = 1'b0;
    idu2exu_use_imm_o         = 1'b0;
`endif // SCR1_NO_EXE_STAGE

    rvi_illegal             = 1'b0;
`ifdef SCR1_RVE_EXT
    rve_illegal             = 1'b0;
`endif  // SCR1_RVE_EXT
`ifdef SCR1_RVC_EXT
    rvc_illegal             = 1'b0;
`endif  // SCR1_RVC_EXT

    // Check for IMEM access fault
    if (ifu2idu_imem_err_i) begin
        idu2exu_cmd_o.exc_req     = 1'b1;
        idu2exu_cmd_o.exc_code    = SCR1_EXC_CODE_INSTR_ACCESS_FAULT;
        idu2exu_cmd_o.instr_rvc   = ifu2idu_err_rvi_hi_i;
    end else begin  // no imem fault
        case (instr_type)
            SCR1_INSTR_RVI  : begin
                idu2exu_cmd_o.rs1_addr    = instr[19:15];
                idu2exu_cmd_o.rs2_addr    = instr[24:20];
                idu2exu_cmd_o.rd_addr     = instr[11:7];
                case (rvi_opcode)
                    SCR1_OPCODE_AUIPC           : begin
`ifndef SCR1_NO_EXE_STAGE
                        idu2exu_use_rd_o          = 1'b1;
                        idu2exu_use_imm_o         = 1'b1;
`endif // SCR1_NO_EXE_STAGE
                        idu2exu_cmd_o.sum2_op     = SCR1_SUM2_OP_PC_IMM;
                        idu2exu_cmd_o.rd_wb_sel   = SCR1_RD_WB_SUM2;
                        idu2exu_cmd_o.imm         = {instr[31:12], 12'b0};
`ifdef SCR1_RVE_EXT
                        if (instr[11])          rve_illegal = 1'b1;
`endif  // SCR1_RVE_EXT
                    end // SCR1_OPCODE_AUIPC

                    SCR1_OPCODE_LUI             : begin
`ifndef SCR1_NO_EXE_STAGE
                        idu2exu_use_rd_o          = 1'b1;
                        idu2exu_use_imm_o         = 1'b1;
`endif // SCR1_NO_EXE_STAGE
                        idu2exu_cmd_o.rd_wb_sel   = SCR1_RD_WB_IMM;
                        idu2exu_cmd_o.imm         = {instr[31:12], 12'b0};
`ifdef SCR1_RVE_EXT
                        if (instr[11])          rve_illegal = 1'b1;
`endif  // SCR1_RVE_EXT
                    end // SCR1_OPCODE_LUI

                    SCR1_OPCODE_JAL             : begin
`ifndef SCR1_NO_EXE_STAGE
                        idu2exu_use_rd_o          = 1'b1;
                        idu2exu_use_imm_o         = 1'b1;
`endif // SCR1_NO_EXE_STAGE
                        idu2exu_cmd_o.sum2_op     = SCR1_SUM2_OP_PC_IMM;
                        idu2exu_cmd_o.rd_wb_sel   = SCR1_RD_WB_INC_PC;
                        idu2exu_cmd_o.jump_req    = 1'b1;
                        idu2exu_cmd_o.imm         = {{12{instr[31]}}, instr[19:12], instr[20], instr[30:21], 1'b0};
`ifdef SCR1_RVE_EXT
                        if (instr[11])          rve_illegal = 1'b1;
`endif  // SCR1_RVE_EXT
                    end // SCR1_OPCODE_JAL

                    SCR1_OPCODE_LOAD            : begin
                        idu2exu_use_rs1_o         = 1'b1;
`ifndef SCR1_NO_EXE_STAGE
                        idu2exu_use_rd_o          = 1'b1;
                        idu2exu_use_imm_o         = 1'b1;
`endif // SCR1_NO_EXE_STAGE
                        idu2exu_cmd_o.sum2_op     = SCR1_SUM2_OP_REG_IMM;
                        idu2exu_cmd_o.rd_wb_sel   = SCR1_RD_WB_LSU;
                        idu2exu_cmd_o.imm         = {{21{instr[31]}}, instr[30:20]};
                        case (funct3)
                            3'b000  : idu2exu_cmd_o.lsu_cmd = SCR1_LSU_CMD_LB;
                            3'b001  : idu2exu_cmd_o.lsu_cmd = SCR1_LSU_CMD_LH;
                            3'b010  : idu2exu_cmd_o.lsu_cmd = SCR1_LSU_CMD_LW;
                            3'b100  : idu2exu_cmd_o.lsu_cmd = SCR1_LSU_CMD_LBU;
                            3'b101  : idu2exu_cmd_o.lsu_cmd = SCR1_LSU_CMD_LHU;
                            default : rvi_illegal = 1'b1;
                        endcase // funct3
`ifdef SCR1_RVE_EXT
                        if (instr[11] | instr[19])  rve_illegal = 1'b1;
`endif  // SCR1_RVE_EXT
                    end // SCR1_OPCODE_LOAD

                    SCR1_OPCODE_STORE           : begin
                        idu2exu_use_rs1_o         = 1'b1;
                        idu2exu_use_rs2_o         = 1'b1;
`ifndef SCR1_NO_EXE_STAGE
                        idu2exu_use_imm_o         = 1'b1;
`endif // SCR1_NO_EXE_STAGE
                        idu2exu_cmd_o.sum2_op     = SCR1_SUM2_OP_REG_IMM;
                        idu2exu_cmd_o.imm         = {{21{instr[31]}}, instr[30:25], instr[11:7]};
                        case (funct3)
                            3'b000  : idu2exu_cmd_o.lsu_cmd = SCR1_LSU_CMD_SB;
                            3'b001  : idu2exu_cmd_o.lsu_cmd = SCR1_LSU_CMD_SH;
                            3'b010  : idu2exu_cmd_o.lsu_cmd = SCR1_LSU_CMD_SW;
                            default : rvi_illegal = 1'b1;
                        endcase // funct3
`ifdef SCR1_RVE_EXT
                        if (instr[19] | instr[24])  rve_illegal = 1'b1;
`endif  // SCR1_RVE_EXT
                    end // SCR1_OPCODE_STORE

                    SCR1_OPCODE_OP              : begin
                        idu2exu_use_rs1_o         = 1'b1;
                        idu2exu_use_rs2_o         = 1'b1;
`ifndef SCR1_NO_EXE_STAGE
                        idu2exu_use_rd_o          = 1'b1;
`endif // SCR1_NO_EXE_STAGE
                        idu2exu_cmd_o.ialu_op     = SCR1_IALU_OP_REG_REG;
                        idu2exu_cmd_o.rd_wb_sel   = SCR1_RD_WB_IALU;
                        case (funct7)
                            7'b0000000 : begin
                                case (funct3)
                                    3'b000  : idu2exu_cmd_o.ialu_cmd  = SCR1_IALU_CMD_ADD;
                                    3'b001  : idu2exu_cmd_o.ialu_cmd  = SCR1_IALU_CMD_SLL;
                                    3'b010  : idu2exu_cmd_o.ialu_cmd  = SCR1_IALU_CMD_SUB_LT;
                                    3'b011  : idu2exu_cmd_o.ialu_cmd  = SCR1_IALU_CMD_SUB_LTU;
                                    3'b100  : idu2exu_cmd_o.ialu_cmd  = SCR1_IALU_CMD_XOR;
                                    3'b101  : idu2exu_cmd_o.ialu_cmd  = SCR1_IALU_CMD_SRL;
                                    3'b110  : idu2exu_cmd_o.ialu_cmd  = SCR1_IALU_CMD_OR;
                                    3'b111  : idu2exu_cmd_o.ialu_cmd  = SCR1_IALU_CMD_AND;
                                endcase // funct3
                            end // 7'b0000000

                            7'b0100000 : begin
                                case (funct3)
                                    3'b000  : idu2exu_cmd_o.ialu_cmd  = SCR1_IALU_CMD_SUB;
                                    3'b101  : idu2exu_cmd_o.ialu_cmd  = SCR1_IALU_CMD_SRA;
                                    default : rvi_illegal = 1'b1;
                                endcase // funct3
                            end // 7'b0100000
`ifdef SCR1_RVM_EXT
                            7'b0000001 : begin
                                case (funct3)
                                    3'b000  : idu2exu_cmd_o.ialu_cmd  = SCR1_IALU_CMD_MUL;
                                    3'b001  : idu2exu_cmd_o.ialu_cmd  = SCR1_IALU_CMD_MULH;
                                    3'b010  : idu2exu_cmd_o.ialu_cmd  = SCR1_IALU_CMD_MULHSU;
                                    3'b011  : idu2exu_cmd_o.ialu_cmd  = SCR1_IALU_CMD_MULHU;
                                    3'b100  : idu2exu_cmd_o.ialu_cmd  = SCR1_IALU_CMD_DIV;
                                    3'b101  : idu2exu_cmd_o.ialu_cmd  = SCR1_IALU_CMD_DIVU;
                                    3'b110  : idu2exu_cmd_o.ialu_cmd  = SCR1_IALU_CMD_REM;
                                    3'b111  : idu2exu_cmd_o.ialu_cmd  = SCR1_IALU_CMD_REMU;
                                endcase // funct3
                            end // 7'b0000001
`endif  // SCR1_RVM_EXT
                            default : rvi_illegal = 1'b1;
                        endcase // funct7
`ifdef SCR1_RVE_EXT
                        if (instr[11] | instr[19] | instr[24])  rve_illegal = 1'b1;
`endif  // SCR1_RVE_EXT
                    end // SCR1_OPCODE_OP

                    SCR1_OPCODE_OP_IMM          : begin
                        idu2exu_use_rs1_o         = 1'b1;
`ifndef SCR1_NO_EXE_STAGE
                        idu2exu_use_rd_o          = 1'b1;
                        idu2exu_use_imm_o         = 1'b1;
`endif // SCR1_NO_EXE_STAGE
                        idu2exu_cmd_o.imm         = {{21{instr[31]}}, instr[30:20]};
                        idu2exu_cmd_o.ialu_op     = SCR1_IALU_OP_REG_IMM;
                        idu2exu_cmd_o.rd_wb_sel   = SCR1_RD_WB_IALU;
                        case (funct3)
                            3'b000  : idu2exu_cmd_o.ialu_cmd  = SCR1_IALU_CMD_ADD;        // ADDI
                            3'b010  : idu2exu_cmd_o.ialu_cmd  = SCR1_IALU_CMD_SUB_LT;     // SLTI
                            3'b011  : idu2exu_cmd_o.ialu_cmd  = SCR1_IALU_CMD_SUB_LTU;    // SLTIU
                            3'b100  : idu2exu_cmd_o.ialu_cmd  = SCR1_IALU_CMD_XOR;        // XORI
                            3'b110  : idu2exu_cmd_o.ialu_cmd  = SCR1_IALU_CMD_OR;         // ORI
                            3'b111  : idu2exu_cmd_o.ialu_cmd  = SCR1_IALU_CMD_AND;        // ANDI
                            3'b001  : begin
                                case (funct7)
                                    7'b0000000  : begin
                                        // SLLI
                                        idu2exu_cmd_o.imm         = `SCR1_XLEN'(shamt);   // zero-extend
                                        idu2exu_cmd_o.ialu_cmd    = SCR1_IALU_CMD_SLL;
                                    end
                                    default     : rvi_illegal   = 1'b1;
                                endcase // funct7
                            end
                            3'b101  : begin
                                case (funct7)
                                    7'b0000000  : begin
                                        // SRLI
                                        idu2exu_cmd_o.imm         = `SCR1_XLEN'(shamt);   // zero-extend
                                        idu2exu_cmd_o.ialu_cmd    = SCR1_IALU_CMD_SRL;
                                    end
                                    7'b0100000  : begin
                                        // SRAI
                                        idu2exu_cmd_o.imm         = `SCR1_XLEN'(shamt);   // zero-extend
                                        idu2exu_cmd_o.ialu_cmd    = SCR1_IALU_CMD_SRA;
                                    end
                                    default     : rvi_illegal   = 1'b1;
                                endcase // funct7
                            end
                        endcase // funct3
`ifdef SCR1_RVE_EXT
                        if (instr[11] | instr[19])  rve_illegal = 1'b1;
`endif  // SCR1_RVE_EXT
                    end // SCR1_OPCODE_OP_IMM

                    SCR1_OPCODE_MISC_MEM    : begin
                        case (funct3)
                            3'b000  : begin
                                if (~|{instr[31:28], instr[19:15], instr[11:7]}) begin
                                    // FENCE = NOP
                                end
                                else rvi_illegal = 1'b1;
                            end
                            3'b001  : begin
                                if (~|{instr[31:15], instr[11:7]}) begin
                                    // FENCE.I
                                    idu2exu_cmd_o.fencei_req    = 1'b1;
                                end
                                else rvi_illegal = 1'b1;
                            end
                            default : rvi_illegal = 1'b1;
                        endcase // funct3
                    end // SCR1_OPCODE_MISC_MEM

                    SCR1_OPCODE_BRANCH          : begin
                        idu2exu_use_rs1_o         = 1'b1;
                        idu2exu_use_rs2_o         = 1'b1;
`ifndef SCR1_NO_EXE_STAGE
                        idu2exu_use_imm_o         = 1'b1;
`endif // SCR1_NO_EXE_STAGE
                        idu2exu_cmd_o.imm         = {{20{instr[31]}}, instr[7], instr[30:25], instr[11:8], 1'b0};
                        idu2exu_cmd_o.branch_req  = 1'b1;
                        idu2exu_cmd_o.sum2_op     = SCR1_SUM2_OP_PC_IMM;
                        idu2exu_cmd_o.ialu_op     = SCR1_IALU_OP_REG_REG;
                        case (funct3)
                            3'b000  : idu2exu_cmd_o.ialu_cmd = SCR1_IALU_CMD_SUB_EQ;
                            3'b001  : idu2exu_cmd_o.ialu_cmd = SCR1_IALU_CMD_SUB_NE;
                            3'b100  : idu2exu_cmd_o.ialu_cmd = SCR1_IALU_CMD_SUB_LT;
                            3'b101  : idu2exu_cmd_o.ialu_cmd = SCR1_IALU_CMD_SUB_GE;
                            3'b110  : idu2exu_cmd_o.ialu_cmd = SCR1_IALU_CMD_SUB_LTU;
                            3'b111  : idu2exu_cmd_o.ialu_cmd = SCR1_IALU_CMD_SUB_GEU;
                            default : rvi_illegal = 1'b1;
                        endcase // funct3
`ifdef SCR1_RVE_EXT
                        if (instr[19] | instr[24])  rve_illegal = 1'b1;
`endif  // SCR1_RVE_EXT
                    end // SCR1_OPCODE_BRANCH

                    SCR1_OPCODE_JALR        : begin
                        idu2exu_use_rs1_o     = 1'b1;
`ifndef SCR1_NO_EXE_STAGE
                        idu2exu_use_rd_o      = 1'b1;
                        idu2exu_use_imm_o     = 1'b1;
`endif // SCR1_NO_EXE_STAGE
                        case (funct3)
                            3'b000  : begin
                                // JALR
                                idu2exu_cmd_o.sum2_op   = SCR1_SUM2_OP_REG_IMM;
                                idu2exu_cmd_o.rd_wb_sel = SCR1_RD_WB_INC_PC;
                                idu2exu_cmd_o.jump_req  = 1'b1;
                                idu2exu_cmd_o.imm       = {{21{instr[31]}}, instr[30:20]};
                            end
                            default : rvi_illegal = 1'b1;
                        endcase
`ifdef SCR1_RVE_EXT
                        if (instr[11] | instr[19])  rve_illegal = 1'b1;
`endif  // SCR1_RVE_EXT
                    end // SCR1_OPCODE_JALR

                    SCR1_OPCODE_SYSTEM      : begin
`ifndef SCR1_NO_EXE_STAGE
                        idu2exu_use_rd_o      = 1'b1;
                        idu2exu_use_imm_o     = 1'b1;
`endif // SCR1_NO_EXE_STAGE
                        idu2exu_cmd_o.imm     = `SCR1_XLEN'({funct3, instr[31:20]});      // {funct3, CSR address}
                        case (funct3)
                            3'b000  : begin
`ifndef SCR1_NO_EXE_STAGE
                                idu2exu_use_rd_o    = 1'b0;
                                idu2exu_use_imm_o   = 1'b0;
`endif // SCR1_NO_EXE_STAGE
                                case ({instr[19:15], instr[11:7]})
                                    10'd0 : begin
                                        case (funct12)
                                            12'h000 : begin
                                                // ECALL
                                                idu2exu_cmd_o.exc_req     = 1'b1;
                                                idu2exu_cmd_o.exc_code    = SCR1_EXC_CODE_ECALL_M;
                                            end
                                            12'h001 : begin
                                                // EBREAK
                                                idu2exu_cmd_o.exc_req     = 1'b1;
                                                idu2exu_cmd_o.exc_code    = SCR1_EXC_CODE_BREAKPOINT;
                                            end
                                            12'h302 : begin
                                                // MRET
                                                idu2exu_cmd_o.mret_req    = 1'b1;
                                            end
                                            12'h105 : begin
                                                // WFI
                                                idu2exu_cmd_o.wfi_req     = 1'b1;
                                            end
                                            default : rvi_illegal = 1'b1;
                                        endcase // funct12
                                    end
                                    default : rvi_illegal = 1'b1;
                                endcase // {instr[19:15], instr[11:7]}
                            end
                            3'b001  : begin
                                // CSRRW
                                idu2exu_use_rs1_o             = 1'b1;
                                idu2exu_cmd_o.rd_wb_sel       = SCR1_RD_WB_CSR;
                                idu2exu_cmd_o.csr_cmd         = SCR1_CSR_CMD_WRITE;
                                idu2exu_cmd_o.csr_op          = SCR1_CSR_OP_REG;
`ifdef SCR1_RVE_EXT
                                if (instr[11] | instr[19])  rve_illegal = 1'b1;
`endif  // SCR1_RVE_EXT
                            end
                            3'b010  : begin
                                // CSRRS
                                idu2exu_use_rs1_o             = 1'b1;
                                idu2exu_cmd_o.rd_wb_sel       = SCR1_RD_WB_CSR;
                                idu2exu_cmd_o.csr_cmd         = SCR1_CSR_CMD_SET;
                                idu2exu_cmd_o.csr_op          = SCR1_CSR_OP_REG;
`ifdef SCR1_RVE_EXT
                                if (instr[11] | instr[19])  rve_illegal = 1'b1;
`endif  // SCR1_RVE_EXT
                            end
                            3'b011  : begin
                                // CSRRC
                                idu2exu_use_rs1_o             = 1'b1;
                                idu2exu_cmd_o.rd_wb_sel       = SCR1_RD_WB_CSR;
                                idu2exu_cmd_o.csr_cmd         = SCR1_CSR_CMD_CLEAR;
                                idu2exu_cmd_o.csr_op          = SCR1_CSR_OP_REG;
`ifdef SCR1_RVE_EXT
                                if (instr[11] | instr[19])  rve_illegal = 1'b1;
`endif  // SCR1_RVE_EXT
                            end
                            3'b101  : begin
                                // CSRRWI
                                idu2exu_use_rs1_o             = 1'b1;             // zimm
                                idu2exu_cmd_o.rd_wb_sel       = SCR1_RD_WB_CSR;
                                idu2exu_cmd_o.csr_cmd         = SCR1_CSR_CMD_WRITE;
                                idu2exu_cmd_o.csr_op          = SCR1_CSR_OP_IMM;
`ifdef SCR1_RVE_EXT
                                if (instr[11])              rve_illegal = 1'b1;
`endif  // SCR1_RVE_EXT
                            end
                            3'b110  : begin
                                // CSRRSI
                                idu2exu_use_rs1_o             = 1'b1;             // zimm
                                idu2exu_cmd_o.rd_wb_sel       = SCR1_RD_WB_CSR;
                                idu2exu_cmd_o.csr_cmd         = SCR1_CSR_CMD_SET;
                                idu2exu_cmd_o.csr_op          = SCR1_CSR_OP_IMM;
`ifdef SCR1_RVE_EXT
                                if (instr[11])              rve_illegal = 1'b1;
`endif  // SCR1_RVE_EXT
                            end
                            3'b111  : begin
                                // CSRRCI
                                idu2exu_use_rs1_o             = 1'b1;             // zimm
                                idu2exu_cmd_o.rd_wb_sel       = SCR1_RD_WB_CSR;
                                idu2exu_cmd_o.csr_cmd         = SCR1_CSR_CMD_CLEAR;
                                idu2exu_cmd_o.csr_op          = SCR1_CSR_OP_IMM;
`ifdef SCR1_RVE_EXT
                                if (instr[11])              rve_illegal = 1'b1;
`endif  // SCR1_RVE_EXT
                            end
                            default : rvi_illegal = 1'b1;
                        endcase // funct3
                    end // SCR1_OPCODE_SYSTEM

                    default : begin
                        rvi_illegal = 1'b1;
                    end
                endcase // rvi_opcode
            end // SCR1_INSTR_RVI

`ifdef SCR1_RVC_EXT

            // Quadrant 0
            SCR1_INSTR_RVC0 : begin
                idu2exu_cmd_o.instr_rvc   = 1'b1;
                idu2exu_use_rs1_o         = 1'b1;
`ifndef SCR1_NO_EXE_STAGE
                idu2exu_use_imm_o         = 1'b1;
`endif // SCR1_NO_EXE_STAGE
                case (funct3)
                    3'b000  : begin
                        if (~|instr[12:5])      rvc_illegal = 1'b1;
                        // C.ADDI4SPN
`ifndef SCR1_NO_EXE_STAGE
                        idu2exu_use_rd_o          = 1'b1;
`endif // SCR1_NO_EXE_STAGE
                        idu2exu_cmd_o.ialu_cmd    = SCR1_IALU_CMD_ADD;
                        idu2exu_cmd_o.ialu_op     = SCR1_IALU_OP_REG_IMM;
                        idu2exu_cmd_o.rd_wb_sel   = SCR1_RD_WB_IALU;
                        idu2exu_cmd_o.rs1_addr    = SCR1_MPRF_SP_ADDR;
                        idu2exu_cmd_o.rd_addr     = {2'b01, instr[4:2]};
                        idu2exu_cmd_o.imm         = {22'd0, instr[10:7], instr[12:11], instr[5], instr[6], 2'b00};
                    end
                    3'b010  : begin
                        // C.LW
`ifndef SCR1_NO_EXE_STAGE
                        idu2exu_use_rd_o          = 1'b1;
`endif // SCR1_NO_EXE_STAGE
                        idu2exu_cmd_o.sum2_op     = SCR1_SUM2_OP_REG_IMM;
                        idu2exu_cmd_o.lsu_cmd     = SCR1_LSU_CMD_LW;
                        idu2exu_cmd_o.rd_wb_sel   = SCR1_RD_WB_LSU;
                        idu2exu_cmd_o.rs1_addr    = {2'b01, instr[9:7]};
                        idu2exu_cmd_o.rd_addr     = {2'b01, instr[4:2]};
                        idu2exu_cmd_o.imm         = {25'd0, instr[5], instr[12:10], instr[6], 2'b00};
                    end
                    3'b110  : begin
                        // C.SW
                        idu2exu_use_rs2_o         = 1'b1;
                        idu2exu_cmd_o.sum2_op     = SCR1_SUM2_OP_REG_IMM;
                        idu2exu_cmd_o.lsu_cmd     = SCR1_LSU_CMD_SW;
                        idu2exu_cmd_o.rs1_addr    = {2'b01, instr[9:7]};
                        idu2exu_cmd_o.rs2_addr    = {2'b01, instr[4:2]};
                        idu2exu_cmd_o.imm         = {25'd0, instr[5], instr[12:10], instr[6], 2'b00};
                    end
                    default : begin
                        rvc_illegal = 1'b1;
                    end
                endcase // funct3
            end // Quadrant 0

            // Quadrant 1
            SCR1_INSTR_RVC1 : begin
                idu2exu_cmd_o.instr_rvc   = 1'b1;
`ifndef SCR1_NO_EXE_STAGE
                idu2exu_use_rd_o          = 1'b1;
                idu2exu_use_imm_o         = 1'b1;
`endif // SCR1_NO_EXE_STAGE
                case (funct3)
                    3'b000  : begin
                        // C.ADDI / C.NOP
                        idu2exu_use_rs1_o         = 1'b1;
                        idu2exu_cmd_o.ialu_cmd    = SCR1_IALU_CMD_ADD;
                        idu2exu_cmd_o.ialu_op     = SCR1_IALU_OP_REG_IMM;
                        idu2exu_cmd_o.rd_wb_sel   = SCR1_RD_WB_IALU;
                        idu2exu_cmd_o.rs1_addr    = instr[11:7];
                        idu2exu_cmd_o.rd_addr     = instr[11:7];
                        idu2exu_cmd_o.imm         = {{27{instr[12]}}, instr[6:2]};
`ifdef SCR1_RVE_EXT
                        if (instr[11])          rve_illegal = 1'b1;
`endif  // SCR1_RVE_EXT
                    end
                    3'b001  : begin
                        // C.JAL
                        idu2exu_cmd_o.sum2_op     = SCR1_SUM2_OP_PC_IMM;
                        idu2exu_cmd_o.rd_wb_sel   = SCR1_RD_WB_INC_PC;
                        idu2exu_cmd_o.jump_req    = 1'b1;
                        idu2exu_cmd_o.rd_addr     = SCR1_MPRF_RA_ADDR;
                        idu2exu_cmd_o.imm         = {{21{instr[12]}}, instr[8], instr[10:9], instr[6], instr[7], instr[2], instr[11], instr[5:3], 1'b0};
                    end
                    3'b010  : begin
                        // C.LI
                        idu2exu_cmd_o.rd_wb_sel   = SCR1_RD_WB_IMM;
                        idu2exu_cmd_o.rd_addr     = instr[11:7];
                        idu2exu_cmd_o.imm         = {{27{instr[12]}}, instr[6:2]};
`ifdef SCR1_RVE_EXT
                        if (instr[11])          rve_illegal = 1'b1;
`endif  // SCR1_RVE_EXT
                    end
                    3'b011  : begin
                        if (~|{instr[12], instr[6:2]}) rvc_illegal = 1'b1;
                        if (instr[11:7] == SCR1_MPRF_SP_ADDR) begin
                            // C.ADDI16SP
                            idu2exu_use_rs1_o         = 1'b1;
                            idu2exu_cmd_o.ialu_cmd    = SCR1_IALU_CMD_ADD;
                            idu2exu_cmd_o.ialu_op     = SCR1_IALU_OP_REG_IMM;
                            idu2exu_cmd_o.rd_wb_sel   = SCR1_RD_WB_IALU;
                            idu2exu_cmd_o.rs1_addr    = SCR1_MPRF_SP_ADDR;
                            idu2exu_cmd_o.rd_addr     = SCR1_MPRF_SP_ADDR;
                            idu2exu_cmd_o.imm         = {{23{instr[12]}}, instr[4:3], instr[5], instr[2], instr[6], 4'd0};
                        end else begin
                            // C.LUI
                            idu2exu_cmd_o.rd_wb_sel   = SCR1_RD_WB_IMM;
                            idu2exu_cmd_o.rd_addr     = instr[11:7];
                            idu2exu_cmd_o.imm         = {{15{instr[12]}}, instr[6:2], 12'd0};
`ifdef SCR1_RVE_EXT
                            if (instr[11])          rve_illegal = 1'b1;
`endif  // SCR1_RVE_EXT
                        end
                    end
                    3'b100  : begin
                        idu2exu_cmd_o.rs1_addr    = {2'b01, instr[9:7]};
                        idu2exu_cmd_o.rd_addr     = {2'b01, instr[9:7]};
                        idu2exu_cmd_o.rs2_addr    = {2'b01, instr[4:2]};
                        idu2exu_use_rs1_o         = 1'b1;
`ifndef SCR1_NO_EXE_STAGE
                        idu2exu_use_rd_o          = 1'b1;
`endif // SCR1_NO_EXE_STAGE
                        case (instr[11:10])
                            2'b00   : begin
                                if (instr[12])          rvc_illegal = 1'b1;
                                // C.SRLI
`ifndef SCR1_NO_EXE_STAGE
                                idu2exu_use_imm_o         = 1'b1;
`endif // SCR1_NO_EXE_STAGE
                                idu2exu_cmd_o.imm         = {27'd0, instr[6:2]};
                                idu2exu_cmd_o.ialu_cmd    = SCR1_IALU_CMD_SRL;
                                idu2exu_cmd_o.ialu_op     = SCR1_IALU_OP_REG_IMM;
                                idu2exu_cmd_o.rd_wb_sel   = SCR1_RD_WB_IALU;
                            end
                            2'b01   : begin
                                if (instr[12])          rvc_illegal = 1'b1;
                                // C.SRAI
`ifndef SCR1_NO_EXE_STAGE
                                idu2exu_use_imm_o         = 1'b1;
`endif // SCR1_NO_EXE_STAGE
                                idu2exu_cmd_o.imm         = {27'd0, instr[6:2]};
                                idu2exu_cmd_o.ialu_cmd    = SCR1_IALU_CMD_SRA;
                                idu2exu_cmd_o.ialu_op     = SCR1_IALU_OP_REG_IMM;
                                idu2exu_cmd_o.rd_wb_sel   = SCR1_RD_WB_IALU;
                            end
                            2'b10   : begin
                                // C.ANDI
`ifndef SCR1_NO_EXE_STAGE
                                idu2exu_use_imm_o         = 1'b1;
`endif // SCR1_NO_EXE_STAGE
                                idu2exu_cmd_o.ialu_cmd    = SCR1_IALU_CMD_AND;
                                idu2exu_cmd_o.ialu_op     = SCR1_IALU_OP_REG_IMM;
                                idu2exu_cmd_o.rd_wb_sel   = SCR1_RD_WB_IALU;
                                idu2exu_cmd_o.imm         = {{27{instr[12]}}, instr[6:2]};
                            end
                            2'b11   : begin
                                idu2exu_use_rs2_o         = 1'b1;
                                case ({instr[12], instr[6:5]})
                                    3'b000  : begin
                                        // C.SUB
                                        idu2exu_cmd_o.ialu_cmd    = SCR1_IALU_CMD_SUB;
                                        idu2exu_cmd_o.ialu_op     = SCR1_IALU_OP_REG_REG;
                                        idu2exu_cmd_o.rd_wb_sel   = SCR1_RD_WB_IALU;
                                    end
                                    3'b001  : begin
                                        // C.XOR
                                        idu2exu_cmd_o.ialu_cmd    = SCR1_IALU_CMD_XOR;
                                        idu2exu_cmd_o.ialu_op     = SCR1_IALU_OP_REG_REG;
                                        idu2exu_cmd_o.rd_wb_sel   = SCR1_RD_WB_IALU;
                                    end
                                    3'b010  : begin
                                        // C.OR
                                        idu2exu_cmd_o.ialu_cmd    = SCR1_IALU_CMD_OR;
                                        idu2exu_cmd_o.ialu_op     = SCR1_IALU_OP_REG_REG;
                                        idu2exu_cmd_o.rd_wb_sel   = SCR1_RD_WB_IALU;
                                    end
                                    3'b011  : begin
                                        // C.AND
                                        idu2exu_cmd_o.ialu_cmd    = SCR1_IALU_CMD_AND;
                                        idu2exu_cmd_o.ialu_op     = SCR1_IALU_OP_REG_REG;
                                        idu2exu_cmd_o.rd_wb_sel   = SCR1_RD_WB_IALU;
                                    end
                                    default : begin
                                        rvc_illegal = 1'b1;
                                    end
                                endcase // {instr[12], instr[6:5]}
                            end
                        endcase // instr[11:10]
                    end // funct3 == 3'b100
                    3'b101  : begin
                        // C.J
`ifndef SCR1_NO_EXE_STAGE
                        idu2exu_use_imm_o         = 1'b1;
`endif // SCR1_NO_EXE_STAGE
                        idu2exu_cmd_o.sum2_op     = SCR1_SUM2_OP_PC_IMM;
                        idu2exu_cmd_o.jump_req    = 1'b1;
                        idu2exu_cmd_o.imm         = {{21{instr[12]}}, instr[8], instr[10:9], instr[6], instr[7], instr[2], instr[11], instr[5:3], 1'b0};
                    end
                    3'b110  : begin
                        // C.BEQZ
                        idu2exu_use_rs1_o         = 1'b1;
                        idu2exu_use_rs2_o         = 1'b1;
`ifndef SCR1_NO_EXE_STAGE
                        idu2exu_use_imm_o         = 1'b1;
`endif // SCR1_NO_EXE_STAGE
                        idu2exu_cmd_o.ialu_cmd    = SCR1_IALU_CMD_SUB_EQ;
                        idu2exu_cmd_o.ialu_op     = SCR1_IALU_OP_REG_REG;
                        idu2exu_cmd_o.sum2_op     = SCR1_SUM2_OP_PC_IMM;
                        idu2exu_cmd_o.branch_req  = 1'b1;
                        idu2exu_cmd_o.rs1_addr    = {2'b01, instr[9:7]};
                        idu2exu_cmd_o.rs2_addr    = SCR1_MPRF_ZERO_ADDR;
                        idu2exu_cmd_o.imm         = {{24{instr[12]}}, instr[6:5], instr[2], instr[11:10], instr[4:3], 1'b0};
                    end
                    3'b111  : begin
                        // C.BNEZ
                        idu2exu_use_rs1_o         = 1'b1;
                        idu2exu_use_rs2_o         = 1'b1;
`ifndef SCR1_NO_EXE_STAGE
                        idu2exu_use_imm_o         = 1'b1;
`endif // SCR1_NO_EXE_STAGE
                        idu2exu_cmd_o.ialu_cmd    = SCR1_IALU_CMD_SUB_NE;
                        idu2exu_cmd_o.ialu_op     = SCR1_IALU_OP_REG_REG;
                        idu2exu_cmd_o.sum2_op     = SCR1_SUM2_OP_PC_IMM;
                        idu2exu_cmd_o.branch_req  = 1'b1;
                        idu2exu_cmd_o.rs1_addr    = {2'b01, instr[9:7]};
                        idu2exu_cmd_o.rs2_addr    = SCR1_MPRF_ZERO_ADDR;
                        idu2exu_cmd_o.imm         = {{24{instr[12]}}, instr[6:5], instr[2], instr[11:10], instr[4:3], 1'b0};
                    end
                endcase // funct3
            end // Quadrant 1

            // Quadrant 2
            SCR1_INSTR_RVC2 : begin
                idu2exu_cmd_o.instr_rvc   = 1'b1;
                idu2exu_use_rs1_o         = 1'b1;
                case (funct3)
                    3'b000  : begin
                        if (instr[12])          rvc_illegal = 1'b1;
                        // C.SLLI
`ifndef SCR1_NO_EXE_STAGE
                        idu2exu_use_rd_o          = 1'b1;
                        idu2exu_use_imm_o         = 1'b1;
`endif // SCR1_NO_EXE_STAGE
                        idu2exu_cmd_o.rs1_addr    = instr[11:7];
                        idu2exu_cmd_o.rd_addr     = instr[11:7];
                        idu2exu_cmd_o.imm         = {27'd0, instr[6:2]};
                        idu2exu_cmd_o.ialu_cmd    = SCR1_IALU_CMD_SLL;
                        idu2exu_cmd_o.ialu_op     = SCR1_IALU_OP_REG_IMM;
                        idu2exu_cmd_o.rd_wb_sel   = SCR1_RD_WB_IALU;
`ifdef SCR1_RVE_EXT
                        if (instr[11])          rve_illegal = 1'b1;
`endif  // SCR1_RVE_EXT
                    end
                    3'b010  : begin
                        if (~|instr[11:7])      rvc_illegal = 1'b1;
                        // C.LWSP
`ifndef SCR1_NO_EXE_STAGE
                        idu2exu_use_rd_o          = 1'b1;
                        idu2exu_use_imm_o         = 1'b1;
`endif // SCR1_NO_EXE_STAGE
                        idu2exu_cmd_o.sum2_op     = SCR1_SUM2_OP_REG_IMM;
                        idu2exu_cmd_o.lsu_cmd     = SCR1_LSU_CMD_LW;
                        idu2exu_cmd_o.rd_wb_sel   = SCR1_RD_WB_LSU;
                        idu2exu_cmd_o.rs1_addr    = SCR1_MPRF_SP_ADDR;
                        idu2exu_cmd_o.rd_addr     = instr[11:7];
                        idu2exu_cmd_o.imm         = {24'd0, instr[3:2], instr[12], instr[6:4], 2'b00};
`ifdef SCR1_RVE_EXT
                        if (instr[11])          rve_illegal = 1'b1;
`endif  // SCR1_RVE_EXT
                    end
                    3'b100  : begin
                        if (~instr[12]) begin
                            if (|instr[6:2]) begin
                                // C.MV
                                idu2exu_use_rs2_o         = 1'b1;
`ifndef SCR1_NO_EXE_STAGE
                                idu2exu_use_rd_o          = 1'b1;
`endif // SCR1_NO_EXE_STAGE
                                idu2exu_cmd_o.ialu_cmd    = SCR1_IALU_CMD_ADD;
                                idu2exu_cmd_o.ialu_op     = SCR1_IALU_OP_REG_REG;
                                idu2exu_cmd_o.rd_wb_sel   = SCR1_RD_WB_IALU;
                                idu2exu_cmd_o.rs1_addr    = SCR1_MPRF_ZERO_ADDR;
                                idu2exu_cmd_o.rs2_addr    = instr[6:2];
                                idu2exu_cmd_o.rd_addr     = instr[11:7];
`ifdef SCR1_RVE_EXT
                                if (instr[11]|instr[6]) rve_illegal = 1'b1;
`endif  // SCR1_RVE_EXT
                            end else begin
                                if (~|instr[11:7])      rvc_illegal = 1'b1;
                                // C.JR
`ifndef SCR1_NO_EXE_STAGE
                                idu2exu_use_imm_o         = 1'b1;
`endif // SCR1_NO_EXE_STAGE
                                idu2exu_cmd_o.sum2_op     = SCR1_SUM2_OP_REG_IMM;
                                idu2exu_cmd_o.jump_req    = 1'b1;
                                idu2exu_cmd_o.rs1_addr    = instr[11:7];
                                idu2exu_cmd_o.imm         = 0;
`ifdef SCR1_RVE_EXT
                                if (instr[11])          rve_illegal = 1'b1;
`endif  // SCR1_RVE_EXT
                            end
                        end else begin  // instr[12] == 1
                            if (~|instr[11:2]) begin
                                // C.EBREAK
                                idu2exu_cmd_o.exc_req     = 1'b1;
                                idu2exu_cmd_o.exc_code    = SCR1_EXC_CODE_BREAKPOINT;
                            end else if (~|instr[6:2]) begin
                                // C.JALR
                                idu2exu_use_rs1_o         = 1'b1;
`ifndef SCR1_NO_EXE_STAGE
                                idu2exu_use_rd_o          = 1'b1;
                                idu2exu_use_imm_o         = 1'b1;
`endif // SCR1_NO_EXE_STAGE
                                idu2exu_cmd_o.sum2_op     = SCR1_SUM2_OP_REG_IMM;
                                idu2exu_cmd_o.rd_wb_sel   = SCR1_RD_WB_INC_PC;
                                idu2exu_cmd_o.jump_req    = 1'b1;
                                idu2exu_cmd_o.rs1_addr    = instr[11:7];
                                idu2exu_cmd_o.rd_addr     = SCR1_MPRF_RA_ADDR;
                                idu2exu_cmd_o.imm         = 0;
`ifdef SCR1_RVE_EXT
                                if (instr[11])          rve_illegal = 1'b1;
`endif  // SCR1_RVE_EXT
                            end else begin
                                // C.ADD
                                idu2exu_use_rs1_o         = 1'b1;
                                idu2exu_use_rs2_o         = 1'b1;
`ifndef SCR1_NO_EXE_STAGE
                                idu2exu_use_rd_o          = 1'b1;
`endif // SCR1_NO_EXE_STAGE
                                idu2exu_cmd_o.ialu_cmd    = SCR1_IALU_CMD_ADD;
                                idu2exu_cmd_o.ialu_op     = SCR1_IALU_OP_REG_REG;
                                idu2exu_cmd_o.rd_wb_sel   = SCR1_RD_WB_IALU;
                                idu2exu_cmd_o.rs1_addr    = instr[11:7];
                                idu2exu_cmd_o.rs2_addr    = instr[6:2];
                                idu2exu_cmd_o.rd_addr     = instr[11:7];
`ifdef SCR1_RVE_EXT
                                if (instr[11]|instr[6]) rve_illegal = 1'b1;
`endif  // SCR1_RVE_EXT
                            end
                        end // instr[12] == 1
                    end
                    3'b110  : begin
                        // C.SWSP
                        idu2exu_use_rs1_o         = 1'b1;
                        idu2exu_use_rs2_o         = 1'b1;
`ifndef SCR1_NO_EXE_STAGE
                        idu2exu_use_imm_o         = 1'b1;
`endif // SCR1_NO_EXE_STAGE
                        idu2exu_cmd_o.sum2_op     = SCR1_SUM2_OP_REG_IMM;
                        idu2exu_cmd_o.lsu_cmd     = SCR1_LSU_CMD_SW;
                        idu2exu_cmd_o.rs1_addr    = SCR1_MPRF_SP_ADDR;
                        idu2exu_cmd_o.rs2_addr    = instr[6:2];
                        idu2exu_cmd_o.imm         = {24'd0, instr[8:7], instr[12:9], 2'b00};
`ifdef SCR1_RVE_EXT
                        if (instr[6])           rve_illegal = 1'b1;
`endif  // SCR1_RVE_EXT
                    end
                    default : begin
                        rvc_illegal = 1'b1;
                    end
                endcase // funct3
            end // Quadrant 2

            default         : begin
`ifdef SCR1_XPROP_EN
                rvi_illegal             = 1'b1;
`endif // SCR1_XPROP_EN
            end
`else   // SCR1_RVC_EXT
            default         : begin
                idu2exu_cmd_o.instr_rvc = 1'b1;
                rvi_illegal             = 1'b1;
            end
`endif  // SCR1_RVC_EXT
        endcase // instr_type
    end // no imem fault

    // At this point the instruction is fully decoded
    // given that no imem fault has happened

    // Check illegal instruction
    if (
    rvi_illegal
`ifdef SCR1_RVC_EXT
    | rvc_illegal
`endif
`ifdef SCR1_RVE_EXT
    | rve_illegal
`endif
    ) begin
        idu2exu_cmd_o.ialu_cmd        = SCR1_IALU_CMD_NONE;
        idu2exu_cmd_o.lsu_cmd         = SCR1_LSU_CMD_NONE;
        idu2exu_cmd_o.csr_cmd         = SCR1_CSR_CMD_NONE;
        idu2exu_cmd_o.rd_wb_sel       = SCR1_RD_WB_NONE;
        idu2exu_cmd_o.jump_req        = 1'b0;
        idu2exu_cmd_o.branch_req      = 1'b0;
        idu2exu_cmd_o.mret_req        = 1'b0;
        idu2exu_cmd_o.fencei_req      = 1'b0;
        idu2exu_cmd_o.wfi_req         = 1'b0;

        idu2exu_use_rs1_o             = 1'b0;
        idu2exu_use_rs2_o             = 1'b0;
`ifndef SCR1_NO_EXE_STAGE
        idu2exu_use_rd_o              = 1'b0;
`endif // SCR1_NO_EXE_STAGE

`ifndef SCR1_MTVAL_ILLEGAL_INSTR_EN

`ifndef SCR1_NO_EXE_STAGE
        idu2exu_use_imm_o = 1'b0;
`endif // SCR1_NO_EXE_STAGE

`else // SCR1_MTVAL_ILLEGAL_INSTR_EN

`ifndef SCR1_NO_EXE_STAGE
        idu2exu_use_imm_o = 1'b1;
`endif // SCR1_NO_EXE_STAGE

        idu2exu_cmd_o.imm = instr;

`endif // SCR1_MTVAL_ILLEGAL_INSTR_EN

        idu2exu_cmd_o.exc_req         = 1'b1;
        idu2exu_cmd_o.exc_code        = SCR1_EXC_CODE_ILLEGAL_INSTR;
    end

`ifdef SCR1_EARLY_BRANCH
    // ---- Counting new PC earlier ----

    if (idu_accept
    && ~ifu2idu_imem_err_i
    && ~idu2exu_cmd_o.exc_req
    && idu2exu_cmd_o.branch_req) begin

    branch_target_early = ifu2idu_pc_i + idu2exu_cmd_o.imm;

    case (idu2exu_cmd_o.ialu_cmd)
        SCR1_IALU_CMD_SUB_EQ:
            branch_taken_early =
                (mprf2idu_rs1_data_i == mprf2idu_rs2_data_i);

        SCR1_IALU_CMD_SUB_NE:
            branch_taken_early =
                (mprf2idu_rs1_data_i != mprf2idu_rs2_data_i);

        SCR1_IALU_CMD_SUB_LT:
            branch_taken_early =
                ($signed(mprf2idu_rs1_data_i) <
                 $signed(mprf2idu_rs2_data_i));

        SCR1_IALU_CMD_SUB_GE:
            branch_taken_early =
                ($signed(mprf2idu_rs1_data_i) >=
                 $signed(mprf2idu_rs2_data_i));

        SCR1_IALU_CMD_SUB_LTU:
            branch_taken_early =
                (mprf2idu_rs1_data_i < mprf2idu_rs2_data_i);

        SCR1_IALU_CMD_SUB_GEU:
            branch_taken_early =
                (mprf2idu_rs1_data_i >= mprf2idu_rs2_data_i);

        default:
            branch_taken_early = 1'b0;
    endcase

    idu2exu_cmd_o.early_branch_valid = 1'b1;
    idu2exu_cmd_o.early_branch_taken = branch_taken_early;

`ifdef SCR1_BPU_EN
    // With BPU enabled, IFU is already following the predicted path.
    // A redirect is needed only when the early IDU result disagrees
    // with that path. No valid prediction means sequential/not-taken.
    branch_req_early =

           (branch_taken_early != bpu_path_taken_early)
         | (branch_taken_early
            & bpu_path_taken_early
            & (ifu2idu_bpu_target_i != branch_target_early));
    // Recovery address depends on the real early branch result:
    //   actual taken     -> branch target
    //   actual not-taken -> fall-through PC (+2 for RVC, +4 for RVI)
    if (~branch_taken_early) begin
        branch_target_early =
            ifu2idu_pc_i
            + (idu2exu_cmd_o.instr_rvc
               ? `SCR1_XLEN'd2
               : `SCR1_XLEN'd4);
    end
`else
    // Original EARLY_BRANCH behavior without predictor.
    // Original EARLY_BRANCH behavior without predictor:
    // redirect IFU only when the branch is actually taken.
    branch_req_early = branch_taken_early;
`endif // SCR1_BPU_EN
end
`endif // SCR1_EARLY_BRANCH

`ifdef SCR1_EARLY_BRANCH
`ifdef SCR1_BPU_EN
    // BPU + EARLY_BRANCH: direct PC-relative jump target.
    // JAL/C.J/C.JAL are predicted in IFU.  They do not use the conditional
    // early-branch comparator, but IFU still needs the correct next PC for
    // ifu_idu_pc_ff when the predicted-taken instruction is accepted.
    // JALR is intentionally excluded because its target depends on rs1.
    if (idu_accept
        && ~ifu2idu_imem_err_i
        && ~idu2exu_cmd_o.exc_req
        && idu2exu_cmd_o.jump_req
        && (idu2exu_cmd_o.sum2_op == SCR1_SUM2_OP_PC_IMM)) begin

        branch_target_early =
            ifu2idu_pc_i + idu2exu_cmd_o.imm;
    end
`endif // SCR1_BPU_EN
`endif // SCR1_EARLY_BRANCH

end // RV32I(MC) decode


`ifdef SCR1_EARLY_BRANCH
assign idu2mprf_rs1_addr_o     = idu2exu_cmd_o.rs1_addr;
assign idu2mprf_rs2_addr_o     = idu2exu_cmd_o.rs2_addr;
assign idu_accept              = ifu2idu_vd_i & exu2idu_rdy_i;
assign idu2ifu_branch_req_o    = branch_req_early;
assign idu2ifu_branch_target_o = branch_target_early;
`endif


// DBG_BPU_EARLY_TRACE_IDU
`ifdef SCR1_TRGT_SIMULATION
`ifdef SCR1_BPU_EN
`ifdef SCR1_EARLY_BRANCH
integer dbg_bpu_early_idu_cnt;

always_ff @(posedge clk, negedge rst_n) begin
    if (~rst_n) begin
        dbg_bpu_early_idu_cnt <= 0;
    end else if (dbg_bpu_early_idu_cnt < 200
                 && idu_accept
                 && (idu2exu_cmd_o.branch_req | idu2exu_cmd_o.jump_req)) begin
        dbg_bpu_early_idu_cnt <= dbg_bpu_early_idu_cnt + 1;
    end
end
`endif
`endif
`endif


// DBG_BPU_EARLY_FOCUS_IDU
`ifdef SCR1_TRGT_SIMULATION
`ifdef SCR1_BPU_EN
`ifdef SCR1_EARLY_BRANCH
integer dbg_focus_idu_cnt;
always_ff @(posedge clk, negedge rst_n) begin
    if (~rst_n) begin
        dbg_focus_idu_cnt <= 0;
    end else if (dbg_focus_idu_cnt < 2000
                 && idu_accept
                 && idu2exu_cmd_o.branch_req
                 && (
                      ifu2idu_bpu_vld_i
                      || (mprf2idu_rs1_data_i == mprf2idu_rs2_data_i)
                    )) begin
        dbg_focus_idu_cnt <= dbg_focus_idu_cnt + 1;
    end
end
`endif
`endif
`endif

`ifdef SCR1_TRGT_SIMULATION
//-------------------------------------------------------------------------------
// Assertion
//-------------------------------------------------------------------------------

// X checks

SCR1_SVA_IDU_XCHECK : assert property (
    @(negedge clk) disable iff (~rst_n)
    !$isunknown({ifu2idu_vd_i, exu2idu_rdy_i})
    ) else $error("IDU Error: unknown values");

// Behavior checks

SCR1_SVA_IDU_IALU_CMD_RANGE : assert property (
    @(negedge clk) disable iff (~rst_n)
    (ifu2idu_vd_i & ~ifu2idu_imem_err_i) |->
    ((idu2exu_cmd_o.ialu_cmd >= SCR1_IALU_CMD_NONE) &
    (idu2exu_cmd_o.ialu_cmd <=
`ifdef SCR1_RVM_EXT
                            SCR1_IALU_CMD_REMU
`else
                            SCR1_IALU_CMD_SRA
`endif // SCR1_RVM_EXT
        ))
    ) else $error("IDU Error: IALU_CMD out of range");

`endif // SCR1_TRGT_SIMULATION

endmodule : scr1_pipe_idu
