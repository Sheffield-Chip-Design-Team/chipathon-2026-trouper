#!/bin/bash
# Full-chip, review-only GF180 KLayout DRC of the all-DVDD/DVSS A40 trial.
set -euo pipefail

PDK_ROOT=/foss/pdks
PDK=gf180mcuD
VERSION=7b70722e33c03fcb5dabcf4d479fb0822d9251c9
DECK="$PDK_ROOT/ciel/gf180mcu/versions/$VERSION/$PDK/libs.tech/klayout/tech/drc/gf180mcu.drc"
GDS=/foss/designs/a40_review/SSCS_2026_01_a40_ring5396_all_dvdd_dvss_pdn_trial.gds
OUT=${RUN_DIR:-/foss/runs}/a40_full_gds_drc
mkdir -p "$OUT"

exec klayout -b -r "$DECK" \
  -rd input="$GDS" \
  -rd topcell=SSCS_2026_01 \
  -rd report="$OUT/a40_all_dvdd_dvss_full_drc.lyrdb" \
  -rd feol=true -rd beol=true -rd metal_level=5LM -rd run_mode=deep -rd thr=6
