// On-chip memory behind AXI4-Lite: used for both the boot ROM (WRITABLE=0) and the
// data RAM (WRITABLE=1). Synchronous read (registered in axil_slave), byte-strobe writes.
// Writes to a ROM are answered with SLVERR and do not change it.
// WAIT_STATES=1 inserts pseudo-random wait states (8-bit LFSR, ~25% of cycles) on reads
// and writes, modelling a slow memory; it is used to test bus backpressure end to end.
module axil_mem #(
    parameter int WORDS       = 4096,
    parameter bit WRITABLE    = 1,
    parameter bit WAIT_STATES = 0
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
    output logic [1:0]  s_rresp
);
  localparam int AW = $clog2(WORDS) + 2;

  logic [31:0]   mem [0:WORDS-1];
  logic          wr_en, rd_en, stall;
  logic [AW-1:0] wr_addr, rd_addr;
  logic [31:0]   wr_data;
  logic [3:0]    wr_strb;

  axil_slave #(.AW(AW)) u_if (
      .clk, .rst_n,
      .s_awvalid, .s_awready, .s_awaddr(s_awaddr[AW-1:0]),
      .s_wvalid, .s_wready, .s_wdata, .s_wstrb,
      .s_bvalid, .s_bready, .s_bresp,
      .s_arvalid, .s_arready, .s_araddr(s_araddr[AW-1:0]),
      .s_rvalid, .s_rready, .s_rdata, .s_rresp,
      .wr_en, .wr_addr, .wr_data, .wr_strb, .wr_wait(stall), .wr_err(!WRITABLE),
      .rd_en, .rd_addr, .rd_data(mem[rd_addr[AW-1:2]]), .rd_wait(stall), .rd_err(1'b0)
  );

  always_ff @(posedge clk)
    if (WRITABLE && wr_en)
      for (int b = 0; b < 4; b++)
        if (wr_strb[b]) mem[wr_addr[AW-1:2]][8*b +: 8] <= wr_data[8*b +: 8];

  if (WAIT_STATES) begin : g_wait
    logic [7:0] lfsr;
    always_ff @(posedge clk)
      if (!rst_n) lfsr <= 8'hA5;
      else        lfsr <= {lfsr[6:0], lfsr[7] ^ lfsr[5] ^ lfsr[4] ^ lfsr[3]};
    assign stall = lfsr[0] & lfsr[1];
  end else begin : g_nowait
    assign stall = 1'b0;
  end
endmodule
