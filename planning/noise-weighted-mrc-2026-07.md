# Noise-Weighted MRC — implementation record, 2026-07-26

Closes the modelling and verification half of Open Risks #23. Firmware C and a
runtime gating policy remain open (§7).

**Code:** `sim/models/weight_generation.py` (`NoiseFloorEstimator`),
`sim/models/training_accumulator.py` (float references),
`sim/models/eigvec_fw.py` (fixed-point),
`rtl-test/tb/test_weight_gen_spi_flow.py` (RTL end-to-end),
`sim/tests/test_noise_floor_estimator.py`, `sim/tests/test_eigvec_nw_fw.py`.

---

## 1. Why the eigenvector path needed this

`Z ≈ n_acc · (h·hᴴ + diag(σ²))`. The signal term is rank-1; noise is
uncorrelated between antennas so it lands **only on the diagonal**.

With **matched** branch noise the diagonal term is `σ²·I`. Since `(A + cI)` has
the same eigenvectors as `A`, the noise floor shifts eigenvalues but never
rotates the eigenvector — whitening is a no-op in direction. This is why the
earlier study using a *scalar* `N0·I` (`sims/compare_mrc_methods.py::_eigvec_nw`,
pre-2026-07-26) found no benefit: that form structurally cannot find one.

With **unequal** branch noise `diag(σ²)` is not a multiple of `I`.
`Z_kk = (|h_k|² + σ²_k)·n_acc`, so a noisy branch's diagonal is inflated and the
eigensolver cannot distinguish "strong signal" from "loud noise". It steers
toward the loudest branch — the inverse of what MRC should do.

Measured, identical channel on all four branches, ant0 10× noisier:

| | weights (normalised) |
|---|---|
| raw eigenvector | `[1.000, 0.023, 0.023, 0.023]` |
| pedestal subtraction | `[1.000, 1.000, 1.000, 1.000]` |
| full `D^-1/2` whitening | `[0.100, 1.000, 1.000, 1.000]` |
| optimum `D⁻¹h` | `[0.100, 1.000, 1.000, 1.000]` |

The raw eigenvector discards three good antennas.

**Why the legacy row-sum was immune.** `W_k = Σ_{l≠k} Z_kl` excludes the
diagonal by construction, so it never sees the pedestal. That explains the
otherwise surprising BER result where plain `eigvec` scored *worse* than legacy
`hw_mrc` under imbalance. The eigenvector path buys coherent use of all six
cross-correlations and pays with sensitivity to the diagonal it now consumes.

---

## 2. Three levels, and the distinction that matters

| level | function (float / fixed-point) | returns | optimal when |
|---|---|---|---|
| raw | `compute_eigvec_weights` / `compute_eigvec_fw` | `conj(h)` from biased Z | no noise |
| de-biased | `compute_eigvec_nw_weights` / `compute_eigvec_nw_fw` | `conj(h)` | noise **matched** |
| SNR-weighted | `compute_eigvec_snr_weights` / `compute_eigvec_snrw_fw` | `conj(D⁻¹h)` | noise **unequal** |

**De-biasing is not SNR weighting.** Subtracting `σ²_k·n_acc` from the diagonal
recovers `Z' ≈ n_acc·h·hᴴ`, whose principal eigenvector is `h` — the
*equal-noise* optimum. It removes the bias but never applies `1/σ²_k`.

True SNR weighting needs the similarity transform, not a subtraction: form
`D^-1/2 Z' D^-1/2`, take its principal eigenvector `ṽ`, map back with
`D^-1/2 ṽ = D⁻¹h`.

σ² source is existing hardware: `TACC_NOISE_TRIG` (0x1F) arms a signal-free
window between packets; `ZDIAG_k` (0x64–0x6F) then reads `≈ σ²_k·n_acc`.

---

## 3. Measured BER — unequal noise (ant0 +10 dB), SF6 NR=4

From `sim/notebooks/05_sw_vs_hw_weight_gen.ipynb` §5, N=2000:

| SNR | hw_mrc | sw_nw | eigvec | eigvec_nw | eigvec_snrw | ideal_mrc |
|---|---|---|---|---|---|---|
| −15 | 0.9225 | 0.7570 | 0.9705 | 0.9040 | **0.6150** | 0.6170 |
| −12 | 0.8120 | 0.5040 | 0.9635 | 0.7565 | **0.3155** | 0.4175 |
| −9 | 0.5850 | 0.2755 | 0.9060 | 0.4770 | **0.0920** | 0.1820 |
| −6 | 0.3065 | 0.1120 | 0.7890 | 0.2115 | **0.0150** | 0.0435 |
| −3 | 0.1425 | 0.0335 | 0.5690 | 0.0520 | **0.0035** | 0.0120 |

`eigvec_snrw` clears `sw_nw` (the row-sum path doing genuine `1/σ²` weighting)
by ~3× at −9 dB.

**It also beats `ideal_mrc`, and that is not an error.** This notebook's
`ideal_mrc` is a genie that knows `h` exactly but assumes *equal* noise
(`w = conj(h)`). Under 10 dB imbalance that is the wrong combiner. Estimating
`h` imperfectly while weighting by `1/σ²_k` wins. The honest bound for the
unequal-noise case would be `conj(D⁻¹h)`; the notebook's label is only a bound
for the matched-noise case.

**Fixed-point costs nothing measurable** (N=1500, measured σ² from a noise
window): `fw_snrw` tracks the float `eigvec_snrw` within run-to-run noise at
every SNR point (0.3167 vs 0.3087 at −12 dB, 0.0993 vs 0.0933 at −9 dB).

Caveat: SF6 is the notebook's fixed constant and is **out of scope** for the
chip (`SF_CFG` is 7–12). The shape should carry to SF7+; the absolute numbers
will not.

---

## 4. Fixed-point design (`eigvec_fw.py`)

Ordering matters on picorv32 (`ENABLE_MUL=1, ENABLE_FAST_MUL=0`:
**MUL = 40 cycles, MULH = 72 cycles**, `ip/picorv32/README.md`):

* Scaling the **raw** matrix needs `Z' (≤2^24) × gg (≤2^15) = 2^39` — a
  32×32→64 product. Available as MUL+MULH, but 112 cycles per entry.
* Scaling **after** the `>>sh` normalisation, entries are ≤2^12, so
  `2^12 × 2^15 = 2^27` fits int32: one 40-cycle MUL, **no MULH anywhere**.

Adopted the second ("A′"): `Z̃ = G Z' G` is built once from the already
normalised matrix, then the stock power iteration runs untouched — so its
existing int32 overflow proof still applies verbatim. One final `G` maps
`ṽ → D⁻¹h`.

| approach | multiplies | est. cycles | MULH |
|---|---|---|---|
| **A′ scale after normalise (adopted)** | 26 MUL | **~1040** | no |
| A scale raw matrix | 10 MUL + 16 (MUL+MULH) | ~2190 | yes |
| B fold G into each iteration | 136 MUL | ~5440 | no |

A′ and B measured **identically accurate** (0.1863° vs 0.1865° mean alignment
error over 300 channels); the win is purely cycles. `test_fp_snr_weighting_
needs_no_mulh` pins the int32 bound so a refactor cannot silently move the
scaling back before normalisation.

> Cycle figures are README per-instruction costs × multiply counts — **not
> measured, not compiled**. The existing 36.5k-cycle / 2.28 ms eigenvector
> budget came from a real measurement; A′ needs measuring the same way before
> the ~12% saving is quoted anywhere load-bearing.

---

## 5. `NoiseFloorEstimator` — repointed at ZDIAG

Was modelling a dead interface: polled free-running `ENERGY[0..3]`, removed with
`noise_est.v`. Now `update(zdiag, n_acc)` on the real policy — wait
`PACKET_ACTIVE=0`, write `TACC_NOISE_TRIG`, wait `NOISE_READY`, read
`ZDIAG`/`N_ACC`.

Integer throughout (Q`NFE_FRAC_BITS`, shift-and-add EMA, one `divu`), so it is
already the firmware-realisable form — no separate fixed-point version needed.

`estimate` is in **ZDIAG register units per sample**, deliberately the same
scale as the `Z_kl` pairs (both bits [31:8]), so `estimate * n_acc` subtracts
directly from a ZDIAG-scale diagonal with no alignment step.

### Q8 → Q16: σ² underflow on real capture data

SGE job 3593 measured `ZDIAG = [11, 7, 5, 4]` at `n_acc = 2048`, i.e.
σ² ≈ 0.0034 ZDIAG units/sample against a Q8 floor of 1/256 = 0.0039. **Three of
four branches floored to exactly zero.** The ΣΔ full scale is set by the packet
peak, so a quiet noise floor sits below one ZDIAG LSB.

A **partially** underflowed estimate is worse than not whitening: subtracting a
pedestal from only some branches fabricates an imbalance that was never
measured. Hence `NoiseFloorEstimator.valid` / `.underflow_mask`, and
`compute_eigvec_nw_fw(strict=True)` raising on that case.

**A longer noise window does NOT fix it** — σ² is the ratio `ZDIAG_k / n_acc`,
so lengthening scales both and leaves the fixed-point resolution untouched. Only
more fractional bits help. Default is now Q16, which resolves the job-3593 case
to `[0.005371, 0.003418, 0.002441, 0.001953]`, all four branches valid.
`test_longer_window_alone_does_NOT_fix_underflow` pins the trap.

Firmware note: `(zdiag << 16)` with a 24-bit ZDIAG reaches 2^40, so RV32IM needs
a 64-bit divide (`__udivdi3`). Alternative if that cost bites: carry the
pedestal directly as `ZDIAG_noise · n_acc_sig / n_acc_noise`, multiply first —
same precision, one 64/32 divide, no fractional state.

---

## 6. Verification

**Python:** 180 tests pass (`sim/tests/`), up from 146 at the start of this
work. New: `test_noise_floor_estimator.py` (19), `test_eigvec_nw_fw.py` (41).

**RTL end-to-end** (`rtl-test/cocotb_trouper_capture`, Verilator, real capture
`lora_20260619_144822_SF7-BW250-gain30.npy`, gains 0/−3/−6/−9 dB):

| job | test | result |
|---|---|---|
| 3593 | `_nw` (Q8 era) | PASS — first end-to-end noise-window flow |
| 3596 | `_nw` with validity gate | PASS, `valid=True`, combiner `max_err=0.00` |
| 3597 | original `test_weight_gen_spi_flow` | PASS — no regression |
| 3598 | `_snrw` | PASS, combiner `max_err=0.00` |

Job 3598 weight comparison on real silicon-model data:

```
rel |w_nw|   = [1.0000, 0.7093, 0.5016, 0.3552]   ∝ g (amplitude ratios)
rel |w_snrw| = [0.8553, 1.0000, 0.9887, 0.8751]   flattened
ant0/ant3 ratio:  nw 2.815 -> snrw 0.977          angle 21.9 deg
```

### The real capture's noise floor is quantisation-limited

Predicted `w_snrw ∝ 1/g` = `[0.354, 0.5, 0.707, 1.0]`, a full inversion of the
de-biased answer, because `gains_db` scales signal and noise together so all
branches carry equal SNR. **It flattened instead.** Measured
`ZDIAG_noise = [11, 7, 5, 4]` gives ratios `1 : 0.64 : 0.45 : 0.36` where
gain-proportional would be `1 : 0.5 : 0.25 : 0.125`.

At this signal scale the pre-packet region is mostly int8 0/±1, so ΣΔ and int8
**quantisation** noise dominates thermal noise and does not scale with LNA gain.
SNR weighting therefore lands between `∝g` and `∝1/g`.

**Consequence:** the on-silicon benefit depends on whether the branch noise
floor is thermal (scales with gain) or quantisation-limited (does not). That is
an AFE question — see `planning/AFE Characterisation Board.md`.

### Stimulus limitation

`iq_capture.fan_out_branches` applies "identical sigma on every branch"
(`iq_capture.py:165`); `gains_db` spreads per-antenna *SNR* but leaves the noise
floor common. **The capture harness cannot generate unequal per-branch noise
floors**, so "whitening improves reception" is not assertable in RTL without
extending `iq_capture` with per-branch noise. The RTL tests therefore verify
flow and arithmetic; BER is answered by the Python sweep.

---

## 7. Open

1. **Firmware C.** `firmware/picorv32/main.c:35` `compute_eigvec_weights_fw()`
   has no σ² handling; `main.c:140` defers noise-EMA policy to the host. The
   bit-true model exists, so this is a mechanical port.
2. **Gating policy.** With de-biasing alone, whitening cost slightly at matched
   noise (0.0435 → 0.0625 BER at −12 dB) so gating on measured imbalance
   mattered. With full SNR weighting the upside is far larger and the threshold
   is much less delicate — but no rule is implemented anywhere.
3. **Measure A′ cycles** on the real core; reconcile with the ~31 cycles/MUL
   figure in `planning/blocks/Eigenvector Weight Computation.md` and Open Risks
   #7, which the vendor README contradicts (40 for MUL, 72 for MULH). That
   independently makes the SF7 margin worse than currently written.
4. **Per-branch noise in `iq_capture`** so the RTL path can assert gain, not
   just plumbing.
5. **Re-run `sims/compare_mrc_methods.py`** — its stored "whitening adds
   nothing" table was produced with the scalar form.
