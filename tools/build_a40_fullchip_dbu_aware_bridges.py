"""Add review-only A40 PDN bridges directly to the original 5 nm-DBU chip GDS.

This intentionally does not import or replace the A40 cell: all existing GDS
hierarchy remains unchanged.  Coordinates are the physically verified bridge
locations expressed in SSCS_2026_01's native 0.005 um database unit.
"""
import pya

chip_gds = globals()["chip_gds"]
output_gds = globals()["output_gds"]

L = {"m2": 36, "via2": 38, "m3": 42, "via3": 40,
     "m4": 46, "via4": 41, "m5": 81}


def via_array(cut, lower, upper, x, y, columns, rows, orientation):
    # 0.26 um cuts, 0.62 um pitch, Via*_GEN enclosure.  All values in 5 nm DBU.
    half, pitch = 26, 124
    for col in range(columns):
        for row in range(rows):
            cx = x + (2 * col - columns + 1) * pitch // 2
            cy = y + (2 * row - rows + 1) * pitch // 2
            top.shapes(layout.layer(cut, 0)).insert(
                pya.Box(cx - half, cy - half, cx + half, cy + half))
    outer_x = (columns - 1) * pitch // 2 + half
    outer_y = (rows - 1) * pitch // 2 + half
    enclosure_x, enclosure_y = (12, 2) if orientation == "HH" else (2, 12)
    for layer in (lower, upper):
        top.shapes(layout.layer(layer, 0)).insert(
            pya.Box(x - outer_x - enclosure_x, y - outer_y - enclosure_y,
                    x + outer_x + enclosure_x, y + outer_y + enclosure_y))


layout = pya.Layout()
layout.read(chip_gds)
assert abs(layout.dbu - 0.005) < 1e-12, layout.dbu
top = layout.cell("SSCS_2026_01") or layout.top_cell()
assert top is not None

# Six north-facing A40 VDD fingers.  These are the A40 M2 terminals at the
# actual macro location, not the earlier DBU-mismatched trial coordinates.
vdd = [(336272, 338172), (338752, 340802), (341122, 343172),
       (343828, 345878), (346198, 348248), (348828, 350728)]
for left, right in vdd:
    x = (left + right) // 2
    top.shapes(layout.layer(L["m2"], 0)).insert(pya.Box(left, 514000, right, 517200))
    via_array(L["via2"], L["m2"], L["m3"], x, 514636, 12, 8, "HH")
    via_array(L["via3"], L["m3"], L["m4"], x, 514636, 12, 8, "HH")
    via_array(L["via4"], L["m4"], L["m5"], x, 514636, 12, 8, "HH")

# Six west-facing A40 VSS fingers.
vss = [(296272, 298172), (298752, 300802), (301122, 303172),
       (303828, 305878), (306198, 308248), (308828, 310728)]
for bottom, upper in vss:
    y = (bottom + upper) // 2
    top.shapes(layout.layer(L["m2"], 0)).insert(pya.Box(69800, bottom, 71400, upper))
    via_array(L["via2"], L["m2"], L["m3"], 70724, y, 8, 12, "VV")
    via_array(L["via3"], L["m3"], L["m4"], 70724, y, 8, 12, "VV")

layout.write(output_gds)
print("wrote", output_gds, "dbu", layout.dbu, "top", top.name,
      "direct M2 shapes", top.shapes(layout.layer(L["m2"], 0)).size(),
      "with 12 A40 PDN bridges")
