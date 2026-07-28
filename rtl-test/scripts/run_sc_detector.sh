#!/bin/bash
set -e

RTL_ROOT=${RTL_ROOT:-/foss/designs/lora-mimo}
if [ ! -d "$RTL_ROOT/src" ] && [ -d /foss/designs/src ]; then RTL_ROOT=/foss/designs; fi
echo "RTL_ROOT=$RTL_ROOT"
RT=$RTL_ROOT/rtl-test
LOG=$RT/ol_sc_detector_rerun.log
exec > >(tee "$LOG") 2>&1
echo "=== ol_sc_detector START $(date --iso-8601=seconds) ==="
cd $RT
librelane --pdk gf180mcuD --scl gf180mcu_fd_sc_mcu7t5v0 ol_sc_detector/config.json
echo "=== ol_sc_detector EXIT $? $(date --iso-8601=seconds) ==="
