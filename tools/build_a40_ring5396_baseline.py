"""Make a review-only full-chip GDS with the job-5396 A40 macro and no bridge."""
import pya

macro = pya.Layout()
macro.read(globals()["macro_gds"])
prefix = "A40_RING5396_BASE__"
top_name = macro.top_cell().name
for cell in macro.each_cell():
    cell.name = prefix + cell.name
renamed = "/tmp/a40_ring5396_baseline_renamed.gds"
macro.write(renamed)

chip = pya.Layout()
chip.read(globals()["chip_gds"])
chip.read(renamed)
top = chip.cell("SSCS_2026_01")
replacement = chip.cell(prefix + top_name)
old = [i for i in top.each_inst() if i.cell.name == "A40_trouper_top"]
assert top and replacement and len(old) == 1
trans = old[0].trans
old[0].delete()
top.insert(pya.CellInstArray(replacement.cell_index(), trans))
chip.write(globals()["output_gds"])
