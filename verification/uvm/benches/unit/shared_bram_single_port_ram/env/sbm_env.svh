class sbm_env extends uvm_env;
  `uvm_component_utils(sbm_env)
  sbm_agent agent;
  sbm_scoreboard scoreboard;
  sbm_coverage coverage;
  sbm_intent_audit intent_audit;
  sbm_watchdog watchdog;
  function new(string name, uvm_component parent); super.new(name,parent); endfunction
  function void build_phase(uvm_phase phase);
    super.build_phase(phase);
    agent = sbm_agent::type_id::create("agent",this);
    scoreboard = sbm_scoreboard::type_id::create("scoreboard",this);
    coverage = sbm_coverage::type_id::create("coverage",this);
    intent_audit = sbm_intent_audit::type_id::create("intent_audit",this);
    watchdog = sbm_watchdog::type_id::create("watchdog",this);
  endfunction
  function void connect_phase(uvm_phase phase);
    super.connect_phase(phase);
    agent.mon.ap.connect(scoreboard.imp);
    agent.mon.ap.connect(coverage.analysis_export);
    if (agent.get_is_active() == UVM_ACTIVE) begin
      agent.seqr.intent_ap.connect(intent_audit.intent_imp);
      agent.drv.accept_ap.connect(intent_audit.accept_imp);
      agent.drv.complete_ap.connect(intent_audit.complete_imp);
    end
    agent.mon.ap.connect(intent_audit.cycle_imp);
    agent.mon.ap.connect(watchdog.watch_imp);
    watchdog.scoreboard=scoreboard;
    watchdog.audit=intent_audit;
  endfunction
endclass
