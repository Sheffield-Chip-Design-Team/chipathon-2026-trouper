"""Fast, hierarchy-aware check of the 12 A40 bridges in the full-chip GDS."""
import json
import pya

baseline_gds = globals()["baseline_gds"]
trial_gds = globals()["trial_gds"]
report_json = globals()["report_json"]
L = {"m2": 36, "via2": 38, "m3": 42, "via3": 40,
     "m4": 46, "via4": 41, "m5": 81}


def load(path):
    ly = pya.Layout(); ly.read(path)
    assert abs(ly.dbu - .005) < 1e-12, ly.dbu
    return ly, ly.cell("SSCS_2026_01") or ly.top_cell()


def has(ly, top, layer, box):
    """Return on first recursive shape whose transformed bbox meets box."""
    it = top.begin_shapes_rec_touching(ly.layer(layer, 0), box)
    while not it.at_end():
        if it.shape().bbox().transformed(it.trans()).overlaps(box):
            return True
        it.next()
    return False


base, btop = load(baseline_gds)
trial, ttop = load(trial_gds)
checks, failures = [], []


def check(name, value):
    checks.append({"name": name, "pass": bool(value)})
    if not value: failures.append(name)


vdd = [(336272, 338172), (338752, 340802), (341122, 343172),
       (343828, 345878), (346198, 348248), (348828, 350728)]
for i, (left, right) in enumerate(vdd, 1):
    x = (left + right) // 2
    check("VDD%d baseline macro M2" % i,
          has(base, btop, L["m2"], pya.Box(left + 20, 516900, right - 20, 517100)))
    check("VDD%d baseline M5 ring" % i,
          has(base, btop, L["m5"], pya.Box(left, 514136, right, 515136)))
    for name in ("m2", "via2", "m3", "via3", "m4", "via4", "m5"):
        check("VDD%d %s stack" % (i, name),
              has(trial, ttop, L[name], pya.Box(x - 800, 514000, x + 800, 515300)))

vss = [(296272, 298172), (298752, 300802), (301122, 303172),
       (303828, 305878), (306198, 308248), (308828, 310728)]
for i, (bottom, upper) in enumerate(vss, 1):
    y = (bottom + upper) // 2
    check("VSS%d baseline macro M2" % i,
          has(base, btop, L["m2"], pya.Box(69800, bottom + 20, 70050, upper - 20)))
    check("VSS%d baseline M4 ring" % i,
          has(base, btop, L["m4"], pya.Box(70224, bottom, 71224, upper)))
    for name in ("m2", "via2", "m3", "via3", "m4"):
        check("VSS%d %s stack" % (i, name),
              has(trial, ttop, L[name], pya.Box(69800, y - 800, 71400, y + 800)))

result = {"pass": not failures, "checks": checks, "failures": failures,
          "baseline_gds": baseline_gds, "trial_gds": trial_gds}
open(report_json, "w").write(json.dumps(result, indent=2) + "\n")
print(json.dumps({"pass": result["pass"], "checks": len(checks), "failures": failures}, indent=2))
if failures: raise SystemExit(1)
