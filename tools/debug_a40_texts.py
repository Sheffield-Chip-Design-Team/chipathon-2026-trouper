import pya
gds = globals()["gds"]
layout = pya.Layout(); layout.read(gds)
for cell in layout.each_cell():
    if "trouper" not in cell.name.lower() and cell.name != "SSCS_2026_01":
        continue
    print("CELL", cell.name, "bbox", cell.bbox().to_s())
    for layer_index in range(layout.layers()):
        info = layout.get_info(layer_index)
        it = cell.begin_shapes_rec(layer_index)
        count = 0
        while not it.at_end():
            shape = it.shape()
            if shape.is_text():
                text = shape.text.string
                if "VDD" in text.upper() or "VSS" in text.upper() or "DV" in text.upper():
                    print("TEXT", info.to_s(), text, "at", shape.text.trans.disp.to_s())
                    count += 1
                    if count >= 100: break
            it.next()
