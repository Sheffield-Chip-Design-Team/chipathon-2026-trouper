#!/bin/bash
# LVS the BRIDGED trouper_top macro vs final/pnl/trouper_top.pnl.v.
# Magic extracts the bridged GDS (std cells LEF-abstracted -> top-level
# interconnect only, same class as the base-streamout flow LVS), then netgen
# compares -blackbox exactly as LibreLane step 70 did. Closes the
# "flow LVS runs on the base streamout, not the bridged GDS" gap.
set -uo pipefail

D=/foss/designs/pd/bridged_lvs
OUT=${RUN_DIR:-/foss/runs}
mkdir -p "$OUT/extraction"
MAGICRC=/foss/pdks/gf180mcuD/libs.tech/magic/gf180mcuD.magicrc
NETGEN_SETUP=/usr/local/lib/python3.12/dist-packages/librelane/scripts/netgen/setup.tcl
SC_SPICE=/foss/pdks/gf180mcuD/libs.ref/gf180mcu_fd_sc_mcu7t5v0/spice/gf180mcu_fd_sc_mcu7t5v0.spice
PNL=$D/trouper_top.pnl.v

echo "=== inputs ==="
md5sum "$D/trouper_top_bridged.gds"
[ -f "$NETGEN_SETUP" ] || NETGEN_SETUP=/foss/pdks/gf180mcuD/libs.tech/netgen/gf180mcuD_setup.tcl
echo "netgen setup: $NETGEN_SETUP"

echo; echo "=== 1. Magic extraction (bridged GDS, std cells abstracted) ==="
cd "$OUT"
magic -dnull -noconsole -rcfile "$MAGICRC" "$D/extract_bridged.tcl" 2>&1 | tee "$OUT/magic_ext.log"
echo "magic exit: ${PIPESTATUS[0]}"
if [ ! -s "$OUT/trouper_top_bridged.spice" ]; then echo "NO SPICE PRODUCED"; exit 3; fi
echo "spice lines: $(wc -l < "$OUT/trouper_top_bridged.spice")"
head -12 "$OUT/trouper_top_bridged.spice"
echo "... top subckt line:"; grep -nE '^\.subckt trouper_top ' "$OUT/trouper_top_bridged.spice" | head -1

echo; echo "=== 2. Netgen LVS vs pnl.v ==="
mkdir -p "$OUT/reports"
cat > "$OUT/lvs_script.lvs" <<TCL
set circuit1 [readnet spice $OUT/trouper_top_bridged.spice]
set circuit2 [readnet verilog /dev/null]
readnet spice $SC_SPICE \$circuit2
readnet verilog $PNL \$circuit2
lvs "\$circuit1 trouper_top" "\$circuit2 trouper_top" $NETGEN_SETUP $OUT/reports/lvs.netgen.rpt -blackbox -json $OUT/reports/lvs.netgen.json
TCL
netgen -batch source "$OUT/lvs_script.lvs" 2>&1 | tee "$OUT/netgen.log"
echo "netgen exit: ${PIPESTATUS[0]}"

echo; echo "=== VERDICT ==="
grep -aE "Circuits match|do not match|match uniquely|Final result|Net count|Device count|Netlists" "$OUT/reports/lvs.netgen.rpt" 2>/dev/null | tail -30
echo "---- rpt tail 70 ----"
tail -70 "$OUT/reports/lvs.netgen.rpt" 2>/dev/null
