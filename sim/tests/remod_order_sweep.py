"""
remod_order_sweep.py — 2nd- vs 3rd-order CIFF sd_remod comparison at OSR=64.

Answers the B3 area-cut question (planning/area-reduction-roadmap.md §7): does a
2nd-order re-modulator still clear the design's noise/stability requirements at
the deployed OSR=64 operating point? order=3 is the deployed sd_remod.v; order=2
is NOT in RTL — this is a feasibility check only, mirroring the methodology of
sim/notebooks/14_sd_remod.ipynb (NTF shaping, stability boundary, full SF/BW
loopback, integrator headroom) for both orders side by side.

Run: python3 -m sim.tests.remod_order_sweep
"""
import numpy as np
from scipy.signal import welch

from sim.models.converter import SigmaDeltaRemodulator
from sim.models.decimator import FS_ADC, FS_OUT, sample_shift_for_bw, SUPPORTED_BW
from sim.models.lora import modulate, demodulate

OSR = int(FS_ADC / FS_OUT)
MINUS_3DBFS = 10 ** (-3 / 20)

# int8 quantisation noise floor at the remod's output amplitude convention
# (roadmap §7 B3 claim: "int8 input is ~50 dB floor"). 8-bit signed full-scale
# SNR = 6.02*8 + 1.76 ~= 49.9 dB.
INT8_FLOOR_DB = 6.02 * 8 + 1.76


def remod_upsampled(x_baseband: np.ndarray, order: int) -> np.ndarray:
    x_hi = np.repeat(x_baseband, OSR)
    remod = SigmaDeltaRemodulator(order=order)
    return remod.process_block(x_hi)


def brickwall_lp_decim(y_hi: np.ndarray, cutoff_hz: float, fs: float, osr: int) -> np.ndarray:
    n = len(y_hi)
    Y = np.fft.fft(y_hi)
    freqs = np.fft.fftfreq(n, 1 / fs)
    Y[np.abs(freqs) > cutoff_hz] = 0
    return np.fft.ifft(Y)[::osr]


def measure_sqnr(amp: float, order: int, f_hz: float = 40e3, n: int = 4096, edge: int = 200) -> float:
    t = np.arange(n) / FS_OUT
    tone = amp * np.exp(1j * 2 * np.pi * f_hz * t)
    y = remod_upsampled(tone, order)
    y_rec = brickwall_lp_decim(y, FS_OUT / 2, FS_ADC, OSR)
    seg = slice(edge, -edge)
    g = np.vdot(tone[seg], y_rec[seg]) / np.vdot(tone[seg], tone[seg])
    resid = y_rec[seg] - g * tone[seg]
    return 10 * np.log10(np.mean(np.abs(g * tone[seg]) ** 2) / np.mean(np.abs(resid) ** 2))


def section_ntf_shaping(order: int) -> float:
    n = 8192
    t = np.arange(n) / FS_OUT
    tone = 0.1 * np.exp(1j * 2 * np.pi * 30e3 * t)
    y = remod_upsampled(tone, order)
    f, Pxx = welch(y.real, fs=FS_ADC, nperseg=16384)
    idx_lo = np.argmin(np.abs(f - 10e3))
    idx_hi = np.argmin(np.abs(f - 15.9e6))
    return 10 * np.log10(Pxx[idx_hi] / Pxx[idx_lo])


def section_stability(order: int):
    amps = np.array([0.1, 0.2, 0.3, 0.4, 0.5, 0.6, 0.65, 0.7, 0.72, 0.74, 0.76,
                      0.78, 0.8, 0.82, 0.84, 0.86, 0.88, 0.9, 0.95, 1.0])
    sqnr_db = np.array([measure_sqnr(a, order) for a in amps])
    # Low amplitudes are quantization-noise-dominated (SQNR ramps up with signal
    # power, not a stability effect) — search for the collapse only *after* the
    # peak, not from the start, so the ramp-up region can't be mistaken for a cliff.
    peak_idx = int(np.argmax(sqnr_db))
    peak_sqnr = sqnr_db[peak_idx]
    tail = sqnr_db[peak_idx:]
    collapsed = np.where(tail < peak_sqnr - 6)[0]
    cliff_amp = amps[peak_idx + collapsed[0]] if len(collapsed) else amps[-1]
    margin_db = 20 * np.log10(cliff_amp / MINUS_3DBFS)
    return peak_sqnr, cliff_amp, margin_db, amps, sqnr_db


def section_loopback(order: int, amp: float = 0.5) -> bool:
    rng = np.random.default_rng(0)
    all_match = True
    for sf in range(7, 13):
        for bw in SUPPORTED_BW:
            shift = sample_shift_for_bw(bw)
            M = 1 << (sf + shift)
            b_tx = int(rng.integers(0, M))
            s = modulate(b_tx, M)
            s = s / np.max(np.abs(s)) * amp
            y = remod_upsampled(s, order)
            y_rec = brickwall_lp_decim(y, FS_OUT / 2, FS_ADC, OSR)
            b_rx = demodulate(y_rec)
            all_match &= (b_tx == b_rx)
    return all_match


def section_headroom(order: int, amp: float = 0.5) -> float:
    sf, bw = 9, 250e3
    shift = sample_shift_for_bw(bw)
    M = 1 << (sf + shift)
    s = modulate(0, M)
    s = s / np.max(np.abs(s)) * amp
    x_hi = np.repeat(s, OSR)
    remod = SigmaDeltaRemodulator(order=order)
    peak = 0.0
    for x in x_hi:
        remod.process(x)
        peak = max(peak, max(abs(v) for v in remod._s))
    return peak / SigmaDeltaRemodulator.CLIP  # fraction of saturation bound used


def main():
    print(f'OSR = {OSR}, int8 SNR floor (reference) = {INT8_FLOOR_DB:.1f} dB\n')
    results = {}
    for order in (3, 2):
        shaping_db = section_ntf_shaping(order)
        flat_sqnr, cliff_amp, margin_db, amps, sqnr_db = section_stability(order)
        loopback_ok = section_loopback(order)
        headroom_frac = section_headroom(order)
        sqnr_at_op = measure_sqnr(0.5, order)  # realistic deployed operating amplitude
        results[order] = dict(shaping_db=shaping_db, flat_sqnr=flat_sqnr,
                               cliff_amp=cliff_amp, margin_db=margin_db,
                               loopback_ok=loopback_ok, headroom_frac=headroom_frac,
                               sqnr_at_op=sqnr_at_op)

        print(f'=== order={order} ===')
        print(f'  NTF shaping rise (DC->Nyquist):   {shaping_db:6.1f} dB')
        print(f'  Peak-achievable SQNR (near cliff): {flat_sqnr:6.1f} dB')
        print(f'  SQNR at realistic op point (amp=0.5): {sqnr_at_op:6.1f} dB')
        print(f'  Stability cliff amplitude:         {cliff_amp:6.2f}  (margin over -3dBFS={MINUS_3DBFS:.3f}: {margin_db:+.1f} dB)')
        print(f'  Full SF7-12 x BW125/250 loopback:  {"PASS" if loopback_ok else "FAIL"} (amp=0.5)')
        print(f'  Integrator headroom used @0.5:     {headroom_frac*100:5.1f}% of CLIP')
        print(f'  Clears int8 floor ({INT8_FLOOR_DB:.1f} dB) by (peak):      {flat_sqnr - INT8_FLOOR_DB:+.1f} dB')
        print(f'  Clears int8 floor ({INT8_FLOOR_DB:.1f} dB) by (amp=0.5):  {sqnr_at_op - INT8_FLOOR_DB:+.1f} dB')
        print()

    r2, r3 = results[2], results[3]
    print('=== Comparison: order=2 vs order=3 (deployed) ===')
    print(f'  Peak-SQNR delta (2 - 3):          {r2["flat_sqnr"] - r3["flat_sqnr"]:+.1f} dB')
    print(f'  Op-point SQNR delta (2 - 3):      {r2["sqnr_at_op"] - r3["sqnr_at_op"]:+.1f} dB')
    print(f'  Stability margin delta:           {r2["margin_db"] - r3["margin_db"]:+.1f} dB')
    print(f'  order=2 clears -3dBFS design point with margin: '
          f'{"YES" if r2["cliff_amp"] > MINUS_3DBFS else "NO"}')
    print(f'  order=2 clears int8 floor AT REALISTIC OP POINT (amp=0.5): '
          f'{"YES" if r2["sqnr_at_op"] > INT8_FLOOR_DB else "NO"} '
          f'({r2["sqnr_at_op"] - INT8_FLOOR_DB:+.1f} dB margin)')
    print(f'  order=2 full-pipeline loopback:   {"PASS" if r2["loopback_ok"] else "FAIL"}')


if __name__ == '__main__':
    main()
