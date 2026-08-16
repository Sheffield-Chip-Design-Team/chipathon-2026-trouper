#!/usr/bin/env bash
# CONTROL run: config_current_signoff with the sc_clear MCP exception RESTORED.
# Everything else byte-identical to job 4376, so the WNS/TNS delta and the
# packet_done_pulse path slacks isolate that exception's true cost on the
# signoff configuration. See Open Risks #43.
set -euo pipefail
export PDK_ROOT=/foss/pdks
export PDK=gf180mcuD
export STD_CELL_LIBRARY=gf180mcu_fd_sc_mcu7t5v0
OUT="${RUN_DIR:-/foss/runs}/trouper_top_ctl_scclr"
mkdir -p "$OUT/run"
echo "=== sc_clear CONTROL P&R START $(date --iso-8601=seconds) ==="
cd /foss/designs/rtl-test
librelane --pdk gf180mcuD --scl gf180mcu_fd_sc_mcu7t5v0 \
  --force-run-dir "$OUT/run" \
  ol_trouper_top/config_ctl_scclr.json
echo "=== sc_clear CONTROL P&R COMPLETE $(date --iso-8601=seconds) ==="
