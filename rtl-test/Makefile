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

.PHONY: sim_decimator_hb
sim_decimator_hb: obj_dir_decimator_hb/Vtb_decimator_hb
	$<

obj_dir_decimator_hb/Vtb_decimator_hb: $(TB)/tb_decimator_hb.v $(RTL)/sd_decimator_hb.v
	$(VERILATOR) $(VFLAGS) --Mdir obj_dir_decimator_hb \
	    --top-module tb_decimator_hb $^

DSP_SRCS  = $(RTL)/dc_removal.v $(RTL)/frontend_buf_ctrl.v \
            $(RTL)/sc_detector.v $(RTL)/training_acc.v \
            $(RTL)/mrc_combiner.v $(RTL)/sd_remod.v
DSP_SRCS_SD = $(DSP_SRCS) $(RTL)/sd_decimator_cic_only.v

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

obj_dir_const/Vtb_remod_decim_const: $(TB)/tb_remod_decim_const.v $(RTL)/sd_remod.v $(RTL)/sd_decimator_cic_only.v
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

obj_dir_mrc_combiner/Vtb_mrc_combiner: $(TB)/tb_mrc_combiner.v $(RTL)/mrc_combiner.v
	$(VERILATOR) $(VFLAGS) --Mdir obj_dir_mrc_combiner \
	    --top-module tb_mrc_combiner $^

# -----------------------------------------------------------------------
# MRC firmware precision testbench (Verilator)
# 5 channel scenarios; verifies Q0.7 weight quantisation vs float-optimal
# -----------------------------------------------------------------------
.PHONY: sim_mrc_fw_precision

sim_mrc_fw_precision: obj_dir_mrc_fw_precision/Vtb_mrc_fw_precision
	$<

obj_dir_mrc_fw_precision/Vtb_mrc_fw_precision: $(TB)/tb_mrc_fw_precision.v $(RTL)/mrc_combiner.v
	$(VERILATOR) $(VFLAGS) --Mdir obj_dir_mrc_fw_precision \
	    --top-module tb_mrc_fw_precision $^

# -----------------------------------------------------------------------
# MRC randomised precision testbench (Verilator)
# 100 random A_k scenarios; +seed=<N> plusarg overrides default seed
# -----------------------------------------------------------------------
.PHONY: sim_mrc_fw_rand

sim_mrc_fw_rand: obj_dir_mrc_fw_rand/Vtb_mrc_fw_rand
	$< +seed=42

obj_dir_mrc_fw_rand/Vtb_mrc_fw_rand: $(TB)/tb_mrc_fw_rand.v $(RTL)/mrc_combiner.v
	$(VERILATOR) $(VFLAGS) --Mdir obj_dir_mrc_fw_rand \
	    --top-module tb_mrc_fw_rand $^

# -----------------------------------------------------------------------
# Randomised DSP chain end-to-end testbench (Verilator)
# 20 random A_k/phase cases; +seed=<N> plusarg overrides default seed
# -----------------------------------------------------------------------
DSP_SRCS_RAND = $(RTL)/dc_removal.v $(RTL)/sc_detector.v \
                $(RTL)/training_acc.v $(RTL)/mrc_combiner.v $(RTL)/sd_remod.v

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

tb_sd_remod.vvp: $(TB)/tb_sd_remod.v $(RTL)/sd_remod.v
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
# -----------------------------------------------------------------------
TROUPER_TOP_SRCS = \
    $(RTL)/trouper_top.v \
    $(RTL)/sd_decimator_cic_tdm8.v \
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

# -----------------------------------------------------------------------
# cocotb integration tests (SF7–SF12 × BW250/125) — requires chipathon26 container
# -----------------------------------------------------------------------
.PHONY: sim_trouper_cocotb

sim_trouper_cocotb:
	$(MAKE) -C cocotb_trouper_top

# cocotb HB integration tests (SF7–SF12 × BW250/125, trouper_top_hb)
# -----------------------------------------------------------------------
.PHONY: sim_trouper_hb_cocotb

sim_trouper_hb_cocotb:
	$(MAKE) -C cocotb_trouper_top_hb

clean:
	rm -rf obj_dir_dsp_chain obj_dir_dsp_chain_real obj_dir_loopback_probe \
		obj_dir_dsp_chain_real_probe obj_dir_dsp_chain_real_probe_osr256 \
		obj_dir_const obj_dir_mrc_combiner obj_dir_mrc_fw_precision \
		obj_dir_mrc_fw_rand obj_dir_dsp_chain_rand *.vvp *.vcd
	$(MAKE) -C cocotb_trouper_top clean 2>/dev/null || true
	$(MAKE) -C cocotb_trouper_top_hb clean 2>/dev/null || true
