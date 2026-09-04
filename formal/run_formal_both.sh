#!/bin/bash
set -uo pipefail

# Every .sby in this directory. spi_slave was already missing from the old list
# when bringup_src was added (2026-09-03) -- an unlisted proof is an unrun
# proof, which is the same dark-coverage shape the VACUITY guard below catches
# one level down.
PROOFS="psram_buf_ctrl packet_ctrl_fsm spi_slave bringup_src"

# --project lora-mimo mounts the project itself at /foss/designs; without it the
# project sits at /foss/designs/lora-mimo. Accept either.
if [ -d /foss/designs/formal ]; then SRC_ROOT=/foss/designs
else SRC_ROOT=/foss/designs/lora-mimo; fi

# /foss/designs is READ-ONLY (NFS manage_gids change, 2026-07-27/28) and sby
# creates its work directory in the CWD, so running in place fails with
# "Read-only file system: '<proof>_<task>'". Every proof failed that way and the
# script still had to be read to find out. Stage a writable copy under $RUN_DIR
# instead; the .sby files reference ../src/... so the src tree comes along.
WORK=${RUN_DIR:-/foss/runs}/formal
rm -rf "$WORK"; mkdir -p "$WORK"
cp -r "$SRC_ROOT/formal" "$WORK/formal"
cp -r "$SRC_ROOT/src"    "$WORK/src"
cd "$WORK/formal"

rc=0
for proof in $PROOFS; do
    echo "=== sby $proof ==="
    sby -f "${proof}.sby"
    r=$?
    echo "=== $proof exit=$r ==="
    # Guard against the vacuous-PASS failure mode: the checker instance must
    # actually exist in the elaborated design.
    if ! grep -rq "_formal" "${proof}"*/model/ 2>/dev/null; then
        echo "VACUITY WARNING: no *_formal instance found in ${proof}*/model/"
        r=1
    fi
    [ $r -ne 0 ] && rc=1
done
echo "OVERALL rc=$rc"
exit $rc
