#!/bin/bash
# Full P&R of trouper_top_hb (poly) with SYNTH_STRATEGY="AREA 0" — measure whether
# the -6.5% combinational-area recovery (synth: 894,919 vs 956,734 um2) survives
# timing. Same FD+MCP=3 1650x1100 die as the reset poly run (SGE 2100, SS -8.59).
set -e
LOG=/foss/designs/lora-mimo/rtl-test/ol_trouper_top_hb/area_pnr_run.log
exec > >(tee "$LOG") 2>&1
echo "=== trouper_top_hb AREA-0 P&R START $(date --iso-8601=seconds) on $(hostname) ==="
cd /foss/designs/lora-mimo/rtl-test
librelane --pdk gf180mcuD --scl gf180mcu_fd_sc_mcu7t5v0 ol_trouper_top_hb/config_area.json
echo "=== trouper_top_hb AREA-0 P&R EXIT $? $(date --iso-8601=seconds) ==="
