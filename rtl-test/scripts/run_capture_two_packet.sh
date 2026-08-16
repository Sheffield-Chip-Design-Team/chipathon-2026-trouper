#!/bin/bash
# Drive cocotb/capture_two_packet: sc_lock re-arm on a REAL two-packet capture.
#
# LONG RUN (~50 min): spans two bursts ~4.07 M capture samples apart. The gap is
# load-bearing coverage (filter settling, PSRAM pointer wrap, SC counter
# accumulation), not overhead -- do not shorten the window to speed it up.
set -uo pipefail

RTL_ROOT=${RTL_ROOT:-/foss/designs/lora-mimo}
if [ ! -d "$RTL_ROOT/src" ] && [ -d /foss/designs/src ]; then RTL_ROOT=/foss/designs; fi
RUN_OUT=${RUN_DIR:-/foss/runs}
mkdir -p "$RUN_OUT"
export SHARED_DIR=${SHARED_DIR:-/foss/shared}

LOG=$RUN_OUT/capture_two_packet.log
exec > >(tee "$LOG") 2>&1
echo "=== capture_two_packet START $(date --iso-8601=seconds) on $(hostname) ==="
echo "RTL_ROOT=$RTL_ROOT  RUN_OUT=$RUN_OUT  SHARED_DIR=$SHARED_DIR"
echo "NOTE: expect ~50 minutes."

cd "$RTL_ROOT/cocotb/capture_two_packet"
make clean SIM_BUILD="$RUN_OUT/sim_build" >/dev/null 2>&1
make SIM_BUILD="$RUN_OUT/sim_build" \
     COCOTB_RESULTS_FILE="$RUN_OUT/results.xml" \
     DESIGN_ROOT="$RTL_ROOT"
rc=$?

# cocotb can exit 0 with failures recorded in the XML -- trust the XML.
if grep -q "<failure" "$RUN_OUT/results.xml" 2>/dev/null; then rc=1; fi
if [ ! -s "$RUN_OUT/results.xml" ]; then rc=1; fi

echo "=== capture_two_packet EXIT $rc $(date --iso-8601=seconds) ==="
exit $rc
