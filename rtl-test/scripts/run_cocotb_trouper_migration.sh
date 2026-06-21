#!/bin/bash
# Top-level cocotb on the MIGRATED production trouper_top (canonical names + sd_decimator_poly).
# Arg1 = TESTCASE filter (empty = full SF7-SF12 x BW250/125 sweep).
set -e
LOG=/foss/designs/lora-mimo/rtl-test/cocotb_trouper_top/migration_cocotb_run.log
exec > >(tee "$LOG") 2>&1
echo "=== cocotb trouper_top (migrated) START $(date --iso-8601=seconds) on $(hostname) ==="
cd /foss/designs/lora-mimo/rtl-test/cocotb_trouper_top
make clean
if [ -n "$1" ]; then make TESTCASE="$1"; else make; fi
echo "=== cocotb EXIT $? $(date --iso-8601=seconds) ==="
