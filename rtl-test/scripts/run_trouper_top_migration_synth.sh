#!/bin/bash
# Post-migration synth check: production ol_trouper_top now built from the promoted
# canonical HB RTL (sd_decimator_poly + *_hb-derived blocks). Confirms the canonical
# trouper_top elaborates + synthesizes after the HB->production rename.
set -e
LOG=/foss/designs/lora-mimo/rtl-test/ol_trouper_top/migration_synth_run.log
exec > >(tee "$LOG") 2>&1
echo "=== trouper_top MIGRATION synth START $(date --iso-8601=seconds) on $(hostname) ==="
cd /foss/designs/lora-mimo/rtl-test
librelane --pdk gf180mcuD --scl gf180mcu_fd_sc_mcu7t5v0 \
          --to Yosys.Synthesis ol_trouper_top/config_current.json
echo "=== MIGRATION synth EXIT $? $(date --iso-8601=seconds) ==="
