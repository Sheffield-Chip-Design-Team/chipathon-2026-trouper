# sd_remod ΣΔ Re-modulator: 4th-Order Fix + STF Flatness Investigation (2026-09-04)

> **Status:** 4th-order fix (scale bug + excess-loop-delay coefficient re-derivation)
> IMPLEMENTED and verified. STF (signal transfer function) flatness at fs/4 is a
> known, unresolved residual issue — 5th-order exploration so far has NOT found a
> clean fix (see §6). Nothing in this doc has been committed to git — all changes
> are working-tree only pending explicit approval.

## 0. Trigger

A code review of `src/remod/sd_remod.v` found the feed-forward summer scaled the
direct error term `e_i` by ×8192 instead of ×256 (a stray `13'b0` shift instead of
`8'b0`), with the resulting 28-bit value silently truncated into a 27-bit wire.
This investigation started as a fix for that one bug and grew into a full
re-derivation of the loop-filter coefficients once the scale fix alone turned out
not to close the gap.

## 1. First bug: scale factor + width truncation

`v_i = {{2{e_i[12]}}, e_i, 13'b0} + w1_i + w2_i + w3_i` — the `13'b0` shift is
×8192 (2^13), not the ×256 (2^8) the code's own comment claimed, and the resulting
28-bit expression (`2+13+13`) was silently truncated into the 27-bit `v_i` wire
(Verilog drops the MSB on narrowing assignment, no warning). **Fixed**: shift
changed to `8'b0` with correct sign-extension width (`{{6{e_i[12]}}, e_i, 8'b0}`,
27 bits, matching `v_i`'s width exactly).

**Measured impact** (bit-exact iverilog sim on real RTL, job 5568 baseline / 5569
post-fix, amp=0.5 tone @ 40kHz):

| | SQNR |
|---|---|
| original (broken) RTL | 14.82 dB |
| scale-fix only | 20.14 dB |
| Python reference model (`sim/models/converter.py`, idealized) | 65.68 dB |
| spec (TRPR-RMD-005) | >40 dB |

The scale fix alone was necessary but far from sufficient — 20.14 dB is still
well short of both the model and the spec, which triggered the deeper
investigation below.

## 2. Root cause: excess loop delay

`converter.py`'s `SigmaDeltaRemodulator.process()` cascades integrator stages
using each stage's **just-updated** value within the same sample call (zero
extra loop delay). RTL's registered cascade — `s2_i_next = s2_i + s1_i` using
the **previous cycle's** registered `s1_i`, not a same-cycle value — is the
only physically realizable clocked-hardware topology (a same-cycle version would
require an unrealizable combinational loop through the quantizer's own feedback).
That register (`out_i <= q_i`, one cycle after `v_i` is computed) is a **full
extra sample of loop delay** beyond what each integrator already contributes.

Verified analytically (z-domain derivation, via `python-deltasigma`'s
`synthesizeNTF`, patched to run under Python 3.12/modern numpy — see §7):

- RTL's real (with-delay) closed-loop NTF: **H_inf ≈ 3.76** using the original
  `A1=205/A2=74/A3=11` coefficients.
- Same coefficients, idealized (no extra delay, i.e. what the coefficients were
  actually derived for): **H_inf ≈ 1.74** — right at the ~1.5 target
  `synthesizeNTF` uses by default.
- **Structural proof the gap isn't closable with 3 taps**: RTL's real
  with-delay NTF denominator has its top-2 coefficients fixed regardless of
  `A1/A2/A3` — the pole-sum is pinned at exactly 2. A well-conditioned 3rd-order
  NTF at OSR=64 needs pole-sum ≈2.20. Not achievable by any 3-tap coefficient
  choice, only approximable — and the best 3-tap approximation's real (nonlinear,
  bit-exact) stability cliff lands around amp≈0.55–0.6, short of the required
  −3 dBFS (amp=0.708) operating point.

## 3. Fix: 4th-order CIFF

Added a 4th integrator stage + tap (`s4_i`, `A4`), restoring the missing degree
of freedom. Verified: with a 4th coefficient, all four remaining denominator
coefficients become free (symbolic check) — full pole placement is achievable.

**Coefficient derivation**: 3 target poles from
`synthesizeNTF(order=3, osr=64, opt=0, H_inf=1.5)` (`0.765±0.279j, 0.669`) +
2 auxiliary "padding" poles (to fill the now-5-pole/degree-5 with-delay system),
chosen by a grid search over real bit-exact SQNR at the required amp=0.708
stability point (not just linear H_inf, which doesn't reliably predict the real
nonlinear cliff once excess loop delay is in play).

**Adopted coefficients**: `A1=377, A2=106, A3=-8, A4=-8` (Q8, i.e. `/256`).
Widened `A1..A4` from 9-bit to 10-bit signed (`A1=377` exceeds the old 9-bit
255 max).

**Verification** (all real RTL unless noted):

| check | result |
|---|---|
| SQNR @ amp=0.5, 40kHz (job 5570, iverilog) | 42.20 dB |
| Existing correlation testbench (job 5571) | PASS, correlation 0.9258 (was ~broken before) |
| Bit-exact Python replica vs real RTL | matched within ~2dB throughout |
| Randomized tone sweep, 300 trials, amp∈[0.3,0.708], f∈[1kHz,125kHz], real RTL via Verilator batch (job 5575) | min 39.75dB, mean 44.58dB, 1/300 below 40dB spec (natural low-amp/band-edge weak point, not a cliff) |
| LoRa chirp loopback, 200 trials, random SF7-12 × BW125/250 × random symbol × random amp, real RTL via Verilator (job 5575) | **200/200 pass** |
| Stability sweep (bit-exact, amp 0.3→0.78) | no cliff, monotonic-ish improvement with amplitude |
| Nonlinear stability at ±127 (full scale, outside the −3dBFS spec range) | output freezes ~8190/8192 cycles — expected, full scale was never a supported operating point (TRPR-RMD-004) |
| Core cocotb regression (job 5572) | 45/47 clean; 2 failures, see §4 |

Files changed: `src/remod/sd_remod.v` (primary), synced to `rtl-test/rtl/sd_remod.v`
per [[project_rtl_tree_divergence_fixed]].

## 4. Regression fallout

**`bringup_src` FAILED** — see §5 (STF gain, a real finding, not a test artifact).

**`remod_backoff` FAILED, then recalibrated.** The test forces a near-full-scale
combiner output and checks the quantizer's output measurably freezes with no
backoff (`STUCK_DEGRADED=120` cycles, calibrated in job 3293 against the *old*
3-tap RTL, which measured 167). The new 4th-order loop only produces a 54-cycle
stuck-run at the same forced condition — not a regression, a **direct,
expected consequence of the fix**: `REMOD_BACKOFF_SHIFT` existed largely to
paper over the old modulator's marginal stability near full scale, and the new
modulator doesn't degrade that way anymore. Backoff still helps measurably
(54 vs 5 cycles, ~10x), just at a much smaller absolute scale. Recalibrated
`STUCK_HEALTHY=20` / `STUCK_DEGRADED=35` against real post-fix measurements
(job 5572: low-amp both shifts = 3-4 cycles; shift=1 forced-saturation = 5
cycles; shift=0 forced-saturation = 54 cycles). File:
`cocotb/tests/test_remod_backoff.py`.

`bringup_src`'s OTHER failure mode in the same run (`test_amplitude_is_clamped`
family — reconstructed tone amplitude assertion) is the STF finding, see §5.

## 5. Known residual: STF gain droop at fs/4 (125kHz) — UNRESOLVED

`cocotb/tests/test_bringup_src.py::test_tone_signature_at_the_remod_output`
drives an exact fs/4 (125kHz) rotation at A=48 (want=0.3780) and checks
reconstructed amplitude within ±(5%+0.01). Confirmed via bit-exact replica
(exactly reproduces the real RTL measurement):

| coefficients | reconstructed amplitude @ fs/4 | vs. programmed |
|---|---|---|
| old 3-tap (205/74/11) | 0.4041 | +6.9% (inside old tolerance) |
| new 4-tap (377/106/-8/-8, deployed) | 0.3407 (real RTL measured) | **−9.9%** (outside tolerance) |

**Root cause**: the coefficient search optimized for in-band noise suppression
(NTF magnitude) and nonlinear stability margin only — never for STF (signal
transfer function) flatness. STF and NTF are both derived from the same loop
filter `L(z)`; moving NTF poles to fix noise/stability reshapes STF too, and it
happened to droop ~1dB right at fs/4 — also the edge of the BW=250kHz passband,
the same weak corner the randomized sweep already flagged generally.

**Overall chain SNR context** (why this matters, and why it doesn't dominate):
combining remod's own SQNR with the upstream int8 quantization floor
(49.9dB reference ceiling — `sd_remod`'s input is already int8-truncated
regardless of what came before it), using `1/SNR_total = Σ 1/SNR_i`:

| | remod SQNR alone | combined w/ int8 floor | loss vs remod alone |
|---|---|---|---|
| original broken RTL | 14.82 dB | 14.82 dB | 0.00 dB |
| 4th-order fix, typical (amp=0.5) | 42.20 dB | 41.52 dB | 0.68 dB |
| 4th-order fix, worst realistic case | 39.75 dB | 39.35 dB | 0.40 dB |

The 4th-order fix took the remod stage from being the **sole, degenerate
bottleneck** (0.00dB combine loss = remod was so much worse than everything
upstream that the rest of the chain's ~50dB headroom was wasted) to being
**co-limiting** with the int8 floor (~0.4-1.1dB combine loss). This is a large
real improvement. The STF droop is a *separate* effect (frequency-dependent
gain, not added noise) — it doesn't show up in this SNR combine at all, and its
real-world impact would be a mild gain ripple across a chirp's swept bandwidth
rather than a noise-floor hit. The 200/200 clean chirp-demod pass rate (§3)
suggests it isn't breaking decode correctness in the cases tested, but no
direct SNR-equivalent number has been put on the ripple itself.

Given this is an MRC system where combining losses compound (per user context:
CIC droop compensation still left a residual SNR drop even after fixing it),
**the droop should not be treated as an acceptable residual by default** — see
§6 for the (so far unsuccessful) attempt to close it via a 5th tap, and §8 for
the recommended alternative.

## 6. 5th-order exploration — NOT SUCCESSFUL YET

**Hypothesis**: with only 4 taps (2 free "padding" pole parameters after the 3
required `synthesizeNTF` poles are placed), there's no design freedom left to
independently target STF flatness — confirmed by a systematic search
explicitly prioritizing fs/4 flatness, which converged back to essentially the
*same* coefficients as the noise/stability-focused search (best found:
`Q8=(383,118,1,-6)`, gain ratio 0.9013 — no improvement). A wider, unfiltered
search found genuinely flatter points (best: gain ratio 1.0338, +3.4% error)
but they came with catastrophic broadband failure — SQNR collapsing to ~11dB at
the normal 40kHz test point and going *unstable* (negative SQNR) across
amp=0.65–0.72, squarely inside the required operating range. **4 taps cannot
do meaningfully better on flatness without sacrificing stability or noise
floor elsewhere** — this looks like a real structural ceiling, not a search
miss.

**5th-order attempt**: added a 5th tap (3 free padding poles instead of 2),
which should restore enough freedom to solve both simultaneously in principle.
In practice, every optimization approach tried so far either failed to
converge or found a candidate that overfits to the one or two frequency points
being checked:

- **Differential evolution** (3D, over the free pole locations): diverged to
  a nonsensical point (`Q8=(9,-948,-1204,-642,-131)`, cost≈598 — effectively
  unusable).
- **Nelder-Mead seeded at the "obvious" extension** of the working 4-tap pole
  location (`r1=0.28, r2=0.48, r3≈0`): the seed itself already lands outside
  the viable coefficient-magnitude region for the 5-tap system (the
  pole-to-coefficient mapping is not a simple continuation from 4→5 taps) —
  the optimizer never moved.
- **Random sampling of the viable region** (200k random (r1,r2,r3) triples,
  filtered to |A|<3, then 250 evaluated for flatness+SQNR+stability): found a
  genuinely promising candidate, `Q8=(404,156,18,-9,-3)` — gain ratio 0.9745 at
  fs/4 (only −0.22dB error, vs the deployed −0.90dB), SQNR 43.9dB at the exact
  spec test point (amp=0.5, 40kHz), stable (no cliff) through amp=0.78.
  **However**, a broader frequency check exposed the same overfitting trap:
  SQNR at other frequencies in the realistic band collapses badly —
  18.86dB @ 120kHz, 21.48dB @ 100kHz, 26.42dB @ 80kHz (all well below the
  40dB spec) — it only looks good at the specific 40kHz/fs·4 points the quick
  filter checked.
- **Local refinement (Nelder-Mead) from that candidate**: moved to a
  different point (`Q8=(372,65,-83,-61,-13)`) that recovered excellent,
  monotonic stability (39-46dB across the whole amp 0.3-0.78 range) but gave
  up almost all the flatness gain (back to gain ratio 0.9102, essentially the
  same as the deployed 4-tap solution) — the optimizer's short-simulation
  (n=384 baseband samples) cost function was too noisy to reliably
  distinguish nearby points, causing it to wander away from the actually-better
  seed.

**Conclusion so far**: every 5-tap candidate that meaningfully improves fs/4
flatness has failed a broader frequency check. It remains unproven whether a
genuinely Pareto-better 5-tap solution exists — the searches run so far only
checked 1-2 frequency points per candidate (cheap) rather than the full
broadband sweep (expensive) that validated the deployed 4-tap solution. A
proper search would need the broadband sweep (or a good proxy for it) baked
into the optimization cost function itself, which hasn't been attempted yet.

## 7. Tooling note: `python-deltasigma` under modern Python

Not installed by default; `pip install python-deltasigma` succeeds but the
package (last released ~2016) fails to import under Python 3.12 / modern
numpy/scipy for five separate reasons, in order encountered:

1. `np.float` deprecated alias (`_constants.py`) — `np.float64`.
2. `fractions.gcd` removed (moved to `math.gcd` in Py3.5+) — `_utils.py`.
3. `numpy.distutils` removed in modern numpy/Py3.12 — patched to stub
   `get_info()` in `_config.py` (only used for optional Cython/BLAS
   acceleration, not needed for `synthesizeNTF`).
4. `scipy.signal.step2` removed (renamed `step`) — `_pulse.py`.
5. `collections.Iterable` moved to `collections.abc.Iterable` (Py3.10+) —
   `_utils.py` and others.

All patches applied directly to the installed copy inside a disposable venv
(`/tmp/.../scratchpad/venv_ds`), never to any project file. Used to confirm
`synthesizeNTF(order=3, osr=64, opt=0, H_inf=1.5)`'s actual target poles
(`0.765±0.279j, 0.669`) rather than re-deriving them by hand.

## 8. Recommended next step

Given the 5th-order search hasn't yet produced a clean, broadband-validated
win, and every direct loop-filter change keeps trading one frequency's SNR for
another's, the more surgical option is likely better: a **cheap input
pre-emphasis / shelf filter on `sd_remod`'s input**, directly analogous to the
CIC droop equalizer already implemented upstream
(`planning/cic-droop-eq-findings.md`) — pre-boost frequencies near the
passband edge before they reach the ΔΣ loop, correcting the droop without
touching the loop coefficients (and therefore without risk of re-opening the
noise/stability whack-a-mole this section keeps finding). Not yet implemented
— pending direction.

## 9. Stale references fixed

- `src/remod/sd_remod.v` header: removed the false "SX1257 Figure 6-3
  compliant" claim (that figure is the SX1257's own 3rd-order TX-side
  modulator, p.37; Trouper drives the SX1302 RX-side pins instead, whose
  normal SX1257 source is a 5th-order continuous-time ΣΔ ADC, p.24) — replaced
  with the correct Trouper→SX1302 receive-path + excess-loop-delay rationale.
- `planning/Trouper Chip Specification.md` §4.9 / TRPR-RMD-001: 3rd→4th order,
  with a note on why it was raised.
- `src/README.md`: `remod/` line, 3rd→4th order.
- `sim/models/converter.py`: docstring corrected to flag the model as an
  idealized reference (zero extra loop delay — not physically realizable)
  that no longer matches deployed RTL at any order, rather than fabricate a
  misleading `order=4` entry in the same mismatched (same-cycle-cascade)
  topology.

## 10. Job log (SGE)

| job | what | result |
|---|---|---|
| 5567 | SQNR baseline attempt, broken RTL — build failed (`/foss/designs` read-only) | FAILED, fixed→5568 |
| 5568 | SQNR baseline, broken RTL, amp=0.5 | 14.82 dB |
| 5569 | SQNR, scale-fix-only RTL, amp=0.5 | 20.14 dB |
| 5570 | SQNR, 4th-order fix, amp=0.5 | 42.20 dB |
| 5571 | Existing correlation testbench, 4th-order fix | PASS, corr=0.9258 |
| 5572 | Core cocotb regression, 4th-order fix | 45/47 (bringup_src, remod_backoff fail — see §4/§5) |
| 5573 | Verilator version check | 5.046, confirmed available |
| 5574 | Batch Verilator randomized+chirp sweep, attempt 1 | FAILED (200ms global TB timeout too short, needed ~3s) |
| 5575 | Batch Verilator randomized+chirp sweep, fixed timeout | 500/500 trials ran clean; scoring in §3 |

## 12. Test coverage rewrite (2026-09-04, second review)

A second review found every existing test of remod output quality was too
weak to have caught the original scale bug in the first place:

- `cocotb/tests/test_capture_two_packet.py` never examines `REMOD_A_I/Q` at
  all.
- The weight-generation tests stop at `comb_y`, before the remodulator.
- `test_capture_playback.py`'s reconstruction records only 8,192 clocks (128
  baseband samples) and asserts correlation > 0.70 — for uncorrelated
  additive error, correlation 0.70 is roughly −0.2 dB SNR, 0.80 is roughly
  2.5 dB; a genuine 40 dB SQNR requirement would need correlation ≈0.99995
  for the metric to mean anything close to that. It's also invariant to gain
  error, tolerant of phase rotation/polarity inversion (`abs()` of the dot
  product), and searches ±8 samples of delay.
- `rtl-test/tb/tb_sd_remod.v` claimed "~55dB SQNR" in its own header comment
  but never computed SQNR or RMS error — only the same weak correlation
  check — and changed the input every 32 MHz clock instead of holding each
  500 kS/s sample for 64 clocks the way production does.
- The Python reference model (`sim/models/converter.py`) was implicitly
  trusted as bit-exact but implements different scaling and a structurally
  different (same-cycle, not registered-delay) integrator cascade — SQNR
  numbers from the model were never a check on deployed RTL (see §2).

**Fix: new authoritative regression, `cocotb/remod_sqnr/` +
`cocotb/tests/test_remod_sqnr.py`.** Drives the real, deployed `sd_remod.v`
directly (thin wrapper, not a behavioral model), holding each int8 sample for
exactly 64 clocks (production cadence, `in_valid` pulsed once then held),
records 65,536–131,072 output bits per case, reconstructs with the same
SX1302-band (250 kHz) brickwall filter used elsewhere in this repo
(`sim.tests.remod_order_sweep.brickwall_lp_decim`), and asserts actual SQNR
(>40dB, TRPR-RMD-005), RMS error (<1 LSB, TRPR-RMD-007), and fitted gain
(within 15% — a broken/dead/mis-scaled-channel check, not the known STF
droop, which is deliberately avoided by choosing test frequencies away from
the exact fs/4 edge already covered by `bringup_src`) — across 4
frequency/amplitude combinations plus a dedicated amplitude-transition case
(steps mid-capture, confirms no stuck/frozen output and that the settled tail
still meets spec — the old ×8192 bug damaged loop dynamics without stopping
the output from toggling, so a steady-state-only test could plausibly have
missed a transient-response regression too).

Added to `SUITES_CORE` in `cocotb/run_toplevel_regression_sge.sh` (the
unassigned-suite check would otherwise refuse to pass with a new
`cocotb/*/Makefile` present but unassigned to a group).

Also fixed `rtl-test/tb/tb_sd_remod.v`'s sample-cadence bug (was changing
input every clock; now holds each baseband sample for OSR=64 clocks matching
production) and corrected its header comment to stop claiming an SQNR number
it never computed — it's now explicitly documented as a fast smoke test
("not obviously broken"), with `cocotb/remod_sqnr` as the real regression
gate.

**Debugging notes** (for anyone touching this suite later):
- cocotb's `Clock(sig, period, unit)` wants the FULL period (31.25ns @32MHz),
  not the half-period some raw-Verilog testbenches use in `always #15.625
  clk=~clk` — using 15.625 throws `ValueError: Bad period`.
- `brickwall_lp_decim`'s output is normalised to the raw ±1 bitstream's own
  scale (the decimated duty-cycle average), not int8 counts — multiply by
  127 to compare against a reference in count units (mirrors
  `comb_remod_transfer`'s `si*127/OSR`). Forgetting this gave a fitted gain
  of ~0.0079 (≈1/127) that looked like a broken channel but was a pure units
  bug.
- `slice(edge, -edge)` is **empty** when `edge=0` (`-0 == 0` in Python) — use
  `slice(None)` for the no-trim case.
- The amplitude-transition test's post-step scoring must decimate the
  post-step segment as its **own independent FFT block**, not as a slice of
  a combined pre+post-step block — a single `brickwall_lp_decim` FFT over a
  block containing a sharp discontinuity leaks spectral energy from that
  discontinuity across the *entire* block (circular-convolution artifact),
  degrading the apparent SQNR of an already-settled tail region for reasons
  unrelated to real settling time. Re-slicing the raw bits first, then
  decimating only the isolated post-step portion (with its own edge trim —
  a short re-sliced block still needs one), fixed a spurious 27dB "failure"
  that had nothing to do with the RTL.

**Verification**: standalone suite run (jobs 5576→5580, iterating through the
bugs above) — final result 2/2 tests passing (SQNR 41.0–48.6dB, RMS
0.29–0.35 LSB, gain 0.978–0.999 across all cases). Full core regression
(job 5582) with `remod_sqnr` now included: **46/47 suites pass** — the sole
failure is `bringup_src` (§5, unrelated/known), confirming the new suite
integrates cleanly and nothing else regressed.

## 13. Working-tree changes (uncommitted)

- `src/remod/sd_remod.v` — 4th-order fix (primary)
- `rtl-test/rtl/sd_remod.v` — synced copy
- `rtl-test/tb/tb_sd_remod.v` — sample-cadence fix + honest header
- `cocotb/remod_sqnr/remod_sqnr.v`, `cocotb/remod_sqnr/Makefile` — new suite (new)
- `cocotb/tests/test_remod_sqnr.py` — new authoritative fidelity regression (new)
- `cocotb/run_toplevel_regression_sge.sh` — `remod_sqnr` added to `SUITES_CORE`
- `cocotb/tests/test_remod_backoff.py` — recalibrated thresholds
- `planning/Trouper Chip Specification.md` — TRPR-RMD-001 + §4.9 intro
- `src/README.md` — remod/ line
- `sim/models/converter.py` — docstring correction
- `planning/sd-remod-4th-order-fix-2026-09-04.md` — this doc (new)

Nothing committed to git — standing "wait" instruction from earlier in this
session remains in effect.
