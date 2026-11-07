// AXI4-Lite slave front-end, shared by every slave in the SoC (ROM, RAM, MAC, UART).
// Converts AXI handshakes into one-cycle register-bus strobes so each slave only
// implements its register/memory behaviour.
//
// Write: AW and W are accepted independently (AW first, W first, or together) into
//   one-entry holding registers. The write is performed exactly once (wr_en for one
//   cycle) when both are present and the B channel is free, then B is returned.
//   A VALID held high while the slave is busy can therefore never cause a second write.
// Read:  one read outstanding. rd_en is issued when the register side is ready
//   (rd_wait = 0); read data is registered, like a synchronous SRAM output.
// The register side flags wr_err / rd_err to answer with SLVERR.
module axil_slave #(
    parameter int AW = 12                // local address width (byte address)
) (
    input  logic          clk,
    input  logic          rst_n,
    // AXI4-Lite slave port
    input  logic          s_awvalid,
    output logic          s_awready,
    input  logic [AW-1:0] s_awaddr,
    input  logic          s_wvalid,
    output logic          s_wready,
    input  logic [31:0]   s_wdata,
    input  logic [3:0]    s_wstrb,
    output logic          s_bvalid,
    input  logic          s_bready,
    output logic [1:0]    s_bresp,
    input  logic          s_arvalid,
    output logic          s_arready,
    input  logic [AW-1:0] s_araddr,
    output logic          s_rvalid,
    input  logic          s_rready,
    output logic [31:0]   s_rdata,
    output logic [1:0]    s_rresp,
    // register side
    output logic          wr_en,         // one cycle per AXI write transaction
    output logic [AW-1:0] wr_addr,
    output logic [31:0]   wr_data,
    output logic [3:0]    wr_strb,
    input  logic          wr_wait,       // insert write wait states
    input  logic          wr_err,        // sampled with wr_en: respond SLVERR
    output logic          rd_en,         // one cycle per AXI read transaction
    output logic [AW-1:0] rd_addr,
    input  logic [31:0]   rd_data,       // combinational from rd_addr, captured on rd_en
    input  logic          rd_wait,       // insert read wait states
    input  logic          rd_err         // sampled with rd_en: respond SLVERR
);
  localparam logic [1:0] OKAY = 2'b00, SLVERR = 2'b10;

  // ---------------- write path ----------------
  logic          aw_full, w_full;
  logic [AW-1:0] aw_q;
  logic [31:0]   w_q;
  logic [3:0]    ws_q;

  assign s_awready = !aw_full;
  assign s_wready  = !w_full;
  assign wr_addr   = aw_full ? aw_q : s_awaddr;
  assign wr_data   = w_full  ? w_q  : s_wdata;
  assign wr_strb   = w_full  ? ws_q : s_wstrb;
  assign wr_en     = (aw_full || s_awvalid) && (w_full || s_wvalid) && !s_bvalid && !wr_wait;

  always_ff @(posedge clk) begin
    if (!rst_n) begin
      aw_full  <= 1'b0;
      w_full   <= 1'b0;
      s_bvalid <= 1'b0;
      s_bresp  <= OKAY;
    end else if (wr_en) begin
      // address and data consumed (from the holding registers or directly)
      aw_full  <= 1'b0;
      w_full   <= 1'b0;
      s_bvalid <= 1'b1;
      s_bresp  <= wr_err ? SLVERR : OKAY;
    end else begin
      if (s_awvalid && !aw_full) begin aw_full <= 1'b1; aw_q <= s_awaddr; end
      if (s_wvalid  && !w_full)  begin w_full  <= 1'b1; w_q <= s_wdata; ws_q <= s_wstrb; end
      if (s_bvalid  && s_bready) s_bvalid <= 1'b0;
    end
  end

  // ---------------- read path ----------------
  logic          ar_pend;     // address accepted, data not yet produced (wait state)
  logic [AW-1:0] ar_q;

  assign s_arready = !ar_pend && !s_rvalid;
  assign rd_addr   = ar_pend ? ar_q : s_araddr;
  assign rd_en     = (ar_pend || (s_arvalid && s_arready)) && !rd_wait;

  always_ff @(posedge clk) begin
    if (!rst_n) begin
      ar_pend  <= 1'b0;
      s_rvalid <= 1'b0;
      s_rresp  <= OKAY;
    end else begin
      if (rd_en) begin
        ar_pend  <= 1'b0;
        s_rvalid <= 1'b1;
        s_rdata  <= rd_data;
        s_rresp  <= rd_err ? SLVERR : OKAY;
      end else if (s_arvalid && s_arready) begin
        ar_pend  <= 1'b1;
        ar_q     <= s_araddr;
      end
      if (s_rvalid && s_rready) s_rvalid <= 1'b0;   // rd_en cannot coincide with rvalid
    end
  end
endmodule
