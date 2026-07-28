#!/bin/bash
set -e

RTL_ROOT=${RTL_ROOT:-/foss/designs/lora-mimo}
if [ ! -d "$RTL_ROOT/src" ] && [ -d /foss/designs/src ]; then RTL_ROOT=/foss/designs; fi
echo "RTL_ROOT=$RTL_ROOT"
RT=$RTL_ROOT/rtl-test
LOG=$RT/ol_trouper_top_run1.log
exec > >(tee "$LOG") 2>&1
echo "=== ol_trouper_top START $(date --iso-8601=seconds) ==="
cd $RT
librelane --pdk gf180mcuD --scl gf180mcu_fd_sc_mcu7t5v0 ol_trouper_top/config.json
echo "=== ol_trouper_top EXIT $? $(date --iso-8601=seconds) ==="
