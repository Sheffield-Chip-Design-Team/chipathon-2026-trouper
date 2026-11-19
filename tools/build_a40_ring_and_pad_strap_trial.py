"""Create a review-only full-chip GDS with the 5396 A40 macro and pad straps.

The released full-chip GDS is read as input only.  The old A40 macro instance is
replaced in the output hierarchy by a prefix-renamed import of the job-5396
macro, avoiding any collision with cells already in the assembled chip.  Twelve
top-level Metal2 rectangles bridge the A40 VDD/VSS boundary fingers to N14/W12.
"""
import pya

chip_gds = globals()["chip_gds"]
macro_gds = globals()["macro_gds"]
output_gds = globals()["output_gds"]
prefix = "A40_RING5396__"

# Rename the imported macro hierarchy in a separate layout.  This deliberately
# preserves the original cells in the assembled source layout untouched.
macro = pya.Layout()
macro.read(macro_gds)
macro_top = macro.top_cell()
macro_top_name = macro_top.name
for cell in macro.each_cell():
    cell.name = prefix + cell.name
new_top_name = prefix + macro_top_name
renamed_macro_gds = "/tmp/a40_ring5396_renamed_for_trial.gds"
macro.write(renamed_macro_gds)

chip = pya.Layout()
chip.read(chip_gds)
chip.read(renamed_macro_gds)
top = chip.cell("SSCS_2026_01")
assert top, "missing full-chip top"
new_macro = chip.cell(new_top_name)
if not new_macro:
    print("macro top before rename:", macro_top.name)
    print("requested imported top:", new_top_name)
    print("available imported cells:", [c.name for c in chip.each_cell() if c.name.startswith(prefix)][:20])
    raise AssertionError("failed to import renamed 5396 macro")

old = []
for inst in top.each_inst():
    if inst.cell.name == "A40_trouper_top":
        old.append(inst)
assert len(old) == 1, "expected exactly one old A40 macro instance"
old_trans = old[0].trans
old[0].delete()
top.insert(pya.CellInstArray(new_macro.cell_index(), old_trans))

# Physical overlaps across the original abutments, in 1 nm database units.
m2 = chip.layer(36, 0)
vdd_x = [(1681360, 1690860), (1693760, 1704010), (1705610, 1715860),
         (1719140, 1729390), (1730990, 1741240), (1744140, 1753640)]
vss_y = [(1481360, 1490860), (1493760, 1504010), (1505610, 1515860),
         (1519140, 1529390), (1530990, 1541240), (1544140, 1553640)]
for left, right in vdd_x:
    top.shapes(m2).insert(pya.Box(left, 2584000, right, 2586000))
for bottom, top_y in vss_y:
    top.shapes(m2).insert(pya.Box(349000, bottom, 351000, top_y))

chip.write(output_gds)
print("wrote", output_gds, "with", new_top_name, "and 12 M2 bridges")
