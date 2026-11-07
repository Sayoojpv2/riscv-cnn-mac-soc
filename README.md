# RISC-V SoC Integration and Hardware-Software Co-Design of a Low-Power CNN MAC Accelerator

A small, fully simulated System-on-Chip: a **PicoRV32 RV32IM** processor runs compiled
**bare-metal C firmware** from a boot ROM and drives a **custom CNN MAC accelerator** over an
**AXI4-Lite** bus. The firmware computes the same 5×5 convolution in software and on the
accelerator, compares both against a golden model, measures cycles with the CPU's cycle
counter and prints `RESULT: PASS` on a real (bit-serial) UART. Everything runs in open-source
RTL simulation (Icarus Verilog); nothing here was tested on an FPGA or on silicon.

## Why this project builds on my earlier work

| project | what it contributed here |
|---|---|
| [MNIST-CNN-Zynq-Energy-Efficient-Accelerator](https://github.com/Sayoojpv2/MNIST-CNN-Zynq-Energy-Efficient-Accelerator) | the CNN datapath arithmetic (`MAC.sv`, `PE.sv`): 12-bit activations × 8-bit weights, 5×5 kernels, 20-bit accumulators, 28×28 MNIST input |
| [cnn-mac-asic-hardening](https://github.com/Sayoojpv2/cnn-mac-asic-hardening) | the verified **operand-isolated MAC** `mac_opiso.sv` (exhaustively simulated, taken through SKY130 RTL-to-GDSII). It is reused **unchanged** here as [`rtl/mac_opiso.sv`](rtl/mac_opiso.sv) |

The earlier projects showed the MAC works and what it costs in silicon. This one answers the
system question: **what happens when a CPU has to feed it over a bus?**

## SoC architecture

```
                 +-----------------------------------------------+
                 |  PicoRV32  (RV32IM, rdcycle, fast or iterative |
                 |            multiplier, hardware divider)       |
                 +----------------------+------------------------+
                                        | AXI4-Lite master (picorv32_axi)
                 +----------------------v------------------------+
                 |  axil_decoder  1 -> 4, DECERR for unmapped     |
                 +-----+-----------+------------+------------+---+
                       |           |            |            |
              +--------v--+ +------v-----+ +----v--------+ +-v-----------+
              | boot ROM  | |    RAM     | |  mac_axil   | |  uart_axil  |
              | 16 KiB    | |  16 KiB    | |  registers  | |  8N1 TX     |
              | axil_mem  | |  axil_mem  | |      |      | |  + SCRATCH  |
              +-----------+ +------------+ | mac_opiso   | +------+------+
                                           | (unchanged) |        |
                                           +-------------+     uart_tx
   every slave = axil_slave (shared AXI4-Lite front-end) + its own register/memory logic
```

| address | slave | notes |
|---|---|---|
| `0x0000_0000` | boot ROM, 16 KiB | firmware image (code, constants, `.data` initial values); stores get SLVERR |
| `0x1000_0000` | RAM, 16 KiB | `.data`, `.bss`, stack; byte/halfword/word strobes |
| `0x2000_0000` | MAC accelerator, 4 KiB window | register map below |
| `0x3000_0000` | UART, 4 KiB window | `TXDATA`, `STATUS`, `SCRATCH` |
| anything else | – | the decoder answers DECERR, read data 0 |

## Processor and bus

* **CPU:** the official [PicoRV32](https://github.com/YosysHQ/picorv32) (`picorv32_axi`,
  ISC licence, commit `ef203c2`, vendored unmodified in `rtl/third_party/`). Configuration:
  RV32IM (no C), `ENABLE_COUNTERS` (for `rdcycle`), barrel shifter, `ENABLE_DIV`, and either
  `ENABLE_FAST_MUL` (default) or the iterative `ENABLE_MUL` (`FAST_MUL=0`), illegal-instruction
  and misalignment traps on, no interrupts. `ebreak` asserts `trap`, which ends the simulation.
* **AXI4-Lite:** PicoRV32's adapter issues one transaction at a time and has **no BRESP/RRESP
  inputs**. The bus still produces correct responses (the testbench checks them), and the
  MAC also records every error in a sticky `ERR` register, because that is the only place
  firmware can see it.
* **`axil_decoder`** routes VALID/READY and responses and broadcasts the payloads. Write and
  read channels are independent; W may arrive before, with or after AW. AWREADY/ARREADY are
  only asserted together with VALID.
* **`axil_slave`** is the single AXI4-Lite front-end used by all four slaves. AW and W are
  accepted independently into one-entry holding registers. The write happens **exactly once**,
  when both are present and the B channel is free. Reads support wait states. A held
  VALID or a stalled BREADY can never repeat or drop a write. Measured latency without
  wait states: **2 cycles** per read or write from VALID to the completing handshake.

## MAC accelerator peripheral (`rtl/mac_axil.sv`)

The peripheral wraps the unchanged `mac_opiso` core (3-stage pipeline: operand registers held
on zero activations → product → 20-bit accumulator).

| offset | name | access | description |
|---|---|---|---|
| `0x00` | `CTRL` | W | bit 0 `CLR`: clear accumulator and sample count |
| `0x04` | `SAMPLE` | W | `[11:0]` activation (signed), `[19:12]` weight (signed), `[30:20]` reserved = 0, `[31]` `CLR`: this sample starts a new sum |
| `0x08` | `STATUS` | R | bit 0 `DONE` (no sample/clear in flight, `RESULT` final), bit 1 `ERR` (any `ERR` bit set), `[31:16]` `COUNT` samples since clear (saturating) |
| `0x0C` | `RESULT` | R | 20-bit accumulator, sign-extended to 32 bits |
| `0x10` | `ERR` | R/W1C | sticky: bit 0 `ADDR` unmapped offset, bit 1 `ACCESS` write to read-only / read of write-only, bit 2 `STRB` partial write, bit 3 `SAMPLE` reserved bits set |
| `0x14` | `ID` | R | `0x4D414331` ("MAC1") |

Integrity rules, all implemented in hardware and tested:

* One accepted `SAMPLE` write produces exactly one `valid_i` pulse. The core accepts one
  sample per cycle, so back-to-back writes cannot overrun it.
* A `RESULT` read **waits (bus wait states) until the pipeline has drained**, so software can
  never read a partial sum. `STATUS.DONE` is there for polling as well.
* Every erroneous access gets SLVERR, sets an `ERR` bit and has **no other effect**: a rejected
  `SAMPLE` or `CTRL` write never reaches the core. Writing an unmasked negative activation
  (sign bits in the weight/reserved fields) is caught this way.
* `COUNT` is updated on the same clock edge as the accumulator. After a dot product the driver
  can confirm that exactly 25 samples were absorbed.
* Arithmetic is the original's: exact 20-bit product, **20-bit two's-complement wrap-around**
  accumulation (no saturation).

The UART (`rtl/uart_axil.sv`) is transmit-only 8N1. A `TXDATA` write is held with wait states
while the shifter is busy, so no character is lost. `SCRATCH` is a plain read/write register,
like the 16550's SCR. The firmware writes test markers and its exit code there for the
testbench.

## Firmware (`firmware/`)

| file | content |
|---|---|
| `start.S` | zero x1–x31, set `sp`, copy `.data` ROM→RAM, clear `.bss`, `call main`, write exit code, `ebreak` |
| `link.ld` | ROM/RAM memory regions, `.data` LMA in ROM, stack at the top of RAM |
| `soc.h` | memory map, MMIO macro, UART, `rdcycle` (CSR `0xC00`), testbench markers |
| `mac.h` | MAC register map and driver (`mac_init`, `mac_push`, `mac_result`, `mac_err`, …) |
| `main.c` | self-tests, software and accelerated convolution, comparison, report |

Run sequence: boot → memory/bus self-test (byte/halfword strobes, ROM write protection,
unmapped read) → MAC driver self-test (ID, signed extremes, zero activation, wrap-around, both
clear mechanisms, all four error types and W1C) → **5×5 valid convolution of a 28×28 feature
map (576 outputs, 14,400 MACs)** in software, then on the accelerator, each timed with
`rdcycle` → both compared with each other and with a golden reference generated by
`scripts/gen_conv_data.py` → `RESULT: PASS`/`FAIL`.

The test data is deterministic. It has about 36 % zero activations, fully zero windows, and
saturated ±2047/−2048 regions, so 157 of 576 outputs wrap 20 bits, plus the extreme weights
−128/+127. Software and hardware use identical operands and identical wrap semantics.

Build flags: `-march=rv32im_zicsr -mabi=ilp32 -O2 -ffreestanding -nostdlib`. The firmware also
needs `-fno-delete-null-pointer-checks`. Without it GCC treats the deliberate ROM read at
address 0 as undefined behaviour and replaces the rest of `main` with a trap. Seeing this in the
disassembly was a useful lesson in embedded C.

## Verification

Two self-checking testbenches, each covering what the other cannot:

| testbench | DUT | what it proves |
|---|---|---|
| `sim/tb_mac_axil.sv` | `mac_axil` alone, driven by a randomized AXI4-Lite master | register access; AW-first / W-first / same-cycle writes; B and R backpressure; a write queued behind a stalled B is performed exactly once; long AW/W gaps; back-to-back samples; `RESULT` interlock (read during busy pipeline); signed extremes, zero activations, wrap-around; every error case and W1C; `COUNT` saturation; ~74k transactions against a reference model |
| `sim/tb_soc.sv` | full `soc_top` running `build/firmware.hex` | CPU boot and firmware execution; memory accesses; all AXI traffic of a real program; software-vs-hardware convolution; exact numbers of SLVERR/DECERR responses; `rdcycle` equals simulated cycles; firmware cycle counts match the testbench's own window; exactly 25 MAC writes per `RESULT` read; MAC latency |

Both use `sim/axil_checker.sv`, a passive protocol checker (VALID held until READY with a stable
payload, no response without a request, no X on control or OKAY read data). `tb_soc` places it
on the CPU port and on all four slave ports. The full-system test runs in three
configurations: `fastmul` (default CPU), `slowmul` (iterative multiplier) and `memwait`
(pseudo-random wait states in ROM and RAM, which exercises backpressure through the CPU,
decoder and slaves).

To check that the testbench can fail, three bugs were injected into copies of the RTL: a write
performed while B was pending, a missing `RESULT` interlock, and a missing reserved-bit check.
`tb_mac_axil` reported each one.

## How to build and run

Tools: Icarus Verilog (12 or 13), a RISC-V GCC (`riscv64-unknown-elf-`), GNU make, Python 3,
Yosys (or `pip install yowasp-yosys`).

* **Ubuntu / CI:** `sudo apt install iverilog gcc-riscv64-unknown-elf make` and
  `pip install yowasp-yosys`.
* **Windows (no WSL):** the MSYS2 UCRT64 packages `mingw-w64-ucrt-x86_64-iverilog` and
  `mingw-w64-ucrt-x86_64-riscv64-unknown-elf-gcc` (installed with `pacman`, or extracted
  as-is), plus Git Bash, `make` and Python.

```bash
make fw                      # build/firmware.elf, .hex, .lst, .map
make sim                     # tb_mac_axil + tb_soc in 3 configurations (logs in build/)
make synth YOSYS=yowasp-yosys  # build/synth_summary.md
make all                     # sim + synth
```

`make sim` fails unless every log ends with `SIM RESULT: PASS`. A single full-SoC run takes a
few minutes in Icarus. `vvp -n build/tb_soc_fastmul.vvp +firmware=build/firmware.hex +vcd`
writes a waveform. GitHub Actions runs the same targets on every push.

## Results

All numbers are from the simulation logs in [`results/`](results/); see [RESULTS.md](RESULTS.md).

* **All tests pass.** In each of the three SoC configurations the software, accelerator and
  Python golden-model outputs agree on all 576 outputs, including 157 that wrap 20 bits.
* **5×5 convolution cycles** (14,400 MACs, `rdcycle`, cross-checked by the testbench):

  | CPU | software | accelerator | software ÷ accelerator |
  |---|---:|---:|---:|
  | fast multiplier | 713,542 | 783,716 | 0.91 |
  | iterative multiplier | 1,203,142 | 783,716 | 1.54 |
  | fast multiplier + memory wait states | 802,789 | 882,548 | 0.91 |

  (GCC 16.1. With CI's GCC 13.2 the software cycle count is identical but the accelerator
  loop takes 841,338 cycles, a ratio of 0.85 / 1.43. That loop is limited by CPU code.)

* **The accelerator only pays off when the CPU multiplier is slow.** Each accelerated MAC
  needs a load, packing and an MMIO store (9 instructions, ~54 cycles) versus 8 instructions
  for `lh/lb/mul/add` in software. Communication, not arithmetic, dominates: the MAC core is
  busy 1.8 % of the time.
* **Bus traffic:** 210,642 transactions for the accelerated convolution (14,400 MAC writes,
  576 `RESULT` reads) vs 182,134 for software. Each transaction takes 2 cycles. MAC latency is
  3 cycles from write to accumulated result.
* **Synthesis (Yosys):** SoC logic without memories 20,019 generic cells (2,315 sequential).
  7-series estimate 1,997 LUT, 1,218 FF, 5 DSP48E1. The MAC peripheral alone is 192 LUT,
  150 FF, 1 DSP48E1.

## Limitations

* Simulation only. No FPGA bitstream, no board, no silicon. The 7-series numbers are a Yosys
  mapping estimate without place and route or timing.
* The memories are behavioural arrays. They are synthesised as black boxes and would be
  SRAM macros or block RAM. The ROM image is loaded by the testbench (`$readmemh`).
* PicoRV32 is a small multi-cycle core (no caches, one bus transaction at a time). On a
  pipelined or cached CPU the software baseline would be faster, so the accelerator would need
  a better interface to pay off (see Results).
* The MAC interface is programmed I/O, one 32-bit write per MAC. There is no DMA, no
  weight buffer and no interrupt. This was a deliberate minimal choice, and its cost is what
  the measurements show.
* The 20-bit accumulator wraps like the original design. It does not saturate.
* No timing closure or power numbers for the SoC (the MAC's ASIC PPA is in
  cnn-mac-asic-hardening).

## Repository layout

```
rtl/        soc_top, axil_decoder, axil_slave, axil_mem, mac_axil, uart_axil, mac_opiso (reused),
            third_party/picorv32.v
firmware/   start.S, link.ld, soc.h, mac.h, main.c
sim/        tb_soc.sv, tb_mac_axil.sv, axil_checker.sv
scripts/    gen_conv_data.py (test data + golden model), synth.ys, synth_report.py
results/    simulation and synthesis logs from the runs reported in RESULTS.md
```

## Licence

MIT (see [LICENSE](LICENSE)). `rtl/mac_opiso.sv` is from cnn-mac-asic-hardening (MIT), with
arithmetic derived from MNIST-CNN-Zynq-Energy-Efficient-Accelerator (MIT, © 2024 Hoooo).
PicoRV32 is © Claire Xenia Wolf under the ISC licence in its file header.
