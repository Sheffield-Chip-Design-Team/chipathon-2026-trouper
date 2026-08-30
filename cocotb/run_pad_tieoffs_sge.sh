#!/bin/bash
# A40 pad-control tie-off contract test (cocotb/pad_tieoffs), for SGE.
#   hqsub --name pad_tieoffs --project lora-mimo --cpus 4 --mem 12G \
#         /foss/designs/cocotb/run_pad_tieoffs_sge.sh
set -uo pipefail
DESIGN_ROOT=${DESIGN_ROOT:-/foss/designs}
RUN_OUT=${RUN_DIR:-/foss/runs}
OUT="$RUN_OUT/cocotb_pad_tieoffs"
mkdir -p "$OUT/sim_build"
cd "$DESIGN_ROOT/cocotb/pad_tieoffs" || exit 2
make DESIGN_ROOT="$DESIGN_ROOT" \
     SIM_BUILD="$OUT/sim_build" \
     COCOTB_RESULTS_FILE="$OUT/results.xml" 2>&1 | tee "$OUT/run.log"
rc=${PIPESTATUS[0]}
grep -oE "TESTS=[0-9]+ PASS=[0-9]+ FAIL=[0-9]+ SKIP=[0-9]+" "$OUT/run.log" | tail -1
[ "$rc" -eq 0 ] && echo "*** PASSED: cocotb/pad_tieoffs" || echo "*** FAILED: cocotb/pad_tieoffs (exit $rc)"
exit $rc
