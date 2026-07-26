# Test Plan

## Strategy

**Primary method:** FPGA-in-the-loop, block-level first, then integration

**Golden reference:** Python simulation in `sim/` (numpy/scipy), plus real SX1257 hardware for loopback

**FPGA platform:** Digilent Arty A7-100T (Artix-7 XC7A100T, 63K LUTs). Vivado for synthesis and P&R. Est. ~30% LUT utilisation for full MIMO path.

**Test data:** Real captured LoRa I/Q samples (CF32 format, 125 kHz BW), sigma-delta modulated to 1-bit at 32 MS/s. Real-world impairments from day one. Existing captures in `sim/`.

## Verification pyramid

| Level | Method | When |
| --- | --- | --- |
| L1 — RTL simulation | iverilog + cocotb, numpy/scipy golden models | Block bring-up — catch bugs before FPGA |
| L2 — FPGA-in-the-loop | Arty A7-100T, synthetic + captured data, SX1257 digital loopback | Primary validation of combined MIMO path |
| L3 — Over-the-air | Two real LoRa nodes at f₀±Δf → SX1257 ×4 → ASIC RTL → SX1302 → ChirpStack | Final system validation |

---

## Block test sequence

### Block 1 — ΣΔ Decimator (CIC + FIR, ×4)

**Pass criterion:** RMS error vs scipy reference < 1 LSB. Frequency response within ±0.5 dB across 0–500 kHz. All 4 instances produce identical output given identical input.

**Method:**
- Generate synthetic chirp in Python → sigma-delta modulate to 1-bit @ 32 MS/s → load into FPGA block RAM → clock through decimator → capture output
- Compare against `scipy.signal.decimate()` reference via cocotb
- Check accumulator overflow: inject max-rate toggling (all 1s) input

**Test matrix:**

| Input | Expected |
| --- | --- |
| DC (all 1s) | Settles to +127 within N×R cycles |
| DC (all 0s) | Settles to −128 within N×R cycles |
| Sine at 100 kHz, −3 dBFS | Output matches scipy to ±1 LSB |
| Sine at 600 kHz (stopband) | Attenuation > 40 dB |
| Max toggle (alternating 1/0) | No accumulator wrap |

---

### Block 2 — Energy Measurement

> **Superseded 2026-07-26 (same defect class as audit item 18).** The `ENERGY[n]`
> registers and the lock-latched energy snapshot went with `noise_est.v`; `ENERGY_THR`
> and `SC_CFG` are listed under *Removed registers*. Per-branch power is now read from
> `ZDIAG_k` (`0x64`–`0x6F`) divided by `n_acc`, and noise-only power from a
> firmware-armed `TACC_NOISE_TRIG` window.

**Pass criterion:** `ZDIAG_k / n_acc` matches the Python reference branch power within
Q-format rounding, and ranks the four branches by received power correctly. In noise
mode, `ZDIAG_k ≈ σ²_k × n_acc` with `NOISE_READY` gating out SC-contaminated windows.

**Method:**
- Inject known-amplitude per-branch signals; compare `ZDIAG_k/n_acc` against the model
- Measured-capture playback asserts the branch power ranking (`cocotb/trouper_capture`)
- Arm `TACC_NOISE_TRIG` between packets; verify `NOISE_READY` and the σ² estimate

---

### Block 3 — Correlator Bank (single shared correlator, ×4 branches)

**Pass criterion:** `|H_j,k|` magnitude matches Python correlator reference to within ±2 LSB after 8-symbol integration. `lock` flag asserts within ±1 symbol of Python model prediction. Cross-correlator term (wrong Δf bin) < −20 dB relative to on-bin term.

**Method:**
- Generate synthetic LoRa preamble (8 upchirps) at f₀+Δf for node 1, f₀−Δf for node 2
- Feed through 4 decimator instances (different per-antenna channel gains applied in Python)
- Compare H matrix and lock timing to Python `sim/receiver.py` reference

**Test matrix:**

| Scenario | Expected |
| --- | --- |
| NT=1, clean preamble, 0 dB SNR | lock, correct H column 0 |
| NT=1, minimum SNR (sweep to find threshold) | lock within 8 symbols |
| NT=2, both nodes present | lock, both H columns valid, cross-term < −20 dB |
| Noise only (no preamble) | no lock for 1000 symbol periods |
| Δf mismatch (±1 bin) | no lock — confirms bin selectivity |
| `SC_HITS_REQ` sweep (1,2,3) | lower hit count reduces latency / sensitivity threshold; higher hit count reduces false locks |

---

### Block 4 — Training Accumulator + Weight Generation

> **Non-FFT path:** FFT Engine test is not applicable. This block is now split between the Trouper Training Accumulator RTL and firmware weight generation. See [Training Accumulator](blocks/Training%20Accumulator.md), [Trouper Chip Specification](Trouper%20Chip%20Specification.md), and [Firmware Spec](Firmware%20Spec.md).

**Pass criterion (Training Accumulator):** `Z_j / n_acc` matches Python reference `h_j` within Q1.15 rounding on a noiseless channel. `training_done` asserts at the correct sample boundary. `n_acc` matches `(TACC_WINDOW_SYMS - SC_HITS_REQ - 1) × M - 1` — with the reset defaults (`TACC_WINDOW_SYMS = 8`, `SC_HITS_REQ = 2`) that is `5M - 1`; the `-1` is real and is asserted by `cocotb/tests/test_trouper_top.py` (`7M - 1` in its `SC_HITS_REQ = 0` configuration). `TACC_WINDOW_SYMS` is clamped to ≥ 8 on write (`reg_bank.v:240`), so windows below 8 cannot be tested from the register interface. In noise mode the window is forward-only from the trigger and `n_acc == 8M` exactly (`cocotb/tests/test_noise_trig.py`).

**Pass criterion (Firmware Weight Generation):** Firmware-computed weights match the Python reference for the selected algorithm (row-sum MRC or eigenvector power iteration) to within the expected Q1.15 rounding error. `W_COMMIT` is issued within the timing budget for the SF under test after `training_done` (`SF_CFG` valid range is 7–12; SF5/SF6 are out of scope). The measured 8-iteration eigenvector kernel costs 2.08 ms (rv32im) / 2.28 ms (rv32emc) at 16 MHz independent of SF, so in **live** mode only SF9+ meets the `4·M / 500 kHz` deadline — SF7 and SF8 must be tested in **PSRAM replay** mode, where the deadline scales with payload length (TRPR-WGN-004). Full same-packet delivery is proven with PSRAM replay tests, not by a standalone hardware weight FSM latency check.

**End-to-end SPI weight flow:** `rtl-test/tb/test_weight_gen_spi_flow.py` drives the full off-chip-MCU loop against real captured IQ data (4 antennas at distinct gains) — `sc_lock` → `training_done` IRQ → SPI-read `Z_kl`/`Zdiag` (`0x40`–`0x6F`) → firmware-accurate eigenvector computation → SPI-write `W_SHADOW` (`0x30`–`0x3F`) → `W_COMMIT` → combiner output, compared bit-exact against an independent oracle model (`sim/models/receiver.py`). Passing (SGE job 3286, `max_err=0.00`); see `planning/Open Risks.md` #33 for findings surfaced while building it (undocumented Q0.7 combiner weight precision, now in the Register Map's `0x30`–`0x3F` section).

**Test matrix:**

| Test | Pass criterion |
| --- | --- |
| Noiseless single-path, SF6 | `Z_j / n_acc` matches `h_j` within rounding |
| Noiseless single-path, SF7 | `Z_j / n_acc` matches `h_j` within rounding when the selected sample-memory mode is valid |
| CFO immunity ±10 kHz | Firmware weights remain correctly phase-aligned to h_j |
| MRC all branches equal | Firmware outputs equal-magnitude MRC/eigenvector weights with no unexpected clipping |
| Eigenvector vs row-sum | Eigenvector path matches Python model and outperforms row-sum on noisy cases |
| Single-branch dominance | Firmware collapses weight to the dominant branch when the channel is strongly imbalanced |
| 8-bit saturation vs full-precision | SC lock timing unaffected at −10 dB SNR |
| Strong signal saturation | SC lock and training accumulator degrade gracefully |

---

### Block 5 — MRC Combiner

**Pass criterion:** Combined output `ŷ[n]` matches Python matrix multiply reference to within ±2 LSB. Post-combining SNR improvement matches theoretical MRC gain (10·log10(NR) dB = 6 dB for NR=4) within 1 dB on a flat channel.

**Method:**
- Pre-load W register bank with known MRC weights computed by Python
- Inject 4-channel int8 test vectors through combiner
- Compare output stream to `W @ x` computed in numpy

**Test matrix:**

| Mode | W | Input | Expected gain |
| --- | --- | --- | --- |
| NT=1 MRC | H* / (‖H‖²+N₀) | 4 equal-amplitude channels | ~6 dB vs single antenna |
| NT=1 MRC | Degenerate (1 antenna only) | One channel active | Matches single-channel SNR |
| ~~NT=2 ALMMSE~~ | — | — | **Out of scope** — NT=1 design; full ALMMSE is not implemented (TRPR-WGN-006/012) |
| ~~NT=2 ALMMSE, ill-conditioned H~~ | — | — | **Out of scope**, as above |

---

### Block 6 — ΣΔ Re-modulator ×2

**Pass criterion:** Re-demodulated output (Python decimation of 1-bit re-mod stream) matches int8 input to within ±1 LSB RMS. In-band SQNR > 40 dB at −6 dBFS (expected ~44 dB; 8-bit input limits effective SQNR regardless of OSR).

**Method:**
- Inject known int8 sine at −6 dBFS → capture 1-bit output → decimate in Python → compare to input
- Stability test: inject input at −3 dBFS and 0 dBFS (should clip/saturate not diverge)
- Both re-mod instances tested independently and simultaneously

**Test matrix:**

| Input | Expected |
| --- | --- |
| Sine at −6 dBFS | SQNR > 80 dB after Python decimation |
| Input at 0 dBFS | Integrators saturate, no runaway |
| DC input | Output bitstream average matches DC value |
| Re-mod B idle (Mode 1) | REMOD_B_I/Q pads driven to defined idle level |

**RTL regression — `REMOD_BACKOFF_SHIFT` (register `0x0F`):** `rtl-test/tb/test_remod_backoff.py` verifies the register end-to-end through `trouper_top` (not just the Python model): (1) `remod_in_i/q == comb_y_i/q >>> shift` bit-exact for shift 0–3; (2) at a forced near-full-scale (~0 dBFS) MRC combiner output, the reset-default `shift=1` keeps `sd_remod`'s 1-bit output dithering (healthy) while `shift=0` measurably degrades it (longer runs of the output frozen at a constant value). Note: `sd_remod`'s integrator states (`s1/s2/s3`) are *not* a usable instability signal on their own — `sat16` clips them near the rail during essentially all normal healthy operation, not just fault conditions; the output's dither/freeze behavior is the real signature. Passing (SGE job 3294).

---

### Block 7 — SPI Slave (host interface)

**Pass criterion:** All register R/W operations via RPi SPI0 match expected values. CHIP_ID reads `0xA7`. Reset values match the map on every implemented address, and RO/W1P/W1C behaviour matches the map's access column.

**Method:**
- cocotb testbench simulates RPi SPI master; write and read back every defined register
- Reset/access sweep over the whole 7-bit map (`cocotb/reg_reset_sweep`, TRPR-REG-001)
- Grouper-vs-SPI arbitration, Grouper priority (`tb_trouper_grp_arb.v`)
- SPI-domain CDC scenarios: phase sweep, back-to-back frames, burst, read side effects, reset interrupt, abort, clock limit, W1P (`cocotb/spi_cdc`)

> **Removed 2026-07-26 (audit item 18).** This block previously specified extended
> firmware-load opcodes `0x01`/`0x02`, a `CPU_RESET` boot sequence, CPU SRAM banks
> `BANK0`–`BANK2`, a reserved `BANK3`/`CPU_SRAM_BORROW_BANK`, and per-bank BIST
> registers. Trouper has no on-chip CPU and no on-chip SRAM (§3.x, TRPR-PHY-006), and
> the extended SPI frame was removed with §4.11. None of it is testable.

**Additional matrix:**

| Test | Pass criterion |
| --- | --- |
| Register reset sweep | Every implemented address reads its documented reset value; resetless Z-bank (`0x40`–`0x6F`) excluded by design |
| Write-lock behaviour | `0x30`–`0x3F` writes rejected while `W_VALID`, setting sticky `W_WR_REJECTED` (`0x1E[5]`) |
| Mid-packet write gates | `SF_CFG`, `BW_CFG`, `PSRAM_EN`, `SC_FORCE_LOCK` writes ignored while `PACKET_ACTIVE` |

---

### Blocks 8 and 9 — retired 2026-07-26 (audit item 18)

Both blocks tested hardware Trouper does not contain.

**Block 8 — SPI Master (→ SX1257).** Trouper has no on-chip SPI master (TRPR-SPM-001).
SX1257 configuration is external: the host RPi or Grouper programs the four front-ends
directly, so there is no Trouper-side transaction to capture, and no master/slave bus
contention to check. AFE bring-up coverage lives in
[Frontend Calibration Procedure](Frontend%20Calibration%20Procedure.md) and
[AFE Characterisation Board](AFE%20Characterisation%20Board.md).

**Block 9 — PicoRV32 + Firmware.** There is no CPU in Trouper (§3.x); weight computation
is performed by Grouper firmware or the host, and Trouper consumes only the committed W
bank. The old pass criteria are superseded on three counts: the CPU SRAM banks and borrow
bank do not exist; the `H`/`N₀` register interface does not exist (firmware reads `Z`
from `0x40`–`0x6F` instead); and "within one LoRa symbol period of correlator lock" was
the removed next-packet constraint, explicitly superseded by TRPR-WGN-004, whose real
deadline is `packet_end` in replay mode and `4·M / 500 kHz` in live mode.

Current equivalent coverage:

| Concern | Where it is actually tested |
| --- | --- |
| Firmware weight computation matches the reference model | `cocotb/tests/test_weight_gen_spi_flow.py` (bit-exact vs `sim/models/eigvec_fw.py`, job 3286); `sim/tests/test_eigvec_fw.py` |
| Weight-commit timing against the real deadline | `planning/blocks/Eigenvector Weight Computation.md` Timing Budget (cycle-accurate, jobs 3333–3335) + TRPR-WGN-004 |
| Same-packet delivery of trained weights | PSRAM replay suite (`cocotb/replay_data`, `cocotb/replay_delay`, `test_capture_playback.py`) |
| Missed / late commit degradation | `cocotb/tests/test_w_missed_packet.py` (job 3310), `W_COMMIT_LATE` sticky |
| AGC convergence | Software-owned (TRPR-AGC-002 thresholds are firmware constants); not a Trouper RTL test |
| NT=2 mode auto-switch | Out of scope — this is an NT=1 design |

---

## SX1257 loopback validation

Uses SX1257 built-in loopback once hardware is assembled.

### Digital loopback (SX1257 §3.8.1)

Connects `I_IN`/`Q_IN` to `I_OUT`/`Q_OUT` inside the SX1257 — validates the round-trip digital baseband path without RF.

| Test | Method | Pass criterion |
| --- | --- | --- |
| Single-tone round-trip | Enable digital loopback; inject known symbol; check SX1302 RX | SX1302 decodes correct packet |
| Interface timing | Check I/Q setup/hold vs CLK_OUT falling edge (logic analyser) | No timing violations |

### RF loopback (SX1257 §3.8.2)

See [Frontend Calibration Procedure](../Frontend%20Calibration%20Procedure.md) for the full step-by-step procedure to derive `cal_j` from RF loopback or external common-tone measurements and program the `CAL` registers.

| Test | Method | Pass criterion |
| --- | --- | --- |
| I/Q gain mismatch | Enable RF loopback; inspect decimator output spectrum | < 1 dB mismatch |
| TX DC offset | Check baseband bin 0 from diagnostic capture | < −30 dBc |
| Inter-branch phase calibration | Follow calibration procedure Method B | Post-cal phase spread < 5° |
| Inter-branch amplitude calibration | Follow calibration procedure Method A | Post-cal amplitude spread < 0.5 dB |

### AFE characterization before full-system integration

These checks are intended to de-risk coherent combining before full packet-path testing is available. The primary method is synchronous FPGA capture of the four SX1257 `1-bit I/Q` outputs after injecting a common RF source through a 4-way splitter. The MISO front-end test board (AFE) used for this characterization is at <https://gitlab.com/m0rtal/miso_frontend>.

| Test | Method | Pass criterion |
| --- | --- | --- |
| Per-branch LO offset | Inject one common CW tone; capture 4 synchronized sigma-delta streams in FPGA; decimate and estimate `df_j` from inter-branch phase slope | Branch-to-branch frequency mismatch within defined drift budget |
| RX DC offset stability | With RF input terminated and then with RF loopback/CW enabled, capture per-branch decimated I/Q over temperature, gain states, and time; estimate DC mean before any DSP high-pass removal | Decide whether RX DC can be treated as a one-time/per-gain calibration term or requires continuous DSP tracking |
| LO drift vs time | Hold common CW tone; log `df_j` and `phi_j` over time from FPGA capture | Drift remains within packet-coherence budget |
| LO drift vs temperature | Repeat common-tone FPGA capture across temperature range | No branch exceeds allowed differential drift |
| RX gain mismatch | Inject one common CW tone; estimate `G_j_dB` from fitted branch tone amplitude | Gain spread within calibration budget |
| Branch phase mismatch | Inject one common CW tone; estimate `phi_j` after common decimation | Residual phase mismatch within combining budget |
| Compression / near-far | Sweep input power with common tone; track `C_j(Pin)` and mismatch growth per branch | Compression onset variation within allowed budget |
| LO leakage / DC spur | Measure `DC_j_dBc` after decimation; optionally cross-check with spectrum analyzer | Spur level low enough not to corrupt channel estimation |

**Supporting instrument:** Spectrum-analyzer measurements are still useful for absolute RF checks such as leakage, carrier placement, and compression, but the FPGA capture path is the primary method for coherent branch characterization.

**Fixture note:** The common-tone setup should be treated as a configurable RF fixture, not only a one-time bring-up connection. Use a 4-way power splitter to feed all branches from one source, add fixed or stepped attenuators as needed for equal-power, mismatch, and near-far cases, and keep a record of the attenuation placed in each branch. Also include a controlled cable-length experiment: first use equal-length cables as the baseline, then introduce known length differences on selected branches to create deterministic phase shifts at the test frequency. This helps separate stable fixture-induced phase offsets from true SX1257/clock-path mismatch and gives a simple lab check that the estimated `phi_j` tracks expected RF path delay.

**Disposition rule:** A failed AFE characterization result must not stop at "out of spec". Each failure must be classified as `accept`, `calibrate`, `mask/fallback`, or `hardware action`, with the chosen mitigation recorded before moving to full MIMO integration.

---

## Integration test — full MIMO path

First test with all blocks connected. Run after all block tests pass.

| Test | Method | Pass criterion |
| --- | --- | --- |
| NT=1 MRC, single node, SF7 | Real node → SX1257 ×4 → ASIC RTL → SX1302 → ChirpStack | Packet received and decoded |
| NT=1 MRC, single node, SF7 via PSRAM replay | Real node → SX1257 ×4 → ASIC → SX1302 → ChirpStack, `PSRAM_EN=1` | Packet decoded with `REPLAY_ACTIVE` observed and `REPLAY_MISSED=0` |
| NT=1 MRC, late weight commit | Withhold `W_COMMIT` until after replay start | Packet still decoded; `W_COMMIT_LATE` sticky set (partial diversity, not a whole-packet miss) |
| NT=1 MRC, sensitivity sweep | Vary node TX power | Sensitivity ≥ standard SX1302 single-antenna (−125 dBm SF7) |
| NT=1 MRC, gain vs single antenna | Compare PER with 1 vs 4 antennas enabled | ≥ 4 dB improvement at threshold SNR |
| NT=1 noise-weighted MRC | Per-branch noise floors deliberately unequal | Combining gain ≥ plain MRC; weights track `1/σ²_ema[k]` |
| AGC settling | Start at mid-gain; vary path loss by 20 dB | AGC converges within 3 packets |

---

## End-to-end over-the-air validation

Two Heltec V3 nodes (or equivalent) configured at f₀±Δf → 4 antennas → SX1257 ×4 → ASIC → SX1302 → RPi ChirpStack

**Pass criterion:** PER ≤ 1% for both nodes simultaneously at −10 dB SNR.

---

## Test data pipeline

Real LoRa captures available in `sim/` (CF32 format). Processing for RTL stimulus:

```
1. Load CF32 at 250 kHz BW (sim/load_capture.py)
2. Resample to 32 MS/s
3. Sigma-delta modulate to 1-bit (1st-order Python modulator)
4. Pack to bitstream file
5. Load into FPGA block RAM → feed to decimator RTL
```

For multi-antenna testing: apply independent per-antenna complex gains and phase shifts in Python to simulate a spatial channel before sigma-delta modulation.

---

## Tooling

| Task | Tool |
| --- | --- |
| Golden reference model | Python — `sim/` (numpy, scipy) |
| Sigma-delta modulation | Python script |
| RTL simulation | iverilog + cocotb |
| FPGA bitstream | Vivado (Artix-7 XC7A100T) |
| In-circuit debug | Vivado ILA over USB-JTAG |
| SPI traffic capture | Saleae Logic / sigrok |
| Physical synthesis | Yosys + OpenROAD (GF180MCU) |
| Regression runner | Makefile + cocotb |
