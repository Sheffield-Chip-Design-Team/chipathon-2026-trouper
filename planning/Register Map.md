# Register Map

Internal registers accessible through two primary control paths:
1.  **Trouper Host SPI Slave:** Dedicated interface for external host access (RPi SPI0 CS1).
2.  **Grouper Register Bus (`GRP_*`):** Inter-project bus for Grouper firmware access (priority over SPI).

This file is the authoritative register-map source for the non-FFT LoRa-MIMO architecture. All addresses below are final for the current planning set. There are no legacy aliases or compatibility mappings.

## Addressing constraint — 7-bit register space

The host SPI frame carries the register address in a single command byte: **bit [7] = R/W# (1 = read, 0 = write), bits [6:0] = register address**. The entire register map therefore lives in `0x00`–`0x7F` (128 slots). This is a hard constraint — new registers must fit in the reserved slots listed below; there is no bank-select or extended-address mechanism.

- All registers are 8-bit. Multi-byte values are big-endian (MSB at lower address).
- Addresses not listed here return `0x00` on read and ignore writes.
- **`0x7F` is permanently reserved** and must never be implemented as a register: the command byte `0x7F` (a write to `0x7F`) is held back as a future protocol-escape code.
- **Burst access:** while `HOST_CS` stays low after the data byte, each additional data byte accesses the next consecutive address (auto-increment, wrapping modulo 128). Exception: `PSRAM_DBG_DATA` (`0x76`) does not auto-increment — repeated bytes re-read the same data port.

---

## Address map

| Address | Name | R/W | Reset | Block | Description |
| --- | --- | --- | --- | --- | --- |
| **Global / IRQ / Debug** (`0x00`–`0x07`) | | | | | |
| `0x00` | `CHIP_ID` | R | `0xA7` | — | Chip identification byte |
| `0x01` | `CHIP_REV` | R | `0x01` | — | Silicon revision |
| `0x02` | `IRQ_STATUS` | R | `0x00` | IRQ | Sticky interrupt source bits |
| `0x03` | `IRQ_CLEAR` | W | `0x00` | IRQ | Write 1 to clear matching `IRQ_STATUS` bits |
| `0x04` | — | — | `0x00` | — | Reserved (former `DEBUG_CTRL`/`JTAG_EN`; JTAG removed, no TAP in RTL) |
| `0x05` | — | — | `0x00` | — | Reserved (former `GPIO_DIR`; GPIO removed) |
| `0x06` | — | — | `0x00` | — | Reserved (former `GPIO_OUT`; GPIO removed) |
| `0x07` | — | — | `0x00` | — | Reserved (former `GPIO_IN`; GPIO removed) |
| **RX / Modem Configuration** (`0x08`–`0x0F`) | | | | | |
| `0x08` | `MIMO_CTRL` | R/W | `0xF0` | Control | [0] `MODE` (0=MRC, 1=passthrough); [7:4] `ANTENNA_EN` |
| `0x09` | `SF_CFG` | R/W | `0x07` | Packet timing | [3:0] spreading factor, direct-coded (7–12); write ignored while `PACKET_ACTIVE` |
| `0x0A` | `BW_CFG` | R/W | `0x00` | ΣΔ Decimator | [0] `bw_sel` LoRa bandwidth (0 = 250 kHz, 1 = 125 kHz); write ignored while `PACKET_ACTIVE` |
| `0x0B` | `PKT_TIMEOUT_SYMS` | R/W | `0x50` | Packet Control FSM | Packet timeout in LoRa symbols |
| `0x0C` | `SC_THR_HI` | R/W | `0x01` | Schmidl-Cox | Detection threshold [15:8]. RTL consumes bits [11:0] only — values ≥ `0x1000` are unsupported. |
| `0x0D` | `SC_THR_LO` | R/W | `0xCC` | Schmidl-Cox | Detection threshold [7:0] |
| `0x0E` | `SC_HITS_REQ` | R/W | `0x02` | Schmidl-Cox | Consecutive SC hits required for `sc_lock`, valid range 1-3 |
| `0x0F` | `COMB_CFG` | R/W | `0x10` | MRC Combiner / Re-mod | [2:0] `COMB_POST_GAIN_SHIFT`; [5:4] `REMOD_BACKOFF_SHIFT` (reset 1); [3], [7:6] reserved |
| **Gain / AGC / SX1257 Live RX Control** (`0x10`–`0x1B`) | | | | | |
| `0x10` | `RX_GAIN_SHADOW_0` | R/W | `0x3E` | AGC / External Control | Software-visible desired gain byte for SX1257_1 (Trouper does not apply it on chip) |
| `0x11` | `RX_GAIN_SHADOW_1` | R/W | `0x3E` | AGC / External Control | Software-visible desired gain byte for SX1257_2 |
| `0x12` | `RX_GAIN_SHADOW_2` | R/W | `0x3E` | AGC / External Control | Software-visible desired gain byte for SX1257_3 |
| `0x13` | `RX_GAIN_SHADOW_3` | R/W | `0x3E` | AGC / External Control | Software-visible desired gain byte for SX1257_4 |
| `0x14` | `RX_GAIN_ACTIVE_0` | R | `0x3E` | AGC | Hardware-latched live gain byte for SX1257_1; updated from `RX_GAIN_SHADOW_0` on commit pulse |
| `0x15` | `RX_GAIN_ACTIVE_1` | R | `0x3E` | AGC | Hardware-latched live gain byte for SX1257_2 |
| `0x16` | `RX_GAIN_ACTIVE_2` | R | `0x3E` | AGC | Hardware-latched live gain byte for SX1257_3 |
| `0x17` | `RX_GAIN_ACTIVE_3` | R | `0x3E` | AGC | Hardware-latched live gain byte for SX1257_4 |
| `0x18` | `RX_GAIN_CTRL` | R/W | `0x00` | AGC | [0] `RX_GAIN_COMMIT` (W1P: latches shadow→active, auto-clears; reads 0 — commit completes within one clock, there is no observable pending state) |
| `0x19`–`0x1B` | — | — | — | — | Reserved for gain/AGC growth |
| **Packet / Weight-Path / Training Control** (`0x1C`–`0x23`) | | | | | |
| `0x1C` | `PACKET_STATUS` | R | `0x00` | Packet Control FSM | [0] `PACKET_ACTIVE`; [3:1] `PACKET_PHASE`; [4] `TRAINING_DONE`; [5] `W_PENDING`; [6] `W_VALID`; [7] `W_MISSED_PACKET` |
| `0x1D` | `ACTIVE_STATUS` | R | `0x10` | Packet Control FSM | [1:0] `ACTIVE_MODE` latched at packet-safe boundary; [7:4] `ACTIVE_ANTENNA_EN`; [3:2] reserved. Reset = FSM defaults (mode 0, antenna_en 0x1) until the first lock latches the shadow |
| `0x1E` | `WGT_CTRL` | R/W | `0x00` | Combiner weight path | [0] `W_COMMIT` (W1P); [1] `W_VALID` (RO); [2] `W_PENDING` (RO); [3] `W_MISSED_PACKET` (RO); [7:4] reserved |
| `0x1F` | `TACC_NOISE_TRIG` | W | `0x00` | Training Accumulator | [0] W1P: arm accumulator for firmware-triggered noise measurement (ignores `sc_lock`) |
| `0x20` | `TRAINING_STATUS` | R | `0x00` | Training Accumulator | [0] `TRAINING_DONE`; [1] `TRAINING_ARMED`; [7:2] reserved |
| `0x21` | `N_ACC_HI` | R | `0x00` | Training Accumulator | Samples accumulated [17:16] (bits [1:0]; [7:2] read 0) |
| `0x22` | `N_ACC_MID` | R | `0x00` | Training Accumulator | Samples accumulated [15:8] |
| `0x23` | `N_ACC_LO` | R | `0x00` | Training Accumulator | Samples accumulated [7:0] |
| **SC Status / Bring-Up Debug** (`0x24`–`0x2F`) | | | | | |
| `0x24` | `SC_STAT_HI` | R | `0x00` | Schmidl-Cox | Current SC metric numerator `\|C[s]\|^2` telemetry [15:8] |
| `0x25` | `SC_STAT_LO` | R | `0x00` | Schmidl-Cox | Current SC metric numerator `\|C[s]\|^2` telemetry [7:0] |
| `0x26` | `SC_DBG_FLAGS` | R | `0x00` | Schmidl-Cox | [0] `SC_HIT` (hit decision of the most recent symbol evaluation, held until the next one; cleared on re-arm); [2:1] hit counter; [3] `SC_LOCK`; [7:4] reserved |
| `0x27` | `TACC_WINDOW_SYMS` | R/W | `0x08` | Training Accumulator | [3:0] accumulation endpoint in symbols from `timing_ref`; writes below 8 clamp to 8; [7:4] read 0 |
| `0x28`–`0x2B` | `SC_FIRST_HIT` | R | `0x00` | Schmidl-Cox | First-hit sample-count snapshot [31:0], big-endian ([31:24] at `0x28`) |
| `0x2C`–`0x2F` | `SC_LOCK_SNAP` | R | `0x00` | Schmidl-Cox | Lock sample-count snapshot [31:0], big-endian ([31:24] at `0x2C`) |
| **W Shadow Bank** (`0x30`–`0x3F`) | | | | | |
| `0x30` | `W_0_RE_HI` | R/W | `0x00` | MRC Combiner | Branch 0 real [15:8], int16 Q1.15 |
| `0x31` | `W_0_RE_LO` | R/W | `0x00` | MRC Combiner | Branch 0 real [7:0] |
| `0x32` | `W_0_IM_HI` | R/W | `0x00` | MRC Combiner | Branch 0 imag [15:8] |
| `0x33` | `W_0_IM_LO` | R/W | `0x00` | MRC Combiner | Branch 0 imag [7:0] |
| `0x34` | `W_1_RE_HI` | R/W | `0x00` | MRC Combiner | Branch 1 real [15:8] |
| `0x35` | `W_1_RE_LO` | R/W | `0x00` | MRC Combiner | Branch 1 real [7:0] |
| `0x36` | `W_1_IM_HI` | R/W | `0x00` | MRC Combiner | Branch 1 imag [15:8] |
| `0x37` | `W_1_IM_LO` | R/W | `0x00` | MRC Combiner | Branch 1 imag [7:0] |
| `0x38` | `W_2_RE_HI` | R/W | `0x00` | MRC Combiner | Branch 2 real [15:8] |
| `0x39` | `W_2_RE_LO` | R/W | `0x00` | MRC Combiner | Branch 2 real [7:0] |
| `0x3A` | `W_2_IM_HI` | R/W | `0x00` | MRC Combiner | Branch 2 imag [15:8] |
| `0x3B` | `W_2_IM_LO` | R/W | `0x00` | MRC Combiner | Branch 2 imag [7:0] |
| `0x3C` | `W_3_RE_HI` | R/W | `0x00` | MRC Combiner | Branch 3 real [15:8] |
| `0x3D` | `W_3_RE_LO` | R/W | `0x00` | MRC Combiner | Branch 3 real [7:0] |
| `0x3E` | `W_3_IM_HI` | R/W | `0x00` | MRC Combiner | Branch 3 imag [15:8] |
| `0x3F` | `W_3_IM_LO` | R/W | `0x00` | MRC Combiner | Branch 3 imag [7:0] |
| **Z_kl Pair Readback — 24-bit** (`0x40`–`0x63`) | | | | | |
| `0x40`–`0x45` | `Z_01` | R | `0x00` | Training Accumulator | Pair (0,1): I[31:8] at `0x40`–`0x42`, Q[31:8] at `0x43`–`0x45` |
| `0x46`–`0x4B` | `Z_02` | R | `0x00` | Training Accumulator | Pair (0,2): I[31:8] at `0x46`–`0x48`, Q[31:8] at `0x49`–`0x4B` |
| `0x4C`–`0x51` | `Z_03` | R | `0x00` | Training Accumulator | Pair (0,3): I[31:8] at `0x4C`–`0x4E`, Q[31:8] at `0x4F`–`0x51` |
| `0x52`–`0x57` | `Z_12` | R | `0x00` | Training Accumulator | Pair (1,2): I[31:8] at `0x52`–`0x54`, Q[31:8] at `0x55`–`0x57` |
| `0x58`–`0x5D` | `Z_13` | R | `0x00` | Training Accumulator | Pair (1,3): I[31:8] at `0x58`–`0x5A`, Q[31:8] at `0x5B`–`0x5D` |
| `0x5E`–`0x63` | `Z_23` | R | `0x00` | Training Accumulator | Pair (2,3): I[31:8] at `0x5E`–`0x60`, Q[31:8] at `0x61`–`0x63` |
| **Z_kk Diagonal — 24-bit** (`0x64`–`0x6F`) | | | | | |
| `0x64`–`0x66` | `ZDIAG_0` | R | `0x00` | Training Accumulator | Branch 0 diagonal Σ\|raw_0\|² top 24 bits [31:8]. In noise mode: ≈ σ²_0 · n_acc. Same scale as the Z_kl pairs above. |
| `0x67`–`0x69` | `ZDIAG_1` | R | `0x00` | Training Accumulator | Branch 1 diagonal [31:8] |
| `0x6A`–`0x6C` | `ZDIAG_2` | R | `0x00` | Training Accumulator | Branch 2 diagonal [31:8] |
| `0x6D`–`0x6F` | `ZDIAG_3` | R | `0x00` | Training Accumulator | Branch 3 diagonal [31:8] |
| **External Memory (PSRAM)** (`0x70`–`0x76`) | | | | | |
| `0x70` | `PSRAM_CTRL` | R/W | `0x00` | PSRAM Buffer | [0] `PSRAM_EN`; [1] `PSRAM_CLR_ERR` (W1P); [2] `SAMPLE_WIDTH`; [3] `QSPI_OWNER`; [7:4] reserved |
| `0x71` | `PSRAM_STATUS` | R | `0x00` | PSRAM Buffer | [1:0] state; [2] `SAMPLE_SKIP`; [3] `INIT_DONE`; [4] `REPLAY_ACTIVE`; [5] `REPLAY_MISSED`; [6] `OVERFLOW`; [7] `BUF_ACTIVE` |
| `0x72` | `PSRAM_DBG_ADDR_LO` | R/W | `0x00` | PSRAM Buffer | Debug read byte address [7:0] |
| `0x73` | `PSRAM_DBG_ADDR_MID` | R/W | `0x00` | PSRAM Buffer | Debug read byte address [15:8] |
| `0x74` | `PSRAM_DBG_ADDR_HI` | R/W | `0x00` | PSRAM Buffer | Debug read byte address [22:16] (bit [7] reserved) |
| `0x75` | `PSRAM_DBG_CTRL` | R/W | `0x80` | PSRAM Buffer | [0] `RD_TRIG` (strobe, self-clears); [1] `AUTO_INC` (re-arm after 8-byte drain); [7] `DBG_BUSY` (R only — held during fetch, while `packet_active=1` or `QSPI_OWNER=1`, and before `qe_init_done`; reads `1` at power-on since PSRAM init has not run yet) |
| `0x76` | `PSRAM_DBG_DATA` | R | `0x00` | PSRAM Buffer | Byte window into last fetched 8-byte IQ sample; 8 consecutive reads drain one sample (byte order: i0,q0,i1,q1,i2,q2,i3,q3); address advances by 8 after the eighth read when `AUTO_INC=1`. Never auto-increments the SPI burst address. |
| **Reserved** (`0x77`–`0x7F`) | | | | | |
| `0x77`–`0x7E` | — | — | — | — | Reserved for future growth |
| `0x7F` | — | — | — | — | **Permanently reserved** — the `0x7F` command byte is held back as a future SPI protocol-escape code |

**Occupancy:** 110 implemented + 18 reserved = 128.

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

### `0x02` — IRQ_STATUS (read-only)

Sticky interrupt source bits.

| Bit | Field | Meaning |
| --- | --- | --- |
| [0] | `CORR_LOCK` | Schmidl-Cox detected preamble; Packet Control FSM entered `PREAMBLE_ACQ` |
| [1] | `TRAINING_DONE` | Training accumulator complete; software path may inspect `Z_kl` |
| [2] | `W_MISSED_PACKET` | W was not committed before safe switch; current packet remains bypass |
| [3] | `PACKET_DONE` | Packet Control FSM returned to `IDLE` |
| [4] | `NOISE_READY` | Noise-window accumulation complete without SC contamination; firmware may read `Z_kl`/`ZDIAG_k` |
| [7:5] | — | Reserved |

### `0x03` — IRQ_CLEAR (write-only)

Write 1s to clear corresponding `IRQ_STATUS` bits. Writing 0 leaves a bit unchanged.

---

### `0x04`–`0x07` — Reserved (former DEBUG_CTRL / GPIO_DIR / GPIO_OUT / GPIO_IN)

JTAG and GPIO were removed from Trouper. There is no JTAG TAP in the RTL, and the
former GPIO direction/output/input path was never wired out of the macro boundary.
These four addresses are now unimplemented: reads return `0x00`, writes are ignored.

The four pads formerly described as `TCK_IRQ`/`TMS_GPIO0`/`TDI_GPIO1`/`TDO_GPIO2`
now carry only `PSRAM_SIO[3:0]` on four dedicated pads; `IRQ_OUT` has its own
dedicated pad. See TRPR-PHY-003 and TRPR-IRQ.

---

### `0x08` — MIMO_CTRL (read/write)

| Bits | Field | Description |
| --- | --- | --- |
| [0] | `MODE` | 0 = MRC NR=4 (default); 1 = passthrough |
| [3:1] | — | Reserved, write 0 |
| [7:4] | `ANTENNA_EN` | One bit per antenna; default `0xF` (all enabled) |

`MODE=1` bypasses the MRC path and routes the lowest-numbered enabled antenna directly to the output path. Writes to `MODE` and `ANTENNA_EN` update shadow configuration during an active packet; hardware latches `ACTIVE_MODE` and `ACTIVE_ANTENNA_EN` only when the receiver is idle between packets.

---

### `0x09` — SF_CFG (read/write)

Spreading-factor selection for the non-FFT receive path. Direct-coded: the register holds the SF value itself.

| Bits | Field | Description |
| --- | --- | --- |
| [3:0] | `SF` | Spreading factor, valid range 7–12 |
| [7:4] | — | Reserved, write 0 |

This configures `M = 2^SF` for the PSRAM delay line, SC detector, training accumulator, and packet-control timing arithmetic. Like `BW_CFG`, writes are blocked in hardware while `PACKET_ACTIVE=1` — an SF change mid-packet would desynchronize the SC detector's and training accumulator's symbol-length arithmetic (neither has a re-arm mechanism for a live SF change), unlike the PSRAM delay line which explicitly re-arms its warm-up counter on any `sf`/`sample_shift` change.

---

### `0x0A` — BW_CFG (read/write)

| Bits | Field | Description |
| --- | --- | --- |
| [0] | `bw_sel` | LoRa bandwidth select: 0 = 250 kHz (2× oversample, `sample_shift=1`), 1 = 125 kHz (4× oversample, `sample_shift=2`) |
| [7:1] | — | Reserved, write 0 |

The decimator is a fixed R=64 half-band chain (500 kS/s output); bandwidth is **not**
a decimation-ratio change. `bw_sel` selects only `sample_shift`, which sets the
symbol period `M = 1 << (SF + sample_shift)` used by every symbol-domain block (SC
detector, training accumulator, packet-control FSM, PSRAM delay). Writes are ignored
while `PACKET_ACTIVE = 1`; a BW (or SF) change re-arms decimator/delay warm-up.

### `0x0B` — PKT_TIMEOUT_SYMS (read/write)

Maximum packet duration in LoRa symbols before the Packet Control FSM forces a return to `IDLE`.

### `0x0C`–`0x0D` — SC_THR (read/write)

Schmidl-Cox detection threshold, big-endian. Reset is `0x01CC`, the 12-bit-safe scaled equivalent of the legacy `0x7333` threshold (`0x7333 / 64`, rounded down). The RTL consumes bits [11:0] only; software must program a value in the range `0x0000`–`0x0FFF`. Bits [15:12] are stored and read back but do not affect detection.

### `0x0E` — SC_HITS_REQ (read/write)

Consecutive SC hits required for `sc_lock`; valid range 1–3.

### `0x0F` — COMB_CFG (read/write)

Combined post-combiner gain and re-modulator backoff control. Reset `0x10` (`POST_GAIN_SHIFT=0`, `REMOD_BACKOFF_SHIFT=1`).

| Bits | Field | Description |
| --- | --- | --- |
| [2:0] | `COMB_POST_GAIN_SHIFT` | 0-7 bit left shift applied after the combiner's fixed guard divide-by-2 |
| [3] | — | Reserved, write 0 |
| [5:4] | `REMOD_BACKOFF_SHIFT` | Right shift applied before the ΣΔ re-modulator to maintain < −3 dBFS input |
| [7:6] | — | Reserved, write 0 |

Reset values are conservative. Firmware/host may adjust after observing output headroom.

---

### `0x10`–`0x18` — RX gain shadow/active/commit control

**Gain byte format** (applies to `RX_GAIN_SHADOW_n` and `RX_GAIN_ACTIVE_n`):

- `[7:5]` `RxLnaGain` (`1=G1` max gain, `6=G6` min gain)
- `[4:1]` `RxBbGain` (0-15, 2 dB per step)
- `[0]` `LnaZin` (keep 0 for 50 ohm)

Reset value `0x3E` gives maximum-gain fallback for CPU-less RX-only mode.

**Commit model:** Software writes `RX_GAIN_SHADOW_n` (`0x10`–`0x13`), programs the corresponding SX1257 externally (board-level SPI master), then writes `RX_GAIN_CTRL` (`0x18`[0]=1). Trouper hardware latches `RX_GAIN_SHADOW_n → RX_GAIN_ACTIVE_n` on the commit pulse. `RX_GAIN_ACTIVE_n` is therefore a hardware-latched record of the last committed gain, not a software-maintained mirror.

### `0x18` — RX_GAIN_CTRL (read/write)

| Bits | Field | Description |
| --- | --- | --- |
| [0] | `RX_GAIN_COMMIT` | W1P: latches all four `RX_GAIN_SHADOW_n → RX_GAIN_ACTIVE_n`; auto-clears. Reads 0 (like `WGT_CTRL[0]`): the latch completes within one clock, so no pending state is ever observable over SPI. |
| [7:1] | — | Reserved |

**AGC policy (software-owned):** After `IRQ_TRAINING_DONE`, controlling software reads per-antenna preamble power from `ZDIAG_k` (`0x64`–`0x6F`) divided by `n_acc` and compares against its own gain-down / saturation thresholds (host- or Grouper-side constants — there are no on-chip AGC threshold registers). One SX1257 LNA gain step per packet, per antenna independently.

**Noise EMA (separate from AGC):** Between packets (`PACKET_ACTIVE=0`), software arms a noise accumulation window via `TACC_NOISE_TRIG` (`0x1F`[0]=1). After `IRQ_TRAINING_DONE` fires in noise mode, `ZDIAG_k ≈ σ²_k × n_acc`. Software maintains σ²_ema[k] ← (1−α)·σ²_ema[k] + α·(ZDIAG_k/n_acc); this feeds ALMMSE weight computation (w_k ∝ h_k/σ²_k).

---

### `0x1C` — PACKET_STATUS (read-only)

| Bits | Field | Description |
| --- | --- | --- |
| [0] | `PACKET_ACTIVE` | Packet FSM is not idle |
| [3:1] | `PACKET_PHASE` | 0=IDLE, 1=PREAMBLE_ACQ, 2=W_PENDING, 3=PAYLOAD_ACTIVE |
| [4] | `TRAINING_DONE` | Training accumulator complete this packet |
| [5] | `W_PENDING` | Training is done and W commit is pending |
| [6] | `W_VALID` | Active W bank is valid for the current packet |
| [7] | `W_MISSED_PACKET` | W missed the current packet safe-switch point. Sticky: held through IDLE (readable after `PACKET_DONE`), cleared at the next packet start |

### `0x1D` — ACTIVE_STATUS (read-only)

| Bits | Field | Description |
| --- | --- | --- |
| [1:0] | `ACTIVE_MODE` | Active mode latched at packet-safe boundary from `MIMO_CTRL.MODE` (0 = MRC, 1 = passthrough) |
| [3:2] | — | Reserved |
| [7:4] | `ACTIVE_ANTENNA_EN` | Latched active antenna mask for the current packet |

### `0x1E` — WGT_CTRL (read/write)

Weight-path commit control and status. Firmware is the sole weight source (there is no hardware weight-generation block).

`W_COMMIT` is pulsed by software after writing the `0x30`–`0x3F` W shadow bank.

| Bits | Field | Description |
| --- | --- | --- |
| [0] | `W_COMMIT` | Write-1 pulse after W shadow writes complete |
| [1] | `W_VALID` | Read-only: active W bank is valid for the current packet |
| [2] | `W_PENDING` | Read-only: training done but W commit not yet received |
| [3] | `W_MISSED_PACKET` | Read-only: W was not committed before safe-switch; current packet stayed bypass. Sticky: held through IDLE, cleared at the next packet start |
| [7:4] | — | Reserved |

### `0x1F` — TACC_NOISE_TRIG (write-only, W1P)

Firmware-triggered noise measurement. Writing bit 0 = 1 arms the training accumulator without waiting for `sc_lock`. The accumulator resets all internal state and immediately begins accumulating the next `TACC_WINDOW_SYMS × M` samples. `TRAINING_DONE` fires on completion.

In noise mode (no signal): off-diagonal `Z_kl ≈ 0` (uncorrelated noise); diagonal `ZDIAG_k ≈ σ²_k · n_acc`.

Software EMA flow:
1. Write `0x1F ← 0x01` during idle (no packet in progress)
2. Poll `TRAINING_STATUS.TRAINING_DONE` (or wait for `IRQ_STATUS.NOISE_READY`)
3. Read `ZDIAG_k` at `0x64`–`0x6F` (top 24 bits) for all branches
4. Update per-branch EMA: `sigma2_k ← (1-α)·sigma2_k + α · ZDIAG_k[31:8] / n_acc`

### `0x20`–`0x23` — TRAINING_STATUS / N_ACC (read-only)

Training-window bookkeeping: arm/done flags and the accumulated sample count `n_acc`
(full **18-bit** unsigned, big-endian across `0x21`–`0x23`: `0x21`[1:0] = `[17:16]`,
`0x22` = `[15:8]`, `0x23` = `[7:0]`). The training window is controlled by
`TACC_WINDOW_SYMS` (`0x27`) and spans from `sc_lock` until `timing_ref + TACC_WINDOW_SYMS × M - 1` in live mode. With the 4-bit maximum of 15 symbols, the SF12/BW125 maximum is `15 × 2^(12+2) = 245760` samples, which still fits in 18 bits.

---

### `0x24`–`0x25` — SC_STAT (read-only)

Current Schmidl-Cox metric numerator telemetry from the detector. This is the exposed `|C[s]|^2` snapshot (`sym_mag_sc[27:13]` plus a zero LSB), not a normalised `Lambda^2[s]` value.

### `0x27` — TACC_WINDOW_SYMS (read/write)

Controls the training accumulator endpoint in whole LoRa symbols from `timing_ref`. Reset is 8. Writes below 8 store 8 to avoid too-short/empty post-lock training windows. Values above the actual transmitted preamble length can include non-preamble symbols and degrade the channel estimate; firmware should set this consistently with the packet preamble profile. The packet-control FSM derives acquisition and W-pending timeouts from the same value.

### `0x26`, `0x28`–`0x2F` — SC Bring-Up Debug (read-only)

Optional Schmidl-Cox debug visibility intended primarily for FPGA and first-silicon bring-up.

- `SC_DBG_FLAGS` (`0x26`)
  current raw threshold result, hit-counter state, and current `SC_LOCK`
- `SC_FIRST_HIT` (`0x28`–`0x2B`)
  32-bit free-running `iq_valid` sample-count snapshot taken at the first qualifying hit of the eventual lock sequence
- `SC_LOCK_SNAP` (`0x2C`–`0x2F`)
  32-bit free-running `iq_valid` sample-count snapshot taken when `sc_lock` asserts

These registers are debug aids, not part of the normal packet-processing control path.

---

### `0x30`–`0x3F` — W vector (read/write)

MRC weight vector `w` (4 complex coefficients, int16 Q1.15). Written by software after computing weights from the Z_kl pairs. These locations hold the shadow bank; the live combiner reads only `W_ACTIVE`.

`W_ACTIVE` updates atomically after `WGT_CTRL.W_COMMIT` is pulsed and the Packet Control FSM reaches an idle boundary.

A 17-byte SPI burst (command byte + 16 data bytes starting at `0x30`) loads the full bank in one transaction.

**Precision note:** `mrc_combiner.v` takes `signed [7:0]` weight inputs — only the HI byte of each Q1.15 pair (e.g. `W_0_RE_HI` at `0x30`) actually reaches the combiner; the corresponding LO byte (`0x31`, etc.) is write-only and silently discarded by hardware. Effective weight precision is Q0.7 (int8, ±127), not the full Q1.15 the shadow bank register names imply. Firmware should quantize weights to int8 before committing. Confirmed by `rtl-test/tb/test_weight_gen_spi_flow.py` (SGE job 3286, bit-exact vs. oracle).

---

### `0x40`–`0x63` — Z_kl pair readback, 24-bit (read-only)

All C(4,2)=6 branch-pair cross-correlations from the training accumulator. Each value exposes the **top 24 bits `[31:8]` of the signed int32 accumulator**, big-endian, 3 bytes per component (I then Q), 6 bytes per pair.

> **Precision note:** bits [7:0] of each accumulator are not readable. At realistic operating points the discarded byte is below the statistical noise of the Z estimate itself (training windows of 1k–32k samples); firmware treats the 24-bit value as `Z_kl >> 8`. This cut saves 12 register slots versus full 32-bit readback under the 128-register constraint.

> **External debug access note:** the `Z_kl`/`ZDIAG_k` accumulator flops in `training_acc` have no reset (area optimisation — they are zeroed at every arm event instead; see `planning/blocks/Training Accumulator.md`). Between power-on and the *first* arm (a real `sc_lock` or a `TACC_NOISE_TRIG` write, `0x1F`), these registers hold undefined power-on silicon state, not `0`. Shipped firmware never hits this — it only reads `0x40`–`0x6F` from `handle_training_done()`, gated on `IRQ_TRAINING_DONE` — but an external SPI/AHB debug master reading this range directly (e.g. bring-up scripts, bench tooling) before the first arm will see garbage, not zero. Issue a `TACC_NOISE_TRIG` write first if a deterministic zero is needed before a real packet arrives.

| Addresses | Name | Description |
| --- | --- | --- |
| `0x40`–`0x42` | `Z_01_I` | Pair (0,1) real part Σ raw_0·conj(raw_1), bits [31:8] |
| `0x43`–`0x45` | `Z_01_Q` | Pair (0,1) imaginary part [31:8] |
| `0x46`–`0x48` | `Z_02_I` | Pair (0,2) real part [31:8] |
| `0x49`–`0x4B` | `Z_02_Q` | Pair (0,2) imaginary part [31:8] |
| `0x4C`–`0x4E` | `Z_03_I` | Pair (0,3) real part [31:8] |
| `0x4F`–`0x51` | `Z_03_Q` | Pair (0,3) imaginary part [31:8] |
| `0x52`–`0x54` | `Z_12_I` | Pair (1,2) real part [31:8] |
| `0x55`–`0x57` | `Z_12_Q` | Pair (1,2) imaginary part [31:8] |
| `0x58`–`0x5A` | `Z_13_I` | Pair (1,3) real part [31:8] |
| `0x5B`–`0x5D` | `Z_13_Q` | Pair (1,3) imaginary part [31:8] |
| `0x5E`–`0x60` | `Z_23_I` | Pair (2,3) real part [31:8] |
| `0x61`–`0x63` | `Z_23_Q` | Pair (2,3) imaginary part [31:8] |

Firmware eigenvector path: read all 6 Z_kl pairs, build the 4×4 Hermitian matrix `Z` (the conjugate `Z_lk = conj(Z_kl)` is implied by Hermitian symmetry; diagonals from `ZDIAG_k`), take the principal eigenvector `eigh(Z)[:,-1]` as the MRC weight direction. This achieves near-ideal diversity gain.

A single 49-byte SPI burst (command byte + 48 data bytes starting at `0x40`) reads all pairs plus diagonals (`0x40`–`0x6F`) in one transaction.

---

### `0x64`–`0x6F` — Z_kk diagonal autocorrelation, 24-bit (read-only)

Per-branch `ZDIAG_k = Σ|raw_k[n]|²` over the training window. Top 24 bits `[31:8]` of the 32-bit accumulator — the same scale as the Z_kl off-diagonal pairs above (widened from an earlier 16-bit `[31:16]` readback; see `planning/blocks/Training Accumulator.md`). Matching the off-diagonal scale removes a separate scale-alignment step in the firmware eigenvector solve, and closes a measured ≈0.9 dB combining-gain loss that the 16-bit truncation introduced (see `sim/notebooks/11_training_accumulator.ipynb`).

| Addresses | Field | Description |
| --- | --- | --- |
| `0x64`–`0x66` | `ZDIAG_0` | Branch 0 Σ\|raw_0\|² [31:8] |
| `0x67`–`0x69` | `ZDIAG_1` | Branch 1 Σ\|raw_1\|² [31:8] |
| `0x6A`–`0x6C` | `ZDIAG_2` | Branch 2 Σ\|raw_2\|² [31:8] |
| `0x6D`–`0x6F` | `ZDIAG_3` | Branch 3 Σ\|raw_3\|² [31:8] |

In normal signal mode: `ZDIAG_k ≈ (|h_k|² + σ²_k) · n_acc`.
In noise mode (triggered by `TACC_NOISE_TRIG`): `ZDIAG_k ≈ σ²_k · n_acc`.

---

### `0x70` — PSRAM_CTRL (read/write)

| Bits | Field | Description |
| --- | --- | --- |
| [0] | `PSRAM_EN` | 0 = disabled (default); 1 = enable optional same-packet PSRAM buffering/replay. Write ignored while `PACKET_ACTIVE` — like `SF_CFG`/`BW_CFG`, toggling this mid-packet would leave `psram_buf_ctrl`'s `buf_active` set with `psram_en` now 0, an inconsistent state its own logic assumes can't happen. |
| [1] | `PSRAM_CLR_ERR` | Write 1 to clear sticky PSRAM error flags (`OVERFLOW`, `REPLAY_MISSED`); self-clears |
| [2] | `SAMPLE_WIDTH` | 0 = 16-bit I/Q storage (default, max f_s = 1 MS/s); 1 = 32-bit I/Q storage (max f_s = 500 kS/s) |
| [3] | `QSPI_OWNER` | 0 = Trouper `psram_buf_ctrl` owns the APS6404L pads for capture/replay (default); 1 = ownership transferred away from the replay controller for a future firmware-managed external-memory mode. Ownership changes take effect only when the PSRAM controller is idle. |
| [7:4] | — | Reserved |

### `0x71` — PSRAM_STATUS (read-only)

Only meaningful when `PSRAM_CTRL.QSPI_OWNER=0` and `PSRAM_CTRL.PSRAM_EN=1`. Exposes the same-packet replay controller state. When `QSPI_OWNER=1`, BUFFERING/REPLAY is suspended and the off-chip memory interface is reserved for a future firmware-managed access mode.

| Bits | Field | Description |
| --- | --- | --- |
| [1:0] | `STATE` | Controller state (0 = UNINIT, 1 = QE_INIT, 2 = WRITE, 3 = REPLAY; see `psram_buf_ctrl.v` `state_dbg`) |
| [2] | `SAMPLE_SKIP` | Sticky: an `iq_valid` arrived while the QPI engine was busy and a sample was not captured. Always 0 at 125/250 kHz (timing budget guarantees no skip); non-zero only out of spec. Clear via `PSRAM_CLR_ERR` (0x70[1]) |
| [3] | `INIT_DONE` | QE init sequence complete |
| [4] | `REPLAY_ACTIVE` | Replay in progress |
| [5] | `REPLAY_MISSED` | Sticky: `packet_end` before `W_commit` |
| [6] | `OVERFLOW` | Sticky: write pointer lapped read pointer |
| [7] | `BUF_ACTIVE` | Same-packet capture window active |

### `0x72`–`0x76` — PSRAM Debug Readback Registers

Available when `PSRAM_STATUS.STATE=IDLE` and `PSRAM_CTRL.QSPI_OWNER=0`. Provides host SPI access to arbitrary PSRAM addresses without requiring Grouper firmware — useful for bring-up and post-capture IQ inspection.

**Access sequence:**
1. Write 23-bit target byte address to `PSRAM_DBG_ADDR_LO` (`0x72`), `PSRAM_DBG_ADDR_MID` (`0x73`), `PSRAM_DBG_ADDR_HI[6:0]` (`0x74`).
2. Write `0x01` to `PSRAM_DBG_CTRL` (`0x75`) to strobe `RD_TRIG`. `DBG_BUSY` (bit 7) asserts immediately.
3. Poll `PSRAM_DBG_CTRL[7]` until clear (~1 µs at 32 MHz).
4. Read `PSRAM_DBG_DATA` (`0x76`) eight times. Bytes arrive in sample order: i0, q0, i1, q1, i2, q2, i3, q3.
5. To stream further samples: set `AUTO_INC` (`0x75`[1]=1) before triggering — the address advances by 8 after the eighth read and a new fetch begins automatically.

`DBG_BUSY` is held (and reads of `0x76` return 0x00) while `packet_active=1` or `QSPI_OWNER=1`. Debug reads are serviced in spare sub-cycles between `iq_valid` pulses and do not disrupt normal capture or replay (see TRPR-PSR-017).

`PSRAM_DBG_DATA` is exempt from SPI burst address auto-increment: repeated data bytes in a burst re-read `0x76`, with the port's own internal byte index advancing through the 8-byte sample.

---

## Removed registers

The following registers existed in earlier revisions of this map (which spanned `0x00`–`0xEF`) and were **removed** to fit the 7-bit SPI address constraint. None of them had live hardware behind them in the current `trouper_top` integration.

| Former address(es) | Name | Reason removed |
| --- | --- | --- |
| `0x02`, `0x07`–`0x08` | `CPU_RESET`, `CPU_SRAM_CTRL/STATUS` | No PicoRV32 / CPU SRAM in Trouper |
| `0x0A` | `LOW_BAT_THR` | No hardware; never implemented in RTL. Address `0x0A` is now reused for `BW_CFG` (see active map). |
| `0x13`–`0x15` | `FRONTEND_CFG/STATUS`, `BUF_WR_PTR` | frontend_buf_ctrl and on-chip frontend SRAMs removed (PSRAM delay line replaces them) |
| `0x17`–`0x18`, `0x1C` | `ENERGY_THR`, `SC_CFG.ENERGY_GATE_EN` | Energy gating removed with `noise_est.v` |
| `0x2B`–`0x2E` | `AGC_THR_HI`, `AGC_THR_SAT` | AGC comparison is software-owned; thresholds live host-side, never implemented in RTL |
| `0x35`[7:4] | `WGT_SRC`, `WGT_AUTO_COMMIT`, `WGT_MODE` | Hardware weight_gen removed; firmware is sole weight source |
| `0x48`–`0x4F` | `CORR_MAG_0..3` | Hardwired 0; SC magnitude readback never wired |
| `0x52`–`0x57` | `COND_NUM`, `SNR_0`, `NULL_QUALITY` | Firmware scratch diagnostics; no CPU on chip — host keeps its own diagnostics |
| `0x63`–`0x69` | `Z_SHIFT`, `C_POOL`, `CFO_DIAG` | Hardwired 0 in `trouper_top` |
| `0x6A`–`0x6B` | `NOISE_WIN_CTRL`, `TACC_REF_SEL` | Legacy single-ref/noise-enable path; superseded by `TACC_NOISE_TRIG` |
| `0xB2`–`0xB4` | `PSRAM_PKT_BYTES`, `PSRAM_RD_OFFSET` | Hardwired 0; pointer telemetry never wired |
| `0xCA`–`0xCD` | `SRAM_DUMP_*` | Frontend SRAMs removed; PSRAM debug readback (`0x72`–`0x76`) replaces this |
| `0x70`–`0x8F`, `0xD4`–`0xDB`, `0xE0`–`0xE7` low bytes | `Z_kl` bits [7:0] | Z readback narrowed to 24-bit under the 128-register constraint |
| — | SPI extended frame (`0x7F` escape, firmware load) | No CPU SRAM to load; `0x7F` command byte re-reserved for future protocol escape |
| `0x04`–`0x07` | `DEBUG_CTRL`/`JTAG_EN`, `GPIO_DIR`/`OUT`/`IN` | JTAG/GPIO removed; no TAP in RTL, GPIO never wired out of macro. Addresses now reserved |

If a future revision reinstates any of these features, allocate addresses from the reserved slots (`0x19`–`0x1B`, `0x77`–`0x7E`). Note `0x6C`–`0x6F` — formerly reserved for training-derived metrics — was consumed by the ZDIAG 16-bit→24-bit widening (see active map above).

---

## Address range reservations

| Range | Block |
| --- | --- |
| `0x00`–`0x07` | Global / IRQ (`0x04`–`0x07` reserved; former JTAG/GPIO) |
| `0x08`–`0x0F` | RX / modem configuration |
| `0x10`–`0x1B` | Gain / AGC / SX1257 live RX control (`0x19`–`0x1B` reserved) |
| `0x1C`–`0x23` | Packet / weight-path / training control |
| `0x24`–`0x2F` | SC status, `TACC_WINDOW_SYMS`, and bring-up debug |
| `0x30`–`0x3F` | W shadow bank |
| `0x40`–`0x63` | Z_kl pair readback (24-bit) |
| `0x64`–`0x6F` | Z_kk diagonal (24-bit) |
| `0x70`–`0x76` | External memory (PSRAM) control and debug |
| `0x77`–`0x7E` | Reserved (future growth) |
| `0x7F` | Permanently reserved (SPI protocol escape) |
