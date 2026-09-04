#!/bin/bash
# rtl/open-risk-fixes #68 re-check after job 5493:
#   - w_missed        : test hook fix (force training_done_pkt low too)
#   - capture_two_packet : re-run to see if the mid-sim Verilator segfault
#                          at simtime ~43ms reproduces (=> #68) or was a flake
#   - noise_window_edge / noise_trig : #68 + #66 directed coverage
export PYTHONUNBUFFERED=1 JOBS=4
export SUITES="w_missed capture_two_packet noise_window_edge noise_trig"
exec bash /foss/designs/cocotb/run_toplevel_regression_sge.sh
