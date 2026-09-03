#!/bin/bash
# Open Risk #60 baseline: full `core` cocotb regression against the current
# (post-Grouper/AHB-removal) tree. The removal (2026-09-01) has never been
# functionally simulated -- every regression job cited in the verification
# plans predates it.
#
# Submit (from an NFS-synced checkout):
#   hqsub --name or60_baseline_regr --project lora-mimo --cpus 8 --mem 24G \
#         /srv/eda/designs/timothyn-dev/lora-mimo/cocotb/run_or60_regr.sh
export PYTHONUNBUFFERED=1 SUITE_GROUPS=core JOBS=6
exec bash /foss/designs/cocotb/run_toplevel_regression_sge.sh
