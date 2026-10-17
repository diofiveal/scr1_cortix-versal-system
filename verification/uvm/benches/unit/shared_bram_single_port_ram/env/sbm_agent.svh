class sbm_sequencer extends uvm_sequencer #(sbm_item);
  `uvm_component_utils(sbm_sequencer)
  uvm_analysis_port #(sbm_item) intent_ap;
  longint unsigned next_intent_id;
  function new(string name, uvm_component parent);
    super.new(name,parent); intent_ap = new("intent_ap",this);
  endfunction
endclass

class sbm_driver extends uvm_driver #(sbm_item);
  `uvm_component_utils(sbm_driver)
  sbm_vif_t vif;
  uvm_analysis_port #(sbm_item) accept_ap, complete_ap;
  // Fixture-only fault switches. Production configuration leaves this at zero.
  int unsigned fault_mode;
  bit fault_fired;
  function new(string name, uvm_component parent);
    super.new(name,parent);
    accept_ap = new("accept_ap",this);
    complete_ap = new("complete_ap",this);
  endfunction
  function void build_phase(uvm_phase phase);
    super.build_phase(phase);
    if (!uvm_config_db#(sbm_vif_t)::get(this,"","vif",vif))
      `uvm_fatal("NO_VIF","Missing sbm_ram_if")
    void'(uvm_config_db#(int unsigned)::get(this,"","driver_fault_mode",fault_mode));
  endfunction
  task run_phase(uvm_phase phase);
    sbm_item tr, snap, event_copy;
    bit inject;
    drive_idle();
    forever begin
      @(negedge vif.clk);
      drive_idle();
      tr = null;
      seq_item_port.try_next_item(tr);
      if (tr == null) continue;
      $cast(snap,tr.clone());
      if (snap == null) `uvm_fatal("SBM-CLONE","Driver item clone failed")
      $cast(event_copy,snap.clone());
      accept_ap.write(event_copy);
      inject = !fault_fired &&
               ((fault_mode == 1 && snap.op == SBM_READ) ||
                (fault_mode == 2 && snap.op == SBM_WRITE && |snap.strb) ||
                (fault_mode == 3 && snap.op inside {SBM_READ,SBM_WRITE}) ||
                (fault_mode == 4 && snap.op == SBM_READ) ||
                (fault_mode == 5 && snap.op == SBM_READ) ||
                (fault_mode == 6 && snap.op == SBM_WRITE && |snap.strb));
      if (inject) fault_fired = 1;
      if (inject && fault_mode == 4) begin
        // MUT-D04: acknowledge the item before its intended issue edge.
        // The sequence-side intent remains pending for the physical audit.
        $cast(event_copy,snap.clone());
        complete_ap.write(event_copy);
        seq_item_port.item_done();
        continue;
      end
      // READ/WRITE (including illegal/zero-mask probes) occupies one edge.
      // Level-held RESET/INIT is intentionally a different contract.
      case (snap.op)
        SBM_READ: begin
          if (!(inject && fault_mode==1)) vif.ram_rd_en_i = 1'b1;
          vif.ram_addr_i = (inject && fault_mode==5) ? (snap.addr ^ 14'd1) : snap.addr;
          vif.ram_issue_ticket_i = snap.ticket;
        end
        SBM_WRITE: begin
          if (!(inject && fault_mode==6)) vif.ram_wr_en_i = 1'b1;
          vif.ram_addr_i = snap.addr;
          vif.ram_wr_data_i = snap.data;
          vif.ram_wr_strb_i = snap.strb;
          vif.ram_issue_ticket_i = snap.ticket;
        end
        SBM_RESET: begin
          vif.rst_n = 1'b0;
          vif.coherent_isolation_proven_i = snap.isolation;
          vif.platform_zero_init_i = 1'b1;
        end
        SBM_INIT, SBM_INIT_HOLD: begin
          vif.coherent_isolation_proven_i = snap.isolation;
          vif.platform_zero_init_i = 1'b1;
        end
        SBM_BOTH: begin
          vif.ram_rd_en_i = 1'b1;
          vif.ram_wr_en_i = 1'b1;
          vif.ram_addr_i = snap.addr;
          vif.ram_wr_data_i = snap.data;
          vif.ram_wr_strb_i = snap.strb;
          vif.ram_issue_ticket_i = snap.ticket;
        end
        SBM_X_RD: begin
          vif.ram_rd_en_i = 1'bx;
          vif.ram_addr_i = snap.addr;
          vif.ram_issue_ticket_i = snap.ticket;
        end
        default: ;
      endcase
      if (inject && fault_mode == 3) vif.ram_issue_ticket_i = snap.ticket ^ SBM_TICKET_W'(1);
      @(posedge vif.clk);
      if (inject && fault_mode == 2) @(posedge vif.clk); // deliberate extra WE
      repeat ((snap.hold_cycles > 0) ? snap.hold_cycles-1 : 0) begin
        @(negedge vif.clk);
        if (snap.op inside {SBM_READ,SBM_WRITE,SBM_BOTH,SBM_X_RD}) begin
          vif.ram_rd_en_i = 1'b0;
          vif.ram_wr_en_i = 1'b0;
        end
        @(posedge vif.clk);
      end
      $cast(event_copy,snap.clone());
      complete_ap.write(event_copy);
      seq_item_port.item_done();
      repeat (snap.gap_cycles) begin
        @(negedge vif.clk);
        drive_idle();
      end
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
