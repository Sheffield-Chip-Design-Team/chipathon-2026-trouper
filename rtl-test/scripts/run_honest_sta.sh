#!/bin/bash
# Does the 4.5 V core still close with the multicycle exceptions withdrawn?
#
# Reloads job 3738's routed netlist + SPEF and re-times it twice at the same
# corner: once with the scoped signoff SDC (CONTROL -- must reproduce the
# recorded WNS 0.0, or the harness is not faithful and nothing else counts),
# once with an MCP-free SDC derived from it (HONEST).
#
# Submit:
#   hqsub --name honest_sta --project lora-mimo --cpus 2 --mem 16G \
#         /foss/designs/rtl-test/scripts/run_honest_sta.sh
set -uo pipefail

DESIGN=${DESIGN_ROOT:-/foss/designs}
OUT=${RUN_DIR:-/foss/runs}
mkdir -p "$OUT" || exit 1

# Routed artifacts from the 4.5 V margin run (job 3738). The container sees the
# NFS *designs* tree at /foss/designs but NOT the whole runs tree, so the
# netlist/SPEF must be staged into designs first -- same convention as
# run_mcp_audit.sh. stage_honest_sta_inputs.sh does that copy.
STAGE=${HSTA_STAGE_DIR:-$DESIGN/rtl-test/ol_trouper_top/honest_sta_inputs}
NETLIST=$STAGE/trouper_top.nl.v
SPEF_MAX=$STAGE/trouper_top.max.spef
SPEF_MIN=$STAGE/trouper_top.min.spef

for f in "$NETLIST" "$SPEF_MAX" "$SPEF_MIN"; do
  [ -r "$f" ] || { echo "ERROR: cannot read $f -- run stage_honest_sta_inputs.sh first"; exit 2; }
done

PDK=/foss/pdks/gf180mcuD
SCL=$PDK/libs.ref/gf180mcu_fd_sc_mcu7t5v0
TECH_LEF=$SCL/techlef/gf180mcu_fd_sc_mcu7t5v0__nom.tlef
CELL_LEF=$SCL/lef/gf180mcu_fd_sc_mcu7t5v0.lef

SCOPED_SDC=$DESIGN/src/config/pnr_32m_scoped_v25_b6.sdc
HONEST_SDC=$OUT/pnr_32m_honest_from_v25_b6.sdc
TCL=$DESIGN/rtl-test/ol_trouper_top/honest_sta.tcl

python3 "$DESIGN/rtl-test/scripts/gen_honest_sdc.py" \
        --src "$SCOPED_SDC" --out "$HONEST_SDC" || exit 2

run_sta() {
  local tag=$1 sdc=$2 corner=$3 lib=$4 spef=$5
  echo "=== $tag @ $corner ==="
  HSTA_LIBERTY="$lib" \
  HSTA_TECH_LEF="$TECH_LEF" \
  HSTA_CELL_LEF="$CELL_LEF" \
  HSTA_NETLIST="$NETLIST" \
  HSTA_SPEF="$spef" \
  HSTA_SDC="$sdc" \
  HSTA_CORNER="$corner" \
  HSTA_REPORT="$OUT/${tag}_${corner}.rpt" \
    openroad -exit "$TCL" > "$OUT/${tag}_${corner}.log" 2>&1
  local rc=$?
  grep -E "^HONEST_STA\|(setup|hold)_(wns|tns)\|" "$OUT/${tag}_${corner}.rpt" 2>/dev/null | sed 's/^/   /'
  [ $rc -ne 0 ] && echo "   [sta exit $rc -- see ${tag}_${corner}.log]"
  return 0
}

SS_LIB=$SCL/lib/gf180mcu_fd_sc_mcu7t5v0__ss_125C_4v50.lib
FF_LIB=$SCL/lib/gf180mcu_fd_sc_mcu7t5v0__ff_n40C_3v60.lib

# CONTROL first: if this does not reproduce WNS 0.0 / TNS 0.0, stop reading.
run_sta control $SCOPED_SDC max_ss_125C_4v50 "$SS_LIB" "$SPEF_MAX"
run_sta honest  $HONEST_SDC max_ss_125C_4v50 "$SS_LIB" "$SPEF_MAX"

# Hold: withdrawing the MCP -hold exceptions changes hold too, so check that
# the honest SDC does not trade a setup answer for a hold problem.
run_sta control $SCOPED_SDC max_ff_n40C_3v60 "$FF_LIB" "$SPEF_MIN"
run_sta honest  $HONEST_SDC max_ff_n40C_3v60 "$FF_LIB" "$SPEF_MIN"

echo
echo "=== SUMMARY ==="
for f in "$OUT"/*_max_*.rpt; do
  [ -r "$f" ] || continue
  name=$(basename "$f" .rpt)
  swns=$(grep -m1 "^HONEST_STA|setup_wns|" "$f" | cut -d'|' -f3)
  stns=$(grep -m1 "^HONEST_STA|setup_tns|" "$f" | cut -d'|' -f3)
  hwns=$(grep -m1 "^HONEST_STA|hold_wns|" "$f" | cut -d'|' -f3)
  printf "  %-34s setup WNS=%-12s TNS=%-14s hold WNS=%s\n" "$name" "${swns:-?}" "${stns:-?}" "${hwns:-?}"
done
echo "=== honest STA DONE ==="
