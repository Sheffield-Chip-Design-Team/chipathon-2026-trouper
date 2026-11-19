"""Inspect the A40 macro power-port and padring power-cell geometry in a GDS."""
import pya

ly = pya.Layout()
ly.read(globals()["gds"])
top = ly.top_cell()

for inst in top.each_inst():
    child = inst.cell
    if "a40_trouper" in child.name.lower():
        print("MACRO", child.name, "trans", inst.trans, "bbox", inst.bbox())
        for li, layer_name in [(36, "M2"), (42, "M3"), (46, "M4"), (81, "M5")]:
            reg = pya.Region(child.begin_shapes_rec(ly.layer(li, 0)))
            reg.merge()
            print(" MACRO", layer_name, "bbox", reg.bbox(), "polys", reg.count())
            if layer_name == "M2":
                for poly in reg.each():
                    b = poly.bbox()
                    if b.left <= 0 or b.top >= 1110000:
                        print("  BOUNDARY_M2", b)
        for li in ly.layer_indexes():
            for shape in child.shapes(li).each():
                if shape.is_text() and shape.text.string.upper() in ("VDD", "VSS"):
                    print(" MACRO_TEXT", shape.text.string, "layer", ly.get_info(li), "at", shape.text.trans)
    if "padring" in child.name.lower():
        print("PADRING", child.name, "trans", inst.trans, "bbox", inst.bbox())
        for pad in child.each_inst():
            n = pad.cell.name.lower()
            if any(key in n for key in ("dvdd", "dvss", "n14", "w12")):
                print(" PAD", pad.cell.name, "trans", pad.trans, "bbox", pad.bbox())
                for li, layer_name in [(36, "M2"), (42, "M3"), (46, "M4"), (81, "M5")]:
                    reg = pya.Region(pad.cell.begin_shapes_rec(ly.layer(li, 0)))
                    reg.transform(pad.trans)
                    reg.merge()
                    print("  PAD", layer_name, "bbox", reg.bbox(), "polys", reg.count())
