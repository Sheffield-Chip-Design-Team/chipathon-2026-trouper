# fpga-emul/Makefile
# Simulation (Verilator via SGE) and Vivado build targets for the DSP chain FPGA emulation.
#
# fpga_dsp_wrap.v instantiates trouper_top.v directly (spi_slave + reg_bank
# included) — the host-SPI register interface is exercised through the
# wrapper's host_cs/spi_sck/spi_mosi/spi_miso ports. On real hardware these
# are wired to a dedicated axi_quad_spi core so MicroBlaze firmware drives
# them exactly as the real RPi host would (see vivado/create_project.tcl).
#
# SGE targets (primary): submit Verilator jobs to the homelab SGE cluster.
#   make sge_sim_spi_reg     — SPI register pass-through smoke test
#   make sge_sim_all         — same
#
# Local Verilator targets (for use inside the chipathon26 container directly):
#   make sim_spi_reg / sim_psram / sim_all
#
# After submitting an SGE job, poll completion with:
#   curl -s http://nas.home:4783/api/jobs/<ID>
# Read output from:
#   /srv/eda/logs/timothyjabez/job-<ID>.o

HLAB_SGE_URL  = http://nas.home:4783
NFS_DESIGN    = /srv/eda/designs/timothyjabez/lora-mimo

VERILATOR   = verilator
VFLAGS      = --binary --timing -Wall --Wno-UNUSED --Wno-DECLFILENAME \
              --Wno-WIDTHTRUNC --Wno-WIDTHEXPAND --Wno-BLKSEQ \
              --Wno-SYNCASYNCNET --Wno-PINCONNECTEMPTY \
              --Wno-UNOPTFLAT -sv

RTL         = rtl
ASIC_RTL    = ../src

# All ASIC RTL modules needed by fpga_dsp_wrap (trouper_top.v + its subblocks).
# src/ is the definitive ASIC source tree (rtl-test/rtl is the
# working/synthesis-and-sim copy).
ASIC_SRCS   = $(ASIC_RTL)/top/trouper_top.v             \
              $(ASIC_RTL)/decimator/sd_decimator_poly.v \
              $(ASIC_RTL)/frontend/dc_removal.v        \
              $(ASIC_RTL)/frontend/sc_detector.v       \
              $(ASIC_RTL)/control/psram_buf_ctrl.v     \
              $(ASIC_RTL)/combiner/training_acc.v      \
              $(ASIC_RTL)/control/packet_ctrl_fsm.v    \
              $(ASIC_RTL)/combiner/mrc_combiner.v      \
              $(ASIC_RTL)/remod/sd_remod.v             \
              $(ASIC_RTL)/control/spi_slave.v          \
              $(ASIC_RTL)/control/reg_bank.v

FPGA_SRCS   = $(RTL)/sync_fifo.v    \
              $(RTL)/psram_model.v  \
              $(RTL)/axi_inj_ctrl.v \
              $(RTL)/fpga_dsp_wrap.v

# ============================================================================
# SGE simulation targets (submit to homelab cluster)
# Scripts in sge/ run inside the chipathon26 container on the NFS-mounted tree.
# ============================================================================

.PHONY: sge_sim_spi_reg sge_sim_all \
        sim_spi_reg sim_all sim_psram sim_clksync clean vivado_project vivado_synth \
        test_fw run_test_fw eth_fw run_eth_fw

sge_sim_spi_reg:
	HLAB_SGE_URL=$(HLAB_SGE_URL) hqsub \
	    --name fpga-sim-spi-reg \
	    --cpus 4 \
	    --mem 8G \
	    $(NFS_DESIGN)/fpga-emul/sge/sim_spi_reg.sh

sge_sim_all: sge_sim_spi_reg

# ============================================================================
# Local Verilator targets (run inside chipathon26 container)
# ============================================================================

# SPI register pass-through smoke test (wrapper wiring only — the deep
# spi_slave/reg_bank/GRP-arbiter correctness tests live in rtl-test/tb/
# against trouper_top.v directly)
sim_spi_reg: obj_dir_spi_reg/Vtb_fpga_spi_reg
	$<

obj_dir_spi_reg/Vtb_fpga_spi_reg: tb/tb_fpga_spi_reg.v $(FPGA_SRCS) $(ASIC_SRCS)
	$(VERILATOR) $(VFLAGS) --Wno-PROCASSINIT --Mdir obj_dir_spi_reg \
	    --top-module tb_fpga_spi_reg $^

sim_all: sim_spi_reg

# PSRAM model cosim: psram_buf_ctrl ⇄ psram_model, checks the SC delay path
sim_psram: obj_dir_psram/Vtb_psram_model
	$<

obj_dir_psram/Vtb_psram_model: tb/tb_psram_model.v $(RTL)/psram_model.v $(ASIC_RTL)/control/psram_buf_ctrl.v
	$(VERILATOR) $(VFLAGS) --Wno-PROCASSINIT --Mdir obj_dir_psram \
	    --top-module tb_psram_model $^

# CLK_OUT phase-lock monitor: self-checking (locked vs unlocked) via Vivado
# xsim (no verilator/iverilog dependency). Standalone — axi_clk_sync_mon.v only.
XSIM_BIN = /home/timothyjabez/tools/Xilinx/2025.2/Vivado/bin
sim_clksync:
	rm -rf xsim_clksync && mkdir xsim_clksync
	cd xsim_clksync && \
	  $(XSIM_BIN)/xvlog ../rtl/axi_clk_sync_mon.v ../tb/tb_clk_sync_mon.v && \
	  $(XSIM_BIN)/xelab tb_clk_sync_mon -s tb_run --timescale 1ns/1ps --debug off && \
	  $(XSIM_BIN)/xsim tb_run -R

# ============================================================================
# Vivado project
# ============================================================================
VIVADO = /home/timothyjabez/tools/Xilinx/2025.2/Vivado/bin/vivado

vivado_project:
	$(VIVADO) -mode batch -source vivado/create_project.tcl 2>&1 | tee vivado_create.log

vivado_synth:
	$(VIVADO) -mode batch -source vivado/run_synth.tcl 2>&1 | tee vivado_synth.log

# ============================================================================
# Bare-metal MicroBlaze test firmware (sw/test_fw.c)
# Built with mb-gcc + crt0.S + lscript.ld — no Vitis BSP / -lxil dependency.
# Produces a known-good ELF for `xsdb vivado/run_test_fw.tcl`.
# ============================================================================
MB_BIN   = /home/timothyjabez/tools/Xilinx/2025.2/Vitis/gnu/microblaze/lin/bin
MB_GCC   = $(MB_BIN)/mb-gcc
XSDB     = /home/timothyjabez/tools/Xilinx/2025.2/Vivado/bin/xsdb
MB_FLAGS = -mlittle-endian -O2 -G0 -nostdlib -nostartfiles -ffreestanding
SW       = sw

test_fw: $(SW)/test_fw.elf

$(SW)/test_fw.elf: $(SW)/crt0.S $(SW)/test_fw.c $(SW)/lscript.ld
	$(MB_GCC) $(MB_FLAGS) -Wl,-T,$(SW)/lscript.ld -Wl,-Map,$(SW)/test_fw.map \
	    -o $@ $(SW)/crt0.S $(SW)/test_fw.c \
	    `$(MB_GCC) -mlittle-endian -print-libgcc-file-name`

# Program bitstream + download/run the bare-metal firmware over JTAG (xsdb)
run_test_fw: $(SW)/test_fw.elf
	$(XSDB) vivado/run_test_fw.tcl

# ============================================================================
# Full Ethernet/SPI firmware (sw/main.c) — Vitis BSP build from the XSA.
# Vitis 2025.2 xsct needs an X display, so the BSP generation runs under Xvfb.
# We then link main.c directly against libxil to avoid the Vitis app-build's
# missing -L for the BSP lib dir.
# ============================================================================
XSCT     = /home/timothyjabez/tools/Xilinx/2025.2/Vitis/bin/xsct
BSP_DIR  = $(SW)/vitis_ws/arty_dsp_emul/export/arty_dsp_emul/sw/arty_dsp_emul/standalone_domain
ETH_LD   = $(SW)/vitis_ws/lora_mimo_fw/src/lscript.ld
ETH_FLAGS = -Wall -O2 -g -mlittle-endian -mcpu=v11.0 \
            -mno-xl-soft-mul -mno-xl-soft-div -mxl-barrel-shift -Wl,--no-relax \
            -ffunction-sections -fdata-sections
MRC_BENCH_SELF_TRIGGER ?= 0
ETH_FLAGS += -DMRC_BENCH_SELF_TRIGGER=$(MRC_BENCH_SELF_TRIGGER)

eth_fw: $(SW)/lora_mimo_fw.elf

# BSP (libxil.a + headers) generated from the XSA by xsct under Xvfb.
$(BSP_DIR)/bsplib/lib/libxil.a: $(SW)/arty_dsp_emul.xsa $(SW)/build_fw.tcl
	cd $(SW) && xvfb-run -a $(XSCT) build_fw.tcl

$(SW)/lora_mimo_fw.elf: $(SW)/main.c $(BSP_DIR)/bsplib/lib/libxil.a
	$(MB_GCC) $(ETH_FLAGS) -I$(BSP_DIR)/bspinclude/include \
	    -Wl,-T -Wl,$(ETH_LD) -Wl,--gc-sections -L$(BSP_DIR)/bsplib/lib \
	    -o $@ $(SW)/main.c -Wl,--start-group,-lxil,-lgcc,-lc,--end-group

# Program bitstream + download/run the full Ethernet firmware over JTAG (xsdb)
run_eth_fw: $(SW)/lora_mimo_fw.elf
	$(XSDB) vivado/run_eth_fw.tcl

# ============================================================================
# Clean
# ============================================================================
clean:
	rm -rf obj_dir_spi_reg obj_dir_psram *.vcd
	rm -f $(SW)/test_fw.elf $(SW)/test_fw.map
	rm -f $(SW)/lora_mimo_fw.elf
