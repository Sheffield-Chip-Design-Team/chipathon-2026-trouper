#!/bin/bash
# rtl/open-risk-fixes: re-check noise_window_edge after the
# test_retrigger_during_drain_not_lost expectation fix (monitor-latch reset).
export PYTHONUNBUFFERED=1 JOBS=4
export SUITES="noise_window_edge"
exec bash /foss/designs/cocotb/run_toplevel_regression_sge.sh
