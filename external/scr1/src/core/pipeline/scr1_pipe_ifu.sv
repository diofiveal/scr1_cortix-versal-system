/// Copyright by Syntacore LLC © 2016-2021. See LICENSE for details
/// @file       <scr1_pipe_ifu.sv>
/// @brief      Instruction Fetch Unit (IFU)
///

`include "scr1_memif.svh"
`include "scr1_arch_description.svh"
`ifdef SCR1_DBG_EN
`include "scr1_hdu.svh"
`endif // SCR1_DBG_EN

module scr1_pipe_ifu
(
    // Control signals
    input   logic                                   rst_n,                      // IFU reset
    input   logic                                   clk,                        // IFU clock
    input   logic                                   pipe2ifu_stop_fetch_i,      // Stop instruction fetch

    // IFU <-> IMEM interface
    input   logic                                   imem2ifu_req_ack_i,         // Instruction memory request acknowledgement
    output  logic                                   ifu2imem_req_o,             // Instruction memory request
    output  type_scr1_mem_cmd_e                     ifu2imem_cmd_o,             // Instruction memory command (READ/WRITE)
    output  logic [`SCR1_IMEM_AWIDTH-1:0]           ifu2imem_addr_o,            // Instruction memory address
    input   logic [`SCR1_IMEM_DWIDTH-1:0]           imem2ifu_rdata_i,           // Instruction memory read data
    input   type_scr1_mem_resp_e                    imem2ifu_resp_i,            // Instruction memory response

    // IFU <-> EXU New PC interface
    input   logic                                   exu2ifu_pc_new_req_i,       // New PC request (jumps, branches, traps etc)
    input   logic [`SCR1_XLEN-1:0]                  exu2ifu_pc_new_i,           // New PC
`ifdef SCR1_BPU_EN
    // Proposal 3: FENCE.I flush signal for BHT reset
    input   logic                                   exu2ifu_bpu_flush_i,       // Flush BHT on FENCE.I
`endif // SCR1_BPU_EN

`ifdef SCR1_DBG_EN
    // IFU <-> HDU Program Buffer interface
    input   logic                                   hdu2ifu_pbuf_fetch_i,       // Fetch instructions provided by Program Buffer
    output  logic                                   ifu2hdu_pbuf_rdy_o,         // Program Buffer Instruction i/f ready
    input   logic                                   hdu2ifu_pbuf_vd_i,          // Program Buffer Instruction valid
    input   logic                                   hdu2ifu_pbuf_err_i,         // Program Buffer Instruction i/f error
    input   logic [SCR1_HDU_CORE_INSTR_WIDTH-1:0]   hdu2ifu_pbuf_instr_i,       // Program Buffer Instruction itself
`endif // SCR1_DBG_EN

`ifdef SCR1_CLKCTRL_EN
    output  logic                                   ifu2pipe_imem_txns_pnd_o,   // There are pending imem transactions
`endif // SCR1_CLKCTRL_EN

    // IFU <-> IDU interface
    input   logic                                   idu2ifu_rdy_i,              // IDU ready for new data
    output  logic [`SCR1_IMEM_DWIDTH-1:0]           ifu2idu_instr_o,            // IFU instruction
    output  logic                                   ifu2idu_imem_err_o,         // Instruction access fault exception
    output  logic                                   ifu2idu_err_rvi_hi_o,       // 1 - imem fault when trying to fetch second half of an unaligned RVI instruction
    output  logic                                   ifu2idu_vd_o                // IFU request
`ifdef SCR1_EARLY_BRANCH
    ,output logic [`SCR1_XLEN-1:0]                  ifu2idu_pc_o                // PC paired with IFU->IDU instruction
`endif // SCR1_EARLY_BRANCH
`ifdef SCR1_BPU_EN
    ,// BPU prediction outputs to IDU (v19: target piped for EXU compare)
    output  logic                                   ifu2idu_bpu_pred_o,         // BPU predicted taken
    output  logic                                   ifu2idu_bpu_vld_o,          // BPU prediction valid
    output  logic [`SCR1_XLEN-1:0]                  ifu2idu_bpu_target_o,       // BPU predicted target
    output  logic                                   ifu2idu_bpu_str_o,          // v20: instruction slot was BPU-steered (no wrong-path behind)
    output  logic                                   ifu2idu_bpu_steer_bypass_o, // v20: bypassed & BPU steered (live)
    // BPU training inputs from EXU
    input   logic                                   exu2ifu_bpu_train_vld_i,   // BPU train valid
    input   logic [`SCR1_XLEN-1:0]                  exu2ifu_bpu_train_pc_i,    // BPU train PC
    input   logic                                   exu2ifu_bpu_train_taken_i,  // BPU train taken
    input   logic [`SCR1_XLEN-1:0]                  exu2ifu_bpu_train_target_i, // BPU train target
    // OPTIMIZATION: RAS training inputs from EXU (push/pop at commit)
    input   logic                                   exu2ifu_bpu_ras_push_i,      // RAS push (call instruction)
    input   logic [`SCR1_XLEN-1:0]                  exu2ifu_bpu_ras_push_addr_i, // RAS push address
    input   logic                                   exu2ifu_bpu_ras_is_return_i  // RAS pop (return instruction)
`endif // SCR1_BPU_EN
);

//------------------------------------------------------------------------------
// Local parameters declaration
//------------------------------------------------------------------------------

localparam SCR1_IFU_Q_SIZE_WORD     = 2;
localparam SCR1_IFU_Q_SIZE_HALF     = SCR1_IFU_Q_SIZE_WORD * 2;
localparam SCR1_TXN_CNT_W           = 3;

localparam SCR1_IFU_QUEUE_ADR_W     = $clog2(SCR1_IFU_Q_SIZE_HALF);
localparam SCR1_IFU_QUEUE_PTR_W     = SCR1_IFU_QUEUE_ADR_W + 1;

localparam SCR1_IFU_Q_FREE_H_W      = $clog2(SCR1_IFU_Q_SIZE_HALF + 1);
localparam SCR1_IFU_Q_FREE_W_W      = $clog2(SCR1_IFU_Q_SIZE_WORD + 1);

//------------------------------------------------------------------------------
// Local types declaration
//------------------------------------------------------------------------------

typedef enum logic {
    SCR1_IFU_FSM_IDLE,
    SCR1_IFU_FSM_FETCH
} type_scr1_ifu_fsm_e;

typedef enum logic[1:0] {
    SCR1_IFU_QUEUE_WR_NONE,      // No write to queue
    SCR1_IFU_QUEUE_WR_FULL,      // Write 32 rdata bits to queue
    SCR1_IFU_QUEUE_WR_HI,        // Write 16 upper rdata bits to queue
    SCR1_IFU_QUEUE_WR_LO         // v19: Write 16 lower rdata bits (steer suppression)
} type_scr1_ifu_queue_wr_e;

typedef enum logic[1:0] {
    SCR1_IFU_QUEUE_RD_NONE,      // No queue read
    SCR1_IFU_QUEUE_RD_HWORD,     // Read halfword
    SCR1_IFU_QUEUE_RD_WORD       // Read word
} type_scr1_ifu_queue_rd_e;

`ifdef SCR1_NO_DEC_STAGE
typedef enum logic[1:0] {
    SCR1_BYPASS_NONE,               // No bypass
    SCR1_BYPASS_RVC,                // Bypass RVC
    SCR1_BYPASS_RVI_RDATA_QUEUE,    // Bypass RVI, rdata+queue
    SCR1_BYPASS_RVI_RDATA           // Bypass RVI, rdata only
} type_scr1_bypass_e;
`endif // SCR1_NO_DEC_STAGE

typedef enum logic [2:0] {
    // SCR1_IFU_INSTR_<UPPER_16_BITS>_<LOWER_16_BITS>
    SCR1_IFU_INSTR_NONE,                // No valid instruction
    SCR1_IFU_INSTR_RVI_HI_RVI_LO,       // Full RV32I instruction
    SCR1_IFU_INSTR_RVC_RVC,
    SCR1_IFU_INSTR_RVI_LO_RVC,
    SCR1_IFU_INSTR_RVC_RVI_HI,
    SCR1_IFU_INSTR_RVI_LO_RVI_HI,
    SCR1_IFU_INSTR_RVC_NV,              // Instruction after unaligned new_pc
    SCR1_IFU_INSTR_RVI_LO_NV            // Instruction after unaligned new_pc
} type_scr1_ifu_instr_e;

//------------------------------------------------------------------------------
// Local signals declaration
//------------------------------------------------------------------------------


`ifdef SCR1_EARLY_BRANCH
logic                               ifu_idu_accept;
logic                               ifu_idu_pc_advance;
logic [`SCR1_XLEN-1:0]              ifu_idu_pc_ff;
logic [`SCR1_XLEN-1:0]              ifu_idu_instr_size;
`ifdef SCR1_BPU_EN
logic                               ifu_idu_bpu_path_taken;
`endif // SCR1_BPU_EN
`endif // SCR1_EARLY_BRANCH

// Instruction queue signals
//------------------------------------------------------------------------------

// New PC unaligned flag register
logic                               new_pc_unaligned_ff;
logic                               new_pc_unaligned_next;
logic                               new_pc_unaligned_upd;

// IMEM instruction type decoder
logic                               instr_hi_is_rvi;
logic                               instr_lo_is_rvi;
type_scr1_ifu_instr_e               instr_type;

// Register to store if the previous IMEM instruction had low part of RVI instruction
// in its high part
logic                               instr_hi_rvi_lo_ff;
logic                               instr_hi_rvi_lo_next;

// Queue read/write size decoders
type_scr1_ifu_queue_rd_e            q_rd_size;
logic                               q_rd_vd;
logic                               q_rd_none;
logic                               q_rd_hword;
type_scr1_ifu_queue_wr_e            q_wr_size;
logic                               q_wr_none;
logic                               q_wr_full;

// Write/read pointer registers
logic [SCR1_IFU_QUEUE_PTR_W-1:0]    q_rptr;
logic [SCR1_IFU_QUEUE_PTR_W-1:0]    q_rptr_next;
logic                               q_rptr_upd;
logic [SCR1_IFU_QUEUE_PTR_W-1:0]    q_wptr;
logic [SCR1_IFU_QUEUE_PTR_W-1:0]    q_wptr_next;
logic                               q_wptr_upd;

// Instruction queue control signals
logic                               q_wr_en;
logic                               q_flush_req;

// Queue data registers
logic [`SCR1_IMEM_DWIDTH/2-1:0]     q_data  [SCR1_IFU_Q_SIZE_HALF];
logic [`SCR1_IMEM_DWIDTH/2-1:0]     q_data_head;
logic [`SCR1_IMEM_DWIDTH/2-1:0]     q_data_next;

// Queue error flags registers
logic                               q_err   [SCR1_IFU_Q_SIZE_HALF];
logic                               q_err_head;
logic                               q_err_next;

// Instruction queue status signals
logic                               q_is_empty;
logic                               q_has_free_slots;
logic                               q_has_1_ocpd_hw;
logic                               q_head_is_rvc;
logic                               q_head_is_rvi;
logic [SCR1_IFU_Q_FREE_H_W-1:0]     q_ocpd_h;
logic [SCR1_IFU_Q_FREE_H_W-1:0]     q_free_h_next;
logic [SCR1_IFU_Q_FREE_W_W-1:0]     q_free_w_next;

// IFU FSM signals
//------------------------------------------------------------------------------

// IFU FSM control signals
logic                               ifu_fetch_req;
logic                               ifu_stop_req;

type_scr1_ifu_fsm_e                 ifu_fsm_curr;
type_scr1_ifu_fsm_e                 ifu_fsm_next;
logic                               ifu_fsm_fetch;

// IMEM signals
//------------------------------------------------------------------------------

// IMEM response signals
logic                               imem_resp_ok;
logic                               imem_resp_er;
logic                               imem_resp_er_discard_pnd;
logic                               imem_resp_discard_req;
logic                               imem_resp_received;
logic                               imem_resp_vd;
logic                               imem_handshake_done;

logic [15:0]                        imem_rdata_lo;
logic [31:16]                       imem_rdata_hi;

// IMEM address signals
logic                               imem_addr_upd;
logic [`SCR1_XLEN-1:2]              imem_addr_ff;
logic [`SCR1_XLEN-1:2]              imem_addr_next;

// IMEM pending transactions counter
logic                               imem_pnd_txns_cnt_upd;
logic [SCR1_TXN_CNT_W-1:0]          imem_pnd_txns_cnt;
logic [SCR1_TXN_CNT_W-1:0]          imem_pnd_txns_cnt_next;
logic [SCR1_TXN_CNT_W-1:0]          imem_vd_pnd_txns_cnt;
logic                               imem_pnd_txns_q_full;

// IMEM responses discard counter
logic                               imem_resp_discard_cnt_upd;
logic [SCR1_TXN_CNT_W-1:0]          imem_resp_discard_cnt;
logic [SCR1_TXN_CNT_W-1:0]          imem_resp_discard_cnt_next;

`ifdef SCR1_NEW_PC_REG
logic                               new_pc_req_ff;
`endif // SCR1_NEW_PC_REG

// Instruction bypass signals
`ifdef SCR1_NO_DEC_STAGE
type_scr1_bypass_e                  instr_bypass_type;
logic                               instr_bypass_vd;
`endif // SCR1_NO_DEC_STAGE

`ifdef SCR1_BPU_EN
// BPU local signals (v19: dual-channel prediction + FTB)
logic                               bpu_predict_taken;      // effective steer decision taken
logic [`SCR1_XLEN-1:0]              bpu_target;             // effective steer target (word addr)
logic                               bpu_pred_vld;           // effective prediction valid
logic                               bpu_steer;              // response-time steer (any channel)
logic                               bpu_ch1_pred,  bpu_ch2_pred;
logic                               bpu_ch1_predvld, bpu_ch2_predvld;
logic                               bpu_steer_from_ch1, bpu_steer_from_ch2;
logic                               bpu_ch1_vld,   bpu_ch2_vld;
logic [`SCR1_XLEN-1:0]              bpu_ch1_target, bpu_ch2_target;
logic [`SCR1_XLEN-1:0]              bpu_ch1_pc,     bpu_ch2_pc;
logic [`SCR1_IMEM_DWIDTH-1:0]       bpu_ch1_instr,  bpu_ch2_instr;
// channel targets as word addresses for imem_addr_next
logic [`SCR1_XLEN-1:2]              bpu_steer_target_word;
logic [`SCR1_XLEN-1:2]              bpu_recover_word;       // resp_word + 1 (FTB miss recovery)
// BPU prediction per queue half-word (v19: target stored alongside)
logic                               q_bpu_pred [SCR1_IFU_Q_SIZE_HALF];
logic                               q_bpu_str  [SCR1_IFU_Q_SIZE_HALF];
logic                               q_bpu_vld  [SCR1_IFU_Q_SIZE_HALF];
logic [`SCR1_XLEN-1:0]              q_bpu_targ [SCR1_IFU_Q_SIZE_HALF];
// v21 FIX [IFU-IMPLICIT-NET]: the *_next readouts were never declared, so the
// simulator created 1-bit implicit nets — q_bpu_targ_next was silently
// truncated to the target LSB (always 0), EXU never matched
// (predicted_target == resolved_target) and the zero-bubble flush-skip
// never fired. Declared here with correct widths.
logic                               q_bpu_pred_next;
logic                               q_bpu_vld_next;
logic                               q_bpu_str_next;
logic [`SCR1_XLEN-1:0]              q_bpu_targ_next;
logic                               q_bpu_pred_head;
logic                               q_bpu_vld_head;
logic [`SCR1_XLEN-1:0]              q_bpu_targ_head;
logic                               q_bpu_str_head;
// FTB (Fetch Target Buffer) request-time steering bookkeeping
logic                               ftb_hit;
logic [`SCR1_XLEN-1:2]              ftb_target_word;
logic                               ftb_steer;              // FTB hit: redirect the next request
logic                               ftb_pend_ff;            // a FTB-steered word is in flight
logic [`SCR1_XLEN-1:2]              ftb_pend_word_ff;       // the steered word address
logic                               ftb_recover;            // response-time recovery (stale/miss)
logic                               ftb_pend_match;         // response of the FTB-steered word
logic                               ftb_match_ok;           // eval taken && target matches FTB
// wrong-path write suppression on response-time steer
logic                               wr_suppress_hi;         // drop the upper halfword (after-branch)
logic                               wr_suppress_all;        // write nothing (straddled steer)
// q_bpu write data (slot-keyed)
logic                               wq0_pred, wq0_vld, wq1_pred, wq1_vld;
logic                               wq0_str, wq1_str;
logic [`SCR1_XLEN-1:0]              wq0_targ, wq1_targ;
// FIX v17 [IFU-BPU-RESP-ADDR]: Correct BPU prediction PC.
// imem_addr_ff is a pre-incremented "next request address" register.
// When IMEM latency > 0, handshakes between request and response
// pre-increment imem_addr_ff, making it point to a future address,
// not the address of the current IMEM response. The BPU needs the
// response address for correct target computation.
//
// Derivation: imem_addr_ff was pre-incremented once for each pending
// transaction. Subtracting imem_pnd_txns_cnt (pending acknowledged but
// not yet responded) gives the word address of the current response.
logic [`SCR1_XLEN-1:2]              bpu_resp_word_addr;
// word address of the arriving IMEM response (oldest in-flight request)
assign bpu_resp_word_addr = imem_addr_ff[`SCR1_XLEN-1:2] - SCR1_TXN_CNT_W'(imem_pnd_txns_cnt);
`endif // SCR1_BPU_EN

//------------------------------------------------------------------------------
// Instruction queue
//------------------------------------------------------------------------------
//
 // Instruction queue consists of the following functional units:
 // - New PC unaligned flag register
 // - Instruction type decoder, including register to store if the previous
 //   IMEM instruction had low part of RVI instruction in its high part
 // - Read/write size decoders
 // - Read/write pointer registers
 // - Data and error flag registers
 // - Status logic
//

// New PC unaligned flag register
//------------------------------------------------------------------------------

assign new_pc_unaligned_upd = exu2ifu_pc_new_req_i | imem_resp_vd;

always_ff @(posedge clk, negedge rst_n) begin
    if (~rst_n) begin
        new_pc_unaligned_ff <= 1'b0;
    end else if (new_pc_unaligned_upd) begin
        new_pc_unaligned_ff <= new_pc_unaligned_next;
    end
end

assign new_pc_unaligned_next = exu2ifu_pc_new_req_i ? exu2ifu_pc_new_i[1]
`ifdef SCR1_BPU_EN
                             : bpu_steer              ? bpu_target[1]
`endif // SCR1_BPU_EN
                             : ~imem_resp_vd        ? new_pc_unaligned_ff
                                                    : 1'b0;

// Instruction type decoder
//------------------------------------------------------------------------------

assign instr_hi_is_rvi = &imem2ifu_rdata_i[17:16];
assign instr_lo_is_rvi = &imem2ifu_rdata_i[1:0];

always_comb begin
    instr_type = SCR1_IFU_INSTR_NONE;

    if (imem_resp_ok & ~imem_resp_discard_req) begin
        if (new_pc_unaligned_ff) begin
            instr_type = instr_hi_is_rvi ? SCR1_IFU_INSTR_RVI_LO_NV
                                         : SCR1_IFU_INSTR_RVC_NV;
        end else begin // ~new_pc_unaligned_ff
            if (instr_hi_rvi_lo_ff) begin
                instr_type = instr_hi_is_rvi ? SCR1_IFU_INSTR_RVI_LO_RVI_HI
                                             : SCR1_IFU_INSTR_RVC_RVI_HI;
            end else begin // SCR1_OTHER
                case ({instr_hi_is_rvi, instr_lo_is_rvi})
                    2'b00   : instr_type   = SCR1_IFU_INSTR_RVC_RVC;
                    2'b10   : instr_type   = SCR1_IFU_INSTR_RVI_LO_RVC;
                    default : instr_type   = SCR1_IFU_INSTR_RVI_HI_RVI_LO;
                endcase
            end
        end
    end
end

// Register to store if the previous IMEM instruction had low part of RVI
// instruction in its high part
//------------------------------------------------------------------------------

always_ff @(posedge clk, negedge rst_n) begin
    if (~rst_n) begin
        instr_hi_rvi_lo_ff <= 1'b0;
    end else begin
        if (exu2ifu_pc_new_req_i) begin
            instr_hi_rvi_lo_ff <= 1'b0;
        end else if (imem_resp_vd) begin
            instr_hi_rvi_lo_ff <= instr_hi_rvi_lo_next;
        end
    end
end

assign instr_hi_rvi_lo_next = (instr_type == SCR1_IFU_INSTR_RVI_LO_NV)
                            | (instr_type == SCR1_IFU_INSTR_RVI_LO_RVI_HI)
                            | (instr_type == SCR1_IFU_INSTR_RVI_LO_RVC);

// Queue write/read size decoders
//------------------------------------------------------------------------------

// Queue read size decoder
assign q_rd_vd    = ~q_is_empty & ifu2idu_vd_o & idu2ifu_rdy_i;
assign q_rd_hword = q_head_is_rvc | q_err_head
`ifdef SCR1_NO_DEC_STAGE
                  | (q_head_is_rvi & instr_bypass_vd)
`endif // SCR1_NO_DEC_STAGE
                  ;
assign q_rd_size  = ~q_rd_vd   ? SCR1_IFU_QUEUE_RD_NONE
                  : q_rd_hword ? SCR1_IFU_QUEUE_RD_HWORD
                               : SCR1_IFU_QUEUE_RD_WORD;
assign q_rd_none  = (q_rd_size == SCR1_IFU_QUEUE_RD_NONE);

// Queue write size decoder (v19: wrong-path suppression on steer)
// When the BPU steers at the response of the word containing the predicted
// branch, halfwords AFTER the predicted branch are wrong-path and must not
// enter the queue. This is what allows EXU to skip the queue flush for a
// correctly-predicted taken branch (FIX-FALSE-FLUSH).
//
// Channel-1 steer cases (the predicted branch is in THIS word):
//   RVI_HI_RVI_LO : whole word IS the branch            -> write both (unchanged)
//   RVC_RVC       : branch = lower half, upper = wrong  -> WR_LO (new)
//   RVC_NV        : branch = upper half, NV lower       -> WR_HI (unchanged)
//   RVI_LO_RVC / RVI_LO_RVI_HI (straddled, bypassed)    -> WR_NONE (unchanged)
// Channel-2 steer cases (branch = upper RVC): no suppression.
`ifdef SCR1_BPU_EN
always_comb begin
    wr_suppress_hi  = 1'b0;
    wr_suppress_all = 1'b0;
    if (bpu_steer_from_ch1) begin
        case (instr_type)
            // word = {RVI-hi16 | RVI-lo16}: the whole word is the branch
            SCR1_IFU_INSTR_RVI_HI_RVI_LO: wr_suppress_hi  = 1'b0;
            // word = {RVC | RVC}: upper half is sequential-after-branch
            SCR1_IFU_INSTR_RVC_RVC:       wr_suppress_hi  = 1'b1;
            // straddled branch: 3-stage bypass completes it from rdata_lo
            // directly in IDU, so nothing of this word is queued; 4-stage has
            // no bypass — the branch-completing halfword (rdata_lo) MUST be
            // queued, only the after-branch upper halfword is dropped.
            SCR1_IFU_INSTR_RVI_LO_RVC,
            SCR1_IFU_INSTR_RVI_LO_RVI_HI: begin
                wr_suppress_all = `ifdef SCR1_NO_DEC_STAGE 1'b1 `else 1'b0 `endif;
                wr_suppress_hi  = `ifdef SCR1_NO_DEC_STAGE 1'b0 `else 1'b1 `endif;
            end
            // NV: the "lower" half is architecturally absent
            SCR1_IFU_INSTR_RVC_NV,
            SCR1_IFU_INSTR_RVI_LO_NV:     wr_suppress_hi  = 1'b0;
            default:                      wr_suppress_hi  = 1'b0;
        endcase
    end
end
`endif // SCR1_BPU_EN

always_comb begin
    q_wr_size = SCR1_IFU_QUEUE_WR_NONE;
    if (~imem_resp_discard_req) begin
        if (imem_resp_ok) begin
`ifdef SCR1_NO_DEC_STAGE
            case (instr_type)
                SCR1_IFU_INSTR_NONE         : q_wr_size = SCR1_IFU_QUEUE_WR_NONE;
                SCR1_IFU_INSTR_RVI_LO_NV    : q_wr_size = SCR1_IFU_QUEUE_WR_HI;
                SCR1_IFU_INSTR_RVC_NV       : q_wr_size = (instr_bypass_vd & idu2ifu_rdy_i)
                                                        ? SCR1_IFU_QUEUE_WR_NONE
                                                        : SCR1_IFU_QUEUE_WR_HI;
// FIX CI-4 [IFU-QUEUE-OVF]: Added q_free_h_next >= 2 guard for WR_FULL.
                SCR1_IFU_INSTR_RVI_HI_RVI_LO: q_wr_size = (instr_bypass_vd & idu2ifu_rdy_i)
                                                        ? SCR1_IFU_QUEUE_WR_NONE
                                                        : (q_free_h_next >= SCR1_IFU_Q_FREE_H_W'(2))
                                                          ? SCR1_IFU_QUEUE_WR_FULL
                                                          : SCR1_IFU_QUEUE_WR_NONE;
                SCR1_IFU_INSTR_RVC_RVC,
                SCR1_IFU_INSTR_RVI_LO_RVC,
                SCR1_IFU_INSTR_RVC_RVI_HI,
                SCR1_IFU_INSTR_RVI_LO_RVI_HI: q_wr_size = (instr_bypass_vd & idu2ifu_rdy_i)
                                                        ? SCR1_IFU_QUEUE_WR_HI
                                                        : (q_free_h_next >= SCR1_IFU_Q_FREE_H_W'(2))
                                                          ? SCR1_IFU_QUEUE_WR_FULL
                                                          : SCR1_IFU_QUEUE_WR_NONE;
            endcase // instr_type
            // v19 FIX-FALSE-FLUSH: drop wrong-path halfwords on a response-time steer
            if (bpu_steer) begin
                if (wr_suppress_all)                    q_wr_size = SCR1_IFU_QUEUE_WR_NONE;
                else if (wr_suppress_hi)                q_wr_size = SCR1_IFU_QUEUE_WR_LO;
            end
`else // SCR1_NO_DEC_STAGE (4-stage)
            case (instr_type)
                SCR1_IFU_INSTR_NONE         : q_wr_size = SCR1_IFU_QUEUE_WR_NONE;
                SCR1_IFU_INSTR_RVC_NV,
                SCR1_IFU_INSTR_RVI_LO_NV    : q_wr_size = SCR1_IFU_QUEUE_WR_HI;
                default                     : q_wr_size = SCR1_IFU_QUEUE_WR_FULL;
            endcase // instr_type
`ifdef SCR1_BPU_EN
            // v20: same wrong-path suppression as the 3-stage path — the
            // halfwords after a steered branch must not enter the queue
            if (bpu_steer) begin
                if (wr_suppress_all)                    q_wr_size = SCR1_IFU_QUEUE_WR_NONE;
                else if (wr_suppress_hi)                q_wr_size = SCR1_IFU_QUEUE_WR_LO;
            end
`endif // SCR1_BPU_EN
`endif // SCR1_NO_DEC_STAGE
        end else if (imem_resp_er) begin
            q_wr_size = SCR1_IFU_QUEUE_WR_FULL;
        end // imem_resp_er
    end // ~imem_resp_discard_req
end

assign q_wr_none   = (q_wr_size == SCR1_IFU_QUEUE_WR_NONE);
assign q_wr_full   = (q_wr_size == SCR1_IFU_QUEUE_WR_FULL);

// Write/read pointer registers
//------------------------------------------------------------------------------

assign q_flush_req = exu2ifu_pc_new_req_i | pipe2ifu_stop_fetch_i
`ifdef SCR1_BPU_EN
// OPTIMIZATION (2-stage only): when BPU steers on a bypassed instruction
// (queue was empty), flush the queue to prevent wrong-path data from being
// written behind the bypassed branch. The bypass has already delivered the
// branch to IDU, so dropping the queue write here is lossless.
// 4-stage MUST NOT flush here: there is no bypass, the branch itself is
// delivered through the queue — a flush would discard the branch (v21 fix).
`ifdef SCR1_NO_DEC_STAGE

`else // SCR1_NO_DEC_STAGE
                     | (bpu_steer & q_is_empty)
`endif // SCR1_NO_DEC_STAGE
`endif // SCR1_BPU_EN
                     ;

// Queue write pointer register
assign q_wptr_upd  = q_flush_req | ~q_wr_none;

always_ff @(posedge clk, negedge rst_n) begin
    if (~rst_n) begin
        q_wptr <= '0;
    end else if (q_wptr_upd) begin
        q_wptr <= q_wptr_next;
    end
end

assign q_wptr_next = q_flush_req ? '0
                   : ~q_wr_none  ? q_wptr + (q_wr_full ? SCR1_IFU_QUEUE_PTR_W'('b010) : SCR1_IFU_QUEUE_PTR_W'('b001))
                                 : q_wptr;

// Queue read pointer register
assign q_rptr_upd  = q_flush_req | ~q_rd_none;

always_ff @(posedge clk, negedge rst_n) begin
    if (~rst_n) begin
        q_rptr <= '0;
    end else if (q_rptr_upd) begin
        q_rptr <= q_rptr_next;
    end
end

assign q_rptr_next = q_flush_req ? '0
                   : ~q_rd_none  ? q_rptr + (q_rd_hword ? SCR1_IFU_QUEUE_PTR_W'('b001) : SCR1_IFU_QUEUE_PTR_W'('b010))
                                 : q_rptr;

`ifdef SCR1_BPU_EN
assign q_bpu_str_next  = q_bpu_str [SCR1_IFU_QUEUE_ADR_W'(q_rptr + 1'b1)];
`endif // SCR1_BPU_EN

// Queue data and error flag registers
//------------------------------------------------------------------------------

assign imem_rdata_hi = imem2ifu_rdata_i[31:16];
assign imem_rdata_lo = imem2ifu_rdata_i[15:0];

assign q_wr_en = imem_resp_vd
                 & ~q_flush_req;

// v21 FIX [IFU-PRED-SLOT-INDEPENDENT]: predictions are stored per CHANNEL,
// not per steer outcome. v19/v20 keyed the storage on bpu_steer_from_ch1/2,
// so when ch1 predicted taken, ch2's valid prediction was dropped (and vice
// versa) — a systematic coverage leak for the second branch in a word.
//   ch1 -> slot of its instruction COMPLETION halfword:
//            unaligned NV word (instr starts at hi16) -> upper slot (wq1)
//            full RVI word (completion = hi16)        -> upper slot (wq1)
//            all other cases (own/lo slot)            -> lower slot (wq0)
//   ch2 -> upper slot (wq1) whenever ch2 evaluated a valid instruction.
// The two channels never collide: ch1 goes to wq1 exactly when ch2 is
// gated off (new_pc_unaligned_ff or instr_hi_is_rvi).
// Slots not selected by q_wr_size this cycle are don't-care.
`ifdef SCR1_BPU_EN
always_comb begin
    wq0_pred = 1'b0; wq0_vld = 1'b0; wq0_targ = '0;
    wq1_pred = 1'b0; wq1_vld = 1'b0; wq1_targ = '0;
    wq0_str = 1'b0; wq1_str = 1'b0;
    if (new_pc_unaligned_ff | (instr_type == SCR1_IFU_INSTR_RVI_HI_RVI_LO)) begin
        wq1_pred = bpu_ch1_pred; wq1_vld = bpu_ch1_predvld; wq1_targ = bpu_ch1_target;
    end else begin
        wq0_pred = bpu_ch1_pred; wq0_vld = bpu_ch1_predvld; wq0_targ = bpu_ch1_target;
    end
    if (bpu_ch2_vld) begin
        wq1_pred = bpu_ch2_pred; wq1_vld = bpu_ch2_predvld; wq1_targ = bpu_ch2_target;
    end
    // v20: slots written on a steer cycle carry str=1 — the queue behind the
    // steered branch holds only correct-path instructions (wrong-path
    // halfwords were suppressed), so EXU may skip the flush on a match.
    if (bpu_steer) begin
        wq0_str = 1'b1; wq1_str = 1'b1;
    end
end
`endif // SCR1_BPU_EN

always_ff @(posedge clk, negedge rst_n) begin
    if (~rst_n) begin
        q_data  <= '{SCR1_IFU_Q_SIZE_HALF{'0}};
        q_err   <= '{SCR1_IFU_Q_SIZE_HALF{1'b0}};
`ifdef SCR1_BPU_EN
        q_bpu_pred <= '{SCR1_IFU_Q_SIZE_HALF{1'b0}};
        q_bpu_vld  <= '{SCR1_IFU_Q_SIZE_HALF{1'b0}};
        q_bpu_targ <= '{SCR1_IFU_Q_SIZE_HALF{'0}};
        q_bpu_str  <= '{SCR1_IFU_Q_SIZE_HALF{1'b0}};
`endif // SCR1_BPU_EN
    end else if (q_wr_en) begin
        case (q_wr_size)
            SCR1_IFU_QUEUE_WR_LO    : begin
                q_data[SCR1_IFU_QUEUE_ADR_W'(q_wptr)]         <= imem_rdata_lo;
                q_err [SCR1_IFU_QUEUE_ADR_W'(q_wptr)]         <= imem_resp_er;
`ifdef SCR1_BPU_EN
                q_bpu_pred[SCR1_IFU_QUEUE_ADR_W'(q_wptr)] <= wq0_pred;
                q_bpu_vld [SCR1_IFU_QUEUE_ADR_W'(q_wptr)] <= wq0_vld;
                q_bpu_targ[SCR1_IFU_QUEUE_ADR_W'(q_wptr)] <= wq0_targ;
                q_bpu_str [SCR1_IFU_QUEUE_ADR_W'(q_wptr)] <= wq0_str;
`endif // SCR1_BPU_EN
            end
            SCR1_IFU_QUEUE_WR_HI    : begin
                q_data[SCR1_IFU_QUEUE_ADR_W'(q_wptr)]         <= imem_rdata_hi;
                q_err [SCR1_IFU_QUEUE_ADR_W'(q_wptr)]         <= imem_resp_er;
`ifdef SCR1_BPU_EN
                q_bpu_pred[SCR1_IFU_QUEUE_ADR_W'(q_wptr)] <= wq1_pred;
                q_bpu_vld [SCR1_IFU_QUEUE_ADR_W'(q_wptr)] <= wq1_vld;
                q_bpu_targ[SCR1_IFU_QUEUE_ADR_W'(q_wptr)] <= wq1_targ;
                q_bpu_str [SCR1_IFU_QUEUE_ADR_W'(q_wptr)] <= wq1_str;
`endif // SCR1_BPU_EN
            end
            SCR1_IFU_QUEUE_WR_FULL  : begin
                q_data[SCR1_IFU_QUEUE_ADR_W'(q_wptr)]         <= imem_rdata_lo;
                q_err [SCR1_IFU_QUEUE_ADR_W'(q_wptr)]         <= imem_resp_er;
                q_data[SCR1_IFU_QUEUE_ADR_W'(q_wptr + 1'b1)]  <= imem_rdata_hi;
                q_err [SCR1_IFU_QUEUE_ADR_W'(q_wptr + 1'b1)]  <= imem_resp_er;
`ifdef SCR1_BPU_EN
                q_bpu_pred[SCR1_IFU_QUEUE_ADR_W'(q_wptr)]         <= wq0_pred;
                q_bpu_vld [SCR1_IFU_QUEUE_ADR_W'(q_wptr)]         <= wq0_vld;
                q_bpu_targ[SCR1_IFU_QUEUE_ADR_W'(q_wptr)]         <= wq0_targ;
// v21 FIX [IFU-STR-STALE]: str of the lower slot must be rewritten on every
// full-word write. Leaving it stale could let a non-steered branch reach EXU
// with str=1 and trigger a flush-skip on an unsteered (wrong-path) stream.
                q_bpu_str [SCR1_IFU_QUEUE_ADR_W'(q_wptr)]         <= wq0_str;
                q_bpu_pred[SCR1_IFU_QUEUE_ADR_W'(q_wptr + 1'b1)] <= wq1_pred;
                q_bpu_vld [SCR1_IFU_QUEUE_ADR_W'(q_wptr + 1'b1)] <= wq1_vld;
                q_bpu_targ[SCR1_IFU_QUEUE_ADR_W'(q_wptr + 1'b1)] <= wq1_targ;
                q_bpu_str [SCR1_IFU_QUEUE_ADR_W'(q_wptr + 1'b1)] <= wq1_str;
`endif // SCR1_BPU_EN
            end
        endcase
    end
end

assign q_data_head = q_data [SCR1_IFU_QUEUE_ADR_W'(q_rptr)];
assign q_data_next = q_data [SCR1_IFU_QUEUE_ADR_W'(q_rptr + 1'b1)];
assign q_err_head  = q_err  [SCR1_IFU_QUEUE_ADR_W'(q_rptr)];
assign q_err_next  = q_err  [SCR1_IFU_QUEUE_ADR_W'(q_rptr + 1'b1)];
`ifdef SCR1_BPU_EN
assign q_bpu_pred_head = q_bpu_pred[SCR1_IFU_QUEUE_ADR_W'(q_rptr)];
assign q_bpu_vld_head  = q_bpu_vld [SCR1_IFU_QUEUE_ADR_W'(q_rptr)];
assign q_bpu_targ_head = q_bpu_targ[SCR1_IFU_QUEUE_ADR_W'(q_rptr)];
assign q_bpu_str_head  = q_bpu_str [SCR1_IFU_QUEUE_ADR_W'(q_rptr)];
assign q_bpu_pred_next = q_bpu_pred[SCR1_IFU_QUEUE_ADR_W'(q_rptr + 1'b1)];
assign q_bpu_vld_next  = q_bpu_vld [SCR1_IFU_QUEUE_ADR_W'(q_rptr + 1'b1)];
assign q_bpu_targ_next = q_bpu_targ[SCR1_IFU_QUEUE_ADR_W'(q_rptr + 1'b1)];
`endif // SCR1_BPU_EN

// Queue status logic
//------------------------------------------------------------------------------

assign q_ocpd_h         = SCR1_IFU_Q_FREE_H_W'(q_wptr - q_rptr);
assign q_free_h_next    = SCR1_IFU_Q_FREE_H_W'(SCR1_IFU_Q_SIZE_HALF - (q_wptr - q_rptr_next));
assign q_free_w_next    = SCR1_IFU_Q_FREE_W_W'(q_free_h_next >> 1'b1);

assign q_is_empty       = (q_rptr == q_wptr);
assign q_has_free_slots = (SCR1_TXN_CNT_W'(q_free_w_next) > imem_vd_pnd_txns_cnt);
assign q_has_1_ocpd_hw  = (q_ocpd_h == SCR1_IFU_Q_FREE_H_W'(1));

assign q_head_is_rvi    = &(q_data_head[1:0]);
assign q_head_is_rvc    = ~q_head_is_rvi;

//------------------------------------------------------------------------------
// Branch Prediction Unit (BPU)
//------------------------------------------------------------------------------
`ifdef SCR1_BPU_EN

// BPU steering signals
// v21.1: explicit declarations (were implicit 1-bit wires)
logic                bpu_pred_is_hi;           // predicted instruction starts in high halfword
logic                bpu_pred_instr_complete;  // ch1 instruction fully contained in fetched data
logic                bpu_can_steer;            // response-time steer admissibility (memory side)
assign bpu_pred_is_hi        = new_pc_unaligned_ff | instr_hi_rvi_lo_ff;
// FIX CI-1 [IFU-STRADDLING-COMPLETE]: When instr_hi_rvi_lo_ff=1, the straddling RVI
// instruction is already complete (low half in queue, high half in rdata_lo).
// The old code checked ~instr_hi_is_rvi (upper half of CURRENT word = next instr),
// which is wrong. For instr_hi_rvi_lo_ff, completeness is always 1'b1.
assign bpu_pred_instr_complete = bpu_pred_is_hi
                                ? (instr_hi_rvi_lo_ff ? 1'b1 : ~instr_hi_is_rvi)
                                : 1'b1;
assign bpu_can_steer = imem_resp_ok & bpu_pred_instr_complete
`ifdef SCR1_DBG_EN
                       & ~hdu2ifu_pbuf_fetch_i
`endif // SCR1_DBG_EN
                       ;
// v21 FIX [IFU-STEER-COMB-LOOP] + [IFU-STEER-PND] + [IFU-STEER-HOLD]:
// (1) v20 read imem_pnd_txns_cnt_next here, closing a combinational loop
// bpu_steer -> ifu2imem_req_o -> imem_handshake_done -> imem_pnd_txns_cnt_next
// -> bpu_steer (simulator UNOPTFLAT). v21 uses ONLY registered state.
// (2) v20 required the steered word to be the ONLY in-flight txn; v21 instead
// discards the in-flight sequential prefetches behind it via
// imem_resp_discard_cnt = imem_pnd_txns_cnt - 1 (exact for in-order memory),
// so the steer may fire regardless of prefetch depth.
// (3) steer_hold_ff keeps a 2-cycle settle window after any EXU redirect:
// without it a mispredict->steer chain re-steers on a stale response and the
// core hangs (verified experimentally). The discard counter alone is not
// sufficient because the first post-redirect response may already be in
// flight when the redirect lands.
// Straddling branches still never steer: their fetch spans two imem words,
// the EXU redirect handles them the classic way.
logic [1:0]          steer_hold_ff;   // post-redirect settle window
always_ff @(posedge clk, negedge rst_n) begin
    if (~rst_n)                                             steer_hold_ff <= 2'd0;
    else if (exu2ifu_pc_new_req_i)                          steer_hold_ff <= 2'd2;
    else if (|steer_hold_ff)                                steer_hold_ff <= steer_hold_ff - 1'b1;
end
// v21: the gate does NOT read exu2ifu_pc_new_req_i — in the 2-stage config
// that signal depends on the EXU flush-skip decision, which depends on the
// steered-bypass flag, which depends on bpu_steer: a combinational loop.
// Instead, every steering side effect (imem_addr_next, address mux, discard
// count, unaligned flag) gives exu2ifu_pc_new_req_i strict priority, so a
// coincident EXU redirect fully supersedes the steer.
assign bpu_steer     = bpu_predict_taken & bpu_can_steer
                       & ~instr_hi_rvi_lo_ff
                       & (steer_hold_ff == 2'd0)
                       & (imem_resp_discard_cnt == '0)
                       & (imem_pnd_txns_cnt != '0);

// ---- v20: prediction channel formation (response-time evaluation) ----
// ch1: instruction starting the current response word:
//   straddle completion -> assembled 32-bit {rdata_lo, prev_lo_half}
//   unaligned stream    -> upper halfword RVC of this word
//   aligned             -> the full word (RVI) / lower halfword (RVC)
// ch2: upper halfword RVC, only when the word holds two RVC instructions.
assign bpu_ch1_pc     = instr_hi_rvi_lo_ff ? {bpu_resp_word_addr - 1'b1, 2'b10}
                      : new_pc_unaligned_ff ? {bpu_resp_word_addr, 2'b10}
                      : {bpu_resp_word_addr, 2'b00};
assign bpu_ch1_instr  = instr_hi_rvi_lo_ff ? {imem_rdata_lo, q_data_head}
                      : new_pc_unaligned_ff ? {16'h0, imem_rdata_hi}
                      : imem2ifu_rdata_i;
assign bpu_ch1_vld    = imem_resp_vd & bpu_pred_instr_complete;
assign bpu_ch2_pc     = {bpu_resp_word_addr, 2'b10};
assign bpu_ch2_instr  = {16'h0, imem_rdata_hi};
// v21: ch2 also evaluates the upper RVC of a straddle-completion word
// (RVI_LO_RVC): that halfword is a complete instruction. ch2 stays off when
// the upper halfword is an incomplete RVI (instr_hi_is_rvi) or when the word
// is an unaligned NV word (ch1 covers it).
assign bpu_ch2_vld    = imem_resp_vd & ~new_pc_unaligned_ff
                        & ~instr_hi_is_rvi
                        & (instr_hi_rvi_lo_ff | ~instr_lo_is_rvi);

// steer source: ch1 (earlier in program order) wins; ch2 only when ch1
// does not predict taken. Both include their own vld gating inside the BPU.
assign bpu_steer_from_ch2 = bpu_ch2_pred & ~bpu_ch1_pred;
assign bpu_steer_from_ch1 = bpu_ch1_pred & ~bpu_steer_from_ch2;

// effective prediction used for steering and queue tagging
assign bpu_predict_taken = bpu_steer_from_ch1 | bpu_steer_from_ch2;
assign bpu_pred_vld      = bpu_steer_from_ch2 ? bpu_ch2_predvld
                         : bpu_ch1_predvld;
assign bpu_target        = bpu_steer_from_ch2 ? bpu_ch2_target
                         : bpu_ch1_target;

// BPU instance (v19: dual channel + FTB + RAS-8)
scr1_pipe_bpu i_pipe_bpu (
    .clk                 (clk),
    .rst_n               (rst_n),
    .ch1_pc_i            (bpu_ch1_pc),
    .ch1_instr_i         (bpu_ch1_instr),
    .ch1_vld_i           (bpu_ch1_vld),
    .ch1_pred_o          (bpu_ch1_pred),
    .ch1_target_o        (bpu_ch1_target),
    .ch1_predvld_o       (bpu_ch1_predvld),
    .ch2_pc_i            (bpu_ch2_pc),
    .ch2_instr_i         (bpu_ch2_instr),
    .ch2_vld_i           (bpu_ch2_vld),
    .ch2_pred_o          (bpu_ch2_pred),
    .ch2_target_o        (bpu_ch2_target),
    .ch2_predvld_o       (bpu_ch2_predvld),
`ifdef SCR1_BPU_FTB_EN
    .ftb_idx_pc_i        (imem_addr_ff),
    .ftb_hit_o           (ftb_hit),
    .ftb_target_o        (ftb_target_word),
`endif // SCR1_BPU_FTB_EN
    .bpu_flush_i          (exu2ifu_bpu_flush_i),
    .bpu_train_vld_i     (exu2ifu_bpu_train_vld_i),
    .bpu_train_pc_i      (exu2ifu_bpu_train_pc_i),
    .bpu_train_taken_i   (exu2ifu_bpu_train_taken_i),
    .bpu_train_target_i  (exu2ifu_bpu_train_target_i),
    .bpu_train_push_i     (exu2ifu_bpu_ras_push_i),
    .bpu_train_push_addr_i(exu2ifu_bpu_ras_push_addr_i),
    .bpu_train_is_return_i(exu2ifu_bpu_ras_is_return_i)
);

`endif // SCR1_BPU_EN

//------------------------------------------------------------------------------
// IFU FSM
//------------------------------------------------------------------------------

// IFU FSM control signals
assign ifu_fetch_req = exu2ifu_pc_new_req_i & ~pipe2ifu_stop_fetch_i;
assign ifu_stop_req  = pipe2ifu_stop_fetch_i
                     | (imem_resp_er_discard_pnd & ~exu2ifu_pc_new_req_i);

always_ff @(posedge clk, negedge rst_n) begin
    if (~rst_n) begin
        ifu_fsm_curr <= SCR1_IFU_FSM_IDLE;
    end else begin
        ifu_fsm_curr <= ifu_fsm_next;
    end
end

always_comb begin
    case (ifu_fsm_curr)
        SCR1_IFU_FSM_IDLE   : begin
            ifu_fsm_next = ifu_fetch_req ? SCR1_IFU_FSM_FETCH
                                         : SCR1_IFU_FSM_IDLE;
        end
        SCR1_IFU_FSM_FETCH  : begin
            ifu_fsm_next = ifu_stop_req  ? SCR1_IFU_FSM_IDLE
                                         : SCR1_IFU_FSM_FETCH;
        end
    endcase
end

assign ifu_fsm_fetch = (ifu_fsm_curr == SCR1_IFU_FSM_FETCH);

//------------------------------------------------------------------------------
// IFU <-> IMEM interface
//------------------------------------------------------------------------------
//
 // IFU <-> IMEM interface consists of the following functional units:
 // - IMEM response logic
 // - IMEM address register
 // - Pending IMEM transactions counter
 // - IMEM discard responses counter
 // - IFU <-> IMEM interface output signals
//

// v19 FTB bookkeeping registers
`ifdef SCR1_BPU_FTB_EN
always_ff @(posedge clk, negedge rst_n) begin
    if (~rst_n) begin
        ftb_pend_ff      <= 1'b0;
        ftb_pend_word_ff <= '0;
    end else if (exu2ifu_pc_new_req_i | (bpu_steer & ~steer_suppress_ftb) | ftb_recover) begin
        // any redirect supersedes FTB bookkeeping
        ftb_pend_ff <= bpu_steer & ~steer_suppress_ftb;
        ftb_pend_word_ff <= bpu_resp_word_addr;
    end else if (ftb_steer) begin
        ftb_pend_ff      <= 1'b1;
        ftb_pend_word_ff <= imem_addr_ff;
    end else if (ftb_pend_match) begin
        ftb_pend_ff <= 1'b0;
    end
end
`endif // SCR1_BPU_FTB_EN

// IMEM response logic
//------------------------------------------------------------------------------

assign imem_resp_er             = (imem2ifu_resp_i == SCR1_MEM_RESP_RDY_ER);
assign imem_resp_ok             = (imem2ifu_resp_i == SCR1_MEM_RESP_RDY_OK);
assign imem_resp_received       = imem_resp_ok | imem_resp_er;
assign imem_resp_vd             = imem_resp_received & ~imem_resp_discard_req;
assign imem_resp_er_discard_pnd = imem_resp_er & ~imem_resp_discard_req;

assign imem_handshake_done = ifu2imem_req_o & imem2ifu_req_ack_i;

// IMEM address register
//------------------------------------------------------------------------------

`ifdef SCR1_BPU_EN
assign imem_addr_upd = imem_handshake_done | exu2ifu_pc_new_req_i | bpu_steer;
`else // ~SCR1_BPU_EN
assign imem_addr_upd = imem_handshake_done | exu2ifu_pc_new_req_i;
`endif // SCR1_BPU_EN

always_ff @(posedge clk, negedge rst_n) begin
    if (~rst_n) begin
        imem_addr_ff <= '0;
    end else if (imem_addr_upd) begin
        imem_addr_ff <= imem_addr_next;
    end
end

`ifdef SCR1_BPU_EN
// v19 FTB: request-time redirect. When the word about to be fetched holds a
// previously-taken branch, redirect the fetch stream to its target one word
// earlier than the response-time steer can. Bookkeeping: ftb_pend tracks the
// steered word; at its response the prediction is checked -- on a hit the
// response-time steer is suppressed (fetch is already at the target), on a
// miss/not-taken the stream is recovered to the sequential successor.
// Single-outstanding policy keeps bookkeeping trivial and safe for AHB.
assign ftb_steer   = `ifdef SCR1_BPU_FTB_EN ftb_hit & ~ftb_pend_ff `else 1'b0 `endif;
assign ftb_pend_match = ftb_pend_ff & (ftb_pend_word_ff == bpu_resp_word_addr);
// recovery: the FTB-steered word does not predict taken (aliased FTB hit,
// counter flipped) -> resume sequential fetch after the steered word
assign ftb_recover = ftb_pend_match & ~bpu_pred_vld;
assign ftb_match_ok = ftb_pend_match & bpu_pred_vld & bpu_steer_from_ch1 &
                      (bpu_ch1_target[`SCR1_XLEN-1:2] == ftb_pend_word_ff) |
                      (ftb_pend_match & bpu_steer_from_ch2 &
                      (bpu_ch2_target[`SCR1_XLEN-1:2] == ftb_pend_word_ff));
// suppress the response-time steer when the FTB already redirected to the
// same target (double-steer would discard correct-path words)
logic steer_suppress_ftb;
assign steer_suppress_ftb = ftb_pend_match & bpu_pred_vld & bpu_steer &
                            ((bpu_steer_from_ch1 & (bpu_ch1_target[`SCR1_XLEN-1:2] == ftb_pend_word_ff)) |
                             (bpu_steer_from_ch2 & (bpu_ch2_target[`SCR1_XLEN-1:2] == ftb_pend_word_ff)));
`ifndef SCR1_NEW_PC_REG
assign imem_addr_next = exu2ifu_pc_new_req_i ? exu2ifu_pc_new_i[`SCR1_XLEN-1:2] + imem_handshake_done
                      : bpu_steer & ~steer_suppress_ftb ? bpu_target[`SCR1_XLEN-1:2] + imem_handshake_done
                      : ftb_recover           ? bpu_resp_word_addr + 1'b1
`ifdef SCR1_BPU_FTB_EN
                      : ftb_steer             ? ftb_target_word
`endif
                      : &imem_addr_ff[5:2]   ? imem_addr_ff + imem_handshake_done
                                             : {imem_addr_ff[`SCR1_XLEN-1:6], imem_addr_ff[5:2] + imem_handshake_done};
`else // SCR1_NEW_PC_REG
assign imem_addr_next = exu2ifu_pc_new_req_i ? exu2ifu_pc_new_i[`SCR1_XLEN-1:2]
                      : bpu_steer & ~steer_suppress_ftb ? bpu_target[`SCR1_XLEN-1:2] + imem_handshake_done
                      : ftb_recover           ? bpu_resp_word_addr + 1'b1
`ifdef SCR1_BPU_FTB_EN
                      : ftb_steer             ? ftb_target_word
`endif
                      : &imem_addr_ff[5:2]   ? imem_addr_ff + imem_handshake_done
                                             : {imem_addr_ff[`SCR1_XLEN-1:6], imem_addr_ff[5:2] + imem_handshake_done};
`endif // SCR1_NEW_PC_REG
`else // ~SCR1_BPU_EN
`ifndef SCR1_NEW_PC_REG
assign imem_addr_next = exu2ifu_pc_new_req_i ? exu2ifu_pc_new_i[`SCR1_XLEN-1:2] + imem_handshake_done
                      : &imem_addr_ff[5:2]   ? imem_addr_ff + imem_handshake_done
                                             : {imem_addr_ff[`SCR1_XLEN-1:6], imem_addr_ff[5:2] + imem_handshake_done};
`else // SCR1_NEW_PC_REG
assign imem_addr_next = exu2ifu_pc_new_req_i ? exu2ifu_pc_new_i[`SCR1_XLEN-1:2]
                      : &imem_addr_ff[5:2]   ? imem_addr_ff + imem_handshake_done
                                             : {imem_addr_ff[`SCR1_XLEN-1:6], imem_addr_ff[5:2] + imem_handshake_done};
`endif // SCR1_NEW_PC_REG
`endif // SCR1_BPU_EN

// Pending IMEM transactions counter
//------------------------------------------------------------------------------
// Pending IMEM transactions occur if IFU request has been acknowledged, but
// response comes in the next cycle or later

assign imem_pnd_txns_cnt_upd  = imem_handshake_done ^ imem_resp_received;

always_ff @(posedge clk, negedge rst_n) begin
    if (~rst_n) begin
        imem_pnd_txns_cnt <= '0;
    end else if (imem_pnd_txns_cnt_upd) begin
        imem_pnd_txns_cnt <= imem_pnd_txns_cnt_next;
    end
end

assign imem_pnd_txns_cnt_next = imem_pnd_txns_cnt + (imem_handshake_done - imem_resp_received);
assign imem_pnd_txns_q_full   = &imem_pnd_txns_cnt;

// IMEM discard responses counter
//------------------------------------------------------------------------------
// IMEM instructions should be discarded in the following 2 cases:
// 1. New PC is requested by jump, branch, mret or other instruction
// 2. IMEM response was erroneous and not discarded
//
// In both cases the number of instructions to be discarded equals to the number
// of pending instructions.
// In the 1st case we don't need all the instructions that haven't been fetched
// yet, since the PC has changed.
// In the 2nd case, since the IMEM responce was erroneous there is no guarantee
// that subsequent IMEM instructions would be valid.

`ifdef SCR1_BPU_EN
assign imem_resp_discard_cnt_upd = exu2ifu_pc_new_req_i | imem_resp_er
                                 | (imem_resp_ok & imem_resp_discard_req) | bpu_steer;
`else // ~SCR1_BPU_EN
assign imem_resp_discard_cnt_upd = exu2ifu_pc_new_req_i | imem_resp_er
                                 | (imem_resp_ok & imem_resp_discard_req);
`endif // SCR1_BPU_EN

always_ff @(posedge clk, negedge rst_n) begin
    if (~rst_n) begin
        imem_resp_discard_cnt <= '0;
    end else if (imem_resp_discard_cnt_upd) begin
        imem_resp_discard_cnt <= imem_resp_discard_cnt_next;
    end
end

// v21: on bpu_steer the discard count is computed from the REGISTERED pending
// counter only: the steered word has just been consumed (resp), the steered
// request issued this cycle is NOT stale, so exactly imem_pnd_txns_cnt-1
// older responses must be dropped. This term is acyclic by construction.
`ifndef SCR1_NEW_PC_REG
`ifdef SCR1_BPU_EN
assign imem_resp_discard_cnt_next = exu2ifu_pc_new_req_i     ? imem_pnd_txns_cnt_next - imem_handshake_done
                                  : bpu_steer               ? (imem_pnd_txns_cnt - 1'b1)
                                  : imem_resp_er_discard_pnd ? imem_pnd_txns_cnt_next
                                                             : imem_resp_discard_cnt - 1'b1;
`else // ~SCR1_BPU_EN
assign imem_resp_discard_cnt_next = exu2ifu_pc_new_req_i     ? imem_pnd_txns_cnt_next - imem_handshake_done
                                  : imem_resp_er_discard_pnd ? imem_pnd_txns_cnt_next
                                                             : imem_resp_discard_cnt - 1'b1;
`endif // SCR1_BPU_EN
`else // SCR1_NEW_PC_REG
`ifdef SCR1_BPU_EN
assign imem_resp_discard_cnt_next = exu2ifu_pc_new_req_i | imem_resp_er_discard_pnd
                                  ? imem_pnd_txns_cnt_next
                                  : bpu_steer               ? (imem_pnd_txns_cnt - 1'b1)
                                  : imem_resp_discard_cnt - 1'b1;
`else // ~SCR1_BPU_EN
assign imem_resp_discard_cnt_next = exu2ifu_pc_new_req_i | imem_resp_er_discard_pnd
                                  ? imem_pnd_txns_cnt_next
                                  : imem_resp_discard_cnt - 1'b1;
`endif // SCR1_BPU_EN
`endif // SCR1_NEW_PC_REG

assign imem_vd_pnd_txns_cnt  = imem_pnd_txns_cnt - imem_resp_discard_cnt;
assign imem_resp_discard_req = |imem_resp_discard_cnt;

// IFU <-> IMEM interface output signals
//------------------------------------------------------------------------------

// v21 [IFU-STEER-SAME-CYCLE-REQ]: the steered request is issued in the SAME
// cycle as the response, replacing (not suppressing) the sequential request —
// a correctly predicted taken branch costs ZERO fetch bubbles.
// ifu2imem_addr_o selects the steered target on the steer cycle; if the ack
// does not come immediately, imem_addr_ff holds the target (updated in
// imem_addr_next) and the pending request keeps driving it.
`ifndef SCR1_NEW_PC_REG
`ifdef SCR1_BPU_EN
assign ifu2imem_req_o  = (exu2ifu_pc_new_req_i & ~imem_pnd_txns_q_full & ~pipe2ifu_stop_fetch_i)
                       | (ifu_fsm_fetch & ~imem_pnd_txns_q_full & q_has_free_slots `ifdef SCR1_NO_DEC_STAGE
                                                                     & ~instr_bypass_vd `endif // SCR1_NO_DEC_STAGE
                                                                    );
`else // ~SCR1_BPU_EN
assign ifu2imem_req_o  = (exu2ifu_pc_new_req_i & ~imem_pnd_txns_q_full & ~pipe2ifu_stop_fetch_i)
                       | (ifu_fsm_fetch        & ~imem_pnd_txns_q_full & q_has_free_slots);
`endif // SCR1_BPU_EN
`ifdef SCR1_BPU_EN
assign ifu2imem_addr_o = exu2ifu_pc_new_req_i ? {exu2ifu_pc_new_i[`SCR1_XLEN-1:2], 2'b00}
                       : bpu_steer            ? {bpu_target[`SCR1_XLEN-1:2], 2'b00}
                       : {imem_addr_ff, 2'b00};
`else // ~SCR1_BPU_EN
assign ifu2imem_addr_o = exu2ifu_pc_new_req_i
                       ? {exu2ifu_pc_new_i[`SCR1_XLEN-1:2], 2'b00}
                       : {imem_addr_ff, 2'b00};
`endif // SCR1_BPU_EN
`else // SCR1_NEW_PC_REG
`ifdef SCR1_BPU_EN
assign ifu2imem_req_o  = ifu_fsm_fetch & ~imem_pnd_txns_q_full & q_has_free_slots `ifdef SCR1_NO_DEC_STAGE
                       & ~instr_bypass_vd `endif // SCR1_NO_DEC_STAGE
                       ;
assign ifu2imem_addr_o = bpu_steer            ? {bpu_target[`SCR1_XLEN-1:2], 2'b00}
                       : {imem_addr_ff, 2'b00};
`else // ~SCR1_BPU_EN
assign ifu2imem_req_o  = ifu_fsm_fetch & ~imem_pnd_txns_q_full & q_has_free_slots;
assign ifu2imem_addr_o = {imem_addr_ff, 2'b00};
`endif // SCR1_BPU_EN
`endif // SCR1_NEW_PC_REG

assign ifu2imem_cmd_o  = SCR1_MEM_CMD_RD;

`ifdef SCR1_CLKCTRL_EN
assign ifu2pipe_imem_txns_pnd_o = |imem_pnd_txns_cnt;
`endif // SCR1_CLKCTRL_EN

//------------------------------------------------------------------------------
// IFU <-> IDU interface
//------------------------------------------------------------------------------
//
 // IFU <-> IDU interface consists of the following functional units:
 // - Instruction bypass type decoder
 // - IFU <-> IDU status signals
 // - Output instruction multiplexer
//

`ifdef SCR1_NO_DEC_STAGE

// Instruction bypass type decoder
//------------------------------------------------------------------------------

assign instr_bypass_vd  = (instr_bypass_type != SCR1_BYPASS_NONE);

always_comb begin
    instr_bypass_type    = SCR1_BYPASS_NONE;

    if (imem_resp_vd) begin
        if (q_is_empty) begin
            case (instr_type)
                SCR1_IFU_INSTR_RVC_NV,
                SCR1_IFU_INSTR_RVC_RVC,
                SCR1_IFU_INSTR_RVI_LO_RVC       : begin
                    instr_bypass_type = SCR1_BYPASS_RVC;
                end
                SCR1_IFU_INSTR_RVI_HI_RVI_LO    : begin
                    instr_bypass_type = SCR1_BYPASS_RVI_RDATA;
                end
                default : begin end
            endcase // instr_type
        end else if (q_has_1_ocpd_hw & q_head_is_rvi) begin
            if (instr_hi_rvi_lo_ff) begin
                instr_bypass_type = SCR1_BYPASS_RVI_RDATA_QUEUE;
            end
        end
    end // imem_resp_vd
end

// IFU <-> IDU interface status signals
//------------------------------------------------------------------------------

always_comb begin
    ifu2idu_vd_o         = 1'b0;
    ifu2idu_imem_err_o   = 1'b0;
    ifu2idu_err_rvi_hi_o = 1'b0;

    if (ifu_fsm_fetch | ~q_is_empty) begin
        if (instr_bypass_vd) begin
            ifu2idu_vd_o          = 1'b1;
            ifu2idu_imem_err_o    = (instr_bypass_type == SCR1_BYPASS_RVI_RDATA_QUEUE)
                                  ? (imem_resp_er | q_err_head)
                                  : imem_resp_er;
            ifu2idu_err_rvi_hi_o  = (instr_bypass_type == SCR1_BYPASS_RVI_RDATA_QUEUE) & imem_resp_er;
        end else if (~q_is_empty) begin
            if (q_has_1_ocpd_hw) begin
                ifu2idu_vd_o         = q_head_is_rvc | q_err_head;
                ifu2idu_imem_err_o   = q_err_head;
                ifu2idu_err_rvi_hi_o = ~q_err_head & q_head_is_rvi & q_err_next;
            end else begin
                ifu2idu_vd_o         = 1'b1;
                ifu2idu_imem_err_o   = q_err_head ? 1'b1 : (q_head_is_rvi & q_err_next);
            end
        end // ~q_is_empty
    end
`ifdef SCR1_DBG_EN
    if (hdu2ifu_pbuf_fetch_i) begin
        ifu2idu_vd_o          = hdu2ifu_pbuf_vd_i;
        ifu2idu_imem_err_o    = hdu2ifu_pbuf_err_i;
    end
`endif // SCR1_DBG_EN
end

// Output instruction multiplexer
//------------------------------------------------------------------------------

always_comb begin
    case (instr_bypass_type)
        SCR1_BYPASS_RVC            : begin
            ifu2idu_instr_o = `SCR1_IMEM_DWIDTH'(new_pc_unaligned_ff ? imem_rdata_hi
                                                                     : imem_rdata_lo);
        end
        SCR1_BYPASS_RVI_RDATA      : begin
            ifu2idu_instr_o = imem2ifu_rdata_i;
        end
        SCR1_BYPASS_RVI_RDATA_QUEUE: begin
            ifu2idu_instr_o = {imem_rdata_lo, q_data_head};
        end
        default                    : begin
            ifu2idu_instr_o = `SCR1_IMEM_DWIDTH'(q_head_is_rvc ? q_data_head
                                                               : {q_data_next, q_data_head});
        end
    endcase // instr_bypass_type
`ifdef SCR1_DBG_EN
    if (hdu2ifu_pbuf_fetch_i) begin
        ifu2idu_instr_o = `SCR1_IMEM_DWIDTH'({'0, hdu2ifu_pbuf_instr_i});
    end
`endif // SCR1_DBG_EN
end

// ==================== BPU PREDICTION OUTPUT ====================
`ifdef SCR1_BPU_EN
// BPU prediction output to IDU (3-stage pipeline with queue + bypass).
// CRITICAL-2 FIX [IFU-BPU-BYPASS-ROUTING]: Use live BPU signals for ALL bypass
// cases (including RVI_RDATA_QUEUE where queue is non-empty). The queue stores
// q_bpu_vld=0 for the first half of a straddling instruction (it was incomplete
// when written), but BPU now has the full instruction and a valid live prediction.
// Using stale q_bpu_vld_head caused false mispredictions on straddling branches.
// OPTIMIZATION: BPU steer bypass flag output.
// When an instruction is bypassed (queue was empty, sent directly from IMEM
// response to IDU) AND BPU steered (predicted taken), set this flag.
// EXU uses it to skip the IFU queue flush for correctly-predicted
// taken non-JALR branches, saving 1 cycle per correctly-predicted branch.
assign ifu2idu_bpu_steer_bypass_o = instr_bypass_vd & bpu_steer;

// v21 FIX [IFU-PRED-COMPLETION-SLOT]: a queue-read RVI instruction spans two
// halfword slots {lo=head, hi=next}; its prediction is stored in the
// COMPLETION (hi) slot. Reading the head slot unconditionally made every
// 32-bit branch arrive at EXU with bpu_vld=0 in queue-fed modes (measured
// 0.00% coverage on RV32IMC_MAX). RVC occupies a single slot = head.
logic ifu_bpu_sel_next;
assign ifu_bpu_sel_next = ~q_head_is_rvc;

always_comb begin
    if (instr_bypass_vd) begin
        // Bypass: instruction assembled NOW — use fresh BPU prediction.
        // Covers RVC (empty queue), RVI_RDATA (empty queue),
        // RVI_RDATA_QUEUE (1 entry in queue = straddling RVI).
        ifu2idu_bpu_pred_o = bpu_predict_taken;
        ifu2idu_bpu_vld_o  = bpu_pred_vld;
    end else if (~q_is_empty && ifu2idu_vd_o) begin
        // Queue read (no bypass): completion-slot selection (v21).
        ifu2idu_bpu_pred_o = ifu_bpu_sel_next ? q_bpu_pred_next : q_bpu_pred_head;
        ifu2idu_bpu_vld_o  = ifu_bpu_sel_next ? q_bpu_vld_next  : q_bpu_vld_head;
    end else begin
        // Fallback (should not occur in normal operation)
        ifu2idu_bpu_pred_o = bpu_predict_taken;
        ifu2idu_bpu_vld_o  = bpu_pred_vld;
    end
end
// v20: steer-proof output. bypass  -> live steer decision;
//      queue   -> str flag stored with the instruction completion slot (v21).
assign ifu2idu_bpu_str_o = instr_bypass_vd ? bpu_steer
                         : ifu_bpu_sel_next ? q_bpu_str_next : q_bpu_str_head;
assign ifu2idu_bpu_target_o = instr_bypass_vd ? bpu_target
                         : ifu_bpu_sel_next ? q_bpu_targ_next : q_bpu_targ_head;
`endif // SCR1_BPU_EN
// ================================================================

`else   // SCR1_NO_DEC_STAGE (4-stage)

// IFU <-> IDU interface status signals
//------------------------------------------------------------------------------

always_comb begin
    ifu2idu_vd_o          = 1'b0;
    ifu2idu_imem_err_o    = 1'b0;
    ifu2idu_err_rvi_hi_o  = 1'b0;
    if (~q_is_empty) begin
        if (q_has_1_ocpd_hw) begin
            ifu2idu_vd_o          = q_head_is_rvc | q_err_head;
            ifu2idu_imem_err_o    = q_err_head;
        end else begin
            ifu2idu_vd_o          = 1'b1;
            ifu2idu_imem_err_o    = q_err_head ? 1'b1 : (q_head_is_rvi & q_err_next);
            ifu2idu_err_rvi_hi_o  = ~q_err_head & q_head_is_rvi & q_err_next;
        end
    end // ~q_is_empty
`ifdef SCR1_DBG_EN
    if (hdu2ifu_pbuf_fetch_i) begin
        ifu2idu_vd_o          = hdu2ifu_pbuf_vd_i;
        ifu2idu_imem_err_o    = hdu2ifu_pbuf_err_i;
    end
`endif // SCR1_DBG_EN
end

// Output instruction multiplexer
//------------------------------------------------------------------------------

always_comb begin
    ifu2idu_instr_o = q_head_is_rvc ? `SCR1_IMEM_DWIDTH'(q_data_head)
                                    : {q_data_next, q_data_head};
`ifdef SCR1_DBG_EN
    if (hdu2ifu_pbuf_fetch_i) begin
        ifu2idu_instr_o = `SCR1_IMEM_DWIDTH'({'0, hdu2ifu_pbuf_instr_i});
    end
`endif // SCR1_DBG_EN
end

`ifdef SCR1_BPU_EN
// BPU prediction output to IDU (non-bypass mode, 4-stage).
// 4-stage: prediction always comes from the queue (already synchronized).
// v21 FIX [IFU-PRED-COMPLETION-SLOT]: RVI instructions read the COMPLETION
// (hi16) slot = q_*_next; RVC read their own slot = q_*_head. Reading the
// head slot unconditionally (v20) killed 100% of 32-bit branch coverage.
logic ifu_bpu_sel_next;
assign ifu_bpu_sel_next = ~q_head_is_rvc;

assign ifu2idu_bpu_pred_o = (~q_is_empty & ifu2idu_vd_o
`ifdef SCR1_DBG_EN
                            & ~hdu2ifu_pbuf_fetch_i
`endif // SCR1_DBG_EN
                            ) ? (ifu_bpu_sel_next ? q_bpu_pred_next : q_bpu_pred_head) : 1'b0;
assign ifu2idu_bpu_vld_o  = (~q_is_empty & ifu2idu_vd_o
`ifdef SCR1_DBG_EN
                            & ~hdu2ifu_pbuf_fetch_i
`endif // SCR1_DBG_EN
                            ) ? (ifu_bpu_sel_next ? q_bpu_vld_next  : q_bpu_vld_head ) : 1'b0;
assign ifu2idu_bpu_str_o  = (~q_is_empty & ifu2idu_vd_o
`ifdef SCR1_DBG_EN
                            & ~hdu2ifu_pbuf_fetch_i
`endif // SCR1_DBG_EN
                            ) ? (ifu_bpu_sel_next ? q_bpu_str_next  : q_bpu_str_head ) : 1'b0;
assign ifu2idu_bpu_target_o = (~q_is_empty & ifu2idu_vd_o
`ifdef SCR1_DBG_EN
                            & ~hdu2ifu_pbuf_fetch_i
`endif // SCR1_DBG_EN
                            ) ? (ifu_bpu_sel_next ? q_bpu_targ_next : q_bpu_targ_head) : '0;
// 2-stage-only flag (bypass does not exist without DEC stage)
assign ifu2idu_bpu_steer_bypass_o = 1'b0;
`endif // SCR1_BPU_EN

`endif  // SCR1_NO_DEC_STAGE


`ifdef SCR1_EARLY_BRANCH
// PC paired with the instruction accepted by IDU.  A BPU prediction is not
// treated as taken unless the new IFU metadata says fetch really steered.
assign ifu_idu_accept = ifu2idu_vd_o & idu2ifu_rdy_i;
assign ifu_idu_pc_advance = ifu_idu_accept
`ifdef SCR1_DBG_EN
                          & ~hdu2ifu_pbuf_fetch_i
`endif // SCR1_DBG_EN
                          ;

`ifdef SCR1_RVC_EXT
assign ifu_idu_instr_size = (ifu2idu_instr_o[1:0] == 2'b11)
                          ? `SCR1_XLEN'd4
                          : `SCR1_XLEN'd2;
`else
assign ifu_idu_instr_size = `SCR1_XLEN'd4;
`endif // SCR1_RVC_EXT

`ifdef SCR1_BPU_EN
assign ifu_idu_bpu_path_taken =
       ifu2idu_bpu_vld_o
     & ifu2idu_bpu_pred_o
     & (ifu2idu_bpu_str_o | ifu2idu_bpu_steer_bypass_o);
`endif // SCR1_BPU_EN

always_ff @(posedge clk, negedge rst_n) begin
    if (~rst_n) begin
        ifu_idu_pc_ff <= SCR1_RST_VECTOR;
    end else if (exu2ifu_pc_new_req_i) begin
        // pipe_top also routes IDU EARLY_BRANCH correction through this input.
        ifu_idu_pc_ff <= exu2ifu_pc_new_i;
    end else if (ifu_idu_pc_advance) begin
`ifdef SCR1_BPU_EN
        if (ifu_idu_bpu_path_taken)
            ifu_idu_pc_ff <= ifu2idu_bpu_target_o;
        else
`endif // SCR1_BPU_EN
            ifu_idu_pc_ff <= ifu_idu_pc_ff + ifu_idu_instr_size;
    end
end

assign ifu2idu_pc_o = ifu_idu_pc_ff;
`endif // SCR1_EARLY_BRANCH

`ifdef SCR1_DBG_EN
assign ifu2hdu_pbuf_rdy_o = idu2ifu_rdy_i;
`endif // SCR1_DBG_EN

`ifdef SCR1_TRGT_SIMULATION

//------------------------------------------------------------------------------
// Assertions
//------------------------------------------------------------------------------

// X checks

SCR1_SVA_IFU_XCHECK : assert property (
    @(negedge clk) disable iff (~rst_n)
    !$isunknown({imem2ifu_req_ack_i, idu2ifu_rdy_i, exu2ifu_pc_new_req_i})
    ) else $error("IFU Error: unknown values");

SCR1_SVA_IFU_XCHECK_REQ : assert property (
    @(negedge clk) disable iff (~rst_n)
    ifu2imem_req_o |-> !$isunknown({ifu2imem_addr_o, ifu2imem_cmd_o})
    ) else $error("IFU Error: unknown {ifu2imem_addr_o, ifu2imem_cmd_o}");

// Behavior checks

SCR1_SVA_IFU_DRC_UNDERFLOW : assert property (
    @(negedge clk) disable iff (~rst_n)
    ~imem_resp_discard_req |=> ~(imem_resp_discard_cnt == SCR1_TXN_CNT_W'('1))
    ) else $error("IFU Error: imem_resp_discard_cnt underflow");

SCR1_SVA_IFU_DRC_RANGE : assert property (
    @(negedge clk) disable iff (~rst_n)
    (imem_resp_discard_cnt >= 0) & (imem_resp_discard_cnt <= imem_pnd_txns_cnt)
    ) else $error("IFU Error: imem_resp_discard_cnt out of range");

SCR1_SVA_IFU_QUEUE_OVF : assert property (
    @(negedge clk) disable iff (~rst_n)
    (q_ocpd_h >= SCR1_IFU_Q_FREE_H_W'(SCR1_IFU_Q_SIZE_HALF-1)) |->
    ((q_ocpd_h == SCR1_IFU_Q_FREE_H_W'(SCR1_IFU_Q_SIZE_HALF-1)) ? (q_wr_size != SCR1_IFU_QUEUE_WR_FULL)
                                                                : (q_wr_size == SCR1_IFU_QUEUE_WR_NONE))
    ) else $error("IFU Error: queue overflow");

SCR1_SVA_IFU_IMEM_ERR_BEH : assert property (
    @(negedge clk) disable iff (~rst_n)
    (imem_resp_er & ~imem_resp_discard_req & ~exu2ifu_pc_new_req_i) |=>
    (ifu_fsm_curr == SCR1_IFU_FSM_IDLE) & (imem_resp_discard_cnt == imem_pnd_txns_cnt)
    ) else $error("IFU Error: incorrect behavior after memory error");

SCR1_SVA_IFU_NEW_PC_REQ_BEH : assert property (
    @(negedge clk) disable iff (~rst_n)
    exu2ifu_pc_new_req_i |=> q_is_empty
    ) else $error("IFU Error: incorrect behavior after exu2ifu_pc_new_req_i");

SCR1_SVA_IFU_IMEM_ADDR_ALIGNED : assert property (
    @(negedge clk) disable iff (~rst_n)
    ifu2imem_req_o |-> ~|ifu2imem_addr_o[1:0]
    ) else $error("IFU Error: unaligned IMEM access");

SCR1_SVA_IFU_STOP_FETCH : assert property (
    @(negedge clk) disable iff (~rst_n)
    pipe2ifu_stop_fetch_i |=> (ifu_fsm_curr == SCR1_IFU_FSM_IDLE)
    ) else $error("IFU Error: fetch not stopped");

SCR1_SVA_IFU_IMEM_FAULT_RVI_HI : assert property (
    @(negedge clk) disable iff (~rst_n)
    ifu2idu_err_rvi_hi_o |-> ifu2idu_imem_err_o
    ) else $error("IFU Error: ifu2idu_imem_err_o == 0");

`endif // SCR1_TRGT_SIMULATION

`ifdef SCR1_BPU_EN
// v17 DEBUG: Enhanced BPU steer and queue state trace
always_ff @(posedge clk) begin
    if (bpu_steer) begin
    end
    if (exu2ifu_pc_new_req_i) begin
    end
    if (bpu_predict_taken & ~bpu_steer) begin
    end
end
`endif // SCR1_BPU_EN

endmodule : scr1_pipe_ifu