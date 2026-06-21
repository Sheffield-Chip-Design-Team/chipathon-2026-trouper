#!/usr/bin/env python3
"""
Schmidl-Cox preamble detector for LoRa IQ captures.

Computes the normalised SC metric:

    P[d]  = sum_{m=0}^{L-1}  x*[d+m] * x[d+m+M]   (cross-correlation)
    R1[d] = sum_{m=0}^{L-1}  |x[d+m]|^2            (energy of current window)
    R2[d] = sum_{m=0}^{L-1}  |x[d+m+M]|^2          (energy of delayed window)
    SC[d] = |P[d]|^2 / (R1[d] * R2[d])             (Cauchy-Schwarz bounded 0..1)

By Cauchy-Schwarz, SC[d] <= 1 always.  SC[d] -> 1 during the preamble
(identical upchirps at lag M apart).

L = M = 2^SF (full symbol) for maximum processing gain.  The ASIC uses
L = min(M,256) to fit SRAM; that costs 3-12 dB integration loss for SF9-12.

Sliding sums are computed via cumsum (O(N) total).  Cumsums are accumulated
in float64 to avoid catastrophic cancellation on long captures (float32 loses
all precision for L=65536 windows across 24M-sample files).

Plateau width ~ (N_pre - 1) * M samples -> preamble symbol count estimate.

Usage
-----
    python analyse_sc.py captures/lora_20260619_150946_SF7-BW125-Pre8.npy

    # Force SF/BW:
    python analyse_sc.py myfile.npy --sf 7 --bw 125 --threshold 0.3

    # Simulate ASIC integration loss (L=min(M,256)):
    python analyse_sc.py captures/lora_20260619_151110_SF12-BW125-Pre8.npy --asic-L
"""

import argparse
import re
import sys
from pathlib import Path

import numpy as np


SR = 2_000_000   # RTL-SDR sample rate (samples/sec)


def parse_label(path):
    """Extract SF and BW from a filename like SF7-BW125-Pre8."""
    m = re.search(r'SF(\d+)-BW(\d+)', Path(path).stem)
    if m:
        return int(m.group(1)), int(m.group(2))
    return None, None


def sc_metric_fast(samples, M, L=None):
    """
    Compute SC[d] = |P[d]|^2 / (R1[d] * R2[d]) for all d.

    Uses float64 prefix-sum cumsums to prevent catastrophic cancellation that
    occurs with float32 on long captures (e.g. SF12 L=65536, N=24M samples).

    Returns float32 array, same length as samples, zero outside valid range.
    """
    if L is None:
        L = M
    N = len(samples)
    valid = N - M - L
    if valid <= 0:
        return np.zeros(N, dtype=np.float32)

    # Products accumulated in float64
    xc  = (samples[:N-M].conj() * samples[M:]).astype(np.complex128)
    en1 = (samples[:N-M].real**2 + samples[:N-M].imag**2).astype(np.float64)
    en2 = (samples[M:].real**2   + samples[M:].imag**2).astype(np.float64)

    # Prefix sums (float64 — avoids ~10000x error seen in float32 for SF12)
    xc_cs  = np.empty(N - M + 1, dtype=np.complex128)
    en1_cs = np.empty(N - M + 1, dtype=np.float64)
    en2_cs = np.empty(N - M + 1, dtype=np.float64)
    xc_cs[0]  = 0j
    en1_cs[0] = 0.0
    en2_cs[0] = 0.0
    np.cumsum(xc,  out=xc_cs[1:])
    np.cumsum(en1, out=en1_cs[1:])
    np.cumsum(en2, out=en2_cs[1:])

    P  = xc_cs[L:L+valid]  - xc_cs[:valid]
    R1 = en1_cs[L:L+valid] - en1_cs[:valid]
    R2 = en2_cs[L:L+valid] - en2_cs[:valid]

    denom = R1 * R2
    sc = np.zeros(N, dtype=np.float32)
    mask = denom > 0
    sc[:valid][mask] = (np.abs(P[mask])**2 / denom[mask]).astype(np.float32)
    return sc


def find_detections(sc, M, threshold=0.3, min_gap=None):
    """
    Find SC plateaus above threshold and estimate preamble length.

    min_gap: merge adjacent regions within this many samples.
    Default is M (one symbol period) — bridges dips at sync-word symbols.

    Returns list of dicts with keys:
        start, end, peak_val, peak_idx, plateau_samp, n_pre_est
    """
    if min_gap is None:
        min_gap = M

    hot = sc > threshold

    # Raw regions
    regions = []
    in_region = False
    reg_start = 0
    for i, h in enumerate(hot):
        if h and not in_region:
            reg_start = i
            in_region = True
        elif not h and in_region:
            regions.append((reg_start, i))
            in_region = False
    if in_region:
        regions.append((reg_start, len(sc)))

    # Merge close regions (handles fragmented plateaus and sync-word dips)
    merged = []
    for (s, e) in regions:
        if merged and s - merged[-1][1] < min_gap:
            merged[-1] = (merged[-1][0], e)
        else:
            merged.append((s, e))

    detections = []
    for (s, e) in merged:
        seg  = sc[s:e]
        pk   = float(seg.max())
        pki  = int(seg.argmax()) + s
        plat = e - s
        # plateau ~ (N_pre - 1) * M  =>  N_pre = round(plat/M) + 1
        n_pre_est = max(2, round(plat / M) + 1)
        detections.append(dict(
            start        = s,
            end          = e,
            peak_val     = pk,
            peak_idx     = pki,
            plateau_samp = plat,
            n_pre_est    = n_pre_est,
        ))

    return detections


def parse_args():
    p = argparse.ArgumentParser(
        description="Schmidl-Cox LoRa preamble detector",
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog=__doc__,
    )
    p.add_argument("npy", help=".npy complex64 capture file")
    p.add_argument("--sf",  type=int, default=None)
    p.add_argument("--bw",  type=int, default=None, help="Bandwidth in kHz")
    p.add_argument("--sr",  type=int, default=SR,   help=f"Sample rate Hz (default {SR})")
    p.add_argument("--threshold", type=float, default=0.3)
    p.add_argument("--asic-L", action="store_true",
                   help="Use L=min(M,256) to simulate ASIC integration loss")
    return p.parse_args()


def main():
    args = parse_args()
    path = args.npy

    sf, bw = args.sf, args.bw
    if sf is None or bw is None:
        sf_auto, bw_auto = parse_label(path)
        if sf is None: sf = sf_auto
        if bw is None: bw = bw_auto

    if sf is None or bw is None:
        print("ERROR: cannot determine SF/BW — pass --sf and --bw", file=sys.stderr)
        sys.exit(1)

    M   = int(2**sf / (bw * 1e3) * args.sr)
    L   = min(M, 256) if args.asic_L else M
    sr  = args.sr

    print(f"File  : {path}")
    print(f"SF={sf}  BW={bw} kHz  SR={sr/1e6:.1f} MSPS")
    print(f"M={M} samples/symbol  L={L} (window)  threshold={args.threshold}")
    if args.asic_L and L < M:
        print(f"ASIC mode: L={L} < M => {10*np.log10(L/M):.1f} dB integration loss")
    print()

    samples = np.load(path)
    print(f"Loaded {len(samples):,} samples  ({len(samples)/sr:.1f} s)\n")

    sc   = sc_metric_fast(samples, M, L)
    dets = find_detections(sc, M, threshold=args.threshold)

    if not dets:
        print(f"No detections above threshold {args.threshold}.")
        print(f"SC max={sc.max():.4f}  mean={sc.mean():.6f}")
        print("Try lowering --threshold.")
        return

    sym_ms = M / sr * 1000
    print(f"{'#':>3}  {'Time (s)':>9}  {'Peak SC':>8}  {'Plateau (ms)':>13}  {'N_pre est':>10}")
    print("-" * 55)
    for i, d in enumerate(dets):
        t       = d['peak_idx'] / sr
        plat_ms = d['plateau_samp'] / sr * 1000
        print(f"{i+1:>3}  {t:>9.3f}  {d['peak_val']:>8.4f}  {plat_ms:>12.1f}  {d['n_pre_est']:>10}")

    pre_counts = [d['n_pre_est'] for d in dets]
    mode_pre   = max(set(pre_counts), key=pre_counts.count)
    print(f"\nDetected {len(dets)} packet(s).")
    print(f"Preamble symbols estimated: {pre_counts}")
    print(f"  mode = {mode_pre}  (firmware config: Pre8 for most, Pre6/12/16 for configs 3/4/5)")
    print(f"Symbol duration : {sym_ms:.3f} ms  ({M} samples)")


if __name__ == "__main__":
    main()
