import pya
gds = globals()["gds"]
ly = pya.Layout(); ly.read(gds)
cell = ly.cell("A40_trouper_top")
assert cell
for number in (36, 42, 46, 81):
    print("LAYER", number)
    count = 0
    for shape in cell.shapes(ly.layer(number, 0)).each():
        box = shape.bbox()
        if box.width() >= 200 or box.height() >= 200:
            print(box.to_s())
            count += 1
            if count >= 100: break
    print("COUNT", count)
