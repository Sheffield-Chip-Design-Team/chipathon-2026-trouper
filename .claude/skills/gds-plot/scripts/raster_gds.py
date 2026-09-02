"""
Bypass KLayout's broken save_image() paint stage entirely: extract merged
polygon geometry per layer via pya.Region and rasterize with pycairo
directly. Run via: klayout -z -r raster_gds.py -rd gds=... -rd out=... [-rd width=... -rd height=...]
"""
import pya
import cairo
import time

gds = globals().get("gds")
out = globals().get("out")
width = int(globals().get("width", 2400))
height = int(globals().get("height", 1600))

t0 = time.time()
ly = pya.Layout()
ly.read(gds)
top = ly.top_cell()
dbu = ly.dbu
bbox = top.bbox()
bx0, by0, bx1, by1 = bbox.left, bbox.bottom, bbox.right, bbox.top
w_dbu = bx1 - bx0
h_dbu = by1 - by0

# fit-to-image scale, preserve aspect ratio, small margin
margin = 0.02
scale = min(width * (1 - 2 * margin) / w_dbu, height * (1 - 2 * margin) / h_dbu)
ox = (width - w_dbu * scale) / 2.0
oy = (height - h_dbu * scale) / 2.0

def to_px(x, y):
    # flip Y: GDS y-up -> image y-down
    px = ox + (x - bx0) * scale
    py = height - (oy + (y - by0) * scale)
    return px, py

surface = cairo.ImageSurface(cairo.FORMAT_ARGB32, width, height)
cr = cairo.Context(surface)
cr.set_source_rgb(0, 0, 0)
cr.paint()

# (layer, datatype) -> (r,g,b,a, label), drawn in this list's order = bottom to top physically
LAYERS = [
    ((22, 0), (0.50, 0.50, 0.50, 0.35), "COMP"),      # translucent gray wash
    ((34, 0), (0.50, 0.50, 0.50, 1.0), "Metal1"),
    ((35, 0), (1.00, 1.00, 1.00, 1.0), "Via1"),
    ((36, 0), (1.00, 0.549, 0.0, 1.0), "Metal2"),      # orange
    ((38, 0), (1.00, 1.00, 1.00, 1.0), "Via2"),
    ((42, 0), (1.00, 0.0, 0.0, 1.0), "Metal3"),        # red
    ((40, 0), (1.00, 1.00, 1.00, 1.0), "Via3"),
    ((46, 0), (0.690, 0.0, 1.00, 1.0), "Metal4"),      # purple
    ((41, 0), (1.00, 1.00, 1.00, 1.0), "Via4"),
    ((81, 0), (0.0, 0.898, 1.00, 1.0), "Metal5"),      # cyan
    ((82, 0), (1.00, 1.00, 1.00, 1.0), "Via5"),
    ((53, 0), (1.00, 0.835, 0.0, 1.0), "MetalTop"),    # yellow
]

for (l, d), (r, g, b, a), name in LAYERS:
    li = ly.layer(l, d)
    region = pya.Region(top.begin_shapes_rec(li))
    region.merge()
    n = region.count()
    if n == 0:
        print("%s: 0 polygons, skip" % name)
        continue
    cr.set_source_rgba(r, g, b, a)
    # Even-odd fill so a polygon's holes stay holes.  Ring-shaped geometry
    # (padring power rings, guard rings) is a donut: drawing only the hull
    # fills the hole solid and floods everything beneath it.
    cr.set_fill_rule(cairo.FILL_RULE_EVEN_ODD)
    drawn = 0
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
        drawn += 1
    cr.fill()
    print("%s: %d polygons drawn (%.1fs elapsed)" % (name, drawn, time.time() - t0))

surface.write_to_png(out)
print("wrote %s (%.1fs total)" % (out, time.time() - t0))
