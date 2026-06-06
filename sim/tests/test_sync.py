"""Unit tests for the Schmidl-Cox trigger model.

Run with: python3 -m sim.tests.test_sync
"""

import numpy as np

from sim.models.lora import upchirp
from sim.models.sync import SchmidlCoxDetector


SF = 7
M = 2 ** SF
NR = 4
RNG = np.random.default_rng(0)


def make_rx(prefix_len: int, n_preamble: int, cfo: float = 0.0) -> np.ndarray:
    """Return a noiseless multi-antenna preamble with a programmable offset."""
    suffix_len = M
    tx = np.concatenate(
        [
            np.zeros(prefix_len, dtype=complex),
            np.tile(upchirp(M), n_preamble),
            np.zeros(suffix_len, dtype=complex),
        ]
    )

    n = np.arange(tx.size)
    cfo_rot = np.exp(1j * 2 * np.pi * cfo * n / M)
    h = (RNG.standard_normal(NR) + 1j * RNG.standard_normal(NR)) / np.sqrt(2)
    return h[:, None] * tx[None, :] * cfo_rot[None, :]


def pass_fail(label: str, ok: bool):
    status = "PASS" if ok else "FAIL"
    print(f"  [{status}] {label}")
    return ok


def test_lock_and_timing_ref():
    print("\nTest 1 — Lock and timing_ref")
    prefix_len = 37
    det = SchmidlCoxDetector(M, threshold=0.9, hits_req=2)
    result = det.detect(make_rx(prefix_len=prefix_len, n_preamble=8))

    ok = True
    ok &= pass_fail("lock asserted", result.lock)
    ok &= pass_fail(
        f"timing_ref == prefix_len ({result.timing_ref})",
        result.timing_ref == prefix_len,
    )
    ok &= pass_fail(
        f"lock_sample follows first_hit_candidate ({result.lock_sample})",
        result.lock_sample == result.first_hit_candidate + 3 * M - 1,
    )
    return ok


def test_cfo_immunity():
    print("\nTest 2 — CFO immunity")
    prefix_len = 19
    all_pass = True

    for cfo in [-0.35, 0.20, 0.49]:
        det = SchmidlCoxDetector(M, threshold=0.9, hits_req=2)
        result = det.detect(make_rx(prefix_len=prefix_len, n_preamble=8, cfo=cfo))
        ok = result.lock and result.timing_ref == prefix_len and result.peak_metric > 0.99
        all_pass &= pass_fail(
            f"CFO={cfo:+.2f} bins  lock={result.lock} timing_ref={result.timing_ref} peak={result.peak_metric:.4f}",
            ok,
        )

    return all_pass


def test_hits_req_back_calculation():
    print("\nTest 3 — Hit-count back calculation")
    prefix_len = 11
    all_pass = True

    for hits_req in [1, 2, 3]:
        det = SchmidlCoxDetector(M, threshold=0.9, hits_req=hits_req)
        result = det.detect(make_rx(prefix_len=prefix_len, n_preamble=8))
        ok = (
            result.lock
            and result.timing_ref == prefix_len
            and result.lock_sample == result.first_hit_candidate + (hits_req + 1) * M - 1
        )
        all_pass &= pass_fail(
            f"hits_req={hits_req}  lock_sample={result.lock_sample}",
            ok,
        )

    return all_pass


def test_short_input():
    print("\nTest 4 — Short input")
    det = SchmidlCoxDetector(M, threshold=0.9, hits_req=2)
    rx = np.zeros((NR, 2 * M - 1), dtype=complex)
    result = det.detect(rx)

    ok = (
        not result.lock
        and result.timing_ref == 0
        and result.lock_sample == 0
        and result.metric.size == 0
    )
    return pass_fail("short input does not lock", ok)


def main():
    print(f"Schmidl-Cox trigger unit tests  (SF={SF}, M={M}, NR={NR})")
    results = [
        test_lock_and_timing_ref(),
        test_cfo_immunity(),
        test_hits_req_back_calculation(),
        test_short_input(),
    ]
    n_pass = sum(bool(r) for r in results)
    print(f"\n{n_pass}/{len(results)} test groups passed.")


if __name__ == "__main__":
    main()
