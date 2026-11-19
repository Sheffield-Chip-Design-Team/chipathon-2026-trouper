#!/bin/bash
# NEGATIVE CONTROL: inject a VDD<->VSS short into the bridged GDS, then run the
# EXACT same extract+LVS harness as job 5732. A sound harness must FAIL here.
set -uo pipefail
D=/foss/designs/pd/bridged_lvs
OUT=${RUN_DIR:-/foss/runs}
mkdir -p "$OUT/extraction"
MAGICRC=/foss/pdks/gf180mcuD/libs.tech/magic/gf180mcuD.magicrc
NETGEN_SETUP=/usr/local/lib/python3.12/dist-packages/librelane/scripts/netgen/setup.tcl
SC_SPICE=/foss/pdks/gf180mcuD/libs.ref/gf180mcu_fd_sc_mcu7t5v0/spice/gf180mcu_fd_sc_mcu7t5v0.spice

echo "=== inject short into a copy of the bridged GDS ==="
klayout -b -r "$D/inject_short.py" \
  -rd src="$D/trouper_top_bridged.gds" -rd out="$OUT/trouper_top_shorted.gds" \
  -rd x=800 -rd y0=500 -rd y1=545 -rd layer=34
md5sum "$D/trouper_top_bridged.gds" "$OUT/trouper_top_shorted.gds"

echo; echo "=== extract (same recipe, shorted GDS) ==="
sed "s#trouper_top_bridged.gds#$OUT/trouper_top_shorted.gds#; s#/foss/designs/pd/bridged_lvs/$OUT#$OUT#" \
  "$D/extract_bridged.tcl" > "$OUT/extract_shorted.tcl"
sed -i "s#-o /foss/runs/trouper_top_bridged.spice#-o $OUT/trouper_top_shorted.spice#" "$OUT/extract_shorted.tcl"
grep -nE 'gds read|ext2spice -o' "$OUT/extract_shorted.tcl"
cd "$OUT"
magic -dnull -noconsole -rcfile "$MAGICRC" "$OUT/extract_shorted.tcl" 2>&1 | tail -20
[ -s "$OUT/trouper_top_shorted.spice" ] || { echo "NO SPICE"; exit 3; }

echo; echo "=== LVS (same recipe) ==="
mkdir -p "$OUT/reports"
cat > "$OUT/lvs_script.lvs" <<TCL
set circuit1 [readnet spice $OUT/trouper_top_shorted.spice]
set circuit2 [readnet verilog /dev/null]
readnet spice $SC_SPICE \$circuit2
readnet verilog $D/trouper_top.pnl.v \$circuit2
lvs "\$circuit1 trouper_top" "\$circuit2 trouper_top" $NETGEN_SETUP $OUT/reports/lvs.netgen.rpt -blackbox -json $OUT/reports/lvs.netgen.json
TCL
netgen -batch source "$OUT/lvs_script.lvs" 2>&1 | tee "$OUT/netgen.log" | tail -40

echo; echo "=== EXPECT: mismatch naming VDD/VSS ==="
grep -aE "Circuits match|do not match|match uniquely|merged|Net .*VDD|Net .*VSS|VDD.*VSS|shorted|Final result" "$OUT/reports/lvs.netgen.rpt" 2>/dev/null | tail -30
