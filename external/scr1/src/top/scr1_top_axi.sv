/// Copyright by Syntacore LLC © 2016-2020. See LICENSE for details
/// @file       <scr1_top_axi.sv>
/// @brief      SCR1 AXI top
///

`include "scr1_arch_description.svh"
`include "scr1_memif.svh"
`ifdef SCR1_IPIC_EN
`include "scr1_ipic.svh"
`endif // SCR1_IPIC_EN

`ifdef SCR1_TCM_EN
 `define SCR1_IMEM_ROUTER_EN
`endif // SCR1_TCM_EN

module scr1_top_axi #(
    parameter int unsigned SCR1_ICACHE_LINE_BYTES = 8,
    parameter int unsigned SCR1_DCACHE_LINE_BYTES = 8,
    parameter bit SCR1_ICACHE_AXI_BURST_ENABLE = 1'b1,
    parameter bit SCR1_DCACHE_AXI_BURST_ENABLE = 1'b1,
    parameter int unsigned SCR1_AXI_MAX_READ_BURST_BEATS = 8,
`ifdef SCR1_DCACHE_VICTIM_EN
    parameter int unsigned SCR1_DCACHE_VICTIM_LINES = 4,
`endif
    // 1: no-write-allocate on cacheable STORE miss; 0: legacy write-allocate.
    parameter bit SCR1_DCACHE_NO_WRITE_ALLOCATE = 1'b1
) (
    // Control
    input   logic                                   pwrup_rst_n,            // Power-Up Reset
    input   logic                                   rst_n,                  // Regular Reset signal
    input   logic                                   cpu_rst_n,              // CPU Reset (Core Reset)
    input   logic                                   test_mode,              // Test mode
    input   logic                                   test_rst_n,             // Test mode's reset
    input   logic                                   clk,                    // System clock
    input   logic                                   rtc_clk,                // Real-time clock

    // Lifecycle memory admission / drain control
    input   logic                                   master_enable_i,         // 1: accept new CPU memory requests
    output  logic                                   memory_idle_o,           // all accepted CPU/cache/AXI work drained
    output  logic                                   cpu_reset_applied_o,     // synchronized CPU reset is active
`ifdef SCR1_DBG_EN
    output  logic                                   sys_rst_n_o,            // External System Reset output
                                                                            //   (for the processor cluster's components or
                                                                            //    external SOC (could be useful in small
                                                                            //    SCR-core-centric SOCs))
    output  logic                                   sys_rdc_qlfy_o,         // System-to-External SOC Reset Domain Crossing Qualifier
`endif // SCR1_DBG_EN

    // Fuses
    input   logic [`SCR1_XLEN-1:0]                  fuse_mhartid,           // Hart ID
`ifdef SCR1_DBG_EN
    input   logic [31:0]                            fuse_idcode,            // TAPC IDCODE
`endif // SCR1_DBG_EN

    // IRQ
`ifdef SCR1_IPIC_EN
    input   logic [SCR1_IRQ_LINES_NUM-1:0]          irq_lines,              // IRQ lines to IPIC
`else // SCR1_IPIC_EN
    input   logic                                   ext_irq,                // External IRQ input
`endif // SCR1_IPIC_EN
    input   logic                                   soft_irq,               // Software IRQ input

`ifdef SCR1_DBG_EN
    // -- JTAG I/F
    input   logic                                   trst_n,
    input   logic                                   tck,
    input   logic                                   tms,
    input   logic                                   tdi,
    output  logic                                   tdo,
    output  logic                                   tdo_en,
`endif // SCR1_DBG_EN

    // Instruction Memory Interface
    output  logic [3:0]                             io_axi_imem_awid,
    output  logic [31:0]                            io_axi_imem_awaddr,
    output  logic [7:0]                             io_axi_imem_awlen,
    output  logic [2:0]                             io_axi_imem_awsize,
    output  logic [1:0]                             io_axi_imem_awburst,
    output  logic                                   io_axi_imem_awlock,
    output  logic [3:0]                             io_axi_imem_awcache,
    output  logic [2:0]                             io_axi_imem_awprot,
    output  logic [3:0]                             io_axi_imem_awregion,
    output  logic [3:0]                             io_axi_imem_awuser,
    output  logic [3:0]                             io_axi_imem_awqos,
    output  logic                                   io_axi_imem_awvalid,
    input   logic                                   io_axi_imem_awready,
    output  logic [31:0]                            io_axi_imem_wdata,
    output  logic [3:0]                             io_axi_imem_wstrb,
    output  logic                                   io_axi_imem_wlast,
    output  logic [3:0]                             io_axi_imem_wuser,
    output  logic                                   io_axi_imem_wvalid,
    input   logic                                   io_axi_imem_wready,
    input   logic [3:0]                             io_axi_imem_bid,
    input   logic [1:0]                             io_axi_imem_bresp,
    input   logic                                   io_axi_imem_bvalid,
    input   logic [3:0]                             io_axi_imem_buser,
    output  logic                                   io_axi_imem_bready,
    output  logic [3:0]                             io_axi_imem_arid,
    output  logic [31:0]                            io_axi_imem_araddr,
    output  logic [7:0]                             io_axi_imem_arlen,
    output  logic [2:0]                             io_axi_imem_arsize,
    output  logic [1:0]                             io_axi_imem_arburst,
    output  logic                                   io_axi_imem_arlock,
    output  logic [3:0]                             io_axi_imem_arcache,
    output  logic [2:0]                             io_axi_imem_arprot,
    output  logic [3:0]                             io_axi_imem_arregion,
    output  logic [3:0]                             io_axi_imem_aruser,
    output  logic [3:0]                             io_axi_imem_arqos,
    output  logic                                   io_axi_imem_arvalid,
    input   logic                                   io_axi_imem_arready,
    input   logic [3:0]                             io_axi_imem_rid,
    input   logic [31:0]                            io_axi_imem_rdata,
    input   logic [1:0]                             io_axi_imem_rresp,
    input   logic                                   io_axi_imem_rlast,
    input   logic [3:0]                             io_axi_imem_ruser,
    input   logic                                   io_axi_imem_rvalid,
    output  logic                                   io_axi_imem_rready,

    // Data Memory Interface
    output  logic [3:0]                             io_axi_dmem_awid,
    output  logic [31:0]                            io_axi_dmem_awaddr,
    output  logic [7:0]                             io_axi_dmem_awlen,
    output  logic [2:0]                             io_axi_dmem_awsize,
    output  logic [1:0]                             io_axi_dmem_awburst,
    output  logic                                   io_axi_dmem_awlock,
    output  logic [3:0]                             io_axi_dmem_awcache,
    output  logic [2:0]                             io_axi_dmem_awprot,
    output  logic [3:0]                             io_axi_dmem_awregion,
    output  logic [3:0]                             io_axi_dmem_awuser,
    output  logic [3:0]                             io_axi_dmem_awqos,
    output  logic                                   io_axi_dmem_awvalid,
    input   logic                                   io_axi_dmem_awready,
    output  logic [31:0]                            io_axi_dmem_wdata,
    output  logic [3:0]                             io_axi_dmem_wstrb,
    output  logic                                   io_axi_dmem_wlast,
    output  logic [3:0]                             io_axi_dmem_wuser,
    output  logic                                   io_axi_dmem_wvalid,
    input   logic                                   io_axi_dmem_wready,
    input   logic [3:0]                             io_axi_dmem_bid,
    input   logic [1:0]                             io_axi_dmem_bresp,
    input   logic                                   io_axi_dmem_bvalid,
    input   logic [3:0]                             io_axi_dmem_buser,
    output  logic                                   io_axi_dmem_bready,
    output  logic [3:0]                             io_axi_dmem_arid,
    output  logic [31:0]                            io_axi_dmem_araddr,
    output  logic [7:0]                             io_axi_dmem_arlen,
    output  logic [2:0]                             io_axi_dmem_arsize,
    output  logic [1:0]                             io_axi_dmem_arburst,
    output  logic                                   io_axi_dmem_arlock,
    output  logic [3:0]                             io_axi_dmem_arcache,
    output  logic [2:0]                             io_axi_dmem_arprot,
    output  logic [3:0]                             io_axi_dmem_arregion,
    output  logic [3:0]                             io_axi_dmem_aruser,
    output  logic [3:0]                             io_axi_dmem_arqos,
    output  logic                                   io_axi_dmem_arvalid,
    input   logic                                   io_axi_dmem_arready,
    input   logic [3:0]                             io_axi_dmem_rid,
    input   logic [31:0]                            io_axi_dmem_rdata,
    input   logic [1:0]                             io_axi_dmem_rresp,
    input   logic                                   io_axi_dmem_rlast,
    input   logic [3:0]                             io_axi_dmem_ruser,
    input   logic                                   io_axi_dmem_rvalid,
    output  logic                                   io_axi_dmem_rready
);

//-------------------------------------------------------------------------------
// Local parameters
//-------------------------------------------------------------------------------
localparam int unsigned SCR1_CLUSTER_TOP_RST_SYNC_STAGES_NUM            = 2;

//-------------------------------------------------------------------------------
// Local signal declaration
//-------------------------------------------------------------------------------
// Reset logic
logic                                               pwrup_rst_n_sync;
logic                                               rst_n_sync;
logic                                               cpu_rst_n_sync;
logic                                               core_rst_n_local;
logic                                               axi_rst_n;

// Lifecycle admission and drain observability
logic                                               lifecycle_cpu_rst_n;
logic                                               lifecycle_active_epoch_q;
logic                                               lifecycle_dcache_idle;

logic                                               core_imem_req_raw;
logic                                               core_imem_req_ack_gated;
logic                                               lifecycle_imem_accept;
logic                                               lifecycle_imem_complete;
logic [31:0]                                        lifecycle_imem_pending_q;

logic                                               core_dmem_req_raw;
logic                                               core_dmem_req_ack_gated;
logic                                               lifecycle_dmem_accept;
logic                                               lifecycle_dmem_complete;
logic [31:0]                                        lifecycle_dmem_pending_q;
`ifdef SCR1_DBG_EN
logic                                               tapc_trst_n;
`endif // SCR1_DBG_EN

// Instruction memory interface from core to router
logic                                               core_imem_req_ack;
logic                                               core_imem_req;
type_scr1_mem_cmd_e                                 core_imem_cmd;
logic [`SCR1_IMEM_AWIDTH-1:0]                       core_imem_addr;
logic [`SCR1_IMEM_DWIDTH-1:0]                       core_imem_rdata;
type_scr1_mem_resp_e                                core_imem_resp;

`ifdef SCR1_IMEM_SKID_BUF
// Buffered instruction-memory request interface to the IMEM router
logic                                               router_imem_req_ack_raw;
logic                                               router_imem_req;
type_scr1_mem_cmd_e                                 router_imem_cmd;
logic [`SCR1_IMEM_AWIDTH-1:0]                       router_imem_addr;

logic                                               imem_skid_vd_ff;
type_scr1_mem_cmd_e                                 imem_skid_cmd_ff;
logic [`SCR1_IMEM_AWIDTH-1:0]                       imem_skid_addr_ff;

logic                                               imem_skid_capture;
logic                                               imem_skid_pop;
`endif // SCR1_IMEM_SKID_BUF

// Data memory interface from core to router
logic                                               core_dmem_req_ack;
logic                                               core_dmem_req;
type_scr1_mem_cmd_e                                 core_dmem_cmd;
type_scr1_mem_width_e                               core_dmem_width;
logic [`SCR1_DMEM_AWIDTH-1:0]                       core_dmem_addr;
logic [`SCR1_DMEM_DWIDTH-1:0]                       core_dmem_wdata;
logic [`SCR1_DMEM_DWIDTH-1:0]                       core_dmem_rdata;
type_scr1_mem_resp_e                                core_dmem_resp;

// Instruction memory interface from router to AXI bridge
logic                                               axi_imem_req_ack;
logic                                               axi_imem_req;
type_scr1_mem_cmd_e                                 axi_imem_cmd;
logic [`SCR1_IMEM_AWIDTH-1:0]                       axi_imem_addr;
logic [`SCR1_IMEM_DWIDTH-1:0]                       axi_imem_rdata;
type_scr1_mem_resp_e                                axi_imem_resp;
logic [7:0]                                         axi_imem_burst_len;
logic                                               axi_imem_rvalid;
logic                                               axi_imem_rlast;
logic [`SCR1_IMEM_DWIDTH-1:0]                       axi_imem_beat_rdata;
type_scr1_mem_resp_e                                axi_imem_beat_resp;
// Instruction cache interface to IMEM router
logic                                               icache_imem_req_ack;
logic                                               icache_imem_req;
type_scr1_mem_cmd_e                                 icache_imem_cmd;
logic [`SCR1_IMEM_AWIDTH-1:0]                       icache_imem_addr;
logic [`SCR1_IMEM_DWIDTH-1:0]                       icache_imem_rdata;
type_scr1_mem_resp_e                                icache_imem_resp;

// Data memory interface from router to AXI bridge
logic                                               axi_dmem_req_ack;
logic                                               axi_dmem_req;
type_scr1_mem_cmd_e                                 axi_dmem_cmd;
type_scr1_mem_width_e                               axi_dmem_width;
logic [`SCR1_DMEM_AWIDTH-1:0]                       axi_dmem_addr;
logic [`SCR1_DMEM_DWIDTH-1:0]                       axi_dmem_wdata;
logic [`SCR1_DMEM_DWIDTH-1:0]                       axi_dmem_rdata;
type_scr1_mem_resp_e                                axi_dmem_resp;
logic [7:0]                                         axi_dmem_burst_len;
logic                                               axi_dmem_rvalid;
logic                                               axi_dmem_rlast;
logic [`SCR1_DMEM_DWIDTH-1:0]                       axi_dmem_beat_rdata;
type_scr1_mem_resp_e                                axi_dmem_beat_resp;

// Dcache interface to DMEM router
logic                                               dcache_dmem_req_ack;
logic                                               dcache_dmem_req;
type_scr1_mem_cmd_e                                 dcache_dmem_cmd;
type_scr1_mem_width_e                               dcache_dmem_width;
logic [`SCR1_DMEM_AWIDTH-1:0]                       dcache_dmem_addr;
logic [`SCR1_DMEM_DWIDTH-1:0]                       dcache_dmem_wdata;
logic [`SCR1_DMEM_DWIDTH-1:0]                       dcache_dmem_rdata;
type_scr1_mem_resp_e                                dcache_dmem_resp;

// Four cacheable stores can retire ahead of the external memory response.
// Keep the depth explicit at the SoC top so FPGA builds have one clear knob.
localparam int unsigned SCR1_DCACHE_WRITE_BUFFER_DEPTH = 4;
`ifdef SCR1_TCM_EN
// Instruction memory interface from router to TCM
logic                                               tcm_imem_req_ack;
logic                                               tcm_imem_req;
type_scr1_mem_cmd_e                                 tcm_imem_cmd;
logic [`SCR1_IMEM_AWIDTH-1:0]                       tcm_imem_addr;
logic [`SCR1_IMEM_DWIDTH-1:0]                       tcm_imem_rdata;
type_scr1_mem_resp_e                                tcm_imem_resp;

// Data memory interface from router to TCM
logic                                               tcm_dmem_req_ack;
logic                                               tcm_dmem_req;
type_scr1_mem_cmd_e                                 tcm_dmem_cmd;
type_scr1_mem_width_e                               tcm_dmem_width;
logic [`SCR1_DMEM_AWIDTH-1:0]                       tcm_dmem_addr;
logic [`SCR1_DMEM_DWIDTH-1:0]                       tcm_dmem_wdata;
logic [`SCR1_DMEM_DWIDTH-1:0]                       tcm_dmem_rdata;
type_scr1_mem_resp_e                                tcm_dmem_resp;
`endif // SCR1_TCM_EN

// Data memory interface from router to memory-mapped timer
logic                                               timer_dmem_req_ack;
logic                                               timer_dmem_req;
type_scr1_mem_cmd_e                                 timer_dmem_cmd;
type_scr1_mem_width_e                               timer_dmem_width;
logic [`SCR1_DMEM_AWIDTH-1:0]                       timer_dmem_addr;
logic [`SCR1_DMEM_DWIDTH-1:0]                       timer_dmem_wdata;
logic [`SCR1_DMEM_DWIDTH-1:0]                       timer_dmem_rdata;
type_scr1_mem_resp_e                                timer_dmem_resp;

// Misc
logic                                               timer_irq;
logic [63:0]                                        timer_val;
logic                                               axi_reinit;
logic                                               axi_imem_idle;
logic                                               axi_dmem_idle;

// Cache-controller events. These are simple observation nets; all counters and
// cross-hierarchy simulation signals are guarded by SCR1_TRGT_SIMULATION.
`ifdef SCR1_IMEM_ROUTER_EN
logic ic_perf_req_accept;
logic ic_perf_lookup_event;
logic ic_perf_lookup_hit;
logic ic_perf_refill_word;
logic ic_perf_refill_burst;
logic ic_perf_burst_error;
logic ic_perf_victim_word_hit;
logic ic_perf_victim_swap;
`endif // SCR1_IMEM_ROUTER_EN

logic dc_perf_req_accept;
logic dc_perf_lookup_event;
logic dc_perf_lookup_hit;
logic dc_perf_req_is_store;
logic dc_perf_refill_word;
logic dc_perf_refill_burst;
logic dc_perf_burst_error;
logic dc_perf_victim_word_hit;
logic dc_perf_victim_swap;
logic dc_perf_victim_store_invalidate;

`ifdef SCR1_TRGT_SIMULATION
logic dc_response_completed;

assign dc_response_completed =
    (dcache_dmem_resp == SCR1_MEM_RESP_RDY_OK) ||
    (dcache_dmem_resp == SCR1_MEM_RESP_RDY_ER);

logic perf_retired_event;

`ifndef SCR1_CSR_REDUCED_CNT
assign perf_retired_event =
    i_core_top.i_pipe_top.instret_nexc;
`else
assign perf_retired_event =
    i_core_top.i_pipe_top.instret;
`endif

logic dc_memory_stall;

assign dc_memory_stall =
    i_core_top.i_pipe_top.exu_busy &&
    i_core_top.i_pipe_top.i_pipe_exu.lsu_req;

`ifdef SCR1_IMEM_ROUTER_EN
logic ic_response_completed;
logic ic_memory_stall;

assign ic_response_completed =
    (icache_imem_resp == SCR1_MEM_RESP_RDY_OK) ||
    (icache_imem_resp == SCR1_MEM_RESP_RDY_ER);

assign ic_memory_stall =
    i_core_top.i_pipe_top.idu2ifu_rdy &&
   !i_core_top.i_pipe_top.ifu2idu_vd &&
   (
       (|i_core_top.i_pipe_top.i_pipe_ifu.imem_pnd_txns_cnt) ||
       (core_imem_req && !core_imem_req_ack)
   );
`endif // SCR1_IMEM_ROUTER_EN
`endif // SCR1_TRGT_SIMULATION

//-------------------------------------------------------------------------------
// Reset logic
//-------------------------------------------------------------------------------
// Power-Up Reset synchronizer
scr1_reset_sync_cell #(
    .STAGES_AMOUNT       (SCR1_CLUSTER_TOP_RST_SYNC_STAGES_NUM)
) i_pwrup_rstn_reset_sync (
    .rst_n          (pwrup_rst_n     ),
    .clk            (clk             ),
    .test_rst_n     (test_rst_n      ),
    .test_mode      (test_mode       ),
    .rst_n_in       (1'b1            ),
    .rst_n_out      (pwrup_rst_n_sync)
);

// Regular Reset synchronizer
scr1_reset_sync_cell #(
    .STAGES_AMOUNT       (SCR1_CLUSTER_TOP_RST_SYNC_STAGES_NUM)
) i_rstn_reset_sync (
    .rst_n          (pwrup_rst_n     ),
    .clk            (clk             ),
    .test_rst_n     (test_rst_n      ),
    .test_mode      (test_mode       ),
    .rst_n_in       (rst_n           ),
    .rst_n_out      (rst_n_sync      )
);

// CPU Reset synchronizer
scr1_reset_sync_cell #(
    .STAGES_AMOUNT       (SCR1_CLUSTER_TOP_RST_SYNC_STAGES_NUM)
) i_cpu_rstn_reset_sync (
    .rst_n          (pwrup_rst_n     ),
    .clk            (clk             ),
    .test_rst_n     (test_rst_n      ),
    .test_mode      (test_mode       ),
    .rst_n_in       (lifecycle_cpu_rst_n),
    .rst_n_out      (cpu_rst_n_sync  )
);

`ifdef SCR1_DBG_EN
// TAPC Reset
scr1_reset_and2_cell i_tapc_rstn_and2_cell (
    .rst_n_in       ({trst_n, pwrup_rst_n}),
    .test_rst_n     (test_rst_n      ),
    .test_mode      (test_mode       ),
    .rst_n_out      (tapc_trst_n     )
);
`endif // SCR1_DBG_EN

`ifdef SCR1_DBG_EN
assign axi_rst_n = sys_rst_n_o;
`else // SCR1_DBG_EN
assign axi_rst_n = rst_n_sync;
`endif // SCR1_DBG_EN

//-------------------------------------------------------------------------------
// SCR1 core instance
//-------------------------------------------------------------------------------
scr1_core_top i_core_top (
    // Common
    .pwrup_rst_n                (pwrup_rst_n_sync ),
    .rst_n                      (rst_n_sync       ),
    .cpu_rst_n                  (cpu_rst_n_sync   ),
    .test_mode                  (test_mode        ),
    .test_rst_n                 (test_rst_n       ),
    .clk                        (clk              ),
    .core_rst_n_o               (core_rst_n_local ),
    .core_rdc_qlfy_o            (                 ),
`ifdef SCR1_DBG_EN
    .sys_rst_n_o                (sys_rst_n_o      ),
    .sys_rdc_qlfy_o             (sys_rdc_qlfy_o   ),
`endif // SCR1_DBG_EN

    // Fuses
    .core_fuse_mhartid_i        (fuse_mhartid     ),
`ifdef SCR1_DBG_EN
    .tapc_fuse_idcode_i         (fuse_idcode      ),
`endif // SCR1_DBG_EN

    // IRQ
`ifdef SCR1_IPIC_EN
    .core_irq_lines_i           (irq_lines        ),
`else // SCR1_IPIC_EN
    .core_irq_ext_i             (ext_irq          ),
`endif // SCR1_IPIC_EN
    .core_irq_soft_i            (soft_irq         ),
    .core_irq_mtimer_i          (timer_irq        ),

    // Memory-mapped external timer
    .core_mtimer_val_i          (timer_val        ),

`ifdef SCR1_DBG_EN
    // Debug interface
    .tapc_trst_n                (tapc_trst_n      ),
    .tapc_tck                   (tck              ),
    .tapc_tms                   (tms              ),
    .tapc_tdi                   (tdi              ),
    .tapc_tdo                   (tdo              ),
    .tapc_tdo_en                (tdo_en           ),
`endif // SCR1_DBG_EN

    // Instruction memory interface
    .imem2core_req_ack_i        (core_imem_req_ack_gated),
    .core2imem_req_o            (core_imem_req_raw),
    .core2imem_cmd_o            (core_imem_cmd    ),
    .core2imem_addr_o           (core_imem_addr   ),
    .imem2core_rdata_i          (core_imem_rdata  ),
    .imem2core_resp_i           (core_imem_resp   ),

    // Data memory interface
    .dmem2core_req_ack_i        (core_dmem_req_ack_gated),
    .core2dmem_req_o            (core_dmem_req_raw),
    .core2dmem_cmd_o            (core_dmem_cmd    ),
    .core2dmem_width_o          (core_dmem_width  ),
    .core2dmem_addr_o           (core_dmem_addr   ),
    .core2dmem_wdata_o          (core_dmem_wdata  ),
    .dmem2core_rdata_i          (core_dmem_rdata  ),
    .dmem2core_resp_i           (core_dmem_resp   )
);


`ifdef SCR1_TCM_EN
//-------------------------------------------------------------------------------
// TCM instance
//-------------------------------------------------------------------------------
scr1_tcm #(
    .SCR1_TCM_SIZE  (`SCR1_DMEM_AWIDTH'(~SCR1_TCM_ADDR_MASK + 1'b1))
) i_tcm (
    .clk            (clk             ),
    .rst_n          (core_rst_n_local),

    // Instruction interface to TCM
    .imem_req_ack   (tcm_imem_req_ack),
    .imem_req       (tcm_imem_req    ),
    .imem_addr      (tcm_imem_addr   ),
    .imem_rdata     (tcm_imem_rdata  ),
    .imem_resp      (tcm_imem_resp   ),

    // Data interface to TCM
    .dmem_req_ack   (tcm_dmem_req_ack),
    .dmem_req       (tcm_dmem_req    ),
    .dmem_cmd       (tcm_dmem_cmd    ),
    .dmem_width     (tcm_dmem_width  ),
    .dmem_addr      (tcm_dmem_addr   ),
    .dmem_wdata     (tcm_dmem_wdata  ),
    .dmem_rdata     (tcm_dmem_rdata  ),
    .dmem_resp      (tcm_dmem_resp   )
);
`endif // SCR1_TCM_EN


//-------------------------------------------------------------------------------
// Memory-mapped timer instance
//-------------------------------------------------------------------------------
scr1_timer i_timer (
    // Common
    .rst_n          (core_rst_n_local  ),
    .clk            (clk               ),
    .rtc_clk        (rtc_clk           ),

    // Memory interface
    .dmem_req       (timer_dmem_req    ),
    .dmem_cmd       (timer_dmem_cmd    ),
    .dmem_width     (timer_dmem_width  ),
    .dmem_addr      (timer_dmem_addr   ),
    .dmem_wdata     (timer_dmem_wdata  ),
    .dmem_req_ack   (timer_dmem_req_ack),
    .dmem_rdata     (timer_dmem_rdata  ),
    .dmem_resp      (timer_dmem_resp   ),

    // Timer interface
    .timer_val      (timer_val         ),
    .timer_irq      (timer_irq         )
);


`ifdef SCR1_IMEM_ROUTER_EN
//-------------------------------------------------------------------------------
// Instruction memory router
//-------------------------------------------------------------------------------
`ifdef SCR1_IMEM_SKID_BUF
// ------------------------------------------------------------
// 1-entry fall-through IMEM request buffer
// ------------------------------------------------------------

// IFU talks only to local registered state.
// No combinational cache/router ACK path back to the core.
assign core_imem_req_ack = ~imem_skid_vd_ff;

// If the buffer is empty, request falls through directly
// from IFU to the IMEM router.
//
// If the buffer contains a stalled request, the buffered
// request owns the router interface.
assign router_imem_req =
       imem_skid_vd_ff
     ? 1'b1
     : core_imem_req;

assign router_imem_cmd =
       imem_skid_vd_ff
     ? imem_skid_cmd_ff
     : core_imem_cmd;

assign router_imem_addr =
       imem_skid_vd_ff
     ? imem_skid_addr_ff
     : core_imem_addr;

// Empty buffer + core request + downstream did not accept:
// core already saw ACK from the local buffer, therefore
// we must save the request.
assign imem_skid_capture =
       ~imem_skid_vd_ff
     & core_imem_req
     & ~router_imem_req_ack_raw;

// Buffered request was finally accepted by router/cache.
assign imem_skid_pop =
       imem_skid_vd_ff
     & router_imem_req_ack_raw;

// Buffer storage
always_ff @(posedge clk, negedge core_rst_n_local) begin
    if (~core_rst_n_local) begin
        imem_skid_vd_ff   <= 1'b0;
        imem_skid_cmd_ff  <= SCR1_MEM_CMD_RD;
        imem_skid_addr_ff <= '0;
    end else begin
        if (imem_skid_pop) begin
            imem_skid_vd_ff <= 1'b0;
        end

        if (imem_skid_capture) begin
            imem_skid_vd_ff   <= 1'b1;
            imem_skid_cmd_ff  <= core_imem_cmd;
            imem_skid_addr_ff <= core_imem_addr;
        end
    end
end
`endif // SCR1_IMEM_SKID_BUF

scr1_imem_router #(
    .SCR1_ADDR_MASK             (SCR1_TCM_ADDR_MASK),
    .SCR1_ADDR_PATTERN          (SCR1_TCM_ADDR_PATTERN)
) i_imem_router (
    .rst_n          (core_rst_n_local ),
    .clk            (clk              ),

    // Interface to core
`ifdef SCR1_IMEM_SKID_BUF
    .imem_req_ack   (router_imem_req_ack_raw),
    .imem_req       (router_imem_req        ),
    .imem_cmd       (router_imem_cmd        ),
    .imem_addr      (router_imem_addr       ),
`else
    .imem_req_ack   (core_imem_req_ack),
    .imem_req       (core_imem_req    ),
    .imem_cmd       (core_imem_cmd    ),
    .imem_addr      (core_imem_addr   ),
`endif // SCR1_IMEM_SKID_BUF
    .imem_rdata     (core_imem_rdata  ),
    .imem_resp      (core_imem_resp   ),

    // Interface to AXI bridge
    .port0_req_ack  (icache_imem_req_ack),
    .port0_req      (icache_imem_req),
    .port0_cmd      (icache_imem_cmd),
    .port0_addr     (icache_imem_addr),
    .port0_rdata    (icache_imem_rdata),
    .port0_resp     (icache_imem_resp),
    //.port0_req_ack  (axi_imem_req_ack ),
    //.port0_req      (axi_imem_req     ),
    //.port0_cmd      (axi_imem_cmd     ),
    //.port0_addr     (axi_imem_addr    ),
    //.port0_rdata    (axi_imem_rdata   ),
    //.port0_resp     (axi_imem_resp    ),

    // Interface to TCM
    .port1_req_ack  (tcm_imem_req_ack ),
    .port1_req      (tcm_imem_req     ),
    .port1_cmd      (tcm_imem_cmd     ),
    .port1_addr     (tcm_imem_addr    ),
    .port1_rdata    (tcm_imem_rdata   ),
    .port1_resp     (tcm_imem_resp    )
);
scr1_icache #(
    .ICACHE_LINE_BYTES            (SCR1_ICACHE_LINE_BYTES),
    .ICACHE_AXI_BURST_ENABLE      (SCR1_ICACHE_AXI_BURST_ENABLE),
    .ICACHE_MAX_READ_BURST_BEATS  (SCR1_AXI_MAX_READ_BURST_BEATS)
) i_icache (
    .clk                 (clk),
    .rst_n               (core_rst_n_local),

    // IMEM router interface
    .router_req_ack_o    (icache_imem_req_ack),
    .router_req_i        (icache_imem_req),
    .router_cmd_i        (icache_imem_cmd),
    .router_addr_i       (icache_imem_addr),
    .router_rdata_o      (icache_imem_rdata),
    .router_resp_o       (icache_imem_resp),

    // AXI bridge interface
    .memory_req_ack_i    (axi_imem_req_ack),
    .memory_req_o        (axi_imem_req),
    .memory_cmd_o        (axi_imem_cmd),
    .memory_addr_o       (axi_imem_addr),
    .memory_burst_len_o  (axi_imem_burst_len),
    .memory_rvalid_i     (axi_imem_rvalid),
    .memory_rlast_i      (axi_imem_rlast),
    .memory_rdata_i      (axi_imem_beat_rdata),
    .memory_resp_i       (axi_imem_beat_resp),


    .perf_req_accept        (ic_perf_req_accept),
    .perf_lookup_event      (ic_perf_lookup_event),
    .perf_lookup_hit        (ic_perf_lookup_hit),
    .perf_refill_word       (ic_perf_refill_word),
    .perf_refill_burst      (ic_perf_refill_burst),
    .perf_burst_error       (ic_perf_burst_error),
    .perf_victim_word_hit   (ic_perf_victim_word_hit),
    .perf_victim_swap       (ic_perf_victim_swap)
);

`else // SCR1_IMEM_ROUTER_EN

assign axi_imem_req         = core_imem_req;
assign axi_imem_cmd         = core_imem_cmd;
assign axi_imem_addr        = core_imem_addr;
assign axi_imem_burst_len   = 8'd0;
assign core_imem_req_ack    = axi_imem_req_ack;
assign core_imem_resp       = axi_imem_resp;
assign core_imem_rdata      = axi_imem_rdata;

`endif // SCR1_IMEM_ROUTER_EN


//-------------------------------------------------------------------------------
// Data memory router
//-------------------------------------------------------------------------------
scr1_dmem_router #(

`ifdef SCR1_TCM_EN
    .SCR1_PORT1_ADDR_MASK       (SCR1_TCM_ADDR_MASK),
    .SCR1_PORT1_ADDR_PATTERN    (SCR1_TCM_ADDR_PATTERN),
`else // SCR1_TCM_EN
    .SCR1_PORT1_ADDR_MASK       (32'h00000000),
    .SCR1_PORT1_ADDR_PATTERN    (32'hFFFFFFFF),
`endif // SCR1_TCM_EN

    .SCR1_PORT2_ADDR_MASK       (SCR1_TIMER_ADDR_MASK),
    .SCR1_PORT2_ADDR_PATTERN    (SCR1_TIMER_ADDR_PATTERN)

) i_dmem_router (
    .rst_n          (core_rst_n_local    ),
    .clk            (clk                 ),

    // Interface to core
    .dmem_req_ack   (core_dmem_req_ack   ),
    .dmem_req       (core_dmem_req       ),
    .dmem_cmd       (core_dmem_cmd       ),
    .dmem_width     (core_dmem_width     ),
    .dmem_addr      (core_dmem_addr      ),
    .dmem_wdata     (core_dmem_wdata     ),
    .dmem_rdata     (core_dmem_rdata     ),
    .dmem_resp      (core_dmem_resp      ),

`ifdef SCR1_TCM_EN
    // Interface to TCM
    .port1_req_ack  (tcm_dmem_req_ack    ),
    .port1_req      (tcm_dmem_req        ),
    .port1_cmd      (tcm_dmem_cmd        ),
    .port1_width    (tcm_dmem_width      ),
    .port1_addr     (tcm_dmem_addr       ),
    .port1_wdata    (tcm_dmem_wdata      ),
    .port1_rdata    (tcm_dmem_rdata      ),
    .port1_resp     (tcm_dmem_resp       ),
`else // SCR1_TCM_EN
    .port1_req_ack  (1'b0                ),
    .port1_req      (                    ),
    .port1_cmd      (                    ),
    .port1_width    (                    ),
    .port1_addr     (                    ),
    .port1_wdata    (                    ),
    .port1_rdata    ('0                  ),
    .port1_resp     (SCR1_MEM_RESP_RDY_ER),
`endif // SCR1_TCM_EN

    // Interface to memory-mapped timer
    .port2_req_ack  (timer_dmem_req_ack  ),
    .port2_req      (timer_dmem_req      ),
    .port2_cmd      (timer_dmem_cmd      ),
    .port2_width    (timer_dmem_width    ),
    .port2_addr     (timer_dmem_addr     ),
    .port2_wdata    (timer_dmem_wdata    ),
    .port2_rdata    (timer_dmem_rdata    ),
    .port2_resp     (timer_dmem_resp     ),

    // Interface to AXI bridge
    //.port0_req_ack  (axi_dmem_req_ack    ),
    //.port0_req      (axi_dmem_req        ),
    //.port0_cmd      (axi_dmem_cmd        ),
    //.port0_width    (axi_dmem_width      ),
    //.port0_addr     (axi_dmem_addr       ),
    //.port0_wdata    (axi_dmem_wdata      ),
    //.port0_rdata    (axi_dmem_rdata      ),
    //.port0_resp     (axi_dmem_resp       )
    // Interface to data cache
    .port0_req_ack  (dcache_dmem_req_ack),
    .port0_req      (dcache_dmem_req),
    .port0_cmd      (dcache_dmem_cmd),
    .port0_width    (dcache_dmem_width),
    .port0_addr     (dcache_dmem_addr),
    .port0_wdata    (dcache_dmem_wdata),
    .port0_rdata    (dcache_dmem_rdata),
    .port0_resp     (dcache_dmem_resp)
);
scr1_dcache #(
    .DCACHE_LINE_BYTES         (SCR1_DCACHE_LINE_BYTES),
    .DCACHE_WRITE_BUFFER_DEPTH (SCR1_DCACHE_WRITE_BUFFER_DEPTH),
    .DCACHE_NO_WRITE_ALLOCATE  (SCR1_DCACHE_NO_WRITE_ALLOCATE),
    .DCACHE_AXI_BURST_ENABLE   (SCR1_DCACHE_AXI_BURST_ENABLE),
`ifdef SCR1_DCACHE_VICTIM_EN
    .DCACHE_VICTIM_LINES       (SCR1_DCACHE_VICTIM_LINES),
`endif
    .DCACHE_MAX_READ_BURST_BEATS (SCR1_AXI_MAX_READ_BURST_BEATS)
) i_dcache (
    .clk                (clk),
    .rst_n              (core_rst_n_local),
    .drain_idle_o       (lifecycle_dcache_idle),

    // DMEM router interface
    .router_req_i       (dcache_dmem_req),
    .router_cmd_i       (dcache_dmem_cmd),
    .router_width_i     (dcache_dmem_width),
    .router_addr_i      (dcache_dmem_addr),
    .router_wdata_i     (dcache_dmem_wdata),
    .router_req_ack_o   (dcache_dmem_req_ack),
    .router_rdata_o     (dcache_dmem_rdata),
    .router_resp_o      (dcache_dmem_resp),

    // AXI bridge interface
    .memory_req_o       (axi_dmem_req),
    .memory_cmd_o       (axi_dmem_cmd),
    .memory_width_o     (axi_dmem_width),
    .memory_addr_o      (axi_dmem_addr),
    .memory_wdata_o     (axi_dmem_wdata),
    .memory_burst_len_o (axi_dmem_burst_len),
    .memory_req_ack_i   (axi_dmem_req_ack),
    .memory_rvalid_i    (axi_dmem_rvalid),
    .memory_rlast_i     (axi_dmem_rlast),
    .memory_rdata_i     (axi_dmem_beat_rdata),
    .memory_resp_i      (axi_dmem_beat_resp),

    .perf_req_accept    (dc_perf_req_accept),
    .perf_lookup_event  (dc_perf_lookup_event),
    .perf_lookup_hit    (dc_perf_lookup_hit),
    .perf_req_is_store  (dc_perf_req_is_store),
    .perf_refill_word   (dc_perf_refill_word),
    .perf_refill_burst  (dc_perf_refill_burst),
    .perf_burst_error   (dc_perf_burst_error),
    .perf_victim_word_hit
                         (dc_perf_victim_word_hit),
    .perf_victim_swap   (dc_perf_victim_swap),
    .perf_victim_store_invalidate
                         (dc_perf_victim_store_invalidate)
);


//-------------------------------------------------------------------------------
// Instruction memory AXI bridge
//-------------------------------------------------------------------------------
scr1_mem_axi #(
`ifdef SCR1_IMEM_AXI_REQ_BP
    .SCR1_AXI_REQ_BP    (1),
`else // SCR1_IMEM_AXI_REQ_BP
    .SCR1_AXI_REQ_BP    (0),
`endif // SCR1_IMEM_AXI_REQ_BP
`ifdef SCR1_IMEM_AXI_RESP_BP
    .SCR1_AXI_RESP_BP   (1),
`else // SCR1_IMEM_AXI_RESP_BP
    .SCR1_AXI_RESP_BP   (0),
`endif // SCR1_IMEM_AXI_RESP_BP
    .SCR1_AXI_BURST_ENABLE (SCR1_ICACHE_AXI_BURST_ENABLE),
    .SCR1_AXI_MAX_READ_BURST_BEATS (SCR1_AXI_MAX_READ_BURST_BEATS)
) i_imem_axi (
    .clk            (clk                    ),
    .rst_n          (axi_rst_n              ),
    .axi_reinit     (axi_reinit             ),

    // Interface to core
    .core_idle      (axi_imem_idle          ),
    .core_req_ack   (axi_imem_req_ack       ),
    .core_req       (axi_imem_req           ),
    .core_cmd       (axi_imem_cmd           ),
    .core_width     (SCR1_MEM_WIDTH_WORD    ),
    .core_addr      (axi_imem_addr          ),
    .core_wdata     ('0                     ),
    .core_burst_len (axi_imem_burst_len     ),
    .core_rdata     (axi_imem_rdata         ),
    .core_resp      (axi_imem_resp          ),
    .core_rvalid    (axi_imem_rvalid        ),
    .core_rlast     (axi_imem_rlast         ),
    .core_beat_rdata(axi_imem_beat_rdata    ),
    .core_beat_resp (axi_imem_beat_resp     ),

    // AXI I/O
    .awid           (io_axi_imem_awid       ),
    .awaddr         (io_axi_imem_awaddr     ),
    .awlen          (io_axi_imem_awlen      ),
    .awsize         (io_axi_imem_awsize     ),
    .awburst        (io_axi_imem_awburst    ),
    .awlock         (io_axi_imem_awlock     ),
    .awcache        (io_axi_imem_awcache    ),
    .awprot         (io_axi_imem_awprot     ),
    .awregion       (io_axi_imem_awregion   ),
    .awuser         (io_axi_imem_awuser     ),
    .awqos          (io_axi_imem_awqos      ),
    .awvalid        (io_axi_imem_awvalid    ),
    .awready        (io_axi_imem_awready    ),
    .wdata          (io_axi_imem_wdata      ),
    .wstrb          (io_axi_imem_wstrb      ),
    .wlast          (io_axi_imem_wlast      ),
    .wuser          (io_axi_imem_wuser      ),
    .wvalid         (io_axi_imem_wvalid     ),
    .wready         (io_axi_imem_wready     ),
    .bid            (io_axi_imem_bid        ),
    .bresp          (io_axi_imem_bresp      ),
    .bvalid         (io_axi_imem_bvalid     ),
    .buser          (io_axi_imem_buser      ),
    .bready         (io_axi_imem_bready     ),
    .arid           (io_axi_imem_arid       ),
    .araddr         (io_axi_imem_araddr     ),
    .arlen          (io_axi_imem_arlen      ),
    .arsize         (io_axi_imem_arsize     ),
    .arburst        (io_axi_imem_arburst    ),
    .arlock         (io_axi_imem_arlock     ),
    .arcache        (io_axi_imem_arcache    ),
    .arprot         (io_axi_imem_arprot     ),
    .arregion       (io_axi_imem_arregion   ),
    .aruser         (io_axi_imem_aruser     ),
    .arqos          (io_axi_imem_arqos      ),
    .arvalid        (io_axi_imem_arvalid    ),
    .arready        (io_axi_imem_arready    ),
    .rid            (io_axi_imem_rid        ),
    .rdata          (io_axi_imem_rdata      ),
    .rresp          (io_axi_imem_rresp      ),
    .rlast          (io_axi_imem_rlast      ),
    .ruser          (io_axi_imem_ruser      ),
    .rvalid         (io_axi_imem_rvalid     ),
    .rready         (io_axi_imem_rready     )
);
//-------------------------------------------------------------------------------
// Data memory AXI bridge
//-------------------------------------------------------------------------------
scr1_mem_axi #(
`ifdef SCR1_DMEM_AXI_REQ_BP
    .SCR1_AXI_REQ_BP    (1),
`else // SCR1_DMEM_AXI_REQ_BP
    .SCR1_AXI_REQ_BP    (0),
`endif // SCR1_DMEM_AXI_REQ_BP
`ifdef SCR1_DMEM_AXI_RESP_BP
    .SCR1_AXI_RESP_BP   (1),
`else // SCR1_DMEM_AXI_RESP_BP
    .SCR1_AXI_RESP_BP   (0),
`endif // SCR1_DMEM_AXI_RESP_BP
    .SCR1_AXI_BURST_ENABLE (SCR1_DCACHE_AXI_BURST_ENABLE),
    .SCR1_AXI_MAX_READ_BURST_BEATS (SCR1_AXI_MAX_READ_BURST_BEATS)
) i_dmem_axi (
    .clk            (clk                    ),
    .rst_n          (axi_rst_n              ),
    .axi_reinit     (axi_reinit             ),

    // Interface to core
    .core_idle      (axi_dmem_idle          ),
    .core_req_ack   (axi_dmem_req_ack       ),
    .core_req       (axi_dmem_req           ),
    .core_cmd       (axi_dmem_cmd           ),
    .core_width     (axi_dmem_width         ),
    .core_addr      (axi_dmem_addr          ),
    .core_wdata     (axi_dmem_wdata         ),
    .core_burst_len (axi_dmem_burst_len     ),
    .core_rdata     (axi_dmem_rdata         ),
    .core_resp      (axi_dmem_resp          ),
    .core_rvalid    (axi_dmem_rvalid        ),
    .core_rlast     (axi_dmem_rlast         ),
    .core_beat_rdata(axi_dmem_beat_rdata    ),
    .core_beat_resp (axi_dmem_beat_resp     ),

    // AXI I/O
    .awid           (io_axi_dmem_awid       ),
    .awaddr         (io_axi_dmem_awaddr     ),
    .awlen          (io_axi_dmem_awlen      ),
    .awsize         (io_axi_dmem_awsize     ),
    .awburst        (io_axi_dmem_awburst    ),
    .awlock         (io_axi_dmem_awlock     ),
    .awcache        (io_axi_dmem_awcache    ),
    .awprot         (io_axi_dmem_awprot     ),
    .awregion       (io_axi_dmem_awregion   ),
    .awuser         (io_axi_dmem_awuser     ),
    .awqos          (io_axi_dmem_awqos      ),
    .awvalid        (io_axi_dmem_awvalid    ),
    .awready        (io_axi_dmem_awready    ),
    .wdata          (io_axi_dmem_wdata      ),
    .wstrb          (io_axi_dmem_wstrb      ),
    .wlast          (io_axi_dmem_wlast      ),
    .wuser          (io_axi_dmem_wuser      ),
    .wvalid         (io_axi_dmem_wvalid     ),
    .wready         (io_axi_dmem_wready     ),
    .bid            (io_axi_dmem_bid        ),
    .bresp          (io_axi_dmem_bresp      ),
    .bvalid         (io_axi_dmem_bvalid     ),
    .buser          (io_axi_dmem_buser      ),
    .bready         (io_axi_dmem_bready     ),
    .arid           (io_axi_dmem_arid       ),
    .araddr         (io_axi_dmem_araddr     ),
    .arlen          (io_axi_dmem_arlen      ),
    .arsize         (io_axi_dmem_arsize     ),
    .arburst        (io_axi_dmem_arburst    ),
    .arlock         (io_axi_dmem_arlock     ),
    .arcache        (io_axi_dmem_arcache    ),
    .arprot         (io_axi_dmem_arprot     ),
    .arregion       (io_axi_dmem_arregion   ),
    .aruser         (io_axi_dmem_aruser     ),
    .arqos          (io_axi_dmem_arqos      ),
    .arvalid        (io_axi_dmem_arvalid    ),
    .arready        (io_axi_dmem_arready    ),
    .rid            (io_axi_dmem_rid        ),
    .rdata          (io_axi_dmem_rdata      ),
    .rresp          (io_axi_dmem_rresp      ),
    .rlast          (io_axi_dmem_rlast      ),
    .ruser          (io_axi_dmem_ruser      ),
    .rvalid         (io_axi_dmem_rvalid     ),
    .rready         (io_axi_dmem_rready     )
);
//-------------------------------------------------------------------------------
// Lifecycle memory admission / drain
//-------------------------------------------------------------------------------
// master_enable_i is applied on the native SCR1 request side, before the
// request reaches the skid buffer/router/cache/AXI bridge.  AXI VALID/READY
// signals are deliberately NOT gated: once a transaction has entered an AXI
// bridge it is allowed to complete according to the AXI protocol.
assign core_imem_req           = core_imem_req_raw && master_enable_i;
assign core_imem_req_ack_gated = core_imem_req_ack && master_enable_i;
assign core_dmem_req           = core_dmem_req_raw && master_enable_i;
assign core_dmem_req_ack_gated = core_dmem_req_ack && master_enable_i;

assign lifecycle_imem_accept = core_imem_req_raw && core_imem_req_ack_gated;
assign lifecycle_dmem_accept = core_dmem_req_raw && core_dmem_req_ack_gated;

// A terminal response completes one request previously accepted by the core.
// The pending/nonzero qualification makes this robust against a terminal
// response value lingering for a cycle after the actual completion.
assign lifecycle_imem_complete =
       ((core_imem_resp == SCR1_MEM_RESP_RDY_OK)
     || (core_imem_resp == SCR1_MEM_RESP_RDY_ER))
    && ((lifecycle_imem_pending_q != 0) || lifecycle_imem_accept);

assign lifecycle_dmem_complete =
       ((core_dmem_resp == SCR1_MEM_RESP_RDY_OK)
     || (core_dmem_resp == SCR1_MEM_RESP_RDY_ER))
    && ((lifecycle_dmem_pending_q != 0) || lifecycle_dmem_accept);

always_ff @(posedge clk or negedge pwrup_rst_n) begin
    if (!pwrup_rst_n) begin
        lifecycle_imem_pending_q <= '0;
        lifecycle_dmem_pending_q <= '0;
    end else if (!rst_n_sync) begin
        lifecycle_imem_pending_q <= '0;
        lifecycle_dmem_pending_q <= '0;
    end else begin
        case ({lifecycle_imem_accept, lifecycle_imem_complete})
            2'b10: lifecycle_imem_pending_q <= lifecycle_imem_pending_q + 1'b1;
            2'b01: lifecycle_imem_pending_q <= lifecycle_imem_pending_q - 1'b1;
            default: begin end
        endcase

        case ({lifecycle_dmem_accept, lifecycle_dmem_complete})
            2'b10: lifecycle_dmem_pending_q <= lifecycle_dmem_pending_q + 1'b1;
            2'b01: lifecycle_dmem_pending_q <= lifecycle_dmem_pending_q - 1'b1;
            default: begin end
        endcase
    end
end

// Full lifecycle drain means:
//  * every CPU request accepted before admission closed has completed;
//  * the D-cache write buffer/pass-through state is empty;
//  * both AXI bridge request/status queues are idle.
assign memory_idle_o = (lifecycle_imem_pending_q == 0)
                    && (lifecycle_dmem_pending_q == 0)
                    && !lifecycle_imem_accept
                    && !lifecycle_dmem_accept
                    && lifecycle_dcache_idle
                    && axi_imem_idle
                    && axi_dmem_idle;

// Remember whether the current lifecycle epoch actually ran with memory
// admission enabled.  This lets an abrupt FAULT close admission immediately
// but delay only the CPU reset until already-accepted work drains.  Normal
// OFF/RESET/LOADING/READY states are not accidentally released from reset.
always_ff @(posedge clk or negedge pwrup_rst_n) begin
    if (!pwrup_rst_n) begin
        lifecycle_active_epoch_q <= 1'b0;
    end else if (!rst_n_sync) begin
        lifecycle_active_epoch_q <= 1'b0;
    end else if (master_enable_i) begin
        lifecycle_active_epoch_q <= 1'b1;
    end else if (!cpu_rst_n && memory_idle_o) begin
        lifecycle_active_epoch_q <= 1'b0;
    end
end

// Active-low lifecycle CPU reset.  During an abrupt stop/fault from a running
// epoch, keep the core alive only long enough for accepted memory work to drain.
// The normal HALT path already reaches memory_idle_o before cpu_rst_n goes low.
assign lifecycle_cpu_rst_n = cpu_rst_n
                           || (lifecycle_active_epoch_q && !memory_idle_o);

// Report the reset after the existing SCR1 two-stage synchronizer.
assign cpu_reset_applied_o = !cpu_rst_n_sync;

`ifdef SCR1_TRGT_SIMULATION
always_ff @(posedge clk) begin
    if (pwrup_rst_n && rst_n_sync) begin
        if (!master_enable_i) begin
            assert (!lifecycle_imem_accept && !lifecycle_dmem_accept)
                else $error("scr1_top_axi: memory request accepted while admission disabled");
        end
        assert (!(lifecycle_imem_complete
                  && (lifecycle_imem_pending_q == 0)
                  && !lifecycle_imem_accept))
            else $error("scr1_top_axi: IMEM completion without accepted request");
        assert (!(lifecycle_dmem_complete
                  && (lifecycle_dmem_pending_q == 0)
                  && !lifecycle_dmem_accept))
            else $error("scr1_top_axi: DMEM completion without accepted request");
    end
end
`endif

//-------------------------------------------------------------------------------
// AXI reinit logic
//-------------------------------------------------------------------------------
always_ff @(negedge core_rst_n_local, posedge clk) begin
    if (~core_rst_n_local)                      axi_reinit <= 1'b1;
    else if (axi_imem_idle & axi_dmem_idle)     axi_reinit <= 1'b0;
end

`ifdef SCR1_TRGT_SIMULATION

`ifdef SCR1_IMEM_ROUTER_EN
cache_perf_monitor #(
    .CACHE_NAME    ("I-cache"),
`ifdef SCR1_ICACHE_VICTIM_EN
    .HAS_VICTIM    (1'b1),
`else
    .HAS_VICTIM    (1'b0),
`endif
    .IS_DATA_CACHE (1'b0)
) i_icache_perf_monitor (
    .clk                  (clk),
    .rst_n                (core_rst_n_local),

    .perf_req_accept      (ic_perf_req_accept),
    .perf_lookup_event    (ic_perf_lookup_event),
    .perf_lookup_hit      (ic_perf_lookup_hit),
    .perf_req_is_store    (1'b0),
    .perf_refill_word     (ic_perf_refill_word),
    .perf_refill_burst    (ic_perf_refill_burst),
    .perf_burst_error     (ic_perf_burst_error),
    .perf_victim_word_hit (ic_perf_victim_word_hit),
    .perf_victim_swap     (ic_perf_victim_swap),

    .response_completed   (ic_response_completed),
    .retired_event        (perf_retired_event),
    .memory_stall         (ic_memory_stall),
    .axi_ar_backpressure  (io_axi_imem_arvalid &&
                           !io_axi_imem_arready),
    .axi_r_backpressure   (io_axi_imem_rvalid &&
                           !io_axi_imem_rready),
    .axi_aw_backpressure  (1'b0),
    .axi_w_backpressure   (1'b0),
    .axi_b_backpressure   (1'b0)
);
`endif // SCR1_IMEM_ROUTER_EN

cache_perf_monitor #(
    .CACHE_NAME    ("D-cache"),
`ifdef SCR1_DCACHE_VICTIM_EN
    .HAS_VICTIM    (1'b1),
`else
    .HAS_VICTIM    (1'b0),
`endif
    .IS_DATA_CACHE (1'b1)
) i_dcache_perf_monitor (
    .clk                  (clk),
    .rst_n                (core_rst_n_local),

    .perf_req_accept      (dc_perf_req_accept),
    .perf_lookup_event    (dc_perf_lookup_event),
    .perf_lookup_hit      (dc_perf_lookup_hit),
    .perf_req_is_store    (dc_perf_req_is_store),
    .perf_refill_word     (dc_perf_refill_word),
    .perf_refill_burst    (dc_perf_refill_burst),
    .perf_burst_error     (dc_perf_burst_error),
    .perf_victim_word_hit (dc_perf_victim_word_hit),
    .perf_victim_swap     (dc_perf_victim_swap),

    .response_completed   (dc_response_completed),
    .retired_event        (perf_retired_event),
    .memory_stall         (dc_memory_stall),
    .axi_ar_backpressure  (io_axi_dmem_arvalid &&
                           !io_axi_dmem_arready),
    .axi_r_backpressure   (io_axi_dmem_rvalid &&
                           !io_axi_dmem_rready),
    .axi_aw_backpressure  (io_axi_dmem_awvalid &&
                           !io_axi_dmem_awready),
    .axi_w_backpressure   (io_axi_dmem_wvalid &&
                           !io_axi_dmem_wready),
    .axi_b_backpressure   (io_axi_dmem_bvalid &&
                           !io_axi_dmem_bready)
);

`endif
endmodule : scr1_top_axi
