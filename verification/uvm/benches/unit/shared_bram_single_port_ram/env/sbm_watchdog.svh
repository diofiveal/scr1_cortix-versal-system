// Independent clock heartbeat; the monitor stream and sequence ledger are
// observed, never driven, by this component.
class sbm_watchdog extends uvm_component;
  `uvm_component_utils(sbm_watchdog)
  uvm_analysis_imp_watch #(sbm_cycle,sbm_watchdog) watch_imp;
  sbm_vif_t vif;
  sbm_scoreboard scoreboard;
  sbm_intent_audit audit;
  longint unsigned cycle, last_monitor_cycle, last_progress_cycle, active_since;
  int unsigned last_scrub_count;
  string last_event = "none";
  logic active, done;
  int unsigned seed;
  function new(string name,uvm_component parent);
    super.new(name,parent); watch_imp=new("watch_imp",this);
  endfunction
  function void build_phase(uvm_phase phase);
    super.build_phase(phase);
    if (!uvm_config_db#(sbm_vif_t)::get(this,"","vif",vif))
      `uvm_fatal("NO_VIF","Watchdog needs RAM interface")
    if (!$value$plusargs("ntb_random_seed=%d",seed))
      void'($value$plusargs("sv_seed=%d",seed));
  endfunction
  function void write_watch(sbm_cycle c);
    last_monitor_cycle=c.cycle;
    active=c.active;
    done=c.done;
    if (c.init_we) last_event=$sformatf("INIT address=%0d cycle=%0d",c.init_addr,c.cycle);
    else if (c.phys_rd) last_event=$sformatf("READ address=%0d ticket=%h cycle=%0d",c.addr,c.ticket,c.cycle);
    else if (|c.phys_we) last_event=$sformatf("WRITE address=%0d ticket=%h cycle=%0d",c.addr,c.ticket,c.cycle);
  endfunction
  task run_phase(uvm_phase phase);
    longint unsigned id;
    logic [SBM_TICKET_W-1:0] ticket;
    string op;
    forever begin
      @(negedge vif.clk);
      cycle++;
      if (scoreboard == null || audit == null) continue;
      id=0; ticket='0; op="none";
      if (audit.completed < audit.intents.size()) begin
        id=audit.intents[audit.completed].intent_id;
        ticket=audit.intents[audit.completed].ticket;
        op=audit.intents[audit.completed].op.name();
      end
      if (scoreboard.scrub_count != last_scrub_count) begin
        last_scrub_count=scoreboard.scrub_count;
        last_progress_cycle=cycle;
      end
      if (active && active_since==0) active_since=cycle;
      if (!active) active_since=0;
      if (cycle > last_monitor_cycle+3)
        fail("monitor clock heartbeat lost",op,id,ticket);
      if (active && cycle > last_progress_cycle+64)
        fail("INIT counter stopped progressing",op,id,ticket);
      if (active && cycle > active_since+SBM_DEPTH+256)
        fail("INIT sweep exceeded bounded duration",op,id,ticket);
      if (scoreboard.scrub_count == SBM_DEPTH && !done &&
          cycle > last_progress_cycle+64)
        fail("INIT_DONE absent after final commit",op,id,ticket);
      if (audit.completed < audit.accepted &&
          cycle > audit.born[audit.completed]+64+
                  audit.intents[audit.completed].hold_cycles+
                  audit.intents[audit.completed].gap_cycles)
        fail("Driver accepted item but did not call item_done",op,id,ticket);
      if (audit.accepted < audit.intents.size() &&
          cycle > audit.born[audit.accepted]+65)
        fail("Sequence intent was not accepted by Driver",op,id,ticket);
    end
  endtask
  function void fail(string why,string op,longint unsigned id,
                     logic [SBM_TICKET_W-1:0] ticket);
    `uvm_fatal("SBM-PROGRESS",$sformatf(
      "test=%s seed=%0d cycle=%0d reason=%s op=%s id=%0d ticket=%h outstanding_reads=%0d outstanding_writes=%0d init_active=%b init_done=%b last_physical=%s",
      get_parent().get_parent().get_name(),seed,cycle,why,op,id,ticket,
      scoreboard.pending_reads.size(),scoreboard.pending_writes.size(),
      active,done,last_event))
  endfunction
endclass
