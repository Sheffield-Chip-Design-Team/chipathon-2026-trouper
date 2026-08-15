#!/bin/bash
# Measure the sc_clear cone's true slack under the MCP-free SDC.
set -uo pipefail
DESIGN=${DESIGN_ROOT:-/foss/designs}
OUT=${RUN_DIR:-/foss/runs}
mkdir -p "$OUT" || exit 1

STAGE=$DESIGN/rtl-test/ol_trouper_top/honest_sta_inputs
PDK=/foss/pdks/gf180mcuD
SCL=$PDK/libs.ref/gf180mcu_fd_sc_mcu7t5v0

python3 "$DESIGN/rtl-test/scripts/gen_honest_sdc.py" \
        --src "$DESIGN/src/config/pnr_32m_scoped_v25_b6.sdc" \
        --out "$OUT/honest.sdc" || exit 2

HSTA_LIBERTY=$SCL/lib/gf180mcu_fd_sc_mcu7t5v0__ss_125C_4v50.lib \
HSTA_TECH_LEF=$SCL/techlef/gf180mcu_fd_sc_mcu7t5v0__nom.tlef \
HSTA_CELL_LEF=$SCL/lef/gf180mcu_fd_sc_mcu7t5v0.lef \
HSTA_NETLIST=$STAGE/trouper_top.nl.v \
HSTA_SPEF=$STAGE/trouper_top.max.spef \
HSTA_SDC=$OUT/honest.sdc \
HSTA_CORNER=max_ss_125C_4v50 \
HSTA_REPORT=$OUT/sc_clr_slack.rpt \
  openroad -exit "$DESIGN/rtl-test/ol_trouper_top/sc_clr_slack.tcl" > "$OUT/sc_clr_slack.log" 2>&1

grep -E "^SC_CLR_SLACK\|" "$OUT/sc_clr_slack.rpt" 2>/dev/null | head -6
echo "--- worst slacks into the cone:"
grep -E "slack" "$OUT/sc_clr_slack.log" | head -12
echo "=== sc_clr slack probe DONE ==="
