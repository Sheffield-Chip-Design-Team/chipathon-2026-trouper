#!/usr/bin/env python3
"""
convert_iq.py — Convert SDR IQ capture to signed int8 chip-rate binary for RTL testbench.

Input:  uint8 interleaved I/Q at 1 MS/s  (format: I0 Q0 I1 Q1 ...)
Output: int8 interleaved I/Q at 125 kHz  (same layout, raw binary)

Steps:
  1. Load uint8, centre at 0:  int_samp = uint8 - 128
  2. Form complex float
  3. Decimate 8x with FIR lowpass (hamming, 64*R+1 taps, fc=1/R)
  4. Scale so peak magnitude = 120 (leaves 6 counts headroom to ±127)
  5. Round and clip to int8, write raw binary

Usage:
  python3 convert_iq.py <input.iq> <output.bin>
"""

import sys
import numpy as np
from scipy.signal import resample_poly, firwin

def convert(in_path, out_path):
    raw = np.fromfile(in_path, dtype=np.uint8)
    if len(raw) % 2:
        raw = raw[:-1]

    # Centre: uint8 mid-scale = 128
    I = (raw[0::2].astype(np.float32) - 128.0)
    Q = (raw[1::2].astype(np.float32) - 128.0)
    iq = (I + 1j * Q).astype(np.complex64)

    # 8x FIR decimation to chip rate (125 kHz)
    R = 8
    h = firwin(64 * R + 1, 1.0 / R, window='hamming')
    iq_chip = resample_poly(iq, 1, R, window=h).astype(np.complex64)

    # Scale so peak magnitude fills to 120/127 of int8 range (no clipping)
    peak = np.max(np.abs(iq_chip))
    if peak > 0:
        scale = 120.0 / peak
    else:
        scale = 1.0

    i8_I = np.clip(np.round(iq_chip.real * scale), -127, 127).astype(np.int8)
    i8_Q = np.clip(np.round(iq_chip.imag * scale), -127, 127).astype(np.int8)

    # Interleave I, Q and write
    out = np.empty(len(i8_I) * 2, dtype=np.int8)
    out[0::2] = i8_I
    out[1::2] = i8_Q
    out.tofile(out_path)

    print(f"Input:  {len(raw)//2:,} samples @ 1 MS/s")
    print(f"Output: {len(i8_I):,} chip samples @ 125 kHz")
    print(f"Scale:  {scale:.3f}  (peak float = {peak:.3f})")
    print(f"int8 I: rms={np.sqrt(np.mean(i8_I.astype(float)**2)):.1f}  "
          f"peak={np.abs(i8_I).max()}")
    print(f"int8 Q: rms={np.sqrt(np.mean(i8_Q.astype(float)**2)):.1f}  "
          f"peak={np.abs(i8_Q).max()}")
    print(f"Written: {out_path}  ({len(out):,} bytes)")

if __name__ == "__main__":
    if len(sys.argv) != 3:
        print(f"Usage: {sys.argv[0]} <input.iq> <output.bin>")
        sys.exit(1)
    convert(sys.argv[1], sys.argv[2])
