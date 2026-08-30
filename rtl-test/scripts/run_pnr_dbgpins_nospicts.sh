#!/bin/bash
# Open Risks #6 CTS probe (nospicts). See the config's _comment_cts_probe.
set -euo pipefail
export PDK_ROOT=/foss/pdks
export PDK=gf180mcuD
export STD_CELL_LIBRARY=gf180mcu_fd_sc_mcu7t5v0
OUT=${RUN_DIR:-/foss/runs}/dbgpins_nospicts
mkdir -p "$OUT/run"
cd /foss/designs
librelane --pdk "$PDK" --scl "$STD_CELL_LIBRARY" \
          --force-run-dir "$OUT/run" \
          src/config/trouper_top_dbgpins_nospicts.json
