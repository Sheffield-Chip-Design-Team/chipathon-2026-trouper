#!/bin/bash
# rtl/open-risk-fixes: core + capture regression (all suites incl. real IQ +
# weight-gen SPI e2e) against #61/#62/#63/#65/#66/#68. ~50 min.
export PYTHONUNBUFFERED=1 JOBS=6
export SUITE_GROUPS="core capture"
exec bash /foss/designs/cocotb/run_toplevel_regression_sge.sh
