"""
iq_capture.py — turn a measured baseband IQ capture into the 1-bit ΣΔ
stimulus that trouper_top's decimator expects, and fan it out to 4 branches.

Pipeline (all numpy, scipy optional):

    .npy complex64 @ sr_in (e.g. 2 MS/s)
      -> resample to 32 MS/s            (16x for a 2 MS/s capture)
      -> per-branch fan-out: y = x + AWGN  (NR=4 from a single-antenna capture)
      -> 1st-order ΣΔ modulate I and Q independently -> 0/1 bitstreams

The ΣΔ loop mirrors sdm_driver() in test_trouper_top.py exactly (acc += x∓1
with x scaled to [-1, 1)), so the decimator sees the same kind of 1-bit input
it gets from the synthetic CW driver — just modulating real captured signal.

These helpers are pure data prep: they return numpy arrays. The cocotb test
(test_capture_playback.py) drives them onto IQ_DATA_I/Q one bit per IQ_CLK.
"""

import json
import os
import numpy as np

CHIP_RATE_HZ = 32_000_000   # decimator input rate (1-bit ΣΔ)


# ---------------------------------------------------------------------------
# Load
# ---------------------------------------------------------------------------

def load_capture(path):
    """Load a capture as complex64. Accepts .npy or raw uint8 .iq."""
    if path.endswith(".npy"):
        x = np.load(path)
    elif path.endswith(".iq"):
        raw = np.fromfile(path, dtype=np.uint8).astype(np.float32)
        iq = (raw - 127.5) / 127.5
        x = iq[0::2] + 1j * iq[1::2]
    else:
        raise ValueError(f"Unrecognised file type (need .npy or .iq): {path}")
    return x.astype(np.complex64)


def load_meta(path):
    """Best-effort load of the sibling .json metadata (sample_rate etc.)."""
    stem = path.rsplit(".", 1)[0]
    jp = stem + ".json"
    if os.path.exists(jp):
        with open(jp) as f:
            return json.load(f)
    return {}


# ---------------------------------------------------------------------------
# Resample to the 32 MS/s chip rate
# ---------------------------------------------------------------------------

def resample_to_chip_rate(x, sr_in, sr_out=CHIP_RATE_HZ):
    """Rational resample sr_in -> sr_out. Prefers scipy.resample_poly (good
    anti-image filter); falls back to linear interpolation if scipy is absent.

    Linear interp leaves images near multiples of sr_in; for a 2 MS/s capture
    the first image (~2 MHz) lands close to the CIC-3 R=16 null at 32M/16 = 2M,
    so it is largely decimated away. Use scipy for a cleaner stimulus.
    """
    from math import gcd
    g = gcd(int(sr_out), int(sr_in))
    up, down = int(sr_out) // g, int(sr_in) // g
    try:
        from scipy.signal import resample_poly
        yi = resample_poly(x.real.astype(np.float64), up, down)
        yq = resample_poly(x.imag.astype(np.float64), up, down)
        return (yi + 1j * yq).astype(np.complex64)
    except ImportError:
        n_out = int(round(len(x) * sr_out / sr_in))
        t_in = np.arange(len(x))
        t_out = np.arange(n_out) * (sr_in / sr_out)
        yi = np.interp(t_out, t_in, x.real)
        yq = np.interp(t_out, t_in, x.imag)
        return (yi + 1j * yq).astype(np.complex64)


# ---------------------------------------------------------------------------
# Per-antenna multipath channel (fractional delay + complex tap gains)
# ---------------------------------------------------------------------------
#
# A channel is a list of taps; each tap is (delay_samples, complex_gain) where
# delay_samples may be fractional (sub-sample, linear-interpolated) and the
# gain carries amplitude AND phase. NR=4 fan-out applies one independent
# channel per antenna. The noise floor (set by snr_db) is the SAME across all
# antennas, so a deeply-faded branch genuinely sees lower SNR — which is what
# makes MRC training do something.

def _frac_delay(x, d):
    """Delay complex x by d samples (d may be fractional), zero-filled edges."""
    if d == 0:
        return x.copy()
    n = len(x)
    src = np.arange(n) - d
    grid = np.arange(n)
    re = np.interp(src, grid, x.real, left=0.0, right=0.0)
    im = np.interp(src, grid, x.imag, left=0.0, right=0.0)
    return (re + 1j * im).astype(np.complex64)


def apply_channel(x, taps):
    """Sum of fractional-delayed, complex-weighted copies of x."""
    y = np.zeros(len(x), dtype=np.complex64)
    for d, g in taps:
        y = y + g * _frac_delay(x, d)
    return y


def make_channels(n_branches=4, *, model="awgn", n_taps=3,
                  delay_spread_ns=300.0, sample_rate=CHIP_RATE_HZ,
                  phases=None, gains_db=None, seed=0):
    """Build one channel (tap list) per antenna.

    model="awgn"/"flat" : single tap; optional per-antenna carrier phase
                          (phases=[rad,...]) — flat fading, tests phase tracking.
    model="rayleigh"    : n_taps taps at random delays in [0, delay_spread_ns]
                          with i.i.d. complex-Gaussian gains, power-normalised,
                          INDEPENDENT per antenna -> frequency-selective fading.

    gains_db : per-antenna large-scale gain (dB) applied on top of the (unit
               average power) small-scale fading. Use this to set a deliberate
               per-branch SNR ordering so MRC has stronger/weaker branches to
               weight — verified downstream via ZDIAG ordering.

    delay_spread_ns is converted to samples at sample_rate (32 MS/s -> 31.25 ns
    per sample, so a 300 ns spread ≈ 9.6 taps of resolution).
    """
    rng = np.random.default_rng(seed)
    spread_samp = delay_spread_ns * 1e-9 * sample_rate
    if phases is None:
        phases = [0.0] * n_branches
    if gains_db is None:
        gains_db = [0.0] * n_branches

    chans = []
    for b in range(n_branches):
        amp = (10.0 ** (gains_db[b] / 20.0)) * np.exp(1j * phases[b])
        if model in ("awgn", "flat", "none"):
            chans.append([(0.0, complex(amp))])
        elif model == "rayleigh":
            delays = np.sort(rng.uniform(0.0, spread_samp, size=n_taps))
            delays[0] = 0.0   # anchor first tap at 0 for a defined timing ref
            g = (rng.standard_normal(n_taps) + 1j * rng.standard_normal(n_taps))
            g /= np.sqrt(np.sum(np.abs(g) ** 2))   # unit total channel power
            g *= amp                                # per-antenna gain + phase
            chans.append(list(zip(delays.tolist(), g.astype(np.complex64).tolist())))
        else:
            raise ValueError(f"unknown channel model: {model}")
    return chans


def fan_out_branches(x, n_branches=4, snr_db=None, channels=None,
                     delays=None, seed=0):
    """Replicate one capture across n_branches through per-antenna channels,
    with a shared (per-antenna-independent realisation) AWGN floor.

    channels : list of tap lists (see make_channels). Takes precedence.
    delays   : legacy integer per-branch sample delay (used only if channels
               is None) — equivalent to a single unit tap at that delay.
    snr_db   : noise power vs the CLEAN input power, identical sigma on every
               branch so fading -> per-antenna SNR spread. None = noiseless.
    """
    rng = np.random.default_rng(seed)

    if channels is None:
        if delays is None:
            delays = [0] * n_branches
        channels = [[(float(delays[b]), 1.0 + 0j)] for b in range(n_branches)]
    assert len(channels) == n_branches

    if snr_db is None:
        sigma = 0.0
    else:
        p_ref = float(np.mean(np.abs(x) ** 2))   # clean reference power
        p_noise = p_ref / (10 ** (snr_db / 10.0))
        sigma = np.sqrt(p_noise / 2.0)           # per I/Q component

    n = len(x)
    out = []
    for b in range(n_branches):
        xb = apply_channel(x, channels[b])
        if sigma > 0:
            w = (rng.standard_normal(n) + 1j * rng.standard_normal(n))
            xb = xb + (sigma * w).astype(np.complex64)
        out.append(xb.astype(np.complex64))
    return out


# ---------------------------------------------------------------------------
# 1st-order ΣΔ modulation (matches sdm_driver in test_trouper_top.py)
# ---------------------------------------------------------------------------

def sigma_delta_1bit(x_complex, scale):
    """Modulate a complex baseband stream to two 0/1 bitstreams (I and Q).

    `scale` multiplies the input into the ΣΔ's [-1, 1) range and MUST be common
    across all branches so per-antenna power differences are preserved (a
    per-branch peak normalisation would erase exactly the SNR ordering MRC
    needs). The loop is the float form of sdm_driver's integer acc += x ∓ 127.
    Returns (bits_i, bits_q) as uint8 arrays of 0/1, same length as input.
    """
    xi = np.asarray(x_complex.real, dtype=np.float64) * scale
    xq = np.asarray(x_complex.imag, dtype=np.float64) * scale

    n = len(xi)
    bi = np.empty(n, dtype=np.uint8)
    bq = np.empty(n, dtype=np.uint8)
    acc_i = acc_q = 0.0
    for k in range(n):
        if acc_i >= 0.0:
            bi[k] = 1; acc_i += xi[k] - 1.0
        else:
            bi[k] = 0; acc_i += xi[k] + 1.0
        if acc_q >= 0.0:
            bq[k] = 1; acc_q += xq[k] - 1.0
        else:
            bq[k] = 0; acc_q += xq[k] + 1.0
    return bi, bq


# ---------------------------------------------------------------------------
# One-call convenience
# ---------------------------------------------------------------------------

def prepare_stimulus(npy_path, *, start=0, nsamp=None, n_branches=4,
                     snr_db=None, seed=0,
                     channel="awgn", n_taps=3, delay_spread_ns=300.0,
                     phases=None, gains_db=None, full_scale=0.95):
    """Load -> clip -> resample -> per-antenna channel -> ΣΔ.  Returns:
        bits_i, bits_q : uint8 arrays shape (n_branches, N32) of 0/1 at 32 MS/s
        meta           : capture .json dict (for sample_rate, label, ...)

    channel="awgn"     : flat copies + per-antenna phase (phases=[rad,...])
    channel="rayleigh" : independent frequency-selective multipath per antenna
    gains_db           : per-antenna large-scale gain -> deliberate SNR ordering.

    A SINGLE ΣΔ scale (full_scale / global peak across all branches) is used so
    relative per-antenna power survives into the 1-bit streams.

    Also returns branch_power: the actual realised mean |x|² per branch (after
    channel + noise). Under frequency-selective fading this is NOT the nominal
    gains_db ordering — it is what the chip actually receives, so it is the
    correct reference for a ZDIAG-ranking check.
    """
    meta = load_meta(npy_path)
    sr_in = float(meta.get("sample_rate_sps", 2_000_000))

    x = load_capture(npy_path)
    if nsamp is not None:
        x = x[start:start + nsamp]
    else:
        x = x[start:]

    x32 = resample_to_chip_rate(x, sr_in)
    channels = make_channels(n_branches, model=channel, n_taps=n_taps,
                             delay_spread_ns=delay_spread_ns,
                             sample_rate=CHIP_RATE_HZ, phases=phases,
                             gains_db=gains_db, seed=seed)
    branches = fan_out_branches(x32, n_branches, snr_db,
                                channels=channels, seed=seed)

    # Common scale across ALL branches -> preserves per-antenna power ordering.
    global_peak = max(
        max(float(np.max(np.abs(xb.real))), float(np.max(np.abs(xb.imag))))
        for xb in branches)
    scale = full_scale / max(global_peak, 1e-12)

    branch_power = [float(np.mean(np.abs(xb) ** 2)) for xb in branches]

    bits_i = np.empty((n_branches, len(x32)), dtype=np.uint8)
    bits_q = np.empty((n_branches, len(x32)), dtype=np.uint8)
    for b, xb in enumerate(branches):
        bi, bq = sigma_delta_1bit(xb, scale)
        bits_i[b] = bi
        bits_q[b] = bq
    return bits_i, bits_q, meta, branch_power
