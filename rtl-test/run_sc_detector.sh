#!/bin/bash
set -e
LOG=/foss/designs/lora-mimo/rtl-test/ol_sc_detector_rerun.log
exec > >(tee "$LOG") 2>&1
echo "=== ol_sc_detector START $(date --iso-8601=seconds) ==="
cd /foss/designs/lora-mimo/rtl-test
librelane --pdk gf180mcuD --scl gf180mcu_fd_sc_mcu7t5v0 ol_sc_detector/config.json
echo "=== ol_sc_detector EXIT $? $(date --iso-8601=seconds) ==="
