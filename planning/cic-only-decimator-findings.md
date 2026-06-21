# CIC-only Decimator: Findings

> **Status:** historical decimator note.
>
> The active RTL no longer uses four standalone `sd_decimator_cic_only.v` instances as the production top-level decimator arrangement.
> The current hard macro uses the shared TDM path in `sd_decimator_cic_tdm8.v`.
> The CIC-only findings here remain useful background for filter-quality tradeoffs, but the module/deployment wording below reflects the earlier pre-TDM integration.

## Background

Motivation: could we eliminate the 13×16 multiplier in the SD decimator entirely by
dropping the CIC compensation FIR? Prior analysis (shift-add experiment, jobs 1088–1090)
showed Yosys already finds the optimal shift-add decomposition (only −3 k µm² saving).
This investigation tests the more radical option: no FIR at all.

RTL written: `rtl-test/sd_decimator_cic_only.v` — drop-in replacement for
`sd_decimator_combchain`, identical port list, all logic on `clk_32m`, zero multipliers.

Test: `rtl-test/syn_mimo_per_module/run_sqnr_cic_only.sh` — 4 decimation ratios ×
2 variants, tone at 0.4×Nyquist (worst-case droop), pass threshold 28 dB.

## RTL SQNR Results (SGE job 1102)

Tone at 0.4×Nyquist (near band edge). Signal amplitude and noise RMS from LS sine fit.

| R | BW | Variant | Sig amp (LSB) | Noise RMS (LSB) | SQNR I | SQNR Q | Pass? |
|---|---|---|---|---|---|---|---|
| 256 | 125 kHz | combchain | 46.0 | 0.81 | 32.1 dB | 41.8 dB | ✓ |
| 256 | 125 kHz | **cic_only** | 19.6 | 0.61 | **27.2 dB** | 36.5 dB | **✗** |
| 128 | 250 kHz | combchain | 45.4 | 0.42 | 37.7 dB | 41.7 dB | ✓ |
| 128 | 250 kHz | cic_only | 19.4 | 0.41 | **30.6 dB** | **30.3 dB** | **✓** |
| 64 | 500 kHz | combchain | 46.1 | 0.44 | 37.5 dB | 33.8 dB | ✓ |
| 64 | 500 kHz | **cic_only** | 19.5 | **4.56** | **9.6 dB** | **8.1 dB** | **✗** |
| 32 | 1 MS/s | combchain | 46.6 | 5.57 | 15.4 dB | 14.1 dB | ✗ |
| 32 | 1 MS/s | cic_only | 19.8 | 11.35 | 1.8 dB | 1.3 dB | ✗ |

Pass threshold: 28 dB. Note: combchain also fails at R=32 — low OSR, debug mode only.

## What the noise decomposition reveals

At R=256 and R=128: the noise floors are nearly identical between combchain and cic_only
(~0.4–0.8 LSB RMS). The SQNR difference (32.1 vs 27.2 dB at R=256) is **entirely from
the signal amplitude** — the FIR compensates the −7.3 dB CIC droop at 0.4×Nyquist,
boosting the signal from 19.6 to 46 LSB before 8-bit quantisation. Noise is dominated
by quantisation (theoretical ≈ 0.29 LSB RMS for ±0.5 LSB uniform distribution).

At R=64: cic_only noise is **4.56 LSB vs 0.44 LSB** for combchain — a 20 dB difference.
The noise at R=64 is dominated by **sigma-delta alias noise** folding back into the
[0, 250 kHz] passband. At R=64, the CIC has only N=3 orders of alias rejection and its
first null lands at 500 kHz (the Nyquist edge). Aliases from [300–500 kHz] enter with
only −18 dB to −40 dB attenuation. The 9-tap FIR reduces the effective alias noise
through its temporal averaging (the 9-sample window spans ~18 µs = ~12 cycles of the
strongest alias at 700 kHz). The cic_only module has no such filtering.

## Why the Python model was wrong

The earlier Python prediction (~34 dB for cic_only at all R) used floating-point CIC
simulation that does not model sigma-delta alias noise accurately. The Python model
applied the CIC as an ideal decimator and added only quantisation noise, missing the
real alias noise in the RTL at R=64.

**Lesson**: floating-point CIC models are inadequate for predicting alias noise at
low oversampling ratios. RTL simulation with a real ±1 sigma-delta stimulus is required.

## Deployed operating point

The raw SQNR results above tested CIC-only as a drop-in for a digital-to-digital chain
where the downstream demodulator was on-chip. That assumption is wrong for this design:
**the LoRa demodulator is off-chip (SX1302)**. The ASIC output goes through `sd_remod`
which always produces a 32 MHz ΣΔ bitstream regardless of internal IQ rate.

This changes the operating point. Both supported LoRa bandwidths use `decim_ratio=1`
(R=128) in the deployed design:

| Mode | R | decim_ratio | Oversampling | Band-edge droop | Verdict |
|---|---|---|---|---|---|
| 125 kHz BW | 128 | 1 | 2× (natural R=256) | −2.74 dB → ~0 dB w/ EQ | **PASS** |
| 250 kHz BW | 128 | 1 | 1× natural rate | −11.8 dB at Nyquist | **PASS w/ limitation** |
| 500 kHz BW | 64 | 2 | 1× natural rate | −11.8 dB + alias noise | **TEST ONLY** |

**125 kHz BW at R=128 (2× oversample):** chirp band edge lands at Nyquist/2 (62.5 kHz),
−2.74 dB CIC droop, corrected to ~0 dB by the 2-tap EQ. The extra 62.5–125 kHz
bandwidth above the chirp is rejected by the SX1302 channel filter downstream.

**250 kHz BW at R=128 (natural rate — known limitation):** chirp band edge lands at
Nyquist (125 kHz), −11.8 dB CIC droop. Ideally this BW would also run at 2× oversample
(R=64), but R=64 has unacceptable sigma-delta alias noise (SQNR ≈ 9.6 dB) — the same
problem that makes 500 kHz BW test-only. 250 kHz BW therefore runs at natural rate; the
on-chip MRC chain (SC detector, training_acc, combiner) sees the full chirp-edge droop.
The SX1302 downstream demodulator compensates partially, but this is a real sensitivity
budget item for 250 kHz BW operation.

**500 kHz BW — test mode only (not operational):** R=64 gives 9.6 dB SQNR due to
sigma-delta alias noise folding into the 500 kHz passband at this decimation ratio.
Lower R (R=32) is worse (1.8 dB). This is a fundamental CIC alias rejection limit, not
fixable by the 2-tap droop EQ (EQ corrects passband droop, not alias noise). At natural
rate (R=64) the chirp band edge also lands at Nyquist (−11.8 dB droop), compounding
the problem.

`decim_ratio=2` (R=64) is retained in hardware for factory test / RF characterisation
only. The PSRAM QPI timing budget (44 cycles write+read per iq_valid) fits within the
64-cycle iq_valid period at R=64 (20 cycles spare) so PSRAM capture works in test mode.

**R=32 (1 MHz output) is explicitly out of scope:** the PSRAM timing budget (44 cycles)
exceeds the 32-cycle iq_valid period, causing sample loss.

**FIR status:** Dropped from the design. Area saving vs combchain: ~75 k µm² per
instance (4 instances = ~300 k µm²).

**Firmware init:** Set reg 0x12 `decim_ratio = 2'b01` at startup for both 125 and 250 kHz BW.

## Files

| File | Purpose |
|---|---|
| `rtl-test/sd_decimator_cic_only.v` | Historical standalone CIC-only decimator used in earlier pre-TDM `trouper_top` integrations |
| `rtl-test/syn_mimo_per_module/run_sqnr_cic_only.sh` | A/B SQNR test script |
| `rtl-test/syn_mimo_per_module/out_sqnr_cic_only/` | RTL output files + log (NFS only) |
