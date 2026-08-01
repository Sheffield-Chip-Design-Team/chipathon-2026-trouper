#!/usr/bin/env bash
# Full current-signoff P&R.  Designed for `hqsub --project lora-mimo`, where
# the project root is mounted read-only at /foss/designs and RUN_DIR is writable.
set -euo pipefail

export PDK_ROOT=/foss/pdks
export PDK=gf180mcuD
export STD_CELL_LIBRARY=gf180mcu_fd_sc_mcu7t5v0

OUT="${RUN_DIR:-/foss/runs}/trouper_top_current_signoff_mcp"
mkdir -p "$OUT/run"
echo "=== current-signoff MCP P&R START $(date --iso-8601=seconds) ==="
echo "RUN_DIR=$OUT"
cd /foss/designs/rtl-test
librelane --pdk gf180mcuD --scl gf180mcu_fd_sc_mcu7t5v0 \
  --force-run-dir "$OUT/run" \
  ol_trouper_top/config_current_signoff.json
echo "=== current-signoff MCP P&R COMPLETE $(date --iso-8601=seconds) ==="
