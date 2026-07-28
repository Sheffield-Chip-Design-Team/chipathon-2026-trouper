#!/bin/bash
set -euo pipefail

RTL_ROOT=${RTL_ROOT:-/foss/designs/lora-mimo}
if [ ! -d "$RTL_ROOT/src" ] && [ -d /foss/designs/src ]; then RTL_ROOT=/foss/designs; fi
echo "RTL_ROOT=$RTL_ROOT"
RT=$RTL_ROOT/rtl-test
OVR=/tmp/pdk_overlay_as_sc
LOG=$RT/ol_picorv32_as_mcu7t3v3_pnr.log
exec > >(tee "$LOG") 2>&1
echo "=== picorv32-on-as_sc_mcu7t3v3 START $(date --iso-8601=seconds) on $(hostname) ==="
cd $RT
./stage_as_scl.sh "$OVR"
echo "--- staged; launching librelane ---"
# Skip OpenROAD.CTS: as_sc clock buffers (clkbuff_4/8/12) and even regular buff_*
# repurposed for CTS hit DRT-0073 on pin access — a library-side clock-net
# routing defect (same buff_16 cell routes fine in the data path). Bypassing
# CTS routes the clock as a high-fanout signal so we can produce a layout +
# die area for the area comparison. Timing is upper-bound, not signoff-quality.
# To revisit: fix the as_sc clock-buffer pin geometry upstream.
/foss/tools/bin/librelane --pdk-root "$OVR" --pdk gf180mcuD --scl gf180mcu_as_sc_mcu7t3v3 \
    --skip Magic.SpiceExtraction --skip OpenROAD.CTS \
    ol_picorv32_as_mcu7t3v3/config.json
echo "=== picorv32-on-as_sc EXIT $? $(date --iso-8601=seconds) ==="
