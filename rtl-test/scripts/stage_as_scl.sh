#!/bin/bash
# Stage the Avalon as_sc_mcu7t3v3 3.3V 7-track SCL into a writable PDK overlay.
# Unlike OSU, this library ships a complete pdk/ tree (libs.ref + librelane
# config.tcl with tap/endcap/diode/tie/fill cells + full tt/ss/ff corners), so
# staging just drops it into the overlay. /foss/pdks is read-only -> overlay in
# /tmp, run librelane with --pdk-root.
# Usage: stage_as_scl.sh <overlay_root>
set -euo pipefail
SCL=gf180mcu_as_sc_mcu7t3v3
OVR="${1:?usage: $0 <overlay_root>}"
REAL=/foss/pdks/gf180mcuD
SRC=/foss/designs/lora-mimo/ip/gf180mcu_as_sc_mcu7t3v3/pdk
if [ -d "$REAL/libs.tech/librelane" ]; then TSUB=librelane; else TSUB=openlane; fi

echo "[stage] writable overlay ${OVR}/gf180mcuD (tech subdir: $TSUB); SCL=$SCL"
rm -rf "$OVR"; mkdir -p "$OVR/gf180mcuD"
for e in "$REAL"/*; do ln -s "$e" "$OVR/gf180mcuD/$(basename "$e")"; done
rm "$OVR/gf180mcuD/libs.ref" "$OVR/gf180mcuD/libs.tech"
mkdir -p "$OVR/gf180mcuD/libs.ref" "$OVR/gf180mcuD/libs.tech"
for e in "$REAL"/libs.ref/*;  do ln -s "$e" "$OVR/gf180mcuD/libs.ref/$(basename "$e")"; done
for e in "$REAL"/libs.tech/*; do ln -s "$e" "$OVR/gf180mcuD/libs.tech/$(basename "$e")"; done
rm "$OVR/gf180mcuD/libs.tech/$TSUB"; mkdir -p "$OVR/gf180mcuD/libs.tech/$TSUB"
for e in "$REAL"/libs.tech/$TSUB/*; do ln -s "$e" "$OVR/gf180mcuD/libs.tech/$TSUB/$(basename "$e")"; done

# libs.ref: symlink the submodule's library files (verified to match the PDK
# config's cell names). libs.tech: COPY the PDK's OWN as_sc config dir (the
# complete LibreLane-format config — NOT the submodule's caravel/OpenLane one),
# then add no_synth.cells (the PDK top config's NO_SYNTH_CELL_LIST expects that
# name; as_sc ships synth_exclude.cells).
rm -rf "$OVR/gf180mcuD/libs.ref/$SCL" "$OVR/gf180mcuD/libs.tech/$TSUB/$SCL"
ln -s "$SRC/libs.ref/$SCL" "$OVR/gf180mcuD/libs.ref/$SCL"
cp -rL "$REAL/libs.tech/$TSUB/$SCL" "$OVR/gf180mcuD/libs.tech/$TSUB/$SCL"
SCLT="$OVR/gf180mcuD/libs.tech/$TSUB/$SCL"
[ -f "$SCLT/no_synth.cells" ] || { [ -f "$SCLT/synth_exclude.cells" ] && cp "$SCLT/synth_exclude.cells" "$SCLT/no_synth.cells" || : > "$SCLT/no_synth.cells"; }
[ -f "$SCLT/drc_exclude.cells" ] || : > "$SCLT/drc_exclude.cells"
# PDK-load requires TIMING_VIOLATION_CORNERS; the as_sc config omits it and the
# default isn't resolving here. Set the proven 5V value (tt-corner glob).
grep -q TIMING_VIOLATION_CORNERS "$SCLT/config.tcl" || echo 'set ::env(TIMING_VIOLATION_CORNERS) "*tt*"' >> "$SCLT/config.tcl"
echo "[stage] done. SCL tech files:"; ls "$SCLT"; echo "lib corners:"; ls "$SRC/libs.ref/$SCL/lib"/*.lib | grep -vi template
