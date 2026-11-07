// Source: github.com/Sayoojpv2/cnn-mac-asic-hardening rtl/mac_opiso.sv @ 720e7ea (unchanged below this line).
// Sparsity-aware operand-isolated MAC. Same ports, latency and results as mac_baseline.
//
// A zero activation (or an idle cycle) gives a zero product, so the sample is
// not loaded into the operand registers: they keep their previous values, the
// multiplier inputs stay constant, and the multiplier, product register and
// accumulator adder do not switch. A 1-bit flag (n1 -> n2) records that the
// product is live; for zero samples the accumulator holds instead of adding 0.
//
// Isolation is done with register enables (D-input recirculation), not clock
// gating: every flop is clocked every cycle, so there is no gated-clock glitch
// or CTS risk. The original FPGA design only forced the product register to 0
// while its operand registers kept loading, which leaves the multiplier switching.
module mac_opiso (
    input  logic               clk,
    input  logic               rst_n,     // synchronous, active low
    input  logic               valid_i,
    input  logic               clear_i,
    input  logic signed [11:0] act_i,
    input  logic signed [7:0]  wgt_i,
    output logic signed [19:0] acc_o,
    output logic               valid_o
);
  logic signed [11:0] act_q;
  logic signed [7:0]  wgt_q;
  logic signed [19:0] prod_q;
  logic               v1, v2, n1, n2, c1, c2;

  wire live = valid_i && (act_i != 12'sd0);  // product may be non-zero

  always_ff @(posedge clk) begin
    if (!rst_n) begin
      act_q   <= '0;
      wgt_q   <= '0;
      prod_q  <= '0;
      {v1, v2, n1, n2, c1, c2} <= '0;
      acc_o   <= '0;
      valid_o <= 1'b0;
    end else begin
      // S1: operands load only for live samples; otherwise they hold.
      if (live) begin
        act_q <= act_i;
        wgt_q <= wgt_i;
      end
      v1 <= valid_i;
      n1 <= live;
      c1 <= clear_i;
      // S2: held operands give an unchanged product, so prod_q does not toggle.
      prod_q <= act_q * wgt_q;
      v2 <= v1;
      n2 <= n1;
      c2 <= c1;
      // S3: only live products are added; a held prod_q is never used.
      if (c2)      acc_o <= n2 ? prod_q : '0;
      else if (n2) acc_o <= acc_o + prod_q;
      valid_o <= v2;
    end
  end
endmodule
