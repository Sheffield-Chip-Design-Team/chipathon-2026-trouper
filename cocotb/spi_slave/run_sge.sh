#!/bin/bash
# One-off SGE entry point for the standalone spi_slave suite.
# With `hqsub --project lora-mimo`, the project root is /foss/designs and is
# read-only; all simulator products therefore go under the writable RUN_DIR.
set -euo pipefail

DESIGN_ROOT=${DESIGN_ROOT:-/foss/designs}
RUN_OUT=${RUN_DIR:-/foss/runs}

mkdir -p "$RUN_OUT/sim_build"
cd "$DESIGN_ROOT/cocotb/spi_slave"

make \
    DESIGN_ROOT="$DESIGN_ROOT" \
    SIM_BUILD="$RUN_OUT/sim_build" \
    COCOTB_RESULTS_FILE="$RUN_OUT/results.xml"
