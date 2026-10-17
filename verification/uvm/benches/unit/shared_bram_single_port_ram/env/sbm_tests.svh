class sbm_base_test extends uvm_test;
  `uvm_component_utils(sbm_base_test)
  sbm_env env;
  sbm_vif_t vif;
  function new(string name, uvm_component parent); super.new(name,parent); endfunction
  function void build_phase(uvm_phase phase);
    super.build_phase(phase);
    if (!uvm_config_db#(sbm_vif_t)::get(this,"","vif",vif))
      `uvm_fatal("NO_VIF","Test needs sbm_ram_if")
    env = sbm_env::type_id::create("env",this);
  endfunction
  task wait_initialized();
    for (int n=0; n<SBM_DEPTH+100; n++) begin
      @(posedge vif.clk); #1step;
      if (vif.bram_init_done_o === 1'b1) return;
    end
    `uvm_fatal("SBM-TIMEOUT","Qualified scrub did not finish")
  endtask
  virtual task scenario();
    sbm_mask_seq masks = sbm_mask_seq::type_id::create("masks");
    sbm_snapshot_seq snap = sbm_snapshot_seq::type_id::create("snap");
    masks.start(env.agent.seqr);
    snap.start(env.agent.seqr);
  endtask
  task run_phase(uvm_phase phase);
    sbm_init_seq init = sbm_init_seq::type_id::create("init");
    phase.raise_objection(this);
    init.start(env.agent.seqr);
    wait_initialized();
    // Let the monitor publish DONE's post-NBA edge before a test starts a
    // scoreboard scan or issues the first normal command.
    @(negedge vif.clk);
    scenario();
    repeat (8) @(posedge vif.clk);
    phase.drop_objection(this);
  endtask
  function void report_phase(uvm_phase phase);
    super.report_phase(phase);
    `uvm_info("SBM_SUMMARY",$sformatf("errors=%0d scrubs=%0d reads=%0d writes=%0d no_op=%0d",
      env.scoreboard.errors,env.scoreboard.completed_scrubs,
      env.scoreboard.reads_checked,env.scoreboard.writes_checked,
      env.scoreboard.zero_reads_checked),UVM_NONE)
    check_witness();
  endfunction
  virtual function void check_witness();
    if (env.scoreboard.completed_scrubs == 0 ||
        env.scoreboard.reads_checked == 0 ||
        env.scoreboard.writes_checked == 0 ||
        env.scoreboard.zero_reads_checked == 0 ||
        env.scoreboard.errors != 0)
      `uvm_error("SBM_WITNESS","Mandatory physical issue/receipt witnesses absent or checks failed")
    for (int m=1; m<16; m++)
      if (env.scoreboard.masks_seen[m] == 0)
        `uvm_error("SBM_WITNESS",$sformatf("Missing physical byte-mask witness %0d",m))
  endfunction
endclass

class sbm_full_scan_test extends sbm_base_test;
  `uvm_component_utils(sbm_full_scan_test)
  function new(string name,uvm_component parent); super.new(name,parent); endfunction
  virtual task run_scan();
    sbm_zero_scan_seq scan = sbm_zero_scan_seq::type_id::create("scan");
    scan.start(env.agent.seqr);
  endtask
  task scenario();
    sbm_mask_seq masks = sbm_mask_seq::type_id::create("masks");
    env.scoreboard.start_zero_scan();
    run_scan();
    repeat (4) begin @(posedge vif.clk); #1step; end
    env.scoreboard.finish_zero_scan();
    masks.start(env.agent.seqr);
  endtask
endclass

// Expected negative test: the checker must report SBM-SCAN for address 7777.
class sbm_missing_scan_test extends sbm_full_scan_test;
  `uvm_component_utils(sbm_missing_scan_test)
  function new(string name,uvm_component parent); super.new(name,parent); endfunction
  task run_scan();
    sbm_zero_scan_missing_seq scan=sbm_zero_scan_missing_seq::type_id::create("scan");
    scan.start(env.agent.seqr);
  endtask
endclass

class sbm_timing_ticket_test extends sbm_base_test;
  `uvm_component_utils(sbm_timing_ticket_test)
  function new(string name,uvm_component parent); super.new(name,parent); endfunction
  task scenario();
    sbm_mask_seq masks=sbm_mask_seq::type_id::create("masks");
    sbm_snapshot_seq snap=sbm_snapshot_seq::type_id::create("snap");
    sbm_ticket_seq tickets=sbm_ticket_seq::type_id::create("tickets");
    sbm_alternating_seq alternating=sbm_alternating_seq::type_id::create("alternating");
    masks.start(env.agent.seqr);
    snap.start(env.agent.seqr);
    tickets.start(env.agent.seqr);
    alternating.start(env.agent.seqr);
  endtask
  function void check_witness();
    super.check_witness();
    // 48/48 masks + 2/3 snapshot + 96/97 ticket + 52/52 alternating.
    if (env.scoreboard.writes_checked!=198 || env.scoreboard.reads_checked!=200 ||
        env.intent_audit.physical_writes!=198 || env.intent_audit.physical_reads!=200)
      `uvm_error("SBM-WITNESS","Timing/ticket physical READ/WRITE cardinality mismatch")
  endfunction
endclass

class sbm_address_pattern_test extends sbm_base_test;
  `uvm_component_utils(sbm_address_pattern_test)
  function new(string name,uvm_component parent); super.new(name,parent); endfunction
  task scenario();
    sbm_address_pattern_seq walk=sbm_address_pattern_seq::type_id::create("walk");
    sbm_mask_seq masks=sbm_mask_seq::type_id::create("masks");
    walk.start(env.agent.seqr);
    masks.start(env.agent.seqr);
  endtask
  function void check_witness();
    super.check_witness();
    if (env.scoreboard.reads_checked < SBM_DEPTH)
      `uvm_error("SBM-WITNESS","Address-pattern readback did not complete")
  endfunction
endclass

class sbm_mutation_probe_test extends sbm_base_test;
  `uvm_component_utils(sbm_mutation_probe_test)
  int unsigned mutation_case;
  function new(string name,uvm_component parent); super.new(name,parent); endfunction
  function void build_phase(uvm_phase phase);
    super.build_phase(phase);
    if (!$value$plusargs("SBM_MUT_CASE=%d",mutation_case) ||
        !(mutation_case inside {[1:16]}))
      `uvm_fatal("SBM-MUT","Supply +SBM_MUT_CASE=1..16")
  endfunction
  task scenario();
    sbm_mutation_probe_seq probe=sbm_mutation_probe_seq::type_id::create("probe");
    probe.mutation_case=mutation_case;
    probe.start(env.agent.seqr);
  endtask
  function void check_witness();
    if (env.scoreboard.completed_scrubs==0)
      `uvm_error("SBM-WITNESS","Mutation probe lacked a completed INIT sweep")
    // Expected mutation kills are UVM_ERRORs from the unmodified oracle.
    // Do not turn them into a green simulation result here.
  endfunction
endclass

class sbm_repeat_init_test extends sbm_base_test;
  `uvm_component_utils(sbm_repeat_init_test)
  function new(string name,uvm_component parent); super.new(name,parent); endfunction
  task run_phase(uvm_phase phase);
    sbm_init_seq init = sbm_init_seq::type_id::create("init");
    sbm_repeat_init_seq repeated = sbm_repeat_init_seq::type_id::create("repeated");
    sbm_during_scrub_seq collision = sbm_during_scrub_seq::type_id::create("collision");
    sbm_mask_seq masks = sbm_mask_seq::type_id::create("masks");
    phase.raise_objection(this);
    init.start(env.agent.seqr);
    repeated.start(env.agent.seqr);
    collision.start(env.agent.seqr);
    wait_initialized();
    @(negedge vif.clk);
    masks.start(env.agent.seqr);
    repeat (8) @(posedge vif.clk);
    phase.drop_objection(this);
  endtask
  function void report_phase(uvm_phase phase);
    super.report_phase(phase);
    if (env.scoreboard.during_scrub_attempts == 0)
      `uvm_error("SBM-WITNESS","No attempted normal service during scrub")
  endfunction
endclass

class sbm_unqualified_init_test extends sbm_base_test;
  `uvm_component_utils(sbm_unqualified_init_test)
  function new(string name,uvm_component parent); super.new(name,parent); endfunction
  task run_phase(uvm_phase phase);
    sbm_unqualified_seq seq = sbm_unqualified_seq::type_id::create("seq");
    phase.raise_objection(this);
    seq.start(env.agent.seqr);
    repeat (5) @(posedge vif.clk);
    if (vif.bram_init_done_o !== 1'b0 || vif.init_active_o !== 1'b0)
      `uvm_error("SBM-ASRT-06","Uncertified request started initialization")
    phase.drop_objection(this);
  endtask
  function void report_phase(uvm_phase phase);
    super.report_phase(phase);
  endfunction
  function void check_witness();
    // This negative test deliberately has no normal read/write witness.
    if (env.scoreboard.scrub_count != 0 || env.scoreboard.errors ||
        !env.scoreboard.unsafe_fault_seen)
      `uvm_error("SBM_WITNESS","Uncertified request caused physical scrub or checker error")
  endfunction
endclass

class sbm_illegal_control_test extends sbm_base_test;
  `uvm_component_utils(sbm_illegal_control_test)
  function new(string name,uvm_component parent); super.new(name,parent); endfunction
  task scenario();
    sbm_mask_seq masks = sbm_mask_seq::type_id::create("masks");
    sbm_illegal_control_seq illegal = sbm_illegal_control_seq::type_id::create("illegal");
    masks.start(env.agent.seqr);
    illegal.start(env.agent.seqr);
  endtask
endclass
