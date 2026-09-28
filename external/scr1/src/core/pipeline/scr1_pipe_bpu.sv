/// Copyright (c) 2026. See LICENSE for details.
/// @file       <scr1_pipe_bpu.sv>
/// @brief      Branch Prediction Unit (BPU)
///
/// v19 (CoreMark optimization iteration):
///   - RAS: 8 entries, count-based empty/full tracking (fixes wrap-around
///     bug of v18 where ras_empty=(tos==0) broke after 4 pushes).
///   - BHT: 1024 entries x {valid, tag[1:0], ctr[1:0]}. Partial tag PC[13:12]
///     kills most aliasing; valid-bit scheme removes the 1024-entry reset
///     loop (lazy reset) -- smaller reset tree, better FPGA timing.
///   - Dual prediction channels: ch1 = lower halfword / straddled RVI /
///     NV-upper-RVC; ch2 = upper-halfword RVC (C.J/C.JAL/C.Bxx/C.JR).
///     Previously only the lower halfword was ever predicted.
///   - Single 32-bit adder per channel (imm mux -> add) instead of 4 adders.
///   - FTB (Fetch Target Buffer): 32-entry request-time redirect structure
///     (feature-gated: SCR1_BPU_FTB_EN). Target is validated by EXU via
///     predicted-target compare, so stale/aliased FTB entries can only cost
///     a redirect, never correctness.
///   - RAS prediction for JALR rs1=ra rd=x0 and C.JR rs1=ra (returns).
///
/// This module is instantiated inside scr1_pipe_ifu.

`include "scr1_arch_description.svh"
`include "scr1_riscv_isa_decoding.svh"

module scr1_pipe_bpu (
    // Clock and reset (for BHT training and RAS)
    input  logic                                clk,
    input  logic                                rst_n,

    // Channel 1 predict interface (combinational)
    // Covers: lower-halfword instruction, straddled RVI (lo16 in queue),
    //         first instruction after unaligned new_pc (upper halfword RVC).
    input  logic [`SCR1_XLEN-1:0]               ch1_pc_i,
    input  logic [`SCR1_IMEM_DWIDTH-1:0]        ch1_instr_i,
    input  logic                                ch1_vld_i,
    output logic                                ch1_pred_o,         // predicted taken
    output logic [`SCR1_XLEN-1:0]               ch1_target_o,       // predicted target
    output logic                                ch1_predvld_o,      // prediction valid (decode-based)

    // Channel 2 predict interface (combinational)
    // Covers: upper-halfword complete RVC instruction.
    input  logic [`SCR1_XLEN-1:0]               ch2_pc_i,
    input  logic [`SCR1_IMEM_DWIDTH-1:0]        ch2_instr_i,
    input  logic                                ch2_vld_i,
    output logic                                ch2_pred_o,
    output logic [`SCR1_XLEN-1:0]               ch2_target_o,
    output logic                                ch2_predvld_o,

    // FTB request-time lookup (word-granular, combinational)
`ifdef SCR1_BPU_FTB_EN
    input  logic [`SCR1_XLEN-1:2]               ftb_idx_pc_i,       // word addr of the fetch request
    output logic                                ftb_hit_o,
    output logic [`SCR1_XLEN-1:2]               ftb_target_o,
`endif // SCR1_BPU_FTB_EN

    // Flush interface (fence.i): invalidates BHT and FTB, resets RAS
    input  logic                                bpu_flush_i,

    // BHT training interface (sequential, from EXU commit)
    input  logic                                bpu_train_vld_i,
    input  logic [`SCR1_XLEN-1:0]               bpu_train_pc_i,
    input  logic                                bpu_train_taken_i,
    input  logic [`SCR1_XLEN-1:0]               bpu_train_target_i, // resolved target (for FTB)

    // RAS training interface (sequential, from EXU commit)
    input  logic                                bpu_train_push_i,       // call: JAL/JALR/C.JAL/C.JALR with rd=ra
    input  logic [`SCR1_XLEN-1:0]               bpu_train_push_addr_i,  // return address
    input  logic                                bpu_train_is_return_i   // ret: JALR ra/x0 or C.JR ra
);

//------------------------------------------------------------------------------
// Parameters
//------------------------------------------------------------------------------

localparam int unsigned BHT_ENTRIES   = 1024;
localparam int unsigned BHT_IDX_WIDTH = $clog2(BHT_ENTRIES);    // 10: PC[11:2]

// RAS: 8 entries with count-based occupancy (fixes v18 wrap bug)
localparam int unsigned RAS_DEPTH      = 8;
localparam int unsigned RAS_PTR_WIDTH  = $clog2(RAS_DEPTH);     // 3
localparam int unsigned RAS_CNT_WIDTH  = RAS_PTR_WIDTH + 1;     // 4: 0..8

// FTB: 32 entries. idx = PC[6:2], tag = PC[11:7]
`ifdef SCR1_BPU_FTB_EN
localparam int unsigned FTB_ENTRIES    = 32;
localparam int unsigned FTB_IDX_WIDTH  = $clog2(FTB_ENTRIES);   // 5
localparam int unsigned FTB_TAG_WIDTH  = 5;                     // PC[11:7]
`endif

//------------------------------------------------------------------------------
// BHT: Branch History Table (tagged, 2-bit saturating counters)
//------------------------------------------------------------------------------

logic [BHT_ENTRIES-1:0]             bht_valid;
logic [BHT_ENTRIES-1:0][1:0]        bht_tag;                    // PC[13:12]
logic [BHT_ENTRIES-1:0][1:0]        bht_ctr;

logic [BHT_IDX_WIDTH-1:0]           train_idx;
logic [1:0]                         train_tag;                  // train_pc[13:12]
logic [1:0]                         train_wr_ctr;               // counter value to be written this cycle
logic                               train_hit;                  // training entry currently hit

function automatic logic [1:0] sat_inc (input logic [1:0] val);
    sat_inc = (val == 2'b11) ? 2'b11 : (val + 1'b1);
endfunction

function automatic logic [1:0] sat_dec (input logic [1:0] val);
    sat_dec = (val == 2'b00) ? 2'b00 : (val - 1'b1);
endfunction

assign train_idx  = bpu_train_pc_i[BHT_IDX_WIDTH+1:2];
assign train_tag  = bpu_train_pc_i[13:12];
assign train_hit  = bht_valid[train_idx] & (bht_tag[train_idx] == train_tag);

// Allocation policy: on miss, allocate weakly taken/not-taken
assign train_wr_ctr = train_hit ? (bpu_train_taken_i ? sat_inc(bht_ctr[train_idx])
                                                     : sat_dec(bht_ctr[train_idx]))
                                : (bpu_train_taken_i ? 2'b10 : 2'b01);

// BHT training + flush (no giant reset loop: valid vector is reset lazily)
always_ff @(posedge clk, negedge rst_n) begin
    if (~rst_n) begin
        bht_valid <= '0;
    end else if (bpu_train_vld_i) begin
        bht_valid[train_idx] <= 1'b1;
        bht_tag [train_idx]  <= train_tag;
        bht_ctr [train_idx]  <= train_wr_ctr;
    end
end

//------------------------------------------------------------------------------
// Prediction channel helper: BHT lookup with read-during-write bypass
//------------------------------------------------------------------------------
// Each channel reads the BHT asynchronously (flop/LUTRAM array). If training
// hits the same index this cycle, the updated counter value is used.

function automatic logic chn_taken (
    input logic        vld,         // instruction valid (decode-level)
    input logic [BHT_IDX_WIDTH-1:0] idx,
    input logic [1:0]  tag
);
    logic [1:0] ctr_eff;
    logic       hit;
    begin
        hit = (bht_valid[idx] & (bht_tag[idx] == tag))
              | (bpu_train_vld_i & (train_idx == idx) & (train_tag == tag));
        ctr_eff = (bpu_train_vld_i & (train_idx == idx)) ? train_wr_ctr : bht_ctr[idx];
        chn_taken = vld & hit & ctr_eff[1];
    end
endfunction

//------------------------------------------------------------------------------
// Channel 1: lower halfword / straddled RVI / NV upper RVC
//------------------------------------------------------------------------------
// Instruction is delivered fully assembled by IFU. 32-bit opcodes always have
// bits[1:0]==2'b11, RVC never does, so 32-bit decoders cannot false-fire on
// RVC-only channels.

logic [15:0]                        ch1_lo;
logic                               ch1_is_rvc;
logic                               ch1_is_rvi_b;
logic                               ch1_is_rvi_jal;
logic                               ch1_is_rvi_jalr;
logic                               ch1_is_rvi_ret;     // JALR rs1=ra rd=x0
logic                               ch1_is_rvc_branch;  // C.BEQZ/C.BNEZ
logic                               ch1_is_rvc_jump;    // C.J/C.JAL
logic                               ch1_is_rvc_ret;     // C.JR rs1=ra
logic                               ch1_is_return;
logic [`SCR1_XLEN-1:0]              ch1_imm;            // sign-extended delta
logic [`SCR1_XLEN-1:0]              ch1_target;
logic                               ch1_ras_taken;

assign ch1_lo           = ch1_instr_i[15:0];
assign ch1_is_rvc       = (ch1_lo[1:0] != 2'b11);
assign ch1_is_rvi_b     = ~ch1_is_rvc & (ch1_lo[6:0] == 7'h63);
assign ch1_is_rvi_jal   = ~ch1_is_rvc & (ch1_lo[6:0] == 7'h6F);
assign ch1_is_rvi_jalr  = ~ch1_is_rvc & (ch1_lo[6:0] == 7'h67);
// rs1 is instruction[19:15], which is outside the 16-bit ch1_lo slice.
assign ch1_is_rvi_ret   = ch1_is_rvi_jalr & (ch1_instr_i[19:15] == 5'd1) & (ch1_lo[11:7] == 5'd0);
assign ch1_is_rvc_branch= ch1_is_rvc & (ch1_lo[1:0] == 2'b01)
                        & ((ch1_lo[15:13] == 3'b110) | (ch1_lo[15:13] == 3'b111));
assign ch1_is_rvc_jump  = ch1_is_rvc & ((ch1_lo[15:13] == 3'b101) | (ch1_lo[15:13] == 3'b001))
                          & (ch1_lo[1:0] == 2'b10);
assign ch1_is_rvc_ret   = (ch1_lo[1:0] == 2'b10) & (ch1_lo[15:12] == 4'b1000) & (ch1_lo[11:7] == 5'd1);
assign ch1_is_return    = ch1_is_rvi_ret | ch1_is_rvc_ret;

// B-type immediate
logic [`SCR1_XLEN-1:0] ch1_imm_b;
assign ch1_imm_b[12]    = ch1_instr_i[31];
assign ch1_imm_b[11]    = ch1_instr_i[7];
assign ch1_imm_b[10:5]  = ch1_instr_i[30:25];
assign ch1_imm_b[4:1]   = ch1_instr_i[11:8];
assign ch1_imm_b[0]     = 1'b0;

// J-type immediate
logic [`SCR1_XLEN-1:0] ch1_imm_j;
assign ch1_imm_j[20]    = ch1_instr_i[31];
assign ch1_imm_j[10:1]  = ch1_instr_i[30:21];
assign ch1_imm_j[11]    = ch1_instr_i[20];
assign ch1_imm_j[19:12] = ch1_instr_i[19:12];
assign ch1_imm_j[0]     = 1'b0;

// RVC branch immediate (C.BEQZ/C.BNEZ)
logic [8:0] ch1_imm_cb;
assign ch1_imm_cb[8]   = ch1_lo[12];
assign ch1_imm_cb[7:6] = ch1_lo[6:5];
assign ch1_imm_cb[5]   = ch1_lo[2];
assign ch1_imm_cb[4:3] = ch1_lo[11:10];
assign ch1_imm_cb[2:1] = ch1_lo[4:3];
assign ch1_imm_cb[0]   = 1'b0;

// RVC jump immediate (C.J/C.JAL)
logic [11:0] ch1_imm_cj;
assign ch1_imm_cj[11]  = ch1_lo[12];
assign ch1_imm_cj[4]   = ch1_lo[11];
assign ch1_imm_cj[9:8] = ch1_lo[10:9];
assign ch1_imm_cj[10]  = ch1_lo[8];
assign ch1_imm_cj[6]   = ch1_lo[7];
assign ch1_imm_cj[7]   = ch1_lo[6];
assign ch1_imm_cj[3:1] = ch1_lo[5:3];
assign ch1_imm_cj[5]   = ch1_lo[2];
assign ch1_imm_cj[0]   = 1'b0;

// single delta mux -> single adder per channel (timing: adder after small mux)
// v21 FIX [BPU-IMM-SLICE]: the concatenation must use the immediate FIELD
// slice, not the whole 32-bit immediate vector. Using the full vector made
// the RHS 51 bits and destroyed sign extension (negative branch offsets got
// zero-extended), so every predicted taken-target with a backward offset was
// garbage - the steer fetched a wrong path and the EXU flush-skip
// (predicted_target == resolved_target) could never match.
always_comb begin
    case (1'b1)
        ch1_is_rvi_b     : ch1_imm = {{(`SCR1_XLEN-13){ch1_imm_b[12]}}, ch1_imm_b[12:0]};
        ch1_is_rvi_jal   : ch1_imm = {{(`SCR1_XLEN-21){ch1_imm_j[20]}}, ch1_imm_j[20:0]};
        ch1_is_rvc_branch: ch1_imm = {{(`SCR1_XLEN-9){ch1_imm_cb[8]}},  ch1_imm_cb[8:0]};
        ch1_is_rvc_jump  : ch1_imm = {{(`SCR1_XLEN-12){ch1_imm_cj[11]}}, ch1_imm_cj[11:0]};
        default          : ch1_imm = `SCR1_XLEN'd4;
    endcase
end

assign ch1_target = ch1_pc_i + ch1_imm;

// RAS peek
logic [`SCR1_XLEN-1:0]              ras_top;
logic                               ras_vld;
assign ras_vld  = (ras_cnt != '0);
assign ras_top  = ras_stack[ras_cnt[RAS_PTR_WIDTH-1:0] - 1'b1];

assign ch1_ras_taken = ch1_is_return & ras_vld;

assign ch1_predvld_o = ch1_vld_i & ( ch1_is_rvi_b | ch1_is_rvi_jal | ch1_is_rvc_branch
                                   | ch1_is_rvc_jump | ch1_is_return);
assign ch1_pred_o    = ch1_predvld_o & ( ch1_is_rvi_jal | ch1_is_rvc_jump
                                       | ch1_ras_taken
                                       | ((ch1_is_rvi_b | ch1_is_rvc_branch)
                                          & chn_taken(ch1_vld_i, ch1_pc_i[BHT_IDX_WIDTH+1:2], ch1_pc_i[13:12])));
assign ch1_target_o  = ch1_ras_taken ? ras_top : ch1_target;

//------------------------------------------------------------------------------
// Channel 2: upper-halfword complete RVC only
//------------------------------------------------------------------------------
// IFU guarantees ch2_instr_i[15:0] is a complete RVC instruction.

logic [15:0]                        ch2_lo;
logic                               ch2_is_rvc_branch;
logic                               ch2_is_rvc_jump;
logic                               ch2_is_rvc_ret;
logic                               ch2_is_return;
logic [`SCR1_XLEN-1:0]              ch2_imm;
logic [`SCR1_XLEN-1:0]              ch2_target;
logic                               ch2_ras_taken;

assign ch2_lo            = ch2_instr_i[15:0];
assign ch2_is_rvc_branch = (ch2_lo[1:0] == 2'b01) & ((ch2_lo[15:13] == 3'b110) | (ch2_lo[15:13] == 3'b111));
assign ch2_is_rvc_jump   = (ch2_lo[1:0] == 2'b10) & ((ch2_lo[15:13] == 3'b101) | (ch2_lo[15:13] == 3'b001));
assign ch2_is_rvc_ret    = (ch2_lo[1:0] == 2'b10) & (ch2_lo[15:12] == 4'b1000) & (ch2_lo[11:7] == 5'd1);
assign ch2_is_return     = ch2_is_rvc_ret;

logic [8:0]  ch2_imm_cb;
assign ch2_imm_cb[8]   = ch2_lo[12];
assign ch2_imm_cb[7:6] = ch2_lo[6:5];
assign ch2_imm_cb[5]   = ch2_lo[2];
assign ch2_imm_cb[4:3] = ch2_lo[11:10];
assign ch2_imm_cb[2:1] = ch2_lo[4:3];
assign ch2_imm_cb[0]   = 1'b0;

logic [11:0] ch2_imm_cj;
assign ch2_imm_cj[11]  = ch2_lo[12];
assign ch2_imm_cj[4]   = ch2_lo[11];
assign ch2_imm_cj[9:8] = ch2_lo[10:9];
assign ch2_imm_cj[10]  = ch2_lo[8];
assign ch2_imm_cj[6]   = ch2_lo[7];
assign ch2_imm_cj[7]   = ch2_lo[6];
assign ch2_imm_cj[3:1] = ch2_lo[5:3];
assign ch2_imm_cj[5]   = ch2_lo[2];
assign ch2_imm_cj[0]   = 1'b0;

always_comb begin
    case (1'b1)
        ch2_is_rvc_branch: ch2_imm = {{(`SCR1_XLEN-9){ch2_imm_cb[8]}},  ch2_imm_cb[8:0]};
        ch2_is_rvc_jump  : ch2_imm = {{(`SCR1_XLEN-12){ch2_imm_cj[11]}}, ch2_imm_cj[11:0]};
        default          : ch2_imm = `SCR1_XLEN'd2;
    endcase
end

assign ch2_target   = ch2_pc_i + ch2_imm;
assign ch2_ras_taken= ch2_is_return & ras_vld;

assign ch2_predvld_o= ch2_vld_i & (ch2_is_rvc_branch | ch2_is_rvc_jump | ch2_is_return);
assign ch2_pred_o   = ch2_predvld_o & ( ch2_is_rvc_jump | ch2_ras_taken
                                      | (ch2_is_rvc_branch
                                         & chn_taken(ch2_vld_i, ch2_pc_i[BHT_IDX_WIDTH+1:2], ch2_pc_i[13:12])));
assign ch2_target_o = ch2_ras_taken ? ras_top : ch2_target;

//------------------------------------------------------------------------------
// FTB: Fetch Target Buffer (request-time redirect for zero-bubble taken branches)
//------------------------------------------------------------------------------
// Trained on taken, non-JALR branches whose start address has pc[1]==0
// (self-contained in the fetched word). Straddling and upper-halfword
// branches are excluded: the response-time steering covers them.

`ifdef SCR1_BPU_FTB_EN
logic [FTB_ENTRIES-1:0]                 ftb_valid;
logic [FTB_ENTRIES-1:0][FTB_TAG_WIDTH-1:0] ftb_tag;
logic [FTB_ENTRIES-1:0][`SCR1_XLEN-3:0] ftb_target;

logic [FTB_IDX_WIDTH-1:0]               ftb_train_idx;
logic [FTB_TAG_WIDTH-1:0]               ftb_train_tag;
logic [FTB_IDX_WIDTH-1:0]               ftb_pred_idx;
logic [FTB_TAG_WIDTH-1:0]               ftb_pred_tag;
logic                                   ftb_train_sel;

assign ftb_train_idx  = bpu_train_pc_i[FTB_IDX_WIDTH+1:2];
assign ftb_train_tag  = bpu_train_pc_i[FTB_IDX_WIDTH+FTB_TAG_WIDTH+1:FTB_IDX_WIDTH+2];
// ftb_idx_pc_i keeps original PC bit numbering [XLEN-1:2]. Use PC[6:2]/PC[11:7].
assign ftb_pred_idx   = ftb_idx_pc_i[FTB_IDX_WIDTH+1:2];
assign ftb_pred_tag   = ftb_idx_pc_i[FTB_IDX_WIDTH+FTB_TAG_WIDTH+1:FTB_IDX_WIDTH+2];
assign ftb_train_sel  = bpu_train_vld_i & bpu_train_taken_i & (bpu_train_pc_i[1] == 1'b0);

always_ff @(posedge clk, negedge rst_n) begin
    if (~rst_n) begin
        ftb_valid <= '0;
    end else if (bpu_flush_i) begin
        ftb_valid <= '0;
    end else if (ftb_train_sel) begin
        ftb_valid[ftb_train_idx] <= 1'b1;
        ftb_tag  [ftb_train_idx] <= ftb_train_tag;
        ftb_target[ftb_train_idx]<= bpu_train_target_i;
    end
end

assign ftb_hit_o    = ftb_valid[ftb_pred_idx] & (ftb_tag[ftb_pred_idx] == ftb_pred_tag);
assign ftb_target_o = ftb_target[ftb_pred_idx];
`endif // SCR1_BPU_FTB_EN

//------------------------------------------------------------------------------
// Return Address Stack (RAS): 8 entries, count-based occupancy
//------------------------------------------------------------------------------
// Push at commit (calls), pop at commit (returns), peek at prediction.
// cnt-based occupancy is robust to depth wrapping (v18 bug fix: tos==0
// was misread as "empty" after 4 pushes without pops).

logic [RAS_DEPTH-1:0][`SCR1_XLEN-1:0]   ras_stack;
logic [RAS_CNT_WIDTH-1:0]               ras_cnt;

always_ff @(posedge clk, negedge rst_n) begin
    if (~rst_n) begin
        ras_cnt   <= '0;
    end else if (bpu_flush_i) begin
        ras_cnt   <= '0;
    end else if (bpu_train_push_i & ~bpu_train_is_return_i) begin
        // Push (single-issue commit: push+pop cannot collide)
        ras_stack[ras_cnt[RAS_PTR_WIDTH-1:0]] <= bpu_train_push_addr_i;
        if (ras_cnt != RAS_DEPTH[RAS_CNT_WIDTH-1:0])
            ras_cnt <= ras_cnt + 1'b1;
        // full: top is overwritten in place, count stays at RAS_DEPTH
    end else if (bpu_train_is_return_i & ras_vld) begin
        ras_cnt <= ras_cnt - 1'b1;
    end
end

endmodule : scr1_pipe_bpu
