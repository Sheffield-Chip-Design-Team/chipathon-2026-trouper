#!/bin/bash
# End-to-end DSP chain simulation — verifies current RTL against key checks:
#   1. tb_dsp_chain    — self-checking: sc_lock, training_done, W_commit, y_valid, sd_remod output
#   2. run_sqnr_cic_only — SQNR >= 28 dB for CIC-only decimator at all 4 decim_ratios
#
# RTL changes validated:
#   - mrc_combiner serialised I/Q (ser-IQ, 11-state FSM)
#   - energy_meas_coarse replacing energy_meas
#   - noise_floor_est removed
#   - sd_decimator_cic_only (CIC-only, no FIR)
set -euo pipefail

RTL=/foss/designs/lora-mimo
RT=$RTL/rtl-test
LOG=$RT/e2e_test.log
echo "=== E2E DSP chain test $(date --iso-8601=seconds) on $(hostname) ===" | tee "$LOG"

cd "$RT"

# ── 1. tb_dsp_chain: end-to-end self-checking testbench ─────────────────────
echo "" | tee -a "$LOG"
echo "--- tb_dsp_chain (iverilog) ---" | tee -a "$LOG"

iverilog -g2012 -Wall \
    -Wno-timescale \
    -o /tmp/tb_dsp_chain.vvp \
    tb_dsp_chain.v \
    dc_removal.v \
    frontend_buf_ctrl.v \
    energy_meas_coarse.v \
    sc_detector.v \
    training_acc.v \
    weight_gen.v \
    mrc_combiner.v \
    sd_remod.v \
    2>&1 | tee -a "$LOG" | grep -i "error\|warning" | grep -v "@\*" | head -20

echo "--- running simulation ---" | tee -a "$LOG"
vvp /tmp/tb_dsp_chain.vvp 2>&1 | tee -a "$LOG"

# ── 2. SQNR test for CIC-only decimator ─────────────────────────────────────
echo "" | tee -a "$LOG"
echo "--- run_sqnr_cic_only ---" | tee -a "$LOG"
bash "$RT/syn_mimo_per_module/run_sqnr_cic_only.sh" 2>&1 | tee -a "$LOG" | \
    grep -E "PASS|FAIL|SQNR|dB|ERROR" | head -30

echo "" | tee -a "$LOG"
echo "=== E2E TEST COMPLETE ===" | tee -a "$LOG"
grep -E "PASS|FAIL|ERROR|Test.*:" "$LOG" | tail -20
