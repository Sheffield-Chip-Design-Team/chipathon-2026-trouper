#!/usr/bin/env bash
# 5V-core experiment on top of the margin-reclaimed 1117.5x1117.5 die (job
# 4484: DRC=0/LVS=0, WNS nom_tt_025C_3v30 -4.10ns, WNS max_ss_125C_3v00
# -56.66ns -- the only open item was timing, not routability). Isolates ONE
# variable vs config_1117sq_maxarea.json: DEFAULT_CORNER/STA_CORNERS/LIB
# swapped from the 3.3V-core set (tt_3v30/ss_3v00/ff_3v60) to the 5V-core
# set (tt_5v00/ss_4v50/ff_5v50), matching the project's established 5V-rail
# config pattern (config_5vrail_1550.json). Margin reclaim (MARGIN_MULT=1),
# density target (88%), pin order, and SDC are all held constant from the
# known-clean 4484 run so any delta is attributable to voltage alone.
#
# Prior 5V test (project_1100_target_not_reachable_via_rtl, 2026-08-05) found
# 5V died at DPL-0036 CTS legalization -- but that was on the OLD
# default-margin 1100x1100 floorplan, before the margin-reclaim fix was
# known. With margins reclaimed and 1117.5sq already proven routable at
# 3.3V (job 4484), DPL-0036 is not expected to recur here; this run tests
# whether 5V actually closes the remaining SS/TT timing gap as the
# voltage-bound hypothesis (project_vdd_closes_ss_timing) predicts.
set -euo pipefail
export PDK_ROOT=/foss/pdks
export PDK=gf180mcuD
export STD_CELL_LIBRARY=gf180mcu_fd_sc_mcu7t5v0
OUT="${RUN_DIR:-/foss/runs}/trouper_top_1117sq_maxarea_5vrail"
mkdir -p "$OUT/run"
echo "=== 1117.5x1117.5 MAX-AREA 5V-CORE P&R START $(date --iso-8601=seconds) ==="
cd /foss/designs/rtl-test
librelane --pdk gf180mcuD --scl gf180mcu_fd_sc_mcu7t5v0 \
  --force-run-dir "$OUT/run" \
  ol_trouper_top/config_1117sq_maxarea_5vrail.json
echo "=== 1117.5x1117.5 MAX-AREA 5V-CORE P&R COMPLETE $(date --iso-8601=seconds) ==="
