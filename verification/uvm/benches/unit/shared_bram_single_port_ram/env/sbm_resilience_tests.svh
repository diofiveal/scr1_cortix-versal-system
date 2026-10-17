// Each selector is a separate regression manifest entry. These are unit-level
// pin stimuli; CPU/Task reset and real AXI isolation belong to L1 integration.
class sbm_resilience_seq extends sbm_supervisor_seq;
  `uvm_object_utils(sbm_resilience_seq)
  int unsigned mode, selector;
  sbm_vif_t vif;
  function new(string name="sbm_resilience_seq"); super.new(name); endfunction
  task wait_done_bounded();
    for (int n=0;n<SBM_DEPTH+128;n++) begin
      @(posedge vif.clk);
      if (vif.bram_init_done_o === 1'b1) return;
    end
    `uvm_fatal("SBM-PROGRESS","Resilience sequence timed out awaiting INIT_DONE")
  endtask
  task body();
    int unsigned addr, mask, gap;
    if (!uvm_config_db#(sbm_vif_t)::get(p_sequencer,"","vif",vif))
      `uvm_fatal("NO_VIF","Resilience sequence needs interface")
    case (mode)
      1: case (selector) // RST-01..10 plus dedicated mutation probe 11
        1: send(SBM_RESET,0,0,0,0,3);
        2: begin send(SBM_RESET,0,0,0,0,2); send(SBM_INIT,0,0,0,0,3); end
        3: begin certify(); coherent_reset(); zero_init(); end
        4,5: begin
          certify(); coherent_reset(); zero_init();
          if (selector==5) begin
            // Leave room for pre-reset certification before last address.
            for (int n=0;n<SBM_DEPTH+128;n++) begin
              @(posedge vif.clk);
              if (vif.init_addr_o >= 14'd16376) break;
              if (n==SBM_DEPTH+127)
                `uvm_fatal("SBM-PROGRESS","INIT index did not approach final commit")
            end
          end
          certify(); coherent_reset(); zero_init();
        end
        6,10: begin
          certify(); coherent_reset(); zero_init();
          wait_done_bounded();
          certify(); coherent_reset(); zero_init();
          if (selector==10) begin
            wait_done_bounded();
            send(SBM_WRITE,14'd7,32'h12345678,4'hf);
            send(SBM_READ,14'd7);
          end
        end
        7: begin
          certify(); coherent_reset(); zero_init();
          wait_done_bounded();
          certify();
          send(SBM_READ,14'd7);
          coherent_reset(); zero_init();
        end
        8: begin
          certify(); coherent_reset(); zero_init();
          wait_done_bounded();
          certify();
          send(SBM_WRITE,14'd7,32'h13579bdf,4'hf);
          coherent_reset(); zero_init();
        end
        9: begin
          certify(); coherent_reset(); zero_init();
          wait_done_bounded();
          send(SBM_INIT_HOLD,0,0,0,0,6);
        end
        11: begin // unqualified reset cannot discard an outstanding ticket
          certify(); coherent_reset(); zero_init();
          wait_done_bounded();
          send(SBM_READ,14'd7);
          send(SBM_RESET,0,0,0,0,2);
        end
        default: `uvm_fatal("SBM-CASE","RST selector must be 1..11")
      endcase
      2: case (selector) // STALL-01..10
        1: begin send(SBM_READ,14'd0,0,0,0,1,100); send(SBM_READ,14'd0); end
        2: begin send(SBM_WRITE,14'd0,32'h76543210,4'hf,0,1,100); send(SBM_READ,14'd0); end
        3: for (int i=0;i<100;i++)
             if (i[0]) send(SBM_WRITE,14'd0,32'(i),4'hf);
             else send(SBM_READ,14'd0);
        4: for (int i=0;i<100;i++) begin
             gap=$urandom_range(0,50);
             if (i[0]) send(SBM_WRITE,14'(i%SBM_DEPTH),$urandom(),4'($urandom_range(1,15)),0,1,gap);
             else send(SBM_READ,14'(i%SBM_DEPTH),0,0,0,1,gap);
           end
        5: send(SBM_READ,14'd0);
        6: send(SBM_WRITE,14'd0,32'hffffffff,4'hf);
        7,8,9: send(SBM_READ,14'd0);
        10: begin send(SBM_WRITE,14'd0,32'ha5a5a5a5,4'hf); send(SBM_READ,14'd0); end
        11: send(SBM_READ,14'd0,0,0,0,3);
        default: `uvm_fatal("SBM-CASE","STALL selector must be 1..11")
      endcase
      3: case (selector) // NEG-01..10
        1: send(SBM_BOTH,14'd2,32'h12345678,4'hf);
        2: begin send(SBM_WRITE,14'd2,32'hffffffff,4'b0);
                 send(SBM_WRITE,14'd2,32'h12345678,4'hf); end
        3: send(SBM_X_RD,14'd2);
        4: send(SBM_X_WR,14'd2);
        5: send(SBM_X_STRB,14'd2);
        6: begin send(SBM_Z_RD,14'd2); send(SBM_Z_WR,14'd2); send(SBM_Z_STRB,14'd2); end
        7: send(SBM_WRITE,14'd2,32'habcdef01,4'hf);
        8: send(SBM_READ,14'd2);
        9: send(SBM_INIT_HOLD,0,0,0,0,5);
        10: begin send(SBM_RESET,0,0,0,0,2); send(SBM_INIT,0,0,0,0,3); end
        default: `uvm_fatal("SBM-CASE","NEG selector must be 1..10")
      endcase
      4: begin // reproducible via simulator seed; full 16 masks plus random pairs
        for (int m=0;m<16;m++) begin
          send(SBM_WRITE,14'(m),$urandom(),4'(m));
          send(SBM_READ,14'(m));
        end
        for (int i=0;i<400;i++) begin
          addr=(i%16==0) ? 0 : ((i%16==1) ? SBM_DEPTH-1 : $urandom_range(0,SBM_DEPTH-1));
          mask=$urandom_range(0,15);
          gap=$urandom_range(0,50);
          if ($urandom_range(0,1))
            send(SBM_WRITE,14'(addr),$urandom(),4'(mask),0,1,gap);
          else send(SBM_READ,14'(addr),0,0,0,1,gap);
        end
      end
      default: `uvm_fatal("SBM-CASE","Unknown mode")
    endcase
  endtask
endclass

class sbm_resilience_test extends sbm_base_test;
  `uvm_component_utils(sbm_resilience_test)
  int unsigned mode, selector;
  function new(string name,uvm_component parent); super.new(name,parent); endfunction
  function void build_phase(uvm_phase phase);
    super.build_phase(phase);
    if (!$value$plusargs("SBM_MODE=%d",mode) || !(mode inside {[1:4]}))
      `uvm_fatal("SBM-CASE","Supply +SBM_MODE=1(reset),2(stall),3(negative),4(stress)")
    if (mode!=4 && !$value$plusargs("SBM_CASE=%d",selector))
      `uvm_fatal("SBM-CASE","Supply +SBM_CASE=1..10")
  endfunction
  task run_phase(uvm_phase phase);
    sbm_init_seq init=sbm_init_seq::type_id::create("init");
    sbm_resilience_seq seq=sbm_resilience_seq::type_id::create("seq");
    phase.raise_objection(this);
    // Some tests intentionally begin in INIT_LOCKED; no hidden init sequence.
    if (mode==4 || (mode==2 && !(selector inside {5,6})) ||
        (mode==3 && !(selector inside {7,8,10})) ||
        (mode==1 && selector==9)) begin
      init.start(env.agent.seqr);
      wait_initialized();
    end else if ((mode==2 && selector==6) || (mode==3 && selector==7)) begin
      init.start(env.agent.seqr); // scrub still active when next item is sent
    end
    seq.mode=mode; seq.selector=selector;
    seq.start(env.agent.seqr);
    // An active scrub is bounded independently by the watchdog. This wait is
    // itself finite if the DUT never produces INIT_DONE.
    if (mode==1 && !(selector inside {1,2,11})) wait_initialized();
    if ((mode==2 && selector==6) || (mode==3 && selector==7)) wait_initialized();
    repeat (8) @(posedge vif.clk);
    phase.drop_objection(this);
  endtask
  function void check_witness();
    int unsigned expected_r, expected_w;
    if (env.scoreboard.errors || env.intent_audit.errors)
      `uvm_error("SBM-WITNESS","Resilience oracle reported an error")
    if (mode==1 && selector==2 && !env.scoreboard.unsafe_fault_seen)
      `uvm_error("SBM-WITNESS","Uncertified init did not raise fault")
    if (mode==4 && (env.scoreboard.reads_checked==0 ||
                     env.scoreboard.writes_checked==0))
      `uvm_error("SBM-WITNESS","Stress lacked read/write receipts")
    if (mode==2) begin
      case (selector)
        1: expected_r=2;
        2,10: begin expected_r=1; expected_w=1; end
        3: begin expected_r=50; expected_w=50; end
        5: expected_r=0;
        6: expected_w=0;
        7,8,9,11: expected_r=1;
        default: ; // random gaps: intent audit checks each issue
      endcase
      if (selector!=4 && (env.intent_audit.physical_reads!=expected_r ||
                          env.intent_audit.physical_writes!=expected_w))
        `uvm_error("SBM-WITNESS","STALL physical operation count mismatch")
    end
    if (mode==3 && selector==2 &&
        (env.intent_audit.physical_reads!=0 || env.intent_audit.physical_writes!=1))
      `uvm_error("SBM-WITNESS","WSTRB0 + valid WRITE physical count mismatch")
  endfunction
endclass
