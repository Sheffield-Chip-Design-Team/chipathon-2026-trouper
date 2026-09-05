# rtl-test/Makefile — simulation targets (Verilator primary, iverilog fallback)

VERILATOR = verilator
VFLAGS    = --binary --timing -Wall --Wno-UNUSED --Wno-DECLFILENAME \
            --Wno-WIDTHTRUNC --Wno-WIDTHEXPAND --Wno-BLKSEQ \
            --Wno-SYNCASYNCNET --Wno-PINCONNECTEMPTY -sv

IVERILOG  = iverilog
VVP       = vvp
IFLAGS    = -g2012

# Source files for the DSP chain (no PicoRV32)
RTL = rtl
TB  = tb
SRC = ../src

# DSP_SRCS pulls the actively-maintained blocks straight from src/ (the source
# of truth) rather than the rtl-test/rtl/ copies, which drift silently and
# previously let regressions here pass against different hardware than
# tapeout source (dc_removal/sc_detector/training_acc/mrc_combiner/sd_remod
# all have current src/ equivalents; frontend_buf_ctrl.v does not -- it was
# replaced architecturally by psram_buf_ctrl.v and only survives in the
# legacy-standalone targets below that still instantiate it directly).
DSP_SRCS  = $(SRC)/frontend/dc_removal.v \
            $(SRC)/frontend/sc_detector.v $(SRC)/combiner/training_acc.v \
            $(SRC)/combiner/mrc_combiner.v $(SRC)/remod/sd_remod.v
# Legacy-standalone targets (tb_dsp_chain_real*.v, tb_dsp_chain_loopback_probe.v)
# instantiate frontend_buf_ctrl.v directly; it has no current src/ replacement
# (superseded by psram_buf_ctrl.v, a different interface/architecture), so it
# stays sourced from the rtl-test/rtl/ legacy copy.
DSP_SRCS_SD = $(DSP_SRCS) $(RTL)/sd_decimator_cic_only.v $(RTL)/frontend_buf_ctrl.v

# -----------------------------------------------------------------------
# DSP chain end-to-end testbench (Verilator)
# -----------------------------------------------------------------------
.PHONY: sim_dsp_chain sim_dsp_chain_iverilog clean

sim_dsp_chain: obj_dir_dsp_chain/Vtb_dsp_chain
	$<

obj_dir_dsp_chain/Vtb_dsp_chain: $(TB)/tb_dsp_chain.v $(DSP_SRCS)
	$(VERILATOR) $(VFLAGS) --Mdir obj_dir_dsp_chain --top-module tb_dsp_chain $^

# iverilog fallback
sim_dsp_chain_iverilog: tb_dsp_chain.vvp
	$(VVP) $<

tb_dsp_chain.vvp: $(TB)/tb_dsp_chain.v $(DSP_SRCS)
	$(IVERILOG) $(IFLAGS) -o $@ $^

# -----------------------------------------------------------------------
# Real-capture DSP chain testbench (Verilator)
# -----------------------------------------------------------------------
.PHONY: sim_dsp_chain_real sim_dsp_chain_loopback_probe \
	sim_dsp_chain_real_probe sim_dsp_chain_real_probe_osr256 \
	sim_remod_decim_const

sim_dsp_chain_real: obj_dir_dsp_chain_real/Vtb_dsp_chain_real
	$<

obj_dir_dsp_chain_real/Vtb_dsp_chain_real: $(TB)/tb_dsp_chain_real.v $(DSP_SRCS)
	$(VERILATOR) $(VFLAGS) --Mdir obj_dir_dsp_chain_real \
	    --top-module tb_dsp_chain_real $^

sim_dsp_chain_loopback_probe: obj_dir_loopback_probe/Vtb_dsp_chain_real
	$<

obj_dir_loopback_probe/Vtb_dsp_chain_real: $(TB)/tb_dsp_chain_loopback_probe.v $(DSP_SRCS_SD)
	$(VERILATOR) $(VFLAGS) --Mdir obj_dir_loopback_probe \
	    --top-module tb_dsp_chain_real $^

sim_dsp_chain_real_probe: obj_dir_dsp_chain_real_probe/Vtb_dsp_chain_real
	$<

obj_dir_dsp_chain_real_probe/Vtb_dsp_chain_real: $(TB)/tb_dsp_chain_real_probe.v $(DSP_SRCS_SD)
	$(VERILATOR) $(VFLAGS) --Mdir obj_dir_dsp_chain_real_probe \
	    --top-module tb_dsp_chain_real $^

sim_dsp_chain_real_probe_osr256: obj_dir_dsp_chain_real_probe_osr256/Vtb_dsp_chain_real
	$<

obj_dir_dsp_chain_real_probe_osr256/Vtb_dsp_chain_real: $(TB)/tb_dsp_chain_real_probe_osr256.v $(DSP_SRCS_SD)
	$(VERILATOR) $(VFLAGS) --Mdir obj_dir_dsp_chain_real_probe_osr256 \
	    --top-module tb_dsp_chain_real $^

sim_remod_decim_const: obj_dir_const/Vtb_remod_decim_const
	$<

obj_dir_const/Vtb_remod_decim_const: $(TB)/tb_remod_decim_const.v $(SRC)/remod/sd_remod.v $(RTL)/sd_decimator_cic_only.v
	$(VERILATOR) $(VFLAGS) --Mdir obj_dir_const \
	    --top-module tb_remod_decim_const $^

# -----------------------------------------------------------------------
# Energy / noise-floor testbench (existing)
# -----------------------------------------------------------------------
DSP_SRCS2 = $(RTL)/noise_est.v

.PHONY: sim_dsp

sim_dsp: tb_dsp.vvp
	$(VVP) $<

tb_dsp.vvp: $(TB)/tb_dsp.v $(DSP_SRCS2)
	$(IVERILOG) $(IFLAGS) -o $@ $^

# -----------------------------------------------------------------------
# SQNR testbench (existing)
# -----------------------------------------------------------------------
.PHONY: sim_sqnr

sim_sqnr: tb_sqnr.vvp
	$(VVP) $<

tb_sqnr.vvp: $(TB)/tb_sqnr.v $(RTL)/sd_decimator_cic_only.v
	$(IVERILOG) $(IFLAGS) -o $@ $^

# -----------------------------------------------------------------------

# -----------------------------------------------------------------------
# MRC combiner unit testbench (Verilator)
# -----------------------------------------------------------------------
.PHONY: sim_mrc_combiner

sim_mrc_combiner: obj_dir_mrc_combiner/Vtb_mrc_combiner
	$<

obj_dir_mrc_combiner/Vtb_mrc_combiner: $(TB)/tb_mrc_combiner.v $(SRC)/combiner/mrc_combiner.v
	$(VERILATOR) $(VFLAGS) --Mdir obj_dir_mrc_combiner \
	    --top-module tb_mrc_combiner $^

# -----------------------------------------------------------------------
# MRC firmware precision testbench (Verilator)
# 5 channel scenarios; verifies Q0.7 weight quantisation vs float-optimal
# -----------------------------------------------------------------------
.PHONY: sim_mrc_fw_precision

sim_mrc_fw_precision: obj_dir_mrc_fw_precision/Vtb_mrc_fw_precision
	$<

obj_dir_mrc_fw_precision/Vtb_mrc_fw_precision: $(TB)/tb_mrc_fw_precision.v $(SRC)/combiner/mrc_combiner.v
	$(VERILATOR) $(VFLAGS) --Mdir obj_dir_mrc_fw_precision \
	    --top-module tb_mrc_fw_precision $^

# -----------------------------------------------------------------------
# MRC randomised precision testbench (Verilator)
# 100 random A_k scenarios; +seed=<N> plusarg overrides default seed
# -----------------------------------------------------------------------
.PHONY: sim_mrc_fw_rand

sim_mrc_fw_rand: obj_dir_mrc_fw_rand/Vtb_mrc_fw_rand
	$< +seed=42

obj_dir_mrc_fw_rand/Vtb_mrc_fw_rand: $(TB)/tb_mrc_fw_rand.v $(SRC)/combiner/mrc_combiner.v
	$(VERILATOR) $(VFLAGS) --Mdir obj_dir_mrc_fw_rand \
	    --top-module tb_mrc_fw_rand $^

# -----------------------------------------------------------------------
# Randomised DSP chain end-to-end testbench (Verilator)
# 20 random A_k/phase cases; +seed=<N> plusarg overrides default seed
# -----------------------------------------------------------------------
DSP_SRCS_RAND = $(SRC)/frontend/dc_removal.v $(SRC)/frontend/sc_detector.v \
                $(SRC)/combiner/training_acc.v $(SRC)/combiner/mrc_combiner.v $(SRC)/remod/sd_remod.v

.PHONY: sim_dsp_chain_rand

sim_dsp_chain_rand: obj_dir_dsp_chain_rand/Vtb_dsp_chain_rand
	$< +seed=42

obj_dir_dsp_chain_rand/Vtb_dsp_chain_rand: $(TB)/tb_dsp_chain_rand.v $(DSP_SRCS_RAND)
	$(VERILATOR) $(VFLAGS) --Mdir obj_dir_dsp_chain_rand \
	    --top-module tb_dsp_chain_rand $^

.PHONY: sim_dsp_chain_sf

sim_dsp_chain_sf: obj_dir_dsp_chain_sf/Vtb_dsp_chain_sf
	$< +seed=42

obj_dir_dsp_chain_sf/Vtb_dsp_chain_sf: $(TB)/tb_dsp_chain_sf.v $(DSP_SRCS_RAND)
	$(VERILATOR) $(VFLAGS) --Mdir obj_dir_dsp_chain_sf \
	    --top-module tb_dsp_chain_sf $^

# -----------------------------------------------------------------------
# sd_remod AC sine self-check (iverilog — uses $sin/$sqrt system functions)
# PASS: correlation > 0.80 (CIFF tuned); FAIL: broken/unity coefficients
# -----------------------------------------------------------------------
.PHONY: sim_sd_remod

sim_sd_remod: tb_sd_remod.vvp
	$(VVP) $<

tb_sd_remod.vvp: $(TB)/tb_sd_remod.v $(SRC)/remod/sd_remod.v
	$(IVERILOG) $(IFLAGS) -o $@ $^

# -----------------------------------------------------------------------
# sd_remod vs sd_remod_multiplierless bit-exact equivalence check (iverilog)
# PASS: 0 mismatches across directed extremes + dense random + paced random.
# -----------------------------------------------------------------------
.PHONY: sim_sd_remod_multiplierless_equiv

sim_sd_remod_multiplierless_equiv: tb_sd_remod_multiplierless_equiv.vvp
	$(VVP) $<

tb_sd_remod_multiplierless_equiv.vvp: $(TB)/tb_sd_remod_multiplierless_equiv.v \
                                       $(SRC)/remod/sd_remod.v \
                                       $(RTL)/sd_remod_multiplierless.v
	$(IVERILOG) $(IFLAGS) -o $@ $^

# -----------------------------------------------------------------------
# CIC-3 droop equalizer testbench (iverilog)
# Drives 1st-order ΣΔ encoded tones at 31.25 kHz and 50 kHz, verifies
# amplitude ratio > 0.97 after the 2-tap correction.
# Without correction: 50 kHz gives ratio 0.82 — FAIL.
# -----------------------------------------------------------------------
.PHONY: sim_cic_droop_eq

sim_cic_droop_eq: tb_cic_droop_eq.vvp
	$(VVP) $<

tb_cic_droop_eq.vvp: $(TB)/tb_cic_droop_eq.v $(RTL)/sd_decimator_cic_only.v
	$(IVERILOG) $(IFLAGS) -o $@ $^

# -----------------------------------------------------------------------
# Side-by-side CIC_ONLY vs TDM8 comparison (iverilog → Python DFT)
# Streams IQ samples to stdout; pipe into compare_decimators.py.
# -----------------------------------------------------------------------
.PHONY: sim_compare_decimators

sim_compare_decimators: tb_compare_decimators.vvp
	$(VVP) $< | python3 ../sim/tests/compare_decimators.py

tb_compare_decimators.vvp: $(TB)/tb_compare_decimators.v \
                            $(RTL)/sd_decimator_cic_only.v \
                            $(RTL)/sd_decimator_cic_tdm8.v
	$(IVERILOG) $(IFLAGS) -o $@ $^

# -----------------------------------------------------------------------
# trouper_top integration testbench (iverilog)
# Exercises the full signal path: SDM IQ → decimator → PSRAM SC delay →
# sc_detector → training_acc → MRC weights (via SPI) → mrc_combiner → sd_remod.
#
# SUPERSEDED: trouper_top.v itself has drifted 400+ diff lines from
# src/top/trouper_top.v (Grouper-boundary removal, BRINGUP_SRC, pin/port
# changes since), and packet_ctrl_fsm.v/psram_buf_ctrl.v/reg_bank.v below
# have also diverged -- these targets test an architecture that no longer
# matches tapeout source and are NOT safe to repoint blindly (port interfaces
# changed). cocotb/ is the canonical, current integration coverage for
# trouper_top (see [[project_bypass_e2e_closed]]) -- use sim_trouper_cocotb
# or the cocotb/ suites directly, not these targets, for real regression
# signal. Left as-is rather than force-repointed; a real fix here means
# updating tb_trouper_top.v etc. to the current port list, not just paths.
# -----------------------------------------------------------------------
TROUPER_TOP_SRCS = \
    $(RTL)/trouper_top.v \
    $(RTL)/sd_decimator_poly.v \
    $(RTL)/dc_removal.v \
    $(RTL)/sc_detector.v \
    $(RTL)/training_acc.v \
    $(RTL)/packet_ctrl_fsm.v \
    $(RTL)/psram_buf_ctrl.v \
    $(RTL)/mrc_combiner.v \
    $(RTL)/sd_remod.v \
    $(RTL)/spi_slave.v \
    $(RTL)/reg_bank.v \
    ../fpga-emul/rtl/psram_model.v

.PHONY: sim_trouper_top

sim_trouper_top: tb_trouper_top.vvp
	$(VVP) $<

tb_trouper_top.vvp: $(TB)/tb_trouper_top.v $(TROUPER_TOP_SRCS)
	$(IVERILOG) $(IFLAGS) -o $@ $^

# Directed two-packet test: sc_lock re-arm + IRQ edge-set (Open Risks #2/#3).
.PHONY: sim_trouper_two_packet

sim_trouper_two_packet: tb_trouper_two_packet.vvp
	$(VVP) $<

tb_trouper_two_packet.vvp: $(TB)/tb_trouper_two_packet.v $(TROUPER_TOP_SRCS)
	$(IVERILOG) $(IFLAGS) -o $@ $^

# SPI register-map and GRP/SPI arbitration benches. These had NO make target
# until 2026-08-30 and so had never been run against the current RTL -- both
# were broken (see the tb reset comments). A bench with no runner is not
# coverage; keep every trouper_top bench reachable from here.
.PHONY: sim_trouper_spi sim_trouper_all

sim_trouper_spi: tb_trouper_spi.vvp
	$(VVP) $<

tb_trouper_spi.vvp: $(TB)/tb_trouper_spi.v $(TROUPER_TOP_SRCS)
	$(IVERILOG) $(IFLAGS) -o $@ $^

# Every trouper_top-level bench in one go.
sim_trouper_all: sim_trouper_top sim_trouper_two_packet sim_trouper_spi

# -----------------------------------------------------------------------
# cocotb integration tests (SF7–SF12 × BW250/125) — requires chipathon26 container
# -----------------------------------------------------------------------
.PHONY: sim_trouper_cocotb

sim_trouper_cocotb:
	$(MAKE) -C cocotb_trouper_top

# Measured-IQ playback (Verilator): drive trouper_top with a real capture.
# Pass a capture and (optionally) SF/BW/window, e.g.:
#   make sim_trouper_capture \
#     CAPTURE_NPY=/foss/designs/lora-mimo/lora-capture/captures/<file>.npy \
#     CAPTURE_SF=7 CAPTURE_BW=250 CAPTURE_NSAMP=60000
# -----------------------------------------------------------------------
.PHONY: sim_trouper_capture

sim_trouper_capture:
	$(MAKE) -C cocotb_trouper_capture

clean:
	rm -rf obj_dir_dsp_chain obj_dir_dsp_chain_real obj_dir_loopback_probe \
		obj_dir_dsp_chain_real_probe obj_dir_dsp_chain_real_probe_osr256 \
		obj_dir_const obj_dir_mrc_combiner obj_dir_mrc_fw_precision \
		obj_dir_mrc_fw_rand obj_dir_dsp_chain_rand *.vvp *.vcd
	$(MAKE) -C cocotb_trouper_top clean 2>/dev/null || true
	$(MAKE) -C cocotb_trouper_capture clean 2>/dev/null || true
