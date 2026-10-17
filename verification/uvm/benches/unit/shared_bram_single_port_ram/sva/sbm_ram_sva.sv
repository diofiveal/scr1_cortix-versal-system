module sbm_ram_sva #(parameter int READ_LATENCY = 2)
  (sbm_ram_if vif);
  // These properties check pin-level safety. Data, snapshot timing, ticket
  // identity, and exact scrub cardinality are checked by the UVM scoreboard.
  ap_one_port: assert property (@(posedge vif.clk) disable iff (!vif.rst_n)
    !(vif.physical_rd_en_o && (|vif.physical_wr_en_o || vif.init_write_en_o)) &&
    !((|vif.physical_wr_en_o) && vif.init_write_en_o))
    else $error("SBM-ASRT-01: physical port collision");

  ap_no_zero_we: assert property (@(posedge vif.clk) disable iff (!vif.rst_n)
    (vif.ram_wr_en_i && vif.ram_wr_strb_i == 4'b0) |=>
    (vif.physical_wr_en_o == 4'b0))
    else $error("SBM-ASRT-05: WSTRB0 caused physical WE");

  ap_init_exclusive: assert property (@(posedge vif.clk) disable iff (!vif.rst_n)
    vif.init_active_o |-> !(vif.physical_rd_en_o || |vif.physical_wr_en_o))
    else $error("SBM-ASRT-09: normal service during INIT");

  ap_done_safe: assert property (@(posedge vif.clk) disable iff (!vif.rst_n)
    vif.bram_init_done_o |-> !vif.init_active_o)
    else $error("SBM-ASRT-08: init_done while sweep active");

  ap_no_unknown_ctrl: assert property (@(posedge vif.clk) disable iff (!vif.rst_n)
    !$isunknown({vif.physical_rd_en_o,vif.physical_wr_en_o,
                 vif.init_write_en_o,vif.init_commit_o,
                 vif.ram_rd_valid_o,vif.ram_wr_commit_valid_o,
                 vif.bram_init_done_o,vif.ram_idle_o}))
    else $error("SBM-XZ: unknown control signal");

  ap_x_is_safe: assert property (@(posedge vif.clk) disable iff (!vif.rst_n)
    $isunknown({vif.ram_rd_en_i,vif.ram_wr_en_i,vif.ram_wr_strb_i})
    |=> (!vif.physical_rd_en_o && !(|vif.physical_wr_en_o) && vif.init_fault_o))
    else $error("SBM-CC-22: X command reached physical RAM");

  cp_normal_write: cover property (@(posedge vif.clk) (|vif.physical_wr_en_o));
  cp_normal_read: cover property (@(posedge vif.clk) vif.physical_rd_en_o);
  cp_scrub: cover property (@(posedge vif.clk) vif.init_commit_o);
  cp_done: cover property (@(posedge vif.clk) vif.bram_init_done_o);
endmodule
