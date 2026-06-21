#!/bin/bash
# SF7 sanity (both BWs) of MIGRATED production trouper_top (sd_decimator_poly).
set -e
LOG=/foss/designs/lora-mimo/rtl-test/cocotb_trouper_top/migration_cocotb_sf7.log
exec > >(tee "$LOG") 2>&1
echo "=== cocotb trouper_top (migrated) SF7 START $(date --iso-8601=seconds) on $(hostname) ==="
cd /foss/designs/lora-mimo/rtl-test/cocotb_trouper_top
make clean
make TESTCASE=test_sf7_bw250,test_sf7_bw125
echo "=== cocotb SF7 EXIT $? $(date --iso-8601=seconds) ==="
