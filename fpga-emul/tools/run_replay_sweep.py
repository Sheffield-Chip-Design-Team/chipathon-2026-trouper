#!/usr/bin/env python3
"""Upload one captured LoRa window and run the FPGA replay envelope.

The existing UDP 5007 live injector is intentionally not used here: replay is
locally paced at 500 ksample/s after this script preloads BRAM over UDP 5008.
"""
import argparse, csv, math, socket, struct, time
from pathlib import Path
import numpy as np
from scipy.signal import resample_poly

MAGIC = b"CTLR"
CMD_UPLOAD, CMD_CONFIG, CMD_START, CMD_SET_DEBUG = 7, 8, 9, 11
FS_REPLAY, MAX_SAMPLES = 500_000, 16_384

def send(sock, host, cmd, body=b""):
    sock.sendto(MAGIC + bytes([cmd]) + body, (host, 5008))

def load_capture(path, n, source_rate, capture_start=None):
    x = np.load(path)
    if not np.iscomplexobj(x):
        x = x[:, 0] + 1j*x[:, 1] if x.ndim == 2 else x[0::2] + 1j*x[1::2]
    if source_rate <= 0:
        raise ValueError("source rate must be positive")
    # Keep one deterministic, anti-aliased reference for every sweep point.
    # A captured BW250 signal is close to the 500 ksample/s Nyquist edge, so
    # linear interpolation is not adequate for an acquisition measurement.
    if source_rate != FS_REPLAY:
        from fractions import Fraction
        ratio = Fraction(FS_REPLAY / source_rate).limit_denominator()
        x = resample_poly(x, ratio.numerator, ratio.denominator).astype(np.complex64)
    if len(x) < n:
        raise ValueError("capture shorter than requested replay window")
    # Capture files include idle time. Select the maximum-energy contiguous
    # replay window so the envelope measures a LoRa burst, not arbitrary
    # pre-trigger noise. The cumulative sum keeps this O(number of samples).
    if capture_start is None:
        power = np.abs(x) ** 2
        cumulative = np.concatenate(([0.0], np.cumsum(power, dtype=np.float64)))
        start = int(np.argmax(cumulative[n:] - cumulative[:-n]))
    else:
        start = capture_start
        if not 0 <= start <= len(x) - n:
            raise ValueError("--capture-start does not leave a complete replay window")
    x = x[start:start+n].astype(np.complex64)
    peak = np.percentile(np.abs(x), 99.5)
    if peak == 0: raise ValueError("capture contains no signal")
    x = np.clip(x * (64.0 / peak), -127, 127)
    return np.stack((np.rint(x.real), np.rint(x.imag)), axis=1).astype(np.int8), start

def q15(gain_db, phase_deg):
    gain = 10 ** (gain_db / 20.0)
    ph = math.radians(phase_deg)
    return int(round(32767*gain*math.cos(ph))), int(round(32767*gain*math.sin(ph)))

def upload(sock, host, iq):
    for addr in range(0, len(iq), 128):
        block = iq[addr:addr+128].astype(np.uint8).tobytes()
        send(sock, host, CMD_UPLOAD, struct.pack(">HB", addr, len(block)//2) + block)
        # EthernetLite provides a single receive buffer; leave firmware time
        # to drain each datagram rather than silently losing capture chunks.
        time.sleep(0.002)

def configure(sock, host, length, seed, gain_db, phase_deg, noise):
    # Q1.15 tops out just below 0 dB.  Normalize the four coefficients to
    # the strongest requested branch, which preserves the intended relative
    # 0/3/6 dB channel mismatch while keeping all coefficients representable.
    coeffs = [q15(-gain_db, 0)] + [q15(0, phase_deg)] * 3
    body = struct.pack(">HH", length, seed)
    body += b"".join(struct.pack(">hh", *c) for c in coeffs)
    body += bytes([noise] * 4)
    send(sock, host, CMD_CONFIG, body)

def drain(sock):
    sock.setblocking(False)
    try:
        while True: sock.recvfrom(2048)
    except BlockingIOError:
        pass
    finally:
        sock.setblocking(True)

def completion_status(sock, timeout_s):
    """Return post-replay fields from the firmware's completion snapshot."""
    sock.settimeout(timeout_s)
    end = time.monotonic() + timeout_s
    while time.monotonic() < end:
        try: data, _ = sock.recvfrom(2048)
        except socket.timeout: break
        # UDP header is 12 B, dsp_status_t is little-endian on MicroBlaze.
        # status offsets: sequence 0, packet/sc/irq/reserved 4..7,
        # W bank 8..23, zdiag 24..35, inj/replay status 36/40.
        if len(data) < 12 + 44 or data[:4] != b"LMIM" or data[4] != 2:
            continue
        st = data[12:]
        inj, replay = struct.unpack_from("<II", st, 36)
        if replay & 2:
            return dict(packet_status=st[4], sc_dbg_flags=st[5],
                        irq_status=st[6], inj_status=inj,
                        replay_status=replay,
                        w_bank_hex=st[8:24].hex(), zdiag_hex=st[24:36].hex())
    return dict(packet_status="", sc_dbg_flags="", irq_status="",
                inj_status="", replay_status="timeout", w_bank_hex="", zdiag_hex="")

def main():
    p = argparse.ArgumentParser()
    p.add_argument("capture", type=Path, help="complex .npy, or Nx2 / interleaved I/Q")
    p.add_argument("--host", default="192.168.10.2")
    p.add_argument("--samples", type=int, default=8192)
    p.add_argument("--source-rate", type=float, default=500_000,
                   help="input capture sample rate (default: 500000)")
    p.add_argument("--capture-start", type=int,
                   help="start index after resampling; use a guarded preamble window")
    p.add_argument("--settle-ms", type=float, default=50.0)
    p.add_argument("--snr-db", default="0,5,10,15,20",
                   help="comma-separated nominal SNR stress points in dB; negative values allowed")
    p.add_argument("--gain-db", default="0,3,6",
                   help="comma-separated branch-0 attenuation points in dB")
    p.add_argument("--phase-deg", default="0,30,60,90",
                   help="comma-separated phase offsets for branches 1..3")
    p.add_argument("--seeds", default="1-20",
                   help="comma-separated seeds and inclusive ranges, e.g. 1-20,37")
    p.add_argument("--max-conditions", type=int,
                   help="run only the first N envelope points (bring-up aid)")
    p.add_argument("--debug0", type=lambda s: int(s, 0),
                   help="DBG_CTRL0 byte for ILA/ASIC DBG0 (for example 0xB0 = SC hit)")
    p.add_argument("--debug1", type=lambda s: int(s, 0),
                   help="DBG_CTRL1 byte for ILA/ASIC DBG1 (for example 0xB0 = SC lock)")
    p.add_argument("--csv", type=Path, default=Path("replay_conditions.csv"))
    a = p.parse_args()
    if not 1 <= a.samples <= MAX_SAMPLES: p.error("--samples must fit replay BRAM")
    try:
        snr_points = [float(v.strip()) for v in a.snr_db.split(",") if v.strip()]
        gain_points = [float(v.strip()) for v in a.gain_db.split(",") if v.strip()]
        phase_points = [float(v.strip()) for v in a.phase_deg.split(",") if v.strip()]
        seed_points = []
        for token in (v.strip() for v in a.seeds.split(",") if v.strip()):
            if "-" in token[1:]:
                lo, hi = map(int, token.split("-", 1))
                seed_points.extend(range(lo, hi + 1))
            else:
                seed_points.append(int(token))
    except ValueError:
        p.error("invalid gain, phase, SNR, or seed list")
    if not snr_points or not gain_points or not phase_points or not seed_points:
        p.error("gain, phase, SNR, and seed lists must be non-empty")
    if any(s < 1 or s > 65535 for s in seed_points):
        p.error("seeds must be in 1..65535")
    iq, capture_start = load_capture(a.capture, a.samples, a.source_rate,
                                     a.capture_start)
    s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    s.bind(("0.0.0.0", 5006))
    if (a.debug0 is None) != (a.debug1 is None):
        p.error("--debug0 and --debug1 must be supplied together")
    if a.debug0 is not None:
        if not 0 <= a.debug0 <= 255 or not 0 <= a.debug1 <= 255:
            p.error("debug control bytes must fit in one byte")
        send(s, a.host, CMD_SET_DEBUG, bytes((a.debug0, a.debug1)))
        time.sleep(0.005)
    upload(s, a.host, iq)
    rows = []
    for gain in gain_points:
        for phase in phase_points:
            for snr in snr_points:
                # RTL noise scale is a deterministic approximate-Gaussian unit.
                # This conservative mapping is recorded so calibration can be
                # refined from measured status/weight results without ambiguity.
                noise = min(255, int(round(32 * 10 ** (-snr / 20))))
                for seed in seed_points:
                    if a.max_conditions is not None and len(rows) >= a.max_conditions:
                        break
                    configure(s, a.host, len(iq), seed, gain, phase, noise)
                    time.sleep(0.005)
                    drain(s)
                    send(s, a.host, CMD_START)
                    time.sleep(0.005)
                    result = completion_status(
                        s, len(iq) / FS_REPLAY + a.settle_ms / 1000 + 2.0)
                    rows.append(dict(capture_start=capture_start, gain_db=gain,
                                     phase_deg=phase, snr_db=snr, seed=seed,
                                     noise_scale=noise, **result))
    with a.csv.open("w", newline="") as f:
        w = csv.DictWriter(f, fieldnames=rows[0].keys()); w.writeheader(); w.writerows(rows)
    print(f"uploaded {len(iq)} samples from input index {capture_start}; "
          f"dispatched {len(rows)} replay conditions -> {a.csv}")

if __name__ == "__main__": main()
