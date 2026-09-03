#!/usr/bin/env bash
# Regenerate the A40 (ACV) pin-placement template from info.yaml + the current
# signoff GDS, using the shared integrator padframe tooling.
#
#   ip/chipathon-2026-padring-system  = d-m-bailey/padring_chipathon2026
#                                       @ agent/project-padframe-makefile
#   make target                       = project-def-A40
#
# Inputs
#   info.yaml                       -> the 27-pin participant list (LIST ORDER IS
#                                      LOAD-BEARING; see the header in info.yaml)
#   lvs_config.json                 -> names TOP_SOURCE / LAYOUT_FILE
#   final/gds/trouper_top.gds       -> measured for its 0/0 outline rectangle;
#                                      the tool picks the smallest fitting block
#                                      variant (currently ACV, 1675 x 1110 um)
#
# Outputs (copied into the repo)
#   rtl-test/ol_trouper_top/a40_integrator/   raw generator artifacts (provenance)
#   rtl-test/ol_trouper_top/A40_ACV_rtlnames.def   FP_DEF_TEMPLATE for P&R
#   src/config/A40_ACV_rtlnames.def                (identical copy)
#
# The a40_def_to_rtlnames.py transform is a pure pass-through now that the RTL
# port names already match the generator's <pad>_<terminal> convention; it is
# still run so a future name divergence is caught loudly.
#
# Runs the generator inside hpretl/iic-osic-tools:chipathon26. The padring C++
# tool (2019 vintage) does not build under GCC 13 unpatched -- a two-line
# <cstdint> fix is applied from ip/patches/ before the build and reverted after.
set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
SUBMOD="$REPO/ip/chipathon-2026-padring-system"
PATCH="$REPO/ip/patches/padring-system-cstdint-gcc13.patch"
IMAGE="hpretl/iic-osic-tools:chipathon26"
GDS="${1:-$REPO/final/gds/trouper_top.gds}"

[ -f "$SUBMOD/chipathon2026-system/Makefile.padframe" ] || {
	echo "submodule missing -- run: git submodule update --init ip/chipathon-2026-padring-system" >&2
	exit 1
}
[ -f "$GDS" ] || { echo "GDS not found: $GDS" >&2; exit 1; }

WORK="$(mktemp -d)"
trap 'git -C "$SUBMOD" checkout -- CMakeLists.txt src/logging.h 2>/dev/null || true; rm -rf "$WORK"' EXIT

mkdir -p "$WORK/info" "$WORK/gds/A40"
cp "$REPO/info.yaml"        "$WORK/info/A40_info.yaml"
cp "$REPO/lvs_config.json"  "$WORK/info/A40_lvs_config.json"
cp "$GDS"                   "$WORK/gds/A40/trouper_top.gds"

git -C "$SUBMOD" apply "$PATCH"
rm -rf "$SUBMOD/build"

docker run --rm --user "$(id -u):$(id -g)" \
	-v "$REPO:/foss/designs/trouper" \
	-v "$WORK:/work" \
	"$IMAGE" --skip bash -c "
		cd /work &&
		make -f /foss/designs/trouper/ip/chipathon-2026-padring-system/chipathon2026-system/Makefile.padframe \
			project-def-A40 PROJECT_GDS=/work/gds/A40/trouper_top.gds"

ACV="$WORK/build/padframes/A40/project_defs/ACV"
OUT="$REPO/rtl-test/ol_trouper_top/a40_integrator"
mkdir -p "$OUT"
cp "$ACV"/A40_ACV.def "$ACV"/A40_ACV_interface.yaml "$ACV"/A40_ACV_pad_map.yaml \
   "$ACV"/A40_ACV_padring.v "$ACV"/A40_ACV_padring.cfg "$OUT/"
python3 -c "import json,sys; d=json.load(open(sys.argv[1])); d['project_size'].pop('top_cell_text',None); json.dump(d,open(sys.argv[2],'w'),indent=2)" \
	"$WORK/build/padframes/A40/project_defs/A40_selected_variants.json" \
	"$OUT/A40_selected_variants.json"

python3 "$REPO/rtl-test/scripts/a40_def_to_rtlnames.py" \
	"$ACV/A40_ACV.def" "$REPO/rtl-test/ol_trouper_top/A40_ACV_rtlnames.def"
cp "$REPO/rtl-test/ol_trouper_top/A40_ACV_rtlnames.def" "$REPO/src/config/A40_ACV_rtlnames.def"

echo
echo "regenerated:  $REPO/rtl-test/ol_trouper_top/A40_ACV_rtlnames.def"
grep -E '^PINS|^DIEAREA|^BLOCKAGES' "$REPO/rtl-test/ol_trouper_top/A40_ACV_rtlnames.def"
