"""Review-only A40 trial: one native-width M2 finger extended to the M5 ring.

All six VDD north fingers and all six VSS west fingers are connected.  Each
keeps its native M2 width.  A generated VDD 12x8 Via2/Via3/Via4 array is
centred in the VDD M5 rail; an 8x12 Via2/Via3 array is centred in the VSS M4
rail.  Both arrays follow the GF180 technology LEF's Via*_GEN enclosure and
cut-pitch rules.  The macro's M4/M5 ring is unmodified.
"""
import re
import pya

chip_gds = globals()["chip_gds"]
macro_gds = globals()["macro_gds"]
output_gds = globals()["output_gds"]
techlef = globals()["techlef"]
prefix = "A40_RING5396_FINGER__"


def via_rectangles(name, x, y):
    text = open(techlef, encoding="utf-8").read()
    match = re.search(r"(?ms)^\s*VIA\s+" + re.escape(name) + r"\b.*?^\s*END\s+"
                      + re.escape(name) + r"\s*$", text)
    assert match, name
    layers = {"Metal2": 36, "Via2": 38, "Metal3": 42,
              "Via3": 40, "Metal4": 46, "Via4": 41, "Metal5": 81}
    current = None
    for line in match.group(0).splitlines():
        layer = re.match(r"\s*LAYER\s+(\S+)\s*;", line)
        if layer:
            current = layer.group(1)
        rect = re.match(r"\s*RECT\s+([-0-9.]+)\s+([-0-9.]+)\s+([-0-9.]+)\s+([-0-9.]+)\s*;", line)
        if rect:
            assert current in layers, current
            a, b, c, d = [round(float(v) * 1000) for v in rect.groups()]
            yield layers[current], pya.Box(x + a, y + b, x + c, y + d)


def generated_via_array(cut_layer, lower_layer, upper_layer, x, y, columns, rows,
                        orientation):
    """Emit one PDK Via*_GEN array (HH for VDD, VV for VSS)."""
    # The PDK's DEFAULT 4x4 array verifies this generated-rule pitch: 0.62um.
    # Via*_GEN_HH supplies 0.26um cuts and 0.06um x / 0.01um y enclosure.
    cut_half, pitch_x, pitch_y = 130, 620, 620
    for col in range(columns):
        for row in range(rows):
            cx = x + (2 * col - columns + 1) * pitch_x // 2
            cy = y + (2 * row - rows + 1) * pitch_y // 2
            top.shapes(chip.layer(cut_layer, 0)).insert(
                pya.Box(cx - cut_half, cy - cut_half, cx + cut_half, cy + cut_half))
    outer_x = (columns - 1) * pitch_x // 2 + cut_half
    outer_y = (rows - 1) * pitch_y // 2 + cut_half
    enclosure_x, enclosure_y = (60, 10) if orientation == "HH" else (10, 60)
    for layer in (lower_layer, upper_layer):
        top.shapes(chip.layer(layer, 0)).insert(
            pya.Box(x - outer_x - enclosure_x, y - outer_y - enclosure_y,
                    x + outer_x + enclosure_x, y + outer_y + enclosure_y))


macro = pya.Layout()
macro.read(macro_gds)
macro_top_name = macro.top_cell().name
for cell in macro.each_cell():
    cell.name = prefix + cell.name
renamed = "/tmp/a40_ring5396_finger_renamed.gds"
macro.write(renamed)

chip = pya.Layout()
chip.read(chip_gds)
chip.read(renamed)
top = chip.cell("SSCS_2026_01")
replacement = chip.cell(prefix + macro_top_name)
old = [i for i in top.each_inst() if i.cell.name == "A40_trouper_top"]
assert top and replacement and len(old) == 1
trans = old[0].trans
old[0].delete()
top.insert(pya.CellInstArray(replacement.cell_index(), trans))

# VDD north: extend every native-width M2 finger down through the unchanged
# M5 VDD rail (y=2570.680..2575.680 um), and centre a corner-sized 12x8 stack.
vdd_fingers = [(1681360, 1690860), (1693760, 1704010),
               (1705610, 1715860), (1719140, 1729390),
               (1730990, 1741240), (1744140, 1753640)]
for left, right in vdd_fingers:
    via_x, via_y = (left + right) // 2, 2573180
    top.shapes(chip.layer(36, 0)).insert(pya.Box(left, 2570000, right, 2586000))
    generated_via_array(38, 36, 42, via_x, via_y, 12, 8, "HH")
    generated_via_array(40, 42, 46, via_x, via_y, 12, 8, "HH")
    generated_via_array(41, 46, 81, via_x, via_y, 12, 8, "HH")

# VSS west: extend each native-height M2 finger through the unchanged M4 VSS
# rail (x=351.120..356.120 um).  Rotate the same corner-sized connection to
# 8x12 so its 4.62 um dimension is across the ring width.
vss_fingers = [(1481360, 1490860), (1493760, 1504010),
               (1505610, 1515860), (1519140, 1529390),
               (1530990, 1541240), (1544140, 1553640)]
for bottom, top_y in vss_fingers:
    via_x, via_y = 353620, (bottom + top_y) // 2
    top.shapes(chip.layer(36, 0)).insert(pya.Box(349000, bottom, 357000, top_y))
    generated_via_array(38, 36, 42, via_x, via_y, 8, 12, "VV")
    generated_via_array(40, 42, 46, via_x, via_y, 8, 12, "VV")

chip.write(output_gds)
print("wrote", output_gds, "with six VDD and six VSS M2 extensions and PDK via arrays")
