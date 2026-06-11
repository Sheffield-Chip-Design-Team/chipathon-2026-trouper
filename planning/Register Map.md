# Register Map

Internal registers accessible through two primary control paths:
1.  **Trouper Host SPI Slave:** Dedicated interface for external host access (RPi SPI0 CS1).
2.  **Grouper AHB-Lite Bus:** Shared system bus for inter-project control by the PicoRV32.

This file is the authoritative register-map source for the non-FFT LoRa-MIMO architecture. All addresses below are final for the current planning set. There are no legacy aliases or compatibility mappings.

All registers are 8-bit. Multi-byte values are big-endian (MSB at lower address). Addresses not listed here return `0x00` on read and ignore writes.

---

## Address map

| Address | Name | R/W | Reset | Block | Description |
| --- | --- | --- | --- | --- | --- |
| **Global / Control / Debug** (`0x00`–`0x0F`) | | | | | |
| `0x00` | `CHIP_ID` | R | `0xA7` | — | Chip identification byte |
| `0x01` | `CHIP_REV` | R | `0x01` | — | Silicon revision |
| `0x02` | — | — | — | — | Reserved (legacy `CPU_RESET`; Trouper has no local CPU reset control in the current revision) |
| `0x03` | `DEBUG_CTRL` | R/W | `0x00` | JTAG TAP | [0] `JTAG_EN`; [7:1] reserved |
| `0x04` | `GPIO_DIR` | R/W | `0x00` | JTAG TAP | GPIO direction bits for `TMS_GPIO0`, `TDI_GPIO1`, `TDO_GPIO2` when `JTAG_EN=0` |
| `0x05` | `GPIO_OUT` | R/W | `0x00` | JTAG TAP | GPIO output values when `JTAG_EN=0` |
| `0x06` | `GPIO_IN` | R | `0x00` | JTAG TAP | GPIO sampled inputs when `JTAG_EN=0` |
| `0x07` | — | — | — | — | Reserved (legacy CPU-SRAM borrow control; removed) |
| `0x08` | — | — | — | — | Reserved (legacy CPU-SRAM status; removed) |
| `0x09` | — | — | — | — | Reserved (was TX_CTRL; TX not supported) |
| `0x0A` | `LOW_BAT_THR` | R/W | `0x02` | Control | Low-battery threshold configuration |
| `0x0B`–`0x0F` | — | — | — | — | Reserved for future global boot/BIST/debug control |
| **RX Front-End Configuration** (`0x10`–`0x1F`) | | | | | |
| `0x10` | `MIMO_CTRL` | R/W | `0xF0` | Control | [0] `MODE` (0=MRC, 1=passthrough); [7:4] `ANTENNA_EN` |
| `0x11` | `SF_CFG` | R/W | `0x07` | Packet timing | [2:0] spreading-factor selector |
| `0x12` | `DECIM_CFG` | R/W | `0x00` | ΣΔ Decimator | [1:0] decimation-ratio / output-bandwidth select |
| `0x13` | `FRONTEND_CFG` | R/W | `0x00` | Frontend Buffer | [0] reserved; [1] `BIST_RUN`; [7:2] reserved |
| `0x14` | `FRONTEND_STATUS` | R | `0x00` | Frontend Buffer | [1:0] `BUF_MODE`; [2] `BUF_VALID`; [3] `SRAM0_BIST_PASS`; [4] `SRAM1_BIST_PASS`; [5] `BUF_FREEZE`; [7:6] reserved |
| `0x15` | `BUF_WR_PTR` | R | `0x00` | Frontend Buffer | [6:0] current write pointer mod 128; [7] `BUF_FREEZE` mirror |
| `0x16` | `PKT_TIMEOUT_SYMS` | R/W | `0x50` | Packet Control FSM | Packet timeout in LoRa symbols |
| `0x17` | `ENERGY_THR_HI` | R/W | `0x00` | Energy Measurement | Optional coarse energy threshold [15:8] used when `SC_CFG.ENERGY_GATE_EN=1` |
| `0x18` | `ENERGY_THR_LO` | R/W | `0x00` | Energy Measurement | Optional coarse energy threshold [7:0] |
| `0x19` | `SC_THR_HI` | R/W | `0x73` | Schmidl-Cox | Detection threshold register [15:8]. Current RTL only consumes bits [12:0]; reset value is legacy. |
| `0x1A` | `SC_THR_LO` | R/W | `0x33` | Schmidl-Cox | Detection threshold register [7:0] |
| `0x1B` | `SC_HITS_REQ` | R/W | `0x02` | Schmidl-Cox | Consecutive SC hits required for `sc_lock`, valid range 1-3 |
| `0x1C` | `SC_CFG` | R/W | `0x00` | Schmidl-Cox | [0] `ENERGY_GATE_EN`; [7:1] reserved |
| `0x1D`–`0x1F` | — | — | — | — | Reserved for RX front-end growth |
| **Gain / AGC / SX1257 Live RX Control** (`0x20`–`0x2F`) | | | | | |
| `0x20` | `RX_GAIN_SHADOW_0` | R/W | `0x3E` | AGC / External Control | Software-visible desired gain byte for SX1257_1 (Trouper does not apply it on chip) |
| `0x21` | `RX_GAIN_SHADOW_1` | R/W | `0x3E` | AGC / External Control | Software-visible desired gain byte for SX1257_2 |
| `0x22` | `RX_GAIN_SHADOW_2` | R/W | `0x3E` | AGC / External Control | Software-visible desired gain byte for SX1257_3 |
| `0x23` | `RX_GAIN_SHADOW_3` | R/W | `0x3E` | AGC / External Control | Software-visible desired gain byte for SX1257_4 |
| `0x24`–`0x25` | — | — | — | — | Reserved (was TX_GAIN_0/1; TX not supported) |
| `0x26` | `RX_GAIN_ACTIVE_0` | R | `0x3E` | AGC / External Control | Software-maintained mirror of the live SX1257_1 gain setting |
| `0x27` | `RX_GAIN_ACTIVE_1` | R | `0x3E` | AGC / External Control | Software-maintained mirror of the live SX1257_2 gain setting |
| `0x28` | `RX_GAIN_ACTIVE_2` | R | `0x3E` | AGC / External Control | Software-maintained mirror of the live SX1257_3 gain setting |
| `0x29` | `RX_GAIN_ACTIVE_3` | R | `0x3E` | AGC / External Control | Software-maintained mirror of the live SX1257_4 gain setting |
| `0x2A` | `RX_GAIN_CTRL` | R/W | `0x00` | AGC / External Control | [0] `RX_GAIN_COMMIT`; [1] reserved; [2] reserved; [3] reserved; [7:4] reserved |
| `0x2B`–`0x2F` | — | — | — | — | Reserved for AGC thresholds and gain diagnostics |
| **Packet / Weight-Path Control** (`0x30`–`0x3F`) | | | | | |
| `0x30` | `ACTIVE_MODE` | R | `0x00` | Control | Active mode latched at packet-safe boundary from `MIMO_CTRL.MODE` |
| `0x31` | `ACTIVE_ANTENNA_EN` | R | `0x0F` | Packet Control FSM | Latched active antenna mask for the current packet |
| `0x32` | `IRQ_STATUS` | R | `0x00` | IRQ Controller | Sticky interrupt source bits |
| `0x33` | `IRQ_CLEAR` | W | `0x00` | IRQ Controller | Write 1 to clear matching `IRQ_STATUS` bits |
| `0x34` | `PACKET_STATUS` | R | `0x00` | Packet Control FSM | `PACKET_ACTIVE`, `PACKET_PHASE`, `TRAINING_DONE`, `W_PENDING`, `W_VALID`, `W_MISSED_PACKET` |
| `0x35` | `WGT_CTRL` | R/W | `0x00` | Packet Control FSM / Combiner | [0] `W_COMMIT`; [1] `W_VALID`; [2] `W_PENDING`; [3] `W_MISSED_PACKET`; [7:4] reserved (WGT_SRC/AUTO_COMMIT/WGT_MODE removed — HW weight_gen gone) |
| `0x36` | `COMB_POST_GAIN` | R/W | `0x00` | MRC Combiner | Post-combine left-shift gain after fixed guard divide-by-2 |
| `0x37`–`0x3F` | — | — | — | — | Reserved for packet-FSM and weight-path expansion |
| **Runtime Measurement / Live Observability** (`0x40`–`0x5F`) | | | | | |
| `0x40` | `ENERGY_0_HI` | R | `0x00` | Training Accumulator | Antenna 0 Z_kk energy [15:8] (latched at training_done) |
| `0x41` | `ENERGY_0_LO` | R | `0x00` | Training Accumulator | Antenna 0 Z_kk energy [7:0] |
| `0x42` | `ENERGY_1_HI` | R | `0x00` | Training Accumulator | Antenna 1 Z_kk energy [15:8] |
| `0x43` | `ENERGY_1_LO` | R | `0x00` | Training Accumulator | Antenna 1 Z_kk energy [7:0] |
| `0x44` | `ENERGY_2_HI` | R | `0x00` | Training Accumulator | Antenna 2 Z_kk energy [15:8] |
| `0x45` | `ENERGY_2_LO` | R | `0x00` | Training Accumulator | Antenna 2 Z_kk energy [7:0] |
| `0x46` | `ENERGY_3_HI` | R | `0x00` | Training Accumulator | Antenna 3 Z_kk energy [15:8] |
| `0x47` | `ENERGY_3_LO` | R | `0x00` | Training Accumulator | Antenna 3 Z_kk energy [7:0] |
| `0x48` | `CORR_MAG_0_HI` | R | `0x00` | Correlator Bank | Reserved SC magnitude readback [15:8]; currently hardwired 0 |
| `0x49` | `CORR_MAG_0_LO` | R | `0x00` | Correlator Bank | Reserved SC magnitude readback [7:0]; currently hardwired 0 |
| `0x4A` | `CORR_MAG_1_HI` | R | `0x00` | Correlator Bank | Reserved SC magnitude readback [15:8]; currently hardwired 0 |
| `0x4B` | `CORR_MAG_1_LO` | R | `0x00` | Correlator Bank | Reserved SC magnitude readback [7:0]; currently hardwired 0 |
| `0x4C` | `CORR_MAG_2_HI` | R | `0x00` | Correlator Bank | Reserved SC magnitude readback [15:8]; currently hardwired 0 |
| `0x4D` | `CORR_MAG_2_LO` | R | `0x00` | Correlator Bank | Reserved SC magnitude readback [7:0]; currently hardwired 0 |
| `0x4E` | `CORR_MAG_3_HI` | R | `0x00` | Correlator Bank | Reserved SC magnitude readback [15:8]; currently hardwired 0 |
| `0x4F` | `CORR_MAG_3_LO` | R | `0x00` | Correlator Bank | Reserved SC magnitude readback [7:0]; currently hardwired 0 |
| `0x50` | `SC_STAT_HI` | R | `0x00` | Schmidl-Cox | Current SC metric numerator `|C[s]|^2` telemetry [15:8] |
| `0x51` | `SC_STAT_LO` | R | `0x00` | Schmidl-Cox | Current SC metric numerator `|C[s]|^2` telemetry [7:0] |
| `0x52` | `COND_NUM_HI` | R | `0x00` | Grouper FW | Optional firmware diagnostic: channel condition number [15:8] |
| `0x53` | `COND_NUM_LO` | R | `0x00` | Grouper FW | Optional firmware diagnostic: channel condition number [7:0] |
| `0x54` | `SNR_0_HI` | R | `0x00` | Grouper FW | Optional firmware diagnostic: post-combining SNR [15:8] |
| `0x55` | `SNR_0_LO` | R | `0x00` | Grouper FW | Optional firmware diagnostic: post-combining SNR [7:0] |
| `0x56` | `NULL_QUALITY_HI` | R | `0x00` | Grouper FW | Optional null-steering diagnostic: post-combining noise power ratio [15:8] (see register detail) |
| `0x57` | `NULL_QUALITY_LO` | R | `0x00` | Grouper FW | Optional null-steering diagnostic: post-combining noise power ratio [7:0] |
| `0x58`–`0x5F` | — | — | — | — | Reserved; keep this page read-mostly live telemetry |
| **Training and Estimation** (`0x60`–`0x8F`) | | | | | |
| `0x60` | `TRAINING_STATUS` | R | `0x00` | Training Accumulator | [0] `TRAINING_DONE`; [1] `TRAINING_ARMED`; [7:2] reserved |
| `0x61` | `N_ACC_HI` | R | `0x00` | Training Accumulator | Samples accumulated [15:8] |
| `0x62` | `N_ACC_LO` | R | `0x00` | Training Accumulator | Samples accumulated [7:0] |
| `0x63` | `Z_SHIFT` | R | `0x00` | Training Accumulator | Common right shift applied to `Z_j` readback [5:0] |
| `0x64` | `C_POOL_I_HI` | R | `0x00` | Schmidl-Cox | Reserved SC phasor readback [15:8]; currently hardwired 0 |
| `0x65` | `C_POOL_I_LO` | R | `0x00` | Schmidl-Cox | Reserved SC phasor readback [7:0]; currently hardwired 0 |
| `0x66` | `C_POOL_Q_HI` | R | `0x00` | Schmidl-Cox | Reserved SC phasor readback [15:8]; currently hardwired 0 |
| `0x67` | `C_POOL_Q_LO` | R | `0x00` | Schmidl-Cox | Reserved SC phasor readback [7:0]; currently hardwired 0 |
| `0x68` | `CFO_DIAG_HI` | R | `0x00` | Schmidl-Cox | Coarse CFO diagnostic [15:8] |
| `0x69` | `CFO_DIAG_LO` | R | `0x00` | Schmidl-Cox | Coarse CFO diagnostic [7:0] |
| `0x6A` | `NOISE_WIN_CTRL` | R/W | `0x00` | Training Accumulator | [0] `NOISE_EN`: enable noise-window accumulation mode; [7:1] reserved |
| `0x6B` | `TACC_REF_SEL` | R/W | `0x00` | Training Accumulator | [1:0] reference branch selector for legacy single-ref path; [7:2] reserved |
| `0x6C` | `TACC_NOISE_TRIG` | W | `0x00` | Training Accumulator | [0] W1P: write 1 to arm accumulator for firmware-triggered noise measurement (ignores `sc_lock`). Accumulates for 8 symbols then asserts `TRAINING_DONE`. Off-diagonal `Z_kl` ≈ 0; diagonal `ZDIAG_k` ≈ σ²_k · n_acc. |
| `0x6D`–`0x6F` | — | — | — | — | Reserved for future training-derived metrics |
| `0x70`–`0x77` | `Z_01` | R | `0x00` | Training Accumulator | Pair (0,1) cross-correlation: I[31:0] at 0x70–0x73, Q[31:0] at 0x74–0x77. Z_01 = Σ raw_0[n]·conj(raw_1[n]). |
| `0x78`–`0x7F` | `Z_02` | R | `0x00` | Training Accumulator | Pair (0,2): I at 0x78–0x7B, Q at 0x7C–0x7F |
| `0x80`–`0x87` | `Z_03` | R | `0x00` | Training Accumulator | Pair (0,3): I at 0x80–0x83, Q at 0x84–0x87 |
| `0x88`–`0x8F` | `Z_12` | R | `0x00` | Training Accumulator | Pair (1,2): I at 0x88–0x8B, Q at 0x8C–0x8F |
| **Active Weight / Shadow Bank Interface** (`0x90`–`0x9F`) | | | | | |
| `0x90` | `W_0_RE_HI` | R/W | `0x00` | MRC Combiner | Branch 0 real [15:8], int16 Q1.15 |
| `0x91` | `W_0_RE_LO` | R/W | `0x00` | MRC Combiner | Branch 0 real [7:0] |
| `0x92` | `W_0_IM_HI` | R/W | `0x00` | MRC Combiner | Branch 0 imag [15:8] |
| `0x93` | `W_0_IM_LO` | R/W | `0x00` | MRC Combiner | Branch 0 imag [7:0] |
| `0x94` | `W_1_RE_HI` | R/W | `0x00` | MRC Combiner | Branch 1 real [15:8] |
| `0x95` | `W_1_RE_LO` | R/W | `0x00` | MRC Combiner | Branch 1 real [7:0] |
| `0x96` | `W_1_IM_HI` | R/W | `0x00` | MRC Combiner | Branch 1 imag [15:8] |
| `0x97` | `W_1_IM_LO` | R/W | `0x00` | MRC Combiner | Branch 1 imag [7:0] |
| `0x98` | `W_2_RE_HI` | R/W | `0x00` | MRC Combiner | Branch 2 real [15:8] |
| `0x99` | `W_2_RE_LO` | R/W | `0x00` | MRC Combiner | Branch 2 real [7:0] |
| `0x9A` | `W_2_IM_HI` | R/W | `0x00` | MRC Combiner | Branch 2 imag [15:8] |
| `0x9B` | `W_2_IM_LO` | R/W | `0x00` | MRC Combiner | Branch 2 imag [7:0] |
| `0x9C` | `W_3_RE_HI` | R/W | `0x00` | MRC Combiner | Branch 3 real [15:8] |
| `0x9D` | `W_3_RE_LO` | R/W | `0x00` | MRC Combiner | Branch 3 real [7:0] |
| `0x9E` | `W_3_IM_HI` | R/W | `0x00` | MRC Combiner | Branch 3 imag [15:8] |
| `0x9F` | `W_3_IM_LO` | R/W | `0x00` | MRC Combiner | Branch 3 imag [7:0] |
| **Calibration Coefficients** (`0xA0`–`0xAF`) — **REMOVED** | | | | | |
| `0xA0`–`0xAF` | — | — | — | — | Reserved. Calibration coefficients (`CAL_j`) are not stored in the Trouper register bank in this revision. Grouper firmware or host software owns the active coefficient image. |
| **External Memory / Radio Sideband Control** (`0xB0`–`0xBF`) | | | | | |
| `0xB0` | `PSRAM_CTRL` | R/W | `0x00` | PSRAM Buffer | [0] `PSRAM_EN`; [1] `PSRAM_CLR_ERR`; [2] `SAMPLE_WIDTH`; [3] `QSPI_OWNER`; [7:4] reserved |
| `0xB1` | `PSRAM_STATUS` | R | `0x00` | PSRAM Buffer | [2:0] state; [3] `INIT_DONE`; [4] `REPLAY_ACTIVE`; [5] `REPLAY_MISSED`; [6] `OVERFLOW`; [7] `PAD_CONFLICT` |
| `0xB2` | `PSRAM_PKT_BYTES_HI` | R | `0x00` | PSRAM Buffer | Current packet bytes written to PSRAM [15:8] |
| `0xB3` | `PSRAM_PKT_BYTES_LO` | R | `0x00` | PSRAM Buffer | Current packet bytes written to PSRAM [7:0] |
| `0xB4` | `PSRAM_RD_OFFSET` | R | `0x00` | PSRAM Buffer | Replay start offset low 8 bits |
| `0xB5` | — | — | — | — | Reserved (legacy Trouper SPI-master window removed) |
| `0xB6` | — | — | — | — | Reserved (legacy Trouper SPI-master window removed) |
| `0xB7` | — | — | — | — | Reserved (legacy Trouper SPI-master window removed) |
| `0xB8` | — | — | — | — | Reserved (legacy Trouper SPI-master window removed) |
| `0xB9`–`0xBF` | — | — | — | — | Reserved for off-chip interface growth |
| **Bring-Up / Debug / BIST Observability** (`0xC0`–`0xCF`) | | | | | |
| `0xC0` | `SC_DBG_FLAGS` | R | `0x00` | Schmidl-Cox | [0] `SC_HIT`; [2:1] hit counter; [3] `SC_LOCK`; [7:4] reserved |
| `0xC1` | `SC_DBG_RSVD` | R | `0x00` | Schmidl-Cox | Reserved for future SC bring-up status |
| `0xC2` | `SC_FIRST_HIT_3` | R | `0x00` | Schmidl-Cox | First-hit sample-count snapshot [31:24] |
| `0xC3` | `SC_FIRST_HIT_2` | R | `0x00` | Schmidl-Cox | First-hit sample-count snapshot [23:16] |
| `0xC4` | `SC_FIRST_HIT_1` | R | `0x00` | Schmidl-Cox | First-hit sample-count snapshot [15:8] |
| `0xC5` | `SC_FIRST_HIT_0` | R | `0x00` | Schmidl-Cox | First-hit sample-count snapshot [7:0] |
| `0xC6` | `SC_LOCK_SNAP_3` | R | `0x00` | Schmidl-Cox | Lock sample-count snapshot [31:24] |
| `0xC7` | `SC_LOCK_SNAP_2` | R | `0x00` | Schmidl-Cox | Lock sample-count snapshot [23:16] |
| `0xC8` | `SC_LOCK_SNAP_1` | R | `0x00` | Schmidl-Cox | Lock sample-count snapshot [15:8] |
| `0xC9` | `SC_LOCK_SNAP_0` | R | `0x00` | Schmidl-Cox | Lock sample-count snapshot [7:0] |
| `0xCA` | `SRAM_DUMP_CTRL` | R/W | `0x00` | Frontend Buffer | [0] `SRAM_DUMP_START` (write 1 to enter dump mode; only accepted in Locked state); [1] `SRAM_DUMP_DONE` (read-only; 1 = result valid) |
| `0xCB` | `SRAM_DUMP_ADDR_HI` | R/W | `0x00` | Frontend Buffer | [0] byte address bit [8]; [1] macro select (0=SRAM0, 1=SRAM1); [7:2] reserved |
| `0xCC` | `SRAM_DUMP_ADDR_LO` | R/W | `0x00` | Frontend Buffer | Byte address bits [7:0] (0–255 within each 256-byte half of the 512 B macro) |
| `0xCD` | `SRAM_DUMP_DATA` | R | `0x00` | Frontend Buffer | Byte at `{DUMP_ADDR_HI[1], DUMP_ADDR_HI[0], DUMP_ADDR_LO}` in selected macro; valid after `SRAM_DUMP_DONE=1` |
| `0xCE`–`0xCF` | — | — | — | — | Reserved for bring-up-only observability |
| **Training (continued) / Reserved** (`0xD0`–`0xDF`) | | | | | |
| `0xD0`–`0xD3` | — | — | — | — | Reserved (was NFE_CTRL/STATUS/THRESH; hardware `noise_floor_est` removed — firmware owns sigma2 EMA in CPU SRAM) |
| `0xD4`–`0xDB` | `Z_13` | R | `0x00` | Training Accumulator | Pair (1,3): I at 0xD4–0xD7, Q at 0xD8–0xDB. Big-endian int32. |
| `0xDC`–`0xDF` | — | — | — | — | Reserved |
| **Z_23 Pair and Z_kk Diagonal** (`0xE0`–`0xEF`) | | | | | |
| `0xE0`–`0xE7` | `Z_23` | R | `0x00` | Training Accumulator | Pair (2,3): I[31:0] at 0xE0–0xE3 (via sigma2_hw_0..1 ports), Q[31:0] at 0xE4–0xE7 (sigma2_hw_2..3). Replaces former sigma2_hw estimate addresses (sigma2_hw was always 0). |
| `0xE8`–`0xE9` | `ZDIAG_0_HI` | R | `0x00` | Training Accumulator | Branch 0 diagonal Z_kk = Σ\|raw_0\|² top 16 bits [31:16]. In noise mode: ≈ σ²_0 · n_acc. |
| `0xEA`–`0xEB` | `ZDIAG_1_HI` | R | `0x00` | Training Accumulator | Branch 1 diagonal [31:16] |
| `0xEC`–`0xED` | `ZDIAG_2_HI` | R | `0x00` | Training Accumulator | Branch 2 diagonal [31:16] |
| `0xEE`–`0xEF` | `ZDIAG_3_HI` | R | `0x00` | Training Accumulator | Branch 3 diagonal [31:16] |
| **Reserved** (`0xF0`–`0xFF`) | | | | | |
| `0xF0`–`0xFF` | — | — | — | — | Reserved (was SIGMA2 software override bank; NFE removed — firmware maintains sigma2 estimates in CPU SRAM) |

---

## Register details

### `0x00` — CHIP_ID (read-only)

Fixed identification value. First register read during bring-up to confirm SPI communication.

| Bits | Field | Description |
| --- | --- | --- |
| [7:0] | `ID` | Always `0xA7` |

---

### `0x01` — CHIP_REV (read-only)

Silicon revision.

| Bits | Field | Description |
| --- | --- | --- |
| [7:0] | `REV` | `0x01` for first tapeout |

---

### `0x02` — Reserved (legacy `CPU_RESET`)

Trouper has no local CPU reset control in the current revision. Address `0x02` is reserved; reads return `0x00` and writes are ignored. Any Grouper firmware boot/reset sequencing is handled in the Grouper project, not through the Trouper register bank.

---

### `0x03` — DEBUG_CTRL (read/write)

Controls JTAG debug mode for the four dual-function pads (`TCK_IRQ`, `TMS_GPIO0`, `TDI_GPIO1`, `TDO_GPIO2`).

| Bits | Field | Description |
| --- | --- | --- |
| [0] | `JTAG_EN` | 0 = normal mode (IRQ + GPIO), 1 = 4-pin JTAG mode |
| [7:1] | — | Reserved, write 0 |

Mode switch procedure: RPi reconfigures its `TCK_IRQ` GPIO as input before writing `JTAG_EN=1` to avoid contention. On debug exit, RPi writes `JTAG_EN=0` and restores rising-edge IRQ input mode. While `JTAG_EN=1`, `GPIO_DIR`, `GPIO_OUT`, and `GPIO_IN` are ignored; RPi must poll `IRQ_STATUS` via SPI instead of relying on the pad IRQ.

---

### `0x04` — GPIO_DIR (read/write)

Direction register for GPIO_0-2. Has no effect when `JTAG_EN=1`.

| Bits | Field | Description |
| --- | --- | --- |
| [0] | `GPIO0_DIR` | Direction for `TMS_GPIO0` |
| [1] | `GPIO1_DIR` | Direction for `TDI_GPIO1` |
| [2] | `GPIO2_DIR` | Direction for `TDO_GPIO2` |
| [7:3] | — | Reserved, write 0 |

---

### `0x05` — GPIO_OUT (read/write)

Output drive value for GPIO_0-2 when `GPIO_DIR` is output and `JTAG_EN=0`.

| Bits | Field | Description |
| --- | --- | --- |
| [0] | `GPIO0_OUT` | Drive value for `TMS_GPIO0` |
| [1] | `GPIO1_OUT` | Drive value for `TDI_GPIO1` |
| [2] | `GPIO2_OUT` | Drive value for `TDO_GPIO2` |
| [7:3] | — | Reserved, write 0 |

---

### `0x06` — GPIO_IN (read-only)

Sampled input values for GPIO_0-2.

| Bits | Field | Description |
| --- | --- | --- |
| [0] | `GPIO0_IN` | Sampled input on `TMS_GPIO0` |
| [1] | `GPIO1_IN` | Sampled input on `TDI_GPIO1` |
| [2] | `GPIO2_IN` | Sampled input on `TDO_GPIO2` |
| [7:3] | — | Returns 0 |

---

### `0x07` — CPU_SRAM_CTRL ~~(read/write)~~ — **DEPRECATED, REGISTER REMOVED**

> **DEPRECATED — DO NOT IMPLEMENT**
>
> The CPU SRAM borrow path is removed. The block-based fixed-L=256 frontend buffer
> fits in one 512×8 SRAM for all SFs. Register `0x07` is now reserved (reads 0x00,
> writes ignored). `CPU_SRAM_STATUS` (0x08) is similarly removed — see below.

Control register for the optional CPU-SRAM borrow path used by the Frontend Buffer Controller.

`CPU_SRAM_BORROW_EN` does not by itself guarantee that borrowed sample memory will be used. The borrow path is legal only when:

- the reserved upper `1 kB` bank (`BANK3`) is excluded from the linker/runtime-visible PicoRV32 memory map
- `CPU_SRAM_BORROW_BANK_PASS=1`
- the selected borrow mode is compatible with the current CPU state

| Bits | Field | Description |
| --- | --- | --- |
| [0] | `CPU_SRAM_BORROW_EN` | 1 = allow the Frontend Buffer Controller to use the reserved upper `1 kB` CPU SRAM bank when legal; 0 = dedicated frontend SRAM only |
| [1] | `CPU_SRAM_SHARED_BORROW_EN` | 1 = shared borrow is allowed while `CPU_RESET=0`; the frontend has absolute priority on the borrowed bank, Pico stalls on contention, and Pico must not disturb borrowed sample storage. 0 = borrow is legal only while `CPU_RESET=1` |
| [7:2] | — | Reserved |

---

### `0x08` — CPU_SRAM_STATUS ~~(read-only)~~ — **DEPRECATED, REGISTER REMOVED**

> **DEPRECATED** — removed along with `CPU_SRAM_CTRL`. Register `0x08` is reserved.

Status and BIST qualification for the fixed-bank CPU SRAM partition:

- `BANK0` `0x0000`-`0x03FF`
- `BANK1` `0x0400`-`0x07FF`
- `BANK2` `0x0800`-`0x0BFF`
- `BANK3` `0x0C00`-`0x0FFF` reserved as `CPU_SRAM_BORROW_BANK`

| Bits | Field | Description |
| --- | --- | --- |
| [0] | `CPU_SRAM_BANK0_PASS` | 1 = firmware-visible `BANK0` passed BIST |
| [1] | `CPU_SRAM_BANK1_PASS` | 1 = firmware-visible `BANK1` passed BIST |
| [2] | `CPU_SRAM_BANK2_PASS` | 1 = firmware-visible `BANK2` passed BIST |
| [3] | `CPU_SRAM_BORROW_BANK_PASS` | 1 = reserved `BANK3` passed BIST and is eligible for live sample buffering |
| [4] | `CPU_SRAM_BORROW_AVAIL` | 1 = borrow path is currently legal under the documented enable, BIST, linker, and CPU-state rules |
| [5] | `CPU_SRAM_BORROW_ACTIVE` | 1 = Frontend Buffer Controller is actively using the reserved borrow bank |
| [7:6] | — | Reserved |

---

### `0x10` — MIMO_CTRL (read/write)

| Bits | Field | Description |
| --- | --- | --- |
| [0] | `MODE` | 0 = MRC NR=4 (default); 1 = passthrough |
| [1] | — | Reserved, write 0 |
| [3:2] | — | Reserved, write 0 |
| [7:4] | `ANTENNA_EN` | One bit per antenna; default `0xF0` (all enabled) |

`MODE=1` bypasses the MRC path and routes the lowest-numbered enabled antenna directly to the output path. Writes to `MODE` and `ANTENNA_EN` update shadow configuration during an active packet; hardware latches `ACTIVE_MODE` and `ACTIVE_ANTENNA_EN` only when the receiver is idle between packets.

---

### `0x11` — SF_CFG (read/write)

Spreading-factor selection for the non-FFT receive path.

| Bits | Field | Description |
| --- | --- | --- |
| [2:0] | `sf` | 0 = SF5 (M=32) ... 7 = SF12 (M=4096) |
| [7:3] | — | Reserved, write 0 |

This configures `M = 2^SF` for the frontend buffer, SC detector, training accumulator, and packet-control timing arithmetic.

---

### `0x12` — DECIM_CFG (read/write)

| Bits | Field | Description |
| --- | --- | --- |
| [1:0] | `DECIM_RATIO` | 0 = 32x (1 MHz), 1 = 64x (500 kHz), 2 = 128x (250 kHz), 3 = 256x (125 kHz) |
| [7:2] | — | Reserved, write 0 |

---

### `0x13` — FRONTEND_CFG (read/write)

| Bits | Field | Description |
| --- | --- | --- |
| [0] | — | Reserved (was `STORE_W`; storage width fixed at 8-bit) |
| [1] | `BIST_RUN` | Write 1 to trigger frontend SRAM BIST; self-clears |
| [7:2] | — | Reserved |

### `0x14` — FRONTEND_STATUS (read-only)

| Bits | Field | Description |
| --- | --- | --- |
| [1:0] | `BUF_MODE` | 0=idle, 1=acquiring, 2=frozen, 3=post-lock |
| [2] | `BUF_VALID` | Buffer has at least M valid samples |
| [3] | `SRAM0_BIST_PASS` | BIST pass flag for SRAM0 |
| [4] | `SRAM1_BIST_PASS` | BIST pass flag for SRAM1 |
| [5] | `BUF_FREEZE` | Frontend buffer currently frozen |
| [7:6] | — | Reserved |

### `0x15` — BUF_WR_PTR (read-only)

| Bits | Field | Description |
| --- | --- | --- |
| [6:0] | `BUF_WR_PTR` | Current frontend-buffer write pointer mod 128 |
| [7] | `BUF_FREEZE` | Mirror of freeze state |

### `0x16` — PKT_TIMEOUT_SYMS (read/write)

Maximum packet duration in LoRa symbols before the Packet Control FSM forces a return to `IDLE`.

---

### `0x20`–`0x2A` — RX gain shadow/active control and TX gain

`RX_GAIN_SHADOW_n` holds the desired SX1257 `RegRxAnaGain (0x0C)` value for branch `n` in software-visible form.

`RX_GAIN_ACTIVE_n` is a software-maintained mirror of the live value believed to be active on the external SX1257. Trouper itself does not issue the AFE write in this revision.

Bit layout of each RX gain byte:

- `[7:5]` `RxLnaGain` (`1=G1` max gain, `6=G6` min gain)
- `[4:1]` `RxBbGain` (0-15, 2 dB per step)
- `[0]` `LnaZin` (keep 0 for 50 ohm)

Reset value `0x3E` gives maximum-gain fallback for CPU-less RX-only mode.

Commit model:

- host or Grouper firmware writes `RX_GAIN_SHADOW_n`
- software that owns the external AFE control path applies the corresponding SX1257 writes out of band
- software MAY then update `RX_GAIN_ACTIVE_n` as a mirror for Trouper-side observability
- `RX_GAIN_CTRL.RX_GAIN_COMMIT` is retained only as a software handshake/debug pulse in the current revision; it does not trigger an on-chip SPI sequence

### `0x2A` — RX_GAIN_CTRL (read/write)

| Bits | Field | Description |
| --- | --- | --- |
| [0] | `RX_GAIN_COMMIT` | Write-1 pulse for software bookkeeping after updating `RX_GAIN_SHADOW_n` / external AFE state |
| [3:1] | — | Reserved |
| [7:4] | — | Reserved |

`TX_GAIN_n` remains direct programmer-visible TX-path state and does not currently use a shadow/active scheme.

---

### `0x30` — ACTIVE_MODE (read-only)

Current active mode: 0 = MRC, 1 = passthrough. Latched at the packet-safe idle boundary from `MIMO_CTRL.MODE`.

### `0x31` — ACTIVE_ANTENNA_EN (read-only)

Latched antenna-enable mask used by the live packet.

### `0x32` — IRQ_STATUS (read-only)

Sticky interrupt source bits.

| Bit | Field | Meaning |
| --- | --- | --- |
| [0] | `CORR_LOCK` | Schmidl-Cox detected preamble; Packet Control FSM entered `PREAMBLE_ACQ` |
| [1] | `TRAINING_DONE` | Training accumulator complete; software path may inspect `Z_j` |
| [2] | `W_MISSED_PACKET` | W was not committed before safe switch; current packet remains bypass |
| [3] | `PACKET_DONE` | Packet Control FSM returned to `IDLE` |
| [4] | `NOISE_READY` | Noise-window accumulation complete; firmware may read Z_kl and commit null weights |
| [6:5] | — | Reserved (was TX_PREP/TX_DONE; TX not supported) |
| [7] | — | Reserved |

### `0x33` — IRQ_CLEAR (write-only)

Write 1s to clear corresponding `IRQ_STATUS` bits. Writing 0 leaves a bit unchanged.

### `0x34` — PACKET_STATUS (read-only)

| Bits | Field | Description |
| --- | --- | --- |
| [0] | `PACKET_ACTIVE` | Packet FSM is not idle |
| [3:1] | `PACKET_PHASE` | 0=IDLE, 1=PREAMBLE_ACQ, 2=W_PENDING, 3=PAYLOAD_ACTIVE |
| [4] | `TRAINING_DONE` | Training accumulator complete this packet |
| [5] | `W_PENDING` | Training is done and W commit is pending |
| [6] | `W_VALID` | `W_ACTIVE` is valid for the current packet |
| [7] | `W_MISSED_PACKET` | W missed the current packet safe-switch point |

### `0x35` — WGT_CTRL (read/write)

Weight-path commit control and status. `WGT_SRC`, `WGT_AUTO_COMMIT`, and `WGT_MODE` are removed — the hardware weight-generation block no longer exists. Firmware is the sole weight source and always uses the software commit path.

`W_COMMIT` is pulsed by Grouper firmware or the host (via SPI) after writing the `0x90`-`0x9F` W shadow bank. Reset value `0x00`.

| Bits | Field | Description |
| --- | --- | --- |
| [0] | `W_COMMIT` | Write-1 pulse after W shadow writes complete |
| [1] | `W_VALID` | Read-only: active W bank is valid for the current packet |
| [2] | `W_PENDING` | Read-only: training done but W commit not yet received |
| [3] | `W_MISSED_PACKET` | Read-only: W was not committed before safe-switch; current packet stayed bypass |
| [7:4] | — | Reserved |

---

### `0x36` — COMB_POST_GAIN (read/write)

Post-combine gain control for the MRC combiner. The combiner first applies its fixed guard divide-by-2, then left-shifts by this value before int8 saturation. Firmware should update this packet-to-packet; reset value `0` is the safe default.

| Bits | Field | Description |
| --- | --- | --- |
| [2:0] | `COMB_POST_GAIN_SHIFT` | 0-7 bit left shift applied after the fixed guard divide-by-2 |
| [7:3] | — | Reserved, read as zero |

Reset value `0x00` is conservative. Firmware/host may increase this after observing output headroom.

---

### `0x40`–`0x47` — ENERGY[0..3] (read-only)

Per-antenna `Z_kk = Σ|raw_k[n]|²` latched at `training_done` from the Training Accumulator diagonal. Int16 unsigned (top 16 bits of the 32-bit accumulator). Replaces the former standalone Energy Measurement block — firmware reads these for AGC after `IRQ_TRAINING_DONE`. Note: `SC_CFG.ENERGY_GATE_EN` (pre-lock energy gating) is no longer supported without a dedicated pre-lock energy path; set to 0.

### `0x48`–`0x4F` — CORR_MAG[0..3] (read-only)

Reserved for future per-branch SC autocorrelation magnitude readback. In the current `trouper_top` integration all four fields are tied to `16'd0`, so firmware should treat them as unavailable telemetry until the detector outputs are wired through.

### `0x50`–`0x51` — SC_STAT (read-only)

Current Schmidl-Cox metric numerator telemetry from the detector. This is the exposed `|C[s]|^2` snapshot (`sym_mag_sc[27:13]` plus a zero LSB), not a normalised `Lambda^2[s]` value.

---

### `0x60`–`0x69` — Training diagnostics (read-only)

These registers expose training-window bookkeeping and placeholder SC diagnostics:

- `TRAINING_STATUS`
- `N_ACC`
- `Z_SHIFT`
- `C_POOL` (currently hardwired zero in `trouper_top`)
- `CFO_DIAG`

### `0x56`–`0x57` — NULL_QUALITY (read-only, firmware-written)

Optional null-steering quality diagnostic. Firmware computes this after committing null weights and writes it as a firmware-visible register (same mechanism as `COND_NUM` / `SNR_0`). Holds the ratio of post-combining noise power without null vs with null applied, expressed as an unsigned int16 fixed-point value (Q8.8 — values >256 indicate >0 dB null improvement).

A value of `0x0000` means the null steering firmware has not yet run. Firmware should reset this to zero if `NOISE_EN` is cleared.

---

### `0x6A` — NOISE_WIN_CTRL (read/write)

Controls noise-window accumulation in the training accumulator.

| Bits | Field | Description |
| --- | --- | --- |
| [0] | `NOISE_EN` | Legacy flag retained for firmware compatibility; [7:1] reserved |

---

### `0x6B` — TACC_REF_SEL (read/write)

| Bits | Field | Description |
| --- | --- | --- |
| [1:0] | `REF_SEL` | Reference branch index for the legacy single-ref path (0–3). Not used in the all-pairs cross-correlator path. |
| [7:2] | — | Reserved |

---

### `0x6C` — TACC_NOISE_TRIG (write-only, W1P)

Firmware-triggered noise measurement. Writing bit 0 = 1 arms the training accumulator without waiting for `sc_lock`. The accumulator resets all internal state and immediately begins accumulating the next `8 × 2^SF` samples. `TRAINING_DONE` fires on completion.

In noise mode (no signal): off-diagonal `Z_kl ≈ 0` (uncorrelated noise); diagonal `ZDIAG_k ≈ σ²_k · n_acc`.

Firmware EMA flow:
1. Write `0x6C ← 0x01` during idle (no packet in progress)
2. Poll `TRAINING_STATUS.TRAINING_DONE`
3. Read `ZDIAG_k` at 0xE8–0xEF (top 16 bits) for all branches
4. Update per-branch EMA: `sigma2_k ← (1-α)·sigma2_k + α · ZDIAG_k[31:16] / n_acc`

This replaces the former `noise_est.v` Manhattan-norm flow which required a dedicated pre-lock measurement period.

---

### `0x70`–`0x8F` — Z_kl pair readback, pairs 0–3 (read-only)

All C(4,2)=6 branch-pair cross-correlations from the training accumulator. Values are signed int32, big-endian. Use `Z_SHIFT` (0x63) for firmware scaling.

Firmware eigenvector path: read all 6 Z_kl pairs, build the 4×4 Hermitian matrix `Z`, take the principal eigenvector `eigh(Z)[:,-1]` as the MRC weight direction. This achieves near-ideal diversity gain and is significantly better than the W_k row-sum (hardware path) which mixes channel estimates.

| Addresses | Name | Description |
| --- | --- | --- |
| `0x70`–`0x73` | `Z_01_I` | Pair (0,1) real part Σ raw_0·conj(raw_1), int32 |
| `0x74`–`0x77` | `Z_01_Q` | Pair (0,1) imaginary part |
| `0x78`–`0x7B` | `Z_02_I` | Pair (0,2) real part |
| `0x7C`–`0x7F` | `Z_02_Q` | Pair (0,2) imaginary part |
| `0x80`–`0x83` | `Z_03_I` | Pair (0,3) real part |
| `0x84`–`0x87` | `Z_03_Q` | Pair (0,3) imaginary part |
| `0x88`–`0x8B` | `Z_12_I` | Pair (1,2) real part |
| `0x8C`–`0x8F` | `Z_12_Q` | Pair (1,2) imaginary part |

Pairs Z_13 and Z_23 are at `0xD4`–`0xDB` and `0xE0`–`0xE7` respectively. The conjugate `Z_lk = conj(Z_kl)` is implied by Hermitian symmetry — firmware reconstructs the full 4×4 matrix from these 6 unique values.

Note: the register bank exposes the individual Z_kl pairs for firmware use. Firmware builds the 4×4 Hermitian matrix from these 6 unique off-diagonal values plus the Z_kk diagonals and computes weights in software.

---

### `0x90`–`0x9F` — W vector (read/write)

MRC weight vector `w` (4 complex coefficients, int16 Q1.15). Written by Grouper firmware or a host-assisted path after computing weights from the Z_kl pairs. These locations hold the shadow bank; the live combiner reads only `W_ACTIVE`.

`W_ACTIVE` updates atomically after `WGT_CTRL.W_COMMIT` is pulsed and the Packet Control FSM reaches an idle boundary.

### `0xA0`–`0xAF` — Calibration coefficients — **REMOVED**

Removed from the register bank. Grouper firmware or host software owns the active `cal_j` coefficient image outside Trouper. No hardware path in Trouper reads these values directly.

---

### `0xB0` — PSRAM_CTRL (read/write)

| Bits | Field | Description |
| --- | --- | --- |
| [0] | `PSRAM_EN` | 0 = disabled (default); 1 = enable optional same-packet PSRAM buffering/replay |
| [1] | `PSRAM_CLR_ERR` | Write 1 to clear sticky PSRAM error flags (`OVERFLOW`, `REPLAY_MISSED`); self-clears |
| [2] | `SAMPLE_WIDTH` | 0 = 16-bit I/Q storage (default, max f_s = 1 MS/s); 1 = 32-bit I/Q storage (max f_s = 500 kS/s) |
| [3] | `QSPI_OWNER` | 0 = Trouper `psram_buf_ctrl` owns the APS6404L pads for capture/replay (default); 1 = ownership transferred away from the replay controller for a future firmware-managed external-memory mode. Ownership changes take effect only when the PSRAM controller is idle. |
| [7:4] | — | Reserved |

### `0xB1`–`0xB4` — PSRAM replay status (read-only)

Only meaningful when `PSRAM_CTRL.QSPI_OWNER=0` and `PSRAM_CTRL.PSRAM_EN=1`. Exposes the optional same-packet replay controller state and coarse pointer snapshots. When `QSPI_OWNER=1`, BUFFERING/REPLAY is suspended and the off-chip memory interface is reserved for a future firmware-managed access mode.

### `0xB5`–`0xB8` — Reserved legacy SPI-master window

These addresses are reserved in the current revision. The earlier Trouper-local `SX_TARGET` / `SX_ADDR` / `SX_DATA` / `SX_CTRL` pass-through path was removed along with the on-chip AFE SPI master. Any SX1257 configuration now happens outside Trouper.

### `0xC0`–`0xC9` — SC Bring-Up Debug (read-only)

Optional Schmidl-Cox debug visibility intended primarily for FPGA and first-silicon bring-up.

- `SC_DBG_FLAGS` (`0xC0`)
  current raw threshold result, hit-counter state, and current `SC_LOCK`
- `SC_FIRST_HIT_[3:0]` (`0xC2`-`0xC5`)
  32-bit free-running `iq_valid` sample-count snapshot taken at the first qualifying hit of the eventual lock sequence
- `SC_LOCK_SNAP_[3:0]` (`0xC6`-`0xC9`)
  32-bit free-running `iq_valid` sample-count snapshot taken when `sc_lock` asserts

These registers are debug aids, not part of the normal packet-processing control path.

### `0xD0`–`0xD3` — **REMOVED** (was NFE_CTRL / NFE_STATUS / NOISE_THRESH)

Hardware `noise_floor_est` block removed. Firmware maintains per-branch sigma2 EMA in CPU SRAM using `ZDIAG_k` readback from the training accumulator (see `0xE8`–`0xEF`). These addresses are reserved.

### `0xE0`–`0xE7` — Z_23 pair readback (read-only)

Pair (2,3) cross-correlation: I[31:0] at 0xE0–0xE3, Q[31:0] at 0xE4–0xE7. These addresses formerly held `sigma2_hw` estimates (always zero); repurposed for Z_23.

### `0xE8`–`0xEF` — Z_kk diagonal autocorrelation (read-only)

Per-branch `Zdiag_k = Σ|raw_k[n]|²` over the training window. Top 16 bits of the 32-bit accumulator, sufficient for firmware noise EMA.

| Addresses | Field | Description |
| --- | --- | --- |
| `0xE8`–`0xE9` | `ZDIAG_0` | Branch 0 Σ\|raw_0\|² [31:16] |
| `0xEA`–`0xEB` | `ZDIAG_1` | Branch 1 Σ\|raw_1\|² [31:16] |
| `0xEC`–`0xED` | `ZDIAG_2` | Branch 2 Σ\|raw_2\|² [31:16] |
| `0xEE`–`0xEF` | `ZDIAG_3` | Branch 3 Σ\|raw_3\|² [31:16] |

In normal signal mode: `ZDIAG_k ≈ (|h_k|² + σ²_k) · n_acc`.
In noise mode (triggered by `TACC_NOISE_TRIG`): `ZDIAG_k ≈ σ²_k · n_acc`.

### `0xF0`–`0xFF` — **REMOVED** (was SIGMA2 software override bank)

Removed along with the hardware NFE block. Firmware maintains sigma2 estimates in CPU SRAM. These addresses are reserved.

---

## Address range reservations

| Range | Block |
| --- | --- |
| `0x00`–`0x0F` | Global / CPU / debug |
| `0x10`–`0x1F` | RX front-end configuration |
| `0x20`–`0x2F` | Gain / AGC / SX1257 live RX control |
| `0x30`–`0x3F` | Packet / weight-path control |
| `0x40`–`0x5F` | Runtime measurement and live observability |
| `0x60`–`0x8F` | Training and estimation (Z_01–Z_12 pairs at 0x70–0x8F) |
| `0x90`–`0x9F` | Active weight / shadow bank interface |
| `0xA0`–`0xAF` | Reserved (calibration coefficients moved to CPU SRAM) |
| `0xB0`–`0xBF` | External memory / radio sideband control |
| `0xC0`–`0xCF` | Bring-up / debug / BIST observability |
| `0xD0`–`0xD3` | Reserved (NFE removed); `0xD4`–`0xDB` Z_13 pair; `0xDC`–`0xDF` reserved |
| `0xE0`–`0xEF` | Z_23 pair (0xE0–0xE7); Z_kk diagonal (0xE8–0xEF) |
| `0xF0`–`0xFF` | Reserved (SIGMA2 override bank removed — NFE removed) |
