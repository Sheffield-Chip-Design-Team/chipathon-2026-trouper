#!/bin/bash
# Every cocotb suite under cocotb/, run as one SGE job.
#
# Two groups, because they differ in what they need, not in how much we trust
# them:
#   core    -- self-contained: RTL + the harness in cocotb/hdl, nothing else.
#   capture -- needs a measured .npy from the hlab-sge shared mount
#              ($SHARED_DIR/lora-mimo-captures/captures, read-only in every
#              job). Slower: capture_two_packet alone is ~50 min because the
#              two bursts are ~4.07 M capture samples apart.
#
# Default SUITE_GROUPS=core keeps a plain submit at the old turnaround; SUITE_GROUPS=all
# runs the capture suites too. Every suite lives in exactly one group and the
# script REFUSES TO PASS if a cocotb/<dir>/Makefile is missing from both --
# that unassigned-suite check is the point of this script. Before it existed,
# the default list covered 20 of 41 suites and reported "REGRESSION CLEAN"
# while the other half had never run (2026-08-30: two real breakages were
# sitting in the unrun half).
#
# Submit:
#   hqsub --name top_regression --project lora-mimo --cpus 8 --mem 24G \
#         /foss/designs/cocotb/run_toplevel_regression_sge.sh
#
# Environment:
#   SUITE_GROUPS  core | capture | all | "core capture"  (default core)
#   SUITES        explicit space-separated list; overrides SUITE_GROUPS
#   JOBS          suites run concurrently (default 1; each needs ~1 core)
#   DESIGN_ROOT   repo mount            (default /foss/designs)
#   RUN_DIR       writable output root  (default /foss/runs) -- /foss/designs
#                is read-only under SGE, so sim_build/ and results.xml go here
#   SHARED_DIR    capture mount         (default /foss/shared)
set -uo pipefail

DESIGN_ROOT=${DESIGN_ROOT:-/foss/designs}
RUN_OUT=${RUN_DIR:-/foss/runs}
SHARED=${SHARED_DIR:-/foss/shared}
export DESIGN_ROOT SHARED_DIR="$SHARED" RUN_DIR="$RUN_OUT"

# --- Group membership -------------------------------------------------------
# Ordered longest-first within each group so a parallel run finishes sooner and
# a sequential one surfaces the slow failures early.
SUITES_CORE="trouper_top replay_data replay_delay reg_bank spi_cdc remod_en \
array_sync dbg_probe bringup_src \
packet_ctrl_fsm spi_slave w_missed warmup_rearm bypass_e2e bypass_antenna \
noise_trig w_shadow_lock sc_force_lock sc_ant_sel sc_dbg reg_reset_sweep \
psram_ops psram_en_glitch qspi_owner dbg_write dbg_write_collision \
dbg_amask_wrap host_only_e2e pad_tieoffs io_cell_controls irq_pins \
dc_removal comb_remod_transfer remod_backoff tacc_window_clamp \
mcp_cfg_hold_settle mcp_decimator_settle mcp_iq_samp_cnt_settle \
mcp_mrc_settle mcp_pcfsm_settle mcp_psram_bshift_settle mcp_sc_settle \
mcp_tacc_settle \
w_valid_split bypass_backoff noise_window_edge tacc_acc_overflow sc_acc_overflow"

SUITES_CAPTURE="capture_two_packet weight_gen_spi_flow trouper_capture"

# Directed benches for open RTL risks (planning/Open Risks.md). Each asserts the
# INTENDED contract; while the risk is open the asserting testcase FAILS (that
# failure IS the confirmation), so these live outside `core`/`all` -- run with
# SUITE_GROUPS=xfail. When a fix lands and its bench goes green, move that suite
# into SUITES_CORE (done for #61/#62/#63/#65/#66 on branch rtl/open-risk-fixes).
# Still open: #64 (pkt_timeout_states) and #67 (dbg_qpi_busy) -- both spec/doc
# changes, no RTL fix, so their benches stay here as expected-fail markers.
SUITES_XFAIL="pkt_timeout_states dbg_qpi_busy"

# Per-suite extra make arguments. trouper_capture is the only suite whose
# in-test defaults do not land on a packet burst -- the window below was
# located with cocotb/tests/sweep_captures.py against this specific file, and
# the stock CAPTURE_START=0/NSAMP=60000 would run clean past the packet and
# report "sc_lock never fired". Keep in step with
# rtl-test/scripts/run_capture_playback.sh, which runs this suite standalone.
suite_args() {
    case "$1" in
    trouper_capture)
        echo "CAPTURE_NPY=$SHARED/lora-mimo-captures/captures/lora_20260621_092430_SF7-BW125-Pre8.npy \
CAPTURE_SF=7 CAPTURE_BW=125 CAPTURE_START=360482 CAPTURE_NSAMP=49152" ;;
    # capture_two_packet and weight_gen_spi_flow carry their own shared-mount
    # defaults (file + window) in the test module; nothing to add here.
    *) echo "" ;;
    esac
}

# --- Suite selection --------------------------------------------------------
# NOT named GROUPS: bash owns that name (the caller's gid array), and an
# assignment to it is silently ignored -- the script would read "1000".
SUITE_GROUPS=${SUITE_GROUPS:-core}
if [ -n "${SUITES:-}" ]; then
    SELECTED="$SUITES"
else
    SELECTED=""
    for g in $SUITE_GROUPS; do
        case "$g" in
        core)    SELECTED="$SELECTED $SUITES_CORE" ;;
        capture) SELECTED="$SELECTED $SUITES_CAPTURE" ;;
        xfail)   SELECTED="$SELECTED $SUITES_XFAIL" ;;
        all)     SELECTED="$SELECTED $SUITES_CORE $SUITES_CAPTURE" ;;
        *) echo "unknown group '$g' (want: core, capture, xfail, all)"; exit 2 ;;
        esac
    done
fi

# --- Unassigned-suite check -------------------------------------------------
# Compares the group tables against what is actually on disk. A new suite dir
# with a Makefile that nobody added to a group fails the run rather than being
# silently skipped.
UNASSIGNED=""
for mk in "$DESIGN_ROOT"/cocotb/*/Makefile; do
    [ -e "$mk" ] || continue
    d=$(basename "$(dirname "$mk")")
    case " $SUITES_CORE $SUITES_CAPTURE $SUITES_XFAIL " in
        *" $d "*) ;;
        *) UNASSIGNED="$UNASSIGNED $d" ;;
    esac
done

# --- Run one suite ----------------------------------------------------------
# Invoked as `$0 --one <suite>` so the parallel path can reuse it via xargs.
run_one() {
    local suite=$1
    local out="$RUN_OUT/cocotb_$suite"
    local t0=$SECONDS
    mkdir -p "$out/sim_build"
    # The parent reads this file for the summary: under `xargs -P` the child
    # exit codes are not recoverable, and grepping the log for "FAIL" is not
    # reliable (cocotb prints banner lines full of asterisks).
    rm -f "$out/status"

    # A capture suite with no shared mount is reported SKIPPED, never PASSED:
    # a missing .npy must not read as evidence.
    case " $SUITES_CAPTURE " in *" $suite "*)
        if [ ! -d "$SHARED/lora-mimo-captures/captures" ]; then
            echo "SKIP" > "$out/status"
            echo "*** SKIPPED: cocotb/$suite (no $SHARED/lora-mimo-captures/captures)"
            return 3
        fi ;;
    esac

    ( cd "$DESIGN_ROOT/cocotb/$suite" || exit 2
      # shellcheck disable=SC2046  # suite_args is a deliberate word-split list
      make DESIGN_ROOT="$DESIGN_ROOT" \
           SIM_BUILD="$out/sim_build" \
           COCOTB_RESULTS_FILE="$out/results.xml" \
           $(suite_args "$suite")
    ) > "$out/run.log" 2>&1
    local rc=$?
    local dt=$((SECONDS - t0))

    # cocotb's make exits non-zero on any failing testcase; the tally makes a
    # partial failure (and a suite that ran zero tests) visible without opening
    # the log. io_cell_controls is a plain iverilog bench with no cocotb tally.
    local tally
    tally=$(grep -oE "TESTS=[0-9]+ PASS=[0-9]+ FAIL=[0-9]+ SKIP=[0-9]+" "$out/run.log" | tail -1)
    if [ "$rc" -eq 0 ]; then
        echo "PASS" > "$out/status"
        echo "*** PASSED: cocotb/$suite  ${tally:-(no cocotb tally)}  [${dt}s]"
    else
        echo "FAIL" > "$out/status"
        echo "*** FAILED: cocotb/$suite (exit $rc)  ${tally:-}  [${dt}s]"
        grep -E "(AssertionError|TimeoutError|ModuleNotFoundError|Error:|error:)" "$out/run.log" | head -3
    fi
    return $rc
}

if [ "${1:-}" = "--one" ]; then
    run_one "$2"
    exit $?
fi

# --- Drive ------------------------------------------------------------------
JOBS=${JOBS:-1}
echo "SUITE_GROUPS=$SUITE_GROUPS JOBS=$JOBS DESIGN_ROOT=$DESIGN_ROOT RUN_DIR=$RUN_OUT"
echo "suites:$(echo " $SELECTED" | tr -s ' ')"
echo

if [ "$JOBS" -gt 1 ]; then
    # One line of output per suite, emitted whole when that suite finishes, so
    # parallel logs stay readable. Per-suite detail is in its own run.log.
    printf '%s\n' $SELECTED | xargs -P "$JOBS" -I{} "$0" --one {}
else
    for suite in $SELECTED; do
        echo "================ cocotb/$suite ================"
        run_one "$suite"
    done
fi

# --- Summary ----------------------------------------------------------------
PASSED=""; FAILED=""; SKIPPED=""
for suite in $SELECTED; do
    case "$(cat "$RUN_OUT/cocotb_$suite/status" 2>/dev/null)" in
        PASS) PASSED="$PASSED $suite" ;;
        SKIP) SKIPPED="$SKIPPED $suite" ;;
        *)    FAILED="$FAILED $suite" ;;   # FAIL, or no status = never ran
    esac
done

echo
echo "================ SUMMARY ================"
echo "PASSED:$PASSED"
[ -n "$SKIPPED" ] && echo "SKIPPED:$SKIPPED"
echo "FAILED:$FAILED"
[ -n "$UNASSIGNED" ] && echo "UNASSIGNED (in cocotb/ but in no group -- add them):$UNASSIGNED"
echo "logs under $RUN_OUT/cocotb_<suite>/run.log"
if [ -z "$FAILED" ] && [ -z "$UNASSIGNED" ] && [ -z "$SKIPPED" ]; then
    echo "=== COCOTB REGRESSION CLEAN ($SUITE_GROUPS) ==="
    exit 0
fi
echo "=== COCOTB REGRESSION HAS FAILURES ==="
exit 1
