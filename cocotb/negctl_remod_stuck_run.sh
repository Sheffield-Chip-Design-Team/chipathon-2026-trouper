#!/bin/bash
# Negative control for TRPR-RMD-006: force one quantizer output low and prove
# test_boundary_stuck_run_sweep reports the output-stuck-run failure.
set -euo pipefail

repo_root=$(cd "$(dirname "$0")/.." && pwd)
work_dir=$(mktemp -d)
trap 'rm -rf "$work_dir"' EXIT
cp "$repo_root/src/remod/sd_remod.v" "$work_dir/sd_remod.v"
sed -i "0,/out_i <= q_i;/s//out_i <= 1'b0;\/\/ NEGATIVE_CONTROL/" "$work_dir/sd_remod.v"

set +e
make -C "$repo_root/cocotb/remod_en" clean >/dev/null
make -C "$repo_root/cocotb/remod_en" SIM=verilator REMOD_SOURCE="$work_dir/sd_remod.v" \
    COCOTB_TESTCASE=test_boundary_stuck_run_sweep >"$work_dir/run.log" 2>&1
rc=$?
set -e

if [ "$rc" -eq 0 ]; then
    echo "FAIL: forced-constant output unexpectedly passed TRPR-RMD-006"
    exit 1
fi
if ! grep -q "TRPR-RMD-006 input" "$work_dir/run.log"; then
    echo "FAIL: negative control failed without the expected stuck-run diagnostic"
    cat "$work_dir/run.log"
    exit 1
fi
echo "PASS: forced-constant output was caught by the TRPR-RMD-006 stuck-run metric"
