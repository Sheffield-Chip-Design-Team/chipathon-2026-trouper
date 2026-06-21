#!/bin/bash
# trouper_top_hb with NO-RESET HB delay lines (sd_decimator_hb_poly_nordl) — numbers
# only: measure top-level area/density/SS vs the reset poly run (SGE 2100). Same
# FD+MCP=3 1650x1100 die. NOTE: reset-removal is a DEFERRED candidate pending
# X-init GLS; this run is for area comparison, not a production config.
set -e
LOG=/foss/designs/lora-mimo/rtl-test/ol_trouper_top_hb/nordl_pnr_run.log
exec > >(tee "$LOG") 2>&1
echo "=== trouper_top_hb_nordl P&R START $(date --iso-8601=seconds) on $(hostname) ==="
cd /foss/designs/lora-mimo/rtl-test
librelane --pdk gf180mcuD --scl gf180mcu_fd_sc_mcu7t5v0 ol_trouper_top_hb/config_nordl.json
echo "=== trouper_top_hb_nordl P&R EXIT $? $(date --iso-8601=seconds) ==="
