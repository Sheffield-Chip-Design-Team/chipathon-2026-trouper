---
name: gds-plot
description: Render a GDS layout (from a local P&R run or an NFS run directory) to a PNG via headless KLayout, with a hand-tuned color/dither scheme for routing review. Covers the xvfb-run hang, .lyp layer-name-vs-source_layer matching bug, near-identical PDK default metal colors, and the diagonal-dither-pattern that misrepresents wire direction. Triggers on "screenshot the GDS", "render the layout", "plot the die", "show me the routing", "klayout image of <run>".
---

# gds-plot

Renders a `.gds` (local or under `/srv/eda/runs/...` on NFS) to a PNG with
only the metal/via routing layers + cell footprints visible, each metal in a
distinct solid color. Use the launcher; read the rest only if it misbehaves
or the default scheme needs changing.

## Use the launcher

```bash
.claude/skills/gds-plot/scripts/render_gds.sh <gds> <out.png> [width] [height] [cellname]
```

Examples:

```bash
# Local run
.claude/skills/gds-plot/scripts/render_gds.sh \
  rtl-test/ol_trouper_top/runs/RUN_2026.../final/gds/trouper_top.gds \
  reports/trouper_top_render.png

# NFS run (SGE job output), custom resolution
.claude/skills/gds-plot/scripts/render_gds.sh \
  /srv/eda/runs/timothyn-dev/lora-mimo/4473/trouper_top_lshape_v27_keepout/run/final/gds/trouper_top.gds \
  reports/trouper_top_lshape_v27_keepout.png \
  2400 1600
```

`<gds>` can be anywhere readable (it gets its own read-only mount); `<out.png>`
is written relative to the repo root or as an absolute path. Takes ~1-2 min.

## What gets drawn, and why these specific choices

Only metal/via layers (M1-M5, MetalTop, all vias) plus COMP (cell footprints,
drawn as a translucent gray wash) are visible — everything else in the PDK
`.lyp` (wells, implants, text, etc.) is hidden. Each metal gets a distinct
hand-picked saturated color (M2 orange, M3 red, M4 purple, M5 cyan, MetalTop
yellow, vias white, M1 gray). Every kept layer is forced to solid fill
(`dither_pattern = 0`).

These aren't arbitrary — both non-obvious choices were found the hard way
while producing the L-shape floorplan comparison renders:

- **PDK default colors put M3, M5, and MetalTop on near-identical
  yellow-greens** (`0x97b91b`, `0xcdc16b`, `0xb1dd9c`) — visually
  indistinguishable at any zoom. The layer set above uses mutually distinct
  hues instead.
- **PDK default dither for metals is a diagonal hatch stipple.** At low zoom
  (a full-die render) this diagonal texture visually dominates over the
  actual wire direction, making horizontal-preferred layers (M3, M5 per the
  tech-LEF) *look* vertical-dominant and vice versa — actively misleading for
  a "which layer is routing which direction" review. Forcing solid fill
  (`dither_pattern = 0`) was the fix; re-rendering then correctly showed
  M3/M5 horizontal-dominant and M4 vertical-dominant, matching the tech-LEF.

To change the layer set or colors, edit the `KEEP` dict at the top of
`scripts/render_gds.py` — GF180MCU GDS layer/datatype numbers: Metal1=(34,0),
Via1=(35,0), Metal2=(36,0), Via2=(38,0), Metal3=(42,0), Via3=(40,0),
Metal4=(46,0), Via4=(41,0), Metal5=(81,0), Via5=(82,0), MetalTop=(53,0),
COMP=(22,0).

## The three failure modes this works around

**1. `xvfb-run` hangs with 0% CPU, no error.** `xvfb-run`'s internal
readiness-wait is flaky and can stall forever without klayout ever launching
(confirmed via `docker top`/`docker stats` showing only `Xvfb` running). The
script starts `Xvfb` manually, sleeps 3s, then runs `klayout -z` directly with
`DISPLAY` set — bypassing `xvfb-run` entirely.

**2. Layer filtering by name silently does nothing.** `LayerProperties.name`
is empty (`''`) for every entry in this `.lyp` file — filtering on it matches
nothing. Match on `(lp.source_layer, lp.source_datatype)` instead (the
numeric GDS layer/datatype pair), which is reliable.

**3. Touching `cv.cell_index` / `set_current_cell_path` after load blanks the
view.** `load_layout(gds, 1)` already shows the layout's top cell; explicitly
re-setting the cellview's `cell_index` (even to the same top cell) and then
calling `set_current_cell_path` afterwards was found to leave `zoom_fit()`
saving an empty image (grid only, no geometry) despite `begin_layers()`
correctly reporting the expected layers as visible. Only touch cell selection
when a specific `cellname` sub-cell is requested; leave the default top-cell
view alone otherwise — `render_gds.py` does this already.

**4. `-rd name=value` doesn't show up in `sys.argv`.** With `klayout -z -r
script.py -rd k=v`, KLayout injects `-rd` values as **Python global
variables** in the script's namespace, not as `sys.argv` entries. Reference
them as bare names (`gds = globals().get("gds")`, etc.) as `render_gds.py`
does — don't write `sys.argv` parsing into it.

## Layer-utilization analysis (not just images)

For "how much of layer X is used" or "why does this region look dominated by
layer Y" questions, `pya.Region` boolean ops on a loaded layout answer it
directly rather than eyeballing the render — e.g. intersect a metal layer's
`Region` with a `pya.Box` for a sub-area (leg vs. main lobe of an L-shape) and
compare `.area()` against the box's area. There's no bundled script for this
(it was written ad hoc per-question); write a small one-off `klayout -z -r`
script alongside `render_gds.py` if a load-bearing area comparison comes up
again — reuse the same `-rd` global-injection pattern and the same
`cv.layout()` / `begin_layers()` access shown in `render_gds.py`.

## This is a local `docker run`, by design

Like `gtkwave-view`, this needs a local X-less headless docker run for a
one-shot image, not an SGE batch job — submitting it to SGE for one PNG isn't
worth the round-trip. It's a sanctioned exception to "always submit via SGE"
in the same way GTKWave viewing is.
