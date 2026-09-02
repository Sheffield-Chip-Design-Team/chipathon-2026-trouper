#!/bin/bash
# Full A40 P&R of trouper_top, including ARRAY_ACQ_N + DBG0_OUT/DBG1_OUT.
#
# Uses the canonical src/config/trouper_top.json, last validated by job 5379
# (0 antenna / 0 DRC / 0 XOR / 0 LVS; SS WNS -10.13 ns, TNS -383.5, worst IR drop
# 3.61 mV VDD / 2.15 mV VSS). That config was collapsed on 2026-09-01 from the
# trouper_top_dbgpins.json chain and on 2026-09-02 from the trouper_top_pdn_*
# PDN chain. NOT comparable with jobs 5279/5284/5286: those predate the
# 2026-09-01 Grouper-boundary removal and run a different netlist (35670 vs
# 35300 cells). The same-netlist stock-PDN control is job 5378 (SS WNS -11.17 ns,
# TNS -336.1) -- compare against that, not against 5286.
set -euo pipefail
export PDK_ROOT=/foss/pdks
export PDK=gf180mcuD
export STD_CELL_LIBRARY=gf180mcu_fd_sc_mcu7t5v0

OUT=${RUN_DIR:-/foss/runs}/dbgpins
mkdir -p "$OUT/run"
cd /foss/designs
librelane --pdk "$PDK" --scl "$STD_CELL_LIBRARY" \
          --force-run-dir "$OUT/run" \
          src/config/trouper_top.json
