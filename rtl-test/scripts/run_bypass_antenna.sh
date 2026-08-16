#!/bin/bash
# Drive cocotb/bypass_antenna: Open Risks #4 regression (bypass_ant must select
# the lowest enabled antenna). Synthetic stimulus -- no capture file needed.
set -uo pipefail

RTL_ROOT=${RTL_ROOT:-/foss/designs/lora-mimo}
if [ ! -d "$RTL_ROOT/src" ] && [ -d /foss/designs/src ]; then RTL_ROOT=/foss/designs; fi
RUN_OUT=${RUN_DIR:-/foss/runs}
mkdir -p "$RUN_OUT"

LOG=$RUN_OUT/bypass_antenna.log
exec > >(tee "$LOG") 2>&1
echo "=== bypass_antenna START $(date --iso-8601=seconds) on $(hostname) ==="
echo "RTL_ROOT=$RTL_ROOT  RUN_OUT=$RUN_OUT"

cd "$RTL_ROOT/cocotb/bypass_antenna"
make clean SIM_BUILD="$RUN_OUT/sim_build" >/dev/null 2>&1
make SIM_BUILD="$RUN_OUT/sim_build" \
     COCOTB_RESULTS_FILE="$RUN_OUT/results.xml" \
     DESIGN_ROOT="$RTL_ROOT"
rc=$?

# cocotb can exit 0 with failures recorded in the XML -- trust the XML.
if grep -q "<failure" "$RUN_OUT/results.xml" 2>/dev/null; then rc=1; fi
if [ ! -s "$RUN_OUT/results.xml" ]; then rc=1; fi

echo "=== bypass_antenna EXIT $rc $(date --iso-8601=seconds) ==="
exit $rc
