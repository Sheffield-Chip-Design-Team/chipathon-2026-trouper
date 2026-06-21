#!/bin/bash
# DELAY-0 poly die-shrink: 1500x1100. Spends poly's +7.6 ns SS headroom for a
# smaller floorplan without changing mapping. Compare SS/density vs 1650x1100 (2100).
set -e
LOG=/foss/designs/lora-mimo/rtl-test/ol_trouper_top_hb/shrink_1500_pnr_run.log
exec > >(tee "$LOG") 2>&1
echo "=== trouper_top_hb shrink 1500x1100 START $(date --iso-8601=seconds) on $(hostname) ==="
cd /foss/designs/lora-mimo/rtl-test
librelane --pdk gf180mcuD --scl gf180mcu_fd_sc_mcu7t5v0 ol_trouper_top_hb/config_shrink_1500.json
echo "=== shrink 1500 EXIT $? $(date --iso-8601=seconds) ==="
