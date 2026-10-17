package sbm_pkg;
  timeunit 1ns;
  timeprecision 1ps;
  import uvm_pkg::*;
  `include "uvm_macros.svh"
  parameter int SBM_TICKET_W = 95;
  parameter int SBM_DEPTH = 16384;
  typedef virtual sbm_ram_if #(SBM_TICKET_W) sbm_vif_t;
  `uvm_analysis_imp_decl(_intent)
  `uvm_analysis_imp_decl(_accept)
  `uvm_analysis_imp_decl(_complete)
  `uvm_analysis_imp_decl(_cycle)
  `uvm_analysis_imp_decl(_watch)

  typedef enum {SBM_IDLE, SBM_READ, SBM_WRITE, SBM_RESET,
                SBM_INIT, SBM_INIT_HOLD, SBM_BOTH, SBM_X_RD,
                SBM_CERTIFY, SBM_DROP_CERT, SBM_X_WR, SBM_X_STRB,
                SBM_Z_RD, SBM_Z_WR, SBM_Z_STRB} sbm_op_e;

  class sbm_item extends uvm_sequence_item;
    rand sbm_op_e op;
    rand bit [13:0] addr;
    rand bit [31:0] data;
    rand bit [3:0] strb;
    rand bit [SBM_TICKET_W-1:0] ticket;
    bit isolation;
    int unsigned hold_cycles = 1;
    int unsigned gap_cycles = 0;
    longint unsigned intent_id;
    `uvm_object_utils_begin(sbm_item)
      `uvm_field_enum(sbm_op_e, op, UVM_DEFAULT)
      `uvm_field_int(addr, UVM_DEFAULT)
      `uvm_field_int(data, UVM_DEFAULT)
      `uvm_field_int(strb, UVM_DEFAULT)
      `uvm_field_int(ticket, UVM_DEFAULT)
      `uvm_field_int(isolation, UVM_DEFAULT)
      `uvm_field_int(hold_cycles, UVM_DEFAULT)
      `uvm_field_int(gap_cycles, UVM_DEFAULT)
      `uvm_field_int(intent_id, UVM_DEFAULT)
    `uvm_object_utils_end
    function new(string name="sbm_item"); super.new(name); endfunction
  endclass

  // A complete clock-edge record. Inputs and old outputs are sampled at the
  // edge; outputs are sampled after the NBA update. Never use driver intent as
  // the scoreboard's evidence of a physical operation.
  class sbm_cycle extends uvm_sequence_item;
    longint unsigned cycle;
    logic rst_n, init_req, isolation, rd, wr;
    logic [13:0] addr;
    logic [31:0] wdata;
    logic [3:0] strb;
    logic [SBM_TICKET_W-1:0] ticket;
    logic pre_wr_valid, pre_rd_valid, pre_done, pre_active;
    logic [SBM_TICKET_W-1:0] pre_wr_ticket;
    logic [SBM_TICKET_W-1:0] pre_rd_ticket;
    logic [31:0] pre_rdata;
    logic [31:0] rdata;
    logic rvalid, wvalid, phys_rd, init_we, init_commit;
    logic [3:0] phys_we;
    logic [13:0] init_addr;
    logic post_phys_rd, post_init_we;
    logic [3:0] post_phys_we;
    logic [13:0] post_init_addr;
    logic [SBM_TICKET_W-1:0] rticket, wticket;
    logic done, active, idle, fault;
    `uvm_object_utils(sbm_cycle)
    function new(string name="sbm_cycle"); super.new(name); endfunction
  endclass

  `include "sbm_agent.svh"
  `include "sbm_intent_audit.svh"
  `include "sbm_scoreboard.svh"
  `include "sbm_watchdog.svh"
  `include "sbm_coverage.svh"
  `include "sbm_env.svh"
  `include "sbm_sequences.svh"
  `include "sbm_tests.svh"
  `include "sbm_resilience_tests.svh"
  `include "sbm_driver_tests.svh"
endpackage
