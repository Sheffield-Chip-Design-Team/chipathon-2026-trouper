#!/bin/bash
# Run cocotb/trouper_capture across every labelled real capture in scope
# (BW125/250; BW500 is out of scope for this chip). The per-point window and
# stage come from cocotb/tests/sweep_captures.py, which locates the packet
# burst in each file -- do NOT hand-pick CAPTURE_START/NSAMP, the defaults
# do not reliably land on the burst and produce misleading "sc_lock never
# fired" failures.
#
# Each point runs to completion and its result is recorded; the script does
# not stop at the first failure, so one bad (SF,BW) does not hide the rest.
set -uo pipefail

RTL_ROOT=${RTL_ROOT:-/foss/designs/lora-mimo}
if [ ! -d "$RTL_ROOT/src" ] && [ -d /foss/designs/src ]; then RTL_ROOT=/foss/designs; fi
RUN_OUT=${RUN_DIR:-/foss/runs}
mkdir -p "$RUN_OUT"
SHARED=${SHARED_DIR:-/foss/shared}
CAPTURES=${CAPTURES:-$SHARED/lora-mimo-captures/captures}

LOG=$RUN_OUT/capture_sweep.log
exec > >(tee "$LOG") 2>&1
echo "=== trouper_capture SWEEP START $(date --iso-8601=seconds) on $(hostname) ==="
echo "RTL_ROOT=$RTL_ROOT  RUN_OUT=$RUN_OUT  CAPTURES=$CAPTURES"

BASE=$RUN_OUT/sweep_plan_base.tsv
python3 "$RTL_ROOT/cocotb/tests/sweep_captures.py" "$CAPTURES" > "$BASE"

# The planner emits equal-gain (flat) points only. With flat gains every branch
# lands within 3 dB, so test_capture_playback's ZDIAG rank assertion -- the one
# MIMO-specific check in this suite -- silently *skips* itself. Re-run each
# non-lock point with a deliberate per-antenna gain ordering so that assertion
# actually fires and the chip has to rank the branches by received power.
#
# Skipped for stage=lock (SF12): that stage returns before training, so no
# ZDIAG is ever read and a gains variant would add runtime for no coverage.
GAINS=${SWEEP_GAINS:-0,-3,-6,-9}
PLAN=$RUN_OUT/sweep_plan.tsv
: > "$PLAN"
while IFS=$'\t' read -r npy sf bw start nsamp stage; do
    [ -n "${npy:-}" ] || continue
    printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$npy" "$sf" "$bw" "$start" "$nsamp" "$stage" "" >> "$PLAN"
    if [ "$stage" != "lock" ]; then
        printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$npy" "$sf" "$bw" "$start" "$nsamp" "$stage" "$GAINS" >> "$PLAN"
    fi
done < "$BASE"
cat "$PLAN"
echo "--- $(wc -l < "$PLAN") sweep points planned ($(wc -l < "$BASE") flat + gains variants) ---"

cd "$RTL_ROOT/cocotb/trouper_capture"
SUMMARY=$RUN_OUT/sweep_summary.txt
: > "$SUMMARY"
rc_all=0

while IFS=$'\t' read -r npy sf bw start nsamp stage gains; do
    [ -n "${npy:-}" ] || continue
    if [ -n "${gains:-}" ]; then tag="SF${sf}_BW${bw}_${stage}_gains"
    else tag="SF${sf}_BW${bw}_${stage}_flat"; fi
    echo ""
    echo "############ $tag ############"
    echo "npy=$npy start=$start nsamp=$nsamp stage=$stage gains=${gains:-flat}"
    bdir="$RUN_OUT/sim_build_$tag"
    make clean SIM_BUILD="$bdir" >/dev/null 2>&1
    make SIM_BUILD="$bdir" \
         COCOTB_RESULTS_FILE="$RUN_OUT/results_$tag.xml" \
         DESIGN_ROOT="$RTL_ROOT" \
         CAPTURE_NPY="$npy" CAPTURE_SF="$sf" CAPTURE_BW="$bw" \
         CAPTURE_START="$start" CAPTURE_NSAMP="$nsamp" CAPTURE_STAGE="$stage" \
         CAPTURE_GAINS="${gains:-}"
    rc=$?
    # cocotb returns 0 even on test failure in some configs -- trust the XML.
    if grep -q "<failure" "$RUN_OUT/results_$tag.xml" 2>/dev/null; then rc=1; fi
    if [ ! -s "$RUN_OUT/results_$tag.xml" ]; then rc=1; fi
    if [ $rc -eq 0 ]; then echo "$tag PASS" >> "$SUMMARY"
    else echo "$tag FAIL (rc=$rc)" >> "$SUMMARY"; rc_all=1; fi
done < "$PLAN"

echo ""
echo "=== SWEEP SUMMARY ==="
cat "$SUMMARY"
echo "=== trouper_capture SWEEP EXIT $rc_all $(date --iso-8601=seconds) ==="
exit $rc_all
