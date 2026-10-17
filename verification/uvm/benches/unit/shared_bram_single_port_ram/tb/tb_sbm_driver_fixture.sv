`timescale 1ns/1ps
// UVM component fixture only. This is not the DUT and cannot establish RAM
// data, scrub, reset qualification, ticket receipt or Vivado requirements.
module tb_sbm_driver_fixture;
  import uvm_pkg::*;
  import sbm_pkg::*;
  logic clk=0;
  always #5 clk=~clk;
  sbm_ram_if #(SBM_TICKET_W) bus(clk);
  initial begin
    bus.rst_n=1;
    bus.platform_zero_init_i=0;
    bus.coherent_isolation_proven_i=0;
    bus.ram_rd_en_i=0;
    bus.ram_wr_en_i=0;
    bus.ram_addr_i=0;
    bus.ram_wr_data_i=0;
    bus.ram_wr_strb_i=0;
    bus.ram_issue_ticket_i=0;
    bus.init_write_en_o=0;
    bus.init_commit_o=0;
    bus.init_addr_o=0;
    bus.bram_init_done_o=1;
    bus.init_active_o=0;
    bus.ram_idle_o=1;
    bus.init_fault_o=0;
    bus.ram_rd_valid_o=0;
    bus.ram_wr_commit_valid_o=0;
    bus.ram_rd_data_o=0;
    bus.ram_rd_ticket_o=0;
    bus.ram_wr_commit_ticket_o=0;
    uvm_config_db#(sbm_vif_t)::set(null,"uvm_test_top*","vif",bus);
    run_test("sbm_driver_fixture_test");
  end
  assign bus.physical_rd_en_o = (bus.ram_rd_en_i === 1'b1 && bus.ram_wr_en_i === 1'b0);
  assign bus.physical_wr_en_o = (bus.ram_wr_en_i === 1'b1 && bus.ram_rd_en_i === 1'b0)
                                ? bus.ram_wr_strb_i : 4'b0;
endmodule
