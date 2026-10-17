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
  function new(string name, uvm_component parent);
    super.new(name,parent); physical_cg = new();
  endfunction
  function void build_phase(uvm_phase phase);
    super.build_phase(phase);
    void'(uvm_config_db#(int unsigned)::get(this,"","read_latency",latency));
  endfunction
  function void write(sbm_cycle t);
    int op, addr_cls;
    if (!t.rst_n) return;
    op = t.init_commit ? 3 : (t.phys_rd ? 1 : ((|t.phys_we) ? 2 :
         ((t.wr && t.strb==0) ? 4 : 0)));
    if (!op) return;
    addr_cls = t.init_commit ? ((t.init_addr==0) ? 0 :
               ((t.init_addr==SBM_DEPTH-1) ? 2 : 1)) :
               ((t.addr==0) ? 0 : ((t.addr==SBM_DEPTH-1) ? 2 : 1));
    physical_cg.sample(op,addr_cls,t.phys_we,latency);
  endfunction
endclass
