# ASIC Pinout

GF180MCU MIMO ASIC — logical pad list. Total: **23 pads** (20 signal + 3 supply/ground).

This pinout follows the Chipathon 2026 per-team allocation limit of ≤25 pads.

**Related:** [System Architecture](System%20Architecture.md), [Trouper Chip Specification](Trouper%20Chip%20Specification.md)

---

## Signal pads (20)

All signal pads use **GF180 5V-capable IO cells** operated on a **3.3V `VDD_IO` rail**. Core logic runs at **3.3V**.

### RX data from SX1257 (8 pads, input)

| Pad name | Dir | Connected to | Description |
|---|---|---|---|
| `IQ_DATA_I[n]` | in | SX1257_n I_OUT | 1-bit ΣΔ RX I stream, antennas 1–4 |
| `IQ_DATA_Q[n]` | in | SX1257_n Q_OUT | 1-bit ΣΔ RX Q stream, antennas 1–4 |

### Clock (1 pad, input)

| Pad name | Dir | Connected to | Description |
|---|---|---|---|
| `IQ_CLK` | in | PCB TCXO buffer | 32 MHz master clock. Shared reference for ASIC and SX1257s. |

### ΣΔ re-mod outputs to SX1302 (2 pads, output)

| Pad name | Dir | Connected to | Description |
|---|---|---|---|
| `REMOD_A_I` | out | SX1302 Radio A I | 1-bit ΣΔ MRC combined stream (I) |
| `REMOD_A_Q` | out | SX1302 Radio A Q | 1-bit ΣΔ MRC combined stream (Q) |

### Host SPI — Trouper dedicated control (4 pads, input/output)

Dedicated interface for external host register access and debug (e.g., Raspberry Pi).

| Pad name | Dir | Connected to | Description |
|---|---|---|---|
| `SPI_MOSI` | in | RPi SPI0 MOSI | Host-to-ASIC register writes and debug commands |
| `SPI_MISO` | out | RPi SPI0 MISO | ASIC-to-host readback |
| `SPI_SCK` | in | RPi SPI0 SCLK | Host SPI clock (up to 10 MHz) |
| `HOST_CS` | in | RPi SPI0 CE1 | Active-low slave select |

### Chip Reset (1 pad, input)

| Pad name | Dir | Connected to | Description |
|---|---|---|---|
| `RESETB` | in | PCB Reset / RPi | Active-low global reset. |

### JTAG / IRQ / GPIO nibble (4 pads, muxed)

Muxed pads providing debug, interrupt, and general-purpose IO. Function is selected by `JTAG_EN`.

| Pad name | JTAG_EN=0 | JTAG_EN=1 | Description |
|---|---|---|---|
| `TCK_IRQ` | `IRQ` (out) | `TCK` (in) | Interrupt / JTAG Clock |
| `TMS_GPIO0` | `GPIO[0]` | `TMS` (in) | GPIO / JTAG Mode |
| `TDI_GPIO1` | `GPIO[1]` | `TDI` (in) | GPIO / JTAG Data In |
| `TDO_GPIO2` | `GPIO[2]` | `TDO` (out) | GPIO / JTAG Data Out |

---

## Supply and ground pads (3 pads)

| Pad name | Voltage | Count | Description |
|---|---|---|---|
| `VDD_IO` | 3.3V | 1 | IO ring supply |
| `VDD_CORE` | 3.3V | 1 | Digital core supply |
| `GND` | 0V | 1 | Shared ground |

---

## Inter-Project Interconnect (No ASIC Pads)

The following signals connect Trouper to the **Grouper** project on the same MPW. These are internal "wires" or shared harness signals and do not consume Trouper project pads.

| Interface | Signals | Description |
|---|---|---|
| AHB-Lite Bus | `HADDR`, `HWDATA`, `HRDATA`, etc. | Connecting Grouper (Master) to Trouper (Slave) |
| IRQ | `IRQ_TO_CPU` | Internal interrupt line to Grouper's PicoRV32 |

---

## Pads NOT on ASIC

- **SX1257 DIOs:** Not connected to Trouper pads. Any AFE polling or bring-up control is handled outside Trouper's hardened RTL.
- **SX1257 CLK_IN:** Not needed; using shared TCXO reference.
- **AFE chip-select / config pins:** No Trouper `CS_A[1:0]` outputs are allocated in the current revision. AFE configuration is board/system logic territory, not a Trouper pad function.
- **PSRAM QSPI:** The current 23-pad plan excludes dedicated PSRAM pads. Same-packet replay via PSRAM therefore requires either shared/internal routing not yet committed or a future larger-pad revision.
