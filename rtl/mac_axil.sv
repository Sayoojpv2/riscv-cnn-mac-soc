// CNN MAC accelerator peripheral: the operand-isolated MAC core (mac_opiso, reused
// unchanged from cnn-mac-asic-hardening) behind an AXI4-Lite register interface.
//
// Register map (byte offsets, 32-bit registers, full-word access only):
//   0x00 CTRL    W    bit0 CLR: reset the accumulator and the sample count
//   0x04 SAMPLE  W    [11:0] activation (signed), [19:12] weight (signed),
//                     [30:20] reserved (must be 0), [31] CLR: this sample starts a new sum
//   0x08 STATUS  R    bit0 DONE (no sample/clear in flight: RESULT is final),
//                     bit1 ERR (some ERR bit set), [31:16] COUNT (samples since clear, saturating)
//   0x0C RESULT  R    20-bit accumulator, sign-extended. A read waits (bus wait
//                     states) until DONE, so it can never return a partial sum.
//   0x10 ERR     R/W1C sticky error flags (write 1 to clear):
//                     bit0 ADDR   access to an unmapped offset
//                     bit1 ACCESS write to a read-only / read of a write-only register
//                     bit2 STRB   partial (byte/halfword) write
//                     bit3 SAMPLE SAMPLE write with reserved bits set
//   0x14 ID      R    0x4D414331 ("MAC1")
// Every erroneous access is also answered with SLVERR and has no other effect
// (a rejected SAMPLE or CTRL write never reaches the MAC core).
//
// One accepted SAMPLE write = exactly one valid_i pulse: axil_slave performs each AXI
// write once, and the core takes one sample per cycle, so back-to-back writes never
// overflow it. Arithmetic: 12b x 8b signed -> 20b product, 20-bit wrap-around accumulator.
module mac_axil (
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
  localparam logic [11:0] CTRL = 12'h000, SAMPLE = 12'h004, STATUS = 12'h008,
                          RESULT = 12'h00C, ERR = 12'h010, ID = 12'h014;
  localparam logic [31:0] ID_VALUE = 32'h4D41_4331;

  logic        wr_en, rd_en, wr_err, rd_err;
  logic [11:0] wr_addr, rd_addr;
  logic [31:0] wr_data, rd_data;
  logic [3:0]  wr_strb;
  logic        busy;

  axil_slave #(.AW(12)) u_if (
      .clk, .rst_n,
      .s_awvalid, .s_awready, .s_awaddr(s_awaddr[11:0]),
      .s_wvalid, .s_wready, .s_wdata, .s_wstrb,
      .s_bvalid, .s_bready, .s_bresp,
      .s_arvalid, .s_arready, .s_araddr(s_araddr[11:0]),
      .s_rvalid, .s_rready, .s_rdata, .s_rresp,
      .wr_en, .wr_addr, .wr_data, .wr_strb, .wr_wait(1'b0), .wr_err,
      .rd_en, .rd_addr, .rd_data, .rd_wait(busy && rd_addr == RESULT), .rd_err
  );

  // ---------------- access checking ----------------
  function automatic logic is_reg(input logic [11:0] a);
    is_reg = a == CTRL || a == SAMPLE || a == STATUS || a == RESULT || a == ERR || a == ID;
  endfunction

  wire w_ro     = wr_addr == STATUS || wr_addr == RESULT || wr_addr == ID;
  wire e_waddr  = !is_reg(wr_addr);
  wire e_wacc   = w_ro;
  wire e_strb   = is_reg(wr_addr) && !w_ro && wr_strb != 4'hF;
  wire e_sample = wr_addr == SAMPLE && wr_strb == 4'hF && wr_data[30:20] != 11'd0;
  assign wr_err = e_waddr | e_wacc | e_strb | e_sample;

  wire e_raddr  = !is_reg(rd_addr);
  wire e_racc   = rd_addr == CTRL || rd_addr == SAMPLE;
  assign rd_err = e_raddr | e_racc;

  // ---------------- MAC core ----------------
  wire wr_ok = wr_en && !wr_err;
  wire iss_v = wr_ok && wr_addr == SAMPLE;
  wire iss_c = wr_ok && ((wr_addr == SAMPLE && wr_data[31]) || (wr_addr == CTRL && wr_data[0]));

  logic signed [19:0] acc;
  logic               core_valid;

  mac_opiso u_core (
      .clk, .rst_n,
      .valid_i(iss_v), .clear_i(iss_c),
      .act_i(wr_data[11:0]), .wgt_i(wr_data[19:12]),
      .acc_o(acc), .valid_o(core_valid)
  );

  // The core has a fixed 3-cycle latency (operands -> product -> accumulator).
  // pv/pc mirror its first two stages: while any is set, acc_o is not final.
  // COUNT is updated on the same clock edge as acc_o.
  logic [1:0]  pv, pc;
  logic [15:0] cnt;
  assign busy = |pv || |pc;

  always_ff @(posedge clk) begin
    if (!rst_n) begin
      pv  <= '0;
      pc  <= '0;
      cnt <= '0;
    end else begin
      pv <= {pv[0], iss_v};
      pc <= {pc[0], iss_c};
      if (pc[1])                       cnt <= {15'd0, pv[1]};
      else if (pv[1] && cnt != 16'hFFFF) cnt <= cnt + 16'd1;
    end
  end

  // ---------------- error flags ----------------
  logic [3:0] err;
  wire  [3:0] err_set = (wr_en ? {e_sample, e_strb, e_wacc, e_waddr} : 4'd0) |
                        (rd_en ? {2'b00, e_racc, e_raddr}            : 4'd0);
  wire  [3:0] err_clr = (wr_ok && wr_addr == ERR) ? wr_data[3:0] : 4'd0;

  always_ff @(posedge clk)
    if (!rst_n) err <= '0;
    else        err <= (err & ~err_clr) | err_set;

  // ---------------- read data ----------------
  always_comb
    case (rd_addr)
      STATUS:  rd_data = {cnt, 14'd0, |err, !busy};
      RESULT:  rd_data = {{12{acc[19]}}, acc};
      ERR:     rd_data = {28'd0, err};
      ID:      rd_data = ID_VALUE;
      default: rd_data = 32'd0;
    endcase

`ifndef SYNTHESIS
  // Simulation check: the stage mirror must stay in step with the core's valid pipeline.
  logic pv2;
  always @(posedge clk) begin
    pv2 <= rst_n && pv[1];
    if (rst_n && core_valid !== pv2)
      $display("ERROR: mac_axil valid mirror out of step with mac_opiso at %0t", $time);
  end
`endif
endmodule
