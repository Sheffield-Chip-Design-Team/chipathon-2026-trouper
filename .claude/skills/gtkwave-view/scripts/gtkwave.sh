#!/usr/bin/env bash
# Open a waveform in GTKWave from the pinned chipathon26 image over X11.
#
# Usage: gtkwave.sh <waveform> [extra gtkwave args...]
#   <waveform>  VCD/FST path, absolute or relative to the repo root (or to $PWD).
#   Extra args are passed through; path-like args are translated to container
#   paths the same way as the waveform (so --save foo.gtkw works).

set -euo pipefail

IMAGE=hpretl/iic-osic-tools:chipathon26
MOUNT=/foss/designs/lora-mimo
XAUTH_DOCKER=/tmp/trouper-x11.xauth

die() { printf 'gtkwave.sh: %s\n' "$*" >&2; exit 1; }

[ $# -ge 1 ] || die "usage: gtkwave.sh <waveform.vcd|.fst> [gtkwave args...]"
[ -n "${DISPLAY:-}" ] || die "DISPLAY is unset — X11 forwarding is not active in this shell."

ROOT=$(git rev-parse --show-toplevel 2>/dev/null) \
  || die "not inside a git repository; run from the trouper checkout."

# Map a host path to its path inside the container. Accepts absolute paths,
# paths relative to the repo root, and paths relative to $PWD. Anything that
# isn't an existing file is echoed unchanged (it's a plain gtkwave flag).
to_container() {
  local p=$1 abs
  case $p in
    -*) printf '%s' "$p"; return ;;
  esac
  if [ -e "$p" ]; then
    abs=$(realpath "$p")
  elif [ -e "$ROOT/$p" ]; then
    abs=$(realpath "$ROOT/$p")
  else
    printf '%s' "$p"; return
  fi
  case $abs in
    "$ROOT"/*) printf '%s' "$MOUNT/${abs#"$ROOT"/}" ;;
    *) die "'$p' resolves outside the repo ($abs); only files under $ROOT are mounted." ;;
  esac
}

WAVE=$1; shift
[ -e "$WAVE" ] || [ -e "$ROOT/$WAVE" ] \
  || die "waveform '$WAVE' not found (looked in \$PWD and $ROOT). Has the sim run yet?"
CWAVE=$(to_container "$WAVE")

ARGS=()
for a in "$@"; do ARGS+=("$(to_container "$a")"); done

# Address-family-independent X cookie: the host cookie is bound to a family the
# container can't match, which surfaces as
#   MoTTY X11 proxy: Unsupported authorisation protocol
rm -f "$XAUTH_DOCKER"
xauth nlist "$DISPLAY" | sed -e 's/^..../ffff/' | xauth -f "$XAUTH_DOCKER" nmerge -
chmod 644 "$XAUTH_DOCKER"
[ -s "$XAUTH_DOCKER" ] || die "no X cookie for DISPLAY=$DISPLAY — is the X session alive?"

# Mount the repo ROOT, not $PWD: mounting the wrong directory is what makes
# GTKWave start fine and then fail to open the file.
exec docker run --rm -it --network host \
  -e DISPLAY \
  -e XAUTHORITY=/tmp/.Xauthority \
  -v "$XAUTH_DOCKER:/tmp/.Xauthority:ro" \
  -v "$ROOT":"$MOUNT" \
  "$IMAGE" \
  --skip bash -lc \
  'exec gtkwave "$@"' _ "$CWAVE" "${ARGS[@]}"
