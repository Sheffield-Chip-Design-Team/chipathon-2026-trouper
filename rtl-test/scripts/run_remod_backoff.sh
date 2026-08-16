#!/bin/bash
# Drive cocotb/remod_backoff: the REMOD_BACKOFF_SHIFT regression.
# Synthetic stimulus only -- no capture file, no shared mount needed.
set -uo pipefail

RTL_ROOT=${RTL_ROOT:-/foss/designs/lora-mimo}
if [ ! -d "$RTL_ROOT/src" ] && [ -d /foss/designs/src ]; then RTL_ROOT=/foss/designs; fi
RUN_OUT=${RUN_DIR:-/foss/runs}
mkdir -p "$RUN_OUT"

LOG=$RUN_OUT/remod_backoff.log
exec > >(tee "$LOG") 2>&1
echo "=== remod_backoff START $(date --iso-8601=seconds) on $(hostname) ==="
echo "RTL_ROOT=$RTL_ROOT  RUN_OUT=$RUN_OUT"

cd "$RTL_ROOT/cocotb/remod_backoff"
make clean SIM_BUILD="$RUN_OUT/sim_build" >/dev/null 2>&1
make SIM_BUILD="$RUN_OUT/sim_build" \
     COCOTB_RESULTS_FILE="$RUN_OUT/results.xml" \
     DESIGN_ROOT="$RTL_ROOT"
rc=$?

# cocotb can exit 0 with failures recorded in the XML -- trust the XML.
if grep -q "<failure" "$RUN_OUT/results.xml" 2>/dev/null; then rc=1; fi
if [ ! -s "$RUN_OUT/results.xml" ]; then rc=1; fi

echo "=== remod_backoff EXIT $rc $(date --iso-8601=seconds) ==="
exit $rc
