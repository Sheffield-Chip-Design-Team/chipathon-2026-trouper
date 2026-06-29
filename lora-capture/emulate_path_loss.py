#!/usr/bin/env python3
"""
Emulate large path loss on a clean IQ capture.

Physics: increasing path loss drops the *signal* power at the receiver while
the thermal noise floor stays fixed -> the signal sinks toward a constant
noise floor and the SNR falls. This tool reproduces exactly that:

    y = g * x + w

where `x` is a clean (high-SNR) capture, `g` attenuates the signal, and `w`
is fresh complex AWGN at a fixed reference floor `N_ref`. Lowering the target
SNR (or raising the path loss) shrinks `g`, sinking the signal into the floor.

This is the right way to make weak-signal data when you have no RF attenuator:
one clean capture -> a calibrated, repeatable SNR / path-loss sweep.

Examples
--------
# Sweep a single capture to several target SNRs (dB):
    python emulate_path_loss.py captures/lora_..._SF7-BW125-Pre8.npy \
        --snr 20 12 6 3 0

# Drive it by path loss instead (dB of extra attenuation vs the input):
    python emulate_path_loss.py captures/lora_..._SF7-BW125-Pre8.npy \
        --path-loss 10 20 30 40

# Reproducible noise:
    python emulate_path_loss.py <file> --snr 6 --seed 1234

Each target produces .iq (uint8, rtl_sdr-compatible) + .npy (complex64) +
.json, with the emulation parameters and the *achieved* SNR recorded.
"""

import argparse
import json
import os
import sys
import numpy as np
from datetime import datetime, timezone


def load_capture(path):
    """Load a capture as complex64. Accepts .npy or raw uint8 .iq."""
    if path.endswith(".npy"):
        x = np.load(path)
    elif path.endswith(".iq"):
        raw = np.fromfile(path, dtype=np.uint8).astype(np.float32)
        iq = (raw - 127.5) / 127.5
        x = iq[0::2] + 1j * iq[1::2]
    else:
        sys.exit(f"Unrecognised file type (need .npy or .iq): {path}")
    return x.astype(np.complex64)


def load_meta(path):
    """Best-effort load of the sibling .json metadata."""
    stem = path.rsplit(".", 1)[0]
    jp = stem + ".json"
    if os.path.exists(jp):
        with open(jp) as f:
            return json.load(f)
    return {}


def classify(x, sr, noise_pct, sig_frac):
    """Classify a bursty capture into signal-burst vs noise-only sample masks.

    Returns (sig_mask, noise_mask) boolean arrays from a smoothed power
    envelope. Run this on the *clean* source so the burst time-positions are
    detectable; reuse the masks to measure power on weak (buried) outputs.
    """
    p = np.abs(x) ** 2
    w = max(1, sr // 1000)                       # ~1 ms smoothing window
    env = np.convolve(p, np.ones(w) / w, mode="same")
    noise_mask = env < np.percentile(env, noise_pct)
    sig_mask = env > sig_frac * np.percentile(env, 99.5)
    if sig_mask.sum() == 0:
        sys.exit("No signal-present samples found; is this an empty capture?")
    return sig_mask, noise_mask


def powers(x, sig_mask, noise_mask):
    """Noise-subtracted signal power Ps and noise floor Pn over fixed masks."""
    p = np.abs(x) ** 2
    Pn = float(p[noise_mask].mean())
    Ps = max(float(p[sig_mask].mean()) - Pn, 0.0)
    return Ps, Pn


def apply_path_loss(x, g, n_ref, rng):
    """y = g*x + AWGN(power n_ref).  Returns complex64."""
    n = len(x)
    # complex AWGN with total power n_ref -> n_ref/2 per I and Q
    w = (rng.standard_normal(n) + 1j * rng.standard_normal(n)).astype(np.complex64)
    w *= np.sqrt(n_ref / 2.0)
    return (g * x + w).astype(np.complex64)


def to_uint8_iq(y):
    """Convert complex64 (rtl_sdr scale) back to uint8 offset-binary IQ.

    Inverse of (raw-127.5)/127.5. Clips to [0,255]; returns (bytes, clip_frac).
    """
    i = y.real * 127.5 + 127.5
    q = y.imag * 127.5 + 127.5
    inter = np.empty(2 * len(y), dtype=np.float32)
    inter[0::2] = i
    inter[1::2] = q
    clipped = (inter < 0) | (inter > 255)
    clip_frac = float(clipped.mean())
    return np.clip(np.round(inter), 0, 255).astype(np.uint8), clip_frac


def achieved_snr(y, sig_mask, noise_mask):
    Ps, Pn = powers(y, sig_mask, noise_mask)
    return 10 * np.log10(Ps / Pn) if Pn > 0 and Ps > 0 else float("-inf")


def parse_args():
    p = argparse.ArgumentParser(
        description="Emulate path loss / SNR sweep on a clean IQ capture.",
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog=__doc__,
    )
    p.add_argument("infile", help="Clean source capture (.npy or .iq)")
    g = p.add_mutually_exclusive_group(required=True)
    g.add_argument("--snr", type=float, nargs="+", metavar="dB",
                   help="Target output SNR(s) in dB")
    g.add_argument("--path-loss", type=float, nargs="+", metavar="dB",
                   help="Extra path loss(es) in dB relative to the input signal")
    p.add_argument("--outdir", default=None,
                   help="Output directory (default: same dir as input)")
    p.add_argument("--seed", type=int, default=None,
                   help="RNG seed for reproducible noise")
    p.add_argument("--noise-pct", type=float, default=20.0,
                   help="Envelope percentile treated as noise floor (default 20)")
    p.add_argument("--sig-frac", type=float, default=0.5,
                   help="Fraction of peak envelope marking signal bursts (default 0.5)")
    p.add_argument("--no-iq", action="store_true",
                   help="Skip writing the uint8 .iq file (npy + json only)")
    return p.parse_args()


def main():
    args = parse_args()
    x = load_capture(args.infile)
    meta = load_meta(args.infile)
    sr = int(meta.get("sample_rate_sps", 2_000_000))
    src_label = meta.get("label") or os.path.basename(args.infile).rsplit(".", 1)[0]

    sig_mask, noise_mask = classify(x, sr, args.noise_pct, args.sig_frac)
    Ps, Pn = powers(x, sig_mask, noise_mask)
    in_snr = 10 * np.log10(Ps / Pn)
    print(f"Source: {os.path.basename(args.infile)}  ({len(x):,} samples @ {sr/1e6:.3f} MSPS)")
    print(f"  signal power = {Ps:.3e}, noise floor = {Pn:.3e}")
    print(f"  input SNR    = {in_snr:.1f} dB   (signal-present {sig_mask.mean():.1%})")

    # Fixed reference noise floor = the capture's real receiver floor.
    n_ref = Pn
    outdir = args.outdir or os.path.dirname(os.path.abspath(args.infile))
    os.makedirs(outdir, exist_ok=True)
    rng = np.random.default_rng(args.seed)
    ts = datetime.now(timezone.utc).strftime("%Y%m%d_%H%M%S")

    # Build the list of (g, tag, target_descr) jobs.
    jobs = []
    if args.snr is not None:
        for snr in args.snr:
            g = np.sqrt((10 ** (snr / 10.0)) * n_ref / Ps)
            jobs.append((g, f"snr{snr:g}dB", f"target SNR {snr:g} dB"))
    else:
        for pl in args.path_loss:
            g = 10 ** (-pl / 20.0)
            jobs.append((g, f"PL{pl:g}dB", f"path loss {pl:g} dB"))

    print(f"\nGenerating {len(jobs)} output(s) (fixed noise floor, seed={args.seed}):")
    for g, tag, descr in jobs:
        y = apply_path_loss(x, g, n_ref, rng)
        ach = achieved_snr(y, sig_mask, noise_mask)
        pl_db = -20 * np.log10(g)
        stem = f"lora_{ts}_{src_label}_{tag}"
        npy_path = os.path.join(outdir, stem + ".npy")
        np.save(npy_path, y)

        clip_frac = None
        if not args.no_iq:
            iq_bytes, clip_frac = to_uint8_iq(y)
            iq_bytes.tofile(os.path.join(outdir, stem + ".iq"))

        out_meta = dict(meta)
        out_meta.update({
            "derived_from":     os.path.basename(args.infile),
            "emulation":        "path_loss",
            "target":           descr,
            "signal_gain_g":    float(g),
            "path_loss_db":     float(pl_db),
            "input_snr_db":     float(in_snr),
            "achieved_snr_db":  float(ach),
            "noise_floor_power": float(n_ref),
            "seed":             args.seed,
            "timestamp_utc":    ts,
            "files": {"raw_iq": stem + ".iq" if not args.no_iq else None,
                      "numpy": stem + ".npy"},
        })
        with open(os.path.join(outdir, stem + ".json"), "w") as f:
            json.dump(out_meta, f, indent=2)

        clip_note = "" if clip_frac is None else f"  clip={clip_frac:.2%}"
        warn = "  <-- CLIPPING" if (clip_frac or 0) > 0.001 else ""
        print(f"  {descr:<22}  g={g:.4f} ({pl_db:5.1f} dB)  "
              f"achieved SNR={ach:5.1f} dB{clip_note}{warn}")
        print(f"      -> {stem}.npy")

    print("\nDone.")


if __name__ == "__main__":
    main()
