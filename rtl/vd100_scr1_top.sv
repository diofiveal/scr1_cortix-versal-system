// Board-level top for ALINX VD100, XCVE2302, Vivado 2023.2.
//
// Synthesis fix:
//   The generated vd100_platform_wrapper does not expose AXI AWREGION/ARREGION
//   pins on S_AXI_IMEM/S_AXI_DMEM.  SCR1 still produces these signals, but the
//   BD/SmartConnect path does not consume them, so they are intentionally left
//   unconnected at the subsystem boundary.
//
// Dedicated PS MIO is configured by CIPS, not assigned as ordinary PL pins.

import vd100_scr1_pkg::*;

module vd100_scr1_top (
    input  wire [0:0]  sys_clk_clk_p,
    input  wire [0:0]  sys_clk_clk_n,
    output wire [0:0]  DDR4_act_n,
    output wire [16:0] DDR4_adr,
    output wire [1:0]  DDR4_ba,
    output wire [0:0]  DDR4_bg,
    output wire [0:0]  DDR4_ck_t,
    output wire [0:0]  DDR4_ck_c,
    output wire [0:0]  DDR4_cke,
    output wire [0:0]  DDR4_cs_n,
    inout  wire [7:0]  DDR4_dm_n,
    inout  wire [63:0] DDR4_dq,
    inout  wire [7:0]  DDR4_dqs_t,
    inout  wire [7:0]  DDR4_dqs_c,
    output wire [0:0]  DDR4_odt,
    output wire [0:0]  DDR4_reset_n
);

    wire clk;
    wire rst_n;
    wire [2:0] platform_ready;
    wire irq_to_a72;
    wire boot_write_allowed;
    wire clear_fault;
    wire boot_violation;
    wire [31:0] boot_violation_addr;
    scr1_lifecycle_state_e lifecycle_state;
    wire debug_cpu_rst_n;
    wire [3:0] debug_axi_fault_code;
    wire [11:0] debug_outstanding;

    // -------------------------------------------------------------------------
    // AXI4-Lite: platform -> SCR1 control
    // -------------------------------------------------------------------------
    wire [11:0] ctrl_awaddr;
    wire [2:0]  ctrl_awprot;
    wire        ctrl_awvalid;
    wire        ctrl_awready;
    wire [31:0] ctrl_wdata;
    wire [3:0]  ctrl_wstrb;
    wire        ctrl_wvalid;
    wire        ctrl_wready;
    wire [1:0]  ctrl_bresp;
    wire        ctrl_bvalid;
    wire        ctrl_bready;
    wire [11:0] ctrl_araddr;
    wire [2:0]  ctrl_arprot;
    wire        ctrl_arvalid;
    wire        ctrl_arready;
    wire [31:0] ctrl_rdata;
    wire [1:0]  ctrl_rresp;
    wire        ctrl_rvalid;
    wire        ctrl_rready;

    // -------------------------------------------------------------------------
    // AXI4-Lite: platform -> Boot BRAM adapter
    // -------------------------------------------------------------------------
    wire [15:0] boot_awaddr;
    wire [2:0]  boot_awprot;
    wire        boot_awvalid;
    wire        boot_awready;
    wire [31:0] boot_wdata;
    wire [3:0]  boot_wstrb;
    wire        boot_wvalid;
    wire        boot_wready;
    wire [1:0]  boot_bresp;
    wire        boot_bvalid;
    wire        boot_bready;
    wire [15:0] boot_araddr;
    wire [2:0]  boot_arprot;
    wire        boot_arvalid;
    wire        boot_arready;
    wire [31:0] boot_rdata;
    wire [1:0]  boot_rresp;
    wire        boot_rvalid;
    wire        boot_rready;

    // -------------------------------------------------------------------------
    // SCR1 IMEM AXI4
    // REGION is intentionally not carried into the generated BD wrapper.
    // -------------------------------------------------------------------------
    wire [3:0]  m_axi_imem_awid;
    wire [31:0] m_axi_imem_awaddr;
    wire [7:0]  m_axi_imem_awlen;
    wire [2:0]  m_axi_imem_awsize;
    wire [1:0]  m_axi_imem_awburst;
    wire        m_axi_imem_awlock;
    wire [3:0]  m_axi_imem_awcache;
    wire [2:0]  m_axi_imem_awprot;
    wire [3:0]  m_axi_imem_awqos;
    wire [3:0]  m_axi_imem_awuser;
    wire        m_axi_imem_awvalid;
    wire        m_axi_imem_awready;

    wire [31:0] m_axi_imem_wdata;
    wire [3:0]  m_axi_imem_wstrb;
    wire        m_axi_imem_wlast;
    wire [3:0]  m_axi_imem_wuser;
    wire        m_axi_imem_wvalid;
    wire        m_axi_imem_wready;

    wire [3:0]  m_axi_imem_bid;
    wire [1:0]  m_axi_imem_bresp;
    wire [3:0]  m_axi_imem_buser;
    wire        m_axi_imem_bvalid;
    wire        m_axi_imem_bready;

    wire [3:0]  m_axi_imem_arid;
    wire [31:0] m_axi_imem_araddr;
    wire [7:0]  m_axi_imem_arlen;
    wire [2:0]  m_axi_imem_arsize;
    wire [1:0]  m_axi_imem_arburst;
    wire        m_axi_imem_arlock;
    wire [3:0]  m_axi_imem_arcache;
    wire [2:0]  m_axi_imem_arprot;
    wire [3:0]  m_axi_imem_arqos;
    wire [3:0]  m_axi_imem_aruser;
    wire        m_axi_imem_arvalid;
    wire        m_axi_imem_arready;

    wire [3:0]  m_axi_imem_rid;
    wire [31:0] m_axi_imem_rdata;
    wire [1:0]  m_axi_imem_rresp;
    wire        m_axi_imem_rlast;
    wire [3:0]  m_axi_imem_ruser;
    wire        m_axi_imem_rvalid;
    wire        m_axi_imem_rready;

    // -------------------------------------------------------------------------
    // SCR1 DMEM AXI4
    // REGION is intentionally not carried into the generated BD wrapper.
    // -------------------------------------------------------------------------
    wire [3:0]  m_axi_dmem_awid;
    wire [31:0] m_axi_dmem_awaddr;
    wire [7:0]  m_axi_dmem_awlen;
    wire [2:0]  m_axi_dmem_awsize;
    wire [1:0]  m_axi_dmem_awburst;
    wire        m_axi_dmem_awlock;
    wire [3:0]  m_axi_dmem_awcache;
    wire [2:0]  m_axi_dmem_awprot;
    wire [3:0]  m_axi_dmem_awqos;
    wire [3:0]  m_axi_dmem_awuser;
    wire        m_axi_dmem_awvalid;
    wire        m_axi_dmem_awready;

    wire [31:0] m_axi_dmem_wdata;
    wire [3:0]  m_axi_dmem_wstrb;
    wire        m_axi_dmem_wlast;
    wire [3:0]  m_axi_dmem_wuser;
    wire        m_axi_dmem_wvalid;
    wire        m_axi_dmem_wready;

    wire [3:0]  m_axi_dmem_bid;
    wire [1:0]  m_axi_dmem_bresp;
    wire [3:0]  m_axi_dmem_buser;
    wire        m_axi_dmem_bvalid;
    wire        m_axi_dmem_bready;

    wire [3:0]  m_axi_dmem_arid;
    wire [31:0] m_axi_dmem_araddr;
    wire [7:0]  m_axi_dmem_arlen;
    wire [2:0]  m_axi_dmem_arsize;
    wire [1:0]  m_axi_dmem_arburst;
    wire        m_axi_dmem_arlock;
    wire [3:0]  m_axi_dmem_arcache;
    wire [2:0]  m_axi_dmem_arprot;
    wire [3:0]  m_axi_dmem_arqos;
    wire [3:0]  m_axi_dmem_aruser;
    wire        m_axi_dmem_arvalid;
    wire        m_axi_dmem_arready;

    wire [3:0]  m_axi_dmem_rid;
    wire [31:0] m_axi_dmem_rdata;
    wire [1:0]  m_axi_dmem_rresp;
    wire        m_axi_dmem_rlast;
    wire [3:0]  m_axi_dmem_ruser;
    wire        m_axi_dmem_rvalid;
    wire        m_axi_dmem_rready;

    // Address-only aliases preserve AXI ordering/handshake semantics.
    // SCR1 keeps the local FFxx_xxxx map; A72 uses the A4xx_xxxx PL aperture.
    function automatic logic [31:0] platform_address(input logic [31:0] a);
        if (a[31:16] == 16'hFFFF)
            platform_address = 32'hA401_0000 | {16'd0, a[15:0]};
        else if (a[31:12] == 20'hFF000)
            platform_address = 32'hA400_0000 | {20'd0, a[11:0]};
        else
            platform_address = a;
    endfunction

    // -------------------------------------------------------------------------
    // Vivado-generated Block Design wrapper
    // -------------------------------------------------------------------------
    vd100_platform_wrapper u_platform (
        .sys_clk_clk_p          (sys_clk_clk_p),
        .sys_clk_clk_n          (sys_clk_clk_n),
        .DDR4_act_n             (DDR4_act_n),
        .DDR4_adr               (DDR4_adr),
        .DDR4_ba                (DDR4_ba),
        .DDR4_bg                (DDR4_bg),
        .DDR4_ck_t              (DDR4_ck_t),
        .DDR4_ck_c              (DDR4_ck_c),
        .DDR4_cke               (DDR4_cke),
        .DDR4_cs_n              (DDR4_cs_n),
        .DDR4_dm_n              (DDR4_dm_n),
        .DDR4_dq                (DDR4_dq),
        .DDR4_dqs_t             (DDR4_dqs_t),
        .DDR4_dqs_c             (DDR4_dqs_c),
        .DDR4_odt               (DDR4_odt),
        .DDR4_reset_n           (DDR4_reset_n),

        .pl_clk_o               (clk),
        .pl_rst_no              (rst_n),
        .platform_ready_o       (platform_ready),
        .scr1_irq_i             (irq_to_a72),
        .debug_scr1_resetn_i     (debug_cpu_rst_n),
        .debug_lifecycle_i       (lifecycle_state),
        .debug_axi_fault_i       (debug_axi_fault_code),
        .debug_outstanding_i     (debug_outstanding),

        .M_AXIL_CTRL_awaddr     (ctrl_awaddr),
        .M_AXIL_CTRL_awprot     (ctrl_awprot),
        .M_AXIL_CTRL_awvalid    (ctrl_awvalid),
        .M_AXIL_CTRL_awready    (ctrl_awready),
        .M_AXIL_CTRL_wdata      (ctrl_wdata),
        .M_AXIL_CTRL_wstrb      (ctrl_wstrb),
        .M_AXIL_CTRL_wvalid     (ctrl_wvalid),
        .M_AXIL_CTRL_wready     (ctrl_wready),
        .M_AXIL_CTRL_bresp      (ctrl_bresp),
        .M_AXIL_CTRL_bvalid     (ctrl_bvalid),
        .M_AXIL_CTRL_bready     (ctrl_bready),
        .M_AXIL_CTRL_araddr     (ctrl_araddr),
        .M_AXIL_CTRL_arprot     (ctrl_arprot),
        .M_AXIL_CTRL_arvalid    (ctrl_arvalid),
        .M_AXIL_CTRL_arready    (ctrl_arready),
        .M_AXIL_CTRL_rdata      (ctrl_rdata),
        .M_AXIL_CTRL_rresp      (ctrl_rresp),
        .M_AXIL_CTRL_rvalid     (ctrl_rvalid),
        .M_AXIL_CTRL_rready     (ctrl_rready),

        .M_AXIL_BOOT_awaddr     (boot_awaddr),
        .M_AXIL_BOOT_awprot     (boot_awprot),
        .M_AXIL_BOOT_awvalid    (boot_awvalid),
        .M_AXIL_BOOT_awready    (boot_awready),
        .M_AXIL_BOOT_wdata      (boot_wdata),
        .M_AXIL_BOOT_wstrb      (boot_wstrb),
        .M_AXIL_BOOT_wvalid     (boot_wvalid),
        .M_AXIL_BOOT_wready     (boot_wready),
        .M_AXIL_BOOT_bresp      (boot_bresp),
        .M_AXIL_BOOT_bvalid     (boot_bvalid),
        .M_AXIL_BOOT_bready     (boot_bready),
        .M_AXIL_BOOT_araddr     (boot_araddr),
        .M_AXIL_BOOT_arprot     (boot_arprot),
        .M_AXIL_BOOT_arvalid    (boot_arvalid),
        .M_AXIL_BOOT_arready    (boot_arready),
        .M_AXIL_BOOT_rdata      (boot_rdata),
        .M_AXIL_BOOT_rresp      (boot_rresp),
        .M_AXIL_BOOT_rvalid     (boot_rvalid),
        .M_AXIL_BOOT_rready     (boot_rready),

        .S_AXI_IMEM_awid        (m_axi_imem_awid),
        .S_AXI_IMEM_awaddr      (platform_address(m_axi_imem_awaddr)),
        .S_AXI_IMEM_awlen       (m_axi_imem_awlen),
        .S_AXI_IMEM_awsize      (m_axi_imem_awsize),
        .S_AXI_IMEM_awburst     (m_axi_imem_awburst),
        .S_AXI_IMEM_awlock      (m_axi_imem_awlock),
        .S_AXI_IMEM_awcache     (m_axi_imem_awcache),
        .S_AXI_IMEM_awprot      (m_axi_imem_awprot),
        .S_AXI_IMEM_awqos       (m_axi_imem_awqos),
        .S_AXI_IMEM_awuser      (m_axi_imem_awuser),
        .S_AXI_IMEM_awvalid     (m_axi_imem_awvalid),
        .S_AXI_IMEM_awready     (m_axi_imem_awready),
        .S_AXI_IMEM_wdata       (m_axi_imem_wdata),
        .S_AXI_IMEM_wstrb       (m_axi_imem_wstrb),
        .S_AXI_IMEM_wlast       (m_axi_imem_wlast),
        .S_AXI_IMEM_wuser       (m_axi_imem_wuser),
        .S_AXI_IMEM_wvalid      (m_axi_imem_wvalid),
        .S_AXI_IMEM_wready      (m_axi_imem_wready),
        .S_AXI_IMEM_bid         (m_axi_imem_bid),
        .S_AXI_IMEM_bresp       (m_axi_imem_bresp),
        .S_AXI_IMEM_buser       (m_axi_imem_buser),
        .S_AXI_IMEM_bvalid      (m_axi_imem_bvalid),
        .S_AXI_IMEM_bready      (m_axi_imem_bready),
        .S_AXI_IMEM_arid        (m_axi_imem_arid),
        .S_AXI_IMEM_araddr      (platform_address(m_axi_imem_araddr)),
        .S_AXI_IMEM_arlen       (m_axi_imem_arlen),
        .S_AXI_IMEM_arsize      (m_axi_imem_arsize),
        .S_AXI_IMEM_arburst     (m_axi_imem_arburst),
        .S_AXI_IMEM_arlock      (m_axi_imem_arlock),
        .S_AXI_IMEM_arcache     (m_axi_imem_arcache),
        .S_AXI_IMEM_arprot      (m_axi_imem_arprot),
        .S_AXI_IMEM_arqos       (m_axi_imem_arqos),
        .S_AXI_IMEM_aruser      (m_axi_imem_aruser),
        .S_AXI_IMEM_arvalid     (m_axi_imem_arvalid),
        .S_AXI_IMEM_arready     (m_axi_imem_arready),
        .S_AXI_IMEM_rid         (m_axi_imem_rid),
        .S_AXI_IMEM_rdata       (m_axi_imem_rdata),
        .S_AXI_IMEM_rresp       (m_axi_imem_rresp),
        .S_AXI_IMEM_rlast       (m_axi_imem_rlast),
        .S_AXI_IMEM_ruser       (m_axi_imem_ruser),
        .S_AXI_IMEM_rvalid      (m_axi_imem_rvalid),
        .S_AXI_IMEM_rready      (m_axi_imem_rready),

        .S_AXI_DMEM_awid        (m_axi_dmem_awid),
        .S_AXI_DMEM_awaddr      (platform_address(m_axi_dmem_awaddr)),
        .S_AXI_DMEM_awlen       (m_axi_dmem_awlen),
        .S_AXI_DMEM_awsize      (m_axi_dmem_awsize),
        .S_AXI_DMEM_awburst     (m_axi_dmem_awburst),
        .S_AXI_DMEM_awlock      (m_axi_dmem_awlock),
        .S_AXI_DMEM_awcache     (m_axi_dmem_awcache),
        .S_AXI_DMEM_awprot      (m_axi_dmem_awprot),
        .S_AXI_DMEM_awqos       (m_axi_dmem_awqos),
        .S_AXI_DMEM_awuser      (m_axi_dmem_awuser),
        .S_AXI_DMEM_awvalid     (m_axi_dmem_awvalid),
        .S_AXI_DMEM_awready     (m_axi_dmem_awready),
        .S_AXI_DMEM_wdata       (m_axi_dmem_wdata),
        .S_AXI_DMEM_wstrb       (m_axi_dmem_wstrb),
        .S_AXI_DMEM_wlast       (m_axi_dmem_wlast),
        .S_AXI_DMEM_wuser       (m_axi_dmem_wuser),
        .S_AXI_DMEM_wvalid      (m_axi_dmem_wvalid),
        .S_AXI_DMEM_wready      (m_axi_dmem_wready),
        .S_AXI_DMEM_bid         (m_axi_dmem_bid),
        .S_AXI_DMEM_bresp       (m_axi_dmem_bresp),
        .S_AXI_DMEM_buser       (m_axi_dmem_buser),
        .S_AXI_DMEM_bvalid      (m_axi_dmem_bvalid),
        .S_AXI_DMEM_bready      (m_axi_dmem_bready),
        .S_AXI_DMEM_arid        (m_axi_dmem_arid),
        .S_AXI_DMEM_araddr      (platform_address(m_axi_dmem_araddr)),
        .S_AXI_DMEM_arlen       (m_axi_dmem_arlen),
        .S_AXI_DMEM_arsize      (m_axi_dmem_arsize),
        .S_AXI_DMEM_arburst     (m_axi_dmem_arburst),
        .S_AXI_DMEM_arlock      (m_axi_dmem_arlock),
        .S_AXI_DMEM_arcache     (m_axi_dmem_arcache),
        .S_AXI_DMEM_arprot      (m_axi_dmem_arprot),
        .S_AXI_DMEM_arqos       (m_axi_dmem_arqos),
        .S_AXI_DMEM_aruser      (m_axi_dmem_aruser),
        .S_AXI_DMEM_arvalid     (m_axi_dmem_arvalid),
        .S_AXI_DMEM_arready     (m_axi_dmem_arready),
        .S_AXI_DMEM_rid         (m_axi_dmem_rid),
        .S_AXI_DMEM_rdata       (m_axi_dmem_rdata),
        .S_AXI_DMEM_rresp       (m_axi_dmem_rresp),
        .S_AXI_DMEM_rlast       (m_axi_dmem_rlast),
        .S_AXI_DMEM_ruser       (m_axi_dmem_ruser),
        .S_AXI_DMEM_rvalid      (m_axi_dmem_rvalid),
        .S_AXI_DMEM_rready      (m_axi_dmem_rready)
    );

    // -------------------------------------------------------------------------
    // SCR1 subsystem
    // -------------------------------------------------------------------------
    scr1_subsystem u_subsystem (
        .clk                         (clk),
        .rst_n                       (rst_n),
        .rtc_clk                     (1'b0),
        .clock_locked_i              (rst_n),
        .noc_ready_i                 (platform_ready[0]),
        .ddr_ready_i                 (platform_ready[1]),
        .verifier_ready_i            (platform_ready[2]),
        .irq_lines_i                 (16'd0),
        .soft_irq_i                  (1'b0),

        .s_axil_awaddr_i             (ctrl_awaddr),
        .s_axil_awprot_i             (ctrl_awprot),
        .s_axil_awvalid_i            (ctrl_awvalid),
        .s_axil_awready_o            (ctrl_awready),
        .s_axil_wdata_i              (ctrl_wdata),
        .s_axil_wstrb_i              (ctrl_wstrb),
        .s_axil_wvalid_i             (ctrl_wvalid),
        .s_axil_wready_o             (ctrl_wready),
        .s_axil_bresp_o              (ctrl_bresp),
        .s_axil_bvalid_o             (ctrl_bvalid),
        .s_axil_bready_i             (ctrl_bready),
        .s_axil_araddr_i             (ctrl_araddr),
        .s_axil_arprot_i             (ctrl_arprot),
        .s_axil_arvalid_i            (ctrl_arvalid),
        .s_axil_arready_o            (ctrl_arready),
        .s_axil_rdata_o              (ctrl_rdata),
        .s_axil_rresp_o              (ctrl_rresp),
        .s_axil_rvalid_o             (ctrl_rvalid),
        .s_axil_rready_i             (ctrl_rready),

        .m_axi_imem_awid_o           (m_axi_imem_awid),
        .m_axi_imem_awaddr_o         (m_axi_imem_awaddr),
        .m_axi_imem_awlen_o          (m_axi_imem_awlen),
        .m_axi_imem_awsize_o         (m_axi_imem_awsize),
        .m_axi_imem_awburst_o        (m_axi_imem_awburst),
        .m_axi_imem_awlock_o         (m_axi_imem_awlock),
        .m_axi_imem_awcache_o        (m_axi_imem_awcache),
        .m_axi_imem_awprot_o         (m_axi_imem_awprot),
        .m_axi_imem_awregion_o       (),
        .m_axi_imem_awqos_o          (m_axi_imem_awqos),
        .m_axi_imem_awuser_o         (m_axi_imem_awuser),
        .m_axi_imem_awvalid_o        (m_axi_imem_awvalid),
        .m_axi_imem_awready_i        (m_axi_imem_awready),
        .m_axi_imem_wdata_o          (m_axi_imem_wdata),
        .m_axi_imem_wstrb_o          (m_axi_imem_wstrb),
        .m_axi_imem_wlast_o          (m_axi_imem_wlast),
        .m_axi_imem_wuser_o          (m_axi_imem_wuser),
        .m_axi_imem_wvalid_o         (m_axi_imem_wvalid),
        .m_axi_imem_wready_i         (m_axi_imem_wready),
        .m_axi_imem_bid_i            (m_axi_imem_bid),
        .m_axi_imem_bresp_i          (m_axi_imem_bresp),
        .m_axi_imem_buser_i          (m_axi_imem_buser),
        .m_axi_imem_bvalid_i         (m_axi_imem_bvalid),
        .m_axi_imem_bready_o         (m_axi_imem_bready),
        .m_axi_imem_arid_o           (m_axi_imem_arid),
        .m_axi_imem_araddr_o         (m_axi_imem_araddr),
        .m_axi_imem_arlen_o          (m_axi_imem_arlen),
        .m_axi_imem_arsize_o         (m_axi_imem_arsize),
        .m_axi_imem_arburst_o        (m_axi_imem_arburst),
        .m_axi_imem_arlock_o         (m_axi_imem_arlock),
        .m_axi_imem_arcache_o        (m_axi_imem_arcache),
        .m_axi_imem_arprot_o         (m_axi_imem_arprot),
        .m_axi_imem_arregion_o       (),
        .m_axi_imem_arqos_o          (m_axi_imem_arqos),
        .m_axi_imem_aruser_o         (m_axi_imem_aruser),
        .m_axi_imem_arvalid_o        (m_axi_imem_arvalid),
        .m_axi_imem_arready_i        (m_axi_imem_arready),
        .m_axi_imem_rid_i            (m_axi_imem_rid),
        .m_axi_imem_rdata_i          (m_axi_imem_rdata),
        .m_axi_imem_rresp_i          (m_axi_imem_rresp),
        .m_axi_imem_rlast_i          (m_axi_imem_rlast),
        .m_axi_imem_ruser_i          (m_axi_imem_ruser),
        .m_axi_imem_rvalid_i         (m_axi_imem_rvalid),
        .m_axi_imem_rready_o         (m_axi_imem_rready),

        .m_axi_dmem_awid_o           (m_axi_dmem_awid),
        .m_axi_dmem_awaddr_o         (m_axi_dmem_awaddr),
        .m_axi_dmem_awlen_o          (m_axi_dmem_awlen),
        .m_axi_dmem_awsize_o         (m_axi_dmem_awsize),
        .m_axi_dmem_awburst_o        (m_axi_dmem_awburst),
        .m_axi_dmem_awlock_o         (m_axi_dmem_awlock),
        .m_axi_dmem_awcache_o        (m_axi_dmem_awcache),
        .m_axi_dmem_awprot_o         (m_axi_dmem_awprot),
        .m_axi_dmem_awregion_o       (),
        .m_axi_dmem_awqos_o          (m_axi_dmem_awqos),
        .m_axi_dmem_awuser_o         (m_axi_dmem_awuser),
        .m_axi_dmem_awvalid_o        (m_axi_dmem_awvalid),
        .m_axi_dmem_awready_i        (m_axi_dmem_awready),
        .m_axi_dmem_wdata_o          (m_axi_dmem_wdata),
        .m_axi_dmem_wstrb_o          (m_axi_dmem_wstrb),
        .m_axi_dmem_wlast_o          (m_axi_dmem_wlast),
        .m_axi_dmem_wuser_o          (m_axi_dmem_wuser),
        .m_axi_dmem_wvalid_o         (m_axi_dmem_wvalid),
        .m_axi_dmem_wready_i         (m_axi_dmem_wready),
        .m_axi_dmem_bid_i            (m_axi_dmem_bid),
        .m_axi_dmem_bresp_i          (m_axi_dmem_bresp),
        .m_axi_dmem_buser_i          (m_axi_dmem_buser),
        .m_axi_dmem_bvalid_i         (m_axi_dmem_bvalid),
        .m_axi_dmem_bready_o         (m_axi_dmem_bready),
        .m_axi_dmem_arid_o           (m_axi_dmem_arid),
        .m_axi_dmem_araddr_o         (m_axi_dmem_araddr),
        .m_axi_dmem_arlen_o          (m_axi_dmem_arlen),
        .m_axi_dmem_arsize_o         (m_axi_dmem_arsize),
        .m_axi_dmem_arburst_o        (m_axi_dmem_arburst),
        .m_axi_dmem_arlock_o         (m_axi_dmem_arlock),
        .m_axi_dmem_arcache_o        (m_axi_dmem_arcache),
        .m_axi_dmem_arprot_o         (m_axi_dmem_arprot),
        .m_axi_dmem_arregion_o       (),
        .m_axi_dmem_arqos_o          (m_axi_dmem_arqos),
        .m_axi_dmem_aruser_o         (m_axi_dmem_aruser),
        .m_axi_dmem_arvalid_o        (m_axi_dmem_arvalid),
        .m_axi_dmem_arready_i        (m_axi_dmem_arready),
        .m_axi_dmem_rid_i            (m_axi_dmem_rid),
        .m_axi_dmem_rdata_i          (m_axi_dmem_rdata),
        .m_axi_dmem_rresp_i          (m_axi_dmem_rresp),
        .m_axi_dmem_rlast_i          (m_axi_dmem_rlast),
        .m_axi_dmem_ruser_i          (m_axi_dmem_ruser),
        .m_axi_dmem_rvalid_i         (m_axi_dmem_rvalid),
        .m_axi_dmem_rready_o         (m_axi_dmem_rready),

        .boot_violation_i            (boot_violation),
        .boot_violation_addr_i       (boot_violation_addr),
        .boot_bram_host_write_enable_o(boot_write_allowed),
        .clear_fault_o               (clear_fault),
        .irq_to_a72_o                (irq_to_a72),
        .lifecycle_state_o           (lifecycle_state),
        .debug_cpu_rst_no            (debug_cpu_rst_n),
        .debug_axi_fault_code_o      (debug_axi_fault_code),
        .debug_outstanding_o         (debug_outstanding)
    );

    // -------------------------------------------------------------------------
    // A72 Boot BRAM AXI-Lite adapter / write guard
    // -------------------------------------------------------------------------
    scr1_boot_bram_axil u_boot (
        .clk                         (clk),
        .rst_n                       (rst_n),
        .write_allowed_i             (boot_write_allowed),
        .clear_fault_i               (clear_fault),
        .s_axil_awaddr_i             (boot_awaddr),
        .s_axil_awprot_i             (boot_awprot),
        .s_axil_awvalid_i            (boot_awvalid),
        .s_axil_awready_o            (boot_awready),
        .s_axil_wdata_i              (boot_wdata),
        .s_axil_wstrb_i              (boot_wstrb),
        .s_axil_wvalid_i             (boot_wvalid),
        .s_axil_wready_o             (boot_wready),
        .s_axil_bresp_o              (boot_bresp),
        .s_axil_bvalid_o             (boot_bvalid),
        .s_axil_bready_i             (boot_bready),
        .s_axil_araddr_i             (boot_araddr),
        .s_axil_arprot_i             (boot_arprot),
        .s_axil_arvalid_i            (boot_arvalid),
        .s_axil_arready_o            (boot_arready),
        .s_axil_rdata_o              (boot_rdata),
        .s_axil_rresp_o              (boot_rresp),
        .s_axil_rvalid_o             (boot_rvalid),
        .s_axil_rready_i             (boot_rready),
        .boot_violation_o            (boot_violation),
        .boot_violation_addr_o       (boot_violation_addr)
    );

endmodule : vd100_scr1_top
