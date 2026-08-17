#!/bin/bash
# Drive cocotb/weight_gen_spi_flow: the firmware weight-generation flow over
# the real SPI register interface, checked bit-exactly against the sim/models
# oracle. This is the only suite covering the eigenvector weight path, and it
# is the one that closed Open Risk #33.
#
# NOTE: this suite imports sim/models -- the NFS design tree must have sim/
# synced, not just src/. A src-only sync fails at import, not at runtime.
set -uo pipefail

RTL_ROOT=${RTL_ROOT:-/foss/designs/lora-mimo}
if [ ! -d "$RTL_ROOT/src" ] && [ -d /foss/designs/src ]; then RTL_ROOT=/foss/designs; fi
RUN_OUT=${RUN_DIR:-/foss/runs}
mkdir -p "$RUN_OUT"
export SHARED_DIR=${SHARED_DIR:-/foss/shared}

LOG=$RUN_OUT/weight_gen_spi_flow.log
exec > >(tee "$LOG") 2>&1
echo "=== weight_gen_spi_flow START $(date --iso-8601=seconds) on $(hostname) ==="
echo "RTL_ROOT=$RTL_ROOT  RUN_OUT=$RUN_OUT  SHARED_DIR=$SHARED_DIR"

# Fail loudly and early if sim/ is missing rather than emitting a confusing
# ModuleNotFoundError from inside cocotb.
for m in sim/models/eigvec_fw.py sim/models/receiver.py sim/models/weight_generation.py; do
    if [ ! -f "$RTL_ROOT/$m" ]; then
        echo "FATAL: $RTL_ROOT/$m missing -- sync sim/ to the design tree, not just src/"
        exit 2
    fi
done

cd "$RTL_ROOT/cocotb/weight_gen_spi_flow"
make clean SIM_BUILD="$RUN_OUT/sim_build" >/dev/null 2>&1
make SIM_BUILD="$RUN_OUT/sim_build" \
     COCOTB_RESULTS_FILE="$RUN_OUT/results.xml" \
     DESIGN_ROOT="$RTL_ROOT"
rc=$?

# cocotb can exit 0 with failures recorded in the XML -- trust the XML.
if grep -q "<failure" "$RUN_OUT/results.xml" 2>/dev/null; then rc=1; fi
if [ ! -s "$RUN_OUT/results.xml" ]; then rc=1; fi

echo "=== weight_gen_spi_flow EXIT $rc $(date --iso-8601=seconds) ==="
exit $rc
