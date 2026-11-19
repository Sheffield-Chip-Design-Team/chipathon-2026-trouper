import pya
gds = globals()["gds"]
ly = pya.Layout(); ly.read(gds)
top = ly.cell("SSCS_2026_01") or ly.top_cell()
area = pya.Box(330000, 510000, 345000, 520000)
print("dbu", ly.dbu, "top", top.name)
for number in (36, 38, 42, 40, 46, 41, 81):
    boxes = []
    for s in top.shapes(ly.layer(number, 0)).each_touching(area):
        boxes.append(s.bbox().to_s())
    print(number, len(boxes), boxes[:30])
