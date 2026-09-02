#!/usr/bin/env python3
"""Transform the A40 (ACV) integrator pin-template DEF into one Trouper's
FP_DEF_TEMPLATE flow can consume directly.

Input : the integrator bundle's A40/project_defs/ACV/A40_ACV.def
Output : rtl-test/ol_trouper_top/A40_ACV_rtlnames.def

Two edits (as of the 2026-08-28 RTL rename, commit renaming the 18 functional
ports in src/top/trouper_top.v to the generator's <pad>_<terminal> convention,
the DEF names now match trouper_top verbatim - no rename step needed):
  1. Keep the VDD / VSS boundary pin entries (USE POWER / USE GROUND, W12 / N14)
     so the file matches the integrator artifact. NOTE: with the default config
     these are INERT - FP_DEF_TEMPLATE matching filters POWER/GROUND sigtype
     bterms, and FP_TEMPLATE_COPY_POWER_PINS defaults False, so their
     coordinates are never copied; the LibreLane PDN builds its own VDD/VSS
     ring regardless (jobs 5150 == 5153). To honour them, set
     FP_TEMPLATE_COPY_POWER_PINS: true and reconcile pdn_cfg.tcl.
  2. (Removed 2026-09-01.) This step used to append the die-internal Grouper
     interface (GRP_* + AHB H* + IRQ_GROUPER, 68 pins) on the south edge at
     synthetic coordinates, purely to satisfy FP_DEF_TEMPLATE's "every
     top-level port must be placed" rule. Grouper is not taping out and those
     ports no longer exist on trouper_top, so nothing is appended: the output
     is now the integrator template's own pin set, unmodified.

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

allpins = kept
newbody = [f"PINS {len(allpins)} ;"]
for ent in allpins:
    newbody += ent
open(OUT, "w").write("\n".join(pre + newbody + post))
print(f"{OUT}: renames {len(ren)} (RTL matches), kept VDD/VSS -> {len(allpins)} pins")
