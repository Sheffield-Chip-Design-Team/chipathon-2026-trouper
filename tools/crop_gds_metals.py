"""Write a flat, metal-only crop of a GDS for visual review."""
import pya

src = globals()["source"]
out = globals()["output"]
box = pya.Box(*[int(v) for v in globals()["box"].split(",")])

source = pya.Layout()
source.read(src)
target = pya.Layout()
target.dbu = source.dbu
top = target.create_cell("A40_POWER_CROP")
source_top = source.cell(globals().get("top_name", "")) or source.top_cell()

for layer, datatype in [(34, 0), (35, 0), (36, 0), (38, 0), (42, 0),
                        (40, 0), (46, 0), (41, 0), (81, 0), (82, 0)]:
    src_layer = source.layer(layer, datatype)
    region = pya.Region(source_top.begin_shapes_rec(src_layer))
    region = region & pya.Region(box)
    if not region.is_empty():
        top.shapes(target.layer(layer, datatype)).insert(region)

target.write(out)
print("wrote", out, "crop", box)
