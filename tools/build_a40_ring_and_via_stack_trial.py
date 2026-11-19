"""Review-only A40 full-chip trial with legal GF180 Via2/3/4 power stacks.

This imports the job-5396 macro into a copy of the full chip, then creates
six VDD towers from N14 Metal2 fingers to the VDD Metal5 ring and six VSS
towers from W12 Metal2 fingers to the VSS Metal4 ring.  Via cut geometry is
taken exactly from the GF180 technology LEF's 4x4 default via definitions.
"""
import pya

chip_gds = globals()["chip_gds"]
macro_gds = globals()["macro_gds"]
output_gds = globals()["output_gds"]
prefix = "A40_RING5396_STACK__"

macro = pya.Layout()
macro.read(macro_gds)
macro_top_name = macro.top_cell().name
for cell in macro.each_cell():
    cell.name = prefix + cell.name
renamed_macro_gds = "/tmp/a40_ring5396_stack_renamed.gds"
macro.write(renamed_macro_gds)

chip = pya.Layout()
chip.read(chip_gds)
chip.read(renamed_macro_gds)
top = chip.cell("SSCS_2026_01")
new_macro = chip.cell(prefix + macro_top_name)
assert top and new_macro
old = [inst for inst in top.each_inst() if inst.cell.name == "A40_trouper_top"]
assert len(old) == 1
old_trans = old[0].trans
old[0].delete()
top.insert(pya.CellInstArray(new_macro.cell_index(), old_trans))

m2, v2, m3, v3, m4, v4, m5 = [chip.layer(layer, 0) for layer in
                                 (36, 38, 42, 40, 46, 41, 81)]

def box(layer, left, bottom, right, top_y):
    top.shapes(layer).insert(pya.Box(left, bottom, right, top_y))

def via4x4(layer, x, y):
    # GF180 Via{2,3,4}_4X4H_*_DEFAULT: sixteen 0.26 um cuts on 0.62 um pitch.
    for dx in (-1060, -440, 180, 800):
        for dy in (-1060, -440, 180, 800):
            box(layer, x + dx, y + dy, x + dx + 260, y + dy + 260)

def vdd_stack(x):
    # N14 pad M2 begins at y=2585 um.  VDD's M5 ring centre is y=2573.18 um.
    # The 3 um landing bars are wider than each 4x4 via enclosure (2.24 um).
    for layer in (m2, m3, m4):
        box(layer, x - 1500, 2573180, x + 1500, 2586000)
    via4x4(v2, x, 2573180)
    via4x4(v3, x, 2573180)
    via4x4(v4, x, 2573180)

def vss_stack(y):
    # W12 pad M2 ends at x=350 um.  VSS's M4 ring centre is x=353.62 um.
    for layer in (m2, m3, m4):
        box(layer, 349000, y - 1500, 353620, y + 1500)
    via4x4(v2, 353620, y)
    via4x4(v3, 353620, y)

# Centres of the six A40 VDD north-edge and VSS west-edge pin fingers.
for left, right in [(1681360, 1690860), (1693760, 1704010),
                    (1705610, 1715860), (1719140, 1729390),
                    (1730990, 1741240), (1744140, 1753640)]:
    vdd_stack((left + right) // 2)
for bottom, top_y in [(1481360, 1490860), (1493760, 1504010),
                      (1505610, 1515860), (1519140, 1529390),
                      (1530990, 1541240), (1544140, 1553640)]:
    vss_stack((bottom + top_y) // 2)

chip.write(output_gds)
print("wrote", output_gds, "with six VDD M2-to-M5 and six VSS M2-to-M4 stacks")
