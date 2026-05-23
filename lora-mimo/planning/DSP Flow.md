# DSP Flow

The digital signal processing chain is receive-only. The ASIC sits between four SX1257 RF front-ends and an SX1302 LoRa baseband processor, performing multi-antenna combining before passing re-modulated bitstreams to the SX1302 for LoRa demodulation.

## Architectural requirement

Baseline RX operation must not require PicoRV32 firmware execution.

The mandatory hardware-only receive path is:

- decimation
- DC removal
- SC detection and timing
- training accumulation
- hardware weight generation
- packet-phase control
- combiner or bypass selection
- ΣΔ re-modulation

PicoRV32 is therefore treated as:

- optional for baseline RX correctness
- useful for ALMMSE, EMA smoothing, diagnostics, AGC policy, and TDD control
- allowed to fail or remain in reset without preventing packet reception in the baseline MRC/bypass modes

If firmware-dependent features are enabled, they must fail back to the hardware baseline rather than blocking the live receive stream.

The supported firmware-free fallback is specifically `RX-only`:

- `CPU_RESET=1`
- hardware weight path enabled
- PSRAM replay disabled
- fixed SX1257 gain from reset defaults or host-programmed register values
- no TX/TDD sequencing

Two operating modes share the same hardware:

| Mode | Config | Combining | Output |
| --- | --- | --- | --- |
| 1 | NT=1, NR=4 | MRC | ΣΔ re-mod → SX1302 Radio A |
| 2 | NT=1, NR=1 | Passthrough (bypass) | ΣΔ re-mod → SX1302 Radio A |

---

## Stage-by-stage pipeline

| Stage | Block | Input | Output | Rate | Mode |
| --- | --- | --- | --- | --- | --- |
| 1 | SX1257 ΣΔ ADC (×4) | RF signal at each antenna | 1-bit I + 1-bit Q × 4 | 32 MS/s | All |
| 2 | ΣΔ Decimator — CIC + FIR (×4) | 1-bit I+Q × 4 | int8 complex × 4 | **125 kS/s – 1 MS/s** | All |
| 3 | DC Removal (×4) | Full-precision complex × 4 | DC-removed complex × 4 | f_s | All |
| 4 | Frontend Buffer Controller | DC-removed samples | current + M-delayed samples per branch | f_s | Mode 1 |
| 5 | SC Preamble Detector | current + delayed samples | `sc_lock`, `timing_ref` | per 2 sym | Mode 1 |
| 5.5 | Packet Control FSM | `sc_lock`, `timing_ref`, `training_done`, `W_commit` | `buf_freeze`, `combiner_source`, `safe_switch` | per packet | Mode 1 |
| 6 | Training Accumulator | DC-removed samples, `sc_lock`, `timing_ref` | `Z_j` (complex channel estimates), `E_ref`, `training_done` | per packet | Mode 1 |
| 7 | Weight Generation | `Z_j`, `training_done` | `W_SHADOW`, `W_COMMIT` | per packet | Mode 1 |
| 7' | Bypass MUX | int8 from selected antenna | int8 (no sign-extension needed) | f_s | Mode 2 only |
| 8 | MRC Combiner | `W_ACTIVE`, `x_j[n]` (4 branches) | `ŷ[n]` (1 stream) | f_s | Mode 1 |
| 9 | ΣΔ Re-modulator (3rd order) | int8 I+Q from combiner | 1-bit I+Q | 32 MS/s | All |

---

## Mode 2 — Passthrough (Bypass)

`MIMO_CTRL.MODE = 1` (register value 1, referred to as Mode 2 in human-facing numbering).

Stages 4–8 (SC detector, frontend buffer, training accumulator, weight generation, combiner) are clock-gated and their outputs ignored. A bypass MUX immediately after the decimators routes a single antenna's int8 samples directly into REMOD_A:

```
bypass_sel = lowest set bit of ANTENNA_EN[3:0]
remod_a_in = x[bypass_sel][n]   // int8 directly; no sign-extension needed
```

**Antenna selection.** The lowest-numbered enabled antenna in `ANTENNA_EN` is used. Disable unwanted antennas via `ANTENNA_EN` before entering passthrough mode to choose a specific antenna.

**Purpose.** Provides a hardware-verified single-antenna baseline with identical front-end, decimation, and re-modulation paths as MRC mode. BER vs SNR comparisons against Mode 1 isolate the combining gain contribution.

**Latency.** Passthrough introduces only the decimator pipeline latency plus 1 cycle for the bypass MUX.

---

## Stage 2 — ΣΔ Decimation

Programmable CIC filter decimates the 32 MS/s bitstream to match the LoRa bandwidth. This ensures all downstream DSP blocks see exactly one symbol per 2^SF samples.

| BW Selection | Ratio (R) | Sample Rate (f_s) | decim_ratio | Notes |
| --- | --- | --- | --- | --- |
| 125 kHz | 256× | 125 kS/s | 0 | 1× Nyquist |
| 250 kHz | 128× | 250 kS/s | 1 | 1× Nyquist |
| 500 kHz | 64× | 500 kS/s | 2 | 1× Nyquist |
| 500 kHz (2×) | 32× | 1 MS/s | 3 | 2× oversampled; debug / wideband capture |

All ratios are power-of-2 — samples/symbol = 2^SF exactly for all SF and all BW settings (M is BW-independent). A 32-tap FIR compensation filter corrects sinc frequency droop. The entire downstream pipeline is clock-gated by the `iq_valid` strobe.

See [ΣΔ Decimator](blocks/ΣΔ%20Decimator.md).

---

## Stage 3 — DC Removal

Per-branch running-mean subtraction removes residual DC bias introduced by the SX1257 direct-conversion mixer before any phase-sensitive correlation.

```
dc_est[j]  += (raw[j][n] - dc_est[j]) >> DC_ALPHA_SHIFT
out[j][n]   = raw[j][n] - dc_est[j]
```

DC bias contaminates the SC detection metric, pooled CFO statistics, and training cross-correlation. Removal is mandatory before the Frontend Buffer and SC Detector.

See [DC Removal](blocks/DC%20Removal.md).

---

## Stage 4 — Frontend Buffer Controller

Manages the shared 1 kB dual-SRAM rolling history. Provides the current and M-sample-delayed raw samples needed by the SC Preamble Detector for adjacent-symbol autocorrelation. Frozen on `sc_lock` to preserve the acquisition history.

At SF7 with 8-bit storage using D=M read-before-write: 1-symbol (128-sample) rolling delay per branch fits exactly in 2×512B macros. SF8 requires 4 macros; SF9 requires 8.

The dedicated frontend SRAM remains the primary acquisition buffer. An optional extension may let hardware borrow a reserved upper CPU SRAM window (`CPU_SRAM_BORROW_EN=1`) to extend buffer depth, but only when `CPU_RESET=1` or when firmware is explicitly excluded from that bank. If the borrow path is not available, `SF7` falls back to `NR=2` acquisition on branches `1` and `3` rather than four-branch operation that depends on unavailable sample memory.

See [Frontend Buffer Controller](blocks/Frontend%20Buffer%20Controller.md).

---

## Stage 5 — SC Preamble Detector

Sliding-window complex autocorrelation across adjacent M-sample windows. Detects the LoRa preamble and provides coarse timing. No dechirp required — the LoRa chirp reference cancels algebraically in the autocorrelation product.

**Per-branch statistic:**

```
c_j = Σ_{n=0}^{M-1} current_j[n] · conj(delayed_j[n])
```

**Incoherent combine across branches:**

```
Mag_SC     = Σ_j |c_j|²
Energy_Ref = Σ_j E_j_curr · E_j_del
```

**Lock condition (multiplication form, avoids division):**

```
Mag_SC >= θ_SC² · Energy_Ref     (default θ_SC = 0.90)
```

**Outputs:**
- `sc_lock` — asserted when statistic exceeds threshold for `SC_HITS_REQ` consecutive symbol pairs
- `timing_ref` — estimated preamble-start sample index, back-calculated from the lock event

`sc_lock` is the terminal acquisition event in the non-FFT path. No downstream FFT or sync/downchirp refiner is needed — `timing_ref` alone locates the full packet.

See [Correlator Bank (SC)](blocks/Correlator%20Bank.md).

---

## Stage 5.5 — Packet Control FSM

Owns packet phase and no-glitch switching between bypass and combined output. Converts SC timing events and weight-readiness signals into deterministic control for the frontend buffer, weight generation, and combiner.

**States:** IDLE → PREAMBLE_ACQ → W_PENDING → PAYLOAD_ACTIVE → IDLE

Key outputs:
- `safe_switch` — receiver idle; W/mode/antenna active banks may update
- `combiner_source` — bypass until W is valid for the current packet
- `buf_freeze` — holds FRONTEND_BUF frozen from `sc_lock` to packet end

See [Packet Control FSM](blocks/Packet%20Control%20FSM.md).

---

## Stage 6 — Training Accumulator

Estimates one complex channel coefficient per receive branch by cross-correlating preamble samples against a nominated reference branch. CFO cancels exactly in the cross-product — no CFO correction is needed at any CFO value.

**Per-branch cross-correlation:**

```
Z_j = Σ_n rx_j[n] · conj(rx_ref[n])
    ≈ h_j · conj(h_ref) · N_acc
```

where the sum runs over the available preamble symbols after `sc_lock` (`N_acc ≈ 5·M` at SF6 with `SC_HITS_REQ=2`).

Setting `w_j = conj(Z_j)` gives full MRC combining gain `Σ_j |h_j|²` without any explicit CFO estimation or derotation step.

**Additional output:** `E_ref = Σ_n |rx_ref[n]|²` — reference branch energy over the same window. Enables recovery of absolute per-branch magnitudes from the relative estimates `Z_j`.

See [Training Accumulator](blocks/Training%20Accumulator.md).

---

## Stage 7 — Weight Generation

Converts `Z_j` into combining weights `W` via a dual hardware/software path.

**Hardware path (SC/shift-MRC, deterministic, ~16 cycles):**

```
SHIFT → CALIBRATE → COMPUTE (SC metric or shared MRC shift) → SCALE → WRITE W_HW
```

With `WGT_AUTO_COMMIT=1`, the hardware path commits weights within ~16 cycles of `training_done` in current RTL simulation — enabling same-packet weight application at SF6 (payload starts ~69,000 cycles after `training_done`). Exact normalized MRC remains a software/oracle option, not the hardened AUTO path.

**Software path (firmware, ALMMSE / EMA smoothing):**

PicoRV32 is triggered by `IRQ_TRAINING_DONE`, reads `Z_j` from registers (or `W_HW` for EMA), computes any weight formula, writes `W_SHADOW`, and pulses `W_COMMIT`.

This software path is optional. Baseline RX must still work when PicoRV32 does not service the interrupt.

`W_HW` read-only registers expose the hardware-computed result to firmware at all times, enabling EMA smoothing without re-deriving the raw per-packet estimate.

See [Weight Generation](blocks/Weight%20Generation.md).

---

## Stage 8 — MRC Combining

Time-domain combining performed at the decimated rate f_s.

`y[n] = w^H · x[n]`

Before current-packet W is valid, the combiner falls back to the selected bypass antenna so the SX1302 continues seeing a valid single-antenna LoRa stream:

```
if !W_valid:
    y[n] = x[bypass_sel][n]        // int8 direct, no ÷2
else:
    y[n] = (w^H · x[n]) >> 1      // MRC: int32 ÷2 → int8
```

`W_ACTIVE`, `ACTIVE_MODE`, and `ACTIVE_ANTENNA_EN` switch only at `safe_switch` boundaries (IDLE between packets). If W is not ready when the current packet ends, it activates on the next packet.

See [MRC Combiner](blocks/ALMMSE-MRC%20Combiner.md).

---

## Stage 9 — ΣΔ Re-modulation

3rd order feed-forward ΣΔ modulator converts combined int8 samples back to a 32 MS/s bitstream for the SX1302 Radio A input. The combiner MRC output stage applies ÷2 (absorbing √NR=4 combining gain) before delivering int8; the bypass path delivers int8 directly.

| BW | f_s (combiner output) | OSR | In-band SQNR (3rd order) |
| --- | --- | --- | --- |
| 125 kHz | 125 kS/s | 256 | > 130 dB |
| 250 kHz | 250 kS/s | 128 | > 115 dB |
| 500 kHz | 500 kS/s | 64 | > 100 dB |
| 500 kHz (2×) | 1 MS/s | 32 | > 85 dB |

All OSR values give SQNR far exceeding LoRa requirements. The 8-bit input gives ~44 dB effective SQNR (after ÷2); the quantisation noise floor is negligible at all supported bandwidths.

See [ΣΔ Re-modulator](blocks/ΣΔ%20Re-modulator.md).

---

## Bring-up & Calibration Recommendations

### 1. Analog Filter Matching

The SX1257 analog roofing filter (`RegRxBw`, 0x0D) must be matched to the selected digital bandwidth in `DECIM_CFG`.

| DECIM_CFG | Digital BW | Recommended SX1257 Analog BW |
| --- | --- | --- |
| `0x02` | 125 kHz | 250 kHz (minimum setting) |
| `0x01` | 250 kHz | 250 kHz |
| `0x00` | 500 kHz | 500 kHz |
| `0x03` | 500 kHz (1 MS/s) | 500 kHz |

If the analog filter is left wider than the digital sampling rate, signals and noise above the Nyquist frequency alias directly into the LoRa band.

### 2. Schmidl-Cox Threshold Calibration

- Detection threshold `θ_SC` via register `SC_THR`
- Consecutive hit requirement via register `SC_HITS_REQ`

Recommended starting points:
- **Default:** 0.90 — static indoor channels; matches rpp0/gr-lora default
- **Low SNR / mobile:** reduce to 0.75 — trades false-alarm rate for sensitivity
- **Hit count:** default `SC_HITS_REQ = 2`; 1 for aggressive weak-signal mode, 3 for noisy environments
- **False-alarm floor:** at threshold 0.90, noise-only statistic < threshold with > 99.9% probability (SF6, NR=4)

### 3. Weight Path Selection

- **Hardware auto (`WGT_SRC=0`, `WGT_AUTO_COMMIT=1`):** same-packet MRC/EGC. No firmware involvement in the weight path.
- **Software (`WGT_SRC=1`):** ALMMSE, EMA cross-packet smoothing, or custom formulas.
- **EMA smoothing:** use `WGT_SRC=1`; firmware reads `W_HW` (hardware result), applies EMA in DMEM, writes back to `W_SHADOW`.

Disable EMA (`ALPHA_SHIFT=0`) for mobile deployments where channel coherence time may be shorter than the averaging window.

### 4. Initial Gain Setting

Start at full gain (G1 + BB_MAX on all SX1257s) for maximum weak-signal sensitivity. The AGC loop converges within 1–3 packets via the `IRQ_CORR_LOCK` path. For a known deployment, pre-set `RX_GAIN_SHADOW_n` via SPI and pulse `RX_GAIN_COMMIT` before releasing `CPU_RESET`.

---

## Key design constraints

| Constraint | Value | Impact |
| --- | --- | --- |
| Decimation ratios | R=256, 128, 64, 32 | Native support for 125, 250, 500 kHz BW (1×) plus 1 MS/s (2× / 500 kHz); power-of-2 ensures integer M for all SF |
| SC detection window | 2M samples (current + M-delayed) | Buffer stores M samples (D=M); SC correlation spans 2M |
| Training accumulation | ~5 symbols (SC_HITS_REQ=2) | ~2 dB loss vs ideal 8-symbol average; acceptable baseline |
| Weight gen (hardware) | ~50 clock cycles | Same-packet application feasible at all supported SF; ~1,390× margin at SF6, ~2,780× at SF7 (commit window = 4.25M samples between training_done and payload start) |
| Weight gen (software) | < 5,000 cycles | ~14× margin at SF6/125 kHz, ~28× at SF7; late SC lock reduces this further (see Training Accumulator risks) |
| Frontend Buffer SRAM | 1 kB (2 × 512 B macros) | SF7 maximum with D=M at 8-bit storage; SF8+ requires more macros |
| ΣΔ re-mod | 3rd order, single instance | SQNR > 100 dB at OSR=64 (500 kHz BW) — LoRa headroom > 70 dB |
