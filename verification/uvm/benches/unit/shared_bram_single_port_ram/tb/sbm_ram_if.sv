interface sbm_ram_if #(parameter int TICKET_W = 95) (input logic clk);
  logic rst_n;
  logic platform_zero_init_i, coherent_isolation_proven_i;
  logic ram_rd_en_i, ram_wr_en_i;
  logic [13:0] ram_addr_i;
  logic [31:0] ram_wr_data_i;
  logic [3:0] ram_wr_strb_i;
  logic [TICKET_W-1:0] ram_issue_ticket_i;

  logic [31:0] ram_rd_data_o;
  logic ram_rd_valid_o;
  logic [TICKET_W-1:0] ram_rd_ticket_o;
  logic ram_wr_commit_valid_o;
  logic [TICKET_W-1:0] ram_wr_commit_ticket_o;
  logic physical_rd_en_o;
  logic [3:0] physical_wr_en_o;
  logic init_write_en_o;
  logic [13:0] init_addr_o;
  logic init_commit_o;
  logic bram_init_done_o, init_active_o, ram_idle_o, init_fault_o;
endinterface
