# Simulation Ideas & Extensions

Open ideas for future notebook cells, model extensions, or verification experiments.

> **Note:** Most items below predate the switch to the non-FFT streaming frontend
> (see `planning/Non-FFT LoRa Frontend Proposal.md`). Ideas that reference FFT peak
> bins, capture SRAM, RCTSL, or sub-bin CFO correction apply to the legacy FFT path
> only and are superseded by the training accumulator architecture. Items still
> relevant to the current design are noted inline.

---

## In Progress

### Sub-bin CFO interpolation for coherent preamble averaging

**Status:** Analysis done in notebook (CFO sensitivity cell after Stage 4), implementation pending.

**Why it matters — coherent averaging:** The 8-symbol coherent average `h_hat_j = (1/N_sym·M) Σ_s D_j[s][k_peak]` only works if all 8 symbols add in phase. Each symbol accumulates an extra phase of `2π·ε_sub` from the sub-bin fractional offset. Over 8 symbols the combining loss is:

```
loss = |sin(π·N_sym·ε_sub)| / (N_sym · |sin(π·ε_sub)|)
```

At the worst case (ε_sub = 0.5, halfway between bins): loss = 0 — complete cancellation of the 8-symbol gain. At a typical 10 ppm crystal offset (ε_sub ≈ 0.14 bins for SF7/125 kHz): ~3.5 dB loss. The sub-bin correction multiplies each symbol by `exp(-j·2π·ε_sub·s)` before summing, restoring full coherent gain.

**Problem:** After integer-bin FFT-based CFO correction, the residual offset is ±BW/(2M) ≈ ±122 Hz (SF9). This reduces the dechirped FFT peak by up to −3.9 dB at the worst-case half-bin point, directly hitting sensitivity at low SNR. MRC combining weights are unaffected (common α cancels), but the signal path loss is real.

**Fix:** Parabolic sub-bin interpolation on the three FFT peak bins.

The FFT bins are spaced BW/M = 244 Hz apart. The true tone sits between bins;
the Dirichlet kernel is approximately parabolic near its peak, so fitting a parabola
to the peak bin and its two neighbours locates the true frequency:

```
magnitude
    │
  β │        ●          ← peak bin k
    │      ·   ·
  α │    ●       ● γ    ← neighbours k-1, k+1
    └──────┬──┬──┬──── bin
         k-1  k  k+1
```

- If α > γ: tone is left of k (δ < 0)
- If α < γ: tone is right of k (δ > 0)
- If α = γ: tone exactly at k (δ = 0)

Works well because with 32× averaging (4 antennas × 8 symbols) the SNR on α, β, γ
is high, so noise doesn't distort the parabola fit.

**Code:**

```python
k_peak = np.argmax(|FFT|)
α, β, γ = |FFT|[k_peak-1], |FFT|[k_peak], |FFT|[k_peak+1]
k_frac  = k_peak + 0.5 * (α - γ) / (α - 2β + γ)
df_est  = k_frac * BW / M
```

Reduces residual to ±BW/(10–20M) ≈ ±10–25 Hz → worst-case FFT peak loss < −0.1 dB.

**Architecture decision — shared SX1302 clock:**
All NR antennas share the same RX clock, so CFO is common across antennas. This means:
- One pooled dechirped FFT (4 antennas × 8 symbols = 32× averaging) gives a very clean integer-bin estimate
- Detection sensitivity loss from ±122 Hz residual is modest given 27 dB LoRa processing gain (SF9) + ~6 dB MRC gain
- Sub-bin is NOT needed for detection, but IS needed to unlock N-symbol complex averaging

**Phase accuracy tradeoff (at −5 dB SNR, SF9):**
1-symbol vs 8-symbol complex averaging improves phase std dev by √8 ≈ 2.8×:

| Antenna | \|h\| | σ_φ 1-sym | σ_φ 8-sym | MRC loss 1-sym |
|---|---|---|---|---|
| weak  | 0.21 | ~22° | ~8°  | ~0.7 dB |
| mid   | 0.44 | ~9°  | ~3°  | ~0.1 dB |
| strong| 0.86 | ~4°  | ~2°  | ~0.02 dB |

Weak antenna dominates phase error but has smallest MRC weight — net combining loss from 1-symbol phase noise is ≤ 0.7 dB. Becomes significant only at deeper negative SNR or SF7 (smaller M → lower correlation SNR).

**Conclusion:** Sub-bin is low priority for current operating point. Revisit if operating at SF7 or below −10 dB SNR.

**Next steps:**
- Add notebook cell showing residual error and peak loss vs interpolation method (integer-bin vs parabolic vs CoM) — see cross-antenna extension below
- Wire into `estimate_channel()` (receiver.py) as a pre-correction step: compute ε_sub from inter-symbol phase after Pass 1, apply `exp(-j·2π·ε_sub·s)` per symbol before Pass 2 accumulation
- BER comparison: no correction vs integer-bin vs interpolated

### Cross-antenna coherent CFO estimation (extension of above)

**Status:** Architecture analysed, Jupyter notebook simulation planned as next step.

**Insight:** All four SX1257 front-ends share a single TCXO reference via the PCB clock buffer, so the carrier frequency offset `df` is identical across all NR=4 antennas. Only the channel phase `φ_j = ∠h_j` differs per antenna. This means all four antennas' dechirped samples can be exploited jointly for CFO estimation.

**Two combining strategies:**

| Strategy | How | Resolution | SNR boost | Complexity |
|---|---|---|---|---|
| Incoherent | Sum `\|FFT_j[k]\|²` across antennas, then find peak + sub-bin interpolate | BW/M (unchanged) | 4× (6 dB) | Trivial — no prior needed |
| Coherent (two-pass) | Pass 1: per-antenna FFT → coarse `φ_j`; Pass 2: phase-align by `exp(-jφ_j)`, sum 4 antennas → single M-sample stream → FFT + sub-bin | BW/M (same resolution, but 4× SNR → better interpolation accuracy) | 4× coherent | 2 FFT passes + firmware phase rotation |

Note: true 4× resolution improvement (BW/4M) would require concatenating all 4×M samples into a 4M-point FFT with no phase jumps at boundaries. This requires phase alignment, and the resolution gain is likely unnecessary — the 8-symbol preamble coherent integration already achieves BW/(8M) ≈ 30 Hz at SF9/125 kHz, which is comparable to what 4× wider FFT would give from a single symbol.

**The practical win is SNR, not resolution.** Incoherent 4-antenna combining gives 6 dB better peak SNR in the CFO spectrum, making sub-bin interpolation reliable 6 dB deeper into the noise floor.

**Architecture fit — no new hardware needed:**
- Raw preamble samples remain in capture SRAM (`0x08000+`) throughout both passes
- Pass 1 uses FFT staging (`0x00000–0x07FFF`) as normal; outputs coarse `φ_j` to PicoRV32
- Pass 2: PicoRV32 reads from capture SRAM, applies `exp(-jφ_j)` rotation, sums 4 antennas → M samples back into staging → FFT engine re-triggered
- Summed pass-2 signal: M × 2 bytes (8 KB at SF12) — fits staging easily
- **Timing:** total two-pass overhead ~370 µs (SF9) to ~3.9 ms (SF12) vs. available window of ~17 ms / ~139 ms — 36–47× margin
- **PicoRV32 bottleneck:** phase rotation + sum step is 4×M complex MACs; ~2 ms at SF12 on RV32IM — within margin but is the critical path

**Notebook sim plan:**
Sweep residual CFO error vs per-antenna SNR for four methods:
1. Single antenna, integer-bin only
2. Single antenna, integer-bin + parabolic sub-bin
3. 4-antenna incoherent `Σ|FFT_j|²` + sub-bin
4. 4-antenna coherent two-pass + sub-bin

Plot: RMS residual df error (Hz) vs SNR (dB), and resulting worst-case FFT peak loss (dB). Target: confirm that method 3 (incoherent, no new hardware) gives adequate accuracy across the operating SNR range before deciding whether the coherent two-pass complexity is justified.

---

## Channel Estimation

### Bayesian / Kalman Channel Tracking

**Motivation:** The current LS preamble estimator assumes a flat-fading-per-packet channel. This breaks for mobile nodes at SF12 (packet duration ~2.5 s exceeds coherence time at walking speed, 868 MHz).

**Idea:** Replace the single preamble estimate with an AR-1 Kalman filter that tracks `h[t]` sample-by-sample through the payload.

```
State:  h[t] = α·h[t-1] + w[t],   w ~ CN(0, σ_w²)
Obs:    y[t] = h[t]·s[t] + n[t],  n ~ CN(0, N0)
α = J₀(2π·f_D·T_s)               (Jakes AR-1 approximation)
```

The preamble LS estimate seeds the prior; each payload sample updates the posterior. The firmware computes `α` and `σ_w²` from a Doppler class register.

**Experiment:** Notebook cell comparing BER vs SNR for:
- Static LS estimate (current)
- AR-1 Kalman tracking
- Genie-aided (true h known)

at 10 Hz Doppler (walking speed, 868 MHz) across SF7–SF12.

**Cost:** Per-sample complex MAC × NR. Feasible on PicoRV32 at decimated `f_s = 125 kS/s`.

**Variants:**
- Extended Kalman / particle filter for non-linear fading (fast mobile / urban)
- Online Doppler estimation: add `f_D` as a state variable

---

## BER Sweeps

### BER vs SNR — Full sweep

Monte Carlo BER vs per-antenna SNR (−15 to +5 dB) across:
- NT=1 MRC (estimated vs genie-aided)
- NT=2 ALMMSE
- Best single antenna baseline

Parameterised by SF (7, 9, 12) and BW (125, 500 kHz). Validates combining gain and quantifies estimation loss.

### BER vs SNR — Time-varying channel

Same sweep but with a time-varying Jakes channel at `f_D = 10 Hz`. Highlights SF12 degradation and motivates Kalman tracking.

---

## Fixed-Point Analysis

### Wordwidth sweep

Sweep the combiner output wordwidth (8–16 bits) and plot BER degradation. Identify the minimum safe wordwidth for each SF.

### Accumulator overflow stress test

Drive the correlator with maximum-amplitude int8 inputs (±127) and verify the int32 accumulator does not saturate for the longest preamble (8 × 4096 samples at SF12).

---

## ΣΔ Re-modulator

### SQNR vs OSR

Plot SQNR of the 3rd-order ΣΔ re-modulator vs oversampling ratio (32–256×) against theoretical `6.02·L·bits + 1.76 + 5.17·(2L+1)·log₂(OSR)` bound. Verify the 125 kHz and 1000 kHz operating points.

### Spectral mask check

FFT of re-modulator output at each BW setting, overlaid with the LoRaWAN spectral mask. Confirms no out-of-band emissions from the 3rd-order noise shaping.

---

## Multi-Packet / System Level

### EMA smoothing gain

Simulate a static channel over 50 consecutive packets and plot the EMA-smoothed `|h_hat|²` vs the per-packet LS estimate. Quantify variance reduction as a function of `ALPHA_SHIFT`.

### Throughput vs combining gain trade-off

Model effective throughput (bits/s) vs SNR for MRC and ALMMSE, accounting for LoRaWAN duty cycle. Shows where MIMO gain translates to range extension vs data-rate improvement.
