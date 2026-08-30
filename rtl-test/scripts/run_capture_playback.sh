#!/bin/bash
# Drive the canonical cocotb/trouper_capture suite (test_capture_playback.py)
# against a real measured LoRa IQ capture. Defaults to a capture served from
# the hlab-sge shared_data_dir mount (read-only, present automatically in
# every job as $SHARED_DIR/foss/shared) rather than requiring a capture file
# to be staged into the design tree — override CAPTURE_NPY/CAPTURE_SF/
# CAPTURE_BW to use a different one.
set -euo pipefail

RTL_ROOT=${RTL_ROOT:-/foss/designs/lora-mimo}
if [ ! -d "$RTL_ROOT/src" ] && [ -d /foss/designs/src ]; then RTL_ROOT=/foss/designs; fi
echo "RTL_ROOT=$RTL_ROOT"

# /foss/designs is read-only under SGE (see .claude/skills/sge-job/SKILL.md) —
# cocotb's sim_build/ and results.xml, and this script's own log, must all
# land under $RUN_DIR (writable), not next to the read-only source tree.
RUN_OUT=${RUN_DIR:-/foss/runs}
mkdir -p "$RUN_OUT"

SHARED=${SHARED_DIR:-/foss/shared}
CAPTURE_NPY=${CAPTURE_NPY:-$SHARED/lora-mimo-captures/captures/lora_20260621_092430_SF7-BW125-Pre8.npy}
CAPTURE_SF=${CAPTURE_SF:-7}
CAPTURE_BW=${CAPTURE_BW:-125}
# Defaults (CAPTURE_START=0/NSAMP=60000) don't reliably land on the packet
# burst (see .claude/skills/block-regression/SKILL.md) — window below was
# computed via cocotb/tests/sweep_captures.py against this specific file.
CAPTURE_START=${CAPTURE_START:-360482}
CAPTURE_NSAMP=${CAPTURE_NSAMP:-49152}

LOG=$RUN_OUT/capture_playback.log
exec > >(tee "$LOG") 2>&1
echo "=== cocotb trouper_capture (test_capture_playback) START $(date --iso-8601=seconds) on $(hostname) ==="
echo "RUN_OUT=$RUN_OUT"
echo "CAPTURE_NPY=$CAPTURE_NPY"
echo "SHARED_DIR=$SHARED"

cd "$RTL_ROOT/cocotb/trouper_capture"
make clean SIM_BUILD="$RUN_OUT/sim_build" COCOTB_RESULTS_FILE="$RUN_OUT/results.xml"
make SIM_BUILD="$RUN_OUT/sim_build" COCOTB_RESULTS_FILE="$RUN_OUT/results.xml" \
    DESIGN_ROOT="$RTL_ROOT" CAPTURE_NPY="$CAPTURE_NPY" CAPTURE_SF="$CAPTURE_SF" CAPTURE_BW="$CAPTURE_BW" \
    CAPTURE_START="$CAPTURE_START" CAPTURE_NSAMP="$CAPTURE_NSAMP"
echo "=== cocotb trouper_capture EXIT $? $(date --iso-8601=seconds) ==="
