# ASIC Pinout

GF180MCU MIMO ASIC — logical pad list. Physical pad numbers and positions are not yet assigned (pending floorplan). Total: **33 pads** (30 signal + 3 supply/ground). Chipathon allocation target is 33 pads; a condensed 28-pad fallback is documented in the pad budget summary.

**Related:** [System Architecture](System%20Architecture.md)

---

## Signal pads (30)

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

### ΣΔ re-mod output to SX1302 (2 pads, output)

| Pad name | Dir | Connected to | Description |
|---|---|---|---|
| `REMOD_A_I` | out | SX1302 Radio A I input | 1-bit ΣΔ MRC combined stream |
| `REMOD_A_Q` | out | SX1302 Radio A Q input | 1-bit ΣΔ MRC combined stream Q |

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

### Condensed SPI option (−3 pads, 30-pad fallback)

If the chipathon pad budget cannot reach 33, the two SPI buses can share their data and clock lines by installing **0Ω PCB resistors** bridging `HOST_SCK`↔`SX_SCK`, `HOST_MOSI`↔`SX_MOSI`, and `HOST_MISO`↔`SX_MISO`. The dedicated host slave pads are renamed back to `SPI_MOSI`/`SPI_MISO`/`SPI_SCK`/`HOST_CS`, and `SX_MOSI`/`SX_MISO`/`SX_SCK` are removed. The remaining pad list (10 → 7 SPI+CS pads) reduces the signal total by 3 (30 → 27) and the grand total to 30.

**Bus-conflict rule for condensed mode:** the ASIC must never drive `SPI_MOSI` or `SPI_SCK` while `HOST_CS` is asserted, and must never accept a host transaction while a SX1257 or QSPI transaction is in progress (`BUSY=1`). This is enforced through hardware output-enable gating: `SPI_MOSI`/`SPI_SCK` output enables are masked by `!HOST_CS`.

### GPIO bank — flexible mux (8 pads, bidirectional)

Eight GPIO pads split into two independent 4-pin nibbles. Each nibble is configured via the `IO_MUX_CTRL` register independently as GPIO, QSPI data, or JTAG. Only one QSPI instance exists; asserting QSPI on both nibbles simultaneously is invalid (treated as all-GPIO).

**`IO_MUX_CTRL` register (`0x07`):**

| Field | Bits | Encoding |
|---|---|---|
| `UPPER_MODE` | [3:2] | `00`=GPIO, `01`=QSPI, `10`=JTAG, `11`=reserved |
| `LOWER_MODE` | [1:0] | `00`=GPIO, `01`=QSPI, `10`=JTAG, `11`=reserved |

**Valid mode combinations:**

| `UPPER_MODE` | `LOWER_MODE` | Result |
|---|---|---|
| GPIO | GPIO | 8× GPIO |
| GPIO | QSPI | QSPI IO[3:0] on lower + 4× GPIO upper |
| QSPI | GPIO | QSPI IO[3:0] on upper + 4× GPIO lower |
| GPIO | JTAG | JTAG on lower + 4× GPIO upper |
| JTAG | GPIO | JTAG on upper + 4× GPIO lower |
| JTAG | QSPI | QSPI IO[3:0] on lower + JTAG on upper |
| QSPI | JTAG | QSPI IO[3:0] on upper + JTAG on lower |
| QSPI | QSPI | **Invalid** → hardware forces both nibbles to GPIO |
| JTAG | JTAG | **Invalid** → hardware forces both nibbles to GPIO |

**Pin function by mode:**

| Pad | GPIO mode | QSPI mode | JTAG mode |
|---|---|---|---|
| `GPIO[n+0]` | bidir GPIO | QSPI IO0 bidir | TCK input |
| `GPIO[n+1]` | bidir GPIO | QSPI IO1 bidir | TMS input |
| `GPIO[n+2]` | bidir GPIO | QSPI IO2 bidir | TDI input |
| `GPIO[n+3]` | bidir GPIO | QSPI IO3 bidir | TDO output |

Where `n=0` for the lower nibble (`GPIO[3:0]`) and `n=4` for the upper nibble (`GPIO[7:4]`).

**QSPI CLK and CS:** `SX_SCK` is shared on the PCB with the QSPI device clock input (see SPI master section). QSPI chip-select is issued via `CS_A[2:0]=100` through the board-level 74HC138 decoder. No additional ASIC pads are required for QSPI CLK or CS.

**IRQ:** The interrupt output is software-assigned to any GPIO pin via `GPIO_IRQ_SEL[2:0]` in the `IRQ_CTRL` register (`0x08`). The selected pin's output-enable is asserted by the IRQ controller regardless of `GPIO_DIR`. Default after reset: `GPIO[0]`. The RPi should configure the chosen GPIO pin as a rising-edge input.

**SE2435L front-end control:** SE2435L_3/4 CPS and CTX signals are driven from any available GPIO pins in the non-JTAG, non-QSPI nibble. See [SE2435L Front-End Module](blocks/SE2435L%20Front-End%20Module.md).

**Register map:** `GPIO_DIR` (`0x04`), `GPIO_OUT` (`0x05`), `GPIO_IN` (`0x06`), `IO_MUX_CTRL` (`0x07`), `IRQ_CTRL` (`0x08`).

**JTAG mode switch procedure:**
1. RPi writes `IO_MUX_CTRL` to set the target nibble to `10` (JTAG).
2. RPi GPIO connected to the IRQ pin reconfigured as input/high-Z before JTAG mode takes effect.
3. Probe drives TCK, TMS, TDI; ASIC drives TDO.
4. On debug exit: RPi writes `IO_MUX_CTRL` nibble back to `00` (GPIO); firmware resumes GPIO control.

### Chip reset (1 pad, input)

| Pad name | Dir | Connected to | Description |
|---|---|---|---|
| `RESETB` | in | RPi GPIO or power-on RC | Active-low. Resets all logic including PicoRV32. CPU reset is additionally software-controlled via SPI register for BIST-then-boot sequence. |

---

## Supply and ground pads (3 pads)

| Pad name | Voltage | Count | Notes |
|---|---|---|---|
| `VDD_IO` | 3.3V | 1 | Powers GF180 5V-capable padring cells in 3.3V operation. External SX1257 SPI, IQ data, and SX1302 interfaces are 3.3V CMOS. |
| `VDD_CORE` | 3.3V | 1 | Core digital + SRAM supply. Single pad — IR drop must be verified in floorplan. |
| `GND` | 0V | 1 | Ground. Single pad — placement should favour the highest switching-current region. |

---

## Pad budget summary

### Full (33 pads — target, requires 33-pad allocation)

| Group | Pads | Notes |
|---|---|---|
| RX data (`IQ_DATA_I/Q[3:0]`) | 8 | |
| Clock (`IQ_CLK`) | 1 | |
| ΣΔ re-mod (`REMOD_A_I`, `REMOD_A_Q`) | 2 | |
| SPI slave — host (`HOST_MOSI`, `HOST_MISO`, `HOST_SCK`, `HOST_CS`) | 4 | |
| SPI master + CS (`SX_MOSI`, `SX_MISO`, `SX_SCK`, `CS_A[2:0]`) | 6 | `CS_A[2]` added vs prior rev |
| GPIO bank (`GPIO[7:0]`) | 8 | Replaces 4-pad JTAG/GPIO block |
| `RESETB` | 1 | |
| **Signal subtotal** | **30** | |
| `VDD_IO` (3.3V) | 1 | |
| `VDD_CORE` (3.3V) | 1 | |
| `GND` | 1 | |
| **Supply/ground subtotal** | **3** | |
| **Total** | **33** | |

### Condensed SPI fallback (30 pads — if allocation capped at 30)

Remove `SX_MOSI`, `SX_MISO`, `SX_SCK`; bridge to host SPI pads via PCB 0Ω resistors. Hardware OE gating required (see condensed SPI option section above). `CS_A[2:0]` and GPIO bank unchanged.

| Group | Pads |
|---|---|
| RX data (`IQ_DATA_I/Q[3:0]`) | 8 |
| Clock (`IQ_CLK`) | 1 |
| ΣΔ re-mod (`REMOD_A_I`, `REMOD_A_Q`) | 2 |
| SPI shared bus (`SPI_MOSI`, `SPI_MISO`, `SPI_SCK`, `HOST_CS`, `CS_A[2:0]`) | 7 |
| GPIO bank (`GPIO[7:0]`) | 8 |
| `RESETB` | 1 |
| **Signal subtotal** | **27** |
| Supply/ground | 3 |
| **Total** | **30** |

---

## Pads NOT on ASIC

The following signals are board-level only — no ASIC pad allocated:

| Signal | Reason | Disposition |
|---|---|---|
| SX1257 DIO0–DIO3 (×4 devices) | 0 spare ASIC pads | PLL lock polled via `RegModeStatus` (0x11) over SPI instead |
| SX1257 individual NSS (×4) | Replaced by 74HC138 decoder | ASIC drives 3-bit address `CS_A[2:0]`; decoder generates individual active-low NSS lines on the PCB |
| SX1257 RESET (pin 9, ×4) | 0 spare ASIC pads | Decision pending: floating (POR only) or RPi GPIO |
| SX1257 CLK_IN (pin 11, ×4) | Not needed — XTB shared TCXO used for lock | Leave NC on all 4 devices |
| SX1257 CLK_OUT (pin 10) | SX1257_1: CLK_OUT → SX1302 CLK_IN (PCB trace, no ASIC pad) | SX1257_2–4: leave NC |
| SE2435L CTX/CPS (ant 3/4) | Covered by GPIO bank | Any available `GPIO[7:0]` pin in non-JTAG, non-QSPI nibble; see [SE2435L Front-End Module](blocks/SE2435L%20Front-End%20Module.md) |

---

## Open items

- Physical pad placement / ordering around die perimeter — pending floorplan
- **Confirm chipathon pad allocation** — target is 33; condensed SPI fallback brings this to 30 if needed
- Confirm `RESETB` is a dedicated pad vs. managed by chipathon harness (Caravel or equivalent)
- Resolve SE2435L_3/4 CPS/CTX pin assignment within GPIO bank before PCB layout
- Resolve SX1257 RESET (floating vs. RPi-controlled via GPIO bank) before PCB layout
- **GPIO Mux block spec** — `IO_MUX_CTRL`, `GPIO_IRQ_SEL`, pad output-enable gating logic, and QSPI controller interface need a dedicated block document
- **Update SPI Master block spec** — reflect `CS_A[2:0]`, 74HC138 decode table, and QSPI CLK sharing note
- **IR drop verification required** — single VDD_CORE and single GND pad; floorplan must place power pad near highest switching-current block (ΣΔ decimators or PicoRV32) and rely on on-chip power mesh; may need decoupling capacitor cells near critical blocks
- **Pad-library assumption** — chipathon integration documentation provides 5V-capable GF180 IO cells, not native 3.3V-only pad cells; current plan is to run those pads from a 3.3V `VDD_IO` rail for 3.3V board signaling, accepting any speed impact noted by the integration team
- **Consider power ring strategy** — GF180MCU IO ring includes power rails; confirm whether VDD_CORE/GND pads feed a global ring or require explicit mesh routing in the core
