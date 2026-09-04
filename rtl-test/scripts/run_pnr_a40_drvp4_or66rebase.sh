#!/bin/bash
# A40 P&R of trouper_top on rtl/open-risk-fixes, drvp4 DRV variant
# (src/config/trouper_top_drvp4.json): identical to the canonical
# src/config/trouper_top.json EXCEPT GRT_DESIGN_REPAIR_MAX_{SLEW,CAP}_PCT
# 65 -> 40 (post-GRT margin only; pre-GRT DESIGN_REPAIR_MAX_*_PCT stays 65 --
# tightening the pre-GRT margin regressed hard in the 2026-09-03 sweep).
#
# Runs alongside run_pnr_a40_or66rebase.sh (65/65 baseline) and
# run_pnr_a40_drvp1_or66rebase.sh (GRT 50) on top of the #70 two-stage
# IQ-capture fix (a6c4a15).  Distinct run subdir.
set -euo pipefail
export PDK_ROOT=/foss/pdks
export PDK=gf180mcuD
export STD_CELL_LIBRARY=gf180mcu_fd_sc_mcu7t5v0

OUT=${RUN_DIR:-/foss/runs}/a40_drvp4_or66rebase
mkdir -p "$OUT/run"
cd /foss/designs
librelane --pdk "$PDK" --scl "$STD_CELL_LIBRARY" \
          --force-run-dir "$OUT/run" \
          src/config/trouper_top_drvp4.json
