#!/usr/bin/env python3
"""
SQNR testbench runner for sd_decimator.

Steps:
  1. Generate sigma-delta stimulus (1-bit I/Q streams) from a known tone.
  2. Run rtl-test/tb_sqnr.v under iverilog+vvp (auto-detects local or Docker).
  3. Read RTL int8 output, measure SQNR via least-squares sine fit.
  4. Compare against Python model SQNR.  Pass if RTL SQNR >= MIN_SQNR_DB.

Usage (from lora-mimo/ root):
    python3 -m sim.sims.run_sqnr_tb
    python3 -m sim.sims.run_sqnr_tb --gen-only   # only write stim files
    python3 -m sim.sims.run_sqnr_tb --check-only # assume sim already ran
"""

import argparse
import os
import shutil
import subprocess
import sys
import numpy as np

sys.path.insert(0, os.path.join(os.path.dirname(__file__), "..", ".."))
from sim.models.decimator import SigmaDeltaDecimator

# ---------------------------------------------------------------------------
# Parameters — must match tb_sqnr.v
# ---------------------------------------------------------------------------
R          = 64          # decim_ratio = 2'd2 → 500 kHz BW
FS_ADC     = 32e6
FS_OUT     = FS_ADC / R  # 500 kHz
AMPLITUDE  = 0.35        # well within sigma-delta stability limit (< 1.0)
N_OUT      = 544         # output samples to generate
N_STIM     = N_OUT * R   # = 34816 input bits
# Test tone: FS_OUT / 16 = 31250 Hz → 32 complete cycles in 512 samples → clean FFT bin
F_TONE     = FS_OUT / 16
SKIP_N     = 20          # discard first N outputs (group delay + CIC startup)
MIN_SQNR   = 28.0        # dB — sanity floor; Python model gives ~34 dB at OSR=64.
                         # At OSR=64 the 1st-order ΣΔ noise floor (~37 dB) dominates
                         # over 8-bit quantisation noise (~39 dB) — 8 bits is fine.

REPO_ROOT  = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", ".."))
TB_DATA    = os.path.join(REPO_ROOT, "sim", "tb_data")
STIM_I     = os.path.join(TB_DATA, "stim_i.txt")
STIM_Q     = os.path.join(TB_DATA, "stim_q.txt")
RTL_OUT    = os.path.join(TB_DATA, "rtl_out.txt")
SIM_BIN    = os.path.join(TB_DATA, "tb_sqnr.vvp")

DOCKER_IMG = "hpretl/iic-osic-tools:chipathon26"
MOUNT_DST  = "/foss/designs/lora-mimo"


# ---------------------------------------------------------------------------
# Sigma-delta modulator (matches full_chain.py)
# ---------------------------------------------------------------------------
def sigma_delta_adc(x: np.ndarray) -> np.ndarray:
    """1st-order ΣΔ modulator. Input bounded |x| < 1. Returns ±1 complex."""
    out = np.empty(x.size, dtype=np.complex128)
    e_re, e_im = 0.0, 0.0
    for i in range(x.size):
        u = x.real[i] + e_re
        q = 1.0 if u >= 0.0 else -1.0
        e_re = u - q
        qr = q
        u = x.imag[i] + e_im
        q = 1.0 if u >= 0.0 else -1.0
        e_im = u - q
        out[i] = complex(qr, q)
    return out


# ---------------------------------------------------------------------------
# Step 1: generate stimulus + Python reference
# ---------------------------------------------------------------------------
def gen_stimulus():
    os.makedirs(TB_DATA, exist_ok=True)

    t_adc = np.arange(N_STIM) / FS_ADC
    sig   = AMPLITUDE * np.exp(2j * np.pi * F_TONE * t_adc)

    sd   = sigma_delta_adc(sig)
    bi   = (sd.real > 0).astype(np.int8)
    bq   = (sd.imag > 0).astype(np.int8)

    np.savetxt(STIM_I, bi, fmt="%d")
    np.savetxt(STIM_Q, bq, fmt="%d")
    print(f"[gen] wrote {N_STIM} bits → {STIM_I}")

    # Python model reference (ideal CIC + FIR + 8-bit, ±1 encoding).
    # NOTE: sd_decimator.v:71 uses bit=0 → -2 (not -1), giving 1.5× AC gain and
    # a -64 LSB DC bias vs this reference.  DC removal corrects the bias;
    # the gain difference means RTL amplitudes will be ~1.5× larger than ref.
    # SQNR should be similar in both since sigma-delta noise shapes the same way.
    dec   = SigmaDeltaDecimator(ratio=R, output_bits=8)
    ref   = dec.process(sd)          # float in [-1, 1]
    ref_i = np.clip(np.round(ref.real * 128), -128, 127).astype(np.int8)
    ref_q = np.clip(np.round(ref.imag * 128), -128, 127).astype(np.int8)
    return ref_i, ref_q


# ---------------------------------------------------------------------------
# Step 2: run simulation (iverilog + vvp)
# ---------------------------------------------------------------------------
def run_sim():
    tb_v   = "rtl-test/tb_sqnr.v"
    dec_v  = "rtl-test/sd_decimator.v"
    vvp    = "sim/tb_data/tb_sqnr.vvp"

    compile_cmd = ["iverilog", "-g2001", "-Wall", "-o", vvp, tb_v, dec_v]
    run_cmd     = ["vvp", vvp]

    if shutil.which("iverilog"):
        # Running directly (already inside container, or iverilog in PATH)
        print("[sim] iverilog found in PATH — running directly")
        _run(compile_cmd, cwd=REPO_ROOT)
        _run(run_cmd,     cwd=REPO_ROOT)
    else:
        # Wrap in Docker
        print(f"[sim] iverilog not found — running via Docker ({DOCKER_IMG})")
        inner = (
            f"cd {MOUNT_DST} && "
            f"iverilog -g2001 -Wall -o {vvp} {tb_v} {dec_v} && "
            f"vvp {vvp}"
        )
        docker_cmd = [
            "docker", "run", "--rm",
            "-v", f"{REPO_ROOT}:{MOUNT_DST}",
            DOCKER_IMG,
            "bash", "-c", inner,
        ]
        _run(docker_cmd)


def _run(cmd, cwd=None):
    print(f"[sim] $ {' '.join(cmd)}")
    r = subprocess.run(cmd, cwd=cwd)
    if r.returncode != 0:
        sys.exit(f"[sim] FAILED (exit {r.returncode})")


# ---------------------------------------------------------------------------
# Step 3: read RTL output
# ---------------------------------------------------------------------------
def read_rtl_output():
    if not os.path.exists(RTL_OUT):
        sys.exit(f"[check] {RTL_OUT} not found — did the simulation run?")
    data = np.loadtxt(RTL_OUT, dtype=np.int8)
    if data.ndim == 1:
        data = data.reshape(-1, 2)
    return data[:, 0], data[:, 1]


# ---------------------------------------------------------------------------
# Step 4: measure SQNR via least-squares sine fit at known frequency
# ---------------------------------------------------------------------------
def measure_sqnr(samples_i, samples_q):
    """
    Fit cos/sin at F_TONE to the captured output.
    Signal power = fitted tone amplitude^2 / 2.
    Noise power  = residual variance.
    """
    n  = len(samples_i)
    t  = np.arange(n) / FS_OUT
    c  = np.cos(2 * np.pi * F_TONE * t)
    s  = np.sin(2 * np.pi * F_TONE * t)
    A  = np.column_stack([c, s])

    results = {}
    for name, x in [("I", samples_i.astype(float)), ("Q", samples_q.astype(float))]:
        coeffs, *_ = np.linalg.lstsq(A, x, rcond=None)
        fitted     = A @ coeffs
        residual   = x - fitted
        sig_pwr    = np.mean(fitted ** 2)
        noise_pwr  = np.mean(residual ** 2)
        sqnr_db    = 10 * np.log10(sig_pwr / noise_pwr) if noise_pwr > 1e-12 else 99.0
        results[name] = (sqnr_db, coeffs)

    return results


# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
def main():
    p = argparse.ArgumentParser()
    p.add_argument("--gen-only",   action="store_true")
    p.add_argument("--check-only", action="store_true")
    args = p.parse_args()

    ref_i = ref_q = None
    if not args.check_only:
        ref_i, ref_q = gen_stimulus()

    if not args.gen_only:
        if not args.check_only:
            run_sim()

        rtl_i, rtl_q = read_rtl_output()
        # skip startup transient
        rtl_i = rtl_i[SKIP_N:]
        rtl_q = rtl_q[SKIP_N:]

        sqnr = measure_sqnr(rtl_i, rtl_q)

        print()
        print(f"  Test tone : {F_TONE/1e3:.3f} kHz   Amplitude : {AMPLITUDE}   R : {R}")
        print(f"  Output samples analysed : {len(rtl_i)}  (skipped first {SKIP_N})")
        print()

        passed = True
        for ch in ["I", "Q"]:
            db, coeffs = sqnr[ch]
            amp = np.hypot(*coeffs)
            ok  = db >= MIN_SQNR
            flag = "PASS" if ok else "FAIL"
            print(f"  [{flag}] {ch} channel  SQNR = {db:.1f} dB  "
                  f"(fitted amp = {amp:.1f} LSB,  threshold = {MIN_SQNR:.0f} dB)")
            if not ok:
                passed = False

        # Python model reference SQNR (for comparison)
        if ref_i is not None:
            py_sqnr = measure_sqnr(ref_i[SKIP_N:], ref_q[SKIP_N:])
            print()
            for ch in ["I", "Q"]:
                db, _ = py_sqnr[ch]
                print(f"  [ref]  Python model {ch}  SQNR = {db:.1f} dB")

        print()
        if passed:
            print("  RESULT: PASS — 8-bit quantisation noise is acceptable.")
        else:
            print("  RESULT: FAIL — SQNR below threshold; check RTL encoding.")
        print()
        sys.exit(0 if passed else 1)


if __name__ == "__main__":
    main()
