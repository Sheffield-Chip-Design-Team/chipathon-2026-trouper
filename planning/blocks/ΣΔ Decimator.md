# ΣΔ Decimator

RX path stage 2. See [DSP Flow](../DSP%20Flow.md) for pipeline context.

**Owner:** TBD
**Status:** **Production = fixed R=64 half-band chain** (`sd_decimator_poly`: CIC-3 R=16 → HB1 ÷2 → HB2 ÷2 → int8 @ 500 kS/s). Migrated to production 2026-06-21.

> Canonical detail lives in [`decimator-hb-redesign.md`](../decimator-hb-redesign.md)
> (architecture), [`decimator-hb-area-reduction.md`](../decimator-hb-area-reduction.md)
> (polyphase + 14-bit CIC area work) and
> [`decimator-hb-migration-impact-plan.md`](../decimator-hb-migration-impact-plan.md)
> (Gates 0–12). The 2×/4× oversampling margins referenced below are a hard
> architectural floor, not a safety margin — see
> [`decimator-hb-redesign.md#why-2-is-a-floor-not-a-conservative-margin-for-250-khz-bw`](../decimator-hb-redesign.md#why-2-is-a-floor-not-a-conservative-margin-for-250-khz-bw)
> for why 1× oversampling is infeasible for any finite-order filter in this cascade.

Everything from here through **Verification** describes the current,
production RTL (`src/decimator/sd_decimator_poly.v`). Superseded designs and
rejected alternatives are collected under **History and rejected approaches**
near the end of this file — treat that section as background, not spec.

---

## Function

Converts the four SX1257 1-bit complex ΣΔ streams into signed 8-bit complex
IQ samples for the on-chip receive chain. **One module instance handles all
four antenna branches** via internal time-division multiplexing (TDM) —
there is no per-branch instantiation.

- Input: 4 × 1-bit I streams + 4 × 1-bit Q streams at **32 Msps**, clocked by
  `clk_32m`.
- Output: 4 × signed int8 I samples + 4 × signed int8 Q samples at
  **500 kS/s**, packed into 32-bit buses (one byte per channel) with a
  per-channel `iq_valid` strobe.
- Fixed decimation ratio **R=64** (CIC R=16 × HB1 ÷2 × HB2 ÷2). There is no
  runtime ratio selection — the LoRa bandwidth setting (`BW_CFG.bw_sel`) does
  **not** change decimator behavior at all; see
  [BW selection is downstream of the decimator](#bw-selection-is-downstream-of-the-decimator).

Internally: a 3-stage CIC (R=16, pure adders) brings the 32 Msps bitstream
down to 2 MS/s, then two cascaded half-band FIR stages (HB1, HB2 — each a
real multiply-accumulate, but each throwing away half its own arithmetic for
free by construction) take it the rest of the way to 500 kS/s while holding
passband droop to ≈ −0.17 dB (vs. −11.8 dB for the superseded CIC-only R=128
design at the 250 kHz band edge).

---

## Interface

Ground truth: `src/decimator/sd_decimator_poly.v:90-95`.

| Port | Direction | Width | Description |
| --- | --- | --- | --- |
| `clk_32m` | in | 1 | Sample clock; all logic in this block runs here |
| `rst_n` | in | 1 | Active-low reset |
| `iq_in_i` | in | 4 | I ΣΔ bitstream, one bit per antenna channel |
| `iq_in_q` | in | 4 | Q ΣΔ bitstream, one bit per antenna channel |
| `iq_out_i` | out | 32 | 4 × signed int8 I samples, packed `[ch*8 +: 8]` |
| `iq_out_q` | out | 32 | 4 × signed int8 Q samples, packed `[ch*8 +: 8]` |
| `iq_valid` | out | 4 | Per-channel valid strobe; all 4 bits pulse together (`4'hf`) once a full TDM sweep completes |

There is no `decim_ratio`, no ratio-select input of any kind, and no
`clk_16m` — those belong to the superseded design (see History section).

---

## Architecture / DSP view

### CIC primer (Stage 1)

A CIC (Cascaded Integrator-Comb) filter is a decimating low-pass filter built
entirely from adders/accumulators — no multipliers. It's the standard
front-end for converting a high-rate 1-bit ΣΔ bitstream down to a lower rate
with modest hardware, and is exactly what Stage 1 of `sd_decimator_poly` does
(`sd_decimator_poly_cic_comb` + the three integrators) before the HB1/HB2 FIR
stages take over.

**Integrators** run at the fast input rate (32 MS/s). Each is a plain
accumulator, `y[n] = y[n-1] + x[n]` — transfer function `1/(1-z⁻¹)`. Three are
cascaded per channel:

```verilog
int_i1[ch] <= int_i1[ch] + (iq_in_i[ch] ? 14'sd1 : -14'sd1);  // integrator 1
int_i2[ch] <= int_i2[ch] + int_i1[ch];                          // integrator 2
int_i3[ch] <= int_i3[ch] + int_i2[ch];                          // integrator 3
```

The 1-bit ΣΔ stream is converted to ±1 first, then integrated three times in
series.

**Combs** run at the slow output rate (2 MS/s here — every 16th cycle). A
comb is a differentiator, `y[n] = x[n] - x[n-R]` — transfer function
`1 - z⁻ᴿ`, `R` = decimation ratio. Three are cascaded, evaluated only when the
CIC strobe fires:

```verilog
assign comb1 = int3 - comb1_z;   // comb1_z = int3 delayed by one decimated sample
assign comb2 = comb1 - comb2_z;
assign comb3 = comb2 - comb3_z;
```

Because the combs only need to run at the decimated rate, decimation happens
for free between the integrator cascade and the comb cascade — no separate
anti-alias filter is needed before downsampling, since the integrators' own
gain already provides the shaping.

`H(z) = ((1 - z⁻ᴿ) / (1 - z⁻¹))^N` — N=3 is the conventional sweet spot for
ΣΔ front-ends (steeper rolloff vs. more registers/droop per extra stage).
Worst-case DC input, accumulator gain after decimation is `R^N = 16³ = 4096
= 2^12`; `int_i1/2/3` are sized **14-bit** to hold that growth (13-bit wraps
at a sustained full-scale run — see
[`decimator-hb-area-reduction.md`](../decimator-hb-area-reduction.md)), and
`sample8 = (comb3 + 16) >>> 5` removes the residual gain and saturates to
signed 8-bit.

This CIC stage is R=16 only, not the full R=64 — the remaining ÷4 comes from
HB1 (÷2) and HB2 (÷2), which restore the passband flatness a CIC-only design
would otherwise sacrifice.

### HB1 and HB2 primer (Stages 2 and 3)

Where the CIC stage above uses pure adders, HB1 and HB2 are proper FIR
filters with multipliers — but a special class called **half-band filters**,
chosen because a 2:1 decimating half-band throws away half its own
arithmetic for free.

**What makes a filter "half-band":** a half-band FIR is a symmetric lowpass
filter designed so its cutoff sits at exactly Fs/4 (half of Nyquist). That
symmetry has a well-known side effect: **every even-indexed tap except the
centre tap is exactly zero**. For a filter that's about to be evaluated only
every 2nd input sample anyway (a decimate-by-2 filter), this is a huge win —
roughly half the multiply-adds a same-length ordinary FIR would need are
already zero, so they're never computed.

**Polyphase split:** because the decimating half-band only ever evaluates its
output on every other input sample, and the odd taps are zero, the delay line
naturally splits into two independent halves that shift at different times:

- **Phase A** — the nonzero even-lag taps (HB1: lags 0,2,4,6,8,10; HB2: lags
  0,2,...,14). This line shifts once per *input* sample.
- **Phase B** — just the centre tap (HB1: lag 5; HB2: lag 7). This line
  shifts on the alternating half.

Each polyphase branch only holds ~N/2 registers instead of N, and the MAC
still reads exactly the same sample values a direct-form implementation
would — the output is bit-exact with a non-polyphase reference; it's just
organized to avoid storing (and multiplying by) the taps that are always
zero.

In the RTL, each channel gets its own phase-A/phase-B storage arrays
(`h1a_i/q`, `h1b_i/q` for HB1; `h2a_i/q`, `h2b_i/q` for HB2), and which phase
gets written on a given strobe is tracked by `hb1_phase` / `hb2_phase` toggle
bits.

**HB1 — first ÷2 stage.** Takes the CIC output (2 MS/s) down to 1 MS/s. 6
nonzero even-lag coefficients plus the centre tap, folded by symmetry
(`tap[k] == tap[10-k]`) so the MAC only needs 4 distinct multiplies:

```verilog
acc = 19  * (a0 + a5)     // lags 0,10
    - 73  * (a1 + a4)     // lags 2,8
    + 312 * (a2 + a3)     // lags 4,6
    + 512 * centre;       // lag 5 (centre tap, always kept)
scaled = (acc + 512) >>> 10;
```

The `+512 >>> 10` is rounding to nearest before truncating back to int8 —
`512 = 2^9`, half an LSB at the `>>>10` scale.

**HB2 — second ÷2 stage.** Takes HB1's 1 MS/s output down to the final
500 kS/s. Same polyphase idea, one size up: 8 nonzero even-lag taps plus
centre, folded to 4 distinct multiplies:

```verilog
acc = -27 * (a0 + a7)     // lags 0,14
    + 45  * (a1 + a6)     // lags 2,12
    - 96  * (a2 + a5)     // lags 4,10
    + 321 * (a3 + a4)     // lags 6,8
    + 512 * centre;       // lag 7
scaled = (acc + 512) >>> 10;
```

The alternating sign pattern (−, +, −, +) in both HB1 and HB2 is a signature
of a well-designed half-band lowpass: near taps reinforce and far taps
partially cancel ringing, shaping a raised-cosine-like response.

Feeding HB2: `insert_hb2_frame` shifts HB1's *already-decimated* output
samples into HB2's own phase-A/phase-B lines — so HB2's delay line runs at
1 MS/s tap-spacing, one rate below HB1's.

**Why droop nearly vanishes vs. CIC-only:** a pure 3rd-order CIC has
significant passband droop that gets worse toward the band edge. HB1+HB2
exist specifically to claw that back: each half-band stage is designed with
an optimized passband, so the cascade holds the LoRa passband to ≈ −0.17 dB
instead of the CIC-only chain's −11.8 dB at 250 kHz BW — at the cost of two
real multiplier MACs instead of zero.

**Where the coefficient values came from:** the integer taps in
`sd_decimator_poly_hb1_mac` / `_hb2_mac` (`19, -73, 312, 512` and `-27, 45,
-96, 321, 512`) are not hand-picked — they're a Parks-McClellan (Remez)
equiripple half-band design, quantized to Q10 fixed-point. Reproducible with
`scipy.signal.remez`:

```python
import numpy as np
from scipy.signal import remez

# HB1: 11 taps, fs=2 MHz. Passband edge 300 kHz (guard above the 250 kHz
# chirp edge), stopband edge 700 kHz -- both symmetric about Fs/4 = 500 kHz,
# which is what makes this a half-band design (forces even taps to zero).
h1 = remez(11, [0, 300e3, 700e3, 1e6], [1, 0], fs=2e6)
q1 = np.round(h1 * 1024).astype(int)
# -> [19, 0, -73, 0, 312, 512, 312, 0, -73, 0, 19]  (matches RTL exactly)

# HB2: 15 taps, fs=1 MHz. Passband edge 200 kHz, stopband edge 300 kHz,
# symmetric about Fs/4 = 250 kHz.
h2 = remez(15, [0, 200e3, 300e3, 500e3], [1, 0], fs=1e6)
q2 = np.round(h2 * 1024).astype(int)
# -> [-27, 0, 45, 0, -96, 0, 321, 512, 321, 0, -96, 0, 45, 0, -27]  (matches RTL exactly)
```

Steps: (1) set the spec from the band-edge requirements above — both band
pairs are symmetric about Fs/4, which is the half-band constraint (it isn't
imposed separately; it falls out of the equiripple solution for these
particular edges); (2) run Remez for the target tap count (11 / 15); (3)
quantize to Q10 (`×1024`, round to nearest — a half-band centre tap is always
`0.5` in float, so `0.5 × 1024 = 512` exactly); (4) fold by linear-phase
symmetry (`tap[k] == tap[N-1-k]`) so the RTL only stores/multiplies the
distinct pairs. Re-running this recipe reproduces the deployed RTL
coefficients bit-for-bit — the traceable source of truth if the
passband/stopband spec ever needs to change.

---

## Parameters and scaling

| Item | Value | Notes |
| --- | --- | --- |
| CIC stages `N` | 3 | Same for I and Q |
| CIC ratio `R` | 16 | Fixed, not runtime-selectable |
| CIC integrator/comb width | 14-bit signed | Bit-exact minimum for sustained full-scale input |
| HB1 taps | 11 (6 nonzero even + centre) | Q10, folded to 4 distinct multiplies |
| HB2 taps | 15 (8 nonzero even + centre) | Q10, folded to 4 distinct multiplies |
| Overall decimation `R` | 64 (16 × 2 × 2) | Fixed — no runtime ratio select |
| Output width | 8-bit signed | Saturated at each of CIC/HB1/HB2 |
| Output rate | 500 kS/s | Fixed, independent of LoRa BW setting |

---

## Timing and latency

- CIC integrators update every `clk_32m` cycle; the CIC strobe (comb
  evaluation + HB1 phase-A/phase-B insert) fires every 16 cycles.
- The HB1/HB2 MAC is a ~40-logic-level combinational cone that cannot settle
  in one 31.25 ns cycle at the SS timing corner. Each MAC evaluation is
  therefore **paced 3 cycles** (`MAC_WAIT=2`, i.e. held for `MAC_WAIT+1=3`
  cycles), matched by `set_multicycle_path 3` in the SDC.
- HB1 processes all 8 streams (4 channels × I/Q) as a paced burst — 8 × 3 =
  24 clocks — once per 16-clock CIC cadence. Because the centre tap
  (`h1b`) shifts every 16 clocks but the HB1 burst takes 24, the centre value
  is snapshotted (`h1bc_snap_i/q`) at burst start and held fixed for all 8
  streams, so a mid-burst shift can't corrupt it partway through.
- HB2 fires once per 64-clock window, also 8 streams TDM'd, also 3-cycle
  paced.
- `iq_valid` pulses all 4 bits together (`4'hf`) once HB2's last stream
  (Q3) completes — output arrival is TDM-synchronized across all 4 channels
  by construction, not by a separate alignment mechanism.

---

## BW selection is downstream of the decimator

The decimator has **no BW or ratio-select input** — it always runs fixed
R=64 → 500 kS/s. `BW_CFG.bw_sel` (register `0x0A`, see
[Register Map](../Register%20Map.md)) only sets `sample_shift`, consumed by
`packet_ctrl_fsm.v`, `sc_detector.v`, `training_acc.v`, and
`psram_buf_ctrl.v` to compute the LoRa symbol length
`M = 2^(SF+sample_shift)` in the *decimated* sample domain:

| LoRa BW | `bw_sel` | `sample_shift` | Oversampling | Samples/symbol `M` |
| --- | --- | --- | --- | --- |
| 250 kHz | 0 | 1 | 2× | `2^(SF+1)` |
| 125 kHz | 1 | 2 | 4× | `2^(SF+2)` |

Both bandwidths see the same 500 kS/s decimator output; only the downstream
symbol-length arithmetic differs. The 2×/4× oversampling floors are
architectural, not conservative margin — see the redesign doc link at the
top of this file.

---

## Coherence properties

`sd_decimator_poly` is a **single module instance** that TDMs all 4 antenna
channels through shared CIC and HB1/HB2 datapaths. This is a stronger
guarantee than the old multi-instance design it replaced: there is no
cross-instance clock-skew or reset-phase risk to manage, because there are no
separate instances — all 4 channels' CIC integrators update in the same
`always @(posedge clk_32m)` block on the same edge, and the HB1/HB2 stream
order (`hb1_stream`/`hb2_stream` counters) is fixed and deterministic.
`iq_valid` asserting all 4 bits together is a direct consequence of this
single-instance TDM structure, not a separately-verified alignment property.

Downstream blocks (training accumulator, combiner) still require all 4
channels to originate from the same decimator sweep — that's automatically
true here since there's only one sweep per output period.

---

## Area

Standalone decimator (`sd_decimator_poly`, FD TT synthesis): **≈325,761 µm²**
(SGE 2099, `sd_decimator_hb_poly`), down from a 378,108 µm² HB baseline
(**−13.8%**, from 14-bit CIC trim + polyphase delay lines). Full derivation
and further candidate levers: [`decimator-hb-area-reduction.md`](../decimator-hb-area-reduction.md).
This supersedes the pre-migration CIC-only area figures in the History
section below — do not quote those as current.

---

## Verification

- **Functional regression:** cocotb SF/BW sweep in
  `rtl-test/tb/test_trouper_top.py` (SF7–SF12 × BW250/BW125) exercises the
  decimator as part of the full RX chain.
- **Bit-exactness proof:** `sd_decimator_hb_poly`/`sd_decimator_hb_w14`
  candidates were proven bit-exact against the `sd_decimator_hb_tdm`
  reference (cycle-for-cycle, including sustained ±full-scale CIC corner
  cases) — see `rtl-test/tb/tb_hb_{w14,poly}_equiv.v` and
  [`decimator-hb-area-reduction.md`](../decimator-hb-area-reduction.md).
- **Droop/SQNR:** passband droop and SQNR figures for the HB chain are
  tracked in [`decimator-hb-redesign.md`](../decimator-hb-redesign.md), not
  in this doc.

---

## History and rejected approaches

Everything in this section is **historical background, not current spec**.
Some file links point at RTL that has since been deleted from the repo;
those are called out inline.

### Superseded CIC-only R=128 design

Before the 2026-06-21 HB migration, production was **CIC-only**: 3 CIC
integrator stages, 3 comb stages, fixed per-rate right-shift normalisation,
8-bit saturation, no FIR compensation, no multiplier. The interface
supported a 2-bit `decim_ratio` select (`0=R256, 1=R128, 2=R64, 3=R32`) plus
a `clk_16m` port accepted for compatibility but unused. Both supported LoRa
bandwidths ran at `R=128` → 250 kS/s; `R=64` (500 kHz) measured ~9.6 dB SQNR
and was never supported; `R=128` measured ~30.6 dB SQNR, above the adopted
28 dB floor. The final LoRa channel filtering was performed downstream by
the SX1302, which is why CIC-only droop was acceptable at the time. Primary
reference result: [`planning/cic-only-decimator-findings.md`](../cic-only-decimator-findings.md).

The deployed RTL for this design lived at `rtl-test/sd_decimator_cic_only.v`
— **this file has since been deleted from the repo**, superseded by
`src/decimator/sd_decimator_poly.v`.

Pre-migration area snapshot (2026-06-11, standalone `trouper_top` with this
CIC-only decimator): total top ~879.9 kµm², decimator bank 4 × 75.1 kµm² =
300.2 kµm² (~34.1% of top). **Do not quote this as current** — see the
[Area](#area) section above for the current figure.

### Rejected alternative: `sd_decimator_cic_tdm8` (earlier R=256 variant)

An earlier `sd_decimator_cic_tdm8` implemented a boxcar-4 pre-stage + 4-slot
TDM CIC(N=3, R=64) across all 4 channels, fixed at R=256 (125 kHz only) —
rejected because it permanently eliminated 250 kHz BW support, halved
downstream output rate (250→125 kS/s, a non-trivial re-verification burden
for every downstream block), and its area saving (~43 kµm², 14.5% of the
decimator block) didn't justify the risk.

A later synthesis-only structural TDM experiment reused the same filename
for a *different* design — a boxcar-4 front end + shared 4-slot CIC back end
totalling `R=128` (still 250 kS/s, not the rejected R=256 variant above).
Measured: 300.2 kµm² (4× CIC-only baseline) → 207.1 kµm² test RTL (−31%,
structural estimate only, includes TDM control logic). Simulation-validated
(iverilog, SGE jobs 1608/1612) against `sd_decimator_cic_only` at R=128,
after fixing two bugs (a shared-stage frame-overrun dropping 1-in-5 frames,
and a normalisation shift copied from the wrong `decim_ratio` case). Post-fix
it matched the CIC-only reference to within ±1 LSB (expected — different
passband response from partitioning, bit-exactness wasn't a goal), zero
inter-branch skew. This experimental RTL is still on disk at
[`rtl-test/rtl/sd_decimator_cic_tdm8.v`](../../rtl-test/rtl/sd_decimator_cic_tdm8.v)
(testbench: [`rtl-test/tb/tb_sd_decimator_cic_tdm8.v`](../../rtl-test/tb/tb_sd_decimator_cic_tdm8.v))
as a synthesis reference; it was never instantiated in `trouper_top.v`, and
is now superseded in intent by the HB migration anyway (which achieves both
FIR compensation *and* area reduction, rather than trading one for the
other).

### Optional FIR Upgrade (moot)

Pre-HB-migration, there was a proposal to keep the CIC-only baseline but add
a shared TDM+FIR compensator (~214 kµm² vs. ~300 kµm² for 4× separate FIR)
if late-stage P&R left headroom. **This is moot as of the 2026-06-21 HB
migration** — production already restores FIR compensation via the HB1/HB2
half-band stages, at less area than this proposal would have cost, and with
no timing/area gate to satisfy first. The RTL this proposal would have wired
together — `rtl-test/sd_cic_chan.v`, `sd_fir_state.v`, `sd_fir_mac.v`,
`sd_decimator_top.v` — **has since been deleted from the repo**.

---

## Related blocks

- [DSP Flow](../DSP%20Flow.md)
- [DC Removal](DC%20Removal.md)
- [Frontend Buffer Controller](Frontend%20Buffer%20Controller.md) (its RTL, `frontend_buf_ctrl.v`, was removed and replaced by `psram_buf_ctrl.v` — see [PSRAM Buffer Controller](PSRAM%20Buffer%20Controller.md) for the current block; that target doc itself hasn't been updated to say so)
- [Training Accumulator](Training%20Accumulator.md)
- [MRC Combiner](MRC%20Combiner.md)
- [ΣΔ Re-modulator](ΣΔ%20Re-modulator.md)
- [Register Map](../Register%20Map.md)
