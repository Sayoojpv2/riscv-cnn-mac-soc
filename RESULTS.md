# Results

Everything below was measured in RTL simulation on 2026-11-07. Raw logs are in [`results/`](results/).
Tools: Icarus Verilog 13.0, riscv64-unknown-elf-gcc 16.1.0 (binutils 2.47) at `-O2`, Yosys 0.70
(YoWASP), Windows 11. Cycle counts depend on the compiler. CI uses Ubuntu's GCC 13, so its logs
(GitHub Actions artifacts) may differ slightly from these.

## Test outcomes

| test | result | key figures |
|---|---|---|
| `tb_mac_axil` (peripheral) | **PASS** | 73,164 AXI writes, 935 reads, 72,938 samples; orderings AW-first / W-first / same-cycle 2,339 / 2,434 / 68,389; B backpressure on 4,837 writes, R backpressure on 632 reads; 78 `RESULT` interlock wait cycles; 0 model mismatches; 0 protocol violations |
| `tb_soc` fastmul | **PASS** | firmware `RESULT: PASS`, exit code 0, 1,702,642 cycles to `ebreak` |
| `tb_soc` slowmul | **PASS** | 2,195,174 cycles to `ebreak` |
| `tb_soc` memwait | **PASS** | 1,908,391 cycles to `ebreak`, average ROM read 2.49–2.60 cycles (wait states) |

In every `tb_soc` configuration:

* All three convolution comparisons show **0 mismatches out of 576** (software vs Python golden
  model, accelerator vs golden model, software vs accelerator), including the 157 outputs whose
  sums wrap 20 bits and the 24 all-zero windows.
* Firmware self-tests (memory/bus, MAC arithmetic, MAC error handling) and the post-run
  accelerator check (`COUNT` = 25, `ERR` = 0) pass.
* Bus error responses are exactly as provoked by the firmware: **5 SLVERR, 1 DECERR**.
* The five AXI protocol checkers (CPU port and the four slave ports) report no violations.
* `count_cycle` in PicoRV32 equals the testbench's count of simulated cycles.
* Exactly **14,400 MAC writes for 576 `RESULT` reads** (25 per output). The software
  convolution makes no MAC access.
* Every one of the 14,405 samples (5 self-test + 14,400 convolution) reaches the
  accumulator **3 cycles** after its `SAMPLE` write is accepted.

Mutation check (run once by hand, not part of `make sim`): three bugs were injected into copies
of the RTL. `tb_mac_axil` failed on each one: a write performed while B was pending, a removed
`RESULT` interlock, and a removed reserved-bit check.

## Software vs accelerator: 5×5 convolution, 28×28 → 24×24 (14,400 MACs)

Cycles from `rdcycle` around each call. The testbench measures its own window between the
firmware's marker writes, which adds 19–30 cycles of call and marker overhead and agrees in
every run.

| CPU configuration | software | accelerator | software ÷ accelerator |
|---|---:|---:|---:|
| `ENABLE_FAST_MUL` (default) | 713,542 (49.6 / MAC) | 783,716 (54.4 / MAC) | **0.91**: accelerator 9.8 % slower |
| iterative `ENABLE_MUL` | 1,203,142 (83.6 / MAC) | 783,716 (54.4 / MAC) | **1.54**: accelerator faster |
| fast mul + random ROM/RAM wait states | 802,789 | 882,548 | 0.91 |

Bus transactions in the measured windows (fastmul; all transactions take 2 cycles without
wait states):

| | instruction fetches | ROM data reads | RAM reads | RAM writes | MAC writes | MAC reads | total |
|---|---:|---:|---:|---:|---:|---:|---:|
| software | 152,755 | 28,800 | 1 | 577 | 0 | 0 | 182,134 |
| accelerator | 166,237 | 14,425 | 14,401 | 602 | 14,400 | 576 | 210,642 |

Accelerator latency: 3 cycles from an accepted `SAMPLE` write to the accumulated result
(`mac_opiso` pipeline). An AXI write or read to the peripheral takes 2 cycles. In the
full-system runs the `RESULT` interlock never had to wait (average `RESULT` read 2.00 cycles):
by the time PicoRV32 issues the load, the 3-cycle pipeline has already drained. Its wait path
is exercised by `tb_mac_axil`.

### Why the accelerator does not win with a fast multiplier

The compiled inner loops (`build/firmware.lst`, GCC 16.1 `-O2`):

* software, per MAC: `lh, lb, mul, add` plus 4 loop/address instructions = **8 instructions**
* accelerator, per MAC: `lhu, lw` (packed weight from the stack), `slli, srli` (12-bit mask),
  `or`, `sw` to `SAMPLE`, plus 3 loop/address instructions = **9 instructions**

The accelerator replaces `mul + add` (2 instructions) with packing and an MMIO store (4
instructions plus a RAM load). PicoRV32 averages ~4.7 cycles per instruction here, and every
instruction and every load/store is a 2-cycle bus transaction. So the cost is set by
instruction count and bus traffic, not by the multiplier. The MAC core itself is busy for
14,400 of the 783,716 cycles (1.8 %). It could take one sample per cycle, but programmed I/O
feeds it one sample every ~54 cycles.

When the CPU multiplier is iterative, each `mul` costs 34 more cycles ((1,203,142 −
713,542) / 14,400 = 34.0). The software loop slows by that amount while the accelerator loop,
which has no `mul`, is unchanged. That gives the 1.54× speed-up. Wait states slow both versions
by about 12 % and leave the ratio unchanged, because both are fetch/bus bound.

### Compiler sensitivity (GitHub Actions run 42359714867)

CI builds the same firmware with Ubuntu's GCC 13.2.0 and simulates with Icarus Verilog 12.0.
All tests pass there too, and synthesis gives identical numbers. The cycle counts:

| CPU configuration | software (GCC 13.2) | accelerator (GCC 13.2) | software ÷ accelerator |
|---|---:|---:|---:|
| fast mul | 713,542 | 841,338 | 0.85 |
| iterative mul | 1,203,142 | 841,338 | 1.43 |
| fast mul + wait states | 802,809 | 941,732 | 0.85 |

The software loop compiles to the same cycle count with both compilers. The accelerator loop
is 7.4 % slower with GCC 13.2 (841,338 vs 783,716). The per-MAC packing and MMIO store
sequence is sensitive to code generation, which is another sign that the accelerated path is
limited by CPU-side overhead.

So for this SoC the gain depends on the interface, not on the MAC. Fewer bus transactions per
MAC would be needed: weights held in the peripheral (only activations streamed), several
activations packed per write, or DMA from memory. These were not implemented, to keep the
peripheral minimal.

## Synthesis (Yosys 0.70)

ROM/RAM arrays are excluded (black boxes); they would be SRAM macros or block RAM. Numbers are
from [`results/synth_summary.md`](results/synth_summary.md).

Generic gate-level cells (`synth`, hierarchy kept, cells local to each module):

| module | cells | sequential | combinational |
|---|---:|---:|---:|
| picorv32 (core, incl. 31×32 register file as flops) | 8,834 | 1,629 | 7,205 |
| picorv32_pcpi_fast_mul (33×33 multiplier) | 7,609 | 133 | 7,476 |
| picorv32_pcpi_div | 1,438 | 200 | 1,238 |
| mac_opiso (12×8 multiplier + 20-bit accumulator) | 843 | 67 | 776 |
| axil_decoder | 414 | 11 | 403 |
| mac_axil (registers, checks, stage mirror) | 282 | 24 | 258 |
| uart_axil | 202 | 49 | 153 |
| axil_slave (one instance; used by MAC and UART here) | 187 | 99 | 88 |
| picorv32_axi_adapter | 23 | 4 | 19 |
| **soc_top total** | **20,019** | **2,315** | **17,704** |

AMD 7-series (Zynq-7000 fabric) mapping estimate (`synth_xilinx -family xc7`, no place and
route, no timing):

| design | LUT | FF | CARRY4 | DSP48E1 | LUTRAM |
|---|---:|---:|---:|---:|---:|
| soc_top (CPU + bus + MAC + UART) | 1,997 | 1,218 | 162 | 5 | 12 |
| mac_axil (MAC peripheral alone) | 192 | 150 | 9 | 1 | 0 |

The MAC peripheral is about 10 % of the SoC logic's LUTs. In generic cells the CPU's fast
33×33 multiplier alone (7,609) is about 5.8× the whole MAC peripheral (mac_axil + its
axil_slave + mac_opiso = 1,312), and the iterative multiplier that makes the accelerator
worthwhile would be much smaller. That area-versus-cycles trade-off is the co-design point.
