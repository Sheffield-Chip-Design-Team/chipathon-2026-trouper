#!/bin/bash
# Full A40 P&R of trouper_top including ARRAY_ACQ_N + DBG0_OUT/DBG1_OUT.
#
# Uses src/config/trouper_top_dbgpins.json = the job-5214 signoff config with
# the floorplan template extended for the three pads the integrator DEF
# predates. The antenna-closure recipe (DIODE_PADDING 4, DPL_CELL_PADDING 2,
# mixed GRT/DRT repair, 65% density) is carried through unchanged, so the
# result is directly comparable with 5214's 0 antenna / 0 DRC / 0 LVS.
set -euo pipefail
export PDK_ROOT=/foss/pdks
export PDK=gf180mcuD
export STD_CELL_LIBRARY=gf180mcu_fd_sc_mcu7t5v0

OUT=${RUN_DIR:-/foss/runs}/dbgpins
mkdir -p "$OUT/run"
cd /foss/designs
librelane --pdk "$PDK" --scl "$STD_CELL_LIBRARY" \
          --force-run-dir "$OUT/run" \
          src/config/trouper_top_dbgpins.json
