#!/bin/bash
set -euo pipefail
LOG=/foss/designs/lora-mimo/rtl-test/dsp_chain_real_sim.log
exec > >(tee "$LOG") 2>&1
echo "=== tb_dsp_chain_real START $(date --iso-8601=seconds) ==="
cd /foss/designs/lora-mimo/rtl-test
make sim_dsp_chain_real
echo "=== tb_dsp_chain_real EXIT $? $(date --iso-8601=seconds) ==="
