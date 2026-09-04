#!/bin/bash
# rtl/open-risk-fixes: capture-group regression (real captured IQ + modelled
# weight-gen SPI e2e) against the #61/#62/#63/#65/#66 RTL fixes. Slow (~50 min).
export PYTHONUNBUFFERED=1 SUITE_GROUPS=capture JOBS=6
exec bash /foss/designs/cocotb/run_toplevel_regression_sge.sh
