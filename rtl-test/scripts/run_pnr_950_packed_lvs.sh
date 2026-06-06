#!/bin/bash
set -euo pipefail
export HLAB_SGE_URL=http://nas.home:4783
LOG=/foss/designs/lora-mimo/rtl-test/ol_mimo_rx_top_950_packed_lvs.log
exec > >(tee "$LOG") 2>&1
echo "=== ol_mimo_rx_top 950 packed LVS START $(date --iso-8601=seconds) ==="
cd /foss/designs/lora-mimo/rtl-test
/foss/tools/bin/librelane --pdk gf180mcuD --scl gf180mcu_fd_sc_mcu7t5v0 \
    ol_mimo_rx_top/config_trial_top_950_packed_lvs.json
echo "=== ol_mimo_rx_top 950 packed LVS EXIT $? $(date --iso-8601=seconds) ==="
