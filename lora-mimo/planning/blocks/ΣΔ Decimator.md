# ΣΔ Decimator (CIC + FIR, ×4)

RX path stage 2. See [DSP Flow](../DSP%20Flow.md) for context.

**Owner:** TBD
**Status:** Updated — 1× oversampling, R=256, 32 MHz

---

## Function

Converts the 1-bit sigma-delta bitstream from each SX1257 ΣΔ ADC into full-precision complex I+Q samples. Four identical instances — one per antenna. A power-of-2 CIC filter performs the primary decimation; an FIR compensation filter corrects the sinc frequency droop.

**Output precision:** The decimator outputs **8-bit signed** samples per I and Q component. This is the full resolution of the digital processing chain — no further truncation is applied downstream. See open item below for GNU Radio confirmation.

**Design note:** 8-bit was chosen over 12-bit after simulation showed no BER degradation at either width across the full operating SNR range (SF=7, NR=4, training accumulator path). The low-gain edge case (AGC at minimum, high channel power) is benign: quantization noise can exceed thermal noise only when SNR is high, so decoding is unaffected. 8-bit allows the training accumulator to use int32 instead of int64, and the Frontend Buffer write path requires no saturation shift. See sim/tests/test_bitwidth_sweep.py for the simulation. **Pending GNU Radio confirmation — see open item.**

---

## Clock and oversampling decision

### Chosen configuration: 32 MHz, R=256, 1× oversampling

```
Fs_out  = 32 MHz / 256 = 125,000 S/s
Nyquist = 62,500 Hz  =  BW/2  (1× Nyquist)
```

**Why 1× is sufficient:**

1. **Training accumulator is CFO-immune.** The cross-correlation scheme (`Z_j = Σ rx_j · conj(rx_ref)`) cancels CFO phase rotation exactly — no Dirichlet attenuation, no integer-bin nulls. The aliasing risk from CFO is limited to the decimator anti-alias filter only.

2. **CFO aliasing loss is small even at 2 ppm TCXO.** CFO is the sum of TX and RX oscillator errors. With a 2 ppm gateway TCXO and a 20 ppm end-device crystal, the worst-case total CFO = ±19.1 kHz at 868 MHz. The aliased fraction of the chirp is p = 19,100 / 125,000 = 15.3%, giving a peak SNR loss of ~1.5 dB. This is less than half the 3 dB unconditional noise penalty from 2× oversampling — so 1× is always better.

3. **1× gives integer samples/symbol.** samples/symbol = 2^SF exactly for all spreading factors. Non-power-of-2 oversampling (e.g., 1.28×) produces fractional M, causing timing drift in the SC correlator and preamble accumulation window.

4. **0 dB noise penalty.** The SX1257 analog prefilter RXBWANA minimum is 250 kHz SSB — much wider than the 125 kHz LoRa BW. The CIC output rate sets the effective noise bandwidth, so any oversampling above 1× costs noise directly. 2× costs 3 dB (half the NR=4 MRC gain).

### CFO aliasing budget (1× Nyquist, 125 kHz BW)

Total CFO = TX oscillator error + RX oscillator error (worst case, opposite sign).
Aliased fraction p = CFO_total / BW. SNR loss ≈ −20·log₁₀(1 − p).

| End-device TX | Gateway RX (this design) | Total CFO @ 868 MHz | p | Aliasing loss | vs 2× noise |
|---|---|---|---|---|---|
| 2 ppm TCXO | 2 ppm TCXO | ±3.5 kHz | 2.8% | 0.24 dB | 3 dB ✓ |
| 10 ppm crystal | 2 ppm TCXO | ±10.4 kHz | 8.3% | 0.75 dB | 3 dB ✓ |
| **20 ppm crystal** | **2 ppm TCXO** | **±19.1 kHz** | **15.3%** | **1.5 dB** | **3 dB ✓** |

In all cases the aliasing loss is less than the 3 dB noise penalty of 2× oversampling.

### Oversampling options considered

| Config | R | Fs_out | Guard | Noise penalty | Samples/symbol SF6 | Notes |
|---|---|---|---|---|---|---|
| **1× (chosen)** | **256** | **125 kS/s** | **0 Hz** | **0 dB** | **64** | **2 ppm TCXO on gateway** |
| 1.28× | 200 | 160 kS/s | 17.5 kHz | −1.1 dB | 81.92 ✗ | Fractional M — rejected |
| 2× | 128 | 250 kS/s | 62.5 kHz | −3.0 dB | 128 | 3 dB cost — rejected |
| **2× / 500 kHz BW** | **32** | **1 MS/s** | **250 kHz** | **−3.0 dB** | **256** | **decim_ratio=3; debug / wideband capture** |

### Proportional ratios for other LoRa BWs

| LoRa BW | R | Fs_out | Samples/symbol SF6 | Notes |
|---|---|---|---|---|
| 125 kHz | 256 | 125 kS/s | 64 | 1× Nyquist |
| 250 kHz | 128 | 250 kS/s | 128 | 1× Nyquist |
| 500 kHz | 64 | 500 kS/s | 256 | 1× Nyquist |
| 500 kHz | 32 | 1 MS/s | 512 | 2× oversampled; decim_ratio=3 |

All R values are power-of-2. Samples/symbol = 2^SF for all SF and all BW settings at 1×; 2×2^SF at decim_ratio=3.

---

## Interface

| Port | Direction | Width | Rate | Description |
| --- | --- | --- | --- | --- |
| `iq_in_i` | in | 1 | 32 MS/s | I bitstream from SX1257 `I_OUT` |
| `iq_in_q` | in | 1 | 32 MS/s | Q bitstream from SX1257 `Q_OUT` |
| `clk_32m` | in | — | 32 MHz | Shared clock from SX1257_1 `CLK_OUT` |
| `rst_n` | in | — | — | Active-low reset |
| `decim_ratio` | in | 2 | static | 0=R256 (125 kS/s / 125 kHz BW), 1=R128 (250 kS/s / 250 kHz BW), 2=R64 (500 kS/s / 500 kHz BW), 3=R32 (1 MS/s / 500 kHz BW 2×) |
| `iq_out_i` | out | 8 signed | $f_s$ | Decimated I sample |
| `iq_out_q` | out | 8 signed | $f_s$ | Decimated Q sample |
| `iq_valid` | out | 1 | $f_s$ | High for one cycle when output is valid |

---

## Parameters

| Parameter | Value | Notes |
| --- | --- | --- |
| Decimation ratios ($R$) | 256, 128, 64, 32 | Power-of-2; R=32 gives 1 MS/s (2× oversampled 500 kHz BW) |
| CIC stages ($N$) | 3 | Balanced for area and stopband rejection |
| Accumulator width | 25-bit | `1 + N·log₂(R_max) = 1 + 3·8 = 25` bits; covers all four ratios |
| FIR taps | 9 (symmetric Type-I, 5 unique) | Single coefficient set — see FIR Compensation note below |
| Output width | 8-bit signed | Convergent rounding from 25-bit CIC accumulator; normalisation right-shift 17 (R=256), 14 (R=128), 11 (R=64), 8 (R=32) |

---

## Implementation notes

**CIC counter.** For power-of-2 R, the strobe is a free-running counter MSB:

```verilog
always @(posedge clk)
    count <= count + 1;

assign strobe = (count[log2(R)-1:0] == 0);
```

R is set by `decim_ratio` (selects counter width 8, 7, or 6 bits for R=256/128/64).

**Accumulator Scaling.** CIC gain $G = R^N$:
* $R=256 \rightarrow G = 256^3 = 2^{24}$
* $R=128 \rightarrow G = 128^3 = 2^{21}$
* $R=64  \rightarrow G = 64^3  = 2^{18}$
* $R=32  \rightarrow G = 32^3  = 2^{15}$

Normalisation right-shift: `shift = N·log₂(R) − (W_out − 1)` with W_out = 8.
* R=256 → shift 17; R=128 → shift 14; R=64 → shift 11; R=32 → shift 8.

**FIR Compensation.** The normalised CIC response is:

```
H_norm(f_norm) = (sin(π·f_norm) / (R·sin(π·f_norm/R)))^N
```

For large R (≥64), `sin(π·f/R) ≈ π·f/R` across the passband, so the response collapses to sinc³(f/fs_out) — identical normalised droop for all large-R ratios, one coefficient set corrects all three (R=256, 128, 64).

**R=32 (1 MS/s) is an exception.** The sinc approximation is less accurate at R=32; the true normalised passband droop differs slightly from sinc³. The current fixed coefficients (tuned for large R) will under-compensate the droop at 1 MS/s. For LoRa's chirp modulation this is expected to be acceptable (residual droop ≪ 1 dB across the LoRa BW), but it has not been verified. See open item below.

**Clock domain.** Entire block runs at 32 MHz. `iq_valid` rate changes with `decim_ratio`. All downstream DSP must use `iq_valid` as their clock enable.

---

## Open items

**FIR compensation accuracy at R=32 (1 MS/s).** The fixed 9-tap compensator coefficients are accurate for R≥64 (sinc³ approximation holds). At R=32 the normalised CIC droop shape diverges slightly, leaving a residual passband ripple. Two options:

1. **Accept as-is** — simulate the R=32 path to measure actual droop error. If < ~0.5 dB across the LoRa passband, no change needed given LoRa's chirp resilience.
2. **Per-rate coefficient ROM** — store 4 × 5 = 20 Q1.14 values (symmetric filter, 5 unique coefficients per ratio) indexed by `decim_ratio`. Negligible area (320 bits of registers). Required if option 1 shows meaningful sensitivity loss.

**Confirm 8-bit precision with GNU Radio.** The 8-bit output width decision is based on Python simulations (sim/tests/test_bitwidth_sweep.py) showing no BER degradation vs float across SF=7, NR=4, SNR=-10 to +10 dB. Confidence is high (~90%) but the simulation uses an idealised channel model and assumed SC lock timing. Before RTL freeze, validate with GNU Radio (gr-lora or gr-lora_sdr) using:
- Real or simulated LoRa packets decoded end-to-end through the 8-bit quantised chain
- Sweep SF, SNR, and BW to confirm no sensitivity cliff at 8-bit vs higher precision
- Verify SC detection performance with 8-bit inputs specifically (the current simulation assumes perfect SC lock timing)

If GNU Radio confirms no degradation, 8-bit is locked. If a sensitivity penalty is found at any operating point, revisit 12-bit (int64 training accumulator required — see Training Accumulator spec).

---

## Verification

| Test | Method | Pass criterion |
| --- | --- | --- |
| Ratio switching | Sweep `decim_ratio` in sim | `iq_valid` frequency matches 125/250/500 kS/s |
| Integer M | Check samples/symbol at each ratio | samples/symbol = 2^SF exactly |
| DC Scaling | Inject all-ones at R=256 | `iq_out` does not overflow; reaches max positive value |
| Sinc droop | Sweep input tone 0–62.5 kHz | FIR-corrected output flat within ±0.5 dB |
| CFO aliasing | Inject LoRa with ±19 kHz CFO (20 ppm TX + 2 ppm RX worst case) | Aliasing loss < 1.5 dB; main chirp peak still detectable |

---

## Related blocks

- [Register Map](../Register%20Map.md) — `DECIM_CFG` at `0x12`
- [Frontend Buffer Controller](Frontend%20Buffer%20Controller.md) — receives 8-bit output; stored directly to SRAM with no shift
- [Training Accumulator](Training%20Accumulator.md) — receives 8-bit output directly (not from SRAM)
- [Energy Measurement](Energy%20Measurement.md) — receives 8-bit output; clock-gated by `iq_valid`
- [ALMMSE-MRC Combiner](ALMMSE-MRC%20Combiner.md) — receives 8-bit output
- [DSP Flow](../DSP%20Flow.md) — updated pipeline rates
