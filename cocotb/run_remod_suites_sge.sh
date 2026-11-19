#!/bin/bash
set -uo pipefail
DESIGN_ROOT=${DESIGN_ROOT:-/foss/designs}
export SUITES="${SUITES:-remod_golden remod_en remod_sqnr remod_flatness remod_stability remod_backoff remod_lora remod_amp_sweep comb_remod_transfer bringup_src}"
exec "$DESIGN_ROOT/cocotb/run_toplevel_regression_sge.sh"
