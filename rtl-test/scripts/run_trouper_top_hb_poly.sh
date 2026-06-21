#!/bin/bash
# trouper_top_hb P&R with folded area-reduction decimator (sd_decimator_hb_poly:
# polyphase HB + 14-bit CIC, bit-exact vs sd_decimator_hb_tdm). Same FD+MCP=3
# 1650x1100 6-block config that passed as SGE 2094 — only the decimator changed,
# so this is an apples-to-apples re-run to measure the folded saving at top level.
set -e
LOG=/foss/designs/lora-mimo/rtl-test/ol_trouper_top_hb/poly_pnr_run.log
exec > >(tee "$LOG") 2>&1
echo "=== trouper_top_hb POLY P&R START $(date --iso-8601=seconds) on $(hostname) ==="
cd /foss/designs/lora-mimo/rtl-test
librelane --pdk gf180mcuD --scl gf180mcu_fd_sc_mcu7t5v0 ol_trouper_top_hb/config.json
echo "=== trouper_top_hb POLY P&R EXIT $? $(date --iso-8601=seconds) ==="
