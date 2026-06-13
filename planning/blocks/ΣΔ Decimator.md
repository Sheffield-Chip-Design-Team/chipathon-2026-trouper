# ΣΔ Decimator (CIC-only, deployed)

RX path stage 2. See [DSP Flow](../DSP%20Flow.md) for pipeline context.

**Owner:** TBD  
**Status:** Deployed — `sd_decimator_cic_only`, CIC N=3, `decim_ratio=1` for all supported modes

---

## Function

Converts each SX1257 1-bit complex sigma-delta stream into signed 8-bit complex IQ samples for the on-chip receive chain. There is one identical decimator per antenna branch.

The input bitstream runs at **32 Msps**, clocked by `clk_32m`. Each CIC integrator stage advances on every `clk_32m` cycle, so the CIC input rate equals the clock rate.

The production implementation is **CIC-only**:

- 3 CIC integrator stages running at `clk_32m`
- 3 CIC comb stages evaluated on the decimation strobe
- fixed per-rate right-shift normalisation
- 8-bit output saturation
- no FIR compensation, no multiplier, no `clk_16m` logic

The deployed RTL is [`rtl-test/sd_decimator_cic_only.v`](../../rtl-test/sd_decimator_cic_only.v).

---

## System-level operating point

The block interface still supports four `decim_ratio` encodings, but the **system specification supports only two LoRa bandwidths** and uses a single runtime setting in normal operation:

| LoRa BW | Firmware setting | CIC ratio | Output rate | Samples/symbol | Support status |
| --- | --- | --- | --- | --- | --- |
| 125 kHz | `decim_ratio=1` | R=128 | 250 kS/s | `2^(SF+1)` | Supported |
| 250 kHz | `decim_ratio=1` | R=128 | 250 kS/s | `2^SF` | Supported |
| 500 kHz | `decim_ratio=2` | R=64 | 500 kS/s | `2^SF` | Not supported in product |
| 500 kHz, 2× OS | `decim_ratio=3` | R=32 | 1 MS/s | `2^(SF+1)` | Debug / lab only |
| 125 kHz, 1× Nyquist | `decim_ratio=0` | R=256 | 125 kS/s | `2^SF` | Legacy analysis only |

**Important system decision:** both supported bandwidths run at `R=128`. For 125 kHz LoRa this is intentionally 2× oversampled at the ASIC IQ boundary; the downstream `sd_remod` and SX1302 channel filter absorb the extra bandwidth.

---

## Why CIC-only is acceptable in the deployed design

The original FIR-compensated decimator was dropped for area. CIC-only is acceptable for the shipped receive path because the system no longer exposes the CIC output directly to a LoRa demodulator.

The deployed chain is:

```text
SX1257 ΣΔ ADC -> CIC decimator -> on-chip DSP -> ΣΔ re-modulator -> SX1302
```

That changes the requirement:

- the ASIC only needs enough IQ fidelity for on-chip detection, training, combining, and re-modulation
- the final LoRa channel filtering is performed downstream by the SX1302
- 125 kHz mode can therefore run at 250 kS/s without requiring a flat FIR-equalised 125 kS/s handoff

Measured RTL result from [`planning/cic-only-decimator-findings.md`](../cic-only-decimator-findings.md):

- `R=128` gives about **30.6 dB SQNR**, which passes the adopted 28 dB floor
- `R=64` gives about **9.6 dB SQNR**, so 500 kHz mode is not supported

---

## Interface

The production module keeps the old drop-in port list for compatibility with earlier wrappers.

| Port | Direction | Width | Description |
| --- | --- | --- | --- |
| `clk_32m` | in | 1 | Main sample clock; all active logic runs here |
| `clk_16m` | in | 1 | Accepted for compatibility, unused internally |
| `rst_n` | in | 1 | Active-low reset |
| `iq_in_i` | in | 1 | I sigma-delta bitstream from SX1257 |
| `iq_in_q` | in | 1 | Q sigma-delta bitstream from SX1257 |
| `decim_ratio` | in | 2 | Ratio select: `0=R256`, `1=R128`, `2=R64`, `3=R32` |
| `iq_out_i` | out | 8 signed | Saturated decimated I sample |
| `iq_out_q` | out | 8 signed | Saturated decimated Q sample |
| `iq_valid` | out | 1 | Output-valid strobe, stretched to 2 `clk_32m` cycles |

---

## Parameters and scaling

| Item | Value | Notes |
| --- | --- | --- |
| CIC stages `N` | 3 | Same for I and Q |
| Integrator / comb width | 26-bit signed | Sized for worst-case growth at `R=256` |
| Output width | 8-bit signed | Saturated, not rounded-to-nearest |
| Normalisation shift | `17 / 14 / 11 / 8` | For `R=256 / 128 / 64 / 32` |
| Decimation counter compare | `255 / 127 / 63 / 31` | Produces strobe every `R` input samples |

CIC gain is `G = R^3`, so the per-rate right shift is:

- `R=256 -> 24 - 7 = 17`
- `R=128 -> 21 - 7 = 14`
- `R=64  -> 18 - 7 = 11`
- `R=32  -> 15 - 7 = 8`

This matches the implemented `norm_shift` mapping in the RTL.

---

## Timing and latency

Pipeline structure in the deployed RTL:

1. integrators update every `clk_32m` cycle
2. when the decimation counter hits the selected terminal count, `cic_strobe` pulses
3. comb subtraction and right shift are evaluated on that strobe
4. one cycle later the output register latches `iq_out_i/q`
5. `iq_valid` stays high for **two** `clk_32m` cycles so slower consumers derived from `/2` clocks cannot miss it

The block therefore has deterministic fixed latency and remains phase-aligned across branches as long as all instances share the same clock, reset, and `decim_ratio`.

---

## Multi-branch coherence requirement

The training accumulator and combiner assume all receive branches are sample-aligned. A permanent one-sample offset between decimator instances silently corrupts cross-correlation.

Required conditions:

- all instances share the same `clk_32m`
- all instances share the same `decim_ratio`
- reset release must be phase-consistent across all instances so the decimation counters start together

Physical checks to keep in the top-level signoff list:

- verify clock skew is comfortably below one `clk_32m` period
- verify reset distribution or use a shared synchronised reset release before the decimator bank

---

## Supported vs unsupported modes

### Supported product modes

- `125 kHz BW` with `decim_ratio=1` (`R=128`, 250 kS/s)
- `250 kHz BW` with `decim_ratio=1` (`R=128`, 250 kS/s)

### Unsupported in product

- `500 kHz BW` with `decim_ratio=2` because CIC-only SQNR is too low

### Retained only for compatibility / lab work

- `decim_ratio=0` (`R=256`)
- `decim_ratio=3` (`R=32`, 1 MS/s)

These modes remain encoded in the module interface and are useful for bench comparison, but they are not part of the ASIC system specification.

---

## Rejected alternative: `sd_decimator_cic_tdm8` (earlier R=256 variant)

> **Note:** this section describes an **earlier R=256 variant** that carried the
> same filename. The RTL currently on disk is the **R=128 (250 kS/s)** staged
> TDM experiment described under
> [2026-06-11 structural TDM experiment](#2026-06-11-structural-tdm-experiment),
> which does **not** suffer the rate/BW objections below.

The earlier `sd_decimator_cic_tdm8` implemented a boxcar-4 pre-stage + 4-slot TDM CIC(N=3, R=64) across all 4 channels. It was evaluated and **rejected** for the following reasons:

- **Fixed at R=256 (125 kHz only).** The system requires both 125 kHz and 250 kHz BW modes, both served at R=128 by `sd_decimator_cic_only`. Using `tdm8` eliminates 250 kHz mode permanently.
- **Output rate halves** from 250 kS/s to 125 kS/s. Every downstream block (`dc_removal`, `sc_detector`, `mrc_combiner`, front buffer write rate, SDC input delay) was sized for 250 kS/s — a non-trivial re-verification burden.
- **Area saving is too small to justify the risk.** Synthesis shows 256,779 µm² vs 300,207 µm² for 4× CIC-only — a saving of ~43 kµm² (14.5% of the decimator block, ~2.3% of die area). This does not unlock any new floorplan floor.
- No FIR compensation (identical signal quality to current CIC-only).

The module stays on disk as a synthesis reference. It will not be instantiated in `trouper_top.v`.

---

## Current area context

Fresh `chipathon26` FD-cell synthesis of the current standalone `trouper_top`
(`2026-06-11`, current checked-in RTL boundary with `spi_slave`) gives:

- total flat top area: **~879.9 kµm²**
- decimator contribution: **4 × 75.1 kµm² = 300.2 kµm²**
- decimator share of current top: **~34.1%**

Current top-level area ranking after the decimator bank:

- `training_acc`: ~132.1 kµm²
- `sc_detector`: ~107.2 kµm²
- `reg_bank`: ~83.7 kµm²
- `mrc_combiner`: ~61.8 kµm²

This confirms that the decimator bank is still the single largest remaining
area lever in the current `trouper_top`.

### 2026-06-11 structural TDM experiment

A new synthesis-only test RTL at
[`rtl-test/rtl/sd_decimator_cic_tdm8.v`](../../rtl-test/rtl/sd_decimator_cic_tdm8.v)
was written to estimate a more aggressive staged TDM architecture:

- per-branch **boxcar-4** front end at `32 MHz`
- shared **4-slot CIC** back end with total `R=128`
- integrated local scheduler / buffering / common `iq_valid` release

Measured standalone synthesis result:

| Variant | Area |
| --- | --- |
| `sd_decim_4ch_cic_only` | **300.2 kµm²** |
| `sd_decimator_cic_tdm8` test RTL | **207.1 kµm²** |
| Delta | **−93.1 kµm²** (**−31%**) |

Important scope note:

- this is a **structural area experiment only**
- it **does include** local TDM control logic
- it is now **simulation-validated** (see below) but **not** integrated into `trouper_top`
- the area number above predates the 2026-06-11 functional fixes (which added a
  4-way slot mux ahead of the shared CIC adders and changed a shift constant) —
  **re-synthesise before quoting**; the delta is expected to be small

### 2026-06-11 functional validation and fixes

The test RTL was simulation-checked against `sd_decimator_cic_only` at R=128
(iverilog, SGE jobs 1608/1612; testbench at
[`rtl-test/tb/tb_sd_decimator_cic_tdm8.v`](../../rtl-test/tb/tb_sd_decimator_cic_tdm8.v),
rerunnable via `/srv/eda/designs/timothyjabez/lora-mimo/tdm8_check/run_sim.sh`).
The TB drives all 4 branches and the reference with the same 1st-order ΣΔ
bitstream (DC at 0.5 FS, then a 30 kHz sine at 0.7 FS) and measures output
rate, amplitude, branch consistency, and Stage A frame drops.

Two functional bugs were found and fixed:

1. **Shared-stage overrun (1 in 5 frames dropped).** Stage A produced a
   4-branch frame every 4 clocks but the shared stage spent 5 clocks per frame
   (1 pickup + 4 slots), so every 5th frame was overwritten in the double
   buffer before being read — effective decimation 160 instead of 128
   (200 kS/s instead of 250 kS/s). Fixed by folding frame pickup into the
   slot-0 processing cycle (combinational `proc_en`/`proc_slot`/`proc_bank`
   view; pickup now sets `slot <= 1`), making the sweep exactly 4 clocks.
2. **Normalisation shift wrong by 7 bits.** Chain gain is boxcar-4 × 32³ =
   2¹⁷, so full scale needs `>>> 10` to map to int8 — the code used `>>> 17`
   (copied from the R=256 case of `sd_decimator_cic_only`, gain 2²⁴), which
   quantised the output to {−1, 0, +1}.

Post-fix results (800k cycles, both phases):

| Metric | tdm8 | `cic_only` R=128 |
| --- | --- | --- |
| Output interval (min/max) | 128/128 clk | 128/128 clk |
| Max \|out\| DC @ 0.5 FS | 64 | 64 |
| Max \|out\| sine @ 0.7 FS | 83 | 84 |
| Stage A frame overwrites | 0 | — |
| Inter-branch byte mismatches | 0 / 6249 samples | — |

The ±1 LSB amplitude difference vs the reference is expected: the
boxcar-4 + CIC-32 partition has a slightly different passband response than a
monolithic CIC-128; bit-exactness is not a goal.

**Branch synchronism:** the TDM is an internal processing-order detail only.
All branches share one `box_cnt` (identical input windows), the per-slot
`decim_cnt` counters stay in lockstep, and outputs are released atomically
with a common `iq_valid = 4'b1111` — zero inter-branch skew, same contract as
4× `cic_only` under common reset. Absolute group delay differs from
`cic_only` by ~100 ns (common-mode across branches), so the two decimator
types must not be mixed across branches in one chip.

Practical estimate for a hardened version of this idea is roughly **220–240 kµm²**
once extra verification-grade control and alignment logic are added. If that
estimate holds, the current top-level `trouper_top` would drop from ~879.9 kµm²
to roughly **800–820 kµm²**, with the decimator bank falling from ~34% of top
area to roughly **26–29%**.

---

## Optional FIR Upgrade

If late-stage P&R leaves headroom, the decimator can be upgraded to a shared **TDM+FIR** implementation that restores FIR compensation while still reducing area versus the old 4× FIR design.

### When to do it

Only take this upgrade if all of the following are true after top-level P&R:

- timing closes cleanly at 32 MHz
- DRC/LVS are clean
- floorplan utilisation is at or below about 55%
- at least ~86 kµm² of area headroom remains
- schedule still has several days before tapeout freeze

Otherwise ship the current CIC-only path.

### What it buys

| Metric | CIC-only current | Optional TDM+FIR |
| --- | --- | --- |
| Decimator area | ~300 kµm² | ~214 kµm² |
| Sensitivity / passband | droop accepted | full FIR-compensated response |
| Multiplier count | 0 | 1 shared 13×16 MAC |
| Status | deployed | optional late-stage upgrade |

The point of this upgrade is not to restore the old large FIR architecture. The point is to keep the FIR benefit while sharing the expensive arithmetic across channels.

### Architecture summary

The concise structure is:

```text
sd_decimator_top
|- sd_cic_chan  x4   (per-channel CIC path at 32 MHz)
|- sd_fir_state x4   (per-channel FIR delay state)
`- sd_fir_mac   x1   (shared FIR MAC / scheduler)
```

Guiding constraint:

- CIC integrators stay per-channel because folding them would require a much faster clock
- FIR arithmetic is the part worth sharing because it only runs at the decimated rate

### Implementation status

Relevant RTL already exists:

- [`rtl-test/sd_cic_chan.v`](../../rtl-test/sd_cic_chan.v)
- [`rtl-test/sd_fir_state.v`](../../rtl-test/sd_fir_state.v)
- [`rtl-test/sd_fir_mac.v`](../../rtl-test/sd_fir_mac.v)
- [`rtl-test/sd_decimator_top.v`](../../rtl-test/sd_decimator_top.v) — integration wrapper / upgrade target

### Minimum upgrade plan

1. Wire `sd_decimator_top` around the existing `sd_cic_chan`, `sd_fir_state`, and `sd_fir_mac` blocks.
2. Re-run SQNR and loopback regressions against the CIC-only baseline.
3. Swap the 4× `sd_decimator_cic_only` instances in `trouper_top` for the shared top wrapper.
4. Re-run synthesis and P&R; keep the upgrade only if timing and routing still close.

### Upgrade risks

- routing congestion from concentrating FIR traffic into one shared block
- scheduler / handshake bugs in the shared FIR sequencing
- lower-than-expected area win if the shared wrapper overhead eats into the saving

---

## Verification

| Test | Method | Pass criterion |
| --- | --- | --- |
| Ratio decode | Simulate all 4 `decim_ratio` values | Output rate matches selected `R` |
| Output strobe stretch | Check `iq_valid` width | Exactly 2 `clk_32m` cycles |
| DC scaling | Drive constant `+1/-1` stream | No overflow beyond 8-bit saturation behavior |
| Supported-mode SQNR | RTL tone test at `R=128` | `SQNR >= 28 dB` |
| Unsupported-mode guardrail | RTL tone test at `R=64` | Confirms 500 kHz mode remains below spec and unsupported |
| Branch alignment | Instantiate 4 identical decimators | Coincident `iq_valid`; identical outputs for identical inputs |
| FIR-upgrade gate | If TDM+FIR is enabled, compare against CIC-only and re-run top-level P&R | Keep only if SQNR improves and timing/routing still close |

Primary reference result: [`planning/cic-only-decimator-findings.md`](../cic-only-decimator-findings.md).

---

## Related blocks

- [DSP Flow](../DSP%20Flow.md)
- [DC Removal](DC%20Removal.md)
- [Frontend Buffer Controller](Frontend%20Buffer%20Controller.md)
- [Training Accumulator](Training%20Accumulator.md)
- [MRC Combiner](MRC%20Combiner.md)
- [ΣΔ Re-modulator](ΣΔ%20Re-modulator.md)
- [Register Map](../Register%20Map.md)
