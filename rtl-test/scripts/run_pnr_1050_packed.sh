#!/bin/bash
set -euo pipefail

RTL_ROOT=${RTL_ROOT:-/foss/designs/lora-mimo}
if [ ! -d "$RTL_ROOT/src" ] && [ -d /foss/designs/src ]; then RTL_ROOT=/foss/designs; fi
echo "RTL_ROOT=$RTL_ROOT"
RT=$RTL_ROOT/rtl-test
export HLAB_SGE_URL=http://nas.home:4783
LOG=$RT/ol_trouper_top_1050_packed.log
exec > >(tee "$LOG") 2>&1
echo "=== ol_trouper_top 1050 packed START $(date --iso-8601=seconds) ==="
cd $RT
/foss/tools/bin/librelane --pdk gf180mcuD --scl gf180mcu_fd_sc_mcu7t5v0 \
    --skip Magic.SpiceExtraction \
    ol_trouper_top/config_trial_top_1050_packed.json
echo "=== ol_trouper_top 1050 packed EXIT $? $(date --iso-8601=seconds) ==="
