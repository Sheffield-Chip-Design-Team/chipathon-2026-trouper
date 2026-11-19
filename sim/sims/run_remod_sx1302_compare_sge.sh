#!/bin/bash
# SX1302-input comparison sweep (sim/sims/remod_sx1302_compare.py): SX1257-style
# 5th-order reference vs legacy CIFF4 vs CIFF3 sd_remod, through two receiver
# proxies, parts A/B/C. Pure Python, CPU-bound; submit with
#   hqsub --project lora-mimo --name remod-sx1302-compare --cpus 12 --mem 20G \
#         sim/sims/run_remod_sx1302_compare_sge.sh
# hqsub copies the script to /job/run.sh, so reach the repo via the mount.
set -euo pipefail
DESIGN_ROOT=${DESIGN_ROOT:-/foss/designs}
OUT=${RUN_DIR:-/foss/runs}/remod_sx1302_compare
mkdir -p "$OUT"
cd "$DESIGN_ROOT"
export PYTHONDONTWRITEBYTECODE=1 MPLCONFIGDIR=$OUT/.mpl OMP_NUM_THREADS=1
python3 -m sim.sims.remod_sx1302_compare --parts ${PARTS:-ABC} \
    --workers ${WORKERS:-12} --out "$OUT" 2>&1 | grep -v -i "cblas\|NOTE: You need"
ls -la "$OUT"
