#!/bin/bash
set -uo pipefail
cd /foss/designs/lora-mimo/formal
rc=0
for proof in psram_buf_ctrl packet_ctrl_fsm; do
    echo "=== sby $proof ==="
    sby -f ${proof}.sby
    r=$?
    echo "=== $proof exit=$r ==="
    # Guard against the vacuous-PASS failure mode: the checker instance must
    # actually exist in the elaborated design.
    if ! grep -q "_formal" ${proof}/model/design.ys 2>/dev/null && \
       ! grep -rq "_formal" ${proof}/model/ 2>/dev/null; then
        echo "VACUITY WARNING: no *_formal instance found in ${proof}/model/"
        r=1
    fi
    [ $r -ne 0 ] && rc=1
done
echo "OVERALL rc=$rc"
exit $rc
