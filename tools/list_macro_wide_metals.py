import pya
gds = globals()["gds"]
ly = pya.Layout(); ly.read(gds)
top = ly.cell("trouper_top") or ly.top_cell()
print("dbu", ly.dbu, "bbox", top.bbox().to_s())
for number in (36, 42, 46, 81):
    print("LAYER", number)
    shown = 0
    for shape in top.shapes(ly.layer(number, 0)).each():
        b = shape.bbox()
        if b.width() >= 5000 or b.height() >= 5000:
            print(b.to_s())
            shown += 1
            if shown == 80: break
    print("COUNT", shown)
