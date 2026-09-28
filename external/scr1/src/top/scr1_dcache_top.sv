`include "scr1_memif.svh"
`include "scr1_arch_description.svh"

module scr1_dcache #(
    parameter int unsigned DCACHE_SIZE_BYTES        = 16384,
    parameter int unsigned DCACHE_LINE_BYTES        = 16,
    parameter int unsigned DCACHE_WAYS               = 1,
    parameter int unsigned DCACHE_WRITE_BUFFER_DEPTH = 4,
    // 1: STORE miss bypasses allocation/refill; 0: legacy write-allocate.
    parameter bit          DCACHE_NO_WRITE_ALLOCATE  = 1'b1,
    parameter bit          DCACHE_AXI_BURST_ENABLE   = 1'b1,
`ifdef SCR1_DCACHE_VICTIM_EN
    parameter int unsigned DCACHE_VICTIM_LINES       = 4,
`endif
    parameter int unsigned DCACHE_MAX_READ_BURST_BEATS = 8
) (
    input  logic                         clk,
    input  logic                         rst_n,

    // DMEM router interface
    input  logic                         router_req_i,
    input  type_scr1_mem_cmd_e           router_cmd_i,
    input  type_scr1_mem_width_e         router_width_i,
    input  logic [`SCR1_DMEM_AWIDTH-1:0] router_addr_i,
    input  logic [`SCR1_DMEM_DWIDTH-1:0] router_wdata_i,
    output logic                         router_req_ack_o,
    output logic [`SCR1_DMEM_DWIDTH-1:0] router_rdata_o,
    output type_scr1_mem_resp_e          router_resp_o,

    // AHB / AXI bridge interface
    output logic                         memory_req_o,
    output type_scr1_mem_cmd_e           memory_cmd_o,
    output type_scr1_mem_width_e         memory_width_o,
    output logic [`SCR1_DMEM_AWIDTH-1:0] memory_addr_o,
    output logic [`SCR1_DMEM_DWIDTH-1:0] memory_wdata_o,
    output logic [7:0]                   memory_burst_len_o,
    input  logic                         memory_req_ack_i,
    input  logic                         memory_rvalid_i,
    input  logic                         memory_rlast_i,
    input  logic [`SCR1_DMEM_DWIDTH-1:0] memory_rdata_i,
    input  type_scr1_mem_resp_e          memory_resp_i,

    // Cache performance monitor events
    output logic                         perf_req_accept,
    output logic                         perf_lookup_event,
    output logic                         perf_lookup_hit,
    output logic                         perf_req_is_store,
    output logic                         perf_refill_word,
    output logic                         perf_refill_burst,
    output logic                         perf_burst_error,
    output logic                         perf_victim_word_hit,
    output logic                         perf_victim_swap,
    output logic                         perf_victim_store_invalidate,

    // Lifecycle drain status propagated from the write buffer.
    output logic                         drain_idle_o
);

    localparam int unsigned DCACHE_ADDR_WIDTH = `SCR1_DMEM_AWIDTH;
    localparam int unsigned DCACHE_DATA_WIDTH = `SCR1_DMEM_DWIDTH;
    localparam int unsigned DCACHE_WORD_BYTES = DCACHE_DATA_WIDTH / 8;
    localparam int unsigned DCACHE_LINE_WORDS =
        DCACHE_LINE_BYTES / DCACHE_WORD_BYTES;
    localparam int unsigned DCACHE_LINES =
        DCACHE_SIZE_BYTES / DCACHE_LINE_BYTES;
    localparam int unsigned DCACHE_OFFSET_BITS =
        $clog2(DCACHE_LINE_BYTES);
    localparam int unsigned DCACHE_WORD_OFFSET_BITS =
        (DCACHE_LINE_WORDS > 1) ? $clog2(DCACHE_LINE_WORDS) : 1;
    localparam int unsigned DCACHE_INDEX_BITS =
        (DCACHE_LINES > 1) ? $clog2(DCACHE_LINES) : 1;
    localparam int unsigned DCACHE_TAG_BITS =
        DCACHE_ADDR_WIDTH - DCACHE_OFFSET_BITS - DCACHE_INDEX_BITS;
    localparam int unsigned DCACHE_REFILL_CNT_WIDTH =
        (DCACHE_LINE_WORDS > 1) ? $clog2(DCACHE_LINE_WORDS) : 1;
    localparam int unsigned DCACHE_BYTE_OFFSET_BITS =
        (DCACHE_WORD_BYTES > 1) ? $clog2(DCACHE_WORD_BYTES) : 1;
    localparam int unsigned DCACHE_WB_COUNT_WIDTH =
        $clog2(DCACHE_WRITE_BUFFER_DEPTH + 1);
`ifdef SCR1_DCACHE_VICTIM_EN
    localparam int unsigned DCACHE_VICTIM_ENTRY_BITS =
        (DCACHE_VICTIM_LINES > 1) ? $clog2(DCACHE_VICTIM_LINES) : 1;
`endif

    // DCACHE_WAYS is intentionally kept in the public interface for
    // compatibility with the previous top. This refactor preserves the current
    // direct-mapped implementation; associativity is not changed here.

    // Controller <-> cache lookup
    logic                                     cache_lookup_en;
    logic [DCACHE_INDEX_BITS-1:0]             cache_lookup_index;
    logic [DCACHE_WORD_OFFSET_BITS-1:0]       cache_lookup_word_offset;
    logic [DCACHE_TAG_BITS-1:0]               cache_lookup_tag;
    logic [DCACHE_DATA_WIDTH-1:0]             cache_lookup_data;
    logic                                     cache_lookup_valid;

    // Controller -> cache update controls
    logic                                     cache_line_invalidate;
    logic [DCACHE_INDEX_BITS-1:0]             cache_line_invalidate_index;

    logic                                     cache_refill_we;
    logic [DCACHE_INDEX_BITS-1:0]             cache_refill_index;
    logic [DCACHE_WORD_OFFSET_BITS-1:0]       cache_refill_word_offset;
    logic [DCACHE_DATA_WIDTH-1:0]             cache_refill_data;

    logic                                     cache_line_commit;
    logic [DCACHE_INDEX_BITS-1:0]             cache_line_commit_index;
    logic [DCACHE_TAG_BITS-1:0]               cache_line_commit_tag;

    logic                                     cache_store_we;
    logic [DCACHE_INDEX_BITS-1:0]             cache_store_index;
    logic [DCACHE_WORD_OFFSET_BITS-1:0]       cache_store_word_offset;
    logic [DCACHE_DATA_WIDTH-1:0]             cache_store_data;

    // Controller <-> write buffer. Keeping this interface internal lets the
    // public scr1_dcache memory interface remain unchanged for AHB and AXI.
    logic                                     ctrl_memory_req;
    type_scr1_mem_cmd_e                       ctrl_memory_cmd;
    type_scr1_mem_width_e                     ctrl_memory_width;
    logic [DCACHE_ADDR_WIDTH-1:0]             ctrl_memory_addr;
    logic [DCACHE_DATA_WIDTH-1:0]             ctrl_memory_wdata;
    logic [7:0]                               ctrl_memory_burst_len;
    logic                                     ctrl_memory_req_ack;
    logic                                     ctrl_memory_rvalid;
    logic                                     ctrl_memory_rlast;
    logic [DCACHE_DATA_WIDTH-1:0]             ctrl_memory_rdata;
    type_scr1_mem_resp_e                      ctrl_memory_resp;

    // Write-buffer status and simulation events.
    logic                                     wb_full;
    logic                                     wb_empty;
    logic [DCACHE_WB_COUNT_WIDTH-1:0]         wb_count;
    logic                                     wb_write_error;
    logic                                     wb_perf_enqueue;
    logic                                     wb_perf_dequeue;
    logic                                     wb_perf_full_stall;

`ifdef SCR1_DCACHE_VICTIM_EN
    // Controller <-> D-cache victim cache
    logic victim_lookup_en;
    logic [DCACHE_TAG_BITS-1:0] victim_lookup_tag;
    logic [DCACHE_INDEX_BITS-1:0] victim_lookup_index;
    logic [DCACHE_WORD_OFFSET_BITS-1:0] victim_lookup_word_offset;

    logic victim_lookup_hit;
    logic [DCACHE_VICTIM_ENTRY_BITS-1:0] victim_lookup_entry;
    logic [DCACHE_DATA_WIDTH-1:0] victim_lookup_data;

    logic [DCACHE_LINE_WORDS*DCACHE_DATA_WIDTH-1:0] victim_lookup_line;

    logic victim_write_en;
    logic [DCACHE_VICTIM_ENTRY_BITS-1:0] victim_write_entry;
    logic [DCACHE_TAG_BITS-1:0] victim_write_tag;
    logic [DCACHE_INDEX_BITS-1:0] victim_write_index;

    logic [DCACHE_LINE_WORDS*DCACHE_DATA_WIDTH-1:0] victim_write_line;

    logic victim_invalidate_en;
    logic [DCACHE_VICTIM_ENTRY_BITS-1:0] victim_invalidate_entry;
`endif // SCR1_DCACHE_VICTIM_EN

    dcache #(
        .DCACHE_DATA_WIDTH        (DCACHE_DATA_WIDTH),
        .DCACHE_LINE_WORDS        (DCACHE_LINE_WORDS),
        .DCACHE_LINES             (DCACHE_LINES),
        .DCACHE_WORD_OFFSET_BITS  (DCACHE_WORD_OFFSET_BITS),
        .DCACHE_INDEX_BITS        (DCACHE_INDEX_BITS),
        .DCACHE_TAG_BITS          (DCACHE_TAG_BITS)
    ) i_dcache (
        .clk                         (clk),
        .rst_n                       (rst_n),

        .lookup_en_i                 (cache_lookup_en),
        .lookup_index_i              (cache_lookup_index),
        .lookup_word_offset_i        (cache_lookup_word_offset),
        .lookup_tag_o                (cache_lookup_tag),
        .lookup_data_o               (cache_lookup_data),
        .lookup_valid_o              (cache_lookup_valid),

        .line_invalidate_i           (cache_line_invalidate),
        .line_invalidate_index_i     (cache_line_invalidate_index),

        .refill_we_i                 (cache_refill_we),
        .refill_index_i              (cache_refill_index),
        .refill_word_offset_i        (cache_refill_word_offset),
        .refill_data_i               (cache_refill_data),

        .line_commit_i               (cache_line_commit),
        .line_commit_index_i         (cache_line_commit_index),
        .line_commit_tag_i           (cache_line_commit_tag),

        .store_we_i                  (cache_store_we),
        .store_index_i               (cache_store_index),
        .store_word_offset_i         (cache_store_word_offset),
        .store_data_i                (cache_store_data)
    );

    dcache_controller #(
        .DCACHE_ADDR_WIDTH        (DCACHE_ADDR_WIDTH),
        .DCACHE_DATA_WIDTH        (DCACHE_DATA_WIDTH),
        .DCACHE_WORD_BYTES        (DCACHE_WORD_BYTES),
        .DCACHE_LINE_WORDS        (DCACHE_LINE_WORDS),
        .DCACHE_OFFSET_BITS       (DCACHE_OFFSET_BITS),
        .DCACHE_WORD_OFFSET_BITS  (DCACHE_WORD_OFFSET_BITS),
        .DCACHE_INDEX_BITS        (DCACHE_INDEX_BITS),
        .DCACHE_TAG_BITS          (DCACHE_TAG_BITS),
        .DCACHE_REFILL_CNT_WIDTH  (DCACHE_REFILL_CNT_WIDTH),
        .DCACHE_BYTE_OFFSET_BITS  (DCACHE_BYTE_OFFSET_BITS),
        .DCACHE_NO_WRITE_ALLOCATE  (DCACHE_NO_WRITE_ALLOCATE),
        .DCACHE_AXI_BURST_ENABLE   (DCACHE_AXI_BURST_ENABLE),
`ifdef SCR1_DCACHE_VICTIM_EN
        .DCACHE_VICTIM_LINES       (DCACHE_VICTIM_LINES),
        .DCACHE_VICTIM_ENTRY_BITS  (DCACHE_VICTIM_ENTRY_BITS),
`endif
        .DCACHE_MAX_READ_BURST_BEATS (DCACHE_MAX_READ_BURST_BEATS)
    ) i_dcache_controller (
        .clk                         (clk),
        .rst_n                       (rst_n),

        .router_req_i                (router_req_i),
        .router_cmd_i                (router_cmd_i),
        .router_width_i              (router_width_i),
        .router_addr_i               (router_addr_i),
        .router_wdata_i              (router_wdata_i),
        .router_req_ack_o            (router_req_ack_o),
        .router_rdata_o              (router_rdata_o),
        .router_resp_o               (router_resp_o),

        .memory_req_o                (ctrl_memory_req),
        .memory_cmd_o                (ctrl_memory_cmd),
        .memory_width_o              (ctrl_memory_width),
        .memory_addr_o               (ctrl_memory_addr),
        .memory_wdata_o              (ctrl_memory_wdata),
        .memory_burst_len_o          (ctrl_memory_burst_len),
        .memory_req_ack_i            (ctrl_memory_req_ack),
        .memory_rvalid_i             (ctrl_memory_rvalid),
        .memory_rlast_i              (ctrl_memory_rlast),
        .memory_rdata_i              (ctrl_memory_rdata),
        .memory_resp_i               (ctrl_memory_resp),

        .cache_lookup_tag_i          (cache_lookup_tag),
        .cache_lookup_data_i         (cache_lookup_data),
        .cache_lookup_valid_i        (cache_lookup_valid),

        .cache_lookup_en_o           (cache_lookup_en),
        .cache_lookup_index_o        (cache_lookup_index),
        .cache_lookup_word_offset_o  (cache_lookup_word_offset),

        .cache_line_invalidate_o       (cache_line_invalidate),
        .cache_line_invalidate_index_o (cache_line_invalidate_index),

        .cache_refill_we_o           (cache_refill_we),
        .cache_refill_index_o        (cache_refill_index),
        .cache_refill_word_offset_o  (cache_refill_word_offset),
        .cache_refill_data_o         (cache_refill_data),

        .cache_line_commit_o         (cache_line_commit),
        .cache_line_commit_index_o   (cache_line_commit_index),
        .cache_line_commit_tag_o     (cache_line_commit_tag),

        .cache_store_we_o            (cache_store_we),
        .cache_store_index_o         (cache_store_index),
        .cache_store_word_offset_o   (cache_store_word_offset),
        .cache_store_data_o          (cache_store_data),

`ifdef SCR1_DCACHE_VICTIM_EN
        .victim_lookup_hit_i         (victim_lookup_hit),
        .victim_lookup_entry_i       (victim_lookup_entry),
        .victim_lookup_data_i        (victim_lookup_data),
        .victim_lookup_line_i        (victim_lookup_line),

        .victim_lookup_en_o          (victim_lookup_en),
        .victim_lookup_tag_o         (victim_lookup_tag),
        .victim_lookup_index_o       (victim_lookup_index),
        .victim_lookup_word_offset_o (victim_lookup_word_offset),

        .victim_write_en_o           (victim_write_en),
        .victim_write_entry_o        (victim_write_entry),
        .victim_write_tag_o          (victim_write_tag),
        .victim_write_index_o        (victim_write_index),
        .victim_write_line_o         (victim_write_line),

        .victim_invalidate_en_o      (victim_invalidate_en),
        .victim_invalidate_entry_o   (victim_invalidate_entry),
`endif // SCR1_DCACHE_VICTIM_EN

        .perf_req_accept_o           (perf_req_accept),
        .perf_lookup_event_o         (perf_lookup_event),
        .perf_lookup_hit_o           (perf_lookup_hit),
        .perf_req_is_store_o         (perf_req_is_store),
        .perf_refill_word_o          (perf_refill_word),
        .perf_refill_burst_o         (perf_refill_burst),
        .perf_burst_error_o          (perf_burst_error),
        .perf_victim_word_hit_o      (perf_victim_word_hit),
        .perf_victim_swap_o          (perf_victim_swap),
        .perf_victim_store_invalidate_o
                                      (perf_victim_store_invalidate)
    );

`ifdef SCR1_DCACHE_VICTIM_EN
    victim_cache #(
        .CACHE_DATA_WIDTH         (DCACHE_DATA_WIDTH),
        .CACHE_LINE_WORDS         (DCACHE_LINE_WORDS),
        .CACHE_WORD_OFFSET_BITS   (DCACHE_WORD_OFFSET_BITS),
        .CACHE_INDEX_BITS         (DCACHE_INDEX_BITS),
        .CACHE_TAG_BITS           (DCACHE_TAG_BITS),
        .VICTIM_LINES             (DCACHE_VICTIM_LINES),
        .VICTIM_ENTRY_BITS        (DCACHE_VICTIM_ENTRY_BITS)
    ) i_dcache_victim_cache (
        .clk                         (clk),
        .rst_n                       (rst_n),

        .victim_lookup_en_i          (victim_lookup_en),
        .victim_lookup_tag_i         (victim_lookup_tag),
        .victim_lookup_index_i       (victim_lookup_index),
        .victim_lookup_word_offset_i (victim_lookup_word_offset),
        .victim_lookup_hit_o         (victim_lookup_hit),
        .victim_lookup_entry_o       (victim_lookup_entry),
        .victim_lookup_data_o        (victim_lookup_data),
        .victim_lookup_line_o        (victim_lookup_line),

        .victim_write_en_i           (victim_write_en),
        .victim_write_entry_i        (victim_write_entry),
        .victim_write_tag_i          (victim_write_tag),
        .victim_write_index_i        (victim_write_index),
        .victim_write_line_i         (victim_write_line),

        .victim_invalidate_en_i      (victim_invalidate_en),
        .victim_invalidate_entry_i   (victim_invalidate_entry)
    );
`endif // SCR1_DCACHE_VICTIM_EN

    // Ordered 4-entry write buffer. Cacheable stores are accepted into the
    // FIFO; reads/refills and MMIO accesses drain older stores and pass through.
    scr1_write_buffer #(
        .ADDR_WIDTH        (DCACHE_ADDR_WIDTH),
        .DATA_WIDTH        (DCACHE_DATA_WIDTH),
        .BUFFER_DEPTH      (DCACHE_WRITE_BUFFER_DEPTH)
    ) i_write_buffer (
        .clk               (clk),
        .rst_n             (rst_n),

        .dcache_req_i      (ctrl_memory_req),
        .dcache_cmd_i      (ctrl_memory_cmd),
        .dcache_width_i    (ctrl_memory_width),
        .dcache_addr_i     (ctrl_memory_addr),
        .dcache_wdata_i     (ctrl_memory_wdata),
        .dcache_burst_len_i (ctrl_memory_burst_len),
        .dcache_req_ack_o   (ctrl_memory_req_ack),
        .dcache_rvalid_o    (ctrl_memory_rvalid),
        .dcache_rlast_o     (ctrl_memory_rlast),
        .dcache_rdata_o    (ctrl_memory_rdata),
        .dcache_resp_o     (ctrl_memory_resp),

        .memory_req_o      (memory_req_o),
        .memory_cmd_o      (memory_cmd_o),
        .memory_width_o    (memory_width_o),
        .memory_addr_o     (memory_addr_o),
        .memory_wdata_o     (memory_wdata_o),
        .memory_burst_len_o (memory_burst_len_o),
        .memory_req_ack_i   (memory_req_ack_i),
        .memory_rvalid_i    (memory_rvalid_i),
        .memory_rlast_i     (memory_rlast_i),
        .memory_rdata_i    (memory_rdata_i),
        .memory_resp_i     (memory_resp_i),

        .buffer_full_o     (wb_full),
        .buffer_empty_o    (wb_empty),
        .buffer_count_o    (wb_count),
        .write_error_o     (wb_write_error),
        .perf_enqueue_o    (wb_perf_enqueue),
        .perf_dequeue_o    (wb_perf_dequeue),
        .perf_full_stall_o (wb_perf_full_stall),
        .drain_idle_o      (drain_idle_o)
    );

`ifdef SCR1_TRGT_SIMULATION
    initial begin
        if (DCACHE_LINE_BYTES < DCACHE_WORD_BYTES) begin
            $fatal(1, "scr1_dcache: line must contain at least one data word");
        end
        if ((DCACHE_LINE_BYTES % DCACHE_WORD_BYTES) != 0) begin
            $fatal(1, "scr1_dcache: line size must be a whole number of words");
        end
        if ((DCACHE_LINE_BYTES & (DCACHE_LINE_BYTES - 1)) != 0) begin
            $fatal(1, "scr1_dcache: line size must be a power of two");
        end
        if ((4096 % DCACHE_LINE_BYTES) != 0) begin
            $fatal(1, "scr1_dcache: line size must divide the AXI 4 KiB boundary");
        end
        if (DCACHE_AXI_BURST_ENABLE
            && (DCACHE_LINE_WORDS > DCACHE_MAX_READ_BURST_BEATS)) begin
            $fatal(1, "scr1_dcache: cache line exceeds maximum read burst");
        end
    end

    logic [63:0] perf_load_accesses;
    logic [63:0] perf_store_accesses;
    logic [63:0] perf_hits;
    logic [63:0] perf_misses;
    logic [63:0] perf_load_misses;
    logic [63:0] perf_store_misses;
    logic [63:0] perf_store_miss_no_allocates;
    logic [63:0] perf_refill_words;
    logic [63:0] perf_refill_bursts;
    logic [63:0] perf_burst_errors;
    logic [63:0] perf_victim_word_hits;
    logic [63:0] perf_victim_swaps;
    logic [63:0] perf_victim_store_invalidates;
    logic [63:0] perf_stall_cycles;
    logic [63:0] perf_wb_enqueues;
    logic [63:0] perf_wb_dequeues;
    logic [63:0] perf_wb_full_stall_cycles;
    logic [DCACHE_WB_COUNT_WIDTH-1:0] perf_wb_max_occupancy;

    logic perf_request_active_q;
    logic perf_router_response;

    assign perf_router_response =
        (router_resp_o == SCR1_MEM_RESP_RDY_OK)
        || (router_resp_o == SCR1_MEM_RESP_RDY_ER);

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            perf_load_accesses    <= 64'd0;
            perf_store_accesses   <= 64'd0;
            perf_hits             <= 64'd0;
            perf_misses           <= 64'd0;
            perf_load_misses      <= 64'd0;
            perf_store_misses             <= 64'd0;
            perf_store_miss_no_allocates <= 64'd0;
            perf_refill_words             <= 64'd0;
            perf_refill_bursts            <= 64'd0;
            perf_burst_errors             <= 64'd0;
            perf_victim_word_hits         <= 64'd0;
            perf_victim_swaps             <= 64'd0;
            perf_victim_store_invalidates <= 64'd0;
            perf_stall_cycles       <= 64'd0;
            perf_wb_enqueues         <= 64'd0;
            perf_wb_dequeues         <= 64'd0;
            perf_wb_full_stall_cycles <= 64'd0;
            perf_wb_max_occupancy    <= '0;
            perf_request_active_q    <= 1'b0;
        end else begin
            if (perf_req_accept) begin
                if (router_cmd_i == SCR1_MEM_CMD_RD) begin
                    perf_load_accesses <= perf_load_accesses + 64'd1;
                end else if (router_cmd_i == SCR1_MEM_CMD_WR) begin
                    perf_store_accesses <= perf_store_accesses + 64'd1;
                end
            end

            if (perf_lookup_event) begin
                if (perf_lookup_hit) begin
                    perf_hits <= perf_hits + 64'd1;
                end else begin
                    perf_misses <= perf_misses + 64'd1;

                    if (perf_req_is_store) begin
                        perf_store_misses <= perf_store_misses + 64'd1;
                        if (DCACHE_NO_WRITE_ALLOCATE) begin
                            perf_store_miss_no_allocates <=
                                perf_store_miss_no_allocates + 64'd1;
                        end
                    end else begin
                        perf_load_misses <= perf_load_misses + 64'd1;
                    end
                end
            end

            if (perf_refill_word) begin
                perf_refill_words <= perf_refill_words + 64'd1;
            end

            if (perf_refill_burst) begin
                perf_refill_bursts <= perf_refill_bursts + 64'd1;
            end

            if (perf_burst_error) begin
                perf_burst_errors <= perf_burst_errors + 64'd1;
            end

            if (perf_victim_word_hit) begin
                perf_victim_word_hits <= perf_victim_word_hits + 64'd1;
            end

            if (perf_victim_swap) begin
                perf_victim_swaps <= perf_victim_swaps + 64'd1;
            end

            if (perf_victim_store_invalidate) begin
                perf_victim_store_invalidates <=
                    perf_victim_store_invalidates + 64'd1;
            end

            if (wb_perf_enqueue) begin
                perf_wb_enqueues <= perf_wb_enqueues + 64'd1;
            end

            if (wb_perf_dequeue) begin
                perf_wb_dequeues <= perf_wb_dequeues + 64'd1;
            end

            if (wb_perf_full_stall) begin
                perf_wb_full_stall_cycles <= perf_wb_full_stall_cycles + 64'd1;
            end

            // Account for the just-accepted enqueue as well as the registered
            // occupancy so a 3 -> 4 transition records max occupancy = 4.
            if (wb_perf_enqueue && !wb_perf_dequeue) begin
                if ((wb_count + 1'b1) > perf_wb_max_occupancy) begin
                    perf_wb_max_occupancy <= wb_count + 1'b1;
                end
            end else if (wb_count > perf_wb_max_occupancy) begin
                perf_wb_max_occupancy <= wb_count;
            end

            if (perf_request_active_q) begin
                perf_stall_cycles <= perf_stall_cycles + 64'd1;
            end

            if (perf_req_accept) begin
                perf_request_active_q <= 1'b1;
            end

            if (perf_router_response) begin
                perf_request_active_q <= 1'b0;
            end
        end
    end

    final begin
        $display("");
        $display("========================================");
        $display(" D-cache counters");
        $display("========================================");
        $display("load accesses  : %0d", perf_load_accesses);
        $display("store accesses : %0d", perf_store_accesses);
        $display("total accesses : %0d",
                 perf_load_accesses + perf_store_accesses);
        $display("hits           : %0d", perf_hits);
        $display("misses         : %0d", perf_misses);
        $display("load misses    : %0d", perf_load_misses);
        $display("store misses   : %0d", perf_store_misses);
        $display("store no-alloc : %0d", perf_store_miss_no_allocates);
        $display("refill words   : %0d", perf_refill_words);
        $display("refill bursts  : %0d", perf_refill_bursts);
        $display("burst errors   : %0d", perf_burst_errors);
        $display("victim hits    : %0d", perf_victim_word_hits);
        $display("victim swaps   : %0d", perf_victim_swaps);
        $display("victim store invalidates : %0d",
                 perf_victim_store_invalidates);
        $display("burst enabled  : %0d", DCACHE_AXI_BURST_ENABLE);
        $display("NWA enabled    : %0d", DCACHE_NO_WRITE_ALLOCATE);
        $display("service cycles : %0d", perf_stall_cycles);
        $display("----------------------------------------");
        $display("Write Buffer");
        $display("stores buffered   : %0d", perf_wb_enqueues);
        $display("stores drained    : %0d", perf_wb_dequeues);
        $display("full stall cycles : %0d", perf_wb_full_stall_cycles);
        $display("max occupancy     : %0d", perf_wb_max_occupancy);
        $display("pending entries   : %0d", wb_count);
        $display("write error       : %0d", wb_write_error);
        $display("========================================");
    end
`endif

endmodule
