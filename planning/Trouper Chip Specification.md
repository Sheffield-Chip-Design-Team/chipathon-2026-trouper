# Trouper DSP Chip Specification

## Document Control

| Field | Value |
|---|---|
| Document ID | TRPR-SPEC-001 |
| Version | 0.5 |
| Status | DRAFT |
| Date | 2026-07-18 |
| Project | SSCS PICO Chipathon 2026 — Trouper (DSP) |
| Companion | Grouper is a separate hardened control macro; Trouper is hardened independently and integrated with Grouper only at a later top level |

> **Requirement notation:** SHALL = mandatory, SHOULD = strongly recommended, MAY = optional.
> **Columns:** ID · Priority (C=Critical / H=High / M=Medium / L=Low) · Type (F=Functional / P=Performance / I=Interface / HW=Physical) · Requirement · Verification (T=Test/Simulation / A=Analysis / I=Inspection)

---

## 1. Scope

Trouper is a pure DSP ASIC implementing a NT=1 NR=4 Maximum Ratio Combining (MRC) LoRa diversity receiver in GF180MCU (3.3 V). It accepts four 1-bit ΣΔ I/Q streams from SX1257 RF front-ends, performs preamble detection, channel estimation, and MRC combining, and outputs a 1-bit ΣΔ re-modulated combined stream to an SX1302 LoRa baseband.

Trouper is a standalone hardened DSP macro. In the current top-level RTL it exposes a simple external byte-oriented configuration/status interface rather than embedding PicoRV32 or an on-chip AHB-Lite master/slave fabric. Weight computation is performed externally by Grouper firmware or a host-assisted software path. Trouper SHALL also operate in bypass mode when no weight commit is received or the external control plane is inactive.

---

## 2. Definitions

| Term | Definition |
|---|---|
| Grouper control plane | Separate hardened RV32IM control macro; accesses Trouper from a higher-level top integration, not from inside the standalone Trouper hard macro |
| Host SPI | External Raspberry Pi or equivalent controller using the SPI slave for Trouper register access and debug |
| MRC | Maximum Ratio Combining — coherent weighted sum of NR=4 antenna branches |
| SC lock | Schmidl-Cox preamble lock; triggers training accumulation |
| W | Complex weight vector, 4 × int8 Q0.7 (combiner consumes the high byte of each 16-bit shadow field at 0x30–0x3F); written pre-conjugated by Grouper firmware or host-assisted control software; applied by MRC combiner |
| Z_kl | Cross-correlation accumulator between branches k and l; all 6 pairs C(4,2) + 4 diagonal |
| Training window | 8 × M samples from SC lock; defines n_acc |
| sample_shift | Oversampling exponent: 1 (250 kHz), 2 (125 kHz), from `BW_CFG.bw_sel` |
| M | Symbol period in output samples = 1 << (SF + sample_shift) |
| Bypass mode | Combiner passes lowest-enabled antenna directly to output without weighting |
| AHB-Lite | AMBA 3 AHB-Lite protocol used on the inter-project Grouper-to-Trouper control link and within Trouper's local register/peripheral fabric |

---

## 3. System-Level Requirements

| ID | Pri | Type | Requirement | Verif |
|---|---|---|---|---|
| TRPR-SYS-001 | C | F | Trouper SHALL receive four independent 1-bit I+Q ΣΔ bitstreams from SX1257 AFEs at 32 MS/s per branch. | T |
| TRPR-SYS-002 | C | F | Trouper SHALL output a single MRC-combined 1-bit I+Q ΣΔ stream at 32 MS/s to SX1302 Radio A. | T |
| TRPR-SYS-003 | C | P | Trouper operates from a single external 32 MHz clock (IQ_CLK) driving one clock net — no divided or generated clocks, no CDC, no metastability synchronisers. Quasi-static control-plane blocks update only on a `ce_16m` clock-enable (honest MCP=2); paced datapath TDM engines carry RTL hold counters (honest MCP=3). The SDC declares only `create_clock -period 31.25` on IQ_CLK plus scoped multicycle constraints matching the RTL pacing (TRPR-PHY-014). | I |
| TRPR-SYS-015 | C | P | **Full-rate paths** — logic that acts on every IQ_CLK edge SHALL meet single-cycle (31.25 ns) setup timing: the decimator CIC integrators, `sd_remod`, and the `psram_buf_ctrl` QPI FSM. The TDM/MAC cones in `sd_decimator_poly`, `sc_detector`, `training_acc`, and `mrc_combiner` are paced by RTL hold counters to a genuine 3-cycle budget and SHALL be constrained as scoped MCP=3 paths (see TRPR-PHY-008 for the residual SS gap). | I |
| TRPR-SYS-016 | C | P | **CE-gated control plane** — `reg_bank` (incl. interrupt aggregation), `spi_slave`, and `packet_ctrl_fsm` SHALL update only on the `ce_16m` clock-enable (62.5 ns effective budget, honest MCP=2). `dc_removal` and `training_acc` update only on their valid strobes. All handshakes are CE-aligned by construction on the single clock net — there are no clock-domain crossings. Weight generation is not an RTL block in Trouper; it is performed entirely by Grouper firmware or an equivalent host-assisted software path (see §4.6). | I |
| TRPR-SYS-004 | C | F | Trouper SHALL support **125 kHz and 250 kHz** BW via the fixed R=64 half-band decimator (500 kS/s); `BW_CFG.bw_sel` selects BW (sets `sample_shift`, not decimation ratio). 1 MHz out of scope. See `planning/decimator-hb-migration-impact-plan.md`. | A |
| TRPR-SYS-005 | C | F | Trouper SHALL operate in standalone bypass mode when no weight commit is received, routing the lowest-numbered enabled antenna to the output. | T |
| TRPR-SYS-006 | C | I | Trouper SHALL expose a byte-oriented external configuration/status interface that can be driven by a higher-level integration wrapper or companion control macro. | T |
| TRPR-SYS-007 | H | I | Host-side SPI access, if required in the final chip, SHALL be provided by the higher-level integration wrapper around the hardened Trouper macro rather than by logic embedded in the standalone Trouper hard macro. | T |
| TRPR-SYS-008 | C | HW | Trouper SHALL be fabricated in GF180MCU (gf180mcuD PDK), 3.3 V core and IO, targeting the `gf180mcu_fd_sc_mcu7t5v0` standard-cell library. | I |
| TRPR-SYS-009 | C | HW | Trouper SHALL use the Chipathon workshop padring as the physical baseline: die `2935 um × 2935 um`, user core `2493 um × 2493 um`. Trouper itself targets **`1100 um × 1100 um`**, which fits within the quarter-slot budget. | I |
| TRPR-SYS-010 | C | P | The end-to-end RTL implementation SHALL be validated bit-exactly against the Python reference model in `sim/models/receiver.py` across the full input dynamic range. | T |
| TRPR-SYS-011 | H | P | Post-PNR setup WNS at TT/25 °C/3.3 V SHALL be positive. SS/125 °C/3.0 V timing shall be documented; MCP or clock-domain partitioning is the preferred path to closure. | A |
| TRPR-SYS-012 | H | F | Trouper SHALL provide an active-low chip reset pad (RESETB). All state SHALL be cleared on assertion; DSP datapath SHALL resume within one IQ_CLK cycle after de-assertion. | T |
| TRPR-SYS-013 | H | P | Estimated total power at TT/25 °C/3.3 V SHALL be documented for each P&R run. Target ≤ 60 mW. | A |
| TRPR-SYS-014 | M | F | Trouper SHALL support two operating modes: MRC NR=4 (Mode 0) and single-antenna passthrough (Mode 1). | T |
| TRPR-SYS-017 | C | F | Trouper SHALL implement **same-packet MRC** as the primary operating mode. The PSRAM Buffer Controller SHALL continuously stream all decimated I/Q samples to an external APS6404L PSRAM. After `training_done` plus the `REPLAY_DELAY_SAMPLES` margin, the controller SHALL replay the stored packet from the preamble start through the MRC combiner as a never-rewinding delay line, with the committed weights applied from `W_COMMIT` onward (TRPR-PSR-003/004). This ensures the trained weights are applied to the packet they were derived from, not the next packet. An uncommitted packet replays in bypass — degraded, never lost. | T |
| TRPR-SYS-018 | C | HW | An external APS6404L PSRAM (8 MB, QSPI) SHALL be present on the host board. Trouper SHALL initialise the device once firmware sets `PSRAM_CTRL.PSRAM_EN=1` (not automatically on reset — RTL enforces no on-chip tPU wait; firmware SHALL not set this bit until ≥150 µs after PSRAM power-up, see Open Risks #27.1) and defaults QSPI ownership to the local `psram_buf_ctrl` path. A register-controlled handover away from the replay controller MAY be supported for future firmware-managed off-chip memory access. Board designs without PSRAM are not supported. | A |

### 3.1 Clock Architecture

Single clock: the external 32 MHz `IQ_CLK` drives every flop. There is no divided or generated clock net and no CDC anywhere in the core. The timing tiers below are *constraint* tiers, not clock domains:

| Tier | Mechanism | Effective budget | Blocks |
|---|---|---|---|
| Full-rate | single-cycle | 31.25 ns | decimator CIC integrators, `sd_remod`, `psram_buf_ctrl` |
| Paced TDM | RTL hold counters + scoped MCP=3 | 93.75 ns | HB MACs (`sd_decimator_poly`), `sc_detector` TDM + serial eval, `training_acc` walk, `mrc_combiner` states 1–10 |
| CE-gated | `ce_16m` clock-enable + scoped MCP=2 | 62.5 ns | `reg_bank`, `spi_slave`, `packet_ctrl_fsm` |

The former CLK_16M generated-clock scheme (registered divide-by-2 net) and the former single-cycle SC-detector TDM limitation are both superseded: the control plane is clock-enable-gated (see `planning/ce-gated-quasi-static-retimer-experiment.md`) and every TDM/MAC cone is paced in RTL so its multicycle constraint is honest. The residual SS/3.0 V gap is a library limitation tracked under TRPR-PHY-008.

---


### 3.x Current Hardened-Macro Boundary

The active `trouper_top` hard macro contains the full Trouper signal chain and control-plane peripherals:

- **Included:** DSP chain (decimators, SC detector, training_acc, mrc_combiner, sd_remod), PSRAM buffer controller, packet_ctrl_fsm, reg_bank, SPI slave (host RPi interface), sticky interrupt aggregation (irq_status in reg_bank)
- **Not included:** PicoRV32 / Grouper CPU — weight computation is performed by Grouper firmware via the inter-project `GRP_*` register bus
- Control boundary: SPI pads (`HOST_CS`, `SPI_SCK`, `SPI_MOSI`, `SPI_MISO`) for host access; `GRP_ADDR/WDATA/WE/RE/RDATA/READY` inter-chip bus for Grouper access (priority over SPI)
- Two interrupt outputs: `IRQ_OUT` → dedicated package pad; `IRQ_GROUPER` → inter-project line to Grouper. Both are driven by the same sticky `irq_status` OR from reg_bank.
- `mimo_rx_top` remains only as a legacy compatibility wrapper for older flows and is not the canonical hardened macro

Recent area-reduction work removed two stale hardware paths from the active RTL:

- the legacy `W_k` / `Z_i*` / `Z_q*` training-accumulator outputs, because the current firmware-driven combiner path does not consume them
- the standalone `noise_est` block, replacing it with firmware-triggered `training_acc` noise-mode windows and `Zdiag`-based validity gating

Open verification note: the new noise-window accept/reject path uses `training_done` plus SC-contamination tracking (`sc_hit_dbg` / `sc_lock`) and still requires directed verification of edge timing around window end.

## 4. Block Requirements

---

### 4.1 ΣΔ Decimator (`sd_decimator_poly.v`) — TRPR-DEC

The active RTL uses one shared time-division-multiplexed decimator datapath across the four RX branches. It accepts four 1-bit ΣΔ I/Q branch inputs at 32 MS/s and emits per-branch signed int8 complex baseband samples on the decimated schedule.

| ID | Pri | Type | Requirement | Verif |
|---|---|---|---|---|
| TRPR-DEC-001 | C | F | Each decimator instance SHALL accept a 1-bit I and a 1-bit Q input at 32 MS/s and produce a signed 8-bit I and 8-bit Q output. | T |
| TRPR-DEC-002 | C | F | The decimator SHALL implement the fixed R=64 half-band chain (CIC-3 R=16 → HB1 ÷2 → HB2 ÷2), giving 500 kS/s for both BWs. | T |
| TRPR-DEC-003 | C | P | SQNR at the decimator output SHALL be ≥ 30 dB (measured at R=64 with a −3 dBFS tone input). | T |
| TRPR-DEC-004 | C | F | For identical per-branch 1-bit input streams, the shared TDM decimator path SHALL produce bit-identical per-branch outputs. | T |
| TRPR-DEC-005 | H | F | The CIC stages SHALL use wrap-around (modulo 2^14) arithmetic at the overflow-safe width — 14 bits = 3·log2(16) + 1-bit input + sign for the 3rd-order R=16 stage — so integrator wrap is cancelled exactly by comb differencing. Saturating arithmetic SHALL NOT be inserted; it would break the modulo cancellation. | A |
| TRPR-DEC-006 | H | F | The decimator SHALL produce a valid-strobe output (`iq_valid`) every 64 input clocks (R=64) to gate downstream DSP. | T |
| TRPR-DEC-007 | H | P | Stopband attenuation SHALL exceed 40 dB for tones above 500 kHz (half the 1 MS/s intermediate rate). | A |
| TRPR-DEC-008 | M | I | `BW_CFG.bw_sel` selects BW only (sets `sample_shift`); the decimator ratio is fixed at R=64. | I |
| TRPR-DEC-009 | L | P | The half-band chain SHALL hold passband droop ≤ 0.5 dB without a separate CIC droop equalizer (inherent ≈ −0.17 dB). | A |

---

### 4.2 DC Removal (`dc_removal.v`) — TRPR-DCR

Processes all four branches in a single module. Eliminates SX1257 direct-conversion mixer DC bias before the SC detector and training accumulator. Unremoved DC causes three downstream failures: (1) it biases the SC autocorrelation metric, increasing false-lock risk; (2) it adds a spurious real offset to every Z_kl cross-correlation entry, corrupting channel estimation; (3) it inflates ZDIAG_k = Σ|rx_k|², corrupting the noise EMA and any AGC loop driven by it.

#### Algorithm

```
Per branch k, per sample n (updates on raw_valid only):
  diff_k[n]  = raw_k[n] - acc_k[n-1][12:5]       // raw − dc_est_prev
  acc_k[n]   = acc_k[n-1] + sign_extend(diff_k[n], 13)  // full error added (no shift)
  dc_est_k   = acc_k[n][12:5]                     // top 8 bits of 13-bit Q8.5 acc
  out_k[n]   = raw_k[n] - acc_k[n-1][12:5]        // subtract pre-update estimate (1-cycle lag)
```

The accumulator is 13-bit Q8.5 signed (α = 1/32). The integer DC estimate is `acc[12:5]`; `acc[4:0]` holds sub-LSB precision. Adding the full diff (not `diff>>5`) eliminates the positive-DC convergence deadband. τ = 32 samples = 64 µs at 500 kS/s.

#### Requirements

| ID | Pri | Type | Requirement | Verif |
|---|---|---|---|---|
| TRPR-DCR-001 | C | F | The module SHALL process all four I+Q branches in parallel on the 32 MHz clock (port `clk_32m`), updating accumulators only when `raw_valid` is asserted. | I |
| TRPR-DCR-002 | C | F | Each branch accumulator SHALL be 13-bit signed Q8.5. The integer DC estimate is `acc[12:5]`; the output is `raw - acc_prev[12:5]` (pre-update estimate, one `raw_valid` cycle lag). | I |
| TRPR-DCR-003 | C | F | The accumulator update SHALL add the full signed difference `(raw − dc_est_prev)` — not a right-shifted version — to eliminate the convergence deadband on small positive DC values. | I |
| TRPR-DCR-004 | C | F | Input and output word widths SHALL both be int8 signed (8 bits). | I |
| TRPR-DCR-005 | C | P | Effective time constant SHALL be τ = 32 samples (α = 1/32) = **64 µs** at 500 kS/s; 90% settling within ~74 samples. | A |
| TRPR-DCR-006 | C | P | Steady-state output DC SHALL be < 1 LSB (int8) after 256 samples of constant input. | T |
| TRPR-DCR-007 | H | F | Output saturation is not currently implemented. `raw − dc_est` is bounded within int8 in steady state, but during a full-scale step transient (signal peak + \|DC\| > 127, a cliff at \|DC\| ≈ 38 counts under the TRPR-MRC-009 AGC contract) the 9-bit difference wraps to a sign-flipped output. Whether a clamp is required is gated on the AFE PCB DC-vs-LNA-gain measurement (change R2, `planning/dsp-block-review-changes-2026-07.md`; measurement in `planning/AFE Characterisation Board.md`). | A |
| TRPR-DCR-008 | H | F | Maximum accumulator value at full-scale input (+127 raw, sustained) SHALL be 127 × 32 = 4064, which fits within the 13-bit signed range (±4095). No accumulator overflow is possible for int8 inputs. | A |
| TRPR-DCR-009 | H | F | All four branches (I and Q independently) SHALL use the same fixed α = 1/32 coefficient with no runtime configurability. | I |
| TRPR-DCR-010 | H | P | AC passband droop SHALL be < 0.1 dB across the LoRa signal band (filter corner ≈ 2.5 kHz for α=1/32 at 500 kS/s). | A |
| TRPR-DCR-011 | H | F | `out_valid` SHALL be `raw_valid` delayed by exactly one clock cycle. All downstream blocks SHALL be timed from `out_valid`, not `raw_valid`. | I |
| TRPR-DCR-012 | H | F | On RESETB assertion, all 8 accumulators (4 branches × I/Q) and all output registers SHALL clear to zero. | T |
| TRPR-DCR-013 | M | P | After RESETB de-assertion with a non-zero DC input already present, the output SHALL settle to < 1 LSB DC within ~74 samples (one 90% time constant). | T |
| TRPR-DCR-014 | L | F | A bypass mode port is not present in the current RTL. If diagnostic bypass is needed it SHALL be implemented by asserting RESETB then observing raw outputs upstream, not via a module-level bypass register. | I |
| TRPR-DCR-015 | C | F | The SC detector SHALL be held off from asserting `sc_lock` for at least 64 samples after RESETB de-assertion (4 × τ; residual DC < 0.1 LSB). Provided structurally by the PSRAM delay-line warm-up: SC evaluations cannot begin until `del_rdy` (M ≥ 128 samples ≥ the required 64), verified by `cocotb/tests/test_startup.py`. | T |

---

### 4.3 Schmidl-Cox Detector (`sc_detector.v`) — TRPR-SCD

Generates `sc_lock` and `timing_ref` using a full-symbol Schmidl-Cox detector on branch 0 only. With the active PSRAM delay path, the detector sees a true `M = 1 << (SF + sample_shift)` sample delay for all supported spreading factors and accumulates over the full symbol period on each hit decision. The detector remains single-branch: four-branch diversity gain begins only after lock in the downstream training accumulator and combiner path.

| ID | Pri | Type | Requirement | Verif |
|---|---|---|---|---|
| TRPR-SCD-001 | C | F | The detector SHALL compute a per-symbol complex autocorrelation `C[s] = Σ_{n=0}^{M-1} x_0[n] · conj(x_0[n−M])` on antenna branch 0, where `M = 1 << (SF + sample_shift)` for all supported `SF7–SF12` and both BWs. | I |
| TRPR-SCD-002 | C | F | The detector SHALL form the Schmidl-Cox hit test without an explicit divider: `|C[s]|² >= THR_eff · E[s]`, where `E[s] = (Σ_{n in S_s} |x_0[n]|²) · (Σ_{n in S_s} |x_0[n−M]|²)`. | T |
| TRPR-SCD-003 | C | F | The detector SHALL evaluate one hit decision per completed symbol using the full `M` delayed samples supplied by the PSRAM path. | I |
| TRPR-SCD-004 | C | F | `sc_lock` SHALL assert after `SC_HITS_REQ+1` consecutive symbol-hit decisions. | T |
| TRPR-SCD-005 | C | F | `timing_ref` SHALL back-calculate the first symbol boundary of the qualifying hit run as `lock_sample - (SC_HITS_REQ+1)·M + 1`. | T |
| TRPR-SCD-006 | C | F | The current RTL SHALL operate on antenna branch 0 only. Four-branch diversity gain begins after lock in the training accumulator and combiner path; the SC detector itself is not pooled across branches. | I |
| TRPR-SCD-007 | H | I | `SC_THR` SHALL remain writable through `SC_THR_HI` (0x0C) and `SC_THR_LO` (0x0D), but the current RTL consumes only `SC_THR[11:0]`. Firmware SHALL program the effective threshold in the low 12 bits (`0x0000`–`0x0FFF`). The reset default SHALL be `0x01CC`, the scaled 12-bit-safe equivalent of the legacy `0x7333` threshold (`0x7333 / 64`, rounded down). Note the RTL hit comparison additionally halves the \|C\|² side (`eval_mag_acc[27:1]`); this fixed ÷2 is part of the effective threshold scale and must be carried in any re-derivation of `SC_THR` from first principles. | I |
| TRPR-SCD-008 | H | I | `SC_HITS_REQ` SHALL be configurable via register 0x0E. The hardware locks after `SC_HITS_REQ+1` consecutive symbol hits: firmware-supported normal-operation values 1–3 therefore require 2–4 hits. Raw value 0 is an unclamped **diagnostic-only one-hit mode**; firmware SHALL use it only for controlled bring-up/characterisation and restore a value of 1–3 before normal reception because its false-lock immunity is substantially reduced. | T |
| TRPR-SCD-009 | H | F | `SC_STAT_HI/LO` (0x24–0x25) SHALL expose the detector's current `|C[s]|²` telemetry snapshot (`sym_mag_sc[27:13]` with a zero-padded LSB). It is not a normalised `Λ²` register in the current RTL. | I |
| TRPR-SCD-010 | H | I | The detector SHALL expose debug registers `SC_DBG_FLAGS` (0x26), `SC_FIRST_HIT` (0x28–0x2B), and `SC_LOCK_SNAP` (0x2C–0x2F) for bring-up visibility. | T |
| TRPR-SCD-011 | — | — | **REMOVED.** The former `CORR_MAG_n` allocation at `0x48–0x4F` was superseded by live training-accumulator `Z_02`/`Z_03` readback (TRPR-TAC-004). No SC autocorrelation-magnitude register is implemented in the current revision. | — |
| TRPR-SCD-012 | — | — | **REMOVED.** The former `C_POOL_I/Q` allocation at `0x64–0x67` was superseded by live `ZDIAG_0`/`ZDIAG_1` readback (TRPR-TAC-005). No pooled SC phasor/CFO readback register is implemented in the current revision. | — |
| TRPR-SCD-013 | H | P | `sc_lock` SHALL assert within ±1 symbol of the Python block-model prediction on a clean branch-0 SF7 125 kHz preamble at 0 dB SNR. | T |
| TRPR-SCD-014 | C | F | `sc_lock` SHALL de-assert and the detector SHALL re-arm (hit counter, symbol accumulators, and metric-engine state cleared) when the Packet Control FSM returns to IDLE, so every subsequent packet is acquired. | T |
| TRPR-SCD-015 | L | F | `ENERGY_GATE_EN` (SC_CFG bit 0) is reserved; energy gating prior to SC lock is not implemented in the current RTL and SHALL be left at 0. | I |
| TRPR-SCD-016 | H | F | The hit decision SHALL include an e_slice guard: `eval_e_acc[25:13] > 0` (energy² ≥ 8192 ADU). When this condition is false the energy is too low for a meaningful threshold comparison; the hit is suppressed to prevent false alarms on noise. This guard is SF-adaptive because minimum detectable amplitude `A_min ∝ 1/√M`. | I |

---

### 4.4 Frontend Buffer Controller — TRPR-FBC (RELOCATED)

The standalone `frontend_buf_ctrl.v` block and its on-chip SRAM delay line are deleted; the decimator output fans out directly to the SC detector and the PSRAM controller inside `trouper_top`. Requirements TRPR-FBC-001…005 are retained under their original IDs in **§4.10.2 (SC Correlator Delay RAM)**, which the PSRAM Buffer Controller serves.

---

### 4.5 Training Accumulator (`training_acc.v`) — TRPR-TAC

Computes all-pairs cross-correlations Z_kl and diagonal autocorrelations Z_kk over the training window.

> **Zdiag headroom note:** the 32-bit Z_kk accumulator reaches exactly 2^32 (1-count overflow) only at the pathological corner — SF12/125 kHz, 8-symbol window (n_acc = 131072), both I and Q railed at −128 for the whole window. Under the TRPR-MRC-009 AGC contract (≤ 90 counts) worst case is ≈ 2.1e9, ≥ 2× margin. Accepted; documented rather than widened.

| ID | Pri | Type | Requirement | Verif |
|---|---|---|---|---|
| TRPR-TAC-001 | C | F | The accumulator SHALL compute all C(4,2) = 6 off-diagonal complex cross-correlations Z_kl = Σ raw_k[n] · conj(raw_l[n]) and all 4 diagonal autocorrelations Z_kk = Σ \|raw_k[n]\|² over the training window. | T |
| TRPR-TAC-002 | C | F | The training accumulator endpoint SHALL be controlled by `TACC_WINDOW_SYMS` (0x27), spanning from `sc_lock` until `timing_ref + TACC_WINDOW_SYMS × M - 1` in live mode. Reset SHALL be 8 symbols; writes below 8 SHALL clamp to 8 — enforced both at the register (`reg_bank` 0x27) and by a matching module-level clamp in `training_acc` (a sub-latency window would put `acc_end` before the lock instant and deadlock `training_done`; verified `cocotb/tacc_window_clamp/`). | T |
| TRPR-TAC-003 | C | F | `training_done` SHALL assert at the end of the training window. The accumulated sample count n_acc SHALL be latched as a full 18-bit unsigned count and readable from `N_ACC` (0x21–0x23). | T |
| TRPR-TAC-004 | C | I | All 6 off-diagonal Z_kl pairs SHALL be readable from the register bank as the top 24 bits [31:8] of the signed int32 accumulators, big-endian, 3 bytes per component (I then Q): Z_01 (0x40–0x45), Z_02 (0x46–0x4B), Z_03 (0x4C–0x51), Z_12 (0x52–0x57), Z_13 (0x58–0x5D), Z_23 (0x5E–0x63). | T |
| TRPR-TAC-005 | C | I | The diagonal Z_kk top 24 bits [31:8] SHALL be readable from `ZDIAG_k` (0x64–0x6F), three bytes per branch. | T |
| TRPR-TAC-006 | — | — | **REMOVED.** `Z_SHIFT` is not implemented as a hardware register in the current revision (hardwired 0 in `trouper_top`; see `planning/Register Map.md` "Former addresses"). No common register-side right-shift is applied to Z_kl readback; see TRPR-WGN-009 for the firmware-side equivalent. | — |
| TRPR-TAC-007 | H | F | A firmware-triggered noise measurement mode SHALL be supported: writing bit 0 to `TACC_NOISE_TRIG` (0x1F) SHALL arm the accumulator for `TACC_WINDOW_SYMS × M` samples without waiting for `sc_lock`. Off-diagonal Z_kl ≈ 0; diagonal ZDIAG_k ≈ σ²_k · n_acc. `training_done` SHALL fire on completion. | T |
| TRPR-TAC-008 | H | I | `TRAINING_STATUS` (0x20) SHALL expose `TRAINING_DONE` and `TRAINING_ARMED` bits. | T |
| TRPR-TAC-009 | H | P | Z_kl / n_acc SHALL match the Python reference `h_k · conj(h_l)` within Q1.15 rounding on a noiseless channel. | T |
| TRPR-TAC-010 | M | F | On each `sc_lock` event, the accumulator SHALL automatically reset internal state before beginning a new training window. | T |
| TRPR-TAC-011 | — | — | **REMOVED.** `TACC_REF_SEL` is not implemented as a hardware register in the current revision (address range superseded by `TACC_NOISE_TRIG`; see `planning/Register Map.md` "Former addresses"). The legacy single-reference path no longer exists. | — |

---

### 4.5A Static Frontend Calibration (`cal_j`) — TRPR-CAL

Static frontend calibration compensates fixed branch-to-branch complex mismatch before firmware weight generation. The calibration term is a per-branch complex coefficient `cal_j` applied as:

```
H_j_cal = H_j · conj(cal_j)
```

where `H_j` is the branch channel estimate derived from the Training Accumulator. The current revision uses `cal_j` only for static branch gain and carrier-phase equalisation; it is not a true I/Q imbalance canceller. Calibration procedure and bench method are defined in `planning/Frontend Calibration Procedure.md`.

| ID | Pri | Type | Requirement | Verif |
|---|---|---|---|---|
| TRPR-CAL-001 | C | F | The system SHALL support one static complex calibration coefficient `cal_j` per enabled RX branch. `cal_j` SHALL be applied before firmware weight generation so that the effective estimate used for MRC/eigenvector weighting is `H_j_cal = H_j · conj(cal_j)`. | T |
| TRPR-CAL-002 | C | I | `cal_j` SHALL use signed complex Q1.15 format per branch and SHALL be held in Grouper firmware memory or an equivalent host-managed software image. Trouper SHALL NOT require a dedicated hardware `CAL_*` register bank in this revision. | I |
| TRPR-CAL-003 | H | F | Calibration SHALL be performed offline or during bring-up using a coherent common-input fixture so that fixed branch gain/phase mismatch can be separated from packet-to-packet channel variation. Accepted methods are defined in `planning/Frontend Calibration Procedure.md`. | I |
| TRPR-CAL-004 | H | P | Under the calibration fixture, after applying `cal_j`, the residual inter-branch phase spread SHALL be less than `5 deg` and the residual inter-branch amplitude spread SHALL be less than `0.5 dB`. | T |
| TRPR-CAL-005 | H | F | The loaded `cal_j` set SHALL remain the active default for normal operation until explicitly replaced by firmware or host software. Reset default may be `cal_j = 1 + 0j` for all branches until a measured calibration set is loaded. | T |
| TRPR-CAL-006 | H | F | `cal_j` SHALL be treated as a scalar branch equalisation term only. It SHALL NOT be specified or verified as a complete correction for true per-branch I/Q imbalance. Residual I/Q imbalance SHALL be handled as a separately characterised frontend impairment (see TRPR-WGN-010 and TRPR-WGN-011). | A |


---

### 4.6 Firmware Weight Generation (Grouper SW / Host-Assisted, no Trouper RTL) — TRPR-WGN

Weight generation is performed entirely in software. There is no `weight_gen.v` block instantiated in Trouper; the HW weight generation FSM was removed due to area constraints. Trouper exposes the raw correlation accumulators (Z_kl, Z_kk) via the register bank; Grouper firmware is the primary consumer, with host-assisted SPI writes retained as an optional fallback path.

#### Weight Computation Flow

```
training_done IRQ fires
  → controlling software (host SPI or Grouper bus) reads Z_kl (0x40–0x63) and full 18-bit N_ACC (0x21–0x23)
  → software computes W_k = Z_k* / ||Z|| (MRC normalisation)
     or principal eigenvector via 8-step power iteration (sim/models/eigvec_fw.py)
  → software writes W shadow regs (0x30–0x3F): 4 complex pairs in 16-bit fields
     (combiner consumes the high byte of each = int8 Q0.7)
  → software pulses WGT_CTRL.W_COMMIT (0x1E[0])
  → Trouper PCF FSM asserts W_VALID; the combiner consumes the live W register bank
    from its next sample latch, and the bank is write-locked while W_VALID is high
```

#### Requirements

| ID | Pri | Type | Requirement | Verif |
|---|---|---|---|---|
| TRPR-WGN-001 | C | F | Weight generation SHALL be performed exclusively by software running on Grouper or an equivalent host-assisted control path. No HW weight_gen block SHALL be instantiated in Trouper RTL. | I |
| TRPR-WGN-002 | C | I | Trouper SHALL expose all 6 off-diagonal Z_kl pairs and 4 diagonal Z_kk values in the register bank (see TRPR-TAC-004, TRPR-TAC-005) for firmware to read after `training_done`. | T |
| TRPR-WGN-003 | C | I | Firmware SHALL write the computed weight vector to the Trouper shadow weight bank (0x30–0x3F: 4 complex pairs in 16-bit big-endian fields; only the high byte of each — int8 Q0.7 — is consumed by the combiner) and then pulse `WGT_CTRL.W_COMMIT` (0x1E[0]) within the W_PENDING window. | T |
| TRPR-WGN-004 | C | P | **Firmware timing deadline — same-packet PSRAM replay mode (primary):** `W_COMMIT` must arrive before `packet_end`. Available window from `training_done` to `packet_end` = **(4.25 + n_payload_syms) × T_symbol** (training window consumes 8 of the 12.25 preamble symbols; residual 4.25 preamble symbols plus full payload remain). Worst case is minimum-payload: 4.25 × T_symbol. **`SF_CFG`'s valid range is 7–12 (TRPR-SYS / Register Map `0x09`) — SF6 is out of scope and dropped from this analysis; SF7 is the tightest supported case.** The per-SF margin figures previously listed here (assuming a ~335 µs eigenvector-path compute cost) are **superseded**: a corrected estimate accounting for PicoRV32's actual non-`FAST_MUL` multiplier (~31 cycles/MUL, not ~1) puts 8-iteration eigenvector compute at ~1.0–1.1 ms, making **SF7 only roughly break-even**, not comfortably margined — see `planning/blocks/Eigenvector Weight Computation.md` (Timing Budget) and `planning/Open Risks.md` #7 for the current numbers; this row's specific multiplier figures need re-deriving against that corrected cost model. Risk: AHB inter-project stall cycles at low SF can further erode the margin — firmware SHALL prioritise `training_done` over all other IRQ sources. The "one symbol period" constraint was for the removed next-packet path and is superseded. | A |
| TRPR-WGN-005 | H | F | The primary firmware weight mode SHALL be MRC: `W_k = conj(Z_0k) / Σ |Z_0k|`, normalised to int8 Q0.7 in the high byte of each shadow field (the precision the combiner consumes — TRPR-MRC-006). | T |
| TRPR-WGN-006 | H | F | A secondary firmware weight mode SHALL be **principal eigenvector via power iteration**: firmware finds the dominant eigenvector of the 4×4 Hermitian Z matrix using 8 fixed-point iterations on RV32IM, then conjugates and normalises to the shadow-field format (effective precision int8 Q0.7 in the high byte — TRPR-MRC-006). Algorithm: (1) normalise all Z entries to int12 via a common right-shift to prevent int32 overflow; (2) iteratively compute w = Z·v (exploiting Hermitian symmetry, 4 complex dot products per row), renormalise v by the max-magnitude power-of-2 shift; (3) after 8 iterations, output W_k = conj(v_k) × 32767 / v_max. Diagonal Z_kk is read from `ZDIAG_k` (0x64–0x6F) as bits [31:8] of the 32-bit accumulator; off-diagonal Z_kl are read as bits [31:8] (both already at the same scale — no left-shift needed once ZDIAG is read at its current 24-bit width). Reference model: `sim/models/eigvec_fw.py`. Detailed algorithm: `planning/blocks/Eigenvector Weight Computation.md`. | T |
| TRPR-WGN-007 | H | F | The firmware weight mode (MRC row-sum per TRPR-WGN-005, eigenvector power iteration per TRPR-WGN-006, or noise-weighted MRC per TRPR-WGN-012) SHALL be selectable at runtime within Grouper/host firmware without requiring a chip reset. Mode selection is a firmware-internal decision: Trouper exposes **no `WEIGHT_MODE` hardware register**, since it consumes only the committed W bank (0x30–0x3F) and is agnostic to how `W` was computed. | I |
| TRPR-WGN-008 | H | P | If `W_COMMIT` is not received before the payload boundary, the PCF FSM SHALL remain in bypass mode for that packet (see TRPR-PCF-005). Firmware SHALL maintain a missed-packet counter in its own memory (`DBG_MISSED_PKTS` is a firmware variable, not a Trouper register — same software-owned pattern as the TRPR-AGC-002 thresholds), incremented on each `W_MISSED_PACKET` IRQ or sticky `WGT_CTRL[3]`/`PACKET_STATUS[7]` readback. | T |
| TRPR-WGN-009 | — | — | **REMOVED.** There is no hardware `Z_SHIFT` register in the current revision (see TRPR-TAC-006); Z_kl/Zdiag readback already presents the top 24/24 bits directly, so firmware applies no register-driven undo-shift. Any fixed-point normalisation firmware needs is internal to the weight-computation algorithm (TRPR-WGN-006), not a hardware compensation step. | — |
| TRPR-WGN-010 | H | F | Static frontend calibration via `cal_j` SHALL be treated as a complex scalar correction for per-branch gain and phase mismatch only. It SHALL NOT be assumed to correct true per-branch I/Q imbalance, which introduces an image term proportional to `conj(x)` rather than a pure complex scale. | A |
| TRPR-WGN-011 | H | P | The current Trouper combiner architecture SHALL be treated as a linear combiner `sum w_k x_k`. Any performance loss caused by branch-dependent I/Q imbalance beyond what can be absorbed into `cal_j` or the estimated weight vector SHALL be documented as a residual frontend impairment. A widely-linear compensator is out of scope for this revision. | A |
| TRPR-WGN-012 | H | F | Firmware MAY use **noise-weighted MRC (NW-MRC)** when per-branch noise estimates are available: scale each conventional MRC weight by the inverse noise variance, `w_k ∝ w_MRC,k / σ²_ema[k]`, then normalise to int8 Q0.7. For the supported NT=1, diagonal-noise model this is the diagonal-noise special case of a linear MMSE combiner; it does **not** introduce a full ALMMSE or multi-user detector. `σ²_ema` is supplied by TRPR-AGC-005. | T |

---

### 4.7 Packet Control FSM (`packet_ctrl_fsm.v`) — TRPR-PCF

Master datapath controller. Sequences buf_freeze, weight gating, and mode latching.

| ID | Pri | Type | Requirement | Verif |
|---|---|---|---|---|
| TRPR-PCF-001 | C | F | The FSM SHALL implement four states: IDLE → PREAMBLE_ACQ → W_PENDING → PAYLOAD_ACTIVE, with transition back to IDLE on packet end or timeout. | T |
| TRPR-PCF-002 | C | F | On `sc_lock`: the FSM SHALL assert `buf_freeze` and transition to PREAMBLE_ACQ. | T |
| TRPR-PCF-003 | C | F | On `training_done`: the FSM SHALL transition to W_PENDING and assert `TRAINING_DONE` IRQ. | T |
| TRPR-PCF-004 | C | F | On receipt of `W_COMMIT` from the weight path: the FSM SHALL assert `W_VALID` and transition to PAYLOAD_ACTIVE. There is no separate `W_ACTIVE` bank in the current RTL: the combiner reads the live W register bank, which is write-locked while `W_VALID` is high (TRPR-MRC-004). | T |
| TRPR-PCF-005 | C | F | If `W_COMMIT` is not received before the payload boundary, the FSM SHALL remain in bypass mode for the current packet, set `W_MISSED_PACKET`, and assert the corresponding IRQ. | T |
| TRPR-PCF-006 | C | F | `ACTIVE_MODE` and `ACTIVE_ANTENNA_EN` (both packed into `ACTIVE_STATUS`, 0x1D: `[1:0]`/`[7:4]`) SHALL be latched from `MIMO_CTRL` only at the safe-switch boundary (FSM in IDLE), never during an active packet. | T |
| TRPR-PCF-007 | C | F | A packet timeout SHALL be enforced: if the FSM does not reach IDLE within `PKT_TIMEOUT_SYMS` (0x0B) LoRa symbols, it SHALL force a return to IDLE and assert `PACKET_DONE` IRQ. | T |
| TRPR-PCF-008 | H | F | On IDLE entry, `buf_freeze` SHALL de-assert and the frontend buffer SHALL resume rolling capture. | T |
| TRPR-PCF-009 | H | I | `PACKET_STATUS` (0x1C) SHALL expose `PACKET_ACTIVE`, `PACKET_PHASE[2:0]`, `TRAINING_DONE`, `W_PENDING`, `W_VALID`, and `W_MISSED_PACKET`. | T |
| TRPR-PCF-010 | H | F | When firmware is held in reset or no W_COMMIT is received, the FSM SHALL pass through W_PENDING → timeout → IDLE without deadlock. | T |
| TRPR-PCF-011 | M | F | Mode 1 (passthrough, `MIMO_CTRL.MODE=1`): the FSM SHALL route the lowest-numbered enabled antenna directly to the re-modulator output, bypassing training accumulation and weight computation. | T |

---

### 4.8 MRC Combiner (`mrc_combiner.v`) — TRPR-MRC

Computes ŷ[n] = w^H · x[n] per sample in the time domain.

| ID | Pri | Type | Requirement | Verif |
|---|---|---|---|---|
| TRPR-MRC-001 | C | F | The combiner SHALL compute ŷ[n] = Σ_{k=0}^{3} w_k · x_k[n] where x_k is int8 and w_k is int8 Q0.7 complex. The conjugation required for MRC is applied by firmware, which writes W pre-conjugated (TRPR-WGN-005) — the combiner itself performs a plain complex multiply-accumulate. | T |
| TRPR-MRC-002 | C | F | The accumulator SHALL be 18-bit signed (16-bit product sign-extended + 2 guard bits for 4 additions). The final output SHALL be produced by a single combined arithmetic right-shift of `(8 − pgs)` bits applied to the accumulator, then saturated to int8. `pgs` is `COMB_POST_GAIN_SHIFT` (0–7); combined shift ∈ [1,8], always a right shift. | T |
| TRPR-MRC-003 | C | F | The combiner SHALL operate sample-by-sample at 500 kS/s (one output per `iq_valid` strobe). | T |
| TRPR-MRC-004 | C | F | The combiner SHALL consume the live W register bank at `0x30–0x3F`; no separate `W_ACTIVE` copy is implemented. Firmware SHALL write the complete vector, then pulse `WGT_CTRL.W_COMMIT` to assert `W_VALID`. While `W_VALID` is high, writes to `0x30–0x3F` SHALL be rejected and set sticky `WGT_CTRL.W_WR_REJECTED` (bit 5), preventing a partially updated live vector. | T |
| TRPR-MRC-005 | C | F | Before any W_COMMIT, the combiner SHALL output the bypass signal (lowest-enabled antenna int8 sample, no weighting). | T |
| TRPR-MRC-006 | H | I | Weights SHALL be stored as 4 complex pairs (w_RE, w_IM) in 16-bit big-endian shadow fields at registers 0x30–0x3F; the combiner consumes the high byte of each field as int8 Q0.7 (the low bytes are ignored — see Register Map.md). | I |
| TRPR-MRC-007 | H | F | `COMB_POST_GAIN_SHIFT` (pgs, `COMB_CFG` 0x0F[2:0], reset 0, range 0–7) adjusts output amplitude by varying the combined shift: effective division = 2^(8−pgs). Firmware SHALL set pgs per-packet from ZDIAG to target ≈ 90 combined output counts. Worst-case quantisation loss with combined shift: < 0.2 dB (pgs=0); boundary cases at pgs=3/4 show 0.000 dB loss (verified tb_mrc_fw_rand, SGE job 2010). | T |
| TRPR-MRC-008 | H | P | Post-combining SNR improvement SHALL be ≥ 5 dB relative to single-antenna baseline on a flat channel with equal-power branches (theoretical MRC gain ≈ 6 dB for NR=4). | T |
| TRPR-MRC-009 | H | P | AGC SHALL keep per-branch amplitude ≤ −3 dBFS (≤ 90 counts int8) so the combined int32 sum fits within int8 after ÷2. Int8 saturation is a safety net only, not the normal operating path. | T |
| TRPR-MRC-010 | H | P | `ŷ[n]` SHALL match `W @ x` computed in numpy to within ±2 LSB (int8). | T |
| TRPR-MRC-011 | M | I | `WGT_CTRL` (0x1E) SHALL expose: `W_COMMIT` (W1P), `W_VALID` (RO), `W_PENDING` (RO), `W_MISSED_PACKET` (RO), `W_COMMIT_LATE` (RO), and sticky `W_WR_REJECTED` (RO/W1C). | I |

---

### 4.9 ΣΔ Re-modulator (`sd_remod.v`) — TRPR-RMD

Third-order ΣΔ modulator. Converts int8 combined output back to 1-bit I+Q streams for SX1302.

| ID | Pri | Type | Requirement | Verif |
|---|---|---|---|---|
| TRPR-RMD-001 | C | F | The re-modulator SHALL implement a 3rd-order ΣΔ modulator, converting int8 I and int8 Q inputs to 1-bit I and 1-bit Q outputs. | T |
| TRPR-RMD-002 | C | F | The re-modulator SHALL operate at 32 MS/s output rate with OSR=64 (int8 at 500 kS/s → 1-bit at 32 MS/s). | T |
| TRPR-RMD-003 | C | F | All integrators SHALL use saturating arithmetic. Wrap-around addition is prohibited; a wrapped integrator will cause permanent instability. | T |
| TRPR-RMD-004 | C | P | Input amplitude SHALL be constrained to strictly < −3 dBFS (< 90 counts int8) by AGC (TRPR-MRC-009) plus `REMOD_BACKOFF_SHIFT`. No on-chip over-range flag exists and none is feasible: integrator states sit near-rail even in healthy operation, so they are not a valid instability signal (see `cocotb`/`test_remod_backoff.py`). | T |
| TRPR-RMD-005 | H | P | In-band SQNR SHALL exceed 40 dB at −6 dBFS input (measured by Python decimation of the 1-bit output stream). | T |
| TRPR-RMD-006 | H | F | The re-modulator output SHALL be stable (no integrator divergence) for any int8 input within [−90, +90]. | T |
| TRPR-RMD-007 | H | P | Re-demodulated output (Python decimation of 1-bit stream) SHALL match int8 input to within ±1 LSB RMS at −6 dBFS. | T |
| TRPR-RMD-008 | M | F | When Mode 1 (passthrough) is active, the re-modulator SHALL receive the single-antenna int8 stream directly. | T |
| TRPR-RMD-009 | C | F | Except at first-ever lock after `RESETB`, the re-modulator's input SHALL NOT jump backward in signal time-index during normal operation (silence→signal and mid-stream weight changes are fine; replaying already-sent time-index is not). Met 2026-07-12 by the continuous-delay replay (`planning/psram-replay-continuous-delay-redesign.md`, implemented; monotonic-`rd_ptr` check in `cocotb/tests/test_replay_delay.py`). | T |
| TRPR-RMD-010 | M | F | While `en=0` the re-modulator SHALL hold its integrators and 1-bit outputs at their reset state, so re-enabling is bit-identical to starting from a fresh reset (verified `cocotb/remod_en/`). `trouper_top` ties `en` high; the port serves other integrations. | T |

---

### 4.10 PSRAM Buffer Controller (`psram_buf_ctrl.v`) — TRPR-PSR

One shared QPI engine serving the external APS6404L provides three user-facing functions, specified separately below: **SC correlator delay RAM** (§4.10.2), **same-packet capture & continuous-delay replay** (§4.10.3 — mandatory, see TRPR-SYS-017), and **host debug readback** (§4.10.4). §4.10.1 specifies the shared QPI core they arbitrate over. Implementation detail: `planning/blocks/PSRAM Buffer Controller.md`; replay redesign record: `planning/psram-replay-continuous-delay-redesign.md`.

#### Same-Packet MRC Replay Sequence (continuous-delay)

```
Power-on: firmware sets PSRAM_EN (≥150 µs after board power, TRPR-SYS-018) → QPI init; INIT_DONE
Idle: circular capture of every decimated sample (overwrites oldest); SC delay reads interleaved
sc_lock: packet start pointer (buf_base) latched; capture continues; SC delay reads cease
training_done: margin timer armed — REPLAY_DELAY_SAMPLES (0x77/0x78) captured samples
margin expiry: REPLAY_ACTIVE asserts; read pointer starts at buf_base and advances in lockstep
        with capture writes — a fixed-depth delay line that never rewinds
W_COMMIT (before packet end): gates only W_VALID in the combiner — replayed stream is weighted
        from the commit onward; a commit after replay start also sets sticky W_COMMIT_LATE
        (WGT_CTRL 0x1E[4]); no commit → replay runs in combiner bypass
Packet end: REPLAY_ACTIVE de-asserts; circular capture resumes; a commit after packet end is
        inert and latches sticky REPLAY_MISSED
```

#### 4.10.1 QPI Core, Init & Pad Ownership (shared substrate) — TRPR-PSR

| ID | Pri | Type | Requirement | Verif |
|---|---|---|---|---|
| TRPR-PSR-001 | C | F | The controller SHALL implement a QSPI master interface compatible with APS6404L (8 MB, 32 MHz QPI mode). Initialisation (enter QPI, set drive strength) SHALL complete within 1 ms of RESETB de-assertion. | T |
| TRPR-PSR-006 | H | I | `PSRAM_STATUS` (0x71) SHALL expose: `state[1:0]`, `SAMPLE_SKIP[2]`, `INIT_DONE[3]`, `REPLAY_ACTIVE[4]`, `REPLAY_MISSED[5]`, `OVERFLOW[6]`, `BUF_ACTIVE[7]`. STATE occupies 2 bits (only 4 FSM states); the freed bit [2] carries `SAMPLE_SKIP`. | T |
| TRPR-PSR-007 | H | F | Sticky error flags (`OVERFLOW`, `REPLAY_MISSED`, `SAMPLE_SKIP`) SHALL be clearable by writing `PSRAM_CLR_ERR` (0x70[1]). The `PSRAM_CLR_ERR` pulse SHALL be routed into `psram_buf_ctrl` (`clr_err` port); a genuine error coinciding with a clear in the same cycle SHALL NOT be lost. | T |
| TRPR-PSR-008 | — | — | **DELETED.** `PSRAM_PKT_BYTES` removed from the register map (never wired in RTL; cut under the 128-register constraint). Overflow detection uses the sticky `OVERFLOW` flag in `PSRAM_STATUS`. | — |
| TRPR-PSR-009 | M | F | A disable mode (`PSRAM_EN=0`, 0x70[0]) SHALL be supported for factory test and bring-up only. In this mode the controller SHALL remain idle and SHALL NOT assert any QSPI pad outputs. | T |
| TRPR-PSR-010 | C | I | `PSRAM_CTRL.QSPI_OWNER` (0x70[3]) SHALL select the active QSPI master: `0` = Trouper `psram_buf_ctrl` owns the pads for capture/replay, `1` = ownership is transferred away from the replay controller for a future firmware-managed external-memory mode. While `QSPI_OWNER=1`, the local replay controller SHALL de-assert CE#, hold SCK low, tri-state SIO[3:0], and suspend BUFFERING/REPLAY activity. | T |
| TRPR-PSR-011 | H | F | Writes to `QSPI_OWNER` during BUFFERING or REPLAY SHALL NOT glitch the pads: an in-flight QPI transaction completes with its clock running, no new bursts start after the request, and the ownership change takes effect at the next QPI burst boundary, after which the newly selected owner has exclusive control of the PSRAM QSPI pads. | T |
| TRPR-PSR-012 | — | — | **REMOVED.** No `PAD_CONFLICT` signal exists in RTL and none is needed: `psram_buf_ctrl` is the only on-chip QSPI driver, and under `QSPI_OWNER=1` it tri-states (TRPR-PSR-010/011), so no simultaneous-driver case can arise on-chip. | — |
| TRPR-PSR-013 | C | P | **Maximum PSRAM write data rate (nominal operating point):** 4 channels × 2 bytes (int8 I + int8 Q) × 500 000 S/s = **4 MB/s (32 Mbit/s)**. The APS6404L rated maximum is ~66 MB/s (QPI at 133 MHz); nominal utilisation is ~6% of device capacity. | A |
| TRPR-PSR-014 | C | P | **QPI timing headroom (32 MHz controller clock):** `iq_valid` arrives every 64 cycles (2.0 µs at 500 kS/s). S_WRITE = 25 (write) + 19 (SC delay read) = 44 cycles, leaving **20 spare**. S_REPLAY = 25 (write) + 31 (replay read) = 56 cycles, leaving **8 spare**. Both phases SHALL complete before the next `iq_valid`. See Gate 8 in `planning/decimator-hb-migration-impact-plan.md`. | A |
| TRPR-PSR-018 | C | I | **QPI-only interface mandate:** The PSRAM interface SHALL use QPI (4-bit) mode exclusively; SPI (1-bit) mode is not a supported operating point. Rationale: at the 500 kS/s `iq_valid` rate (64-cycle period at 32 MHz), one period must accommodate a write (25 QPI cycles) + SC delay read (19 QPI cycles) = 44 cycles (20 spare). SPI equivalents (~200 cycles) are >3× over the 64-cycle budget. Additionally, SIO[3:0] occupy four dedicated pads (TRPR-PHY-003), so QPI incurs zero additional pad cost versus SPI. | A |

#### 4.10.2 SC Correlator Delay RAM — TRPR-PSR / TRPR-FBC

Serves the SC detector's M-sample delay (`x[n−M]`, M = 1 << (SF + sample_shift)) from PSRAM — worst case SF12/125 kHz needs M = 16384 samples = 128 kB, far beyond any on-chip option. TRPR-FBC-001…005 are retained here under their original IDs (the standalone `frontend_buf_ctrl` block is deleted — §4.4).

| ID | Pri | Type | Requirement | Verif |
|---|---|---|---|---|
| TRPR-FBC-001 | C | F | The SC correlator M-sample delay SHALL be provided by the PSRAM Buffer Controller. On each `iq_valid`, the PSRAM controller SHALL supply the selected branch's `x[n−M]` (M = 1 << (SF + sample_shift), branch per TRPR-PSR-021) by issuing a QPI read at `write_ptr − M` before the next `iq_valid` arrives. The QPI read latency (30 cycles at 32 MHz) is well within the 64-cycle `iq_valid` period. | T |
| TRPR-FBC-002 | C | F | At packet start the PSRAM controller SHALL latch the packet start pointer and cease SC delay reads; implemented directly off `sc_lock` (see TRPR-PSR-002/016) — the FSM's `buf_freeze` output is not connected to the buffer controller (Open Risks #25). | T |
| TRPR-FBC-003 | C | F | The SC detector SHALL receive: `x[n]` — the selected branch's live sample from the decimator; `x[n−M]` — the same branch read back from PSRAM at offset M behind the current write pointer. Both SHALL be valid and stable before the SC detector evaluates each `iq_valid` pulse. | T |
| TRPR-FBC-004 | C | P | The PSRAM controller SHALL arbitrate SC delay reads against same-packet capture writes. SC delay reads are issued in the idle cycles between writes; the idle margin of TRPR-PSR-014 is sufficient to accommodate one additional QPI read per `iq_valid`. | A |
| TRPR-FBC-005 | H | I | PSRAM controller status SHALL remain readable via `PSRAM_STATUS` (0x71). The legacy `BUF_WR_PTR`, `FRONTEND_STATUS`, `FRONTEND_CFG`, and `SRAM_DUMP_*` registers are removed from the map (see Register Map.md "Removed registers"). | I |
| TRPR-PSR-016 | C | F | **SC correlator delay reads:** on each `iq_valid` (pre-lock), the controller SHALL issue a QPI read of the selected branch's I/Q at address `(write_ptr − M)`, where M = 1 << (SF + sample_shift), and present the result as `sc_delayed_sample` to the SC detector before the next `iq_valid`. SC delay reads SHALL be interleaved with circular writes in the idle cycles between writes; they SHALL NOT delay or preempt same-packet capture writes. After `sc_lock`, SC delay reads cease until the FSM returns to IDLE. | T |
| TRPR-PSR-019 | C | F | **Spreading factor is fixed per session.** SF SHALL be programmed at start-up before acquisition begins and SHALL NOT change during operation in the current revision. The SC delay distance (`M = 1 << (SF + sample_shift)`) and the delay-line warm-up window depend on SF and BW; changing either live would otherwise present a stale delayed sample read from an address not yet written with `N = M` fresh samples at the new distance. The controller SHALL re-arm the SC delay warm-up (suppress `del_valid` until `N` fresh samples are buffered) whenever `sf` or `sample_shift` changes. | T |
| TRPR-PSR-021 | H | F | **Delay-line branch select:** `sc_ant_sel` (`BW_CFG` 0x0A[2:1], reset 0) SHALL select which antenna branch feeds the SC correlator's live/delayed sample pair. Writes SHALL be locked while `packet_active=1` (no mid-packet retarget). This is the firmware mitigation for the single-branch detector's antenna-0 deep-fade SPOF (Open Risks #9); the correlator itself remains single-branch (TRPR-SCD-006). | T |

#### 4.10.3 Same-Packet Capture & Continuous-Delay Replay — TRPR-PSR

The "FIFO" between capture and weight availability: every sample is captured continuously; after `training_done` a bounded margin covers firmware weight computation, then the stored packet drains through the combiner as a fixed-depth delay line.

| ID | Pri | Type | Requirement | Verif |
|---|---|---|---|---|
| TRPR-PSR-002 | C | F | The controller SHALL continuously stream all decimated I/Q samples to PSRAM in a circular buffer pattern, recording every sample from power-on. On `sc_lock`, the controller SHALL latch the current PSRAM write address as the packet start pointer (`buf_base`). | T |
| TRPR-PSR-003 | C | F | **Continuous-delay replay (supersedes the former W_COMMIT-triggered rewind):** replay SHALL start at the expiry of a margin of `REPLAY_DELAY_SAMPLES` captured samples measured from the `training_done` rising edge — not on `W_COMMIT`. At margin expiry the controller asserts `REPLAY_ACTIVE` and reads from `buf_base`, advancing in lockstep with ongoing capture writes as a fixed-depth delay line, presenting the full packet including preamble to the MRC combiner at the live rate (500 kS/s). `W_COMMIT` gates only the combiner's `W_VALID`; it does not start, stop, or reposition replay. | T |
| TRPR-PSR-004 | C | F | **Late/absent commit handling:** if no `W_COMMIT` arrives before `packet_end`, sticky `REPLAY_MISSED` SHALL latch and any subsequent commit SHALL be inert (packet base invalidated) — the packet was presented in bypass. A commit arriving after replay start but before `packet_end` SHALL take effect from the commit onward and SHALL set the sticky `W_COMMIT_LATE` flag (`WGT_CTRL` 0x1E[4]). | T |
| TRPR-PSR-005 | H | F | The controller SHALL store samples in int8 format: 1 byte per I component + 1 byte per Q component per branch = **8 bytes per sample** for NR=4, in order i0,q0,i1,q1,i2,q2,i3,q3. No other storage width is implemented. | T |
| TRPR-PSR-015 | C | P | **Buffer capacity (worst case SF12/125 kHz, int8 I/Q mode):** `M = 1 << (SF + sample_shift) = 2^14 = 16384` samples/symbol; maximum occupied depth ≈ 8 × 16384 × 8 bytes = **1 MiB**. The APS6404L provides 8 MiB; headroom ≥ 8×. No overflow SHALL occur for SF ≤ 12 at either supported bandwidth. | A |
| TRPR-PSR-020 | C | F | **No-skip detection.** The controller SHALL latch a sticky `SAMPLE_SKIP` flag (`PSRAM_STATUS` 0x71[2], clearable via `PSRAM_CLR_ERR` 0x70[1]) if any `iq_valid` is asserted while a prior QPI transaction is still in progress — i.e. any decimated sample that cannot be captured. Under all supported bandwidths (125 kHz, 250 kHz) the timing budget of TRPR-PSR-014 guarantees this condition never occurs and `SAMPLE_SKIP` SHALL remain 0; the flag exists to make any out-of-budget condition observable rather than silent. Verified by a directed sustained-`iq_valid` test that asserts `SAMPLE_SKIP=0` across a full packet at 125 and 250 kHz. | T |
| TRPR-PSR-022 | C | I | `REPLAY_DELAY_SAMPLES` (`REPLAY_DELAY_LO/HI` 0x77/0x78, reset 1500 ≈ 3 ms at 500 kS/s) SHALL set the margin from `training_done` to replay start. It doubles as the weight-computation timeout and SHALL be sized to the measured weight-generation path (default covers the Grouper rv32emc 8-iteration eigenvector compute plus readout/IRQ overhead — `planning/blocks/Eigenvector Weight Computation.md`). Writes SHALL be gated by `!packet_active`. | T |
| TRPR-PSR-023 | C | F | From replay start until `W_COMMIT` (or packet end), the combiner SHALL process the replayed stream in bypass mode (lowest-enabled antenna): a late or absent commit degrades to single-antenna output — never silence, and never a retroactive re-present of already-output samples. | T |
| TRPR-PSR-024 | C | F | The replay read pointer SHALL be monotonically non-decreasing for the life of a packet (the delay line never rewinds). This is the mechanism satisfying TRPR-RMD-009 (no backward time-index jump at the re-modulator input); verified by the monotonic-`rd_ptr` check in `cocotb/tests/test_replay_delay.py`. | T |

#### 4.10.4 Host Debug Readback — TRPR-PSR

Register-mediated PSRAM reads over host SPI (no Grouper required) for bring-up and capture inspection. Note the `PSRAM_DBG_DATA` auto-increment exception in TRPR-SPS-010.

| ID | Pri | Type | Requirement | Verif |
|---|---|---|---|---|
| TRPR-PSR-017 | H | F | **PSRAM debug readback (host SPI, no Grouper required):** When `PSRAM_STATUS.STATE=IDLE` (`packet_active=0`) and `QSPI_OWNER=0`, the controller SHALL accept register-mediated QPI read requests from the host SPI slave: (1) Host writes a 23-bit byte address to `PSRAM_DBG_ADDR_LO/MID/HI` (0x72–0x74). (2) Host writes `PSRAM_DBG_CTRL.RD_TRIG=1` (0x75[0]); the controller asserts `DBG_BUSY` (0x75[7]) and issues a QPI burst read of 8 bytes from the target address. (3) Host polls `DBG_BUSY` until clear (≤ 31 QSPI cycles ≈ 0.97 µs at 32 MHz). (4) Host reads `PSRAM_DBG_DATA` (0x76) eight times; bytes arrive in order i0,q0,i1,q1,i2,q2,i3,q3. (5) If `AUTO_INC=1` (0x75[1]), the address advances by 8 after the last byte is read and a new fetch begins automatically. `DBG_BUSY` SHALL remain asserted and reads of `PSRAM_DBG_DATA` SHALL return 0x00 while `packet_active=1`, while `QSPI_OWNER=1`, or before `INIT_DONE`. Debug reads are serviced in the spare sub-cycles between `iq_valid` pulses and SHALL NOT delay or preempt circular capture writes. | T |

---

### 4.11 SPI Slave (`spi_slave.v`) — TRPR-SPS

Host (Raspberry Pi) configuration and debug interface. The register map is constrained to the 7-bit address space `0x00`–`0x7F` (see `planning/Register Map.md`); the former extended firmware-load frame is removed (Trouper has no CPU SRAM to load).

| ID | Pri | Type | Requirement | Verif |
|---|---|---|---|---|
| TRPR-SPS-001 | C | F | The SPI slave SHALL accept standard Mode 0 SPI transactions from the host RPi on `SPI_MOSI`, `SPI_SCK`, `HOST_CS` and return data on `SPI_MISO`. | T |
| TRPR-SPS-002 | C | F | Each transaction SHALL consist of a command byte followed by one or more data bytes. Command byte: bit [7] = R/W# (0 = write, 1 = read), bits [6:0] = 7-bit register address. The entire register map SHALL fit in `0x00`–`0x7F`; there is no extended-address or bank-select mechanism. | T |
| TRPR-SPS-003 | C | I | The SPI slave SHALL translate transactions to accesses on the internal register bank bus. | T |
| TRPR-SPS-004 | C | P | Maximum SPI clock rate SHALL be 10 MHz. | A |
| TRPR-SPS-005 | C | HW | `HOST_CS`, `SPI_SCK`, and `SPI_MOSI` are asynchronous to the 32 MHz core clock. A 2-FF synchroniser SHALL be applied to `HOST_CS` and `SPI_SCK` edges, or the SPI slave FSM SHALL run in the SPI clock domain with an AHB-Lite handshake. | I |
| TRPR-SPS-006 | H | F | `CHIP_ID` (0x00) SHALL return 0xA7 on any SPI read, confirming interface health on first bring-up. | T |
| TRPR-SPS-007 | H | F | The SPI slave SHALL arbitrate with Grouper register-bus accesses; host SPI transactions SHALL be queued or stalled during an in-progress inter-project bus cycle. Priority: Grouper path > SPI Slave (host). | T |
| TRPR-SPS-008 | M | F | The SPI slave SHALL tri-state `SPI_MISO` when `HOST_CS` is de-asserted to avoid bus contention with other SPI devices sharing the bus. | T |
| TRPR-SPS-009 | C | F | **Read-data timing:** the slave SHALL latch the register address on the final (8th) rising `SPI_SCK` edge of the command byte, so that read data is valid on `SPI_MISO` for every bit of the immediately following data byte. A 2-byte read transaction (command + data) SHALL return the addressed register's value in the data byte. | T |
| TRPR-SPS-010 | H | F | **Burst access:** if `HOST_CS` remains asserted after the first data byte, each additional data byte SHALL access the next consecutive register address (auto-increment, wrapping modulo 128). Exception: `PSRAM_DBG_DATA` (`0x76`) SHALL NOT auto-increment — repeated data bytes re-access the same port. | T |
| TRPR-SPS-011 | M | I | Register `0x7F` SHALL NOT be implemented (reads return 0x00, writes ignored). The command byte `0x7F` is reserved as a future protocol-escape code; current hardware SHALL treat it as a write to `0x7F` and discard it. | I |

---

### 4.12 Removed AFE SPI Master (not present in current Trouper revision) — TRPR-SPM

Trouper does not contain an on-chip SPI master for SX1257 configuration in the current revision. AFE configuration is provided externally at board/system level and is outside Trouper's hardened RTL contract.

| ID | Pri | Type | Requirement | Verif |
|---|---|---|---|---|
| TRPR-SPM-001 | C | F | Trouper SHALL NOT instantiate an on-chip SPI master or expose `CS_A[1:0]` AFE-select outputs in the current revision. | I |
| TRPR-SPM-002 | H | I | SX1257 configuration, gain programming, and frequency programming SHALL be handled by external system logic or the companion controller outside Trouper's hardened RTL. | I |

---

### 4.13 Register Bank — TRPR-REG

Custom hand-written register bank (no generator exists or is planned — TRPR-REG-005). Authoritative register definitions in `planning/Register Map.md`.

| ID | Pri | Type | Requirement | Verif |
|---|---|---|---|---|
| TRPR-REG-001 | C | F | The register bank SHALL implement all 8-bit registers defined in `planning/Register Map.md`, maintaining defined reset values and R/W permissions. | T |
| TRPR-REG-002 | C | I | The register bank SHALL be an AHB-Lite slave with 8-bit address and 8-bit data, accessible from both the SPI slave bridge and the inter-project Grouper AHB-Lite master. | T |
| TRPR-REG-003 | C | F | Multi-byte registers (e.g., Z_kl int32, W int16) SHALL be big-endian: MSB at the lower address. | I |
| TRPR-REG-004 | H | F | Reads from undefined or reserved addresses SHALL return 0x00. Writes to reserved addresses SHALL be silently ignored. | T |
| TRPR-REG-005 | H | F | The register bank is custom hand-written RTL (`reg_bank.v`); `planning/Register Map.md` is the single source of truth and every register-map change SHALL update RTL and map together, verified by register-level tests (no generator tool exists or is planned). | I |
| TRPR-REG-006 | H | F | Write-1-Pulse (W1P) registers (`TACC_NOISE_TRIG` 0x1F, `WGT_CTRL.W_COMMIT` 0x1E[0], `RX_GAIN_COMMIT` 0x18[0], `PSRAM_CLR_ERR` 0x70[1], `PSRAM_DBG_CTRL.RD_TRIG` 0x75[0]) SHALL self-clear on the cycle after assertion. | T |
| TRPR-REG-007 | M | F | Sticky status registers such as `IRQ_STATUS` (0x02) SHALL clear only on an explicit write to their corresponding clear register. | T |

---

### 4.14 Interrupt Aggregation (in `reg_bank.v`) — TRPR-IRQ

Interrupt aggregation is implemented **inside `reg_bank.v`**, not as a standalone module. (The former `irq_ctrl.v` block was never instantiated and has been removed.) reg_bank aggregates event signals into sticky interrupt bits and drives two independent interrupt outputs — one external pad, one inter-project line.

| ID | Pri | Type | Requirement | Verif |
|---|---|---|---|---|
| TRPR-IRQ-001 | C | F | reg_bank SHALL aggregate the following events into sticky `IRQ_STATUS` bits (0x02): `CORR_LOCK` [0], `TRAINING_DONE` [1], `W_MISSED_PACKET` [2], `PACKET_DONE` [3], `NOISE_READY` [4]. | T |
| TRPR-IRQ-002 | C | F | Each sticky bit SHALL be cleared by writing the corresponding bit to `IRQ_CLEAR` (0x03). | T |
| TRPR-IRQ-003 | C | F | When any `IRQ_STATUS` bit is set, Trouper SHALL assert both `IRQ_OUT` and `IRQ_GROUPER`. `IRQ_OUT` routes to a dedicated package pad. `IRQ_GROUPER` is an inter-project wire to Grouper. Both are driven by the same `\|irq_status` signal from reg_bank. | T |
| TRPR-IRQ-004 | H | F | Both IRQ outputs SHALL remain asserted until all `IRQ_STATUS` bits are cleared (level-high, not a pulse). | T |
| TRPR-IRQ-005 | — | — | **DELETED.** JTAG removed; the IRQ pad is dedicated (no pad muxing), so the former `JTAG_EN`/`TCK` mode-switch and PSRAM-pad-sharing caveats no longer apply. | I |
| TRPR-IRQ-006 | C | F | Each `IRQ_STATUS` bit SHALL be set on the rising edge of its source event, not by a held level, so a bit cleared via `IRQ_CLEAR` is not immediately re-asserted while the source condition persists (required for TRPR-IRQ-002 on the level-driven `CORR_LOCK`/`TRAINING_DONE` sources). | T |

---

### 4.15 AGC and Noise Estimation — TRPR-AGC

Trouper has no on-chip SPI master. Grouper firmware owns SX1257 LNA gain control via its dedicated SPI master and uses Trouper's Zdiag registers for power measurement.

**AGC loop — absolute power, gain before saturation:**

| ID | Pri | Type | Requirement | Verif |
|---|---|---|---|---|
| TRPR-AGC-001 | C | I | Per-antenna preamble power SHALL be measured via `Zdiag[k][31:8] / n_acc` after `training_done`. Controlling software reads Zdiag at 0x64–0x6F and the full 18-bit `N_ACC` at 0x21–0x23. | T |
| TRPR-AGC-002 | C | I | The AGC strategy SHALL be "maximum gain before saturation": Grouper firmware SHALL increase LNA gain unless Zdiag/n_acc exceeds a firmware-held high-water threshold, and decrease gain if it exceeds a firmware-held saturation threshold. **No on-chip `AGC_THR_HI`/`AGC_THR_SAT` comparator registers exist** — both thresholds live entirely in host/Grouper firmware memory; the comparison itself is a software computation against the Zdiag/n_acc value read per TRPR-AGC-001 (see `planning/Register Map.md` "Former addresses": these register names were never implemented in RTL). One SX1257 LNA gain step per packet. All four antennas are controlled independently. | T |
| TRPR-AGC-003 | H | I | After programming each SX1257 (board-level SPI master), controlling software SHALL write the applied gain byte to `RX_GAIN_SHADOW_k` (0x10–0x13) and strobe `RX_GAIN_COMMIT` (0x18[0]=1). Trouper SHALL latch shadow→`RX_GAIN_ACTIVE_k` (0x14–0x17) on the commit pulse within one 32 MHz clock cycle. | T |

**Noise EMA — weight quality, separate from AGC:**

| ID | Pri | Type | Requirement | Verif |
|---|---|---|---|---|
| TRPR-AGC-004 | C | I | Between packets (`packet_active=0`), controlling software SHALL arm a noise accumulation window by writing `TACC_NOISE_TRIG` (0x1F[0]=1). training_acc accumulates noise-only samples; `IRQ_TRAINING_DONE` fires when complete. Zdiag[k] then reflects σ²_k × n_acc. | T |
| TRPR-AGC-005 | C | I | Grouper firmware SHALL maintain a per-antenna noise-floor EMA: σ²_ema[k] ← (1−α)·σ²_ema[k] + α·(Zdiag[k]/n_acc). A single per-packet noise sample is not sufficient for stable weight quality. This EMA supplies the optional noise-weighted MRC mode (TRPR-WGN-012), which scales conventional MRC weights by `1/σ²_ema[k]`. | T |

---

### 4.16 JTAG / GPIO — REMOVED — TRPR-JTG

JTAG and GPIO have been removed from Trouper. No JTAG TAP is instantiated in the
RTL, and the former GPIO direction/output/input path was never wired out of the
hardened-macro boundary. The four pads formerly described as
`TCK_IRQ`/`TMS_GPIO0`/`TDI_GPIO1`/`TDO_GPIO2` now carry only `PSRAM_SIO[3:0]`
on four dedicated pads; `IRQ_OUT` has its own dedicated pad (see TRPR-PHY-003).
Registers `0x04`–`0x07` (`DEBUG_CTRL`/`JTAG_EN`, `GPIO_DIR`/`OUT`/`IN`) are
reserved: reads return `0x00`, writes ignored. Structural scan-chain DFT, if
required, is inserted by the LibreLane flow independently of any functional TAP.
Host debug uses the SPI register/PSRAM-readback path (TRPR-SPS, TRPR-PSR-017).

| ID | Pri | Type | Requirement | Verif |
|---|---|---|---|---|
| TRPR-JTG-001 | — | — | **DELETED.** GPIO removed; `0x04`–`0x07` reserved. | — |
| TRPR-JTG-002 | — | — | **DELETED.** No JTAG TAP in RTL. | — |
| TRPR-JTG-003 | — | — | **DELETED.** | — |
| TRPR-JTG-004 | — | — | **DELETED.** | — |

---

## 5. Control-Plane Integration (On-Chip AHB-Lite + Host SPI) — TRPR-INT

Trouper is a MIMO RX ASIC connected to a companion **Grouper** project on the same MPW. The control plane lives inside Grouper (PicoRV32 hardened macro), while Trouper acts as an AHB-Lite peripheral to Grouper.

### 5.1 Architecture

```
┌──────────────────────────────────────────────────────────────┐
│                        TROUPER PROJECT                       │
│                                                              │
│  [Host SPI Slave] ─┐                                         │
│                    ├─► [AHB Bridge / Slave] ─► [Reg Bank]    │
│  [AHB-Lite Port] ──┘                 │                       │
│      (from Grouper)                  ├─► IRQ controller      │
│                                      └─► DSP control/status  │
└──────────────────────────────────────────────────────────────┘
```

### 5.2 Signal Roles

| Signal / path | Scope | Description |
|---|---|---|
| `HCLK` / `HRESETn` | inter-project clock/reset | `HCLK` is the 32 MHz `IQ_CLK` clock and `HRESETn` is `RESETB`; they are the clock and reset for the AHB endpoint. They are not members of Grouper's `ahb3lite_intf` SystemVerilog interface. |
| AHB3-Lite slave interface | Inter-project (no pads) | The endpoint SHALL connect to the `slave` modport of Grouper's `ahb3lite_intf` (`ADDR_WIDTH=32`, `DATA_WIDTH=32`). Its complete signal set is defined below. **MPW-internal wires only — not bonded to package pads; excluded from the 26-pad budget (TRPR-PHY-002/003).** |
| `IRQ` | Inter-project (no pads) | active-high interrupt from `reg_bank` (interrupt aggregation) in Trouper to PicoRV32 in Grouper. Internal wire; the pad-facing copy is the dedicated `IRQ_OUT` pad. |
| Host SPI | package pins | external register access and debug path to Trouper |

#### 5.2.1 Grouper `ahb3lite_intf.slave` contract

| Direction at Trouper | Signal | Width | Required use |
|---|---|---:|---|
| input | `HADDR` | 32 | Address bus; the Trouper adapter uses the byte offset needed to select the 7-bit register map. |
| input | `HBURST` | 3 | Accepted but ignored; Trouper supports only individual register transfers. |
| input | `HMASTLOCK` | 1 | Accepted but ignored; Trouper provides no locked-transfer-specific behaviour. |
| input | `HPROT` | 4 | Accepted but ignored; access permissions are not encoded in this endpoint. |
| input | `HSIZE` | 3 | Must be `3'b000` (byte). Other sizes return an AHB error response. |
| input | `HTRANS` | 2 | A transfer is requested only for `NONSEQ` (`2'b10`) or `SEQ` (`2'b11`); `IDLE` and `BUSY` have no register side effect. |
| input | `HWDATA` | 32 | Write data; for a byte transfer the adapter selects the byte lane addressed by `HADDR[1:0]`. |
| input | `HWRITE` | 1 | High selects a write; low selects a read. |
| input | `HREADYIN` | 1 | Decoder/global data-phase completion input. The adapter must not complete or advance its data phase while low. |
| input | `HSEL` | 1 | Decoder select for the Trouper address range. A request is valid only when asserted with a valid `HTRANS`. |
| output | `HRDATA` | 32 | Read result; register data is returned in the byte lane addressed by `HADDR[1:0]`, with all other lanes zero. |
| output | `HREADYOUT` | 1 | Slave completion output. It is high for a completed zero-wait-state transfer and may be held low only to insert a wait state. |
| output | `HRESP` | 1 | `1'b0` for `OKAY`; `1'b1` for an unsupported transfer, including a non-byte `HSIZE`. |

> **Control-plane interface (implementation note).** Trouper presents its register bank to Grouper as an **AHB3-Lite slave peripheral**. A small adapter converts the AHB3-Lite slave protocol to the internal reg_bank byte interface (`addr/wdata/we/re/rdata/ready`), which the host SPI slave shares via arbitration (Grouper priority). A transfer is accepted only when `HSEL` is high, `HTRANS[1]` is high, and the preceding data phase is permitted by `HREADYIN`; a write or read side effect occurs exactly once when that transfer completes. **All AHB3-Lite slave signals are inter-project MPW connections to the Grouper master and are never routed to package pads** — they consume none of the 26 pads. *Current RTL status:* the `trouper_top` boundary still exposes the simplified `GRP_*` byte bus as a placeholder; swapping it for the AHB3-Lite slave adapter is pending (TRPR-INT-001).

### 5.3 Integration Requirements

| ID | Pri | Type | Requirement | Verif |
|---|---|---|---|---|
| TRPR-INT-001 | C | I | Trouper SHALL contain an internal control fabric linking the inter-project AHB-Lite slave endpoint, the SPI slave bridge, and the register/peripheral fabric. | I |
| TRPR-INT-002 | C | F | Trouper's internal AHB-Lite path SHALL provide access to the complete register bank (0x00–0x7F, 7-bit map) with the same semantics as SPI slave access. | T |
| TRPR-INT-003 | C | F | An arbiter/bridge SHALL mediate between the SPI slave bridge and the Grouper AHB-Lite master path. The Grouper AHB-Lite path SHALL have priority over host SPI. SPI transactions SHALL stall during an active inter-project bus cycle. | T |
| TRPR-INT-004 | C | F | When the Grouper control path is idle, unavailable, or held in reset, Trouper SHALL continue operating normally through the host SPI path with no bus contention or undriven control inputs. | T |
| TRPR-INT-005 | H | I | The internal `IRQ` line SHALL be asserted whenever any unmasked `IRQ_STATUS` bit is set, providing Grouper with an interrupt to trigger firmware service such as weight computation. | T |
| TRPR-INT-006 | H | I | The whole digital core runs on the single 32 MHz clock; control-plane peripherals (`reg_bank`) are clock-enable-gated to an effective 16 MHz update rate (`clk_en`, honest MCP=2 — no separate `CLK_16M` net or generated clock exists). No metastability synchronisers are required anywhere in the core; the Grouper register bus and SPI-slave handshakes are CE-aligned by construction. | I |
| TRPR-INT-007 | H | F | Grouper firmware and host SPI SHALL use the same Trouper register map as defined in `planning/Register Map.md`. No separate Trouper-only firmware register space exists. | I |
| TRPR-INT-008 | M | F | AHB-Lite HSIZE SHALL be BYTE (8-bit) only for this integration. Firmware SHALL NOT issue halfword or word AHB transactions to the Trouper peripheral fabric. | T |
| TRPR-INT-009 | M | F | The weight commit flow SHALL be: firmware computes W from Z_kl → writes the complete W register bank (0x30–0x3F) → writes `WGT_CTRL.W_COMMIT` (0x1E[0]) → Trouper FSM asserts `W_VALID`; the combiner consumes the live write-locked bank (TRPR-MRC-004). | T |
| TRPR-INT-013 | C | I | The Trouper AHB endpoint SHALL exactly implement the signal directions and widths of the `slave` modport in Grouper's `ahb3lite_intf` with `ADDR_WIDTH=32` and `DATA_WIDTH=32`, as specified in §5.2.1. | I |
| TRPR-INT-014 | C | F | The endpoint SHALL recognise a request only when `HSEL=1` and `HTRANS[1]=1`. It SHALL use `HREADYIN` to qualify data-phase progress and SHALL perform each register read side effect or write exactly once per completed transfer. | T |
| TRPR-INT-015 | H | F | `HBURST`, `HMASTLOCK`, and `HPROT` SHALL not affect register-map semantics. `HSIZE!=3'b000` SHALL complete with `HRESP=1'b1` and SHALL have no register side effect. | T |

### 5.4 CPU-Held-Reset Operation

| ID | Pri | Type | Requirement | Verif |
|---|---|---|---|---|
| TRPR-INT-010 | C | F | When the Grouper firmware path is inactive or no `W_COMMIT` is received, Trouper SHALL operate in bypass mode: the combiner routes the lowest-enabled antenna to the re-modulator output without MRC weighting. | T |
| TRPR-INT-011 | H | F | The host RPi SHALL be able to pre-configure Trouper registers such as SC thresholds, antenna enable, and mode via the SPI slave without requiring firmware execution. | T |
| TRPR-INT-012 | M | F | Grouper-inactive Trouper with Mode 1 (passthrough) SHALL provide a functional single-antenna LoRa receive path for bring-up and basic system validation. | T |

---

## 6. Physical Design Requirements — TRPR-PHY

| ID | Pri | Type | Requirement | Verif |
|---|---|---|---|---|
| TRPR-PHY-001 | C | HW | The design SHALL be submitted in GF180MCU (gf180mcuD), targeting `gf180mcu_fd_sc_mcu7t5v0` standard cells. AS cells (`gf180mcu_as_sc_mcu7t3v3`) are not the current plan and carry tapeout risk; new work SHALL NOT target AS cells without explicit team decision. | I |
| TRPR-PHY-015 | C | HW | VDD_CORE and VDD_IO SHALL be separate, independently-tunable supply rails (NOT tied on-die), each 3.3 V (±5%) at baseline; the separation SHALL permit the contingency split-rail — 5 V core / 3.6 V IO — to be applied without a silicon respin if 32 MHz SS cannot close at 3.3 V (see planning/Open Risks.md #27). | I |
| TRPR-PHY-002 | C | HW | The chip-level integration baseline SHALL use the Chipathon workshop padring: die `[0, 0, 2935, 2935]` um and user-core `[442, 442, 2493, 2493]` um. | I |
| TRPR-PHY-003 | C | HW | The standalone Trouper hard macro SHALL fit within the Chipathon quarter-slot budget. The current Trouper target is **`1100 um × 1100 um`**. | I |
| TRPR-PHY-004 | C | HW | Final package-pad allocation SHALL be validated at the later chip-top integration stage against the Chipathon padring. | I |
| TRPR-PHY-005 | H | HW | Physical design SHALL use LibreLane inside the `hpretl/iic-osic-tools:chipathon26` Docker image. `:latest` and `:2026.04` tags are prohibited. | I |
| TRPR-PHY-006 | H | HW | No on-chip SRAM macro instances are required. The frontend buffer SRAM (`gf180mcu_fd_ip_sram__sram512x8m8wm1`) has been removed; the SC correlator delay line is served by the off-chip APS6404L PSRAM (see TRPR-FBC-001). | I |
| TRPR-PHY-007 | H | P | Post-PNR WNS at TT/25 °C/3.3 V (setup) SHALL be ≥ 0 ns. | A |
| TRPR-PHY-008 | H | P | Post-PNR WNS at SS/125 °C/3.0 V SHALL be documented each run. The SS gap is a known FD cell library limitation (cells rated 5 V, characterised at 3 V); −7 to −10 ns at MCP=2 is accepted for chipathon submission. Trouper is guaranteed only at TT ≥ 0 °C, 3.3 V ±5%. | A |
| TRPR-PHY-009 | H | P | Post-PNR hold WNS at FF/−40 °C/3.6 V SHALL be ≥ 0 ns. | A |
| TRPR-PHY-010 | H | HW | Magic DRC error count SHALL be 0 before tapeout submission. | A |
| TRPR-PHY-011 | H | P | Estimated total power at TT/25 °C/3.3 V SHALL be ≤ 60 mW. | A |
| TRPR-PHY-012 | M | HW | Core utilisation SHOULD be in the range 65–75%. | I |
| TRPR-PHY-013 | M | HW | Power-pad count and placement are chip-top integration concerns under the Chipathon padring. Standalone Trouper floorplanning SHALL still document estimated current draw and any local PDN hotspots so the later padring/power-grid integration can assign sufficient DVDD/DVSS resources. | A |
| TRPR-PHY-014 | C | P | The PNR and signoff SDC SHALL declare a single clock: `create_clock -period 31.25 [get_ports IQ_CLK]`. Paced and CE-gated paths SHALL be covered by *scoped* `set_multicycle_path` constraints that exactly match the RTL hold counters / clock-enables (MCP=3 TDM cones, MCP=2 CE-gated control plane) — no generated clocks and no blanket MCP override. Every MCP arc SHALL be honest: the RTL must guarantee the multi-cycle stability the constraint claims (see Open Risks #39/#40 history). | I |

---

## 7. Verification Requirements — TRPR-VER

| ID | Pri | Type | Requirement | Verif |
|---|---|---|---|---|
| TRPR-VER-001 | C | F | Each DSP block SHALL have a cocotb testbench comparing RTL output to the Python reference model in `sim/models/` with the same stimulus. | T |
| TRPR-VER-002 | C | F | A full-chain bit-exactness test SHALL be run: real ΣΔ input → decimator → DC removal → SC detector → training accumulator → combiner → re-modulator, comparing RTL output to Python reference. Error-signal SNR SHALL reflect only LSB quantisation and no correlated clipping artifacts. | T |
| TRPR-VER-003 | H | F | The FPGA emulation platform (Arty A7-100T) SHALL be used as the primary pre-silicon validation environment for the full DSP chain. | T |
| TRPR-VER-004 | H | F | The internal AHB-Lite control path SHALL be testable in simulation with a BFM (Bus Functional Model) acting as the Grouper-side master. | T |
| TRPR-VER-005 | H | F | Grouper-inactive mode (no firmware activity, no W_COMMIT) SHALL be verified: the combiner SHALL produce valid bypass output without FSM deadlock. | T |
| TRPR-VER-006 | M | F | Over-the-air validation with a single Heltec V3 transmitter SHALL demonstrate MRC diversity gain: PER with all four branches active (Mode 0, MRC weights committed) SHALL be ≤ 1% at an attenuation level where single-antenna bypass (Mode 1) yields PER ≥ 10%. Test SHALL be performed at SF7 and SF12, BW=250 kHz. | T |

---

---
