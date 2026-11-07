`timescale 1ns / 1ps
// Full-system test: the compiled firmware runs on PicoRV32 inside soc_top.
// The testbench only provides clock, reset, the ROM image and observation:
//  - UART receiver (decodes the real 8N1 tx line) -> console, PASS/FAIL detection
//  - AXI4-Lite protocol checkers on the CPU port and on every slave port
//  - bus monitor: transactions, latency and error responses per target and per phase
//    (phases delimited by firmware markers written to the UART SCRATCH register)
//  - cross-checks of the firmware's rdcycle measurements and of the CPU cycle counter
//  - MAC core latency (SAMPLE accepted -> mac_opiso valid_o)
// plusargs: +firmware=<hex>  +vcd
module tb_soc;
  parameter bit FAST_MUL = 1;
  parameter bit MEM_WAIT = 0;
  localparam int CPB        = 16;           // UART clocks per bit
  localparam int MAX_CYCLES = 10_000_000;
  // Error responses the firmware provokes on purpose (firmware/main.c):
  // SLVERR: ROM store, MAC unmapped read, MAC RESULT write, MAC byte write, MAC reserved bits
  // DECERR: read of UNMAPPED_ADDR
  localparam int EXP_SLVERR = 5, EXP_DECERR = 1;

  logic clk = 0, rst_n = 0;
  always #5 clk = ~clk;
  wire uart_tx, trap;

  soc_top #(.FAST_MUL(FAST_MUL), .MEM_WAIT(MEM_WAIT), .UART_CLKS_PER_BIT(CPB)) dut (
      .clk, .rst_n, .uart_tx, .trap);

  // ---------------- protocol checkers ----------------
  axil_checker #(.NAME("cpu")) chk_cpu (
      .clk, .rst_n,
      .awvalid(dut.m_awvalid), .awready(dut.m_awready), .awaddr(dut.m_awaddr),
      .wvalid(dut.m_wvalid), .wready(dut.m_wready), .wdata(dut.m_wdata), .wstrb(dut.m_wstrb),
      .bvalid(dut.m_bvalid), .bready(dut.m_bready), .bresp(dut.m_bresp),
      .arvalid(dut.m_arvalid), .arready(dut.m_arready), .araddr(dut.m_araddr),
      .rvalid(dut.m_rvalid), .rready(dut.m_rready), .rdata(dut.m_rdata), .rresp(dut.m_rresp));

  for (genvar i = 0; i < 4; i++) begin : g_chk
    axil_checker #(.NAME("slave"), .ID(i)) chk (
        .clk, .rst_n,
        .awvalid(dut.s_awvalid[i]), .awready(dut.s_awready[i]), .awaddr(dut.s_awaddr),
        .wvalid(dut.s_wvalid[i]), .wready(dut.s_wready[i]), .wdata(dut.s_wdata), .wstrb(dut.s_wstrb),
        .bvalid(dut.s_bvalid[i]), .bready(dut.s_bready[i]), .bresp(dut.s_bresp[2*i +: 2]),
        .arvalid(dut.s_arvalid[i]), .arready(dut.s_arready[i]), .araddr(dut.s_araddr),
        .rvalid(dut.s_rvalid[i]), .rready(dut.s_rready[i]), .rdata(dut.s_rdata[32*i +: 32]),
        .rresp(dut.s_rresp[2*i +: 2]));
  end

  // ---------------- reset, ROM image, waves ----------------
  string fw;
  initial begin
    if (!$value$plusargs("firmware=%s", fw)) fw = "build/firmware.hex";
    $readmemh(fw, dut.u_rom.mem);
    // RAM powers up with garbage, not X (a 32-bit read of a partly written word must
    // not trip the X check) and not zero (startup code must clear .bss itself)
    for (int i = 0; i < 4096; i++) dut.u_ram.mem[i] = $urandom;
    if ($test$plusargs("vcd")) begin $dumpfile("build/tb_soc.vcd"); $dumpvars(0, tb_soc); end
    repeat (10) @(posedge clk);
    rst_n <= 1;
  end

  // ---------------- cycle counting ----------------
  longint cyc = 0;                                   // posedges with reset released
  always @(posedge clk) if (rst_n) cyc <= cyc + 1;

  // ---------------- UART receiver ----------------
  logic [31:0] last4 = 0;
  int n_pass = 0, n_fail = 0, n_chars = 0, uart_err = 0;
  initial begin : uart_rx
    logic [7:0] ch;
    forever begin
      @(negedge uart_tx);
      repeat (CPB / 2) @(posedge clk);
      if (uart_tx !== 1'b0) uart_err++;              // start bit
      for (int i = 0; i < 8; i++) begin repeat (CPB) @(posedge clk); ch[i] = uart_tx; end
      repeat (CPB) @(posedge clk);
      if (uart_tx !== 1'b1) uart_err++;              // stop bit
      $write("%c", ch);
      n_chars++;
      last4 = {last4[23:0], ch};
      if (last4 == "PASS") n_pass++;
      if (last4 == "FAIL") n_fail++;
    end
  end

  // ---------------- bus monitor (CPU port) ----------------
  // target classes: 0 ROM instruction fetch, 1 ROM data, 2 RAM, 3 MAC, 4 UART, 5 unmapped
  localparam int NT = 6;
  int phase = 0;                                     // 0 other, 1 software conv, 2 hardware conv
  int rd_n  [0:2][0:NT-1], wr_n [0:2][0:NT-1];
  longint rd_lat[0:2][0:NT-1], wr_lat[0:2][0:NT-1];
  longint ph_start[0:2], ph_cycles[0:2];
  int n_slverr = 0, n_decerr = 0, exit_code = -1;
  longint fw_sw = -1, fw_hw = -1;
  initial for (int p = 0; p < 3; p++) begin
    ph_cycles[p] = 0;
    for (int t = 0; t < NT; t++) begin rd_n[p][t] = 0; wr_n[p][t] = 0; rd_lat[p][t] = 0; wr_lat[p][t] = 0; end
  end

  function automatic int tclass(input logic [31:0] a, input logic instr);
    case (a[31:28])
      4'h0: return (a < 32'h4000) ? (instr ? 0 : 1) : 5;
      4'h1: return (a < 32'h1000_4000) ? 2 : 5;
      4'h2: return (a < 32'h2000_1000) ? 3 : 5;
      4'h3: return (a < 32'h3000_1000) ? 4 : 5;
      default: return 5;
    endcase
  endfunction

  logic        rd_busy = 0, wr_busy = 0;
  longint      rd_t0, wr_t0;
  int          rd_c, wr_c;
  logic [31:0] wr_a, wr_d;
  always @(posedge clk) if (rst_n) begin
    // reads: from ARVALID rising to the R handshake
    if (dut.m_arvalid && !rd_busy) begin
      rd_busy = 1; rd_t0 = cyc; rd_c = tclass(dut.m_araddr, dut.m_arprot[2]);
    end
    if (dut.m_rvalid && dut.m_rready) begin
      rd_n[phase][rd_c]++; rd_lat[phase][rd_c] += cyc - rd_t0 + 1; rd_busy = 0;
      if (dut.m_rresp == 2'b10) n_slverr++;
      if (dut.m_rresp == 2'b11) n_decerr++;
    end
    // writes: from AWVALID rising to the B handshake
    if (dut.m_awvalid && !wr_busy) begin
      wr_busy = 1; wr_t0 = cyc; wr_c = tclass(dut.m_awaddr, 1'b0); wr_a = dut.m_awaddr;
    end
    if (dut.m_wvalid && dut.m_wready) wr_d = dut.m_wdata;
    if (dut.m_bvalid && dut.m_bready) begin
      wr_n[phase][wr_c]++; wr_lat[phase][wr_c] += cyc - wr_t0 + 1; wr_busy = 0;
      if (dut.m_bresp == 2'b10) n_slverr++;
      if (dut.m_bresp == 2'b11) n_decerr++;
      if (wr_a == 32'h3000_0008) scratch_write(wr_d);
    end
  end

  task automatic scratch_write(input logic [31:0] v);
    case (v[31:24])
      8'hA1: begin                                   // phase markers 1..4
        if (v[23:0] == 1 || v[23:0] == 3) begin phase = (v[23:0] == 1) ? 1 : 2; ph_start[phase] = cyc; end
        else begin ph_cycles[phase] = cyc - ph_start[phase]; phase = 0; end
      end
      8'hA2: fw_sw = v[23:0];
      8'hA3: fw_hw = v[23:0];
      8'hC0: exit_code = v[23:0];
      default: ;
    endcase
  endtask

  // ---------------- MAC core latency ----------------
  longint iss_t[0:7];
  int iss_w = 0, iss_r = 0, lat_min = 1000, lat_max = 0, n_core = 0, l;
  always @(posedge clk) if (rst_n) begin
    if (dut.u_mac.iss_v) begin iss_t[iss_w % 8] = cyc; iss_w++; end
    if (dut.u_mac.core_valid) begin
      l = int'(cyc - iss_t[iss_r % 8]);
      iss_r++; n_core++;
      if (l < lat_min) lat_min = l;
      if (l > lat_max) lat_max = l;
    end
  end

  // ---------------- end of test ----------------
  function automatic string tname(input int t);
    case (t) 0: return "ROM fetch"; 1: return "ROM data "; 2: return "RAM      ";
             3: return "MAC      "; 4: return "UART     "; default: return "unmapped ";
    endcase
  endfunction

  task automatic report_phase(input int p, input string name);
    int nr = 0, nw = 0;
    $display("  %s: %0d cycles (testbench window)", name, ph_cycles[p]);
    for (int t = 0; t < NT; t++) begin
      nr += rd_n[p][t]; nw += wr_n[p][t];
      if (rd_n[p][t] || wr_n[p][t])
        $display("    %s reads %7d (avg %0.2f cyc)  writes %7d (avg %0.2f cyc)", tname(t),
                 rd_n[p][t], rd_n[p][t] ? 1.0 * rd_lat[p][t] / rd_n[p][t] : 0.0,
                 wr_n[p][t], wr_n[p][t] ? 1.0 * wr_lat[p][t] / wr_n[p][t] : 0.0);
    end
    $display("    total bus transactions: %0d (%0d reads, %0d writes)", nr + nw, nr, nw);
  endtask

  int errors = 0;
  task automatic expect_true(input bit ok, input string what);
    if (!ok) begin errors++; $display("TB CHECK FAILED: %s", what); end
  endtask

  initial begin
    wait (rst_n);
    while (trap !== 1'b1 && cyc < MAX_CYCLES) @(posedge clk);
    expect_true(trap === 1'b1, "CPU reached ebreak (trap) before the cycle limit");
    while (dut.u_uart.busy) @(posedge clk);          // let the last character finish
    repeat (4 * CPB) @(posedge clk);

    $display("\n==== tb_soc summary (FAST_MUL=%0d, MEM_WAIT=%0d) ====", FAST_MUL, MEM_WAIT);
    $display("  firmware: %s, %0d cycles to ebreak, %0d UART characters", fw, cyc, n_chars);
    report_phase(1, "software convolution");
    report_phase(2, "hardware convolution");
    $display("  firmware rdcycle: sw=%0d hw=%0d (testbench windows %0d / %0d)",
             fw_sw, fw_hw, ph_cycles[1], ph_cycles[2]);
    $display("  MAC core latency SAMPLE accepted -> valid_o: min %0d max %0d cycles over %0d samples",
             lat_min, lat_max, n_core);
    $display("  error responses: SLVERR %0d (expected %0d), DECERR %0d (expected %0d)",
             n_slverr, EXP_SLVERR, n_decerr, EXP_DECERR);

    expect_true(exit_code == 0, "firmware exit code 0");
    expect_true(n_pass == 1 && n_fail == 0, "UART reported PASS once and no FAIL");
    expect_true(uart_err == 0, "UART framing");
    expect_true(chk_cpu.errors == 0 && g_chk[0].chk.errors == 0 && g_chk[1].chk.errors == 0 &&
                g_chk[2].chk.errors == 0 && g_chk[3].chk.errors == 0, "AXI protocol checkers");
    expect_true(n_slverr == EXP_SLVERR && n_decerr == EXP_DECERR, "expected bus error responses");
    expect_true(dut.cpu.picorv32_core.count_cycle == cyc, "rdcycle counter equals simulated cycles");
    expect_true(fw_sw > 0 && ph_cycles[1] >= fw_sw && ph_cycles[1] - fw_sw < 100,
                "firmware software-conv cycles match the testbench window");
    expect_true(fw_hw > 0 && ph_cycles[2] >= fw_hw && ph_cycles[2] - fw_hw < 100,
                "firmware hardware-conv cycles match the testbench window");
    expect_true(wr_n[2][3] > 0 && wr_n[2][3] == 25 * rd_n[2][3],
                "hardware conv: exactly 25 SAMPLE writes per RESULT read");
    expect_true(wr_n[1][3] == 0 && rd_n[1][3] == 0, "software conv does not touch the MAC");
    expect_true(n_core == iss_w && lat_min == 3 && lat_max == 3, "MAC core latency is 3 cycles for every sample");

    $display("METRIC fast_mul=%0d mem_wait=%0d sw_cycles=%0d hw_cycles=%0d mac_writes=%0d mac_reads=%0d",
             FAST_MUL, MEM_WAIT, fw_sw, fw_hw, wr_n[2][3], rd_n[2][3]);
    $display("SIM RESULT: %s", errors == 0 ? "PASS" : "FAIL");
    $finish;
  end
endmodule
