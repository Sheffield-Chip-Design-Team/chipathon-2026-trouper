"""
remod_sx1302_compare.py — what does the SX1302 actually receive from Trouper,
compared with what it was designed to receive from an SX1257?

Three 1-bit, 32 MS/s complex streams are generated from the same baseband:

  sx1257_ref    float baseband, band-limited ×64 interpolation, 5th-order
                OSR=32 1-bit ΣΔ (sim/models/sx1257_adc_ref.py) — the SX1302's
                design-intent input. No int8 anywhere.
  legacy_ciff4  int8 @ 500 kS/s -> sd_remod 2026-09-05 core (effectively 2nd
                order, s3/s4 railed), bit-true.
  ciff3         int8 @ 500 kS/s -> sd_remod CIFF3 redesign, bit-true.

The SX1302's decimators/channelisers are undocumented, so each stream is
received through two float proxies (no int8 output rounding, so the stream's
own noise is visible):

  hb   CIC-3 R=16 -> HB1 ↓2 -> HB2 ↓2 (Trouper's own SX1257-stream decimator
       structure, sd_decimator_poly.v coefficients)
  cic  CIC-3 R=64 only — weak alias rejection, the stress case for shaped
       out-of-band noise folding into the channel

followed by a 255-tap FIR channel filter at ±BW/2.

Parts:
  A  stream PSD + integrated noise per frequency band (tone at amp 0.5)
  B  in-channel tone SNR through each proxy, BW 125/250 kHz
  C  LoRa symbol-error rate vs in-channel SNR, SF7/SF9 × BW125/250 (+ SF12
     sanity points), through both proxies, against an ideal float receiver

Run:  python3 -m sim.sims.remod_sx1302_compare [--parts ABC] [--workers N]
      [--quick]
Outputs: sim/plots/remod_sx1302_psd.png, sim/plots/remod_sx1302_ser.png and
         a JSON summary at sim/plots/remod_sx1302_compare.json.
"""
from __future__ import annotations

import argparse
import json
import os
import time
from concurrent.futures import ProcessPoolExecutor

import numpy as np
from scipy.signal import firwin, lfilter, welch, get_window

from sim.models.sd_remod import CIFF3, LEGACY_CIFF4, remodulate
from sim.models.sx1257_adc_ref import Sx1257AdcRef

FS_HI = 32e6
FS_BB = 500e3
OSR = 64
SOURCES = ("sx1257_ref", "legacy_ciff4", "ciff3")
PROXIES = ("hb", "cic")
HB1 = np.array([19, 0, -73, 0, 312, 512, 312, 0, -73, 0, 19]) / 1024
HB2 = np.array([-27, 0, 45, 0, -96, 0, 321, 512, 321, 0, -96, 0, 45, 0, -27]) / 1024
PLOTS = os.path.join(os.path.dirname(__file__), "..", "plots")

_REF = None


def _ref():
    global _REF
    if _REF is None:
        _REF = Sx1257AdcRef()
    return _REF


# --------------------------------------------------------------------------
# Streams
def interp64(bb: np.ndarray) -> np.ndarray:
    """Band-limited ×64 interpolation (FFT zero-pad). bb is periodic-safe
    because callers pad both ends with guard samples."""
    n = len(bb)
    X = np.fft.fft(bb)
    Y = np.zeros(n * OSR, dtype=complex)
    h = n // 2
    Y[:h] = X[:h]
    Y[-(n - h):] = X[h:]
    return np.fft.ifft(Y) * OSR


def make_stream(source: str, bb: np.ndarray) -> np.ndarray:
    """bb: complex float @ 500 kS/s, full scale ±1. Returns ±1±1j @ 32 MS/s."""
    if source == "sx1257_ref":
        return _ref().modulate(interp64(bb))
    cfg = {"legacy_ciff4": LEGACY_CIFF4, "ciff3": CIFF3}[source]
    return remodulate(bb * 127.0, cfg=cfg)


# --------------------------------------------------------------------------
# Receiver proxies (float)
def _cic3(x: np.ndarray, r: int) -> np.ndarray:
    k = np.ones(r)
    y = np.convolve(np.convolve(np.convolve(x, k), k), k)[: len(x)]
    return y[r - 1::r] / r ** 3


def proxy(name: str, stream: np.ndarray) -> np.ndarray:
    if name == "hb":
        y = _cic3(stream, 16)
        y = lfilter(HB1, 1, y)[1::2]
        return lfilter(HB2, 1, y)[1::2]
    if name == "cic":
        return _cic3(stream, 64)
    raise ValueError(name)


def channel_filter(x: np.ndarray, bw: float) -> np.ndarray:
    h = firwin(255, bw / 2 * 1.05, fs=FS_BB)
    return lfilter(h, 1, x)


# --------------------------------------------------------------------------
# Part A — stream PSD and band noise
BANDS = ((0, 125e3), (125e3, 250e3), (250e3, 500e3), (500e3, 1e6), (1e6, 2e6), (2e6, 4e6))


def part_a(amp=0.5, f_hz=20e3, n_bb=8192):
    k = round(f_hz * n_bb / FS_BB)
    f = k * FS_BB / n_bb
    t = np.arange(n_bb) / FS_BB
    bb = amp * np.exp(2j * np.pi * f * t)
    res, psd = {}, {}
    for s in SOURCES:
        y = make_stream(s, bb)[256 * OSR:]
        fr, P = welch(y, fs=FS_HI, window="blackmanharris", nperseg=1 << 16,
                      return_onesided=False, scaling="spectrum")
        fr, P = np.fft.fftshift(fr), np.fft.fftshift(P)
        tone = np.abs(fr - f) < 6 * FS_HI / (1 << 16)
        p_sig = P[tone].sum()
        rows = {}
        for lo, hi in BANDS:
            m = (np.abs(fr) >= lo) & (np.abs(fr) < hi) & ~tone
            rows[f"{lo/1e3:g}-{hi/1e3:g}k"] = 10 * np.log10(P[m].sum() / p_sig)
        res[s] = rows
        psd[s] = (fr, P / p_sig)
    return res, psd


# --------------------------------------------------------------------------
# Part B — in-channel tone SNR through proxies
def _tone_snr(y: np.ndarray, f: float, bw: float) -> float:
    n = len(y)
    w = get_window("blackmanharris", n)
    Y = np.abs(np.fft.fft(y * w)) ** 2
    fr = np.fft.fftfreq(n, 1 / FS_BB)
    tone = np.abs(fr - f) < 6 * FS_BB / n
    inb = (np.abs(fr) < bw / 2) & ~tone
    return 10 * np.log10(Y[tone].sum() / Y[inb].sum())


def part_b(amps=(0.1, 0.3, 0.5, 0.65), n_bb=8192):
    out = {}
    for bw in (125e3, 250e3):
        f = round(0.3 * bw / 2 * n_bb / FS_BB) * FS_BB / n_bb
        bb_ideal = None
        for amp in amps:
            t = np.arange(n_bb + 1024) / FS_BB
            bb = amp * np.exp(2j * np.pi * f * t)
            for s in SOURCES:
                y_hi = make_stream(s, bb)
                for p in PROXIES:
                    y = channel_filter(proxy(p, y_hi), bw)[1024:1024 + n_bb]
                    out.setdefault(f"bw{bw/1e3:g}k/{p}/{s}", {})[amp] = _tone_snr(y, f, bw)
            # ideal int8 reference (what Trouper is limited to before remod)
            q = np.round(bb * 127) / 127
            y = channel_filter(q, bw)[1024:1024 + n_bb]
            out.setdefault(f"bw{bw/1e3:g}k/int8_only", {})[amp] = _tone_snr(y, f, bw)
    return out


# --------------------------------------------------------------------------
# Part C — LoRa SER
def lora_packet(syms, sf, bw):
    os_ = int(FS_BB // bw)
    ns = 1 << sf
    n = ns * os_
    tt = np.arange(n) / os_                      # chip time
    out = []
    for s in syms:
        fchip = ((s + tt) % ns) / ns - 0.5       # cycles/chip, in [-0.5, 0.5)
        # Exclusive running sum: phase at sample k integrates f over samples
        # < k. An inclusive sum leaves the post-wrap part of the symbol offset
        # by pi/os per odd sample count -- a full pi flip at BW250 (os=2).
        ph = 2 * np.pi * (np.cumsum(fchip) - fchip) / os_
        out.append(np.exp(1j * ph))
    return np.concatenate(out)


def lora_demod(rx, nsym, sf, bw, delay):
    os_ = int(FS_BB // bw)
    ns = 1 << sf
    down = np.conj(lora_packet([0], sf, bw)[::os_])
    syms = []
    for i in range(nsym):
        seg = rx[delay + i * ns * os_: delay + (i + 1) * ns * os_: os_]
        syms.append(int(np.argmax(np.abs(np.fft.fft(seg * down)))))
    return np.array(syms)


GUARD = 1024


def _ser_task(args):
    sf, bw, snr_db, nsym, seed, level = args
    rng = np.random.default_rng(seed)
    ns = 1 << sf
    syms = rng.integers(0, ns, nsym)
    x = lora_packet(syms, sf, bw)
    # AWGN, in-channel SNR referenced to BW (noise is white over ±250 kHz)
    sig_p = 1.0
    nvar = sig_p / 10 ** (snr_db / 10) * (FS_BB / bw)
    noise = np.sqrt(nvar / 2) * (rng.standard_normal(len(x)) + 1j * rng.standard_normal(len(x)))
    bb = x + noise
    bb = np.r_[np.zeros(GUARD), bb, np.zeros(GUARD)]
    bb *= level / np.sqrt(np.mean(np.abs(bb[GUARD:-GUARD]) ** 2))   # AGC: total rms
    res = {}
    # ideal float receiver
    y = channel_filter(bb, bw)
    res["ideal"] = y
    for s in SOURCES:
        y_hi = make_stream(s, bb)
        for p in PROXIES:
            res[f"{p}/{s}"] = channel_filter(proxy(p, y_hi), bw)
    errs = {}
    for k, y in res.items():
        d = _DELAY[(k, bw)]
        errs[k] = int(np.sum(lora_demod(y, nsym, sf, bw, GUARD + d) != syms))
    return sf, bw, snr_db, nsym, errs


_DELAY = {}


def calibrate_delays():
    """Group delay (in 500 kS/s samples) of every receive path (source ×
    proxy, plus the ideal float path) from a clean chirp pair. Delay does not
    depend on SF, so SF7 calibrates every SF."""
    for bw in (125e3, 250e3):
        x = lora_packet([0, 5], 7, bw)
        bb = np.r_[np.zeros(GUARD), x, np.zeros(GUARD)] * 10 ** (-14 / 20)
        paths = {"ideal": channel_filter(bb, bw)}
        for s in SOURCES:
            y_hi = make_stream(s, bb)
            for p in PROXIES:
                paths[f"{p}/{s}"] = channel_filter(proxy(p, y_hi), bw)
        for key, y in paths.items():
            c = np.abs(np.correlate(y, bb, mode="full"))
            _DELAY[(key, bw)] = int(np.argmax(c) - (len(bb) - 1))


def part_c(workers, quick=False):
    calibrate_delays()
    grid = []
    plan = {7: (np.arange(-12, -3, 1.0), 400), 9: (np.arange(-17, -8, 1.0), 150)}
    if quick:
        plan = {7: (np.array([-10.0, -8.0]), 40)}
    seed = 1
    for sf, (snrs, nsym) in plan.items():
        for bw in (125e3, 250e3):
            # Bound each task to ~16k baseband samples (~1M stream clocks):
            # the bit-true models hold per-clock Python lists, and 50-symbol
            # SF9 packets OOM'd 16 workers in 8 GB (job 5819).
            chunk = max(1, 16384 // ((1 << sf) * int(FS_BB // bw)))
            for snr in snrs:
                left = nsym
                while left > 0:
                    k = min(chunk, left)
                    grid.append((sf, bw, float(snr), k, seed, 10 ** (-14 / 20)))
                    seed += 1
                    left -= k
    if not quick:
        for bw in (125e3, 250e3):         # SF12 sanity: clean + one noisy point
            for snr in (30.0, -24.0):
                for _ in range(8):        # one symbol per task (1M+ clocks)
                    grid.append((12, bw, snr, 1, seed, 10 ** (-14 / 20)))
                    seed += 1
    agg = {}
    with ProcessPoolExecutor(max_workers=workers, initializer=_init_worker,
                             initargs=(dict(_DELAY),)) as ex:
        for sf, bw, snr, nsym, errs in ex.map(_ser_task, grid):
            key = f"SF{sf}/BW{bw/1e3:g}k"
            row = agg.setdefault(key, {}).setdefault(snr, {"nsym": 0})
            row["nsym"] += nsym
            for k, e in errs.items():
                row[k] = row.get(k, 0) + e
    return agg


def _init_worker(delays):
    _DELAY.update(delays)


# --------------------------------------------------------------------------
def _plot_psd(psd, path):
    import matplotlib
    matplotlib.use("Agg")
    import matplotlib.pyplot as plt
    fig, ax = plt.subplots(figsize=(9, 5))
    for s, (fr, P) in psd.items():
        m = fr > 0
        ax.semilogx(fr[m], 10 * np.log10(P[m] + 1e-30), lw=0.8, label=s)
    for x in (62.5e3, 125e3, 250e3, 500e3):
        ax.axvline(x, color="0.7", lw=0.6, ls="--")
    ax.set_xlabel("frequency (Hz)")
    ax.set_ylabel("dBc per bin (BH window, 2^16 bins)")
    ax.set_title("1-bit stream PSD into SX1302 (tone 0.5 FS @ 20 kHz)")
    ax.set_xlim(2e3, 16e6)
    ax.set_ylim(-160, 5)
    ax.legend()
    ax.grid(alpha=0.3)
    fig.tight_layout()
    fig.savefig(path, dpi=130)


def _plot_ser(agg, path):
    import matplotlib
    matplotlib.use("Agg")
    import matplotlib.pyplot as plt
    keys = [k for k in agg if not k.startswith("SF12")]
    fig, axes = plt.subplots(1, len(keys), figsize=(4.2 * len(keys), 4), squeeze=False)
    for ax, key in zip(axes[0], keys):
        rows = agg[key]
        snrs = sorted(rows)
        paths = [p for p in rows[snrs[0]] if p != "nsym"]
        for p in paths:
            ser = [max(rows[s][p] / rows[s]["nsym"], 1e-4) for s in snrs]
            ax.semilogy(snrs, ser, marker="o", ms=3, lw=1, label=p)
        ax.set_title(key)
        ax.set_xlabel("in-channel SNR (dB)")
        ax.grid(alpha=0.3, which="both")
    axes[0][0].set_ylabel("symbol error rate")
    axes[0][-1].legend(fontsize=7)
    fig.tight_layout()
    fig.savefig(path, dpi=130)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--parts", default="ABC")
    ap.add_argument("--workers", type=int, default=os.cpu_count())
    ap.add_argument("--quick", action="store_true")
    ap.add_argument("--out", default=PLOTS)
    a = ap.parse_args()
    os.makedirs(a.out, exist_ok=True)
    summary = {}
    t0 = time.time()
    if "A" in a.parts:
        res, psd = part_a()
        summary["A_band_noise_dBc"] = res
        _plot_psd(psd, os.path.join(a.out, "remod_sx1302_psd.png"))
        print("A: integrated noise per band, dBc (tone 0.5 FS @ 20 kHz)")
        for s, rows in res.items():
            print(f"  {s:13s} " + "  ".join(f"{b}:{v:6.1f}" for b, v in rows.items()))
    if "B" in a.parts:
        res = part_b()
        summary["B_tone_snr_dB"] = res
        print("B: in-channel tone SNR (dB) by amplitude")
        for k, rows in res.items():
            print(f"  {k:30s} " + "  ".join(f"{amp}:{v:5.1f}" for amp, v in rows.items()))
    if "C" in a.parts:
        agg = part_c(a.workers, a.quick)
        summary["C_ser"] = {k: {str(s): r for s, r in v.items()} for k, v in agg.items()}
        _plot_ser(agg, os.path.join(a.out, "remod_sx1302_ser.png"))
        print("C: symbol errors / symbols")
        for key, rows in agg.items():
            for snr in sorted(rows):
                r = rows[snr]
                print(f"  {key:14s} {snr:6.1f} dB n={r['nsym']:4d} " +
                      " ".join(f"{p}:{r[p]}" for p in r if p != "nsym"))
    summary["elapsed_s"] = time.time() - t0
    with open(os.path.join(a.out, "remod_sx1302_compare.json"), "w") as f:
        json.dump(summary, f, indent=1, default=float)
    print(f"done in {summary['elapsed_s']:.0f}s")


if __name__ == "__main__":
    main()
