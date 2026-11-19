import pya
gds = globals()["gds"]
ly = pya.Layout(); ly.read(gds)
target = pya.Box(336000, 513000, 346000, 518000)
for cell in ly.each_cell():
    n = 0
    for s in cell.shapes(ly.layer(36, 0)).each_touching(target):
        print(cell.name, s.bbox().to_s())
        n += 1
        if n >= 20: break
