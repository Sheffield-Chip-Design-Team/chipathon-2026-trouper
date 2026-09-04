#!/bin/bash
# Full A40 P&R of trouper_top after rebasing rtl/open-risk-fixes (Open Risks
# #61/#62/#63/#65/#66/#68 RTL) onto pinout/dbg1-shared-irq-pad-27 (27-pad
# padframe, regenerated A40_ACV_rtlnames.def @ 224c151).
#
# Same canonical src/config/trouper_top.json as run_pnr_a40.sh -- reads src/ RTL
# directly, so the #66/#68 training_acc/sc_detector/trouper_top edits ARE
# exercised. Regression target: job 5379 (SS WNS -10.13 ns, TNS -383.5,
# 0 DRC / 0 LVS / 0 antenna) or the same-netlist stock-PDN control job 5378
# (SS WNS -11.17 ns, TNS -336.1). Distinct run subdir -- does NOT touch the
# shared "dbgpins" run dir other branches use.
set -euo pipefail
export PDK_ROOT=/foss/pdks
export PDK=gf180mcuD
export STD_CELL_LIBRARY=gf180mcu_fd_sc_mcu7t5v0

OUT=${RUN_DIR:-/foss/runs}/a40_or66rebase
mkdir -p "$OUT/run"
cd /foss/designs
librelane --pdk "$PDK" --scl "$STD_CELL_LIBRARY" \
          --force-run-dir "$OUT/run" \
          src/config/trouper_top.json
