// AXI4-Lite 1-master to N-slave address decoder.
// Slave i is selected when (addr & MASK[i]) == BASE[i]. Payloads (address, write
// data, strobes) are broadcast; only VALID/READY and responses are routed.
// One write and one read may be in flight at the same time (independent channels);
// each channel accepts a new address only after the previous response completed.
// W is routed to the slave named by the pending (or accepted) AW, so W may arrive
// before, with, or after AW. Unmapped addresses are completed by the decoder itself
// with DECERR (read data 0). AWREADY/ARREADY are only driven high together with VALID
// (AXI allows this), so they are defined even while the address is still unknown.
module axil_decoder #(
    parameter int              N    = 4,
    parameter logic [32*N-1:0] BASE = '0,
    parameter logic [32*N-1:0] MASK = '0
) (
    input  logic            clk,
    input  logic            rst_n,
    // master side (CPU)
    input  logic            m_awvalid,
    output logic            m_awready,
    input  logic [31:0]     m_awaddr,
    input  logic            m_wvalid,
    output logic            m_wready,
    input  logic [31:0]     m_wdata,
    input  logic [3:0]      m_wstrb,
    output logic            m_bvalid,
    input  logic            m_bready,
    output logic [1:0]      m_bresp,
    input  logic            m_arvalid,
    output logic            m_arready,
    input  logic [31:0]     m_araddr,
    output logic            m_rvalid,
    input  logic            m_rready,
    output logic [31:0]     m_rdata,
    output logic [1:0]      m_rresp,
    // slave side
    output logic [N-1:0]    s_awvalid,
    input  logic [N-1:0]    s_awready,
    output logic [31:0]     s_awaddr,
    output logic [N-1:0]    s_wvalid,
    input  logic [N-1:0]    s_wready,
    output logic [31:0]     s_wdata,
    output logic [3:0]      s_wstrb,
    input  logic [N-1:0]    s_bvalid,
    output logic [N-1:0]    s_bready,
    input  logic [2*N-1:0]  s_bresp,
    output logic [N-1:0]    s_arvalid,
    input  logic [N-1:0]    s_arready,
    output logic [31:0]     s_araddr,
    input  logic [N-1:0]    s_rvalid,
    output logic [N-1:0]    s_rready,
    input  logic [32*N-1:0] s_rdata,
    input  logic [2*N-1:0]  s_rresp
);
  localparam logic [1:0] DECERR = 2'b11;

  logic [N-1:0] aw_hit, ar_hit;          // one-hot decode, all-zero = unmapped
  for (genvar i = 0; i < N; i++) begin : g_dec
    assign aw_hit[i] = (m_awaddr & MASK[32*i +: 32]) == BASE[32*i +: 32];
    assign ar_hit[i] = (m_araddr & MASK[32*i +: 32]) == BASE[32*i +: 32];
  end

  assign s_awaddr = m_awaddr;
  assign s_wdata  = m_wdata;
  assign s_wstrb  = m_wstrb;
  assign s_araddr = m_araddr;

  // ---------------- write channel ----------------
  logic         wr_act;                  // AW accepted, waiting for B
  logic         w_done;                  // W accepted
  logic [N-1:0] wr_sel;                  // target of the accepted AW

  wire [N-1:0] w_tgt = wr_act ? wr_sel : aw_hit;
  wire         w_ok  = !w_done && (wr_act || m_awvalid);
  wire         wr_de = wr_act && (wr_sel == '0);

  assign s_awvalid = (m_awvalid && !wr_act) ? aw_hit : '0;
  assign m_awready = m_awvalid && !wr_act && ((aw_hit == '0) || |(aw_hit & s_awready));
  assign s_wvalid  = (m_wvalid && w_ok) ? w_tgt : '0;
  assign m_wready  = w_ok && ((w_tgt == '0) || |(w_tgt & s_wready));
  assign s_bready  = (wr_act && m_bready) ? wr_sel : '0;
  assign m_bvalid  = wr_act && (wr_de ? w_done : |(wr_sel & s_bvalid));

  always_comb begin
    m_bresp = DECERR;
    for (int i = 0; i < N; i++) if (wr_sel[i]) m_bresp = s_bresp[2*i +: 2];
  end

  always_ff @(posedge clk) begin
    if (!rst_n) begin
      wr_act <= 1'b0;
      w_done <= 1'b0;
      wr_sel <= '0;
    end else begin
      if (m_awvalid && m_awready) begin wr_act <= 1'b1; wr_sel <= aw_hit; end
      if (m_wvalid && m_wready) w_done <= 1'b1;
      if (m_bvalid && m_bready) begin wr_act <= 1'b0; w_done <= 1'b0; end
    end
  end

  // ---------------- read channel ----------------
  logic         rd_act;
  logic [N-1:0] rd_sel;

  assign s_arvalid = (m_arvalid && !rd_act) ? ar_hit : '0;
  assign m_arready = m_arvalid && !rd_act && ((ar_hit == '0) || |(ar_hit & s_arready));
  assign s_rready  = (rd_act && m_rready) ? rd_sel : '0;
  assign m_rvalid  = rd_act && ((rd_sel == '0) || |(rd_sel & s_rvalid));

  always_comb begin
    m_rdata = '0;
    m_rresp = DECERR;
    for (int i = 0; i < N; i++)
      if (rd_sel[i]) begin
        m_rdata = s_rdata[32*i +: 32];
        m_rresp = s_rresp[2*i +: 2];
      end
  end

  always_ff @(posedge clk) begin
    if (!rst_n) begin
      rd_act <= 1'b0;
      rd_sel <= '0;
    end else begin
      if (m_arvalid && m_arready) begin rd_act <= 1'b1; rd_sel <= ar_hit; end
      if (m_rvalid && m_rready) rd_act <= 1'b0;
    end
  end
endmodule
