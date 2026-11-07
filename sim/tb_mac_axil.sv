`timescale 1ns / 1ps
// Peripheral test: mac_axil (axil_slave + registers + mac_opiso) driven directly by a
// randomized AXI4-Lite master and checked against a reference model. It covers bus
// cases the CPU never produces: W before AW, long AW/W gaps, B/R backpressure, writes
// queued behind a stalled B, back-to-back samples, RESULT read while the pipeline is busy,
// every error case and COUNT saturation.
module tb_mac_axil;
  localparam logic [31:0] CTRL = 'h00, SAMPLE = 'h04, STATUS = 'h08, RESULT = 'h0C, ERR = 'h10, ID = 'h14;
  localparam logic [1:0]  OKAY = 2'b00, SLVERR = 2'b10;

  logic clk = 0, rst_n = 0;
  always #5 clk = ~clk;

  logic        awvalid = 0, wvalid = 0, bready = 0, arvalid = 0, rready = 0;
  logic [31:0] awaddr = 0, wdata = 0, araddr = 0;
  logic [3:0]  wstrb = 0;
  wire         awready, wready, bvalid, arready, rvalid;
  wire  [1:0]  bresp, rresp;
  wire  [31:0] rdata;

  mac_axil dut (
      .clk, .rst_n,
      .s_awvalid(awvalid), .s_awready(awready), .s_awaddr(awaddr),
      .s_wvalid(wvalid), .s_wready(wready), .s_wdata(wdata), .s_wstrb(wstrb),
      .s_bvalid(bvalid), .s_bready(bready), .s_bresp(bresp),
      .s_arvalid(arvalid), .s_arready(arready), .s_araddr(araddr),
      .s_rvalid(rvalid), .s_rready(rready), .s_rdata(rdata), .s_rresp(rresp));

  axil_checker #(.NAME("mac")) chk (
      .clk, .rst_n, .awvalid, .awready, .awaddr, .wvalid, .wready, .wdata, .wstrb,
      .bvalid, .bready, .bresp, .arvalid, .arready, .araddr, .rvalid, .rready, .rdata, .rresp);

  int errors = 0, n_wr = 0, n_rd = 0, n_samples = 0;
  int n_aw_first = 0, n_w_first = 0, n_same = 0, n_b_hold = 0, n_r_hold = 0, n_stall = 0;
  int max_delay = 3;                       // random handshake delay range; 0 = full rate
  int ref_acc = 0, ref_cnt = 0;            // reference model

  always @(posedge clk) if (dut.u_if.ar_pend) n_stall++;   // RESULT read held by the interlock

  function automatic int rnd(input int n);
    return (n <= 0) ? 0 : int'($urandom % (n + 1));
  endfunction

  function automatic int wrap20(input int x);
    return (x <<< 12) >>> 12;
  endfunction

  function automatic logic [31:0] word(input int a, input int w, input bit clr);
    return (a & 32'hFFF) | ((w & 32'hFF) << 12) | (clr ? 32'h8000_0000 : 32'h0);
  endfunction

  task automatic expect_eq(input string what, input logic [31:0] got, input logic [31:0] exp);
    if (got !== exp) begin
      errors++;
      if (errors <= 20) $display("[%0t] FAIL %s: got %h expected %h", $time, what, got, exp);
    end
  endtask

  // ---------------- AXI4-Lite master BFM ----------------
  task automatic axi_write_t(input logic [31:0] addr, input logic [31:0] data, input logic [3:0] strb,
                             input int da, input int dw, input int db, output logic [1:0] resp);
    if (da < dw) n_aw_first++; else if (dw < da) n_w_first++; else n_same++;
    if (db > 0) n_b_hold++;
    fork
      begin
        repeat (da) @(posedge clk);
        awvalid <= 1; awaddr <= addr;
        @(posedge clk); while (!awready) @(posedge clk);
        awvalid <= 0;
      end
      begin
        repeat (dw) @(posedge clk);
        wvalid <= 1; wdata <= data; wstrb <= strb;
        @(posedge clk); while (!wready) @(posedge clk);
        wvalid <= 0;
      end
    join
    repeat (db) @(posedge clk);
    bready <= 1;
    @(posedge clk); while (!bvalid) @(posedge clk);
    resp = bresp;
    bready <= 0;
    n_wr++;
  endtask

  task automatic axi_write(input logic [31:0] addr, input logic [31:0] data, input logic [3:0] strb,
                           output logic [1:0] resp);
    axi_write_t(addr, data, strb, rnd(max_delay), rnd(max_delay), rnd(max_delay), resp);
  endtask

  task automatic axi_read(input logic [31:0] addr, output logic [31:0] data, output logic [1:0] resp);
    int dr;
    repeat (rnd(max_delay)) @(posedge clk);
    arvalid <= 1; araddr <= addr;
    @(posedge clk); while (!arready) @(posedge clk);
    arvalid <= 0;
    dr = rnd(max_delay);
    if (dr > 0) n_r_hold++;
    repeat (dr) @(posedge clk);
    rready <= 1;
    @(posedge clk); while (!rvalid) @(posedge clk);
    data = rdata; resp = rresp;
    rready <= 0;
    n_rd++;
  endtask

  // ---------------- model-checked operations ----------------
  task automatic model_push(input int a, input int w, input bit clr);
    if (clr) begin ref_acc = 0; ref_cnt = 0; end
    ref_acc = wrap20(ref_acc + a * w);
    if (ref_cnt < 65535) ref_cnt++;
    n_samples++;
  endtask

  task automatic push(input int a, input int w, input bit clr);
    logic [1:0] r;
    axi_write(SAMPLE, word(a, w, clr), 4'hF, r);
    expect_eq("SAMPLE bresp", r, OKAY);
    model_push(a, w, clr);
  endtask

  task automatic clear_acc();
    logic [1:0] r;
    axi_write(CTRL, 32'h1, 4'hF, r);
    expect_eq("CTRL bresp", r, OKAY);
    ref_acc = 0; ref_cnt = 0;
  endtask

  task automatic check_result(input logic err_bit = 1'b0);
    logic [31:0] d; logic [1:0] r;
    axi_read(RESULT, d, r);
    expect_eq("RESULT", d, ref_acc);
    expect_eq("RESULT rresp", r, OKAY);
    axi_read(STATUS, d, r);
    expect_eq("STATUS", d, {ref_cnt[15:0], 14'd0, err_bit, 1'b1});
  endtask

  function automatic int rand_act();
    int p = rnd(99);
    if (p < 30) return 0;                       // sparsity
    if (p < 35) return -2048;
    if (p < 40) return 2047;
    return rnd(4095) - 2048;
  endfunction

  function automatic int rand_wgt();
    int p = rnd(99);
    if (p < 5)  return -128;
    if (p < 10) return 127;
    return rnd(255) - 128;
  endfunction

  // ---------------- tests ----------------
  task automatic queued_writes_test();
    // Two writes while BREADY is low: the second is accepted into the AW/W holding
    // registers but must not be performed until B#1 is accepted, and then only once.
    int nb;
    clear_acc();
    @(posedge clk);
    awvalid <= 1; awaddr <= SAMPLE; wvalid <= 1; wdata <= word(1000, -3, 0); wstrb <= 4'hF;
    @(posedge clk); while (!(awready && wready)) @(posedge clk);
    wdata <= word(-777, 99, 0);
    @(posedge clk); while (!(awready && wready)) @(posedge clk);
    awvalid <= 0; wvalid <= 0;
    repeat (8) @(posedge clk);
    expect_eq("queued write not performed before B", dut.cnt, 1);
    expect_eq("B held while BREADY low", bvalid, 1);
    bready <= 1;
    nb = 0;
    while (nb < 2) begin @(posedge clk); if (bvalid) nb++; end
    bready <= 0;
    n_wr += 2;
    model_push(1000, -3, 0);
    model_push(-777, 99, 0);
    check_result();
  endtask

  task automatic error_tests();
    logic [31:0] d; logic [1:0] r;
    clear_acc();
    push(100, 7, 1);                            // known state: RESULT 700, COUNT 1

    axi_read(32'h018, d, r);   expect_eq("unmapped read resp", r, SLVERR); expect_eq("unmapped read data", d, 0);
    axi_write(32'h100, 32'hFFFF_FFFF, 4'hF, r); expect_eq("unmapped write resp", r, SLVERR);
    axi_write(32'h006, 32'h1, 4'hF, r);         expect_eq("misaligned write resp", r, SLVERR);
    axi_read(ERR, d, r);       expect_eq("ERR=ADDR", d, 32'h1);

    axi_write(STATUS, 32'h0, 4'hF, r);          expect_eq("write STATUS resp", r, SLVERR);
    axi_write(RESULT, 32'h0, 4'hF, r);          expect_eq("write RESULT resp", r, SLVERR);
    axi_write(ID, 32'h0, 4'hF, r);              expect_eq("write ID resp", r, SLVERR);
    axi_read(CTRL, d, r);      expect_eq("read CTRL resp", r, SLVERR);
    axi_read(SAMPLE, d, r);    expect_eq("read SAMPLE resp", r, SLVERR);
    axi_read(ERR, d, r);       expect_eq("ERR=ADDR|ACCESS", d, 32'h3);

    axi_write(SAMPLE, word(5, 5, 1), 4'b0011, r); expect_eq("partial SAMPLE resp", r, SLVERR);
    axi_write(CTRL, 32'h1, 4'b0001, r);           expect_eq("partial CTRL resp", r, SLVERR);
    axi_read(ERR, d, r);       expect_eq("ERR=..|STRB", d, 32'h7);

    axi_write(SAMPLE, 32'hFFFF_FFFB, 4'hF, r);    expect_eq("unmasked negative SAMPLE resp", r, SLVERR);
    axi_write(SAMPLE, word(1, 1, 0) | 32'h0010_0000, 4'hF, r); expect_eq("reserved bit SAMPLE resp", r, SLVERR);
    axi_read(ERR, d, r);       expect_eq("ERR=all", d, 32'hF);
    check_result(1'b1);                         // nothing rejected reached the core; STATUS.ERR set

    axi_write(ERR, 32'h5, 4'hF, r);             expect_eq("W1C resp", r, OKAY);
    axi_read(ERR, d, r);       expect_eq("ERR after W1C 0x5", d, 32'hA);
    axi_write(ERR, 32'hA, 4'hF, r);
    axi_read(ERR, d, r);       expect_eq("ERR after W1C 0xA", d, 32'h0);
    check_result();
  endtask

  initial begin
    logic [31:0] d; logic [1:0] r; int len; bit by_ctrl;
    repeat (5) @(posedge clk);
    rst_n <= 1;
    @(posedge clk);

    // reset state and identification
    axi_read(ID, d, r);     expect_eq("ID", d, 32'h4D41_4331); expect_eq("ID resp", r, OKAY);
    axi_read(STATUS, d, r); expect_eq("STATUS after reset", d, 32'h1);
    axi_read(RESULT, d, r); expect_eq("RESULT after reset", d, 32'h0);
    axi_read(ERR, d, r);    expect_eq("ERR after reset", d, 32'h0);

    // directed: signed extremes, zero activation, wrap-around, clear
    push(-2048, -128, 1); check_result();          // +262144, the largest product
    push(2047, 127, 0);   check_result();
    push(0, -128, 0);     check_result();          // zero activation is counted, adds 0
    push(-2048, 127, 0); push(2047, -128, 0); push(-1, -1, 0); push(1, -1, 0); check_result();
    for (int i = 0; i < 4; i++) push(-2048, -128, 0);
    check_result();                                // passes +2^19: wraps negative
    clear_acc(); check_result();

    // random dot products, random AXI timing, CLR via SAMPLE bit or CTRL
    for (int t = 0; t < 400; t++) begin
      len = 1 + rnd(30);
      by_ctrl = rnd(1);
      if (by_ctrl) clear_acc();
      for (int k = 0; k < len; k++) push(rand_act(), rand_wgt(), !by_ctrl && k == 0);
      check_result();
    end

    // full-rate: back-to-back samples, RESULT read straight after the last write
    max_delay = 0;
    for (int t = 0; t < 50; t++) begin
      for (int k = 0; k < 25; k++) push(rand_act(), rand_wgt(), k == 0);
      check_result();
    end
    max_delay = 3;

    queued_writes_test();

    // AW and W separated by a long gap, in both orders
    axi_write_t(SAMPLE, word(-1234, 56, 1), 4'hF, 0, 12, 0, r); expect_eq("AW-first resp", r, OKAY);
    model_push(-1234, 56, 1);
    axi_write_t(SAMPLE, word(321, -77, 0), 4'hF, 12, 0, 5, r);  expect_eq("W-first resp", r, OKAY);
    model_push(321, -77, 0);
    check_result();

    error_tests();

    // COUNT saturates at 0xFFFF
    max_delay = 0;
    clear_acc();
    for (int k = 0; k < 65540; k++) push(1, 1, 0);
    check_result();
    max_delay = 3;

    if (n_aw_first == 0 || n_w_first == 0 || n_same == 0 || n_b_hold == 0 || n_r_hold == 0 || n_stall == 0) begin
      errors++;
      $display("FAIL coverage: aw_first=%0d w_first=%0d same=%0d b_hold=%0d r_hold=%0d stall=%0d",
               n_aw_first, n_w_first, n_same, n_b_hold, n_r_hold, n_stall);
    end
    $display("tb_mac_axil: %0d AXI writes, %0d AXI reads, %0d samples", n_wr, n_rd, n_samples);
    $display("  write orderings AW-first/W-first/same-cycle: %0d/%0d/%0d", n_aw_first, n_w_first, n_same);
    $display("  B backpressure: %0d writes, R backpressure: %0d reads, RESULT interlock wait cycles: %0d",
             n_b_hold, n_r_hold, n_stall);
    $display("  model mismatches: %0d, AXI protocol violations: %0d", errors, chk.errors);
    $display("SIM RESULT: %s", (errors == 0 && chk.errors == 0) ? "PASS" : "FAIL");
    $finish;
  end

  initial begin
    #50_000_000;
    $display("SIM RESULT: FAIL (timeout)");
    $finish;
  end
endmodule
