"""Verify the explicit layer-by-layer continuity of A40's added PDN bridges."""
import json
import pya

baseline_gds = globals()["baseline_gds"]
trial_gds = globals()["trial_gds"]
report_json = globals()["report_json"]

L = {"m2": 36, "via2": 38, "m3": 42, "via3": 40,
     "m4": 46, "via4": 41, "m5": 81}


def load(path):
    ly = pya.Layout(); ly.read(path)
    assert abs(ly.dbu - .001) < 1e-12, ly.dbu
    return ly, (ly.cell("trouper_top") or ly.top_cell())


def region(ly, top, layer):
    out = pya.Region()
    it = top.begin_shapes_rec(ly.layer(layer, 0))
    while not it.at_end():
        if it.shape().is_box() or it.shape().is_polygon() or it.shape().is_path():
            out.insert(it.shape().polygon.transformed(it.trans()))
        it.next()
    return out.merged()


def touches(r, box):
    return not r.interacting(pya.Region(box)).is_empty()


base, base_top = load(baseline_gds)
trial, top = load(trial_gds)
base_m2 = region(base, base_top, L["m2"])
g = {name: region(trial, top, number) for name, number in L.items()}
checks, failures = [], []


def check(name, condition):
    checks.append({"name": name, "pass": bool(condition)})
    if not condition:
        failures.append(name)


vdd = [(631360, 640860), (643760, 654010), (655610, 665860),
       (669140, 679390), (680990, 691240), (694140, 703640)]
for n, (left, right) in enumerate(vdd, 1):
    x = (left + right) // 2
    # Existing M2 must meet the new finger just inside A40's north boundary.
    check("VDD%d native-M2-to-finger" % n,
          touches(base_m2, pya.Box(left + 100, 1095000, right - 100, 1095680)))
    for name in ("m2", "via2", "m3", "via3", "m4", "via4", "m5"):
        check("VDD%d %s at stack" % (n, name),
              touches(g[name], pya.Box(x - 4000, 1095000, x + 4000, 1102000)))
    check("VDD%d M5-ring landing" % n,
          touches(g["m5"], pya.Box(left, 1095680, right, 1100680)))

vss = [(6360, 15860), (18760, 29010), (30610, 40860),
       (44140, 54390), (55990, 66240), (69140, 78640)]
for n, (bottom, top_y) in enumerate(vss, 1):
    y = (bottom + top_y) // 2
    check("VSS%d native-M2-to-finger" % n,
          touches(base_m2, pya.Box(0, bottom + 100, 6120, top_y - 100)))
    for name in ("m2", "via2", "m3", "via3", "m4"):
        check("VSS%d %s at stack" % (n, name),
              touches(g[name], pya.Box(-1000, y - 4000, 8000, y + 4000)))
    check("VSS%d M4-ring landing" % n,
          touches(g["m4"], pya.Box(1120, bottom, 6120, top_y)))

result = {"pass": not failures, "checks": checks, "failures": failures,
          "baseline_gds": baseline_gds, "trial_gds": trial_gds}
open(report_json, "w").write(json.dumps(result, indent=2) + "\n")
print(json.dumps({"pass": result["pass"], "checks": len(checks),
                  "failures": failures}, indent=2))
if failures:
    raise SystemExit(1)
