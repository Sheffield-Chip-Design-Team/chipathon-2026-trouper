#!/bin/bash
# Stage an OSU 3.3V SCL into a writable PDK overlay, then P&R picorv32 on it.
# Usage: run_picorv32_osu.sh <scl> <config_subdir>
#   e.g. run_picorv32_osu.sh gf180mcu_osu_sc_gp9t3v3 ol_picorv32_osu_gp9t3v3
set -euo pipefail

RTL_ROOT=${RTL_ROOT:-/foss/designs/lora-mimo}
if [ ! -d "$RTL_ROOT/src" ] && [ -d /foss/designs/src ]; then RTL_ROOT=/foss/designs; fi
echo "RTL_ROOT=$RTL_ROOT"
RT=$RTL_ROOT/rtl-test
SCL="${1:?usage: $0 <scl> <config_subdir>}"
CFGDIR="${2:?usage: $0 <scl> <config_subdir>}"
OVR=/tmp/pdk_overlay_${SCL}
LOG=$RT/${CFGDIR}_pnr.log
exec > >(tee "$LOG") 2>&1
echo "=== picorv32-on-${SCL} START $(date --iso-8601=seconds) on $(hostname) ==="
cd $RT
./stage_osu_scl.sh "$SCL" "$OVR"
echo "--- staged; launching librelane (--pdk-root ${OVR}) ---"
# Skips: Magic.SpiceExtraction = macro OBS-vs-M2 overlap artifact (see mimo notes);
# OpenROAD.CutRows = tap/endcap insertion, which OSU has no cells for (tapless test
# build) and errors TAP-0034 on the empty FP_WELLTAP_CELL. Both must be revisited
# for tapout signoff.
/foss/tools/bin/librelane --pdk-root "$OVR" --pdk gf180mcuD --scl "$SCL" \
    --skip Magic.SpiceExtraction --skip OpenROAD.CutRows \
    ${CFGDIR}/config.json
echo "=== picorv32-on-${SCL} EXIT $? $(date --iso-8601=seconds) ==="
