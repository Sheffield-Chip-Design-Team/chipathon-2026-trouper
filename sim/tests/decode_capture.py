"""Decode real LoRa IQ captures through the single-antenna DSP chain.

Pipeline
--------
1. Load uint8 offset-binary IQ (1 MS/s, centre 868.1 MHz)
2. Anti-alias FIR + decimate 8× to chip rate (125 kHz)
3. Schmidl-Cox preamble detection
4. Integer CFO estimation and correction
5. Training accumulator channel estimate (MRC weight)
6. Payload symbol decode: dechirp → FFT → argmax

Usage
-----
python3 -m sim.tests.decode_capture sim/examples/1_packet_mingain.iq
python3 -m sim.tests.decode_capture sim/examples/5_packets_mingain.iq --sf 7 --bw 125e3
python3 -m sim.tests.decode_capture capture.iq --fs 2e6 --sf 9 --bw 250e3
"""

import argparse
import numpy as np
from collections import Counter
from pathlib import Path
from scipy.signal import resample_poly, firwin

from sim.models.lora import demodulate


# ---------------------------------------------------------------------------
# File loading
# ---------------------------------------------------------------------------

def load_iq(path: str) -> np.ndarray:
    """Load uint8 offset-binary IQ file.

    Conversion: z = ((I - 127.5) + j*(Q - 127.5)) / 127.5
    Byte layout: I0 Q0 I1 Q1 ...
    """
    raw = np.fromfile(path, dtype=np.uint8)
    I   = (raw[0::2].astype(np.float32) - 127.5) / 127.5
    Q   = (raw[1::2].astype(np.float32) - 127.5) / 127.5
    return (I + 1j * Q).astype(np.complex64)


# ---------------------------------------------------------------------------
# Decimation
# ---------------------------------------------------------------------------

def decimate_to_chiprate(iq: np.ndarray, fs: float, bw: float) -> np.ndarray:
    """Anti-alias FIR + polyphase decimation from fs to bw (chip rate)."""
    if abs(fs - bw) < 1.0:
        return iq
    from fractions import Fraction
    frac = Fraction(bw / fs).limit_denominator(512)
    p, q = frac.numerator, frac.denominator
    h    = firwin(64 * q + 1, float(p) / q, window='hamming')
    return resample_poly(iq, p, q, window=h).astype(np.complex64)


# ---------------------------------------------------------------------------
# Schmidl-Cox detection
# ---------------------------------------------------------------------------

def sc_metric(iq: np.ndarray, M: int) -> np.ndarray:
    """Compute sample-by-sample Schmidl-Cox metric on chip-rate IQ."""
    n  = np.arange(len(iq))
    dc = np.exp(-1j * np.pi * (n % M) ** 2 / M)
    d  = iq * dc
    N  = len(d) - 2 * M
    P  = np.array([np.abs(np.dot(d[k:k+M], np.conj(d[k+M:k+2*M]))) for k in range(N)])
    Re = np.array([np.sum(np.abs(d[k+M:k+2*M]) ** 2)               for k in range(N)])
    return np.where(Re > 0, P / Re, 0.0)


def find_packet_onsets(metric: np.ndarray, M: int,
                       threshold: float = 0.85,
                       min_gap: int = 0) -> list[int]:
    """Return chip-sample indices of each packet's preamble start.

    Walks backwards from each threshold crossing to the plateau edge so
    that the returned index is the first sample of the preamble.
    min_gap defaults to 10 × M when not set.
    """
    if min_gap == 0:
        min_gap = 10 * M
    onsets: list[int] = []
    last = -min_gap
    for i, v in enumerate(metric):
        if v >= threshold and (i - last) >= min_gap:
            j = i
            while j > 0 and metric[j - 1] >= threshold * 0.8:
                j -= 1
            onsets.append(j)
            last = i
    return onsets


# ---------------------------------------------------------------------------
# CFO estimation and correction
# ---------------------------------------------------------------------------

def estimate_cfo(iq_chip: np.ndarray, onset: int, M: int,
                 n_sym: int = 8) -> int:
    """Estimate integer CFO in bins from preamble upchirps.

    Returns the modal dechirp bin over n_sym symbols (signed, range
    (-M/2, M/2]).  A positive value means the signal is above centre.
    """
    ref  = np.exp(-1j * np.pi * np.arange(M) ** 2 / M)
    bins = []
    for k in range(n_sym):
        s = onset + k * M
        if s + M > len(iq_chip):
            break
        b = int(np.argmax(np.abs(np.fft.fft(iq_chip[s:s+M] * ref))))
        bins.append(b)
    mode_bin = Counter(bins).most_common(1)[0][0]
    return mode_bin if mode_bin <= M // 2 else mode_bin - M


def apply_cfo(iq: np.ndarray, cfo_bins: int, M: int) -> np.ndarray:
    """Multiply by exp(-j·2π·cfo_bins/M·n) to remove integer CFO."""
    n = np.arange(len(iq), dtype=np.float64)
    return (iq * np.exp(-1j * 2 * np.pi * cfo_bins / M * n)).astype(np.complex64)


# ---------------------------------------------------------------------------
# Training accumulator
# ---------------------------------------------------------------------------

def training_accumulate(iq_chip: np.ndarray, onset: int,
                        M: int, n_preamble: int = 8) -> complex:
    """Z_j = Σ iq[n] · conj(upchirp[n mod M]) over n_preamble symbols."""
    N     = n_preamble * M
    n     = np.arange(N)
    cref  = np.exp(1j * np.pi * (n % M) ** 2 / M)
    seg   = iq_chip[onset:onset + N]
    return complex(np.dot(seg, np.conj(cref)))


# ---------------------------------------------------------------------------
# Per-packet decode
# ---------------------------------------------------------------------------

N_PREAMBLE  = 8
N_SYNC_SKIP = 5   # 2 sync words + 2.25 downchirps, rounded up


def decode_packet(iq_chip: np.ndarray, onset: int, M: int,
                  n_payload: int = 0) -> dict:
    """Full single-antenna decode for one packet starting at onset.

    Parameters
    ----------
    iq_chip   : chip-rate complex IQ (full file)
    onset     : sample index of preamble start
    M         : samples per symbol (2^SF)
    n_payload : symbols to decode; 0 = all remaining

    Returns
    -------
    dict with keys: cfo_bins, cfo_hz, Z, phase_deg, symbols, snr
    """
    # CFO
    cfo_bins = estimate_cfo(iq_chip, onset, M)
    iq_corr  = apply_cfo(iq_chip[onset:], cfo_bins, M)

    # Training accumulator → MRC weight
    Z = training_accumulate(iq_corr, 0, M)
    w = Z / (abs(Z) + 1e-12)

    # Payload
    ref         = np.exp(-1j * np.pi * np.arange(M) ** 2 / M)
    payload_off = (N_PREAMBLE + N_SYNC_SKIP) * M
    available   = (len(iq_corr) - payload_off) // M
    n_decode    = available if n_payload == 0 else min(n_payload, available)

    symbols, snrs = [], []
    for k in range(n_decode):
        s    = payload_off + k * M
        seg  = iq_corr[s:s+M] * np.conj(w)
        spec = np.abs(np.fft.fft(seg * ref))
        b    = int(np.argmax(spec))
        symbols.append(b)
        snrs.append(float(spec.max() / (spec.mean() + 1e-9)))

    return dict(
        cfo_bins  = cfo_bins,
        cfo_hz    = cfo_bins * 125e3 / M,
        Z         = Z,
        phase_deg = float(np.degrees(np.angle(Z))),
        symbols   = symbols,
        snr       = snrs,
    )


# ---------------------------------------------------------------------------
# Top-level runner
# ---------------------------------------------------------------------------

def process_file(path: str, fs: float = 1e6, sf: int = 7, bw: float = 125e3,
                 sc_threshold: float = 0.85, min_gap_symbols: int = 200,
                 n_payload: int = 0) -> list[dict]:
    """Load, decimate, detect, and decode all packets in an IQ file.

    Parameters
    ----------
    path             : path to uint8 offset-binary .iq file
    fs               : file sample rate in Hz
    sf               : LoRa spreading factor
    bw               : LoRa bandwidth in Hz (chip rate)
    sc_threshold     : SC metric threshold for preamble detection
    min_gap_symbols  : minimum symbols between distinct packets
    n_payload        : payload symbols to decode per packet (0 = all)
    """
    M = 2 ** sf

    print(f"Loading {path} ...")
    iq = load_iq(path)
    print(f"  {len(iq)} samples  ({len(iq)/fs*1e3:.1f} ms)")

    print(f"Decimating {fs/1e3:.0f} kHz → {bw/1e3:.0f} kHz (R={int(fs/bw)}) ...")
    iq_chip = decimate_to_chiprate(iq, fs, bw)
    print(f"  {len(iq_chip)} chip-rate samples  ({len(iq_chip)/bw*1e3:.1f} ms)\n")

    print("Computing Schmidl-Cox metric ...")
    metric  = sc_metric(iq_chip, M)
    min_gap = min_gap_symbols * M
    onsets  = find_packet_onsets(metric, M, sc_threshold, min_gap)
    print(f"  Detected {len(onsets)} packet(s)  SC peak={metric.max():.3f}\n")

    results = []
    for i, onset in enumerate(onsets):
        # Bound payload to this packet only (stop at next onset or EOF)
        next_onset = onsets[i + 1] if i + 1 < len(onsets) else len(iq_chip)
        max_pay    = (next_onset - onset - (N_PREAMBLE + N_SYNC_SKIP) * M) // M
        n_pay      = max_pay if n_payload == 0 else min(n_payload, max_pay)

        r = decode_packet(iq_chip, onset, M, n_payload=n_pay)
        r['onset']      = onset
        r['sc_metric']  = float(metric[onset])
        r['packet_num'] = i + 1

        preamble_bins_consistent = Counter(
            [int(np.argmax(np.abs(np.fft.fft(
                apply_cfo(iq_chip[onset:onset+N_PREAMBLE*M],
                          r['cfo_bins'], M)[k*M:(k+1)*M]
                * np.exp(-1j * np.pi * np.arange(M)**2 / M)
            )))) for k in range(N_PREAMBLE)]
        ).most_common(1)[0][1]

        print(f"Packet {i+1}  onset={onset}  SC={r['sc_metric']:.3f}")
        print(f"  CFO        : {r['cfo_bins']:+d} bins = {r['cfo_hz']:+.0f} Hz")
        print(f"  Channel    : |Z|={abs(r['Z']):.3f}  phase={r['phase_deg']:+.1f}°")
        print(f"  Preamble   : {preamble_bins_consistent}/8 bins consistent")
        snr_arr = r['snr']
        if snr_arr:
            print(f"  Payload    : {len(r['symbols'])} symbols  "
                  f"SNR avg={np.mean(snr_arr):.2f}×  min={np.min(snr_arr):.2f}×")
            bstr = bytes(s % 256 for s in r['symbols'])
            print(f"  Bytes      : {bstr.hex()}")
        else:
            print("  Payload    : 0 symbols (not enough samples after header)")
        print()
        results.append(r)

    return results


# ---------------------------------------------------------------------------
# CLI
# ---------------------------------------------------------------------------

def main():
    parser = argparse.ArgumentParser(
        description="Decode uint8 offset-binary LoRa IQ captures."
    )
    parser.add_argument("file", help="Path to .iq capture file")
    parser.add_argument("--fs",        type=float, default=1e6,
                        help="File sample rate in Hz (default 1e6)")
    parser.add_argument("--sf",        type=int,   default=7,
                        help="Spreading factor (default 7)")
    parser.add_argument("--bw",        type=float, default=125e3,
                        help="LoRa bandwidth / chip rate in Hz (default 125e3)")
    parser.add_argument("--threshold", type=float, default=0.85,
                        help="SC metric threshold for preamble detection (default 0.85)")
    parser.add_argument("--min-gap",   type=int,   default=200,
                        help="Min gap between packets in symbols (default 200)")
    parser.add_argument("--n-payload", type=int,   default=0,
                        help="Payload symbols to decode per packet (0=all)")
    args = parser.parse_args()

    process_file(
        path             = args.file,
        fs               = args.fs,
        sf               = args.sf,
        bw               = args.bw,
        sc_threshold     = args.threshold,
        min_gap_symbols  = args.min_gap,
        n_payload        = args.n_payload,
    )


if __name__ == "__main__":
    main()
