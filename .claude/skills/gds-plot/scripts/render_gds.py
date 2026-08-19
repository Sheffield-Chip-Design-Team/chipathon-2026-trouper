"""
KLayout pya batch-render script. Run only via klayout -z -r (not standalone).

Injected globals (via `klayout -z -r render_gds.py -rd name=value`):
  gds     - path to the .gds file to render (required)
  lyp     - path to a KLayout .lyp layer-properties file to source colors from
            (required; use the PDK's gf180mcu.lyp)
  out     - output PNG path (required)
  width   - image width in px (default 2000)
  height  - image height in px (default 2000)
  cellname- top cell name to render (default: layout's top cell)

Fixed, hand-tuned color/visibility scheme (see .claude/skills/gds-plot/SKILL.md
for why these particular choices exist -- do not "restore" PDK default colors
or dither patterns, both were found to be actively misleading for routing
review):
  - Only metal/via routing layers + COMP (transistor/cell footprint) are shown;
    everything else in the .lyp (wells, implants, texts, etc.) is hidden.
  - Each metal gets a distinct saturated color (the PDK defaults put M3/M5/
    MetalTop on near-identical yellow-greens -- unusable for visual diff).
  - dither_pattern is forced to 0 (solid fill) for every kept layer. The PDK
    default stipple for metals is a diagonal hatch that visually dominates at
    low zoom and makes horizontal-preferred layers look vertical-dominant and
    vice versa -- solid fill is the only way to see the true wire direction.
  - COMP is drawn as a translucent gray wash (cell footprints), not a solid
    fill, so it reads as background texture under the metals.
"""
import pya

gds = globals().get("gds")
lyp = globals().get("lyp")
out = globals().get("out")
width = int(globals().get("width", 2000))
height = int(globals().get("height", 2000))
cellname = globals().get("cellname", None)

if not gds or not lyp or not out:
    raise SystemExit("render_gds.py requires -rd gds=... -rd lyp=... -rd out=...")

# GDS layer/datatype -> (fill/frame color, label). GF180MCU numbering.
KEEP = {
    (34, 0): (0x808080, "Metal1"),   # gray
    (35, 0): (0xFFFFFF, "Via1"),     # white
    (36, 0): (0xFF8C00, "Metal2"),   # orange
    (38, 0): (0xFFFFFF, "Via2"),
    (42, 0): (0xFF0000, "Metal3"),   # red
    (40, 0): (0xFFFFFF, "Via3"),
    (46, 0): (0xB000FF, "Metal4"),   # purple
    (41, 0): (0xFFFFFF, "Via4"),
    (81, 0): (0x00E5FF, "Metal5"),   # cyan
    (82, 0): (0xFFFFFF, "Via5"),
    (53, 0): (0xFFD500, "MetalTop"), # yellow
}
CELL_LAYER = (22, 0)          # COMP - transistor/cell footprint wash
CELL_COLOR = 0x30808080        # translucent gray (ARGB)

mw = pya.Application.instance().main_window()
mw.create_layout(1)
lv = mw.current_view()
cv_index = lv.load_layout(gds, 1)
lv.active_cellview_index = cv_index
# load_layout(..., 1) already shows the layout's top cell -- don't touch
# cv.cell_index / set_current_cell_path afterwards, it was found (empirically)
# to leave the view showing nothing. Only override when a specific sub-cell
# was requested.
if cellname:
    cv = lv.cellview(cv_index)
    top = cv.layout().cell_by_name(cellname)
    lv.set_current_cell_path(cv_index, [top])

lv.load_layer_props(lyp)

kept = 0
total = 0
it = lv.begin_layers()
while not it.at_end():
    lp = it.current()
    total += 1
    key = (lp.source_layer, lp.source_datatype)
    new_lp = lp.dup()
    if key in KEEP:
        color, _label = KEEP[key]
        new_lp.visible = True
        new_lp.fill_color = color
        new_lp.frame_color = color
        new_lp.dither_pattern = 0
        kept += 1
    elif key == CELL_LAYER:
        new_lp.visible = True
        new_lp.fill_color = CELL_COLOR
        new_lp.frame_color = CELL_COLOR
        new_lp.dither_pattern = 0
        kept += 1
    else:
        new_lp.visible = False
    lv.set_layer_properties(it, new_lp)
    it.next()

print("layers total=%d kept=%d" % (total, kept))

lv.zoom_fit()
lv.save_image(out, width, height)
print("wrote %s" % out)
