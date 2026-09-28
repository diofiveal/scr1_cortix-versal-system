`timescale 1ns/1ps

`include "scr1_memif.svh"
`include "scr1_arch_description.svh"

`default_nettype none

module scr1_icache_tb;

    localparam int unsigned AW = `SCR1_IMEM_AWIDTH;
    localparam int unsigned DW = `SCR1_IMEM_DWIDTH;

    localparam int unsigned ICACHE_SIZE_BYTES = 4096;
    localparam int unsigned ICACHE_LINE_BYTES = 16;
    localparam int unsigned ICACHE_WAYS       = 1;
    localparam int unsigned WORD_BYTES        = DW / 8;
    localparam int unsigned LINE_WORDS        = ICACHE_LINE_BYTES / WORD_BYTES;
    localparam int unsigned LINE_OFFSET_BITS  = $clog2(ICACHE_LINE_BYTES);

    localparam int unsigned CLK_PERIOD_NS   = 10;
    localparam int unsigned MEM_LATENCY     = 2;
    localparam int unsigned MEM_LOG_ENTRIES = 1024;

    logic clk;
    logic rst_n;

    // IMEM router side
    logic                         router_req_ack_o;
    logic                         router_req_i;
    type_scr1_mem_cmd_e           router_cmd_i;
    logic [AW-1:0]                router_addr_i;
    logic [DW-1:0]                router_rdata_o;
    type_scr1_mem_resp_e          router_resp_o;

    // External memory side
    logic                         memory_req_ack_i;
    logic                         memory_req_o;
    type_scr1_mem_cmd_e           memory_cmd_o;
    logic [AW-1:0]                memory_addr_o;
    logic [DW-1:0]                memory_rdata_i;
    type_scr1_mem_resp_e          memory_resp_i;

    scr1_icache #(
        .ICACHE_SIZE_BYTES (ICACHE_SIZE_BYTES),
        .ICACHE_LINE_BYTES (ICACHE_LINE_BYTES),
        .ICACHE_WAYS       (ICACHE_WAYS)
    ) i_icache (
        .clk              (clk),
        .rst_n            (rst_n),

        .router_req_ack_o (router_req_ack_o),
        .router_req_i     (router_req_i),
        .router_cmd_i     (router_cmd_i),
        .router_addr_i    (router_addr_i),
        .router_rdata_o   (router_rdata_o),
        .router_resp_o    (router_resp_o),

        .memory_req_ack_i (memory_req_ack_i),
        .memory_req_o     (memory_req_o),
        .memory_cmd_o     (memory_cmd_o),
        .memory_addr_o    (memory_addr_o),
        .memory_rdata_i   (memory_rdata_i),
        .memory_resp_i    (memory_resp_i)
    );

    initial begin
        clk = 1'b0;
        forever #(CLK_PERIOD_NS / 2) clk = ~clk;
    end

    // -------------------------------------------------------------------------
    // External memory model
    // -------------------------------------------------------------------------

    logic          mem_pending_q;
    int unsigned   mem_latency_cnt_q;
    int unsigned   mem_ack_delay_cfg;
    int unsigned   mem_ack_delay_cnt_q;
    logic [AW-1:0] mem_addr_q;

    int unsigned   external_req_count;
    logic [AW-1:0] accepted_mem_addr_log [0:MEM_LOG_ENTRIES-1];

    logic          force_error_en;
    logic [AW-1:0] force_error_addr;

    // ACK is delayed by mem_ack_delay_cfg complete clock cycles. While ACK is
    // low, the DUT must keep memory_req_o, memory_addr_o and memory_cmd_o stable.
    assign memory_req_ack_i = memory_req_o
                            && !mem_pending_q
                            && (mem_ack_delay_cnt_q == 0);

    function automatic logic [DW-1:0] mem_read_word(
        input logic [AW-1:0] addr
    );
        logic [31:0] word32;
        begin
            word32 = 32'hA500_0000 ^ addr[31:0];
            mem_read_word = '0;
            mem_read_word[31:0] = word32;
        end
    endfunction

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            mem_pending_q       <= 1'b0;
            mem_latency_cnt_q   <= '0;
            mem_ack_delay_cnt_q <= '0;
            mem_addr_q          <= '0;
            memory_resp_i       <= SCR1_MEM_RESP_NOTRDY;
            memory_rdata_i      <= '0;
            external_req_count  <= 0;
        end else begin
            memory_resp_i  <= SCR1_MEM_RESP_NOTRDY;
            memory_rdata_i <= '0;

            if (!mem_pending_q) begin
                if (!memory_req_o) begin
                    mem_ack_delay_cnt_q <= mem_ack_delay_cfg;
                end else if (mem_ack_delay_cnt_q != 0) begin
                    mem_ack_delay_cnt_q <= mem_ack_delay_cnt_q - 1;
                end
            end

            if (memory_req_o && memory_req_ack_i) begin
                if (memory_cmd_o != SCR1_MEM_CMD_RD) begin
                    $fatal(1, "[TB ERROR] ICACHE sent non-read command to memory");
                end

                if (memory_addr_o[1:0] != 2'b00) begin
                    $fatal(
                        1,
                        "[TB ERROR] ICACHE sent unaligned memory address 0x%08h",
                        memory_addr_o
                    );
                end

                if (external_req_count >= MEM_LOG_ENTRIES) begin
                    $fatal(1, "[TB ERROR] Memory request log overflow");
                end

                accepted_mem_addr_log[external_req_count] <= memory_addr_o;
                external_req_count <= external_req_count + 1;

                mem_pending_q       <= 1'b1;
                mem_latency_cnt_q   <= MEM_LATENCY;
                mem_ack_delay_cnt_q <= mem_ack_delay_cfg;
                mem_addr_q          <= memory_addr_o;
            end else if (mem_pending_q) begin
                if (mem_latency_cnt_q <= 1) begin
                    mem_pending_q <= 1'b0;

                    if (force_error_en && (mem_addr_q == force_error_addr)) begin
                        memory_resp_i  <= SCR1_MEM_RESP_RDY_ER;
                        memory_rdata_i <= '0;
                    end else begin
                        memory_resp_i  <= SCR1_MEM_RESP_RDY_OK;
                        memory_rdata_i <= mem_read_word(mem_addr_q);
                    end
                end else begin
                    mem_latency_cnt_q <= mem_latency_cnt_q - 1;
                end
            end
        end
    end

    // -------------------------------------------------------------------------
    // Protocol monitors
    // -------------------------------------------------------------------------

    logic          stalled_req_q;
    logic [AW-1:0] stalled_addr_q;
    type_scr1_mem_cmd_e stalled_cmd_q;
    logic          router_resp_seen_q;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            stalled_req_q       <= 1'b0;
            stalled_addr_q      <= '0;
            stalled_cmd_q       <= SCR1_MEM_CMD_RD;
            router_resp_seen_q  <= 1'b0;
        end else begin
            if (memory_req_o && !memory_req_ack_i) begin
                if (!stalled_req_q) begin
                    stalled_req_q  <= 1'b1;
                    stalled_addr_q <= memory_addr_o;
                    stalled_cmd_q  <= memory_cmd_o;
                end else begin
                    if (memory_addr_o != stalled_addr_q) begin
                        $fatal(
                            1,
                            "[TB ERROR] Memory address changed before ACK: old=0x%08h new=0x%08h",
                            stalled_addr_q,
                            memory_addr_o
                        );
                    end

                    if (memory_cmd_o != stalled_cmd_q) begin
                        $fatal(1, "[TB ERROR] Memory command changed before ACK");
                    end
                end
            end else begin
                stalled_req_q <= 1'b0;
            end

            if (memory_req_o && (memory_cmd_o != SCR1_MEM_CMD_RD)) begin
                $fatal(1, "[TB ERROR] ICACHE must be read-only");
            end

            if (mem_pending_q && memory_req_o) begin
                $fatal(1, "[TB ERROR] ICACHE issued a second request before response");
            end

            if (router_resp_seen_q &&
                (router_resp_o != SCR1_MEM_RESP_NOTRDY)) begin
                $fatal(1, "[TB ERROR] Router response lasted more than one cycle");
            end

            router_resp_seen_q <=
                (router_resp_o != SCR1_MEM_RESP_NOTRDY);
        end
    end

    // -------------------------------------------------------------------------
    // Driver and check tasks
    // -------------------------------------------------------------------------

    task automatic reset_dut();
        begin
            router_req_i      = 1'b0;
            router_cmd_i      = SCR1_MEM_CMD_RD;
            router_addr_i     = '0;
            force_error_en    = 1'b0;
            force_error_addr  = '0;
            mem_ack_delay_cfg = 0;
            rst_n             = 1'b0;

            repeat (5) @(posedge clk);
            @(negedge clk);
            rst_n = 1'b1;
            repeat (3) @(posedge clk);
        end
    endtask

    task automatic do_icache_request(
        input  logic [AW-1:0]       addr,
        input  type_scr1_mem_cmd_e  cmd,
        output logic [DW-1:0]       rdata,
        output type_scr1_mem_resp_e resp
    );
        int unsigned timeout;
        bit          accepted;
        bit          done;
        begin
            rdata    = '0;
            resp     = SCR1_MEM_RESP_NOTRDY;
            accepted = 1'b0;
            done     = 1'b0;

            @(negedge clk);
            router_addr_i = addr;
            router_cmd_i  = cmd;
            router_req_i  = 1'b1;

            timeout = 0;
            while (!accepted) begin
                @(posedge clk);
                #1;
                timeout++;

                if (router_req_i && router_req_ack_o) begin
                    accepted = 1'b1;

                    if (router_resp_o != SCR1_MEM_RESP_NOTRDY) begin
                        rdata = router_rdata_o;
                        resp  = router_resp_o;
                        done  = 1'b1;
                    end
                end

                if (timeout > 1000) begin
                    $fatal(
                        1,
                        "[TB ERROR] Timeout waiting for request acceptance, addr=0x%08h cmd=%0d",
                        addr,
                        cmd
                    );
                end
            end

            @(negedge clk);
            router_req_i  = 1'b0;
            router_addr_i = '0;
            router_cmd_i  = SCR1_MEM_CMD_RD;

            timeout = 0;
            while (!done) begin
                @(posedge clk);
                #1;
                timeout++;

                if (router_resp_o != SCR1_MEM_RESP_NOTRDY) begin
                    rdata = router_rdata_o;
                    resp  = router_resp_o;
                    done  = 1'b1;
                end

                if (timeout > 2000) begin
                    $fatal(
                        1,
                        "[TB ERROR] Timeout waiting for response, addr=0x%08h cmd=%0d",
                        addr,
                        cmd
                    );
                end
            end
        end
    endtask

    task automatic check_refill_addresses(
        input logic [AW-1:0] addr,
        input int unsigned   log_start,
        input int unsigned   request_count,
        input string         test_name
    );
        logic [AW-1:0] line_base;
        logic [AW-1:0] expected_addr;
        int unsigned   word_idx;
        begin
            line_base = {
                addr[AW-1:LINE_OFFSET_BITS],
                {LINE_OFFSET_BITS{1'b0}}
            };

            for (word_idx = 0; word_idx < request_count; word_idx++) begin
                expected_addr = line_base + AW'(word_idx * WORD_BYTES);

                if (accepted_mem_addr_log[log_start + word_idx] != expected_addr) begin
                    $fatal(
                        1,
                        "[TB FAIL] %s: refill address %0d is wrong, expected=0x%08h got=0x%08h",
                        test_name,
                        word_idx,
                        expected_addr,
                        accepted_mem_addr_log[log_start + word_idx]
                    );
                end
            end
        end
    endtask

    task automatic check_read(
        input logic [AW-1:0]       addr,
        input int unsigned         expected_external_req_inc,
        input type_scr1_mem_resp_e expected_resp,
        input string               test_name
    );
        logic [DW-1:0]       rdata;
        logic [DW-1:0]       expected_data;
        type_scr1_mem_resp_e resp;
        int unsigned         req_count_before;
        int unsigned         req_count_after;
        int unsigned         req_delta;
        begin
            req_count_before = external_req_count;

            do_icache_request(addr, SCR1_MEM_CMD_RD, rdata, resp);

            req_count_after = external_req_count;
            req_delta       = req_count_after - req_count_before;

            if (resp != expected_resp) begin
                $fatal(
                    1,
                    "[TB FAIL] %s: wrong response, addr=0x%08h expected=%0d got=%0d",
                    test_name,
                    addr,
                    expected_resp,
                    resp
                );
            end

            if (req_delta != expected_external_req_inc) begin
                $fatal(
                    1,
                    "[TB FAIL] %s: wrong external request count, addr=0x%08h expected=%0d got=%0d",
                    test_name,
                    addr,
                    expected_external_req_inc,
                    req_delta
                );
            end

            if (expected_external_req_inc != 0) begin
                check_refill_addresses(
                    addr,
                    req_count_before,
                    expected_external_req_inc,
                    test_name
                );
            end

            if (expected_resp == SCR1_MEM_RESP_RDY_OK) begin
                expected_data = mem_read_word(addr);

                if (rdata != expected_data) begin
                    $fatal(
                        1,
                        "[TB FAIL] %s: wrong data, addr=0x%08h expected=0x%08h got=0x%08h",
                        test_name,
                        addr,
                        expected_data,
                        rdata
                    );
                end
            end

            $display(
                "[TB PASS] %-42s addr=0x%08h resp=%0d rdata=0x%08h ext_req_inc=%0d",
                test_name,
                addr,
                resp,
                rdata,
                req_delta
            );
        end
    endtask

    task automatic check_write_rejected(
        input logic [AW-1:0] addr,
        input string         test_name
    );
        logic [DW-1:0]       rdata;
        type_scr1_mem_resp_e resp;
        int unsigned         req_count_before;
        begin
            req_count_before = external_req_count;

            do_icache_request(addr, SCR1_MEM_CMD_WR, rdata, resp);

            if (resp != SCR1_MEM_RESP_RDY_ER) begin
                $fatal(
                    1,
                    "[TB FAIL] %s: write command was not rejected, resp=%0d",
                    test_name,
                    resp
                );
            end

            if (external_req_count != req_count_before) begin
                $fatal(
                    1,
                    "[TB FAIL] %s: rejected write reached external memory",
                    test_name
                );
            end

            $display(
                "[TB PASS] %-42s addr=0x%08h resp=%0d ext_req_inc=0",
                test_name,
                addr,
                resp
            );
        end
    endtask

    // -------------------------------------------------------------------------
    // Test sequence
    // -------------------------------------------------------------------------

    initial begin
        if (DW != 32) begin
            $fatal(1, "[TB ERROR] This testbench expects SCR1_IMEM_DWIDTH = 32");
        end

        if (LINE_WORDS != 4) begin
            $fatal(1, "[TB ERROR] This testbench expects four words per cache line");
        end

        if (MEM_LATENCY < 1) begin
            $fatal(1, "[TB ERROR] MEM_LATENCY must be at least one cycle");
        end

        $dumpfile("scr1_icache_tb.vcd");
        $dumpvars(0, scr1_icache_tb);

        reset_dut();

        $display("\n=== Test 1: cold miss and same-line hits ===");
        check_read(AW'(32'h0000_1008), 4, SCR1_MEM_RESP_RDY_OK, "cold miss, requested word 2");
        check_read(AW'(32'h0000_1000), 0, SCR1_MEM_RESP_RDY_OK, "hit word 0");
        check_read(AW'(32'h0000_1004), 0, SCR1_MEM_RESP_RDY_OK, "hit word 1");
        check_read(AW'(32'h0000_1008), 0, SCR1_MEM_RESP_RDY_OK, "hit word 2");
        check_read(AW'(32'h0000_100C), 0, SCR1_MEM_RESP_RDY_OK, "hit word 3");

        $display("\n=== Test 2: same index, different tag ===");
        check_read(AW'(32'h0000_2008), 4, SCR1_MEM_RESP_RDY_OK, "conflict miss");
        check_read(AW'(32'h0000_200C), 0, SCR1_MEM_RESP_RDY_OK, "hit after replacement");
        check_read(AW'(32'h0000_1008), 4, SCR1_MEM_RESP_RDY_OK, "old tag was evicted");

        $display("\n=== Test 3: memory request backpressure ===");
        mem_ack_delay_cfg = 3;
        @(posedge clk);
        check_read(AW'(32'h0000_4014), 4, SCR1_MEM_RESP_RDY_OK, "refill with delayed ACK");
        mem_ack_delay_cfg = 0;
        @(posedge clk);

        $display("\n=== Test 4: cold miss for every requested word offset ===");
        check_read(AW'(32'h0000_5000), 4, SCR1_MEM_RESP_RDY_OK, "cold miss offset 0");
        check_read(AW'(32'h0000_5114), 4, SCR1_MEM_RESP_RDY_OK, "cold miss offset 1");
        check_read(AW'(32'h0000_5228), 4, SCR1_MEM_RESP_RDY_OK, "cold miss offset 2");
        check_read(AW'(32'h0000_533C), 4, SCR1_MEM_RESP_RDY_OK, "cold miss offset 3");

        $display("\n=== Test 5: memory errors during refill ===");
        force_error_en   = 1'b1;
        force_error_addr = AW'(32'h0000_6000);
        check_read(AW'(32'h0000_6008), 1, SCR1_MEM_RESP_RDY_ER, "error on first refill word");
        force_error_en = 1'b0;
        check_read(AW'(32'h0000_6008), 4, SCR1_MEM_RESP_RDY_OK, "retry after first-word error");

        force_error_en   = 1'b1;
        force_error_addr = AW'(32'h0000_611C);
        check_read(AW'(32'h0000_6114), 4, SCR1_MEM_RESP_RDY_ER, "error on last refill word");
        force_error_en = 1'b0;
        check_read(AW'(32'h0000_6114), 4, SCR1_MEM_RESP_RDY_OK, "retry after last-word error");

        $display("\n=== Test 6: reset invalidates cache ===");
        reset_dut();
        check_read(AW'(32'h0000_6114), 4, SCR1_MEM_RESP_RDY_OK, "miss after reset");

        $display("\n=== Test 7: write command is rejected locally ===");
        check_write_rejected(AW'(32'h0000_7000), "reject write command");

        $display("\n============================================================");
        $display(" ALL ICACHE TESTS PASSED");
        $display("============================================================\n");

        repeat (5) @(posedge clk);
        $finish;
    end

endmodule : scr1_icache_tb

`default_nettype wire
