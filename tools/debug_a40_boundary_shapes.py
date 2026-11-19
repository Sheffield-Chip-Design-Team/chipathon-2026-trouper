import pya
gds = globals()["gds"]
layout = pya.Layout(); layout.read(gds)
top = layout.cell("trouper_top") or layout.top_cell()
for label, layer, clip in [
    ("north-m2", 36, pya.Box()), ("north-m3", 42, pya.Box()),
    ("north-m4", 46, pya.Box()), ("north-m5", 81, pya.Box()),
    ("west-m2", 36, pya.Box()), ("west-m3", 42, pya.Box()),
    ("west-m4", 46, pya.Box()), ("west-m5", 81, pya.Box()),
]:
    print(label, "layer", layer)
    it = top.begin_shapes_rec(layout.layer(layer, 0))
    n = 0
    while not it.at_end():
        box = it.shape().bbox().transformed(it.trans())
        if (label.startswith("north") and box.top >= 1109900) or (label.startswith("west") and box.left <= 100):
            print(box.to_s())
            n += 1
            if n == 80: break
        it.next()
    print("count", n)
