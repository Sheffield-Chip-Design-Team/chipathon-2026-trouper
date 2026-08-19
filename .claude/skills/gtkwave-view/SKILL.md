---
name: gtkwave-view
description: Open a waveform (VCD/FST) in GTKWave from the pinned hpretl/iic-osic-tools:chipathon26 image over X11 forwarding. Covers the Xauthority cookie fix for "MoTTY X11 proxy: Unsupported authorisation protocol", the required `--skip bash -lc` image wrapper, and the mount-root pitfall that makes GTKWave fail to open the file. Triggers on "open the VCD", "view the waveform", "gtkwave", "show me the waves", "look at tb_*.vcd", "dump the signals for <tb>".
---

# Viewing waveforms in GTKWave (chipathon26 image, X11)

GTKWave is not installed on the host — it lives in the pinned
`hpretl/iic-osic-tools:chipathon26` image and is displayed over X11 forwarding.
Three things must all be right or it fails in three distinct ways. Use the
launcher script; read the rest only when it misbehaves.

## Use the launcher

```bash
.claude/skills/gtkwave-view/scripts/gtkwave.sh rtl-test/tb_trouper_spi.vcd
```

The path is host-relative (to the repo root) or absolute; the script translates
it to the container path. Extra args pass straight through to GTKWave, so a
saved signal list works:

```bash
.claude/skills/gtkwave-view/scripts/gtkwave.sh rtl-test/tb_trouper_spi.vcd --save rtl-test/waves/spi.gtkw
```

GTKWave is interactive and blocks the terminal until the window is closed. Run
it in the background (`run_in_background`) if you need the shell back, and tell
the user the window is up rather than waiting on the process to exit.

## The three failure modes

**1. Image wrapper.** The OSIC image has an entrypoint wrapper. A normal tool
command must be prefixed with `--skip bash -lc`; without it the container
misinterprets the command and never reaches GTKWave.

**2. `MoTTY X11 proxy: Unsupported authorisation protocol`.** The host
`~/.Xauthority` cookie is bound to a specific address family that the container
cannot match. Build a Docker-specific cookie file with an address-family-
independent (`ffff`) entry:

```bash
XAUTH_DOCKER=/tmp/trouper-x11.xauth
rm -f "$XAUTH_DOCKER"
xauth nlist "$DISPLAY" | sed -e 's/^..../ffff/' | xauth -f "$XAUTH_DOCKER" nmerge -
chmod 644 "$XAUTH_DOCKER"
```

Mount that file (not `~/.Xauthority`) and point `XAUTHORITY` at it inside the
container. The cookie must be regenerated whenever the X session restarts — the
script rebuilds it every invocation, which is cheap and avoids a stale-cookie
class of bug.

**3. GTKWave launches but cannot open the file.** The bind mount is
`$PWD:/foss/designs/lora-mimo`, so running from `~` mounts the *home directory*
at the project path and every in-container path is wrong. Always mount the
repository root, not the current directory. The script resolves the root with
`git rev-parse --show-toplevel` for exactly this reason.

A successful launch prints `GTKWave Analyzer v4.0.0-prealpha ...` before the
window appears.

## Raw command, if the script is unavailable

```bash
cd ~/Documents/chipathon-2026/chipathon-2026-trouper

docker run --rm -it --network host \
  -e DISPLAY \
  -e XAUTHORITY=/tmp/.Xauthority \
  -v "$XAUTH_DOCKER:/tmp/.Xauthority:ro" \
  -v "$PWD":/foss/designs/lora-mimo \
  hpretl/iic-osic-tools:chipathon26 \
  --skip bash -lc \
  'exec gtkwave /foss/designs/lora-mimo/rtl-test/tb_trouper_spi.vcd'
```

Note this is a **local interactive** `docker run`, which is the one sanctioned
exception to the "always submit via SGE" rule — GTKWave needs the local X
display. Simulations that *produce* the waveform still go through `hqsub`
(see the **sge-job** skill); only the viewer runs locally.

## Signals worth adding

For `tb_trouper_spi.vcd`, add under the `tb_trouper_spi` scope:
`spi_cs`, `spi_sck`, `spi_mosi`, `spi_miso`.

Save the signal list from GTKWave (File → Write Save File) into
`rtl-test/waves/<tb>.gtkw` and reuse it via `--save` so the next session opens
with the same view instead of re-picking signals by hand.
