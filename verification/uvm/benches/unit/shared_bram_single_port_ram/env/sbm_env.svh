class sbm_env extends uvm_env;
  `uvm_component_utils(sbm_env)
  sbm_agent agent;
  sbm_scoreboard scoreboard;
  sbm_coverage coverage;
  function new(string name, uvm_component parent); super.new(name,parent); endfunction
  function void build_phase(uvm_phase phase);
    super.build_phase(phase);
    agent = sbm_agent::type_id::create("agent",this);
    scoreboard = sbm_scoreboard::type_id::create("scoreboard",this);
    coverage = sbm_coverage::type_id::create("coverage",this);
  endfunction
  function void connect_phase(uvm_phase phase);
    super.connect_phase(phase);
    agent.mon.ap.connect(scoreboard.imp);
    agent.mon.ap.connect(coverage.analysis_export);
  endfunction
endclass
