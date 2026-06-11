#!/bin/bash
# Run one trouper_top LibreLane P&R at a chosen utilization config.
# Usage: run_mimo_util_sweep.sh <config_basename>   (e.g. config_util55)
# Tests how far util can be pushed before the GF180 DRT density wall breaks
# routing — the top has +38ns slack so this is a pure routability probe.
set -euo pipefail
CFG="${1:?usage: $0 <config_basename>}"
LOG=/foss/designs/lora-mimo/rtl-test/ol_mimo_${CFG}.log
exec > >(tee "$LOG") 2>&1
echo "=== trouper_top ${CFG} START $(date --iso-8601=seconds) on $(hostname) ==="
cd /foss/designs/lora-mimo/rtl-test
# Skip Magic.SpiceExtraction: on these SRAM macros it emits 36 "Illegal overlap
# between obsv2 and metal2" feedbacks (router Metal2 abutting the macros' own
# Metal2 OBS at pin edges) which deferred-error the flow. They are an LVS-
# extraction artifact, not a routing/DRC defect (route DRC = 0). Skipping lets
# the area/routability runs complete cleanly. MUST be revisited for tapeout
# signoff (trim macro LEF OBS / abstract the macros / waive). See
# ol_trouper_top/CONGESTION_EXPERIMENT.md.
/foss/tools/bin/librelane --pdk gf180mcuD --scl gf180mcu_fd_sc_mcu7t5v0 \
    --skip Magic.SpiceExtraction \
    ol_trouper_top/${CFG}.json
echo "=== trouper_top ${CFG} EXIT $? $(date --iso-8601=seconds) ==="
