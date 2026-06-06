# ASIC Pinout

GF180MCU MIMO ASIC — logical pad list. Physical pad numbers and positions are not yet assigned (pending floorplan). Total: **44 pads** (38 signal + 6 supply/ground).

**Related:** [System Architecture](System%20Architecture.md)

---

## Signal pads (38)

All signal pads use **GF180 5V-capable IO cells** from the chipathon padring library, operated on a **3.3V `VDD_IO` rail** to match the SX1257/SX1302/RPi board interfaces. Core logic runs at **3.3V**, so no internal level translation is required between the core and SRAM domains.

### RX data from SX1257 (8 pads, input)

| Pad name | Dir | Connected to | Description |
|---|---|---|---|
| `IQ_DATA_I[0]` | in | SX1257_1 I_OUT (pin 15) | 1-bit ΣΔ RX I stream, antenna 1 |
| `IQ_DATA_Q[0]` | in | SX1257_1 Q_OUT (pin 14) | 1-bit ΣΔ RX Q stream, antenna 1 |
| `IQ_DATA_I[1]` | in | SX1257_2 I_OUT | 1-bit ΣΔ RX I stream, antenna 2 |
| `IQ_DATA_Q[1]` | in | SX1257_2 Q_OUT | 1-bit ΣΔ RX Q stream, antenna 2 |
| `IQ_DATA_I[2]` | in | SX1257_3 I_OUT | 1-bit ΣΔ RX I stream, antenna 3 |
| `IQ_DATA_Q[2]` | in | SX1257_3 Q_OUT | 1-bit ΣΔ RX Q stream, antenna 3 |
| `IQ_DATA_I[3]` | in | SX1257_4 I_OUT | 1-bit ΣΔ RX I stream, antenna 4 |
| `IQ_DATA_Q[3]` | in | SX1257_4 Q_OUT | 1-bit ΣΔ RX Q stream, antenna 4 |

> **Polarity note (SX1257 Table 1-1 typo):** Table 1-1 of the SX1257 datasheet v1.2 describes pin 14 Q_OUT as "I channel" and pin 15 I_OUT as "Q channel" — this is a Semtech typo. The §3.7.1 block diagram is correct. Connect I_OUT (pin 15) → `IQ_DATA_I[n]` and Q_OUT (pin 14) → `IQ_DATA_Q[n]`.

### Clock (1 pad, input)

| Pad name | Dir | Connected to | Description |
|---|---|---|---|
| `IQ_CLK` | in | PCB TCXO clock buffer output | 32 MHz master clock. Shared reference: same buffer also drives SX1257_1–4 XTB (pin 8) via separate PCB traces. This pad is the ASIC core clock. |

### ΣΔ re-mod outputs to SX1302 (4 pads, output)

Two independent ΣΔ re-mod outputs. Radio A carries the primary MRC combined stream. Radio B carries a second stream — used in the 3-chip cascade topology as the second feeder input to the combiner ASIC, or as a passthrough/bypass output for diagnostics.

| Pad name | Dir | Connected to | Description |
|---|---|---|---|
| `REMOD_A_I` | out | SX1302 Radio A I input | 1-bit ΣΔ MRC combined stream (primary) |
| `REMOD_A_Q` | out | SX1302 Radio A Q input | 1-bit ΣΔ MRC combined stream Q (primary) |
| `REMOD_B_I` | out | SX1302 Radio B I input / cascade combiner | 1-bit ΣΔ second stream I |
| `REMOD_B_Q` | out | SX1302 Radio B Q input / cascade combiner | 1-bit ΣΔ second stream Q |

> **SX1302 clock:** SX1302 CLK_IN is driven by SX1257_1 CLK_OUT (pin 10) directly on the PCB — no ASIC pad required. See board-level pin dispositions in [System Architecture](System%20Architecture.md).

### SPI slave — host config and firmware load (4 pads, input/output)

The ASIC acts as SPI slave for host configuration and firmware load. All four pads are dedicated and unidirectional. The RPi drives MOSI/SCK; the ASIC drives MISO. No bus contention is possible because `HOST_MOSI`, `HOST_SCK`, and `HOST_CS` are input-only pads.

| Pad name | Dir | Connected to | Description |
|---|---|---|---|
| `HOST_MOSI` | in | RPi SPI0 MOSI | Host-to-ASIC data |
| `HOST_MISO` | out | RPi SPI0 MISO | ASIC-to-host data |
| `HOST_SCK` | in | RPi SPI0 SCLK | Host clock. Max 10 MHz |
| `HOST_CS` | in | RPi SPI0 CE1 | Active-low. Selects ASIC as SPI slave |

### SPI master — SX1257 radio config and QSPI device select (6 pads, output/input)

The ASIC acts as SPI master for all four SX1257 radios and the QSPI peripheral (PSRAM). All three data/clock pads are ASIC-driven outputs; `SX_MISO` is the only input. No bidirectional pad is required.

Device selection uses a board-level **74HC138 3-to-8 decoder**: the ASIC drives a 3-bit address (`CS_A[2:0]`) generating up to 8 individual active-low chip-select lines. The decoder enable is tied to GND (always active); the selected output goes low, all others remain high. SPI CLK quiescent = no transaction on spuriously-selected devices.

`SX_SCK` is shared on the PCB with the QSPI peripheral clock input. Both the SX1257 SPI master and the QSPI controller use the same clock output pad; only one device is selected at a time via `CS_A[2:0]`.

| Pad name | Dir | Connected to | Description |
|---|---|---|---|
| `SX_MOSI` | out | SX1257_1–4 SDI | ASIC-to-SX1257 data |
| `SX_MISO` | in | SX1257_1–4 SDO | SX1257-to-ASIC data (diagnostic reads only) |
| `SX_SCK` | out | SX1257_1–4 SCK; QSPI device CLK | ASIC-generated clock. Default 4 MHz (16 MHz÷4); max 10 MHz for SX1257, max 8 MHz for QSPI |
| `CS_A[0]` | out | 74HC138 A0 input | Bit 0 of device address |
| `CS_A[1]` | out | 74HC138 A1 input | Bit 1 of device address |
| `CS_A[2]` | out | 74HC138 A2 input | Bit 2 of device address |

**74HC138 decode table (board-level):**

| `CS_A[2:0]` | Device selected |
|---|---|
| `000` | SX1257_1 |
| `001` | SX1257_2 |
| `010` | SX1257_3 |
| `011` | SX1257_4 |
| `100` | QSPI device (PSRAM) |
| `101`–`111` | Spare |

> **Broadcast writes removed.** With individual CS pads the SPI master could assert multiple lines simultaneously to write the same register to several SX1257s in one transaction. With the decoder only one device is selectable at a time; multi-device config requires sequential transactions (4 × ~1.6 µs at 10 MHz — negligible for startup).

### JTAG (5 pads, dedicated)

Dedicated JTAG pads — always available, no mode-switch required, no conflict with GPIO or QSPI. Connects to the PicoRV32 RISC-V debug module (halt, step, breakpoint, register/memory inspection). A custom `DEBUG_REG` DR instruction additionally allows direct register bank read/write via JTAG scan, independent of the SPI slave interface.

`JTAG_TRST` provides an asynchronous TAP reset without requiring the TMS five-clock reset sequence — cleaner reset in automated test environments.

| Pad name | Dir | Connected to | Description |
|---|---|---|---|
| `JTAG_TCK` | in | JTAG probe / RPi GPIO | JTAG clock. Max 8 MHz |
| `JTAG_TMS` | in | JTAG probe / RPi GPIO | JTAG mode select |
| `JTAG_TDI` | in | JTAG probe / RPi GPIO | JTAG data in |
| `JTAG_TDO` | out | JTAG probe / RPi GPIO | JTAG data out |
| `JTAG_TRST` | in | JTAG probe / RPi GPIO (pull-up) | Async TAP reset, active-low. Pull to VDD_IO via 10 kΩ on PCB; assert low only when intentionally resetting TAP. |

### GPIO bank — flexible mux (8 pads, bidirectional)

Eight GPIO pads split into two independent 4-pin nibbles. Each nibble is configured via the `IO_MUX_CTRL` register independently as GPIO or QSPI. JTAG is now on dedicated pads and is no longer a GPIO mux option.

**`IO_MUX_CTRL` register (`0x07`):**

| Field | Bits | Encoding |
|---|---|---|
| `UPPER_MODE` | [3:2] | `00`=GPIO, `01`=QSPI, `10`–`11`=reserved |
| `LOWER_MODE` | [1:0] | `00`=GPIO, `01`=QSPI, `10`–`11`=reserved |

**Valid mode combinations:**

| `UPPER_MODE` | `LOWER_MODE` | Result |
|---|---|---|
| GPIO | GPIO | 8× GPIO |
| GPIO | QSPI | QSPI IO[3:0] on lower nibble + 4× GPIO upper |
| QSPI | GPIO | QSPI IO[3:0] on upper nibble + 4× GPIO lower |
| QSPI | QSPI | **Invalid** → hardware forces both nibbles to GPIO |

**Pin function by mode:**

| Pad | GPIO mode | QSPI mode |
|---|---|---|
| `GPIO[n+0]` | bidir GPIO | QSPI IO0 bidir |
| `GPIO[n+1]` | bidir GPIO | QSPI IO1 bidir |
| `GPIO[n+2]` | bidir GPIO | QSPI IO2 bidir |
| `GPIO[n+3]` | bidir GPIO | QSPI IO3 bidir |

Where `n=0` for the lower nibble (`GPIO[3:0]`) and `n=4` for the upper nibble (`GPIO[7:4]`).

**QSPI CLK and CS:** `SX_SCK` is shared on the PCB with the QSPI device clock input (see SPI master section). QSPI chip-select is issued via `CS_A[2:0]=100` through the board-level 74HC138 decoder. No additional ASIC pads are required for QSPI CLK or CS.

**IRQ:** The interrupt output is software-assigned to any GPIO pin via `GPIO_IRQ_SEL[2:0]` in the `IRQ_CTRL` register (`0x08`). The selected pin's output-enable is asserted by the IRQ controller regardless of `GPIO_DIR`. Default after reset: `GPIO[0]`. The RPi should configure the chosen GPIO pin as a rising-edge input.

**SE2435L front-end control:** SE2435L_3/4 CPS and CTX signals are driven from any available GPIO pins. With JTAG on dedicated pads, all 8 GPIO pins are available simultaneously alongside QSPI (one nibble QSPI + one nibble GPIO).

**Suggested GPIO assignment:**

| Pin | Suggested use |
|---|---|
| `GPIO[0]` | IRQ output to RPi (default after reset) |
| `GPIO[1]` | SE2435L_3 CTX |
| `GPIO[2]` | SE2435L_4 CTX |
| `GPIO[3]` | SE2435L_3/4 CPS (shared) |
| `GPIO[7:4]` | QSPI IO[3:0] (APS6404L SIO lines) |

**Register map:** `GPIO_DIR` (`0x04`), `GPIO_OUT` (`0x05`), `GPIO_IN` (`0x06`), `IO_MUX_CTRL` (`0x07`), `IRQ_CTRL` (`0x08`).

### Chip reset (1 pad, input)

| Pad name | Dir | Connected to | Description |
|---|---|---|---|
| `RESETB` | in | RPi GPIO or power-on RC | Active-low. Resets all logic including PicoRV32. CPU reset is additionally software-controlled via SPI register for BIST-then-boot sequence. |

---

## Supply and ground pads (6 pads)

Three supply and three ground pads provide adequate current return paths and reduce IR drop. VDD_CORE pads should be placed near the highest switching-current blocks (ΣΔ decimators, PicoRV32). GND pads should be distributed to cover the IQ data input side and the digital core separately.

| Pad name | Voltage | Count | Notes |
|---|---|---|---|
| `VDD_IO` | 3.3V | 2 | Powers GF180 5V-capable padring cells. Place one near IQ data pads, one near SPI/GPIO pads. |
| `VDD_CORE` | 3.3V | 1 | Core digital + SRAM supply. |
| `GND` | 0V | 3 | Ground. Distribute around perimeter — one near IQ data inputs, one near digital core, one near SPI/JTAG pads. |

---

## Pad budget summary

### Full (44 pads)

| Group | Pads | Notes |
|---|---|---|
| RX data (`IQ_DATA_I/Q[3:0]`) | 8 | NR=4 capable |
| Clock (`IQ_CLK`) | 1 | |
| ΣΔ re-mod A (`REMOD_A_I`, `REMOD_A_Q`) | 2 | Primary MRC output |
| ΣΔ re-mod B (`REMOD_B_I`, `REMOD_B_Q`) | 2 | Cascade / Radio B output — **new** |
| SPI slave — host (`HOST_MOSI`, `HOST_MISO`, `HOST_SCK`, `HOST_CS`) | 4 | |
| SPI master + CS (`SX_MOSI`, `SX_MISO`, `SX_SCK`, `CS_A[2:0]`) | 6 | |
| JTAG (`JTAG_TCK`, `JTAG_TMS`, `JTAG_TDI`, `JTAG_TDO`, `JTAG_TRST`) | 5 | Dedicated — **new**; removed from GPIO mux |
| GPIO bank (`GPIO[7:0]`) | 8 | GPIO/QSPI only (JTAG mux removed) |
| `RESETB` | 1 | |
| **Signal subtotal** | **37** | |
| `VDD_IO` ×2 | 2 | **+1 vs 33-pad plan** |
| `VDD_CORE` ×1 | 1 | |
| `GND` ×3 | 3 | **+2 vs 33-pad plan** |
| **Supply/ground subtotal** | **6** | |
| **Total** | **43** | One pad spare vs 44 allocation |

> One pad remains spare within the 44-pad allocation. Reserved for future use (e.g. SX1257 shared RESET, second VDD_CORE, or cascade lock-detect GPIO).

### Condensed SPI fallback (40 pads — if needed)

Remove `SX_MOSI`, `SX_MISO`, `SX_SCK`; bridge to host SPI pads via PCB 0Ω resistors. Hardware OE gating required. All other additions retained.

| Group | Pads |
|---|---|
| RX data | 8 |
| Clock | 1 |
| ΣΔ re-mod A + B | 4 |
| SPI shared bus (`SPI_MOSI`, `SPI_MISO`, `SPI_SCK`, `HOST_CS`, `CS_A[2:0]`) | 7 |
| JTAG (dedicated) | 5 |
| GPIO bank | 8 |
| `RESETB` | 1 |
| **Signal subtotal** | **34** |
| Supply/ground | 6 |
| **Total** | **40** |

---

## Pads NOT on ASIC

The following signals are board-level only — no ASIC pad allocated:

| Signal | Reason | Disposition |
|---|---|---|
| SX1257 DIO0–DIO3 (×4 devices) | No ASIC pad — not worth the cost | PLL lock polled via `RegModeStatus` (0x11) over SPI instead |
| SX1257 individual NSS (×4) | Replaced by 74HC138 decoder | ASIC drives 3-bit address `CS_A[2:0]`; decoder generates individual active-low NSS lines on the PCB |
| SX1257 RESET (pin 9, ×4) | Candidate for the 1 spare pad | Decision pending: leave floating (POR only), RPi GPIO, or use spare ASIC pad for shared reset |
| SX1257 CLK_IN (pin 11, ×4) | Not needed — XTB shared TCXO used for lock | Leave NC on all 4 devices |
| SX1257 CLK_OUT (pin 10) | SX1257_1: CLK_OUT → SX1302 CLK_IN (PCB trace, no ASIC pad) | SX1257_2–4: leave NC |
| SE2435L CTX/CPS (ant 3/4) | Covered by GPIO bank | `GPIO[1:3]` in non-QSPI nibble per suggested GPIO assignment above |

---

## Changes vs 33-pad plan

| Change | Detail |
|---|---|
| +2 REMOD pads | Added `REMOD_B_I`, `REMOD_B_Q` for cascade topology / SX1302 Radio B |
| +5 JTAG pads | Dedicated `JTAG_TCK/TMS/TDI/TDO/TRST` — removed from GPIO mux entirely |
| +3 power pads | +1 `VDD_IO`, +2 `GND` — reduces IR drop risk |
| IO_MUX_CTRL simplified | JTAG option removed; only GPIO and QSPI per nibble |
| GPIO bank freed | All 8 GPIO available simultaneously with QSPI — no mode conflict |
| 1 pad spare | Available for SX1257 shared RESET or second VDD_CORE |

---

## Open items

- Physical pad placement / ordering around die perimeter — pending floorplan
- **Allocate the 1 spare pad** — SX1257 shared RESET is the leading candidate
- Confirm `RESETB` is a dedicated pad vs. managed by chipathon harness (Caravel or equivalent)
- Resolve SE2435L_3/4 CPS/CTX final GPIO pin assignment before PCB layout
- **GPIO Mux block spec update** — remove JTAG mode from `IO_MUX_CTRL`; update block document
- **JTAG TAP spec** — document `DEBUG_REG` custom DR instruction (17-bit scan: 8-bit addr + 8-bit data + R/W); update [JTAG TAP](blocks/JTAG%20TAP.md)
- **SPI Master block spec** — reflect `CS_A[2:0]`, 74HC138 decode table, QSPI CLK sharing
- **IR drop verification** — 1× VDD_CORE + 3× GND; floorplan must verify mesh adequacy; consider decoupling cap cells near ΣΔ decimators and PicoRV32
- **Pad-library assumption** — chipathon integration provides 5V-capable GF180 IO cells run from 3.3V `VDD_IO` rail; confirm speed impact with integration team
- **REMOD_B usage** — confirm sd_remod RTL exposes a second output port; update mimo_rx_top.v if not already present
