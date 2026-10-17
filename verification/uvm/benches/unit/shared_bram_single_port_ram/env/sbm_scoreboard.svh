class sbm_scoreboard extends uvm_component;
  `uvm_component_utils(sbm_scoreboard)
  uvm_analysis_imp #(sbm_cycle, sbm_scoreboard) imp;
  int unsigned latency = 2;
  bit [31:0] mem[SBM_DEPTH];
  bit [SBM_DEPTH-1:0] known;
  bit initialized;
  bit [SBM_DEPTH-1:0] scrub_seen;
  int unsigned scrub_count, completed_scrubs;
  longint unsigned final_scrub_cycle;
  bit last_done;
  bit scrub_started;
  int unsigned errors, reads_checked, writes_checked, zero_reads_checked;
  int unsigned during_scrub_attempts;
  bit unsafe_fault_seen;
  bit pending_illegal_fault;
  bit qualified_epoch;
  bit prior_certificate, reset_held, unqualified_reset;
  int unsigned reset_epochs, denied_resets;
  bit scan_active;
  bit [SBM_DEPTH-1:0] scan_seen;
  int unsigned scan_unique;
  bit prev_post_valid;
  logic prev_post_rvalid, prev_post_wvalid;
  logic [SBM_TICKET_W-1:0] prev_post_rticket, prev_post_wticket;
  logic [31:0] prev_post_rdata;
  int unsigned masks_seen[16];
  typedef struct packed {
    longint unsigned due;
    logic [31:0] data;
    logic [SBM_TICKET_W-1:0] ticket;
    logic [13:0] addr;
    bit scan;
  } expected_read_t;
  expected_read_t pending_reads[$];
  typedef struct packed {
    longint unsigned issue;
    logic [SBM_TICKET_W-1:0] ticket;
  } expected_write_t;
  expected_write_t pending_writes[$];

  function new(string name, uvm_component parent);
    super.new(name,parent); imp = new("imp",this);
  endfunction
  function void build_phase(uvm_phase phase);
    super.build_phase(phase);
    void'(uvm_config_db#(int unsigned)::get(this,"","read_latency",latency));
    if (!(latency inside {1,2})) `uvm_fatal("CONFIG","READ_LATENCY must be 1 or 2")
  endfunction
  function void bad(string id, string detail);
    errors++;
    `uvm_error(id,detail)
  endfunction
  function void start_zero_scan();
    if (!initialized || pending_reads.size()!=0)
      bad("SBM-SCAN","Scan started before completed init or with pending reads");
    scan_seen='0;
    scan_unique=0;
    scan_active=1;
  endfunction
  function void finish_zero_scan();
    if (pending_reads.size())
      bad("SBM-SCAN","Scan finished before all responses were checked");
    scan_active=0;
    if (scan_unique!=SBM_DEPTH || scan_seen !== '1)
      bad("SBM-SCAN",$sformatf("Exhaustive zero scan visited %0d/%0d unique addresses",
                              scan_unique,SBM_DEPTH));
  endfunction
  function void remember_post(sbm_cycle c);
    prev_post_valid=1;
    prev_post_rvalid=c.rvalid;
    prev_post_wvalid=c.wvalid;
    prev_post_rticket=c.rticket;
    prev_post_wticket=c.wticket;
    prev_post_rdata=c.rdata;
  endfunction
  function void check_receipts(sbm_cycle c);
    expected_read_t er;
    expected_write_t ew;
    while (pending_reads.size() && pending_reads[0].due < c.cycle) begin
      er=pending_reads.pop_front();
      bad("SBM-ASRT-03",$sformatf("Lost READ result due at %0d for addr %0d",er.due,er.addr));
    end
    if (pending_reads.size() && pending_reads[0].due == c.cycle) begin
      er=pending_reads.pop_front();
      if (!c.rvalid)
        bad("SBM-ASRT-03",$sformatf("Missing READ result at cycle %0d addr %0d",c.cycle,er.addr));
      else if (c.rticket !== er.ticket || c.rdata !== er.data)
        bad("SBM-ASRT-03",$sformatf("cycle %0d addr %0d: data/ticket expected %08h/%h got %08h/%h",
            c.cycle,er.addr,er.data,er.ticket,c.rdata,c.rticket));
      else begin
        reads_checked++;
        if (er.scan) begin
          if (er.data !== 32'b0)
            bad("SBM-SCAN",$sformatf("Nonzero model word during zero scan at addr %0d",er.addr));
          if (scan_seen[er.addr])
            bad("SBM-SCAN",$sformatf("Duplicate zero-scan address %0d",er.addr));
          else begin scan_seen[er.addr]=1; scan_unique++; end
        end
      end
    end else if (c.rvalid)
      bad("SBM-ASRT-03",$sformatf("Early/duplicate/orphan READ result at cycle %0d",c.cycle));

    while (pending_writes.size() && pending_writes[0].issue < c.cycle) begin
      ew=pending_writes.pop_front();
      bad("SBM-ASRT-04",$sformatf("Lost WRITE receipt for issue %0d",ew.issue));
    end
    if (pending_writes.size() && pending_writes[0].issue == c.cycle) begin
      ew=pending_writes.pop_front();
      if (!c.wvalid || c.wticket !== ew.ticket)
        bad("SBM-ASRT-04",$sformatf("Missing/wrong WRITE receipt at issue edge %0d ticket %h/%h",
                                 c.cycle,ew.ticket,c.wticket));
    end else if (c.wvalid)
      bad("SBM-ASRT-04",$sformatf("Early/duplicate/orphan WRITE receipt at cycle %0d",c.cycle));
  endfunction
  function void write(sbm_cycle c);
    expected_write_t ew;
    bit normal_read, normal_write;
    bit expected_issue;
    bit [31:0] new_word;

    if ($isunknown({c.rst_n,c.init_req,c.isolation,
                    c.rvalid,c.wvalid,c.phys_rd,c.phys_we,c.init_we,
                    c.init_commit,c.done,c.active,c.idle,c.fault})) begin
      bad("SBM-XZ",$sformatf("X/Z control at cycle %0d",c.cycle));
      return;
    end
    // The pre-edge registered outputs must equal the previous edge's
    // post-NBA outputs. A receipt that follows the new inputs combinationally
    // is therefore rejected even when an older write was also outstanding.
    if (prev_post_valid && c.rst_n) begin
      if (c.pre_wr_valid !== prev_post_wvalid ||
          c.pre_rd_valid !== prev_post_rvalid)
        bad("SBM-ASRT-04","Receipt valid changed before the sampling edge");
      if (c.pre_wr_valid && c.pre_wr_ticket !== prev_post_wticket)
        bad("SBM-ASRT-04","Write ticket changed before the sampling edge");
      if (c.pre_rd_valid &&
          (c.pre_rd_ticket !== prev_post_rticket || c.pre_rdata !== prev_post_rdata))
        bad("SBM-ASRT-03","Read payload changed before the sampling edge");
    end
    if (c.phys_rd && (|c.phys_we || c.init_we))
      bad("SBM-ASRT-01","normal read overlaps a write");
    if (|c.phys_we && c.init_we)
      bad("SBM-ASRT-01","normal write overlaps INIT");
    if (c.init_we != c.init_commit)
      bad("SBM-ASRT-07","pre-edge INIT WE and post-edge commit disagree");
    if (pending_illegal_fault && !c.pre_active && !c.fault)
      bad("SBM-XZ","illegal/X command did not record init_fault on following edge");
    pending_illegal_fault=0;
    if ($isunknown({c.rd,c.wr,c.strb}) || (c.rd && c.wr)) begin
      if (c.phys_rd || |c.phys_we)
        bad("SBM-ASRT-01","illegal/X command caused a physical normal operation");
      pending_illegal_fault=1;
    end

    // A reset does not prove isolation. Accepted old tickets are retained until
    // a separately certified coherent reset; the unit test drives that proof.
    if (!c.rst_n) begin
      if (!reset_held) begin
        unqualified_reset = !(prior_certificate && c.isolation === 1'b1);
        if (!unqualified_reset) begin
          reset_epochs++;
        initialized = 0;
        known = '0;
        scrub_seen = '0;
        scrub_count = 0;
        scrub_started = 0;
        final_scrub_cycle = 0;
        qualified_epoch = 1;
        pending_reads.delete();
        pending_writes.delete();
        end else begin
          denied_resets++;
          qualified_epoch=0;
        end
      end
      reset_held=1;
      if (c.init_req)
        bad("SBM-RESET","Platform init request overlaps reset request");
      if (c.phys_rd || |c.phys_we || c.init_we || (!unqualified_reset && c.done))
        bad("SBM-ASRT-06","physical service or premature DONE during reset");
      if (unqualified_reset && initialized && !c.done)
        bad("SBM-RESET","Unqualified reset cleared completed init epoch");
      if (unqualified_reset) check_receipts(c);
      last_done = c.done;
      remember_post(c);
      return;
    end
    reset_held=0;
    prior_certificate=(c.isolation === 1'b1 && !c.init_req);

    if (c.init_we) begin
      if ($isunknown(c.init_addr)) begin
        bad("SBM-XZ","Unknown INIT address at physical write edge");
        remember_post(c);
        return;
      end
      if (!scrub_started) begin
        if (!qualified_epoch)
          bad("SBM-ASRT-06","INIT write without a qualified coherent reset epoch");
        scrub_started = 1;
        scrub_seen = '0;
        scrub_count = 0;
        initialized = 0;
      end
      if (c.init_addr !== 14'(scrub_count))
        bad("SBM-ASRT-07",$sformatf("INIT order: got %0d expected %0d",c.init_addr,scrub_count));
      if (scrub_seen[c.init_addr])
        bad("SBM-ASRT-07",$sformatf("duplicate INIT address %0d",c.init_addr));
      scrub_seen[c.init_addr] = 1'b1;
      // The pin contract does not expose INIT data/byte-mask at the primitive.
      // Zero contents must also be proven by the exhaustive readback scan.
      mem[c.init_addr] = '0;
      known[c.init_addr] = 1;
      scrub_count++;
      if (scrub_count == SBM_DEPTH) final_scrub_cycle = c.cycle;
      if (scrub_count > SBM_DEPTH)
        bad("SBM-ASRT-07","more than 16384 INIT writes");
    end
    if (c.active && (c.phys_rd || |c.phys_we))
      bad("SBM-ASRT-09","normal physical service during INIT");
    if (c.active && (c.rd || c.wr)) during_scrub_attempts++;
    if (c.init_req && !c.isolation && c.fault) unsafe_fault_seen = 1;
    if (c.init_req && !qualified_epoch && !c.active && c.init_we)
      bad("SBM-RESET","Uncertified request started physical scrub");
    if (c.done && !last_done) begin
      if (scrub_count != SBM_DEPTH || scrub_seen !== '1)
        bad("SBM-ASRT-07",$sformatf("DONE after %0d unique INIT writes",scrub_count));
      if (c.cycle <= final_scrub_cycle)
        bad("SBM-ASRT-08","DONE asserted on or before last INIT commit");
      if (c.init_we || c.active)
        bad("SBM-ASRT-08","DONE asserted while INIT busy");
      if (scrub_count == SBM_DEPTH && scrub_seen === '1) begin
        initialized = 1;
        completed_scrubs++;
        qualified_epoch = 0;
      end
    end
    if (last_done && !c.done && !(c.init_req && c.isolation))
      bad("SBM-ASRT-13","init_done lost without certified reinit");
    last_done = c.done;

    expected_issue = c.pre_done && !c.pre_active && !(c.init_req && c.isolation);
    normal_read = expected_issue && c.rd && !c.wr;
    normal_write = expected_issue && c.wr && !c.rd && (|c.strb);
    if (c.phys_rd !== normal_read)
      bad("SBM-ASRT-01",$sformatf("physical RD mismatch at cycle %0d",c.cycle));
    if (c.phys_we !== (normal_write ? c.strb : 4'b0))
      bad("SBM-ASRT-02",$sformatf("physical WE mismatch at cycle %0d",c.cycle));

    if ((c.phys_rd && $isunknown({c.addr,c.ticket})) ||
        ((|c.phys_we) && $isunknown({c.addr,c.ticket,c.wdata,c.phys_we}))) begin
      bad("SBM-XZ","Unknown physical normal address/data/ticket at issue edge");
      remember_post(c);
      return;
    end

    // The physical enables and address are sampled just before N. Model the
    // snapshot/commit at N, then compare registered outputs after NBA at N.
    if (c.phys_rd) begin
      if (!initialized) bad("SBM-ASRT-09","read before qualified initialization");
      if (!known[c.addr]) bad("SBM-MEM","Read from a word without a known model value");
      er.due = c.cycle + latency;
      er.data = mem[c.addr];
      er.ticket = c.ticket;
      er.addr = c.addr;
      er.scan = scan_active;
      pending_reads.push_back(er);
    end
    if (|c.phys_we) begin
      if (!initialized) bad("SBM-ASRT-09","write before qualified initialization");
      if (!known[c.addr]) bad("SBM-MEM","Write to a word without a known model value");
      new_word = mem[c.addr];
      for (int lane=0; lane<4; lane++)
        if (c.phys_we[lane]) new_word[lane*8 +: 8] = c.wdata[lane*8 +: 8];
      mem[c.addr] = new_word;
      known[c.addr] = 1;
      ew.issue = c.cycle;
      ew.ticket = c.ticket;
      pending_writes.push_back(ew);
      masks_seen[c.phys_we]++;
      writes_checked++;
    end
    if (c.wr && c.strb == 0 && !c.rd) begin
      if (c.phys_we !== 0) bad("SBM-ASRT-05","zero strobe drove WE");
      zero_reads_checked++;
    end

    check_receipts(c);

    if (c.idle && (c.active || c.init_we || c.rvalid || c.wvalid ||
                    pending_reads.size() || pending_writes.size()))
      bad("SBM-ASRT-14","RAM declares idle while service is pending");
    remember_post(c);
  endfunction
  function void check_phase(uvm_phase phase);
    super.check_phase(phase);
    if (pending_reads.size() || pending_writes.size())
      bad("SBM-DRAIN","test ended with pending physical receipts");
  endfunction
endclass
