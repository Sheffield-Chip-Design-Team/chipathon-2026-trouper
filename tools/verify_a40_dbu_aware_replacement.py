import pya
gds = globals()["gds"]
ly = pya.Layout(); ly.read(gds)
top = ly.cell("SSCS_2026_01") or ly.top_cell()
print("dbu", ly.dbu, "top_bbox", top.bbox().to_s())
for inst in top.each_inst():
    if inst.cell.name.startswith("A40_"):
        print("cell", inst.cell.name, "raw_bbox", inst.cell.bbox().to_s(),
              "trans", inst.cplx_trans.to_s(), "effective_bbox", inst.bbox().to_s())
