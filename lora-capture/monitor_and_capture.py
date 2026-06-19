#!/usr/bin/env python3
"""
Monitor the Heltec serial port and automatically trigger a capture when a
specific LoRa config starts.  Parses serial output line-by-line so a TX line
and a config banner that arrive in the same read() chunk can never
cross-contaminate the trigger.

Banner format emitted by lora_tx.ino:
    === CONFIG 6/8: SF7-BW250-Pre8 ===

Usage
-----
# Capture every config once across a full cycle:
    python monitor_and_capture.py --port /dev/ttyUSB0 --all --duration 12 --gain 30

# Capture specific configs (label substrings matched against the banner):
    python monitor_and_capture.py --port /dev/ttyUSB0 \
        --configs SF7-BW250 SF7-BW500 --duration 12 --gain 30

# Dry-run: show banners without capturing:
    python monitor_and_capture.py --port /dev/ttyUSB0 --dry-run
"""

import argparse
import re
import subprocess
import sys
import time
from pathlib import Path

BANNER_RE = re.compile(r"=== CONFIG \d+/\d+: (\S+) ===")
SCRIPT_DIR = Path(__file__).parent


def parse_args():
    p = argparse.ArgumentParser(
        description="Serial monitor → RTL-SDR capture trigger",
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog=__doc__,
    )
    p.add_argument("--port", default="/dev/ttyUSB0",
                   help="Serial port of the Heltec (default /dev/ttyUSB0)")
    p.add_argument("--baud", type=int, default=115200)

    target = p.add_mutually_exclusive_group(required=True)
    target.add_argument("--all", action="store_true",
                        help="Capture every distinct config once")
    target.add_argument("--configs", nargs="+", metavar="LABEL",
                        help="Config label substrings to capture, e.g. SF7-BW250 SF7-BW500")

    p.add_argument("--duration", type=int, default=12,
                   help="Capture duration in seconds (default 12)")
    p.add_argument("--gain", type=float, default=30.0,
                   help="RTL-SDR gain in dB (default 30)")
    p.add_argument("--freq", type=float, default=868.1,
                   help="Centre frequency in MHz (default 868.1)")
    p.add_argument("--outdir", default=None,
                   help="Output directory (default: captures/ next to this script)")
    p.add_argument("--dry-run", action="store_true",
                   help="Print banners but do not capture")
    p.add_argument("--timeout", type=int, default=600,
                   help="Give up after this many seconds if targets not seen (default 600)")
    return p.parse_args()


def targets_remaining(args, captured: set) -> set:
    if args.all:
        return set()   # never done — run until timeout
    return {c for c in args.configs if not any(c in done for done in captured)}


def should_capture(args, label: str, captured: set) -> bool:
    if label in captured:
        return False
    if args.all:
        return True
    return any(target in label for target in args.configs)


def run_capture(label: str, args):
    outdir = args.outdir or str(SCRIPT_DIR / "captures")
    cmd = [
        sys.executable, str(SCRIPT_DIR / "capture.py"),
        "--gain",     str(args.gain),
        "--duration", str(args.duration),
        "--freq",     str(args.freq),
        "--outdir",   outdir,
        "--label",    label,
    ]
    print(f"  → capture.py --label {label} --duration {args.duration} --gain {args.gain}")
    subprocess.run(cmd)


def main():
    args = parse_args()

    import serial  # deferred so --help works without pyserial

    captured: set = set()
    deadline = time.time() + args.timeout

    print(f"Opening {args.port} at {args.baud} baud …")
    ser = serial.Serial(args.port, args.baud, timeout=1)

    # Line buffer: serial.readline() blocks for up to `timeout` seconds then
    # returns a partial line — accumulate until we see \n.
    buf = b""

    print("Watching for config banners. Press Ctrl+C to stop.\n")
    try:
        while time.time() < deadline:
            chunk = ser.read(256)
            if not chunk:
                continue
            buf += chunk
            # Process every complete line in the buffer
            while b"\n" in buf:
                line_bytes, buf = buf.split(b"\n", 1)
                line = line_bytes.decode("utf-8", errors="replace").strip()
                if line:
                    print(line)
                m = BANNER_RE.search(line)
                if not m:
                    continue
                label = m.group(1)   # e.g. "SF7-BW250-Pre8"
                print(f"\n[banner] config={label}")
                if args.dry_run:
                    print("  (dry-run, skipping capture)")
                elif should_capture(args, label, captured):
                    run_capture(label, args)
                    captured.add(label)
                    print(f"  captured. done so far: {sorted(captured)}\n")
                else:
                    print(f"  (already captured or not in target list, skipping)\n")

                if not args.all and not targets_remaining(args, captured):
                    print("All targets captured.")
                    return

    except KeyboardInterrupt:
        print("\nStopped by user.")
    finally:
        ser.close()

    if not args.all and targets_remaining(args, captured):
        print(f"Timed out. Still missing: {targets_remaining(args, captured)}")
    else:
        print(f"Done. Captured: {sorted(captured)}")


if __name__ == "__main__":
    main()
