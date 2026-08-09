#!/bin/bash
# Open Risks item 43 -- paced_dsp settle proof regression.
# Runs the four unit-level MCP settle benches (decimator / sc_detector /
# training_acc / mrc_combiner) added for the paced_dsp SDC group.
set -uo pipefail

DESIGN_ROOT=${DESIGN_ROOT:-/foss/designs}
RUN_OUT=${RUN_DIR:-/foss/runs}
SUITES="mcp_decimator_settle mcp_sc_settle mcp_tacc_settle mcp_mrc_settle"
FAILED=""

for suite in $SUITES; do
    echo "=== cocotb/$suite ==="
    OUT="$RUN_OUT/cocotb_$suite"
    mkdir -p "$OUT/sim_build"
    (
        cd "$DESIGN_ROOT/cocotb/$suite"
        make \
            DESIGN_ROOT="$DESIGN_ROOT" \
            SIM_BUILD="$OUT/sim_build" \
            COCOTB_RESULTS_FILE="$OUT/results.xml"
    )
    rc=$?
    if [ "$rc" -eq 0 ]; then
        echo "*** PASSED: cocotb/$suite ***"
    else
        echo "*** FAILED: cocotb/$suite (exit $rc) ***"
        FAILED="$FAILED cocotb/$suite"
    fi
done

echo
echo "===== PACED_DSP SETTLE REGRESSION SUMMARY ====="
if [ -z "$FAILED" ]; then
    echo "ALL TARGETS PASSED"
    exit 0
fi

echo "FAILED TARGETS:$FAILED"
exit 1
