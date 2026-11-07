### Generic gates (Yosys `synth`, hierarchy kept; cells local to each module)

| module | cells | sequential | combinational | instantiates |
|---|---:|---:|---:|---|
| picorv32 | 8834 | 1629 | 7205 | picorv32_pcpi_div x1, picorv32_pcpi_fast_mul x1 |
| picorv32_pcpi_fast_mul | 7609 | 133 | 7476 | - |
| picorv32_pcpi_div | 1438 | 200 | 1238 | - |
| mac_opiso | 843 | 67 | 776 | - |
| axil_decoder | 414 | 11 | 403 | - |
| mac_axil | 282 | 24 | 258 | axil_slave x1, mac_opiso x1 |
| uart_axil | 202 | 49 | 153 | axil_slave x1 |
| axil_slave | 187 | 99 | 88 | - |
| picorv32_axi_adapter | 23 | 4 | 19 | - |
| soc_top | 0 | 0 | 0 | axil_mem x2, picorv32_axi x1, axil_decoder x1, uart_axil x1, mac_axil x1 |
| picorv32_axi | 0 | 0 | 0 | picorv32 x1, picorv32_axi_adapter x1 |
| **soc_top total** (excl. ROM/RAM arrays) | **20019** | **2315** | **17704** | |

### AMD 7-series (Zynq-7000 fabric) estimate (Yosys `synth_xilinx -family xc7`, no place & route)

| design | LUT | FF | CARRY4 | DSP48E1 | LUTRAM | SRL | MUXF7/8 |
|---|---:|---:|---:|---:|---:|---:|---:|
| soc_top (CPU + bus + MAC + UART) | 1997 | 1218 | 162 | 5 | 12 | 0 | 0 |
| mac_axil (MAC peripheral only) | 192 | 150 | 9 | 1 | 0 | 0 | 0 |

