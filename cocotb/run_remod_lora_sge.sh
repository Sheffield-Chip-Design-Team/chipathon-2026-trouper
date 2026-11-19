#!/bin/bash
# Just the absolute LoRa symbol-error gate for the canonical sd_remod.
# hqsub copies the submitted script to /job/run.sh, so reach the runner
# through the project mount.
set -uo pipefail
DESIGN_ROOT=${DESIGN_ROOT:-/foss/designs}
export SUITES=remod_lora
exec "$DESIGN_ROOT/cocotb/run_toplevel_regression_sge.sh"
