#!/usr/bin/env bash
# L-shape floorplan retest: 1100x1100 + 550x550 (DIE 1650x1100 with the
# top-right 550x550 obstructed) = 1,512,500 um^2 usable, i.e. 5 padring slot
# blocks instead of the current 6.
#
# Variant of run_pnr_lshape_v26.sh with the two shaping levers the prepared
# L config never used, and nothing else changed:
#   IO_PIN_ORDER_CFG = io_placement_lshape.cfg -- the prepared config had NO pin
#     order at all, so OpenROAD spreads all 59 pins around the full 1650x1100
#     perimeter INCLUDING the two edges of the obstructed 550x550 corner,
#     anchoring logic toward a region nothing can legally occupy. The new cfg
#     uses only the fully-usable South and West edges, and deliberately places
#     IQ_DATA_{I,Q}_2/3 at the far-east end of South so decimator branches 2/3
#     are pulled into the leg (they are independent, ~20 wires each, and
#     already MCP=3 paced so seam wire delay is absorbed).
#   PL_TARGET_DENSITY_PCT 50 -> 78 -- 50 is BELOW the geometry's own 70.9%
#     post-CTS fill, i.e. unsatisfiable; the placer spreads maximally and hands
#     detailed placement an illegal result.
#
# History: this exact geometry FAILED as SGE job 2095 (DPL-0036, post-GRT)
# when synth cell area was ~961K um^2. Today it is 969,927 um^2 (+0.9%), so the
# design has not grown away from feasibility -- and the failure was placement
# legalization, which has known levers (DPL_CELL_PADDING=1,
# PL_MAX_DISPLACEMENT_*), already present in this config. Retested here on
# current RTL + SDC v26.
set -euo pipefail
export PDK_ROOT=/foss/pdks
export PDK=gf180mcuD
export STD_CELL_LIBRARY=gf180mcu_fd_sc_mcu7t5v0
OUT="${RUN_DIR:-/foss/runs}/trouper_top_lshape_v26_pins"
mkdir -p "$OUT/run"
echo "=== L-shape 1100+550 PINNED P&R START $(date --iso-8601=seconds) ==="
cd /foss/designs/rtl-test
librelane --pdk gf180mcuD --scl gf180mcu_fd_sc_mcu7t5v0 \
  --force-run-dir "$OUT/run" \
  ol_trouper_top/config_lshape_1100_550_v26_pins.json
echo "=== L-shape 1100+550 PINNED P&R COMPLETE $(date --iso-8601=seconds) ==="
