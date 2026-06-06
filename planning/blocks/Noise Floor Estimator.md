# Noise Floor Estimator

RX path stage 7b. See [DSP Flow](../DSP%20Flow.md) and [Weight Generation](Weight%20Generation.md) for context.

**Owner:** TBD
**Status:** Not started

---

## Function

Maintains a per-branch exponential moving average of the noise power σ²_j, sampled during idle periods when no preamble has been detected. The estimates feed the noise-weighted MRC (NW-MRC) weight computation path.

The block operates entirely on symbol-window energy sums provided by the Energy Measurement block. It updates on each valid idle symbol window signalled by `noise_sample_en` from the Packet Control FSM. The FSM applies the near-far guard (`energy_j < NOISE_THRESH` and `!sc_lock`) before asserting `noise_sample_en`; the NFE block trusts this gate.

**Per-branch EMA update (on each `noise_sample_en` pulse):**

```
energy_per_sample_j = energy_sum_j >> SF_SHIFT          (divide by M = 2^SF)

if (n_updates == 0):
    sigma2_hw_j = energy_per_sample_j                   (cold-start seed)
else:
    sigma2_hw_j += (energy_per_sample_j - sigma2_hw_j) >> NOISE_ALPHA_SHIFT
```

`n_updates` is a saturating counter that tracks whether the EMA has been seeded.

**Software override:** Firmware may write `SIGMA2_SHADOW[0..3]` and pulse `SIGMA2_COMMIT` to replace the hardware estimates. The active estimate seen by the weight computation path is selected by `SIGMA2_SRC`:

```
sigma2_active_j = (SIGMA2_SRC == HW) ? sigma2_hw_j : sigma2_sw_j
```

This follows the same shadow/commit/source-select pattern as the weight generation block.

---

## Interface

| Port | Direction | Width | Rate | Description |
|---|---|---|---|---|
| `clk_16m` | in | — | 16 MHz | Master clock |
| `rst_n` | in | — | — | Active-low reset. Clears EMA accumulators and `sigma2_valid`. |
| `energy_sum_j[3:0]` | in | 4×32 unsigned | per symbol | Σ\|x\|² per branch per symbol window from Energy Measurement |
| `noise_sample_en` | in | 1 | per symbol | Pulse from Packet Control FSM: IDLE, !sc_lock, all energy < NOISE_THRESH |
| `sf_shift` | in | 3 | static | SF value (3–7); used as right-shift to divide energy_sum by M = 2^SF |
| `noise_alpha_shift` | in | 3 | static | EMA decay exponent; alpha = 2^(−noise_alpha_shift). Default 4 → τ ≈ 16 windows |
| `sigma2_sw_j[3:0]` | in | 4×16 unsigned | static | SW shadow — firmware-supplied σ² per branch (UQ2.14) |
| `sigma2_commit` | in | 1 | — | Strobe: copy `sigma2_sw_j` to `sigma2_sw_active_j`; self-clears next cycle |
| `sigma2_src` | in | 1 | static | 0 = HW (default), 1 = SW override |
| `sigma2_active_j[3:0]` | out | 4×16 unsigned | per symbol | Active per-branch noise estimate (mux of HW/SW); consumed by weight gen |
| `sigma2_hw_j[3:0]` | out | 4×16 unsigned | per symbol | Hardware EMA output (register readback) |
| `sigma2_valid` | out | 1 | — | At least one valid window has been accumulated since reset |
| `n_updates` | out | 8 unsigned | — | Saturating count of EMA updates (diagnostic; saturates at 255) |

---

## Parameters

| Parameter | Value | Notes |
|---|---|---|
| NR | 4 | Number of receive branches |
| W_SIGMA | 16 | Noise estimate width, UQ2.14 format (range 0–4, resolution 6×10⁻⁵) |
| W_ACC | W_SIGMA + NOISE_ALPHA_SHIFT_MAX | Accumulator width; prevents truncation error in IIR |
| NOISE_ALPHA_SHIFT_MAX | 7 | Maximum configurable alpha shift (3-bit field) |
| NOISE_ALPHA_SHIFT_DEFAULT | 4 | Default: α = 1/16, τ ≈ 16 idle symbols |

---

## Fixed-point format

`sigma2_active_j` is UQ2.14: 2 integer bits, 14 fractional bits, unsigned. Range [0, 4). This matches the energy-per-sample range after AGC normalisation (AGC target is well below 4 LSB² per sample at W_IN=12).

The EMA accumulator is `W_SIGMA + NOISE_ALPHA_SHIFT_MAX = 23` bits to hold the full-precision running mean. Only the top `W_SIGMA` bits are exposed as `sigma2_hw_j`.

---

## Implementation notes

**Cold-start seeding.** On the first `noise_sample_en` pulse after reset, the accumulator is loaded directly from `energy_per_sample_j` rather than blending from zero. This avoids a long transient from a zero prior and means the estimate is usable after a single window (with high variance). `sigma2_valid` asserts after the first update.

**Near-far guard is upstream.** The Packet Control FSM checks `energy_j < NOISE_THRESH` before asserting `noise_sample_en`. The NFE block trusts this; it does not re-check the threshold. This keeps the block simple and the guard policy in one place.

**AGC invalidation.** If any antenna's AGC gain changes, the energy scale changes and the EMA is no longer comparable to the new-gain measurements. The block asserts a `sigma2_valid=0` (invalidates) and resets the accumulator when `agc_gain_changed` is asserted. Firmware must set `SIGMA2_SRC=SW` if it needs a valid estimate immediately after a gain step; otherwise the block re-converges over the next ~16 idle symbols.

**Reset behaviour.** `rst_n` clears all accumulators and `sigma2_valid`. The first `noise_sample_en` after reset seeds the EMA from the current energy measurement (cold-start path).

**SW override commit.** `sigma2_commit` is a one-cycle strobe that copies `sigma2_sw_j` into an internal shadow register. The active estimate switches to SW on the same cycle if `SIGMA2_SRC=1`. The strobe self-clears; firmware writes the shadow registers first, then pulses commit.

**Accumulator width.** The IIR update `acc += (x - acc) >> alpha_shift` requires `acc` to be `W_SIGMA + alpha_shift` bits to preserve precision. With `NOISE_ALPHA_SHIFT_MAX=7`, the accumulator is 23 bits. The top 16 bits are registered out as `sigma2_hw_j`.

---

## Timing

One-cycle pipeline latency from `noise_sample_en` to `sigma2_hw_j` update (the output registers on the clock edge following the pulse). `sigma2_active_j` is a combinational mux of `sigma2_hw_j` and `sigma2_sw_active_j`.

`noise_sample_en` pulses once per symbol window (32–64 cycles at SF6–SF7 at 16 MHz). There is no timing pressure on the update path.

---

## Verification

| Test | Method | Pass criterion |
|---|---|---|
| Cold-start seed | First `noise_sample_en` after reset | `sigma2_hw_j == energy_sum_j >> SF_SHIFT`; `sigma2_valid=1` |
| EMA convergence | 30 windows, constant energy input | `sigma2_hw_j` within 5% of true value by window 20 |
| α = 0 (NOISE_ALPHA_SHIFT=0, α=1) | Constant energy | `sigma2_hw_j` tracks input immediately (no averaging) |
| τ = 16 windows (ALPHA_SHIFT=4) | Step change in energy level | After 16 windows, estimate is within 1/e of new level |
| SW override commit | Write SIGMA2_SHADOW, pulse SIGMA2_COMMIT, SIGMA2_SRC=1 | `sigma2_active_j == sigma2_sw_j` from next cycle |
| SW override isolation | SIGMA2_SRC=1; noise_sample_en fires | `sigma2_hw_j` continues to update; `sigma2_active_j` unchanged |
| HW→SW→HW switch | Toggle SIGMA2_SRC | `sigma2_active_j` switches cleanly; no glitch |
| AGC invalidation | Assert `agc_gain_changed` | `sigma2_valid=0`; accumulator resets; re-seeds on next `noise_sample_en` |
| All 4 branches independent | Different energy per branch | Each `sigma2_hw_j[n]` converges independently; no cross-branch leakage |
| Accumulator no overflow | Maximum energy input (all bits set) × 10⁴ windows | No accumulator overflow |
| Reset recovery | Assert/release `rst_n` | Accumulators clear; `sigma2_valid=0`; re-seeds on first update |

---

## Related blocks

- [Energy Measurement](Energy%20Measurement.md) — provides `energy_sum_j` (Σ\|x\|² per branch per symbol)
- [Packet Control FSM](Packet%20Control%20FSM.md) — provides `noise_sample_en` (gated by near-far guard and IDLE state)
- [Weight Generation](Weight%20Generation.md) — consumes `sigma2_active_j` for NW-MRC weight computation
- [DSP Flow](../DSP%20Flow.md)
