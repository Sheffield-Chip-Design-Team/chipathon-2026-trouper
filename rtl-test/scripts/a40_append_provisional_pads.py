#!/usr/bin/env python3
"""SUPERSEDED 2026-09-03 by rtl-test/scripts/regen_a40_def.sh.

The integrator padframe tooling (ip/chipathon-2026-padring-system) now
generates the full 27-pin A40_ACV.def directly, with real coordinates for
ARRAY_ACQ_N (N15) and DBG0 (N16) -- there is nothing left to append. Kept only
as the record of how the synthetic-coordinate stopgap worked.

Append provisional boundary pins for pads the integrator template predates.

FP_DEF_TEMPLATE matching is strict: every top-level port must exist in the
template DEF, or OpenROAD fails with "must exist in template".  Trouper has
since grown two pads the integrator's A40_ACV.def does not contain --
ARRAY_ACQ_N (slot N15) and DBG0_OUT (N16) -- so a P&R run against the stock
template cannot even start.  (DBG1 was merged onto the IRQ_OUT pad on
2026-09-03 to hold the count at 27; it is no longer a pad of its own.)

This script appends them at synthetic north-edge coordinates so the flow can
run and produce real timing/DRC/LVS numbers for the new RTL.  It follows the
precedent already set for the Grouper bus, which config_a40_fpdef.json's own
comment records as "appended on the south edge at synthetic coords since the
integrator template has no Grouper pins".

WHAT THIS IS NOT
----------------
These coordinates are ours, not the integrator's.  They are placed in unused
edge space past VDD and are geometrically plausible -- same layer, same y band,
same 76 DBU pin width, same intra-pad pitch as the existing bi_t clusters -- but
the integrator owns the real slot assignment.  Open Risks #52 tracks that: N15,
N16 and N17 are unconfirmed, and nothing here confirms them.  Treat results from
this template as "the design routes and closes with three more pads on the north
edge", not as a signoff pinout.  Regenerate from the integrator DEF and re-run
before tapeout.

Usage:
    a40_append_provisional_pads.py [in.def] [out.def]
"""

import re
import sys

DEFAULT_IN = "rtl-test/ol_trouper_top/A40_ACV_rtlnames.def"
DEFAULT_OUT = "rtl-test/ol_trouper_top/A40_ACV_rtlnames_dbgpins.def"

# Geometry copied from the existing north-edge bi_t clusters (e.g. IRQ_OUT_*):
# Metal2, y band 221800..222000, pins 76 DBU wide.
LAYER = "Metal2"
Y0, Y1 = 221800, 222000
PIN_W = 76
TERM_PITCH = 1500          # intra-pad spacing; IRQ_OUT spans 13500 over 10 pins
PAD_PITCH = 14000          # cluster-to-cluster
FIRST_X = 282000           # first free x past VDD (which ends at 280728)
DIE_X = 335000

# Terminal order matches io_placement_a40.cfg for these pads.
TERMINALS = ["OUT", "PU", "PD", "OE", "IE", "CS", "SL", "PDRV0", "PDRV1", "IN"]

# (pad prefix, set of terminals that are chip INPUTS)
PADS = [
    ("ARRAY_ACQ_N", {"IN"}),
    ("DBG0",        {"IN"}),
]


def build_pin(name, direction, x):
    return (
        f"- {name} + NET {name} + DIRECTION {direction} + USE SIGNAL\n"
        f"  + LAYER {LAYER} ( {x} {Y0} ) ( {x + PIN_W} {Y1} )\n"
        f"  + FIXED ( 0 0 ) N ;\n"
    )


def main():
    src = sys.argv[1] if len(sys.argv) > 1 else DEFAULT_IN
    dst = sys.argv[2] if len(sys.argv) > 2 else DEFAULT_OUT

    txt = open(src).read()
    m = re.search(r"^PINS (\d+) ;$", txt, re.M)
    if not m:
        sys.exit(f"{src}: no PINS header found")
    count = int(m.group(1))

    existing = set(re.findall(r"^- (\S+) \+ NET", txt, re.M))

    new_pins = []
    added = []
    for pad_i, (pad, inputs) in enumerate(PADS):
        base_x = FIRST_X + pad_i * PAD_PITCH
        for term_i, term in enumerate(TERMINALS):
            name = f"{pad}_{term}"
            if name in existing:
                sys.exit(f"{name} already in template -- refusing to duplicate")
            x = base_x + term_i * TERM_PITCH
            if x + PIN_W > DIE_X:
                sys.exit(f"{name} at x={x} runs past the die edge {DIE_X}")
            direction = "INPUT" if term in inputs else "OUTPUT"
            new_pins.append(build_pin(name, direction, x))
            added.append(name)

    body = "".join(new_pins)
    txt = txt.replace(f"PINS {count} ;", f"PINS {count + len(added)} ;", 1)
    txt = txt.replace("END PINS", body + "END PINS", 1)

    open(dst, "w").write(txt)
    print(f"{src} -> {dst}")
    print(f"  pins {count} -> {count + len(added)} (+{len(added)})")
    for pad_i, (pad, _) in enumerate(PADS):
        base_x = FIRST_X + pad_i * PAD_PITCH
        last = base_x + (len(TERMINALS) - 1) * TERM_PITCH + PIN_W
        print(f"  {pad:12} x {base_x}..{last}  ({len(TERMINALS)} terminals)")
    print(f"  free edge remaining: {DIE_X - last} DBU")


if __name__ == "__main__":
    main()
