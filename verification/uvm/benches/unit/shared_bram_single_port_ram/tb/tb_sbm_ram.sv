`timescale 1ns/1ps
module tb_sbm_ram;
  import uvm_pkg::*;
  import sbm_pkg::*;
  parameter int READ_LATENCY = 2;
  logic clk = 0;
  always #5.556 clk = ~clk; // nominal 90 MHz at 1 ps resolution
  sbm_ram_if #(SBM_TICKET_W) bus(clk);
  sbm_ram_sva #(.READ_LATENCY(READ_LATENCY)) checks(bus);

`ifdef SBM_REAL_DUT
  // Adapt only this instance if the reviewed physical pin freeze changes.
  shared_bram_single_port_ram #(
    .READ_LATENCY(READ_LATENCY), .SERVICE_TICKET_W(SBM_TICKET_W)
  ) dut (
    .clk(clk), .rst_n(bus.rst_n),
    .platform_zero_init_i(bus.platform_zero_init_i),
    .coherent_isolation_proven_i(bus.coherent_isolation_proven_i),
    .ram_rd_en_i(bus.ram_rd_en_i), .ram_wr_en_i(bus.ram_wr_en_i),
    .ram_addr_i(bus.ram_addr_i), .ram_wr_data_i(bus.ram_wr_data_i),
    .ram_wr_strb_i(bus.ram_wr_strb_i),
    .ram_issue_ticket_i(bus.ram_issue_ticket_i),
    .ram_rd_data_o(bus.ram_rd_data_o),
    .ram_rd_valid_o(bus.ram_rd_valid_o),
    .ram_rd_ticket_o(bus.ram_rd_ticket_o),
    .ram_wr_commit_valid_o(bus.ram_wr_commit_valid_o),
    .ram_wr_commit_ticket_o(bus.ram_wr_commit_ticket_o),
    .physical_rd_en_o(bus.physical_rd_en_o),
    .physical_wr_en_o(bus.physical_wr_en_o),
    .init_write_en_o(bus.init_write_en_o),
    .init_addr_o(bus.init_addr_o),
    .init_commit_o(bus.init_commit_o),
    .bram_init_done_o(bus.bram_init_done_o),
    .init_active_o(bus.init_active_o),
    .ram_idle_o(bus.ram_idle_o),
    .init_fault_o(bus.init_fault_o)
  );
`else
  initial $fatal(1,"SBM_REAL_DUT requires the reviewed shared_bram_single_port_ram RTL source");
`endif

  initial begin
    bus.rst_n = 0;
    bus.platform_zero_init_i = 0;
    bus.coherent_isolation_proven_i = 0;
    bus.ram_rd_en_i = 0;
    bus.ram_wr_en_i = 0;
    bus.ram_addr_i = 0;
    bus.ram_wr_data_i = 0;
    bus.ram_wr_strb_i = 0;
    bus.ram_issue_ticket_i = 0;
    uvm_config_db#(sbm_vif_t)::set(null,"uvm_test_top*","vif",bus);
    uvm_config_db#(int unsigned)::set(null,"uvm_test_top.env.*","read_latency",READ_LATENCY);
    repeat (3) @(posedge clk);
    run_test("sbm_base_test");
  end
endmodule
