#!/bin/bash
# Padring integration test (cocotb/padring_integration), for SGE.  icarus:
# drives trouper_top through the real A40_ACV_padring.v + gf180mcu_fd_io models.
#   hqsub --name padring_integration --project lora-mimo --cpus 4 --mem 12G \
#         /foss/designs/cocotb/run_padring_integration_sge.sh
set -uo pipefail
DESIGN_ROOT=${DESIGN_ROOT:-/foss/designs}
RUN_OUT=${RUN_DIR:-/foss/runs}
OUT="$RUN_OUT/cocotb_padring_integration"
mkdir -p "$OUT/sim_build"
cd "$DESIGN_ROOT/cocotb/padring_integration" || exit 2
make DESIGN_ROOT="$DESIGN_ROOT" \
     SIM_BUILD="$OUT/sim_build" \
     COCOTB_RESULTS_FILE="$OUT/results.xml" 2>&1 | tee "$OUT/run.log"
rc=${PIPESTATUS[0]}
grep -oE "TESTS=[0-9]+ PASS=[0-9]+ FAIL=[0-9]+ SKIP=[0-9]+" "$OUT/run.log" | tail -1
[ "$rc" -eq 0 ] && echo "*** PASSED: cocotb/padring_integration" || echo "*** FAILED: cocotb/padring_integration (exit $rc)"
exit $rc
