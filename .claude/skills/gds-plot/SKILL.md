---
name: gds-plot
description: Render a GDS layout (from a local P&R run or an NFS run directory) to a PNG via headless KLayout, with a hand-tuned color/dither scheme for routing review. Covers the xvfb-run hang, .lyp layer-name-vs-source_layer matching bug, near-identical PDK default metal colors, and the diagonal-dither-pattern that misrepresents wire direction. Triggers on "screenshot the GDS", "render the layout", "plot the die", "show me the routing", "klayout image of <run>".
---

# gds-plot

Renders a `.gds` (local or under `/srv/eda/runs/...` on NFS) to a PNG with
only the metal/via routing layers + cell footprints visible, each metal in a
distinct solid color.

**Use `raster_gds.sh`, not `render_gds.sh`.** `render_gds.sh` (KLayout's own
`LayoutView.save_image()`) is confirmed broken as of 2026-08-19 — see "Known
issue" below — it silently ignores all layer colors and paints everything as
a flat, wrong-colored mass, verified via property readback, not just visual
inspection. `raster_gds.sh` bypasses that broken paint stage entirely by
reading polygon geometry directly via `pya.Region` and rasterizing with
`pycairo`; it is the current working path and is also faster (~12s vs
~1-2 min for a ~950k-polygon design). Keep reading only if it misbehaves or
the layer/color scheme needs changing.

## Use the launcher

```bash
.claude/skills/gds-plot/scripts/raster_gds.sh <gds> <out.png> [width] [height]
```

Examples:

```bash
# Local run
.claude/skills/gds-plot/scripts/raster_gds.sh \
  rtl-test/ol_trouper_top/runs/RUN_2026.../final/gds/trouper_top.gds \
  reports/trouper_top_render.png

# NFS run (SGE job output), custom resolution
.claude/skills/gds-plot/scripts/raster_gds.sh \
  /srv/eda/runs/timothyn-dev/lora-mimo/4473/trouper_top_lshape_v27_keepout/run/final/gds/trouper_top.gds \
  reports/trouper_top_lshape_v27_keepout.png \
  3200 2133
```

`<gds>` can be anywhere readable (it gets its own read-only mount); `<out.png>`
is written relative to the repo root or as an absolute path. Takes ~10-15s for
designs in the ~1M-polygon range; scales roughly linearly with total polygon
count across the kept layers.

No `.lyp` file needed (colors are hardcoded in `raster_gds.py`, not sourced
from the PDK layer-properties file) and no Xvfb needed
(`QT_QPA_PLATFORM=offscreen` — a real headless Qt platform plugin, not a
virtual X server).

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

To change the layer set or colors, edit the `LAYERS` list at the top of
`scripts/raster_gds.py` (or `KEEP` in the now-secondary `render_gds.py`) —
GF180MCU GDS layer/datatype numbers: Metal1=(34,0), Via1=(35,0),
Metal2=(36,0), Via2=(38,0), Metal3=(42,0), Via3=(40,0), Metal4=(46,0),
Via4=(41,0), Metal5=(81,0), Via5=(82,0), MetalTop=(53,0), COMP=(22,0).
`raster_gds.py`'s `LAYERS` list order **is** the draw order (bottom to top
physically) — unlike the broken `render_gds.py` path, this one actually
respects it, so list a layer later to have it occlude ones listed earlier.

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

## Known issue (2026-08-19): solid-orange output regardless of layer properties — paint-stage bug, not a script bug

Renders as of 2026-08-19 come out **solid orange everywhere**, no
distinguishable per-layer colors, even for a GDS from a previous run
(job 4473, `trouper_top_lshape_v27_keepout`) that's the source of the
multi-color reference image already in `reports/` and rendered correctly
the day before. Isolated with a definitive test, not just inference from
pixels — **this is not a script logic bug**:

**The docker image itself is unchanged** — `docker inspect
hpretl/iic-osic-tools:chipathon26` shows `Created: 2026-05-12`, same digest
as always. Ruled out a pulled-image regression.

**Layer properties are being set correctly — confirmed by reading them back
after the modification loop, before `save_image()`:**

```python
# after the KEEP-filtering loop, before lv.zoom_fit()/save_image():
it2 = lv.begin_layers()
while not it2.at_end():
    lp2 = it2.current()
    if lp2.visible:
        print(key, "fill=%08x" % lp2.fill_color, "dither=", lp2.dither_pattern)
    it2.next()
```

This printed exactly the 12 intended layers, visible, with the exact
intended `fill_color` values (`ffff8c00` for Metal2, `ffff0000` for Metal3,
etc.) and `dither=0`. Restricting `KEEP` to a single layer (e.g. only
Metal3, red `ffff0000`, COMP disabled) also verified correctly via
readback — and **still rendered solid orange**, not red. A single
confirmed-opaque COMP layer alone (`fill=ff808080`, plain opaque gray, no
alpha — see next point) also rendered orange, not gray.

**One real property bug found along the way (not the main cause):**
`CELL_COLOR = 0x30808080` (alpha `0x30`, meant to be translucent) reads back
as `fill=ff808080` — `fill_color` does not appear to support an alpha
channel in this KLayout build; COMP always ends up fully opaque regardless
of the alpha byte passed in.

**Conclusion: the model-level layer properties are correct; the paint stage
inside `LayoutView.save_image()` isn't honoring them.** Confirmed this isn't
Xvfb-specific either — switching to the `offscreen` Qt platform plugin
(`QT_QPA_PLATFORM=offscreen`, a real headless renderer, no virtual X server
at all) reproduces the identical broken output. So it's something inside
KLayout's `LayoutView` paint pipeline itself in this build, not the display
backend, not this repo's script or `.lyp` config.

**Workaround found and shipped as the new default (`raster_gds.py`/
`raster_gds.sh`):** don't go through `LayoutView`/`save_image()` at all.
Load the GDS with a bare `pya.Layout()` (no view), extract each layer's
merged geometry with `pya.Region(top.begin_shapes_rec(layer_index))`, and
rasterize the polygons directly with `pycairo` (`ImageSurface` +
`Context.fill()`), painting layers bottom-to-top in real physical stack
order so upper metals correctly occlude lower ones. This is a completely
different code path from the broken one and is unaffected — verified
correct output (matches the pre-existing multi-color reference image's
signature: M3 red-dominant, M4 purple vertical, M5 cyan horizontal) and is
also much faster: ~12s end-to-end for a ~950k-merged-polygon design at
3200×2133, vs ~1-2 min (and wrong output) via the old path. `pycairo`,
`PIL`, and `numpy` are all present in the `hpretl/iic-osic-tools:chipathon26`
image's KLayout-embedded Python, confirmed by direct import test.

`render_gds.py`/`render_gds.sh` are kept for reference (e.g. if a future
KLayout image update fixes the underlying bug) but should not be used until
someone re-verifies `save_image()` actually respects layer properties again.

## This is a local `docker run`, by design

Like `gtkwave-view`, this needs a local X-less headless docker run for a
one-shot image, not an SGE batch job — submitting it to SGE for one PNG isn't
worth the round-trip. It's a sanctioned exception to "always submit via SGE"
in the same way GTKWave viewing is.
