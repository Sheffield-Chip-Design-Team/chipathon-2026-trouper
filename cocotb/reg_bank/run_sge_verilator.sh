#!/bin/bash
# reg_bank suite forced onto Verilator, to cross-check the RX_HOLD tests that
# job 4353 verified under the suite's default (Icarus).
set -uo pipefail
DESIGN_ROOT=${DESIGN_ROOT:-/foss/designs}
RUN_OUT=${RUN_DIR:-/foss/runs}
mkdir -p "$RUN_OUT/sim_build"
cd "$DESIGN_ROOT/cocotb/reg_bank"
make SIM=verilator \
     EXTRA_ARGS="--timing -Wno-fatal --public-flat-rw" \
     DESIGN_ROOT="$DESIGN_ROOT" \
     SIM_BUILD="$RUN_OUT/sim_build" \
     COCOTB_RESULTS_FILE="$RUN_OUT/results.xml"
