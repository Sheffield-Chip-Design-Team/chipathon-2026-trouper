#!/usr/bin/env python3
"""
Extract a curated subset of FD standard cells from the GF180MCU fd_sc_mcu7t5v0
Liberty files and write a filtered library for use alongside gf180mcu_as_sc_mcu7t3v3.

These "gap" cells cover logic functions absent from the AS library. Only the listed
cells are included so Yosys does not fall back to FD cells for logic AS can handle.

Usage (inside chipathon26 container):
    python3 extract_gap_cells.py <out_dir>
"""

import sys, re, os

# Gap cells: functions missing from gf180mcu_as_sc_mcu7t3v3
GAP_CELLS = {
    # OAI gates — biggest synthesis quality gain
    "gf180mcu_fd_sc_mcu7t5v0__oai21_1",
    "gf180mcu_fd_sc_mcu7t5v0__oai22_1",
    "gf180mcu_fd_sc_mcu7t5v0__oai31_1",
    "gf180mcu_fd_sc_mcu7t5v0__oai32_1",
    "gf180mcu_fd_sc_mcu7t5v0__oai33_1",
    "gf180mcu_fd_sc_mcu7t5v0__oai221_1",
    # AOI gates
    "gf180mcu_fd_sc_mcu7t5v0__aoi221_1",
    "gf180mcu_fd_sc_mcu7t5v0__aoi222_1",
    # Wide AND/OR
    "gf180mcu_fd_sc_mcu7t5v0__and3_1",
    "gf180mcu_fd_sc_mcu7t5v0__and4_1",
    "gf180mcu_fd_sc_mcu7t5v0__or3_1",
    "gf180mcu_fd_sc_mcu7t5v0__or4_1",
    # Wide XOR
    "gf180mcu_fd_sc_mcu7t5v0__xor3_1",
    "gf180mcu_fd_sc_mcu7t5v0__xnor3_1",
    # Minimum drive strength (x1) — area optimisation
    "gf180mcu_fd_sc_mcu7t5v0__buf_1",
    "gf180mcu_fd_sc_mcu7t5v0__inv_1",
    "gf180mcu_fd_sc_mcu7t5v0__nand2_1",
    "gf180mcu_fd_sc_mcu7t5v0__nor2_1",
    # CTS root buffer — use in CTS_ROOT_BUFFER only, excluded from synthesis
    "gf180mcu_fd_sc_mcu7t5v0__clkbuf_16",
}

FD_LIB_DIR = "/foss/pdks/gf180mcuD/libs.ref/gf180mcu_fd_sc_mcu7t5v0/lib"
CORNERS = [
    ("tt_025C_3v30", "nom_tt_025C_3v30"),
    ("ss_125C_3v00", "max_ss_125C_3v00"),
    ("ff_n40C_3v60", "max_ff_n40C_3v60"),
]


def extract_cells(lib_text):
    """Return dict of {cell_name: cell_block_text} for all cells in a Liberty file."""
    cells = {}
    i = 0
    n = len(lib_text)
    cell_re = re.compile(r'\bcell\s*\(\s*([\w]+)\s*\)\s*\{')

    while i < n:
        m = cell_re.search(lib_text, i)
        if not m:
            break
        cell_name = m.group(1)
        brace_start = m.end() - 1  # position of opening '{'
        # Walk forward counting braces to find the matching '}'
        depth = 0
        j = brace_start
        while j < n:
            if lib_text[j] == '{':
                depth += 1
            elif lib_text[j] == '}':
                depth -= 1
                if depth == 0:
                    break
            j += 1
        cells[cell_name] = lib_text[m.start():j + 1]
        i = j + 1

    return cells


def extract_header(lib_text):
    """Return the Liberty library header up to (but not including) the first cell block."""
    cell_re = re.compile(r'\bcell\s*\(\s*[\w]+\s*\)\s*\{')
    m = cell_re.search(lib_text)
    if not m:
        return lib_text
    return lib_text[:m.start()]


def process_corner(corner_suffix, out_dir):
    src = os.path.join(FD_LIB_DIR, f"gf180mcu_fd_sc_mcu7t5v0__{corner_suffix}.lib")
    if not os.path.exists(src):
        print(f"  WARNING: {src} not found, skipping")
        return

    print(f"  Reading {src}")
    text = open(src).read()

    header = extract_header(text)
    # Rewrite library name to make it clearly a filtered subset
    header = header.replace(
        f"gf180mcu_fd_sc_mcu7t5v0__{corner_suffix}",
        f"gf180mcu_fd_gap__{corner_suffix}",
        1,
    )

    all_cells = extract_cells(text)
    found = []
    missing = []
    for cell in sorted(GAP_CELLS):
        short = cell.replace("gf180mcu_fd_sc_mcu7t5v0__", "")
        full  = f"gf180mcu_fd_sc_mcu7t5v0__{short}"
        if full in all_cells:
            found.append(full)
        else:
            missing.append(full)

    if missing:
        print(f"  WARNING: cells not found in lib: {missing}")

    # Build output
    out_lines = [header.rstrip()]
    for cell_name in sorted(found):
        out_lines.append("")
        out_lines.append(all_cells[cell_name])
    out_lines.append("")
    out_lines.append("}")  # close library

    out_path = os.path.join(out_dir, f"gf180mcu_fd_gap__{corner_suffix}.lib")
    with open(out_path, "w") as f:
        f.write("\n".join(out_lines))
    print(f"  Wrote {len(found)} cells → {out_path}")


def main():
    out_dir = sys.argv[1] if len(sys.argv) > 1 else "/foss/designs/lora-mimo/ip/gf180mcu_fd_gap/lib"
    os.makedirs(out_dir, exist_ok=True)
    print(f"Output dir: {out_dir}")
    print(f"Gap cells to extract: {len(GAP_CELLS)}")

    for corner_suffix, _ in CORNERS:
        print(f"\nCorner: {corner_suffix}")
        process_corner(corner_suffix, out_dir)

    print("\nDone.")


if __name__ == "__main__":
    main()
