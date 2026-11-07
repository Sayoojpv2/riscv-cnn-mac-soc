// Passive AXI4-Lite protocol checker (simulation only).
// - VALID, once asserted, stays asserted with a stable payload until READY.
// - No B/R response without an accepted request (counts AW, W, AR vs B, R).
// - No X/Z on control signals after reset; no X on OKAY read data.
module axil_checker #(
    parameter NAME = "axil",
    parameter ID   = 0
) (
    input logic        clk,
    input logic        rst_n,
    input logic        awvalid, awready,
    input logic [31:0] awaddr,
    input logic        wvalid, wready,
    input logic [31:0] wdata,
    input logic [3:0]  wstrb,
    input logic        bvalid, bready,
    input logic [1:0]  bresp,
    input logic        arvalid, arready,
    input logic [31:0] araddr,
    input logic        rvalid, rready,
    input logic [31:0] rdata,
    input logic [1:0]  rresp
);
  int errors = 0;
  int n_aw = 0, n_w = 0, n_b = 0, n_ar = 0, n_r = 0;
  logic        h_aw = 0, h_w = 0, h_b = 0, h_ar = 0, h_r = 0;   // VALID waiting for READY
  logic [31:0] q_awaddr, q_wdata, q_araddr, q_rdata;
  logic [3:0]  q_wstrb;
  logic [1:0]  q_bresp, q_rresp;

  task automatic fail(input string msg);
    errors++;
    if (errors <= 20) $display("[%0t] AXI CHECK %s%0d: %s", $time, NAME, ID, msg);
  endtask

  always @(posedge clk) begin
    if (!rst_n) begin
      {h_aw, h_w, h_b, h_ar, h_r} <= '0;
    end else begin
      if (^{awvalid, awready, wvalid, wready, bvalid, bready, arvalid, arready, rvalid, rready} === 1'bx)
        fail("X/Z on a VALID/READY signal");
      if (h_aw && (!awvalid || awaddr !== q_awaddr)) fail("AW dropped or changed before AWREADY");
      if (h_w  && (!wvalid || wdata !== q_wdata || wstrb !== q_wstrb)) fail("W dropped or changed before WREADY");
      if (h_b  && (!bvalid || bresp !== q_bresp)) fail("B dropped or changed before BREADY");
      if (h_ar && (!arvalid || araddr !== q_araddr)) fail("AR dropped or changed before ARREADY");
      if (h_r  && (!rvalid || rdata !== q_rdata || rresp !== q_rresp)) fail("R dropped or changed before RREADY");
      // a response may only follow completed request handshakes (earlier cycles)
      if (bvalid && bready && (n_b >= n_aw || n_b >= n_w)) fail("B response without AW and W");
      if (rvalid && rready && n_r >= n_ar) fail("R response without AR");
      if (rvalid && rready && rresp == 2'b00 && ^rdata === 1'bx) fail("X in OKAY read data");

      h_aw <= awvalid && !awready;  q_awaddr <= awaddr;
      h_w  <= wvalid  && !wready;   q_wdata  <= wdata;  q_wstrb <= wstrb;
      h_b  <= bvalid  && !bready;   q_bresp  <= bresp;
      h_ar <= arvalid && !arready;  q_araddr <= araddr;
      h_r  <= rvalid  && !rready;   q_rdata  <= rdata;  q_rresp <= rresp;

      n_aw <= n_aw + (awvalid && awready);
      n_w  <= n_w  + (wvalid  && wready);
      n_b  <= n_b  + (bvalid  && bready);
      n_ar <= n_ar + (arvalid && arready);
      n_r  <= n_r  + (rvalid  && rready);
    end
  end
endmodule
