// Sequence-origin intent is independent of the driver and of DUT receipts.
// The driver acceptance/completion streams diagnose UVM handshake faults;
// physical edge observations remain the authority for issue count and fields.
class sbm_intent_audit extends uvm_component;
  `uvm_component_utils(sbm_intent_audit)
  uvm_analysis_imp_intent #(sbm_item,sbm_intent_audit) intent_imp;
  uvm_analysis_imp_accept #(sbm_item,sbm_intent_audit) accept_imp;
  uvm_analysis_imp_complete #(sbm_item,sbm_intent_audit) complete_imp;
  uvm_analysis_imp_cycle #(sbm_cycle,sbm_intent_audit) cycle_imp;
  sbm_item intents[$], edge_pending[$];
  longint unsigned born[$];
  bit timed_out[$];
  longint unsigned cycles;
  longint unsigned issue_cycles[$];
  int unsigned accepted, completed, observed, physical_reads, physical_writes, errors;
  function new(string name,uvm_component parent);
    super.new(name,parent);
    intent_imp=new("intent_imp",this);
    accept_imp=new("accept_imp",this);
    complete_imp=new("complete_imp",this);
    cycle_imp=new("cycle_imp",this);
  endfunction
  function void bad(string detail);
    errors++;
    `uvm_error("SBM-INTENT",detail)
  endfunction
  function void write_intent(sbm_item t);
    sbm_item snap;
    $cast(snap,t.clone());
    if (snap==null) `uvm_fatal("SBM-CLONE","Intent clone failed")
    if (intents.size() && snap.intent_id <= intents[$].intent_id)
      bad("Non-monotonic/duplicate sequence intent ID");
    intents.push_back(snap);
    born.push_back(cycles);
    timed_out.push_back(0);
  endfunction
  function void write_accept(sbm_item t);
    sbm_item snap;
    if (accepted >= intents.size()) begin
      bad("Driver accepted an item with no prior sequence intent");
      return;
    end
    if (!t.compare(intents[accepted]))
      bad($sformatf("Accepted item %0d differs from sequence snapshot",intents[accepted].intent_id));
    accepted++;
    if (t.op inside {SBM_READ,SBM_WRITE,SBM_BOTH,SBM_X_RD,
                     SBM_X_WR,SBM_X_STRB,SBM_Z_RD,SBM_Z_WR,SBM_Z_STRB}) begin
      $cast(snap,intents[accepted-1].clone());
      edge_pending.push_back(snap);
    end
  endfunction
  function void write_complete(sbm_item t);
    if (completed >= accepted || completed >= intents.size()) begin
      bad("item_done without a corresponding accepted sequence item");
      return;
    end
    if (!t.compare(intents[completed]))
      bad($sformatf("Completed wrong item at position %0d",completed));
    completed++;
  endfunction
  function void write_cycle(sbm_cycle c);
    sbm_item t;
    bit want_read;
    bit [3:0] want_we;
    cycles++;
    for (int i=accepted; i<intents.size(); i++) begin
      if (!timed_out[i] && cycles-born[i] > 64) begin
        bad($sformatf("Sequence intent %0d not accepted within 64 edges",intents[i].intent_id));
        timed_out[i]=1;
      end
    end
    if (completed < accepted && cycles-born[completed] >
        64 + intents[completed].hold_cycles + intents[completed].gap_cycles)
      bad($sformatf("Driver accepted item %0d but did not complete it",intents[completed].intent_id));
    if (edge_pending.size()) begin
      t=edge_pending.pop_front();
      observed++;
      if (c.addr !== t.addr || c.ticket !== t.ticket)
        bad($sformatf("Issue fields differ for intent %0d: address/ticket",t.intent_id));
      case (t.op)
        SBM_READ: if (c.rd !== 1'b1 || c.wr !== 1'b0)
                    bad($sformatf("READ input missing for intent %0d",t.intent_id));
        SBM_WRITE: if (c.wr !== 1'b1 || c.rd !== 1'b0 ||
                        c.strb !== t.strb || c.wdata !== t.data)
                     bad($sformatf("WRITE input fields differ for intent %0d",t.intent_id));
        SBM_BOTH: if (c.rd !== 1'b1 || c.wr !== 1'b1)
                    bad("Illegal simultaneous command lost");
        SBM_X_RD: if (c.rd !== 1'bx)
                    bad("X-control negative stimulus lost");
        SBM_X_WR: if (c.wr !== 1'bx) bad("X-WR negative stimulus lost");
        SBM_Z_RD: if (c.rd !== 1'bz) bad("Z-RD negative stimulus lost");
        SBM_Z_WR: if (c.wr !== 1'bz) bad("Z-WR negative stimulus lost");
        SBM_X_STRB: if (c.strb !== 4'bx) bad("X-WSTRB stimulus lost");
        SBM_Z_STRB: if (c.strb !== 4'bz) bad("Z-WSTRB stimulus lost");
        default: ;
      endcase
      // A denied INIT-locked command, WSTRB0 and intentional illegal
      // command have zero normal physical issues by contract.
      want_read = c.pre_done && !c.pre_active && c.rst_n &&
                  t.op==SBM_READ && !(c.init_req && c.isolation);
      want_we = (c.pre_done && !c.pre_active && c.rst_n &&
                 t.op==SBM_WRITE && !(c.init_req && c.isolation)) ? t.strb : 4'b0;
      if (c.phys_rd !== want_read || c.phys_we !== want_we)
        bad($sformatf("Physical issue count/mask differs for intent %0d",t.intent_id));
    end else if (c.rd !== 1'b0 || c.wr !== 1'b0 ||
                 c.phys_rd !== 1'b0 || c.phys_we !== 4'b0) begin
      bad($sformatf("Unsolicited or duplicate normal command at cycle %0d",c.cycle));
    end
    if (c.phys_rd === 1'b1) physical_reads++;
    if (c.phys_we !== 4'b0) physical_writes++;
    if (c.phys_rd === 1'b1 || c.phys_we !== 4'b0)
      issue_cycles.push_back(c.cycle);
  endfunction
  function void check_phase(uvm_phase phase);
    super.check_phase(phase);
    if (intents.size()!=accepted || accepted!=completed || edge_pending.size())
      bad($sformatf("Lost/incomplete items: intent=%0d accepted=%0d completed=%0d pending_edges=%0d",
                    intents.size(),accepted,completed,edge_pending.size()));
  endfunction
endclass
