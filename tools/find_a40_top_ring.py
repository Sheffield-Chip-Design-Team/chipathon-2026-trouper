"""Print wide M5 shapes at the north edge of the job-5396 A40 macro."""
import pya

ly = pya.Layout()
ly.read(globals()["gds"])
top = ly.top_cell()
region = pya.Region(top.begin_shapes_rec(ly.layer(81, 0)))
window = pya.Region(pya.Box(0, 1070000, 1675000, 1110000))
for poly in (region & window).each():
    box = poly.bbox()
    if box.width() > 100000:
        print(box)
