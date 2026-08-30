# Foundry-I/O-cell smoke test. The model path is supplied by chipathon26's
# pinned GF180 PDK; it is intentionally not copied into this repository.

DESIGN_ROOT ?= /foss/designs/lora-mimo
HDL = $(DESIGN_ROOT)/cocotb/hdl
IO_MODEL ?= /foss/pdks/ciel/gf180mcu/versions/7b70722e33c03fcb5dabcf4d479fb0822d9251c9/gf180mcuD/libs.ref/gf180mcu_fd_io/verilog/gf180mcu_fd_io.v

VERILOG_SOURCES = $(IO_MODEL) $(HDL)/tb_gf180_io_control.v

.PHONY: all clean
all:
	iverilog -g2012 -s tb_gf180_io_control -o /tmp/tb_gf180_io_control.vvp $(VERILOG_SOURCES)
	vvp /tmp/tb_gf180_io_control.vvp

clean:
	rm -f /tmp/tb_gf180_io_control.vvp
