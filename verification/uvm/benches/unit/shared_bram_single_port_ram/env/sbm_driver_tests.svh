class sbm_driver_probe_seq extends sbm_base_seq;
  `uvm_object_utils(sbm_driver_probe_seq)
  int unsigned case_id;
  function new(string name="sbm_driver_probe_seq"); super.new(name); endfunction
  task body();
    case (case_id)
      0: send(SBM_READ,14'd17);
      1: send(SBM_READ,14'd17,0,0,0,3);
      2: send(SBM_WRITE,14'd17,32'h12345678,4'hf);
      3: send(SBM_WRITE,14'd17,32'h12345678,4'hf,0,3);
      4: for (int i=0;i<100;i++) send(SBM_READ,14'(i));
      5: for (int i=0;i<100;i++) send(SBM_WRITE,14'(i),32'(i),4'hf);
      6: for (int i=0;i<100;i++) begin
           send(SBM_READ,14'(i));
           send(SBM_WRITE,14'(i),32'(i),4'hf);
         end
      7: begin
           send(SBM_READ,14'd9,0,0,0,1,1);
           send(SBM_WRITE,14'd9,32'hfedcba98,4'hf,0,1,2);
           send(SBM_READ,14'd9,0,0,0,1,5);
           send(SBM_WRITE,14'd9,32'h76543210,4'h3,0,1,20);
           send(SBM_READ,14'd9);
         end
      8: begin
           send(SBM_READ,14'd99);
           send(SBM_READ,14'd99);
         end
      9: begin
           send(SBM_WRITE,14'd66,32'habcdef01,4'h0);
           send(SBM_BOTH,14'd66,32'habcdef01,4'hf);
           send(SBM_X_RD,14'd66);
         end
      default: `uvm_fatal("SBM-CASE","Unknown driver fixture case")
    endcase
  endtask
endclass

class sbm_driver_fixture_test extends uvm_test;
  `uvm_component_utils(sbm_driver_fixture_test)
  sbm_agent agent;
  sbm_intent_audit audit;
  int unsigned case_id, mut_mode;
  int unsigned expected_reads, expected_writes;
  function new(string name,uvm_component parent); super.new(name,parent); endfunction
  function void build_phase(uvm_phase phase);
    super.build_phase(phase);
    void'($value$plusargs("SBM_CASE=%d",case_id));
    void'($value$plusargs("SBM_MUT=%d",mut_mode));
    if (mut_mode > 6) `uvm_fatal("SBM-MUT","Unknown driver mutation")
    uvm_config_db#(int unsigned)::set(this,"agent.drv","driver_fault_mode",mut_mode);
    agent=sbm_agent::type_id::create("agent",this);
    audit=sbm_intent_audit::type_id::create("audit",this);
  endfunction
  function void connect_phase(uvm_phase phase);
    super.connect_phase(phase);
    agent.seqr.intent_ap.connect(audit.intent_imp);
    agent.drv.accept_ap.connect(audit.accept_imp);
    agent.drv.complete_ap.connect(audit.complete_imp);
    agent.mon.ap.connect(audit.cycle_imp);
  endfunction
  task run_phase(uvm_phase phase);
    sbm_driver_probe_seq s=sbm_driver_probe_seq::type_id::create("s");
    phase.raise_objection(this);
    s.case_id=case_id;
    case (case_id)
      0,1: expected_reads=1;
      2,3: expected_writes=1;
      4: expected_reads=100;
      5: expected_writes=100;
      6: begin expected_reads=100; expected_writes=100; end
      7: begin expected_reads=3; expected_writes=2; end
      8: expected_reads=2;
      9: ; // WSTRB0 and illegal commands have no physical issues.
      default: `uvm_fatal("SBM-CASE","Unknown driver fixture case")
    endcase
    s.start(agent.seqr);
    repeat (3) @(posedge agent.drv.vif.clk);
    phase.drop_objection(this);
  endtask
  function void check_phase(uvm_phase phase);
    super.check_phase(phase);
    if (audit.physical_reads!=expected_reads || audit.physical_writes!=expected_writes)
      `uvm_error("SBM-COUNT",$sformatf("case %0d: physical RD=%0d/%0d WR=%0d/%0d",
        case_id,audit.physical_reads,expected_reads,audit.physical_writes,expected_writes))
    if (mut_mode==0 && audit.errors!=0)
      `uvm_error("SBM-AUDIT","Normal driver scenario has intent/issue mismatch")
    if (mut_mode!=0 && audit.errors==0)
      `uvm_error("SBM-MUT","Mutation escaped independent intent/issue audit")
    if (mut_mode==0 && case_id inside {4,5,6,8})
      for (int i=1;i<audit.issue_cycles.size();i++)
        if (audit.issue_cycles[i]!=audit.issue_cycles[i-1]+1)
          `uvm_error("SBM-B2B",$sformatf("Unintended bubble at issue %0d",i))
    if (mut_mode==0 && case_id==7) begin
      int expected_distance[4]='{2,3,6,21};
      if (audit.issue_cycles.size()==5)
        for (int i=1;i<5;i++)
          if (audit.issue_cycles[i]-audit.issue_cycles[i-1]!=expected_distance[i-1])
            `uvm_error("SBM-GAP",$sformatf("Wrong issue gap at position %0d",i))
    end
    `uvm_info("SBM-FIXTURE",$sformatf("case=%0d mut=%0d intent=%0d accepted=%0d completed=%0d observed=%0d physical_RD=%0d physical_WR=%0d audit_errors=%0d",
      case_id,mut_mode,audit.intents.size(),audit.accepted,audit.completed,
      audit.observed,audit.physical_reads,audit.physical_writes,audit.errors),UVM_NONE)
  endfunction
endclass
