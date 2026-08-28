#!/usr/bin/env python3
"""Transform the A40 (ACV) integrator pin-template DEF into one Trouper's
FP_DEF_TEMPLATE flow can consume directly.

Input : the integrator bundle's A40/project_defs/ACV/A40_ACV.def
Output : rtl-test/ol_trouper_top/A40_ACV_rtlnames.def

Three edits:
  1. Rename 18 pins from the DEF's "<pad>_OUT/_IN/_OE" convention to Trouper
     RTL's port names (PSRAM_SIO_0_OUT -> PSRAM_SIO_OUT_0, REMOD_A_I_OUT ->
     REMOD_A_I, PSRAM_SCK_OUT -> PSRAM_SCK, PSRAM_CE_N_OUT -> PSRAM_CE_N,
     SPI_MISO_OUT -> SPI_MISO, IRQ_OUT_OUT -> IRQ_OUT).
  2. Keep the VDD / VSS boundary pin entries (USE POWER / USE GROUND, W12 / N14)
     so the LibreLane PDN ring terminates on the integrator's power-pad
     locations rather than being a self-contained grid. They have no matching
     trouper_top RTL port - they attach to the PDN's special VDD/VSS nets.
  3. Append the die-internal Grouper interface (GRP_* + AHB H* + IRQ_GROUPER,
     205-139+2 = 68 pins) on the south edge at synthetic coordinates. These are
     NOT part of the integrator flow (no pads, absent from info.yaml, never in
     A40_ACV.def) - they are placed only to satisfy FP_DEF_TEMPLATE's "every
     top-level port must be placed" rule. Their real placement is the
     Trouper<->Grouper abutment, agreed between those two projects.

DEF units are 200 dbu/um; die is 335000 x 222000 dbu = 1675 x 1110 um.

See planning/a40-padframe-integration-2026-08.md.
"""
import re
import sys

SRC = sys.argv[1] if len(sys.argv) > 1 else "tmp/.a40/A40/project_defs/ACV/A40_ACV.def"
OUT = sys.argv[2] if len(sys.argv) > 2 else "rtl-test/ol_trouper_top/A40_ACV_rtlnames.def"

ren = {}
for n in range(4):
    ren[f"PSRAM_SIO_{n}_OUT"] = f"PSRAM_SIO_OUT_{n}"
    ren[f"PSRAM_SIO_{n}_IN"] = f"PSRAM_SIO_IN_{n}"
    ren[f"PSRAM_SIO_{n}_OE"] = f"PSRAM_SIO_OE_{n}"
ren.update({
    "REMOD_A_I_OUT": "REMOD_A_I", "REMOD_A_Q_OUT": "REMOD_A_Q",
    "PSRAM_SCK_OUT": "PSRAM_SCK", "PSRAM_CE_N_OUT": "PSRAM_CE_N",
    "SPI_MISO_OUT": "SPI_MISO", "IRQ_OUT_OUT": "IRQ_OUT",
})

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
print(f"{OUT}: renamed {len(ren)}, kept VDD/VSS, +{len(south)} south -> {len(allpins)} pins")
