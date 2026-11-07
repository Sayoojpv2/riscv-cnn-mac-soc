// RISC-V SoC: PicoRV32 (RV32IM, AXI4-Lite master) + boot ROM + RAM + CNN MAC + UART.
//
//   0x0000_0000  boot ROM   16 KiB  (firmware image, read-only)
//   0x1000_0000  RAM        16 KiB  (.data, .bss, stack)
//   0x2000_0000  MAC        4 KiB   (CNN MAC accelerator registers)
//   0x3000_0000  UART       4 KiB
//   anything else: DECERR
module soc_top #(
    parameter bit FAST_MUL          = 1,   // 1: single-cycle-issue multiplier, 0: iterative
    parameter bit MEM_WAIT          = 0,   // 1: pseudo-random wait states in ROM and RAM
    parameter int UART_CLKS_PER_BIT = 16
) (
    input  logic clk,
    input  logic rst_n,
    output logic uart_tx,
    output logic trap
);
  localparam int N = 4;  // 0 ROM, 1 RAM, 2 MAC, 3 UART
  localparam logic [32*N-1:0] BASE = {32'h3000_0000, 32'h2000_0000, 32'h1000_0000, 32'h0000_0000};
  localparam logic [32*N-1:0] MASK = {32'hFFFF_F000, 32'hFFFF_F000, 32'hFFFF_C000, 32'hFFFF_C000};

  // CPU-side AXI4-Lite
  logic        m_awvalid, m_awready, m_wvalid, m_wready, m_bvalid, m_bready;
  logic        m_arvalid, m_arready, m_rvalid, m_rready;
  logic [31:0] m_awaddr, m_wdata, m_araddr, m_rdata;
  logic [3:0]  m_wstrb;
  logic [2:0]  m_awprot, m_arprot;
  logic [1:0]  m_bresp, m_rresp;   // PicoRV32's AXI adapter has no BRESP/RRESP inputs

  // slave-side AXI4-Lite (payloads broadcast)
  logic [N-1:0]    s_awvalid, s_awready, s_wvalid, s_wready, s_bvalid, s_bready;
  logic [N-1:0]    s_arvalid, s_arready, s_rvalid, s_rready;
  logic [31:0]     s_awaddr, s_wdata, s_araddr;
  logic [3:0]      s_wstrb;
  logic [2*N-1:0]  s_bresp, s_rresp;
  logic [32*N-1:0] s_rdata;

  picorv32_axi #(
      .ENABLE_COUNTERS  (1),            // rdcycle / rdinstret
      .ENABLE_COUNTERS64(1),
      .BARREL_SHIFTER   (1),
      .COMPRESSED_ISA   (0),            // RV32IM, no C
      .CATCH_MISALIGN   (1),
      .CATCH_ILLINSN    (1),
      .ENABLE_MUL       (!FAST_MUL),
      .ENABLE_FAST_MUL  (FAST_MUL),
      .ENABLE_DIV       (1),
      .ENABLE_IRQ       (0),
      .PROGADDR_RESET   (32'h0000_0000)
  ) cpu (
      .clk, .resetn(rst_n), .trap,
      .mem_axi_awvalid(m_awvalid), .mem_axi_awready(m_awready), .mem_axi_awaddr(m_awaddr), .mem_axi_awprot(m_awprot),
      .mem_axi_wvalid (m_wvalid),  .mem_axi_wready (m_wready),  .mem_axi_wdata (m_wdata),  .mem_axi_wstrb (m_wstrb),
      .mem_axi_bvalid (m_bvalid),  .mem_axi_bready (m_bready),
      .mem_axi_arvalid(m_arvalid), .mem_axi_arready(m_arready), .mem_axi_araddr(m_araddr), .mem_axi_arprot(m_arprot),
      .mem_axi_rvalid (m_rvalid),  .mem_axi_rready (m_rready),  .mem_axi_rdata (m_rdata),
      .pcpi_valid(), .pcpi_insn(), .pcpi_rs1(), .pcpi_rs2(),
      .pcpi_wr(1'b0), .pcpi_rd(32'd0), .pcpi_wait(1'b0), .pcpi_ready(1'b0),
      .irq(32'd0), .eoi(),
      .trace_valid(), .trace_data()
  );

  axil_decoder #(.N(N), .BASE(BASE), .MASK(MASK)) u_dec (
      .clk, .rst_n,
      .m_awvalid, .m_awready, .m_awaddr, .m_wvalid, .m_wready, .m_wdata, .m_wstrb,
      .m_bvalid, .m_bready, .m_bresp, .m_arvalid, .m_arready, .m_araddr,
      .m_rvalid, .m_rready, .m_rdata, .m_rresp,
      .s_awvalid, .s_awready, .s_awaddr, .s_wvalid, .s_wready, .s_wdata, .s_wstrb,
      .s_bvalid, .s_bready, .s_bresp, .s_arvalid, .s_arready, .s_araddr,
      .s_rvalid, .s_rready, .s_rdata, .s_rresp
  );

  axil_mem #(.WORDS(4096), .WRITABLE(0), .WAIT_STATES(MEM_WAIT)) u_rom (
      .clk, .rst_n,
      .s_awvalid(s_awvalid[0]), .s_awready(s_awready[0]), .s_awaddr,
      .s_wvalid (s_wvalid[0]),  .s_wready (s_wready[0]),  .s_wdata, .s_wstrb,
      .s_bvalid (s_bvalid[0]),  .s_bready (s_bready[0]),  .s_bresp(s_bresp[1:0]),
      .s_arvalid(s_arvalid[0]), .s_arready(s_arready[0]), .s_araddr,
      .s_rvalid (s_rvalid[0]),  .s_rready (s_rready[0]),  .s_rdata(s_rdata[31:0]), .s_rresp(s_rresp[1:0])
  );

  axil_mem #(.WORDS(4096), .WRITABLE(1), .WAIT_STATES(MEM_WAIT)) u_ram (
      .clk, .rst_n,
      .s_awvalid(s_awvalid[1]), .s_awready(s_awready[1]), .s_awaddr,
      .s_wvalid (s_wvalid[1]),  .s_wready (s_wready[1]),  .s_wdata, .s_wstrb,
      .s_bvalid (s_bvalid[1]),  .s_bready (s_bready[1]),  .s_bresp(s_bresp[3:2]),
      .s_arvalid(s_arvalid[1]), .s_arready(s_arready[1]), .s_araddr,
      .s_rvalid (s_rvalid[1]),  .s_rready (s_rready[1]),  .s_rdata(s_rdata[63:32]), .s_rresp(s_rresp[3:2])
  );

  mac_axil u_mac (
      .clk, .rst_n,
      .s_awvalid(s_awvalid[2]), .s_awready(s_awready[2]), .s_awaddr,
      .s_wvalid (s_wvalid[2]),  .s_wready (s_wready[2]),  .s_wdata, .s_wstrb,
      .s_bvalid (s_bvalid[2]),  .s_bready (s_bready[2]),  .s_bresp(s_bresp[5:4]),
      .s_arvalid(s_arvalid[2]), .s_arready(s_arready[2]), .s_araddr,
      .s_rvalid (s_rvalid[2]),  .s_rready (s_rready[2]),  .s_rdata(s_rdata[95:64]), .s_rresp(s_rresp[5:4])
  );

  uart_axil #(.CLKS_PER_BIT(UART_CLKS_PER_BIT)) u_uart (
      .clk, .rst_n,
      .s_awvalid(s_awvalid[3]), .s_awready(s_awready[3]), .s_awaddr,
      .s_wvalid (s_wvalid[3]),  .s_wready (s_wready[3]),  .s_wdata, .s_wstrb,
      .s_bvalid (s_bvalid[3]),  .s_bready (s_bready[3]),  .s_bresp(s_bresp[7:6]),
      .s_arvalid(s_arvalid[3]), .s_arready(s_arready[3]), .s_araddr,
      .s_rvalid (s_rvalid[3]),  .s_rready (s_rready[3]),  .s_rdata(s_rdata[127:96]), .s_rresp(s_rresp[7:6]),
      .tx(uart_tx)
  );
endmodule
