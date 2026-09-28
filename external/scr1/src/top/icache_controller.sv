`include "scr1_memif.svh"
`include "scr1_arch_description.svh"

module icache_controller #(
    parameter int unsigned ICACHE_ADDR_WIDTH,
    parameter int unsigned ICACHE_DATA_WIDTH,
    parameter int unsigned ICACHE_LINE_WORDS,
    parameter int unsigned ICACHE_OFFSET_BITS,
    parameter int unsigned ICACHE_WORD_OFFSET_BITS,
    parameter int unsigned ICACHE_INDEX_BITS,
    parameter int unsigned ICACHE_TAG_BITS,
    parameter int unsigned ICACHE_REFILL_CNT_WIDTH,
    parameter int unsigned ICACHE_BYTE_OFFSET_BITS,
`ifdef SCR1_ICACHE_VICTIM_EN
    parameter int unsigned VICTIM_LINES = 4,
    parameter int unsigned VICTIM_ENTRY_BITS =
        (VICTIM_LINES > 1) ? $clog2(VICTIM_LINES) : 1,
`endif
    parameter bit          ICACHE_AXI_BURST_ENABLE = 1'b1,
    parameter int unsigned ICACHE_MAX_READ_BURST_BEATS = 8
) (
    input  logic                                          clk,
    input  logic                                          rst_n,

    // IMEM router interface
    input  logic                                          router_req_i,
    input  type_scr1_mem_cmd_e                            router_cmd_i,
    input  logic [ICACHE_ADDR_WIDTH-1:0]                  router_addr_i,
    output logic                                          router_req_ack_o,
    output logic [ICACHE_DATA_WIDTH-1:0]                  router_rdata_o,
    output type_scr1_mem_resp_e                           router_resp_o,

    // Backing-memory interface
    output logic                                          memory_req_o,
    output type_scr1_mem_cmd_e                            memory_cmd_o,
    output logic [ICACHE_ADDR_WIDTH-1:0]                  memory_addr_o,
    output logic [7:0]                                    memory_burst_len_o,
    input  logic                                          memory_req_ack_i,
    input  logic                                          memory_rvalid_i,
    input  logic                                          memory_rlast_i,
    input  logic [ICACHE_DATA_WIDTH-1:0]                  memory_rdata_i,
    input  type_scr1_mem_resp_e                           memory_resp_i,

    // Cache-array lookup results
    input  logic [ICACHE_TAG_BITS-1:0]                    cache_lookup_tag_i,
    input  logic [ICACHE_DATA_WIDTH-1:0]                  cache_lookup_data_i,
    input  logic                                          cache_lookup_valid_i,

    // Cache-array controls
    output logic                                          cache_lookup_en_o,
    output logic [ICACHE_INDEX_BITS-1:0]                  cache_lookup_index_o,
    output logic [ICACHE_WORD_OFFSET_BITS-1:0]            cache_lookup_word_offset_o,

    output logic                                          cache_line_invalidate_o,
    output logic [ICACHE_INDEX_BITS-1:0]                  cache_line_invalidate_index_o,

    output logic                                          cache_refill_we_o,
    output logic [ICACHE_INDEX_BITS-1:0]                  cache_refill_index_o,
    output logic [ICACHE_WORD_OFFSET_BITS-1:0]            cache_refill_word_offset_o,
    output logic [ICACHE_DATA_WIDTH-1:0]                  cache_refill_data_o,

    output logic                                          cache_line_commit_o,
    output logic [ICACHE_INDEX_BITS-1:0]                  cache_line_commit_index_o,
    output logic [ICACHE_TAG_BITS-1:0]                    cache_line_commit_tag_o,

`ifdef SCR1_ICACHE_VICTIM_EN
    // Victim cache lookup results
    input logic                                           victim_lookup_hit_o,
    input logic [VICTIM_ENTRY_BITS-1:0]                   victim_lookup_entry_o,
    input logic [ICACHE_DATA_WIDTH-1:0]                   victim_lookup_data_o,
    input logic [ICACHE_LINE_WORDS*ICACHE_DATA_WIDTH-1:0] victim_lookup_line_o,

    // Victim cache controls
    output logic                                           victim_lookup_en_i,
    output logic [ICACHE_TAG_BITS-1:0]                     victim_lookup_tag_i,
    output logic [ICACHE_INDEX_BITS-1:0]                   victim_lookup_index_i,
    output logic [ICACHE_WORD_OFFSET_BITS-1:0]             victim_lookup_word_offset_i,

    output logic                                           victim_write_en_i,
    output logic [VICTIM_ENTRY_BITS-1:0]                   victim_write_entry_i,
    output logic [ICACHE_TAG_BITS-1:0]                     victim_write_tag_i,
    output logic [ICACHE_INDEX_BITS-1:0]                   victim_write_index_i,
    output logic [ICACHE_LINE_WORDS*ICACHE_DATA_WIDTH-1:0] victim_write_line_i,

    // Victim cache entry invalidation
    output logic                                           victim_invalidate_en_i,
    output logic [VICTIM_ENTRY_BITS-1:0]                   victim_invalidate_entry_i,
`endif // SCR1_ICACHE_VICTIM_EN

    // Monitoring events used by the simulation counters in top.
    output logic                                           perf_req_accept_o,
    output logic                                           perf_lookup_event_o,
    output logic                                           perf_lookup_hit_o,
    output logic                                           perf_refill_word_o,
    output logic                                           perf_refill_burst_o,
    output logic                                           perf_burst_error_o,
    output logic                                           perf_victim_word_hit_o,
    output logic                                           perf_victim_swap_o
);

    localparam logic [ICACHE_REFILL_CNT_WIDTH-1:0] REFILL_LAST_CNT =
        ICACHE_REFILL_CNT_WIDTH'(ICACHE_LINE_WORDS - 1);

    typedef enum logic [3:0] {
        IDLE,
        LOOKUP,
`ifdef SCR1_ICACHE_VICTIM_EN
        VICTIM_LOOKUP,
        EVICT_READ_REQ,
        EVICT_READ_WAIT,
        VICTIM_WRITE,
        SWAP_VICTIM_WRITE,
        SWAP_L1_WRITE,
`endif
        REFILL_REQ,
        REFILL_WAIT,
        BYPASS_REQ,
        BYPASS_WAIT,
        ERROR
    } state_icache_e;

    state_icache_e state_q;
    state_icache_e state_d;

    logic [ICACHE_ADDR_WIDTH-1:0]              req_addr_q;
    logic [ICACHE_TAG_BITS-1:0]                req_tag_q;
    logic [ICACHE_INDEX_BITS-1:0]              req_index_q;
    logic [ICACHE_WORD_OFFSET_BITS-1:0]        req_word_offset_q;

    logic [ICACHE_REFILL_CNT_WIDTH-1:0]        refill_cnt_q;
    logic [ICACHE_DATA_WIDTH-1:0]              response_rdata_q;

`ifdef SCR1_ICACHE_VICTIM_EN
    // Victim-fill context. On a true L1+victim miss, the currently indexed
    // valid L1 line is read word-by-word and copied into one victim entry
    // before the new line refill starts.
    logic [ICACHE_REFILL_CNT_WIDTH-1:0]        evict_cnt_q;
    logic [ICACHE_TAG_BITS-1:0]                evicted_tag_q;
    logic [ICACHE_LINE_WORDS*ICACHE_DATA_WIDTH-1:0] evicted_line_q;
    logic [VICTIM_ENTRY_BITS-1:0]              victim_replace_ptr_q;

    // Victim-hit context used by the swap/promotion sequence.
    logic [VICTIM_ENTRY_BITS-1:0]              victim_hit_entry_q;
    logic [ICACHE_LINE_WORDS*ICACHE_DATA_WIDTH-1:0] victim_hit_line_q;
    logic [ICACHE_REFILL_CNT_WIDTH-1:0]        swap_cnt_q;
    logic                                      swap_pending_q;
`endif // SCR1_ICACHE_VICTIM_EN

    logic [ICACHE_TAG_BITS-1:0]                incoming_tag;
    logic                                      incoming_uncached;
    logic [ICACHE_INDEX_BITS-1:0]              incoming_index;
    logic [ICACHE_WORD_OFFSET_BITS-1:0]        incoming_word_offset;

    logic                                      lookup_hit;
    logic                                      refill_last_word;
    logic [ICACHE_ADDR_WIDTH-1:0]              refill_base_addr;
    logic [ICACHE_ADDR_WIDTH-1:0]              refill_word_offset_addr;
    logic [ICACHE_ADDR_WIDTH-1:0]              refill_addr;

    logic                                      refill_start_event;
    logic                                      refill_beat_event;
    logic                                      refill_word_event;
    logic                                      burst_error_event;
    logic                                      burst_error_q;
`ifdef SCR1_ICACHE_VICTIM_EN
    logic                                      evict_start_event;
    logic                                      evict_word_event;
    logic                                      victim_write_event;
    logic                                      victim_hit_event;
    logic                                      evict_last_word;
    logic                                      swap_last_word;
`endif // SCR1_ICACHE_VICTIM_EN

    // 0xFF00_0000..0xFFFF_FFFF is an uncached/MMIO/boot region for a
    // 32-bit SCR1 address space. Testing the most-significant byte makes the
    // range check cheap and keeps these accesses completely out of I-cache.
    assign incoming_uncached =
        (router_addr_i[ICACHE_ADDR_WIDTH-1 -: 8] == 8'hFF);

    assign incoming_tag =
        router_addr_i[
            ICACHE_ADDR_WIDTH-1:
            ICACHE_INDEX_BITS + ICACHE_OFFSET_BITS
        ];

    assign incoming_index =
        router_addr_i[
            ICACHE_INDEX_BITS + ICACHE_OFFSET_BITS - 1:
            ICACHE_OFFSET_BITS
        ];

    assign incoming_word_offset =
        router_addr_i[
            ICACHE_BYTE_OFFSET_BITS + ICACHE_WORD_OFFSET_BITS - 1:
            ICACHE_BYTE_OFFSET_BITS
        ];

    assign lookup_hit =
        cache_lookup_valid_i && (cache_lookup_tag_i == req_tag_q);

    assign refill_last_word = (refill_cnt_q == REFILL_LAST_CNT);
`ifdef SCR1_ICACHE_VICTIM_EN
    assign evict_last_word  = (evict_cnt_q  == REFILL_LAST_CNT);
    assign swap_last_word   = (swap_cnt_q   == REFILL_LAST_CNT);
`endif

    assign refill_base_addr = {
        req_addr_q[ICACHE_ADDR_WIDTH-1:ICACHE_OFFSET_BITS],
        {ICACHE_OFFSET_BITS{1'b0}}
    };

    assign refill_word_offset_addr =
        {{(ICACHE_ADDR_WIDTH - ICACHE_REFILL_CNT_WIDTH){1'b0}}, refill_cnt_q}
        << ICACHE_BYTE_OFFSET_BITS;

    assign refill_addr = refill_base_addr + refill_word_offset_addr;

    always_comb begin
        state_d = state_q;

        router_req_ack_o = 1'b0;
        router_rdata_o   = response_rdata_q;
        router_resp_o    = SCR1_MEM_RESP_NOTRDY;

        memory_req_o       = 1'b0;
        memory_cmd_o       = SCR1_MEM_CMD_RD;
        memory_addr_o      = refill_addr;
        memory_burst_len_o = 8'd0;

        cache_lookup_en_o          = 1'b0;
        cache_lookup_index_o       = incoming_index;
        cache_lookup_word_offset_o = incoming_word_offset;

        cache_line_invalidate_o       = 1'b0;
        cache_line_invalidate_index_o = req_index_q;

        cache_refill_we_o          = 1'b0;
        cache_refill_index_o       = req_index_q;
        cache_refill_word_offset_o = ICACHE_WORD_OFFSET_BITS'(refill_cnt_q);
        cache_refill_data_o        = memory_rdata_i;

        cache_line_commit_o       = 1'b0;
        cache_line_commit_index_o = req_index_q;
        cache_line_commit_tag_o   = req_tag_q;

`ifdef SCR1_ICACHE_VICTIM_EN
        // Victim-cache controls. Lookup uses the latched request address.
        // Write/invalidate are inactive unless explicitly asserted below.
        victim_lookup_en_i          = 1'b0;
        victim_lookup_tag_i         = req_tag_q;
        victim_lookup_index_i       = req_index_q;
        victim_lookup_word_offset_i = req_word_offset_q;

        victim_write_en_i    = 1'b0;
        victim_write_entry_i = victim_replace_ptr_q;
        victim_write_tag_i   = evicted_tag_q;
        victim_write_index_i = req_index_q;
        victim_write_line_i  = evicted_line_q;

        victim_invalidate_en_i    = 1'b0;
        victim_invalidate_entry_i = '0;
`endif // SCR1_ICACHE_VICTIM_EN

        perf_req_accept_o      = 1'b0;
        perf_lookup_event_o    = 1'b0;
        perf_lookup_hit_o      = lookup_hit;
        perf_refill_word_o     = 1'b0;
        perf_refill_burst_o    = 1'b0;
        perf_burst_error_o     = 1'b0;
        perf_victim_word_hit_o = 1'b0;
        perf_victim_swap_o     = 1'b0;

        refill_start_event = 1'b0;
        refill_beat_event  = 1'b0;
        refill_word_event  = 1'b0;
        burst_error_event  = 1'b0;
`ifdef SCR1_ICACHE_VICTIM_EN
        evict_start_event  = 1'b0;
        evict_word_event   = 1'b0;
        victim_write_event = 1'b0;
        victim_hit_event   = 1'b0;
`endif // SCR1_ICACHE_VICTIM_EN

        case (state_q)
            IDLE: begin
                if (router_req_i) begin
                    router_req_ack_o = 1'b1;

                    if (router_cmd_i == SCR1_MEM_CMD_RD) begin
                        perf_req_accept_o = 1'b1;

                        // Uncached 0xFFxx_xxxx accesses bypass TAG/DATA BRAM
                        // entirely: no lookup, no fill, no valid/tag update.
                        if (incoming_uncached) begin
                            state_d = BYPASS_REQ;
                        end else begin
                            cache_lookup_en_o = 1'b1;
                            state_d = LOOKUP;
                        end
                    end else begin
                        state_d = ERROR;
                    end
                end
            end

            LOOKUP: begin
                perf_lookup_event_o = 1'b1;

                if (lookup_hit) begin
                    router_rdata_o = cache_lookup_data_i;
                    router_resp_o = SCR1_MEM_RESP_RDY_OK;
                    state_d = IDLE;
                end else begin
`ifdef SCR1_ICACHE_VICTIM_EN
                    // Do not destroy the currently indexed L1 line yet.
                    // First check whether the requested line is present in
                    // the fully-associative victim cache.
                    state_d = VICTIM_LOOKUP;
`else
                    // No victim cache: discard the direct-mapped resident and
                    // start the ordinary lower-memory refill immediately.
                    cache_line_invalidate_o = 1'b1;
                    refill_start_event       = 1'b1;
                    state_d                  = REFILL_REQ;
`endif
                end
            end

`ifdef SCR1_ICACHE_VICTIM_EN
            VICTIM_LOOKUP: begin
                victim_lookup_en_i = 1'b1;

                if (victim_lookup_hit_o) begin
                    // Count each requested instruction word served by Victim Cache.
                    perf_victim_word_hit_o = 1'b1;

                    // Capture the hit entry and the complete victim line.
                    // If L1 currently holds a valid line, read it first and
                    // exchange the two lines. Otherwise promote the victim line
                    // into the empty L1 slot and free the victim entry.
                    victim_hit_event = 1'b1;

                    if (cache_lookup_valid_i) begin
                        evict_start_event = 1'b1;
                        state_d = EVICT_READ_REQ;
                    end else begin
                        victim_invalidate_en_i    = 1'b1;
                        victim_invalidate_entry_i = victim_lookup_entry_o;
                        state_d = SWAP_L1_WRITE;
                    end
                end else if (cache_lookup_valid_i) begin
                    // True miss and a valid line currently occupies this L1
                    // index. Preserve that line in Victim before refilling L1.
                    evict_start_event = 1'b1;
                    state_d = EVICT_READ_REQ;
                end else begin
                    // Cold/invalid L1 line: nothing useful to preserve.
                    cache_line_invalidate_o = 1'b1;
                    refill_start_event = 1'b1;
                    state_d = REFILL_REQ;
                end
            end

            EVICT_READ_REQ: begin
                // The L1 data RAM is synchronous, so request one word here...
                cache_lookup_en_o          = 1'b1;
                cache_lookup_index_o       = req_index_q;
                cache_lookup_word_offset_o =
                    ICACHE_WORD_OFFSET_BITS'(evict_cnt_q);
                state_d = EVICT_READ_WAIT;
            end

            EVICT_READ_WAIT: begin
                // ...and capture that word one cycle later.
                evict_word_event = 1'b1;

                if (evict_last_word) begin
                    if (swap_pending_q) begin
                        state_d = SWAP_VICTIM_WRITE;
                    end else begin
                        state_d = VICTIM_WRITE;
                    end
                end else begin
                    state_d = EVICT_READ_REQ;
                end
            end

            VICTIM_WRITE: begin
                // Copy the complete displaced L1 line into the next RR victim
                // entry, then invalidate L1 and start the normal refill.
                victim_write_en_i = 1'b1;
                victim_write_event = 1'b1;

                cache_line_invalidate_o = 1'b1;
                refill_start_event = 1'b1;
                state_d = REFILL_REQ;
            end

            SWAP_VICTIM_WRITE: begin
                // Replace the victim-hit entry with the line displaced from L1.
                // This state is entered only for a real Victim <-> L1 swap.
                // The round-robin pointer is intentionally not advanced here.
                perf_victim_swap_o   = 1'b1;
                victim_write_en_i    = 1'b1;
                victim_write_entry_i = victim_hit_entry_q;
                victim_write_tag_i   = evicted_tag_q;
                victim_write_index_i = req_index_q;
                victim_write_line_i  = evicted_line_q;

                cache_line_invalidate_o = 1'b1;
                state_d = SWAP_L1_WRITE;
            end

            SWAP_L1_WRITE: begin
                // Write the victim-hit line into L1 using the existing refill
                // port. One cache word is written per cycle.
                cache_refill_we_o          = 1'b1;
                cache_refill_index_o       = req_index_q;
                cache_refill_word_offset_o =
                    ICACHE_WORD_OFFSET_BITS'(swap_cnt_q);
                cache_refill_data_o = victim_hit_line_q[
                    ICACHE_DATA_WIDTH*swap_cnt_q +: ICACHE_DATA_WIDTH
                ];

                if (swap_last_word) begin
                    cache_line_commit_o       = 1'b1;
                    cache_line_commit_index_o = req_index_q;
                    cache_line_commit_tag_o   = req_tag_q;

                    router_rdata_o = victim_hit_line_q[
                        ICACHE_DATA_WIDTH*req_word_offset_q +: ICACHE_DATA_WIDTH
                    ];
                    router_resp_o = SCR1_MEM_RESP_RDY_OK;
                    state_d = IDLE;
                end
            end
`endif // SCR1_ICACHE_VICTIM_EN

            REFILL_REQ: begin
                memory_req_o  = 1'b1;
                memory_cmd_o  = SCR1_MEM_CMD_RD;

                if (ICACHE_AXI_BURST_ENABLE) begin
                    // One aligned AXI request fetches the complete cache line.
                    memory_addr_o      = refill_base_addr;
                    memory_burst_len_o = 8'(ICACHE_LINE_WORDS - 1);
                end else begin
                    // Legacy AHB/single-beat path: one request per cache word.
                    memory_addr_o      = refill_addr;
                    memory_burst_len_o = 8'd0;
                end

                if (memory_req_ack_i) begin
                    if (ICACHE_AXI_BURST_ENABLE) begin
                        perf_refill_burst_o = 1'b1;
                    end
                    state_d = REFILL_WAIT;
                end
            end

            REFILL_WAIT: begin
                memory_cmd_o = SCR1_MEM_CMD_RD;

                if (ICACHE_AXI_BURST_ENABLE) begin
                    memory_addr_o      = refill_base_addr;
                    memory_burst_len_o = 8'(ICACHE_LINE_WORDS - 1);

                    // The AXI bridge exposes one pulse per accepted R beat.
                    if (memory_rvalid_i) begin
                        refill_beat_event = 1'b1;

                        if ((memory_resp_i == SCR1_MEM_RESP_RDY_OK)
                            && !burst_error_q) begin
                            cache_refill_we_o  = 1'b1;
                            perf_refill_word_o = 1'b1;
                            refill_word_event  = 1'b1;
                        end else if (memory_resp_i == SCR1_MEM_RESP_RDY_ER) begin
                            burst_error_event = 1'b1;
                        end

                        // RLAST must coincide with the configured final beat.
                        if (memory_rlast_i != refill_last_word) begin
                            burst_error_event = 1'b1;
                        end

                        if (memory_rlast_i) begin
                            if (refill_last_word
                                && (memory_resp_i == SCR1_MEM_RESP_RDY_OK)
                                && !burst_error_q) begin
                                cache_line_commit_o = 1'b1;

                                if (req_word_offset_q
                                    == ICACHE_WORD_OFFSET_BITS'(refill_cnt_q)) begin
                                    router_rdata_o = memory_rdata_i;
                                end
                                router_resp_o = SCR1_MEM_RESP_RDY_OK;
                            end else begin
                                // Early RLAST, a previous beat error, or a late
                                // RLAST after the expected line length.
                                router_resp_o    = SCR1_MEM_RESP_RDY_ER;
                                perf_burst_error_o = 1'b1;
                            end
                            state_d = IDLE;
                        end
                    end
                end else begin
                    memory_addr_o      = refill_addr;
                    memory_burst_len_o = 8'd0;

                    if (memory_resp_i == SCR1_MEM_RESP_RDY_OK) begin
                        cache_refill_we_o  = 1'b1;
                        perf_refill_word_o = 1'b1;
                        refill_beat_event  = 1'b1;
                        refill_word_event  = 1'b1;

                        if (refill_last_word) begin
                            cache_line_commit_o = 1'b1;

                            if (req_word_offset_q
                                == ICACHE_WORD_OFFSET_BITS'(refill_cnt_q)) begin
                                router_rdata_o = memory_rdata_i;
                            end
                            router_resp_o = SCR1_MEM_RESP_RDY_OK;
                            state_d = IDLE;
                        end else begin
                            state_d = REFILL_REQ;
                        end
                    end else if (memory_resp_i == SCR1_MEM_RESP_RDY_ER) begin
                        state_d = ERROR;
                    end
                end
            end

            BYPASS_REQ: begin
                memory_req_o  = 1'b1;
                memory_cmd_o  = SCR1_MEM_CMD_RD;
                memory_addr_o = req_addr_q;

                if (memory_req_ack_i) begin
                    state_d = BYPASS_WAIT;
                end
            end

            BYPASS_WAIT: begin
                memory_cmd_o  = SCR1_MEM_CMD_RD;
                memory_addr_o = req_addr_q;

                if (memory_resp_i == SCR1_MEM_RESP_RDY_OK) begin
                    router_rdata_o = memory_rdata_i;
                    router_resp_o  = SCR1_MEM_RESP_RDY_OK;
                    state_d = IDLE;
                end else if (memory_resp_i == SCR1_MEM_RESP_RDY_ER) begin
                    router_resp_o = SCR1_MEM_RESP_RDY_ER;
                    state_d = IDLE;
                end
            end

            ERROR: begin
                router_resp_o = SCR1_MEM_RESP_RDY_ER;
                state_d = IDLE;
            end

            default: begin
                state_d = IDLE;
            end
        endcase
    end

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state_q           <= IDLE;
            req_addr_q        <= '0;
            req_tag_q         <= '0;
            req_index_q       <= '0;
            req_word_offset_q <= '0;
            refill_cnt_q       <= '0;
            response_rdata_q   <= '0;
`ifdef SCR1_ICACHE_VICTIM_EN
            evict_cnt_q        <= '0;
            evicted_tag_q       <= '0;
            evicted_line_q      <= '0;
            victim_replace_ptr_q <= '0;
            victim_hit_entry_q   <= '0;
            victim_hit_line_q    <= '0;
            swap_cnt_q           <= '0;
            swap_pending_q       <= 1'b0;
`endif
            burst_error_q        <= 1'b0;
        end else begin
            state_q <= state_d;

            if ((state_q == IDLE)
                && router_req_i
                && (router_cmd_i == SCR1_MEM_CMD_RD)) begin
                req_addr_q        <= router_addr_i;
                req_tag_q         <= incoming_tag;
                req_index_q       <= incoming_index;
                req_word_offset_q <= incoming_word_offset;
            end

`ifdef SCR1_ICACHE_VICTIM_EN
            if (victim_hit_event) begin
                victim_hit_entry_q <= victim_lookup_entry_o;
                victim_hit_line_q  <= victim_lookup_line_o;
                swap_cnt_q         <= '0;
                swap_pending_q     <= cache_lookup_valid_i;
            end else begin
                if ((state_q == SWAP_L1_WRITE) && !swap_last_word) begin
                    swap_cnt_q <= swap_cnt_q + 1'b1;
                end

                if ((state_q == SWAP_VICTIM_WRITE)
                    || ((state_q == SWAP_L1_WRITE) && swap_last_word)
                    || ((state_q == VICTIM_LOOKUP) && !victim_lookup_hit_o)) begin
                    swap_pending_q <= 1'b0;
                end
            end

            if (evict_start_event) begin
                evict_cnt_q    <= '0;
                evicted_tag_q  <= cache_lookup_tag_i;
                evicted_line_q <= '0;
            end else if (evict_word_event) begin
                evicted_line_q[
                    ICACHE_DATA_WIDTH*evict_cnt_q +: ICACHE_DATA_WIDTH
                ] <= cache_lookup_data_i;

                if (!evict_last_word) begin
                    evict_cnt_q <= evict_cnt_q + 1'b1;
                end
            end

            if (victim_write_event) begin
                if (victim_replace_ptr_q
                    == VICTIM_ENTRY_BITS'(VICTIM_LINES - 1)) begin
                    victim_replace_ptr_q <= '0;
                end else begin
                    victim_replace_ptr_q <= victim_replace_ptr_q + 1'b1;
                end
            end
`endif // SCR1_ICACHE_VICTIM_EN

            if (refill_start_event) begin
                refill_cnt_q  <= '0;
                burst_error_q <= 1'b0;
            end else begin
                if (refill_beat_event && !refill_last_word) begin
                    refill_cnt_q <= refill_cnt_q + 1'b1;
                end
                if (burst_error_event) begin
                    burst_error_q <= 1'b1;
                end
            end

            if (refill_word_event
                && (req_word_offset_q
                    == ICACHE_WORD_OFFSET_BITS'(refill_cnt_q))) begin
                response_rdata_q <= memory_rdata_i;
            end
        end
    end

`ifdef SCR1_TRGT_SIMULATION
    initial begin
        if ((ICACHE_DATA_WIDTH % 8) != 0) begin
            $fatal(1, "icache_controller: data width must be byte aligned");
        end
        if (ICACHE_AXI_BURST_ENABLE
            && ((ICACHE_LINE_WORDS < 1)
                || (ICACHE_LINE_WORDS > ICACHE_MAX_READ_BURST_BEATS))) begin
            $fatal(1, "icache_controller: line exceeds maximum AXI read burst");
        end
        if ((ICACHE_MAX_READ_BURST_BEATS < 1)
            || (ICACHE_MAX_READ_BURST_BEATS > 256)) begin
            $fatal(1, "icache_controller: invalid maximum AXI burst length");
        end
    end

    always_ff @(posedge clk) begin
        if (rst_n && ICACHE_AXI_BURST_ENABLE
            && (state_q == REFILL_WAIT) && memory_rvalid_i) begin
            assert (memory_rlast_i == refill_last_word)
                else $error("icache_controller: AXI RLAST position mismatch");
        end
    end
`endif

endmodule
