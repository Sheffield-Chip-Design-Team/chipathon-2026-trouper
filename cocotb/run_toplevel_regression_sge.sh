#!/bin/bash
# All trouper_top-level cocotb suites (TOPLEVEL = tb_trouper_cocotb), for SGE.
#
# Purpose right now: measure the blast radius of RX_HOLD (0x1A[0]) coming out
# of reset SET -- the receiver starts disabled, so any suite that resets and
# expects sc_lock without releasing the hold will fail. See
# planning/mcp-config-settle-gate-design.md §4a.
#
# trouper_capture is EXCLUDED: it is the ~52 min real-capture Verilator run and
# would dominate the turnaround. Run it separately once the fast suites are green.
#
# Submit:
#   hqsub --name top_regression --project lora-mimo --cpus 8 --mem 24G \
#         /foss/designs/cocotb/run_toplevel_regression_sge.sh
set -uo pipefail

DESIGN_ROOT=${DESIGN_ROOT:-/foss/designs}
RUN_OUT=${RUN_DIR:-/foss/runs}

SUITES=${SUITES:-"trouper_top bypass_e2e w_missed sc_force_lock sc_ant_sel sc_dbg \
noise_trig warmup_rearm reg_reset_sweep w_shadow_lock spi_cdc psram_ops \
psram_en_glitch qspi_owner replay_data replay_delay dbg_amask_wrap \
dbg_write_collision"}

PASSED=""; FAILED=""
for suite in $SUITES; do
    echo "================ cocotb/$suite ================"
    OUT="$RUN_OUT/cocotb_$suite"
    mkdir -p "$OUT/sim_build"
    (
        cd "$DESIGN_ROOT/cocotb/$suite" || exit 2
        make \
            DESIGN_ROOT="$DESIGN_ROOT" \
            SIM_BUILD="$OUT/sim_build" \
            COCOTB_RESULTS_FILE="$OUT/results.xml"
    ) > "$OUT/run.log" 2>&1
    rc=$?
    # cocotb's make returns non-zero on any failing testcase; also surface the
    # per-test tally so a partial failure is visible without opening the log.
    tally=$(grep -oE "TESTS=[0-9]+ PASS=[0-9]+ FAIL=[0-9]+ SKIP=[0-9]+" "$OUT/run.log" | tail -1)
    if [ "$rc" -eq 0 ]; then
        echo "*** PASSED: cocotb/$suite  ${tally:-}"
        PASSED="$PASSED $suite"
    else
        echo "*** FAILED: cocotb/$suite (exit $rc)  ${tally:-}"
        grep -E "^\s+.*(AssertionError|TimeoutError|Error:)" "$OUT/run.log" | head -3
        FAILED="$FAILED $suite"
    fi
done

echo
echo "================ SUMMARY ================"
echo "PASSED:$PASSED"
echo "FAILED:$FAILED"
echo "logs under $RUN_OUT/cocotb_<suite>/run.log"
[ -z "$FAILED" ] && echo "=== TOP-LEVEL REGRESSION CLEAN ===" || echo "=== TOP-LEVEL REGRESSION HAS FAILURES ==="
[ -z "$FAILED" ]
