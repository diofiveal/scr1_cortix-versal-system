`include "scr1_arch_description.svh"

// Compile this shared implementation when at least one cache uses it. Keeping
// the source in the file list is therefore harmless when both features are off.
`ifdef SCR1_ICACHE_VICTIM_EN
  `define SCR1_VICTIM_CACHE_IMPL_EN
`elsif SCR1_DCACHE_VICTIM_EN
  `define SCR1_VICTIM_CACHE_IMPL_EN
`endif

`ifdef SCR1_VICTIM_CACHE_IMPL_EN

// Generic fully-associative victim cache shared by I-cache and D-cache.
// A victim tag contains the original direct-mapped cache {tag, index}; data is
// stored and exchanged as a complete cache line.
module victim_cache #(
    parameter int unsigned CACHE_DATA_WIDTH,
    parameter int unsigned CACHE_LINE_WORDS,
    parameter int unsigned CACHE_WORD_OFFSET_BITS,
    parameter int unsigned CACHE_INDEX_BITS,
    parameter int unsigned CACHE_TAG_BITS,

    parameter int unsigned VICTIM_LINES = 4,
    parameter int unsigned VICTIM_ENTRY_BITS =
        (VICTIM_LINES > 1) ? $clog2(VICTIM_LINES) : 1
) (
    input  logic                                          clk,
    input  logic                                          rst_n,

    // Fully-associative lookup.
    input  logic                                          victim_lookup_en_i,
    input  logic [CACHE_TAG_BITS-1:0]                     victim_lookup_tag_i,
    input  logic [CACHE_INDEX_BITS-1:0]                   victim_lookup_index_i,
    input  logic [CACHE_WORD_OFFSET_BITS-1:0]             victim_lookup_word_offset_i,
    output logic                                          victim_lookup_hit_o,
    output logic [VICTIM_ENTRY_BITS-1:0]                  victim_lookup_entry_o,
    output logic [CACHE_DATA_WIDTH-1:0]                   victim_lookup_data_o,
    output logic [CACHE_LINE_WORDS*CACHE_DATA_WIDTH-1:0]  victim_lookup_line_o,

    // Complete-line write.
    input  logic                                          victim_write_en_i,
    input  logic [VICTIM_ENTRY_BITS-1:0]                  victim_write_entry_i,
    input  logic [CACHE_TAG_BITS-1:0]                     victim_write_tag_i,
    input  logic [CACHE_INDEX_BITS-1:0]                   victim_write_index_i,
    input  logic [CACHE_LINE_WORDS*CACHE_DATA_WIDTH-1:0]  victim_write_line_i,

    // Entry invalidation, used by promotion and NWA store coherence.
    input  logic                                          victim_invalidate_en_i,
    input  logic [VICTIM_ENTRY_BITS-1:0]                  victim_invalidate_entry_i
);
    localparam int unsigned VICTIM_TAG_BITS = CACHE_TAG_BITS + CACHE_INDEX_BITS;

    logic [VICTIM_LINES-1:0]    valid_array;
    logic [VICTIM_TAG_BITS-1:0] tag_array [0:VICTIM_LINES-1];
    logic [CACHE_DATA_WIDTH-1:0]
        data_array [0:VICTIM_LINES-1] [0:CACHE_LINE_WORDS-1];

    logic [VICTIM_LINES-1:0]    hit_array;
    logic [VICTIM_TAG_BITS-1:0] req_victim_tag;

    assign req_victim_tag = {victim_lookup_tag_i, victim_lookup_index_i};

    always_comb begin
        hit_array             = '0;
        victim_lookup_hit_o   = 1'b0;
        victim_lookup_entry_o = '0;
        victim_lookup_data_o  = '0;
        victim_lookup_line_o  = '0;

        if (victim_lookup_en_i) begin
            // Fully-associative tag lookup
            for (int i = 0; i < VICTIM_LINES; i++) begin
                hit_array[i] = valid_array[i]
                             && (tag_array[i] == req_victim_tag);
            end

            // Priority encoder: choose the first matching entry.
            for (int i = 0; i < VICTIM_LINES; i++) begin
                if (hit_array[i] && !victim_lookup_hit_o) begin
                    victim_lookup_hit_o   = 1'b1;
                    victim_lookup_entry_o = VICTIM_ENTRY_BITS'(i);

                    victim_lookup_data_o =
                        data_array[i][victim_lookup_word_offset_i];

                    for (int w = 0; w < CACHE_LINE_WORDS; w++) begin
                        victim_lookup_line_o[
                            w*CACHE_DATA_WIDTH +: CACHE_DATA_WIDTH
                        ] = data_array[i][w];
                    end
                end
            end
        end
    end

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            valid_array <= '0;
        end else begin
            // Invalidate before a later LOAD can observe a stale NWA store.
            if (victim_invalidate_en_i) begin
                valid_array[victim_invalidate_entry_i] <= 1'b0;
            end

            // A write wins if both controls ever target the same entry.
            if (victim_write_en_i) begin
                valid_array[victim_write_entry_i] <= 1'b1;

                tag_array[victim_write_entry_i] <= {
                    victim_write_tag_i, victim_write_index_i
                };

                for (int w = 0; w < CACHE_LINE_WORDS; w++) begin
                    data_array[victim_write_entry_i][w]
                        <= victim_write_line_i[
                            w*CACHE_DATA_WIDTH +: CACHE_DATA_WIDTH
                        ];
                end
            end
        end
    end

`ifdef SCR1_TRGT_SIMULATION
    initial begin
        if (VICTIM_LINES < 1) begin
            $fatal(1, "victim_cache: VICTIM_LINES must be at least one");
        end
        if (CACHE_LINE_WORDS < 1) begin
            $fatal(1, "victim_cache: line must contain at least one word");
        end
    end
`endif

endmodule

`endif // SCR1_VICTIM_CACHE_IMPL_EN

`ifdef SCR1_VICTIM_CACHE_IMPL_EN
  `undef SCR1_VICTIM_CACHE_IMPL_EN
`endif
