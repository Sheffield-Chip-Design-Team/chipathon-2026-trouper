#!/usr/bin/env bash
# Square-die feasibility test: 1117.5x1117.5 = 1,248,806 um^2 usable.
#
# Requested to see if a square die can beat the signed-off 1200x1100
# (1,320,000 um^2) rectangle. Per planning/area-reduction-roadmap.md +
# project_1100_target_not_reachable_via_rtl.md, placed cell area is
# ~1.07M um^2 at 1200x1100 (85.37% util), and the FIXED-PIN routability
# floor was separately measured at 1200x1100 -- 1150x1100 (1,265,000 um^2,
# i.e. LARGER than this target) already congests (GRT-0116) with real
# board-edge pins per project_trouper_top_floorplan_strategy.md. This run
# is expected to fail the same way; it exists to get a real verdict rather
# than rely on extrapolation.
#
# Uses io_placement_1117sq.cfg (rebalanced S/W/E/N pin counts -- the old
# io_placement_bl.cfg's 23/8/16/12 split assumed a long south edge that a
# square die no longer has) and config_1117sq.json (same die area on both
# axes, PL_TARGET_DENSITY_PCT bumped to 88 since forced util here is
# ~85.7%, otherwise mirrors the latest known-good v26_pins template).
set -euo pipefail
export PDK_ROOT=/foss/pdks
export PDK=gf180mcuD
export STD_CELL_LIBRARY=gf180mcu_fd_sc_mcu7t5v0
OUT="${RUN_DIR:-/foss/runs}/trouper_top_1117sq"
mkdir -p "$OUT/run"
echo "=== 1117.5x1117.5 square die P&R START $(date --iso-8601=seconds) ==="
cd /foss/designs/rtl-test
librelane --pdk gf180mcuD --scl gf180mcu_fd_sc_mcu7t5v0 \
  --force-run-dir "$OUT/run" \
  ol_trouper_top/config_1117sq.json
echo "=== 1117.5x1117.5 square die P&R COMPLETE $(date --iso-8601=seconds) ==="
