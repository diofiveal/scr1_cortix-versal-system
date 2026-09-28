// 64 KiB AXI4-Lite boot store with independent AW/W capture.
// SmartConnect converts SCR1 AXI4 read bursts into AXI4-Lite accesses.
// A denied write returns SLVERR AND is independently blocked by the native guard.
module scr1_boot_bram_axil #(
    parameter INIT_FILE = ""
) (
    input  logic        clk,
    input  logic        rst_n,
    input  logic        write_allowed_i,
    input  logic        clear_fault_i,
    input  logic [15:0] s_axil_awaddr_i,
    input  logic [2:0]  s_axil_awprot_i,
    input  logic        s_axil_awvalid_i,
    output logic        s_axil_awready_o,
    input  logic [31:0] s_axil_wdata_i,
    input  logic [3:0]  s_axil_wstrb_i,
    input  logic        s_axil_wvalid_i,
    output logic        s_axil_wready_o,
    output logic [1:0]  s_axil_bresp_o,
    output logic        s_axil_bvalid_o,
    input  logic        s_axil_bready_i,
    input  logic [15:0] s_axil_araddr_i,
    input  logic [2:0]  s_axil_arprot_i,
    input  logic        s_axil_arvalid_i,
    output logic        s_axil_arready_o,
    output logic [31:0] s_axil_rdata_o,
    output logic [1:0]  s_axil_rresp_o,
    output logic        s_axil_rvalid_o,
    input  logic        s_axil_rready_i,
    output logic        boot_violation_o,
    output logic [31:0] boot_violation_addr_o
);
    logic aw_pending_q, w_pending_q, ar_pending_q, read_pending_q;
    logic [15:0] awaddr_q, araddr_q;
    logic [31:0] wdata_q;
    logic [3:0] wstrb_q;
    logic write_issue, read_issue;
    logic host_en, bram_en;
    logic [31:0] host_addr, bram_addr, bram_wdata, bram_rdata;
    logic [3:0] host_we, bram_we;

    assign s_axil_awready_o = rst_n && !aw_pending_q && !s_axil_bvalid_o;
    assign s_axil_wready_o  = rst_n && !w_pending_q && !s_axil_bvalid_o;
    assign s_axil_arready_o = rst_n && !ar_pending_q && !read_pending_q && !s_axil_rvalid_o;
    assign write_issue = rst_n && aw_pending_q && w_pending_q
                       && !s_axil_bvalid_o && !read_pending_q;
    assign read_issue  = rst_n && ar_pending_q && !read_pending_q
                       && !s_axil_rvalid_o && !write_issue;
    assign host_en = (write_issue && awaddr_q[1:0] == 0)
                  || (read_issue && araddr_q[1:0] == 0);
    assign host_addr = 32'hFFFF0000 | {16'd0, write_issue ? awaddr_q : araddr_q};
    assign host_we = (write_issue && awaddr_q[1:0] == 0) ? wstrb_q : 4'd0;

    boot_bram_write_guard u_guard (
        .clk(clk), .rst_n(rst_n),
        .write_allowed_i(write_allowed_i), .clear_fault_i(clear_fault_i),
        .host_en_i(host_en), .host_addr_i(host_addr),
        .host_wdata_i(wdata_q), .host_we_i(aligned_guard_we),
        .bram_en_o(bram_en), .bram_addr_o(bram_addr),
        .bram_wdata_o(bram_wdata), .bram_we_o(bram_we),
        .violation_o(boot_violation_o), .violation_addr_o(boot_violation_addr_o)
    );

    // No reset loop on the RAM array: infer FPGA block RAM, not flip-flops.
    (* ram_style = "block" *) logic [31:0] memory [0:16383];
    initial begin
        if (INIT_FILE != "") $readmemh(INIT_FILE, memory);
    end
    always_ff @(posedge clk) begin
        if (bram_en) begin
            for (int b = 0; b < 4; b = b + 1) begin
                if (bram_we[b]) memory[bram_addr[15:2]][8*b +: 8] <= bram_wdata[8*b +: 8];
            end
            bram_rdata <= memory[bram_addr[15:2]];
        end
    end

    always_ff @(posedge clk) begin
        if (!rst_n) begin
            aw_pending_q   <= 1'b0;
            w_pending_q    <= 1'b0;
            ar_pending_q   <= 1'b0;
            read_pending_q <= 1'b0;
            awaddr_q       <= '0;
            araddr_q       <= '0;
            wdata_q        <= '0;
            wstrb_q        <= '0;
            s_axil_bvalid_o <= 1'b0;
            s_axil_bresp_o  <= 2'b00;
            s_axil_rvalid_o <= 1'b0;
            s_axil_rresp_o  <= 2'b00;
            s_axil_rdata_o  <= '0;
        end
        else begin
            if (s_axil_bvalid_o && s_axil_bready_i) s_axil_bvalid_o <= 1'b0;
            if (s_axil_rvalid_o && s_axil_rready_i) s_axil_rvalid_o <= 1'b0;
            if (s_axil_awvalid_i && s_axil_awready_o) begin
                awaddr_q     <= s_axil_awaddr_i;
                aw_pending_q <= 1'b1;
            end
            if (s_axil_wvalid_i && s_axil_wready_o) begin
                wdata_q     <= s_axil_wdata_i;
                wstrb_q     <= s_axil_wstrb_i;
                w_pending_q <= 1'b1;
            end
            if (s_axil_arvalid_i && s_axil_arready_o) begin
                araddr_q     <= s_axil_araddr_i;
                ar_pending_q <= 1'b1;
            end
            if (write_issue) begin
                aw_pending_q   <= 1'b0;
                w_pending_q    <= 1'b0;
                s_axil_bvalid_o <= 1'b1;
                s_axil_bresp_o  <= ((awaddr_q[1:0] != 0)
                                  || ((|wstrb_q) && !write_allowed_i)) ? 2'b10 : 2'b00;
            end
            if (read_issue) begin
                ar_pending_q <= 1'b0;
                if (araddr_q[1:0] != 0) begin
                    s_axil_rvalid_o <= 1'b1;
                    s_axil_rresp_o  <= 2'b10;
                    s_axil_rdata_o  <= '0;
                end
                else read_pending_q <= 1'b1;
            end
            if (read_pending_q) begin
                read_pending_q <= 1'b0;
                s_axil_rvalid_o <= 1'b1;
                s_axil_rresp_o  <= 2'b00;
                s_axil_rdata_o  <= bram_rdata;
            end
        end
    end
`ifndef SYNTHESIS
    assert property (@(posedge clk) disable iff (!rst_n)
        s_axil_bvalid_o && !s_axil_bready_i |=> s_axil_bvalid_o && $stable(s_axil_bresp_o));
    assert property (@(posedge clk) disable iff (!rst_n)
        s_axil_rvalid_o && !s_axil_rready_i |=> s_axil_rvalid_o && $stable({s_axil_rdata_o,s_axil_rresp_o}));
`endif

    // A malformed unaligned AXI-Lite write must not mutate a RAM word.
    logic [31:0] aligned_guard_addr;
    logic [3:0] aligned_guard_we;
    assign aligned_guard_addr = host_addr;
    assign aligned_guard_we = (host_we) & {4{aligned_guard_addr[1:0] == 2'b00}};

endmodule : scr1_boot_bram_axil
