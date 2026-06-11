#!/bin/bash
set -euo pipefail
export HLAB_SGE_URL=http://nas.home:4783
LOG=/foss/designs/lora-mimo/rtl-test/ol_trouper_top_1250_iqsouth.log
exec > >(tee "$LOG") 2>&1
echo "=== ol_trouper_top 1250 IQ-South+PSRAM-East START $(date --iso-8601=seconds) ==="
cd /foss/designs/lora-mimo/rtl-test
/foss/tools/bin/librelane --pdk gf180mcuD --scl gf180mcu_fd_sc_mcu7t5v0 \
    --skip Magic.SpiceExtraction \
    ol_trouper_top/config_trial_top_1250_iqsouth.json
echo "=== ol_trouper_top 1250 IQ-South+PSRAM-East EXIT $? $(date --iso-8601=seconds) ==="
