from dataclasses import dataclass

import numpy as np


@dataclass
class SchmidlCoxResult:
    """Trigger-stage Schmidl-Cox detection result."""

    lock: bool
    timing_ref: int
    lock_sample: int
    first_hit_candidate: int
    peak_index: int
    peak_metric: float
    phase_diag: float
    metric: np.ndarray
    hit_mask: np.ndarray


class SchmidlCoxDetector:
    """
    Stage 3 — Schmidl-Cox preamble trigger.

    The detector dechirps the input, forms the magnitude-squared SC statistic,
    and asserts `sc_lock` once `hits_req` consecutive symbol-pair checks pass
    threshold. The reported `timing_ref` is back-calculated to the candidate
    preamble start; SC phase is retained only as a diagnostic.

    Implementation note — dechirp-cancel equivalence
    -------------------------------------------------
    This model dechirps before forming the SC autocorrelation. The hardware
    implementation operates on raw samples WITHOUT dechirping. These are
    identical because for a constant-amplitude LoRa chirp:

        conj(chirp_ref[n mod M]) · chirp_ref[(n+M) mod M]
        = conj(exp(jπ(n%M)²/M)) · exp(jπ(n%M)²/M)   [since (n+M)%M = n%M]
        = 1

    The chirp reference cancels exactly in the M-lag product, so the SC
    statistic on dechirped samples equals that on raw samples. See
    planning/blocks/Correlator Bank.md for the full derivation.
    """
    def __init__(
        self,
        M: int,
        threshold: float = 0.9,
        hits_req: int = 2,
        energy_gate: bool = False,
        energy_threshold: float = 0.0,
    ):
        if hits_req < 1:
            raise ValueError("hits_req must be >= 1")

        self.M = M
        self.threshold = threshold
        self.hits_req = hits_req
        self.energy_gate = energy_gate
        self.energy_threshold = energy_threshold

    def detect(self, rx_signal: np.ndarray) -> SchmidlCoxResult:
        """
        rx_signal: (NR, L) complex array
        """
        NR, L = rx_signal.shape
        M = self.M

        max_start = L - 2 * M + 1
        if max_start <= 0:
            return SchmidlCoxResult(
                lock=False,
                timing_ref=0,
                lock_sample=0,
                first_hit_candidate=0,
                peak_index=0,
                peak_metric=0.0,
                phase_diag=0.0,
                metric=np.zeros(0),
                hit_mask=np.zeros(0, dtype=bool),
            )

        n = np.arange(L)
        downchirp = np.exp(-1j * np.pi * (n % M) ** 2 / M)
        dechirped = rx_signal * downchirp[np.newaxis, :]

        mag_sc = np.zeros(max_start)
        energy_ref = np.zeros(max_start)
        phase_diag_sc = np.zeros(max_start, dtype=complex)
        hit_mask = np.zeros(max_start, dtype=bool)
        threshold_sq = self.threshold ** 2

        for d in range(max_start):
            mag_sc_sum = 0.0
            energy_ref_sum = 0.0
            energy_sum = 0.0
            best_branch_mag = -1.0
            best_branch_sc = 0j

            for j in range(NR):
                seg1 = dechirped[j, d:d + M]
                seg2 = dechirped[j, d + M:d + 2 * M]

                sc_j = np.sum(seg1 * np.conj(seg2))
                e1_j = np.sum(np.abs(seg1) ** 2)
                e2_j = np.sum(np.abs(seg2) ** 2)

                sc_abs_sq = np.abs(sc_j) ** 2
                mag_sc_sum += sc_abs_sq
                energy_ref_sum += e1_j * e2_j
                energy_sum += e1_j + e2_j

                if sc_abs_sq > best_branch_mag:
                    best_branch_mag = sc_abs_sq
                    best_branch_sc = sc_j

            mag_sc[d] = mag_sc_sum
            energy_ref[d] = energy_ref_sum
            phase_diag_sc[d] = best_branch_sc

            if energy_ref[d] == 0.0:
                continue

            if self.energy_gate and energy_sum < self.energy_threshold:
                continue

            hit_mask[d] = mag_sc[d] >= threshold_sq * energy_ref[d]

        metric = np.divide(
            np.sqrt(mag_sc),
            np.sqrt(energy_ref),
            out=np.zeros_like(mag_sc),
            where=energy_ref > 0.0,
        )

        peak_index = int(np.argmax(metric))
        peak_metric = float(metric[peak_index])

        first_hit_candidate = 0
        lock = False
        for d in range(max_start):
            if d + (self.hits_req - 1) * M >= max_start:
                break
            if all(hit_mask[d + k * M] for k in range(self.hits_req)):
                first_hit_candidate = d
                lock = True
                break

        if lock:
            # The first threshold crossing occurs slightly before the true
            # preamble start because partially overlapping symbol pairs can
            # still exceed threshold.  Recover a start estimate by finding the
            # first full-energy point within one symbol after the first hit.
            search_stop = min(first_hit_candidate + M, max_start)
            search_energy = energy_ref[first_hit_candidate:search_stop]
            full_energy = np.max(search_energy)
            full_energy_idx = np.flatnonzero(search_energy >= 0.999 * full_energy)
            timing_ref = first_hit_candidate + int(full_energy_idx[0])
            lock_sample = first_hit_candidate + (self.hits_req + 1) * M - 1
            phase_diag = float(np.angle(phase_diag_sc[first_hit_candidate]))
        else:
            timing_ref = 0
            lock_sample = 0
            phase_diag = 0.0

        return SchmidlCoxResult(
            lock=lock,
            timing_ref=timing_ref,
            lock_sample=lock_sample,
            first_hit_candidate=first_hit_candidate,
            peak_index=peak_index,
            peak_metric=peak_metric,
            phase_diag=phase_diag,
            metric=metric,
            hit_mask=hit_mask,
        )


def resolve_sync(rx_preamble: np.ndarray, rx_sfd: np.ndarray, M: int, eps_sub: float):
    """
    Legacy offline helper for refining timing/CFO from preamble + SFD.

    The live receiver model now estimates `eps_sub` in Stage 4 via RCTSL.
    This helper remains for analysis notebooks that want to combine an
    external fractional-CFO estimate with upchirp/downchirp peak matching.
    """
    NR = rx_preamble.shape[0]
    ref_up = np.exp(-1j * np.pi * np.arange(M) ** 2 / M)
    ref_down = np.exp(1j * np.pi * np.arange(M) ** 2 / M)

    mag_up = np.zeros(M)
    for j in range(NR):
        mag_up += np.abs(np.fft.fft(rx_preamble[j] * ref_up))
    k_up = np.argmax(mag_up)

    mag_down = np.zeros(M)
    for j in range(NR):
        mag_down += np.abs(np.fft.fft(rx_sfd[j] * ref_down))
    k_down = np.argmax(mag_down)

    k_sum = (k_up + k_down) % M
    k_cfo_coarse = (k_sum / 2.0) % (M / 2.0)
    cand1 = k_cfo_coarse
    cand2 = k_cfo_coarse + M / 2.0

    if np.abs((cand1 % 1) - (eps_sub % 1)) < 0.25:
        k_cfo = np.floor(cand1) + eps_sub
    else:
        k_cfo = np.floor(cand2) + eps_sub

    n_off_rel = (k_up - k_cfo) % M
    if n_off_rel > M / 2:
        n_off_rel -= M

    return k_cfo, n_off_rel
