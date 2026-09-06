#!/bin/bash
# Open Risks #41 exit run: full A40 P&R of trouper_top with the min-RC (.min)
# OpenRCX ruleset bound to the ff corner via RCX_RULESETS, so hold is checked
# against a real optimistic-RC deck instead of the glob-default .max.
#
# Config: src/config/trouper_top_minff_rcx.json = canonical trouper_top.json
# (== DRV-sweep baseline job 5527) + one added key, RCX_RULESETS. STA_CORNERS
# is unchanged (max_ff_n40C_3v60 label kept -- renaming to min_ff_* reproducibly
# breaks P&R with GRT-0116, jobs 3423/3426/3436).
#
# Question this answers: does min-RC hold repair still hit GRT-0116 congestion
# on the current 1675x1110 / 65% A40 die? It did at the retired 1200x1100 / 88%
# floorplan (job 3464). If this routes clean, #41's congestion objection is
# retired and hold can sign off against the .min deck.
#
# Compare against job 5527 (a40_or66rebase, same netlist, .max hold deck):
#   SS setup WNS -14.44 / TNS -1008.7, hold MET all corners,
#   DRC 0 / LVS 0 / XOR 0 / antenna 0/0, util 68.7%.
set -euo pipefail
export PDK_ROOT=/foss/pdks
export PDK=gf180mcuD
export STD_CELL_LIBRARY=gf180mcu_fd_sc_mcu7t5v0

OUT=${RUN_DIR:-/foss/runs}/a40_minff_rcx
mkdir -p "$OUT/run"
cd /foss/designs
librelane --pdk "$PDK" --scl "$STD_CELL_LIBRARY" \
          --force-run-dir "$OUT/run" \
          src/config/trouper_top_minff_rcx.json
