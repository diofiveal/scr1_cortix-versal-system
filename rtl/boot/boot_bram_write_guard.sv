// Physical write protection. Addresses are canonical SCR1 byte addresses.
module boot_bram_write_guard (
    input  logic        clk,
    input  logic        rst_n,
    input  logic        write_allowed_i,
    input  logic        clear_fault_i,
    input  logic        host_en_i,
    input  logic [31:0] host_addr_i,
    input  logic [31:0] host_wdata_i,
    input  logic [3:0]  host_we_i,
    output logic        bram_en_o,
    output logic [31:0] bram_addr_o,
    output logic [31:0] bram_wdata_o,
    output logic [3:0]  bram_we_o,
    output logic        violation_o,
    output logic [31:0] violation_addr_o
);
    logic blocked_write;
    assign blocked_write = rst_n && host_en_i && (|host_we_i) && !write_allowed_i;
    assign bram_en_o      = host_en_i && rst_n;
    assign bram_addr_o    = host_addr_i;
    assign bram_wdata_o   = host_wdata_i;
    assign bram_we_o     = host_we_i & {4{write_allowed_i && rst_n}};

    always_ff @(posedge clk) begin
        if (!rst_n) begin
            violation_o      <= 1'b0;
            violation_addr_o <= '0;
        end
        else begin
            if (clear_fault_i) begin
                violation_o      <= 1'b0;
                violation_addr_o <= '0;
            end
            if (blocked_write && (!violation_o || clear_fault_i)) begin
                violation_o      <= 1'b1;
                violation_addr_o <= host_addr_i;
            end
        end
    end
`ifndef SYNTHESIS
    always_ff @(posedge clk) begin
        if (rst_n) begin
            assert (write_allowed_i || bram_we_o == 0)
                else $error("Boot BRAM guard allowed a forbidden write");
        end
    end
`endif
endmodule : boot_bram_write_guard
