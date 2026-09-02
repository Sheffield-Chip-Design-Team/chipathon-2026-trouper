"""Unit tests for the Schmidl-Cox trigger model.

Run with: python3 -m sim.tests.test_sync
"""

import numpy as np
import pytest

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

    assert result.lock, "lock not asserted"
    assert result.timing_ref == prefix_len, f"timing_ref={result.timing_ref}, expected {prefix_len}"
    assert result.lock_sample == result.first_hit_candidate + 3 * M - 1, (
        f"lock_sample={result.lock_sample}"
    )


def test_cfo_immunity():
    print("\nTest 2 — CFO immunity")
    prefix_len = 19
    all_pass = True

    for cfo in [-0.35, 0.20, 0.49]:
        det = SchmidlCoxDetector(M, threshold=0.9, hits_req=2)
        result = det.detect(make_rx(prefix_len=prefix_len, n_preamble=8, cfo=cfo))
        assert result.lock, f"CFO={cfo:+.2f}: no lock"
        assert result.timing_ref == prefix_len, f"CFO={cfo:+.2f}: timing_ref={result.timing_ref}"
        assert result.peak_metric > 0.99, f"CFO={cfo:+.2f}: peak_metric={result.peak_metric:.4f}"


def test_hits_req_back_calculation():
    print("\nTest 3 — Hit-count back calculation")
    prefix_len = 11
    all_pass = True

    for hits_req in [1, 2, 3]:
        det = SchmidlCoxDetector(M, threshold=0.9, hits_req=hits_req)
        result = det.detect(make_rx(prefix_len=prefix_len, n_preamble=8))
        assert result.lock, f"hits_req={hits_req}: no lock"
        assert result.timing_ref == prefix_len, f"hits_req={hits_req}: timing_ref={result.timing_ref}"
        assert result.lock_sample == result.first_hit_candidate + (hits_req + 1) * M - 1, (
            f"hits_req={hits_req}: lock_sample={result.lock_sample}"
        )


def test_short_input():
    print("\nTest 4 — Short input")
    det = SchmidlCoxDetector(M, threshold=0.9, hits_req=2)
    rx = np.zeros((NR, 2 * M - 1), dtype=complex)
    result = det.detect(rx)

    assert not result.lock, "short input should not lock"
    assert result.timing_ref == 0
    assert result.lock_sample == 0
    assert result.metric.size == 0


def test_sc_antenna_selection_matches_single_branch_rtl():
    """SC_ANT_SEL (0x1B) selects one detector branch; it is not MRC."""
    prefix_len = 23
    rx = make_rx(prefix_len=prefix_len, n_preamble=8)
    # A deep fade on branch 0 must fail with reset-default SC selection.
    rx[0] = 0.0
    assert not SchmidlCoxDetector(M, threshold=0.9, hits_req=2, sc_ant_sel=0).detect(rx).lock

    # Selecting a healthy branch recovers the same timing reference.
    result = SchmidlCoxDetector(M, threshold=0.9, hits_req=2, sc_ant_sel=1).detect(rx)
    assert result.lock
    assert result.timing_ref == prefix_len


# ---------------------------------------------------------------------------
# SF sweep — SF=7..12
# ---------------------------------------------------------------------------

def _make_rx_sf(sf: int, prefix_len: int, n_preamble: int, cfo: float = 0.0,
                nr: int = 4, seed: int = 1) -> np.ndarray:
    """Noiseless multi-antenna preamble for an arbitrary SF."""
    M = 2 ** sf
    suffix_len = M
    tx = np.concatenate([
        np.zeros(prefix_len, dtype=complex),
        np.tile(upchirp(M), n_preamble),
        np.zeros(suffix_len, dtype=complex),
    ])
    n = np.arange(tx.size)
    cfo_rot = np.exp(1j * 2 * np.pi * cfo * n / M)
    rng = np.random.default_rng(seed)
    h = (rng.standard_normal(nr) + 1j * rng.standard_normal(nr)) / np.sqrt(2)
    return h[:, None] * tx[None, :] * cfo_rot[None, :]


@pytest.mark.parametrize("sf", [7, 8, 9, 10, 11, 12])
def test_lock_all_sf(sf):
    """SC detector locks and recovers correct timing_ref for SF=7..12."""
    M = 2 ** sf
    prefix_len = 3 * M + 17   # arbitrary non-M-aligned offset
    # Use 4 preamble symbols with hits_req=2 — minimal window, still reliable
    rx = _make_rx_sf(sf, prefix_len=prefix_len, n_preamble=4, nr=4)
    det = SchmidlCoxDetector(M, threshold=0.9, hits_req=2)
    result = det.detect(rx)
    assert result.lock, f"SF={sf}: no lock"
    assert result.timing_ref == prefix_len, (
        f"SF={sf}: timing_ref={result.timing_ref}, expected {prefix_len}"
    )
    assert result.lock_sample == result.first_hit_candidate + 3 * M - 1, (
        f"SF={sf}: lock_sample={result.lock_sample}"
    )


@pytest.mark.parametrize("sf", [7, 9, 12])
def test_cfo_immunity_sf(sf):
    """SC metric stays > 0.99 across ±0.35 bin CFO for SF=7, 9, 12."""
    M = 2 ** sf
    prefix_len = M
    for cfo in [-0.35, 0.20, 0.49]:
        rx = _make_rx_sf(sf, prefix_len=prefix_len, n_preamble=4, cfo=cfo)
        det = SchmidlCoxDetector(M, threshold=0.9, hits_req=2)
        result = det.detect(rx)
        assert result.lock, f"SF={sf} CFO={cfo:+.2f}: no lock"
        assert result.peak_metric > 0.99, (
            f"SF={sf} CFO={cfo:+.2f}: peak_metric={result.peak_metric:.4f}"
        )


@pytest.mark.parametrize("sf", [7, 10, 12])
def test_timing_ref_alignment_sf(sf):
    """timing_ref lands on prefix_len for several non-M-aligned offsets.

    prefix_len must be > 0.1*M so the SC metric at d=prefix_len-1 is clearly
    below the 0.9 threshold (metric = (M-k)/M < 0.9 requires k > 0.1*M).
    """
    M = 2 ** sf
    for prefix_len in [M // 2, M + 3, 2 * M + 7]:
        rx = _make_rx_sf(sf, prefix_len=prefix_len, n_preamble=4)
        det = SchmidlCoxDetector(M, threshold=0.9, hits_req=2)
        result = det.detect(rx)
        assert result.lock, f"SF={sf} prefix={prefix_len}: no lock"
        assert result.timing_ref == prefix_len, (
            f"SF={sf} prefix={prefix_len}: timing_ref={result.timing_ref}"
        )


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
