# Simulation Ideas & Extensions

Open ideas for future notebook cells, model extensions, or verification experiments.

---

## Loose Ends

1. **[In progress]** Confirm post-route timing/DRC for `ol_weight_gen` — fanout constraint raised 2→4, SS corner target.
2. **[In progress]** `ol_mrc_combiner` physical design — removed `(* keep *)` on multiply-input regs, fanout 2→4; SS timing was −11.85 ns with old RTL.

---

## PSRAM Interface

### FIFO requirement analysis

**Conclusion: no FIFO needed at the design operating points.**

Key timing at 32 MHz system clock, 125 kS/s sample rate (BW=125 kHz baseband):

| Operation | Cycles | Time |
|---|---|---|
| Sample period (125 kS/s) | 256 | 8 µs |
| QPI write — 8 bytes, 16-bit mode | 24 | 750 ns |
| QPI read — 8 bytes, fast quad | 30 | 938 ns |
| Write + read interleaved (REPLAY) | 54 | 1.69 µs |

Bus utilisation during REPLAY (worst case): 54/256 = **21%**. There are 202 idle cycles between every write+read pair. Samples arrive every 256 cycles; the controller finishes each transaction and is waiting long before the next `iq_valid` strobe. Nothing accumulates.

A FIFO is only needed when samples arrive faster than the PSRAM can accept them. Here the relationship is inverted — PSRAM can accept a sample in 750 ns, new samples arrive every 8 µs.

The single timing boundary that does exist (`iq_valid` from the decimator into the QPI controller) is resolved by a single synchronisation register, not a FIFO, because both sides use the same 32 MHz clock.

**When a FIFO would become necessary:**

Running at 1 MS/s (os_factor=8, pre-decimation) in 32-bit mode with 4 branches:

```
4 branches × 4 bytes × 1 MS/s = 16 MB/s
QPI write per sample = 40 cycles = 1.25 µs
Sample period = 32 cycles = 1 µs   ← controller cannot keep up
```

A 4–8 sample deep FIFO would be needed to absorb burst overlap. This is why the spec caps 32-bit mode at 500 kS/s — at that rate the write takes 1.25 µs and samples arrive every 2 µs, restoring margin. If the design is ever extended to capture pre-decimation samples at full rate, add a small FIFO between the sigma-delta output and the QPI write engine.

---

## In Progress

### Sub-bin CFO interpolation for coherent preamble averaging

**Status:** Analysis done in notebook (CFO sensitivity cell after Stage 4), implementation pending.

**Why it matters — coherent averaging:** The 8-symbol coherent average `h_hat_j = (1/N_sym·M) Σ_s D_j[s][k_peak]` only works if all 8 symbols add in phase. Each symbol accumulates an extra phase of `2π·ε_sub` from the sub-bin fractional offset. Over 8 symbols the combining loss is:

```
loss = |sin(π·N_sym·ε_sub)| / (N_sym · |sin(π·ε_sub)|)
```

At the worst case (ε_sub = 0.5, halfway between bins): loss = 0 — complete cancellation of the 8-symbol gain. At a typical 10 ppm crystal offset (ε_sub ≈ 0.14 bins for SF7/125 kHz): ~3.5 dB loss. The sub-bin correction multiplies each symbol by `exp(-j·2π·ε_sub·s)` before summing, restoring full coherent gain.

**Problem:** After integer-bin FFT-based CFO correction, the residual offset is ±BW/(2M) ≈ ±122 Hz (SF9). This reduces the dechirped FFT peak by up to −3.9 dB at the worst-case half-bin point, directly hitting sensitivity at low SNR. MRC combining weights are unaffected (common α cancels), but the signal path loss is real.

**Fix:** Parabolic sub-bin interpolation on the three FFT peak bins.

The FFT bins are spaced BW/M = 244 Hz apart. The true tone sits between bins;
the Dirichlet kernel is approximately parabolic near its peak, so fitting a parabola
to the peak bin and its two neighbours locates the true frequency:

```
magnitude
    │
  β │        ●          ← peak bin k
    │      ·   ·
  α │    ●       ● γ    ← neighbours k-1, k+1
    └──────┬──┬──┬──── bin
         k-1  k  k+1
```

- If α > γ: tone is left of k (δ < 0)
- If α < γ: tone is right of k (δ > 0)
- If α = γ: tone exactly at k (δ = 0)

Works well because with 32× averaging (4 antennas × 8 symbols) the SNR on α, β, γ
is high, so noise doesn't distort the parabola fit.

**Code:**

```python
k_peak = np.argmax(|FFT|)
α, β, γ = |FFT|[k_peak-1], |FFT|[k_peak], |FFT|[k_peak+1]
k_frac  = k_peak + 0.5 * (α - γ) / (α - 2β + γ)
df_est  = k_frac * BW / M
```

Reduces residual to ±BW/(10–20M) ≈ ±10–25 Hz → worst-case FFT peak loss < −0.1 dB.

**Architecture decision — shared SX1302 clock:**
All NR antennas share the same RX clock, so CFO is common across antennas. This means:
- One pooled dechirped FFT (4 antennas × 8 symbols = 32× averaging) gives a very clean integer-bin estimate
- Detection sensitivity loss from ±122 Hz residual is modest given 27 dB LoRa processing gain (SF9) + ~6 dB MRC gain
- Sub-bin is NOT needed for detection, but IS needed to unlock N-symbol complex averaging

**Phase accuracy tradeoff (at −5 dB SNR, SF9):**
1-symbol vs 8-symbol complex averaging improves phase std dev by √8 ≈ 2.8×:

| Antenna | \|h\| | σ_φ 1-sym | σ_φ 8-sym | MRC loss 1-sym |
|---|---|---|---|---|
| weak  | 0.21 | ~22° | ~8°  | ~0.7 dB |
| mid   | 0.44 | ~9°  | ~3°  | ~0.1 dB |
| strong| 0.86 | ~4°  | ~2°  | ~0.02 dB |

Weak antenna dominates phase error but has smallest MRC weight — net combining loss from 1-symbol phase noise is ≤ 0.7 dB. Becomes significant only at deeper negative SNR or SF7 (smaller M → lower correlation SNR).

**Conclusion:** Sub-bin is low priority for current operating point. Revisit if operating at SF7 or below −10 dB SNR.

**Next steps:**
- Add notebook cell showing residual error and peak loss vs interpolation method (integer-bin vs parabolic vs CoM) — see cross-antenna extension below
- Wire into `estimate_channel()` (receiver.py) as a pre-correction step: compute ε_sub from inter-symbol phase after Pass 1, apply `exp(-j·2π·ε_sub·s)` per symbol before Pass 2 accumulation
- BER comparison: no correction vs integer-bin vs interpolated

### Cross-antenna coherent CFO estimation (extension of above)

**Status:** Architecture analysed, Jupyter notebook simulation planned as next step.

**Insight:** All four SX1257 front-ends share a single TCXO reference via the PCB clock buffer, so the carrier frequency offset `df` is identical across all NR=4 antennas. Only the channel phase `φ_j = ∠h_j` differs per antenna. This means all four antennas' dechirped samples can be exploited jointly for CFO estimation.

**Two combining strategies:**

| Strategy | How | Resolution | SNR boost | Complexity |
|---|---|---|---|---|
| Incoherent | Sum `\|FFT_j[k]\|²` across antennas, then find peak + sub-bin interpolate | BW/M (unchanged) | 4× (6 dB) | Trivial — no prior needed |
| Coherent (two-pass) | Pass 1: per-antenna FFT → coarse `φ_j`; Pass 2: phase-align by `exp(-jφ_j)`, sum 4 antennas → single M-sample stream → FFT + sub-bin | BW/M (same resolution, but 4× SNR → better interpolation accuracy) | 4× coherent | 2 FFT passes + firmware phase rotation |

Note: true 4× resolution improvement (BW/4M) would require concatenating all 4×M samples into a 4M-point FFT with no phase jumps at boundaries. This requires phase alignment, and the resolution gain is likely unnecessary — the 8-symbol preamble coherent integration already achieves BW/(8M) ≈ 30 Hz at SF9/125 kHz, which is comparable to what 4× wider FFT would give from a single symbol.

**The practical win is SNR, not resolution.** Incoherent 4-antenna combining gives 6 dB better peak SNR in the CFO spectrum, making sub-bin interpolation reliable 6 dB deeper into the noise floor.

**Architecture fit — no new hardware needed:**
- Raw preamble samples remain in capture SRAM (`0x08000+`) throughout both passes
- Pass 1 uses FFT staging (`0x00000–0x07FFF`) as normal; outputs coarse `φ_j` to PicoRV32
- Pass 2: PicoRV32 reads from capture SRAM, applies `exp(-jφ_j)` rotation, sums 4 antennas → M samples back into staging → FFT engine re-triggered
- Summed pass-2 signal: M × 2 bytes (8 KB at SF12) — fits staging easily
- **Timing:** total two-pass overhead ~370 µs (SF9) to ~3.9 ms (SF12) vs. available window of ~17 ms / ~139 ms — 36–47× margin
- **PicoRV32 bottleneck:** phase rotation + sum step is 4×M complex MACs; ~2 ms at SF12 on RV32IM — within margin but is the critical path

**Notebook sim plan:**
Sweep residual CFO error vs per-antenna SNR for four methods:
1. Single antenna, integer-bin only
2. Single antenna, integer-bin + parabolic sub-bin
3. 4-antenna incoherent `Σ|FFT_j|²` + sub-bin
4. 4-antenna coherent two-pass + sub-bin

Plot: RMS residual df error (Hz) vs SNR (dB), and resulting worst-case FFT peak loss (dB). Target: confirm that method 3 (incoherent, no new hardware) gives adequate accuracy across the operating SNR range before deciding whether the coherent two-pass complexity is justified.

---

## Channel Estimation

### Bayesian / Kalman Channel Tracking

**Motivation:** The current LS preamble estimator assumes a flat-fading-per-packet channel. This breaks for mobile nodes at SF12 (packet duration ~2.5 s exceeds coherence time at walking speed, 868 MHz).

**Idea:** Replace the single preamble estimate with an AR-1 Kalman filter that tracks `h[t]` sample-by-sample through the payload.

```
State:  h[t] = α·h[t-1] + w[t],   w ~ CN(0, σ_w²)
Obs:    y[t] = h[t]·s[t] + n[t],  n ~ CN(0, N0)
α = J₀(2π·f_D·T_s)               (Jakes AR-1 approximation)
```

The preamble LS estimate seeds the prior; each payload sample updates the posterior. The firmware computes `α` and `σ_w²` from a Doppler class register.

**Experiment:** Notebook cell comparing BER vs SNR for:
- Static LS estimate (current)
- AR-1 Kalman tracking
- Genie-aided (true h known)

at 10 Hz Doppler (walking speed, 868 MHz) across SF7–SF12.

**Cost:** Per-sample complex MAC × NR. Feasible on PicoRV32 at decimated `f_s = 125 kS/s`.

**Variants:**
- Extended Kalman / particle filter for non-linear fading (fast mobile / urban)
- Online Doppler estimation: add `f_D` as a state variable

---

## BER Sweeps

*Done: BER vs SNR full sweep (`sweep_ber.png`), Doppler/time-varying channel (`sweep_doppler.png`), NR scaling (`sweep_nr.png`), preamble length (`sweep_preamble.png`), shift-MRC vs oracle (`sweep_shift_mrc.png`), full DSP chain with RTL int8 combiner (`full_chain_ber.png`).*

### NT=1 MRC robustness under Doppler

**Motivation:** Gateway MRC assumes the preamble-derived phases and amplitudes remain valid across the packet. At high SF or with mobility, that can become false even if the packet is captured and detected correctly.

**Question:** When does preamble-only MRC stop behaving like coherent combining and collapse toward `EGC`, `SC`, or single-antenna performance?

**Experiment:** Add a notebook sweep over:

- Doppler frequency `f_D`
- SF (`7`, `9`, `12`)
- payload length
- combiner choice: `MRC`, `EGC`, `SC`

Measure:

- BER / PER
- packet-to-packet `H` drift
- within-packet phase drift relative to preamble estimate

**Why it matters:** This is the clean way to decide whether the gateway can rely on one preamble estimate per packet, or whether long-packet / mobile cases need a tracking extension or policy fallback.

### NT=1 MRC robustness under overlapping interference

**Motivation:** Plain MRC is not an interference canceller. In a gateway setting, overlapping packets from other nodes are a real operating condition.

**Question:** How much combining gain survives when a second packet is present, and when does the interferer contaminate the preamble enough to make MRC worse than a simpler mode?

**Experiment:** Add a notebook sweep over:

- desired/interferer power ratio
- same-SF vs different-SF interferer
- partial preamble overlap vs full overlap
- spatial correlation between desired and interferer channels
- combiner choice: `MRC`, `EGC`, `SC`, best single antenna

Measure:

- BER / PER on the desired packet
- preamble-estimate bias
- cases where fallback beats MRC

**Why it matters:** This defines whether the gateway can treat collisions as extra noise, or whether it needs an interference-aware policy or a reject/fallback rule.

---

## Gateway System Considerations

These are broader gateway-specific considerations beyond the base MRC algorithm. They should be treated as system-level checks during planning, simulation, and hardware bring-up.

### Front-end mismatch and calibration

Check sensitivity to:

- per-antenna gain mismatch
- per-antenna phase skew
- IQ imbalance
- DC offset
- filter variation across RX chains

Why it matters: coherent gain depends on the antenna branches behaving like a stable calibrated array, not just four independent receivers.

### Shared-clock and phase-stability assumptions

The current architecture benefits from common RX-side CFO across antennas. Verify the practical limits of that assumption under:

- clock tree skew
- PLL phase behaviour after retune or reset
- temperature drift
- long packet reception

Why it matters: if cross-antenna phase is not stable enough, MRC and coherent estimation lose value.

### AFE characterization for coherent combining

Treat analog-front-end characterization as part of the hardware workstream, not only as later system validation.

Priority measurements:

- branch-to-branch LO frequency mismatch
- LO drift versus time and temperature
- branch-to-branch gain mismatch
- branch-to-branch phase mismatch
- IQ imbalance
- DC offset / LO leakage
- compression and blocker response
- RX filter-response mismatch

Why it matters: the DSP currently assumes the four receive branches are coherent enough for MRC and for shared-CFO estimation. Differential LO drift or unstable branch phase directly reduces combining gain and can invalidate the common-CFO assumption.

Recommended measurement flow:

1. Inject one common CW tone into all RX branches through a splitter
2. Capture all four SX1257 `1-bit I/Q` sigma-delta outputs synchronously with FPGA logic
3. Decimate to complex baseband and estimate per-branch amplitude, phase, and effective frequency offset
4. Log branch-to-branch drift over time and temperature
5. Sweep input power to find compression and mismatch changes
6. Repeat with LoRa-like modulated input after the CW baseline is understood

Instrument note:

- the primary measurement path will be synchronous FPGA capture of the four `1-bit I/Q` outputs, followed by common offline decimation and estimation
- a spectrum analyzer remains useful for absolute RF checks such as leakage, absolute carrier error, and compression
- direct analog baseband observation is not the primary plan; the sigma-delta outputs are the practical observation point for the real digital receive chain

Parameters to estimate from FPGA capture:

- relative gain per branch
- relative phase per branch
- differential CFO / effective LO offset per branch
- phase drift over packet timescales
- IQ image rejection / imbalance indicators
- DC / low-frequency spur level
- mismatch growth near compression

Estimator definitions:

Let `x_j[n]` be the common-decimated complex baseband for branch `j`, and choose branch 0 as the reference unless a different branch is explicitly designated.

For a CW test tone, first estimate the common tone bin or frequency, then form a complex tone estimate per branch:

```text
a_j = (1/N) * Σ_n x_j[n] * exp(-j 2π f_hat n / f_s)
```

where:

- `a_j` is the complex fitted tone for branch `j`
- `f_hat` is the estimated tone frequency
- `f_s` is the decimated complex sample rate

Use `a_j` to define:

- **Relative gain**

  ```text
  G_j_dB = 20 log10(|a_j| / |a_0|)
  ```

- **Relative phase**

  ```text
  phi_j = angle(a_j * conj(a_0))
  ```

- **Differential CFO / effective LO offset**

  Estimate the per-branch residual phase slope relative to branch 0:

  ```text
  r_j[n] = x_j[n] * conj(x_0[n])
  df_j = (f_s / 2π) * slope(unwrap(angle(r_j[n])))
  ```

  where `slope(.)` is a least-squares phase slope in radians/sample.

- **Phase drift over packet timescale**

  Divide the capture into windows and track:

  ```text
  phi_j[k] = angle(a_j[k] * conj(a_0[k]))
  drift_j = slope(phi_j[k] versus time)
  ```

  Report both peak-to-peak phase wander and fitted drift rate.

- **IQ image rejection indicator**

  For a positive-frequency CW input, after FFT:

  ```text
  IRR_j_dB = 10 log10(P_desired / P_image)
  ```

  where `P_desired` is power in the expected tone bin and `P_image` is power in the mirrored negative-frequency bin.

- **DC / low-frequency spur**

  ```text
  DC_j_dBc = 10 log10(P_DC / P_desired)
  ```

  using the DC bin or a small band around DC.

- **Compression onset**

  Sweep input power and track fitted branch amplitude:

  ```text
  C_j(Pin) = G_j_small_signal - G_j(Pin)
  ```

  Compression onset is the input level where gain drops by the chosen criterion, for example `1 dB`.

Recommended reporting:

- branch-to-reference values for all four branches
- worst-case spread across branches
- mean and standard deviation across repeated captures
- time-series plots for `df_j` and `phi_j` during drift tests

LoRa-like modulated input extension:

- reuse the same branch-0 reference convention
- replace the single-tone fit with preamble-based channel estimates `h_j`
- compute relative gain from `|h_j|`, relative phase from `angle(h_j * conj(h_0))`, and drift from packet-to-packet or symbol-to-symbol change in `h_j`

Measurement disposition and fallback policy:

Every measured impairment should map to one of four outcomes:

1. **Accept**  
   Impairment is small enough that predicted combining loss is negligible.

2. **Calibrate**  
   Impairment is stable and can be corrected in firmware, DSP, or a board-calibration table.

3. **Mask / degrade gracefully**  
   Impairment is too large for ideal `NR=4 MRC`, but the system can still operate by disabling a branch or falling back to `EGC`, `SC`, or a reduced-antenna mode.

4. **Escalate to hardware action**  
   Impairment is dynamic or large enough that calibration is not reliable, indicating a board, clocking, routing, or AFE problem.

Recommended mapping by metric:

- `G_j_dB` too large but stable:
  calibrate or compensate in channel/weight estimation

- `phi_j` too large but stable:
  calibrate as static branch phase offset

- `df_j` too large but stable:
  add per-branch compensation or tighten operating assumptions

- `df_j` drifting over packet timescale:
  treat as a coherence risk; fall back from full MRC if needed, or escalate to hardware investigation

- `drift_j` too large:
  treat as a packet-coherence red flag; consider `EGC`, `SC`, branch masking, or limiting supported long-packet operating points

- poor `IRR_j_dB` or high `DC_j_dBc`:
  accept if within budget, otherwise calibrate or down-rank the branch

- early or branch-specific compression from `C_j(Pin)`:
  retune AGC thresholds, add saturation masking, or escalate if one branch is materially worse than the rest

Severity bands:

- **Green**: normal `NR=4 MRC`
- **Yellow**: calibration and monitoring required
- **Red**: fallback mode or hardware action required

Operational fallbacks to support:

- disable one or more bad branches
- fall back from `MRC` to `EGC`
- fall back from `MRC` to `SC` / best antenna
- suppress current-packet coherent combining when confidence is poor
- maintain per-branch health flags for firmware decisions

Relevant datasheet reference numbers:

- `SX1257`
  - synthesizer range: `862-1020 MHz`
  - synthesizer step: `68.7 Hz` typ at `36 MHz` reference
  - external clock jitter spec: `0.01%` max
  - RX noise figure: `7 dB` typ, `10 dB` max
  - RX gain range: `70 dB` typ
  - RX IIP3: `+10 dBm` at lowest LNA gain, `-25 dBm` typ at highest LNA gain
  - RX IQ gain mismatch: `0.5 dB` typ, `1 dB` max
  - RX IQ phase mismatch: `1 deg` typ, `3 deg` max
  - crystal note: initial tolerance, temperature stability, and aging must be chosen to match the target operating range and receiver bandwidth

- `SX1302`
  - system clock: single `32 MHz` source from companion RF front-end
  - recommended reference: `0.5 ppm` GPS-grade TCXO
  - LoRa carrier frequency-offset tolerance for less than `3 dB` degradation: about `+/-0.25 * BW`, assuming `0.5 ppm` gateway reference precision

- `SE2435L`
  - RX gain: `16 dB` typ, `18 dB` max
  - RX noise figure: `2 dB` typ, `2.5 dB` max
  - RX IIP3: `-2 dBm` typ
  - RX IP1dB: `-12 dBm` typ
  - gain variation across frequency range: `2 dBp-p`
  - antenna-port isolation: `20 dB` typ

Important limitation:

- these datasheet numbers do not specify branch-to-branch LO drift mismatch or relative phase stability across four assembled receive chains
- that coherence risk still has to be measured directly in hardware

Suggested acceptance framing:

- gain mismatch after calibration within a defined dB budget
- differential LO drift small enough that MRC loss stays within the combining-loss budget
- branch phase stability maintained over the longest target packet duration
- no branch enters compression at the expected blocker level

### AGC, clipping, and near-far behaviour

Study:

- whether one strong branch sets gain badly for weaker branches
- how saturation on one branch affects channel estimation and combining
- whether a clipped or compressed branch should be masked

Why it matters: gateway operation is often blocker-limited rather than thermal-noise-limited.

### Antenna correlation and placement

Check the impact of:

- antenna spacing
- polarization choice
- enclosure effects
- mounting environment and nearby metal

Why it matters: four antennas only provide full diversity benefit if the branches are not too correlated.

### Branch health and masking policy

Define how the gateway detects and handles:

- dead or noisy antenna paths
- swapped IQ or polarity issues
- abnormal phase outliers
- stuck decimator / ADC behaviour

Why it matters: a bad branch can silently degrade MRC if it is always trusted.

Current status:

- basic contingencies already exist in the architecture:
  - `ANTENNA_EN` can disable one or more branches
  - bypass fallback exists when W is not ready or missed
  - saturation-discard behavior already exists in the AGC / H-estimation path
- what is still missing is a concrete runtime health-check framework

Still to define:

- a branch-health status register or bitmask
- firmware rules for asserting degraded or failed branch state
- thresholds for when branch mismatch, drift, DC spur, or compression should trigger masking
- policy for when to prefer `MRC`, `EGC`, `SC`, or reduced-antenna operation
- whether health state is packet-local, sticky-until-clear, or both

### Detection robustness and fallback policy

Define what the gateway should do when confidence is poor, for example:

- weak or contaminated preamble estimate
- branch saturation
- inconsistent cross-antenna phase
- false-lock risk
- missed timing budget for weight handoff

Why it matters: a bad MRC decision can be worse than best-antenna or bypass.

### Network-level value

Translate gateway improvements into system metrics such as:

- packet success at cell edge
- achievable node TX power reduction
- coverage improvement
- throughput under collision-heavy traffic

Why it matters: gateway value should be measured in packet delivery and coverage, not only BER.

---

## Coherent vs Non-Coherent Combining

### Post-detection (non-coherent) MRC

LoRa is a non-coherent modulation — `fft_demod` selects the peak chirp bin by energy, not phase. This means diversity combining can be done after the FFT instead of on IQ samples:

```
branch 0: IQ → de-chirp → |FFT|²  ─┐
branch 1: IQ → de-chirp → |FFT|²  ─┤─ sum → argmax → symbol
branch 2: IQ → de-chirp → |FFT|²  ─┘
```

Advantages over coherent MRC:
- No inter-branch phase alignment needed — eliminates training accumulator and weight generation blocks entirely
- No preamble required — works from the first symbol
- Robust to fast fading (channel changes within packet don't corrupt the estimate)
- ASIC: adder tree on FFT magnitudes only — significantly less silicon

Cost: ~1.5–2 dB SNR penalty vs coherent MRC at NR=4 (provably optimal gap). Negligible at comfortable link margins; matters only near sensitivity floor.

**When to prefer:** Dense deployments at normal link margins where simplicity and robustness to mobility outweigh the ~2 dB gain.

### Coherent MRC advantages

Coherent combining is the provably optimal combiner (maximises post-combining SNR). Key advantages that post-detection cannot replicate:

- **Full ~10·log₁₀(NR) dB diversity gain** — at NR=4, full 6 dB vs ~4.5 dB non-coherent
- **Null steering** — complex weights can place spatial nulls toward interferers. NR=4 gives 3 degrees of freedom: 1 main beam + 3 nulls. Post-detection has no mechanism for this.
- **Beamforming** — if antennas are physically spaced (~17 cm half-wavelength at 868 MHz), the training-estimated weight vector `w_j = conj(h_j)/Σ|h_k|²` already steers toward the transmitter implicitly. No explicit DOA block needed.
- **EGC/SC fallback** — once complex weights exist, switching between MRC/EGC/SC is a software policy. Post-detection has no SC equivalent.
- **Multi-node spatial multiplexing** — see below.

**When to prefer:** Range extension at sensitivity floor, interference-limited environments, or when beamforming / null steering is a target.

---

## Spatial Processing Extensions

### Beamforming and null steering

The current MRC weight vector `w = conj(h)/Σ|h|²` is equivalent to matched-filter beamforming when the channel vector encodes the array steering response. With physically spaced antennas:

- **Implicit steering:** training accumulator already estimates the complex `h_j` per branch, which includes the phase gradient across the array. The resulting `w_j` steers the beam toward the source automatically, no DOA block needed.
- **Explicit null steering:** replace `w = conj(h)/Σ|h|²` with an MVDR/LCMV weight vector that maximises SINR subject to a gain constraint toward the desired node. Needs an interference covariance estimate (from the noise floor samples between packets).
- **DOA estimation:** add a MUSIC or ESPRIT block upstream of weight generation to estimate angle of arrival from the preamble-derived `h_j`. Useful for diagnostics or for initialising explicit beamforming.

ASIC impact: null steering requires a matrix inversion (NR×NR, complex) — feasible for NR=4 on PicoRV32 firmware but not real-time in hardware. Weight update latency would increase from one preamble to a few preambles.

### Multi-node spatial multiplexing

With NR=4 receive antennas and K simultaneous nodes on the same frequency/SF, the gateway can spatially separate them if their channel vectors `h_k` are sufficiently distinct (K < NR):

```
y = H·s + n    (NR×K channel matrix, K transmit nodes)
ŝ = W·y        (K×NR combining matrix)
```

Combining strategies:
- **Zero-forcing (ZF):** `W = (H^H H)^-1 H^H` — perfect inter-node cancellation, noise enhancement at low SNR
- **MMSE:** `W = (H^H H + σ²I)^-1 H^H` — trades off cancellation vs noise, better at low SNR
- **Successive interference cancellation (SIC):** decode strongest node first, subtract, repeat

For LoRa specifically, `H` must be estimated from simultaneous preambles — requires the two nodes to transmit at the same time (collision), which means this is a collision-resolution technique, not a scheduled SDMA scheme.

**Practical path:** capture all NR×M preamble samples as now, but estimate `H` as a matrix rather than a vector. Weight generation block computes `W = MMSE(H)`. Same SRAM and FFT infrastructure; firmware complexity increases.

**SNR condition for K=2, NR=4:** spatial separation requires `|H^H_0 H_1| / (|H_0| |H_1|) < 0.7` (correlation below ~0.7). In Rayleigh fading this holds with ~80% probability for isotropic antennas at half-wavelength spacing.

**When useful:** high-density deployments where the same SF/BW is shared by many nodes and collisions are frequent. Gateway can resolve 2–3 simultaneous packets without requiring TDMA coordination.

### Hardware requirements for beamforming and null steering

Not currently spec'd. Summary of what is and isn't needed:

**1. Antenna geometry — PCB/mechanical (the binding constraint)**

Current design does not specify antenna spacing. For spatial beamforming and null steering to work:

- Half-wavelength spacing at 868 MHz = 17.3 cm between elements
- 4-element linear array: 3 × 17.3 cm ≈ 52 cm total — long PCB or separate antenna board with coax runs
- 4-element circular array: ~11 cm radius — more symmetric azimuth coverage
- Without defined spacing the weights still provide diversity gain (MRC), but the beam pattern is undefined and nulls cannot be directed to a specific angle

**This has to be decided before PCB layout.** It affects enclosure design and is the hardest constraint to retrofit.

**2. PLL startup phase calibration — firmware only, no new RTL**

SX1257 PLLs lock to a random phase on each power-up. MRC training absorbs this per-packet (h_j includes PLL phase). For directed beamforming toward a known angle without a training signal, the static inter-antenna LO phase offset must be known.

Fix: one-time calibration mode. Inject a CW tone from a known direction (or via a splitter), capture h_j, subtract the geometric phase → measure and store φ_PLL_j per antenna. The Frontend Calibration Procedure already describes this measurement flow.

ASIC change: 4 × 16-bit per-antenna phase offset registers in the Register Map. No new RTL blocks.

**3. Interference covariance for MVDR null steering — firmware only**

MVDR null steering replaces the MRC weight formula with:

```
w_MVDR = R_n⁻¹ · h / (h^H · R_n⁻¹ · h)
```

`R_n` is the NR×NR interference covariance estimated from the noise-only samples before the preamble — already held in PSRAM capture. A 4×4 complex matrix = 128 bytes, trivially fits in PicoRV32 DMEM. 4×4 complex Gaussian elimination ≈ 200 MACs ≈ 20 µs at 32 MHz, well within budget.

ASIC change: one register or FSM pointer to mark the noise-only window in PSRAM. No new RTL accumulator; PicoRV32 firmware reads the window and computes R_n and its inverse.

**4. Summary — what changes where**

| Change | Where | Cost |
|---|---|---|
| Antenna spacing and array topology | PCB layout / mechanical | Design constraint — must decide before layout |
| Per-antenna LO phase calibration register | Register Map | 4 × 16-bit entries |
| Noise-only window pointer | Packet Control FSM | 1 register, minor FSM state |
| R_n accumulation and 4×4 matrix inversion | PicoRV32 firmware | Software only |
| MVDR weight computation | PicoRV32 firmware | Replaces existing MRC formula |

The weight registers and combiner are unchanged — whether the weights implement MRC or MVDR is entirely a firmware decision.

**5. What requires additional hardware beyond the current spec**

- Real-time null steering (update weights faster than once per packet): needs a hardware covariance accumulator and dedicated MAC units — not feasible in current architecture
- DOA estimation (MUSIC / ESPRIT): significant new hardware, not justified for LoRa
- Transmit beamforming: RX-only chip; would require a PA array and analogue phase shifters

**Recommended action:** decide antenna array geometry (linear vs circular, spacing) before PCB layout. Add 4 calibration registers to the Register Map. Note noise-window pointer requirement in the Packet Control FSM spec.

### ASIC cascade for array expansion

Not yet considered in the planning docs. Two distinct interpretations:

**1. Parallel cascade (array expansion)**

Each ASIC handles NR=4 antennas; multiple ASICs feed a second-stage combiner:

```
ASIC 0: ant 0–3  → combined_0 ─┐
ASIC 1: ant 4–7  → combined_1 ─┤─ ASIC_N → final output
ASIC 2: ant 8–11 → combined_2 ─┘
```

Gets to NR=8, 12, 16 with a small number of chips. The second-stage ASIC runs the training accumulator on the combined inputs from the first-stage chips, treating each as a new "antenna branch." This works as long as all chips share a common clock reference (same board, same TCXO) — the inter-chip phase is then determined by propagation geometry and is recoverable from the preamble cross-correlation in the normal way.

If chips are on different boards or at different locations, a timing/phase distribution network is needed (GPS-disciplined clock or white-rabbit style sync).

**2. Serial pipeline**

ASIC 1 output feeds ASIC 2 input as a processed stream — e.g. MRC-combined IQ feeds a second chip for further processing such as CFO correction, matched filtering, or symbol decisions. Less compelling since the current design already outputs decoded bits. More relevant if the first chip is used purely as a front-end combiner with no decode, and the second chip handles all baseband.

**What the current ASIC is missing for cascading:**

- No high-speed digital IQ output port — SPI/I2C only
- No defined inter-chip sample format or clock export pin
- No second-stage input mode (accepting a combined stream as one of NR branches rather than a raw ADC input)

**The practical near-term case:**

Two chips on the same PCB sharing the TCXO, giving NR=8. The second chip needs:
1. A digital IQ input path that bypasses the analogue front-end for its branch 0 slot
2. A clock input pin tied to the first chip's clock output
3. The training accumulator running normally on all 4 inputs (3 raw ADC + 1 from chip 0 combined output)

This is a pin and interface design question more than a DSP question — the combining algorithm is unchanged.

**SNR implication:**

Hierarchical two-stage MRC is not equivalent to flat NR=8 MRC. The first stage combines 4 branches and outputs one stream; the second stage sees this as a single (stronger) branch plus 3 more. The diversity order is still 4 (first stage) × 2 (stages) in the best case, not 8. Full NR=8 flat MRC requires all 8 branch signals to reach a single combiner simultaneously.

For the parallel cascade to achieve near-flat-MRC performance, the first-stage combined outputs should be passed as raw per-branch signals rather than a single combined stream — i.e. chip 0 exports all 4 of its sat-output branches, not just the MRC result. This requires a 4× wider inter-chip interface but preserves the full NR=8 combining gain at the second stage.

**Recommended next step:**

Add an inter-chip digital interface to the pinout exploration (4× complex sample lanes, shared clock, frame sync). Simulate hierarchical vs flat combining gain to quantify the penalty of the two-stage approach and decide whether the interface complexity of exporting 4 branches per chip is justified.

---

## Fixed-Point Analysis

### Wordwidth sweep

Sweep the combiner output wordwidth (8–16 bits) and plot BER degradation. Identify the minimum safe wordwidth for each SF.

### Accumulator overflow stress test

Drive the correlator with maximum-amplitude int8 inputs (±127) and verify the int32 accumulator does not saturate for the longest preamble (8 × 4096 samples at SF12).

---

## ΣΔ Re-modulator

### SQNR vs OSR

Plot SQNR of the 3rd-order ΣΔ re-modulator vs oversampling ratio (32–256×) against theoretical `6.02·L·bits + 1.76 + 5.17·(2L+1)·log₂(OSR)` bound. Verify the 125 kHz and 1000 kHz operating points.

### Spectral mask check

FFT of re-modulator output at each BW setting, overlaid with the LoRaWAN spectral mask. Confirms no out-of-band emissions from the 3rd-order noise shaping.

---

## Implementation / Physical Design

### Two-clock architecture: 32 MHz front-end, 16 MHz DSP

The ASIC uses two clock domains derived from a single 32 MHz GPS TCXO input:

| Domain | Clock | Blocks |
|--------|-------|--------|
| `clk_32m` | 32 MHz (primary input) | CIC decimator, ΣΔ re-modulator, SX1302 SPI interface |
| `clk_16m` | 16 MHz (/2 toggle FF) | mrc_combiner, weight_gen, training_accum, FFT engine, PicoRV32 |

**Rationale:** The decimator and remod are tightly coupled to the 32 MHz front-end sample clock (SX1257 sigma-delta bitstream in, remod bitstream out). All DSP arithmetic blocks have multi-cycle paths that fail at 32 MHz SS 3.3V corners but close with margin at 16 MHz. Running the DSP at 16 MHz halves dynamic power in the dominant logic area.

**CDC boundaries:**
- Decimator → DSP (32 MHz → 16 MHz): one new sample every 256 clk_32m cycles (125 kS/s). 2-FF synchroniser or registered valid/ready handshake.
- DSP → remod (16 MHz → 32 MHz): one new sample every 128 clk_16m cycles. Same.

Both crossings have data valid rates far below either clock — no FIFO needed.

**SDC:** `create_generated_clock` on the /2 net. `set_max_delay -datapath_only` on both CDC directions to bound analysis without over-constraining.  
File: `rtl-test/top_two_domain.sdc`

**RTL:** `mrc_combiner` uses `clk_16m`. Pipeline register between accumulation and saturation (states 4→5→9). Output latency 9 cycles at 16 MHz.

### Switch CPU IMEM/DMEM to ocd_ip_sram for single-cycle access

The `gf180mcu_fd_ip_sram` macros (64–512×8) have a behavioural model with `Tcyc = 55.6 ns` and `ta = 45 ns` (conservative SS-corner values applied uniformly). These require a 2-cycle multicycle path at 32 MHz.

The `gf180mcu_ocd_ip_sram__sram1024x8m8wm1` at 3.3V has corner-aware timing:

| Corner | Tcyc | ta (CLK→Q) |
|--------|------|------------|
| TT 3.3V 25°C | 9.2 ns | 6.2 ns |
| SS worst | 18.3 ns | 7.2 ns |

Both fit comfortably within one 31.25 ns period — **single-cycle access is viable at all 3.3V corners**. Four `ocd_ip_sram` 1024×8 macros in parallel give a 1 kB × 32-bit IMEM/DMEM. This would eliminate the 2-cycle stall penalty on every PicoRV32 fetch and load/store, potentially doubling CPU throughput on memory-bound code.

**Action:** check if the ocd_ip_sram macro is available for this shuttle and whether four-wide instantiation fits the floorplan.

### Timing corner reference

Clock: **16 MHz** (62.5 ns). `mrc_combiner` pipeline register added between multiply and accumulate stages. `weight_gen` fanout constraint raised to 4 to eliminate buffer-chain cascades. SS corner closure still under iteration.

**ws-run1 benchmark (GF180MCU shuttle, 2024):**

| Design | Clock |
|--------|-------|
| RISCBoy-180 (game console SoC) | 50 MHz |
| Chess move generator | 25 MHz |
| FazyRV 1–2 bit variants | 20–25 MHz |
| FazyRV 8-bit wide | ~15 MHz |
| Racquet / FazyRV top-level SoC | 10 MHz |

Range: 10–50 MHz. CPU-heavy designs ran 10 MHz; 20–25 MHz is the safe unpipelined zone for non-trivial datapaths at GF180MCU 3.3V SS. Our 32 MHz target is achievable but requires pipelining of multi-cycle arithmetic paths to close at SS corners.

---

## Multi-Packet / System Level

### EMA smoothing gain

Simulate a static channel over 50 consecutive packets and plot the EMA-smoothed `|h_hat|²` vs the per-packet LS estimate. Quantify variance reduction as a function of `ALPHA_SHIFT`.

### Throughput vs combining gain trade-off

Model effective throughput (bits/s) vs SNR for MRC and ALMMSE, accounting for LoRaWAN duty cycle. Shows where MIMO gain translates to range extension vs data-rate improvement.
