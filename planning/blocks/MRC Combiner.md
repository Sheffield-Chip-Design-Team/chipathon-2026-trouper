# MRC Combiner

RX path stage 8. See [DSP Flow](../DSP%20Flow.md) for context.

**Owner:** TBD
**Status:** Not started

---

## Function

Time-domain, sample-by-sample combining of 4 antenna inputs using weight vector W written by on-chip PicoRV32 firmware into the shadow weight bank. There is no instantiated Trouper `weight_gen` RTL block in the tapeout plan. Supports two modes:

**MRC:** inner product — scalar output
```
y[n] = sat8( (w^H · x[n] >>> 8) << pgs )
//  4 complex MACs → int32 accumulator
//  >>> 8  Q0.7 guard shift  (÷256, i.e. effective weight = W_byte / 128)
//  << pgs  adaptive post-gain shift (COMB_POST_GAIN_SHIFT, 0–7)
//  sat8   saturate to signed int8
```

**Passthrough (bypass):** single-antenna direct route, W ignored
```
y[n] = x[bypass_sel][n]   // 1 antenna, int8 direct — no ÷2 applied
```
`bypass_sel` is the index of the lowest-numbered antenna with its `ANTENNA_EN` bit set, decoded from the `bypass_ant` input.

W is produced by firmware after `training_done` from the Training Accumulator. Until current-packet W is valid, the combiner must not output zeros; it falls back to the selected bypass antenna so the SX1302 continues seeing a valid single-antenna LoRa stream. In passthrough mode W registers are not read.

---

## Interface

| Port | Direction | Width | Rate | Description |
| --- | --- | --- | --- | --- |
| `x_i[3:0]` | in | 4×8 signed | f_s | I from decimators (4 antennas) |
| `x_q[3:0]` | in | 4×8 signed | f_s | Q from decimators |
| `x_valid` | in | 1 | f_s | Sample strobe |
| `W_re[3:0]` | in | 4×8 signed | static | W vector real — from W register bank (int8 Q0.7) |
| `W_im[3:0]` | in | 4×8 signed | static | W vector imaginary (int8 Q0.7) |
| `W_valid` | in | 1 | static | Current-packet W has been atomically committed to the active W bank |
| `mode` | in | 1 | static | 0 = MRC; 1 = passthrough |
| `bypass_ant[1:0]` | in | 2 | static | Index (0–3) of antenna to route in passthrough mode; decoded from ANTENNA_EN by control logic |
| `clk_32m` | in | — | 32 MHz | Master clock |
| `rst_n` | in | — | — | Active-low reset |
| `y_i` | out | 8 signed | f_s | Combined I output (MRC: (acc>>>8)<<pgs saturated to int8; bypass: direct int8) |
| `y_q` | out | 8 signed | f_s | Combined Q output (MRC: (acc>>>8)<<pgs saturated to int8; bypass: direct int8) |
| `y_valid` | out | 1 | f_s | Sample strobe |

---

## Parameters

| Parameter | Value | Notes |
| --- | --- | --- |
| W precision | int8 Q0.7 | Written by firmware; effective weight W_eff = W_byte / 128. Firmware caps W_byte ≤ 120 to preserve ≥ ½ LSB headroom. |
| x precision | 8-bit signed | From decimators; typical operating range A ≤ 90 |
| Accumulator | int32 | 8×8 = 16-bit product; 4 complex MACs; worst-case acc ≈ 4×120×90 = 43 200; 16 bits needed; int32 has 16 bits of headroom |
| MACs per sample | 4 complex = 8 real MACs | Serialised I/Q: 2 multipliers, 11-cycle FSM |
| Guard shift | `acc >>> 8` | Q0.7 normalisation: divides accumulator by 256, yielding effective output in approximately the same range as a single branch input |
| Post-gain shift | `<< pgs`, pgs ∈ 0–7 | Adaptive amplitude recovery (COMB_POST_GAIN_SHIFT). Firmware Step 3 sets pgs to target ≈ 90 combined counts. |
| Output | int8 signed | MRC: sat8((acc>>>8)<<pgs); bypass: direct int8 from antenna |

---

## Flat-fading assumption and antenna spacing

The scalar combining scheme (`y[n] = w^H · x[n]`) assumes each branch's channel `h_j` is a **complex scalar** — a single amplitude and phase. The weight `w_j = conj(Z_j)` then applies an exact phase correction for branch j, regardless of how large that phase is. Phase differences between branches can be anywhere from 0 to 2π (at 868 MHz with half-wavelength spacing the direct-path phase difference alone spans π radians), and the scalar weight handles all of these correctly.

This assumption holds as long as the **inter-branch delay spread** is small relative to one sample period (8 µs at 125 kHz / 2.4 km equivalent path length). If delay spread exceeds one sample, `h_j` is multi-tap and a scalar weight can only align one tap — combining gain degrades.

**Antenna spacing constraint:** the four antennas must be physically close enough that inter-branch delays are well below one sample. For this design, antennas are co-located on the same board or enclosure at separations comparable to the wavelength (~34 cm at 868 MHz, so a few centimetres to a few tens of centimetres). At these separations, the geometric delay difference between branches is at most a few nanoseconds — orders of magnitude below 8 µs. The flat-fading, scalar-weight model is valid.

Distributed antenna deployments (antennas hundreds of metres apart) are outside the design intent and would require per-branch equalisation rather than a scalar weight.

---

## Implementation notes

**MAC structure.** Each complex MAC: `acc_re += W_re×x_i − W_im×x_q`, `acc_im += W_re×x_q + W_im×x_i`. Four complex MACs per sample.

**Output headroom.** MRC coherently adds branch amplitudes. The firmware path writes int8 Q0.7 weights proportional to either `conj(H_j)` (row-sum MRC) or the dominant eigenvector of the Z matrix, normalised so the strongest branch weight ≤ 120. The combiner applies a `>>> 8` Q0.7 guard shift (÷256), then an adaptive `COMB_POST_GAIN_SHIFT` left shift (firmware Step 3) before saturating to int8. Reset value `COMB_POST_GAIN_SHIFT=0` is conservative; firmware computes the shift each packet from ZDIAG registers. Bypass output is int8 directly, preserving the full per-branch amplitude. A separate remod-facing right shift (`REMOD_BACKOFF_SHIFT`, register `0x37`, default `1`) is applied only on the MRC path before `sd_remod`, so remod safety does not depend on AGC alone. Int8 saturation remains a safety net for AGC settling transients only.

**Accumulator saturation.** After the `>>> 8` guard shift and adaptive post-gain, saturate to int8 bounds (±127) — do not allow 2's-complement wrap. This provides a safety net for AGC settling transients or unexpected strong signals, but should not be the normal operating condition.

### COMB_POST_GAIN policy

`COMB_POST_GAIN` is a packet-to-packet amplitude recovery knob for shift-MRC. It is intentionally outside weight generation: weight generation stays conservative and timing-friendly, while firmware/host can recover output level when the combined stream has headroom.

Register behavior:

```
y_guarded = mrc_accumulator >>> 8    // Q0.7 guard shift
y_out     = sat8(y_guarded <<< COMB_POST_GAIN_SHIFT)
```

Reset/default is `0`. A conservative firmware policy is:

1. Start every unknown channel/gain state at `COMB_POST_GAIN=0`.
2. Observe the combined int8 stream peak over a packet or diagnostic window.
3. If any I/Q component is near saturation, keep or return to `0`.
4. Otherwise choose the largest shift such that `observed_peak << shift <= 90`.
5. Apply the new shift for subsequent packets, not mid-packet.

The `90` target preserves roughly -3 dBFS headroom for the ΣΔ re-modulator. Larger values may be useful in lab characterization, but should be treated as an explicit tradeoff against clipping margin.

**Output latency and y_valid handshake.** The combiner propagates `x_valid` through its fixed-depth pipeline and asserts `y_valid` exactly P clock cycles later, where P is a constant determined by the RTL implementation (TBD — typically 1–4 cycles). The ΣΔ re-modulator downstream must consume samples on `y_valid` rather than assuming a fixed offset from `x_valid`. P must be recorded in the RTL as a parameter and exposed in the block's timing documentation once implementation begins. This removes the need to pre-specify latency in the spec and makes the interface self-describing.

**Live output state.** Firmware weight computation runs in parallel with the live decimator-to-remod stream. The combiner output policy is:

```
NO_W / ACQUIRING:   y = x[bypass_sel]                      // int8 direct, no shift
W_VALID, MODE=0:    y = sat8((w^H·x >>> 8) << pgs)         // MRC: Q0.7 guard + post-gain
MODE=1 passthrough: y = x[bypass_sel]                      // int8 direct, no shift
```

This makes the first packet recoverable as a single-antenna packet if W arrives late, and prevents mid-preamble silence from breaking SX1302 detection.

**W register read timing.** W registers must be double-buffered. Firmware writes `W_SHADOW`, then asserts a one-cycle commit strobe after all words are written. Hardware copies `W_SHADOW` to `W_ACTIVE` atomically and sets `W_valid`. The combiner reads only `W_ACTIVE`, so firmware writes cannot glitch live MACs. If W is invalidated mid-packet, keep using the last committed `W_ACTIVE` until firmware explicitly clears `W_valid` or changes mode.

**No-glitch switching.** `W_ACTIVE`, `ACTIVE_MODE`, and `ACTIVE_ANTENNA_EN` must update only when the receiver is idle between packets. Host writes to `MODE` or `ANTENNA_EN` update shadow configuration during an active packet and commit at the next idle boundary. If current-packet W is not ready, stay in bypass for that packet rather than switching mid-symbol or at a payload boundary.

**Degenerate case.** When only 1 antenna is enabled via `ANTENNA_EN`, W is a scalar — trivially computed by firmware. Combiner still works; unused antenna inputs are zero.

**Passthrough MUX.** In passthrough mode, a 4:1 MUX on `bypass_ant` selects the raw int8 sample from one decimator and drives it directly to `y` — no sign-extension, no shift. The MAC array is clock-gated. This MUX sits at the output stage of the combiner block so the bypass path has identical clocking and output register timing as the combining paths.

---

## Verification

| Test | Method | Pass criterion |
| --- | --- | --- |
| MRC, 4 equal antennas | Pre-load MRC W; inject 4-channel sine | Output power ≈ 4× single antenna (6 dB) |
| MRC, degenerate (1 antenna) | Set ANTENNA_EN=0001 | Output = single-antenna SNR |
| No current W | Start packet with `W_valid=0` | Output follows `bypass_ant`; REMOD_A receives a valid single-antenna stream |
| W commit | Write W shadow then commit | `W_ACTIVE` changes atomically; no partially-written W appears at output |
| W update mid-packet | Write new W via AHB-Lite during combining | Old W used until commit; no glitch |
| Safe switch | Assert W commit while packet is active | W activation is deferred until the next idle boundary |
| Mode write mid-packet | Host writes MODE/ANTENNA_EN during active packet | `ACTIVE_MODE`/`ACTIVE_ANTENNA_EN` unchanged until next idle boundary |
| Passthrough, ant0 selected | MODE=2, ANTENNA_EN=0001, inject sine on ant0, zeros on ant1–3 | y = x_ant0 (int8 direct); identical to decimator output, no amplitude reduction |
| Passthrough, ant2 selected | MODE=2, ANTENNA_EN=0100 | y[0] tracks ant2 exactly; ant0/1/3 ignored |
| Passthrough vs MRC gain | Same signal, compare MODE=0 and MODE=2 output power | MRC output ≈ 6 dB higher (4 equal antennas) |
| Latency constant | f_s input, MRC mode | `y_valid` asserts exactly P cycles after `x_valid` for every sample; P is fixed and does not vary with mode or W value |

### Precision characterisation (2026-06-13)

Verified by `rtl-test/tb/tb_mrc_fw_rand.v`: 14 fixed boundary cases + 1000 stratified
random cases (200 per pgs tier), seed=42.  Metric: `quant_loss_dB = 20·log10(y_float / y_int)`
where `y_float` uses exact float weights and `y_int` is the RTL integer output.

| pgs | A_max range | Cases | Max loss | Mean loss | Cases > 0.5 dB | MRC gain vs 1 ant (min–mean–max) |
|-----|-------------|-------|----------|-----------|----------------|----------------------------------|
| 0 | 25–90 | 200 | 0.44 dB | 0.12 dB | 0 | 0.9–6.0–10.6 dB |
| 1 | 13–24 | 200 | 1.29 dB | 0.32 dB | 37 | 0.4–6.2–11.6 dB |
| 2 | 7–12 | 200 | 1.50 dB | 0.46 dB | 81 | 1.9–7.0–12.0 dB |
| 3 | 4–6 | 200 | 2.36 dB | 0.84 dB | 130 | 2.5–8.2–12.0 dB |
| 4 | 2–3 | 200 | 1.94 dB | 1.39 dB | 160 | 7.4–10.9–12.0 dB |

**Loss source:** the dominant loss is the `>>> 8` guard-shift truncation
*before* the `<< pgs` left-shift.  Truncation discards up to 0.996 counts, which
the subsequent left-shift amplifies by 2^pgs.  Per-branch weight-ratio
quantisation (`floor(W_max × A_k / A_max)`) contributes < 0.05 dB separately.

**Operational significance:** pgs ≥ 3 cases (A_max ≤ 6) are below the
minimum useful SNR for LoRa SF12/BW125 (A_decimator ≈ 15 at design sensitivity).
In the expected operating range (**pgs = 0, A_max ≥ 25**) worst-case loss is
**< 0.5 dB** and mean is **0.12 dB** — negligible for LoRa demodulation.

**Potential improvement:** replacing `(acc >>> 8) << pgs` with the single combined
shift `acc >>> (8 − pgs)` would eliminate the amplified truncation and reduce
worst-case loss in all tiers to < 0.05 dB.  Not implemented in the current RTL;
recorded for future revision consideration.

---

## Area reduction analysis

### Implemented — Option A: Serialised I/Q multiply (2026-06-03)

**Current implementation:** `mrc_combiner.v` — **serialised I/Q**, 2 multipliers, 11-state FSM.

Measured area (Yosys, gf180mcu_as_sc_mcu7t3v3, TT/25°C/3.3 V, job 1247):

| Config | Area (µm²) | vs 4-mul baseline |
|---|---|---|
| 4-multiplier baseline (original) | 121,366 | — |
| Ser-IQ NR=4 (current) | **97,601** | **−23,765 (−19.6%)** |
| Ser-IQ NR=2 (const-prop) | **84,315** | **−23,079 (−21.5%)** |

Each complex MAC split into two sub-cycles:
- Sub-cycle 1 (`w_re`): `mul_i = w_re × x_i`, `mul_q = w_re × x_q` → save `a_r`, `c_r`
- Sub-cycle 2 (`w_im`): `mul_i = w_im × x_q`, `mul_q = w_im × x_i` (inputs swapped)
  - `prod_i = a_r − mul_i`, `prod_q = c_r + mul_q`

State count: 11 (vs 7). 11 cycles/sample used of 256-cycle budget at R=256.

### Measured cut options (not implemented)

**Option B — Reduce weight precision 16-bit → 12-bit (~−30 k, medium effort)**

12×8 multipliers instead of 16×8. Weight quantisation noise negligible for LoRa.
Would require the software-visible W register width to shrink from 16-bit to 12-bit and the firmware ABI to change accordingly, so this is not currently planned.
**Estimated result (A+B): ~60–67 k µm².**

**Option C — Fix `post_gain_shift` at synthesis time (measured: −4.3 k NR=2)**

Measured saving is only 4.3 k µm² — not worth the register-map change.

**Option D — CORDIC rotation (~−50 k net, high effort)**

Not recommended for this tapeout — high implementation risk relative to saving.

**Option E — Share multiplier with `training_acc`**

`training_acc` uses 4× 8×8 multipliers during preamble only; `mrc_combiner` uses 2× 16×8 during data phase.
Non-overlapping. A shared 16×8 unit would eliminate `training_acc`'s dedicated multipliers.
Saves area on the `training_acc` side. Moderate complexity; cross-module interface change.

---

## Related blocks

- [ΣΔ Decimator](ΣΔ%20Decimator.md) — 8-bit signed input
- [PicoRV32 Integration](PicoRV32%20Integration.md) — optional software override path via AHB-Lite
- [ΣΔ Re-modulator](ΣΔ%20Re-modulator.md) — consumes int8 input; combiner output is `sat8((acc>>>8)<<pgs)` before the remod input boundary
- [Register Map](../Register%20Map.md) — `W` vector at `0x30`–`0x3F`
- [DSP Flow](../DSP%20Flow.md)
