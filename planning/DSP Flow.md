# DSP Flow

The digital signal processing chain is receive-only. The ASIC sits between four SX1257 RF front-ends and an SX1302 LoRa baseband processor, performing multi-antenna combining before passing re-modulated bitstreams to the SX1302 for LoRa demodulation.

## Architectural requirement

Baseline RX operation must not require PicoRV32 firmware execution.

The mandatory hardware-only receive path is:

- decimation
- DC removal
- SC detection and timing
- training accumulation
- firmware weight generation via on-chip PicoRV32 (host-assisted fallback optional)
- packet-phase control
- combiner or bypass selection
- ΣΔ re-modulation

PicoRV32 is therefore treated as:

- optional for baseline RX correctness
- useful for noise-weighted MRC, EMA smoothing, diagnostics, AGC policy, and TDD control
- required for MRC weighting in the current tapeout plan; if held in reset, Trouper remains limited to bypass-mode packet forwarding

There is no hardware weight-generation baseline in the current tapeout plan. The only firmware-free fallback is bypass-mode receive, with the selected antenna forwarded directly to the re-modulator.

The supported firmware-free fallback is specifically `RX-only bypass`:

- no firmware present (Grouper CPU halted or absent — there is no `CPU_RESET` register in Trouper)
- no weight commits
- PSRAM replay disabled
- fixed SX1257 gain from reset defaults or host-programmed register values
- no TX/TDD sequencing

Two operating modes share the same hardware:

| Mode | `MIMO_CTRL.MODE` | Config | Combining | Output |
| --- | --- | --- | --- | --- |
| 0 | 0 | NT=1, NR=4 | MRC (requires firmware-computed W) | ΣΔ re-mod → SX1302 Radio A |
| 1 | 1 | NT=1, NR=1 | Passthrough (bypass) | ΣΔ re-mod → SX1302 Radio A |

---

## Stage-by-stage pipeline

| Stage | Block | Input | Output | Rate | Mode |
| --- | --- | --- | --- | --- | --- |
| 1 | SX1257 ΣΔ ADC (×4) | RF signal at each antenna | 1-bit I + 1-bit Q × 4 | 32 MS/s | All |
| 2 | ΣΔ Decimator — half-band R=64 (×4) | 1-bit I+Q × 4 | int8 complex × 4 | **500 kS/s** (both BW modes) | All |
| 3 | DC Removal (×4) | Full-precision complex × 4 | DC-removed complex × 4 | f_s | All |
| 4 | Frontend Buffer Controller | DC-removed samples | current + M-delayed samples per branch | f_s | Mode 0 |
| 5 | SC Preamble Detector | current + delayed samples | `sc_lock`, `timing_ref` | per 2 sym | Mode 0 |
| 5.5 | Packet Control FSM | `sc_lock`, `timing_ref`, `training_done`, `W_commit` | `packet_active`, `packet_phase`, `W_valid_set`, `active_mode`/`active_antenna_en` | per packet | Mode 0 |
| 6 | Training Accumulator | DC-removed samples, `sc_lock`, `timing_ref` | all-pairs `Z_kl`, `Z_diag`, `training_done` | per packet | Mode 0 |
| 7 | Firmware Weight Generation | register-bank `Z_kl`, `training_done` IRQ | `W_SHADOW`, `W_COMMIT` | per packet | Mode 0 |
| 7' | Bypass MUX | int8 from selected antenna | int8 (no sign-extension needed) | f_s | Mode 1 only |
| 8 | MRC Combiner | `W_ACTIVE`, `x_j[n]` (4 branches) | `ŷ[n]` (1 stream) | f_s | Mode 0 |
| 9 | ΣΔ Re-modulator (3rd order) | int8 I+Q from combiner | 1-bit I+Q | 32 MS/s | All |

---

## Mode 1 — Passthrough (Bypass)

`MIMO_CTRL.MODE = 1`.

Stages 4–8 (SC detector, frontend buffer, training accumulator, firmware weight path trigger, combiner) are clock-gated and their outputs ignored. A bypass MUX immediately after the decimators routes a single antenna's int8 samples directly into REMOD_A:

```
bypass_sel = lowest set bit of ANTENNA_EN[3:0]
remod_a_in = x[bypass_sel][n]   // int8 directly; no sign-extension needed
```

**Antenna selection.** The lowest-numbered enabled antenna in `ANTENNA_EN` is used. Disable unwanted antennas via `ANTENNA_EN` before entering passthrough mode to choose a specific antenna.

**Purpose.** Provides a hardware-verified single-antenna baseline with identical front-end, decimation, and re-modulation paths as MRC mode. BER vs SNR comparisons against Mode 0 isolate the combining gain contribution.

**Latency.** Passthrough introduces only the decimator pipeline latency plus 1 cycle for the bypass MUX.

---

## Stage 2 — ΣΔ Decimation

The fixed R=64 half-band chain (CIC-3 R=16 → HB1 ÷2 → HB2 ÷2) decimates the 32 MS/s bitstream to a fixed 500 kS/s internal IQ rate. Both supported LoRa bandwidths run at 500 kS/s; `BW_CFG.bw_sel` selects BW by setting `sample_shift` (the oversampling factor), not the decimation ratio.

| BW Selection | Ratio (R) | Sample Rate (f_s) | sample_shift | Notes |
| --- | --- | --- | --- | --- |
| 125 kHz | 64× | 500 kS/s | 2 | 4× oversampled |
| 250 kHz | 64× | 500 kS/s | 1 | 2× oversampled |

Both BW modes share the fixed R=64 chain (500 kS/s). The downstream LoRa demodulator is
off-chip (SX1302); the `sd_remod` always outputs a 32 MHz ΣΔ bitstream so the internal
IQ sample rate is transparent to the SX1302. The SX1257 analog IF filter bandlimits the
signal before the ΣΔ ADC, and the SX1302 channel filter rejects any residual alias noise.
No FIR is required. The entire downstream pipeline is clock-gated by the `iq_valid` strobe.

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

## Stage 4 — PSRAM Buffer Controller (SC delay line)

> **Rewritten 2026-07-26 (audit item 20).** This stage described a block-based fixed-L
> delay buffer in a 512×8 on-chip SRAM macro with `L = min(M, 256)`. That block and all
> on-chip SRAM were removed (TRPR-PHY-006); the delay line is now a full-M read from
> off-chip PSRAM, so the sub-symbol integration loss the old text accepted (3–12 dB at
> SF9–SF12) no longer applies.

Full-depth delay line in the external APS6404L. On each `iq_valid` the controller writes
all four branches (8 bytes) and reads back the selected branch's `x[n−M]` from
`write_ptr − M`, where `M = 1 << (SF + sample_shift)` — the true symbol period at every
supported SF, with no sub-symbol truncation. Provides `cur_i0/cur_q0`, `del_i0/del_q0`
and `del_valid` to the SC detector; the live path for all four branches passes through
directly from `dc_removal`.

Budget: write 25 cycles + delay read 19 cycles = 44 of the 64 cycles between `iq_valid`
pulses (TRPR-PSR-014). Branch selection is `SC_ANT_SEL[1:0]` (`0x1B`).

See [PSRAM Buffer Controller](blocks/PSRAM%20Buffer%20Controller.md).

---

## Stage 5 — SC Preamble Detector

Complex autocorrelation over the full symbol period `M = 1 << (SF + sample_shift)`, against the PSRAM-supplied `x[n−M]`. Single selected branch (`sc_ant_sel`, `SC_ANT_SEL` `0x1B[1:0]`; default branch 0 — see `sc-detector-ant0-fading-risk.md` for the deep-fade single-point-of-failure this leaves open). Detects the LoRa preamble and provides sample-accurate `timing_ref`. No dechirp required. (Corrected 2026-07-26: the old `L = min(M, 256)` block-based form went with the on-chip SRAM.)

**Per-block statistic (channel 0):**

```
c_0 = Σ_{n=0}^{L-1} current_0[n] · conj(delayed_0[n])
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
- `sc_lock` — asserted when statistic exceeds threshold for `SC_HITS_REQ + 1` consecutive symbol pairs
- `timing_ref` — estimated preamble-start sample index, back-calculated from the lock event

`sc_lock` is the terminal acquisition event in the non-FFT path. No downstream FFT or sync/downchirp refiner is needed — `timing_ref` alone locates the full packet.

**Note — complex IQ required for CFO immunity.** The SC metric `|c_j|² = ci² + cq²` is magnitude-squared of the complex autocorrelation and is independent of carrier frequency offset (the CFO phase rotates `c_j` but not its magnitude). Using only the I channel collapses the metric to `Re{c_j}² = |c_j|²·cos²(2πΔf·M·Ts)`, which drops to zero when CFO causes a 90° phase shift. In practice, all SX1257s and the ASIC share a single TCXO, so CFO is entirely due to the remote transmitter; at ±10 ppm / 915 MHz (≈ ±9 kHz) the per-sample phase error at 500 kS/s is small, making I-only detection viable — but this relies on a hidden hardware assumption and should not be made a deliberate design choice. Both I and Q must be fed to `sc_detector`.

> **⚠ Implementation gap — detection is antenna-0 only (deep-fade single point of failure).** The "incoherent combine across branches" above (`Mag_SC = Σ_j |c_j|²`, `Energy_Ref = Σ_j E_j_curr·E_j_del`) is **not implemented in RTL**. `sc_detector` (`rtl/sc_detector.v`) takes only `cur_i0/cur_q0/del_i0/del_q0` — antenna 0 — and `trouper_top` wires only branch 0 into it. The summations therefore degenerate to the `j=0` term. Consequence: if antenna 0 is in a deep fade, **the whole gateway fails to detect the packet even when antennas 1–3 are strong**, throwing away the diversity that the four-antenna front end exists to provide (detection has no diversity; only post-lock MRC training/combining does). Observed directly in `rtl-test/cocotb_trouper_capture` (measured-IQ playback): a Rayleigh realisation that faded ant0 ~18 dB (`branch_power=[0.016, 1.39, 0.52, 0.13]`) produced **no `sc_lock`** across the entire packet, while a realisation with ant0 strongest locked normally. This matches the spec's `NR=1 (channel 0 only)` line at the top of this stage, but contradicts the cross-branch combine formulas — the formulas describe the *intended* design, the RTL implements the reduced one. **Mitigation options:** (a) implement the real `Σ_j` incoherent combine across all four branches (restores detection diversity, costs 4× the autocorrelator MAC or TDM time); (b) select the SC reference antenna at runtime (firmware picks the branch with the highest `Zdiag`/RSSI) — cheap, because PSRAM already buffers all four channels (8 bytes/sample); `psram_buf_ctrl` just reads back branch 0 today, so it needs only a `sc_ant_sel` register + reading the chosen channel's delayed bytes, not a buffer redesign. Do not time-scan antennas (a round-robin scan can miss asynchronously-arriving preambles); (c) accept the limitation and document that ant0 must be the most reliable antenna in the install. See `planning/sc-detector-ant0-fading-risk.md`.

See [Correlator Bank (SC)](blocks/Correlator%20Bank.md).

---

## Stage 5.5 — Packet Control FSM

Owns packet phase and no-glitch switching between bypass and combined output. Converts SC timing events and weight-readiness signals into deterministic control for the frontend buffer, weight generation, and combiner.

**States:** IDLE → PREAMBLE_ACQ → W_PENDING → PAYLOAD_ACTIVE → IDLE

Key outputs:
- safe-switch boundary — a *condition* (FSM in IDLE), not an RTL signal: W/mode/antenna active banks may update. The former `safe_switch` output was deleted from `packet_ctrl_fsm`.
- `combiner_source` — bypass until W is valid for the current packet
- `packet_active` — asserted from `sc_lock` to packet end; gates PSRAM capture/replay and the `SF_CFG`/`PSRAM_EN` shadow registers

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

On-chip PicoRV32 firmware is triggered by `IRQ_TRAINING_DONE`, reads the all-pairs Z matrix from the register bank, computes weights in software, writes `W_SHADOW`, and pulses `W_COMMIT`. A host-assisted SPI path is retained as a fallback if firmware is held in reset. The primary modes are row-sum MRC and eigenvector power iteration; exact algorithm details live in firmware and simulation docs rather than hardened Trouper RTL.

Same-packet MRC requires firmware to meet the packet timing budget and, in the preferred architecture, PSRAM replay to re-present the full stored packet through the combiner after `W_ACTIVE` is committed.

See [Weight Generation](blocks/Weight%20Generation.md) for archived hardware exploration and [Trouper Chip Specification](Trouper%20Chip%20Specification.md) for the active contract.

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

`W_ACTIVE`, `ACTIVE_MODE`, and `ACTIVE_ANTENNA_EN` switch only at `safe_switch` boundaries (IDLE between packets). If W is not ready before the payload window closes, the current packet stays in bypass and the committed weight applies on the next eligible replay/packet boundary.

See [MRC Combiner](blocks/MRC%20Combiner.md).

---

## Stage 9 — ΣΔ Re-modulation

3rd order feed-forward ΣΔ modulator converts combined int8 samples back to a 32 MS/s bitstream for the SX1302 Radio A input. The combiner MRC output stage applies ÷2 (absorbing √NR=4 combining gain) before delivering int8; the bypass path delivers int8 directly.

| BW | f_s (combiner output) | OSR | In-band SQNR (3rd order) | Status |
| --- | --- | --- | --- | --- |
| 125 kHz | 500 kS/s | 64 | > 100 dB | Production (4× oversampled; fixed R=64 half-band for both BW modes) |
| 250 kHz | 500 kS/s | 64 | > 100 dB | Production (2× oversampled) |
| 500 kHz (1 MS/s) | 1 MS/s | 32 | > 85 dB | Out of scope |

All OSR values give SQNR far exceeding LoRa requirements. The 8-bit input gives ~44 dB effective SQNR (after ÷2); the quantisation noise floor is negligible at all supported bandwidths.

See [ΣΔ Re-modulator](blocks/ΣΔ%20Re-modulator.md).

---

## Bring-up & Calibration Recommendations

### 1. Analog Filter Matching

The SX1257 analog roofing filter (`RegRxBw`, 0x0D) must be matched to the selected digital bandwidth in `BW_CFG`.

| BW_CFG.bw_sel | Digital BW | Recommended SX1257 Analog BW |
| --- | --- | --- |
| `1` | 125 kHz | 250 kHz (minimum setting) |
| `0` | 250 kHz | 250 kHz |

If the analog filter is left wider than the digital sampling rate, signals and noise above the Nyquist frequency alias directly into the LoRa band.

### 2. Schmidl-Cox Threshold Calibration

- Detection threshold `θ_SC` via register `SC_THR`
- Consecutive hit requirement via register `SC_HITS_REQ`

Recommended starting points:
- **Default:** 0.90 — static indoor channels; matches rpp0/gr-lora default
- **Low SNR / mobile:** reduce to 0.75 — trades false-alarm rate for sensitivity
- **Hit-count encoding:** default `SC_HITS_REQ = 2` requires 3 hits; 1 requires 2 hits for aggressive weak-signal mode, and 3 requires 4 hits for noisy environments. Raw value 0 selects a diagnostic-only one-hit mode and shall not be used in normal reception.
- **False-alarm floor:** at threshold 0.90, noise-only statistic < threshold with > 99.9% probability (SF6, NR=4)

### 3. Weight Path Selection

- **Firmware MRC:** default tapeout path. PicoRV32 reads the training matrix, computes row-sum MRC or eigenvector weights, writes `W_SHADOW`, and pulses `W_COMMIT`.
- **Host-assisted weighting:** optional backup mode. An off-chip controller may write `W_SHADOW` and pulse `W_COMMIT` through the existing control path if PicoRV32 is unavailable.
- **EMA smoothing:** optional firmware enhancement; apply smoothing in DMEM and commit the filtered weights on a later packet/replay boundary.

Disable EMA (`ALPHA_SHIFT=0`) for mobile deployments where channel coherence time may be shorter than the averaging window.

### 4. Initial Gain Setting

Start at full gain (G1 + BB_MAX on all SX1257s) for maximum weak-signal sensitivity. The AGC loop converges within 1–3 packets via the `IRQ_CORR_LOCK` path. For a known deployment, pre-set the SX1257 gain directly (board-level SPI master) during bring-up, before the first packet — Trouper has no on-chip gain-shadow/commit register to stage this through (removed 2026-07-28). (There is no `CPU_RESET` — Trouper has no on-chip CPU; corrected 2026-07-26.)

---

## Key design constraints

| Constraint | Value | Impact |
| --- | --- | --- |
| Decimation ratio | **Fixed R=64** (CIC-3 R=16 → HB1 ÷2 → HB2 ÷2) | 32 MS/s 1-bit → 500 kS/s int8. BW is selected by `sample_shift` oversampling, *not* by changing R: 250 kHz = 2× (`sample_shift=1`), 125 kHz = 4× (`sample_shift=2`). 1 MS/s is out of scope (PSRAM timing budget) |
| Symbol period | `M = 1 << (SF + sample_shift)` | 256 (SF7/250 kHz) to 16384 (SF12/125 kHz) |
| SC detection delay line | `x[n−M]` read from **off-chip PSRAM** at `write_ptr − M` | No on-chip SRAM and no block-based windowing; one QPI read per `iq_valid`, 19 of the 64 available cycles (TRPR-PSR-014) |
| Training accumulation | `TACC_WINDOW_SYMS × M`, default 8 symbols | See `DSP Chain SNR Loss Budget.md` for the truncation term — that figure is under review (audit item 15) |
| Firmware weight generation | 8-iteration eigenvector: **33,283 cyc / 2.08 ms** (rv32im), 36,458 / 2.28 ms (rv32emc) at 16 MHz, SF-independent | Replay mode's deadline is `packet_end` so all SFs fit; live mode's is `4·M / 500 kHz`, which fits **SF9+ only** — replay is mandatory for SF7/SF8 (TRPR-WGN-004) |
| Host-assisted weight generation | board/software dependent | Valid bring-up or backup path; compute is effectively free but bounded by host IRQ latency, which is unmeasured |
| ΣΔ re-mod | 3rd order, single instance | SQNR > 100 dB at OSR=64 (500 kHz BW) — LoRa headroom > 70 dB |
