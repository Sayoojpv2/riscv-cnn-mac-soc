# riscv-cnn-mac-soc: firmware build, simulation and synthesis.
#   make sim     peripheral test + full-SoC test in three configurations
#   make synth   Yosys synthesis reports
#   make all     both
CROSS    ?= riscv64-unknown-elf-
IVERILOG ?= iverilog
VVP      ?= vvp
YOSYS    ?= yosys
PYTHON   ?= $(if $(shell python3 -c "import sys" 2>/dev/null && echo ok),python3,python)

B       := build
RTL     := rtl/third_party/picorv32.v rtl/axil_slave.sv rtl/axil_decoder.sv rtl/axil_mem.sv \
           rtl/mac_opiso.sv rtl/mac_axil.sv rtl/uart_axil.sv rtl/soc_top.sv
IVFLAGS := -g2012 -Wall -Wno-timescale -Wno-sensitivity-entire-vector
CFLAGS  := -march=rv32im_zicsr -mabi=ilp32 -O2 -ffreestanding -nostdlib -fno-builtin \
           -fno-tree-loop-distribute-patterns -fno-delete-null-pointer-checks \
           -Wall -Wextra -Ifirmware -I$(B)

# full-SoC configurations: CPU multiplier and memory wait states
SOC_CFGS    := fastmul slowmul memwait
CFG_fastmul := -Ptb_soc.FAST_MUL=1 -Ptb_soc.MEM_WAIT=0
CFG_slowmul := -Ptb_soc.FAST_MUL=0 -Ptb_soc.MEM_WAIT=0
CFG_memwait := -Ptb_soc.FAST_MUL=1 -Ptb_soc.MEM_WAIT=1

.PHONY: all fw sim synth clean
all: sim synth
fw: $(B)/firmware.hex
sim: $(B)/tb_mac_axil.log $(foreach c,$(SOC_CFGS),$(B)/tb_soc_$(c).log)
synth: $(B)/synth.log

$(B):
	mkdir -p $(B)

# ---------------- firmware ----------------
$(B)/conv_data.h: scripts/gen_conv_data.py | $(B)
	$(PYTHON) $< $@

$(B)/firmware.elf: firmware/start.S firmware/main.c firmware/soc.h firmware/mac.h firmware/link.ld $(B)/conv_data.h
	$(CROSS)gcc $(CFLAGS) -T firmware/link.ld -Wl,-Map,$(B)/firmware.map -o $@ firmware/start.S firmware/main.c
	$(CROSS)size $@

$(B)/firmware.hex: $(B)/firmware.elf
	$(CROSS)objcopy -O binary --pad-to 0x4000 --gap-fill 0 $< $(B)/firmware.bin
	od -An -v -tx4 -w4 $(B)/firmware.bin > $@
	$(CROSS)objdump -d $< > $(B)/firmware.lst

# ---------------- simulation ----------------
$(B)/tb_mac_axil.log: sim/tb_mac_axil.sv sim/axil_checker.sv rtl/mac_axil.sv rtl/axil_slave.sv rtl/mac_opiso.sv | $(B)
	$(IVERILOG) $(IVFLAGS) -o $(B)/tb_mac_axil.vvp $^
	$(VVP) -n $(B)/tb_mac_axil.vvp > $@.tmp; cat $@.tmp
	@grep -q "SIM RESULT: PASS" $@.tmp && mv $@.tmp $@

$(B)/tb_soc_%.log: $(B)/firmware.hex sim/tb_soc.sv sim/axil_checker.sv $(RTL)
	$(IVERILOG) $(IVFLAGS) $(CFG_$*) -o $(B)/tb_soc_$*.vvp sim/tb_soc.sv sim/axil_checker.sv $(RTL)
	$(VVP) -n $(B)/tb_soc_$*.vvp +firmware=$(B)/firmware.hex > $@.tmp; cat $@.tmp
	@grep -q "SIM RESULT: PASS" $@.tmp && mv $@.tmp $@

# ---------------- synthesis ----------------
$(B)/synth.log: scripts/synth.ys $(RTL) | $(B)
	$(YOSYS) -q -l $@ -s scripts/synth.ys
	$(PYTHON) scripts/synth_report.py $(B)/synth_generic.json $(B)/synth_xc7.json $(B)/synth_xc7_mac.json | tee $(B)/synth_summary.md

clean:
	rm -rf $(B)
