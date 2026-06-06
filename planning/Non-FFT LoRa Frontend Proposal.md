# Non-FFT LoRa Frontend Proposal

## Goal

Define a proposed **receive frontend chain** for a LoRa-based path that:

- keeps standard LoRa packet structure as much as possible
- avoids the current FFT-based preamble acquisition path
- preserves a viable path to `NR=4` combining
- still hands a LoRa-compatible combined stream to `SX1302`

This is a frontend proposal, not a full demodulator replacement for `SX1302`.

## Design intent

The current FFT-based acquisition block performs three jobs:

1. estimate fractional CFO
2. refine timing / symbol alignment
3. estimate per-antenna channel coefficients

The non-FFT proposal must still do those jobs, but with streaming correlator-style blocks instead of capture SRAM + FFT staging.

The intended architecture is:

`SX1257 -> decimator -> DC removal -> dechirp/correlation frontend -> CFO derotation -> LoRa-sequence training correlator -> calibration/weight generation -> combiner -> ΣΔ re-mod -> SX1302`

### CPU independence requirement

Baseline packet reception must not depend on PicoRV32 being operational.

The architectural rule is:

- the receive chain must continue to detect packets, estimate weights, select bypass versus combine, and drive the SX1302-facing output with PicoRV32 halted or held in reset
- PicoRV32 is an enhancement and control-plane block, not a correctness dependency for baseline RX
- any experimental feature that relies on firmware, including ALMMSE, EMA smoothing, or PSRAM policy refinement, must degrade cleanly to the hardware baseline when firmware is unavailable

So the intended baseline receive path is:

`SX1257 -> decimator -> DC removal -> SC/training -> hardware weight generation -> packet FSM -> combiner -> ΣΔ re-mod -> SX1302`

with PicoRV32 used only for optional policy, diagnostics, calibration updates, AGC refinement, and TDD sequencing.

## Proposed frontend chain

### 1. `ΣΔ Decimator x4`

Role:

- convert `1-bit I/Q` from each `SX1257` into low-rate complex samples
- provide `iq_valid` as the sample-enable for downstream frontend logic

Output:

- `int8` complex sample stream per branch

Notes:

- no architectural change from the current plan
- still the natural first digital block

### 2. `DC Removal x4`

Role:

- remove residual per-branch DC bias before any phase-sensitive correlation

Why it stays:

- `SX1257` is effectively zero-IF / direct-conversion
- DC bias can contaminate:
  - repeated-upchirp detection
  - pooled CFO statistics
  - known-sequence matched correlation
  - branch power/confidence metrics

Recommended first implementation:

- per-branch running-mean subtraction, or
- packet-pretraining average subtraction

Outputs:

- `x_dc[j][n]`

### 3. `LoRa Dechirp Frontend`

Role:

- multiply each branch by the conjugate LoRa downchirp reference
- convert repeated upchirps into approximately tone-like sequences
- feed both detector and timing-refinement paths

Inputs:

- DC-corrected complex samples
- known LoRa downchirp reference

Outputs:

- dechirped branch streams `d_j[n]`

Notes:

- this is not an FFT
- it is a streaming reference multiply
- it should be shared by the downstream acquisition blocks where possible

### 4. `Repeated-Upchirp Detector`

Role:

- detect the LoRa preamble using adjacent repeated upchirps
- produce a coarse packet-start estimate
- produce a pooled common-CFO statistic

Per branch statistic:

`c_j = sum_n d_j[n+M] * conj(d_j[n])`

Pooled CFO statistic:

`C_pool = sum_j c_j`

Recommended detection metric:

`Metric_det = sum_j |c_j|^2 / Metric_energy`

where `Metric_energy` is built from the corresponding per-window energies.

Design rule:

- use **incoherent combine** for detection
- use **coherent pooled phase** for CFO

Outputs:

- `lock`
- `timing_coarse`
- `C_pool`
- `det_metric`
- optional per-branch `c_j`

Why this block exists:

- repeated upchirps are still the cleanest standard-LoRa structure for burst detection
- this replaces the current FFT wake-up dependency

### 5. `Sync / Downchirp Timing Refiner`

Role:

- use the non-repeated LoRa preamble tail to resolve timing ambiguity left by repeated upchirps
- confirm the actual packet boundary before training correlation starts

Motivation:

- repeated upchirps alone are ambiguous
- the sync words and downchirps are useful because they are not repeated
- this is the main standard-LoRa feature that helps replace integer-bin FFT timing logic

Possible implementation styles:

- correlate against expected sync/downchirp transition templates
- use short matched windows around the expected boundary
- refine timing within a small search window around `timing_coarse`

Outputs:

- `timing_refined`
- `sync_confidence`

Notes:

- this block should be narrow in purpose
- it is not a generic search engine

### 6. `Common CFO Estimator`

Role:

- extract one shared CFO estimate for all four branches

Recommended estimator:

`omega_hat = angle(C_pool) / M`

where `C_pool` comes from the repeated-upchirp detector.

Assumption:

- all four branches share the same frequency reference closely enough that one common CFO is the right model

Outputs:

- `omega_hat`
- `cfo_confidence`

Notes:

- this is a first-class block, not a side effect
- the frontend should treat CFO correction as mandatory before channel estimation

### 7. `Common CFO Derotator`

Role:

- derotate all four branches using the shared CFO estimate

Form:

`x_corr,j[n] = x_dc,j[n] * exp(-j * omega_hat * n)`

Implementation:

- shared NCO / phase accumulator
- same rotation applied to all four branches

Outputs:

- CFO-corrected streams `x_corr,j[n]`

Why it matters:

- without derotation, coherent training correlation loses strength
- phase estimates become contaminated by time-varying rotation

### 8. `Known LoRa-Sequence Training Correlator`

Role:

- estimate one complex branch coefficient per antenna using a **known LoRa training sequence**

This is the replacement for FFT-based channel estimation.

Per branch:

`z_j = sum_n x_corr,j[n] * conj(s_ref[n])`

with:

- `x_corr,j[n]` = CFO-corrected received samples on branch `j`
- `s_ref[n]` = locally generated known LoRa training waveform sample sequence

Normalized estimate:

`h_j_hat = z_j / sum_n |s_ref[n]|^2`

Outputs:

- `z_j`
- optional normalized `h_j_hat`
- per-branch confidence `|z_j|^2`

Important rule:

- this training field should be **known**
- it should not rely only on repeated preamble structure

Recommended packet idea:

- standard LoRa preamble for detection
- known fixed LoRa symbol sequence for channel estimation
- normal payload after that

### 9. `Calibration Apply`

Role:

- correct static branch gain/phase mismatch before final weight generation

Per branch:

`h_j = z_j / c_j_cal`

or equivalently multiply by a precomputed inverse calibration coefficient.

Outputs:

- calibrated branch estimate `h_j`

Why this should stay explicit:

- calibration is not the same thing as runtime channel estimation
- separating them makes debug and fallback logic much cleaner

### 10. `Confidence / Quality Evaluation`

Role:

- turn detector and correlator statistics into frontend quality signals

Useful inputs:

- repeated-upchirp detection metric
- sync/downchirp confidence
- pooled CFO magnitude
- per-branch training correlation magnitude
- branch power

Useful outputs:

- `frontend_lock_good`
- `cfo_good`
- `training_good`
- optional branch masks

Why it matters:

- allows fallback between bypass / SC / EGC / MRC
- gives observability during bring-up

### 11. `Weight Generation`

Role:

- convert calibrated branch estimates into combining weights

Candidate modes:

- bypass
- selection combining
- EGC
- MRC

Examples:

`w_j = exp(-j angle(h_j))`

or

`w_j = conj(h_j) / (sum_k |h_k|^2 + eps)`

Outputs:

- `W_active`
- active combine mode

Notes:

- this remains naturally aligned with PicoRV32 firmware
- next-packet use is the low-risk baseline
- same-packet use remains optional if buffering exists

### 12. `Combiner`

Role:

- apply `W_active` to the live or replayed decimated branch samples

Form:

`y[n] = w^H x[n]`

Outputs:

- single combined stream for `NT=1`

### 13. `ΣΔ Re-modulator`

Role:

- convert the combined `int8` complex stream back to the 1-bit format expected by `SX1302`

This remains unchanged from the current overall system concept.

## Proposed block boundary summary

Frontend chain:

`Decimator -> DC Removal -> Dechirp -> Repeated-Upchirp Detector -> Sync/Downchirp Timing Refiner -> Common CFO Estimator -> CFO Derotator -> Known LoRa-Sequence Training Correlator`

Post-frontend chain:

`Calibration -> Confidence Evaluation -> Weight Generation -> Combiner -> Re-mod -> SX1302`

## What this replaces from the FFT path

The current FFT path provides:

- `eps_sub`
- `k_peak` / refined preamble alignment
- `H`

The proposed non-FFT replacements are:

- `eps_sub` replacement:
  - repeated-upchirp pooled phase estimate
- timing refinement replacement:
  - sync/downchirp timing refiner
- `H` replacement:
  - known LoRa-sequence training correlator

## Why this is a plausible LoRa-based path

This proposal keeps the most useful standard-LoRa structures:

- repeated upchirps for coarse detection
- sync/downchirp region for timing disambiguation
- known chirp-symbol waveform generation for training correlation

It does **not** attempt to make the ASIC a complete non-FFT LoRa demodulator.

Instead, it aims to do:

- packet detection
- timing/CFO correction
- channel estimation for combining
- handoff of a combined LoRa-compatible stream to `SX1302`

## Key advantages

- avoids FFT staging SRAM in the acquisition path
- removes the multi-pass FFT controller from frontend critical planning
- aligns better with a streaming architecture
- preserves standard-LoRa packet structure better than a fully custom training waveform
- keeps `SX1302` as the downstream LoRa demodulator

## Main risks

### 1. Narrower acquisition margin than FFT search

The frontend becomes more dependent on:

- good repeated-upchirp detection
- good timing refinement from sync/downchirps
- correct CFO correction before training correlation

### 2. Training-sequence definition must be explicit

This architecture depends on a concrete known LoRa training field after the preamble.

Without that field, channel estimation is underspecified.

### 3. Still not a full LoRa demod replacement

This path is suitable if:

- the ASIC performs combining and preprocessing
- `SX1302` still performs downstream demodulation

It is not claiming to replace generic LoRa FFT-style demod in silicon.

### 4. Timing/refinement block needs careful definition

The hardest new block is likely:

- `Sync / Downchirp Timing Refiner`

because it must replace the integer-bin / transition-refinement role previously covered by FFT-based acquisition.

## Recommended implementation order

1. `Decimator`
2. `DC Removal`
3. `Dechirp Frontend`
4. `Repeated-Upchirp Detector`
5. `Common CFO Estimator`
6. `CFO Derotator`
7. `Sync / Downchirp Timing Refiner`
8. `Known LoRa-Sequence Training Correlator`
9. `Calibration + EGC`
10. `MRC`
11. optional same-packet buffering path

## Open questions

1. What exact LoRa training sequence should follow the preamble?
2. Does the training field need to remain standard-LoRa-decodable, or only LoRa-waveform-compatible?
3. How much timing ambiguity remains after repeated-upchirp detection alone?
4. Is sync/downchirp refinement sufficient without an FFT search at the target SNR?
5. Should next-packet MRC remain the default even in the non-FFT path?
