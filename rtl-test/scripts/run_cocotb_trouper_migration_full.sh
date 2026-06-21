#!/bin/bash
# Full SF7-SF12 x BW250/125 cocotb sweep of MIGRATED production trouper_top (sd_decimator_poly).
set -e
LOG=/foss/designs/lora-mimo/rtl-test/cocotb_trouper_top/migration_cocotb_full.log
exec > >(tee "$LOG") 2>&1
echo "=== cocotb trouper_top (migrated) FULL SWEEP START $(date --iso-8601=seconds) on $(hostname) ==="
cd /foss/designs/lora-mimo/rtl-test/cocotb_trouper_top
make clean
make
echo "=== cocotb FULL EXIT $? $(date --iso-8601=seconds) ==="
