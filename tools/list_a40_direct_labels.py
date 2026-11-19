import pya
gds = globals()["gds"]
ly = pya.Layout(); ly.read(gds)
cell = ly.cell("A40_trouper_top")
assert cell
for li in range(ly.layers()):
    info = ly.get_info(li)
    for s in cell.shapes(li).each():
        if s.is_text() and s.text.string in ("VDD", "VSS", "DVDD", "DVSS"):
            print(info.to_s(), s.text.string, s.text.trans.disp.to_s())
