#!/usr/bin/env bash
# Render a GDS to a multi-layer color PNG, bypassing KLayout's LayoutView
# save_image() paint stage (see SKILL.md "Known issue" -- as of 2026-08-19
# that path silently ignores all layer color/visibility properties and
# renders everything as a flat, wrong-colored mass, verified via property
# readback, not just visual inspection). This script instead reads merged
# polygon geometry per layer directly via pya.Region and rasterizes with
# pycairo -- a completely different code path that isn't affected.
#
# No Xvfb needed (QT_QPA_PLATFORM=offscreen) and no .lyp needed (colors are
# hardcoded in raster_gds.py, physical-stack bottom-to-top draw order so
# upper metals correctly occlude lower ones). ~12s for a ~950k-polygon
# design at 3200x2133, vs ~1-2 min (and broken output) via render_gds.sh.
#
# Usage:
#   raster_gds.sh <gds> <out.png> [width] [height]

set -euo pipefail

IMAGE=hpretl/iic-osic-tools:chipathon26
SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)

die() { printf 'raster_gds.sh: %s\n' "$*" >&2; exit 1; }

[ $# -ge 2 ] || die "usage: raster_gds.sh <gds> <out.png> [width] [height]"

ROOT=$(git rev-parse --show-toplevel 2>/dev/null) \
  || die "not inside a git repository; run from the trouper checkout."

GDS_IN=$1
OUT_IN=$2
WIDTH=${3:-2400}
HEIGHT=${4:-1600}

[ -e "$GDS_IN" ] || die "gds not found: $GDS_IN"
GDS_ABS=$(realpath "$GDS_IN")
GDS_DIR=$(dirname "$GDS_ABS")
GDS_BASE=$(basename "$GDS_ABS")

OUT_ABS=$(realpath -m "$OUT_IN")
OUT_DIR=$(dirname "$OUT_ABS")
OUT_BASE=$(basename "$OUT_ABS")
mkdir -p "$OUT_DIR"

GDS_MOUNT=/data/gdsin
OUT_MOUNT=/data/gdsout

docker run --rm \
  -e QT_QPA_PLATFORM=offscreen \
  -v "$GDS_DIR":"$GDS_MOUNT":ro \
  -v "$OUT_DIR":"$OUT_MOUNT" \
  -v "$SCRIPT_DIR":/scripts:ro \
  "$IMAGE" \
  --skip klayout -z -r /scripts/raster_gds.py \
  -rd "gds=$GDS_MOUNT/$GDS_BASE" \
  -rd "out=$OUT_MOUNT/$OUT_BASE" \
  -rd "width=$WIDTH" -rd "height=$HEIGHT"

echo "wrote $OUT_ABS"
