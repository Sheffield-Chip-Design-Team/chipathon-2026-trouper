#!/bin/bash
# Full SPI-slave regression for homelab-sge.  The project snapshot is read-only,
# so copy only the simulation inputs into the job's writable run directory.
set -uo pipefail

DESIGN_ROOT=/foss/designs
WORK_ROOT="${RUN_DIR:-/foss/runs}/spi_slave_regression"

mkdir -p "$WORK_ROOT"
cp -a "$DESIGN_ROOT/src" "$WORK_ROOT/"
cp -a "$DESIGN_ROOT/cocotb" "$WORK_ROOT/"
mkdir -p "$WORK_ROOT/rtl-test"
cp -a "$DESIGN_ROOT/rtl-test/tb" "$WORK_ROOT/rtl-test/"

FAILED=""
for suite in spi_cdc psram_ops; do
    echo "=== cocotb/$suite ==="
    # The cocotb Makefiles default to the unscoped /foss/designs/lora-mimo
    # mount.  This job uses --project lora-mimo and executes from a writable
    # copy, so override the source root explicitly.
    (cd "$WORK_ROOT/cocotb/$suite" && make DESIGN_ROOT="$WORK_ROOT")
    rc=$?
    if [ "$rc" -ne 0 ]; then
        echo "*** FAILED: $suite (exit $rc) ***"
        FAILED="$FAILED $suite"
    else
        echo "*** PASSED: $suite ***"
    fi
done

RTL_SOURCES="
../src/top/trouper_top.v
../src/decimator/sd_decimator_poly.v
../src/frontend/dc_removal.v
../src/frontend/sc_detector.v
../src/combiner/training_acc.v
../src/combiner/mrc_combiner.v
../src/control/packet_ctrl_fsm.v
../src/control/psram_buf_ctrl.v
../src/control/spi_slave.v
../src/control/reg_bank.v
../src/remod/sd_remod.v
"

for bench in tb_trouper_spi tb_trouper_grp_arb; do
    echo "=== rtl-test/tb/$bench.v ==="
    log="$WORK_ROOT/$bench.log"
    (
        cd "$WORK_ROOT/rtl-test"
        iverilog -g2005 -o "$WORK_ROOT/$bench.vvp" "tb/$bench.v" $RTL_SOURCES &&
            vvp "$WORK_ROOT/$bench.vvp"
    ) | tee "$log"
    rc=${PIPESTATUS[0]}
    if [ "$rc" -ne 0 ] || ! grep -q "TB PASS" "$log" || grep -q "TB FAIL" "$log"; then
        echo "*** FAILED: $bench (exit $rc or missing PASS marker) ***"
        FAILED="$FAILED $bench"
    else
        echo "*** PASSED: $bench ***"
    fi
done

echo
echo "===== SPI SLAVE REGRESSION SUMMARY ====="
if [ -z "$FAILED" ]; then
    echo "ALL SUITES PASSED"
    exit 0
fi

echo "FAILED SUITES:$FAILED"
exit 1
