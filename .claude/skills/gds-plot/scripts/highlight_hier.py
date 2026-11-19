"""
Overlay highlight markers for one or more hierarchical instance-name
prefixes (e.g. "u_remod.", or all top-level trouper_top submodules at once)
onto a dimmed version of the same per-layer routing raster raster_gds.py
draws, with a text label at each block's marker centroid.

Why this needs the synthesized netlist AND the DEF, not just the GDS:
post-synthesis/techmap, cell INSTANCES are anonymized (_68483_ etc, both in
the .nl.v netlist and the DEF's COMPONENTS section) -- there is no
"u_remod.*"-prefixed cell instance anywhere (KEEP_HIERARCHY, which would
preserve that, is deliberately not used on this design). Only WIRE/NET names
keep their original hierarchical RTL names post-synthesis. So:
  1. Parse the flat netlist (<top>.nl.v) for each cell instance's port-net
     connections, and mark any instance touching a net whose name starts
     with one of the target prefixes (first-match-wins if a net somehow
     matched more than one, which shouldn't happen for disjoint top-level
     submodule prefixes).
  2. Parse the DEF's COMPONENTS section for each marked instance's placement
     (x, y) -- DEF and netlist share the same anonymized instance names, so
     this is a direct name-keyed join, no separate mapping file needed.
  3. Draw a bright, block-specific-colored marker at each matched instance's
     location on top of the existing GDS raster, then a text label at each
     block's marker centroid.

Approximation, not exhaustive: an instance is caught if ANY of its ports
touches a still-named net. Registers and any logic whose output net survived
with its original name are caught; a purely-internal combinational cell
whose net was fully anonymized by synthesis is not, and glue logic at the
top level with no submodule-prefixed net at all is correctly left
unhighlighted. Good enough to show where each subtree physically landed; not
a substitute for a real KEEP_HIERARCHY-preserving flow if exact cell-for-cell
membership is needed.

Run via: klayout -z -r highlight_hier.py -rd gds=... -rd def=... -rd nl=...
  -rd prefixes=... -rd out=... [-rd width=... -rd height=...]

`prefixes` is a comma-separated list, e.g. "u_dec,u_dcr,u_sc,u_tacc,u_comb,
u_remod" (a trailing "." is added to each automatically if not already
present).
"""
import pya
import cairo
import re
import time

gds = globals().get("gds")
def_path = globals().get("def")
nl_path = globals().get("nl")
prefixes_raw = globals().get("prefixes", "u_remod")
out = globals().get("out")
width = int(globals().get("width", 2400))
height = int(globals().get("height", 1600))

prefixes = []
for p in prefixes_raw.split(","):
    p = p.strip()
    if not p:
        continue
    if not p.endswith("."):
        p += "."
    prefixes.append(p)

PALETTE = [
    (0.0, 1.00, 0.15), (1.00, 0.85, 0.0), (0.20, 0.60, 1.00),
    (1.00, 0.30, 0.75), (1.00, 0.50, 0.0), (0.55, 0.35, 1.00),
    (0.0, 0.90, 0.90), (1.00, 1.00, 1.00), (0.75, 1.00, 0.0),
    (1.00, 0.0, 0.30), (0.45, 0.75, 0.20), (0.65, 0.65, 0.65),
    (0.30, 0.90, 0.55),
]

t0 = time.time()

# --- 1. Parse the flat netlist for instance -> touched net names ----------
inst_nets = {}
cur_inst = None
port_re = re.compile(r'^\s*\.\w+\(\s*(.+?)\s*\)\s*,?\s*$')
inst_start_re = re.compile(r'^\s*\S+\s+(\S+)\s*\($')

with open(nl_path) as f:
    for line in f:
        m = inst_start_re.match(line)
        if m:
            cur_inst = m.group(1)
            inst_nets[cur_inst] = set()
            continue
        if cur_inst is not None:
            if re.match(r'^\s*\);\s*$', line):
                cur_inst = None
                continue
            pm = port_re.match(line)
            if pm:
                expr = pm.group(1)
                for tok in re.findall(r'\\?[^\s{},]+', expr):
                    tok = tok.lstrip('\\')
                    if tok and not tok[0].isdigit() and "'" not in tok:
                        inst_nets[cur_inst].add(tok)

# instance name -> matched prefix (first hit wins)
inst_block = {}
for name, nets in inst_nets.items():
    for pfx in prefixes:
        if any(n.startswith(pfx) for n in nets):
            inst_block[name] = pfx
            break

counts = {}
for pfx in inst_block.values():
    counts[pfx] = counts.get(pfx, 0) + 1
print("netlist: %d instances total, %d matched across %d prefixes (%.1fs)" %
      (len(inst_nets), len(inst_block), len(prefixes), time.time() - t0))
for pfx in prefixes:
    print("  %s: %d" % (pfx, counts.get(pfx, 0)))

# --- 2. Parse the DEF COMPONENTS section for placement ---------------------
def_units = 1000.0
comp_re = re.compile(
    r'^\s*-\s+(\S+)\s+\S+.*PLACED\s*\(\s*(-?\d+)\s+(-?\d+)\s*\)')
points_by_block = {pfx: [] for pfx in prefixes}
in_components = False
with open(def_path) as f:
    for line in f:
        if line.startswith("UNITS DISTANCE MICRONS"):
            def_units = float(line.split()[3])
        if line.startswith("COMPONENTS"):
            in_components = True
            continue
        if line.startswith("END COMPONENTS"):
            in_components = False
            continue
        if in_components:
            m = comp_re.match(line)
            if m:
                name, x, y = m.group(1), m.group(2), m.group(3)
                pfx = inst_block.get(name)
                if pfx:
                    points_by_block[pfx].append(
                        (int(x) / def_units, int(y) / def_units))

print("DEF: placement resolved (%.1fs)" % (time.time() - t0))

# --- 3. Draw the existing per-layer raster, dimmed ------------------------
ly = pya.Layout()
ly.read(gds)
top = ly.top_cell()
dbu = ly.dbu
bbox = top.bbox()
bx0, by0, bx1, by1 = bbox.left, bbox.bottom, bbox.right, bbox.top
w_dbu = bx1 - bx0
h_dbu = by1 - by0

margin = 0.02
scale = min(width * (1 - 2 * margin) / w_dbu, height * (1 - 2 * margin) / h_dbu)
ox = (width - w_dbu * scale) / 2.0
oy = (height - h_dbu * scale) / 2.0

def to_px(x, y):
    px = ox + (x - bx0) * scale
    py = height - (oy + (y - by0) * scale)
    return px, py

surface = cairo.ImageSurface(cairo.FORMAT_ARGB32, width, height)
cr = cairo.Context(surface)
cr.set_source_rgb(0, 0, 0)
cr.paint()

LAYERS = [
    ((22, 0), (0.30, 0.30, 0.30, 0.30), "COMP"),
    ((34, 0), (0.30, 0.30, 0.30, 0.5), "Metal1"),
    ((36, 0), (0.45, 0.25, 0.0, 0.5), "Metal2"),
    ((42, 0), (0.45, 0.0, 0.0, 0.5), "Metal3"),
    ((46, 0), (0.28, 0.0, 0.40, 0.5), "Metal4"),
    ((81, 0), (0.0, 0.35, 0.40, 0.5), "Metal5"),
    ((53, 0), (0.45, 0.34, 0.0, 0.5), "MetalTop"),
]

for (l, d), (r, g, b, a), name in LAYERS:
    li = ly.layer(l, d)
    region = pya.Region(top.begin_shapes_rec(li))
    region.merge()
    if region.count() == 0:
        continue
    cr.set_source_rgba(r, g, b, a)
    cr.set_fill_rule(cairo.FILL_RULE_EVEN_ODD)
    for poly in region.each():
        contours = [list(poly.each_point_hull())]
        for h in range(poly.holes()):
            contours.append(list(poly.each_point_hole(h)))
        for pts in contours:
            if len(pts) < 3:
                continue
            first = True
            for p in pts:
                x_px, y_px = to_px(p.x, p.y)
                if first:
                    cr.move_to(x_px, y_px)
                    first = False
                else:
                    cr.line_to(x_px, y_px)
            cr.close_path()
    cr.fill()
print("background layers drawn (%.1fs)" % (time.time() - t0))

# --- 4. Highlight markers + centroid text labels, one color per block -----
marker_r = max(2.0, min(width, height) * 0.0022)
cr.select_font_face("sans-serif", cairo.FONT_SLANT_NORMAL, cairo.FONT_WEIGHT_BOLD)
font_size = max(14, int(min(width, height) * 0.016))
cr.set_font_size(font_size)

for i, pfx in enumerate(prefixes):
    pts_um = points_by_block[pfx]
    if not pts_um:
        continue
    r, g, b = PALETTE[i % len(PALETTE)]
    cr.set_source_rgba(r, g, b, 0.9)
    px_list = []
    for x_um, y_um in pts_um:
        gx = x_um / dbu
        gy = y_um / dbu
        px, py = to_px(gx, gy)
        px_list.append((px, py))
        cr.arc(px, py, marker_r, 0, 2 * 3.14159265)
        cr.fill()

    cx = sum(p[0] for p in px_list) / len(px_list)
    cy = sum(p[1] for p in px_list) / len(px_list)
    label = pfx.rstrip(".")
    ext = cr.text_extents(label)
    # White halo behind the label (drawn as a filled rect) so it reads over
    # both dark background and bright markers, then the block-colored text
    # on top so the label ties back to its marker color at a glance.
    pad = 4
    cr.set_source_rgba(0.0, 0.0, 0.0, 0.65)
    cr.rectangle(cx - ext.width / 2 - pad, cy - ext.height - pad,
                 ext.width + 2 * pad, ext.height + 2 * pad)
    cr.fill()
    cr.set_source_rgba(r, g, b, 1.0)
    cr.move_to(cx - ext.width / 2, cy - ext.height / 2 + ext.height / 2)
    cr.show_text(label)

surface.write_to_png(out)
print("wrote %s (%.1fs total)" % (out, time.time() - t0))
