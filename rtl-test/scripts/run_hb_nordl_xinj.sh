#!/bin/bash
# Cheap RTL X-injection experiment: how cleanly do un-reset HB delay lines flush?
set -euo pipefail
ROOT=/foss/designs/lora-mimo
RT=$ROOT/rtl-test
OUT=$RT/syn_mimo_per_module/out_nordl_xinj
mkdir -p "$OUT"
LOG=$OUT/run.log
echo "=== nordl X-injection $(date --iso-8601=seconds) on $(hostname) ===" | tee "$LOG"
iverilog -g2012 -o "$OUT/xinj.vvp" \
    "$RT/tb/tb_hb_nordl_xinj.v" \
    "$RT/rtl/sd_decimator_hb_poly.v" \
    "$RT/rtl/sd_decimator_hb_poly_nordl.v" 2>&1 | tee -a "$LOG"
vvp "$OUT/xinj.vvp" 2>&1 | tee -a "$LOG"
echo "=== DONE ===" | tee -a "$LOG"
