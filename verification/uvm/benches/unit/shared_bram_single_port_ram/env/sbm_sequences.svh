class sbm_base_seq extends uvm_sequence #(sbm_item);
  `uvm_object_utils(sbm_base_seq)
  `uvm_declare_p_sequencer(sbm_sequencer)
  static longint unsigned next_ticket = 64'h1357_0000;
  function new(string name="sbm_base_seq"); super.new(name); endfunction
  task send(sbm_op_e op, bit[13:0] addr=0, bit[31:0] data=0,
            bit[3:0] mask=0, bit isolation=0, int unsigned cycles=1,
            int unsigned gap=0, bit use_ticket=0,
            bit[SBM_TICKET_W-1:0] forced_ticket='0);
    sbm_item tr = sbm_item::type_id::create("tr");
    sbm_item intent;
    start_item(tr);
    tr.op = op;
    tr.addr = addr;
    tr.data = data;
    tr.strb = mask;
    tr.ticket = use_ticket ? forced_ticket : SBM_TICKET_W'(next_ticket++);
    tr.isolation = isolation;
    tr.hold_cycles = cycles;
    tr.gap_cycles = gap;
    tr.intent_id = ++p_sequencer.next_intent_id;
    // This immutable clone is published on the sequence side before the
    // driver can fetch, acknowledge or lose the granted item.
    $cast(intent,tr.clone());
    if (intent == null) `uvm_fatal("SBM-CLONE","Sequence item clone failed")
    p_sequencer.intent_ap.write(intent);
    finish_item(tr);
  endtask
endclass

class sbm_init_seq extends sbm_base_seq;
  `uvm_object_utils(sbm_init_seq)
  function new(string name="sbm_init_seq"); super.new(name); endfunction
  task body();
    // The unit-level certificate is a mocked trusted input. The platform
    // producer and pre-reset retention need a separate integration proof.
    send(SBM_RESET,0,0,0,1,3);
    send(SBM_INIT,0,0,0,1,3);
  endtask
endclass

class sbm_mask_seq extends sbm_base_seq;
  `uvm_object_utils(sbm_mask_seq)
  function new(string name="sbm_mask_seq"); super.new(name); endfunction
  task body();
    bit [13:0] addresses[3] = '{14'd0,14'd8191,14'd16383};
    foreach (addresses[j]) begin
      send(SBM_WRITE,addresses[j],32'h11223344,4'hf);
      for (int m=0; m<16; m++) begin
        send(SBM_WRITE,addresses[j],32'hda709e55 ^ (m*32'h01020304),4'(m));
        send(SBM_READ,addresses[j]);
      end
    end
  endtask
endclass

class sbm_snapshot_seq extends sbm_base_seq;
  `uvm_object_utils(sbm_snapshot_seq)
  function new(string name="sbm_snapshot_seq"); super.new(name); endfunction
  task body();
    // Four consecutive physical issue edges at the same word, with unique
    // tickets. T0 must preserve the original snapshot after the later write.
    send(SBM_WRITE,14'd912,32'h11223344,4'hf);
    send(SBM_READ,14'd912);
    send(SBM_WRITE,14'd912,32'h88776655,4'hf);
    send(SBM_READ,14'd912);
    send(SBM_READ,14'd912);
  endtask
endclass

class sbm_zero_scan_seq extends sbm_base_seq;
  `uvm_object_utils(sbm_zero_scan_seq)
  function new(string name="sbm_zero_scan_seq"); super.new(name); endfunction
  task body();
    for (int unsigned a=0; a<SBM_DEPTH; a++)
      send(SBM_READ,14'(a));
  endtask
endclass

class sbm_zero_scan_missing_seq extends sbm_base_seq;
  `uvm_object_utils(sbm_zero_scan_missing_seq)
  function new(string name="sbm_zero_scan_missing_seq"); super.new(name); endfunction
  task body();
    for (int unsigned a=0; a<SBM_DEPTH; a++)
      if (a != 7777) send(SBM_READ,14'(a));
  endtask
endclass

class sbm_address_pattern_seq extends sbm_base_seq;
  `uvm_object_utils(sbm_address_pattern_seq)
  function new(string name="sbm_address_pattern_seq"); super.new(name); endfunction
  task body();
    for (int unsigned a=0;a<SBM_DEPTH;a++)
      send(SBM_WRITE,14'(a),32'h9e3779b9 ^ (32'(a)*32'h01010101),4'hf);
    for (int unsigned a=0;a<SBM_DEPTH;a++)
      send(SBM_READ,14'(a));
  endtask
endclass

class sbm_ticket_seq extends sbm_base_seq;
  `uvm_object_utils(sbm_ticket_seq)
  function new(string name="sbm_ticket_seq"); super.new(name); endfunction
  task body();
    bit [SBM_TICKET_W-1:0] pattern;
    // Same low 32 bits with different upper bits catches truncation.
    send(SBM_WRITE,14'd911,32'ha1b2c3d4,4'hf,0,1,0,1,
         {63'h1234567,32'hdeadbeef});
    send(SBM_READ,14'd911,0,0,0,1,0,1,
         {63'h7654321,32'hdeadbeef});
    send(SBM_READ,14'd911,0,0,0,1,0,1,'1);
    for (int i=0;i<SBM_TICKET_W;i++) begin
      pattern='0;
      pattern[i]=1;
      send(SBM_READ,14'd911,0,0,0,1,0,1,pattern);
      send(SBM_WRITE,14'd911,32'h01020408 ^ 32'(i),4'hf,0,1,0,1,~pattern);
    end
  endtask
endclass

class sbm_alternating_seq extends sbm_base_seq;
  `uvm_object_utils(sbm_alternating_seq)
  function new(string name="sbm_alternating_seq"); super.new(name); endfunction
  task body();
    for (int i=0;i<50;i++) begin
      send(SBM_READ,14'd911);
      send(SBM_WRITE,14'd911,32'(i) ^ 32'hff00aa55,4'hf);
    end
    send(SBM_WRITE,14'd911,32'hffeeddcc,4'hf);
    send(SBM_READ,14'd911);
    send(SBM_WRITE,14'd911,32'h12345678,4'h0);
    send(SBM_WRITE,14'd911,32'h87654321,4'hf);
    send(SBM_READ,14'd911);
  endtask
endclass

// Stimulus for externally mutated RTL. This sequence contains no replacement
// RAM behavior; a mutation is selected by the RTL build, not by the oracle.
class sbm_mutation_probe_seq extends sbm_base_seq;
  `uvm_object_utils(sbm_mutation_probe_seq)
  int unsigned mutation_case;
  function new(string name="sbm_mutation_probe_seq"); super.new(name); endfunction
  task body();
    case (mutation_case)
      1,3,4,14: begin
        send(SBM_READ,14'd919);
        send(SBM_READ,14'd920);
      end
      2,15: begin
        send(SBM_WRITE,14'd919,32'h11223344,4'hf);
        send(SBM_READ,14'd919);
        send(SBM_WRITE,14'd919,32'h88776655,4'hf);
        send(SBM_READ,14'd919);
      end
      5,12,13: send(SBM_WRITE,14'd919,32'h12345678,4'hf);
      6: begin
        send(SBM_WRITE,14'd919,32'h10203040,4'hf);
        for (int m=1;m<16;m++) begin
          send(SBM_WRITE,14'd919,32'hda70babe ^ 32'(m),4'(m));
          send(SBM_READ,14'd919);
        end
      end
      7: begin
        send(SBM_WRITE,14'd919,32'hffffffff,4'h0);
        send(SBM_WRITE,14'd919,32'h11223344,4'hf);
        send(SBM_READ,14'd919);
      end
      8,9,10,16: send(SBM_READ,14'd16383);
      11: begin
        send(SBM_READ,14'd919,0,0,0,1,0,1,
             {63'h1234567,32'hdeadbeef});
        send(SBM_READ,14'd919,0,0,0,1,0,1,
             {63'h7654321,32'hdeadbeef});
      end
      default: `uvm_fatal("SBM-MUT","Unknown mutation probe case")
    endcase
  endtask
endclass

class sbm_repeat_init_seq extends sbm_base_seq;
  `uvm_object_utils(sbm_repeat_init_seq)
  function new(string name="sbm_repeat_init_seq"); super.new(name); endfunction
  task body();
    // An active INIT request must not duplicate the sweep or publish DONE.
    send(SBM_INIT_HOLD,0,0,0,0,5);
  endtask
endclass

class sbm_unqualified_seq extends sbm_base_seq;
  `uvm_object_utils(sbm_unqualified_seq)
  function new(string name="sbm_unqualified_seq"); super.new(name); endfunction
  task body();
    send(SBM_RESET,0,0,0,0,3);
    send(SBM_INIT,0,0,0,0,4);
  endtask
endclass

class sbm_during_scrub_seq extends sbm_base_seq;
  `uvm_object_utils(sbm_during_scrub_seq)
  function new(string name="sbm_during_scrub_seq"); super.new(name); endfunction
  task body();
    send(SBM_READ,14'd0);
    send(SBM_WRITE,14'd1,32'hffffffff,4'hf);
    send(SBM_WRITE,14'd2,32'h12345678,4'h0);
  endtask
endclass

class sbm_illegal_control_seq extends sbm_base_seq;
  `uvm_object_utils(sbm_illegal_control_seq)
  function new(string name="sbm_illegal_control_seq"); super.new(name); endfunction
  task body();
    send(SBM_BOTH,14'd66,32'hff0055aa,4'hf);
    send(SBM_X_RD,14'd66);
  endtask
endclass
