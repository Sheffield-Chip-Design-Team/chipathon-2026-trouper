#!/usr/bin/env bash
# Next step in the square-die sweep: +50um on each axis vs the failing
# 1117.5x1117.5 (job 4480, DPL-0036), matching this project's established
# 50um sweep step size (see area-reduction-roadmap.md's 1150/1200/1250/1300
# rectangle sweep). 1167.5x1167.5 = 1,363,056 um^2 -- ALREADY bigger than
# the signed-off 1200x1100 (1,320,000 um^2), so this is really asking "does
# a square shape need more raw area than the rectangle to reach the same
# forced util," not "is there a smaller square that works." Same pin order
# (io_placement_1117sq.cfg -- still a balanced 4-equal-side split) and same
# 88% density target as the failing 1117.5 run, so this isolates the die-size
# variable only.
set -euo pipefail
export PDK_ROOT=/foss/pdks
export PDK=gf180mcuD
export STD_CELL_LIBRARY=gf180mcu_fd_sc_mcu7t5v0
OUT="${RUN_DIR:-/foss/runs}/trouper_top_1167sq"
mkdir -p "$OUT/run"
echo "=== 1167.5x1167.5 square die P&R START $(date --iso-8601=seconds) ==="
cd /foss/designs/rtl-test
librelane --pdk gf180mcuD --scl gf180mcu_fd_sc_mcu7t5v0 \
  --force-run-dir "$OUT/run" \
  ol_trouper_top/config_1167sq.json
echo "=== 1167.5x1167.5 square die P&R COMPLETE $(date --iso-8601=seconds) ==="
