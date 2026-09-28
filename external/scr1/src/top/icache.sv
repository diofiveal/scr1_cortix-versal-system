module icache #(
    parameter int unsigned ICACHE_DATA_WIDTH,
    parameter int unsigned ICACHE_LINE_WORDS,
    parameter int unsigned ICACHE_LINES,
    parameter int unsigned ICACHE_WORD_OFFSET_BITS,
    parameter int unsigned ICACHE_INDEX_BITS,
    parameter int unsigned ICACHE_TAG_BITS
) (
    input  logic                                      clk,
    input  logic                                      rst_n,

    // Synchronous lookup port.
    input  logic                                      lookup_en_i,
    input  logic [ICACHE_INDEX_BITS-1:0]              lookup_index_i,
    input  logic [ICACHE_WORD_OFFSET_BITS-1:0]        lookup_word_offset_i,
    output logic [ICACHE_TAG_BITS-1:0]                lookup_tag_o,
    output logic [ICACHE_DATA_WIDTH-1:0]              lookup_data_o,
    output logic                                      lookup_valid_o,

    input  logic                                      line_invalidate_i,
    input  logic [ICACHE_INDEX_BITS-1:0]              line_invalidate_index_i,

    input  logic                                      refill_we_i,
    input  logic [ICACHE_INDEX_BITS-1:0]              refill_index_i,
    input  logic [ICACHE_WORD_OFFSET_BITS-1:0]        refill_word_offset_i,
    input  logic [ICACHE_DATA_WIDTH-1:0]              refill_data_i,

    input  logic                                      line_commit_i,
    input  logic [ICACHE_INDEX_BITS-1:0]              line_commit_index_i,
    input  logic [ICACHE_TAG_BITS-1:0]                line_commit_tag_i
);

    localparam int unsigned ICACHE_DATA_WORDS =
        ICACHE_LINES * ICACHE_LINE_WORDS;
    localparam int unsigned ICACHE_DATA_ADDR_WIDTH =
        ICACHE_INDEX_BITS + ICACHE_WORD_OFFSET_BITS;

    // ---------------------------------------------------------------------
    // DATA RAM: canonical 1R/1W synchronous Block-RAM inference template.
    // ---------------------------------------------------------------------
    (* ram_style = "block" *)
    logic [ICACHE_DATA_WIDTH-1:0] data_array [0:ICACHE_DATA_WORDS-1];

    logic [ICACHE_DATA_ADDR_WIDTH-1:0] lookup_data_addr;
    logic [ICACHE_DATA_ADDR_WIDTH-1:0] refill_data_addr;

    assign lookup_data_addr = {lookup_index_i, lookup_word_offset_i};
    assign refill_data_addr = {refill_index_i, refill_word_offset_i};

    // Read port B.
    always_ff @(posedge clk) begin
        if (lookup_en_i) begin
            lookup_data_o <= data_array[lookup_data_addr];
        end
    end

    // Write port A.
    always_ff @(posedge clk) begin
        if (refill_we_i) begin
            data_array[refill_data_addr] <= refill_data_i;
        end
    end

    // ---------------------------------------------------------------------
    // TAG RAM: synchronous 1R/1W Block-RAM inference template.
    // ---------------------------------------------------------------------
    (* ram_style = "block" *)
    logic [ICACHE_TAG_BITS-1:0] tag_array [0:ICACHE_LINES-1];

    always_ff @(posedge clk) begin
        if (lookup_en_i) begin
            lookup_tag_o <= tag_array[lookup_index_i];
        end
    end

    always_ff @(posedge clk) begin
        if (line_commit_i) begin
            tag_array[line_commit_index_i] <= line_commit_tag_i;
        end
    end

    // Valid bits remain resettable FFs. See dcache.sv for the rationale.
    logic [ICACHE_LINES-1:0] valid_array;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            valid_array    <= '0;
            lookup_valid_o <= 1'b0;
        end else begin
            if (lookup_en_i) begin
                lookup_valid_o <= valid_array[lookup_index_i];
            end

            if (line_invalidate_i) begin
                valid_array[line_invalidate_index_i] <= 1'b0;
            end

            if (line_commit_i) begin
                valid_array[line_commit_index_i] <= 1'b1;
            end
        end
    end

endmodule
