#!/usr/bin/env bash
# Margin-reclaim experiment on the 1117.5x1117.5 square die (job 4480 failed
# DPL-0036). Isolates ONE variable vs config_1117sq.json: LEFT/RIGHT/TOP/
# BOTTOM_MARGIN_MULT dropped from LibreLane's defaults (12/12/4/4 site
# pitches) to the minimum (1/1/1/1), reclaiming the core-margin ring
# identified in the earlier floorplan-log investigation (die 1,248,806um^2,
# core was only 1,198,507um^2 -- a 50,300um^2 / 4.0% band). Everything else
# (density target 88%, pin order, SDC) unchanged from config_1117sq.json so
# any WNS/DRC/DPL delta is attributable to this one knob.
#
# Ceiling estimate (see conversation): even fully reclaiming the margin only
# drops forced placement util from 90.2% to ~86.5% -- right at the edge of
# the known-passing/known-failing band, not a clean win. This run measures
# the real number instead of the estimate.
set -euo pipefail
export PDK_ROOT=/foss/pdks
export PDK=gf180mcuD
export STD_CELL_LIBRARY=gf180mcu_fd_sc_mcu7t5v0
OUT="${RUN_DIR:-/foss/runs}/trouper_top_1117sq_maxarea"
mkdir -p "$OUT/run"
echo "=== 1117.5x1117.5 MAX-AREA (margin=1) P&R START $(date --iso-8601=seconds) ==="
cd /foss/designs/rtl-test
librelane --pdk gf180mcuD --scl gf180mcu_fd_sc_mcu7t5v0 \
  --force-run-dir "$OUT/run" \
  ol_trouper_top/config_1117sq_maxarea.json
echo "=== 1117.5x1117.5 MAX-AREA (margin=1) P&R COMPLETE $(date --iso-8601=seconds) ==="
