import pya
gds = globals()["gds"]
ly = pya.Layout(); ly.read(gds)
top = ly.cell("SSCS_2026_01") or ly.top_cell()
area = pya.Box(60000, 280000, 220000, 530000)
for number in (36, 42, 46, 81):
    print("LAYER", number)
    count = 0
    for shape in top.shapes(ly.layer(number, 0)).each_touching(area):
        box = shape.bbox()
        if box.width() >= 200 or box.height() >= 200:
            print(box.to_s())
            count += 1
            if count >= 100: break
    print("COUNT", count)
