#!/bin/bash
# Stage an OSU 3.3V SCL into a WRITABLE PDK overlay so LibreLane's `--scl` finds
# it. The container's /foss/pdks is READ-ONLY, so we build an overlay in /tmp:
# symlink every entry of the real gf180mcuD, but make libs.ref + libs.tech +
# libs.tech/openlane real (writable) dirs of symlinks so we can drop the OSU SCL
# in. Run librelane with --pdk-root <overlay>.
# LibreLane reads libs.tech/openlane/<scl>/config.tcl and derives lib/lef/gds/
# techlef from libs.ref/<scl>/ (see ol_picorv32_osu_gp9t3v3/INTEGRATION.md).
# OSU ships only TT_25C -> all corner libs symlink to it; tracks.info reused
# from the 5V SCL (layer-agnostic); synth map/cells files created empty.
# Usage: stage_osu_scl.sh <scl> <overlay_root>
set -euo pipefail
SCL="${1:?usage: $0 <scl> <overlay_root>}"
OVR="${2:?usage: $0 <scl> <overlay_root>}"
REAL=/foss/pdks/gf180mcuD
SRC=/foss/designs/lora-mimo/ip/gf180mcu_osu_sc/${SCL}
SCLCFG=/foss/designs/lora-mimo/ip/gf180mcu_osu_sc/librelane_scl/${SCL}/config.tcl

# Newer images (2026.04) use libs.tech/librelane; older (:latest) use openlane.
if [ -d "$REAL/libs.tech/librelane" ]; then TSUB=librelane; else TSUB=openlane; fi
echo "[stage] building writable PDK overlay at ${OVR}/gf180mcuD (tech subdir: $TSUB)"
rm -rf "$OVR"; mkdir -p "$OVR/gf180mcuD"
# top level: symlink everything, then override libs.ref + libs.tech as real dirs
for e in "$REAL"/*; do ln -s "$e" "$OVR/gf180mcuD/$(basename "$e")"; done
rm "$OVR/gf180mcuD/libs.ref" "$OVR/gf180mcuD/libs.tech"
mkdir -p "$OVR/gf180mcuD/libs.ref" "$OVR/gf180mcuD/libs.tech"
for e in "$REAL"/libs.ref/*;  do ln -s "$e" "$OVR/gf180mcuD/libs.ref/$(basename "$e")";  done
for e in "$REAL"/libs.tech/*; do ln -s "$e" "$OVR/gf180mcuD/libs.tech/$(basename "$e")"; done
rm "$OVR/gf180mcuD/libs.tech/$TSUB"
mkdir -p "$OVR/gf180mcuD/libs.tech/$TSUB"
for e in "$REAL"/libs.tech/$TSUB/*; do ln -s "$e" "$OVR/gf180mcuD/libs.tech/$TSUB/$(basename "$e")"; done

REF="$OVR/gf180mcuD/libs.ref/${SCL}"
TECH="$OVR/gf180mcuD/libs.tech/$TSUB/${SCL}"
TECH5="$REAL/libs.tech/$TSUB/gf180mcu_fd_sc_mcu7t5v0"
echo "[stage] adding OSU SCL ${SCL}"
mkdir -p "$REF"/{lib,lef,gds,techlef,cdl} "$TECH"

TTLIB="${SRC}/lib/${SCL}_TT_25C.ccs.lib"
ln -sf "$TTLIB" "$REF/lib/${SCL}_TT_25C.ccs.lib"
# DOUBLE-underscore corner names: LibreLane pdk_compat parses pvt via split("__")[1].
# OSU is TT-only -> all three 3.3V corners symlink to the single TT lib.
ln -sf "$TTLIB" "$REF/lib/${SCL}__tt_025C_3v30.lib"
ln -sf "$TTLIB" "$REF/lib/${SCL}__ff_n40C_3v60.lib"
ln -sf "$TTLIB" "$REF/lib/${SCL}__ss_125C_3v00.lib"
ln -sf "${SRC}/lef/${SCL}.lef"   "$REF/lef/${SCL}.lef"
ln -sf "${SRC}/tlef/${SCL}.tlef" "$REF/techlef/${SCL}__nom.tlef"
ln -sf "${SRC}/tlef/${SCL}.tlef" "$REF/techlef/${SCL}__min.tlef"
ln -sf "${SRC}/tlef/${SCL}.tlef" "$REF/techlef/${SCL}__max.tlef"
ln -sf "${SRC}/gds/${SCL}.gds"   "$REF/gds/${SCL}.gds"
[ -f "${SRC}/spice/${SCL}.spice" ] && ln -sf "${SRC}/spice/${SCL}.spice" "$REF/cdl/${SCL}.cdl" || : > "$REF/cdl/${SCL}.cdl"

cp "$SCLCFG" "$TECH/config.tcl"
cp "$TECH5/tracks.info" "$TECH/tracks.info"
: > "$TECH/no_synth.cells"; : > "$TECH/drc_exclude.cells"
for m in latch_map tribuff_map fa_map rca_map csa_map; do : > "$TECH/${m}.v"; done

echo "[stage] done. overlay scl libs:"; ls "$REF"/lib "$REF"/techlef
