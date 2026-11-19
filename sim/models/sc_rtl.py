"""
Integer model of the deployed Schmidl-Cox detector's decision path
(src/frontend/sc_detector.v), for timing_ref / lock studies.

Unlike sim/models/sync.py:SchmidlCoxDetector (which slides every sample and
refines timing_ref to an energy plateau), the RTL evaluates once per symbol on
a free-running grid that starts at reset:

  * window w covers samples [w*M, (w+1)*M); `cur` is the selected antenna,
    `del` the same antenna M samples earlier (PSRAM write_ptr - M; zero before
    the stream starts)
  * per window: ci0 = Re sum(cur*conj(del)), cq0 = Im, E0cur, E0del, each
    snapshotted as sat13(acc >>> (sf + sample_shift + 2))
  * hit = E>0 && E[25:13] != 0 && (|c|^2 >> 1) >= sc_thr[11:0] * E[25:13],
    with E = E0cur*E0del and |c|^2 = ci0^2 + cq0^2
  * lock on the (sc_hits_req+1)-th consecutive hit; a miss resets the run
  * timing_ref = mark - (sc_hits_req+1)*M + 1, mark = 1-based sample count at
    the end of the locking window. In 0-based terms timing_ref - 1 is the
    first sample of the *first hit's* `cur` window.

Checked against the RTL by cocotb/sc_timing_golden.
"""
from __future__ import annotations

import numpy as np

SC_THR_RESET = 0x1CC        # reg_bank reset value (0x0C/0x0D)
SC_HITS_REQ_RESET = 2       # reg_bank reset value (0x0E): lock after 3 hits


def _sat13(v: int) -> int:
    return 4095 if v > 4095 else -4096 if v < -4096 else v


def sc_rtl_detect(x: np.ndarray, sf: int, sample_shift: int,
                  sc_thr: int = SC_THR_RESET, sc_hits_req: int = SC_HITS_REQ_RESET):
    """Run the SC_ANT_SEL branch `x` (complex, int8-valued, sample 0 = first
    sample after reset / sc_clr) through the RTL decision path.

    Returns (lock, timing_ref) with timing_ref in the RTL's own 1-based units
    (sample index of the timing reference = timing_ref - 1), or (False, None).
    """
    M = 1 << (sf + sample_shift)
    sh = sf + sample_shift + 2
    thr = sc_thr & 0xFFF
    xi = np.real(x).astype(np.int64)
    xq = np.imag(x).astype(np.int64)
    di = np.concatenate([np.zeros(M, np.int64), xi])[:len(xi)]
    dq = np.concatenate([np.zeros(M, np.int64), xq])[:len(xq)]
    hit_count = 0
    for w in range(len(xi) // M):
        s = slice(w * M, (w + 1) * M)
        ci = int(np.sum(xi[s] * di[s] + xq[s] * dq[s]))
        cq = int(np.sum(xq[s] * di[s] - xi[s] * dq[s]))
        ec = int(np.sum(xi[s] * xi[s] + xq[s] * xq[s]))
        ed = int(np.sum(di[s] * di[s] + dq[s] * dq[s]))
        eci, ecq, e0c, e0d = (_sat13(v >> sh) for v in (ci, cq, ec, ed))
        e = e0c * e0d
        e_slice = (e >> 13) & 0x1FFF
        hit = e > 0 and e_slice != 0 and ((eci * eci + ecq * ecq) >> 1) >= thr * e_slice
        if not hit:
            hit_count = 0
            continue
        if hit_count == sc_hits_req:
            mark = (w + 1) * M
            return True, mark - (sc_hits_req + 1) * M + 1
        hit_count += 1
    return False, None
