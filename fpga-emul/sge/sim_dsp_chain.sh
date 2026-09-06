#!/bin/bash
# Functional end-to-end sim through fpga_dsp_wrap (Verilator).
# Submit with:  hqsub --project lora-mimo .../fpga-emul/sge/sim_dsp_chain.sh
# --project mounts the project at /foss/designs (read-only), so build in $RUN_DIR.
set -uo pipefail
OUT=${RUN_DIR:-/foss/runs}
echo "RUN_DIR=$OUT  JOB_ID=${JOB_ID:-?}"
mkdir -p "$OUT/build"
cp -r /foss/designs/fpga-emul "$OUT/build/fpga-emul"
cp -r /foss/designs/src       "$OUT/build/src"
cd "$OUT/build/fpga-emul"
rm -rf obj_dir_dsp_chain
verilator --version || { echo "NO VERILATOR"; exit 127; }

echo "======== make sim_dsp_chain ========"
make sim_dsp_chain
rc=$?
echo "sim_dsp_chain exit=$rc"
exit $rc
