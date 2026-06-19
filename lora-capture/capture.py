#!/usr/bin/env python3
"""
Capture IQ samples from an RTL-SDR and save them as a raw uint8 .iq file,
a complex64 .npy file, and a JSON metadata sidecar.

Defaults target EU868 LoRa (868.1 MHz) with a 2 MSPS sample rate, which
gives comfortable headroom for all LoRa bandwidths up to 500 kHz.

Usage examples
--------------
# Capture 60 s with defaults:
    python capture.py

# Capture the SF12/BW125 config with a descriptive label:
    python capture.py --label SF12-BW125-Pre8 --duration 60

# Higher gain for weak signals:
    python capture.py --gain 30

# Override centre frequency and sample rate:
    python capture.py --freq 915.0 --sr 2000000
"""

import argparse
import json
import os
import subprocess
import sys
import time
import numpy as np
from datetime import datetime, timezone

# ---------- defaults ----------
DEFAULT_FREQ     = 868_100_000   # 868.1 MHz (EU868 LoRa channel)
DEFAULT_SR       = 2_000_000     # 2 MSPS — covers BW up to 500 kHz with headroom
DEFAULT_GAIN     = 0.9           # dB — minimum manual gain on R828D tuner (0 = AGC)
DEFAULT_DURATION = 60            # seconds


def parse_args():
    p = argparse.ArgumentParser(
        description="Capture RTL-SDR IQ samples and save with metadata.",
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog=__doc__,
    )
    p.add_argument("--freq", type=float, default=DEFAULT_FREQ / 1e6,
                   metavar="MHz", help=f"Centre frequency in MHz (default {DEFAULT_FREQ/1e6})")
    p.add_argument("--sr", type=int, default=DEFAULT_SR,
                   metavar="SPS", help=f"Sample rate in samples/sec (default {DEFAULT_SR})")
    p.add_argument("--gain", type=float, default=DEFAULT_GAIN,
                   metavar="dB", help="Manual RX gain in dB; 0 enables AGC (default 0.9)")
    p.add_argument("--duration", type=int, default=DEFAULT_DURATION,
                   metavar="SEC", help=f"Capture duration in seconds (default {DEFAULT_DURATION})")
    p.add_argument("--outdir", default=None,
                   metavar="DIR", help="Output directory (default: same directory as this script)")
    p.add_argument("--label", default="",
                   metavar="LABEL", help="Optional label appended to output filenames, e.g. SF7-BW125")
    return p.parse_args()


def capture(freq_hz: int, sr: int, gain: float, n_samples: int,
            raw_path: str, duration_sec: int) -> str:
    cmd = [
        "rtl_sdr",
        "-f", str(freq_hz),
        "-s", str(sr),
        "-g", str(gain),
        "-n", str(n_samples),
        raw_path,
    ]
    gain_label = f"{gain} dB" if gain != 0 else "AGC"
    print(f"Capturing {duration_sec}s  "
          f"@ {freq_hz/1e6:.4f} MHz  "
          f"SR={sr/1e6:.3f} MSPS  "
          f"gain={gain_label}")
    print(f"Output: {raw_path}")
    print("Press Ctrl+C to stop early.\n")

    start = time.time()
    try:
        subprocess.run(cmd, check=True)
    except KeyboardInterrupt:
        print("\nStopped early by user.")
    except subprocess.CalledProcessError as e:
        print(f"rtl_sdr failed: {e}", file=sys.stderr)
        sys.exit(1)

    elapsed = time.time() - start
    size = os.path.getsize(raw_path)
    print(f"\nCaptured {size / 1e6:.1f} MB in {elapsed:.1f}s")
    return raw_path


def convert_to_numpy(raw_path: str, np_path: str) -> np.ndarray:
    """Convert rtl_sdr uint8 IQ pairs → complex64 centred at 0 Hz."""
    raw = np.fromfile(raw_path, dtype=np.uint8).astype(np.float32)
    iq = (raw - 127.5) / 127.5
    samples = iq[0::2] + 1j * iq[1::2]
    np.save(np_path, samples)
    print(f"Saved complex64 numpy array: {np_path}  ({len(samples):,} samples)")
    return samples


def write_metadata(meta_path: str, args, timestamp_utc: str, raw_path: str, np_path: str):
    meta = {
        "timestamp_utc":   timestamp_utc,
        "label":           args.label,
        "centre_freq_hz":  int(args.freq * 1e6),
        "sample_rate_sps": args.sr,
        "gain_db":         args.gain,
        "gain_mode":       "AGC" if args.gain == 0 else "manual",
        "duration_sec":    args.duration,
        "iq_format":       "uint8 offset-binary, interleaved I Q",
        "iq_conversion":   "complex = ((I - 127.5) + j*(Q - 127.5)) / 127.5",
        "files": {
            "raw_iq":  os.path.basename(raw_path),
            "numpy":   os.path.basename(np_path),
        },
    }
    with open(meta_path, "w") as f:
        json.dump(meta, f, indent=2)
    print(f"Saved metadata:              {meta_path}")


def energy_report(samples: np.ndarray, sr: int):
    """Print per-second RMS energy to show when packets arrived."""
    n_secs = len(samples) // sr
    print("\nPer-second RMS energy (higher = packet activity):")
    for i in range(n_secs):
        chunk = samples[i * sr : (i + 1) * sr]
        rms = float(np.sqrt(np.mean(np.abs(chunk) ** 2)))
        bar = "#" * int(rms * 200)
        print(f"  s{i+1:03d}: {rms:.4f}  {bar}")


def main():
    args = parse_args()

    freq_hz   = int(args.freq * 1e6)
    n_samples = args.sr * args.duration
    outdir    = args.outdir or os.path.join(os.path.dirname(os.path.abspath(__file__)), "captures")
    os.makedirs(outdir, exist_ok=True)

    timestamp_utc = datetime.now(timezone.utc).strftime("%Y%m%d_%H%M%S")
    label_part    = f"_{args.label}" if args.label else ""
    stem          = f"lora_{timestamp_utc}{label_part}"

    raw_path  = os.path.join(outdir, stem + ".iq")
    np_path   = os.path.join(outdir, stem + ".npy")
    meta_path = os.path.join(outdir, stem + ".json")

    capture(freq_hz, args.sr, args.gain, n_samples, raw_path, args.duration)
    samples = convert_to_numpy(raw_path, np_path)
    write_metadata(meta_path, args, timestamp_utc, raw_path, np_path)
    energy_report(samples, args.sr)

    print(f"\nDone. Files: {raw_path}")
    print("Load the .npy in a LoRa decoder (gr-lora, pylora) or inspect with inspectrum / URH.")


if __name__ == "__main__":
    main()
