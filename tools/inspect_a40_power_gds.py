"""Report the A40 power-pad and Trouper-macro geometry in an assembled GDS.

Run under KLayout:
  klayout -z -r inspect_a40_power_gds.py -rd gds=/path/to/SSCS_2026_01.gds
"""
import pya

gds = globals()["gds"]
ly = pya.Layout()
ly.read(gds)

top = ly.cell("SSCS_2026_01")
if top is None:
    top = ly.top_cell()
print("dbu", ly.dbu, "top", top.name, "bbox", top.bbox())
print("top-level cells:", [ly.cell(i).name for i in ly.each_top_cell()])

for cell in ly.each_cell():
    name = cell.name.lower()
    if "a40" in name or "trouper" in name or "sscs_2026_01" in name:
        print("CELL", cell.name, "bbox", cell.bbox())

for inst in top.each_inst():
    child = inst.cell
    if "a40" in child.name.lower() or "trouper" in child.name.lower():
        print("TOP_INST", child.name, "trans", inst.trans, "bbox", inst.bbox())

# Do not recursively merge full-chip layers here; the assembled die is large
# enough for that to dominate inspection runtime.
