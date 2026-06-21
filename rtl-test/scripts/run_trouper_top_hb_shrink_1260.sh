#!/bin/bash
# DELAY-0 poly die-shrink: 1260x1100 — pushing past 1500 to find the breaking point
# (where SS blows past budget or routing DRC appears). Compare vs 1500 (SGE 2106).
set -e
LOG=/foss/designs/lora-mimo/rtl-test/ol_trouper_top_hb/shrink_1260_pnr_run.log
exec > >(tee "$LOG") 2>&1
echo "=== trouper_top_hb shrink 1260x1100 START $(date --iso-8601=seconds) on $(hostname) ==="
cd /foss/designs/lora-mimo/rtl-test
librelane --pdk gf180mcuD --scl gf180mcu_fd_sc_mcu7t5v0 ol_trouper_top_hb/config_shrink_1260.json
echo "=== shrink 1260 EXIT $? $(date --iso-8601=seconds) ==="
