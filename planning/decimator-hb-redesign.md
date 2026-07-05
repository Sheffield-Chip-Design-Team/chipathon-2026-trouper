# Decimator Redesign: CIC-3 R=16 + Halfband FIR Chain

**Status:** Standalone RTL prototype; not integrated into `trouper_top`  
**Relates to:** `planning/blocks/ΣΔ Decimator.md`, `planning/cic-only-decimator-findings.md`, `planning/decimator-hb-area-reduction.md`
## Implemented prototype (2026-06-20)

`rtl-test/rtl/sd_decimator_hb.v` implements the fixed R=64 chain and matches the packed four-channel interface of `sd_decimator_cic_tdm8`.

- CIC-3 R=16 with 16-bit modulo accumulators and round-to-nearest int8 scaling
- HB1: 11 taps, Q10 `[19, 0, -73, 0, 312, 512, 312, 0, -73, 0, 19]`
- HB2: 15 taps, Q10 `[-27, 0, 45, 0, -96, 0, 321, 512, 321, 0, -96, 0, 45, 0, -27]`
- Both FIRs exploit symmetry and zero taps, but this prototype computes all four channels in parallel. TDM sharing remains an area optimization.
- Bit-accurate analysis gives 42.0 dB SQNR at the worst tested tone (100 kHz) and approximately -0.50 dB gain at the 125 kHz chirp edge.
- `tb_decimator_hb.v` verifies 64-clock cadence, atomic valid, channel alignment, known outputs, and settled DC polarity.

Area, 32 MHz timing, wideband noise performance, and full-chain behavior remain unverified. The area estimates below are targets, not results.
SGE job 2081 mapped the parallel prototype to 574,698.97 µm² in `gf180mcu_fd_sc_mcu7t5v0` TT (21,424 cells; 2,375 flip-flops). This is 2.6-2.8× the documented 207,754-218,589 µm² TDM CIC baseline, confirming that FIR TDM sharing is required before integration.
SGE job 2082 mapped `sd_decimator_hb_tdm` to 378,107.83 µm² (11,054 cells; 2,567 flip-flops), a 34.2% reduction from the parallel prototype. Sequential elements occupy 191,592.67 µm² (50.67%), so state storage is now the dominant optimization target.


---

## Problem with current design

Both 125 kHz and 250 kHz BW use R=128 (250 kS/s output). This means:

- **125 kHz BW**: chirp edge at 62.5 kHz = Nyquist/2 → −2.74 dB droop → corrected by 2-tap EQ ✓
- **250 kHz BW**: chirp edge at 125 kHz = Nyquist → −11.8 dB droop → no fix possible ✗

The root cause: the chirp edge for 250 kHz BW lands exactly at the CIC Nyquist. Any
single-stage decimation to 250 kS/s has maximum droop there. The only fix is to oversample —
run at a higher output rate so the chirp edge is below Nyquist.

Running at 2× oversample for 250 kHz BW requires R=64. CIC-3 at R=64 has unacceptable
alias noise (SQNR = 9.6 dB). The alias noise comes from insufficient CIC stopband rejection
at the lower oversampling ratio.

---

## Proposed architecture

Three-stage chain with unified 500 kS/s output for both BWs:

```
1-bit ΣΔ @ 32 MHz  (4 branches)
        │
        ▼
  CIC-3, R=16                32 MHz → 2 MS/s
  TDM combs across 4 branches
  Accumulators: 16-bit signed
  norm_shift: >>5  (gain = 16³ = 2¹²; map to int8 headroom)
        │
        ▼
  Halfband FIR #1, 2:1       2 MS/s → 1 MS/s
  11 taps, ~3 non-trivial coefficients
  Shift-add, no multiplier
  TDM MAC across 4 branches
        │
        ▼
  Halfband FIR #2, 2:1       1 MS/s → 500 kS/s
  15 taps, ~4 non-trivial coefficients
  Shift-add, no multiplier
  TDM MAC across 4 branches
        │
        ▼
  4 × 8-bit complex IQ @ 500 kS/s
```

Total decimation: 16 × 2 × 2 = 64. Output rate: 500 kS/s.

---

## Why droop is eliminated

The CIC only decimates by R=16. At R=16, the CIC Nyquist (at 2 MS/s output) is 1 MHz.
Both chirp edges are far below 1 MHz:

| BW | Chirp edge | Fraction of CIC Nyquist | CIC-3 droop |
|---|---|---|---|
| 125 kHz | 62.5 kHz | 6.25% | −0.013 dB |
| 250 kHz | 125 kHz | 12.5% | −0.17 dB |

The halfband FIRs are equiripple flat by design in the passband. Both chirp edges
sit well within the flat region of the second halfband (passband extends to ~200 kHz,
chirp edges at 62.5 kHz and 125 kHz).

No EQ stage needed. No mode switching. Both BWs handled identically.

---

## Why alias noise is eliminated

CIC-3 at R=16 has much better alias rejection than CIC-3 at R=64 or R=128,
because the main alias band is far away relative to the passband:

| Main alias band | CIC-3 rejection |
|---|---|
| R=64 (old attempt for 250 kHz 2× OVS) | −31 dB → SQNR 9.6 dB |
| R=16 (proposed) | −51 dB at 1.75 MHz |

The halfband FIRs provide additional stopband rejection above the passband.
Combined alias noise is well below the int8 quantisation floor.

---

## Oversampling ratios at 500 kS/s output

| BW | Chirp occupies | Output Nyquist | Oversampling |
|---|---|---|---|
| 125 kHz | ±62.5 kHz | ±250 kHz | 4× |
| 250 kHz | ±125 kHz | ±250 kHz | 2× |

Both BWs are oversampled. The SX1302 downstream rejects out-of-chirp content
via its own channel filter.

### Why 2× is a floor, not a conservative margin, for 250 kHz BW

250 kHz BW already runs at the low end of what this architecture can
support — dropping to 1× oversampling (`fs_out = BW = 250 kS/s`, chirp edge
at ±125 kHz landing exactly on the new output Nyquist) is not a smaller
version of the same design, it is structurally infeasible.

The Nyquist *sampling* criterion for a complex (IQ) signal only requires
`fs ≥ BW` — 1× is not a sampling-theorem violation. The problem is the
*realizable filter*, not the sample rate: any linear-phase FIR decimation
stage needs a nonzero transition band between its passband edge and its
stopband edge (where the decimation image would otherwise fold back in). At
1× oversampling that transition band has zero width, since the passband
must extend flat all the way to Nyquist while the stopband must already
have started by Nyquist to reject the image. No finite-order FIR can do
both.

Quantifying this with the standard Harris/fred-harris equiripple order
estimate for a generic decimate-by-2 final stage (`N ≈ (A_dB − 7.95) /
(14.36 · Δf/fs_in)`, target `A_dB = 40 dB` matching the Gate 1 SQNR
threshold) and cross-checking with `scipy.signal.remez`:

| Oversampling | `Δf` (transition width) | Estimated taps | Verified droop @ edge | Verified stopband |
|---|---|---|---|---|
| 1.10× | 25 kHz | ~49 | −0.02 dB (65 taps) | −53.7 dB |
| 1.25× | 62.5 kHz | ~22 | −0.05 dB (25 taps) | −45.1 dB |
| 1.50× | 125 kHz | ~13 | −0.03 dB (15 taps) | −49.0 dB |
| 2.00× (deployed) | 250 kHz | ~9 | −0.10 dB (9 taps) | −39.1 dB |
| 1.00× | 0 kHz | ∞ | — | — |

Required order rises hyperbolically as oversampling approaches 1× and
diverges to infinity exactly at 1×. The deployed 2× point (HB2, 15 taps)
sits at the cheap end of that curve; there is no finite-tap design that
closes the gap to 1×, so the ≥2×/4× oversampling margins in the table above
are a hard architectural floor for this cascade, not a safety margin that
could be traded away for area. See `sim/notebooks/06_sd_decimator.ipynb`
Section 9 for the full derivation, sweep, and `remez` verification.

---

## Halfband FIR design parameters

### HB FIR #1 (2 MS/s → 1 MS/s)

- Input rate: 2 MS/s, output rate: 1 MS/s
- Must pass 0–300 kHz flat (guard above 250 kHz chirp edge)
- Stopband begins at 1000 − 300 = 700 kHz
- Transition bandwidth: 400 kHz = 40% of input Nyquist → very wide → few taps
- Target: 11 taps, ~3 non-trivial coefficients after symmetry + halfband zero structure
- Required stopband attenuation: ~50 dB (to keep alias noise below int8 floor)

### HB FIR #2 (1 MS/s → 500 kS/s)

- Input rate: 1 MS/s, output rate: 500 kS/s
- Must pass 0–200 kHz flat
- Stopband begins at 500 − 200 = 300 kHz
- Transition bandwidth: 100 kHz = 20% of input Nyquist
- Target: 15 taps, ~4 non-trivial coefficients
- Required stopband attenuation: ~60 dB

All non-trivial coefficients are designed as CSD (canonical signed digit) sums of
powers of 2: 2–3 shifts and adds per coefficient, no general multipliers.

---

## TDM scheduling

At 32 MHz system clock:

| Stage | Clocks per output | Branches | Clocks per branch | Operations per branch | Fits? |
|---|---|---|---|---|---|
| CIC-3 R=16 combs | 16 | 4 | 4 | 3 comb stages (combinatorial) | ✓ |
| HB FIR #1 | 32 | 4 | 8 | ~3 shift-add MACs | ✓ |
| HB FIR #2 | 64 | 4 | 16 | ~4 shift-add MACs | ✓ |

CIC integrators run per-branch every clock (cannot be TDM'd — they must accumulate
every sample). Only combs and FIR MACs are shared.

---

## Bit widths

| Node | Width | Notes |
|---|---|---|
| CIC integrators | 16-bit signed | Sized for R=16 N=3: gain = 2¹², 13 bits min |
| CIC output (pre-norm) | 16-bit signed | — |
| CIC output (post-norm >>>5) | 8-bit signed | Maps ±4096 gain to int8 range |
| HB FIR #1 input | 10-bit signed | Keep 2 extra bits through first FIR to reduce truncation |
| HB FIR #1 accumulator | 18-bit signed | Input + ~3 shift-add steps |
| HB FIR #1 output | 8-bit signed | Saturate + truncate |
| HB FIR #2 input | 10-bit signed | Same — keep extra bits |
| HB FIR #2 accumulator | 18-bit signed | — |
| HB FIR #2 output | 8-bit signed | Final int8 output |

---

## Impact on downstream blocks

| Block | Current (250 kS/s) | Proposed (500 kS/s) | Action needed |
|---|---|---|---|
| `dc_removal` | 250 kS/s | 500 kS/s | Timing constant α recalculate |
| `sc_detector` | 250 kS/s | 500 kS/s | Delay lengths change (2× samples per symbol) |
| `training_acc` | 250 kS/s | 500 kS/s | n_acc doubles for same integration time |
| `mrc_combiner` | 250 kS/s | 500 kS/s | Timing transparent |
| `sd_remod` | 250 kS/s | 500 kS/s | Interpolation ratio halves (64→32 remod cycles/sample) |
| PSRAM timing | 84 spare cycles at R=128 | 20 spare at R=64 → still fits | Verify timing margin |
| Noise estimation via Z_kk | Self-consistent | Self-consistent at 500 kS/s | No change needed — signal and noise both measured at same rate |
| `e_slice` threshold | Calibrated for 250 kS/s noise | Wider noise BW per sample | Recalibrate constant in firmware |

---

## Area estimate

| Component | Area estimate |
|---|---|
| CIC-3 R=16 integrators (per-branch, 4×) | ~40 kµm² |
| TDM comb + HB FIR compute (shared) | ~15 kµm² |
| HB FIR delay state registers (4× 14 taps × 10b × 2 stages) | ~8 kµm² |
| **Total decimator** | **~63 kµm²** |
| Current design (4× CIC-only R=128) | ~300 kµm² |
| Current TDM design (`sd_decimator_cic_tdm8`) | ~207 kµm² |

Estimated saving vs current: **~237 kµm²**. The halfband FIRs add minimal area
because they use shift-add (no multipliers) and the TDM shares compute across branches.

---

## RTL plan

New file: `rtl-test/rtl/sd_decimator_hb.v`

Structure:

```
sd_decimator_hb
 ├─ CIC-3 R=16 integrators (per-branch, 4×, update every clk_32m)
 ├─ TDM CIC comb scheduler (shared, 4 slots in 16 clocks)
 ├─ HB FIR #1 delay state (per-branch, 4× 10-bit shift registers, 14 taps)
 ├─ TDM HB FIR #1 MAC (shared, 4 slots in 32 clocks)
 ├─ HB FIR #2 delay state (per-branch, 4× 10-bit shift registers, 14 taps)
 └─ TDM HB FIR #2 MAC (shared, 4 slots in 64 clocks)
```

Interface matches `sd_decimator_cic_tdm8` (same port list):

```verilog
module sd_decimator_hb (
    input  wire        clk_32m,
    input  wire        rst_n,
    input  wire [3:0]  iq_in_i,
    input  wire [3:0]  iq_in_q,
    output reg  [31:0] iq_out_i,   // 4× int8 packed
    output reg  [31:0] iq_out_q,
    output reg  [3:0]  iq_valid
);
```

Verification plan:
1. SQNR test at 0.4×Nyquist (100 kHz tone) for both 125 kHz and 250 kHz BW modes
2. Pass threshold: >38 dB (higher bar than current 28 dB, given improved architecture)
3. Band-edge droop test: tone at chirp edge (62.5 kHz and 125 kHz), confirm < 0.5 dB
4. Alias noise test: confirm no visible alias products in spectrum at 500 kS/s output
5. Branch synchronism: all 4 branches aligned, iq_valid atomic
