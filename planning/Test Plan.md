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

**Pass criterion:** `ENERGY[n]` registers match `Σ|x|²` computed by Python reference over the same 8-symbol window. Lock-latched energy snapshot is stable and packet-consistent.

**Method:**
- Inject known-amplitude sine through decimator → measure ENERGY vs Python reference
- Assert a known correlator-lock event → verify the exported energy snapshot matches the expected lock-time window

---

### Block 3 — Correlator Bank ×8

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

**Pass criterion (Training Accumulator):** `Z_j / n_acc` matches Python reference `h_j` within Q1.15 rounding on a noiseless channel. `training_done` asserts at the correct sample boundary. `n_acc` matches `(8 - SC_HITS_REQ - 1) × M`.

**Pass criterion (Firmware Weight Generation):** Firmware-computed weights match the Python reference for the selected algorithm (row-sum MRC or eigenvector power iteration) to within the expected Q1.15 rounding error. `W_COMMIT` is issued within the SF5/SF6 timing budget after `training_done`. Full same-packet delivery is proven with PSRAM replay tests, not by a standalone hardware weight FSM latency check.

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
| NT=2 ALMMSE | Computed from 2×4 H | Both nodes present | Node separation > 20 dB |
| NT=2 ALMMSE, ill-conditioned H | κ(H) >> 1 | Near-collinear channels | Output valid, no overflow |

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

**Pass criterion:** All register R/W operations via RPi SPI0 match expected values. CHIP_ID reads `0xA7`. Extended firmware-load commands write and read back byte-identical CPU SRAM contents in the firmware-visible banks. Firmware load and CPU_RESET sequence boots PicoRV32 without touching the reserved borrow bank.

**Method:**
- cocotb testbench simulates RPi SPI master; write and read back every defined register
- Issue extended opcode `0x01` firmware-load writes into firmware-visible CPU SRAM window only (`BANK0`–`BANK2`)
- Issue extended opcode `0x02` firmware-readback and compare against written bytes
- Firmware load sequence: assert `CPU_RESET`, load test binary, de-assert, verify PicoRV32 fetches from `0x00000`

**Additional matrix:**

| Test | Pass criterion |
| --- | --- |
| Borrow-bank exclusion | Firmware image and readback never touch reserved `BANK3` / `CPU_SRAM_BORROW_BANK` |
| Reserved-bank persistence | Preload a sentinel pattern into `BANK3`, release `CPU_RESET`, and confirm the sentinel is unchanged after firmware boot |
| Per-bank BIST visibility | Host can read `CPU_SRAM_BANK0_PASS..CPU_SRAM_BORROW_BANK_PASS` distinctly |

---

### Block 8 — SPI Master (→ SX1257)

**Pass criterion:** All SX1257 register writes produce correct SPI transactions (correct chip select, correct opcode/address/data sequence). No bus contention with SPI slave during simultaneous activity.

**Method:**
- Logic analyser / cocotb SPI monitor: capture SPI_MOSI/SCK/CSn during a `RegMode` write
- Verify byte sequence matches SX1257 register write format (§5.1 of SX1257 datasheet)
- Verify MISO tristating while acting as master

---

### Block 9 — PicoRV32 + Firmware

**Pass criterion:** Firmware computes correct W matrix (verified against Python reference) within one LoRa symbol period of correlator lock. AGC converges within 3 packets on a static channel. Mode auto-switch triggers correctly on NT=2 preamble pair. When borrow mode is supported with `CPU_RESET=0`, firmware operates correctly while respecting the reserved upper borrow bank.

**Method:**
- Write H matrix and N₀ to registers; release CPU_RESET; read back W matrix after IRQ
- Compare W to Python `W = (H^H @ H + N0*I)^-1 @ H^H`
- Inject two-node preamble (NT=2); verify ACTIVE_MODE register switches to 1

**Additional matrix:**

| Test | Pass criterion |
| --- | --- |
| Linker reservation | `.text/.data/.bss/stack` are placed only in `BANK0`–`BANK2`; map file shows no allocation in reserved `BANK3` |
| Runtime exclusion | C runtime zero/init path does not clear or write reserved `BANK3` |
| Shared borrow with CPU live | With `CPU_RESET=0` and `CPU_SRAM_BORROW_EN=1`, AGC still runs and borrowed-bank sentinel data is preserved |

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
| NT=1 MRC, single node, SF7 with borrow bank enabled | Real node → SX1257 ×4 → ASIC RTL → SX1302 → ChirpStack | Packet received and decoded with `CPU_SRAM_BORROW_BANK_PASS=1` and `CPU_SRAM_BORROW_EN=1` |
| NT=1 MRC, single node, SF7 borrow bank failed | Force `CPU_SRAM_BORROW_BANK_PASS=0` / inject fault | System downgrades to `NR=2` on branches `1` and `3`; packet still received in degraded mode |
| NT=1 MRC, sensitivity sweep | Vary node TX power | Sensitivity ≥ standard SX1302 single-antenna (−125 dBm SF7) |
| NT=1 MRC, gain vs single antenna | Compare PER with 1 vs 4 antennas enabled | ≥ 4 dB improvement at threshold SNR |
| NT=2 ALMMSE, two nodes, SF7 | Both nodes transmit simultaneously | Both packets received and separated |
| Mode auto-switch | Start in NT=1; bring up second node | ACTIVE_MODE transitions to 1 within one packet |
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
