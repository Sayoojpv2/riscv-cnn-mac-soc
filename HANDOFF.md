# HANDOFF — riscv-cnn-mac-soc

Last updated: 2026-11-07 (session 1). Weekly usage at last check: 11 % used.

## Objective
Simulated RISC-V SoC (PicoRV32 RV32IM, AXI4-Lite) running bare-metal C firmware that drives
the operand-isolated CNN MAC from `Sayoojpv2/cnn-mac-asic-hardening` (reused unchanged) as a
memory-mapped peripheral; software vs accelerator 5x5 convolution measured in cycles.

## State: implementation, verification, synthesis and documentation DONE
- RTL: `soc_top`, `axil_decoder`, `axil_slave`, `axil_mem`, `mac_axil`, `uart_axil`,
  `mac_opiso` (reused), `third_party/picorv32.v` (official, commit ef203c2).
- Firmware: `start.S`, `link.ld`, `soc.h`, `mac.h`, `main.c`; test data/golden model from
  `scripts/gen_conv_data.py`.
- Local results (all PASS, logs in `results/`, numbers in RESULTS.md): `tb_mac_axil`; `tb_soc`
  in fastmul / slowmul / memwait configurations. SW vs HW cycles 713,542 / 783,716 (fast mul),
  1,203,142 / 783,716 (iterative mul).
- Yosys: 20,019 generic cells (memories excluded); xc7 1,997 LUT / 1,218 FF / 5 DSP.

## Problems found and fixed during bring-up (worth remembering)
- GCC replaced `main` with a trap after the deliberate ROM read at address 0 (null-pointer UB)
  -> `-fno-delete-null-pointer-checks`.
- X on AWREADY/ARREADY after reset (PicoRV32 does not reset `mem_addr`) -> READY gated with VALID.
- X read data when callee-saved registers were restored (register file not reset) -> start.S
  zeroes x1-x31; testbench fills RAM with random power-up values instead of X.

## Local tools (Windows, no WSL)
Extracted from MSYS2 UCRT64 packages (no MSYS2 install) into `C:\Users\acer\tools\msys2-eda`:
Icarus Verilog 13.0, riscv64-unknown-elf GCC 16.1 / binutils 2.47 (newlib not installed; the
firmware uses `-nostdlib`). Yosys 0.70 via pip `yowasp-yosys`
(`C:\Users\acer\AppData\Roaming\Python\Python314\Scripts`). The fast MSYS2 mirror here was
mirrors.tuna.tsinghua.edu.cn; repo.msys2.org was very slow.
```
export PATH="/c/Users/acer/tools/msys2-eda/ucrt64/bin:/c/Users/acer/AppData/Roaming/Python/Python314/Scripts:$PATH"
make -j4 sim PYTHON=python          # ~6 min wall time for all four simulations
make synth YOSYS=yowasp-yosys PYTHON=python
```

## GitHub
`Sayoojpv2/riscv-cnn-mac-soc`: created private, pushed, CI run 42359714867 passed (Icarus 12,
GCC 13.2), then made public. CI accelerator cycles differ from local GCC 16.1 (see RESULTS.md).

## Possible next steps (not started)
- Lower-overhead accelerator interface (weights stored in the peripheral, packed activations,
  or DMA) and re-measure; the current results show programmed I/O is the bottleneck.
- Verilator lint in CI.
