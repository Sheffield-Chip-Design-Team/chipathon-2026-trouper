#!/usr/bin/env python3
"""
sweep_captures.py — plan a real-capture SF/BW sweep for test_capture_playback.

For each supported (SF, BW) labelled capture it locates the first packet burst
and sizes the playback window so the clip contains preamble (+ training for the
full/train stages). Emits one TSV line per run:

    <npy>\t<sf>\t<bw>\t<start>\t<nsamp>\t<stage>

Only BW 125/250 are in scope (BW500 captures are skipped). Stage is chosen per
SF to bound Verilator runtime: low SF runs the full chain, SF12 stops at sc_lock.

Usage:
    python3 tb/sweep_captures.py <captures_dir>
"""

import glob
import os
import re
import sys
import numpy as np

LABEL_RE = re.compile(r"SF(\d+)-BW(\d+)(?:-Pre(\d+))?", re.IGNORECASE)


def find_burst(npy_path, sr=2_000_000, scan_sec=3.0):
    """Return the first-burst start sample index (0 if none found)."""
    x = np.load(npy_path, mmap_mode="r")
    n = min(len(x), int(sr * scan_sec))
    p = np.abs(np.asarray(x[:n])) ** 2
    w = max(1, sr // 1000)
    env = np.convolve(p, np.ones(w) / w, mode="same")
    thr = env.max() * 0.3
    idx = np.where(env > thr)[0]
    return int(idx[0]) if len(idx) else 0


def stage_for_sf(sf):
    if sf <= 9:
        return "full"
    if sf <= 11:
        return "train"
    return "lock"          # SF12: sc_lock only


def plan(captures_dir):
    # one capture per (sf, bw): prefer the newest file, Pre8 if available
    best = {}
    for f in sorted(glob.glob(os.path.join(captures_dir, "*.npy"))):
        m = LABEL_RE.search(os.path.basename(f))
        if not m:
            continue
        sf, bw = int(m.group(1)), int(m.group(2))
        if bw not in (125, 250):
            continue
        pre = int(m.group(3)) if m.group(3) else 8
        key = (sf, bw)
        # prefer Pre8, then newest (sorted order ⇒ later overwrites)
        if key not in best or pre == 8:
            best[key] = (f, pre)

    rows = []
    for (sf, bw), (f, pre) in sorted(best.items()):
        sample_shift = 1 if bw == 250 else 2
        m_out = 1 << (sf + sample_shift)             # output samples per symbol
        stage = stage_for_sf(sf)
        train_syms = 0 if stage == "lock" else 10    # 8×M training + margin
        # capture-rate samples: 4 capture-samp per output-samp (×16 up, ÷64 dec)
        syms = pre + 2 + train_syms + 4              # +warmup +margin
        nsamp = 4 * syms * m_out
        burst = find_burst(f)
        start = max(0, burst - 2000)
        rows.append((f, sf, bw, start, nsamp, stage))
    return rows


if __name__ == "__main__":
    d = sys.argv[1] if len(sys.argv) > 1 else "../lora-capture/captures"
    for f, sf, bw, start, nsamp, stage in plan(d):
        print(f"{f}\t{sf}\t{bw}\t{start}\t{nsamp}\t{stage}")
