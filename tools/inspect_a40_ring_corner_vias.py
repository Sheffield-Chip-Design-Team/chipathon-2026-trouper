"""Count generated Via4 cuts in the VDD north-east M4/M5 ring corner."""
import pya

ly = pya.Layout()
ly.read(globals()["gds"])
top = ly.top_cell()
# Job 5396 A40 local VDD north M5 rail: y=1095.680..1100.680 um.
# VDD east M4 rail: x=1661.840..1666.840 um.
window = pya.Box(1661000, 1094800, 1667800, 1101600)
region = pya.Region(top.begin_shapes_rec(ly.layer(41, 0))) & pya.Region(window)
boxes = [p.bbox() for p in region.each()]
print("via4 cuts", len(boxes), "bbox", region.bbox())
print("unique x", sorted({b.left for b in boxes}))
print("unique y", sorted({b.bottom for b in boxes}))
