import scr1_regs_pkg::*;
import vd100_scr1_pkg::*;

`include "scr1_arch_description.svh"
`include "scr1_memif.svh"
`ifdef SCR1_IPIC_EN
`include "scr1_ipic.svh"
`endif // SCR1_IPIC_EN

`ifdef SCR1_TCM_EN
 `define SCR1_IMEM_ROUTER_EN
`endif // SCR1_TCM_EN

module scr1_subsystem #(
    parameter int unsigned AXIL_ADDR_WIDTH       = 12,
    parameter int unsigned AXIL_DATA_WIDTH       = 32,

    parameter int unsigned AXI_ADDR_WIDTH        = 32,
    parameter int unsigned AXI_DATA_WIDTH        = 32,
    parameter int unsigned AXI_ID_WIDTH          = 4,
    parameter int unsigned AXI_USER_WIDTH        = 4,

    parameter int unsigned OUTSTANDING_WIDTH     = 4,

    parameter int unsigned AXI_TIMEOUT_CYCLES    = 0,

    parameter bit VERIFY_REQUIRED                = 1'b0,

    parameter logic [31:0] BOOT_ADDR_VALUE       = 32'hFFFF_0000
) (
    // -------------------------------------------------------------------------
    // Clock / platform reset
    // -------------------------------------------------------------------------
    input  logic                         clk,
    input  logic                         rst_n,

    // Optional RTC source for SCR1 timer.
    // May be tied low in P1 if firmware does not select RTC clock.
    input  logic                         rtc_clk,

    // -------------------------------------------------------------------------
    // Platform readiness
    // -------------------------------------------------------------------------
    input  logic                         clock_locked_i,
    input  logic                         noc_ready_i,
    input  logic                         ddr_ready_i,
    input  logic                         verifier_ready_i,

    // -------------------------------------------------------------------------
    // SCR1 interrupt inputs
    // -------------------------------------------------------------------------
    input  logic [15:0]                  irq_lines_i,
    input  logic                         soft_irq_i,

    // -------------------------------------------------------------------------
    // AXI4-Lite slave: A72 -> scr1_control
    // -------------------------------------------------------------------------
    input  logic [AXIL_ADDR_WIDTH-1:0]   s_axil_awaddr_i,
    input  logic [2:0]                   s_axil_awprot_i,
    input  logic                         s_axil_awvalid_i,
    output logic                         s_axil_awready_o,

    input  logic [AXIL_DATA_WIDTH-1:0]   s_axil_wdata_i,
    input  logic [AXIL_DATA_WIDTH/8-1:0] s_axil_wstrb_i,
    input  logic                         s_axil_wvalid_i,
    output logic                         s_axil_wready_o,

    output logic [1:0]                   s_axil_bresp_o,
    output logic                         s_axil_bvalid_o,
    input  logic                         s_axil_bready_i,

    input  logic [AXIL_ADDR_WIDTH-1:0]   s_axil_araddr_i,
    input  logic [2:0]                   s_axil_arprot_i,
    input  logic                         s_axil_arvalid_i,
    output logic                         s_axil_arready_o,

    output logic [AXIL_DATA_WIDTH-1:0]   s_axil_rdata_o,
    output logic [1:0]                   s_axil_rresp_o,
    output logic                         s_axil_rvalid_o,
    input  logic                         s_axil_rready_i,

    // -------------------------------------------------------------------------
    // IMEM AXI4 master
    // SCR1 -> SmartConnect / NoC
    // -------------------------------------------------------------------------
    output logic [AXI_ID_WIDTH-1:0]      m_axi_imem_awid_o,
    output logic [AXI_ADDR_WIDTH-1:0]    m_axi_imem_awaddr_o,
    output logic [7:0]                   m_axi_imem_awlen_o,
    output logic [2:0]                   m_axi_imem_awsize_o,
    output logic [1:0]                   m_axi_imem_awburst_o,
    output logic                         m_axi_imem_awlock_o,
    output logic [3:0]                   m_axi_imem_awcache_o,
    output logic [2:0]                   m_axi_imem_awprot_o,
    output logic [3:0]                   m_axi_imem_awregion_o,
    output logic [3:0]                   m_axi_imem_awqos_o,
    output logic [AXI_USER_WIDTH-1:0]    m_axi_imem_awuser_o,
    output logic                         m_axi_imem_awvalid_o,
    input  logic                         m_axi_imem_awready_i,

    output logic [AXI_DATA_WIDTH-1:0]    m_axi_imem_wdata_o,
    output logic [AXI_DATA_WIDTH/8-1:0]  m_axi_imem_wstrb_o,
    output logic                         m_axi_imem_wlast_o,
    output logic [AXI_USER_WIDTH-1:0]    m_axi_imem_wuser_o,
    output logic                         m_axi_imem_wvalid_o,
    input  logic                         m_axi_imem_wready_i,

    input  logic [AXI_ID_WIDTH-1:0]      m_axi_imem_bid_i,
    input  logic [1:0]                   m_axi_imem_bresp_i,
    input  logic [AXI_USER_WIDTH-1:0]    m_axi_imem_buser_i,
    input  logic                         m_axi_imem_bvalid_i,
    output logic                         m_axi_imem_bready_o,

    output logic [AXI_ID_WIDTH-1:0]      m_axi_imem_arid_o,
    output logic [AXI_ADDR_WIDTH-1:0]    m_axi_imem_araddr_o,
    output logic [7:0]                   m_axi_imem_arlen_o,
    output logic [2:0]                   m_axi_imem_arsize_o,
    output logic [1:0]                   m_axi_imem_arburst_o,
    output logic                         m_axi_imem_arlock_o,
    output logic [3:0]                   m_axi_imem_arcache_o,
    output logic [2:0]                   m_axi_imem_arprot_o,
    output logic [3:0]                   m_axi_imem_arregion_o,
    output logic [3:0]                   m_axi_imem_arqos_o,
    output logic [AXI_USER_WIDTH-1:0]    m_axi_imem_aruser_o,
    output logic                         m_axi_imem_arvalid_o,
    input  logic                         m_axi_imem_arready_i,

    input  logic [AXI_ID_WIDTH-1:0]      m_axi_imem_rid_i,
    input  logic [AXI_DATA_WIDTH-1:0]    m_axi_imem_rdata_i,
    input  logic [1:0]                   m_axi_imem_rresp_i,
    input  logic                         m_axi_imem_rlast_i,
    input  logic [AXI_USER_WIDTH-1:0]    m_axi_imem_ruser_i,
    input  logic                         m_axi_imem_rvalid_i,
    output logic                         m_axi_imem_rready_o,

    // -------------------------------------------------------------------------
    // DMEM AXI4 master
    // SCR1 -> SmartConnect / NoC
    // -------------------------------------------------------------------------
    output logic [AXI_ID_WIDTH-1:0]      m_axi_dmem_awid_o,
    output logic [AXI_ADDR_WIDTH-1:0]    m_axi_dmem_awaddr_o,
    output logic [7:0]                   m_axi_dmem_awlen_o,
    output logic [2:0]                   m_axi_dmem_awsize_o,
    output logic [1:0]                   m_axi_dmem_awburst_o,
    output logic                         m_axi_dmem_awlock_o,
    output logic [3:0]                   m_axi_dmem_awcache_o,
    output logic [2:0]                   m_axi_dmem_awprot_o,
    output logic [3:0]                   m_axi_dmem_awregion_o,
    output logic [3:0]                   m_axi_dmem_awqos_o,
    output logic [AXI_USER_WIDTH-1:0]    m_axi_dmem_awuser_o,
    output logic                         m_axi_dmem_awvalid_o,
    input  logic                         m_axi_dmem_awready_i,

    output logic [AXI_DATA_WIDTH-1:0]    m_axi_dmem_wdata_o,
    output logic [AXI_DATA_WIDTH/8-1:0]  m_axi_dmem_wstrb_o,
    output logic                         m_axi_dmem_wlast_o,
    output logic [AXI_USER_WIDTH-1:0]    m_axi_dmem_wuser_o,
    output logic                         m_axi_dmem_wvalid_o,
    input  logic                         m_axi_dmem_wready_i,

    input  logic [AXI_ID_WIDTH-1:0]      m_axi_dmem_bid_i,
    input  logic [1:0]                   m_axi_dmem_bresp_i,
    input  logic [AXI_USER_WIDTH-1:0]    m_axi_dmem_buser_i,
    input  logic                         m_axi_dmem_bvalid_i,
    output logic                         m_axi_dmem_bready_o,

    output logic [AXI_ID_WIDTH-1:0]      m_axi_dmem_arid_o,
    output logic [AXI_ADDR_WIDTH-1:0]    m_axi_dmem_araddr_o,
    output logic [7:0]                   m_axi_dmem_arlen_o,
    output logic [2:0]                   m_axi_dmem_arsize_o,
    output logic [1:0]                   m_axi_dmem_arburst_o,
    output logic                         m_axi_dmem_arlock_o,
    output logic [3:0]                   m_axi_dmem_arcache_o,
    output logic [2:0]                   m_axi_dmem_arprot_o,
    output logic [3:0]                   m_axi_dmem_arregion_o,
    output logic [3:0]                   m_axi_dmem_arqos_o,
    output logic [AXI_USER_WIDTH-1:0]    m_axi_dmem_aruser_o,
    output logic                         m_axi_dmem_arvalid_o,
    input  logic                         m_axi_dmem_arready_i,

    input  logic [AXI_ID_WIDTH-1:0]      m_axi_dmem_rid_i,
    input  logic [AXI_DATA_WIDTH-1:0]    m_axi_dmem_rdata_i,
    input  logic [1:0]                   m_axi_dmem_rresp_i,
    input  logic                         m_axi_dmem_rlast_i,
    input  logic [AXI_USER_WIDTH-1:0]    m_axi_dmem_ruser_i,
    input  logic                         m_axi_dmem_rvalid_i,
    output logic                         m_axi_dmem_rready_o,

    // -------------------------------------------------------------------------
    // Boot BRAM write protection interface
    // Guard itself is outside this subsystem in P1.
    // -------------------------------------------------------------------------
    input  logic                         boot_violation_i,
    input  logic [31:0]                  boot_violation_addr_i,

    output logic                         boot_bram_host_write_enable_o,
    output logic                         clear_fault_o,

    // -------------------------------------------------------------------------
    // Platform interrupt / status
    // -------------------------------------------------------------------------
    output logic                         irq_to_a72_o,

    output vd100_scr1_pkg::scr1_lifecycle_state_e lifecycle_state_o,

    // Passive debug exports: no feedback into clocks, resets or lifecycle.
    output wire                          debug_cpu_rst_no,
    output wire [3:0]                    debug_axi_fault_code_o,
    output wire [3*OUTSTANDING_WIDTH-1:0] debug_outstanding_o
);

    logic scr1_cpu_rst_n;
    logic scr1_master_enable;
    logic scr1_quiesce_req;

    // TODO16 lifecycle admission/drain status from the modified scr1_top_axi.
    logic scr1_memory_idle;
    logic scr1_cpu_reset_applied;

    logic [31:0] fw_desc_addr;
    logic [31:0] fw_desc_size;
    logic [31:0] start_token;

    logic [OUTSTANDING_WIDTH-1:0] imem_read_outstanding;
    logic                         imem_quiescent;

    logic [OUTSTANDING_WIDTH-1:0] dmem_read_outstanding;
    logic [OUTSTANDING_WIDTH-1:0] dmem_write_outstanding;
    logic                         dmem_quiescent;

    logic axi_quiescent;

    logic                         imem_fault_valid;
    scr1_fault_code_e             imem_fault_code;
    logic [AXI_ADDR_WIDTH-1:0]    imem_fault_addr;
    logic [AXI_ID_WIDTH-1:0]      imem_fault_id;
    logic [1:0]                   imem_fault_resp;
    logic                         imem_fault_is_write;

    logic                         dmem_fault_valid;
    scr1_fault_code_e             dmem_fault_code;
    logic [AXI_ADDR_WIDTH-1:0]    dmem_fault_addr;
    logic [AXI_ID_WIDTH-1:0]      dmem_fault_id;
    logic [1:0]                   dmem_fault_resp;
    logic                         dmem_fault_is_write;

    logic                         hw_fault_valid;
    scr1_fault_code_e             hw_fault_code;
    logic [31:0]                  hw_fault_info0;
    logic [31:0]                  hw_fault_info1;

    assign debug_cpu_rst_no = scr1_cpu_rst_n;
    assign debug_axi_fault_code_o = hw_fault_code;
    assign debug_outstanding_o = {dmem_write_outstanding,
                                  dmem_read_outstanding, imem_read_outstanding};

        // Instruction Memory Interface
    logic [3:0]                             scr1_axi_imem_awid;
    logic [31:0]                            scr1_axi_imem_awaddr;
    logic [7:0]                             scr1_axi_imem_awlen;
    logic [2:0]                             scr1_axi_imem_awsize;
    logic [1:0]                             scr1_axi_imem_awburst;
    logic                                   scr1_axi_imem_awlock;
    logic [3:0]                             scr1_axi_imem_awcache;
    logic [2:0]                             scr1_axi_imem_awprot;
    logic [3:0]                             scr1_axi_imem_awregion;
    logic [3:0]                             scr1_axi_imem_awuser;
    logic [3:0]                             scr1_axi_imem_awqos;
    logic                                   scr1_axi_imem_awvalid;
    logic                                   scr1_axi_imem_awready;
    logic [31:0]                            scr1_axi_imem_wdata;
    logic [3:0]                             scr1_axi_imem_wstrb;
    logic                                   scr1_axi_imem_wlast;
    logic [3:0]                             scr1_axi_imem_wuser;
    logic                                   scr1_axi_imem_wvalid;
    logic                                   scr1_axi_imem_wready;
    logic [3:0]                             scr1_axi_imem_bid;
    logic [1:0]                             scr1_axi_imem_bresp;
    logic                                   scr1_axi_imem_bvalid;
    logic [3:0]                             scr1_axi_imem_buser;
    logic                                   scr1_axi_imem_bready;
    logic [3:0]                             scr1_axi_imem_arid;
    logic [31:0]                            scr1_axi_imem_araddr;
    logic [7:0]                             scr1_axi_imem_arlen;
    logic [2:0]                             scr1_axi_imem_arsize;
    logic [1:0]                             scr1_axi_imem_arburst;
    logic                                   scr1_axi_imem_arlock;
    logic [3:0]                             scr1_axi_imem_arcache;
    logic [2:0]                             scr1_axi_imem_arprot;
    logic [3:0]                             scr1_axi_imem_arregion;
    logic [3:0]                             scr1_axi_imem_aruser;
    logic [3:0]                             scr1_axi_imem_arqos;
    logic                                   scr1_axi_imem_arvalid;
    logic                                   scr1_axi_imem_arready;
    logic [3:0]                             scr1_axi_imem_rid;
    logic [31:0]                            scr1_axi_imem_rdata;
    logic [1:0]                             scr1_axi_imem_rresp;
    logic                                   scr1_axi_imem_rlast;
    logic [3:0]                             scr1_axi_imem_ruser;
    logic                                   scr1_axi_imem_rvalid;
    logic                                   scr1_axi_imem_rready;

    // Data Memory Interface
    logic [3:0]                             scr1_axi_dmem_awid;
    logic [31:0]                            scr1_axi_dmem_awaddr;
    logic [7:0]                             scr1_axi_dmem_awlen;
    logic [2:0]                             scr1_axi_dmem_awsize;
    logic [1:0]                             scr1_axi_dmem_awburst;
    logic                                   scr1_axi_dmem_awlock;
    logic [3:0]                             scr1_axi_dmem_awcache;
    logic [2:0]                             scr1_axi_dmem_awprot;
    logic [3:0]                             scr1_axi_dmem_awregion;
    logic [3:0]                             scr1_axi_dmem_awuser;
    logic [3:0]                             scr1_axi_dmem_awqos;
    logic                                   scr1_axi_dmem_awvalid;
    logic                                   scr1_axi_dmem_awready;
    logic [31:0]                            scr1_axi_dmem_wdata;
    logic [3:0]                             scr1_axi_dmem_wstrb;
    logic                                   scr1_axi_dmem_wlast;
    logic [3:0]                             scr1_axi_dmem_wuser;
    logic                                   scr1_axi_dmem_wvalid;
    logic                                   scr1_axi_dmem_wready;
    logic [3:0]                             scr1_axi_dmem_bid;
    logic [1:0]                             scr1_axi_dmem_bresp;
    logic                                   scr1_axi_dmem_bvalid;
    logic [3:0]                             scr1_axi_dmem_buser;
    logic                                   scr1_axi_dmem_bready;
    logic [3:0]                             scr1_axi_dmem_arid;
    logic [31:0]                            scr1_axi_dmem_araddr;
    logic [7:0]                             scr1_axi_dmem_arlen;
    logic [2:0]                             scr1_axi_dmem_arsize;
    logic [1:0]                             scr1_axi_dmem_arburst;
    logic                                   scr1_axi_dmem_arlock;
    logic [3:0]                             scr1_axi_dmem_arcache;
    logic [2:0]                             scr1_axi_dmem_arprot;
    logic [3:0]                             scr1_axi_dmem_arregion;
    logic [3:0]                             scr1_axi_dmem_aruser;
    logic [3:0]                             scr1_axi_dmem_arqos;
    logic                                   scr1_axi_dmem_arvalid;
    logic                                   scr1_axi_dmem_arready;
    logic [3:0]                             scr1_axi_dmem_rid;
    logic [31:0]                            scr1_axi_dmem_rdata;
    logic [1:0]                             scr1_axi_dmem_rresp;
    logic                                   scr1_axi_dmem_rlast;
    logic [3:0]                             scr1_axi_dmem_ruser;
    logic                                   scr1_axi_dmem_rvalid;
    logic                                   scr1_axi_dmem_rready;

    scr1_control #(
        .AXIL_ADDR_WIDTH(AXIL_ADDR_WIDTH),
        .AXIL_DATA_WIDTH(AXIL_DATA_WIDTH),
        .OUTSTANDING_WIDTH(OUTSTANDING_WIDTH),
        .VERIFY_REQUIRED(VERIFY_REQUIRED),
        .BOOT_ADDR_VALUE(BOOT_ADDR_VALUE)
    ) u_scr1_control (

    //clk and reset
        .clk(clk),
        .rst_n(rst_n),
    // AXI4-Lite write address channel
        .s_axil_awaddr_i(s_axil_awaddr_i),
        .s_axil_awprot_i(s_axil_awprot_i),
        .s_axil_awvalid_i(s_axil_awvalid_i),
        .s_axil_awready_o(s_axil_awready_o),

    // AXI4-Lite write data channel

        .s_axil_wdata_i(s_axil_wdata_i),
        .s_axil_wstrb_i(s_axil_wstrb_i),
        .s_axil_wvalid_i(s_axil_wvalid_i),
        .s_axil_wready_o(s_axil_wready_o),

    // AXI4-Lite write response channel

        .s_axil_bresp_o(s_axil_bresp_o),
        .s_axil_bvalid_o(s_axil_bvalid_o),
        .s_axil_bready_i(s_axil_bready_i),

    // AXI4-Lite read address channel

        .s_axil_araddr_i(s_axil_araddr_i),
        .s_axil_arprot_i(s_axil_arprot_i),
        .s_axil_arvalid_i(s_axil_arvalid_i),
        .s_axil_arready_o(s_axil_arready_o),

    // AXI4-Lite read data channel

        .s_axil_rdata_o(s_axil_rdata_o),
        .s_axil_rresp_o(s_axil_rresp_o),
        .s_axil_rvalid_o(s_axil_rvalid_o),
        .s_axil_rready_i(s_axil_rready_i),

    // Platform readiness

        .clock_locked_i(clock_locked_i),
        .noc_ready_i(noc_ready_i),
        .ddr_ready_i(ddr_ready_i),
        .verifier_ready_i(verifier_ready_i),

    // SCR1 AXI monitor / drain status

        .imem_outstanding_i(imem_read_outstanding),
        .dmem_read_outstanding_i(dmem_read_outstanding),
        .dmem_write_outstanding_i(dmem_write_outstanding),
        .axi_quiescent_i(axi_quiescent),

    // Hardware fault from AXI monitor

        .hw_fault_valid_i(hw_fault_valid),
        .hw_fault_code_i(hw_fault_code),
        .hw_fault_info0_i(hw_fault_info0),
        .hw_fault_info1_i(hw_fault_info1),

    // Boot BRAM protection violation

        .boot_violation_i(boot_violation_i),
        .boot_violation_addr_i(boot_violation_addr_i),

    // SCR1 lifecycle control

        .scr1_cpu_rst_no(scr1_cpu_rst_n),
        .scr1_master_enable_o(scr1_master_enable),
        .scr1_quiesce_req_o(scr1_quiesce_req),

    // Boot BRAM write policy

        .boot_bram_host_write_enable_o(boot_bram_host_write_enable_o),

    // Clear sticky faults in external monitor / guard

        .clear_fault_o(clear_fault_o),

    // Launch configuration

        .fw_desc_addr_o(fw_desc_addr),
        .fw_desc_size_o(fw_desc_size),
        .start_token_o(start_token),

    // Interrupt / lifecycle observation

        .irq_to_a72_o(irq_to_a72_o),
        .lifecycle_state_o(lifecycle_state_o)
    );

    scr1_top_axi u_scr1_top_axi (
        // Control / reset
        .pwrup_rst_n              (rst_n),
        .rst_n                    (rst_n),
        .cpu_rst_n                (scr1_cpu_rst_n),
        .test_mode                (1'b0),
        .test_rst_n               (1'b1),
        .clk                      (clk),
        .rtc_clk                  (rtc_clk),

        // TODO16: close admission before reset and wait for the complete
        // internal SCR1/cache/AXI drain. AXI VALID signals are not gated here.
        .master_enable_i          (scr1_master_enable),
        .memory_idle_o            (scr1_memory_idle),
        .cpu_reset_applied_o      (scr1_cpu_reset_applied),
`ifdef SCR1_DBG_EN
        .sys_rst_n_o              (),
        .sys_rdc_qlfy_o           (),
`endif // SCR1_DBG_EN

        // Fuses
        .fuse_mhartid             ('0),
`ifdef SCR1_DBG_EN
        .fuse_idcode              (`SCR1_TAP_IDCODE),
`endif // SCR1_DBG_EN

        // IRQ
`ifdef SCR1_IPIC_EN
        .irq_lines                (irq_lines_i),
`else // SCR1_IPIC_EN
        .ext_irq                  (irq_lines_i[0]),
`endif // SCR1_IPIC_EN
        .soft_irq                 (soft_irq_i),

`ifdef SCR1_DBG_EN
        // JTAG is disabled in P1. TAP is kept in reset.
        .trst_n                   (1'b0),
        .tck                      (1'b0),
        .tms                      (1'b0),
        .tdi                      (1'b0),
        .tdo                      (),
        .tdo_en                   (),
`endif // SCR1_DBG_EN

        // Instruction Memory Interface
        .io_axi_imem_awid         (scr1_axi_imem_awid),
        .io_axi_imem_awaddr       (scr1_axi_imem_awaddr),
        .io_axi_imem_awlen        (scr1_axi_imem_awlen),
        .io_axi_imem_awsize       (scr1_axi_imem_awsize),
        .io_axi_imem_awburst      (scr1_axi_imem_awburst),
        .io_axi_imem_awlock       (scr1_axi_imem_awlock),
        .io_axi_imem_awcache      (scr1_axi_imem_awcache),
        .io_axi_imem_awprot       (scr1_axi_imem_awprot),
        .io_axi_imem_awregion     (scr1_axi_imem_awregion),
        .io_axi_imem_awuser       (scr1_axi_imem_awuser),
        .io_axi_imem_awqos        (scr1_axi_imem_awqos),
        .io_axi_imem_awvalid      (scr1_axi_imem_awvalid),
        .io_axi_imem_awready      (scr1_axi_imem_awready),
        .io_axi_imem_wdata        (scr1_axi_imem_wdata),
        .io_axi_imem_wstrb        (scr1_axi_imem_wstrb),
        .io_axi_imem_wlast        (scr1_axi_imem_wlast),
        .io_axi_imem_wuser        (scr1_axi_imem_wuser),
        .io_axi_imem_wvalid       (scr1_axi_imem_wvalid),
        .io_axi_imem_wready       (scr1_axi_imem_wready),
        .io_axi_imem_bid          (scr1_axi_imem_bid),
        .io_axi_imem_bresp        (scr1_axi_imem_bresp),
        .io_axi_imem_bvalid       (scr1_axi_imem_bvalid),
        .io_axi_imem_buser        (scr1_axi_imem_buser),
        .io_axi_imem_bready       (scr1_axi_imem_bready),
        .io_axi_imem_arid         (scr1_axi_imem_arid),
        .io_axi_imem_araddr       (scr1_axi_imem_araddr),
        .io_axi_imem_arlen        (scr1_axi_imem_arlen),
        .io_axi_imem_arsize       (scr1_axi_imem_arsize),
        .io_axi_imem_arburst      (scr1_axi_imem_arburst),
        .io_axi_imem_arlock       (scr1_axi_imem_arlock),
        .io_axi_imem_arcache      (scr1_axi_imem_arcache),
        .io_axi_imem_arprot       (scr1_axi_imem_arprot),
        .io_axi_imem_arregion     (scr1_axi_imem_arregion),
        .io_axi_imem_aruser       (scr1_axi_imem_aruser),
        .io_axi_imem_arqos        (scr1_axi_imem_arqos),
        .io_axi_imem_arvalid      (scr1_axi_imem_arvalid),
        .io_axi_imem_arready      (scr1_axi_imem_arready),
        .io_axi_imem_rid          (scr1_axi_imem_rid),
        .io_axi_imem_rdata        (scr1_axi_imem_rdata),
        .io_axi_imem_rresp        (scr1_axi_imem_rresp),
        .io_axi_imem_rlast        (scr1_axi_imem_rlast),
        .io_axi_imem_ruser        (scr1_axi_imem_ruser),
        .io_axi_imem_rvalid       (scr1_axi_imem_rvalid),
        .io_axi_imem_rready       (scr1_axi_imem_rready),

        // Data Memory Interface
        .io_axi_dmem_awid         (scr1_axi_dmem_awid),
        .io_axi_dmem_awaddr       (scr1_axi_dmem_awaddr),
        .io_axi_dmem_awlen        (scr1_axi_dmem_awlen),
        .io_axi_dmem_awsize       (scr1_axi_dmem_awsize),
        .io_axi_dmem_awburst      (scr1_axi_dmem_awburst),
        .io_axi_dmem_awlock       (scr1_axi_dmem_awlock),
        .io_axi_dmem_awcache      (scr1_axi_dmem_awcache),
        .io_axi_dmem_awprot       (scr1_axi_dmem_awprot),
        .io_axi_dmem_awregion     (scr1_axi_dmem_awregion),
        .io_axi_dmem_awuser       (scr1_axi_dmem_awuser),
        .io_axi_dmem_awqos        (scr1_axi_dmem_awqos),
        .io_axi_dmem_awvalid      (scr1_axi_dmem_awvalid),
        .io_axi_dmem_awready      (scr1_axi_dmem_awready),
        .io_axi_dmem_wdata        (scr1_axi_dmem_wdata),
        .io_axi_dmem_wstrb        (scr1_axi_dmem_wstrb),
        .io_axi_dmem_wlast        (scr1_axi_dmem_wlast),
        .io_axi_dmem_wuser        (scr1_axi_dmem_wuser),
        .io_axi_dmem_wvalid       (scr1_axi_dmem_wvalid),
        .io_axi_dmem_wready       (scr1_axi_dmem_wready),
        .io_axi_dmem_bid          (scr1_axi_dmem_bid),
        .io_axi_dmem_bresp        (scr1_axi_dmem_bresp),
        .io_axi_dmem_bvalid       (scr1_axi_dmem_bvalid),
        .io_axi_dmem_buser        (scr1_axi_dmem_buser),
        .io_axi_dmem_bready       (scr1_axi_dmem_bready),
        .io_axi_dmem_arid         (scr1_axi_dmem_arid),
        .io_axi_dmem_araddr       (scr1_axi_dmem_araddr),
        .io_axi_dmem_arlen        (scr1_axi_dmem_arlen),
        .io_axi_dmem_arsize       (scr1_axi_dmem_arsize),
        .io_axi_dmem_arburst      (scr1_axi_dmem_arburst),
        .io_axi_dmem_arlock       (scr1_axi_dmem_arlock),
        .io_axi_dmem_arcache      (scr1_axi_dmem_arcache),
        .io_axi_dmem_arprot       (scr1_axi_dmem_arprot),
        .io_axi_dmem_arregion     (scr1_axi_dmem_arregion),
        .io_axi_dmem_aruser       (scr1_axi_dmem_aruser),
        .io_axi_dmem_arqos        (scr1_axi_dmem_arqos),
        .io_axi_dmem_arvalid      (scr1_axi_dmem_arvalid),
        .io_axi_dmem_arready      (scr1_axi_dmem_arready),
        .io_axi_dmem_rid          (scr1_axi_dmem_rid),
        .io_axi_dmem_rdata        (scr1_axi_dmem_rdata),
        .io_axi_dmem_rresp        (scr1_axi_dmem_rresp),
        .io_axi_dmem_rlast        (scr1_axi_dmem_rlast),
        .io_axi_dmem_ruser        (scr1_axi_dmem_ruser),
        .io_axi_dmem_rvalid       (scr1_axi_dmem_rvalid),
        .io_axi_dmem_rready       (scr1_axi_dmem_rready)
    );

    scr1_axi_monitor #(
        .AXI_ADDR_WIDTH     (AXI_ADDR_WIDTH),
        .AXI_ID_WIDTH       (AXI_ID_WIDTH),
        .OUTSTANDING_WIDTH  (OUTSTANDING_WIDTH),
        .MAX_OUTSTANDING    (2),
        .MONITOR_WRITES     (1'b0),
        .TIMEOUT_CYCLES     (AXI_TIMEOUT_CYCLES)
    ) u_scr1_imem_monitor (
        // Clock / reset
        .clk_i              (clk),
        .rst_ni             (rst_n),
        .clear_fault_i      (clear_fault_o),

        // Read address channel
        .arid_i             (scr1_axi_imem_arid),
        .araddr_i           (scr1_axi_imem_araddr),
        .arlen_i            (scr1_axi_imem_arlen),
        .arvalid_i          (scr1_axi_imem_arvalid),
        .arready_i          (scr1_axi_imem_arready),

        // Read response channel
        .rid_i              (scr1_axi_imem_rid),
        .rresp_i            (scr1_axi_imem_rresp),
        .rlast_i            (scr1_axi_imem_rlast),
        .rvalid_i           (scr1_axi_imem_rvalid),
        .rready_i           (scr1_axi_imem_rready),

        // Write address channel
        .awid_i             (scr1_axi_imem_awid),
        .awaddr_i           (scr1_axi_imem_awaddr),
        .awlen_i            (scr1_axi_imem_awlen),
        .awvalid_i          (scr1_axi_imem_awvalid),
        .awready_i          (scr1_axi_imem_awready),

        // Write data channel
        .wlast_i            (scr1_axi_imem_wlast),
        .wvalid_i           (scr1_axi_imem_wvalid),
        .wready_i           (scr1_axi_imem_wready),

        // Write response channel
        .bid_i              (scr1_axi_imem_bid),
        .bresp_i            (scr1_axi_imem_bresp),
        .bvalid_i           (scr1_axi_imem_bvalid),
        .bready_i           (scr1_axi_imem_bready),

        // Outstanding / quiescent
        .read_outstanding_o (imem_read_outstanding),
        .write_outstanding_o(),
        .read_high_water_o  (),
        .write_high_water_o (),
        .write_partial_o    (),
        .quiescent_o        (imem_quiescent),

        // Fault
        .fault_valid_o      (imem_fault_valid),
        .fault_code_o       (imem_fault_code),
        .fault_addr_o       (imem_fault_addr),
        .fault_id_o         (imem_fault_id),
        .fault_resp_o       (imem_fault_resp),
        .fault_is_write_o   (imem_fault_is_write)
    );

    scr1_axi_monitor #(
        .AXI_ADDR_WIDTH     (AXI_ADDR_WIDTH),
        .AXI_ID_WIDTH       (AXI_ID_WIDTH),
        .OUTSTANDING_WIDTH  (OUTSTANDING_WIDTH),
        .MAX_OUTSTANDING    (2),
        .MONITOR_WRITES     (1'b1),
        .TIMEOUT_CYCLES     (AXI_TIMEOUT_CYCLES)
    ) u_scr1_dmem_monitor (
        // Clock / reset
        .clk_i              (clk),
        .rst_ni             (rst_n),
        .clear_fault_i      (clear_fault_o),

        // Read address channel
        .arid_i             (scr1_axi_dmem_arid),
        .araddr_i           (scr1_axi_dmem_araddr),
        .arlen_i            (scr1_axi_dmem_arlen),
        .arvalid_i          (scr1_axi_dmem_arvalid),
        .arready_i          (scr1_axi_dmem_arready),

        // Read response channel
        .rid_i              (scr1_axi_dmem_rid),
        .rresp_i            (scr1_axi_dmem_rresp),
        .rlast_i            (scr1_axi_dmem_rlast),
        .rvalid_i           (scr1_axi_dmem_rvalid),
        .rready_i           (scr1_axi_dmem_rready),

        // Write address channel
        .awid_i             (scr1_axi_dmem_awid),
        .awaddr_i           (scr1_axi_dmem_awaddr),
        .awlen_i            (scr1_axi_dmem_awlen),
        .awvalid_i          (scr1_axi_dmem_awvalid),
        .awready_i          (scr1_axi_dmem_awready),

        // Write data channel
        .wlast_i            (scr1_axi_dmem_wlast),
        .wvalid_i           (scr1_axi_dmem_wvalid),
        .wready_i           (scr1_axi_dmem_wready),

        // Write response channel
        .bid_i              (scr1_axi_dmem_bid),
        .bresp_i            (scr1_axi_dmem_bresp),
        .bvalid_i           (scr1_axi_dmem_bvalid),
        .bready_i           (scr1_axi_dmem_bready),

        // Outstanding / quiescent
        .read_outstanding_o (dmem_read_outstanding),
        .write_outstanding_o(dmem_write_outstanding),
        .read_high_water_o  (),
        .write_high_water_o (),
        .write_partial_o    (),
        .quiescent_o        (dmem_quiescent),

        // Fault
        .fault_valid_o      (dmem_fault_valid),
        .fault_code_o       (dmem_fault_code),
        .fault_addr_o       (dmem_fault_addr),
        .fault_id_o         (dmem_fault_id),
        .fault_resp_o       (dmem_fault_resp),
        .fault_is_write_o   (dmem_fault_is_write)
    );

    //AW

    //IMEM
    assign m_axi_imem_awid_o      = scr1_axi_imem_awid;
    assign m_axi_imem_awaddr_o    = scr1_axi_imem_awaddr;
    assign m_axi_imem_awlen_o     = scr1_axi_imem_awlen;
    assign m_axi_imem_awsize_o    = scr1_axi_imem_awsize;
    assign m_axi_imem_awburst_o   = scr1_axi_imem_awburst;
    assign m_axi_imem_awlock_o    = scr1_axi_imem_awlock;
    assign m_axi_imem_awcache_o   = scr1_axi_imem_awcache;
    assign m_axi_imem_awprot_o    = scr1_axi_imem_awprot;
    assign m_axi_imem_awregion_o  = scr1_axi_imem_awregion;
    assign m_axi_imem_awuser_o    = scr1_axi_imem_awuser;
    assign m_axi_imem_awqos_o     = scr1_axi_imem_awqos;
    assign m_axi_imem_awvalid_o   = scr1_axi_imem_awvalid;
    assign scr1_axi_imem_awready  = m_axi_imem_awready_i;

    //DMEM
    assign m_axi_dmem_awid_o      = scr1_axi_dmem_awid;
    assign m_axi_dmem_awaddr_o    = scr1_axi_dmem_awaddr;
    assign m_axi_dmem_awlen_o     = scr1_axi_dmem_awlen;
    assign m_axi_dmem_awsize_o    = scr1_axi_dmem_awsize;
    assign m_axi_dmem_awburst_o   = scr1_axi_dmem_awburst;
    assign m_axi_dmem_awlock_o    = scr1_axi_dmem_awlock;
    assign m_axi_dmem_awcache_o   = scr1_axi_dmem_awcache;
    assign m_axi_dmem_awprot_o    = scr1_axi_dmem_awprot;
    assign m_axi_dmem_awregion_o  = scr1_axi_dmem_awregion;
    assign m_axi_dmem_awuser_o    = scr1_axi_dmem_awuser;
    assign m_axi_dmem_awqos_o     = scr1_axi_dmem_awqos;
    assign m_axi_dmem_awvalid_o   = scr1_axi_dmem_awvalid;
    assign scr1_axi_dmem_awready  = m_axi_dmem_awready_i;

    //W
    
    //IMEM
    assign m_axi_imem_wdata_o   = scr1_axi_imem_wdata;
    assign m_axi_imem_wstrb_o   = scr1_axi_imem_wstrb;
    assign m_axi_imem_wlast_o   = scr1_axi_imem_wlast;
    assign m_axi_imem_wuser_o   = scr1_axi_imem_wuser;
    assign m_axi_imem_wvalid_o  = scr1_axi_imem_wvalid;
    assign scr1_axi_imem_wready = m_axi_imem_wready_i;

    //DMEM
    assign m_axi_dmem_wdata_o   = scr1_axi_dmem_wdata;
    assign m_axi_dmem_wstrb_o   = scr1_axi_dmem_wstrb;
    assign m_axi_dmem_wlast_o   = scr1_axi_dmem_wlast;
    assign m_axi_dmem_wuser_o   = scr1_axi_dmem_wuser;
    assign m_axi_dmem_wvalid_o  = scr1_axi_dmem_wvalid;
    assign scr1_axi_dmem_wready = m_axi_dmem_wready_i;

    //B

    //IMEM
    assign scr1_axi_imem_bid    = m_axi_imem_bid_i;
    assign scr1_axi_imem_bresp  = m_axi_imem_bresp_i;
    assign scr1_axi_imem_buser  = m_axi_imem_buser_i;
    assign scr1_axi_imem_bvalid = m_axi_imem_bvalid_i ;
    assign m_axi_imem_bready_o  = scr1_axi_imem_bready;

    //DMEM
    assign scr1_axi_dmem_bid    = m_axi_dmem_bid_i;
    assign scr1_axi_dmem_bresp  = m_axi_dmem_bresp_i;
    assign scr1_axi_dmem_buser  = m_axi_dmem_buser_i;
    assign scr1_axi_dmem_bvalid = m_axi_dmem_bvalid_i ;
    assign m_axi_dmem_bready_o  = scr1_axi_dmem_bready;

    //AR

    //IMEM
    assign m_axi_imem_arid_o     = scr1_axi_imem_arid;
    assign m_axi_imem_araddr_o   = scr1_axi_imem_araddr;
    assign m_axi_imem_arlen_o    = scr1_axi_imem_arlen;
    assign m_axi_imem_arsize_o   = scr1_axi_imem_arsize;
    assign m_axi_imem_arburst_o  = scr1_axi_imem_arburst;
    assign m_axi_imem_arlock_o   = scr1_axi_imem_arlock;
    assign m_axi_imem_arcache_o  = scr1_axi_imem_arcache;
    assign m_axi_imem_arprot_o   = scr1_axi_imem_arprot;
    assign m_axi_imem_arregion_o = scr1_axi_imem_arregion;
    assign m_axi_imem_arqos_o    = scr1_axi_imem_arqos;
    assign m_axi_imem_aruser_o   = scr1_axi_imem_aruser;
    assign m_axi_imem_arvalid_o  = scr1_axi_imem_arvalid;
    assign scr1_axi_imem_arready = m_axi_imem_arready_i;

    //DMEM
    assign m_axi_dmem_arid_o     = scr1_axi_dmem_arid;
    assign m_axi_dmem_araddr_o   = scr1_axi_dmem_araddr;
    assign m_axi_dmem_arlen_o    = scr1_axi_dmem_arlen;
    assign m_axi_dmem_arsize_o   = scr1_axi_dmem_arsize;
    assign m_axi_dmem_arburst_o  = scr1_axi_dmem_arburst;
    assign m_axi_dmem_arlock_o   = scr1_axi_dmem_arlock;
    assign m_axi_dmem_arcache_o  = scr1_axi_dmem_arcache;
    assign m_axi_dmem_arprot_o   = scr1_axi_dmem_arprot;
    assign m_axi_dmem_arregion_o = scr1_axi_dmem_arregion;
    assign m_axi_dmem_arqos_o    = scr1_axi_dmem_arqos;
    assign m_axi_dmem_aruser_o   = scr1_axi_dmem_aruser;
    assign m_axi_dmem_arvalid_o  = scr1_axi_dmem_arvalid;
    assign scr1_axi_dmem_arready = m_axi_dmem_arready_i;
    //R

    //IMEM
    assign scr1_axi_imem_rid    = m_axi_imem_rid_i;
    assign scr1_axi_imem_rdata  = m_axi_imem_rdata_i;
    assign scr1_axi_imem_rresp  = m_axi_imem_rresp_i;
    assign scr1_axi_imem_rlast  = m_axi_imem_rlast_i;
    assign scr1_axi_imem_ruser  = m_axi_imem_ruser_i;
    assign scr1_axi_imem_rvalid = m_axi_imem_rvalid_i;
    assign m_axi_imem_rready_o  = scr1_axi_imem_rready;

    //DMEM
    assign scr1_axi_dmem_rid    = m_axi_dmem_rid_i;
    assign scr1_axi_dmem_rdata  = m_axi_dmem_rdata_i;
    assign scr1_axi_dmem_rresp  = m_axi_dmem_rresp_i;
    assign scr1_axi_dmem_rlast  = m_axi_dmem_rlast_i;
    assign scr1_axi_dmem_ruser  = m_axi_dmem_ruser_i;
    assign scr1_axi_dmem_rvalid = m_axi_dmem_rvalid_i;
    assign m_axi_dmem_rready_o  = scr1_axi_dmem_rready;

    // External monitors catch accepted AXI work/partial writes; scr1_memory_idle
    // additionally covers native CPU requests, cache state and the D-cache
    // write buffer. All must agree before lifecycle FSM may leave QUIESCING.
    assign axi_quiescent =
        scr1_memory_idle && imem_quiescent && dmem_quiescent;

    // Deterministic first-fault aggregation across the two sticky AXI monitors.
    // Simultaneous first faults use IMEM priority. Once captured, the selected
    // source/context stays stable until the legal clear_fault pulse.
    always_ff @(posedge clk) begin
        if (!rst_n) begin
            hw_fault_valid <= 1'b0;
            hw_fault_code  <= SCR1_FAULT_NONE;
            hw_fault_info0 <= '0;
            hw_fault_info1 <= '0;
        end
        else if (clear_fault_o) begin
            hw_fault_valid <= 1'b0;
            hw_fault_code  <= SCR1_FAULT_NONE;
            hw_fault_info0 <= '0;
            hw_fault_info1 <= '0;
        end
        else if (!hw_fault_valid) begin
            if (imem_fault_valid) begin
                hw_fault_valid <= 1'b1;
                hw_fault_code  <= imem_fault_code;
                hw_fault_info0 <= imem_fault_addr;
                hw_fault_info1 <= {
                    24'd0,
                    1'b0,                  // bit 7: 0 = IMEM
                    imem_fault_is_write,    // bit 6
                    imem_fault_resp,        // bits 5:4
                    imem_fault_id[3:0]      // bits 3:0
                };
            end
            else if (dmem_fault_valid) begin
                hw_fault_valid <= 1'b1;
                hw_fault_code  <= dmem_fault_code;
                hw_fault_info0 <= dmem_fault_addr;
                hw_fault_info1 <= {
                    24'd0,
                    1'b1,                  // bit 7: 1 = DMEM
                    dmem_fault_is_write,    // bit 6
                    dmem_fault_resp,        // bits 5:4
                    dmem_fault_id[3:0]      // bits 3:0
                };
            end
        end
    end

`ifndef SYNTHESIS
    initial begin
        if (BOOT_ADDR_VALUE != SCR1_ARCH_RST_VECTOR)
            $fatal(1, "VD100 boot vector mismatch between control ABI and SCR1 architecture");

        // Current scr1_top_axi physical AXI contract is fixed to these widths.
        if (AXI_ADDR_WIDTH != 32)
            $fatal(1, "scr1_subsystem: AXI_ADDR_WIDTH must be 32 for current SCR1");
        if (AXI_DATA_WIDTH != 32)
            $fatal(1, "scr1_subsystem: AXI_DATA_WIDTH must be 32 for current SCR1");
        if (AXI_ID_WIDTH != 4)
            $fatal(1, "scr1_subsystem: AXI_ID_WIDTH must be 4 for current SCR1");
        if (AXI_USER_WIDTH != 4)
            $fatal(1, "scr1_subsystem: AXI_USER_WIDTH must be 4 for current SCR1");
    end
`endif

endmodule : scr1_subsystem
