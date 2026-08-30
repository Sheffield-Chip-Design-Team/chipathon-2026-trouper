#!/bin/bash
# Density probe for Open Risks #6: trouper_top_dbgpins.json at 63% instead of 65%.
# Job 5281 failed DRT-1231 at 65% on a netlist only 144 cells larger than the
# clean job 5279. Everything else is byte-identical to the 5279/5281 recipe.
set -euo pipefail
export PDK_ROOT=/foss/pdks
export PDK=gf180mcuD
export STD_CELL_LIBRARY=gf180mcu_fd_sc_mcu7t5v0

OUT=${RUN_DIR:-/foss/runs}/dbgpins_d63
mkdir -p "$OUT/run"
cd /foss/designs
librelane --pdk "$PDK" --scl "$STD_CELL_LIBRARY" \
          --force-run-dir "$OUT/run" \
          src/config/trouper_top_dbgpins_d63.json
