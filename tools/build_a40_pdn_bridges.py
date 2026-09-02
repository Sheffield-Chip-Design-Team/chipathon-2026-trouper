"""Insert A40's 12 PDN bridge stacks into the LibreLane trouper_top GDS.

This produced the shipped final/gds/trouper_top.gds: it is the one step applied
on top of the flow streamout, so the other views and reports under final/
describe the base run, not this output.

It operates only on the LibreLane-produced GDS (dbu = 0.001 um) and adds
geometry -- no cell is imported or replaced -- so every standard-cell and macro
coordinate is preserved exactly.  Six VDD bridges climb M2 -> M5 at the north
edge and six VSS bridges climb M2 -> M4 at the west edge, meeting A40's M2
landings.  The coordinates below are the full-chip bridge locations translated
by A40's physical origin (350, 1475) um.

Run under KLayout, which supplies `pya` and the two globals:

    klayout -b -r tools/build_a40_pdn_bridges.py \
            -rd macro_gds=<flow streamout>.gds \
            -rd output_gds=final/gds/trouper_top.gds
"""
import pya

macro_gds = globals()["macro_gds"]
output_gds = globals()["output_gds"]

layers = {"m2": 36, "via2": 38, "m3": 42, "via3": 40,
          "m4": 46, "via4": 41, "m5": 81}


def generated_via_array(top, cut_layer, lower_layer, upper_layer, x, y,
                        columns, rows, orientation):
    """Emit the generated GF180 Via*_GEN geometry in native 1 nm units."""
    cut_half = 130
    pitch = 620
    for col in range(columns):
        for row in range(rows):
            cx = x + (2 * col - columns + 1) * pitch // 2
            cy = y + (2 * row - rows + 1) * pitch // 2
            top.shapes(layout.layer(cut_layer, 0)).insert(
                pya.Box(cx - cut_half, cy - cut_half, cx + cut_half, cy + cut_half))
    outer_x = (columns - 1) * pitch // 2 + cut_half
    outer_y = (rows - 1) * pitch // 2 + cut_half
    enclosure_x, enclosure_y = (60, 10) if orientation == "HH" else (10, 60)
    for layer in (lower_layer, upper_layer):
        top.shapes(layout.layer(layer, 0)).insert(
            pya.Box(x - outer_x - enclosure_x, y - outer_y - enclosure_y,
                    x + outer_x + enclosure_x, y + outer_y + enclosure_y))


layout = pya.Layout()
layout.read(macro_gds)
assert abs(layout.dbu - 0.001) < 1e-12, layout.dbu
top = layout.cell("trouper_top") or layout.top_cell()
assert top is not None

vdd_fingers = [(1331360, 1340860), (1343760, 1354010),
               (1355610, 1365860), (1369140, 1379390),
               (1380990, 1391240), (1394140, 1403640)]
for left, right in vdd_fingers:
    via_x, via_y = (left + right) // 2, 1098180
    top.shapes(layout.layer(layers["m2"], 0)).insert(
        pya.Box(left, 1095000, right, 1111000))
    generated_via_array(top, layers["via2"], layers["m2"], layers["m3"],
                        via_x, via_y, 12, 8, "HH")
    generated_via_array(top, layers["via3"], layers["m3"], layers["m4"],
                        via_x, via_y, 12, 8, "HH")
    generated_via_array(top, layers["via4"], layers["m4"], layers["m5"],
                        via_x, via_y, 12, 8, "HH")

vss_fingers = [(6360, 15860), (18760, 29010), (30610, 40860),
               (44140, 54390), (55990, 66240), (69140, 78640)]
for bottom, top_y in vss_fingers:
    via_x, via_y = 3620, (bottom + top_y) // 2
    top.shapes(layout.layer(layers["m2"], 0)).insert(
        pya.Box(-1000, bottom, 7000, top_y))
    generated_via_array(top, layers["via2"], layers["m2"], layers["m3"],
                        via_x, via_y, 8, 12, "VV")
    generated_via_array(top, layers["via3"], layers["m3"], layers["m4"],
                        via_x, via_y, 8, 12, "VV")

layout.write(output_gds)
print("wrote", output_gds, "dbu", layout.dbu, "with 6 VDD and 6 VSS bridges")
