class sbm_coverage extends uvm_subscriber #(sbm_cycle);
  `uvm_component_utils(sbm_coverage)
  int unsigned latency = 2;
  covergroup physical_cg with function sample(int op, int address_class,
                                               bit[3:0] mask, int latency_value);
    option.per_instance = 1;
    cp_op: coverpoint op {bins read= {1}; bins write={2}; bins init={3}; bins no_op={4};}
    cp_addr: coverpoint address_class {bins first={0}; bins middle={1}; bins last={2};}
    cp_mask: coverpoint mask {bins each_mask[]={[0:15]};}
    cp_latency: coverpoint latency_value {bins one={1}; bins two={2};}
    op_x_addr: cross cp_op, cp_addr;
    mask_x_latency: cross cp_mask, cp_latency iff (op==2 || op==4);
  endgroup
  covergroup ticket_cg with function sample(int op, int ticket_class, int latency_value);
    option.per_instance = 1;
    cp_op: coverpoint op {bins read={1}; bins write={2};}
    cp_ticket: coverpoint ticket_class {
      bins low_only={0}; bins upper_nonzero={1};
      bins walking_one={2}; bins walking_zero={3}; bins all_ones={4};
    }
    cp_latency: coverpoint latency_value {bins one={1}; bins two={2};}
    ticket_x_op_x_latency: cross cp_op,cp_ticket,cp_latency;
  endgroup
  function new(string name, uvm_component parent);
    super.new(name,parent); physical_cg = new(); ticket_cg = new();
  endfunction
  function void build_phase(uvm_phase phase);
    super.build_phase(phase);
    void'(uvm_config_db#(int unsigned)::get(this,"","read_latency",latency));
  endfunction
  function void write(sbm_cycle t);
    int op, addr_cls, ticket_cls;
    if (!t.rst_n) return;
    op = t.init_commit ? 3 : (t.phys_rd ? 1 : ((|t.phys_we) ? 2 :
         ((t.wr && t.strb==0) ? 4 : 0)));
    if (!op) return;
    addr_cls = t.init_commit ? ((t.init_addr==0) ? 0 :
               ((t.init_addr==SBM_DEPTH-1) ? 2 : 1)) :
               ((t.addr==0) ? 0 : ((t.addr==SBM_DEPTH-1) ? 2 : 1));
    physical_cg.sample(op,addr_cls,t.phys_we,latency);
    if (op inside {1,2}) begin
      ticket_cls = (t.ticket === '1) ? 4 :
                   ($countones(t.ticket)==1) ? 2 :
                   ($countones(t.ticket)==SBM_TICKET_W-1) ? 3 :
                   ((t.ticket >> 32)!=0) ? 1 : 0;
      ticket_cg.sample(op,ticket_cls,latency);
    end
  endfunction
endclass
