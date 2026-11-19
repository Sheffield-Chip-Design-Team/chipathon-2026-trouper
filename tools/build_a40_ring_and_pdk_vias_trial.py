"""Review-only A40 full-chip trial using GF180 technology-LEF via shapes.

The PDK's DEFAULT Via2/Via3/Via4 definitions are parsed directly from the
technology LEF.  This deliberately avoids manually recreating a via array or
its metal enclosures.  A single wide bridge per supply gives the PDK via stack
ample enclosure and avoids the dense six-tower pattern from the rejected
trial.  It writes only ``output_gds``; the integration GDS is never changed.
"""
import re
import pya

chip_gds = globals()["chip_gds"]
macro_gds = globals()["macro_gds"]
output_gds = globals()["output_gds"]
techlef = globals()["techlef"]
prefix = "A40_RING5396_PDKVIA__"


def pdk_via_shapes(via_name, x, y):
    """Return every technology-LEF rectangle in a named DEFAULT via."""
    text = open(techlef, encoding="utf-8").read()
    match = re.search(r"(?ms)^\s*VIA\s+" + re.escape(via_name)
                      + r"\b.*?^\s*END\s+" + re.escape(via_name) + r"\s*$",
                      text)
    assert match, "via not found in technology LEF: " + via_name
    layer_map = {"Metal2": 36, "Via2": 38, "Metal3": 42,
                 "Via3": 40, "Metal4": 46, "Via4": 41, "Metal5": 81}
    current_layer = None
    result = []
    for line in match.group(0).splitlines():
        layer = re.match(r"\s*LAYER\s+(\S+)\s*;", line)
        if layer:
            current_layer = layer.group(1)
            continue
        rect = re.match(r"\s*RECT\s+([-0-9.]+)\s+([-0-9.]+)\s+([-0-9.]+)\s+([-0-9.]+)\s*;", line)
        if rect:
            assert current_layer in layer_map, current_layer
            coords = [round(float(v) * 1000) for v in rect.groups()]
            result.append((layer_map[current_layer],
                           pya.Box(x + coords[0], y + coords[1],
                                   x + coords[2], y + coords[3])))
    assert result, via_name
    return result


macro = pya.Layout()
macro.read(macro_gds)
macro_top_name = macro.top_cell().name
for cell in macro.each_cell():
    cell.name = prefix + cell.name
renamed_macro_gds = "/tmp/a40_ring5396_pdkvia_renamed.gds"
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


def add_box(gds_layer, left, bottom, right, top_y):
    top.shapes(chip.layer(gds_layer, 0)).insert(pya.Box(left, bottom, right, top_y))


def add_pdk_via(via_name, x, y):
    for gds_layer, shape in pdk_via_shapes(via_name, x, y):
        top.shapes(chip.layer(gds_layer, 0)).insert(shape)


# VDD: one 3 um-wide M2/M3/M4 bridge from the N14 pad and A40 north M2
# fingers to the existing VDD M5 ring.  The Via4 centre is deliberately
# 1.62 um inside the M5 rail and all PDK enclosure rectangles sit inside the
# 3 um landing bar.
vdd_x, vdd_via_y = 1717500, 2574800
for layer in (36, 42, 46):
    add_box(layer, vdd_x - 1500, 2573200, vdd_x + 1500, 2586000)
for via in ("Via2_4X4H_HH_DEFAULT", "Via3_4X4H_HH_DEFAULT",
            "Via4_4X4H_HH_DEFAULT"):
    add_pdk_via(via, vdd_x, vdd_via_y)

# VSS: the W12 pad and A40 west M2 fingers are joined by a 3 um-wide bridge;
# its generated Via2/Via3 stack lands fully within the existing VSS M4 rail.
vss_via_x, vss_y = 354800, 1517500
for layer in (36, 42, 46):
    add_box(layer, 349000, vss_y - 1500, 356500, vss_y + 1500)
for via in ("Via2_4X4H_HH_DEFAULT", "Via3_4X4H_HH_DEFAULT"):
    add_pdk_via(via, vss_via_x, vss_y)

chip.write(output_gds)
print("wrote", output_gds, "with PDK-LEF generated VDD and VSS via stacks")
