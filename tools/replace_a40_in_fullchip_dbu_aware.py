"""Create a review GDS replacing A40 with job-5413's native 0.001 um macro.

The full chip uses a 0.005 um database unit.  KLayout keeps the imported macro
coordinates verbatim, so the replacement instance uses magnification 0.2.  The
effective physical size is consequently unchanged (1675 x 1110 um).
"""
import pya

chip_gds = globals()["chip_gds"]
macro_gds = globals()["macro_gds"]
output_gds = globals()["output_gds"]
prefix = "A40_JOB5413__"

macro = pya.Layout()
macro.read(macro_gds)
assert abs(macro.dbu - .001) < 1e-12, macro.dbu
macro_top = macro.cell("trouper_top") or macro.top_cell()
assert macro_top is not None
macro_top_name = macro_top.name

chip = pya.Layout()
chip.read(chip_gds)
assert abs(chip.dbu - .005) < 1e-12, chip.dbu

# Do not call chip.read(macro_gds): KLayout would change chip.dbu to the
# imported file's DBU.  Copy the hierarchy into the existing layout instead;
# its raw coordinates are subsequently scaled at the replacement instance.
cell_map = {}
for source in macro.each_cell():
    cell_map[source.cell_index()] = chip.create_cell(prefix + source.name)
for source in macro.each_cell():
    destination = cell_map[source.cell_index()]
    for layer_index in range(macro.layers()):
        target_layer = chip.layer(macro.get_info(layer_index))
        for shape in source.shapes(layer_index).each():
            destination.shapes(target_layer).insert(shape)
    for instance in source.each_inst():
        destination.insert(pya.CellInstArray(
            cell_map[instance.cell_index].cell_index(), instance.cplx_trans))

top = chip.cell("SSCS_2026_01") or chip.top_cell()
replacement = chip.cell(prefix + macro_top_name)
old = [inst for inst in top.each_inst() if inst.cell.name == "A40_trouper_top"]
assert len(old) == 1 and replacement is not None, (len(old), replacement)

old_inst = old[0]
old_trans = old_inst.trans
new_trans = pya.ICplxTrans(0.2, old_trans.angle, old_trans.is_mirror(), old_trans.disp)
old_inst.delete()
top.insert(pya.CellInstArray(replacement.cell_index(), new_trans))

chip.write(output_gds)
print("wrote", output_gds, "chip_dbu", chip.dbu,
      "replacement magnification", new_trans.mag, "origin", new_trans.disp.to_s())
