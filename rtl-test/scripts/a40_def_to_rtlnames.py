#!/usr/bin/env python3
"""Transform the A40 (ACV) integrator pin-template DEF into one Trouper's
FP_DEF_TEMPLATE flow can consume directly.

Input : the integrator bundle's A40/project_defs/ACV/A40_ACV.def
Output : rtl-test/ol_trouper_top/A40_ACV_rtlnames.def

Two edits (as of the 2026-08-28 RTL rename, commit renaming the 18 functional
ports in src/top/trouper_top.v to the generator's <pad>_<terminal> convention,
the DEF names now match trouper_top verbatim - no rename step needed):
  1. Keep the VDD / VSS boundary pin entries (USE POWER / USE GROUND, W12 / N14)
     so the LibreLane PDN ring terminates on the integrator's power-pad
     locations rather than being a self-contained grid. They have no matching
     trouper_top RTL port - they attach to the PDN's special VDD/VSS nets.
  2. Append the die-internal Grouper interface (GRP_* + AHB H* + IRQ_GROUPER,
     68 pins) on the south edge at synthetic coordinates. These are NOT part of
     the integrator flow (no pads, absent from info.yaml, never in A40_ACV.def) -
     they are placed only to satisfy FP_DEF_TEMPLATE's "every top-level port must
     be placed" rule. Their real placement is the Trouper<->Grouper abutment,
     agreed between those two projects.

DEF units are 200 dbu/um; die is 335000 x 222000 dbu = 1675 x 1110 um.

See planning/a40-padframe-integration-2026-08.md.
"""
import re
import sys

SRC = sys.argv[1] if len(sys.argv) > 1 else "tmp/.a40/A40/project_defs/ACV/A40_ACV.def"
OUT = sys.argv[2] if len(sys.argv) > 2 else "rtl-test/ol_trouper_top/A40_ACV_rtlnames.def"

ren = {}  # RTL now matches the DEF's <pad>_<terminal> names - no renames.

lines = open(SRC).read().split("\n")
h = next(i for i, l in enumerate(lines) if re.match(r"^PINS \d+ ;", l))
e = next(i for i in range(h + 1, len(lines)) if lines[i].strip() == "END PINS")
pre, body, post = lines[:h], lines[h + 1:e], lines[e:]

entries, cur = [], []
for l in body:
    if l.startswith("- "):
        if cur:
            entries.append(cur)
        cur = [l]
    else:
        cur.append(l)
if cur:
    entries.append(cur)

kept = []
for ent in entries:
    name = ent[0].split()[1]
    # VDD / VSS kept as-is: USE POWER / USE GROUND boundary pins for the PDN.
    if name in ren:
        new = ren[name]
        ent = [re.sub(r"(^- |\+ NET )" + re.escape(name) + r"\b",
                      lambda m: m.group(1) + new, ln) for ln in ent]
    kept.append(ent)

DIEW = 335000
grp = ([f"GRP_ADDR_{i}" for i in range(8)] + [f"GRP_WDATA_{i}" for i in range(8)] +
       [f"GRP_RDATA_{i}" for i in range(8)] + ["GRP_WE", "GRP_RE", "GRP_READY", "IRQ_GROUPER"])
ahb = []
for b, w in [("HADDR", 8), ("HWDATA", 8), ("HRDATA", 8), ("HBURST", 3),
             ("HPROT", 4), ("HSIZE", 3), ("HTRANS", 2)]:
    ahb += [f"{b}[{i}]" for i in range(w)]
ahb += ["HMASTLOCK", "HWRITE", "HREADY", "HRESP"]
extra = grp + ahb

inp = set(grp[:16] + ["GRP_WE", "GRP_RE"] +
          [f"HADDR[{i}]" for i in range(8)] + [f"HWDATA[{i}]" for i in range(8)] +
          [f"HBURST[{i}]" for i in range(3)] + [f"HPROT[{i}]" for i in range(4)] +
          [f"HSIZE[{i}]" for i in range(3)] + [f"HTRANS[{i}]" for i in range(2)] +
          ["HMASTLOCK", "HWRITE"])

south = []
step = DIEW // (len(extra) + 1)
for k, nm in enumerate(extra):
    x = step * (k + 1)
    d = "INPUT" if nm in inp else "OUTPUT"
    south.append([f"- {nm} + NET {nm} + DIRECTION {d} + USE SIGNAL",
                  f"  + LAYER Metal2 ( {x} 0 ) ( {x + 200} 200 )",
                  f"  + FIXED ( 0 0 ) N ;"])

allpins = kept + south
newbody = [f"PINS {len(allpins)} ;"]
for ent in allpins:
    newbody += ent
open(OUT, "w").write("\n".join(pre + newbody + post))
print(f"{OUT}: renames {len(ren)} (RTL matches), kept VDD/VSS, +{len(south)} south -> {len(allpins)} pins")
