"""Create a review-only full-chip GDS with A40 M2 power-abutment bridges.

The source GDS is opened read-only by the caller.  This script writes a new GDS
and only adds twelve Metal2 rectangles in the top cell: six VDD at N14 and six
VSS at W12.  Each bridge overlaps both the macro boundary pin and the relevant
DVDD/DVSS pad metal by 1 um.
"""
import pya

source = globals()["source"]
output = globals()["output"]

ly = pya.Layout()
ly.read(source)
top = ly.top_cell()
m2 = ly.layer(36, 0)

# Full-chip coordinates in database units (1 nm).  The A40 macro occupies
# (350,1475)--(2025,2585) um.  Values are the integrator's A40 DEF pin
# rectangles scaled from its 0.5 nm units, then translated to this instance.
vdd_x = [
    (1681360, 1690860), (1693760, 1704010), (1705610, 1715860),
    (1719140, 1729390), (1730990, 1741240), (1744140, 1753640),
]
vss_y = [
    (1481360, 1490860), (1493760, 1504010), (1505610, 1515860),
    (1519140, 1529390), (1530990, 1541240), (1544140, 1553640),
]

# N14 DVDD begins at y=2585 um; W12 DVSS ends at x=350 um.
for left, right in vdd_x:
    top.shapes(m2).insert(pya.Box(left, 2584000, right, 2586000))
for bottom, top_y in vss_y:
    top.shapes(m2).insert(pya.Box(349000, bottom, 351000, top_y))

ly.write(output)
print("wrote", output, "with 12 A40 M2 abutment bridges")
