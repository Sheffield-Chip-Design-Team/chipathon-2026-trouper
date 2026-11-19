#!/bin/bash
# Just the SQNR-vs-amplitude cliff sweep for the canonical sd_remod.
set -uo pipefail
DESIGN_ROOT=${DESIGN_ROOT:-/foss/designs}
export SUITES=remod_amp_sweep
exec "$DESIGN_ROOT/cocotb/run_toplevel_regression_sge.sh"
