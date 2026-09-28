`include "scr1_memif.svh"
`include "scr1_arch_description.svh"

module scr1_icache #(
    parameter int unsigned ICACHE_SIZE_BYTES          = 16384,
    parameter int unsigned ICACHE_LINE_BYTES          = 16,
    parameter int unsigned ICACHE_WAYS                = 1,
`ifdef SCR1_ICACHE_VICTIM_EN
    parameter int unsigned ICACHE_VICTIM_LINES        = 4,
`endif
    parameter bit          ICACHE_AXI_BURST_ENABLE    = 1'b1,
    parameter int unsigned ICACHE_MAX_READ_BURST_BEATS = 8
) (
    input  logic                         clk,
    input  logic                         rst_n,

    // IMEM router interface
    output logic                         router_req_ack_o,
    input  logic                         router_req_i,
    input  type_scr1_mem_cmd_e           router_cmd_i,
    input  logic [`SCR1_IMEM_AWIDTH-1:0] router_addr_i,
    output logic [`SCR1_IMEM_DWIDTH-1:0] router_rdata_o,
    output type_scr1_mem_resp_e          router_resp_o,

    // AHB / AXI bridge interface
    input  logic                         memory_req_ack_i,
    output logic                         memory_req_o,
    output type_scr1_mem_cmd_e           memory_cmd_o,
    output logic [`SCR1_IMEM_AWIDTH-1:0] memory_addr_o,
    output logic [7:0]                   memory_burst_len_o,
    input  logic                         memory_rvalid_i,
    input  logic                         memory_rlast_i,
    input  logic [`SCR1_IMEM_DWIDTH-1:0] memory_rdata_i,
    input  type_scr1_mem_resp_e          memory_resp_i,

    //cache performance monitor
    output logic                         perf_req_accept,
    output logic                         perf_lookup_event,
    output logic                         perf_lookup_hit,
    output logic                         perf_refill_word,
    output logic                         perf_refill_burst,
    output logic                         perf_burst_error,
    output logic                         perf_victim_word_hit,
    output logic                         perf_victim_swap
);

    localparam int unsigned ICACHE_ADDR_WIDTH = `SCR1_IMEM_AWIDTH;
    localparam int unsigned ICACHE_DATA_WIDTH = `SCR1_IMEM_DWIDTH;
    localparam int unsigned ICACHE_WORD_BYTES = ICACHE_DATA_WIDTH / 8;
    localparam int unsigned ICACHE_LINE_WORDS =
        ICACHE_LINE_BYTES / ICACHE_WORD_BYTES;
    localparam int unsigned ICACHE_LINES =
        ICACHE_SIZE_BYTES / ICACHE_LINE_BYTES;
    localparam int unsigned ICACHE_OFFSET_BITS =
        $clog2(ICACHE_LINE_BYTES);
    localparam int unsigned ICACHE_WORD_OFFSET_BITS =
        (ICACHE_LINE_WORDS > 1) ? $clog2(ICACHE_LINE_WORDS) : 1;
    localparam int unsigned ICACHE_INDEX_BITS =
        (ICACHE_LINES > 1) ? $clog2(ICACHE_LINES) : 1;
    localparam int unsigned ICACHE_TAG_BITS =
        ICACHE_ADDR_WIDTH - ICACHE_OFFSET_BITS - ICACHE_INDEX_BITS;
    localparam int unsigned ICACHE_REFILL_CNT_WIDTH =
        (ICACHE_LINE_WORDS > 1) ? $clog2(ICACHE_LINE_WORDS) : 1;
    localparam int unsigned ICACHE_BYTE_OFFSET_BITS =
        (ICACHE_WORD_BYTES > 1) ? $clog2(ICACHE_WORD_BYTES) : 1;
`ifdef SCR1_ICACHE_VICTIM_EN
    localparam int unsigned ICACHE_VICTIM_ENTRY_BITS =
        (ICACHE_VICTIM_LINES > 1) ? $clog2(ICACHE_VICTIM_LINES) : 1;
`endif

    // ICACHE_WAYS is kept for top-level compatibility. The current cache is
    // still direct mapped; this refactor changes structure, not associativity.

    logic                                     cache_lookup_en;
    logic [ICACHE_INDEX_BITS-1:0]             cache_lookup_index;
    logic [ICACHE_WORD_OFFSET_BITS-1:0]       cache_lookup_word_offset;
    logic [ICACHE_TAG_BITS-1:0]               cache_lookup_tag;
    logic [ICACHE_DATA_WIDTH-1:0]             cache_lookup_data;
    logic                                     cache_lookup_valid;

    logic                                     cache_line_invalidate;
    logic [ICACHE_INDEX_BITS-1:0]             cache_line_invalidate_index;

    logic                                     cache_refill_we;
    logic [ICACHE_INDEX_BITS-1:0]             cache_refill_index;
    logic [ICACHE_WORD_OFFSET_BITS-1:0]       cache_refill_word_offset;
    logic [ICACHE_DATA_WIDTH-1:0]             cache_refill_data;

    logic                                     cache_line_commit;
    logic [ICACHE_INDEX_BITS-1:0]             cache_line_commit_index;
    logic [ICACHE_TAG_BITS-1:0]               cache_line_commit_tag;

`ifdef SCR1_ICACHE_VICTIM_EN
    // Controller <-> I-cache victim cache
    logic                                     victim_lookup_en;
    logic [ICACHE_TAG_BITS-1:0]               victim_lookup_tag;
    logic [ICACHE_INDEX_BITS-1:0]             victim_lookup_index;
    logic [ICACHE_WORD_OFFSET_BITS-1:0]       victim_lookup_word_offset;
    logic                                     victim_lookup_hit;
    logic [ICACHE_VICTIM_ENTRY_BITS-1:0]      victim_lookup_entry;
    logic [ICACHE_DATA_WIDTH-1:0]             victim_lookup_data;
    logic [ICACHE_LINE_WORDS*ICACHE_DATA_WIDTH-1:0]
                                              victim_lookup_line;

    logic                                     victim_write_en;
    logic [ICACHE_VICTIM_ENTRY_BITS-1:0]      victim_write_entry;
    logic [ICACHE_TAG_BITS-1:0]               victim_write_tag;
    logic [ICACHE_INDEX_BITS-1:0]             victim_write_index;
    logic [ICACHE_LINE_WORDS*ICACHE_DATA_WIDTH-1:0]
                                              victim_write_line;

    logic                                     victim_invalidate_en;
    logic [ICACHE_VICTIM_ENTRY_BITS-1:0]      victim_invalidate_entry;
`endif // SCR1_ICACHE_VICTIM_EN

    //logic                                     perf_req_accept;
    //logic                                     perf_lookup_event;
    //logic                                     perf_lookup_hit;
    //logic                                     perf_refill_word;
    //logic                                     perf_refill_burst;
    //logic                                     perf_burst_error;
    //logic                                     perf_victim_word_hit;
    //logic                                     perf_victim_swap;

    icache #(
        .ICACHE_DATA_WIDTH        (ICACHE_DATA_WIDTH),
        .ICACHE_LINE_WORDS        (ICACHE_LINE_WORDS),
        .ICACHE_LINES             (ICACHE_LINES),
        .ICACHE_WORD_OFFSET_BITS  (ICACHE_WORD_OFFSET_BITS),
        .ICACHE_INDEX_BITS        (ICACHE_INDEX_BITS),
        .ICACHE_TAG_BITS          (ICACHE_TAG_BITS)
    ) i_icache (
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
        .line_commit_tag_i           (cache_line_commit_tag)
    );

`ifdef SCR1_ICACHE_VICTIM_EN
    // Four-entry (by default) fully-associative victim cache. It stores whole
    // lines displaced from the direct-mapped L1 I-cache.
    victim_cache #(
        .CACHE_DATA_WIDTH         (ICACHE_DATA_WIDTH),
        .CACHE_LINE_WORDS         (ICACHE_LINE_WORDS),
        .CACHE_WORD_OFFSET_BITS   (ICACHE_WORD_OFFSET_BITS),
        .CACHE_INDEX_BITS         (ICACHE_INDEX_BITS),
        .CACHE_TAG_BITS           (ICACHE_TAG_BITS),
        .VICTIM_LINES             (ICACHE_VICTIM_LINES),
        .VICTIM_ENTRY_BITS        (ICACHE_VICTIM_ENTRY_BITS)
    ) i_victim_cache (
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
`endif // SCR1_ICACHE_VICTIM_EN

    icache_controller #(
        .ICACHE_ADDR_WIDTH        (ICACHE_ADDR_WIDTH),
        .ICACHE_DATA_WIDTH        (ICACHE_DATA_WIDTH),
        .ICACHE_LINE_WORDS        (ICACHE_LINE_WORDS),
        .ICACHE_OFFSET_BITS       (ICACHE_OFFSET_BITS),
        .ICACHE_WORD_OFFSET_BITS  (ICACHE_WORD_OFFSET_BITS),
        .ICACHE_INDEX_BITS        (ICACHE_INDEX_BITS),
        .ICACHE_TAG_BITS          (ICACHE_TAG_BITS),
        .ICACHE_REFILL_CNT_WIDTH  (ICACHE_REFILL_CNT_WIDTH),
        .ICACHE_BYTE_OFFSET_BITS  (ICACHE_BYTE_OFFSET_BITS),
`ifdef SCR1_ICACHE_VICTIM_EN
        .VICTIM_LINES             (ICACHE_VICTIM_LINES),
        .VICTIM_ENTRY_BITS        (ICACHE_VICTIM_ENTRY_BITS),
`endif
        .ICACHE_AXI_BURST_ENABLE  (ICACHE_AXI_BURST_ENABLE),
        .ICACHE_MAX_READ_BURST_BEATS (ICACHE_MAX_READ_BURST_BEATS)
    ) i_icache_controller (
        .clk                         (clk),
        .rst_n                       (rst_n),

        .router_req_i                (router_req_i),
        .router_cmd_i                (router_cmd_i),
        .router_addr_i               (router_addr_i),
        .router_req_ack_o            (router_req_ack_o),
        .router_rdata_o              (router_rdata_o),
        .router_resp_o               (router_resp_o),

        .memory_req_o                (memory_req_o),
        .memory_cmd_o                (memory_cmd_o),
        .memory_addr_o               (memory_addr_o),
        .memory_burst_len_o          (memory_burst_len_o),
        .memory_req_ack_i            (memory_req_ack_i),
        .memory_rvalid_i             (memory_rvalid_i),
        .memory_rlast_i              (memory_rlast_i),
        .memory_rdata_i              (memory_rdata_i),
        .memory_resp_i               (memory_resp_i),

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

`ifdef SCR1_ICACHE_VICTIM_EN
        .victim_lookup_hit_o         (victim_lookup_hit),
        .victim_lookup_entry_o       (victim_lookup_entry),
        .victim_lookup_data_o        (victim_lookup_data),
        .victim_lookup_line_o        (victim_lookup_line),

        .victim_lookup_en_i          (victim_lookup_en),
        .victim_lookup_tag_i         (victim_lookup_tag),
        .victim_lookup_index_i       (victim_lookup_index),
        .victim_lookup_word_offset_i (victim_lookup_word_offset),

        .victim_write_en_i           (victim_write_en),
        .victim_write_entry_i        (victim_write_entry),
        .victim_write_tag_i          (victim_write_tag),
        .victim_write_index_i        (victim_write_index),
        .victim_write_line_i         (victim_write_line),

        .victim_invalidate_en_i      (victim_invalidate_en),
        .victim_invalidate_entry_i   (victim_invalidate_entry),
`endif // SCR1_ICACHE_VICTIM_EN

        .perf_req_accept_o           (perf_req_accept),
        .perf_lookup_event_o         (perf_lookup_event),
        .perf_lookup_hit_o           (perf_lookup_hit),
        .perf_refill_word_o          (perf_refill_word),
        .perf_refill_burst_o         (perf_refill_burst),
        .perf_burst_error_o          (perf_burst_error),
        .perf_victim_word_hit_o      (perf_victim_word_hit),
        .perf_victim_swap_o          (perf_victim_swap)
    );

`ifdef SCR1_TRGT_SIMULATION
    initial begin
        if (ICACHE_LINE_BYTES < ICACHE_WORD_BYTES) begin
            $fatal(1, "scr1_icache: line must contain at least one data word");
        end
        if ((ICACHE_LINE_BYTES % ICACHE_WORD_BYTES) != 0) begin
            $fatal(1, "scr1_icache: line size must be a whole number of words");
        end
        if ((ICACHE_LINE_BYTES & (ICACHE_LINE_BYTES - 1)) != 0) begin
            $fatal(1, "scr1_icache: line size must be a power of two");
        end
        if ((4096 % ICACHE_LINE_BYTES) != 0) begin
            $fatal(1, "scr1_icache: line size must divide the AXI 4 KiB boundary");
        end
        if (ICACHE_AXI_BURST_ENABLE
            && (ICACHE_LINE_WORDS > ICACHE_MAX_READ_BURST_BEATS)) begin
            $fatal(1, "scr1_icache: cache line exceeds maximum read burst");
        end
    end

    logic [63:0] perf_accesses;
    logic [63:0] perf_hits;
    logic [63:0] perf_misses;
    logic [63:0] perf_refill_words;
    logic [63:0] perf_refill_bursts;
    logic [63:0] perf_burst_errors;
    logic [63:0] perf_stall_cycles;
    logic [63:0] perf_victim_word_hits;
    logic [63:0] perf_victim_swaps;

    logic perf_request_active_q;
    logic perf_router_response;

    assign perf_router_response =
        (router_resp_o == SCR1_MEM_RESP_RDY_OK)
        || (router_resp_o == SCR1_MEM_RESP_RDY_ER);

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            perf_accesses          <= 64'd0;
            perf_hits              <= 64'd0;
            perf_misses            <= 64'd0;
            perf_refill_words      <= 64'd0;
            perf_refill_bursts     <= 64'd0;
            perf_burst_errors      <= 64'd0;
            perf_stall_cycles      <= 64'd0;
            perf_victim_word_hits  <= 64'd0;
            perf_victim_swaps      <= 64'd0;
            perf_request_active_q  <= 1'b0;
        end else begin
            if (perf_req_accept) begin
                perf_accesses <= perf_accesses + 64'd1;
            end

            if (perf_lookup_event) begin
                if (perf_lookup_hit) begin
                    perf_hits <= perf_hits + 64'd1;
                end else begin
                    perf_misses <= perf_misses + 64'd1;
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
        $display(" I-cache counters");
        $display("========================================");
        $display("accesses         : %0d", perf_accesses);
        $display("L1 hits          : %0d", perf_hits);
        $display("L1 misses        : %0d", perf_misses);
        $display("victim word hits : %0d", perf_victim_word_hits);
        $display("victim swaps     : %0d", perf_victim_swaps);
        $display("refill words     : %0d", perf_refill_words);
        $display("refill bursts    : %0d", perf_refill_bursts);
        $display("burst errors     : %0d", perf_burst_errors);
        $display("burst enabled    : %0d", ICACHE_AXI_BURST_ENABLE);
        $display("stall cycles     : %0d", perf_stall_cycles);
        $display("========================================");
    end
`endif

endmodule
