#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OUT_DIR="${SCRIPT_DIR}/out"
IMAGE="${OSIC_IMAGE:-hpretl/iic-osic-tools:2026.04}"
LIBERTY="/foss/pdks/gf180mcuD/libs.ref/gf180mcu_fd_sc_mcu7t5v0/lib/gf180mcu_fd_sc_mcu7t5v0__tt_025C_3v30.lib"

mkdir -p "${OUT_DIR}"

docker run --rm \
  -v "${SCRIPT_DIR}:/work" \
  -w /work \
  "${IMAGE}" \
  --skip bash -lc "test -f '${LIBERTY}' && yosys -s /work/synth_gf180.ys"

printf 'Synthesis outputs written to %s\n' "${OUT_DIR}"
