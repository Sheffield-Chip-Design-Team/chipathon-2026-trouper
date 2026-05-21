# DC Removal (×4)

RX path stage 3. See [DSP Flow](../DSP%20Flow.md) for context.

**Owner:** TBD
**Status:** Not started

---

## Function

Removes residual DC bias from each complex I+Q channel before the Frontend Buffer and SC Preamble Detector. Four identical instances — one per antenna.

DC bias arises from the SX1257 direct-conversion mixer and is unavoidable without this stage. An unremoved DC component appears as a constant additive phasor at the LO frequency, which:

- shifts the SC autocorrelation metric by a constant bias that varies per device and per temperature
- pollutes the training cross-correlation `Z_j = Σ rx_j · conj(rx_ref)` with a spurious DC product
- inflates the energy measurement, interfering with AGC normalisation

The filter is a first-order IIR running-mean subtractor. The time constant is set by `DC_ALPHA_SHIFT` (a power-of-two right-shift applied to the error term).

```
For each sample n and branch j:
  dc_est[j] += (raw[j][n] - dc_est[j]) >> DC_ALPHA_SHIFT
  out[j][n]  = raw[j][n] - dc_est[j]
```

I and Q channels use the same shift parameter and identical update structure. Each accumulates independently (no I↔Q coupling).

---

## Interface

| Port | Direction | Width | Rate | Description |
| --- | --- | --- | --- | --- |
| `raw_i[3:0]` | in | 4×W_IN signed | f_s | I from decimator (W_IN = 12 or 16, TBD) |
| `raw_q[3:0]` | in | 4×W_IN signed | f_s | Q from decimator |
| `raw_valid` | in | 1 | f_s | Sample strobe from decimator |
| `clk_16m` | in | — | 16 MHz | Master clock |
| `rst_n` | in | — | — | Active-low reset. Clears dc_est to 0. |
| `dc_alpha_shift` | in | 4 | static | Right-shift applied to error term. Reset value: `DC_ALPHA_SHIFT` parameter. |
| `dc_bypass` | in | 1 | static | 1 = bypass filter (out = raw). Useful for bring-up diagnostics. |
| `out_i[3:0]` | out | 4×W_IN signed | f_s | DC-removed I per branch |
| `out_q[3:0]` | out | 4×W_IN signed | f_s | DC-removed Q per branch |
| `out_valid` | out | 1 | f_s | Registered version of `raw_valid`. One-cycle pipeline delay. |
| `dc_est_i[3:0]` | out | 4×W_EST signed | f_s | Current DC estimate I per branch (diagnostic readback) |
| `dc_est_q[3:0]` | out | 4×W_EST signed | f_s | Current DC estimate Q per branch |

---

## Parameters

| Parameter | Value | Notes |
| --- | --- | --- |
| NR | 4 | Number of receive branches |
| W_IN | 12 or 16 | Input sample width — TBD pending decimator output width decision |
| W_EST | W_IN + DC_ALPHA_SHIFT | Accumulator width; prevents truncation error accumulation |
| DC_ALPHA_SHIFT | 8 | Default time constant. τ ≈ 2^8 / f_s ≈ 2 ms at f_s=125 kS/s. Configurable at runtime via `dc_alpha_shift` port. |

---

## Implementation notes

**Accumulator width.** The DC estimate accumulator must be `W_IN + DC_ALPHA_SHIFT` bits wide to avoid rounding errors that would cause the estimate to oscillate around the true DC level. The accumulator holds the full-precision running mean; only the top `W_IN` bits are used as the estimate for subtraction.

**Settling time.** At `DC_ALPHA_SHIFT=8` and f_s=125 kS/s, the 1/e settling time is ~2 ms (256 samples). This is acceptable if the preamble is long enough to allow settling before SC correlation begins. If the design uses the first complete preamble symbol as a settling window before SC starts accumulating, 128 samples at SF7 gives roughly half a time constant — adequate to suppress large initial offsets but not optimal. A larger shift (e.g. 9 or 10) improves steady-state suppression at the cost of slower tracking. Runtime configurability via `dc_alpha_shift` allows bring-up tuning.

**Reset.** `rst_n` clears `dc_est` to zero. The filter will take one settling period to reach the true DC value after reset. Firmware must account for this in bring-up sequencing if the signal is present before reset is released.

**Bypass.** `dc_bypass=1` passes `raw` directly to `out` with a one-cycle registered delay. `dc_est` continues to update in bypass mode so that transitioning back to active mode does not require re-settling from zero.

**Pipeline depth.** One register stage (subtractor output registered). `out_valid` is `raw_valid` delayed by one cycle.

**No saturation required.** The output `out[j][n] = raw[j][n] - dc_est[j]` cannot exceed the input range if the DC estimate is bounded by the input range, which it is by construction (IIR output cannot exceed input peak). No clipping needed.

**Shared alpha.** All four branches use the same `dc_alpha_shift` value. Per-branch configurability is not required; DC offsets are a property of the mixer bias, which is similar across all four SX1257 channels on the same board.

---

## Timing

One-cycle pipeline latency from `raw_valid` to `out_valid`. The delay is absorbed into the Frontend Buffer Controller timing — the buffer controller samples `out_valid`, not `raw_valid`.

---

## Verification

| Test | Method | Pass criterion |
| --- | --- | --- |
| Step DC offset | cocotb: inject constant I+j0; measure out mean after 1024 samples | `|mean(out)| < 2 LSB` |
| AC passband — no droop | Inject sine at f_s/16; measure output RMS vs input RMS | RMS ratio > 0.99 |
| AC stopband — DC blocked | Inject sine at DC (constant) | Output < 2 LSB after settling |
| All 4 branches independent | Different DC offsets per branch | Each `out[n]` converges to its own correct offset; no cross-branch leakage |
| Bypass mode | `dc_bypass=1`, inject DC | `out = raw`; estimate still updates |
| Reset recovery | Assert/release `rst_n` mid-stream | DC estimate reinitialises to 0; re-settles within 512 samples |
| `dc_alpha_shift` runtime change | Change shift while running | No transient spike; estimate tracks new time constant |
| Worst-case accumulator | Max positive DC (2^(W_IN-1)−1) for 10^6 samples | No accumulator overflow |

---

## Related blocks

- [ΣΔ Decimator](ΣΔ%20Decimator.md) — provides W_IN-bit I+Q input at f_s
- [Frontend Buffer Controller](Frontend%20Buffer%20Controller.md) — receives DC-removed samples; performs 8-bit saturation for SRAM storage
- [SC Preamble Detector](Correlator%20Bank.md) — receives DC-removed samples directly (bypasses buffer on the live path)
- [Training Accumulator](Training%20Accumulator.md) — receives DC-removed samples after SC lock
- [Energy Measurement](Energy%20Measurement.md) — receives DC-removed samples for Σ|x|² computation
- [DSP Flow](../DSP%20Flow.md)
