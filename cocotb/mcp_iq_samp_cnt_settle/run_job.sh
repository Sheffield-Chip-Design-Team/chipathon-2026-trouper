#!/bin/bash
set -uo pipefail
DESIGN_ROOT=${DESIGN_ROOT:-/foss/designs}
RUN_OUT=${RUN_DIR:-/foss/runs}
mkdir -p "$RUN_OUT/sim_build"
cd "$DESIGN_ROOT/cocotb/mcp_iq_samp_cnt_settle"
make DESIGN_ROOT="$DESIGN_ROOT" SIM_BUILD="$RUN_OUT/sim_build" \
     COCOTB_RESULTS_FILE="$RUN_OUT/results.xml"
