#!/bin/bash
# Just the sc_detector lock + timing_ref diff against sim/models/sc_rtl.py,
# for iterating on it without paying for the whole core regression. Same
# machinery, one suite.
#
# hqsub copies the submitted script to /job/run.sh, so $0's directory is NOT
# the repo -- reach the runner through the project mount instead.
set -uo pipefail
DESIGN_ROOT=${DESIGN_ROOT:-/foss/designs}
export SUITES=sc_timing_golden
exec "$DESIGN_ROOT/cocotb/run_toplevel_regression_sge.sh"
