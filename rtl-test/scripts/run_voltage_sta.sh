#!/bin/bash
# Re-time job 5198's routed netlist (zero antenna, 1675x1110) at the SS corner
# across supply voltages, to show that the -13.15 ns max_ss setup gap is a
# VOLTAGE headroom problem (5V-characterised cells run at 3.0V), not a design
# problem.
#
# 3v00 is the CONTROL: it must reproduce the recorded -13.146 ns, otherwise the
# harness is not faithful and none of the other numbers mean anything.
set -uo pipefail
DESIGN=${DESIGN_ROOT:-/foss/designs}
OUT=${RUN_DIR:-/foss/runs}
mkdir -p "$OUT"
exec > >(tee "$OUT/job.log") 2>&1

PDK=/foss/pdks/gf180mcuD
SCL=$PDK/libs.ref/gf180mcu_fd_sc_mcu7t5v0
export HSTA_TECH_LEF=$SCL/techlef/gf180mcu_fd_sc_mcu7t5v0__nom.tlef
export HSTA_CELL_LEF=$SCL/lef/gf180mcu_fd_sc_mcu7t5v0.lef
S=$DESIGN/rtl-test/ol_trouper_top/vsta_inputs
export HSTA_NETLIST=$S/trouper_top.nl.v
export HSTA_SPEF=$S/trouper_top.max.spef
export HSTA_SDC=$DESIGN/rtl-test/ol_trouper_top/pnr_32m_scoped_v25_b6_signoff.sdc
TCL=$DESIGN/rtl-test/ol_trouper_top/honest_sta.tcl

echo "=== available ss_125C libs ==="
ls "$SCL/lib/" | grep -E "^gf180mcu_fd_sc_mcu7t5v0__ss_125C" || ls "$SCL/lib/"

for V in 3v00 4v50; do
  LIB=$SCL/lib/gf180mcu_fd_sc_mcu7t5v0__ss_125C_${V}.lib
  if [ ! -r "$LIB" ]; then echo "--- ss_125C_${V}: NO LIB, skipped ---"; continue; fi
  echo "=================================================="
  echo "=== SS 125C @ ${V} ==="
  export HSTA_LIBERTY=$LIB
  export HSTA_CORNER=max_ss_125C_${V}
  export HSTA_REPORT=$OUT/sta_ss_${V}.rpt
  openroad -exit "$TCL" > "$OUT/sta_ss_${V}.log" 2>&1
  grep -E "HONEST_STA\|(setup|hold)_(wns|tns)" "$OUT/sta_ss_${V}.rpt" 2>/dev/null | sed 's/^/  /'
done

echo "=================================================="
echo "=== SUMMARY (setup WNS by supply, SS 125C) ==="
for V in 3v00 4v50; do
  R=$OUT/sta_ss_${V}.rpt
  [ -r "$R" ] || continue
  W=$(grep -m1 "HONEST_STA|setup_wns|" "$R" | cut -d'|' -f3)
  H=$(grep -m1 "HONEST_STA|hold_wns|" "$R" | cut -d'|' -f3)
  printf "  ss_125C_%-5s setup WNS = %-22s hold WNS = %s\n" "$V" "$W" "$H"
done
echo "=== EXIT $? $(date --iso-8601=seconds) ==="
