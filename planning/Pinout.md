# ASIC Pinout

GF180MCU MIMO ASIC logical pad list. Total: **26 pads** (**23 signal + 3 supply/ground**).

This pinout is within the Chipathon 2026 per-team allocation limit of **<=26 pads** and matches the current Trouper physical allocation in the chip specification.

**Related:** [System Architecture](System%20Architecture.md), [Trouper Chip Specification](Trouper%20Chip%20Specification.md)

---

## Signal pads (23)

All signal pads use **GF180 5 V-capable IO cells**, run at **3.3 V**. `VDD_CORE` and `VDD_IO` are **separate, independently-tunable rails** (NOT tied on-die), both **3.3 V at baseline** and matching all external parts (APS6404L PSRAM, SX1257 ×4, Raspberry Pi host). Keeping them independent is deliberate: if 32 MHz SS timing cannot be closed at 3.3 V, the **contingency** split-rail **5 V core / 3.6 V IO** (SS proven to close at the 4.5 V worst-case corner) can be applied **without a silicon respin**. That path's gating unknown is the GF180 core>pad IO down-shift — see [Open Risks](Open%20Risks.md) #27.

### RX data from SX1257 (8 pads, input)

| Pad name | Dir | Connected to | Description |
|---|---|---|---|
| `IQ_DATA_I[0]` | in | SX1257_0 I_OUT | 1-bit ΣΔ RX I stream, antenna 0 |
| `IQ_DATA_Q[0]` | in | SX1257_0 Q_OUT | 1-bit ΣΔ RX Q stream, antenna 0 |
| `IQ_DATA_I[1]` | in | SX1257_1 I_OUT | 1-bit ΣΔ RX I stream, antenna 1 |
| `IQ_DATA_Q[1]` | in | SX1257_1 Q_OUT | 1-bit ΣΔ RX Q stream, antenna 1 |
| `IQ_DATA_I[2]` | in | SX1257_2 I_OUT | 1-bit ΣΔ RX I stream, antenna 2 |
| `IQ_DATA_Q[2]` | in | SX1257_2 Q_OUT | 1-bit ΣΔ RX Q stream, antenna 2 |
| `IQ_DATA_I[3]` | in | SX1257_3 I_OUT | 1-bit ΣΔ RX I stream, antenna 3 |
| `IQ_DATA_Q[3]` | in | SX1257_3 Q_OUT | 1-bit ΣΔ RX Q stream, antenna 3 |

### Clock and reset (2 pads, input)

| Pad name | Dir | Connected to | Description |
|---|---|---|---|
| `IQ_CLK` | in | PCB TCXO buffer | 32 MHz master clock shared by ASIC and SX1257 receivers |
| `RESETB` | in | PCB reset / host | Active-low global reset |

### ΣΔ re-mod outputs to SX1302 (2 pads, output)

| Pad name | Dir | Connected to | Description |
|---|---|---|---|
| `REMOD_A_I` | out | SX1302 Radio A I | 1-bit ΣΔ MRC-combined output stream (I) |
| `REMOD_A_Q` | out | SX1302 Radio A Q | 1-bit ΣΔ MRC-combined output stream (Q) |

### PSRAM dedicated control (2 pads, output)

| Pad name | Dir | Connected to | Description |
|---|---|---|---|
| `PSRAM_SCK` | out | APS6404L `CLK` | PSRAM serial clock |
| `PSRAM_CE_N` | out | APS6404L `CE#` | PSRAM active-low chip enable |

### Host SPI (4 pads)

Dedicated interface for external register access and bring-up.

| Pad name | Dir | Connected to | Description |
|---|---|---|---|
| `SPI_MOSI` | in | Host SPI MOSI | Host-to-Trouper register writes and commands |
| `SPI_MISO` | out | Host SPI MISO | Trouper-to-host readback |
| `SPI_SCK` | in | Host SPI SCK | SPI clock, Mode 0, up to 10 MHz |
| `HOST_CS` | in | Host SPI chip select | Active-low slave select |

### Interrupt output (1 pad, output)

| Pad name | Dir | Connected to | Description |
|---|---|---|---|
| `IRQ_OUT` | out | Host RPi IRQ GPIO | Dedicated level-high sticky interrupt (packet ready, preamble lock, etc.). Mirrors the inter-project `IRQ_GROUPER` line. |

### PSRAM data bus (4 pads, bidirectional)

Dedicated PSRAM QPI data nibble. JTAG and GPIO have been removed (no TAP in RTL; see Trouper Chip Specification §4.16), so these four pads carry only `PSRAM_SIO[3:0]`.

| Pad name | Dir | Connected to | Description |
|---|---|---|---|
| `PSRAM_SIO[0]` | bidir | APS6404L `SIO0` | PSRAM QPI data bit 0 |
| `PSRAM_SIO[1]` | bidir | APS6404L `SIO1` | PSRAM QPI data bit 1 |
| `PSRAM_SIO[2]` | bidir | APS6404L `SIO2` | PSRAM QPI data bit 2 |
| `PSRAM_SIO[3]` | bidir | APS6404L `SIO3` | PSRAM QPI data bit 3 |

---

## Supply and ground pads (3 pads)

| Pad name | Voltage | Count | Description |
|---|---|---|---|
| `VDD_IO` | 3.3 V (baseline) | 1 | Pad-ring supply — separate, independently-tunable rail (3.3 V-class externals) |
| `VDD_CORE` | 3.3 V (baseline) | 1 | Digital core supply — separate, independently-tunable rail |
| `GND` | 0 V | 1 | Shared ground |

> **Voltage plan:** `VDD_CORE` and `VDD_IO` are **separate rails**, both **3.3 V at baseline** (all external parts native 3.3 V). The open item is that 32 MHz SS timing does not close at the 3.0 V slow corner (Open Risks item 1). Because the rails are **independently tunable**, the **contingency** — split-rail **5 V core / 3.6 V IO** — can be applied without a respin: SS proven to close at the 4.5 V worst-case corner (SS = +1.40 ns, DRC/LVS clean), external parts safe at 3.6 V (PSRAM 4.0 V / SX1257 3.9 V / RPi clamp ~3.9 V), gated only on GF180 core>pad IO-cell characterization ([Open Risks](Open%20Risks.md) #27).

---

## Inter-Project Interconnect (No ASIC Pads)

The following signals connect Trouper to the Grouper project on the same MPW. They are internal interconnects and do not consume Trouper package pads.

| Interface | Signals | Description |
|---|---|---|
| Grouper register bus (AHB-Lite slave) | target: `HSEL/HADDR/HTRANS/HWRITE/HSIZE/HWDATA/HRDATA/HREADYOUT/HRESP`; current placeholder: `GRP_ADDR[7:0]`, `GRP_WDATA[7:0]`, `GRP_WE`, `GRP_RE`, `GRP_RDATA[7:0]`, `GRP_READY` | Grouper (AHB-Lite master) accesses Trouper's reg_bank as an AHB-Lite slave peripheral via a small adapter. **Inter-project MPW wires only — not bonded to any package pad.** Current RTL still exposes the simplified `GRP_*` byte bus pending the adapter (see Trouper Chip Specification §5.2). |
| Interrupt | `IRQ_GROUPER` | Internal interrupt line from Trouper to Grouper (mirrors the dedicated `IRQ_OUT` pad) |

---

## Pads Not Allocated

- **SX1257 DIO pins:** Not connected to Trouper pads. AFE polling and bring-up remain external to Trouper.
- **SX1257 `CLK_IN`:** Not connected; the radios and ASIC share the board clock reference instead.
- **AFE chip-select / configuration pins:** Not allocated to Trouper package pads in the current revision.
- **Additional PSRAM control pins:** Not required. The current allocation uses dedicated `PSRAM_SCK` and `PSRAM_CE_N`, with `PSRAM_SIO[3:0]` on four dedicated data pads.
- **JTAG / GPIO pins:** Removed. No JTAG TAP is instantiated in the RTL and GPIO was never wired out of the macro; host debug uses the SPI register / PSRAM-readback path. See Trouper Chip Specification §4.16.
- **`sc_lock_in`/`sc_lock_out` (NR2/3 cascade OR-lock, deferred):** No pad available — the current allocation is already at the 26-pad budget. The internal OR-lock logic these pins would drive already exists as a register (`SC_FORCE_LOCK`, `reg_bank` 0x19, see `planning/Register Map.md` `0x19` and `planning/NR2-multi-ASIC-cascade.md`); if a spare pad opens up (e.g. from a future GPIO/JTAG-style feature removal elsewhere), bond it to `sc_lock_in` OR'd into the same internal `sc_lock_force` signal rather than adding a second mechanism. `IRQ_OUT` cannot double as this pin — it is output-only.
