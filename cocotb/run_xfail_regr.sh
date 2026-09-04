#!/bin/bash
# Directed confirmation benches for open RTL risks (planning/Open Risks.md
# #61/#62/#63/#64/#65/#66/#67). Each asserts the INTENDED contract and is
# EXPECTED TO FAIL until its risk is fixed -- a "FAILED" line here is the
# confirmation, not a regression. See the SUITES_XFAIL group in
# run_toplevel_regression_sge.sh.
#
# Submit (from an NFS-synced checkout):
#   hqsub --name xfail_risk_benches --project lora-mimo --cpus 8 --mem 24G \
#         /srv/eda/designs/timothyn-dev/lora-mimo/cocotb/run_xfail_regr.sh
export PYTHONUNBUFFERED=1 SUITE_GROUPS=xfail JOBS=6
exec bash /foss/designs/cocotb/run_toplevel_regression_sge.sh
