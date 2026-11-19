"""Find the existing M2--M5 geometry at A40's VDD/VSS macro taps."""
import pya

ly = pya.Layout()
ly.read(globals()["gds"])
cell = ly.cell("A40_trouper_top") or ly.cell("trouper_top")
assert cell, "A40_trouper_top/trouper_top cell not found"

# Local macro coordinates, DBU=1 nm.  These boxes include the documented
# A40 DEF pin clusters and enough surrounding area to locate the core ring.
windows = {
    "VSS-west": pya.Box(0, 0, 100000, 180000),
    "VDD-north": pya.Box(1250000, 930000, 1675000, 1110000),
}

for wname, window in windows.items():
    print("WINDOW", wname, window)
    for gds_layer, lname in [(36, "M2"), (42, "M3"), (46, "M4"), (81, "M5")]:
        li = ly.layer(gds_layer, 0)
        region = pya.Region(cell.begin_shapes_rec(li)).interacting(pya.Region(window))
        region.merge()
        print(" ", lname, "count", region.count(), "bbox", region.bbox())
        for poly in list(region.each())[:20]:
            print("   ", poly.bbox())
