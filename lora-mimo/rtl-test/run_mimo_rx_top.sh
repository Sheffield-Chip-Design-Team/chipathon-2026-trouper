#!/bin/bash
set -e
LOG=/foss/designs/lora-mimo/rtl-test/ol_mimo_rx_top_run1.log
exec > >(tee "$LOG") 2>&1
echo "=== ol_mimo_rx_top START $(date --iso-8601=seconds) ==="
cd /foss/designs/lora-mimo/rtl-test
librelane --pdk gf180mcuD --scl gf180mcu_fd_sc_mcu7t5v0 ol_mimo_rx_top/config.json
echo "=== ol_mimo_rx_top EXIT $? $(date --iso-8601=seconds) ==="
