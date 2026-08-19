#!/usr/bin/env bash
# Render a GDS file to a PNG via headless KLayout in the pinned chipathon26
# image. See .claude/skills/gds-plot/SKILL.md for the failure modes this
# works around (xvfb-run hangs, .lyp layer-name matching, color/dither choices).
#
# Usage:
#   render_gds.sh <gds> <out.png> [width] [height] [cellname]
#
#   <gds>      GDS path, absolute or relative to the repo root (or $PWD).
#              NFS run paths (/srv/eda/runs/...) work directly.
#   <out.png>  Output PNG path, absolute or relative to the repo root.
#   [width]    Image width in px (default 2000)
#   [height]   Image height in px (default 2000)
#   [cellname] Top cell to render (default: layout's own top cell)
#
# Env overrides:
#   LYP        Path to a KLayout .lyp file (default: ip/ws-run1/lyp/gf180mcu.lyp)

set -euo pipefail

IMAGE=hpretl/iic-osic-tools:chipathon26
SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)

die() { printf 'render_gds.sh: %s\n' "$*" >&2; exit 1; }

[ $# -ge 2 ] || die "usage: render_gds.sh <gds> <out.png> [width] [height] [cellname]"

ROOT=$(git rev-parse --show-toplevel 2>/dev/null) \
  || die "not inside a git repository; run from the trouper checkout."

GDS_IN=$1
OUT_IN=$2
WIDTH=${3:-2000}
HEIGHT=${4:-2000}
CELLNAME=${5:-}
LYP_IN=${LYP:-"$ROOT/ip/ws-run1/lyp/gf180mcu.lyp"}

[ -e "$LYP_IN" ] || die "lyp file not found: $LYP_IN"

# GDS may live outside the repo (NFS run dirs) -- give it its own mount rather
# than requiring it under $ROOT like the render script and lyp file.
[ -e "$GDS_IN" ] || die "gds not found: $GDS_IN"
GDS_ABS=$(realpath "$GDS_IN")
GDS_DIR=$(dirname "$GDS_ABS")
GDS_BASE=$(basename "$GDS_ABS")

OUT_ABS=$(realpath -m "$OUT_IN")
OUT_DIR=$(dirname "$OUT_ABS")
OUT_BASE=$(basename "$OUT_ABS")
mkdir -p "$OUT_DIR"

MOUNT=/foss/designs/lora-mimo
GDS_MOUNT=/data/gdsin
OUT_MOUNT=/data/gdsout

RD_ARGS=(-rd "gds=$GDS_MOUNT/$GDS_BASE" -rd "lyp=$MOUNT/${LYP_IN#"$ROOT"/}" -rd "out=$OUT_MOUNT/$OUT_BASE" -rd "width=$WIDTH" -rd "height=$HEIGHT")
[ -n "$CELLNAME" ] && RD_ARGS+=(-rd "cellname=$CELLNAME")

# xvfb-run's internal readiness wait is flaky and can hang klayout forever
# with 0% CPU (confirmed via docker top/stats). Start Xvfb manually instead.
RUNNER='
set -e
Xvfb :99 -screen 0 1280x1024x24 -nolisten tcp &
XPID=$!
sleep 3
export DISPLAY=:99
klayout -z "$@" -r /scripts/render_gds.py
kill $XPID 2>/dev/null || true
'

docker run --rm \
  -v "$ROOT":"$MOUNT" \
  -v "$GDS_DIR":"$GDS_MOUNT":ro \
  -v "$OUT_DIR":"$OUT_MOUNT" \
  -v "$SCRIPT_DIR":/scripts:ro \
  "$IMAGE" \
  --skip bash -c "$RUNNER" _ "${RD_ARGS[@]}"

echo "wrote $OUT_ABS"
