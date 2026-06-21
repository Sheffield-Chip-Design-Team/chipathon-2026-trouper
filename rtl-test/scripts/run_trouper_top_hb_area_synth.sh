#!/bin/bash
# Synthesis-only (--to Yosys.Synthesis) of trouper_top_hb (poly) with SYNTH_STRATEGY
# = "AREA 0", to measure combinational-area recovery vs the flow's default "DELAY 0"
# (poly DELAY-0 baseline: 956,734 um2 total, 384,050 sequential). Fast, no P&R.
set -e
LOG=/foss/designs/lora-mimo/rtl-test/ol_trouper_top_hb/area_synth_run.log
exec > >(tee "$LOG") 2>&1
echo "=== trouper_top_hb AREA-strategy synth START $(date --iso-8601=seconds) ==="
cd /foss/designs/lora-mimo/rtl-test
librelane --pdk gf180mcuD --scl gf180mcu_fd_sc_mcu7t5v0 \
          --to Yosys.Synthesis ol_trouper_top_hb/config_area.json
echo "=== EXIT $? $(date --iso-8601=seconds) ==="
