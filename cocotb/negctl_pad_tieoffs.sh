#!/bin/bash
# NEGATIVE CONTROL for cocotb/pad_tieoffs -- must FAIL on each injected fault.
# /foss/designs is read-only, so work on a writable copy under $RUN_DIR.
set -uo pipefail
SRC_ROOT=${DESIGN_ROOT:-/foss/designs}
RUN_OUT=${RUN_DIR:-/foss/runs}
TREE="$RUN_OUT/negctl_tree"

rm -rf "$TREE"; mkdir -p "$TREE"
cp -r "$SRC_ROOT/src" "$SRC_ROOT/cocotb" "$TREE/"
TOP="$TREE/src/top/trouper_top.v"
BAK="$TREE/trouper_top.v.orig"; cp "$TOP" "$BAK"

run_case() {
    local name="$1"
    local OUT="$RUN_OUT/negctl_$name"; mkdir -p "$OUT/sim_build"
    ( cd "$TREE/cocotb/pad_tieoffs" && \
      make DESIGN_ROOT="$TREE" SIM_BUILD="$OUT/sim_build" \
           COCOTB_RESULTS_FILE="$OUT/results.xml" ) > "$OUT/run.log" 2>&1
    local rc=$?
    if [ "$rc" -ne 0 ]; then
        echo "[negctl] $name: CAUGHT (test failed as required)"
        grep -oE "AssertionError: .{0,140}" "$OUT/run.log" | head -2
    else
        echo "[negctl] $name: *** ESCAPED -- test passed on broken RTL ***"
    fi
    cp "$BAK" "$TOP"
}

mutate() {  # mutate <from> <to>
    sed -i "s|$1|$2|" "$TOP"
    grep -qF "$2" "$TOP" || { echo "[negctl] mutation did not apply: $1"; return 1; }
}

echo "=== fault 1: SPI_MISO_SL 1 -> 0 (slew mistake) ==="
mutate "assign SPI_MISO_SL = 1'b1;" "assign SPI_MISO_SL = 1'b0;" && run_case slew

echo "=== fault 2: PSRAM_SIO_2_IE polarity inverted (IE=OE) ==="
mutate "assign PSRAM_SIO_2_IE = ~PSRAM_SIO_OE\[2\];" "assign PSRAM_SIO_2_IE = PSRAM_SIO_OE[2];" && run_case ie_polarity

echo "=== fault 3: IQ_DATA_I_1_PU 0 -> 1 (stray on-chip pull-up) ==="
mutate "assign IQ_DATA_I_1_PU = 1'b0;" "assign IQ_DATA_I_1_PU = 1'b1;" && run_case stray_pull

echo "=== negative control complete ==="
