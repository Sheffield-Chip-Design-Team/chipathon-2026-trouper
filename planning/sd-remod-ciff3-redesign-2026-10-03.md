# sd_remod CIFF3 Redesign (2026-10-03)

> **Status:** RTL + bit-true model changed (working tree, uncommitted).
> All 10 remod cocotb suites PASS incl. bit-exact RTL-vs-model golden; SX1302
> comparison done. Full-chip P&R not yet run — see §7. Supersedes the loop-filter parts of
> `sd-remod-4th-order-fix-2026-09-04.md` (§2–§3, §6); the interpolator
> promotion in `sd-remod-interp2x-pnr-investigation-2026-09-05.md` stands.

## 1. Finding: the deployed "4th-order" loop was 2nd order

Deployed core (`sd_remod_multiplierless.v`, 2026-09-05): CIFF, Q8 taps
`(377, 106, -8, -8)`, registered quantizer, delaying integrators, direct
`256·e` term, sat16 states.

- Linearised closed loop (state `[s1..s4, y]`, quantizer gain *k* swept
  1e-6…3e-3): one real pole at **≈ +1.2 for every k**. The highest-order tap
  is negative, so the loop is positive feedback at DC.
- Bit-true model, zero input: s3/s4 pinned at +32767 for 99.98% of clocks
  within ~30 clocks of reset; s2 parks at ≈ 4,890 so that `106·s2` cancels
  the constant `−8·(s3+s4) ≈ −524k`.
- In-band noise slope 38–41 dB/dec, identical to a clean 2nd-order design
  `(328, 72)` (40–42 dB/dec). A genuine 4th-order placement reaches 73–76.

Every regression passed because a 2nd-order shaper still clears the >40 dB
SQNR spec; the int8 input floor dominates (§3).

## 2. Why the 4th tap was never needed

The 2026-09-04 doc (§2) argued a 3-tap loop could not be pole-placed because
the closed-loop pole sum is pinned at 2. The trace of the closed-loop matrix
is `N − k·256·127`, which is pinned **only if the 1-bit quantizer gain k is
fixed at 1/(256·127)**. A 1-bit quantizer has no fixed gain; with k free, the
original 3-tap structure places `synthesizeNTF(3, 64)` poles exactly
(`(348, 106, 14)`, implied gain 0.80). Even at the doc's own assumed gain the
adopted 4-tap coefficients give |poles| = 0.27, 0.40, 0.67, 0.67, **1.21**.

## 3. What actually limits remod-path SNR

Bit-true model, 125 kHz channel, total SNR vs the int8-only floor:

| interpolator output | 2nd-order loop | 4th-order loop |
|---|---|---|
| int8 (deployed) | +1.04 dB loss | +1.04 dB loss |
| int8 + 2 fraction bits | +0.06 dB | +0.05 dB |

- The ≈1 dB is the 2× interpolator re-rounding its even-phase output to
  int8 (theory: half the samples gain 1/12 LSB² over 1 MS/s → 0.97 dB).
- Loop noise alone (vs its own input) is 75–90 dB in 125 kHz for every
  candidate — ~30 dB below the int8 floor. Loop order is irrelevant
  in-channel; it matters only out of channel (§5).
- The deployed loop cannot simply take a wider input: scaling states ×4
  saturates the parked s2 and costs ~2 dB.

## 4. Design

**Interpolator** (`sd_remod.v`): `FRAC_BITS = 2` — even phase
`sat10((acc + 64) >>> 7)`, odd phase `x[n−2] << 2`; 10-bit output at 4× int8
scale. MAC unchanged.

**Loop** (`sd_remod_multiplierless.v`), 3rd-order CIFF:

```
e   = x − (out ? +508 : −508)           x 10-bit, e 12-bit
v   = 256·e + 334·s1 + 89·s2 + 10·s3    23-bit, |v| ≤ 2,685,952
s1' = sat13(s1 + e); s2' = sat14(s2 + s1); s3' = sat16(s3 + s2)
out' = (v ≥ 0)
```

Taps pole-placed for the real topology: `synthesizeNTF(3, OSR=64, opt=0,
H_inf=1.4)` + one pole at 0; implied quantizer gain 0.67. Shift/add:
`334 = 5·64 + 16 − 2`, `89 = 64 + 3·8 + 1`, `10 = 5·2`.

H_inf choice (F=2, 16-bit s3):

| H_inf | taps | s3 peak @0.708 / 0.8 FS | noise ±125/250/500 kHz @0.5 FS |
|---|---|---|---|
| 1.3 | 318, 69, 7 | 0.54 / 0.91 | 93 / 74 / 53 dB |
| **1.4** | **334, 89, 10** | **0.49 / 0.91** | **95 / 77 / 56 dB** |
| 1.5 | 348, 106, 14 | 0.49 / 1.00 (rails) | 97 / 80 / 59 dB |

1.4 is the highest-H_inf point with no integrator saturation through 0.8 FS
(−1.9 dBFS, > 1 dB above the TRPR-RMD-004 −3 dBFS limit). Linearised loop
stable for k ∈ ~0.3×…3× nominal (normal conditional stability for 1-bit
3rd order); above MSA the saturating states recover cleanly (full-scale burst
→ 0.5 FS: longest identical-bit run 5). State widths 13/14/16 vs 16/16/16
gave bit-identical SNR/MSA in sweeps.

Area: removes s4 (×2 rails), narrows s1/s2, v 25→23 bits; interpolator +2
bits on its output regs and `in_*_lat`. Yosys + FD 7t TT, `sd_remod`
flattened: **77,462 → 70,964 µm² (−8.4%)** (job 5823). Timing note: Open
Risks records the full-chip SS critical path at `u_remod.s3_i` — the very
register that was railing; the new s3 cone is shallower (23-bit v).

## 5. SX1302 input comparison

The SX1302 datasheet (Rev 1.2 §4/§6) specifies only separate 1-bit I(t)/Q(t)
on `RADIO_A_IQ` synchronous to the 32 MHz `RADIO_A_CLK_I`; no NTF/SQNR
requirement. The design-intent source (SX1257 DS §3.7.2) is a 5th-order CT ΣΔ,
13-bit after decimation over ≤500 kHz. Harness:
`sim/sims/remod_sx1302_compare.py` with reference model
`sim/models/sx1257_adc_ref.py` (DT 5th-order CIFB, OSR 32, opt=1, H_inf 1.5;
agrees with python-deltasigma `simulateDSM` to ~1 dB in-band; MSA ≈ 0.6 FS).

Receiver proxies (float): `hb` = CIC3 R16 → HB1 → HB2 (Trouper's own
SX1257-stream decimator structure); `cic` = CIC3 R64 only (weak alias
rejection, stress case). Both followed by a 255-tap ±BW/2 channel FIR.

**A — stream noise by band** (dBc, tone 0.5 FS @ 20 kHz, BH-windowed Welch):

| source | 0–125k | 125–250k | 250–500k | 0.5–1M | 1–2M | 2–4M |
|---|---|---|---|---|---|---|
| sx1257_ref | −84.6 | −89.7 | −83.8 | −35.4 | −15.4 | −7.3 |
| legacy_ciff4 | −45.3 | −48.4 | −48.8 | −32.2 | −23.9 | −9.1 |
| ciff3 | −46.5 | −49.4 | −52.6 | −31.1 | −19.8 | −9.2 |

**B — in-channel tone SNR** (dB, `hb` proxy; `cic` within 0.5 dB):

| BW | amp | sx1257_ref | legacy_ciff4 | ciff3 | int8 only |
|---|---|---|---|---|---|
| 125k | 0.3 | 87.7 | 45.1 | 45.5 | 45.6 |
| 125k | 0.5 | 91.6 | 49.0 | 49.8 | 49.9 |
| 250k | 0.3 | 83.2 | 42.4 | 42.8 | 42.9 |
| 250k | 0.5 | 87.0 | 46.0 | 46.9 | 46.8 |

(sx1257_ref at 0.65 FS is past its MSA and diverges — expected for 1-bit
5th order; the real SX1257 relies on AGC.)

Reading:
- In-channel, CIFF3 sits on the int8 floor (≤0.1 dB); legacy is 0.5–0.9 dB
  below it.
- Above 1 MHz both Trouper streams carry **less** noise than the SX1257
  reference, so the SX1302 decimator — which must already handle SX1257
  streams — sees nothing worse there.
- The real gap is 125–500 kHz: ~−50 dBc vs ~−85 dBc. That is int8
  quantisation noise and its interpolator images, not loop shaping (CIFF3
  improves 250–500k by only ~4 dB). Closing it would need a wider combiner
  output, not a higher-order loop.

Plot: `sim/plots/remod_sx1302_psd.png`. Both Trouper streams also show
≈−36 dBc images of the tone near 1/2 MHz (the 32-clock hold at the 1 MS/s
interpolator rate; identical for both loops, far out of channel).

**C — LoRa SER** (job 5826; SF7 400 / SF9 150 symbols per point, SF12 8;
AWGN referenced to the LoRa BW; total rms −14 dBFS; plot
`sim/plots/remod_sx1302_ser.png`, data `sim/plots/remod_sx1302_compare.json`):

- `hb/ciff3` and `hb/legacy_ciff4` symbol-error counts agree within ±1 at
  every point and track the ideal float receiver; the waterfall is set by
  channel noise, not the remod (SF7 ≈ −8 dB, SF9 ≈ −13 dB to <1% SER for
  both BWs). Loop order has no measurable LoRa effect.
- `cic` proxy is ~0.5–1 dB worse than `hb` for every source including the
  SX1257 reference — a property of the weak receiver, not the stream.
- SF12 sanity: 0/8 errors at +30 dB on every path.
- The reference stream shows one burst (SF9/BW250 −9 dB, 10/15 symbols in
  one task): an input peak of 0.72 FS exceeded the float 5th-order model's
  ≈0.6 FS MSA (temporary overload, no divergence). A reference-model
  artefact; CIFF3 stays unsaturated to 0.8 FS.

Harness note: job 5824 is invalid — its chirp used an inclusive phase
cumsum that flipped the post-wrap part of every BW250 symbol by π (ideal
receiver failed at +30 dB). Fixed; `sim/tests/test_remod_sx1302_compare.py`
now requires clean decode on every path.

## 6. Residual risks

- SX1302 channelizer / detector / RSSI internals remain unmodelled; the
  125–500 kHz noise gap (§5) is the specific thing a hardware A/B would check.
- Reference model is a DT stand-in for the SX1257's CT modulator.

## 7. Verification / job log

| job | what | result |
|---|---|---|
| — | `sim/tests/test_sd_remod_model.py` (both configs, + CIFF3 no-rail check) | 15/15 PASS |
| — | `LEGACY_CIFF4` config vs previous model, random stimulus incl. `en` toggles | bit-exact |
| 5819 | `remod_sx1302_compare` A/B/C | A/B done (§5); C crashed (worker OOM, 50-symbol SF9 tasks) |
| 5822 | cocotb remod suites (golden, en, sqnr, flatness, stability, backoff, lora, amp_sweep, comb_remod_transfer, bringup_src) | 9/10 PASS; `remod_backoff` FAIL (shift=1 run 64) |
| 5823 | Yosys A/B synth of `sd_remod` | 77,462 → 70,964 µm² |
| 5824 | sweep rerun | invalid (chirp phase bug, see §5) |
| 5825 | `remod_backoff` with 2,048-clock settle after each COMB_CFG write | PASS (shift=1 run 5; shift=0 run 67) |
| 5826 | sweep, fixed harness | done (§5 C) |
| — | full-chip P&R | not yet run |

`remod_backoff` failure root cause: it measured from the COMB_CFG write, so
shift=1 caught the loop unwinding from the preceding shift=0 overload
(0.97 FS). Bit-true model: the transient is < 1,024 clocks for both cores
(legacy 22–55, CIFF3 31–72 in the first 8,000 clocks; 5 thereafter); legacy
passed by stimulus luck.

Stale after this change: `rtl-test/tb/tb_sd_remod_multiplierless_equiv.v`
(compares against the pre-2026-09-05 4-tap reference, 8-bit input).
