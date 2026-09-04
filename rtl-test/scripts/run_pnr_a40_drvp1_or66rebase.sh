#!/bin/bash
# A40 P&R of trouper_top on the rebased rtl/open-risk-fixes branch, using the
# drvp1 DRV variant (src/config/trouper_top_drvp1.json): identical to the
# canonical src/config/trouper_top.json EXCEPT GRT_DESIGN_REPAIR_MAX_{SLEW,CAP}
# _PCT 65 -> 50 (post-GRT margin only; pre-GRT DESIGN_REPAIR_MAX_*_PCT stays 65).
#
# This is the "RECOMMENDED CHANGE, NOT YET APPLIED -- re-verify against the
# merged netlist first" from trouper_top.json's _comment_drv_margin_sweep. The
# unmerged reference is job 5491 (nom_tt DRV 0/0, max_ff 0/0, SS 7/1,
# SS WNS -11.36 -> -10.56, SS TNS -276 -> -268, 49 fewer cells, DRC/LVS/XOR/
# antenna 0). Runs in parallel with run_pnr_a40_or66rebase.sh (the 65/65
# baseline). Distinct run subdir -- does NOT touch the shared "dbgpins" dir or
# the a40_or66rebase dir.
set -euo pipefail
export PDK_ROOT=/foss/pdks
export PDK=gf180mcuD
export STD_CELL_LIBRARY=gf180mcu_fd_sc_mcu7t5v0

OUT=${RUN_DIR:-/foss/runs}/a40_drvp1_or66rebase
mkdir -p "$OUT/run"
cd /foss/designs
librelane --pdk "$PDK" --scl "$STD_CELL_LIBRARY" \
          --force-run-dir "$OUT/run" \
          src/config/trouper_top_drvp1.json
