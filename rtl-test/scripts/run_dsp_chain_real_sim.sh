#!/bin/bash
set -euo pipefail

RTL_ROOT=${RTL_ROOT:-/foss/designs/lora-mimo}
if [ ! -d "$RTL_ROOT/src" ] && [ -d /foss/designs/src ]; then RTL_ROOT=/foss/designs; fi
echo "RTL_ROOT=$RTL_ROOT"
RT=$RTL_ROOT/rtl-test
LOG=$RT/dsp_chain_real_sim.log
exec > >(tee "$LOG") 2>&1
echo "=== tb_dsp_chain_real START $(date --iso-8601=seconds) ==="
cd $RT
make sim_dsp_chain_real
echo "=== tb_dsp_chain_real EXIT $? $(date --iso-8601=seconds) ==="
