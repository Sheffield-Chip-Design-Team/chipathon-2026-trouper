# DC Removal

**Block ID:** TRPR-DCR
**RTL file:** `rtl-test/rtl/dc_removal.v`
**Status:** RTL complete — spec updated to match implementation
**Spec ref:** [Trouper Chip Specification](../Trouper%20Chip%20Specification.md) §4.2

---

## Purpose

Removes residual DC bias from the four decimated int8 I+Q branches before the Frontend Buffer Controller, SC detector, and Training Accumulator.

DC bias arises from the SX1257 direct-conversion mixer. An unremoved DC component:
- biases the SC autocorrelation metric (false lock risk)
- adds a spurious DC product to `Z_kl = Σ rx_k · conj(rx_l)` (corrupts channel estimation)
- inflates `ZDIAG_k = Σ|rx_k|²` (corrupts noise EMA and AGC)

---

## Algorithm

```
Per branch k (k = 0..3), per sample n, updated on raw_valid only:

  diff_k[n]  = raw_k[n] - acc_k[n-1][11:4]         // 9-bit signed: raw − dc_est_prev
  acc_k[n]   = acc_k[n-1] + sign_extend(diff_k, 12) // full error, no right-shift
  dc_est_k   = acc_k[n][11:4]                       // integer part of Q8.4 accumulator
  out_k[n]   = raw_k[n] - acc_k[n-1][11:4]          // pre-update estimate (1-cycle lag)
```

I and Q channels are independent; each has its own accumulator. All four branches process in parallel within one module.

**Why full error (not `diff>>4`):** Adding the shifted error `diff>>4` introduces a ±15 LSB convergence deadband — small positive DC values floor to zero and stall the accumulator. Adding the full `diff` eliminates this asymmetry while preserving the same effective time constant, because the DC estimate `acc[11:4]` absorbs only the integer part of the accumulated error on each cycle.

**Effective time constant:** Let `z = acc/16`. Then:
```
z[n] = (15/16)·z[n-1] + (1/16)·x[n]   →   α = 1/16 = 2⁻⁴,  τ = 16 samples
```
At 250 kS/s: **τ = 64 µs**. 90% settling in ≈ 37 samples (< ¼ of a SF7 symbol).

---

## Interface

| Port | Dir | Width | Description |
|---|---|---|---|
| `clk_32m` | in | 1 | 32 MHz core clock |
| `rst_n` | in | 1 | Active-low reset; clears all accumulators and output regs |
| `raw_i0..i3` | in | 4 × 8b | Signed int8 I from decimators, branches 0–3 |
| `raw_q0..q3` | in | 4 × 8b | Signed int8 Q from decimators, branches 0–3 |
| `raw_valid` | in | 1 | Sample strobe from decimator (250 kHz effective) |
| `out_i0..i3` | out | 4 × 8b | DC-removed signed int8 I, branches 0–3 |
| `out_q0..q3` | out | 4 × 8b | DC-removed signed int8 Q, branches 0–3 |
| `out_valid` | out | 1 | `raw_valid` delayed by 1 `clk_32m` cycle |

Ports removed from earlier planning: `dc_alpha_shift`, `dc_bypass`, `dc_est_i/q`. These are not present in the current RTL.

---

## Parameters

| Parameter | Value | Notes |
|---|---|---|
| NR | 4 | Branches (hardcoded; not a Verilog parameter) |
| W_IN | 8 | int8 input (hardcoded; planning doc TBD resolved to 8) |
| W_ACC | 12 | Q8.4 accumulator width |
| α | 1/16 = 2⁻⁴ | Hardcoded; not runtime-configurable |
| τ | 16 samples | 64 µs at 250 kS/s |

---

## Implementation notes

**No output saturation.** `out = raw - dc_est`. Since `dc_est` is a leaky average of `raw`, it is bounded within the input dynamic range. The subtraction cannot overflow int8 by more than 1 LSB (at most during the first sample after reset), and that transient is harmless.

**Accumulator bounds.** Maximum sustained input is +127. Maximum accumulator value = 127 × 16 = 2032 < 2047 = 2¹¹ − 1. No overflow possible for int8 inputs.

**Pipeline depth.** Exactly one `clk_32m` register stage between `raw_valid` and `out_valid`. The Frontend Buffer Controller and SC detector use `out_valid` as their sample strobe.

**Reset behaviour.** All 8 accumulators and all 8 output registers clear to zero on `rst_n` de-assertion. With a non-zero input already present before reset, the filter re-settles within ~37 samples (one 90% time constant).

**No dc_alpha_shift port.** The time constant is fixed at α = 1/16. If a different time constant is needed for a future design iteration, the accumulator width and the `acc[11:4]` extract must both change.

---

## Verification

| Test | Method | Pass criterion |
|---|---|---|
| Step DC — I branch | cocotb: inject constant `raw_i0 = +64` for 1024 samples | `mean(out_i0)` over last 512 samples < 1 LSB |
| Step DC — all branches | Inject different constant DC per branch (+32, −48, +10, −5) | Each `out_k` converges independently; no cross-branch leakage |
| AC passband | Inject complex sine at 1 kHz; compare RMS in vs out | Droop < 0.1 dB |
| AC stopband | Inject DC (constant) | Output < 1 LSB after 256 samples |
| Accumulator max | Inject +127 for 10⁶ samples | No overflow; `out` remains valid |
| Accumulator min | Inject −128 for 10⁶ samples | No overflow; `out` remains valid |
| Reset recovery | Assert `rst_n` mid-stream with +64 DC present; release | `out` < 1 LSB DC within 37 samples of re-enable |
| Pipeline delay | Compare `out_valid` edge relative to `raw_valid` | Exactly 1 `clk_32m` cycle |
| Bit-exact vs Python | cocotb: inject real decimated samples; compare to `sim/models/receiver.py` DC removal | Bit-exact match |

---

## Related blocks

- [ΣΔ Decimator](ΣΔ%20Decimator.md) — provides int8 I+Q at 250 kS/s
- [Frontend Buffer Controller](Frontend%20Buffer%20Controller.md) — receives `out_valid` samples; applies 8-bit saturation for SRAM storage
- [SC Preamble Detector](Correlator%20Bank.md) — receives DC-removed samples on the live path
- [Training Accumulator](Training%20Accumulator.md) — receives DC-removed samples after `sc_lock`
