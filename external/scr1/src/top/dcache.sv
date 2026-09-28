module dcache #(
    parameter int unsigned DCACHE_DATA_WIDTH,
    parameter int unsigned DCACHE_LINE_WORDS,
    parameter int unsigned DCACHE_LINES,
    parameter int unsigned DCACHE_WORD_OFFSET_BITS,
    parameter int unsigned DCACHE_INDEX_BITS,
    parameter int unsigned DCACHE_TAG_BITS
) (
    input  logic                                      clk,
    input  logic                                      rst_n,

    // Synchronous lookup port.
    input  logic                                      lookup_en_i,
    input  logic [DCACHE_INDEX_BITS-1:0]              lookup_index_i,
    input  logic [DCACHE_WORD_OFFSET_BITS-1:0]        lookup_word_offset_i,
    output logic [DCACHE_TAG_BITS-1:0]                lookup_tag_o,
    output logic [DCACHE_DATA_WIDTH-1:0]              lookup_data_o,
    output logic                                      lookup_valid_o,

    // Victim invalidation before refill.
    input  logic                                      line_invalidate_i,
    input  logic [DCACHE_INDEX_BITS-1:0]              line_invalidate_index_i,

    // Refill write port.
    input  logic                                      refill_we_i,
    input  logic [DCACHE_INDEX_BITS-1:0]              refill_index_i,
    input  logic [DCACHE_WORD_OFFSET_BITS-1:0]        refill_word_offset_i,
    input  logic [DCACHE_DATA_WIDTH-1:0]              refill_data_i,

    // Tag commit after complete line refill.
    input  logic                                      line_commit_i,
    input  logic [DCACHE_INDEX_BITS-1:0]              line_commit_index_i,
    input  logic [DCACHE_TAG_BITS-1:0]                line_commit_tag_i,

    // Write-through store update after backing-store write completes.
    input  logic                                      store_we_i,
    input  logic [DCACHE_INDEX_BITS-1:0]              store_index_i,
    input  logic [DCACHE_WORD_OFFSET_BITS-1:0]        store_word_offset_i,
    input  logic [DCACHE_DATA_WIDTH-1:0]              store_data_i
);

    // The cache organization already assumes power-of-two line/set geometry.
    // Using concatenation instead of multiplication keeps the RAM address path
    // simple and matches standard Vivado Block-RAM inference templates.
    localparam int unsigned DCACHE_DATA_WORDS =
        DCACHE_LINES * DCACHE_LINE_WORDS;
    localparam int unsigned DCACHE_DATA_ADDR_WIDTH =
        DCACHE_INDEX_BITS + DCACHE_WORD_OFFSET_BITS;

    // ---------------------------------------------------------------------
    // DATA RAM
    // ---------------------------------------------------------------------
    // One synchronous read port + one synchronous write port.
    //
    // IMPORTANT: the old code had two independent write statements to the same
    // array (refill and store). Even though the controller makes those events
    // mutually exclusive, the RTL described two possible write ports. That can
    // prevent a clean single/simple-dual-port BRAM inference and cause a LUT/FF
    // implementation. Here both write sources are explicitly muxed into ONE
    // physical write port.
    // ---------------------------------------------------------------------
    (* ram_style = "block" *)
    logic [DCACHE_DATA_WIDTH-1:0] data_array [0:DCACHE_DATA_WORDS-1];

    logic [DCACHE_DATA_ADDR_WIDTH-1:0] lookup_data_addr;
    logic [DCACHE_DATA_ADDR_WIDTH-1:0] data_wr_addr;
    logic [DCACHE_DATA_WIDTH-1:0]      data_wr_data;
    logic                               data_wr_en;

    assign lookup_data_addr = {lookup_index_i, lookup_word_offset_i};

    always_comb begin
        data_wr_en   = 1'b0;
        data_wr_addr = '0;
        data_wr_data = '0;

        // Controller states make refill_we_i and store_we_i mutually exclusive.
        // Refill gets priority as a defensive choice if that invariant is ever
        // violated.
        if (refill_we_i) begin
            data_wr_en   = 1'b1;
            data_wr_addr = {refill_index_i, refill_word_offset_i};
            data_wr_data = refill_data_i;
        end else if (store_we_i) begin
            data_wr_en   = 1'b1;
            data_wr_addr = {store_index_i, store_word_offset_i};
            data_wr_data = store_data_i;
        end
    end

    // Read port B: synchronous, registered output.
    always_ff @(posedge clk) begin
        if (lookup_en_i) begin
            lookup_data_o <= data_array[lookup_data_addr];
        end
    end

    // Write port A: exactly one write address/data pair per cycle.
    always_ff @(posedge clk) begin
        if (data_wr_en) begin
            data_array[data_wr_addr] <= data_wr_data;
        end
    end

    // ---------------------------------------------------------------------
    // TAG RAM
    // ---------------------------------------------------------------------
    // Tag storage also uses the canonical 1R/1W synchronous BRAM template.
    // It is intentionally not reset; validity makes stale tag contents harmless.
    // ---------------------------------------------------------------------
    (* ram_style = "block" *)
    logic [DCACHE_TAG_BITS-1:0] tag_array [0:DCACHE_LINES-1];

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

    // ---------------------------------------------------------------------
    // VALID storage
    // ---------------------------------------------------------------------
    // Keep valid bits in resettable FFs. A resettable RAM array generally does
    // not map cleanly to 7-series BRAM. This array is tiny compared with DATA
    // RAM and, more importantly, guarantees that all cache lines are invalid
    // immediately after rst_n without a multi-cycle RAM-clear sweep.
    // ---------------------------------------------------------------------
    logic [DCACHE_LINES-1:0] valid_array;

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

`ifdef SCR1_TRGT_SIMULATION
    // If this fires, the controller is asking the single BRAM write port to do
    // two different writes in one clock. Fix the controller rather than adding
    // another RAM write port.
    always_ff @(posedge clk) begin
        if (rst_n) begin
            assert (!(refill_we_i && store_we_i))
                else $error("dcache: refill_we_i and store_we_i asserted together");
        end
    end
`endif

endmodule
