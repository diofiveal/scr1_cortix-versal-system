// Cache and CPU performance monitor. This module is simulation-only and is
// deliberately excluded from FPGA/ASIC builds.
`ifdef SCR1_TRGT_SIMULATION

module cache_perf_monitor #(
    parameter string CACHE_NAME    = "Cache",
    parameter bit    HAS_VICTIM    = 1'b0,
    parameter bit    IS_DATA_CACHE = 1'b0
) (
    input logic clk,
    input logic rst_n,

    // One-cycle cache-controller events.
    input logic perf_req_accept,
    input logic perf_lookup_event,
    input logic perf_lookup_hit,
    input logic perf_req_is_store,
    input logic perf_refill_word,
    input logic perf_refill_burst,
    input logic perf_burst_error,
    input logic perf_victim_word_hit,
    input logic perf_victim_swap,

    // End-to-end cache/router response and global CPU events.
    input logic response_completed,
    input logic retired_event,
    input logic memory_stall,

    // AXI handshake stalls, kept separate to identify the blocked channel.
    input logic axi_ar_backpressure,
    input logic axi_r_backpressure,
    input logic axi_aw_backpressure,
    input logic axi_w_backpressure,
    input logic axi_b_backpressure
);

    longint unsigned cycle_count;
    longint unsigned retired_count;

    longint unsigned accepted_requests;
    longint unsigned completed_requests;
    longint unsigned cache_lookups;
    longint unsigned hits;
    longint unsigned misses;
    longint unsigned load_hits;
    longint unsigned load_misses;
    longint unsigned store_hits;
    longint unsigned store_misses;

    longint unsigned victim_hits;
    longint unsigned victim_swaps;
    longint unsigned refill_words;
    longint unsigned refill_bursts;
    longint unsigned burst_errors;

    longint unsigned total_latency;
    longint unsigned hit_latency_sum;
    longint unsigned miss_latency_sum;
    longint unsigned victim_latency_sum;
    longint unsigned memory_miss_latency_sum;
    longint unsigned load_latency_sum;
    longint unsigned store_latency_sum;

    longint unsigned hit_completions;
    longint unsigned miss_completions;
    longint unsigned victim_completions;
    longint unsigned memory_miss_completions;
    longint unsigned load_completions;
    longint unsigned store_completions;
    longint unsigned uncached_completions;

    longint unsigned memory_stall_cycles;
    longint unsigned axi_backpressure_cycles;
    longint unsigned axi_ar_backpressure_cycles;
    longint unsigned axi_r_backpressure_cycles;
    longint unsigned axi_aw_backpressure_cycles;
    longint unsigned axi_w_backpressure_cycles;
    longint unsigned axi_b_backpressure_cycles;

    longint unsigned request_start_cycle;
    logic            request_pending;
    logic            current_was_hit;
    logic            current_was_miss;
    logic            current_was_victim_hit;
    logic            current_is_store;

    wire axi_any_backpressure =
        axi_ar_backpressure || axi_r_backpressure ||
        axi_aw_backpressure || axi_w_backpressure ||
        axi_b_backpressure;

    // A lookup hit can complete in the same cycle in which the lookup event is
    // observed. Include the current event instead of relying only on registers.
    wire completion_is_hit =
        current_was_hit || (perf_lookup_event && perf_lookup_hit);
    wire completion_is_miss =
        current_was_miss || (perf_lookup_event && !perf_lookup_hit);
    wire completion_is_victim_hit =
        current_was_victim_hit || perf_victim_word_hit;
    wire completion_is_store =
        current_is_store ||
        (perf_lookup_event && IS_DATA_CACHE && perf_req_is_store);

    wire [63:0] completed_latency =
        cycle_count - request_start_cycle + 64'd1;

    function automatic real safe_ratio(
        input longint unsigned numerator,
        input longint unsigned denominator
    );
        begin
            if (denominator == 0) begin
                safe_ratio = 0.0;
            end else begin
                safe_ratio = real'(numerator) / real'(denominator);
            end
        end
    endfunction

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            cycle_count                    <= 0;
            retired_count                  <= 0;
            accepted_requests              <= 0;
            completed_requests             <= 0;
            cache_lookups                   <= 0;
            hits                            <= 0;
            misses                          <= 0;
            load_hits                       <= 0;
            load_misses                     <= 0;
            store_hits                      <= 0;
            store_misses                    <= 0;
            victim_hits                     <= 0;
            victim_swaps                    <= 0;
            refill_words                    <= 0;
            refill_bursts                   <= 0;
            burst_errors                    <= 0;
            total_latency                   <= 0;
            hit_latency_sum                 <= 0;
            miss_latency_sum                <= 0;
            victim_latency_sum              <= 0;
            memory_miss_latency_sum         <= 0;
            load_latency_sum                <= 0;
            store_latency_sum               <= 0;
            hit_completions                 <= 0;
            miss_completions                <= 0;
            victim_completions              <= 0;
            memory_miss_completions         <= 0;
            load_completions                <= 0;
            store_completions               <= 0;
            uncached_completions            <= 0;
            memory_stall_cycles             <= 0;
            axi_backpressure_cycles         <= 0;
            axi_ar_backpressure_cycles      <= 0;
            axi_r_backpressure_cycles       <= 0;
            axi_aw_backpressure_cycles      <= 0;
            axi_w_backpressure_cycles       <= 0;
            axi_b_backpressure_cycles       <= 0;
            request_start_cycle             <= 0;
            request_pending                 <= 1'b0;
            current_was_hit                 <= 1'b0;
            current_was_miss                <= 1'b0;
            current_was_victim_hit          <= 1'b0;
            current_is_store                <= 1'b0;
        end else begin
            cycle_count <= cycle_count + 1;

            if (retired_event) begin
                retired_count <= retired_count + 1;
            end

            if (memory_stall) begin
                memory_stall_cycles <= memory_stall_cycles + 1;
            end

            if (axi_any_backpressure) begin
                axi_backpressure_cycles <= axi_backpressure_cycles + 1;
            end
            if (axi_ar_backpressure) begin
                axi_ar_backpressure_cycles <= axi_ar_backpressure_cycles + 1;
            end
            if (axi_r_backpressure) begin
                axi_r_backpressure_cycles <= axi_r_backpressure_cycles + 1;
            end
            if (axi_aw_backpressure) begin
                axi_aw_backpressure_cycles <= axi_aw_backpressure_cycles + 1;
            end
            if (axi_w_backpressure) begin
                axi_w_backpressure_cycles <= axi_w_backpressure_cycles + 1;
            end
            if (axi_b_backpressure) begin
                axi_b_backpressure_cycles <= axi_b_backpressure_cycles + 1;
            end

            if (perf_req_accept) begin
                accepted_requests          <= accepted_requests + 1;
                request_start_cycle         <= cycle_count;
                request_pending             <= 1'b1;
                current_was_hit             <= 1'b0;
                current_was_miss            <= 1'b0;
                current_was_victim_hit      <= 1'b0;
                current_is_store            <= 1'b0;
            end

            if (perf_lookup_event) begin
                cache_lookups       <= cache_lookups + 1;
                current_was_hit     <= perf_lookup_hit;
                current_was_miss    <= !perf_lookup_hit;
                current_is_store    <= IS_DATA_CACHE && perf_req_is_store;

                if (perf_lookup_hit) begin
                    hits <= hits + 1;
                    if (IS_DATA_CACHE) begin
                        if (perf_req_is_store) begin
                            store_hits <= store_hits + 1;
                        end else begin
                            load_hits <= load_hits + 1;
                        end
                    end
                end else begin
                    misses <= misses + 1;
                    if (IS_DATA_CACHE) begin
                        if (perf_req_is_store) begin
                            store_misses <= store_misses + 1;
                        end else begin
                            load_misses <= load_misses + 1;
                        end
                    end
                end
            end

            if (perf_victim_word_hit) begin
                victim_hits            <= victim_hits + 1;
                current_was_victim_hit <= 1'b1;
            end
            if (perf_victim_swap) begin
                victim_swaps <= victim_swaps + 1;
            end
            if (perf_refill_word) begin
                refill_words <= refill_words + 1;
            end
            if (perf_refill_burst) begin
                refill_bursts <= refill_bursts + 1;
            end
            if (perf_burst_error) begin
                burst_errors <= burst_errors + 1;
            end

            if (response_completed && request_pending) begin
                completed_requests <= completed_requests + 1;
                total_latency      <= total_latency + completed_latency;
                request_pending    <= 1'b0;

                if (completion_is_hit) begin
                    hit_completions <= hit_completions + 1;
                    hit_latency_sum <= hit_latency_sum + completed_latency;
                end else if (completion_is_miss) begin
                    miss_completions <= miss_completions + 1;
                    miss_latency_sum <= miss_latency_sum + completed_latency;

                    if (HAS_VICTIM && completion_is_victim_hit) begin
                        victim_completions <= victim_completions + 1;
                        victim_latency_sum <=
                            victim_latency_sum + completed_latency;
                    end else begin
                        memory_miss_completions <=
                            memory_miss_completions + 1;
                        memory_miss_latency_sum <=
                            memory_miss_latency_sum + completed_latency;
                    end
                end else begin
                    // Accepted transactions without a lookup are uncached/MMIO.
                    uncached_completions <= uncached_completions + 1;
                end

                if (IS_DATA_CACHE &&
                    (completion_is_hit || completion_is_miss)) begin
                    if (completion_is_store) begin
                        store_completions <= store_completions + 1;
                        store_latency_sum <=
                            store_latency_sum + completed_latency;
                    end else begin
                        load_completions <= load_completions + 1;
                        load_latency_sum <=
                            load_latency_sum + completed_latency;
                    end
                end
            end
        end
    end

    final begin : print_metrics
        longint unsigned cacheable_completions;
        longint unsigned lower_level_misses;
        real hit_rate;
        real miss_rate;
        real effective_miss_rate;
        real victim_hit_rate;
        real amat;
        real overall_service_latency;
        real avg_hit_latency;
        real avg_miss_latency;
        real miss_penalty;
        real cpi;
        real mpki;
        real lower_level_mpki;

        cacheable_completions = hit_completions + miss_completions;
        lower_level_misses = (misses >= victim_hits)
                           ? (misses - victim_hits) : 0;

        hit_rate = 100.0 * safe_ratio(hits, cache_lookups);
        miss_rate = 100.0 * safe_ratio(misses, cache_lookups);
        effective_miss_rate =
            100.0 * safe_ratio(lower_level_misses, cache_lookups);
        victim_hit_rate = 100.0 * safe_ratio(victim_hits, misses);

        amat = safe_ratio(hit_latency_sum + miss_latency_sum,
                          cacheable_completions);
        overall_service_latency =
            safe_ratio(total_latency, completed_requests);
        avg_hit_latency = safe_ratio(hit_latency_sum, hit_completions);
        avg_miss_latency = safe_ratio(miss_latency_sum, miss_completions);
        miss_penalty = (avg_miss_latency >= avg_hit_latency)
                     ? (avg_miss_latency - avg_hit_latency) : 0.0;

        cpi = safe_ratio(cycle_count, retired_count);
        mpki = 1000.0 * safe_ratio(misses, retired_count);
        lower_level_mpki =
            1000.0 * safe_ratio(lower_level_misses, retired_count);

        $display("");
        $display("============================================================");
        $display(" %s performance metrics", CACHE_NAME);
        $display("============================================================");
        $display("CPU cycles                    : %0d", cycle_count);
        $display("retired instructions          : %0d", retired_count);
        $display("CPI                            : %0.4f", cpi);
        $display("accepted requests              : %0d", accepted_requests);
        $display("completed requests             : %0d", completed_requests);
        $display("pending request at finish      : %0d", request_pending);
        $display("cache lookups                  : %0d", cache_lookups);
        $display("L1 hits                        : %0d", hits);
        $display("L1 misses                      : %0d", misses);
        $display("L1 hit rate                    : %0.4f %%", hit_rate);
        $display("L1 miss rate                   : %0.4f %%", miss_rate);
        $display("L1 MPKI                        : %0.4f", mpki);
        $display("lower-level misses             : %0d", lower_level_misses);
        $display("effective lower miss rate      : %0.4f %%",
                 effective_miss_rate);
        $display("lower-level MPKI               : %0.4f", lower_level_mpki);
        $display("AMAT, cacheable requests       : %0.4f cycles", amat);
        $display("average hit latency            : %0.4f cycles",
                 avg_hit_latency);
        $display("average miss latency           : %0.4f cycles",
                 avg_miss_latency);
        $display("miss penalty (miss-hit)        : %0.4f cycles",
                 miss_penalty);
        $display("average all-request latency    : %0.4f cycles",
                 overall_service_latency);
        $display("uncached/MMIO completions      : %0d",
                 uncached_completions);

        if (HAS_VICTIM) begin
            $display("victim hits                    : %0d", victim_hits);
            $display("victim swaps                   : %0d", victim_swaps);
            $display("victim hit rate / L1 misses    : %0.4f %%",
                     victim_hit_rate);
            $display("average victim-hit latency     : %0.4f cycles",
                     safe_ratio(victim_latency_sum,
                                victim_completions));
            $display("average memory-miss latency    : %0.4f cycles",
                     safe_ratio(memory_miss_latency_sum,
                                memory_miss_completions));
        end

        if (IS_DATA_CACHE) begin
            $display("cacheable load hits            : %0d", load_hits);
            $display("cacheable load misses          : %0d", load_misses);
            $display("cacheable store hits           : %0d", store_hits);
            $display("cacheable store misses         : %0d", store_misses);
            $display("average load latency           : %0.4f cycles",
                     safe_ratio(load_latency_sum, load_completions));
            $display("average store latency          : %0.4f cycles",
                     safe_ratio(store_latency_sum, store_completions));
        end

        $display("refill words                   : %0d", refill_words);
        $display("refill bursts                  : %0d", refill_bursts);
        $display("words per refill burst         : %0.4f",
                 safe_ratio(refill_words, refill_bursts));
        $display("burst errors                   : %0d", burst_errors);
        $display("CPU memory-stall cycles        : %0d",
                 memory_stall_cycles);
        $display("memory-stall share             : %0.4f %%",
                 100.0 * safe_ratio(memory_stall_cycles, cycle_count));
        $display("memory-stall CPI contribution  : %0.4f",
                 safe_ratio(memory_stall_cycles, retired_count));
        $display("AXI backpressure cycles        : %0d",
                 axi_backpressure_cycles);
        $display("AXI backpressure share         : %0.4f %%",
                 100.0 * safe_ratio(axi_backpressure_cycles,
                                    cycle_count));
        $display("  AR channel                   : %0d",
                 axi_ar_backpressure_cycles);
        $display("  R channel                    : %0d",
                 axi_r_backpressure_cycles);
        $display("  AW channel                   : %0d",
                 axi_aw_backpressure_cycles);
        $display("  W channel                    : %0d",
                 axi_w_backpressure_cycles);
        $display("  B channel                    : %0d",
                 axi_b_backpressure_cycles);
        $display("============================================================");
    end

endmodule : cache_perf_monitor

`endif // SCR1_TRGT_SIMULATION
