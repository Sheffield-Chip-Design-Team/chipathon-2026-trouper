#!/usr/bin/env bash
# Overlay a dimmed routing raster with bright, block-colored markers at every
# cell instance that touches a named net under one or more hierarchical
# prefixes (e.g. "u_remod", or all top-level trouper_top submodules at once),
# with a text label at each block's marker centroid. See highlight_hier.py's
# header for why this needs the synthesized netlist (<top>.nl.v) and the
# DEF, not just the GDS -- cell instances are anonymized post-synthesis,
# only named nets keep their original RTL hierarchy.
#
# Usage:
#   highlight_hier.sh <gds> <def> <netlist.nl.v> <prefixes> <out.png> [width] [height]
#
# <prefixes> is a comma-separated list, e.g. "u_remod" or
# "u_dec,u_dcr,u_sc,u_tacc,u_array_acq_sync,u_pcfsm,u_psram,u_comb,u_remod,u_spi,u_rb,u_dbg,u_bringup_src"
# (trouper_top's full top-level instance list). A trailing "." is added to
# each automatically.
#
# Example (a completed LibreLane run dir):
#   RUN=/srv/eda/runs/timothyn-dev/lora-mimo/5606/pnr_multiplierless_interp2x/run
#   highlight_hier.sh \
#     "$RUN/final/gds/trouper_top.gds" \
#     "$RUN/final/def/trouper_top.def" \
#     "$RUN/06-yosys-synthesis/trouper_top.nl.v" \
#     "u_remod" \
#     reports/trouper_top_5606_remod_highlight.png

set -euo pipefail

IMAGE=hpretl/iic-osic-tools:chipathon26
SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)

die() { printf 'highlight_hier.sh: %s\n' "$*" >&2; exit 1; }

[ $# -ge 5 ] || die "usage: highlight_hier.sh <gds> <def> <netlist.nl.v> <prefixes> <out.png> [width] [height]"

ROOT=$(git rev-parse --show-toplevel 2>/dev/null) \
  || die "not inside a git repository; run from the trouper checkout."

GDS_IN=$1; DEF_IN=$2; NL_IN=$3; PREFIXES=$4; OUT_IN=$5
WIDTH=${6:-2400}
HEIGHT=${7:-1600}

for f in "$GDS_IN" "$DEF_IN" "$NL_IN"; do
  [ -e "$f" ] || die "not found: $f"
done

GDS_ABS=$(realpath "$GDS_IN"); GDS_DIR=$(dirname "$GDS_ABS"); GDS_BASE=$(basename "$GDS_ABS")
DEF_ABS=$(realpath "$DEF_IN"); DEF_DIR=$(dirname "$DEF_ABS"); DEF_BASE=$(basename "$DEF_ABS")
NL_ABS=$(realpath "$NL_IN");   NL_DIR=$(dirname "$NL_ABS");   NL_BASE=$(basename "$NL_ABS")

OUT_ABS=$(realpath -m "$OUT_IN")
OUT_DIR=$(dirname "$OUT_ABS")
OUT_BASE=$(basename "$OUT_ABS")
mkdir -p "$OUT_DIR"

# Mount each input's own directory read-only (they usually live in
# different run-step subdirectories on NFS, so this may be three separate
# mounts, or fewer if some share a parent).
docker run --rm \
  -e QT_QPA_PLATFORM=offscreen \
  -v "$GDS_DIR":/data/gds:ro \
  -v "$DEF_DIR":/data/def:ro \
  -v "$NL_DIR":/data/nl:ro \
  -v "$OUT_DIR":/data/out \
  -v "$SCRIPT_DIR":/scripts:ro \
  "$IMAGE" \
  --skip klayout -z -r /scripts/highlight_hier.py \
  -rd "gds=/data/gds/$GDS_BASE" \
  -rd "def=/data/def/$DEF_BASE" \
  -rd "nl=/data/nl/$NL_BASE" \
  -rd "prefixes=$PREFIXES" \
  -rd "out=/data/out/$OUT_BASE" \
  -rd "width=$WIDTH" -rd "height=$HEIGHT"

echo "wrote $OUT_ABS"
