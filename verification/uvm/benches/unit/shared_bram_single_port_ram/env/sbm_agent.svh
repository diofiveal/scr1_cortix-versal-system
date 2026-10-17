class sbm_sequencer extends uvm_sequencer #(sbm_item);
  `uvm_component_utils(sbm_sequencer)
  function new(string name, uvm_component parent); super.new(name,parent); endfunction
endclass

class sbm_driver extends uvm_driver #(sbm_item);
  `uvm_component_utils(sbm_driver)
  sbm_vif_t vif;
  function new(string name, uvm_component parent); super.new(name,parent); endfunction
  function void build_phase(uvm_phase phase);
    super.build_phase(phase);
    if (!uvm_config_db#(sbm_vif_t)::get(this,"","vif",vif))
      `uvm_fatal("NO_VIF","Missing sbm_ram_if")
  endfunction
  task run_phase(uvm_phase phase);
    sbm_item tr;
    drive_idle();
    forever begin
      @(negedge vif.clk);
      drive_idle();
      tr = null;
      seq_item_port.try_next_item(tr);
      if (tr == null) continue;
      // Inputs settle before the next sampling edge. A following item can
      // issue on the immediately following clock with no inserted idle edge.
      case (tr.op)
        SBM_READ: begin
          vif.ram_rd_en_i = 1'b1;
          vif.ram_addr_i = tr.addr;
          vif.ram_issue_ticket_i = tr.ticket;
        end
        SBM_WRITE: begin
          vif.ram_wr_en_i = 1'b1;
          vif.ram_addr_i = tr.addr;
          vif.ram_wr_data_i = tr.data;
          vif.ram_wr_strb_i = tr.strb;
          vif.ram_issue_ticket_i = tr.ticket;
        end
        SBM_RESET: begin
          vif.rst_n = 1'b0;
          vif.coherent_isolation_proven_i = tr.isolation;
          vif.platform_zero_init_i = 1'b1;
        end
        SBM_INIT: begin
          vif.coherent_isolation_proven_i = tr.isolation;
          vif.platform_zero_init_i = 1'b1;
        end
        SBM_INIT_HOLD: begin
          vif.coherent_isolation_proven_i = tr.isolation;
          vif.platform_zero_init_i = 1'b1;
        end
        SBM_BOTH: begin
          vif.ram_rd_en_i = 1'b1;
          vif.ram_wr_en_i = 1'b1;
          vif.ram_addr_i = tr.addr;
          vif.ram_wr_data_i = tr.data;
          vif.ram_wr_strb_i = tr.strb;
          vif.ram_issue_ticket_i = tr.ticket;
        end
        SBM_X_RD: begin
          vif.ram_rd_en_i = 1'bx;
          vif.ram_addr_i = tr.addr;
          vif.ram_issue_ticket_i = tr.ticket;
        end
        default: ;
      endcase
      repeat ((tr.hold_cycles > 0) ? tr.hold_cycles : 1) @(posedge vif.clk);
      seq_item_port.item_done();
    end
  endtask
  function void drive_idle();
    vif.rst_n = 1'b1;
    vif.platform_zero_init_i = 1'b0;
    vif.coherent_isolation_proven_i = 1'b0;
    vif.ram_rd_en_i = 1'b0;
    vif.ram_wr_en_i = 1'b0;
    vif.ram_addr_i = '0;
    vif.ram_wr_data_i = '0;
    vif.ram_wr_strb_i = '0;
    vif.ram_issue_ticket_i = '0;
  endfunction
endclass

class sbm_monitor extends uvm_component;
  `uvm_component_utils(sbm_monitor)
  sbm_vif_t vif;
  uvm_analysis_port #(sbm_cycle) ap;
  longint unsigned count;
  function new(string name, uvm_component parent);
    super.new(name,parent); ap = new("ap",this);
  endfunction
  function void build_phase(uvm_phase phase);
    super.build_phase(phase);
    if (!uvm_config_db#(sbm_vif_t)::get(this,"","vif",vif))
      `uvm_fatal("NO_VIF","Missing sbm_ram_if")
  endfunction
  task run_phase(uvm_phase phase);
    sbm_cycle c;
    forever begin
      @(posedge vif.clk);
      c = sbm_cycle::type_id::create("c");
      c.cycle = ++count;
      c.rst_n = vif.rst_n;
      c.init_req = vif.platform_zero_init_i;
      c.isolation = vif.coherent_isolation_proven_i;
      c.rd = vif.ram_rd_en_i;
      c.wr = vif.ram_wr_en_i;
      c.addr = vif.ram_addr_i;
      c.wdata = vif.ram_wr_data_i;
      c.strb = vif.ram_wr_strb_i;
      c.ticket = vif.ram_issue_ticket_i;
      c.pre_wr_valid = vif.ram_wr_commit_valid_o;
      c.pre_rd_valid = vif.ram_rd_valid_o;
      c.pre_wr_ticket = vif.ram_wr_commit_ticket_o;
      c.pre_done = vif.bram_init_done_o;
      c.pre_active = vif.init_active_o;
      #1step;
      c.rvalid = vif.ram_rd_valid_o;
      c.rdata = vif.ram_rd_data_o;
      c.rticket = vif.ram_rd_ticket_o;
      c.wvalid = vif.ram_wr_commit_valid_o;
      c.wticket = vif.ram_wr_commit_ticket_o;
      c.phys_rd = vif.physical_rd_en_o;
      c.phys_we = vif.physical_wr_en_o;
      c.init_we = vif.init_write_en_o;
      c.init_addr = vif.init_addr_o;
      c.init_commit = vif.init_commit_o;
      c.done = vif.bram_init_done_o;
      c.active = vif.init_active_o;
      c.idle = vif.ram_idle_o;
      c.fault = vif.init_fault_o;
      ap.write(c);
    end
  endtask
endclass

class sbm_agent extends uvm_agent;
  `uvm_component_utils(sbm_agent)
  sbm_sequencer seqr;
  sbm_driver drv;
  sbm_monitor mon;
  function new(string name, uvm_component parent); super.new(name,parent); endfunction
  function void build_phase(uvm_phase phase);
    super.build_phase(phase);
    mon = sbm_monitor::type_id::create("mon",this);
    if (get_is_active() == UVM_ACTIVE) begin
      seqr = sbm_sequencer::type_id::create("seqr",this);
      drv = sbm_driver::type_id::create("drv",this);
    end
  endfunction
  function void connect_phase(uvm_phase phase);
    super.connect_phase(phase);
    if (get_is_active() == UVM_ACTIVE) drv.seq_item_port.connect(seqr.seq_item_export);
  endfunction
endclass
