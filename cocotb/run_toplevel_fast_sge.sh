#!/bin/bash
# Fast subset of the top-level suites. hqsub snapshots ONLY the named script
# (as /job/run.sh), so $0's directory is NOT the design tree -- resolve the
# real runner via DESIGN_ROOT, which the container mounts the repo at.
export SUITES="sc_force_lock sc_ant_sel sc_dbg noise_trig warmup_rearm reg_reset_sweep w_shadow_lock w_missed bypass_e2e"
exec "${DESIGN_ROOT:-/foss/designs}/cocotb/run_toplevel_regression_sge.sh"
