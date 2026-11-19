"""Report the explicit top-level shapes of the narrow A40 finger trial."""
import pya

ly = pya.Layout()
ly.read(globals()["gds"])
top = ly.cell("SSCS_2026_01")
window = pya.Box(1718000, 2572000, 1731000, 2587000)
for number, name in [(36, "Metal2"), (38, "Via2"), (42, "Metal3"),
                     (40, "Via3"), (46, "Metal4")]:
    shapes = pya.Region(top.shapes(ly.layer(number, 0))) & pya.Region(window)
    print(name, "top-level shapes", shapes.count())
    for polygon in shapes.each():
        print(" ", polygon.bbox())
