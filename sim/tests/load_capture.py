"""Load real SDR IQ captures and feed them through the MRC DSP chain.

The capture pipeline
--------------------
1. Load IQ from file (float32, int16, int8, or .npy)
2. Decimate to chip rate  fs_target = BW  (e.g. 125 kS/s for 125 kHz BW)
   — at chip rate, one symbol = M = 2^SF samples, matching the sim model
3. Coarse CFO correction using dechirped preamble FFT peak
4. Energy detection to find preamble onset
5. Fine preamble alignment (correlate symbol 0 to exact sample)
6. Channel estimation over N_PREAMBLE upchirps
7. Skip sync words + downchirp (4.25 symbols → 5 in practice)
8. Decode each payload symbol: MRC → dechirp → FFT argmax

Supported file formats
----------------------
.npy                 — numpy complex64/float32 array (shape (N,) or (N,2))
.bin / .raw / .f32   — interleaved float32 I/Q (GNU Radio, SDR#)
.cs16 / .s16         — interleaved int16  (RTL-SDR raw)
.cs8  / .s8          — interleaved int8   (HackRF)

Usage (single antenna)
----------------------
python3 -m sim.load_capture capture.npy --fs 250e3 --sf 7

Usage (four synchronised captures for NR=4 MRC)
-----------------------------------------------
python3 -m sim.load_capture ch0.npy ch1.npy ch2.npy ch3.npy --fs 250e3 --sf 7
"""

import argparse
import numpy as np
from pathlib import Path
from scipy import signal as sp_signal

from sim.models.lora     import upchirp, demodulate
from sim.models.receiver import estimate_channel, compute_weights, mrc_combine


# ---------------------------------------------------------------------------
# File loading
# ---------------------------------------------------------------------------

def load_iq(path: str) -> np.ndarray:
    """
    Load IQ samples from file. Returns complex64 array shape (N,).

    Auto-detects format from extension.
    """
    p   = Path(path)
    ext = "".join(p.suffixes).lower()

    if ext == ".npy":
        data = np.load(p)
        if np.iscomplexobj(data):
            return data.astype(np.complex64)
        if data.ndim == 2 and data.shape[1] == 2:
            return (data[:, 0] + 1j * data[:, 1]).astype(np.complex64)
        # interleaved real array
        return (data[0::2] + 1j * data[1::2]).astype(np.complex64)

    if ext in (".cs16", ".s16", ".iq"):
        raw = np.fromfile(p, dtype=np.int16)
        iq  = raw[0::2].astype(np.float32) + 1j * raw[1::2].astype(np.float32)
        return (iq / 32768.0).astype(np.complex64)

    if ext in (".cs8", ".s8"):
        raw = np.fromfile(p, dtype=np.int8)
        iq  = raw[0::2].astype(np.float32) + 1j * raw[1::2].astype(np.float32)
        return (iq / 128.0).astype(np.complex64)

    # default: interleaved float32
    raw = np.fromfile(p, dtype=np.float32)
    return (raw[0::2] + 1j * raw[1::2]).astype(np.complex64)


# ---------------------------------------------------------------------------
# Resampling
# ---------------------------------------------------------------------------

def decimate_to_chiprate(iq: np.ndarray, fs: float, bw: float) -> np.ndarray:
    """
    Resample IQ from fs to bw (chip rate).  Uses polyphase rational resampler
    so fs/bw need not be an integer.

    At chip rate, one LoRa symbol = M = 2^SF samples exactly.
    """
    if abs(fs - bw) < 1.0:
        return iq                          # already at chip rate

    ratio = bw / fs
    # find a good rational approximation p/q ≈ ratio
    from fractions import Fraction
    frac = Fraction(ratio).limit_denominator(512)
    p, q = frac.numerator, frac.denominator

    print(f"  Resampling {fs/1e3:.1f} kS/s → {bw/1e3:.1f} kS/s  ({p}/{q})")
    return sp_signal.resample_poly(iq, p, q).astype(np.complex64)


# ---------------------------------------------------------------------------
# Energy detection
# ---------------------------------------------------------------------------

def find_preamble_onsets(iq: np.ndarray, M: int,
                          n_det: int | None = None,
                          threshold_factor: float = 4.0) -> list[int]:
    """
    Sliding-window power detector matching Stage 2 of the ASIC design.

    n_det defaults to M (one symbol period).
    Returns list of sample indices where preamble onset was detected.
    """
    if n_det is None:
        n_det = M

    power = np.abs(iq) ** 2

    # running sum via cumsum (avoids O(N*n_det) loop)
    cs    = np.concatenate(([0.0], np.cumsum(power)))
    win   = (cs[n_det:] - cs[:-n_det]) / n_det   # shape (N - n_det,)

    # noise floor: 10th percentile of the sliding-window power.
    # Using median breaks when the packet fills >50% of the capture;
    # the lower percentile stays in the noise region as long as the
    # signal occupies <90% of the file.
    noise_floor = np.percentile(win, 10)
    threshold   = threshold_factor * noise_floor

    # Rising-edge detect.
    # win[i] covers samples i…i+n_det-1 so the actual signal onset is at
    # approximately i + n_det - 1 (the last sample in the window).
    # Minimum gap = N_PREAMBLE * M to avoid re-triggering on each preamble
    # symbol of the same packet.
    above   = win > threshold
    onsets  = []
    last    = -(N_PREAMBLE * n_det)
    for i, a in enumerate(above):
        if a and (i - last) > N_PREAMBLE * n_det:
            onsets.append(i + n_det - 1)   # shift to approximate actual onset
            last = i

    return onsets


# ---------------------------------------------------------------------------
# CFO estimation and correction
# ---------------------------------------------------------------------------

def estimate_cfo(iq_symbol: np.ndarray, M: int) -> float:
    """
    Estimate carrier frequency offset in fractional bins from one upchirp symbol.

    Dechirp with the reference upchirp then take FFT; the peak bin offset
    from DC equals the normalised CFO:  δf = peak_bin * BW / M  Hz.

    Returns normalised CFO in bins (multiply by BW/M to get Hz).
    """
    n        = np.arange(M)
    dechirp  = iq_symbol[:M] * np.exp(-1j * np.pi * n ** 2 / M)
    spectrum = np.abs(np.fft.fft(dechirp, M))
    peak_bin = int(np.argmax(spectrum))
    # unwrap: bins > M/2 correspond to negative frequencies
    if peak_bin > M // 2:
        peak_bin -= M
    return float(peak_bin)


def apply_cfo_correction(iq: np.ndarray, cfo_bins: float, M: int) -> np.ndarray:
    """Multiply by exp(-j*2*pi*cfo_bins/M * n) to shift by -cfo_bins bins."""
    n = np.arange(len(iq), dtype=np.float64)
    return (iq * np.exp(-1j * 2 * np.pi * cfo_bins / M * n)).astype(np.complex64)


# ---------------------------------------------------------------------------
# Sub-sample preamble alignment
# ---------------------------------------------------------------------------

def align_to_symbol(iq: np.ndarray, M: int, search_window: int = 16) -> int:
    """
    Find the start of the preamble within iq by maximising the correlation
    against the reference upchirp.

    iq should cover [onset - search_window : onset + search_window + M].
    Returns the index within iq where the preamble starts (0-based).
    """
    c_conj = np.conj(upchirp(M))
    best_idx, best_power = 0, 0.0

    for idx in range(2 * search_window + 1):
        if idx + M > len(iq):
            break
        power = abs(np.dot(iq[idx : idx + M], c_conj)) ** 2
        if power > best_power:
            best_power, best_idx = power, idx

    return best_idx


# ---------------------------------------------------------------------------
# Top-level decoder
# ---------------------------------------------------------------------------

N_PREAMBLE  = 8     # standard LoRa preamble upchirps
N_SYNC_SKIP = 5     # sync words (2) + downchirps (2.25) rounded up


def decode_packet(iq_chip: np.ndarray, SF: int,
                  n_payload_syms: int = 0,
                  channel_idx: int = 0) -> dict:
    """
    Decode one LoRa packet from chip-rate IQ (one antenna).

    Parameters
    ----------
    iq_chip       : complex samples at chip rate (one symbol = M samples)
    SF            : spreading factor
    n_payload_syms: number of payload symbols to decode (0 = auto until end)
    channel_idx   : antenna index label (for multi-channel display)

    Returns
    -------
    dict with keys: h_hat, cfo_bins, payload_symbols, raw_iq_preamble
    """
    M = 2 ** SF

    # --- CFO estimation from first preamble symbol ---------------------------
    cfo_bins = estimate_cfo(iq_chip, M)
    if abs(cfo_bins) > 0.5:
        print(f"  Ant {channel_idx}: CFO = {cfo_bins:+.2f} bins — correcting")
        iq_chip = apply_cfo_correction(iq_chip, cfo_bins, M)
    else:
        print(f"  Ant {channel_idx}: CFO = {cfo_bins:+.2f} bins — within ±0.5, skipping")

    # --- Channel estimation --------------------------------------------------
    n_pre_samples = N_PREAMBLE * M
    if len(iq_chip) < n_pre_samples:
        raise ValueError(
            f"Capture too short: need {n_pre_samples} samples for preamble, "
            f"got {len(iq_chip)}"
        )

    rx_pre = iq_chip[:n_pre_samples][np.newaxis, :]    # shape (1, N_PREAMBLE*M)
    h_hat  = estimate_channel(rx_pre, M, N_PREAMBLE)   # shape (1,)

    print(
        f"  Ant {channel_idx}: |h_hat| = {abs(h_hat[0]):.4f}  "
        f"phase = {np.degrees(np.angle(h_hat[0])):+.1f}°"
    )

    # --- Skip sync words + downchirps ----------------------------------------
    payload_start = (N_PREAMBLE + N_SYNC_SKIP) * M
    payload_iq    = iq_chip[payload_start:]

    # --- Decode payload symbols -----------------------------------------------
    if n_payload_syms == 0:
        n_payload_syms = len(payload_iq) // M

    symbols = []
    for k in range(n_payload_syms):
        sym_iq = payload_iq[k * M : (k + 1) * M]
        if len(sym_iq) < M:
            break
        symbols.append(demodulate(sym_iq))

    return {
        "h_hat"            : h_hat,
        "cfo_bins"         : cfo_bins,
        "payload_symbols"  : symbols,
        "raw_iq_preamble"  : iq_chip[:n_pre_samples],
    }


def process_capture(paths: list[str], fs: float, SF: int,
                    bw: float = 125e3,
                    n_payload_syms: int = 0,
                    threshold_factor: float = 4.0) -> list[dict]:
    """
    Full pipeline for one or more synchronised SDR captures.

    For NR=1: runs single-antenna decode.
    For NR>1: runs MRC combining across all antennas before decoding payload.

    Returns list of decoded packet dicts (one per detected onset).
    """
    NR  = len(paths)
    M   = 2 ** SF

    # Load and decimate all channels
    channels = []
    for i, path in enumerate(paths):
        print(f"\nLoading {path} ...")
        iq = load_iq(path)
        iq = decimate_to_chiprate(iq, fs, bw)
        channels.append(iq)

    # Align lengths to shortest channel
    n_min = min(len(ch) for ch in channels)
    channels = [ch[:n_min] for ch in channels]

    # Energy detection on channel 0 (reference, matching ASIC Stage 2)
    print(f"\nEnergy detection on reference channel (threshold factor={threshold_factor}×) ...")
    onsets = find_preamble_onsets(channels[0], M, threshold_factor=threshold_factor)
    print(f"  Found {len(onsets)} packet onset(s) at samples: {onsets}")

    results = []
    for onset_idx, onset in enumerate(onsets):
        print(f"\n=== Packet {onset_idx + 1} (onset @ sample {onset}) ===")

        # Fine alignment — search ±search_window around detected onset
        search_window = 32
        search_start  = max(0, onset - search_window)
        search_end    = min(n_min, search_start + 2 * search_window + M)
        align_iq      = channels[0][search_start : search_end]
        fine_idx      = align_to_symbol(align_iq, M, search_window)
        start         = search_start + fine_idx
        fine_offset   = start - onset
        print(f"  Fine alignment: onset={onset}  best_start={start}  offset={fine_offset:+d}")

        remaining = n_min - start
        if remaining < (N_PREAMBLE + N_SYNC_SKIP + 1) * M:
            print("  Skipping — not enough samples after onset.")
            continue

        # Per-channel decode (CFO + h_hat)
        per_channel = []
        h_hats      = []
        for j in range(NR):
            ch_iq = channels[j][start:]
            info  = decode_packet(ch_iq, SF, n_payload_syms=0, channel_idx=j)
            per_channel.append(info)
            h_hats.append(info["h_hat"][0])

        h_hat_all = np.array(h_hats)   # shape (NR,)

        # MRC combining (or single-antenna passthrough)
        # Use oracle N0 estimate from preamble correlation residual
        preamble_power = np.mean([np.mean(np.abs(channels[j][start:start+N_PREAMBLE*M])**2)
                                   for j in range(NR)])
        signal_power   = np.sum(np.abs(h_hat_all)**2)
        N0_est         = max(preamble_power - signal_power, 1e-6)

        phi, c = compute_weights(h_hat_all, N0_est)

        print(f"\n  MRC weights (NR={NR}):")
        for j in range(NR):
            print(
                f"    ant {j}: |h_hat|={abs(h_hat_all[j]):.4f}  "
                f"φ={np.degrees(phi[j]):+6.1f}°  c={c[j]:.4f}"
            )

        # Decode payload with MRC combining
        payload_start_sample = start + (N_PREAMBLE + N_SYNC_SKIP) * M
        n_syms = n_payload_syms or ((n_min - payload_start_sample) // M)

        payload_symbols = []
        for k in range(n_syms):
            sym_start = payload_start_sample + k * M
            sym_end   = sym_start + M
            if sym_end > n_min:
                break
            rx_sym = np.stack([channels[j][sym_start:sym_end] for j in range(NR)])
            y      = mrc_combine(rx_sym, phi, c)
            payload_symbols.append(demodulate(y))

        print(f"\n  Decoded {len(payload_symbols)} symbol(s): {payload_symbols}")
        if payload_symbols:
            print(f"  As bytes (SF=7, mod 256): {bytes(s % 256 for s in payload_symbols).hex()}")

        results.append({
            "onset"          : onset,
            "fine_offset"    : fine_offset,
            "h_hat"          : h_hat_all,
            "phi_deg"        : np.degrees(phi),
            "mrc_weights"    : c,
            "N0_est"         : N0_est,
            "payload_symbols": payload_symbols,
            "per_channel"    : per_channel,
        })

    return results


# ---------------------------------------------------------------------------
# CLI
# ---------------------------------------------------------------------------

def main():
    parser = argparse.ArgumentParser(
        description="Decode LoRa IQ captures through the MRC DSP chain."
    )
    parser.add_argument("captures", nargs="+",
                        help="IQ capture file(s). Multiple files = NR antennas.")
    parser.add_argument("--fs",   type=float, required=True,
                        help="Capture sample rate in Hz (e.g. 250e3, 1e6)")
    parser.add_argument("--sf",   type=int,   default=7,
                        help="LoRa spreading factor (default 7)")
    parser.add_argument("--bw",   type=float, default=125e3,
                        help="LoRa bandwidth in Hz (default 125000)")
    parser.add_argument("--n-payload", type=int, default=0,
                        help="Payload symbols to decode (0 = all)")
    parser.add_argument("--threshold", type=float, default=4.0,
                        help="Energy detection threshold factor (default 4.0)")
    args = parser.parse_args()

    process_capture(
        paths            = args.captures,
        fs               = args.fs,
        SF               = args.sf,
        bw               = args.bw,
        n_payload_syms   = args.n_payload,
        threshold_factor = args.threshold,
    )


if __name__ == "__main__":
    main()
