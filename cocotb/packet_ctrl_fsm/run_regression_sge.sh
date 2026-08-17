#!/bin/bash
# Full packet_ctrl_fsm verification-plan regression for homelab SGE.
# The project snapshot is read-only, so every generated file is redirected
# beneath RUN_DIR.
set -uo pipefail

DESIGN_ROOT=${DESIGN_ROOT:-/foss/designs}
RUN_OUT=${RUN_DIR:-/foss/runs}
SUITES="packet_ctrl_fsm w_missed bypass_e2e sc_force_lock trouper_top"
FAILED=""

for suite in $SUITES; do
    echo "=== cocotb/$suite ==="
    OUT="$RUN_OUT/cocotb_$suite"
    mkdir -p "$OUT/sim_build"
    (
        cd "$DESIGN_ROOT/cocotb/$suite"
        make \
            DESIGN_ROOT="$DESIGN_ROOT" \
            SIM_BUILD="$OUT/sim_build" \
            COCOTB_RESULTS_FILE="$OUT/results.xml"
    )
    rc=$?
    if [ "$rc" -eq 0 ]; then
        echo "*** PASSED: cocotb/$suite ***"
    else
        echo "*** FAILED: cocotb/$suite (exit $rc) ***"
        FAILED="$FAILED cocotb/$suite"
    fi
done

echo "=== formal/packet_ctrl_fsm.sby ==="
FORMAL_OUT="$RUN_OUT/formal_work"
mkdir -p "$FORMAL_OUT/formal" "$FORMAL_OUT/src/control"
cp -a "$DESIGN_ROOT/formal/packet_ctrl_fsm.sby" \
      "$DESIGN_ROOT/formal/packet_ctrl_fsm_formal.sv" \
      "$FORMAL_OUT/formal/"
cp -a "$DESIGN_ROOT/src/control/packet_ctrl_fsm.v" \
      "$FORMAL_OUT/src/control/"
(
    cd "$FORMAL_OUT/formal"
    sby -f packet_ctrl_fsm.sby
)
rc=$?
if [ "$rc" -eq 0 ]; then
    echo "*** PASSED: formal/packet_ctrl_fsm.sby ***"
else
    echo "*** FAILED: formal/packet_ctrl_fsm.sby (exit $rc) ***"
    FAILED="$FAILED formal"
fi

echo "=== rtl-test/tb/tb_pcfsm_b6_equiv.v ==="
EQUIV_OUT="$RUN_OUT/pcfsm_b6_equiv"
mkdir -p "$EQUIV_OUT/obj_dir"
verilator --binary --timing -Wno-fatal -sv \
    --Mdir "$EQUIV_OUT/obj_dir" \
    --top-module tb_pcfsm_b6_equiv \
    "$DESIGN_ROOT/rtl-test/tb/tb_pcfsm_b6_equiv.v" \
    "$DESIGN_ROOT/rtl-test/tb/packet_ctrl_fsm_ref.v" \
    "$DESIGN_ROOT/src/control/packet_ctrl_fsm.v"
rc=$?
if [ "$rc" -eq 0 ]; then
    EQUIV_LOG="$EQUIV_OUT/equiv.log"
    "$EQUIV_OUT/obj_dir/Vtb_pcfsm_b6_equiv" | tee "$EQUIV_LOG"
    rc=${PIPESTATUS[0]}
    if ! grep -q '^TB: PASS' "$EQUIV_LOG" || grep -q '^TB: FAIL' "$EQUIV_LOG"; then
        rc=1
    fi
fi
if [ "$rc" -eq 0 ]; then
    echo "*** PASSED: tb_pcfsm_b6_equiv ***"
else
    echo "*** FAILED: tb_pcfsm_b6_equiv (exit $rc) ***"
    FAILED="$FAILED b6_equiv"
fi

echo
echo "===== PACKET_CTRL_FSM REGRESSION SUMMARY ====="
if [ -z "$FAILED" ]; then
    echo "ALL TARGETS PASSED"
    exit 0
fi

echo "FAILED TARGETS:$FAILED"
exit 1
