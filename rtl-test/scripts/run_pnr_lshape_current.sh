#!/usr/bin/env bash
# L-shape floorplan, PROMOTED WORKING BASELINE (2026-08-19).
#
# Geometry unchanged from the original trial: 1100x1100 main lobe + 550x550
# leg (east, southern half), DIE 1650x1100, NE 550x550 corner obstructed and
# reserved for the Grouper project. See lshape-1100-550-floorplan-2026-08.md
# for the original trial and the 2026-08-19 update section for what changed
# to reach this clean signoff:
#
#   1. io_placement_lshape.cfg re-pinned from #S/#W (an unrelated
#      "board-realistic" convention borrowed from io_placement_bl.cfg) to
#      #N/#W -- the padframe's upper-left-quadrant assignment means only the
#      die's N and W edges are real, bondable padframe boundary; S and E are
#      interior seams facing neighbor projects.
#   2. That swap initially broke legalization (DPL-0036 on a single instance,
#      "input23", an IQ_DATA_I_3 input buffer). Root cause: FP_OBSTRUCTIONS
#      only blocks cell placement, it does not reshape DIE_AREA, so
#      CustomIOPlacement spreads #N pins across the FULL 1650 um top edge --
#      any #N pin past x=1100 lands directly above the obstructed NE notch,
#      a placement dead zone bounded by the die edge on two sides. Fixed by
#      appending a "$16" spacer after the #N real-pin group so the
#      proportional spread keeps all real pins within the legal x:0-1100
#      span. (PL_TARGET_DENSITY_PCT and PL_MAX_DISPLACEMENT_Y were both
#      tried and ruled out first -- this was never a density/legalization-
#      search-radius problem, it was pin geometry.)
#   3. Cleared that, then hit the pre-existing, previously-documented
#      DRT-1231 clkbuf-access-point class of failure (see
#      project_drt1231_clkbuf memory / this file's git blame) on detailed
#      routing. Fixed with the already-known recipe: DPL_CELL_PADDING 1->3
#      (CTS_ROOT_BUFFER=clkbuf_16 and CTS_CLK_BUFFERS=8/12/16, i.e. no
#      clkbuf_4/20, were already in place).
#
# Result (SGE job 4496, 2026-08-19): full 77-step flow complete.
#   nom_tt_025C_3v30 WNS =  0.0 ns (met)
#   max_ff_n40C_3v60 WNS =  0.0 ns (met)
#   max_ss_125C_3v00 WNS = -17.96 ns (TNS -5277 ns; chronic FD-cell-at-3V
#                                      corner issue, not a regression)
#   Magic DRC = 0, KLayout DRC (final iter) = 0, LVS = 0 mismatches
#
# config_lshape_current.json is a straight copy of
# config_lshape_1100_550_v26_pins_ymax400_pad3.json -- kept as a stable
# filename for "the current L-shape baseline" per the config_current.json/
# config_current_signoff.json naming convention used by the main floorplan
# family. n=1 on this exact config; re-run before treating WNS as settled
# (see the original trial's repair-lottery caveat).
set -euo pipefail
export PDK_ROOT=/foss/pdks
export PDK=gf180mcuD
export STD_CELL_LIBRARY=gf180mcu_fd_sc_mcu7t5v0
# PDN_KEEPOUT_REGION is read by pdn_cfg.tcl as a raw shell env var
# ($::env(PDN_KEEPOUT_REGION)), NOT a LibreLane config key -- putting it in
# the JSON config is a silent no-op (confirmed 2026-08-19: job 4497's own
# _env.tcl for the GeneratePDN step had no trace of it, and PDN stripes/vias
# crossed straight through the notch despite the JSON key being set). Must
# be exported here, matching job 4473's proven-working invocation.
export PDN_KEEPOUT_REGION="1100 550 1650 1100"
OUT="${RUN_DIR:-/foss/runs}/trouper_top_lshape_current"
mkdir -p "$OUT/run"
echo "=== L-shape 1100+550 CURRENT BASELINE P&R START $(date --iso-8601=seconds) on $(hostname) ==="
cd /foss/designs/rtl-test
librelane --pdk gf180mcuD --scl gf180mcu_fd_sc_mcu7t5v0 \
  --force-run-dir "$OUT/run" \
  ol_trouper_top/config_lshape_current.json
echo "=== L-shape 1100+550 CURRENT BASELINE P&R COMPLETE $(date --iso-8601=seconds) ==="
