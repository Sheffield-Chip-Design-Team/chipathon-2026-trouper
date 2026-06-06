#!/bin/bash
# A/B regression: tb_dsp_chain_loopback_probe with baseline vs combchain
# sd_decimator. This TB exercises the full chain dc_removal -> ... ->
# mrc_combiner -> sd_remod -> sd_decimator (the decimator is used in the
# loopback path). Both PASS/FAIL milestones + CSV-comparison.
set -euo pipefail
RTL=/foss/designs/lora-mimo
OUT=$RTL/rtl-test/syn_mimo_per_module/out_loopback
mkdir -p "$OUT"
LOG=$OUT/run.log
echo "=== loopback_probe A/B $(date --iso-8601=seconds) on $(hostname) ===" | tee "$LOG"

# Verify stimulus binary is reachable
STIM=$RTL/sim/examples/1_packet_mingain_chip.bin
if [ ! -f "$STIM" ]; then
    echo "ERROR: stimulus file missing at $STIM" | tee -a "$LOG"; exit 1
fi
ls -la "$STIM" | tee -a "$LOG"

SWAP=$OUT/sd_decimator_swap.v
sed 's/sd_decimator_combchain/sd_decimator/g' \
    "$RTL/rtl-test/sd_decimator_combchain.v" > "$SWAP"

DSP_SRCS="dc_removal.v frontend_buf_ctrl.v energy_meas.v noise_floor_est.v \
sc_detector.v training_acc.v weight_gen.v mrc_combiner.v sd_remod.v"

cd "$RTL/rtl-test"
for VARIANT in baseline combchain; do
    if [ "$VARIANT" = "baseline" ]; then DEC=$RTL/rtl-test/sd_decimator.v
    else DEC=$SWAP; fi
    BIN=$OUT/tb_loopback_${VARIANT}.vvp
    echo "--- compile $VARIANT ($DEC) ---" | tee -a "$LOG"
    iverilog -g2001 -Wall -o "$BIN" \
        tb_dsp_chain_loopback_probe.v $DSP_SRCS "$DEC" 2>&1 | tee -a "$LOG" | grep -vE "^.*warning: @\* is sensitive" | tail -5
    echo "--- run $VARIANT ---" | tee -a "$LOG"
    # Capture only test results + the trailing summary
    RUNLOG=$OUT/run_${VARIANT}.txt
    vvp "$BIN" 2>&1 | tee "$RUNLOG" >> "$LOG"
    # Move generated CSVs aside
    [ -f "$RTL/rtl-test/loopback_y_ref.csv" ] && mv "$RTL/rtl-test/loopback_y_ref.csv" "$OUT/loopback_y_ref_${VARIANT}.csv" || true
    [ -f "$RTL/rtl-test/loopback_recon.csv" ] && mv "$RTL/rtl-test/loopback_recon.csv" "$OUT/loopback_recon_${VARIANT}.csv" || true
    echo "--- $VARIANT milestones ---" | tee -a "$LOG"
    grep -E "PASS|FAIL|Results:|Loaded|TIMEOUT|never fired" "$RUNLOG" | tee -a "$LOG"
done

echo "--- compare summaries ---" | tee -a "$LOG"
diff <(grep -E "PASS|FAIL|Results:" "$OUT/run_baseline.txt") \
     <(grep -E "PASS|FAIL|Results:" "$OUT/run_combchain.txt") | tee -a "$LOG" || true
echo "=== DONE ===" | tee -a "$LOG"
