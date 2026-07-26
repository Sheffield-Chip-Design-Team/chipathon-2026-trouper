"""Re-derivation of the baseline preamble-truncation term in the SNR loss budget.

Spec-contradictions audit item 15 (2026-07-26). Run from the repo root:

    python3 -m sim.sims.truncation_loss_rederive

`training_acc.v` places its window at `[timing_ref, timing_ref +
TACC_WINDOW_SYMS*M - 1]` but accumulates forward from arming, and arming happens
at `sc_lock` — already `(SC_HITS_REQ + 1)*M` samples past `timing_ref`. With the
reset defaults (`TACC_WINDOW_SYMS = 8`, `SC_HITS_REQ = 2`) the first 3 symbols of
the window are in the past and are never accumulated, giving `n_acc = 5M - 1`.

`DSP Chain SNR Loss Budget.md` §6 previously booked -2.2 dB against that.
Two quantities were conflated:

  (A) training-SNR ratio       = 10log10(n_acc / (W*M))
      -- how much noisier the channel *estimate* is.
  (B) post-combining SNR loss  = 10log10(|w.h|^2 / (||w||^2 ||h||^2)),
      taken as the *increment* from the full window to the truncated one
      -- what the demodulator actually loses, and the only thing a chain
      SNR loss budget may sum.

(A) is -2.04 dB. (B) is at most about -0.5 dB, and only at the very bottom of
the operating range. The -2.2 dB itself came from the `5M -> 3M` row of the
late-lock table in `blocks/Training Accumulator.md` (10log10(3/5) = -2.2 dB),
which is a different step than 8M -> 5M.

Note on the combining-gain convention: `compute_eigvec_weights` /
`compute_eigvec_fw` return the *conjugate* of the principal eigenvector (that is
what `mrc_combiner.v` wants), so the matched-filter gain is |sum_k w_k h_k|^2 --
`np.dot(w, h)`, not `np.vdot`. Using vdot instead floors the measured loss at
about -4 dB even at high SNR and hides the effect being measured.
"""
import numpy as np

from sim.models.channel import rayleigh_coefficients
from sim.models.eigvec_fw import compute_eigvec_fw
from sim.models.lora import modulate
from sim.models.training_accumulator import (compute_eigvec_weights,
                                             training_accumulate_allpairs)

NR = 4
W_SYMS = 8      # tacc_window_syms reset default (reg_bank.v:186, clamped >= 8)
HITS = 2        # sc_hits_req reset default (reg_bank.v:170)

FLOAT_EST = lambda Z, n: compute_eigvec_weights(Z)
FW_EST = lambda Z, n: compute_eigvec_fw(Z, n)


def combining_loss_db(SF, snr_db, lock_syms, wfun, trials, seed):
    """Mean post-combining SNR loss vs an ideal matched filter, in dB."""
    M = 1 << SF
    tx = np.tile(modulate(0, M), W_SYMS)
    rng = np.random.default_rng(seed)
    N0 = 10 ** (-snr_db / 10)
    gains, ideal = [], []
    for _ in range(trials):
        h = rayleigh_coefficients(NR)
        noise = np.sqrt(N0 / 2) * (rng.standard_normal((NR, tx.size))
                                   + 1j * rng.standard_normal((NR, tx.size)))
        rx = h[:, None] * tx[None, :] + noise
        Z, _, n = training_accumulate_allpairs(
            rx, sc_lock_sample=lock_syms * M, timing_ref=0, M=M,
            preamble_len=W_SYMS)
        w = wfun(Z, n)
        gains.append(abs(np.dot(w, h)) ** 2 / max((np.abs(w) ** 2).sum(), 1e-30))
        ideal.append((np.abs(h) ** 2).sum())
    return 10 * np.log10(np.mean(gains) / np.mean(ideal))


def main():
    M = 1 << 7
    tx = np.tile(modulate(0, M), W_SYMS).reshape(1, -1).repeat(NR, 0)

    print("(A) window arithmetic")
    _, _, n_full = training_accumulate_allpairs(
        tx, sc_lock_sample=0, timing_ref=0, M=M, preamble_len=W_SYMS)
    _, _, n_base = training_accumulate_allpairs(
        tx, sc_lock_sample=(HITS + 1) * M, timing_ref=0, M=M,
        preamble_len=W_SYMS)
    print(f"    full window   n_acc = {n_full:5d}  ({n_full/M:.2f} symbols)")
    print(f"    baseline      n_acc = {n_base:5d}  ({n_base/M:.2f} symbols); "
          f"RTL gives (W-HITS-1)*M - 1 = {(W_SYMS-HITS-1)*M - 1}")
    print(f"    training-SNR ratio  = {10*np.log10(n_base/n_full):+.2f} dB "
          f"= 10log10(5/8)")

    print("\n(B) post-combining increment, SF7, 4000 Rayleigh trials/point")
    print("    per-ant SNR   full 8M     trunc 5M-1   increment")
    for snr in (-20, -16, -12, -6, 0, 6):
        a = combining_loss_db(7, snr, 0, FLOAT_EST, 4000, 7)
        b = combining_loss_db(7, snr, HITS + 1, FLOAT_EST, 4000, 7)
        print(f"      {snr:+4.0f} dB    {a:+7.3f} dB  {b:+7.3f} dB   {b-a:+7.3f} dB")

    print("\n    seed stability of the -16 dB increment (float estimator):")
    for seed in (7, 11, 23, 101):
        a = combining_loss_db(7, -16, 0, FLOAT_EST, 4000, seed)
        b = combining_loss_db(7, -16, HITS + 1, FLOAT_EST, 4000, seed)
        print(f"      seed {seed:>3}: {b-a:+.3f} dB")

    print("\n    SF dependence at -16 dB/antenna (n_acc scales with M):")
    for SF in (7, 9, 12):
        a = combining_loss_db(SF, -16, 0, FLOAT_EST, 600, 7)
        b = combining_loss_db(SF, -16, HITS + 1, FLOAT_EST, 600, 7)
        print(f"      SF{SF:<2} n_acc={5*(1<<SF):>6}: increment {b-a:+.3f} dB")

    print("\n    shipped fixed-point firmware path (compute_eigvec_fw, 8 iters), SF7:")
    for snr in (-20, -18, -16, -14, -12):
        a = combining_loss_db(7, snr, 0, FW_EST, 3000, 7)
        b = combining_loss_db(7, snr, HITS + 1, FW_EST, 3000, 7)
        print(f"      {snr:+3.0f} dB: full {a:+.3f}  trunc {b:+.3f}   "
              f"increment {b-a:+.3f} dB")


if __name__ == "__main__":
    main()
