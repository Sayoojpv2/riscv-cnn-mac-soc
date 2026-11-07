// Transmit-only UART (8N1) behind AXI4-Lite.
//   0x00 TXDATA  W  [7:0] byte to send. While the shifter is busy the write is held
//                   with bus wait states, so no character is ever lost.
//   0x04 STATUS  R  bit0 TX_BUSY
//   0x08 SCRATCH RW  general-purpose scratch register (like the 16550 SCR); the
//                   firmware uses it for test markers and its exit code
// Other offsets / wrong direction: SLVERR.
module uart_axil #(
    parameter int CLKS_PER_BIT = 16
) (
    input  logic        clk,
    input  logic        rst_n,
    input  logic        s_awvalid,
    output logic        s_awready,
    input  logic [31:0] s_awaddr,
    input  logic        s_wvalid,
    output logic        s_wready,
    input  logic [31:0] s_wdata,
    input  logic [3:0]  s_wstrb,
    output logic        s_bvalid,
    input  logic        s_bready,
    output logic [1:0]  s_bresp,
    input  logic        s_arvalid,
    output logic        s_arready,
    input  logic [31:0] s_araddr,
    output logic        s_rvalid,
    input  logic        s_rready,
    output logic [31:0] s_rdata,
    output logic [1:0]  s_rresp,
    output logic        tx
);
  localparam logic [11:0] TXDATA = 12'h000, STATUS = 12'h004, SCRATCH = 12'h008;

  logic        wr_en, rd_en;
  logic [11:0] wr_addr, rd_addr;
  logic [31:0] wr_data, scratch;
  logic [3:0]  wr_strb;
  logic        busy;

  axil_slave #(.AW(12)) u_if (
      .clk, .rst_n,
      .s_awvalid, .s_awready, .s_awaddr(s_awaddr[11:0]),
      .s_wvalid, .s_wready, .s_wdata, .s_wstrb,
      .s_bvalid, .s_bready, .s_bresp,
      .s_arvalid, .s_arready, .s_araddr(s_araddr[11:0]),
      .s_rvalid, .s_rready, .s_rdata, .s_rresp,
      .wr_en, .wr_addr, .wr_data, .wr_strb,
      .wr_wait(busy && wr_addr == TXDATA),
      .wr_err(wr_addr != TXDATA && wr_addr != SCRATCH),
      .rd_en, .rd_addr,
      .rd_data(rd_addr == STATUS ? {31'd0, busy} : rd_addr == SCRATCH ? scratch : 32'd0),
      .rd_wait(1'b0),
      .rd_err(rd_addr != STATUS && rd_addr != SCRATCH)
  );

  always_ff @(posedge clk)
    if (!rst_n) scratch <= '0;
    else if (wr_en && wr_addr == SCRATCH)
      for (int b = 0; b < 4; b++)
        if (wr_strb[b]) scratch[8*b +: 8] <= wr_data[8*b +: 8];

  // 8N1 shifter: {stop, data[7:0], start}, LSB first, CLKS_PER_BIT cycles per bit.
  logic [9:0] shreg;
  logic [3:0] nbits;
  logic [$clog2(CLKS_PER_BIT)-1:0] baud;
  assign busy = nbits != 4'd0;
  assign tx   = shreg[0];

  always_ff @(posedge clk) begin
    if (!rst_n) begin
      shreg <= '1;
      nbits <= '0;
      baud  <= '0;
    end else if (wr_en && wr_addr == TXDATA) begin
      shreg <= {1'b1, wr_data[7:0], 1'b0};
      nbits <= 4'd10;
      baud  <= CLKS_PER_BIT - 1;
    end else if (busy) begin
      if (baud == 0) begin
        shreg <= {1'b1, shreg[9:1]};
        nbits <= nbits - 4'd1;
        baud  <= CLKS_PER_BIT - 1;
      end else begin
        baud <= baud - 1'b1;
      end
    end
  end
endmodule
